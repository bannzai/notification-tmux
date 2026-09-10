package main

import (
	tea "github.com/charmbracelet/bubbletea"
)

// 通知サイドバーの TUI。外側 tmux の左 pane で走る。
// 再取得のトリガは push (doorbell ファイルの fsnotify と control mode client の
// ツリーイベント) と、pane 内のプロセス・画面内容を見直す低頻度の時間駆動 (watcher.go)
func runSidebar(cfg Config) error {
	// remote-host はサイドバーの起動時に 1 回読む。変更した時は toggle で開き直す
	cfg.RemoteHosts = readRemoteHosts(cfg.ConfigFile)
	program := tea.NewProgram(newModel(cfg, fetchInnerPrefix(cfg)))
	go newWatcher(cfg, program).run()
	_, err := program.Run()
	return err
}
