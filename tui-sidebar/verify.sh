#!/usr/bin/env bash
# issue #67 Phase 1: サイドバー TUI の自動検証
#
# tui-spike/verify.sh と同じく、普段の tmux (default socket) には一切触れず隔離 socket を
# 3 つ使う:
#   IN  = 内側 tmux の代役 (隔離 socket, -f /dev/null)。session test1 / test2 を持つ
#   OUT = noroshi-outer が構築する外側 (隔離 socket 名を環境変数で注入)
#   T   = ターミナルエミュレータの代役。pane 内で外側へ attach し、send-keys で
#         「実端末からのキー入力 → 外側 → サイドバー TUI」の経路を再現する
#
# 実行: bash tui-sidebar/verify.sh
# 全項目 PASS で exit 0。
set -u

SIDEBAR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPIKE_DIR="$SIDEBAR_DIR/../tui-spike"
TMP_DIR="$SIDEBAR_DIR/../tmp"
IN="nsv-in-$$"
OUT="nsv-out-$$"
T="nsv-term-$$"
DOORBELL_DIR="$TMP_DIR/phase1-doorbell-$$"
DOORBELL="$DOORBELL_DIR/doorbell"
FAIL=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

cleanup() {
  tmux -L "$T" kill-server 2>/dev/null
  tmux -L "$OUT" kill-server 2>/dev/null
  tmux -L "$IN" kill-server 2>/dev/null
  rm -rf "$DOORBELL_DIR"
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

sidebar_pane() {
  tmux -L "$OUT" list-panes -t noroshi:0 -f '#{@noroshi-sidebar}' -F '#{pane_id}' 2>/dev/null | head -1
}

# サイドバー pane の描画に pattern が現れるまで待つ
sidebar_shows() {
  wait_for "tmux -L $OUT capture-pane -p -t \"\$(sidebar_pane)\" 2>/dev/null | grep -qF -- '$1'"
}

active_pane_is_sidebar() {
  [ "$(tmux -L "$OUT" list-panes -t noroshi:0 -f '#{pane_active}' -F '#{@noroshi-sidebar}')" = 1 ]
}

# control mode client (サイドバーの購読) を除いた、実端末に繋がった内側 client の session
inner_real_client_session() {
  tmux -L "$IN" list-clients -f '#{?#{==:#{client_control_mode},1},0,1}' -F '#{client_session}' 2>/dev/null | head -1
}

# 未設定の hook も show-hooks には名前だけ並ぶため、値が入った時だけ現れる
# 添字付きの表記 (after-set-option[0]) で判定する
inner_hook_installed() {
  tmux -L "$IN" show-hooks -g 2>/dev/null | grep -q 'after-set-option\['
}

echo "=== 1. サイドバー TUI をビルド ==="
mkdir -p "$TMP_DIR"
if (cd "$SIDEBAR_DIR" && go build -o bin/noroshi-sidebar .); then
  pass "go build"
else
  fail "go build"
  echo "RESULT: FAILED"
  exit 1
fi

echo "=== 2. 内側 (代役) server を隔離 socket で起動 (test1 / test2) ==="
tmux -L "$IN" -f /dev/null new-session -d -s test1 -x 200 -y 50 \
  'echo INNER_READY_MARKER; exec sh' || fail "内側 session test1 の起動"
tmux -L "$IN" new-session -d -s test2 -n claude-work -x 200 -y 50 'exec sh' \
  || fail "内側 session test2 の起動"
wait_for "tmux -L $IN capture-pane -p -t test1:0.0 2>/dev/null | grep -q INNER_READY_MARKER" \
  && pass "内側 server 起動 (test1 / test2)" || fail "内側 server 起動"

echo "=== 3. noroshi-outer start でサイドバー TUI 付きの外側を構築 ==="
NOROSHI_OUTER_SOCKET="$OUT" \
NOROSHI_INNER_TMUX="tmux -L $IN" \
NOROSHI_INNER_TMUX_CMD="tmux -L $IN attach -t test1" \
NOROSHI_DOORBELL_FILE="$DOORBELL" \
  bash "$SPIKE_DIR/noroshi-outer" start </dev/null || fail "noroshi-outer start"

sidebar_shows 'Noroshi' && pass "サイドバーに Noroshi が描画される" \
  || fail "サイドバーに Noroshi が描画されない"
sidebar_shows '通知なし' && pass "通知が無い時は「通知なし」" || fail "「通知なし」が描画されない"

inner_hook_installed \
  && pass "内側に after-set-option hook が注入されている" || fail "after-set-option hook の注入"

echo "=== 4. 非 attach session (test2) の通知が push で届く ==="
tmux -L "$IN" set-option -t test2:0.0 -p @claude-waiting '🔔09:00' || fail "@claude-waiting の set"
sidebar_shows 'test2:0 claude-work' \
  && pass "非 attach session の通知行が出る (cross-session の push 経路)" \
  || fail "非 attach session の通知行が出ない"
sidebar_shows '🔔' && pass "アイコンが描画される" || fail "アイコンが描画されない"
sidebar_shows 'Noroshi 🔔1' && pass "件数表示が 1" || fail "件数表示が 1 にならない"

echo "=== 5. 実キー経路: prefix+N でサイドバーへ → Enter でジャンプ ==="
tmux -L "$T" -f /dev/null new-session -d -s term -x 220 -y 60 \
  "TMUX= tmux -L $OUT attach -t noroshi" || fail "端末代役 T の起動"
wait_for "tmux -L $T capture-pane -p -t term:0.0 2>/dev/null | grep -q INNER_READY_MARKER" \
  && pass "T → 外側 → 内側の描画チェーン成立" || fail "T → 外側 → 内側の描画チェーン成立"

tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" \
  && pass "prefix+N でサイドバーへフォーカスが移る" || fail "prefix+N でサイドバーへフォーカスが移らない"

tmux -L "$T" send-keys -t term:0.0 Enter
wait_for "[ \"\$(inner_real_client_session)\" = test2 ]" \
  && pass "Enter で内側の実 client が test2 へジャンプ" || fail "Enter で内側の実 client がジャンプしない"
wait_for "! active_pane_is_sidebar" \
  && pass "ジャンプ後にフォーカスが内側 pane へ戻る" || fail "ジャンプ後にフォーカスが戻らない"

echo "=== 6. 通知の解除 ==="
tmux -L "$IN" set-option -t test2:0.0 -pu @claude-waiting || fail "@claude-waiting の解除"
sidebar_shows '通知なし' && pass "解除で「通知なし」に戻る" || fail "解除しても「通知なし」に戻らない"

echo "=== 7. stop は外側と注入したキー・hook だけを片付ける ==="
tmux -L "$T" kill-server 2>/dev/null
NOROSHI_OUTER_SOCKET="$OUT" NOROSHI_INNER_TMUX="tmux -L $IN" NOROSHI_DOORBELL_FILE="$DOORBELL" \
  bash "$SPIKE_DIR/noroshi-outer" stop </dev/null >/dev/null
tmux -L "$OUT" has-session 2>/dev/null \
  && fail "stop 後も外側 server が残っている" || pass "stop で外側 server が消えた"
tmux -L "$IN" has-session -t test2 2>/dev/null \
  && pass "内側 server は無傷" || fail "内側 server が巻き添えで死んだ"
tmux -L "$IN" list-keys -T prefix N 2>/dev/null | grep -q noroshi-outer \
  && fail "stop 後も注入キーが残っている" || pass "stop で注入キー (prefix+N) が解除された"
inner_hook_installed \
  && fail "stop 後も after-set-option hook が残っている" || pass "stop で after-set-option hook が解除された"

echo
if [ "$FAIL" = 0 ]; then
  echo "RESULT: ALL PASS"
else
  echo "RESULT: FAILED"
fi
exit "$FAIL"
