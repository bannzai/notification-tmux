package main

import "testing"

func TestParseNotificationsDedupesByWindow(t *testing.T) {
	// -p と -w の両方に set されると同じ window が 2 行で出てくる
	out := "main\t@3\t0\tclaude-work\t%7\t🔔09:00\n" +
		"main\t@3\t0\tclaude-work\t%8\t🔔09:01\n" +
		"other\t@9\t2\tbuild\t%12\t🔔10:00\n"

	items := parseNotifications(out)
	if len(items) != 2 {
		t.Fatalf("window 単位に畳まれていない: %+v", items)
	}
	if items[0].WindowID != "@3" || items[0].Icon != "🔔09:00" || items[0].PaneID != "%7" {
		t.Errorf("最初の行が代表になっていない: %+v", items[0])
	}
	if items[1].Session != "other" || items[1].WindowIndex != "2" || items[1].WindowName != "build" {
		t.Errorf("2 件目のパースが誤り: %+v", items[1])
	}
}

func TestParseNotificationsSkipsBrokenLines(t *testing.T) {
	out := "\nmain\t@3\n\t\t\t\t\t\nmain\t@4\t1\tweb\t%2\t🔔\n"

	items := parseNotifications(out)
	if len(items) != 1 || items[0].WindowID != "@4" {
		t.Fatalf("壊れた行が混入している: %+v", items)
	}
}

func TestParseNotificationsEmpty(t *testing.T) {
	if items := parseNotifications(""); len(items) != 0 {
		t.Fatalf("空出力で通知が生えた: %+v", items)
	}
}

func TestParseRealClientSkipsControlMode(t *testing.T) {
	out := "/dev/ttys001\t1\t/dev/ttys001\n/dev/ttys004\t0\t/dev/ttys004\n"
	if got := parseRealClient(out, "/dev/ttys004"); got != "/dev/ttys004" {
		t.Fatalf("control mode client を選んでいる: %q", got)
	}
}

func TestParseRealClientSkipsEmptyTTY(t *testing.T) {
	// client_control_mode を解釈できない tmux では空文字になるため tty で判別する
	out := "/dev/ttys001\t\t\n/dev/ttys004\t\t/dev/ttys004\n"
	if got := parseRealClient(out, ""); got != "/dev/ttys004" {
		t.Fatalf("tty が空の client を選んでいる: %q", got)
	}
}

func TestParseRealClientPrefersPaneTTY(t *testing.T) {
	// 普段の端末からの attach が先に並んでいても、右 pane の tty と一致する client を選ぶ
	out := "/dev/ttys001\t0\t/dev/ttys001\n" +
		"/dev/ttys009\t1\t/dev/ttys009\n" +
		"/dev/ttys004\t0\t/dev/ttys004\n"
	if got := parseRealClient(out, "/dev/ttys004"); got != "/dev/ttys004" {
		t.Fatalf("右 pane 以外の client を選んでいる: %q", got)
	}
}

func TestParseRealClientFallsBackWhenPaneTTYUnmatched(t *testing.T) {
	out := "/dev/ttys009\t1\t/dev/ttys009\n/dev/ttys001\t0\t/dev/ttys001\n"
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
	pane, ok := parseInnerPane("%4\t/dev/ttys004\n")
	if !ok || pane.ID != "%4" || pane.TTY != "/dev/ttys004" {
		t.Fatalf("右 pane のパースが誤り: %+v ok=%v", pane, ok)
	}
	if _, ok := parseInnerPane(""); ok {
		t.Error("空出力を pane として受け入れている")
	}
	if _, ok := parseInnerPane("%4\n"); ok {
		t.Error("tty が欠けた出力を pane として受け入れている")
	}
}
