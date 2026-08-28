package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// リモート host (ssh 先) の tmux をサイドバーへ載せる (issue #75。GUI 版 #38 / #39 のパリティ)。
//
// 一覧・操作: ローカルと同じ tmux サブコマンドを `ssh <host> tmux -u ...` として実行する
// (GUI 版 ADR 0010 のコマンドラップ方針)。引数はリモート shell 向けに single quote で包む。
// 更新の受信: host ごとに control mode client を張り、ツリーイベントと
// @claude-waiting の購読 (waitingSubscription) で再取得する。リモート側に hook は注入しない。
// ジャンプ: 内側 tmux に `ssh -t <host> tmux attach -t <session>` を実行する window を開く
// (あれば select、無ければ新規)。suzu の右 pane は普段の tmux なので、attach を
// 右 pane に直接張っていた GUI 版と違い、内側の window として持つのが nested 構成に合う

const (
	remoteHostKey = "remote-host"
	// 内側 tmux に開いたリモート attach 用 window の目印 (window option)。
	// 値は remoteWindowTag で、同じ host・session への window を再利用するために引く
	remoteWindowOption = "@suzu-remote"
	// ssh 自体の失敗 (接続不能・鍵認証で入れない) の exit status。リモートで実行した
	// コマンドの失敗 (tmux の no server 等) とはこれで区別する
	sshFailureStatus = 255
)

// GUI 版と同じ `~/.config/noroshi/config` (Ghostty 互換の `key = value` 形式)。
// XDG_CONFIG_HOME があればその下を見る
func defaultConfigFile() string {
	home := os.Getenv("XDG_CONFIG_HOME")
	if home == "" {
		home = filepath.Join(os.Getenv("HOME"), ".config")
	}
	return filepath.Join(home, "noroshi", "config")
}

// ssh の既定オプション (GUI 版 TmuxClient.sshBatchOptions と同じ意図):
//   - BatchMode: 鍵認証前提。パスワードプロンプトで再取得や attach を止めない
//   - ConnectTimeout=5: 落ちている host への接続で再取得を長時間塞がない
//   - ControlMaster/ControlPath/ControlPersist=600: 接続を多重化し 2 回目以降を数十 ms にする
func defaultSSHCmd() []string {
	return []string{"ssh",
		"-o", "BatchMode=yes",
		"-o", "ConnectTimeout=5",
		"-o", "ControlMaster=auto",
		"-o", "ControlPath=" + filepath.Join(os.TempDir(), "suzu-ssh-%C"),
		"-o", "ControlPersist=600",
	}
}

// config ファイルの remote-host を記述順で返す。重複は先勝ちで畳む (同じ host へ二重に
// control client を張らないため)。ファイルが無ければ空 = リモート未設定
func readRemoteHosts(path string) []string {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	return parseRemoteHosts(string(data))
}

func parseRemoteHosts(text string) []string {
	var hosts []string
	seen := map[string]bool{}
	for _, line := range strings.Split(text, "\n") {
		key, value, ok := parseConfigLine(line)
		if !ok || key != remoteHostKey || value == "" || seen[value] {
			continue
		}
		seen[value] = true
		hosts = append(hosts, value)
	}
	return hosts
}

// `key = value` の 1 行を分ける。空行・`#` コメント・`=` を含まない行は無視する
// (GUI 版 GhosttyTheme.parseLine と同じ規則)
func parseConfigLine(line string) (key, value string, ok bool) {
	trimmed := strings.TrimSpace(line)
	if trimmed == "" || strings.HasPrefix(trimmed, "#") {
		return "", "", false
	}
	key, value, found := strings.Cut(trimmed, "=")
	key = strings.TrimSpace(key)
	if !found || key == "" {
		return "", "", false
	}
	return key, strings.TrimSpace(value), true
}

