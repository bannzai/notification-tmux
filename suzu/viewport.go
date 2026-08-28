package main

import "fmt"

// リストが縦に収まらない時、リストへ最低限残す行数
const minListRows = 3

// 画面に並ぶリストの 1 行。session 見出しはカーソルの対象外なので、
// window 行だけが visible() での添字を持つ
type displayRow struct {
	text      string
	style     string
	itemIndex int
}

// 通知は見出しなしで先頭に、セクションは名前と件数の見出しを付けてその下に並べる。
// どちらも配下は session ごとにまとめる
func (m model) listRows() []displayRow {
	var rows []displayRow
	index := 0
	for _, section := range splitBySection(m.visible()) {
		if section.Title != "" {
			rows = append(rows, displayRow{
				text:      sectionHeader(section.Title, len(section.Items)),
				style:     styleSection,
				itemIndex: -1,
			})
		}
		for _, group := range groupBySession(section.Items) {
			rows = append(rows, displayRow{
				text:      fmt.Sprintf("%s %s (%d)", sessionMarker, group.Session, len(group.Items)),
				style:     styleSession,
				itemIndex: -1,
			})
			for _, item := range group.Items {
				// session 名は見出しに出るので window 行からは外す
				rows = append(rows, displayRow{
					text:      fmt.Sprintf("%s %s %s", item.Icon, item.WindowIndex, item.WindowName),
					itemIndex: index,
				})
				index++
			}
		}
	}
	return rows
}

// 罫線は ambiguous 幅で端末により長さが変わるため ASCII で囲む (width.go の rule と同じ理由)
func sectionHeader(title string, count int) string {
	return fmt.Sprintf("-- %s (%d) --", title, count)
}

func cursorRow(rows []displayRow, cursor int) int {
	for at, row := range rows {
		if row.itemIndex == cursor {
			return at
		}
	}
	return 0
}

// 画面の縦を「固定行 → プレビュー → リスト」の順に割り当てる。
// 画面が狭い時はプレビューを削ってリストの席 (minListRows) を先に確保する
func (m model) layout() (listBudget int, previewBudget int) {
	rows := len(m.listRows())
	if m.height <= 0 {
		// サイズ未取得 (初回描画など) では詰めない
		return rows, len(m.preview)
	}
	fixed := 2 + len(m.footerLines()) // ヘッダー + フッター前の空行 + フッター
	if !m.connected {
		fixed++
	}
	if m.filtering || m.query != "" {
		fixed++
	}
	// View は「通知なし」か「一致なし」のどちらか 1 行を出す
	if len(m.items) == 0 || len(m.visible()) == 0 {
		fixed++
	}
	if m.err != nil {
		fixed++
	}
	if m.sectionErr != nil {
		fixed++
	}
	if len(m.preview) > 0 {
		fixed++ // プレビューの区切り線
	}

	available := m.height - fixed
	if available < 1 {
		return 1, 0
	}
	previewBudget = len(m.preview)
	if rows+previewBudget > available {
		room := available - minListRows
		if room < 0 {
			room = 0
		}
		if previewBudget > room {
			previewBudget = room
		}
	}
	listBudget = available - previewBudget
	if listBudget > rows {
		listBudget = rows
	}
	if listBudget < 1 {
		listBudget = 1
	}
	return listBudget, previewBudget
}

// リスト表示域に実際に入る行数と、スクロールが要るかどうか
func (m model) scrollGeometry() (rows []displayRow, capacity int, scrolling bool) {
	rows = m.listRows()
	capacity, _ = m.layout()
	scrolling = len(rows) > capacity
	if scrolling {
		// 上下のインジケータで 2 行使う
		capacity -= 2
		if capacity < 1 {
			capacity = 1
		}
	}
	return rows, capacity, scrolling
}

func (m model) syncOffset() model {
	rows, capacity, _ := m.scrollGeometry()
	m.offset = adjustOffset(m.offset, cursorRow(rows, m.cursor), len(rows), capacity)
	return m
}

// カーソル行が表示域に入る範囲で、今の位置からいちばん動かさずに済む先頭行を返す。
// 上下どちらに外れたかで最小限だけずらすので、カーソルが端に貼り付かない
func adjustOffset(offset, cursor, total, capacity int) int {
	if capacity >= total {
		return 0
	}
	if last := total - capacity; offset > last {
		offset = last
	}
	if offset < 0 {
		offset = 0
	}
	if cursor < offset {
		return cursor
	}
	if cursor >= offset+capacity {
		return cursor - capacity + 1
	}
	return offset
}
