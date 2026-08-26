package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
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
}

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
	}
	cfg.SidebarCmd = envOr("SUZU_SIDEBAR_CMD", cfg.defaultSidebarCmd())
	return cfg
}

// サイドバー pane は suzu 自身を sidebar サブコマンドで起動する。
// インストール場所に依存しないよう実行中のバイナリの絶対パスを使う
func (c Config) defaultSidebarCmd() string {
	return c.exportedEnv() + " " + shellQuote(executablePath()) + " sidebar"
}

// 子プロセス (サイドバー・注入したキーバインド) へ引き継ぐ設定。
// tmux の pane やキーバインドは親の環境を継がないため、コマンド行へ焼き込む
func (c Config) exportedEnv() string {
	return strings.Join([]string{
		"SUZU_OUTER_SOCKET=" + shellQuote(c.OuterSocket),
		"SUZU_INNER_TMUX=" + shellQuote(strings.Join(c.InnerTmux, " ")),
		"SUZU_INNER_JUMP_KEY=" + shellQuote(c.JumpKey),
		"SUZU_INNER_TOGGLE_KEY=" + shellQuote(c.ToggleKey),
		"SUZU_SIDEBAR_WIDTH=" + shellQuote(strconv.Itoa(c.SidebarWidth)),
		"SUZU_DOORBELL_FILE=" + shellQuote(c.DoorbellFile),
	}, " ")
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
