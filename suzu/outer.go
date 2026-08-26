package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"

	"github.com/mattn/go-isatty"
)

// 外側「額縁」tmux の設定。~/.tmux.conf を読ませないため server は -f /dev/null で起動し、
// ここの値だけを set-option で入れる。
//
// ~/.tmux.conf を読ませない理由: tpm 経由で tmux-resurrect / tmux-continuum が外側にも入り、
// 全 server で共有される ~/.tmux/resurrect/ の last symlink を外側の保存が汚し得る。
// 外側はステートレス (保存すべき状態が無い) なので、プラグインは一切読み込まない
var outerOptions = []struct {
	name  string
	value string
}{
	// キーをすべて内側へ素通しする: prefix を持たず、bind も一切定義しない。
	// フォーカス移動は「内側 tmux の prefix バインド (start が注入) → 外側へ select-pane」と
	// 「サイドバー側のキー処理」で行い、外側はキーを 1 つも掴まない
	{"prefix", "None"},
	{"prefix2", "None"},

	// 額縁としての最小化: status line を持たず、window は 1 枚だけの前提
	{"status", "off"},

	// サイドバー pane のクリック選択と、内側へのマウスイベント転送のために on
	// (内側 client は mouse を掴んでいるため wheel/クリックは内側へ転送される)
	{"mouse", "on"},

	// 内側 tmux からの escape sequence (OSC52 等) を実端末へ透過する
	{"allow-passthrough", "all"},
	{"set-clipboard", "external"},

	// nested での ESC 遅延をなくす
	{"escape-time", "0"},
	{"focus-events", "on"},

	{"default-terminal", "tmux-256color"},

	// スクロールバックは内側 tmux に任せ、外側では持たない
	{"history-limit", "0"},

	// どちらの pane にフォーカスがあるか分かるように、境界線と背景の両方で差をつける。
	// 色はユーザーのライトテーマ端末 (内側 tmux の通知 hook が #effbe9 / #f5e6d0 のような
	// 明るい背景を使う) で見た時のコントラストで選んでいる。暗い端末に移る場合は
	// window-style の背景を colour236 前後へ、border の色を明るい側へ振り直すこと。
	//
	// heavy = 太い罫線。single だと 1px の細線でライト背景に埋もれる
	{"pane-border-lines", "heavy"},
	// 境界線はフォーカス位置に関わらず常に同じ彩度の高い橙 (#ff5f00) 1 色にする。
	// tmux は 2 pane の境界セルを上下でアクティブ/非アクティブ style 混在で描くため
	// (capture-pane -e の実測: 上側 colour250・下側 colour202 に分かれた)、
	// 2 色に分けると線が上下で途切れて見える。フォーカス位置は下の window-style の
	// 背景の明暗が示すので、境界線に役割を持たせない
	{"pane-border-style", "fg=colour202,bold"},
	{"pane-active-border-style", "fg=colour202,bold"},

	// 非アクティブ pane を暗くする。window-style は「その window のすべての pane」、
	// window-active-style は「アクティブ pane」に当たるため、後者だけ地の色に戻すと
	// 非アクティブ側だけが暗くなる。colour253 (#dadada) は白背景から一段落とした薄いグレーで、
	// 文字色を変えずに読める範囲に収めている。
	// bg=default ではなく bg=terminal を使う: tmux の style における default は
	// 「継承元 (= window-style) の値」を指すため、default だと両 pane が同じ背景になる
	{"window-style", "bg=colour253"},
	{"window-active-style", "bg=terminal"},
}

// 外側 server を作る時の初期サイズ。実端末が attach した時点でその大きさに追随する
const (
	outerInitialWidth  = 220
	outerInitialHeight = 60
)

func outerExists(cfg Config) bool {
	return cfg.outerCommand("has-session", "-t", outerSession).Run() == nil
}

