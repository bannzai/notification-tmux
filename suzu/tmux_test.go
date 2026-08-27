package main

import (
	"strings"
	"testing"
)

// tmux の -F 出力の 1 行を組み立てる。区切りは \x1f なので、値にタブが入っても崩れない
func tmuxLine(fields ...string) string {
	return strings.Join(fields, fieldSeparator) + "\n"
}

// pane ローカルの @claude-waiting を引く tmux 呼び出しの代役
func paneOptions(values map[string]string) func(string) string {
	return func(paneID string) string { return values[paneID] }
}

func TestParseNotificationsDedupesByWindow(t *testing.T) {
	// -p と -w の両方に set されると同じ window が 2 行で出てくる
	out := tmuxLine("main", "$0", "@3", "0", "claude-work", "%7", "🔔09:00") +
		tmuxLine("main", "$0", "@3", "0", "claude-work", "%8", "🔔09:01") +
		tmuxLine("other", "$1", "@9", "2", "build", "%12", "🔔10:00")

	items := parseNotifications(out, paneOptions(nil))
	if len(items) != 2 {
		t.Fatalf("window 単位に畳まれていない: %+v", items)
	}
	// pane ローカルの値がどこにも無い時は従来どおり先頭を代表にする
	if items[0].WindowID != "@3" || items[0].Icon != "🔔09:00" || items[0].PaneID != "%7" {
		t.Errorf("最初の行が代表になっていない: %+v", items[0])
	}
	if items[1].Session != "other" || items[1].SessionID != "$1" ||
		items[1].WindowIndex != "2" || items[1].WindowName != "build" {
		t.Errorf("2 件目のパースが誤り: %+v", items[1])
	}
}

func TestParseNotificationsPrefersOriginPane(t *testing.T) {
	// 複数 pane の window では window option の継承で全 pane が候補に挙がる。
	// pane ローカルに値がある %8 が通知元
	out := tmuxLine("main", "$0", "@3", "0", "claude-work", "%7", "🔔09:00") +
		tmuxLine("main", "$0", "@3", "0", "claude-work", "%8", "🔔09:00") +
		tmuxLine("main", "$0", "@3", "0", "claude-work", "%9", "🔔09:00")

	items := parseNotifications(out, paneOptions(map[string]string{"%8": "🔔09:00"}))
	if len(items) != 1 || items[0].PaneID != "%8" {
		t.Fatalf("通知元 pane が代表になっていない: %+v", items)
	}
}

func TestParseNotificationsSkipsPaneLookupForSinglePane(t *testing.T) {
	// 候補が 1 つしかない window で tmux を余計に叩かないこと
	out := tmuxLine("main", "$0", "@4", "1", "web", "%2", "🔔")

	items := parseNotifications(out, func(string) string {
		t.Error("単一 pane の window で pane option を引いている")
		return ""
	})
	if len(items) != 1 || items[0].PaneID != "%2" {
		t.Fatalf("単一 pane の window のパースが誤り: %+v", items)
	}
}

func TestParseNotificationsKeepsTabsInNames(t *testing.T) {
	// タブを含む window 名でもフィールド数が狂わない (\t 区切りだと消えていた)
	out := tmuxLine("main", "$0", "@4", "1", "we\tb", "%2", "🔔")

	items := parseNotifications(out, paneOptions(nil))
	if len(items) != 1 || items[0].WindowName != "we\tb" {
		t.Fatalf("タブを含む window 名が壊れている: %+v", items)
	}
}

func TestParseNotificationsSkipsBrokenLines(t *testing.T) {
	out := "\n" + tmuxLine("main", "@3") +
		tmuxLine("", "", "", "", "", "", "") +
		tmuxLine("main", "$0", "@4", "1", "web", "%2", "🔔")

	items := parseNotifications(out, paneOptions(nil))
	if len(items) != 1 || items[0].WindowID != "@4" {
		t.Fatalf("壊れた行が混入している: %+v", items)
	}
}

func TestParseNotificationsAcceptsEscapedSeparator(t *testing.T) {
	// tmux 3.4 は区切りの制御文字を 8 進表記 (\037) で出す
	out := `work\037$1\037@3\0370\037claude\037%5\037🔔` + "\n"
	items := parseNotifications(out, paneOptions(nil))
	if len(items) != 1 || items[0].WindowID != "@3" || items[0].PaneID != "%5" || items[0].Icon != "🔔" {
		t.Fatalf("可視化表記の区切りをパースできない: %+v", items)
	}
}

func TestParseNotificationsEmpty(t *testing.T) {
	if items := parseNotifications("", paneOptions(nil)); len(items) != 0 {
		t.Fatalf("空出力で通知が生えた: %+v", items)
	}
}

func TestTmuxEnvAddsUTF8LocaleOnlyWhenMissing(t *testing.T) {
	t.Setenv("LANG", "")
	t.Setenv("LC_ALL", "")
	t.Setenv("LC_CTYPE", "")
	if !hasEnv(tmuxEnv(), "LC_CTYPE=en_US.UTF-8") {
		t.Error("locale が無い環境で LC_CTYPE が補われていない")
	}

	t.Setenv("LANG", "ja_JP.UTF-8")
	if hasEnv(tmuxEnv(), "LC_CTYPE=en_US.UTF-8") {
		t.Error("LANG がある環境で LC_CTYPE を上書きしている")
	}
}

