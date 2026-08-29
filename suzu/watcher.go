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
	// ローカルは doorbell hook のままで、この購読は使わない
	waitingSubscription = "suzu::#{S:#{W:#{P:#{pane_id}=#{" + waitingOption + "};}}}"
)

// 再取得の結果 (notificationsMsg / sectionsMsg / connectionMsg) の届け先。サイドバーでは
// bubbletea の Program、serve では HTTP/SSE の server が受ける
type msgSink interface {
	Send(msg tea.Msg)
}

// 内側 tmux の変化を push で受け取り、デバウンスして通知一覧とセクションの再取得を sink へ送る。
// tmux の構造と @claude-waiting の変化は push だけで拾う。時間駆動は pane 内のプロセスと
// 画面内容の見直し (ScrapeInterval) だけで、これは tmux がイベントを出さない変化のため。
// リモート host (cfg.RemoteHosts) は host ごとに remoteSource として独立に監視する
type watcher struct {
	cfg  Config
	sink msgSink
	// 通知の再取得トリガ (速い)。セクションの再取得 (sectionTriggers) と分けるのは、
	// 遅い ps を伴うセクション取得が通知の反映を巻き添えで遅らせないため
	triggers chan struct{}
	// セクションの再取得トリガ (ps を伴い遅い)
	sectionTriggers chan struct{}
}

func newWatcher(cfg Config, sink msgSink) *watcher {
	return &watcher{
		cfg:             cfg,
		sink:            sink,
		triggers:        make(chan struct{}, 1),
		sectionTriggers: make(chan struct{}, 1),
	}
}

func (w *watcher) run() {
	// リモートはトリガもデバウンスも host ごとに持ち、落ちている host の ssh 待ちが
	// ローカルの再取得を遅らせないようにする
	for _, host := range w.cfg.RemoteHosts {
		remote := newRemoteSource(w.cfg, w.sink, host)
		go remote.watchControlMode()
		go debounce(remote.triggers, w.sink, remote.fetch)
	}
	go w.watchDoorbell()
	go w.watchControlMode()
	if w.cfg.ScrapeInterval > 0 {
		go w.tickScrape()
	}
	// セクションの再取得は専用 goroutine に置き、遅い ps が通知の debounce を止めないようにする
	go debounce(w.sectionTriggers, w.sink, func() tea.Msg { return fetchSectionsMsg(w.cfg) })
	debounce(w.triggers, w.sink, func() tea.Msg { return fetchNotifications(w.cfg) })
}

// プロセスの起動・終了 (pane-title-changed hook が拾えない、タイトルを変えないシェル) と
// Claude Code / Codex CLI の 実行中 ↔ 入力待ち の切り替わりは tmux のイベントにならないため、
// 低頻度の再取得だけで追う。1 回の再取得は list-panes・ps・まとめた capture-pane の
// 3 プロセスで済み、UI の描画は差分だけが更新される
func (w *watcher) tickScrape() {
	for {
		time.Sleep(w.cfg.ScrapeInterval)
		send(w.sectionTriggers)
	}
}

// 取りこぼしてもデバウンス後に必ず 1 回再取得されるため、詰まっている時は捨ててよい。
// 通知とセクションの両方を促す
func (w *watcher) trigger() {
	send(w.triggers)
	send(w.sectionTriggers)
}

func send(ch chan struct{}) {
	select {
	case ch <- struct{}{}:
	default:
	}
}

// triggers が落ち着いてから fetch を 1 回実行し、結果を sink へ送り続ける
func debounce(triggers <-chan struct{}, sink msgSink, fetch func() tea.Msg) {
	timer := time.NewTimer(debounceInterval)
	if !timer.Stop() {
		<-timer.C
	}
	armed := false
	for {
		select {
		case <-triggers:
			if armed && !timer.Stop() {
				<-timer.C
			}
			timer.Reset(debounceInterval)
			armed = true
		case <-timer.C:
			armed = false
			sink.Send(fetch())
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
		readControlMode(w.cfg.innerCommand("-C", "attach", "-f", "no-output,ignore-size"), "", "", w.sink, w.trigger)
		w.sink.Send(connectionMsg{connected: false})
		time.Sleep(reconnectDelay)
	}
}

// control client を起動し、繋がったら connectionMsg を送り、終わるまでツリーイベントを
// onRefresh へ流す。終わった理由 (cmd.Wait の結果) を返す。
// subscription が空でなければ接続後に購読を張る (リモートの @claude-waiting 用)。
// 呼び出し側は attach に -f ignore-size を付ける: この control client は監視専用で画面を持たず、
// 付けないと初期寸法が session のサイズ計算に参加し、実端末の client のレイアウトを縮め得る
// (documents/adr/0009)
func readControlMode(cmd *exec.Cmd, host string, subscription string, sink msgSink, onRefresh func()) error {
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
	if subscription != "" {
		stdinW.WriteString("refresh-client -B " + shellQuote(subscription) + "\n")
	}
	sink.Send(connectionMsg{host: host, connected: true})
	// 切断中に起きた変化はイベントとして再送されないため、接続が成立した時点で
	// 一覧を取り直す。初回 fetch が内側 server の起動と競合して失敗した場合もここで埋まる
	onRefresh()

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64*1024), controlLineLimit)
	for scanner.Scan() {
		if isRefreshEvent(scanner.Text()) {
			onRefresh()
		}
	}
	return cmd.Wait()
}

// 1 つのリモート host の tmux server を監視する単位 (remote.go)。
// doorbell hook はリモートに無いため、@claude-waiting の変化は control client の購読で受ける
type remoteSource struct {
	cfg      Config
	sink     msgSink
	host     string
	triggers chan struct{}
}

func newRemoteSource(cfg Config, sink msgSink, host string) *remoteSource {
	return &remoteSource{cfg: cfg, sink: sink, host: host, triggers: make(chan struct{}, 1)}
}

func (s *remoteSource) fetch() tea.Msg {
	return fetchRemoteNotifications(s.cfg, s.host)
}

// 切断されたら remoteReconnectDelay 待って張り直す
func (s *remoteSource) watchControlMode() {
	for {
		err := readControlMode(s.cfg.remoteCommand(s.host, "-C", "attach", "-f", "no-output,ignore-size"),
			s.host, waitingSubscription, s.sink, func() { send(s.triggers) })
		// ssh 自体が失敗した時だけ「未接続」にする。リモートに tmux server が無いだけの時は
		// 通知が無いのと同じで、host が落ちているとは言わない
		s.sink.Send(connectionMsg{host: s.host, connected: false, unreachable: isSSHFailure(err)})
		time.Sleep(remoteReconnectDelay)
	}
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
