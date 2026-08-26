package main

import (
	"strings"

	"github.com/mattn/go-runewidth"
)

// 行の幅は文字数ではなく端末のセル数で数える。絵文字 (🔔) は 2 セル、
// 罫線・矢印・三角 (─ ↑ ↓ ▸) は East Asian ambiguous で端末設定により 1 か 2 セルになる。
// 狭く見積もると pane 幅を超えて折り返し、行数が増えて描画全体が崩れるため、
// 曖昧幅は必ず広い方 (2 セル) として数える。余分に切り詰める方が崩れない
var cells = func() *runewidth.Condition {
	condition := runewidth.NewCondition()
	condition.EastAsianWidth = true
	return condition
}()

func displayWidth(text string) int {
	return cells.StringWidth(text)
}

func truncate(text string, width int) string {
	if width <= 0 {
		return ""
	}
	return cells.Truncate(text, width, "")
}

// 区切り線に罫線 (─) を使うと ambiguous 幅のせいで端末によって長さが倍になる。
// どの端末でも 1 セルの ASCII で引く
func rule(width int) string {
	if width <= 0 {
		return ""
	}
	return strings.Repeat("-", width)
}
