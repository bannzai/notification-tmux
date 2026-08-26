// Noroshi サイドバー TUI: nested tmux (tui-spike/noroshi-outer) の左 pane に入り、
// 内側 tmux の @claude-waiting が付いた window を一覧表示してジャンプする。
//
// 再取得のトリガはすべて push (doorbell ファイルの fsnotify と control mode client の
// ツリーイベント) で、定期ポーリングは行わない。
package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

func main() {
	cfg := loadConfig()
	program := tea.NewProgram(newModel(cfg))
	go newWatcher(cfg, program).run()
	if _, err := program.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "エラー:", err)
		os.Exit(1)
	}
}
