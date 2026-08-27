package main

import "testing"

func TestIsRefreshEvent(t *testing.T) {
	refresh := []string{
		"%sessions-changed",
		"%session-renamed $0 main",
		"%session-window-changed $0 @3",
		"%window-add @5",
		"%window-close @5",
		"%window-renamed @5 claude-work",
		"%unlinked-window-add @7",
		"%unlinked-window-close @7",
		"%unlinked-window-renamed @7 build",
	}
	for _, line := range refresh {
		if !isRefreshEvent(line) {
			t.Errorf("再取得トリガとして扱われていない: %q", line)
		}
	}

	ignored := []string{
		"",
		"%begin 1740000000 1 0",
		"%end 1740000000 1 0",
		"%output %3 hello",
		"%exit",
		"%client-session-changed /dev/ttys001 $0 main",
		"%window-added @5",
		"  %window-add @5",
	}
	for _, line := range ignored {
		if isRefreshEvent(line) {
			t.Errorf("無関係な行で再取得している: %q", line)
		}
	}
}
