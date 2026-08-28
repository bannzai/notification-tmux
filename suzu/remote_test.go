package main

import (
	"errors"
	"os"
	"os/exec"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestParseRemoteHostsKeepsOrderAndDedupes(t *testing.T) {
	// GUI 版と同じ Ghostty 互換の key = value。コメント・空行・無関係なキー・重複を含む
	text := `# 配色
theme = catppuccin
remote-host = dev-machine
remote-host=user@build-server

  remote-host = dev-machine
remote-host =
font-size = 14
`
	hosts := parseRemoteHosts(text)
	if len(hosts) != 2 || hosts[0] != "dev-machine" || hosts[1] != "user@build-server" {
		t.Fatalf("remote-host の抽出が誤り: %q", hosts)
	}
}

func TestParseRemoteHostsEmpty(t *testing.T) {
	if hosts := parseRemoteHosts(""); hosts != nil {
		t.Fatalf("空の config で host が生えた: %q", hosts)
	}
	if hosts := parseRemoteHosts("# remote-host = commented\n"); hosts != nil {
		t.Fatalf("コメント行を host として読んだ: %q", hosts)
	}
}

func TestReadRemoteHostsMissingFile(t *testing.T) {
	if hosts := readRemoteHosts(t.TempDir() + "/missing"); hosts != nil {
		t.Fatalf("存在しない config で host が生えた: %q", hosts)
	}
}

func TestRemoteCommandWrapsTmuxInSSH(t *testing.T) {
	cfg := Config{SSHCmd: []string{"ssh", "-o", "BatchMode=yes"}}
	cmd := cfg.remoteCommand("dev", "list-panes", "-a", "-F", "#{pane_id}")
	// ssh の引数の後に host、最後にリモート shell へ渡す 1 語のコマンド行
	want := []string{"ssh", "-o", "BatchMode=yes", "dev", "'tmux' '-u' 'list-panes' '-a' '-F' '#{pane_id}'"}
	if strings.Join(cmd.Args, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("remote command = %q, want %q", cmd.Args, want)
	}
}

func TestRemoteAttachCommandQuotesForInnerShell(t *testing.T) {
	cfg := Config{SSHCmd: []string{"ssh", "-o", "BatchMode=yes"}}
	got := cfg.remoteAttachCommand("dev", "$3")
	// 内側 tmux の shell → ssh → リモート shell の 2 段を通っても $3 がそのまま届くこと
	want := `'ssh' '-o' 'BatchMode=yes' '-t' 'dev' ''\''tmux'\'' '\''-u'\'' '\''attach'\'' '\''-t'\'' '\''$3'\'''`
	if got != want {
		t.Fatalf("attach command = %s, want %s", got, want)
	}
	if out, err := exec.Command("sh", "-c", "printf '%s\\n' "+got).Output(); err != nil ||
		strings.TrimSpace(string(out)) != "ssh\n-o\nBatchMode=yes\n-t\ndev\n'tmux' '-u' 'attach' '-t' '$3'" {
		t.Fatalf("shell で展開した結果が誤り: %q (err=%v)", out, err)
	}
}

func TestSessionLabelAndKeys(t *testing.T) {
	local := Notification{Session: "work", WindowID: "@3", PaneID: "%7"}
	remote := Notification{Host: "dev", Session: "work", WindowID: "@3", PaneID: "%7"}
	if local.sessionLabel() != "work" || remote.sessionLabel() != "dev:work" {
		t.Errorf("見出しの表示名が誤り: %q / %q", local.sessionLabel(), remote.sessionLabel())
	}
	// 同じ window ID でも host が違えば別物として追跡する
	if local.key() == remote.key() || local.paneKey() == remote.paneKey() {
		t.Error("host をまたいだ同じ ID が同一視されている")
	}
}

func TestGroupBySessionSeparatesHosts(t *testing.T) {
	items := []Notification{
		{Session: "work", WindowID: "@1"},
		{Host: "dev", Session: "work", WindowID: "@1"},
		{Host: "dev", Session: "work", WindowID: "@2"},
	}
	groups := groupBySession(items)
	if len(groups) != 2 || groups[0].Session != "work" || groups[1].Session != "dev:work" {
		t.Fatalf("host ごとにまとまっていない: %+v", groups)
	}
	if len(groups[1].Items) != 2 {
		t.Errorf("リモートの window が 1 つの見出しにまとまっていない: %+v", groups[1])
	}
}

func TestFilterNotificationsMatchesHost(t *testing.T) {
	items := []Notification{
		{Session: "work", WindowID: "@1", WindowName: "a"},
		{Host: "dev", Session: "work", WindowID: "@1", WindowName: "b"},
	}
	got := filterNotifications(items, "dev")
	if len(got) != 1 || got[0].Host != "dev" {
		t.Fatalf("host 名で絞れていない: %+v", got)
	}
}

func TestParseRemoteWindowPicksLiveTaggedWindow(t *testing.T) {
	tag := remoteWindowTag("dev", "$3")
	out := tmuxLine("@1", "$0", "0", "") +
		tmuxLine("@2", "$0", "1", tag) + // ssh が終わって pane が死んでいる
		tmuxLine("@3", "$1", "0", remoteWindowTag("dev", "$4")) +
		tmuxLine("@4", "$1", "0", tag)
	window, ok := parseRemoteWindow(out, tag)
	if !ok || window.ID != "@4" || window.SessionID != "$1" {
		t.Fatalf("生きている目印付き window を選べていない: %+v ok=%v", window, ok)
	}
	if _, ok := parseRemoteWindow(tmuxLine("@1", "$0", "0", ""), tag); ok {
		t.Error("目印の無い window を再利用しようとしている")
	}
}

func TestIsSSHFailure(t *testing.T) {
	// exit 255 は ssh 自体の失敗。リモートの tmux が返す 1 は区別する
	if err := exec.Command("sh", "-c", "exit 255").Run(); !isSSHFailure(err) {
		t.Error("exit 255 を ssh の失敗と判定しない")
	}
	if err := exec.Command("sh", "-c", "exit 1").Run(); isSSHFailure(err) {
		t.Error("exit 1 を ssh の失敗と判定している")
	}
	if isSSHFailure(nil) || isSSHFailure(errors.New("other")) {
		t.Error("exit status を持たないエラーを ssh の失敗と判定している")
	}
}

func TestIsNoServer(t *testing.T) {
	if !isNoServer(errors.New("exit status 1 (no server running on /tmp/tmux-501/default)")) {
		t.Error("no server running を判定できない")
	}
	if isNoServer(errors.New("exit status 127 (sh: tmux: command not found)")) {
		t.Error("無関係なエラーを no server と判定している")
	}
}

func TestEnterIsIgnoredWhileJumping(t *testing.T) {
	m := testModel()
	m.items = sample()
	m, cmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil || !m.jumping {
		t.Fatal("Enter でジャンプが始まらない")
	}
	if _, cmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyEnter}); cmd != nil {
		t.Error("ジャンプ中の Enter で 2 つ目のジャンプが走った")
	}
	updated, _ := m.Update(jumpDoneMsg{})
	if _, cmd := pressKeys(updated.(model), tea.KeyMsg{Type: tea.KeyEnter}); cmd == nil {
		t.Error("ジャンプ完了後の Enter でジャンプが始まらない")
	}
}

