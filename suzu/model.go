package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

const (
	defaultWidth = 40
	// 選択中 pane のプレビュー行数。ユーザー要望の「10行くらい見れたら迷わない」に合わせる
	previewLineCount = 10
	sessionMarker    = "▸"
	// lipgloss を足さずに行を強調するため生の SGR を使う
	styleReset    = "\x1b[0m"
	styleSelected = "\x1b[7m"
	styleSession  = "\x1b[1m"
)

type notificationsMsg struct {
	items []Notification
	err   error
}

type connectionMsg struct{ connected bool }

type actionMsg struct{ err error }

// 選択中の通知が出ている pane の見た目。取得中に選択が動いた結果を捨てられるよう
// どの pane のものかを一緒に運ぶ
type previewMsg struct {
	paneID string
	lines  []string
}

type model struct {
	cfg    Config
	prefix prefixKey
	// tmux から取得した全通知。画面に出るのは query を適用した visible() の方
	items  []Notification
	cursor int
	query  string
	// フィルタ入力モード。printable キーを query へ取り込む
	filtering bool
	preview   []string
	connected bool
	// prefix を受けた直後。次の 1 キーが jump key なら内側へ戻り、toggle key なら閉じる
	awaitingPrefixKey bool
	// リスト表示域の先頭に来る行 (session 見出しを含む) の番号
	offset int
	err    error
	width  int
	height int
}

func newModel(cfg Config, prefix prefixKey) model {
	return model{cfg: cfg, prefix: prefix, width: defaultWidth}
}

func (m model) Init() tea.Cmd {
	return func() tea.Msg { return fetchNotifications(m.cfg) }
}

// 状態が動いたら必ずスクロール位置を追従させたいので、実処理は step に置いて
// ここで一度だけ syncOffset を通す
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	next, cmd := m.step(msg)
	return next.syncOffset(), cmd
}

func (m model) step(msg tea.Msg) (model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	case notificationsMsg:
		selected, _ := m.selected()
		m.items = msg.items
		m.err = msg.err
		m = m.restoreCursor(selected.WindowID)
		return m, m.previewCmd()
	case previewMsg:
		if msg.paneID == m.selectedPaneID() {
			m.preview = msg.lines
		}
	case connectionMsg:
		m.connected = msg.connected
	case actionMsg:
		m.err = msg.err
	case tea.KeyMsg:
		return m.updateKey(msg)
	}
	return m, nil
}

func (m model) visible() []Notification {
	return filterNotifications(m.items, m.query)
}

// cursor は visible() の window 行だけを指す。session 見出しは対象外なので
// j/k は見出しを跨いで次の window へ進む
func (m model) clampCursor() model {
	if count := len(m.visible()); m.cursor >= count {
		m.cursor = count - 1
	}
	if m.cursor < 0 {
		m.cursor = 0
	}
	return m
}

// 再取得で items の並びが変わると整数の cursor は別の window を指してしまう。
// 更新前に選んでいた window を探し直し、消えていた時だけ位置で丸める
func (m model) restoreCursor(windowID string) model {
	if windowID != "" {
		for index, item := range m.visible() {
			if item.WindowID == windowID {
				m.cursor = index
				return m
			}
		}
	}
	return m.clampCursor()
}

func (m model) selected() (Notification, bool) {
	visible := m.visible()
	if m.cursor < 0 || m.cursor >= len(visible) {
		return Notification{}, false
	}
	return visible[m.cursor], true
}

func (m model) selectedPaneID() string {
	if item, ok := m.selected(); ok {
		return item.PaneID
	}
	return ""
}

