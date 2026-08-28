package main

import (
	"crypto/rand"
	"crypto/subtle"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// serve: 通知データ層を daemon として切り出し、iPhone のブラウザから
// 「通知一覧 + 専用ボタン」で内側 tmux を操作できるようにする (issue #72)。
//
// 経路:
//
//	内側 tmux ──(doorbell / control mode の push)──▶ watcher ──▶ server ──(SSE)──▶ iPhone
//	iPhone ──(POST /api/actions)──▶ server ──▶ tmux select-window / switch-client / send-keys
//
// 認証と誤操作対策 (send-keys は任意の入力を流せるため、最初から絞る):
//
//   - 全エンドポイントを Bearer トークンで守る。トークンは SUZU_SERVE_TOKEN か起動時に生成し、
//     初回だけ /?token=<token> で受け取って cookie (SameSite=Strict) に保存する。
//     状態を変える POST は cookie では通さず Authorization ヘッダだけを受ける。
//     カスタムヘッダは別 origin のページから preflight なしに付けられないため、
//     LAN 内の別サイトから cookie 頼みで POST を撃ち込まれる経路を塞ぐ
//   - 送れるキーは allowedKeys の固定ホワイトリストだけ。任意文字列は受けない
//   - 対象 pane は「今の通知一覧に載っている pane」だけ。通知の無い pane へは送れない
//   - 到達性は Tailscale 等の閉じた網を前提にし、既定の bind は localhost。公開サーバーは立てない
//
// 同じ push 基盤 (watcher) をサイドバーと共有するため、serve も定期ポーリングは行わない。

//go:embed web/index.html
var webIndex []byte

const (
	// 既定は localhost 限定 (LAN に晒さない)。port は IANA 登録済みサービスと、よく使う
	// 開発サーバの既定 (3000 / 8000 / 8080 等) を避けた値で、衝突時は SUZU_SERVE_ADDR で変える
	defaultServeAddr = "127.0.0.1:7788"
	tokenCookieName  = "suzu_token"
	// cookie の寿命。iPhone で /?token= を開き直す手間を減らすため長めに取り、
	// トークンを変えた時 (serve の再起動) は cookie が残っていても 401 で弾かれる
	tokenCookieMaxAge = 365 * 24 * time.Hour
	// 生成トークンの長さ。128 bit あれば総当たりは現実的でなく、URL に載せても短い
	tokenBytes = 16
	// SSE の接続維持コメントの間隔。iOS Safari は無通信の接続を切ることがあるため、
	// 一般的なプロキシ・OS の idle timeout (30〜60 秒) より短く取る
	sseKeepAlive = 25 * time.Second
	// 通知ごとにボタンから見えるプレビュー行数。サイドバーと同じ
	servePreviewLines = previewLineCount
	// action の JSON は 3 フィールドの短い body。それを大きく超える入力は受け付けない
	maxActionBody = 4 << 10
)

// ボタンで送れるキー (tmux send-keys のキー名)。Claude Code の確認 (Enter で決定・
// 数字で選択肢・Esc で拒否) と Codex CLI の承認 (y/n) を賄う最小集合
var allowedKeys = []string{"Enter", "Escape", "y", "n", "1", "2", "3"}

func allowedKey(key string) bool {
	return slices.Contains(allowedKeys, key)
}

// ブラウザへ渡す通知 1 件。Notification に pane のプレビューを添えたもの
type notificationView struct {
	Notification
	Preview []string `json:"preview"`
}

// GET /api/notifications と SSE で配る全体像
type stateView struct {
	Connected bool               `json:"connected"`
	Keys      []string           `json:"keys"`
	Items     []notificationView `json:"items"`
	Error     string             `json:"error,omitempty"`
}

// POST /api/actions の body (ボタン 1 回分)
type actionRequest struct {
	// jump | send-keys
	Action string `json:"action"`
	// 対象の通知元 pane。今の通知一覧に載っているものだけ受ける
	PaneID string `json:"pane_id"`
	// send-keys の時だけ。allowedKeys のいずれか
	Key string `json:"key"`
}

// serve の HTTP handler と、watcher から受けた最新状態・SSE 購読者
type server struct {
	cfg   Config
	token string

	mu sync.Mutex
	// action の対象検査に使う、最新の通知一覧そのもの
	items []Notification
	// ブラウザへ配る最新のスナップショット
	state stateView
	// SSE 接続ごとの配信 channel (容量 1・最新だけ残す)
	subscribers map[chan []byte]struct{}

	// tmux を叩く処理の差し替え点 (テストでは代役を入れる)
	preview func(paneID string) []string
	jump    func(n Notification) error
	sendKey func(paneID string, key string) error
}

// tmux を実際に叩く差し替え点を持った server を作る
func newServer(cfg Config, token string) *server {
	return &server{
		cfg:         cfg,
		token:       token,
		state:       stateView{Keys: allowedKeys, Items: []notificationView{}},
		subscribers: map[chan []byte]struct{}{},
		preview: func(paneID string) []string {
			return fetchPreview(cfg, paneID, servePreviewLines)
		},
		jump: func(n Notification) error { return jumpAnyClient(cfg, n) },
		sendKey: func(paneID string, key string) error {
			return sendKey(cfg, paneID, key)
		},
	}
}

// suzu serve: 待ち受けを開き、watcher を起動して HTTP を提供し続ける
func cmdServe(cfg Config) error {
	token := cfg.ServeToken
	if token == "" {
		var err error
		if token, err = generateToken(); err != nil {
			return fmt.Errorf("トークンの生成に失敗: %w", err)
		}
	}
	listener, err := net.Listen("tcp", cfg.ServeAddr)
	if err != nil {
		return fmt.Errorf("待ち受けに失敗 (%s): %w", cfg.ServeAddr, err)
	}
	s := newServer(cfg, token)
	// watcher の接続時 trigger を待たずに一覧を出しておく (初回アクセスを空で返さない)
	s.Send(fetchNotifications(cfg))
	go newWatcher(cfg, s).run()

	fmt.Printf("suzu serve: http://%s/?token=%s\n", listener.Addr(), token)
	if host, _, splitErr := net.SplitHostPort(listener.Addr().String()); splitErr == nil && isUnspecifiedHost(host) {
		fmt.Fprintln(os.Stderr, "全インターフェースで待ち受けています。iPhone からは Tailscale の IP (tailscale ip -4) で開いてください")
	}
	return http.Serve(listener, s.handler())
}

// 0.0.0.0 / :: のような全インターフェース待ち受けか
func isUnspecifiedHost(host string) bool {
	ip := net.ParseIP(host)
	return ip != nil && ip.IsUnspecified()
}

// 起動ごとの認証トークン (hex)
func generateToken() (string, error) {
	buf := make([]byte, tokenBytes)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return hex.EncodeToString(buf), nil
}

// ルーティング。画面 (/) 以外はすべてトークン必須
func (s *server) handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleIndex)
	mux.HandleFunc("/manifest.webmanifest", s.requireToken(s.handleManifest))
	mux.HandleFunc("/api/notifications", s.requireToken(s.handleNotifications))
	mux.HandleFunc("/api/events", s.requireToken(s.handleEvents))
	mux.HandleFunc("/api/actions", s.requireToken(s.handleActions))
	return mux
}