// ssh はリモートコマンドを空白で結合して相手 shell に渡すため、引数ごとに single quote で包む
// (`#{...}` がコメント扱いされ、空白入りの値が分かれるのを防ぐ)
func remoteShellCommand(args []string) string {
	quoted := make([]string, len(args))
	for i, arg := range args {
		quoted[i] = shellQuote(arg)
	}
	return strings.Join(quoted, " ")
}

// リモートで実行する tmux の引数。-u はリモートの非対話 shell の locale が不定で、
// 非 UTF-8 扱いになると出力中の区切り (0x1f) が `_` にサニタイズされるのを避けるため
func remoteTmuxArgs(args ...string) []string {
	return append([]string{"tmux", "-u"}, args...)
}

// `ssh <host> tmux -u <args...>`。ローカルの innerCommand に対応する
func (c Config) remoteCommand(host string, args ...string) *exec.Cmd {
	argv := append(append([]string{}, c.SSHCmd[1:]...), host, remoteShellCommand(remoteTmuxArgs(args...)))
	cmd := exec.Command(c.SSHCmd[0], argv...)
	cmd.Env = tmuxEnv()
	return cmd
}

// 内側 tmux の window で実行する、リモート session への attach コマンド行。
// 内側 tmux が shell に渡すため、ssh の引数も含めて一段クオートする。
// session は名前ではなく ID で指定する (ローカルの jump と同じく、`%` `$` `@` で始まる
// 名前を target にできないため)
func (c Config) remoteAttachCommand(host, sessionID string) string {
	words := append(append([]string{}, c.SSHCmd...), "-t", host,
		remoteShellCommand(remoteTmuxArgs("attach", "-t", sessionID)))
	return remoteShellCommand(words)
}

// ssh 自体が失敗した (host に届かない・鍵認証で入れない) か。
// リモートで tmux が失敗した場合は exit status がそのまま返るため区別できる
func isSSHFailure(err error) bool {
	var exitErr *exec.ExitError
	return errors.As(err, &exitErr) && exitErr.ExitCode() == sshFailureStatus
}

// リモートに tmux server が無い (まだ起動していない・全 session を閉じた) 状態。
// 通知が無いのと同じ扱いにし、エラーとしては出さない
func isNoServer(err error) bool {
	message := err.Error()
	return strings.Contains(message, "no server running") || strings.Contains(message, "error connecting")
}

func fetchRemoteNotifications(cfg Config, host string) notificationsMsg {
	out, err := output(cfg.remoteCommand(host, "list-panes", "-a", "-f", waitingFilter, "-F", waitingFormat))
	switch {
	case err == nil:
	case isSSHFailure(err):
		return notificationsMsg{host: host, unreachable: true}
	case isNoServer(err):
		return notificationsMsg{host: host}
	default:
		return notificationsMsg{host: host, err: fmt.Errorf("通知一覧の取得に失敗: %w", err)}
	}
	items := parseNotifications(out, func(paneID string) string {
		return cfg.remotePaneWaitingOption(host, paneID)
	})
	for i := range items {
		items[i].Host = host
	}
	return notificationsMsg{host: host, items: items}
}

func (c Config) remotePaneWaitingOption(host, paneID string) string {
	out, err := output(c.remoteCommand(host, "show-options", "-p", "-q", "-v", "-t", paneID, waitingOption))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(out)
}

func fetchRemotePreview(cfg Config, host, paneID string, limit int) []string {
	out, err := output(cfg.remoteCommand(host, "capture-pane", "-p", "-t", paneID))
	if err != nil {
		return nil
	}
	return previewLines(out, limit)
}

// 同じ host・session への attach window を引くための目印の値
func remoteWindowTag(host, sessionID string) string {
	return host + " " + sessionID
}

const remoteWindowFormat = "#{window_id}" + fieldSeparator + "#{session_id}" + fieldSeparator +
	"#{pane_dead}" + fieldSeparator + "#{" + remoteWindowOption + "}"

// 内側 tmux に開いた attach 用 window 1 件
type remoteWindow struct {
	ID        string
	SessionID string
}