func (m model) updateKey(msg tea.KeyMsg) (model, tea.Cmd) {
	key := msg.String()
	// フォーカスがサイドバーにある間は内側 tmux にキーが届かず、内側へ注入した
	// prefix バインドが効かない。同じ prefix シーケンスをサイドバー側でも解釈して、
	// 左右どちらにフォーカスがあっても同じキーで往復・開閉できるようにする。
	// prefix の判定を ctrl+c より先に置くのは、内側 prefix が C-c の環境でも
	// prefix として使えるようにするため
	if m.awaitingPrefixKey {
		m.awaitingPrefixKey = false
		switch key {
		case normalizeKey(m.cfg.JumpKey):
			return m, m.focusInnerCmd()
		case normalizeKey(m.cfg.ToggleKey):
			// 自 pane が kill され、このプロセスごと終了する
			return m, m.toggleCmd()
		}
		return m, nil
	}
	if key == m.prefix.Key {
		m.awaitingPrefixKey = true
		return m, nil
	}
	if key == "ctrl+c" {
		return m, tea.Quit
	}
	// 選択の上下は絞り込み中でも効かせる。フィルタで絞ってからそのまま選びたいため
	switch key {
	case "ctrl+p":
		return m.moveCursor(-1)
	case "ctrl+n":
		return m.moveCursor(1)
	}
	if m.filtering {
		return m.updateFilterKey(msg)
	}
	switch key {
	case "/":
		m.filtering = true
		return m, nil
	case "q":
		// pane が死ぬと外側の額縁が壊れるため、終了せずフォーカスだけ内側へ返す
		return m, m.focusInnerCmd()
	case "esc":
		// 絞り込み中の Esc は解除を優先し、フォーカスは動かさない
		if m.query != "" {
			return m.clearQuery()
		}
		return m, m.focusInnerCmd()
	case "up", "k":
		return m.moveCursor(-1)
	case "down", "j":
		return m.moveCursor(1)
	case "enter":
		if visible := m.visible(); m.cursor < len(visible) {
			return m, m.jumpCmd(visible[m.cursor])
		}
	}
	return m, nil
}

// ctrl+c・prefix + jump key・ctrl+n/p は updateKey 側で先に処理済みなので、
// ここでは残りをすべて query の編集として扱う
func (m model) updateFilterKey(msg tea.KeyMsg) (model, tea.Cmd) {
	switch msg.String() {
	case "enter":
		m.filtering = false
		return m, nil
	case "esc":
		m.filtering = false
		return m.clearQuery()
	// ctrl+h は端末によっては backspace と同じバイトで届くが、別扱いの端末もあるため両方受ける
	case "backspace", "ctrl+h":
		runes := []rune(m.query)
		if len(runes) == 0 {
			return m, nil
		}
		m.query = string(runes[:len(runes)-1])
		return m.requery()
	case "ctrl+u":
		return m.clearQuery()
	case "ctrl+w":
		m.query = deleteLastWord(m.query)
		return m.requery()
	}
	switch msg.Type {
	case tea.KeySpace:
		m.query += " "
		return m.requery()
	case tea.KeyRunes:
		m.query += string(msg.Runes)
		return m.requery()
	}
	return m, nil
}

// 末尾の空白ごと直前の単語を落とす (readline の ctrl+w と同じ挙動)
func deleteLastWord(query string) string {
	trimmed := strings.TrimRight(query, " ")
	if at := strings.LastIndex(trimmed, " "); at >= 0 {
		return trimmed[:at+1]
	}
	return ""
}

func (m model) moveCursor(delta int) (model, tea.Cmd) {
	next := m.cursor + delta
	if next < 0 || next >= len(m.visible()) {
		return m, nil
	}
	m.cursor = next
	return m, m.previewCmd()
}

func (m model) clearQuery() (model, tea.Cmd) {
	m.query = ""
	return m.requery()
}

func (m model) requery() (model, tea.Cmd) {
	m = m.clampCursor()
	return m, m.previewCmd()
}

func (m model) focusInnerCmd() tea.Cmd {
	cfg := m.cfg
	return func() tea.Msg { return actionMsg{err: focusInner(cfg)} }
}

func (m model) jumpCmd(n Notification) tea.Cmd {
	cfg := m.cfg
	return func() tea.Msg { return actionMsg{err: jump(cfg, n)} }
}

func (m model) toggleCmd() tea.Cmd {
	cfg := m.cfg
	return func() tea.Msg { return actionMsg{err: cmdToggle(cfg)} }
}