// watcher からの再取得結果を受け、ブラウザへ配る形に整えて購読者へ流す
func (s *server) Send(msg tea.Msg) {
	switch msg := msg.(type) {
	case notificationsMsg:
		views := make([]notificationView, 0, len(msg.items))
		for _, item := range msg.items {
			views = append(views, notificationView{
				Notification: item,
				Preview:      nonNil(s.preview(item.PaneID)),
			})
		}
		s.mu.Lock()
		s.items = msg.items
		s.state.Items = views
		s.state.Error = ""
		if msg.err != nil {
			s.state.Error = msg.err.Error()
		}
		s.mu.Unlock()
	case connectionMsg:
		s.mu.Lock()
		s.state.Connected = msg.connected
		s.mu.Unlock()
	default:
		return
	}
	s.broadcast()
}

// JSON で null ではなく [] にする。ブラウザ側の分岐を減らす
func nonNil(lines []string) []string {
	if lines == nil {
		return []string{}
	}
	return lines
}

// 最新状態の JSON (GET /api/notifications と SSE の data)
func (s *server) snapshot() []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	data, err := json.Marshal(s.state)
	if err != nil {
		return []byte("{}")
	}
	return data
}

// 今の通知一覧から pane を引く。無ければ action の対象にしない
func (s *server) find(paneID string) (Notification, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, item := range s.items {
		if item.PaneID == paneID {
			return item, true
		}
	}
	return Notification{}, false
}

// SSE 接続 1 本分の配信 channel を登録する
func (s *server) subscribe() chan []byte {
	ch := make(chan []byte, 1)
	s.mu.Lock()
	s.subscribers[ch] = struct{}{}
	s.mu.Unlock()
	return ch
}

// SSE 接続が切れた channel を外す
func (s *server) unsubscribe(ch chan []byte) {
	s.mu.Lock()
	delete(s.subscribers, ch)
	s.mu.Unlock()
}

// 購読者ごとの channel は容量 1 で「最新だけ残す」。遅い購読者が居ても送信側を止めず、
// 古いスナップショットを捨てて最新に置き換える
func (s *server) broadcast() {
	data := s.snapshot()
	s.mu.Lock()
	defer s.mu.Unlock()
	for ch := range s.subscribers {
		select {
		case ch <- data:
		default:
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- data:
			default:
			}
		}
	}
}

