# 0009. ignore-size attach を維持し、表示フォントの自動フィットで見切れを防ぐ

## Status

Accepted (GUI 版 Noroshi.app の決定。「他 client の window を resize しないため ignore-size で attach する」は suzu にも引き継がれ、`suzu/watcher.go` の control mode client が `-f ignore-size` で attach する根拠として本 ADR を参照する。フォント自動フィットは GUI 固有で suzu には無い)

## Context

Noroshi は `attach-session -f ignore-size` で attach する (Noroshi の画面サイズで他 client の window を resize しないため)。そのため window の格子サイズは他 client (cmux 等) や `default-size` 基準で決まり、Noroshi の terminal 格子より大きくなり得る。

tmux は client が window より小さい時、カーソルが見えるように表示領域をパンする。カーソルが右端にあると左端が画面外に出て「フルスクリーンなのに左端が見切れる」symptom になる (issue #36)。フルスクリーンでも、Noroshi のフォントサイズ次第で列数が window に届かないため起きる。

検討した代替案:

- **ignore-size をやめる**: Noroshi の attach / resize のたびに他 client の window が resize され、cmux 側の表示が崩れる。ignore-size 採用の意図に反するため採らない
- **`window-size smallest` / `resize-window`**: tmux サーバ側の設定・window 変更で他 client へ影響するため採らない
- **`refresh-client -L/-R` でのパン制御**: カーソル移動で自動パンに戻るため持続しない

## Decision

attach 方式は変えず、表示側 (SwiftTerm) のフォントを設定サイズを上限に自動縮小し、client の格子 (cols × rows) が window の格子以上になるようにする。

- window 格子は attach / switch 時と 2 秒ポーリング (`AppState.refresh`) で `display-message -p` の `#{window_width}` / `#{window_height}` から取得する
- フィット計算 (`TerminalFontFit`) は SwiftTerm の `computeFontDimensions` と同じ式 ("W" の advancement + backingScaleFactor でのピクセル格子への切り上げスナップ) でセル寸法を求め、0.5pt 刻みで「収まる最大サイズ」を選ぶ。下限は 6pt
- 収まる場合は設定サイズのまま表示する (拡大はしない)

実装上の制約 (初回実装でクラッシュした実測):

- レイアウトパス中 (`setFrameSize`) の font 変更は SwiftUI の View 更新と競合して SIGSEGV したため、再フィットは次の runloop へ合流 (`scheduleRefitFont`) させる
- tmux CLI の同期実行 (`Process.waitUntilExit` は runloop を回す) を View 更新中に行うと同様に競合するため、格子取得は常に非同期 (`fetchWindowGrid`) で行う

## Consequences

- 良い点: カーソル位置に関係なく window 全体が常に見え、パン由来の見切れが起きない
- 良い点: 他 client の window サイズには一切影響しない (ignore-size の意図を保つ)
- 注意点: window が Noroshi の格子より大きい間は、設定フォントサイズより小さく表示される
- 注意点: 下限 6pt まで縮めても収まらない極端に大きい window では従来どおりパンが起きる
