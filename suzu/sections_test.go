package main

import (
	"bufio"
	"strings"
	"testing"
)

func psLine(pid, ppid, args string) string {
	return pid + " " + ppid + " " + args + "\n"
}

// 実機の ps 出力の形。Claude Code は実行ファイル名、Codex は node ラッパー + ネイティブ、
// tmux-issue-watcher はインタプリタ (zsh) がスクリプトのパスを引数に取る
func sampleProcesses() []process {
	return parseProcesses(
		psLine("100", "1", "-zsh") +
			psLine("101", "100", "claude -c") +
			psLine("102", "101", "npm exec @upstash/context7-mcp@latest") +
			psLine("200", "1", "-zsh") +
			psLine("201", "200", "node /Users/me/.anyenv/bin/codex resume --last") +
			psLine("202", "201", "/Users/me/.anyenv/lib/node_modules/@openai/codex/vendor/bin/codex resume --last") +
			psLine("300", "1", "-zsh") +
			psLine("301", "300", "/bin/zsh /Users/me/bin/tmux-issue-watcher") +
			psLine("400", "1", "-zsh") +
			psLine("500", "1", "sh /tmp/fake/claude") +
			psLine("600", "1", "vim /tmp/claude"),
	)
}

func samplePanes() []pane {
	out := tmuxLine("work", "$0", "@1", "0", "claude-work", "%1", "100") +
		tmuxLine("work", "$0", "@2", "1", "codex-work", "%2", "200") +
		tmuxLine("ops", "$1", "@3", "0", "watcher", "%3", "300") +
		tmuxLine("ops", "$1", "@4", "1", "shell", "%4", "400") +
		tmuxLine("ops", "$1", "@5", "2", "fake", "%5", "500") +
		tmuxLine("ops", "$1", "@6", "3", "editor", "%6", "600")
	return parsePanes(out)
}

func TestParsePanesReadsPanePID(t *testing.T) {
	panes := samplePanes()
	if len(panes) != 6 {
		t.Fatalf("pane 数 = %d: %+v", len(panes), panes)
	}
	if panes[0].PID != 100 || panes[0].PaneID != "%1" || panes[0].Session != "work" || panes[0].WindowName != "claude-work" {
		t.Errorf("先頭 pane のパースが誤り: %+v", panes[0])
	}
	// pane_pid が数値でない行・欠けた行は捨てる
	broken := parsePanes(tmuxLine("work", "$0", "@1", "0", "x", "%1", "abc") + tmuxLine("work", "$0", "@1"))
	if len(broken) != 0 {
		t.Errorf("壊れた行を取り込んだ: %+v", broken)
	}
}

func TestParseProcessesKeepsArgumentsWithSpaces(t *testing.T) {
	processes := parseProcesses(psLine("  12", "  1", "/bin/zsh /Users/me/bin/tmux-issue-watcher") + "\n" + "garbage line\n")
	if len(processes) != 1 || processes[0].PID != 12 || processes[0].PPID != 1 ||
		processes[0].Args != "/bin/zsh /Users/me/bin/tmux-issue-watcher" {
		t.Fatalf("ps 出力のパースが誤り: %+v", processes)
	}
}

