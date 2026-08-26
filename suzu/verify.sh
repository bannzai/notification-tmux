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
# 全項目 PASS で exit 0。キー入力の実機経路 (IME・コピーモード・マウス・OSC52) は
# 対象外で、ユーザーの手動検証に委ねる。
set -u

SUZU_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUZU_BIN="$SUZU_DIR/bin/suzu"
TMP_DIR="$SUZU_DIR/../tmp"
IN="szv-in-$$"
OUT="szv-out-$$"
T="szv-term-$$"
X="szv-extra-$$"
DOORBELL_DIR="$TMP_DIR/phase2-doorbell-$$"
DOORBELL="$DOORBELL_DIR/doorbell"
FAIL=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

cleanup() {
  tmux -L "$T" kill-server 2>/dev/null
  tmux -L "$X" kill-server 2>/dev/null
  tmux -L "$OUT" kill-server 2>/dev/null
  tmux -L "$IN" kill-server 2>/dev/null
  rm -rf "$DOORBELL_DIR"
}
trap cleanup EXIT

# suzu を隔離 socket 向けの環境で実行する
suzu() {
  SUZU_OUTER_SOCKET="$OUT" \
  SUZU_INNER_TMUX="tmux -L $IN" \
  SUZU_INNER_TMUX_CMD="tmux -L $IN attach -t test1" \
  SUZU_DOORBELL_FILE="$DOORBELL" \
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

# 未設定の hook も show-hooks には名前だけ並ぶため、値が入った時だけ現れる
# 添字付きの表記 (after-set-option[0]) で判定する
inner_hook_installed() {
  tmux -L "$IN" show-hooks -g 2>/dev/null | grep -q 'after-set-option\['
}

inner_key_installed() {
  tmux -L "$IN" list-keys -T prefix "$1" 2>/dev/null | grep -qF -- "$SUZU_BIN"
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
suzu start >/dev/null 2>&1
[ "$(outer_panes)" = 2 ] && pass "start は冪等 (2 pane のまま)" || fail "start は冪等"

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

echo "=== 5b. prefix+N でサイドバーへ → Enter でジャンプ ==="
INNER_TTY=$(inner_pane_tty)
tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" \
  && pass "prefix+N でサイドバーへフォーカスが移る" || fail "prefix+N でサイドバーへフォーカスが移らない"
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
# 2 件目 (test1) を足す。list-panes -a は session 順なので test1 がカーソル 0 に来る
tmux -L "$IN" set-option -t test1:0.0 -p @claude-waiting '🔔09:30' || fail "2 件目の @claude-waiting の set"
sidebar_shows 'Noroshi 🔔2' && pass "件数表示が 2" || fail "件数表示が 2 にならない"
sidebar_shows 'INNER_READY_MARKER' \
  && pass "カーソル 0 (test1) のプレビューに切り替わる" || fail "カーソル 0 のプレビューが切り替わらない"

tmux -L "$T" send-keys -t term:0.0 C-b N
wait_for "active_pane_is_sidebar" || fail "プレビュー検証のためのフォーカス移動"
tmux -L "$T" send-keys -t term:0.0 j
sidebar_shows 'PREVIEW_TEST2_MARKER' \
  && pass "j で選択を下げるとプレビューが test2 の pane に変わる" \
  || fail "j でプレビューが切り替わらない"
tmux -L "$T" send-keys -t term:0.0 k
sidebar_shows 'INNER_READY_MARKER' \
  && pass "k で選択を戻すとプレビューも戻る" || fail "k でプレビューが戻らない"
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
tmux -L "$T" send-keys -t term:0.0 C-b b
wait_for "[ \"\$(outer_panes)\" = 1 ]" \
  && pass "prefix+b でサイドバーが閉じる (1 pane)" || fail "prefix+b で閉じない"
tmux -L "$T" send-keys -t term:0.0 C-b b
wait_for "[ \"\$(outer_panes)\" = 2 ]" \
  && pass "prefix+b でサイドバーが再表示 (2 pane)" || fail "prefix+b で再表示されない"
sidebar_shows '▸ test1' \
  && pass "再表示後も通知一覧を取得できている" || fail "再表示後のサイドバーが通知を出せない"

suzu toggle
wait_for "[ \"\$(outer_panes)\" = 1 ]" \
  && pass "suzu toggle でサイドバーが閉じる (1 pane)" || fail "suzu toggle で閉じない"
suzu toggle
wait_for "[ \"\$(outer_panes)\" = 2 ]" \
  && pass "suzu toggle でサイドバーが再表示 (2 pane)" || fail "suzu toggle で再表示されない"
! active_pane_is_sidebar \
  && pass "再表示後もフォーカスは内側 pane のまま" || fail "再表示後のフォーカスがサイドバーに移った"
inner_pane_shows '[test' \
  && pass "トグル後も内側 attach が生きている" || fail "トグル後に内側 attach が切れた"

echo "=== 5h. 画面が狭い時のスクロール ==="
for i in 1 2 3 4 5 6 7 8; do
  tmux -L "$IN" new-window -d -t test1 -n "w$i" 'exec sh' || fail "スクロール検証用 window の作成"
  tmux -L "$IN" set-option -t "test1:w$i.0" -p @claude-waiting '🔔' || fail "スクロール検証用の通知 set"
done
# 端末代役を低い高さで作り直す (外側は最後に使われた client のサイズに合わせる)
tmux -L "$T" kill-server 2>/dev/null
tmux -L "$T" -f /dev/null new-session -d -s term -x 220 -y 18 \
  "TMUX= tmux -L $OUT attach -t suzu" || fail "低い端末代役の起動"
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

echo "=== 6. 通知の解除 ==="
tmux -L "$IN" set-option -t test2:0.0 -pu @claude-waiting || fail "@claude-waiting の解除"
sidebar_shows '通知なし' && pass "解除で「通知なし」に戻る" || fail "解除しても「通知なし」に戻らない"

echo "=== 7. stop は外側と注入したキー・hook だけを片付ける ==="
tmux -L "$T" kill-server 2>/dev/null
suzu stop >/dev/null
tmux -L "$OUT" has-session 2>/dev/null \
  && fail "stop 後も外側 server が残っている" || pass "stop で外側 server が消えた"
tmux -L "$IN" has-session -t test1 2>/dev/null \
  && pass "内側 server は無傷" || fail "内側 server が巻き添えで死んだ"
inner_key_installed N \
  && fail "stop 後もジャンプキーが残っている" || pass "stop でジャンプキー (prefix+N) が解除された"
inner_key_installed b \
  && fail "stop 後も toggle キーが残っている" || pass "stop で toggle キー (prefix+b) が解除された"
inner_hook_installed \
  && fail "stop 後も after-set-option hook が残っている" || pass "stop で after-set-option hook が解除された"

echo "=== 8. tty から起動した時の attach と二重ネストのガード ==="
# 非 tty の start は attach しないため、実端末から使う経路 (exec で tmux へ置き換わる) は
# ここでしか通らない。$TMUX を外した pane 内で起動して再現する
tmux -L "$T" -f /dev/null new-session -d -s term -x 220 -y 40 \
  "env -u TMUX SUZU_OUTER_SOCKET='$OUT' SUZU_INNER_TMUX='tmux -L $IN' SUZU_INNER_TMUX_CMD='tmux -L $IN attach -t test1' SUZU_DOORBELL_FILE='$DOORBELL' '$SUZU_BIN' start" \
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

echo
if [ "$FAIL" = 0 ]; then
  echo "RESULT: ALL PASS"
else
  echo "RESULT: FAILED"
fi
exit "$FAIL"
