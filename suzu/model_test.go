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
// 取り違えて普段の tmux や本番の suzu socket へ命令が飛ばないようにする
func testModel() model {
	cfg := Config{
		InnerTmux:   []string{"tmux", "-L", "suzu-unit-test-inner"},
		OuterSocket: "suzu-unit-test-outer",
		JumpKey:     "N",
	}
	return newModel(cfg, normalizePrefix("C-b"))
}

// キー処理は tmux を呼ぶ tea.Cmd を返すだけなので、実行せず「返ったかどうか」で判定する
func pressKeys(m model, keys ...tea.KeyMsg) (model, tea.Cmd) {
	var cmd tea.Cmd
	for _, key := range keys {
		m, cmd = m.updateKey(key)
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
	if m.awaitingPrefixKey {
		t.Error("jump key を受けた後も prefix 待ちのままになっている")
	}
}

func TestPrefixAloneWaitsForJumpKey(t *testing.T) {
	m, cmd := pressKeys(testModel(), tea.KeyMsg{Type: tea.KeyCtrlB})
	if cmd != nil {
		t.Error("prefix だけでフォーカスが動いた")
	}
	if !m.awaitingPrefixKey {
		t.Error("prefix を受けても次のキー待ちになっていない")
	}
}

func TestPrefixThenOtherKeyIsCancelled(t *testing.T) {
	m, cmd := pressKeys(testModel(), tea.KeyMsg{Type: tea.KeyCtrlB}, runesKey("x"))
	if cmd != nil {
		t.Error("prefix + jump key 以外でフォーカスが動いた")
	}
	if m.awaitingPrefixKey {
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
	if want := "/:絞込 C-t N か q:右へ"; lines[1] != want {
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

// prefix シーケンスがどの操作を選んだかは、返る actionMsg のエラー文面で見分ける
// (socket が実在しないので、どちらの分岐も固有の失敗メッセージを返す)
func actionError(cmd tea.Cmd) string {
	if cmd == nil {
		return ""
	}
	msg, ok := cmd().(actionMsg)
	if !ok || msg.err == nil {
		return ""
	}
	return msg.err.Error()
}

func TestPrefixThenToggleKeyClosesSidebar(t *testing.T) {
	m := testModel()
	m.cfg.ToggleKey = "b"

	after, cmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlB}, runesKey("b"))
	if got := actionError(cmd); !strings.Contains(got, "先に start") {
		t.Errorf("prefix + toggle key で toggle が呼ばれていない: %q", got)
	}
	if after.awaitingPrefixKey {
		t.Error("toggle key を受けた後も prefix 待ちのままになっている")
	}
}

func TestPrefixSequenceDistinguishesJumpAndToggle(t *testing.T) {
	m := testModel()
	m.cfg.ToggleKey = "b"

	_, cmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlB}, runesKey("N"))
	if got := actionError(cmd); !strings.Contains(got, "外側 pane の列挙") {
		t.Errorf("prefix + jump key で focusInner が呼ばれていない: %q", got)
	}

	// prefix の次が jump key でも toggle key でもなければ何も起きない
	if _, cmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlB}, runesKey("z")); cmd != nil {
		t.Error("prefix + 無関係なキーで操作が走った")
	}
}

func TestPrefixThenToggleKeyWorksWhileFiltering(t *testing.T) {
	m := groupedModel()
	m.cfg.ToggleKey = "b"
	m, _ = pressKeys(m, runesKey("/"), runesKey("wo"))

	after, cmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlB}, runesKey("b"))
	if got := actionError(cmd); !strings.Contains(got, "先に start") {
		t.Errorf("入力モード中に prefix + toggle key が効かない: %q", got)
	}
	if after.query != "wo" {
		t.Errorf("prefix + toggle key が query に取り込まれた: %q", after.query)
	}
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

func TestFilterModeEmacsEditingKeys(t *testing.T) {
	start := func() model {
		m := groupedModel()
		m, _ = pressKeys(m, runesKey("/"))
		m, _ = pressKeys(m, runesKey("wo"), runesKey("rk"))
		return m
	}

	m, _ := pressKeys(start(), tea.KeyMsg{Type: tea.KeyCtrlH})
	if m.query != "wor" {
		t.Errorf("ctrl+h で 1 文字削除されない: %q", m.query)
	}

	m, _ = pressKeys(start(), tea.KeyMsg{Type: tea.KeyCtrlU})
	if m.query != "" {
		t.Errorf("ctrl+u で全削除されない: %q", m.query)
	}
	if !m.filtering {
		t.Error("ctrl+u で入力モードから抜けてしまった")
	}

	m, _ = pressKeys(start(), tea.KeyMsg{Type: tea.KeyCtrlW})
	if m.query != "" {
		t.Errorf("ctrl+w で単語が消えない: %q", m.query)
	}
}

