#!/usr/bin/env bash
# issue #67 Phase 0: nested tmux スパイクの自動検証
#
# 普段の tmux (default socket) には一切触れず、隔離 socket を 3 つ使って検証する:
#   IN  = 内側 tmux の代役 (隔離 socket, -f /dev/null)
#   OUT = noroshi-outer が構築する外側 (隔離 socket 名を環境変数で注入)
#   T   = ターミナルエミュレータの代役。pane 内で外側へ attach し、send-keys で
#         「実端末からのキー入力 → 外側の key table → 内側」の経路を再現する
#
# 実行: bash tui-spike/verify.sh
# 全項目 PASS で exit 0。キー入力の実機経路 (IME・コピーモード・マウス・OSC52) は
# 対象外で、ユーザーの手動検証に委ねる。
set -u

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IN="nrv-in-$$"
OUT="nrv-out-$$"
T="nrv-term-$$"
FAIL=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

cleanup() {
  tmux -L "$T" kill-server 2>/dev/null
  tmux -L "$OUT" kill-server 2>/dev/null
  tmux -L "$IN" kill-server 2>/dev/null
}
trap cleanup EXIT

# cond コマンドが真になるまで最大 50 x 0.2 秒待つ
wait_for() {
  local i
  for i in $(seq 1 50); do
    eval "$1" && return 0
    sleep 0.2
  done
  return 1
}

echo "=== 1. 内側 (代役) server を隔離 socket で起動 ==="
tmux -L "$IN" -f /dev/null new-session -d -s inner -x 200 -y 50 \
  'echo INNER_READY_MARKER; exec sh' || fail "内側 server の起動"
wait_for "tmux -L $IN capture-pane -p -t inner:0.0 2>/dev/null | grep -q INNER_READY_MARKER" \
  && pass "内側 server 起動" || fail "内側 server 起動"

echo "=== 2. noroshi-outer start で外側を構築 (非 tty なので attach はしない) ==="
# 本スクリプトは Phase 0 (額縁 + プレースホルダ) の検証。tui-sidebar のバイナリが
# ビルド済みだと noroshi-outer がそちらを採用してしまうため、プレースホルダを明示的に固定する
PLACEHOLDER_CMD="NOROSHI_OUTER_SOCKET='$OUT' bash '$SPIKE_DIR/sidebar-placeholder.sh'"
NOROSHI_OUTER_SOCKET="$OUT" \
NOROSHI_INNER_TMUX="tmux -L $IN" \
NOROSHI_INNER_TMUX_CMD="tmux -L $IN attach -t inner" \
NOROSHI_SIDEBAR_CMD="$PLACEHOLDER_CMD" \
  bash "$SPIKE_DIR/noroshi-outer" start </dev/null || fail "noroshi-outer start"

wait_for "[ \"\$(tmux -L $OUT list-panes -t noroshi:0 2>/dev/null | wc -l | tr -d ' ')\" = 2 ]" \
  && pass "外側 window が左右 2 pane" || fail "外側 window が左右 2 pane"

wait_for "tmux -L $OUT capture-pane -p -t noroshi:0.1 2>/dev/null | grep -q INNER_READY_MARKER" \
  && pass "右 pane に内側 tmux の内容が描画される" || fail "右 pane に内側 tmux の内容が描画される"

[ "$(tmux -L "$OUT" show-options -gv prefix)" = "None" ] \
  && pass "外側の prefix は None (キーを掴まない)" || fail "外側の prefix は None"
[ "$(tmux -L "$OUT" show-options -gv status)" = "off" ] \
  && pass "外側の status は off" || fail "外側の status は off"

echo "=== 3. 冪等性: start を再実行しても pane が増えない ==="
NOROSHI_OUTER_SOCKET="$OUT" \
NOROSHI_INNER_TMUX="tmux -L $IN" \
NOROSHI_INNER_TMUX_CMD="tmux -L $IN attach -t inner" \
NOROSHI_SIDEBAR_CMD="$PLACEHOLDER_CMD" \
  bash "$SPIKE_DIR/noroshi-outer" start </dev/null >/dev/null 2>&1
[ "$(tmux -L "$OUT" list-panes -t noroshi:0 | wc -l | tr -d ' ')" = 2 ] \
  && pass "start は冪等 (2 pane のまま)" || fail "start は冪等"

tmux -L "$IN" list-keys -T prefix N 2>/dev/null | grep -q noroshi-outer \
  && pass "内側に prefix+N のジャンプキーが注入されている" || fail "内側へのジャンプキー注入"

echo "=== 4. 実キー経路: 端末代役 T から prefix キーが内側まで届く ==="
tmux -L "$T" -f /dev/null new-session -d -s term -x 220 -y 60 \
  "TMUX= tmux -L $OUT attach -t noroshi" || fail "端末代役 T の起動"