func TestMatchSectionsFindsProcessesAnywhereInPaneTree(t *testing.T) {
	rules := []sectionRule{
		{Title: "Claude", Process: "claude", Agent: true},
		{Title: "Codex", Process: "codex", Agent: true},
		{Title: "Watchers", Process: "tmux-issue-watcher"},
		{Title: "Nothing", Process: "no-such-process"},
	}
	sections := matchSections(rules, samplePanes(), sampleProcesses())

	titles := make([]string, 0, len(sections))
	for _, section := range sections {
		titles = append(titles, section.Title)
	}
	// 一致の無いセクションは見出しごと出さない
	if got := strings.Join(titles, ","); got != "Claude,Codex,Watchers" {
		t.Fatalf("セクションの並び = %q", got)
	}
	// Claude: 子プロセス (claude) の実行ファイル名で一致 (%1)。sh がスクリプトとして
	// 起動した claude も、インタプリタ経由のスクリプト引数として一致する (%5)。
	// vim /tmp/claude (%6) は通常引数なので一致しない
	if got := paneIDs(sections[0]); got != "%1,%5" {
		t.Errorf("Claude セクションの pane = %q", got)
	}
	if sections[0].Items[0].Section != "Claude" || sections[0].Items[0].Session != "work" {
		t.Errorf("セクション名や session が引き継がれていない: %+v", sections[0].Items[0])
	}
	// Codex: node ラッパー (bin/codex) とネイティブ (vendor/bin/codex) のどちらでも basename は codex
	if got := paneIDs(sections[1]); got != "%2" {
		t.Errorf("Codex セクションの pane = %q", got)
	}
	// スクリプト名はインタプリタの引数にしか出ない
	if got := paneIDs(sections[2]); got != "%3" {
		t.Errorf("Watchers セクションの pane = %q", got)
	}
}

func paneIDs(section paneSection) string {
	var ids []string
	for _, item := range section.Items {
		ids = append(ids, item.PaneID)
	}
	return strings.Join(ids, ",")
}

func TestMatchSectionsIgnoresProcessesOutsidePane(t *testing.T) {
	// 同じマシンの別 pane (別 session の tmux を含む) の claude は、pane_pid の子孫でなければ数えない
	rules := []sectionRule{{Title: "Claude", Process: "claude"}}
	panes := parsePanes(tmuxLine("ops", "$1", "@4", "1", "shell", "%4", "400"))
	if sections := matchSections(rules, panes, sampleProcesses()); len(sections) != 0 {
		t.Fatalf("pane 外のプロセスを拾った: %+v", sections)
	}
}

func TestCaptureArgsChainsOneCommandPerPane(t *testing.T) {
	args := captureArgs([]string{"%1", "%2"})
	want := []string{
		"display-message", "-p", "-t", "%1", fieldSeparator + "#{pane_id}", ";", "capture-pane", "-p", "-t", "%1",
		";",
		"display-message", "-p", "-t", "%2", fieldSeparator + "#{pane_id}", ";", "capture-pane", "-p", "-t", "%2",
	}
	if strings.Join(args, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("引数列 = %q", args)
	}
}

func TestParseCapturesSplitsByPaneMarker(t *testing.T) {
	out := fieldSeparator + "%1\nfirst\n\n" + fieldSeparator + "%2\nsecond a\nsecond b\n"
	captures := parseCaptures(out)
	if got := strings.Join(captures["%1"], "|"); got != "first|" {
		t.Errorf("%%1 の画面 = %q", got)
	}
	if got := strings.Join(captures["%2"], "|"); got != "second a|second b|" {
		t.Errorf("%%2 の画面 = %q", got)
	}
	// pane が消えて途中で止まった出力でも、取れた分は返す
	partial := parseCaptures(fieldSeparator + "%1\nonly\n")
	if len(partial) != 1 || len(partial["%1"]) == 0 {
		t.Errorf("途中で止まった出力を捨てた: %+v", partial)
	}

	// tmux 3.4 は marker の区切りを 8 進表記 (\037) で出す
	escaped := parseCaptures(escapedFieldSeparator + "%5\nline a\nline b\n")
	if got := strings.Join(escaped["%5"], "|"); got != "line a|line b|" {
		t.Errorf("可視化表記の marker を認識できない: %q", got)
	}
}

func TestAgentIconDetectsClaudeSpinner(t *testing.T) {
	// Claude Code 2.1 の実行中表示 (実機 capture-pane)。記号はアニメーションで変わる
	for _, spinner := range []string{"✶", "✳", "✻", "·", "✢", "✽"} {
		screen := []string{
			"⏺ 調査します",
			spinner + " Swirling… (4m 56s · ↓ 12.0k tokens)",
			"──────────────────────────────────────",
			"❯ ",
			"──────────────────────────────────────",
			"  lt:6m Fable 5 ctx:18%",
			"  ⏵⏵ auto mode on (shift+tab to cycle)",
			"", "", "",
		}
		if got := agentIcon(screen); got != iconAgentRunning {
			t.Errorf("%s の実行中表示を見落とした: %q", spinner, got)
		}
	}
}