func TestTmuxEnvDropsOuterTmux(t *testing.T) {
	t.Setenv("TMUX", "/tmp/tmux-501/suzu,123,0")
	t.Setenv("TMUX_PANE", "%1")
	for _, kv := range tmuxEnv() {
		if strings.HasPrefix(kv, "TMUX=") || strings.HasPrefix(kv, "TMUX_PANE=") {
			t.Errorf("外側 server を指す env が残っている: %q", kv)
		}
	}
}

func hasEnv(env []string, want string) bool {
	for _, kv := range env {
		if kv == want {
			return true
		}
	}
	return false
}

func TestDefinesLocale(t *testing.T) {
	cases := map[string]bool{
		"LANG=ja_JP.UTF-8": true,
		"LC_ALL=C":         true,
		"LC_CTYPE=C":       true,
		// 空値は未設定と同じ扱い
		"LANG=":              false,
		"LANGUAGE=ja":        false,
		"PATH=/usr/bin":      false,
		"LC_CTYPE_EXTRA=foo": false,
	}
	for kv, want := range cases {
		if got := definesLocale(kv); got != want {
			t.Errorf("definesLocale(%q) = %v, want %v", kv, got, want)
		}
	}
}

func TestParseRealClientSkipsControlMode(t *testing.T) {
	out := tmuxLine("/dev/ttys001", "1", "/dev/ttys001") + tmuxLine("/dev/ttys004", "0", "/dev/ttys004")
	if got := parseRealClient(out, "/dev/ttys004"); got != "/dev/ttys004" {
		t.Fatalf("control mode client を選んでいる: %q", got)
	}
}

func TestParseRealClientSkipsEmptyTTY(t *testing.T) {
	// client_control_mode を解釈できない tmux では空文字になるため tty で判別する
	out := tmuxLine("/dev/ttys001", "", "") + tmuxLine("/dev/ttys004", "", "/dev/ttys004")
	if got := parseRealClient(out, ""); got != "/dev/ttys004" {
		t.Fatalf("tty が空の client を選んでいる: %q", got)
	}
}

func TestParseRealClientPrefersPaneTTY(t *testing.T) {
	// 普段の端末からの attach が先に並んでいても、右 pane の tty と一致する client を選ぶ
	out := tmuxLine("/dev/ttys001", "0", "/dev/ttys001") +
		tmuxLine("/dev/ttys009", "1", "/dev/ttys009") +
		tmuxLine("/dev/ttys004", "0", "/dev/ttys004")
	if got := parseRealClient(out, "/dev/ttys004"); got != "/dev/ttys004" {
		t.Fatalf("右 pane 以外の client を選んでいる: %q", got)
	}
}

func TestParseRealClientFallsBackWhenPaneTTYUnmatched(t *testing.T) {
	out := tmuxLine("/dev/ttys009", "1", "/dev/ttys009") + tmuxLine("/dev/ttys001", "0", "/dev/ttys001")
	if got := parseRealClient(out, "/dev/ttys004"); got != "/dev/ttys001" {
		t.Fatalf("一致なし時に非 control の実 client へ落ちていない: %q", got)
	}
}

func TestParseRealClientNone(t *testing.T) {
	if got := parseRealClient("", "/dev/ttys004"); got != "" {
		t.Fatalf("client が無いのに %q を返した", got)
	}
}

func TestPreviewLinesTakesTailIgnoringBlanks(t *testing.T) {
	// capture-pane は pane の高さぶん出るため、下は空行で埋まる
	out := "one\n\ntwo\nthree   \n\n   \n\n"

	got := previewLines(out, 10)
	want := []string{"one", "two", "three"}
	if len(got) != len(want) {
		t.Fatalf("空行が落ちていない: %q", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("%d 行目 = %q, want %q", i, got[i], want[i])
		}
	}
}

func TestPreviewLinesLimitsToTail(t *testing.T) {
	out := "l1\nl2\nl3\nl4\nl5\n"

	got := previewLines(out, 3)
	if len(got) != 3 || got[0] != "l3" || got[2] != "l5" {
		t.Fatalf("末尾 3 行になっていない: %q", got)
	}
}

func TestPreviewLinesEmpty(t *testing.T) {
	if got := previewLines("\n \n\t\n", 10); got != nil {
		t.Fatalf("空行だけの出力でプレビューが生えた: %q", got)
	}
}

func TestParseInnerPane(t *testing.T) {
	pane, ok := parseInnerPane("%4" + fieldSeparator + "/dev/ttys004\n")
	if !ok || pane.ID != "%4" || pane.TTY != "/dev/ttys004" {
		t.Fatalf("右 pane のパースが誤り: %+v ok=%v", pane, ok)
	}
	// tmux 3.4 は区切りの制御文字を 8 進表記 (\037) で出す
	pane, ok = parseInnerPane(`%4\037/dev/pts/3` + "\n")
	if !ok || pane.ID != "%4" || pane.TTY != "/dev/pts/3" {
		t.Fatalf("可視化表記の区切りをパースできない: %+v ok=%v", pane, ok)
	}
	if _, ok := parseInnerPane(""); ok {
		t.Error("空出力を pane として受け入れている")
	}
	if _, ok := parseInnerPane("%4\n"); ok {
		t.Error("tty が欠けた出力を pane として受け入れている")
	}
}
