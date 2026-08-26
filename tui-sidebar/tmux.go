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

const (
	waitingFilter = "#{?#{@claude-waiting},1,0}"
	waitingFormat = "#{session_name}\t#{window_id}\t#{window_index}\t#{window_name}\t#{pane_id}\t#{@claude-waiting}"
	clientFormat  = "#{client_name}\t#{client_control_mode}\t#{client_tty}"
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

// 内側 tmux の「実端末に繋がった client」= 右 pane の attach。control mode client
// (サイドバー自身が張っている購読) と取り違えないよう除外する
func parseRealClient(out string) string {
	for _, line := range strings.Split(out, "\n") {
		if line == "" {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 3 || fields[0] == "" {
			continue
		}
		if fields[1] == "1" || fields[2] == "" {
			continue
		}
		return fields[0]
	}
	return ""
}

// 通知の window を内側で表示し、フォーカスを内側 pane へ返す
func jump(cfg Config, n Notification) error {
	if err := cfg.innerCommand("select-window", "-t", n.WindowID).Run(); err != nil {
		return fmt.Errorf("select-window に失敗: %w", err)
	}
	out, err := output(cfg.innerCommand("list-clients", "-F", clientFormat))
	if err != nil {
		return fmt.Errorf("list-clients に失敗: %w", err)
	}
	client := parseRealClient(out)
	if client == "" {
		return fmt.Errorf("内側 tmux の実 client が見つかりません")
	}
	if err := cfg.innerCommand("switch-client", "-c", client, "-t", n.Session).Run(); err != nil {
		return fmt.Errorf("switch-client に失敗: %w", err)
	}
	return focusInner(cfg)
}

// 外側 tmux のフォーカスをサイドバーでない pane (= 内側 attach) へ移す
func focusInner(cfg Config) error {
	out, err := output(cfg.outerCommand("list-panes", "-t", "noroshi:0",
		"-f", "#{?#{@noroshi-sidebar},0,1}", "-F", "#{pane_id}"))
	if err != nil {
		return fmt.Errorf("外側 pane の列挙に失敗: %w", err)
	}
	paneID := strings.TrimSpace(strings.SplitN(out, "\n", 2)[0])
	if paneID == "" {
		return fmt.Errorf("外側に内側 pane が見つかりません")
	}
	if err := cfg.outerCommand("select-pane", "-t", paneID).Run(); err != nil {
		return fmt.Errorf("select-pane に失敗: %w", err)
	}
	return nil
}