// list-windows の出力から、目印が tag に一致する生きている window を探す。
// ssh が終わって pane が死んでいる window (remain-on-exit の環境) は再利用しない
func parseRemoteWindow(out string, tag string) (remoteWindow, bool) {
	for _, line := range strings.Split(out, "\n") {
		fields := splitFields(line)
		if len(fields) != 4 || fields[0] == "" {
			continue
		}
		if fields[3] == tag && fields[2] != "1" {
			return remoteWindow{ID: fields[0], SessionID: fields[1]}, true
		}
	}
	return remoteWindow{}, false
}

func findRemoteWindow(cfg Config, tag string) (remoteWindow, bool, error) {
	out, err := output(cfg.innerCommand("list-windows", "-a", "-F", remoteWindowFormat))
	if err != nil {
		return remoteWindow{}, false, fmt.Errorf("内側の window 列挙に失敗: %w", err)
	}
	window, found := parseRemoteWindow(out, tag)
	return window, found, nil
}

// 右 pane の client が今いる session に attach 用 window を開き、目印を付ける
func openRemoteWindow(cfg Config, client string, n Notification) (remoteWindow, error) {
	out, err := output(cfg.innerCommand("display-message", "-p", "-c", client, "#{session_id}"))
	if err != nil {
		return remoteWindow{}, fmt.Errorf("client の session 取得に失敗: %w", err)
	}
	sessionID := firstLine(out)
	if sessionID == "" {
		return remoteWindow{}, fmt.Errorf("client の session が分かりません")
	}
	// -n で名前を固定し (automatic-rename が ssh に変えない)、host:session が見えるようにする。
	// `<session ID>:` は「その session の次の空き index」を指す target-window 表記
	out, err = output(cfg.innerCommand("new-window", "-d", "-P", "-F", "#{window_id}",
		"-t", sessionID+":", "-n", n.sessionLabel(), cfg.remoteAttachCommand(n.Host, n.SessionID)))
	if err != nil {
		return remoteWindow{}, fmt.Errorf("attach 用 window の作成に失敗: %w", err)
	}
	window := remoteWindow{ID: firstLine(out), SessionID: sessionID}
	if err := runTmux(cfg.innerCommand("set-option", "-w", "-t", window.ID,
		remoteWindowOption, remoteWindowTag(n.Host, n.SessionID))); err != nil {
		return remoteWindow{}, fmt.Errorf("attach 用 window の目印付けに失敗: %w", err)
	}
	return window, nil
}

// リモートの通知へジャンプする。リモート側で通知の window を前面にしてから、
// 内側 tmux でその session への attach window を前面にする。
// フォーカスはローカルの jump と同じくサイドバーに残す
func jumpRemote(cfg Config, n Notification) error {
	pane, err := fetchInnerPane(cfg)
	if err != nil {
		return err
	}
	if err := runTmux(cfg.remoteCommand(n.Host, "select-window", "-t", n.WindowID)); err != nil {
		return fmt.Errorf("%s: select-window に失敗: %w", n.Host, err)
	}
	out, err := output(cfg.innerCommand("list-clients", "-F", clientFormat))
	if err != nil {
		return fmt.Errorf("list-clients に失敗: %w", err)
	}
	client := parseRealClient(out, pane.TTY)
	if client == "" {
		return fmt.Errorf("内側 tmux の実 client が見つかりません")
	}
	window, found, err := findRemoteWindow(cfg, remoteWindowTag(n.Host, n.SessionID))
	if err != nil {
		return err
	}
	if !found {
		if window, err = openRemoteWindow(cfg, client, n); err != nil {
			return err
		}
	}
	if err := runTmux(cfg.innerCommand("select-window", "-t", window.ID)); err != nil {
		return fmt.Errorf("select-window に失敗: %w", err)
	}
	if err := runTmux(cfg.innerCommand("switch-client", "-c", client, "-t", window.SessionID)); err != nil {
		return fmt.Errorf("switch-client に失敗: %w", err)
	}
	return nil
}
