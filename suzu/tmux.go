package main

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"strings"
)

// サイドバーの 1 行分の pane。通知 (@claude-waiting が set された window。pane と window の
// 両方に set されるため window 単位に畳んだ後の姿) と、セクション (sections.go) の
// プロセス一致 pane の両方をこの型で運ぶ
type Notification struct {
	// 属するセクションの名前。通知は空
	Section string
	Session string
	// switch-client の target に使う。tmux は `%` `$` `@` で始まる target を
	// pane/session/window の ID として解釈するため、その形の session 名は
	// 名前では引けない。表示は Session (名前)、指定は SessionID と分ける
	SessionID   string
	WindowID    string
	WindowIndex string
	WindowName  string
	PaneID      string
	Icon        string
	// セクションの一意識別 (生成元 rule の Process)。同名タイトルのセクション
	// (組み込み Claude と設定の section = Claude:my-wrapper 等) を区別するため key() に含める。
	// 通知は空
	SectionKey string
}

// 再取得の前後で同じ行を探し直すための識別子。同じ pane が通知と複数のセクションに
// 出ることがあるため、pane だけでなくセクションのタイトルと一意識別も含める
func (n Notification) key() string {
	return n.Section + fieldSeparator + n.SectionKey + fieldSeparator + n.PaneID
}

// 外側 tmux でサイドバーの隣にいる pane。内側 tmux へ attach している右 pane を指す
type innerPane struct {
	ID  string
	TTY string
}

// tmux 出力のフィールド区切り。window 名やコマンド行にはタブが入り得るため、
// テキストに現れない ASCII Unit Separator を使う (Noroshi/Noroshi/TmuxModels.swift と同じ)
const fieldSeparator = "\x1f"

// tmux 3.4 は list-* の出力で制御文字を 8 進の可視化表記に変えるため、区切りが
// この 4 文字で届く (CI の apt 版で実測)。3.6a はそのまま届く
const escapedFieldSeparator = `\037`

// tmux の -F 出力 1 行を区切りで分ける。可視化表記で届いた区切りも同じ区切りとして扱う
func splitFields(line string) []string {
	return strings.Split(strings.ReplaceAll(line, escapedFieldSeparator, fieldSeparator), fieldSeparator)
}

const (
	// Claude Code の hook が通知元 pane (-p) と その window (-w) に set する option。
	// window option は同じ window の全 pane へ継承されるため、pane ローカルに
	// 値を持つ pane だけが通知元と分かる
	waitingOption = "@claude-waiting"
	waitingFilter = "#{?#{" + waitingOption + "},1,0}"
	waitingFormat = "#{session_name}" + fieldSeparator + "#{session_id}" + fieldSeparator +
		"#{window_id}" + fieldSeparator + "#{window_index}" + fieldSeparator +
		"#{window_name}" + fieldSeparator + "#{pane_id}" + fieldSeparator + "#{" + waitingOption + "}"
	waitingFieldCount = 7
	clientFormat      = "#{client_name}" + fieldSeparator + "#{client_control_mode}" + fieldSeparator + "#{client_tty}"
	innerPaneFilter   = "#{?#{" + sidebarPaneOption + "},0,1}"
	innerPaneFormat   = "#{pane_id}" + fieldSeparator + "#{pane_tty}"
)

// サイドバーは外側 tmux の pane で動くため $TMUX は外側 server を指す。
// そのまま内側 tmux を呼ぶと外側 server に命令が飛ぶので必ず落とす
func tmuxEnv() []string {
	env := os.Environ()
	kept := env[:0]
	locale := false
	for _, kv := range env {
		if strings.HasPrefix(kv, "TMUX=") || strings.HasPrefix(kv, "TMUX_PANE=") {
			continue
		}
		locale = locale || definesLocale(kv)
		kept = append(kept, kv)
	}
	if !locale {
		// locale がどれも無いと tmux は非 UTF-8 端末とみなし、日本語や絵文字を
		// `_` へサニタイズする (documents/adr/0008)。en_US.UTF-8 は macOS にも
		// Linux にも標準で存在するため、最小の補いとしてこれを足す
		kept = append(kept, "LC_CTYPE=en_US.UTF-8")
	}
	return kept
}

// tmux が文字コードの判定に使う環境変数が値付きで入っているか
func definesLocale(kv string) bool {
	for _, name := range []string{"LANG=", "LC_ALL=", "LC_CTYPE="} {
		if strings.HasPrefix(kv, name) && len(kv) > len(name) {
			return true
		}
	}
	return false
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

// tmux は失敗の理由を stderr にしか出さない ("server exited unexpectedly" 等)。
// exit status だけを包むと原因が消えるため、必ず stderr を載せて返す
func output(cmd *exec.Cmd) (string, error) {
	out, err := cmd.Output()
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			return string(out), withDetail(err, string(exitErr.Stderr))
		}
	}
	return string(out), err
}