func sidebarPaneID(cfg Config) string {
	out, err := output(cfg.outerCommand("list-panes", "-t", outerWindow,
		"-f", "#{"+sidebarPaneOption+"}", "-F", "#{pane_id}"))
	if err != nil {
		return ""
	}
	return firstLine(out)
}

func firstLine(out string) string {
	return strings.TrimSpace(strings.SplitN(out, "\n", 2)[0])
}

// サイドバー pane が無ければ左側に作る (あれば何もしない = 冪等)
func openSidebar(cfg Config) error {
	if sidebarPaneID(cfg) != "" {
		return nil
	}
	out, err := output(cfg.outerCommand("split-window", "-hb", "-d", "-P", "-F", "#{pane_id}",
		"-l", strconv.Itoa(cfg.SidebarWidth), "-t", outerWindow, cfg.SidebarCmd))
	if err != nil {
		return fmt.Errorf("サイドバー pane の作成に失敗: %w", err)
	}
	paneID := firstLine(out)
	if err := cfg.outerCommand("set-option", "-p", "-t", paneID, sidebarPaneOption, "1").Run(); err != nil {
		return fmt.Errorf("サイドバー pane の目印付けに失敗: %w", err)
	}
	return nil
}

// 内側 tmux へ「サイドバーへフォーカス」「サイドバーの表示/非表示」を注入する
// (メモリ上のみ・冪等)。内側 server が起動していない場合は何もしない。
// run-shell に渡すのは実行中バイナリの絶対パスなので、インストール場所に依存しない
func installInnerKeys(cfg Config) {
	exe := shellQuote(executablePath())
	cfg.innerCommand("bind-key", cfg.JumpKey, "run-shell",
		"SUZU_OUTER_SOCKET="+shellQuote(cfg.OuterSocket)+" "+exe+" focus sidebar").Run()
	// toggle は閉じたサイドバーを作り直すため、pane に渡す env も揃えて焼き込む
	cfg.innerCommand("bind-key", cfg.ToggleKey, "run-shell",
		cfg.exportedEnv()+" "+exe+" toggle").Run()
}

// 内側 tmux の「どこかで set-option された」を doorbell ファイルへ伝える hook を注入する
// (メモリ上のみ・冪等)。control mode の購読は attach 中 session の pane に限られるため、
// 別 session の @claude-waiting を拾う経路はこの global hook が担う。
// hook 内で set-option すると再帰発火するため touch しか行わない
func installDoorbellHook(cfg Config) {
	if err := os.MkdirAll(filepath.Dir(cfg.DoorbellFile), 0o755); err != nil {
		return
	}
	cfg.innerCommand("set-hook", "-g", "after-set-option",
		"run-shell -b "+shellQuote("touch "+shellQuote(cfg.DoorbellFile))).Run()
}

func cmdStart(cfg Config) error {
	interactive := isTerminal(os.Stdin)
	if interactive && os.Getenv("TMUX") != "" {
		return fmt.Errorf("tmux の中から start しないでください (外側が二重にネストします)。新しいターミナル pane から実行してください")
	}
	if !outerExists(cfg) {
		// -f は server 起動時のみ効くため、server を生む new-session に付ける
		newSession := cfg.outerCommand("-f", "/dev/null", "new-session", "-d", "-s", outerSession,
			"-x", strconv.Itoa(outerInitialWidth), "-y", strconv.Itoa(outerInitialHeight),
			"TMUX= "+cfg.InnerAttach)
		if err := newSession.Run(); err != nil {
			return fmt.Errorf("外側 tmux の起動に失敗: %w", err)
		}
		for _, option := range outerOptions {
			if err := cfg.outerCommand("set-option", "-g", option.name, option.value).Run(); err != nil {
				return fmt.Errorf("外側の %s 設定に失敗: %w", option.name, err)
			}
		}
		if err := openSidebar(cfg); err != nil {
			return err
		}
	}
	installInnerKeys(cfg)
	installDoorbellHook(cfg)

	if interactive {
		return attachOuter(cfg)
	}
	fmt.Printf("外側 tmux (socket: %s) を構築しました。attach: tmux -L %s attach -t %s\n",
		cfg.OuterSocket, cfg.OuterSocket, outerSession)
	return nil
}