func TestAgentIconIdleWhenPromptIsWaiting(t *testing.T) {
	screen := []string{
		"⏺ 完了しました。✳ という記号 (スピナーと同じ) が会話に残っていても、動詞… (時間) の形でなければ実行中ではない",
		"", "", "", "", "", "", "", "", "",
		"❯ ",
		"──────────────────────────────────────",
		"  lt:6m Fable 5 ctx:18%",
		"  ⏵⏵ auto mode on (shift+tab to cycle) · ← 1 agent",
	}
	if got := agentIcon(screen); got != iconAgentIdle {
		t.Errorf("入力待ちなのに実行中と判定した: %q", got)
	}
	// Codex CLI の入力待ち。"interrupted" は "to interrupt" ではない
	codex := []string{
		"■ Conversation interrupted - tell the model what to do differently.",
		"⚠ MCP startup interrupted. The following servers were not initialized: mobile",
		"› Write tests for @filename",
		"  gpt-5.6-sol high · issue-30 · Context 100% left",
	}
	if got := agentIcon(codex); got != iconAgentIdle {
		t.Errorf("Codex の入力待ちを実行中と判定した: %q", got)
	}
	if got := agentIcon(nil); got != iconAgentIdle {
		t.Errorf("画面が取れなかった pane は入力待ち扱い: %q", got)
	}
}

func TestAgentIconDetectsInterruptHint(t *testing.T) {
	// Codex CLI の実行中表示と、旧 Claude Code の "(esc to interrupt)"
	for _, line := range []string{
		"• Working (12s • esc to interrupt)",
		"▌ Thinking (3s • Esc to interrupt)",
		"· Baking… (esc to interrupt)",
	} {
		screen := []string{"log", line, "› ", "  status"}
		if got := agentIcon(screen); got != iconAgentRunning {
			t.Errorf("%q を実行中と判定しない: %q", line, got)
		}
	}
}

func TestAgentIconOnlyLooksAtTailOfScreen(t *testing.T) {
	// 会話ログの上の方に古い実行中表示が残っていても、末尾の入力欄が静かなら入力待ち
	screen := []string{"✶ Swirling… (10s · ↓ 1.0k tokens)"}
	for i := 0; i < agentStateTailLines; i++ {
		screen = append(screen, "quiet line")
	}
	screen = append(screen, "❯ ")
	if got := agentIcon(screen); got != iconAgentIdle {
		t.Errorf("末尾より上の古い表示で実行中と判定した: %q", got)
	}
}

func TestParseSectionRulesReadsKeyValueLines(t *testing.T) {
	input := `# コメント
section = Watchers:tmux-issue-watcher

section=Builds : xcodebuild
other-key = ignored
section = broken-no-colon
section = :missing-title
not a key value line
`
	rules, warnings := parseSectionRules(bufio.NewScanner(strings.NewReader(input)))
	if len(rules) != 2 {
		t.Fatalf("section 行の数 = %d: %+v", len(rules), rules)
	}
	if rules[0] != (sectionRule{Title: "Watchers", Process: "tmux-issue-watcher"}) {
		t.Errorf("1 行目 = %+v", rules[0])
	}
	if rules[1] != (sectionRule{Title: "Builds", Process: "xcodebuild"}) {
		t.Errorf("空白付きの行 = %+v", rules[1])
	}
	if len(warnings) != 3 {
		t.Errorf("書式の誤りを知らせる行数 = %d: %q", len(warnings), warnings)
	}
	for _, rule := range rules {
		if rule.Agent {
			t.Errorf("設定ファイルのセクションが Agent 扱いになっている: %+v", rule)
		}
	}
}

func TestLoadSectionRulesWithoutFile(t *testing.T) {
	if rules := loadSectionRules(t.TempDir() + "/missing"); rules != nil {
		t.Fatalf("設定ファイルが無いのにセクションが生えた: %+v", rules)
	}
}

