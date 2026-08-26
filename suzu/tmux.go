package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// @claude-waiting が set された window 1 件。pane と window の両方に set されるため
// window 単位に畳んだ後の姿を表す
type Notification struct {
	Session     string
	WindowID    string
	WindowIndex string
	WindowName  string
	PaneID      string
	Icon        string
}

// 外側 tmux でサイドバーの隣にいる pane。内側 tmux へ attach している右 pane を指す
type innerPane struct {
	ID  string
	TTY string
}

const (
	waitingFilter   = "#{?#{@claude-waiting},1,0}"
	waitingFormat   = "#{session_name}\t#{window_id}\t#{window_index}\t#{window_name}\t#{pane_id}\t#{@claude-waiting}"
	clientFormat    = "#{client_name}\t#{client_control_mode}\t#{client_tty}"
	innerPaneFilter = "#{?#{" + sidebarPaneOption + "},0,1}"
	innerPaneFormat = "#{pane_id}\t#{pane_tty}"
)

// サイドバーは外側 tmux の pane で動くため $TMUX は外側 server を指す。
// そのまま内側 tmux を呼ぶと外側 server に命令が飛ぶので必ず落とす
func tmuxEnv() []string {
	env := os.Environ()
	kept := env[:0]
	for _, kv := range env {
		if strings.HasPrefix(kv, "TMUX=") || strings.HasPrefix(kv, "TMUX_PANE=") {
			continue
		}
		kept = append(kept, kv)
	}
	return kept
}

func (c Config) innerCommand(args ...string) *exec.Cmd {
	argv := append(append([]string{}, c.InnerTmux[1:]...), args...)
	cmd := exec.Command(c.InnerTmux[0], argv...)
	cmd.Env = tmuxEnv()
	return cmd
}

func (c Config) outerCommand(args ...string) *exec.Cmd {
	cmd := exec.Command("tmux", append([]string{"-L", c.OuterSocket}, args...)...)
	cmd.Env = tmuxEnv()
	return cmd
}

func output(cmd *exec.Cmd) (string, error) {
	out, err := cmd.Output()
	return string(out), err
}

func fetchNotifications(cfg Config) notificationsMsg {
	out, err := output(cfg.innerCommand("list-panes", "-a", "-f", waitingFilter, "-F", waitingFormat))
	if err != nil {
		// 内側 server が落ちている等。通知なし扱いにして理由だけ添える
		return notificationsMsg{err: fmt.Errorf("通知一覧の取得に失敗: %w", err)}
	}
	return notificationsMsg{items: parseNotifications(out)}
}

// list-panes の出力を window 単位に畳む。-p と -w の両方に set された window は
// 複数行で出てくるため、最初の行 (= 最初に見つかった icon) を代表にする
func parseNotifications(out string) []Notification {
	var items []Notification
	seen := map[string]bool{}
	for _, line := range strings.Split(out, "\n") {
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 6 || fields[1] == "" {
			continue
		}
		if seen[fields[1]] {
			continue
		}
		seen[fields[1]] = true
		items = append(items, Notification{
			Session:     fields[0],
			WindowID:    fields[1],
			WindowIndex: fields[2],
			WindowName:  fields[3],
			PaneID:      fields[4],
			Icon:        fields[5],
		})
	}
	return items
}

// 切り替えるべき内側 tmux の client を選ぶ。ユーザーの実環境では普段の端末からの attach も
// 生きているため実 client が複数あり、tty が右 pane と一致するものを選ばないと
// サイドバーから見えていない別の client を切り替えてしまう。
// control mode client (サイドバー自身が張っている購読) は常に除外する
func parseRealClient(out string, paneTTY string) string {
	fallback := ""
	for _, line := range strings.Split(out, "\n") {
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 3 || fields[0] == "" {
			continue
		}
		name, controlMode, tty := fields[0], fields[1], fields[2]
		if controlMode == "1" || tty == "" {
			continue
		}
		if tty == paneTTY {
			return name
		}
		if fallback == "" {
			fallback = name
		}
	}
	return fallback
}

func parseInnerPane(out string) (innerPane, bool) {
	fields := strings.Split(strings.TrimSpace(strings.SplitN(out, "\n", 2)[0]), "\t")
	if len(fields) != 2 || fields[0] == "" {
		return innerPane{}, false
	}
	return innerPane{ID: fields[0], TTY: fields[1]}, true
}

func fetchInnerPane(cfg Config) (innerPane, error) {
	out, err := output(cfg.outerCommand("list-panes", "-t", outerWindow,
		"-f", innerPaneFilter, "-F", innerPaneFormat))
	if err != nil {
		return innerPane{}, fmt.Errorf("外側 pane の列挙に失敗: %w", err)
	}
	pane, ok := parseInnerPane(out)
	if !ok {
		return innerPane{}, fmt.Errorf("外側に内側 pane が見つかりません")
	}
	return pane, nil
}

// 通知の window を内側で表示する。フォーカスはサイドバーに残し、右 pane へ移るのは
// prefix + jump key / q / Esc の明示操作だけにする
func jump(cfg Config, n Notification) error {
	pane, err := fetchInnerPane(cfg)
	if err != nil {
		return err
	}
	if err := cfg.innerCommand("select-window", "-t", n.WindowID).Run(); err != nil {
		return fmt.Errorf("select-window に失敗: %w", err)
	}
	out, err := output(cfg.innerCommand("list-clients", "-F", clientFormat))
	if err != nil {
		return fmt.Errorf("list-clients に失敗: %w", err)
	}
	client := parseRealClient(out, pane.TTY)
	if client == "" {
		return fmt.Errorf("内側 tmux の実 client が見つかりません")
	}
	if err := cfg.innerCommand("switch-client", "-c", client, "-t", n.Session).Run(); err != nil {
		return fmt.Errorf("switch-client に失敗: %w", err)
	}
	return nil
}

// 選択中の通知が出ている pane の見た目を、カーソル移動と一覧更新の時だけ取りに行く。
// pane が消えている等で失敗したらプレビューを畳むだけにして、サイドバーは動かし続ける
func fetchPreview(cfg Config, paneID string, limit int) []string {
	out, err := output(cfg.innerCommand("capture-pane", "-p", "-t", paneID))
	if err != nil {
		return nil
	}
	return previewLines(out, limit)
}

// pane の下半分は空行で埋まっているのが普通なので、空行を落としてから末尾を取る。
// 幅の狭いサイドバーでは行数を情報のある行だけに使いたい
func previewLines(out string, limit int) []string {
	var lines []string
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimRight(line, " \t\r")
		if line == "" {
			continue
		}
		lines = append(lines, line)
	}
	if len(lines) > limit {
		lines = lines[len(lines)-limit:]
	}
	return lines
}

// 外側 tmux のフォーカスをサイドバーでない pane (= 内側 attach) へ移す
func focusInner(cfg Config) error {
	pane, err := fetchInnerPane(cfg)
	if err != nil {
		return err
	}
	return focusPane(cfg, pane.ID)
}

func focusPane(cfg Config, paneID string) error {
	if err := cfg.outerCommand("select-pane", "-t", paneID).Run(); err != nil {
		return fmt.Errorf("select-pane に失敗: %w", err)
	}
	return nil
}
