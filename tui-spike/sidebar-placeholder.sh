#!/usr/bin/env bash
# issue #67 Phase 0: サイドバーのプレースホルダ
# 通知一覧の実装 (Phase 1) までの仮画面。何かキーが押されたらフォーカスを内側 tmux へ返す
# (フォーカスがサイドバーにある間は内側 tmux にキーが届かないため、戻りはサイドバー側が担う)
set -u

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf '\n  Noroshi sidebar\n  (Phase 0 placeholder)\n\n  ここに通知一覧が入る\n  (通知の受信は Phase 1)\n\n  prefix + %s: サイドバーへ\n  何かキー: 内側 tmux へ戻る\n' \
  "${NOROSHI_INNER_JUMP_KEY:-N}"

while read -rsn1 _; do
  bash "$SPIKE_DIR/noroshi-outer" focus inner
done

# 端末からキーを読めない環境でも pane を維持する
while :; do sleep 3600; done
