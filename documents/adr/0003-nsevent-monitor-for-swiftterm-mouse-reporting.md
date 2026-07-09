# 0003. SwiftTerm のマウスレポート欠落を NSEvent ローカルモニタで補完する

## Status

Accepted

## Context

tmux `mouse on` の環境で、Noroshi のターミナル上のマウス操作が tmux に届かない不具合があった (スクロールで copy-mode に入れない、pane 境界のドラッグでリサイズできない)。原因は SwiftTerm 1.13.0 の 2 箇所 (ピン済みリビジョンのソースで確認):

1. `MacTerminalView.scrollWheel` がマウスモード (tmux が有効化する DECSET 1002/1006) を一切見ず、常にローカルスクロールバックだけを操作してマウスレポートを送らない。tmux attach 中はローカルスクロールバックが実質空のため完全に無反応になる
2. `MacTerminalView.mouseDragged` が motion 送出を `.anyEvent` (1003) 専用の判定で行い、tmux の使う button-event tracking (1002) では motion レポートを送らずに早期 return する

選択肢: A. SwiftTerm を fork して修正 / B. 上流へパッチを送り修正版を待つ / C. サブクラスで該当メソッドを override / D. NSEvent ローカルモニタでイベントを横取りして SGR レポートを自前送出。

## Decision

D を採用する。C は該当メソッドが `public` (非 `open`) のため別モジュールから override 不可 (ビルドエラーで確認)。A は追従コスト、B は解決時期が読めない。

- `TerminalSessionManager` に `NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged])` を 1 本張り、**terminal view の window かつ bounds 内のイベントに限定**して SGR マウスレポート (SwiftTerm の public API: `encodeButton` / `sendEvent` / `sendMotion` / `mouseMode`) を送出し、ローカル処理を抑止する
- `mouseMode == .off` (tmux が mouse off) のときは消費せず SwiftTerm 既定のローカルスクロールへ委ねる (非 tmux 用途の回帰なし)
- セル寸法は internal API に頼らず `getOptimalFrameSize()` から逆算する

## Consequences

- 良い点: fork なし・SPM の安定依存のまま、スクロール copy-mode と pane 境界ドラッグが tmux ネイティブに動く (実測: copy-mode 突入・pane 高さ 27,26→22,31 のリサイズを確認)
- 悪い点: SwiftTerm の内部挙動 (座標系・エンコード) に暗黙依存する補完コードを持つ。**SwiftTerm 側で該当バグが修正されたらローカルモニタを撤去する** (本 ADR を Superseded にする)
- 補完対象は左ボタンのドラッグ motion とホイールのみ。中/右ボタンの button-motion は SwiftTerm 依存のまま (現要件に含まれない)