wait_for "tmux -L $T capture-pane -p -t term:0.0 2>/dev/null | grep -q INNER_READY_MARKER" \
  && pass "T → 外側 → 内側の描画チェーン成立" || fail "T → 外側 → 内側の描画チェーン成立"

# 内側 (代役) の prefix は C-b (-f /dev/null のデフォルト)。C-b c で内側に window が増えれば、
# キーが「T の pane → 外側 client → 外側 server (素通し) → 内側 client → 内側 server」を通った証拠
tmux -L "$T" send-keys -t term:0.0 C-b c
wait_for "[ \"\$(tmux -L $IN list-windows -t inner 2>/dev/null | wc -l | tr -d ' ')\" = 2 ]" \
  && pass "prefix (C-b c) が外側を素通りして内側に window が増えた" \
  || fail "prefix (C-b c) が内側に届かない"

echo "=== 4b. キーボードで左右フォーカス移動 ==="
active_pane_is_sidebar() {
  [ "$(tmux -L "$OUT" list-panes -t noroshi:0 -f '#{pane_active}' -F '#{@noroshi-sidebar}')" = 1 ]
}
# 内側 (代役) の prefix は C-b。注入された prefix+N で内側 → サイドバーへ移る
tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" \
  && pass "prefix+N でサイドバーへフォーカスが移る" || fail "prefix+N でサイドバーへフォーカスが移らない"
# サイドバー (プレースホルダ) は何かキーで内側へ戻す
tmux -L "$T" send-keys -t term:0.0 x
wait_for "! active_pane_is_sidebar" \
  && pass "サイドバーで何かキーを押すと内側へフォーカスが戻る" || fail "サイドバーから内側へフォーカスが戻らない"

echo "=== 5. サイドバーのトグル ==="
NOROSHI_OUTER_SOCKET="$OUT" NOROSHI_SIDEBAR_CMD="$PLACEHOLDER_CMD" bash "$SPIKE_DIR/noroshi-outer" toggle </dev/null
[ "$(tmux -L "$OUT" list-panes -t noroshi:0 | wc -l | tr -d ' ')" = 1 ] \
  && pass "toggle でサイドバーが閉じる (1 pane)" || fail "toggle でサイドバーが閉じる"

NOROSHI_OUTER_SOCKET="$OUT" NOROSHI_SIDEBAR_CMD="$PLACEHOLDER_CMD" bash "$SPIKE_DIR/noroshi-outer" toggle </dev/null
[ "$(tmux -L "$OUT" list-panes -t noroshi:0 | wc -l | tr -d ' ')" = 2 ] \
  && pass "toggle でサイドバーが再表示 (2 pane)" || fail "toggle でサイドバーが再表示"

active_is_inner=$(tmux -L "$OUT" list-panes -t noroshi:0 -F '#{pane_active} #{@noroshi-sidebar}' | grep '^1' | awk '{print $2}')
[ -z "$active_is_inner" ] \
  && pass "再表示後もフォーカスは内側 pane のまま" || fail "再表示後のフォーカスがサイドバーに移った"

# 手順 4 で内側は新 window (空シェル) に切り替わっているため、マーカーではなく
# 内側 tmux の status line ("[inner]") が描画されていることで attach 生存を確認する
inner_pane=$(tmux -L "$OUT" list-panes -t noroshi:0 -f '#{?#{@noroshi-sidebar},0,1}' -F '#{pane_id}')
wait_for "tmux -L $OUT capture-pane -p -t $inner_pane 2>/dev/null | grep -qF '[inner]'" \
  && pass "トグル後も内側 attach が生きている" || fail "トグル後に内側 attach が切れた"

echo "=== 6. stop は外側と注入キーだけを片付ける ==="
tmux -L "$T" kill-server 2>/dev/null
NOROSHI_OUTER_SOCKET="$OUT" NOROSHI_INNER_TMUX="tmux -L $IN" \
  bash "$SPIKE_DIR/noroshi-outer" stop </dev/null >/dev/null
tmux -L "$OUT" has-session 2>/dev/null \
  && fail "stop 後も外側 server が残っている" || pass "stop で外側 server が消えた"
tmux -L "$IN" has-session -t inner 2>/dev/null \
  && pass "内側 server は無傷" || fail "内側 server が巻き添えで死んだ"
tmux -L "$IN" list-keys -T prefix N 2>/dev/null | grep -q noroshi-outer \
  && fail "stop 後も注入キーが残っている" || pass "stop で注入キー (prefix+N) が解除された"

echo
if [ "$FAIL" = 0 ]; then
  echo "RESULT: ALL PASS"
else
  echo "RESULT: FAILED"
fi
exit "$FAIL"