func TestSSHControlDirIsPrivate(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "")
	t.Setenv("TMPDIR", t.TempDir())
	dir := sshControlDir()
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() || info.Mode().Perm() != 0o700 {
		t.Fatalf("ControlPath 用ディレクトリがユーザー専用 (700) で作られていない: %v mode=%v", err, info.Mode())
	}
	if !strings.Contains(strings.Join(defaultSSHCmd(), " "), "ServerAliveInterval=15") {
		t.Error("監視用 ssh に keepalive が付いていない")
	}
	runtimeDir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", runtimeDir)
	if got := sshControlDir(); !strings.HasPrefix(got, runtimeDir) {
		t.Errorf("XDG_RUNTIME_DIR がある環境でそこを使っていない: %s", got)
	}
}

func TestModelMergesHostsInConfigOrder(t *testing.T) {
	m := testModel()
	m.cfg.RemoteHosts = []string{"dev", "build"}
	// 到着順は build → local → dev だが、表示はローカル → remote-host の記述順
	updated, _ := m.Update(notificationsMsg{host: "build", items: []Notification{{Host: "build", Session: "b", WindowID: "@1", PaneID: "%1"}}})
	updated, _ = updated.(model).Update(notificationsMsg{items: []Notification{{Session: "local", WindowID: "@1", PaneID: "%1"}}})
	updated, _ = updated.(model).Update(notificationsMsg{host: "dev", items: []Notification{{Host: "dev", Session: "d", WindowID: "@1", PaneID: "%1"}}})
	m = updated.(model)
	if len(m.items) != 3 || m.items[0].Host != "" || m.items[1].Host != "dev" || m.items[2].Host != "build" {
		t.Fatalf("host の並びが記述順になっていない: %+v", m.items)
	}
	// 1 つの host の更新で他の host の通知が消えないこと
	updated, _ = m.Update(notificationsMsg{host: "dev"})
	if got := updated.(model).items; len(got) != 2 || got[1].Host != "build" {
		t.Fatalf("dev の更新で他の host が消えた: %+v", got)
	}
}

