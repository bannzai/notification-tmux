package main

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	// 外側 tmux の socket 名・session 名の既定値と、サイドバー pane に付ける目印。
	// 目印は「サイドバーでない pane = 内側 attach」を引くためにも使う
	defaultOuterSocket = "suzu"
	outerSession       = "suzu"
	sidebarPaneOption  = "@suzu-sidebar"
	// 外側の window は 1 枚固定
	outerWindow = outerSession + ":0"
)

// suzu が外側 / 内側 tmux と doorbell ファイルへ到達するための設定。
// すべて環境変数で与えられ、start が sidebar / focus / toggle の各プロセスへ引き継ぐ
type Config struct {
	// 内側 tmux server へ命令するコマンド。"tmux -L socket" のような複数語を許すため slice
	InnerTmux   []string
	OuterSocket string
	// 右 pane で実行する内側への接続コマンド
	InnerAttach string
	// 内側 tmux が「サイドバーへ」「表示/非表示」に使う prefix 後のキー。
	// サイドバーは JumpKey と同じキーで内側へ戻し、往復を対称にする
	JumpKey      string
	ToggleKey    string
	SidebarWidth int
	// 左 pane で実行するコマンド (シェルに渡す 1 行)
	SidebarCmd   string
	DoorbellFile string
	// 通知とは別に「特定のプロセスが動いている pane」を並べるセクション。
	// 組み込みの Claude / Codex の後ろに設定ファイルの section 行が続く
	Sections []sectionRule
	// pane 内のプロセスと内容を見直す間隔。tmux はプロセスの起動・終了や画面の変化を
	// イベントとして通知しないため、この間隔だけは時間駆動になる。0 で止める
	ScrapeInterval time.Duration
	ConfigFile     string
}

// サイドバーのセクション 1 つ分の定義。Process はプロセス名 (実行ファイルやスクリプトの basename)
type sectionRule struct {
	Title   string
	Process string
	// pane の内容から 実行中 / 入力待ち を判定する対象 (Claude Code / Codex CLI)
	Agent bool
}

// 設定が無くても出る組み込みセクション。Claude Code のプロセス名は claude、
// Codex CLI は node のラッパー (bin/codex) が同名のネイティブバイナリを起動する
var builtinSections = []sectionRule{
	{Title: "Claude", Process: "claude", Agent: true},
	{Title: "Codex", Process: "codex", Agent: true},
}

const defaultScrapeInterval = 5 * time.Second

func loadConfig() Config {
	inner := strings.Fields(os.Getenv("SUZU_INNER_TMUX"))
	if len(inner) == 0 {
		inner = []string{"tmux"}
	}
	cfg := Config{
		InnerTmux:    inner,
		OuterSocket:  envOr("SUZU_OUTER_SOCKET", defaultOuterSocket),
		InnerAttach:  envOr("SUZU_INNER_TMUX_CMD", strings.Join(inner, " ")+" attach"),
		JumpKey:      envOr("SUZU_INNER_JUMP_KEY", "N"),
		ToggleKey:    envOr("SUZU_INNER_TOGGLE_KEY", "b"),
		SidebarWidth: intEnvOr("SUZU_SIDEBAR_WIDTH", defaultWidth),
		DoorbellFile: doorbellFile(),
		ConfigFile:   configFile(),
		// defaultSidebarCmd は exportedEnv() 経由で ScrapeInterval を焼き込むため、
		// SidebarCmd を組み立てる前に確定させる
		ScrapeInterval: time.Duration(intEnvOrZero("SUZU_SCRAPE_INTERVAL", int(defaultScrapeInterval/time.Second))) * time.Second,
	}
	cfg.SidebarCmd = envOr("SUZU_SIDEBAR_CMD", cfg.defaultSidebarCmd())
	cfg.Sections = append(append([]sectionRule{}, builtinSections...), loadSectionRules(cfg.ConfigFile)...)
	return cfg
}

// 設定ファイルの section 行を読む。ファイルが無いのは通常の状態なので黙って空を返し、
// 書式の誤りは行ごとに stderr へ知らせて読み飛ばす (start を打った端末に出る)
func loadSectionRules(path string) []sectionRule {
	file, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer file.Close()
	rules, warnings := parseSectionRules(bufio.NewScanner(file))
	for _, warning := range warnings {
		fmt.Fprintf(os.Stderr, "%s: %s\n", path, warning)
	}
	return rules
}

