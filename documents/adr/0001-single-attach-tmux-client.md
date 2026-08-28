# 0001. tmux client は表示中 session のみ attach する単一 attach 方式を採用する

## Status

Superseded by [0005](0005-switch-client-for-session-navigation.md) (GUI 版 Noroshi.app の決定。GUI 版は issue #76 で削除したため、現行の suzu には適用されない。記録として残す)

## Context

v1 (NTMUX) は session ごとに `LocalProcessTerminalView` (= PTY 上の `tmux attach-session`) を生成し、一度作った view を破棄せずキャッシュしていた。session を巡回するほど attach client が増え、次のコストが多重化する (issue #6):

1. tmux サーバが session の出力を client 数ぶん複製して書き出す
2. SwiftTerm は非表示 view でも VT パースを継続する
3. 各 view がスクロールバックを保持し続け、メモリが時間とともに増える (cmux が 30GB 級に膨れたのと同じ構造)

比較した選択肢: A. 表示中 session のみ attach / B. LRU で K 本残す / C. `refresh-client -f no-output` で非表示 client を黙らせる / D. 常駐 client 1 本を `switch-client` で切り替える / E. control mode client への再設計。

## Decision

案 A を採用する。session 切替時に直前の view を `terminate()` して破棄し、必要になったら再 attach する。常時 attach client は最大 1 本。

- C は man tmux で確認した結果 control mode 専用のため不可。D は自 client の tty 特定機構が必要で複雑化、E は描画層の再設計でスコープ外。B は A で切替が遅いと感じた場合の発展形として保留
- スクロールバック履歴は tmux サーバ側が持つため、view 破棄による実害は小さい
- 実装上の要点: SwiftTerm 1.13.0 の `LocalProcess.terminate()` は child monitor を cancel するため **terminate した view に `processTerminated` は届かない** (ピン済みソースで確認)。よって「意図的 terminate の遅延コールバックを無視する」機構は不要であり、`processTerminated` では `source === currentView` の場合のみ attach を手放す。ObjectIdentifier を保持する方式はアドレス再利用で後発 view の死を誤って無視する危険があるため使わない

## Consequences

- 良い点: attach client / VT パース / スクロールバック保持が常に 1 session ぶんに抑えられ、session 数に対して定数コストになる。通知バッジ・一覧表示はポーリング + URL イベントで attach と独立しているため影響しない
- 悪い点: session 切替のたびに PTY spawn + attach + 全画面再描画が走る。切替が遅いと感じたら LRU (案 B) → switch-client (案 D) の順に再検討する
- アプリ内の view にスクロールバックが残らないため、過去出力は tmux の copy-mode で参照する
