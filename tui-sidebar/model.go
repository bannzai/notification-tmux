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
	// 反転表示。lipgloss を足さずに選択行を強調するため生の SGR を使う
	reverseOn  = "\x1b[7m"
	reverseOff = "\x1b[0m"
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
	cfg       Config
	prefix    prefixKey
	items     []Notification
	cursor    int
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
		if m.cursor >= len(m.items) {
			m.cursor = len(m.items) - 1
		}
		if m.cursor < 0 {
			m.cursor = 0
		}
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

func (m model) selectedPaneID() string {
	if m.cursor < 0 || m.cursor >= len(m.items) {
		return ""
	}
	return m.items[m.cursor].PaneID
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
	switch key {
	case "q", "esc":
		// pane が死ぬと外側の額縁が壊れるため、終了せずフォーカスだけ内側へ返す
		return m, m.focusInnerCmd()
	case "up", "k":
		if m.cursor > 0 {
			m.cursor--
			return m, m.previewCmd()
		}
	case "down", "j":
		if m.cursor < len(m.items)-1 {
			m.cursor++
			return m, m.previewCmd()
		}
	case "enter":
		if m.cursor < len(m.items) {
			return m, m.jumpCmd(m.items[m.cursor])
		}
	}
	return m, nil
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
	writeLine(&b, header, width, false)
	if !m.connected {
		writeLine(&b, "内側 tmux 未接続", width, false)
	}
	if len(m.items) == 0 {
		writeLine(&b, "通知なし", width, false)
	}
	for i, item := range m.items {
		line := fmt.Sprintf("%s %s:%s %s", item.Icon, item.Session, item.WindowIndex, item.WindowName)
		if i == m.cursor {
			writeLine(&b, "> "+line, width, true)
		} else {
			writeLine(&b, "  "+line, width, false)
		}
	}
	if len(m.preview) > 0 {
		writeLine(&b, strings.Repeat("─", width), width, false)
		for _, line := range m.preview {
			writeLine(&b, line, width, false)
		}
	}
	b.WriteString("\n")
	writeLine(&b, m.footer(), width, false)
	if m.err != nil {
		writeLine(&b, m.err.Error(), width, false)
	}
	return b.String()
}

func (m model) footer() string {
	return fmt.Sprintf("j/k:選択 Enter:ジャンプ %s %s:右へ", m.prefix.Display, m.cfg.JumpKey)
}

func writeLine(b *strings.Builder, text string, width int, emphasized bool) {
	text = truncate(text, width)
	if emphasized {
		b.WriteString(reverseOn + text + reverseOff)
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
