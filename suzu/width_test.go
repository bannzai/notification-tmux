package main

import (
	"regexp"
	"strings"
	"testing"
)

var ansiPattern = regexp.MustCompile("\x1b\\[[0-9;]*m")

func plainLines(view string) []string {
	return strings.Split(ansiPattern.ReplaceAllString(view, ""), "\n")
}

func TestTruncateCountsDisplayCells(t *testing.T) {
	cases := []struct {
		text  string
		width int
		want  string
	}{
		// 🔔 は 2 セル。文字数で切ると 1 セル分はみ出す
		{"🔔abc", 4, "🔔ab"},
		{"🔔🔔🔔", 4, "🔔🔔"},
		{"あいう", 4, "あい"},
		{"abcdefghij", 4, "abcd"},
		{"abc", 10, "abc"},
		{"", 10, ""},
		{"abc", 0, ""},
	}
	for _, c := range cases {
		if got := truncate(c.text, c.width); got != c.want {
			t.Errorf("truncate(%q, %d) = %q, want %q", c.text, c.width, got, c.want)
		}
	}
}

func TestTruncateKeepsEveryLineWithinWidth(t *testing.T) {
	// 通知行そのままの形。絵文字 + 長い window 名
	line := "  🔔09:00 12 🔔-とても長い-window-name-0123456789"
	if got := displayWidth(truncate(line, 40)); got > 40 {
		t.Fatalf("切り詰めても %d セルある", got)
	}
}

func TestRuleMatchesWidth(t *testing.T) {
	// 罫線 (─) は ambiguous 幅で端末によって倍になる。ASCII なら必ず幅ぴったり
	if got := displayWidth(rule(40)); got != 40 {
		t.Fatalf("区切り線が %d セル (want 40)", got)
	}
}

func crowdedModel(height, width int) model {
	m := testModel()
	m.height = height
	m.width = width
	m.connected = true
	for i := 0; i < 13; i++ {
		m.items = append(m.items, Notification{
			Session:     "とても長い名前の-session-" + string(rune('a'+i%3)),
			WindowID:    string(rune('A' + i)),
			WindowIndex: "12",
			WindowName:  "🔔-はみ出す長さの-window-name-0123456789",
			PaneID:      string(rune('A' + i)),
			Icon:        "🔔09:00",
		})
	}
	m.preview = make([]string, previewLineCount)
	for i := range m.preview {
		m.preview[i] = "/very/long/path/to/Something.xcodeproj/project.pbxproj:" + strings.Repeat("x", 40)
	}
	return m.syncOffset()
}

func TestViewFitsInsidePane(t *testing.T) {
	const height, width = 18, 40
	lines := plainLines(crowdedModel(height, width).View())

	if len(lines) > height {
		t.Fatalf("描画が %d 行あり pane の高さ %d を超えている:\n%s", len(lines), height, strings.Join(lines, "\n"))
	}
	for at, line := range lines {
		if columns := displayWidth(line); columns > width {
			t.Errorf("%d 行目が %d セルで pane 幅 %d を超える: %q", at, columns, width, line)
		}
	}
}

func TestViewKeepsHeaderAndFooterWhenTight(t *testing.T) {
	lines := plainLines(crowdedModel(18, 40).View())

	if !strings.HasPrefix(lines[0], "Noroshi") {
		t.Errorf("1 行目がヘッダーでない: %q", lines[0])
	}
	last := lines[len(lines)-1]
	if !strings.Contains(last, "右へ") {
		t.Errorf("最終行がフッターでない: %q", last)
	}
}

func TestViewShowsUpIndicatorAfterScrolling(t *testing.T) {
	m := crowdedModel(18, 40)
	for i := 0; i < len(m.items)-1; i++ {
		next, _ := m.moveCursor(1)
		m = next.syncOffset()
	}
	if m.offset <= 0 {
		t.Fatalf("末尾までカーソルを送ってもスクロールしていない (offset=%d)", m.offset)
	}
	if !strings.Contains(m.View(), "↑") {
		t.Errorf("offset=%d なのに上端インジケータが無い:\n%s", m.offset, m.View())
	}
}

func TestViewFitsAtVariousHeights(t *testing.T) {
	for height := 8; height <= 40; height++ {
		lines := plainLines(crowdedModel(height, 40).View())
		if len(lines) > height {
			t.Errorf("高さ %d の pane に %d 行を描画している", height, len(lines))
		}
	}
}