// 設定ファイルは Noroshi の config (documents/adr/0004) と同じ key = value 形式。
//
//	# セクション名:プロセス名
//	section = Watchers:tmux-issue-watcher
//
// section 以外のキーは将来の拡張のために読み飛ばす
func parseSectionRules(scanner *bufio.Scanner) (rules []sectionRule, warnings []string) {
	lineNumber := 0
	for scanner.Scan() {
		lineNumber++
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, found := strings.Cut(line, "=")
		if !found {
			warnings = append(warnings, fmt.Sprintf("%d 行目: key = value の形ではありません: %q", lineNumber, line))
			continue
		}
		if strings.TrimSpace(key) != "section" {
			continue
		}
		title, process, found := strings.Cut(strings.TrimSpace(value), ":")
		title, process = strings.TrimSpace(title), strings.TrimSpace(process)
		if !found || title == "" || process == "" {
			warnings = append(warnings, fmt.Sprintf("%d 行目: section は セクション名:プロセス名 の形で書きます: %q", lineNumber, line))
			continue
		}
		rules = append(rules, sectionRule{Title: title, Process: process})
	}
	return rules, warnings
}

// サイドバー pane は suzu 自身を sidebar サブコマンドで起動する。
// インストール場所に依存しないよう実行中のバイナリの絶対パスを使う
func (c Config) defaultSidebarCmd() string {
	return c.exportedEnv() + " " + shellQuote(executablePath()) + " sidebar"
}

// SidebarCmd / InnerAttach は他の設定から既定値を組み立てるため、Config の値を
// 無条件に焼き込むと引き継ぐたびに入れ子で肥大する (SUZU_SIDEBAR_CMD の既定値は
// exportedEnv 自身を含む)。ユーザーが明示した時だけ引き継ぐ
var explicitOnlyEnv = []string{"SUZU_SIDEBAR_CMD", "SUZU_INNER_TMUX_CMD", "SUZU_CONFIG_FILE"}

// 子プロセス (サイドバー・注入したキーバインド) へ引き継ぐ設定。
// tmux の pane やキーバインドは親の環境を継がないため、コマンド行へ焼き込む
func (c Config) exportedEnv() string {
	exported := []string{
		"SUZU_OUTER_SOCKET=" + shellQuote(c.OuterSocket),
		"SUZU_INNER_TMUX=" + shellQuote(strings.Join(c.InnerTmux, " ")),
		"SUZU_INNER_JUMP_KEY=" + shellQuote(c.JumpKey),
		"SUZU_INNER_TOGGLE_KEY=" + shellQuote(c.ToggleKey),
		"SUZU_SIDEBAR_WIDTH=" + shellQuote(strconv.Itoa(c.SidebarWidth)),
		"SUZU_DOORBELL_FILE=" + shellQuote(c.DoorbellFile),
		"SUZU_SCRAPE_INTERVAL=" + shellQuote(strconv.Itoa(int(c.ScrapeInterval/time.Second))),
	}
	for _, name := range explicitOnlyEnv {
		if value := os.Getenv(name); value != "" {
			exported = append(exported, name+"="+shellQuote(value))
		}
	}
	return strings.Join(exported, " ")
}

func envOr(name, fallback string) string {
	if value := os.Getenv(name); value != "" {
		return value
	}
	return fallback
}

func intEnvOr(name string, fallback int) int {
	value, err := strconv.Atoi(os.Getenv(name))
	if err != nil || value <= 0 {
		return fallback
	}
	return value
}

// 0 を「止める」の意味で受け付ける整数。未設定や不正な値は fallback
func intEnvOrZero(name string, fallback int) int {
	raw, set := os.LookupEnv(name)
	if !set {
		return fallback
	}
	value, err := strconv.Atoi(raw)
	if err != nil || value < 0 {
		return fallback
	}
	return value
}

func doorbellFile() string {
	if path := os.Getenv("SUZU_DOORBELL_FILE"); path != "" {
		return path
	}
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = filepath.Join(os.Getenv("HOME"), ".local", "state")
	}
	return filepath.Join(state, "suzu", "doorbell")
}

func configFile() string {
	if path := os.Getenv("SUZU_CONFIG_FILE"); path != "" {
		return path
	}
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" {
		config = filepath.Join(os.Getenv("HOME"), ".config")
	}
	return filepath.Join(config, "suzu", "config")
}

func executablePath() string {
	path, err := os.Executable()
	if err != nil {
		// 取得できない環境でも PATH 経由で動けるように名前だけ返す
		return "suzu"
	}
	return path
}

// tmux へ渡すコマンド行はシェルで解釈されるため、値をシングルクオートで包む
func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}
