package main

import (
	"bufio"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/fsnotify/fsnotify"
)

const (
	debounceInterval = 100 * time.Millisecond
	reconnectDelay   = time.Second
	// リモートは ssh の接続が絡むため、落ちている host への再接続の嵐を避けて間隔を空ける
	remoteReconnectDelay = 5 * time.Second
	// %output は -f no-output で止めているが、想定外に長い行で読み取りが止まらないよう余裕を持たせる
	controlLineLimit = 1 << 20
	// リモートの @claude-waiting の変化を control client で受ける購読 (refresh-client -B)。
	// 購読の評価対象は attach 中 session に限られるが、format の S: ループは server の
	// 全 session を回るため、1 本の購読で全 session の pane / window option を追える
	// (tmux 3.6a で実測)。値が変わるたびに %subscription-changed が届く。
	// 評価は tmux 内部の 1 秒タイマーで行われるため、反映は最大約 1 秒遅れる。
	// ローカルは Phase 2 の doorbell hook のままで、この購読は使わない
	waitingSubscription = "suzu::#{S:#{W:#{P:#{pane_id}=#{" + waitingOption + "};}}}"
)

// 内側 tmux とリモート host の変化を push で受け取り、host ごとにデバウンスして
// 通知一覧の再取得を UI へ送る。定期ポーリングは行わない
type watcher struct {
	cfg     Config
	program *tea.Program
}

func newWatcher(cfg Config, program *tea.Program) *watcher {
	return &watcher{cfg: cfg, program: program}
}

// host ごとに独立して動かす。落ちているリモート host の ssh 待ちがローカルの再取得を
// 遅らせないようにするため、トリガもデバウンスも host ごとに持つ
func (w *watcher) run() {
	for _, host := range w.cfg.RemoteHosts {
		remote := newSource(w.cfg, w.program, host)
		go remote.watchControlMode()
		go remote.debounce()
	}
	local := newSource(w.cfg, w.program, "")
	go local.watchDoorbell()
	go local.watchControlMode()
	local.debounce()
}

// 1 つの tmux server (ローカル = 内側 tmux、またはリモート host) を監視する単位
type source struct {
	cfg     Config
	program *tea.Program
	// "" はローカル (内側 tmux)
	host     string
	triggers chan struct{}
}

func newSource(cfg Config, program *tea.Program, host string) *source {
	return &source{cfg: cfg, program: program, host: host, triggers: make(chan struct{}, 1)}
}

// 取りこぼしてもデバウンス後に必ず 1 回再取得されるため、詰まっている時は捨ててよい
func (s *source) trigger() {
	select {
	case s.triggers <- struct{}{}:
	default:
	}
}

func (s *source) debounce() {
	timer := time.NewTimer(debounceInterval)
	if !timer.Stop() {
		<-timer.C
	}
	armed := false
	for {
		select {
		case <-s.triggers:
			if armed && !timer.Stop() {
				<-timer.C
			}
			timer.Reset(debounceInterval)
			armed = true
		case <-timer.C:
			armed = false
			s.program.Send(s.fetch())
		}
	}
}

func (s *source) fetch() notificationsMsg {
	if s.host == "" {
		return fetchNotifications(s.cfg)
	}
	return fetchRemoteNotifications(s.cfg, s.host)
}

// doorbell ファイルは初回起動時に存在しないことがあるため、親ディレクトリを watch する
func (s *source) watchDoorbell() {
	dir := filepath.Dir(s.cfg.DoorbellFile)
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
	base := filepath.Base(s.cfg.DoorbellFile)
	for {
		select {
		case event, ok := <-fsw.Events:
			if !ok {
				return
			}
			if filepath.Base(event.Name) == base {
				s.trigger()
			}
		case _, ok := <-fsw.Errors:
			if !ok {
				return
			}
		}
	}
}

// session/window ツリーの変化は control mode client なら非 attach session の分も届く。
// 切断されたら間隔を置いて張り直す
func (s *source) watchControlMode() {
	for {
		err := s.readControlMode()
		// ssh 自体が失敗した時だけ「未接続」にする。リモートに tmux server が無いだけの時は
		// 通知が無いのと同じで、host が落ちているとは言わない
		s.program.Send(connectionMsg{host: s.host, connected: false, unreachable: isSSHFailure(err)})
		if s.host == "" {
			time.Sleep(reconnectDelay)
		} else {
			time.Sleep(remoteReconnectDelay)
		}
	}
}

func (s *source) controlModeCommand() *exec.Cmd {
	// ignore-size: この control client は監視専用で画面を持たない。付けないと初期寸法が
	// session のサイズ計算に参加し、実端末の client のレイアウトを縮め得る
	// (documents/adr/0009)
	args := []string{"-C", "attach", "-f", "no-output,ignore-size"}
	if s.host == "" {
		return s.cfg.innerCommand(args...)
	}
	return s.cfg.remoteCommand(s.host, args...)
}

// control client が終わるまで読み続け、終わった理由 (cmd.Wait の結果) を返す
func (s *source) readControlMode() error {
	cmd := s.controlModeCommand()
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	// stdin が即 EOF になると control mode client が終了するため、開いたままの pipe を渡す
	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		return err
	}
	defer stdinW.Close()
	cmd.Stdin = stdinR
	if err := cmd.Start(); err != nil {
		stdinR.Close()
		return err
	}
	stdinR.Close()
	if s.host != "" {
		// リモートには doorbell hook が無いため、@claude-waiting の変化は購読で受ける
		stdinW.WriteString("refresh-client -B " + shellQuote(waitingSubscription) + "\n")
	}
	s.program.Send(connectionMsg{host: s.host, connected: true})
	// 切断中に起きた変化はイベントとして再送されないため、接続が成立した時点で
	// 一覧を取り直す。初回 fetch が内側 server の起動と競合して失敗した場合もここで埋まる
	s.trigger()

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), controlLineLimit)
	for scanner.Scan() {
		if isRefreshEvent(scanner.Text()) {
			s.trigger()
		}
	}
	return cmd.Wait()
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
	"%subscription-changed":    true,
}

func isRefreshEvent(line string) bool {
	head, _, _ := strings.Cut(line, " ")
	return refreshEvents[head]
}
