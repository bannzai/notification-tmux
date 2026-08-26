package main

import (
	"bufio"
	"os"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/fsnotify/fsnotify"
)

const (
	debounceInterval = 100 * time.Millisecond
	reconnectDelay   = time.Second
	// %output は -f no-output で止めているが、想定外に長い行で読み取りが止まらないよう余裕を持たせる
	controlLineLimit = 1 << 20
)

// 内側 tmux の変化を push で受け取り、デバウンスして通知一覧の再取得を UI へ送る。
// 定期ポーリングは行わない
type watcher struct {
	cfg      Config
	program  *tea.Program
	triggers chan struct{}
}

func newWatcher(cfg Config, program *tea.Program) *watcher {
	return &watcher{cfg: cfg, program: program, triggers: make(chan struct{}, 1)}
}

func (w *watcher) run() {
	go w.watchDoorbell()
	go w.watchControlMode()
	w.debounce()
}

// 取りこぼしてもデバウンス後に必ず 1 回再取得されるため、詰まっている時は捨ててよい
func (w *watcher) trigger() {
	select {
	case w.triggers <- struct{}{}:
	default:
	}
}

func (w *watcher) debounce() {
	timer := time.NewTimer(debounceInterval)
	if !timer.Stop() {
		<-timer.C
	}
	armed := false
	for {
		select {
		case <-w.triggers:
			if armed && !timer.Stop() {
				<-timer.C
			}
			timer.Reset(debounceInterval)
			armed = true
		case <-timer.C:
			armed = false
			w.program.Send(fetchNotifications(w.cfg))
		}
	}
}

// doorbell ファイルは初回起動時に存在しないことがあるため、親ディレクトリを watch する
func (w *watcher) watchDoorbell() {
	dir := filepath.Dir(w.cfg.DoorbellFile)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	fsw, err := fsnotify.NewWatcher()
	if err != nil {
		return
	}
	defer fsw.Close()
	if err := fsw.Add(dir); err != nil {
		return
	}
	base := filepath.Base(w.cfg.DoorbellFile)
	for {
		select {
		case event, ok := <-fsw.Events:
			if !ok {
				return
			}
			if filepath.Base(event.Name) == base {
				w.trigger()
			}
		case _, ok := <-fsw.Errors:
			if !ok {
				return
			}
		}
	}
}

// session/window ツリーの変化は control mode client なら非 attach session の分も届く。
// 切断されたら 1 秒待って張り直す
func (w *watcher) watchControlMode() {
	for {
		w.readControlMode()
		w.program.Send(connectionMsg{connected: false})
		time.Sleep(reconnectDelay)
	}
}

func (w *watcher) readControlMode() {
	// ignore-size: この control client は監視専用で画面を持たない。付けないと初期寸法が
	// session のサイズ計算に参加し、実端末の client のレイアウトを縮め得る
	// (documents/adr/0009)
	cmd := w.cfg.innerCommand("-C", "attach", "-f", "no-output,ignore-size")
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	// stdin が即 EOF になると control mode client が終了するため、開いたままの pipe を渡す
	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		return
	}
	defer stdinW.Close()
	cmd.Stdin = stdinR
	if err := cmd.Start(); err != nil {
		stdinR.Close()
		return
	}
	stdinR.Close()
	w.program.Send(connectionMsg{connected: true})
	// 切断中に起きた変化はイベントとして再送されないため、接続が成立した時点で
	// 一覧を取り直す。初回 fetch が内側 server の起動と競合して失敗した場合もここで埋まる
	w.trigger()

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), controlLineLimit)
	for scanner.Scan() {
		if isRefreshEvent(scanner.Text()) {
			w.trigger()
		}
	}
	cmd.Wait()
}

// 通知一覧を取り直す必要がある control mode の通知。
// %begin/%end/%output のような無関係な行と区別する
var refreshEvents = map[string]bool{
	"%sessions-changed":        true,
	"%session-renamed":         true,
	"%session-window-changed":  true,
	"%window-add":              true,
	"%window-close":            true,
	"%window-renamed":          true,
	"%layout-change":           true,
	"%window-pane-changed":     true,
	"%unlinked-window-add":     true,
	"%unlinked-window-close":   true,
	"%unlinked-window-renamed": true,
}

func isRefreshEvent(line string) bool {
	head, _, _ := strings.Cut(line, " ")
	return refreshEvents[head]
}
