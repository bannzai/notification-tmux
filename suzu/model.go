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
	styleSection  = "\x1b[1;4m"
)

// 1 つの host (ローカルは "") から取り直した通知一覧
type notificationsMsg struct {
	host  string
	items []Notification
	err   error
	// ssh が繋がらない (host が落ちている・鍵認証で入れない)。リモートだけが取る
	unreachable bool
}

// セクション (プロセス別の pane 一覧) の再取得結果。通知の再取得と別メッセージにするのは、
// セクションが ps でマシン全体のプロセスを走査するため遅く、これを通知の再取得に混ぜると
// @claude-waiting の更新 (list-panes だけで速い) まで巻き添えで遅れるため (watcher.go 参照)
type sectionsMsg struct {
	sections []paneSection
	err      error
}

type connectionMsg struct {
	host      string
	connected bool
	// control client の ssh が失敗した。connected が false の時だけ意味を持つ
	unreachable bool
}

type actionMsg struct{ err error }

// ジャンプの完了。処理中は次の Enter を受け付けないため、actionMsg と分けて解除の合図にする
type jumpDoneMsg struct{ err error }

// 選択中の通知が出ている pane の見た目。取得中に選択が動いた結果を捨てられるよう
// どの行のものか (Notification.key) を一緒に運ぶ
type previewMsg struct {
	key   string
	lines []string
}

// リモート host ごとの最新の取得結果。ローカルは model の local / err / connected が持つ
type hostState struct {
	items       []Notification
	err         error
	unreachable bool
}

type model struct {
	cfg    Config
	prefix prefixKey
	// 全 host の通知を表示順 (ローカル → remote-host の記述順) に並べたもの。
	// 画面に出るのは query を適用した visible() の方
	items []Notification
	// ローカル (内側 tmux) の通知
	local []Notification
	// リモート host ごとの取得結果。items はここと local を合成して作る
	remote map[string]hostState
	// 通知の下に並ぶプロセス別のセクション (Claude / Codex / 設定ファイルの section)
	sections []paneSection
	// セクション取得 (list-panes / ps) の失敗。表示中のセクションは保持したまま原因を出す
	sectionErr error
	cursor     int
	query      string
	// フィルタ入力モード。printable キーを query へ取り込む
	filtering bool
	preview   []string
	connected bool
	// prefix を受けた直後。次の 1 キーが jump key なら内側へ戻り、toggle key なら閉じる
	awaitingPrefixKey bool
	// ジャンプの tea.Cmd が実行中。bubbletea は Cmd を並行して走らせるため、Enter の連打で
	// リモートの attach 用 window の「無ければ作る」が重なって二重に作られないよう直列化する
	jumping bool
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
		key := m.selectedKey()
		if msg.host == "" {
			m.local = msg.items
			m.err = msg.err
		} else {
			m = m.updateRemote(msg.host, func(state *hostState) {
				state.items = msg.items
				state.err = msg.err
				state.unreachable = msg.unreachable
			})
		}
		// 一覧が同じなら items は入れ替えない (無駄な cursor 復元を避ける)。ただし選択中 pane の
		// 中身は一覧が変わらなくても更新され得るため、プレビューの取り直しだけは必ず行う
		merged := m.mergeItems()
		if sameItems(m.items, merged) {
			return m, m.previewCmd()
		}
		m.items = merged
		return m.restoreCursor(key), m.previewCmd()
	case sectionsMsg:
		// 取得に失敗した時は表示中のセクションを消さず保持し、原因だけ差し替える。
		// 失敗で全セクションが黙って消えるのを防ぐ
		if msg.err != nil {
			if sameErr(m.sectionErr, msg.err) {
				return m, m.previewCmd()
			}
			m.sectionErr = msg.err
			return m, m.previewCmd()
		}
		if m.sectionErr == nil && m.sameSections(msg.sections) {
			return m, m.previewCmd()
		}
		key := m.selectedKey()
		m.sections = msg.sections
		m.sectionErr = nil
		return m.restoreCursor(key), m.previewCmd()
	case previewMsg:
		if msg.key == m.selectedKey() {
			m.preview = msg.lines
		}
	case connectionMsg:
		if msg.host == "" {
			m.connected = msg.connected
		} else {
			m = m.updateRemote(msg.host, func(state *hostState) {
				// 繋がった時点で未接続を解き、その後の一覧取得の結果で改めて決める
				state.unreachable = !msg.connected && msg.unreachable
			})
		}
	case actionMsg:
		m.err = msg.err
	case jumpDoneMsg:
		m.jumping = false
		m.err = msg.err
	case tea.KeyMsg:
		return m.updateKey(msg)
	}
	return m, nil
}

