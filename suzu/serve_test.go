package main

import (
	"bufio"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testToken = "test-token"

// tmux を叩かない server。呼ばれた action を記録する
func testServer(t *testing.T) (*server, *[]string) {
	t.Helper()
	var calls []string
	s := newServer(Config{}, testToken)
	s.preview = func(paneID string) []string { return []string{"preview of " + paneID} }
	s.jump = func(n Notification) error {
		calls = append(calls, "jump "+n.WindowID)
		return nil
	}
	s.sendKey = func(paneID string, key string) error {
		calls = append(calls, "send-keys "+paneID+" "+key)
		return nil
	}
	s.installHook = func() { calls = append(calls, "install-hook") }
	s.Send(notificationsMsg{items: []Notification{
		{Session: "main", SessionID: "$0", WindowID: "@3", WindowIndex: "0", WindowName: "claude-work", PaneID: "%7", Icon: "🔔09:00"},
	}})
	s.Send(connectionMsg{connected: true})
	// 接続時の hook 注入は action の記録と分けて数える
	calls = calls[:0]
	return s, &calls
}

// 内側 tmux に繋がるたびに doorbell hook を入れ直す (serve 単独起動・内側 server の再起動でも通知が届く)
func TestServeInstallsDoorbellHookOnConnect(t *testing.T) {
	installs := 0
	s := newServer(Config{}, testToken)
	s.installHook = func() { installs++ }
	s.Send(connectionMsg{connected: true})
	s.Send(connectionMsg{connected: false})
	s.Send(connectionMsg{connected: true})
	if installs != 2 {
		t.Errorf("接続 2 回に対して hook 注入が %d 回", installs)
	}
}

func TestLoadOrCreateTokenPersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "serve-token")
	first, err := loadOrCreateToken(path)
	if err != nil {
		t.Fatal(err)
	}
	second, err := loadOrCreateToken(path)
	if err != nil {
		t.Fatal(err)
	}
	if first == "" || first != second {
		t.Errorf("再読込で同じトークンにならない: %q %q", first, second)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Errorf("トークンファイルが本人以外にも読める: %v", info.Mode().Perm())
	}
}

// + & # のような文字を含むトークンでも、表示する URL と manifest の start_url から復元できる
func TestTokenURLEscapesToken(t *testing.T) {
	s := newServer(Config{}, "a+b&c#d")
	got := tokenURL("http://127.0.0.1:7788", s.token)
	if got != "http://127.0.0.1:7788/?token=a%2Bb%26c%23d" {
		t.Errorf("URL の escape が違う: %s", got)
	}
	parsed, _ := url.Parse(got)
	if parsed.Query().Get("token") != s.token {
		t.Errorf("表示した URL からトークンを復元できない: %q", parsed.Query().Get("token"))
	}
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, request("GET", got[len("http://127.0.0.1:7788"):], "", nil))
	if rec.Code != http.StatusFound {
		t.Errorf("escape 済み URL で初回認証が通らない: %d %s", rec.Code, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	// cookie にはトークンがそのまま入る (Set-Cookie は escape しない)
	s.handler().ServeHTTP(rec, request("GET", "/manifest.webmanifest", "", map[string]string{"Cookie": tokenCookieName + "=" + s.token}))
	if !strings.Contains(rec.Body.String(), `"start_url":"/?token=a%2Bb%26c%23d"`) {
		t.Errorf("manifest の start_url が escape されていない: %s", rec.Body.String())
	}
}

func request(method, path string, body string, headers map[string]string) *http.Request {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	for name, value := range headers {
		req.Header.Set(name, value)
	}
	return req
}

func bearer() map[string]string {
	return map[string]string{"Authorization": "Bearer " + testToken}
}

func TestServeRequiresToken(t *testing.T) {
	s, _ := testServer(t)
	handler := s.handler()
	for _, tc := range []struct {
		name    string
		req     *http.Request
		status  int
		message string
	}{
		{"ヘッダ無しの API", request("GET", "/api/notifications", "", nil), 401, "token が必要"},
		{"違うトークン", request("GET", "/api/notifications", "", map[string]string{"Authorization": "Bearer wrong"}), 401, "token が必要"},
		{"正しいトークン", request("GET", "/api/notifications", "", bearer()), 200, "claude-work"},
		{"cookie 無しの画面", request("GET", "/", "", nil), 401, "/?token="},
		{"cookie 有りの画面", request("GET", "/", "", map[string]string{"Cookie": tokenCookieName + "=" + testToken}), 200, "<title>suzu</title>"},
		{"cookie での GET API", request("GET", "/api/notifications", "", map[string]string{"Cookie": tokenCookieName + "=" + testToken}), 200, "claude-work"},
		// cookie だけでは状態を変えられない (別 origin からの POST に cookie が乗っても弾く)
		{"cookie だけの POST", request("POST", "/api/actions", `{"action":"jump","pane_id":"%7"}`, map[string]string{"Cookie": tokenCookieName + "=" + testToken}), 401, "token が必要"},
		{"違う token の cookie", request("GET", "/api/notifications", "", map[string]string{"Cookie": tokenCookieName + "=wrong"}), 401, "token が必要"},
	} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, tc.req)
		if rec.Code != tc.status || !strings.Contains(rec.Body.String(), tc.message) {
			t.Errorf("%s: status=%d body=%q (期待 %d / %q)", tc.name, rec.Code, rec.Body.String(), tc.status, tc.message)
		}
	}
}

