#!/usr/bin/env bash
# issue #67 Phase 2: suzu (額縁 + 通知サイドバー) の自動検証
#
# 普段の tmux (default socket) には一切触れず、隔離 socket を 4 つ使う:
#   IN  = 内側 tmux の代役 (隔離 socket, -f /dev/null)。session test1 / test2 を持つ
#   OUT = suzu start が構築する外側 (隔離 socket 名を環境変数で注入)
#   T   = ターミナルエミュレータの代役。pane 内で外側へ attach し、send-keys で
#         「実端末からのキー入力 → 外側 → 内側 / サイドバー」の経路を再現する
#   X   = 「普段の端末から内側へ attach しっぱなしの余分な実 client」の代役。
#         実 client が複数ある状況を作り、ジャンプが右 pane の client だけを
#         切り替えることを確かめる
#
# 実行: bash suzu/verify.sh
# 全項目 PASS で exit 0。コピーモード・OSC52・マウスは T への send-keys で再現する (5j / 5k)。
# IME (変換前文字列の描画) だけは実端末でしか再現できず、ユーザーの手動検証に委ねる。
set -u

SUZU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUZU_BIN="$SUZU_DIR/bin/suzu"
TMP_DIR="$SUZU_DIR/../tmp"
IN="szv-in-$$"
OUT="szv-out-$$"
T="szv-term-$$"
X="szv-extra-$$"
# 壊れた socket からの自己修復を試すための使い捨て socket 名
STALE="szv-stale-$$"
BROKEN="szv-broken-$$"
DOORBELL_DIR="$TMP_DIR/phase2-doorbell-$$"
DOORBELL="$DOORBELL_DIR/doorbell"
# セクションの設定ファイルと、Claude Code / 常駐スクリプトの代役 (プロセス名で一致させる)
CONFIG_FILE="$DOORBELL_DIR/config"
FAKE_BIN="$DOORBELL_DIR/bin"
# 端末代役 T の pane 出力 (= 外側 client が実端末へ書く生のバイト列) を pipe-pane で溜める先
OSC52_LOG="$TMP_DIR/phase2-osc52-$$.log"
FAIL=0

pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  # 最初の失敗時点の状態だけ残す。手元で再現せず CI のログだけで切り分けるための材料
  [ "$FAIL" = 0 ] && dump_state
  FAIL=1
}

dump_state() {
  echo "--- state at first failure (tmux $(tmux -V 2>&1)) ---"
  echo "[outer panes]"
  tmux -L "$OUT" list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_id} sidebar=#{@suzu-sidebar} active=#{pane_active} #{pane_width}x#{pane_height} cmd=#{pane_current_command} dead=#{pane_dead} title=#{pane_title}' 2>&1
  echo "[sidebar screen]"
  tmux -L "$OUT" capture-pane -p -t "$(tmux -L "$OUT" list-panes -t suzu:0 -f '#{@suzu-sidebar}' -F '#{pane_id}' 2>/dev/null | head -1)" 2>&1
  echo "[inner sessions]"
  tmux -L "$IN" list-panes -a -F '#{session_name} #{session_id} #{window_id} #{window_name} #{pane_id} waiting=#{@claude-waiting}' 2>&1
  echo "[inner clients]"
  tmux -L "$IN" list-clients -F '#{client_name} control=#{client_control_mode} tty=#{client_tty}' 2>&1
  echo "[inner hooks/keys]"
  tmux -L "$IN" show-hooks -g after-set-option 2>&1
  tmux -L "$IN" list-keys -T prefix 2>&1 | grep -E "^bind-key +(-r +)?-T +prefix +(N|b|Z) "
  # suzu が使う format の区切り (US, 0x1f) と pane option の読み出しが、この tmux 版で
  # 素通しされるかを見る。旧版で _ に置き換わる等の差があればここで分かる
  echo "[format separator passthrough]"
  tmux -L "$IN" list-panes -a -F "#{pane_id}$(printf '\037')#{pane_tty}" 2>&1 | od -c | head -3
  # suzu が内側 pane と通知一覧を引く時と同じ問い合わせ (suzu/tmux.go の innerPaneFilter / waitingFilter)
  echo "[suzu queries]"
  tmux -L "$OUT" list-panes -t suzu:0 -f '#{?#{@suzu-sidebar},0,1}' -F '#{pane_id} #{pane_tty}' 2>&1
  tmux -L "$OUT" list-panes -t suzu:0 -f '#{?#{@suzu-sidebar},0,1}' -F "#{pane_id}$(printf '\037')#{pane_tty}" 2>&1 | od -c | head -3
  tmux -L "$IN" list-panes -a -f '#{?#{@claude-waiting},1,0}' -F '#{session_name} #{session_id} #{window_id} #{window_index} #{window_name} #{pane_id} #{@claude-waiting}' 2>&1
  echo "[pane option readback]"
  tmux -L "$IN" list-panes -a -F '#{pane_id}' 2>/dev/null | while read -r pane; do
    printf '%s local=[%s]\n' "$pane" "$(tmux -L "$IN" show-options -p -q -v -t "$pane" @claude-waiting 2>&1)"
  done
  # セクションが pane のプロセス木をどう見ているか (suzu/sections.go と同じ問い合わせ)
  echo "[inner pane processes]"
  tmux -L "$IN" list-panes -a -F '#{pane_id} pid=#{pane_pid} cmd=#{pane_current_command}' 2>&1
  ps -e -ww -o pid=,ppid=,args= 2>&1 | grep -F "$FAKE_BIN" | grep -v grep
  echo "--- end state ---"
}

# tmux 本体と同じ規則で socket のパスを組む
socket_path() { echo "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$1"; }

cleanup() {
  local socket
  for socket in "$T" "$X" "$OUT" "$STALE" "$BROKEN" "$IN"; do
    tmux -L "$socket" kill-server 2>/dev/null
  done
  # kill-server は socket 経由の命令なので、socket が壊れた server や、server が消えた後も
  # 残る control mode client (サイドバーが張る -C attach) には届かない。完走後にも
  # 内側 server が残った実例があるため、このスクリプトの隔離 socket 名を持つ
  # tmux プロセスをプロセス一覧から直接落とす (socket 名は $$ 付きで一意)。
  # $$( と書くと bash がコマンド置換として読むため ${$} で参照する
  pkill -f "tmux -L szv-[a-z]+-${$}( |\$)" 2>/dev/null
  for socket in "$T" "$X" "$OUT" "$STALE" "$BROKEN" "$IN"; do
    rm -f "$(socket_path "$socket")"
  done
  rm -rf "$DOORBELL_DIR"
  rm -f "$OSC52_LOG"
}
# Ctrl-C や timeout の SIGTERM で中断された時も EXIT trap を通して後片付けする
trap 'exit 130' INT TERM
trap cleanup EXIT

# suzu を隔離 socket 向けの環境で実行する
# SUZU_CONFIG_FILE は、実行者の ~/.config/suzu/config を読まないよう必ず隔離する。
# SUZU_SCRAPE_INTERVAL=1 は既定の 5 秒より短くして待ち時間を詰めるため
suzu() {
  SUZU_OUTER_SOCKET="$OUT" \
  SUZU_INNER_TMUX="tmux -L $IN" \
  SUZU_INNER_TMUX_CMD="tmux -L $IN attach -t test1" \
  SUZU_DOORBELL_FILE="$DOORBELL" \
  SUZU_CONFIG_FILE="$CONFIG_FILE" \
  SUZU_SCRAPE_INTERVAL=1 \
    "$SUZU_BIN" "$@" </dev/null
}

