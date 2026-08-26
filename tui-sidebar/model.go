package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

const (
	defaultWidth = 40
	footer       = "j/k:選択 Enter:ジャンプ q:右へ"
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

type model struct {
	cfg       Config
	items     []Notification
	cursor    int
	connected bool
	err       error
	width     int
}

func newModel(cfg Config) model {
	return model{cfg: cfg, width: defaultWidth}
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
	case connectionMsg:
		m.connected = msg.connected
	case actionMsg:
		m.err = msg.err
	case tea.KeyMsg:
		return m.updateKey(msg)
	}
	return m, nil
}

func (m model) updateKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	switch msg.String() {
	case "ctrl+c":
		return m, tea.Quit
	case "q", "esc":
		// pane が死ぬと外側の額縁が壊れるため、終了せずフォーカスだけ内側へ返す
		return m, m.focusInnerCmd()
	case "up", "k":
		if m.cursor > 0 {
			m.cursor--
		}
	case "down", "j":
		if m.cursor < len(m.items)-1 {
			m.cursor++
		}
	case "enter":
		if m.cursor < len(m.items) {
			return m, m.jumpCmd(m.items[m.cursor])
		}
	default:
		// フォーカスがサイドバーにある間は内側 tmux にキーが届かない。
		// サイドバーが解釈しないキーは飲み込まず、q/Esc と同じくフォーカスを返す
		return m, m.focusInnerCmd()
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
	b.WriteString("\n")
	writeLine(&b, footer, width, false)
	if m.err != nil {
		writeLine(&b, m.err.Error(), width, false)
	}
	return b.String()
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
