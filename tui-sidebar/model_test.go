package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func runesKey(text string) tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(text)}
}

func testModel() model {
	cfg := Config{InnerTmux: []string{"tmux"}, OuterSocket: "noroshi", JumpKey: "N"}
	return newModel(cfg, normalizePrefix("C-b"))
}

// キー処理は tmux を呼ぶ tea.Cmd を返すだけなので、実行せず「返ったかどうか」で判定する
func pressKeys(m model, keys ...tea.KeyMsg) (model, tea.Cmd) {
	var cmd tea.Cmd
	for _, key := range keys {
		var next tea.Model
		next, cmd = m.updateKey(key)
		m = next.(model)
	}
	return m, cmd
}

func TestPrefixThenJumpKeyReturnsFocus(t *testing.T) {
	m, cmd := pressKeys(testModel(), tea.KeyMsg{Type: tea.KeyCtrlB}, runesKey("N"))
	if cmd == nil {
		t.Fatal("prefix + jump key でフォーカスが返らない")
	}
	if m.awaitingJumpKey {
		t.Error("jump key を受けた後も prefix 待ちのままになっている")
	}
}

func TestPrefixAloneWaitsForJumpKey(t *testing.T) {
	m, cmd := pressKeys(testModel(), tea.KeyMsg{Type: tea.KeyCtrlB})
	if cmd != nil {
		t.Error("prefix だけでフォーカスが動いた")
	}
	if !m.awaitingJumpKey {
		t.Error("prefix を受けても次のキー待ちになっていない")
	}
}

func TestPrefixThenOtherKeyIsCancelled(t *testing.T) {
	m, cmd := pressKeys(testModel(), tea.KeyMsg{Type: tea.KeyCtrlB}, runesKey("x"))
	if cmd != nil {
		t.Error("prefix + jump key 以外でフォーカスが動いた")
	}
	if m.awaitingJumpKey {
		t.Error("prefix 待ちが解除されていない")
	}
}

func TestUnassignedKeyDoesNothing(t *testing.T) {
	if _, cmd := pressKeys(testModel(), runesKey("x")); cmd != nil {
		t.Error("未割り当てキーでフォーカスが動いた")
	}
}

func TestQuitKeysReturnFocus(t *testing.T) {
	if _, cmd := pressKeys(testModel(), runesKey("q")); cmd == nil {
		t.Error("q でフォーカスが返らない")
	}
	if _, cmd := pressKeys(testModel(), tea.KeyMsg{Type: tea.KeyEsc}); cmd == nil {
		t.Error("Esc でフォーカスが返らない")
	}
}

func TestPreviewIsDiscardedWhenSelectionMoved(t *testing.T) {
	m := testModel()
	m.items = []Notification{{WindowID: "@1", PaneID: "%1"}, {WindowID: "@2", PaneID: "%2"}}

	updated, _ := m.Update(previewMsg{paneID: "%2", lines: []string{"古い選択の結果"}})
	if got := updated.(model).preview; got != nil {
		t.Errorf("選択外の pane のプレビューを取り込んでいる: %q", got)
	}

	updated, _ = m.Update(previewMsg{paneID: "%1", lines: []string{"選択中の結果"}})
	if got := updated.(model).preview; len(got) != 1 || got[0] != "選択中の結果" {
		t.Errorf("選択中 pane のプレビューが入っていない: %q", got)
	}
}

func TestViewRendersPreview(t *testing.T) {
	m := testModel()
	m.items = []Notification{{Session: "test2", WindowIndex: "0", WindowName: "claude-work", PaneID: "%1", Icon: "🔔"}}
	m.preview = []string{"PREVIEW_MARKER"}

	if !strings.Contains(m.View(), "PREVIEW_MARKER") {
		t.Error("プレビューが描画されていない")
	}
	m.preview = nil
	if strings.Contains(m.View(), "─────") {
		t.Error("プレビューが無いのに区切り線が出ている")
	}
}

func TestFooterShowsActualKeys(t *testing.T) {
	cfg := Config{JumpKey: "N"}
	m := newModel(cfg, normalizePrefix("C-t"))
	if got, want := m.footer(), "j/k:選択 Enter:ジャンプ C-t N:右へ"; got != want {
		t.Errorf("footer = %q, want %q", got, want)
	}
}