func TestProcessNamesStripsLoginShellDash(t *testing.T) {
	// tmux がデフォルトシェルをログインシェルで起動すると argv[0] が -zsh になる。
	// section = Shells:zsh が pane のルートシェルに一致すること
	rules := []sectionRule{{Title: "Shells", Process: "zsh"}}
	panes := parsePanes(tmuxLine("work", "$0", "@1", "0", "shell", "%9", "900"))
	processes := parseProcesses(psLine("900", "1", "-zsh"))
	sections := matchSections(rules, panes, processes)
	if len(sections) != 1 || paneIDs(sections[0]) != "%9" {
		t.Fatalf("ログインシェル (-zsh) が zsh に一致しない: %+v", sections)
	}
}

func TestMatchSectionsCarriesAgentFromRuleNotTitle(t *testing.T) {
	// 組み込み Claude (Agent) と同名タイトルの汎用セクション (Agent でない) を並べても、
	// Agent 属性は各 rule から引き継がれ、タイトルの一致で汎用側まで Agent 扱いにしない
	rules := []sectionRule{
		{Title: "Claude", Process: "claude", Agent: true},
		{Title: "Claude", Process: "my-wrapper", Agent: false},
	}
	panes := parsePanes(
		tmuxLine("work", "$0", "@1", "0", "real", "%1", "100") +
			tmuxLine("work", "$0", "@2", "1", "wrapped", "%2", "700"),
	)
	processes := parseProcesses(psLine("100", "1", "claude") + psLine("700", "1", "/usr/bin/my-wrapper"))
	sections := matchSections(rules, panes, processes)
	if len(sections) != 2 {
		t.Fatalf("同名タイトルのセクションが畳まれた: %+v", sections)
	}
	if !sections[0].Agent || paneIDs(sections[0]) != "%1" {
		t.Errorf("組み込み Claude が Agent でない: %+v", sections[0])
	}
	if sections[1].Agent || paneIDs(sections[1]) != "%2" {
		t.Errorf("同名の汎用セクションが Agent 扱いになっている: %+v", sections[1])
	}
}

func TestCommandNamesLimitsToExecutableAndScript(t *testing.T) {
	cases := []struct {
		args string
		want string
	}{
		// 実行ファイルの basename
		{"claude -c", "claude"},
		{"/usr/local/bin/claude resume", "claude"},
		// ログインシェルの argv[0] の先頭 - を落とす
		{"-zsh", "zsh"},
		// インタプリタ + スクリプト引数 (先頭の非オプション引数) の basename
		{"node /Users/me/.anyenv/bin/codex resume --last", "node,codex"},
		{"/bin/zsh /Users/me/bin/tmux-issue-watcher", "zsh,tmux-issue-watcher"},
		{"python3 -u /opt/app/worker.py", "python3,worker.py"},
		// インタプリタでない実行ファイルの引数は名前に数えない (誤一致の防止)
		{"vim /tmp/claude", "vim"},
		{"tail -f /var/log/codex", "tail"},
		{"", ""},
	}
	for _, c := range cases {
		if got := strings.Join(commandNames(c.args), ","); got != c.want {
			t.Errorf("commandNames(%q) = %q, want %q", c.args, got, c.want)
		}
	}
}

func TestAgentIconIgnoresConversationInterruptText(t *testing.T) {
	// Claude/Codex が会話本文で "esc to interrupt" の語を説明として書き、その行が末尾に
	// 残ったまま入力待ちになっても、括弧のステータス形式でなければ実行中と判定しない
	idle := []string{
		"To stop me, press Esc to interrupt the current turn.",
		"❯ ",
	}
	if got := agentIcon(idle); got != iconAgentIdle {
		t.Errorf("会話本文の to interrupt を実行中と判定した: %q", got)
	}
	// 括弧内のステータスヒントは実行中
	running := []string{"• Working (12s • esc to interrupt)", "› "}
	if got := agentIcon(running); got != iconAgentRunning {
		t.Errorf("括弧のステータスヒントを実行中と判定しない: %q", got)
	}
}