func TestServeTokenQueryMovesTokenToCookie(t *testing.T) {
	s, _ := testServer(t)
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, request("GET", "/?token="+testToken, "", nil))
	if rec.Code != http.StatusFound || rec.Header().Get("Location") != "/" {
		t.Fatalf("/ へリダイレクトしていない: status=%d location=%q", rec.Code, rec.Header().Get("Location"))
	}
	cookie := rec.Header().Get("Set-Cookie")
	if !strings.Contains(cookie, tokenCookieName+"="+testToken) || !strings.Contains(cookie, "SameSite=Strict") {
		t.Errorf("cookie が想定どおりでない: %q", cookie)
	}

	rec = httptest.NewRecorder()
	s.handler().ServeHTTP(rec, request("GET", "/?token=wrong", "", nil))
	if rec.Code != http.StatusUnauthorized || rec.Header().Get("Set-Cookie") != "" {
		t.Errorf("違うトークンで cookie を発行している: status=%d cookie=%q", rec.Code, rec.Header().Get("Set-Cookie"))
	}
}

func TestServeNotificationsIncludePreview(t *testing.T) {
	s, _ := testServer(t)
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, request("GET", "/api/notifications", "", bearer()))
	var got stateView
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("JSON を読めない: %v (%s)", err, rec.Body.String())
	}
	if !got.Connected || len(got.Items) != 1 {
		t.Fatalf("状態が反映されていない: %+v", got)
	}
	item := got.Items[0]
	if item.PaneID != "%7" || item.WindowName != "claude-work" || item.SessionID != "$0" {
		t.Errorf("通知の内容が違う: %+v", item)
	}
	if len(item.Preview) != 1 || item.Preview[0] != "preview of %7" {
		t.Errorf("プレビューが添えられていない: %+v", item.Preview)
	}
	if strings.Join(got.Keys, ",") != strings.Join(allowedKeys, ",") {
		t.Errorf("ボタンに出すキーがホワイトリストと違う: %v", got.Keys)
	}
}

func TestServeNotificationsWithoutItemsIsEmptyArray(t *testing.T) {
	s := newServer(Config{}, testToken)
	s.preview = func(string) []string { return nil }
	s.Send(notificationsMsg{items: nil})
	body := string(s.snapshot())
	if !strings.Contains(body, `"items":[]`) {
		t.Errorf("通知が無い時に items が [] でない: %s", body)
	}
}

func TestServeActionsAreRestricted(t *testing.T) {
	s, calls := testServer(t)
	handler := s.handler()
	for _, tc := range []struct {
		name    string
		body    string
		status  int
		message string
	}{
		{"通知に無い pane", `{"action":"send-keys","pane_id":"%99","key":"Enter"}`, 404, "通知一覧に無い"},
		{"ホワイトリスト外のキー", `{"action":"send-keys","pane_id":"%7","key":"rm -rf"}`, 400, "送信できないキー"},
		{"空のキー", `{"action":"send-keys","pane_id":"%7","key":""}`, 400, "送信できないキー"},
		{"不明な action", `{"action":"kill","pane_id":"%7"}`, 400, "不明な action"},
		{"壊れた JSON", `{`, 400, "JSON"},
	} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, request("POST", "/api/actions", tc.body, bearer()))
		if rec.Code != tc.status || !strings.Contains(rec.Body.String(), tc.message) {
			t.Errorf("%s: status=%d body=%q", tc.name, rec.Code, rec.Body.String())
		}
	}
	if len(*calls) != 0 {
		t.Errorf("弾いたはずの action で tmux を叩いている: %v", *calls)
	}

	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, request("GET", "/api/actions", "", bearer()))
	if rec.Code != http.StatusMethodNotAllowed {
		t.Errorf("GET の action を受けている: %d", rec.Code)
	}
}