func runTmux(cmd *exec.Cmd) error {
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return withDetail(err, stderr.String())
	}
	return nil
}

func withDetail(err error, stderr string) error {
	detail := strings.TrimSpace(stderr)
	if detail == "" {
		return err
	}
	return fmt.Errorf("%w (%s)", err, strings.ReplaceAll(detail, "\n", " / "))
}

// 通知一覧 (@claude-waiting) を取り直す。list-panes だけで速いため、遅い ps を伴う
// セクション取得 (fetchSectionsMsg) とは別メッセージに分ける
func fetchNotifications(cfg Config) notificationsMsg {
	out, err := output(cfg.innerCommand("list-panes", "-a", "-f", waitingFilter, "-F", waitingFormat))
	if err != nil {
		// 内側 server が落ちている等。通知なし扱いにして理由だけ添える
		return notificationsMsg{err: fmt.Errorf("通知一覧の取得に失敗: %w", err)}
	}
	return notificationsMsg{items: parseNotifications(out, cfg.paneWaitingOption)}
}

// セクション (プロセス別の pane 一覧) を取り直す
func fetchSectionsMsg(cfg Config) sectionsMsg {
	return sectionsMsg{sections: fetchSections(cfg)}
}

// pane ローカルに set された @claude-waiting。window から継承しただけの pane では空になる。
// -q があるため未設定でも exit 0 で空文字が返る
func (c Config) paneWaitingOption(paneID string) string {
	out, err := output(c.innerCommand("show-options", "-p", "-q", "-v", "-t", paneID, waitingOption))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

// list-panes の出力を window 単位に畳む。@claude-waiting は通知元 pane (-p) と
// window (-w) の両方に set され、window option は同じ window の全 pane へ継承されるため、
// 複数 pane の window では候補が複数行で出てくる。
// paneOption は候補が 2 つ以上ある時だけ引き、通知元 pane を代表に選ぶ
func parseNotifications(out string, paneOption func(paneID string) string) []Notification {
	var windowIDs []string
	candidates := map[string][]Notification{}
	for _, line := range strings.Split(out, "\n") {
		fields := splitFields(line)
		if len(fields) != waitingFieldCount || fields[2] == "" {
			continue
		}
		notification := Notification{
			Session:     fields[0],
			SessionID:   fields[1],
			WindowID:    fields[2],
			WindowIndex: fields[3],
			WindowName:  fields[4],
			PaneID:      fields[5],
			Icon:        fields[6],
		}
		if _, seen := candidates[notification.WindowID]; !seen {
			windowIDs = append(windowIDs, notification.WindowID)
		}
		candidates[notification.WindowID] = append(candidates[notification.WindowID], notification)
	}
	var items []Notification
	for _, windowID := range windowIDs {
		items = append(items, notificationSource(candidates[windowID], paneOption))
	}
	return items
}

// 同じ window の候補から通知元 pane の行を選ぶ。
// どの pane にも pane ローカルの値が無ければ最初の行を代表にする
func notificationSource(candidates []Notification, paneOption func(paneID string) string) Notification {
	if len(candidates) == 1 {
		return candidates[0]
	}
	for _, candidate := range candidates {
		if paneOption(candidate.PaneID) != "" {
			return candidate
		}
	}
	return candidates[0]
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
		fields := splitFields(line)
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
	fields := splitFields(strings.TrimSpace(strings.SplitN(out, "\n", 2)[0]))
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

// 通知・セクションの pane を内側で表示する。フォーカスはサイドバーに残し、右 pane へ移るのは
// prefix + jump key / q / Esc の明示操作だけにする。
// select-window だけでなく select-pane も行う: セクションで検出した Claude/Codex が
// window の非アクティブ pane にいる場合、window を開くだけではその pane に届かない
func jump(cfg Config, n Notification) error {
	pane, err := fetchInnerPane(cfg)
	if err != nil {
		return err
	}
	if err := runTmux(cfg.innerCommand("select-window", "-t", n.WindowID)); err != nil {
		return fmt.Errorf("select-window に失敗: %w", err)
	}
	if err := runTmux(cfg.innerCommand("select-pane", "-t", n.PaneID)); err != nil {
		return fmt.Errorf("select-pane に失敗: %w", err)
	}
	out, err := output(cfg.innerCommand("list-clients", "-F", clientFormat))
	if err != nil {
		return fmt.Errorf("list-clients に失敗: %w", err)
	}
	client := parseRealClient(out, pane.TTY)
	if client == "" {
		return fmt.Errorf("内側 tmux の実 client が見つかりません")
	}
	if err := runTmux(cfg.innerCommand("switch-client", "-c", client, "-t", n.SessionID)); err != nil {
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
	if err := runTmux(cfg.outerCommand("select-pane", "-t", paneID)); err != nil {
		return fmt.Errorf("select-pane に失敗: %w", err)
	}
	return nil
}
