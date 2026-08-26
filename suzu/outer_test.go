package main

import (
	"strings"
	"testing"
)

func TestParseDoorbellHookTargetsPicksOwnEntriesOnly(t *testing.T) {
	// tmux 3.6a の実出力形式。ユーザー自身の hook を巻き込まずに自分の分だけ拾う
	out := `after-set-option[0] run-shell -b "echo user hook"
after-set-option[1] run-shell -b "touch '/home/me/.local/state/suzu/doorbell'"
after-set-option[2] run-shell -b "notify-send changed"
`
	targets := parseDoorbellHookTargets(out, "/home/me/.local/state/suzu/doorbell")
	if len(targets) != 1 || targets[0] != "after-set-option[1]" {
		t.Fatalf("自分の hook だけを拾えていない: %q", targets)
	}
}

func TestParseDoorbellHookTargetsAcceptsUnindexedEntry(t *testing.T) {
	// 添字を付けずに単独エントリを出す tmux 版でも解除できること
	out := "after-set-option run-shell -b \"touch '/tmp/doorbell'\"\n"
	targets := parseDoorbellHookTargets(out, "/tmp/doorbell")
	if len(targets) != 1 || targets[0] != "after-set-option" {
		t.Fatalf("添字なしのエントリを拾えていない: %q", targets)
	}
}

func TestParseDoorbellHookTargetsIgnoresUnsetHook(t *testing.T) {
	// 未設定の hook は名前だけの行として出る
	if targets := parseDoorbellHookTargets("after-set-option\n", "/tmp/doorbell"); targets != nil {
		t.Fatalf("未設定の hook を自分のものとして拾った: %q", targets)
	}
	if targets := parseDoorbellHookTargets("", "/tmp/doorbell"); targets != nil {
		t.Fatalf("空出力で hook が生えた: %q", targets)
	}
}

func TestParseDoorbellHookTargetsMatchesOnlyOwnDoorbellFile(t *testing.T) {
	// 別の suzu (別 socket・別 doorbell) の hook には触らない
	out := "after-set-option[0] run-shell -b \"touch '/tmp/other/doorbell'\"\n"
	if targets := parseDoorbellHookTargets(out, "/tmp/mine/doorbell"); targets != nil {
		t.Fatalf("別の doorbell の hook を拾った: %q", targets)
	}
}

func TestExportedEnvCarriesExplicitOverridesOnly(t *testing.T) {
	for _, name := range explicitOnlyEnv {
		t.Setenv(name, "")
	}
	cfg := Config{
		InnerTmux:    []string{"tmux"},
		OuterSocket:  "suzu",
		JumpKey:      "N",
		ToggleKey:    "b",
		SidebarWidth: defaultWidth,
		DoorbellFile: "/tmp/doorbell",
	}
	for _, name := range explicitOnlyEnv {
		if strings.Contains(cfg.exportedEnv(), name+"=") {
			t.Errorf("未指定の %s を焼き込んでいる: %s", name, cfg.exportedEnv())
		}
	}

	t.Setenv("SUZU_INNER_TMUX_CMD", "tmux -L inner attach")
	if !strings.Contains(cfg.exportedEnv(), "SUZU_INNER_TMUX_CMD='tmux -L inner attach'") {
		t.Errorf("明示指定した SUZU_INNER_TMUX_CMD が引き継がれない: %s", cfg.exportedEnv())
	}
	// 注入した bind の所有マーカーが常に含まれること (stop の選択的 unbind の前提)
	if !strings.Contains(cfg.exportedEnv(), injectedKeyMarker) {
		t.Errorf("所有マーカーが含まれていない: %s", cfg.exportedEnv())
	}
}