func TestDeleteLastWord(t *testing.T) {
	cases := map[string]string{
		"foo bar":   "foo ",
		"foo bar  ": "foo ",
		"foo":       "",
		"foo   ":    "",
		"":          "",
		"a b c":     "a b ",
	}
	for query, want := range cases {
		if got := deleteLastWord(query); got != want {
			t.Errorf("deleteLastWord(%q) = %q, want %q", query, got, want)
		}
	}
}

func TestCtrlNAndCtrlPMoveCursorInBothModes(t *testing.T) {
	m := groupedModel()
	m, _ = pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlN})
	if got := m.selectedPaneID(); got != "%2" {
		t.Errorf("通常モードの ctrl+n で下へ動かない: %q", got)
	}
	m, _ = pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlP})
	if got := m.selectedPaneID(); got != "%1" {
		t.Errorf("通常モードの ctrl+p で上へ戻らない: %q", got)
	}

	// 絞り込み中でも選択を動かせる (絞ってからそのまま選ぶ流れ)
	m, _ = pressKeys(m, runesKey("/"), runesKey("work"))
	if got := len(m.visible()); got != 2 {
		t.Fatalf("フィルタ結果が 2 件でない: %d", got)
	}
	m, _ = pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlN})
	if got := m.selectedPaneID(); got != "%2" {
		t.Errorf("入力モードの ctrl+n で下へ動かない: %q", got)
	}
	if m.query != "work" {
		t.Errorf("ctrl+n が query に取り込まれた: %q", m.query)
	}
}

func TestNotificationRefreshKeepsSelectedWindow(t *testing.T) {
	m := groupedModel()
	m, _ = pressKeys(m, runesKey("j"))
	if got := m.selectedPaneID(); got != "%2" {
		t.Fatalf("前提が崩れている (2 件目を選べていない): %q", got)
	}

	// 再取得で先頭に別の通知が割り込むと、整数の cursor はそのままでは別 window を指す
	refreshed, _ := m.Update(notificationsMsg{items: append(
		[]Notification{{Session: "new", WindowID: "@9", WindowName: "incoming", PaneID: "%9"}},
		sample()...)})
	if got := refreshed.(model).selectedPaneID(); got != "%2" {
		t.Errorf("更新後に選択中の window を見失っている: %q", got)
	}
}

func TestNotificationRefreshClampsWhenSelectedWindowIsGone(t *testing.T) {
	m := groupedModel()
	m, _ = pressKeys(m, runesKey("j"), runesKey("j"))

	refreshed, _ := m.Update(notificationsMsg{items: sample()[:1]})
	if got := refreshed.(model).cursor; got != 0 {
		t.Errorf("選択中 window が消えた時に丸められていない: cursor=%d", got)
	}
}

func TestPrefixIsCheckedBeforeCtrlC(t *testing.T) {
	// 内側 prefix が C-c の環境。C-c は quit ではなく prefix として働く
	m := newModel(Config{JumpKey: "N", ToggleKey: "b"}, normalizePrefix("C-c"))

	after, cmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlC})
	if cmd != nil {
		t.Error("prefix であるはずの ctrl+c で quit した")
	}
	if !after.awaitingPrefixKey {
		t.Error("ctrl+c が prefix として扱われていない")
	}

	// prefix が C-c でない環境では従来どおり quit する
	if _, cmd := pressKeys(testModel(), tea.KeyMsg{Type: tea.KeyCtrlC}); cmd == nil {
		t.Error("prefix が C-b の環境で ctrl+c が効かない")
	}
}

func TestTmuxNotationJumpKeyMatchesBubbleteaKey(t *testing.T) {
	// SUZU_INNER_JUMP_KEY=C-n のような tmux 表記でも、サイドバー側の判定が一致すること
	m := testModel()
	m.cfg.JumpKey = "C-n"
	m.cfg.ToggleKey = "M-b"

	_, jumpCmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlB}, tea.KeyMsg{Type: tea.KeyCtrlN})
	if got := actionError(jumpCmd); !strings.Contains(got, "外側 pane の列挙") {
		t.Errorf("tmux 表記の jump key (C-n) が prefix シーケンスで効かない: %q", got)
	}

	_, toggleCmd := pressKeys(m, tea.KeyMsg{Type: tea.KeyCtrlB},
		tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("b"), Alt: true})
	if got := actionError(toggleCmd); !strings.Contains(got, "先に start") {
		t.Errorf("tmux 表記の toggle key (M-b) が効かない: %q", got)
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