func TestServeActionsRunWhitelistedCommands(t *testing.T) {
	s, calls := testServer(t)
	handler := s.handler()
	for _, body := range []string{
		`{"action":"jump","pane_id":"%7"}`,
		`{"action":"send-keys","pane_id":"%7","key":"Enter"}`,
		`{"action":"send-keys","pane_id":"%7","key":"y"}`,
	} {
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, request("POST", "/api/actions", body, bearer()))
		if rec.Code != http.StatusOK || rec.Body.String() != `{"ok":true}` {
			t.Errorf("%s: status=%d body=%q", body, rec.Code, rec.Body.String())
		}
	}
	want := []string{"jump @3", "send-keys %7 Enter", "send-keys %7 y"}
	if strings.Join(*calls, "|") != strings.Join(want, "|") {
		t.Errorf("tmux への命令が違う: %v", *calls)
	}
}

func TestServeManifestCarriesTokenInStartURL(t *testing.T) {
	s, _ := testServer(t)
	rec := httptest.NewRecorder()
	s.handler().ServeHTTP(rec, request("GET", "/manifest.webmanifest", "", map[string]string{"Cookie": tokenCookieName + "=" + testToken}))
	if rec.Code != 200 || !strings.Contains(rec.Body.String(), `"start_url":"/?token=`+testToken+`"`) {
		t.Errorf("manifest の start_url にトークンが無い: status=%d body=%s", rec.Code, rec.Body.String())
	}
	rec = httptest.NewRecorder()
	s.handler().ServeHTTP(rec, request("GET", "/manifest.webmanifest", "", nil))
	if rec.Code != 401 {
		t.Errorf("認証無しで manifest (トークン入り) を返している: %d", rec.Code)
	}
}

// SSE は接続直後のスナップショットと、その後の更新を push する
func TestServeEventsPushUpdates(t *testing.T) {
	s, _ := testServer(t)
	ts := httptest.NewServer(s.handler())
	defer ts.Close()

	req, _ := http.NewRequest("GET", ts.URL+"/api/events", nil)
	req.Header.Set("Authorization", "Bearer "+testToken)
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	if res.Header.Get("Content-Type") != "text/event-stream" {
		t.Fatalf("Content-Type が違う: %q", res.Header.Get("Content-Type"))
	}
	reader := bufio.NewReader(res.Body)
	readEvent := func() string {
		type result struct {
			data string
			err  error
		}
		done := make(chan result, 1)
		go func() {
			for {
				line, err := reader.ReadString('\n')
				if err != nil {
					done <- result{err: err}
					return
				}
				if data, found := strings.CutPrefix(line, "data: "); found {
					done <- result{data: strings.TrimSpace(data)}
					return
				}
			}
		}()
		select {
		case r := <-done:
			if r.err != nil {
				t.Fatalf("SSE の読み取りに失敗: %v", r.err)
			}
			return r.data
		case <-time.After(5 * time.Second):
			t.Fatal("SSE のイベントが 5 秒待っても届かない")
			return ""
		}
	}

	if first := readEvent(); !strings.Contains(first, "claude-work") {
		t.Errorf("接続直後のスナップショットに通知が無い: %s", first)
	}
	s.Send(notificationsMsg{items: []Notification{
		{Session: "other", SessionID: "$1", WindowID: "@9", WindowIndex: "2", WindowName: "build", PaneID: "%12", Icon: "🔔"},
	}})
	if second := readEvent(); !strings.Contains(second, "build") || strings.Contains(second, "claude-work") {
		t.Errorf("更新が push されていない: %s", second)
	}
}

func TestGenerateToken(t *testing.T) {
	a, err := generateToken()
	if err != nil {
		t.Fatal(err)
	}
	b, _ := generateToken()
	if len(a) != tokenBytes*2 || a == b {
		t.Errorf("トークンが %d 桁の hex で毎回変わる形になっていない: %q %q", tokenBytes*2, a, b)
	}
}

func TestIsUnspecifiedHost(t *testing.T) {
	for host, want := range map[string]bool{"0.0.0.0": true, "::": true, "127.0.0.1": false, "100.64.0.1": false, "localhost": false} {
		if got := isUnspecifiedHost(host); got != want {
			t.Errorf("%s: %v (期待 %v)", host, got, want)
		}
	}
}