// model は値で受け渡すため map は共有される。Update は直列に呼ばれるので書き換えてよい
func (m model) updateRemote(host string, apply func(state *hostState)) model {
	if m.remote == nil {
		m.remote = map[string]hostState{}
	}
	state := m.remote[host]
	apply(&state)
	m.remote[host] = state
	return m
}

// ローカル → remote-host の記述順で通知を並べる。host ごとの取得は独立しているため、
// 1 つの host の更新で他の host の表示が消えない
func (m model) mergeItems() []Notification {
	merged := append([]Notification{}, m.local...)
	for _, host := range m.cfg.RemoteHosts {
		merged = append(merged, m.remote[host].items...)
	}
	return merged
}

// ヘッダー直下に出す接続状態。ローカルの未接続と、繋がらないリモート host を 1 行ずつ出す。
// 繋がらない host があっても他の host の一覧は止めない
func (m model) statusLines() []string {
	var lines []string
	if !m.connected {
		lines = append(lines, "内側 tmux 未接続")
	}
	for _, host := range m.cfg.RemoteHosts {
		state := m.remote[host]
		switch {
		case state.unreachable:
			lines = append(lines, host+": 未接続")
		case state.err != nil:
			lines = append(lines, host+": "+state.err.Error())
		}
	}
	return lines
}

// 通知 → 各セクションの順に並べた全行 (フィルタ前)
func (m model) allItems() []Notification {
	all := append([]Notification{}, m.items...)
	for _, section := range m.sections {
		all = append(all, section.Items...)
	}
	return all
}

// 選択中の行の識別子 (無選択なら空)。再取得で並びが変わっても同じ行へ戻すために使う
func (m model) selectedKey() string {
	if selected, ok := m.selected(); ok {
		return selected.key()
	}
	return ""
}

// セクションの並びが今と同じか。見出しと配下の行 (表示に出る全フィールド) を見る
func (m model) sameSections(sections []paneSection) bool {
	if len(m.sections) != len(sections) {
		return false
	}
	for i := range m.sections {
		if m.sections[i].Title != sections[i].Title || !sameItems(m.sections[i].Items, sections[i].Items) {
			return false
		}
	}
	return true
}

// error の有無・文面が同じか
func sameErr(a, b error) bool {
	if (a == nil) != (b == nil) {
		return false
	}
	return a == nil || a.Error() == b.Error()
}

// 通知 (Notification) の並びが同じか。表示に出る全フィールドを比較する
func sameItems(a, b []Notification) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// 画面に並ぶ順そのままの選択対象行。cursor / selected() はこの並びの添字を指すため、
// listRows の itemIndex と一致していなければならない。listRows は section → session の順に
// 並べ替える (splitBySection → groupBySession) ので、visible() も同じ並べ替えを通す。
// これを怠ると、同名タイトルのセクションが複数 session にまたがった時に、表示上の行と
// cursor の指す行がずれ、選んだ行と別の行へジャンプ・プレビューする
func (m model) visible() []Notification {
	filtered := filterNotifications(m.allItems(), m.query)
	var ordered []Notification
	for _, section := range splitBySection(filtered) {
		for _, group := range groupBySession(section.Items) {
			ordered = append(ordered, group.Items...)
		}
	}
	return ordered
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

// 再取得で items の並びが変わると整数の cursor は別の行を指してしまう。
// 更新前に選んでいた行 (key) を探し直し、消えていた時だけ位置で丸める
func (m model) restoreCursor(key string) model {
	if key != "" {
		for index, item := range m.visible() {
			if item.key() == key {
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
		if visible := m.visible(); m.cursor < len(visible) && !m.jumping {
			m.jumping = true
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
	return func() tea.Msg { return jumpDoneMsg{err: jump(cfg, n)} }
}

func (m model) toggleCmd() tea.Cmd {
	cfg := m.cfg
	return func() tea.Msg { return actionMsg{err: cmdToggle(cfg)} }
}

func (m model) previewCmd() tea.Cmd {
	cfg := m.cfg
	selected, ok := m.selected()
	if !ok || selected.PaneID == "" {
		return func() tea.Msg { return previewMsg{} }
	}
	return func() tea.Msg {
		lines := fetchPreview(cfg, selected.PaneID, previewLineCount)
		if selected.Host != "" {
			lines = fetchRemotePreview(cfg, selected.Host, selected.PaneID, previewLineCount)
		}
		return previewMsg{key: selected.key(), lines: lines}
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
	for _, line := range m.statusLines() {
		writeLine(&b, line, width, "")
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
	if m.sectionErr != nil {
		writeLine(&b, m.sectionErr.Error(), width, "")
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
	return fmt.Sprintf("filter: %s (%d/%d)", query, matched, len(m.allItems()))
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