# cond コマンドが真になるまで最大 50 x 0.2 秒待つ
wait_for() {
  local i
  for i in $(seq 1 50); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

# 端末代役 T を height 行で起動し、その pane で command を実行する。
# kill-server 直後は旧 server が終了処理中で、同じ socket へ繋いだ新しい client が
# "server exited unexpectedly" で落ちることがある (tmux 3.4 の CI で実測。同じ commit の
# 前回実行は通っており再現性は無い)。socket の残り方は OS で違う (Linux は server が
# unlink する・macOS は残る) ため、socket の消失ではなく起動の成否で短く再試行する
start_terminal_stand_in() {
  local height="$1" command="$2" i
  for i in 1 2 3 4 5; do
    tmux -L "$T" -f /dev/null new-session -d -s term -x 220 -y "$height" "$command" 2>/dev/null \
      && return 0
    sleep 0.2
  done
  return 1
}

outer_panes() {
  tmux -L "$OUT" list-panes -t suzu:0 2>/dev/null | wc -l | tr -d ' '
}

sidebar_pane() {
  tmux -L "$OUT" list-panes -t suzu:0 -f '#{@suzu-sidebar}' -F '#{pane_id}' 2>/dev/null | head -1
}

# サイドバー pane の描画に pattern が現れるまで待つ
sidebar_shows() {
  wait_for "tmux -L $OUT capture-pane -p -t \"\$(sidebar_pane)\" 2>/dev/null | grep -qF -- '$1'"
}

# サイドバー pane の描画から pattern が消えるまで待つ
sidebar_hides() {
  wait_for "! tmux -L $OUT capture-pane -p -t \"\$(sidebar_pane)\" 2>/dev/null | grep -qF -- '$1'"
}

first_sidebar_line() {
  tmux -L "$OUT" capture-pane -p -t "$(sidebar_pane)" 2>/dev/null | head -1
}

active_pane_is_sidebar() {
  [ "$(tmux -L "$OUT" list-panes -t suzu:0 -f '#{pane_active}' -F '#{@suzu-sidebar}')" = 1 ]
}

# 指定 tty に繋がった内側 client の session。実 client が複数あるため tty で特定する
client_session_of_tty() {
  tmux -L "$IN" list-clients -f "#{==:#{client_tty},$1}" -F '#{client_session}' 2>/dev/null | head -1
}

client_name_of_tty() {
  tmux -L "$IN" list-clients -f "#{==:#{client_tty},$1}" -F '#{client_name}' 2>/dev/null | head -1
}

# 外側の右 pane (= 内側へ attach している pane)
inner_pane_id() {
  tmux -L "$OUT" list-panes -t suzu:0 -f '#{?#{@suzu-sidebar},0,1}' -F '#{pane_id}' 2>/dev/null | head -1
}

inner_pane_tty() {
  tmux -L "$OUT" list-panes -t suzu:0 -f '#{?#{@suzu-sidebar},0,1}' -F '#{pane_tty}' 2>/dev/null | head -1
}

# 右 pane (内側 tmux の描画) に pattern が現れるまで待つ
inner_pane_shows() {
  wait_for "tmux -L $OUT capture-pane -p -t \"\$(inner_pane_id)\" 2>/dev/null | grep -qF -- '$1'"
}

# suzu の doorbell hook は touch 先のパスで自分のものと分かる。
# ユーザー自身の after-set-option hook と混ざるため、名前ではなくパスで数える
doorbell_hook_count() {
  tmux -L "$IN" show-hooks -g after-set-option 2>/dev/null | grep -cF -- "$DOORBELL"
}

inner_hook_installed() {
  [ "$(doorbell_hook_count)" -ge 1 ]
}

inner_key_installed() {
  tmux -L "$IN" list-keys -T prefix 2>/dev/null | grep -E "^bind-key +(-r +)?-T +prefix +$1 " | grep -qF -- "$SUZU_BIN"
}

echo "=== 1. suzu をビルド ==="
mkdir -p "$TMP_DIR"
if (cd "$SUZU_DIR" && go build -o bin/suzu .); then
  pass "go build"
else
  fail "go build"
  echo "RESULT: FAILED"
  exit 1
fi

echo "=== 1b. セクションの設定ファイルと代役プロセスを用意 ==="
mkdir -p "$FAKE_BIN"
cat >"$CONFIG_FILE" <<'CONF'
# 設定ファイルの section 行で汎用セクションを足す (Claude / Codex は組み込み)
section = Watchers:szv-fake-watcher
CONF
# Claude Code の代役。実機の capture-pane と同じ実行中表示を出し、Enter で入力待ち表示へ、
# もう一度 Enter で終了する。sh スクリプトなので ps では "sh .../claude" と見え、
# 実行ファイル名ではなく引数の basename で claude と一致する経路を通る
cat >"$FAKE_BIN/claude" <<'FAKE'
printf '✶ Swirling… (3s · ↓ 1.0k tokens)\n'
read -r _
printf '\033[2J\033[H❯ \n'
read -r _
FAKE
# 常駐スクリプトの代役 (tmux-issue-watcher 相当)
cat >"$FAKE_BIN/szv-fake-watcher" <<'FAKE'
read -r _
FAKE
[ -f "$CONFIG_FILE" ] && [ -f "$FAKE_BIN/claude" ] && [ -f "$FAKE_BIN/szv-fake-watcher" ] \
  && pass "設定ファイルと代役スクリプトを配置" || fail "設定ファイルと代役スクリプトの配置"

echo "=== 2. 内側 (代役) server を隔離 socket で起動 (test1 / test2) ==="
tmux -L "$IN" -f /dev/null new-session -d -s test1 -x 200 -y 50 \
  'echo INNER_READY_MARKER; exec sh' || fail "内側 session test1 の起動"
# pane プレビューの検証用に、session ごとに違うマーカーを画面へ出しておく
tmux -L "$IN" new-session -d -s test2 -n claude-work -x 200 -y 50 \
  'echo PREVIEW_TEST2_MARKER; exec sh' || fail "内側 session test2 の起動"
wait_for "tmux -L $IN capture-pane -p -t test1:0.0 2>/dev/null | grep -q INNER_READY_MARKER" \
  && pass "内側 server 起動 (test1 / test2)" || fail "内側 server 起動"

echo "=== 2b. 余分な実 client を先に内側へ attach させる ==="
# ユーザーの実環境では普段の端末からの attach が残ったまま nested の右 pane が attach する。
# ジャンプが右 pane 以外の client を掴む退行を検出するため、右 pane より先に attach させる
tmux -L "$X" -f /dev/null new-session -d -s extra -x 200 -y 50 "TMUX= tmux -L $IN attach -t test1" \
  || fail "余分な実 client の起動"
EXTRA_TTY=$(tmux -L "$X" list-panes -t extra:0 -F '#{pane_tty}' 2>/dev/null | head -1)
wait_for "[ \"\$(client_session_of_tty $EXTRA_TTY)\" = test1 ]" \
  && pass "余分な実 client が test1 へ attach" || fail "余分な実 client が attach しない"

echo "=== 3. suzu start で額縁を構築 ==="
suzu start || fail "suzu start"

wait_for "[ \"\$(outer_panes)\" = 2 ]" \
  && pass "外側 window が左右 2 pane" || fail "外側 window が左右 2 pane"
inner_pane_shows 'INNER_READY_MARKER' \
  && pass "右 pane に内側 tmux の内容が描画される" || fail "右 pane に内側 tmux の内容が描画される"
# 初回構築は内側で作業を始めるため、フォーカスは右のまま (toggle で開いた時だけ左へ当てる)
! active_pane_is_sidebar \
  && pass "start 直後のフォーカスは内側 pane" || fail "start 直後にサイドバーへフォーカスが当たっている"

# 外側は ~/.tmux.conf を読まず、outer.go の設定だけが入っていること
[ "$(tmux -L "$OUT" show-options -gv prefix)" = "None" ] \
  && pass "外側の prefix は None (キーを掴まない)" || fail "外側の prefix は None"
[ "$(tmux -L "$OUT" show-options -gv status)" = "off" ] \
  && pass "外側の status は off" || fail "外側の status は off"
[ "$(tmux -L "$OUT" show-options -gv pane-border-lines)" = "heavy" ] \
  && pass "境界線が太罫線 (pane-border-lines heavy)" || fail "pane-border-lines が heavy でない"
[ "$(tmux -L "$OUT" show-options -gv window-active-style)" = "bg=terminal" ] \
  && pass "アクティブ pane の背景が地の色 (window-active-style)" || fail "window-active-style が bg=terminal でない"

echo "=== 3b. 冪等性: start を再実行しても pane が増えない ==="
# 旧版バイナリが構築した外側には古い設定値が残る。start の再実行で最新値へ揃うことを見る
tmux -L "$OUT" set-option -g set-clipboard external
RESTART_ERR=$(suzu start 2>&1 >/dev/null)
[ "$(outer_panes)" = 2 ] && pass "start は冪等 (2 pane のまま)" || fail "start は冪等 (stderr: $RESTART_ERR)"
[ "$(tmux -L "$OUT" show-options -gv set-clipboard)" = "on" ] && pass "start の再実行で外側の設定が再適用される (旧版で構築した外側にも最新値が入る)" || fail "start の再実行で外側の設定が再適用されない (set-clipboard=$(tmux -L "$OUT" show-options -gv set-clipboard))"

inner_key_installed N && pass "内側に prefix+N のジャンプキーが注入されている" || fail "ジャンプキーの注入"
inner_key_installed b && pass "内側に prefix+b の toggle キーが注入されている" || fail "toggle キーの注入"
inner_hook_installed \
  && pass "内側に after-set-option hook が注入されている" || fail "after-set-option hook の注入"

sidebar_shows 'Noroshi' && pass "サイドバーが描画される" || fail "サイドバーが描画されない"
sidebar_shows '通知なし' && pass "通知が無い時は「通知なし」" || fail "「通知なし」が描画されない"

echo "=== 4. 非 attach session (test2) の通知が push で届く ==="
tmux -L "$IN" set-option -t test2:0.0 -p @claude-waiting '🔔09:00' || fail "@claude-waiting の set"
sidebar_shows '▸ test2 (1)' \
  && pass "非 attach session の見出しが出る (cross-session の push 経路)" \
  || fail "非 attach session の見出しが出ない"
sidebar_shows 'claude-work' \
  && pass "見出しの配下に window 行が出る" || fail "window 行が出ない"
sidebar_shows '🔔' && pass "アイコンが描画される" || fail "アイコンが描画されない"
sidebar_shows 'Noroshi 🔔1' && pass "件数表示が 1" || fail "件数表示が 1 にならない"
sidebar_shows 'PREVIEW_TEST2_MARKER' \
  && pass "選択中通知の pane プレビューが出る" || fail "pane プレビューが出ない"

echo "=== 5. 実キー経路: 端末代役 T から外側を素通りして内側へ ==="
tmux -L "$T" -f /dev/null new-session -d -s term -x 220 -y 60 \
  "TMUX= tmux -L $OUT attach -t suzu" || fail "端末代役 T の起動"
wait_for "tmux -L $T capture-pane -p -t term:0.0 2>/dev/null | grep -q INNER_READY_MARKER" \
  && pass "T → 外側 → 内側の描画チェーン成立" || fail "T → 外側 → 内側の描画チェーン成立"

# 内側 (代役) の prefix は C-b (-f /dev/null のデフォルト)。C-b c で内側に window が増えれば、
# キーが「T の pane → 外側 client → 外側 server (素通し) → 内側 client → 内側 server」を通った証拠
tmux -L "$T" send-keys -t term:0.0 C-b c
wait_for "[ \"\$(tmux -L $IN list-windows -t test1 2>/dev/null | wc -l | tr -d ' ')\" = 2 ]" \
  && pass "prefix (C-b c) が外側を素通りして内側に window が増えた" \
  || fail "prefix (C-b c) が内側に届かない"
# 以降の通知件数に影響しないよう、増えた window は片付けて元の window へ戻す
tmux -L "$IN" kill-window -t test1:1 2>/dev/null

echo "=== 5a. フォーカス位置が境界線と背景で分かる ==="
# 描画そのもの (T の pane) を見る。window-style は pane の grid には残らず
# client への描画時にだけ乗るため、外側の capture-pane では検出できない
outer_render() { tmux -L "$T" capture-pane -e -p -t term:0.0 2>/dev/null; }
# 描画の 1 行には左右両方の pane が入っているため、境界線で切って左半分だけを見る
sidebar_render_segment() {
  local line
  line=$(outer_render | grep -m1 Noroshi)
  printf '%s' "${line%%┃*}"
}
sidebar_is_dimmed() { sidebar_render_segment | grep -q '48;5;253'; }

outer_render | grep -q '┃' \
  && pass "境界線が太罫線で描画される" || fail "境界線が太罫線で描画されない"
wait_for "sidebar_is_dimmed" \
  && pass "非アクティブなサイドバーが暗く描画される" || fail "非アクティブ側が暗くならない"

echo "=== 5a2. 実端末のタイトルに内側 tmux のタイトルが出る ==="
# 内側の set-titles (ユーザーの ~/.tmux.conf と同じ) が流すタイトルを外側が素通しし、
# 実端末 (Alacritty のタブ) には従来どおり session:index:window - "pane title" が出ること
tmux -L "$IN" set -g set-titles on
tmux -L "$IN" select-pane -t test1:0.0 -T TITLE_MARKER
term_title() { tmux -L "$T" display-message -p -t term:0.0 '#{pane_title}'; }
wait_for "term_title | grep -q 'test1:0:.*TITLE_MARKER'" \
  && pass "実端末のタイトルが内側の session:index:window - \"pane title\" になる" \
  || fail "実端末のタイトルに内側のタイトルが出ない ($(term_title))"
term_title | grep -q '"$' \
  && pass "タイトルに末尾の空白が残らない (P: の空要素を落とす)" \
  || fail "タイトルの末尾に余分な空白が残る ($(term_title))"

echo "=== 5b. prefix+N でサイドバーへ → Enter でジャンプ ==="
INNER_TTY=$(inner_pane_tty)
tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" \
  && pass "prefix+N でサイドバーへフォーカスが移る" || fail "prefix+N でサイドバーへフォーカスが移らない"
term_title | grep -q 'test1:0:' \
  && pass "サイドバーにフォーカスしても実端末のタイトルは内側のまま" \
  || fail "サイドバーへのフォーカスでタイトルが変わった ($(term_title))"
# window-active-style に bg=default を書くと「window-style を継承」の意味になり、
# 両 pane が同じ背景色になってしまう。その退行をここで捕まえる
wait_for "! sidebar_is_dimmed" \
  && pass "アクティブになったサイドバーは暗くならない" \
  || fail "アクティブ側まで暗いまま (window-active-style が効いていない)"

tmux -L "$T" send-keys -t term:0.0 Enter
wait_for "[ \"\$(client_session_of_tty $INNER_TTY)\" = test2 ]" \
  && pass "Enter で右 pane の client が test2 へジャンプ" || fail "Enter で右 pane の client がジャンプしない"
[ "$(client_session_of_tty "$EXTRA_TTY")" = test1 ] \
  && pass "余分な実 client は test1 のまま (右 pane 以外を切り替えない)" \
  || fail "右 pane 以外の client を切り替えてしまった"
# ジャンプは window を切り替えるだけ。右へ移るのは明示操作のみにする
sleep 1
active_pane_is_sidebar \
  && pass "ジャンプ後もフォーカスはサイドバーに留まる" || fail "ジャンプ後にフォーカスが右へ移った"

echo "=== 5c. サイドバーからも prefix+N で右 pane へ戻る ==="
# 同じ prefix+N が往復のトグルになる (内側は注入バインド、サイドバーは TUI 側のキー処理)
tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "! active_pane_is_sidebar" \
  && pass "サイドバーで prefix+N を押すと内側 pane へ戻る" || fail "サイドバーの prefix+N で戻らない"

tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" \
  && pass "再度 prefix+N でサイドバーへ移る" || fail "再度 prefix+N でサイドバーへ移らない"
tmux -L "$T" send-keys -t term:0.0 x
sleep 1
active_pane_is_sidebar \
  && pass "未割り当てキー (x) ではフォーカスが動かない" || fail "未割り当てキーでフォーカスが動いた"
tmux -L "$T" send-keys -t term:0.0 q
wait_for "! active_pane_is_sidebar" \
  && pass "q で内側 pane へ戻る" || fail "q で戻らない"

echo "=== 5d. j/k で選択を移すとプレビューも切り替わる ==="
# 2 件目 (test1) を足す。list-panes -a は session 順なので test1 が先頭へ割り込む
tmux -L "$IN" set-option -t test1:0.0 -p @claude-waiting '🔔09:30' || fail "2 件目の @claude-waiting の set"
sidebar_shows 'Noroshi 🔔2' && pass "件数表示が 2" || fail "件数表示が 2 にならない"
# 整数の cursor をそのまま使うと、割り込みで選択が別 window へずれ、
# 直後の Enter が意図しない window へ飛ぶ
sidebar_shows 'PREVIEW_TEST2_MARKER' \
  && pass "一覧が更新されても選択中の window (test2) が保たれる" \
  || fail "一覧の更新で選択が別 window へずれた"

tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" || fail "プレビュー検証のためのフォーカス移動"
tmux -L "$T" send-keys -t term:0.0 k
sidebar_shows 'INNER_READY_MARKER' \
  && pass "k で選択を上げるとプレビューが test1 の pane に変わる" \
  || fail "k でプレビューが切り替わらない"
tmux -L "$T" send-keys -t term:0.0 j
sidebar_shows 'PREVIEW_TEST2_MARKER' \
  && pass "j で選択を戻すとプレビューも戻る" || fail "j でプレビューが戻らない"
tmux -L "$T" send-keys -t term:0.0 q
wait_for "! active_pane_is_sidebar" || fail "プレビュー検証後のフォーカス復帰"

echo "=== 5e. session 見出しの階層表示とフィルタリング ==="
sidebar_shows '▸ test1' \
  && pass "2 session に通知がある時は見出しが 2 つ並ぶ" || fail "session 見出しが 2 つ並ばない"

# ジャンプの検証を意味のあるものにするため、右 pane を一度 test1 へ戻しておく
tmux -L "$IN" switch-client -c "$(client_name_of_tty "$INNER_TTY")" -t test1
wait_for "[ \"\$(client_session_of_tty $INNER_TTY)\" = test1 ]" \
  || fail "右 pane の client を test1 へ戻せない"

tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" || fail "フィルタ検証のためのフォーカス移動"
tmux -L "$T" send-keys -l -t term:0.0 '/'
tmux -L "$T" send-keys -l -t term:0.0 'claude'
sidebar_shows 'filter: claude_' \
  && pass "/ で入力モードに入りクエリが編集中と分かる" || fail "入力中のクエリが表示されない"

tmux -L "$T" send-keys -t term:0.0 Enter
sidebar_hides '▸ test1' \
  && pass "確定で一致しない session のグループが消える" || fail "一致しない session が残る"
sidebar_shows '▸ test2 (1)' \
  && pass "一致した session のグループは残る" || fail "一致した session まで消えた"

tmux -L "$T" send-keys -t term:0.0 Enter
wait_for "[ \"\$(client_session_of_tty $INNER_TTY)\" = test2 ]" \
  && pass "フィルタ確定後の Enter で一致 window へジャンプ" || fail "フィルタ後にジャンプできない"

tmux -L "$T" send-keys -t term:0.0 Escape
sidebar_shows '▸ test1' \
  && pass "Esc でフィルタが解除され全件に戻る" || fail "Esc でフィルタが解除されない"
sidebar_hides 'filter:' && pass "解除でフィルタ行が消える" || fail "フィルタ行が残っている"

echo "=== 5f. 絞り込んだまま ctrl+n で選んでジャンプする ==="
tmux -L "$IN" switch-client -c "$(client_name_of_tty "$INNER_TTY")" -t test1
wait_for "[ \"\$(client_session_of_tty $INNER_TTY)\" = test1 ]" || fail "右 pane の client を test1 へ戻せない"

tmux -L "$T" send-keys -l -t term:0.0 '/'
tmux -L "$T" send-keys -l -t term:0.0 'test'
sidebar_shows 'filter: test_ (2/2)' \
  && pass "2 件に一致するクエリの入力" || fail "2 件に一致するクエリで絞れない"
tmux -L "$T" send-keys -t term:0.0 C-n
tmux -L "$T" send-keys -t term:0.0 Enter
tmux -L "$T" send-keys -t term:0.0 Enter
wait_for "[ \"\$(client_session_of_tty $INNER_TTY)\" = test2 ]" \
  && pass "入力モード中の ctrl+n で選んだ window へジャンプできる" \
  || fail "入力モード中の ctrl+n で選択が動かない"
tmux -L "$T" send-keys -t term:0.0 Escape
sidebar_hides 'filter:' || fail "5f 後のフィルタ解除"
tmux -L "$T" send-keys -t term:0.0 q
wait_for "! active_pane_is_sidebar" || fail "5f 後のフォーカス復帰"

echo "=== 5g. サイドバーの表示/非表示 (prefix+b と suzu toggle) ==="
# 内側にフォーカスがある状態から。キーは内側 tmux の注入バインドが受ける
tmux -L "$T" send-keys -t term:0.0 C-b b
wait_for "[ \"\$(outer_panes)\" = 1 ]" \
  && pass "内側から prefix+b でサイドバーが閉じる (1 pane)" || fail "内側からの prefix+b で閉じない"
tmux -L "$T" send-keys -t term:0.0 C-b b
wait_for "[ \"\$(outer_panes)\" = 2 ]" \
  && pass "内側から prefix+b でサイドバーが再表示 (2 pane)" || fail "内側からの prefix+b で再表示されない"
wait_for "active_pane_is_sidebar" \
  && pass "toggle で開いた時はサイドバーにフォーカスが当たる" || fail "開いてもフォーカスが右のまま"
sidebar_shows '▸ test1' \
  && pass "再表示後も通知一覧を取得できている" || fail "再表示後のサイドバーが通知を出せない"

# サイドバーにフォーカスがある状態から。内側にキーが届かないため、
# 同じ prefix+b を TUI 側が解釈して閉じる
tmux -L "$T" send-keys -t term:0.0 C-b b
wait_for "[ \"\$(outer_panes)\" = 1 ]" \
  && pass "サイドバーから prefix+b で閉じられる (1 pane)" || fail "サイドバーからの prefix+b で閉じない"
tmux -L "$T" send-keys -t term:0.0 C-b b
wait_for "[ \"\$(outer_panes)\" = 2 ]" || fail "5g の再表示"

suzu toggle
wait_for "[ \"\$(outer_panes)\" = 1 ]" \
  && pass "suzu toggle でサイドバーが閉じる (1 pane)" || fail "suzu toggle で閉じない"
suzu toggle
wait_for "[ \"\$(outer_panes)\" = 2 ]" \
  && pass "suzu toggle でサイドバーが再表示 (2 pane)" || fail "suzu toggle で再表示されない"
wait_for "active_pane_is_sidebar" \
  && pass "suzu toggle で開いた時もサイドバーにフォーカスが当たる" || fail "suzu toggle 後のフォーカスが右のまま"
inner_pane_shows '[test' \
  && pass "トグル後も内側 attach が生きている" || fail "トグル後に内側 attach が切れた"
# 以降の手順は内側フォーカスから始まる前提なので戻しておく
tmux -L "$T" send-keys -t term:0.0 q
wait_for "! active_pane_is_sidebar" || fail "5g 後のフォーカス復帰"

echo "=== 5h. 画面が狭い時のスクロール ==="
for i in 1 2 3 4 5 6 7 8; do
  tmux -L "$IN" new-window -d -t test1 -n "w$i" 'exec sh' || fail "スクロール検証用 window の作成"
  tmux -L "$IN" set-option -t "test1:w$i.0" -p @claude-waiting '🔔' || fail "スクロール検証用の通知 set"
done
# 端末代役を低い高さで作り直す (外側は最後に使われた client のサイズに合わせる)
tmux -L "$T" kill-server 2>/dev/null
start_terminal_stand_in 18 "TMUX= tmux -L $OUT attach -t suzu" || fail "低い端末代役の起動"
wait_for "[ \"\$(tmux -L $OUT display-message -p -t suzu:0 '#{window_height}' 2>/dev/null || echo 999)\" -le 20 ]" \
  || fail "外側が低い端末サイズに追従しない"

sidebar_shows '↓' && pass "画面外に続きがあるインジケータが出る" || fail "下向きインジケータが出ない"
# 縦が埋まっている時に描画が 1 行でもはみ出すと、先頭のヘッダーが押し出されて消える
wait_for "first_sidebar_line | grep -q '^Noroshi'" \
  && pass "狭い画面でも 1 行目がヘッダー" || fail "ヘッダーが画面外へ押し出されている"
sidebar_hides '▸ test2' \
  && pass "初期表示には末尾の session が入っていない" || fail "狭い画面なのに全部表示されている"

tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" || fail "スクロール検証のためのフォーカス移動"
for i in $(seq 1 12); do tmux -L "$T" send-keys -t term:0.0 j; done
sidebar_shows '▸ test2' \
  && pass "j 連打で末尾の通知までスクロールする" || fail "j 連打でも末尾が出てこない"
sidebar_shows '↑' && pass "上に隠れた行のインジケータが出る" || fail "上向きインジケータが出ない"
tmux -L "$T" send-keys -t term:0.0 q
wait_for "! active_pane_is_sidebar" || fail "スクロール検証後のフォーカス復帰"

for i in 1 2 3 4 5 6 7 8; do
  tmux -L "$IN" kill-window -t "test1:w$i" 2>/dev/null
done

echo "=== 5i. pane 幅を超える window 名・プレビュー行の切り詰め ==="
# 絵文字は 2 セル。文字数で切ると幅を超えて折り返し、行数が増えて描画全体が崩れる。
# 幅を超えた部分 (末尾のマーカー) がどこにも出ないことで、折り返していないことを確かめる
WIDE_ID=$(tmux -L "$IN" new-window -d -P -F '#{window_id}' -t test1 \
  -n '🔔wide-🔔-window-name-0123456789-NAMETAIL' 'exec sh') || fail "長い window 名の window 作成"
tmux -L "$IN" set-option -t "$WIDE_ID" -p @claude-waiting '🔔09:00' || fail "長い window 名への通知 set"
# 先頭の通知 (test1:0.0) の pane に幅を超える長い行を出し、カーソルをそこへ戻す
LONG_LINE="/very/long/path/to/Something.xcodeproj/project.pbxproj:$(printf 'x%.0s' $(seq 1 40))PREVTAIL"
tmux -L "$IN" send-keys -t test1:0.0 "echo $LONG_LINE" Enter
tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" || fail "5i のためのフォーカス移動"
for i in $(seq 1 5); do tmux -L "$T" send-keys -t term:0.0 k; done

sidebar_shows 'wide-' \
  && pass "長い window 名の先頭は描画される" || fail "長い window 名が描画されない"
sidebar_hides 'NAMETAIL' \
  && pass "pane 幅を超えた window 名が折り返さず切り詰められる" || fail "window 名が折り返している"
sidebar_shows '/very/long/path' \
  && pass "長いプレビュー行の先頭は描画される" || fail "長いプレビュー行が出ない"
sidebar_hides 'PREVTAIL' \
  && pass "pane 幅を超えたプレビュー行が折り返さず切り詰められる" || fail "プレビュー行が折り返している"
wait_for "first_sidebar_line | grep -q '^Noroshi'" \
  && pass "長い行があっても 1 行目はヘッダーのまま" || fail "長い行でヘッダーが押し出された"

tmux -L "$T" send-keys -t term:0.0 q
wait_for "! active_pane_is_sidebar" || fail "5i 後のフォーカス復帰"
tmux -L "$IN" kill-window -t "$WIDE_ID" 2>/dev/null
tmux -L "$IN" set-option -t test1:0.0 -pu @claude-waiting || fail "2 件目の @claude-waiting の解除"

echo "=== 5j. プロセスで一致する pane のセクション (Claude 組み込み + 設定ファイルの Watchers) ==="
# 通知の下に、プロセス名で一致した pane がセクションとして並ぶ。
# Claude / Codex は組み込みで、画面から 実行中 (🏃) / 入力待ち (💤) を判定する
sidebar_hides '-- Claude' && pass "該当プロセスが無い間はセクションを出さない" || fail "空のセクションが出ている"
FAKE_CLAUDE=$(tmux -L "$IN" new-window -d -P -F '#{pane_id}' -t test2 -n fake-claude "sh $FAKE_BIN/claude") \
  || fail "Claude 代役 window の作成"
sidebar_shows '-- Claude (1) --' \
  && pass "claude プロセスの pane が Claude セクションに出る" || fail "Claude セクションが出ない"
sidebar_shows '🏃 ' \
  && pass "実行中表示 (スピナー + 動詞… (経過時間)) を 🏃 と判定する" || fail "実行中と判定しない"
sidebar_shows 'fake-claude' && pass "セクションの行に window 名が出る" || fail "window 名が出ない"

# Enter で代役が入力待ち表示 (❯) に切り替わる。tmux はこれをイベントとして出さないため、
# 時間駆動の見直し (SUZU_SCRAPE_INTERVAL=1) が拾う
tmux -L "$IN" send-keys -t "$FAKE_CLAUDE" Enter
sidebar_shows '💤 ' \
  && pass "入力待ち表示になると 💤 に変わる (時間駆動の見直し)" || fail "入力待ちへの切り替わりを拾わない"

FAKE_WATCHER=$(tmux -L "$IN" new-window -d -P -F '#{pane_id}' -t test2 -n fake-watcher "sh $FAKE_BIN/szv-fake-watcher") \
  || fail "Watchers 代役 window の作成"
sidebar_shows '-- Watchers (1) --' \
  && pass "設定ファイルの section (Watchers) がスクリプト名で一致する" || fail "Watchers セクションが出ない"
sidebar_shows '▶ ' && pass "汎用セクションの行は ▶ で出る" || fail "汎用セクションの行が出ない"

# セクションの行からもジャンプできる。右 pane の client を test1 に戻してから、
# フィルタでセクション名を指定して選ぶ
tmux -L "$IN" switch-client -c "$(client_name_of_tty "$INNER_TTY")" -t test1
wait_for "[ \"\$(client_session_of_tty $INNER_TTY)\" = test1 ]" || fail "5j のための client 復帰"
tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" || fail "5j のためのフォーカス移動"
tmux -L "$T" send-keys -l -t term:0.0 '/'
tmux -L "$T" send-keys -l -t term:0.0 'Watchers'
sidebar_shows 'filter: Watchers_ (1/' \
  && pass "セクション名でも絞り込める" || fail "セクション名で絞り込めない"
tmux -L "$T" send-keys -t term:0.0 Enter
tmux -L "$T" send-keys -t term:0.0 Enter
wait_for "[ \"\$(client_session_of_tty $INNER_TTY)\" = test2 ]" \
  && pass "セクションの行から Enter でジャンプできる" || fail "セクションの行からジャンプできない"
tmux -L "$T" send-keys -t term:0.0 Escape
sidebar_hides 'filter:' || fail "5j のフィルタ解除"
tmux -L "$T" send-keys -t term:0.0 q
wait_for "! active_pane_is_sidebar" || fail "5j 後のフォーカス復帰"

# セクションで検出した pane が window の非アクティブ pane にいても、ジャンプでその pane を選ぶ。
# split-window (-d なし) は新 pane をアクティブにするため、fake-claude 側が非アクティブになる
tmux -L "$IN" split-window -t "$FAKE_CLAUDE" 'echo OTHER_PANE; exec sh' || fail "分割 pane の作成"
tmux -L "$IN" switch-client -c "$(client_name_of_tty "$INNER_TTY")" -t test1
wait_for "[ \"\$(client_session_of_tty $INNER_TTY)\" = test1 ]" || fail "select-pane 検証のための client 復帰"
# fake-claude が非アクティブなことを確かめてからジャンプ
[ "$(tmux -L "$IN" display-message -p -t "$FAKE_CLAUDE" '#{pane_active}')" = 0 ] \
  && pass "検証の前提: 検出 pane は非アクティブ" || fail "検出 pane が非アクティブにならない"
tmux -L "$T" send-keys -t term:0.0 C-b N; wait_for "active_pane_is_sidebar" || fail "select-pane 検証のためのフォーカス移動"
tmux -L "$T" send-keys -l -t term:0.0 '/'; tmux -L "$T" send-keys -l -t term:0.0 'fake-claude'
sidebar_shows 'filter: fake-claude' || fail "fake-claude で絞り込めない"
tmux -L "$T" send-keys -t term:0.0 Enter; tmux -L "$T" send-keys -t term:0.0 Enter
# ジャンプ後、検出 pane (非アクティブだった fake-claude) がアクティブになっていること
wait_for "[ \"\$(tmux -L $IN display-message -p -t $FAKE_CLAUDE '#{pane_active}')\" = 1 ]" \
  && pass "セクションのジャンプは検出 pane を select-pane する" || fail "ジャンプで検出 pane が選択されない"
tmux -L "$T" send-keys -t term:0.0 Escape; sidebar_hides 'filter:' || fail "select-pane 検証後のフィルタ解除"
tmux -L "$T" send-keys -t term:0.0 q; wait_for "! active_pane_is_sidebar" || fail "select-pane 検証後のフォーカス復帰"
tmux -L "$IN" switch-client -c "$(client_name_of_tty "$INNER_TTY")" -t test1

# 代役が終わって pane が消えれば、window の close イベントでセクションも消える
tmux -L "$IN" send-keys -t "$FAKE_CLAUDE" Enter
sidebar_hides '-- Claude' \
  && pass "claude プロセスが終わると Claude セクションが消える" || fail "終了後も Claude セクションが残る"
tmux -L "$IN" kill-window -t "$FAKE_WATCHER" 2>/dev/null
sidebar_hides '-- Watchers' \
  && pass "window を閉じると Watchers セクションが消える" || fail "閉じた後も Watchers セクションが残る"
tmux -L "$IN" switch-client -c "$(client_name_of_tty "$INNER_TTY")" -t test1

echo "=== 5k. コピーモード: prefix+[ が外側を素通りし、コピーの OSC52 が実端末まで届く ==="
# キーは 1 回の send-keys に 1 つずつ渡す。tmux は assume-paste-time (既定 1ms) より短い
# 間隔で 3 つ以上のキーが届くとペーストと見なして 3 つ目以降をキーとして解釈しない
# (server-client.c の server_client_is_assume_paste)。"k V Enter" をまとめて渡すと
# Enter が落ちて copy-selection が走らない (実測)。人の入力は 1ms より遅いので
# 1 キーずつ送るのが実機に近い
inner_state() { tmux -L "$IN" display-message -p -t test1:0.0 "$1" 2>/dev/null; }
inner_in_copy_mode() { [ "$(inner_state '#{pane_in_mode}')" = 1 ]; }
tmux -L "$IN" switch-client -c "$(client_name_of_tty "$INNER_TTY")" -t test1
wait_for "[ \"\$(client_session_of_tty $INNER_TTY)\" = test1 ]" || fail "右 pane の client を test1 へ戻せない"
# 内側 (代役) のキー表は -f /dev/null の既定 ($EDITOR に vi を含むと vi になる) に
# 依存させず、送るキーが一意に決まる vi に固定する
tmux -L "$IN" set-option -g mode-keys vi
tmux -L "$IN" send-keys -t test1:0.0 'echo COPY_MODE_MARKER' Enter
wait_for "tmux -L $IN capture-pane -p -t test1:0.0 2>/dev/null | grep -q '^COPY_MODE_MARKER'" \
  || fail "コピー対象のマーカー行を出せない"
tmux -L "$IN" delete-buffer 2>/dev/null

tmux -L "$T" send-keys -t term:0.0 C-b [
wait_for "inner_in_copy_mode" \
  && pass "prefix+[ が外側を素通りして内側がコピーモードに入る" || fail "prefix+[ で内側がコピーモードに入らない"
[ "$(tmux -L "$OUT" display-message -p -t "$(inner_pane_id)" '#{pane_in_mode}')" = 0 ] \
  && pass "外側の pane はコピーモードに入らない (外側はキーを掴まない)" || fail "外側の pane がコピーモードに入った"

# 内側のコピーは OSC52 で内側 client (= 外側の右 pane) へ流れ、外側がそれを実端末 (= T の pane) へ
# 転送する。T の pane 出力を pipe-pane で溜め、実端末に届いたバイト列で照合する
: > "$OSC52_LOG"
tmux -L "$T" pipe-pane -t term:0.0 "cat >> '$OSC52_LOG'" || fail "T の pipe-pane を開始できない"
tmux -L "$T" send-keys -t term:0.0 k
tmux -L "$T" send-keys -t term:0.0 V
wait_for "[ \"\$(inner_state '#{selection_present}')\" = 1 ]" \
  && pass "k / V で行選択ができる" || fail "k / V で行選択ができない ($(inner_state 'cursor=#{copy_cursor_x},#{copy_cursor_y} sel=#{selection_present}'))"
tmux -L "$T" send-keys -t term:0.0 Enter
wait_for "! inner_in_copy_mode" \
  && pass "Enter でコピーしてコピーモードを抜ける" || fail "Enter でコピーモードを抜けない"
[ "$(tmux -L "$IN" show-buffer 2>/dev/null)" = "COPY_MODE_MARKER" ] \
  && pass "内側の paste buffer に選択した行が入る" || fail "内側の paste buffer が選択した行でない ($(tmux -L "$IN" show-buffer 2>&1))"

# 外側の set-clipboard が external だと、pane 内のアプリ (= 内側 tmux) が出す OSC52 を外側が捨てる
# (tmux の input_osc_52 は set-clipboard on 以外で即 return)。on にした退行検出
OSC52_EXPECTED=$(printf 'COPY_MODE_MARKER\n' | base64)
wait_for "grep -q \$'\\033]52;' '$OSC52_LOG'" \
  && pass "コピーの OSC52 が外側を透過して実端末 (T の pane) に届く" \
  || fail "実端末に OSC52 が届かない (外側 set-clipboard=$(tmux -L "$OUT" show-options -gv set-clipboard))"
grep -aoF "]52;;$OSC52_EXPECTED" "$OSC52_LOG" >/dev/null \
  && pass "OSC52 の中身が選択した行の base64" || fail "OSC52 の中身が選択した行でない ($(grep -ao $'\033]52;[^\a]*' "$OSC52_LOG" | tr -d '\033' | head -1))"
tmux -L "$T" pipe-pane -t term:0.0
tmux -L "$IN" set-option -gu mode-keys

echo "=== 5l. マウス: クリックでフォーカスが移り、ホイールは内側へ届く ==="
# 実端末が送るマウスの SGR シーケンス (CSI < ボタン ; 列 ; 行 M/m) を T の pane へ書き込み、
# 外側 client に読ませる。マウスキーは assume-paste の対象外なので押下と解放をまとめて送れる。
# 列は 1 始まりで、サイドバー幅 40 の内側 (5) と右 pane (100) を打ち分ける
mouse_click() { tmux -L "$T" send-keys -l -t term:0.0 "$(printf '\033[<0;%s;%sM\033[<0;%s;%sm' "$1" "$2" "$1" "$2")"; }
mouse_wheel_up() { tmux -L "$T" send-keys -l -t term:0.0 "$(printf '\033[<64;%s;%sM' "$1" "$2")"; }
! active_pane_is_sidebar || fail "5l の前提 (内側フォーカス) が崩れている"
mouse_click 5 5
wait_for "active_pane_is_sidebar" \
  && pass "サイドバーのクリックでフォーカスが左へ移る" || fail "サイドバーをクリックしてもフォーカスが移らない"
mouse_click 100 5
wait_for "! active_pane_is_sidebar" \
  && pass "右 pane のクリックでフォーカスが右へ移る" || fail "右 pane をクリックしてもフォーカスが戻らない"

# 外側は右 pane のアプリ (= 内側 client) がマウスを要求している時だけイベントを転送する。
# 内側 (代役) で mouse を on にすると、既定の WheelUpPane バインドでコピーモードに入るので、
# それをホイールが内側まで届いた証拠にする
tmux -L "$IN" set-option -g mouse on
# 内側 client が外側の右 pane へマウス要求 (DECSET 1000 系) を書くのを待つ
wait_for "[ \"\$(tmux -L $OUT display-message -p -t \"\$(inner_pane_id)\" '#{mouse_any_flag}')\" = 1 ]" \
  && pass "内側の mouse on で右 pane がマウス要求を受ける" || fail "右 pane にマウス要求が届かない"
mouse_wheel_up 100 10
wait_for "inner_in_copy_mode" \
  && pass "右 pane のホイールが内側 tmux に届く (WheelUpPane でコピーモード)" || fail "ホイールが内側に届かない"
tmux -L "$IN" send-keys -t test1:0.0 -X cancel 2>/dev/null
tmux -L "$IN" set-option -gu mouse
wait_for "! inner_in_copy_mode" || fail "5l の後片付け (コピーモードの解除)"

echo "=== 6. 通知の解除 ==="
tmux -L "$IN" set-option -t test2:0.0 -pu @claude-waiting || fail "@claude-waiting の解除"
sidebar_shows '通知なし' && pass "解除で「通知なし」に戻る" || fail "解除しても「通知なし」に戻らない"

echo "=== 6a. 名前で target にできない session へもジャンプできる ==="
# tmux は %/$/@ で始まる target を pane/session/window の ID として解釈するため、
# その形の session 名は名前では引けない (has-session -t '%odd' は can't find pane)。
# switch-client には名前ではなく #{session_id} を渡す必要がある。
# . と : は new-session が _ へ均すため、この形が実際に起こり得る唯一の衝突
ODD_SESSION='%odd-session'
ODD_PANE=$(tmux -L "$IN" new-session -d -s "$ODD_SESSION" -n odd -P -F '#{pane_id}' -x 200 -y 50 \
  'echo ODD_MARKER; exec sh') || fail "名前で引けない session の作成"
ODD_ID=$(tmux -L "$IN" display-message -p -t "$ODD_PANE" '#{session_id}')
tmux -L "$IN" has-session -t "$ODD_SESSION" 2>/dev/null \
  && fail "前提が崩れている (名前で引けてしまう)" || pass "この session 名は tmux が名前で引けない"
tmux -L "$IN" set-option -t "$ODD_PANE" -p @claude-waiting '🔔12:00' || fail "通知の set"
sidebar_shows "▸ $ODD_SESSION (1)" \
  && pass "名前で引けない session の見出しが出る" || fail "見出しが出ない"

tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" || fail "6a のためのフォーカス移動"
tmux -L "$T" send-keys -t term:0.0 Enter
wait_for "[ \"\$(client_session_of_tty $INNER_TTY)\" = '$ODD_SESSION' ]" \
  && pass "名前で引けない session へジャンプできる (session ID 指定)" \
  || fail "名前で引けない session へジャンプできない"
tmux -L "$T" send-keys -t term:0.0 q
wait_for "! active_pane_is_sidebar" || fail "6a 後のフォーカス復帰"
tmux -L "$IN" switch-client -c "$(client_name_of_tty "$INNER_TTY")" -t test1
tmux -L "$IN" kill-session -t "$ODD_ID" 2>/dev/null
sidebar_shows '通知なし' || fail "6a の後片付け"

echo "=== 6b. 複数 pane の window では通知元 pane をプレビューする ==="
# @claude-waiting は通知元 pane (-p) と window (-w) の両方に set され、window option は
# 同じ window の全 pane へ継承される。先頭 pane を代表にすると別 pane を映してしまう
tmux -L "$IN" new-window -d -t test2 -n multi 'echo NOT_ORIGIN_MARKER; exec sh' \
  || fail "複数 pane 検証用 window の作成"
tmux -L "$IN" split-window -d -t test2:multi 'echo ORIGIN_PANE_MARKER; exec sh' \
  || fail "複数 pane 検証用 pane の作成"
tmux -L "$IN" set-option -t test2:multi.1 -p @claude-waiting '🔔11:00' || fail "通知元 pane への set"
tmux -L "$IN" set-option -t test2:multi -w @claude-waiting '🔔11:00' || fail "window への set"

sidebar_shows 'ORIGIN_PANE_MARKER' \
  && pass "通知元 pane のプレビューが出る" || fail "通知元 pane のプレビューが出ない"
sidebar_hides 'NOT_ORIGIN_MARKER' \
  && pass "同じ window の別 pane を映していない" || fail "通知元でない pane を映している"
tmux -L "$IN" kill-window -t test2:multi 2>/dev/null
sidebar_shows '通知なし' || fail "6b の後片付け"

echo "=== 6c. detach 等で消えた内側 pane を start が作り直す ==="
# 内側で prefix+d すると右 pane の attach プロセスが終わり pane だけが消える。
# サイドバーは残るため、次の start が「構築済み」と誤認して素通りしないこと
tmux -L "$OUT" kill-pane -t "$(inner_pane_id)" 2>/dev/null
wait_for "[ \"\$(outer_panes)\" = 1 ]" \
  && pass "内側 pane が消えるとサイドバーだけが残る" || fail "内側 pane を消せない"
suzu start >/dev/null 2>&1
wait_for "[ \"\$(outer_panes)\" = 2 ]" \
  && pass "start が消えた内側 pane を作り直す" || fail "start が内側 pane を作り直さない"
inner_pane_shows '[test' \
  && pass "作り直した内側 pane が内側 tmux へ attach する" || fail "作り直した内側 pane が attach しない"
wait_for "[ \"\$(tmux -L $OUT display-message -p -t \"\$(sidebar_pane)\" '#{pane_width}')\" = 40 ]" \
  && pass "再作成後もサイドバー幅が 40 に戻る" || fail "再作成後のサイドバー幅が戻らない"

echo "=== 7. stop は自分が入れたものだけを片付ける ==="
tmux -L "$T" kill-server 2>/dev/null
# ユーザー自身の bind と after-set-option hook。stop がこれらを巻き込まないこと
tmux -L "$IN" bind-key Z display-message 'USER_BIND_MARKER' || fail "ユーザー bind の仕込み"
tmux -L "$IN" set-hook -ga after-set-option "run-shell -b 'true USER_HOOK_MARKER'" \
  || fail "ユーザー hook の仕込み"
# 外側 socket に相乗りした無関係な session。kill-server だとこれも巻き添えで落ちる
tmux -L "$OUT" new-session -d -s bystander -x 80 -y 24 'exec sh' || fail "相乗り session の作成"

suzu start >/dev/null 2>&1
[ "$(doorbell_hook_count)" = 1 ] \
  && pass "start を重ねても doorbell hook は 1 つ (set-hook -ga が冪等)" \
  || fail "doorbell hook が重複している ($(doorbell_hook_count) 個)"

suzu stop >/dev/null
tmux -L "$OUT" has-session -t suzu 2>/dev/null \
  && fail "stop 後も外側の suzu session が残っている" || pass "stop で外側の suzu session が消えた"
tmux -L "$OUT" has-session -t bystander 2>/dev/null \
  && pass "同じ socket の無関係な session は残る (kill-server していない)" \
  || fail "無関係な session まで落とした"
tmux -L "$OUT" kill-server 2>/dev/null
tmux -L "$IN" has-session -t test1 2>/dev/null \
  && pass "内側 server は無傷" || fail "内側 server が巻き添えで死んだ"
inner_key_installed N \
  && fail "stop 後もジャンプキーが残っている" || pass "stop でジャンプキー (prefix+N) が解除された"
inner_key_installed b \
  && fail "stop 後も toggle キーが残っている" || pass "stop で toggle キー (prefix+b) が解除された"
[ "$(doorbell_hook_count)" = 0 ] \
  && pass "stop で doorbell hook が解除された" || fail "stop 後も doorbell hook が残っている"
tmux -L "$IN" list-keys -T prefix 2>/dev/null | grep -E "^bind-key +(-r +)?-T +prefix +Z " | grep -q USER_BIND_MARKER \
  && pass "ユーザー自身の bind は残る" || fail "ユーザー自身の bind まで消した"
tmux -L "$IN" show-hooks -g after-set-option 2>/dev/null | grep -q USER_HOOK_MARKER \
  && pass "ユーザー自身の after-set-option hook は残る" || fail "ユーザー自身の hook まで消した"
tmux -L "$IN" unbind-key Z 2>/dev/null

echo "=== 7b. suzu のものでない bind は stop で触らず、上書き時は警告する ==="
tmux -L "$IN" bind-key N display-message 'USER_JUMP_MARKER' || fail "ユーザーのジャンプキー bind の仕込み"
suzu stop >/dev/null
tmux -L "$IN" list-keys -T prefix 2>/dev/null | grep -E "^bind-key +(-r +)?-T +prefix +N " | grep -q USER_JUMP_MARKER \
  && pass "suzu のものでない prefix+N は stop で消さない" || fail "ユーザーの prefix+N を消した"

WARN=$(suzu start 2>&1 >/dev/null)
echo "$WARN" | grep -q '既存の bind' \
  && pass "既存 bind を上書きする時は警告する" || fail "上書きの警告が出ない"
inner_key_installed N \
  && pass "警告した上で suzu のバインドを入れる" || fail "警告するだけで上書きしていない"
WARN=$(suzu start 2>&1 >/dev/null)
echo "$WARN" | grep -q '既存の bind' \
  && fail "自分が入れた bind にも警告している" || pass "自分が入れた bind には警告しない"
suzu stop >/dev/null
tmux -L "$OUT" kill-server 2>/dev/null

echo "=== 8. tty から起動した時の attach と二重ネストのガード ==="
# 非 tty の start は attach しないため、実端末から使う経路 (exec で tmux へ置き換わる) は
# ここでしか通らない。$TMUX を外した pane 内で起動して再現する
start_terminal_stand_in 40 \
  "env -u TMUX SUZU_OUTER_SOCKET='$OUT' SUZU_INNER_TMUX='tmux -L $IN' SUZU_INNER_TMUX_CMD='tmux -L $IN attach -t test1' SUZU_DOORBELL_FILE='$DOORBELL' SUZU_CONFIG_FILE='$CONFIG_FILE' SUZU_SCRAPE_INTERVAL=1 '$SUZU_BIN' start" \
  || fail "tty 付き start のための端末代役の起動"
wait_for "[ \"\$(outer_panes)\" = 2 ]" \
  && pass "tty から start すると額縁が構築される" || fail "tty から start しても額縁ができない"
wait_for "tmux -L $T capture-pane -p -t term:0.0 2>/dev/null | grep -q Noroshi" \
  && pass "start が外側へ attach してサイドバーが見える" || fail "start が外側へ attach しない"

# tmux の中から start すると外側が二重にネストするため、エラーで止まること
tmux -L "$T" new-window -d -t term -n guard \
  "SUZU_OUTER_SOCKET='$OUT' '$SUZU_BIN' start; echo GUARD_EXIT=\$?; sleep 60"
wait_for "tmux -L $T capture-pane -p -t term:guard 2>/dev/null | grep -q 'GUARD_EXIT=1'" \
  && pass "tmux の中からの start はエラーで止まる" || fail "tmux の中からの start が素通りした"

suzu stop >/dev/null
tmux -L "$OUT" has-session 2>/dev/null \
  && fail "8 の後片付けで外側 server が残っている" || pass "8 の後片付けで外側 server が消えた"

echo "=== 9. 壊れた socket からの自己修復 ==="
# 任意の socket 名で suzu を実行する (内側は $IN を使い回す)
suzu_on_socket() {
  local socket="$1"; shift
  SUZU_OUTER_SOCKET="$socket" \
  SUZU_INNER_TMUX="tmux -L $IN" \
  SUZU_INNER_TMUX_CMD="tmux -L $IN attach -t test1" \
  SUZU_DOORBELL_FILE="$DOORBELL" \
  SUZU_CONFIG_FILE="$CONFIG_FILE" \
  SUZU_SCRAPE_INTERVAL=1 \
    "$SUZU_BIN" "$@" </dev/null
}
panes_on() { tmux -L "$1" list-panes -t suzu:0 2>/dev/null | wc -l | tr -d ' '; }

# server プロセスを SIGKILL して socket ファイルだけ残った状態
tmux -L "$STALE" -f /dev/null new-session -d -s dummy -x 80 -y 24 'exec sh' || fail "使い捨て server の起動"
kill -9 "$(tmux -L "$STALE" display-message -p '#{pid}')" 2>/dev/null
wait_for "! tmux -L $STALE has-session 2>/dev/null" || fail "使い捨て server が死なない"
[ -e "$(socket_path "$STALE")" ] \
  && pass "SIGKILL 後も socket ファイルが残る" || fail "socket ファイルが残らず前提が崩れている"
suzu_on_socket "$STALE" start >/dev/null 2>&1
wait_for "[ \"\$(panes_on $STALE)\" = 2 ]" \
  && pass "残った socket ファイルがあっても start できる" || fail "残った socket ファイルで start できない"
suzu_on_socket "$STALE" stop >/dev/null 2>&1

# socket のパスが socket でないファイルで塞がれた状態。
# tmux はこれを自分で片付けられず "Socket operation on non-socket" で起動に失敗する
tmux -L "$BROKEN" -f /dev/null new-session -d -s dummy -x 80 -y 24 'exec sh' || fail "使い捨て server の起動"
kill -9 "$(tmux -L "$BROKEN" display-message -p '#{pid}')" 2>/dev/null
wait_for "! tmux -L $BROKEN has-session 2>/dev/null" || fail "使い捨て server が死なない"
rm -f "$(socket_path "$BROKEN")" && : > "$(socket_path "$BROKEN")"
# この状態は macOS 固有 (connect が ENOTSOCK で失敗し tmux はファイルを残す)。Linux では
# connect が ECONNREFUSED になり tmux 自身がファイルを unlink して起動できてしまうため、
# suzu の自己修復の出番が無い。起動できた OS では検査を飛ばす
if tmux -L "$BROKEN" -f /dev/null new-session -d -s probe -x 80 -y 24 'exec sh' 2>/dev/null; then
  pass "この OS では素の tmux が壊れた socket ファイルを自分で片付ける (suzu の自己修復は対象外)"
  tmux -L "$BROKEN" kill-server 2>/dev/null
else
  pass "壊れた socket では素の tmux が起動できない"
  BROKEN_OUT=$(suzu_on_socket "$BROKEN" start 2>&1)
  echo "$BROKEN_OUT" | grep -q '取り除いて起動し直しました' \
    && pass "壊れた socket を取り除いた旨を報告する" || fail "自己修復の報告が出ない"
  wait_for "[ \"\$(panes_on $BROKEN)\" = 2 ]" \
    && pass "壊れた socket を自己修復して額縁を構築できる" || fail "壊れた socket から復旧できない"
  suzu_on_socket "$BROKEN" stop >/dev/null 2>&1
fi

# 修復できない時は tmux の stderr と対処ヒントを添えて失敗する。
# 中身のあるディレクトリなら suzu の unlink も失敗し、再試行できない状態を作れる
rm -f "$(socket_path "$BROKEN")"
mkdir -p "$(socket_path "$BROKEN")/occupied"
UNFIXABLE=$(suzu_on_socket "$BROKEN" start 2>&1)
# tmux の stderr は OS で文言が変わる (macOS: Socket operation on non-socket、
# Linux: unlink や connect の別の errno) ため、tmux が失敗理由に必ず含める socket のパスで判定する
echo "$UNFIXABLE" | grep -qF "$(socket_path "$BROKEN")" \
  && pass "失敗時に tmux の stderr が出る" || fail "tmux の stderr が握りつぶされている ($UNFIXABLE)"
echo "$UNFIXABLE" | grep -q 'ps ax | grep' \
  && pass "失敗時に残骸の調べ方を案内する" || fail "対処ヒントが出ない"
rmdir "$(socket_path "$BROKEN")/occupied" "$(socket_path "$BROKEN")" 2>/dev/null

echo
if [ "$FAIL" = 0 ]; then
  echo "RESULT: ALL PASS"
else
  echo "RESULT: FAILED"
fi
exit "$FAIL"
