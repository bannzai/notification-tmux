package main

import (
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

// 「特定のプロセスが動いている pane」を並べるセクション。通知 (@claude-waiting) が
// hook 頼みなのに対し、こちらは pane のプロセス木と画面内容から状態を拾うため、
// hook を仕込んでいない Codex CLI や hook が落ちた pane も一覧に出る
type paneSection struct {
	Title string
	// このセクションが Claude Code / Codex CLI か。画面から 実行中/入力待ち を判定する対象。
	// タイトルではなく生成元の sectionRule から引き継ぐ: 設定ファイルで組み込みと同名タイトルの
	// 汎用セクション (section = Claude:my-wrapper) を足しても、そちらを Agent 扱いにしないため
	Agent bool
	Items []Notification
}

// 内側 tmux の全 pane。pane のルートプロセス (pane_pid) からプロセス木を辿る
type pane struct {
	Notification
	PID int
}

type process struct {
	PID  int
	PPID int
	// ps の args 列 (実行ファイルのパス + 引数)
	Args string
}

const (
	paneFormat = "#{session_name}" + fieldSeparator + "#{session_id}" + fieldSeparator +
		"#{window_id}" + fieldSeparator + "#{window_index}" + fieldSeparator +
		"#{window_name}" + fieldSeparator + "#{pane_id}" + fieldSeparator + "#{pane_pid}"
	paneFieldCount = 7
	// 実行中 / 入力待ち の表示。通知の hook が付けるアイコンと混ざらない絵柄にする
	iconAgentRunning = "🏃"
	iconAgentIdle    = "💤"
	iconProcess      = "▶"
	// 状態判定に見る pane 末尾の行数。Claude Code / Codex CLI の実行中表示は入力欄の
	// 直上にあり、入力欄とステータス行を含めても末尾 8 行に収まる。それより上の
	// 会話ログに同じ語が残っていても (ツール出力の引用など) 誤判定しないための上限
	agentStateTailLines = 8
)

// Claude Code の実行中表示: スピナー記号 + 動詞… (経過時間 …)。例: "✶ Swirling… (4m 56s · ↓ 12.0k tokens)"。
// 記号はアニメーションで入れ替わるため候補をまとめて受ける
var claudeSpinnerLine = regexp.MustCompile(`^\s*[·✢✳✶✻✽*]\s+\S+…\s+\(`)

// Codex CLI の実行中表示 ("• Working (12s • esc to interrupt)") と、旧 Claude Code の
// "(esc to interrupt)"。"interrupted" (中断済みの案内) には一致させない
var interruptHintLine = regexp.MustCompile(`(?i)\bto interrupt\b`)

func fetchSections(cfg Config) []paneSection {
	if len(cfg.Sections) == 0 {
		return nil
	}
	out, err := output(cfg.innerCommand("list-panes", "-a", "-F", paneFormat))
	if err != nil {
		return nil
	}
	panes := parsePanes(out)
	psOut, err := listProcesses()
	if err != nil {
		return nil
	}
	sections := matchSections(cfg.Sections, panes, parseProcesses(psOut))
	applyAgentStates(cfg, sections)
	return sections
}

func parsePanes(out string) []pane {
	var panes []pane
	for _, line := range strings.Split(out, "\n") {
		fields := splitFields(line)
		if len(fields) != paneFieldCount || fields[5] == "" {
			continue
		}
		pid, err := strconv.Atoi(fields[6])
		if err != nil {
			continue
		}
		panes = append(panes, pane{
			Notification: Notification{
				Session:     fields[0],
				SessionID:   fields[1],
				WindowID:    fields[2],
				WindowIndex: fields[3],
				WindowName:  fields[4],
				PaneID:      fields[5],
			},
			PID: pid,
		})
	}
	return panes
}

// 全プロセスを 1 回で取る。-e は macOS / Linux の両方で全プロセス、-ww は args を
// 端末幅で切らない指定 (macOS の ps は幅で切る)
func listProcesses() (string, error) {
	out, err := exec.Command("ps", "-e", "-ww", "-o", "pid=,ppid=,args=").Output()
	return string(out), err
}

func parseProcesses(out string) []process {
	var processes []process
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}
		pid, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		ppid, err := strconv.Atoi(fields[1])
		if err != nil {
			continue
		}
		processes = append(processes, process{PID: pid, PPID: ppid, Args: strings.Join(fields[2:], " ")})
	}
	return processes
}

