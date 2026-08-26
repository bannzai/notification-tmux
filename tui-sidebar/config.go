package main

import (
	"os"
	"path/filepath"
	"strings"
)

// サイドバー TUI が外側 / 内側 tmux と doorbell ファイルへ到達するための設定。
// すべて環境変数で与えられ、noroshi-outer が pane 起動時に引き継ぐ
type Config struct {
	// 内側 tmux server へ命令するコマンド。"tmux -L socket" のような複数語を許すため slice
	InnerTmux    []string
	OuterSocket  string
	DoorbellFile string
}

func loadConfig() Config {
	inner := strings.Fields(os.Getenv("NOROSHI_INNER_TMUX"))
	if len(inner) == 0 {
		inner = []string{"tmux"}
	}
	socket := os.Getenv("NOROSHI_OUTER_SOCKET")
	if socket == "" {
		socket = "noroshi"
	}
	return Config{
		InnerTmux:    inner,
		OuterSocket:  socket,
		DoorbellFile: doorbellFile(),
	}
}

func doorbellFile() string {
	if path := os.Getenv("NOROSHI_DOORBELL_FILE"); path != "" {
		return path
	}
	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		state = filepath.Join(os.Getenv("HOME"), ".local", "state")
	}
	return filepath.Join(state, "noroshi", "doorbell")
}