func TestModelKeepsSelectionAcrossHostsWithSameWindowID(t *testing.T) {
	m := testModel()
	m.cfg.RemoteHosts = []string{"dev"}
	updated, _ := m.Update(notificationsMsg{items: []Notification{{Session: "local", WindowID: "@1", PaneID: "%1"}}})
	updated, _ = updated.(model).Update(notificationsMsg{host: "dev", items: []Notification{{Host: "dev", Session: "d", WindowID: "@1", PaneID: "%1"}}})
	m = updated.(model)
	m.cursor = 1
	// ローカルに通知が割り込んでも、選んでいたリモートの window (同じ @1) を追い続ける
	updated, _ = m.Update(notificationsMsg{items: []Notification{
		{Session: "local", WindowID: "@0", PaneID: "%0"}, {Session: "local", WindowID: "@1", PaneID: "%1"},
	}})
	if selected, _ := updated.(model).selected(); selected.Host != "dev" {
		t.Fatalf("host をまたいで同じ window ID を取り違えた: %+v", selected)
	}
}

func TestStatusLinesShowUnreachableHostsOnly(t *testing.T) {
	m := testModel()
	m.cfg.RemoteHosts = []string{"dev", "down", "broken"}
	m.connected = true
	updated, _ := m.Update(connectionMsg{host: "dev", connected: true})
	updated, _ = updated.(model).Update(connectionMsg{host: "down", connected: false, unreachable: true})
	updated, _ = updated.(model).Update(notificationsMsg{host: "broken", err: errors.New("tmux: command not found")})
	lines := updated.(model).statusLines()
	if len(lines) != 2 || lines[0] != "down: 未接続" || !strings.HasPrefix(lines[1], "broken: ") {
		t.Fatalf("接続状態の行が誤り: %q", lines)
	}
	if !strings.Contains(updated.(model).View(), "down: 未接続") {
		t.Error("未接続の host が描画されていない")
	}
	// 繋がった時点で未接続は解ける
	updated, _ = updated.(model).Update(connectionMsg{host: "down", connected: true})
	if lines := updated.(model).statusLines(); len(lines) != 1 {
		t.Fatalf("再接続後も未接続のまま: %q", lines)
	}
	// リモートに tmux server が無いだけの切断は未接続と言わない
	updated, _ = updated.(model).Update(connectionMsg{host: "dev", connected: false})
	if lines := updated.(model).statusLines(); len(lines) != 1 {
		t.Fatalf("tmux server が無いだけの host を未接続にしている: %q", lines)
	}
}

func TestLayoutCountsStatusLines(t *testing.T) {
	m := testModel()
	m.cfg.RemoteHosts = []string{"down"}
	m.connected = true
	m.height = 10
	updated, _ := m.Update(connectionMsg{host: "down", connected: false, unreachable: true})
	m = updated.(model)
	m.items = sample()
	for i := range m.items {
		m.items[i].PaneID = ""
	}
	if lines := strings.Split(m.View(), "\n"); len(lines) > m.height {
		t.Fatalf("未接続行を足すと高さを超える: %d 行 > %d", len(lines), m.height)
	}
}