func (m model) previewCmd() tea.Cmd {
	cfg := m.cfg
	paneID := m.selectedPaneID()
	if paneID == "" {
		return func() tea.Msg { return previewMsg{} }
	}
	return func() tea.Msg {
		return previewMsg{paneID: paneID, lines: fetchPreview(cfg, paneID, previewLineCount)}
	}
}

func (m model) View() string {
	width := m.width
	if width <= 0 {
		width = defaultWidth
	}
	var b strings.Builder
	header := "Noroshi"
	if len(m.items) > 0 {
		header = fmt.Sprintf("Noroshi 🔔%d", len(m.items))
	}
	writeLine(&b, header, width, "")
	if !m.connected {
		writeLine(&b, "内側 tmux 未接続", width, "")
	}

	visible := m.visible()
	if m.filtering || m.query != "" {
		writeLine(&b, m.filterLine(len(visible)), width, "")
	}
	switch {
	case len(m.items) == 0:
		writeLine(&b, "通知なし", width, "")
	case len(visible) == 0:
		writeLine(&b, "一致なし", width, "")
	}

	rows, capacity, scrolling := m.scrollGeometry()
	offset := adjustOffset(m.offset, cursorRow(rows, m.cursor), len(rows), capacity)
	end := offset + capacity
	if end > len(rows) {
		end = len(rows)
	}
	if scrolling {
		writeLine(&b, hiddenCount("↑", offset), width, "")
	}
	for _, row := range rows[offset:end] {
		text, style := row.text, row.style
		if row.itemIndex >= 0 {
			if row.itemIndex == m.cursor {
				text, style = "> "+text, styleSelected
			} else {
				text = "  " + text
			}
		}
		writeLine(&b, text, width, style)
	}
	if scrolling {
		writeLine(&b, hiddenCount("↓", len(rows)-end), width, "")
	}

	if _, previewBudget := m.layout(); previewBudget > 0 {
		writeLine(&b, rule(width), width, "")
		// 画面が狭い時は末尾側 (新しい出力) を優先して残す
		preview := m.preview
		if len(preview) > previewBudget {
			preview = preview[len(preview)-previewBudget:]
		}
		for _, line := range preview {
			writeLine(&b, line, width, "")
		}
	}
	b.WriteString("\n")
	for _, line := range m.footerLines() {
		writeLine(&b, line, width, "")
	}
	if m.err != nil {
		writeLine(&b, m.err.Error(), width, "")
	}
	// 末尾の改行を残すと bubbletea が空行 1 行として数え、pane が埋まっている時に
	// 先頭のヘッダーが押し出される
	lines := strings.Split(strings.TrimRight(b.String(), "\n"), "\n")
	// 高さ収支の計算漏れがあっても崩さないための防波堤。pane より縦長を描くと
	// bubbletea は上端を押し出し、差分描画の残骸で行が重複する。
	// 末尾を落として必ずヘッダー側を残す
	if m.height > 0 && len(lines) > m.height {
		lines = lines[:m.height]
	}
	return strings.Join(lines, "\n")
}

func (m model) filterLine(matched int) string {
	query := m.query
	if m.filtering {
		query += "_"
	}
	return fmt.Sprintf("filter: %s (%d/%d)", query, matched, len(m.items))
}

// 画面外に続きがある時だけ件数を出す。行数は変えずに空行にして、
// スクロールの有無でリストの高さが揺れないようにする
func hiddenCount(marker string, count int) string {
	if count <= 0 {
		return ""
	}
	return fmt.Sprintf("%s %d", marker, count)
}

// 幅 40 の pane に日本語 (全角) の案内を 1 行で詰めると溢れて末尾が切れるため 2 行に割る。
// prefix と jump key はユーザー設定で伸びるので、可変長の方を独立した行に置く
func (m model) footerLines() []string {
	return []string{
		"j/k C-n/C-p:選択 Enter:ジャンプ",
		fmt.Sprintf("/:絞込 %s %s か q:右へ", m.prefix.Display, m.cfg.JumpKey),
	}
}

func writeLine(b *strings.Builder, text string, width int, style string) {
	text = truncate(text, width)
	if style != "" {
		b.WriteString(style + text + styleReset)
	} else {
		b.WriteString(text)
	}
	b.WriteString("\n")
}