// 定数時間比較でトークンを照合する (長さの違いで早期 return しない)
func (s *server) tokenMatches(candidate string) bool {
	return candidate != "" && subtle.ConstantTimeCompare([]byte(candidate), []byte(s.token)) == 1
}

// GET は cookie でも通す (EventSource はヘッダを付けられない)。
// 状態を変える POST は Authorization ヘッダだけを受ける (先頭コメント参照)
func (s *server) authorized(r *http.Request) bool {
	if auth := r.Header.Get("Authorization"); strings.HasPrefix(auth, "Bearer ") {
		return s.tokenMatches(strings.TrimPrefix(auth, "Bearer "))
	}
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		return false
	}
	cookie, err := r.Cookie(tokenCookieName)
	if err != nil {
		return false
	}
	return s.tokenMatches(cookie.Value)
}

func (s *server) requireToken(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.authorized(r) {
			http.Error(w, "unauthorized: token が必要です", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// /?token=<token> で初回だけトークンを受け取り cookie に移す (URL からは消す)。
// 以降は cookie で画面を出す
func (s *server) handleIndex(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	if token := r.URL.Query().Get("token"); token != "" {
		if !s.tokenMatches(token) {
			http.Error(w, "unauthorized: token が違います", http.StatusUnauthorized)
			return
		}
		http.SetCookie(w, &http.Cookie{
			Name:     tokenCookieName,
			Value:    token,
			Path:     "/",
			SameSite: http.SameSiteStrictMode,
			MaxAge:   int(tokenCookieMaxAge.Seconds()),
		})
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}
	if !s.authorized(r) {
		http.Error(w, "unauthorized: serve の起動時に表示された /?token=<token> の URL で開いてください", http.StatusUnauthorized)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(webIndex)
}

// ホーム画面に追加した web app は Safari と cookie を共有しないため、start_url に
// トークンを載せて起動時に cookie を取り直させる (manifest 自体が認証済みにしか返らない)
func (s *server) handleManifest(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/manifest+json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(map[string]any{
		"name":             "suzu",
		"short_name":       "suzu",
		"start_url":        "/?token=" + s.token,
		"display":          "standalone",
		"background_color": "#111111",
		"theme_color":      "#ff5f00",
	})
}

// GET /api/notifications: 最新スナップショット (ページ復帰時の取り直しに使う)
func (s *server) handleNotifications(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(s.snapshot())
}

// GET /api/events: SSE。接続直後にスナップショットを 1 回流し、以降は更新のたびに流す
func (s *server) handleEvents(w http.ResponseWriter, r *http.Request) {
	flusher, ok := w.(http.Flusher)
	if !ok {
		http.Error(w, "streaming unsupported", http.StatusInternalServerError)
		return
	}
	ch := s.subscribe()
	defer s.unsubscribe(ch)
	w.Header().Set("Content-Type", "text/event-stream")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Connection", "keep-alive")
	writeEvent := func(data []byte) bool {
		if _, err := fmt.Fprintf(w, "event: notifications\ndata: %s\n\n", data); err != nil {
			return false
		}
		flusher.Flush()
		return true
	}
	if !writeEvent(s.snapshot()) {
		return
	}
	keepAlive := time.NewTicker(sseKeepAlive)
	defer keepAlive.Stop()
	for {
		select {
		case <-r.Context().Done():
			return
		case data := <-ch:
			if !writeEvent(data) {
				return
			}
		case <-keepAlive.C:
			if _, err := fmt.Fprint(w, ": keep-alive\n\n"); err != nil {
				return
			}
			flusher.Flush()
		}
	}
}

// POST /api/actions: ボタン 1 回分を検査して tmux へ流す
func (s *server) handleActions(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var req actionRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, maxActionBody)).Decode(&req); err != nil {
		writeJSONError(w, http.StatusBadRequest, "リクエストの JSON を読めません")
		return
	}
	item, found := s.find(req.PaneID)
	if !found {
		writeJSONError(w, http.StatusNotFound, "通知一覧に無い pane です: "+req.PaneID)
		return
	}
	var err error
	switch req.Action {
	case "jump":
		err = s.jump(item)
	case "send-keys":
		if !allowedKey(req.Key) {
			writeJSONError(w, http.StatusBadRequest, "送信できないキーです: "+req.Key)
			return
		}
		err = s.sendKey(item.PaneID, req.Key)
	default:
		writeJSONError(w, http.StatusBadRequest, "不明な action です: "+req.Action)
		return
	}
	if err != nil {
		writeJSONError(w, http.StatusInternalServerError, err.Error())
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.Write([]byte(`{"ok":true}`))
}

// ブラウザがトーストに出せるよう、失敗理由を JSON の error に入れて返す
func writeJSONError(w http.ResponseWriter, status int, message string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": message})
}