// pane ごとに、ルートプロセスとその子孫が持つプロセス名の集合を作り、各セクションの
// プロセス名と突き合わせる。pane の並びは list-panes の順 (= session 順) を保つ
func matchSections(rules []sectionRule, panes []pane, processes []process) []paneSection {
	children := map[int][]process{}
	byPID := map[int]process{}
	for _, p := range processes {
		children[p.PPID] = append(children[p.PPID], p)
		byPID[p.PID] = p
	}
	sections := make([]paneSection, len(rules))
	for i, rule := range rules {
		sections[i].Title = rule.Title
		sections[i].Agent = rule.Agent
	}
	for _, pane := range panes {
		names := processNames(pane.PID, byPID, children)
		for i, rule := range rules {
			if !names[rule.Process] {
				continue
			}
			item := pane.Notification
			item.Section = rule.Title
			item.Icon = iconProcess
			sections[i].Items = append(sections[i].Items, item)
		}
	}
	var populated []paneSection
	for _, section := range sections {
		if len(section.Items) > 0 {
			populated = append(populated, section)
		}
	}
	return populated
}

// root とその子孫のプロセスが名乗る名前。Claude Code は実行ファイル名 (claude) で分かるが、
// tmux-issue-watcher のようなスクリプトは "/bin/zsh /path/to/tmux-issue-watcher" と
// インタプリタが先頭に来るため、args の各語の basename をすべて名前として数える
func processNames(root int, byPID map[int]process, children map[int][]process) map[string]bool {
	names := map[string]bool{}
	queue := []int{root}
	visited := map[int]bool{}
	for len(queue) > 0 {
		pid := queue[0]
		queue = queue[1:]
		if visited[pid] {
			continue
		}
		visited[pid] = true
		if p, ok := byPID[pid]; ok {
			for _, word := range strings.Fields(p.Args) {
				// tmux がデフォルトシェルをログインシェルで起動すると argv[0] が -zsh / -bash に
				// なる。実行ファイルの basename で一致させたいので先頭のログインシェル用 - を落とす
				names[strings.TrimPrefix(filepath.Base(word), "-")] = true
			}
		}
		for _, child := range children[pid] {
			queue = append(queue, child.PID)
		}
	}
	return names
}

// Agent セクションの pane の画面を 1 回の tmux 呼び出しでまとめて取り、
// 実行中 / 入力待ち のアイコンを付ける
func applyAgentStates(cfg Config, sections []paneSection) {
	var paneIDs []string
	seen := map[string]bool{}
	for _, section := range sections {
		if !section.Agent {
			continue
		}
		for _, item := range section.Items {
			if !seen[item.PaneID] {
				seen[item.PaneID] = true
				paneIDs = append(paneIDs, item.PaneID)
			}
		}
	}
	if len(paneIDs) == 0 {
		return
	}
	// pane が消えていると tmux は途中で止まる (以降の pane は取れない)。取れなかった
	// pane は入力待ち扱いにし、消えた pane 自体は window の close イベントで次の再取得が消す
	out, _ := output(cfg.innerCommand(captureArgs(paneIDs)...))
	captures := parseCaptures(out)
	for _, section := range sections {
		if !section.Agent {
			continue
		}
		for i := range section.Items {
			section.Items[i].Icon = agentIcon(captures[section.Items[i].PaneID])
		}
	}
}

// capture-pane は target を 1 つしか取れないため、pane ごとに区切り行 (display-message)
// と capture-pane を ; で連ねて 1 プロセスで済ませる。区切りは画面の行に現れない
// fieldSeparator で始める。
// pane ID は #{pane_id} で出す: display-message の書式は strftime も通すため、リテラルの
// "%5" を渡すと % 始まりの並びが日時書式として食われて marker が壊れる (実測)
func captureArgs(paneIDs []string) []string {
	var args []string
	for i, paneID := range paneIDs {
		if i > 0 {
			args = append(args, ";")
		}
		args = append(args, "display-message", "-p", "-t", paneID, fieldSeparator+"#{pane_id}",
			";", "capture-pane", "-p", "-t", paneID)
	}
	return args
}

func parseCaptures(out string) map[string][]string {
	captures := map[string][]string{}
	current := ""
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, fieldSeparator) {
			current = strings.TrimPrefix(line, fieldSeparator)
			captures[current] = nil
			continue
		}
		if current != "" {
			captures[current] = append(captures[current], line)
		}
	}
	return captures
}

func agentIcon(screen []string) string {
	if agentRunning(screen) {
		return iconAgentRunning
	}
	return iconAgentIdle
}

// 画面末尾の空でない行に実行中の表示があるか
func agentRunning(screen []string) bool {
	tail := previewLines(strings.Join(screen, "\n"), agentStateTailLines)
	for _, line := range tail {
		if claudeSpinnerLine.MatchString(line) || interruptHintLine.MatchString(line) {
			return true
		}
	}
	return false
}