// 端末を tmux へ明け渡す。中間プロセスを残さないよう exec で置き換える
func attachOuter(cfg Config) error {
	tmuxPath, err := exec.LookPath("tmux")
	if err != nil {
		return fmt.Errorf("tmux が見つかりません: %w", err)
	}
	argv := []string{"tmux", "-L", cfg.OuterSocket, "attach", "-t", outerSession}
	return syscall.Exec(tmuxPath, argv, os.Environ())
}

func cmdToggle(cfg Config) error {
	if !outerExists(cfg) {
		return fmt.Errorf("外側 tmux がありません。先に start してください")
	}
	if paneID := sidebarPaneID(cfg); paneID != "" {
		if err := cfg.outerCommand("kill-pane", "-t", paneID).Run(); err != nil {
			return fmt.Errorf("サイドバーを閉じられません: %w", err)
		}
		return nil
	}
	return openSidebar(cfg)
}

func cmdFocus(cfg Config, target string) error {
	if !outerExists(cfg) {
		return fmt.Errorf("外側 tmux がありません。先に start してください")
	}
	if target == "toggle" {
		out, err := output(cfg.outerCommand("list-panes", "-t", outerWindow,
			"-f", "#{pane_active}", "-F", "#{"+sidebarPaneOption+"}"))
		if err == nil && firstLine(out) == "1" {
			target = "inner"
		} else {
			target = "sidebar"
		}
	}
	switch target {
	case "sidebar":
		if err := openSidebar(cfg); err != nil {
			return err
		}
		return focusPane(cfg, sidebarPaneID(cfg))
	case "inner":
		return focusInner(cfg)
	}
	return fmt.Errorf("usage: suzu focus {sidebar|inner|toggle}")
}

func cmdStatus(cfg Config) error {
	if !outerExists(cfg) {
		fmt.Printf("外側 tmux (socket: %s): 未起動\n", cfg.OuterSocket)
		return nil
	}
	fmt.Printf("外側 tmux (socket: %s): 起動中\n", cfg.OuterSocket)
	out, err := output(cfg.outerCommand("list-panes", "-t", outerWindow,
		"-F", "  pane #{pane_id} #{pane_width}x#{pane_height} active=#{pane_active} sidebar=#{"+sidebarPaneOption+"} cmd=#{pane_current_command}"))
	if err != nil {
		return fmt.Errorf("pane の一覧取得に失敗: %w", err)
	}
	fmt.Print(out)
	return nil
}

func cmdStop(cfg Config) error {
	// 注入したキーバインドと hook の解除は外側の有無に関わらず行う (冪等)
	cfg.innerCommand("unbind-key", cfg.JumpKey).Run()
	cfg.innerCommand("unbind-key", cfg.ToggleKey).Run()
	cfg.innerCommand("set-hook", "-gu", "after-set-option").Run()
	if !outerExists(cfg) {
		fmt.Printf("外側 tmux (socket: %s): 未起動\n", cfg.OuterSocket)
		return nil
	}
	if err := cfg.outerCommand("kill-server").Run(); err != nil {
		return fmt.Errorf("外側 tmux の停止に失敗: %w", err)
	}
	fmt.Printf("外側 tmux (socket: %s) を停止しました (内側 tmux には触れていません)\n", cfg.OuterSocket)
	return nil
}

// ModeCharDevice では /dev/null も真になるため、実際の tty かどうかを ioctl で見る
func isTerminal(file *os.File) bool {
	return isatty.IsTerminal(file.Fd()) || isatty.IsCygwinTerminal(file.Fd())
}
