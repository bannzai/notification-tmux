package main

import (
	"strings"
	"testing"
)

func TestAdjustOffsetKeepsEverythingWhenItFits(t *testing.T) {
	if got := adjustOffset(3, 5, 8, 8); got != 0 {
		t.Fatalf("全部入るのにスクロールした: %d", got)
	}
}

func TestAdjustOffsetFollowsCursorDown(t *testing.T) {
	// 表示域 5 行・全 12 行。カーソルが下端を越えたら 1 行だけ送る
	if got := adjustOffset(0, 5, 12, 5); got != 1 {
		t.Errorf("下へはみ出した時の offset = %d, want 1", got)
	}
	if got := adjustOffset(0, 11, 12, 5); got != 7 {
		t.Errorf("末尾へ飛んだ時の offset = %d, want 7", got)
	}
}

func TestAdjustOffsetFollowsCursorUp(t *testing.T) {
	if got := adjustOffset(7, 6, 12, 5); got != 6 {
		t.Errorf("上へはみ出した時の offset = %d, want 6", got)
	}
}

func TestAdjustOffsetStaysWhenCursorVisible(t *testing.T) {
	// 表示域に入っている限り動かさない (カーソルが端に貼り付かない)
	if got := adjustOffset(4, 6, 12, 5); got != 4 {
		t.Errorf("見えているのにスクロールした: %d", got)
	}
}

func TestAdjustOffsetClampsToLastPage(t *testing.T) {
	if got := adjustOffset(99, 0, 12, 5); got != 0 {
		t.Errorf("行が減った後に offset が残った: %d", got)
	}
}

func scrollModel(sessions, windowsPerSession, height int) model {
	m := testModel()
	m.height = height
	m.connected = true
	index := 0
	for s := 0; s < sessions; s++ {
		for w := 0; w < windowsPerSession; w++ {
			index++
			m.items = append(m.items, Notification{
				Session:     string(rune('a' + s)),
				WindowID:    string(rune('0' + index)),
				WindowIndex: string(rune('0' + w)),
				WindowName:  "win",
				PaneID:      string(rune('0' + index)),
				Icon:        "🔔",
			})
		}
	}
	return m
}

func TestListRowsCountsSessionHeaders(t *testing.T) {
	rows := scrollModel(2, 3, 40).listRows()
	if len(rows) != 8 {
		t.Fatalf("見出し 2 + window 6 = 8 行にならない: %d", len(rows))
	}
	if rows[0].itemIndex != -1 || rows[1].itemIndex != 0 {
		t.Errorf("見出しと window 行の対応が誤り: %+v", rows[:2])
	}
	if got := cursorRow(rows, 3); got != 5 {
		t.Errorf("カーソル 3 の表示行 = %d, want 5 (見出しを跨ぐ)", got)
	}
}

func TestScrollGeometryReservesIndicatorRows(t *testing.T) {
	// 高さを絞ると表示域が全行より狭くなり、上下インジケータ 2 行が引かれる
	m := scrollModel(2, 6, 14)
	rows, capacity, scrolling := m.scrollGeometry()
	if !scrolling {
		t.Fatalf("全 %d 行が高さ 14 に収まる判定になっている (capacity=%d)", len(rows), capacity)
	}
	if capacity >= len(rows) {
		t.Errorf("capacity %d が全行 %d 以上", capacity, len(rows))
	}
	if capacity < 1 {
		t.Errorf("capacity が 1 未満: %d", capacity)
	}
}

func TestLayoutShrinksPreviewToKeepListRows(t *testing.T) {
	// 全 14 行 + プレビュー 10 行を高さ 16 に詰めるとどちらも入らない
	m := scrollModel(2, 6, 16)
	m.preview = make([]string, previewLineCount)

	listBudget, previewBudget := m.layout()
	if listBudget < minListRows {
		t.Errorf("リストの席が %d 行しか残っていない", listBudget)
	}
	if previewBudget >= previewLineCount {
		t.Errorf("狭い画面でプレビューが削られていない: %d 行", previewBudget)
	}
}

func TestLayoutKeepsFullPreviewWhenTall(t *testing.T) {
	m := scrollModel(1, 2, 60)
	m.preview = make([]string, previewLineCount)

	listBudget, previewBudget := m.layout()
	if previewBudget != previewLineCount {
		t.Errorf("高さに余裕があるのにプレビューが削られた: %d 行", previewBudget)
	}
	if listBudget != len(m.listRows()) {
		t.Errorf("全行入るはずが listBudget = %d", listBudget)
	}
}

func TestViewScrollsToCursorAndShowsIndicators(t *testing.T) {
	m := scrollModel(2, 6, 14)
	if got := m.View(); !strings.Contains(got, "↓") {
		t.Fatalf("下に続きがあるのにインジケータが無い:\n%s", got)
	}

	// 末尾までカーソルを送ると、最後の window 行が見えて上向きインジケータが出る
	for i := 0; i < len(m.items)-1; i++ {
		next, _ := m.moveCursor(1)
		m = next.syncOffset()
	}
	view := m.View()
	if !strings.Contains(view, "↑") {
		t.Errorf("上に隠れた行があるのにインジケータが無い:\n%s", view)
	}
	if !strings.Contains(view, "> 🔔") {
		t.Errorf("スクロール後に選択行が表示域から外れている:\n%s", view)
	}
}
