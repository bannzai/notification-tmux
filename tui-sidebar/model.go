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
	// prefix を受けた直後。次の 1 キーが jump key なら内側へ戻る
	awaitingJumpKey bool
	err             error
	width           int
}

func newModel(cfg Config, prefix prefixKey) model {
	return model{cfg: cfg, prefix: prefix, width: defaultWidth}
}

func (m model) Init() tea.Cmd {
	return func() tea.Msg { return fetchNotifications(m.cfg) }
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
	case notificationsMsg:
		m.items = msg.items
		m.err = msg.err
		m = m.clampCursor()
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

func (m model) selectedPaneID() string {
	visible := m.visible()
	if m.cursor < 0 || m.cursor >= len(visible) {
		return ""
	}
	return visible[m.cursor].PaneID
}

func (m model) updateKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()
	if key == "ctrl+c" {
		return m, tea.Quit
	}
	if m.awaitingJumpKey {
		m.awaitingJumpKey = false
		if key == m.cfg.JumpKey {
			return m, m.focusInnerCmd()
		}
		return m, nil
	}
	if key == m.prefix.Key {
		m.awaitingJumpKey = true
		return m, nil
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
		if m.cursor > 0 {
			m.cursor--
			return m, m.previewCmd()
		}
	case "down", "j":
		if m.cursor < len(m.visible())-1 {
			m.cursor++
			return m, m.previewCmd()
		}
	case "enter":
		if visible := m.visible(); m.cursor < len(visible) {
			return m, m.jumpCmd(visible[m.cursor])
		}
	}
	return m, nil
}

// ctrl+c と prefix + jump key は updateKey 側で先に処理済みなので、ここでは
// 残りをすべて query の編集として扱う
func (m model) updateFilterKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.Type {
	case tea.KeyEnter:
		m.filtering = false
		return m, nil
	case tea.KeyEsc:
		m.filtering = false
		return m.clearQuery()
	case tea.KeyBackspace:
		runes := []rune(m.query)
		if len(runes) == 0 {
			return m, nil
		}
		m.query = string(runes[:len(runes)-1])
		return m.requery()
	case tea.KeySpace:
		m.query += " "
		return m.requery()
	case tea.KeyRunes:
		m.query += string(msg.Runes)
		return m.requery()
	}
	return m, nil
}

func (m model) clearQuery() (tea.Model, tea.Cmd) {
	m.query = ""
	return m.requery()
}

func (m model) requery() (tea.Model, tea.Cmd) {
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

	row := 0
	for _, group := range groupBySession(visible) {
		writeLine(&b, fmt.Sprintf("%s %s (%d)", sessionMarker, group.Session, len(group.Items)), width, styleSession)
		for _, item := range group.Items {
			// session 名は見出しに出るので window 行からは外す
			line := fmt.Sprintf("%s %s %s", item.Icon, item.WindowIndex, item.WindowName)
			if row == m.cursor {
				writeLine(&b, "> "+line, width, styleSelected)
			} else {
				writeLine(&b, "  "+line, width, "")
			}
			row++
		}
	}

	if len(m.preview) > 0 {
		writeLine(&b, strings.Repeat("─", width), width, "")
		for _, line := range m.preview {
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
	return b.String()
}

func (m model) filterLine(matched int) string {
	query := m.query
	if m.filtering {
		query += "_"
	}
	return fmt.Sprintf("filter: %s (%d/%d)", query, matched, len(m.items))
}

// 幅 40 の pane に日本語 (全角) の案内を 1 行で詰めると溢れて末尾が切れるため 2 行に割る。
// prefix と jump key はユーザー設定で伸びるので、可変長の方を独立した行に置く
func (m model) footerLines() []string {
	return []string{
		"j/k:選択 Enter:ジャンプ /:絞込",
		fmt.Sprintf("%s %s か q:右へ", m.prefix.Display, m.cfg.JumpKey),
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

func truncate(text string, width int) string {
	runes := []rune(text)
	if len(runes) <= width {
		return text
	}
	return string(runes[:width])
}
