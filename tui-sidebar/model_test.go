package main

import (
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func runesKey(text string) tea.KeyMsg {
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(text)}
}

// socket 名は実在しないものにする。tea.Cmd を実行するテストがあるため、
// 取り違えて普段の tmux や本番の noroshi socket へ命令が飛ばないようにする
func testModel() model {
	cfg := Config{
		InnerTmux:   []string{"tmux", "-L", "noroshi-unit-test-inner"},
		OuterSocket: "noroshi-unit-test-outer",
		JumpKey:     "N",
	}
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

// どの操作を選んだかは戻り値の Msg 型でしか区別できない (focusInner は actionMsg、
// カーソル・クエリ更新は previewMsg)。socket が実在しないので実行しても副作用は無い
func isFocusInner(cmd tea.Cmd) bool {
	if cmd == nil {
		return false
	}
	_, ok := cmd().(actionMsg)
	return ok
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

	lines := m.footerLines()
	if len(lines) != 2 {
		t.Fatalf("フッターの行数 = %d", len(lines))
	}
	if want := "C-t N か q:右へ"; lines[1] != want {
		t.Errorf("実キーの案内 = %q, want %q", lines[1], want)
	}
	// 幅 40 の pane で切れないこと。日本語は 1 文字 2 桁で数える
	for _, line := range lines {
		if columns := displayColumns(line); columns > defaultWidth {
			t.Errorf("フッターが幅 %d を超える (%d 桁): %q", defaultWidth, columns, line)
		}
	}
}

func displayColumns(text string) int {
	columns := 0
	for _, r := range text {
		if r > 0x2000 {
			columns += 2
		} else {
			columns++
		}
	}
	return columns
}

func groupedModel() model {
	m := testModel()
	m.items = sample()
	return m
}

func TestCursorSkipsSessionHeaders(t *testing.T) {
	// work に 2 件・personal に 1 件。j を 2 回で見出しを跨いで personal の window に入る
	m := groupedModel()
	if got := m.selectedPaneID(); got != "%1" {
		t.Fatalf("初期選択が先頭 window でない: %q", got)
	}
	m, _ = pressKeys(m, runesKey("j"), runesKey("j"))
	if got := m.selectedPaneID(); got != "%3" {
		t.Fatalf("j 2 回で別 session の window に入らない (見出しを数えている): %q", got)
	}
	// 末尾で j を押しても溢れない
	m, _ = pressKeys(m, runesKey("j"))
	if got := m.selectedPaneID(); got != "%3" {
		t.Errorf("末尾から先へ進んだ: %q", got)
	}
	m, _ = pressKeys(m, runesKey("k"))
	if got := m.selectedPaneID(); got != "%2" {
		t.Errorf("k で見出しを跨いで戻れていない: %q", got)
	}
}

func TestFilterModeCollectsQuery(t *testing.T) {
	m := groupedModel()
	m, _ = pressKeys(m, runesKey("/"))
	if !m.filtering {
		t.Fatal("/ で入力モードに入らない")
	}
	m, _ = pressKeys(m, runesKey("c"), runesKey("l"), runesKey("a"))
	if m.query != "cla" {
		t.Fatalf("query = %q, want %q", m.query, "cla")
	}
	if got := len(m.visible()); got != 1 {
		t.Fatalf("入力中に絞り込みが効いていない: %d 件", got)
	}
	m, _ = pressKeys(m, tea.KeyMsg{Type: tea.KeyBackspace})
	if m.query != "cl" {
		t.Errorf("backspace 後の query = %q", m.query)
	}
	m, _ = pressKeys(m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.filtering || m.query != "cl" {
		t.Errorf("Enter 確定で filtering=%v query=%q", m.filtering, m.query)
	}
}

func TestFilterModeEscCancels(t *testing.T) {
	m := groupedModel()
	m, _ = pressKeys(m, runesKey("/"), runesKey("c"), tea.KeyMsg{Type: tea.KeyEsc})
	if m.filtering || m.query != "" {
		t.Fatalf("入力モードの Esc でクリアされない: filtering=%v query=%q", m.filtering, m.query)
	}
	if got := len(m.visible()); got != len(m.items) {
		t.Errorf("解除後に全件へ戻っていない: %d 件", got)
	}
}

func TestNormalEscClearsFilterBeforeReturningFocus(t *testing.T) {
	m := groupedModel()
	m, _ = pressKeys(m, runesKey("/"), runesKey("c"), tea.KeyMsg{Type: tea.KeyEnter})

	m, cmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyEsc})
	if m.query != "" {
		t.Fatalf("1 回目の Esc でフィルタが解除されない: %q", m.query)
	}
	if isFocusInner(cmd) {
		t.Error("フィルタ解除のはずがフォーカスを右へ返した")
	}

	_, cmd = pressKeys(m, tea.KeyMsg{Type: tea.KeyEsc})
	if !isFocusInner(cmd) {
		t.Error("フィルタが無い時の Esc でフォーカスが返らない")
	}
}

func TestFilterModeKeepsExitKeys(t *testing.T) {
	m := groupedModel()
	m, _ = pressKeys(m, runesKey("/"))

	if _, cmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlC}); cmd == nil {
		t.Error("入力モード中に ctrl+c が効かない")
	}
	after, cmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlB}, runesKey("N"))
	if !isFocusInner(cmd) {
		t.Error("入力モード中に prefix + jump key が効かない")
	}
	if after.query != "" {
		t.Errorf("prefix + jump key が query に取り込まれた: %q", after.query)
	}
}

func TestViewShowsSessionHeadersAndFilterLine(t *testing.T) {
	m := groupedModel()
	view := m.View()
	if !strings.Contains(view, "▸ work (2)") || !strings.Contains(view, "▸ personal (1)") {
		t.Fatalf("session 見出しが出ていない:\n%s", view)
	}
	if strings.Contains(view, "filter:") {
		t.Error("フィルタ未使用なのにフィルタ行が出ている")
	}

	m, _ = pressKeys(m, runesKey("/"), runesKey("c"))
	view = m.View()
	if !strings.Contains(view, "filter: c_ (1/3)") {
		t.Errorf("入力中のフィルタ行が誤り:\n%s", view)
	}
	if strings.Contains(view, "▸ personal") {
		t.Error("一致しない session の見出しが残っている")
	}
}
