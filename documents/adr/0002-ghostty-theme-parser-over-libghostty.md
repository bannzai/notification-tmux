# 0002. libghostty 移行を見送り、Ghostty テーマパーサ + SwiftTerm 適用方式を採用する

## Status

Accepted

## Context

cmux と同じ見た目 (Ghostty テーマ) にしたい動機から、cmux と同様に libghostty へ移行する案を調査した (issue #2)。調査結果:

- cmux のテーマ = Ghostty のテーマであり、実体は `~/.config/ghostty/config` の `key = value` テキスト
- フル libghostty は 2026 年時点で非安定 API (公式明言)。プリビルド配布が無く、Zig ビルド + 非安定 API 追従 + IME 転送グルー自前実装のコストが大きい
- GPU 描画が欲しい場合も SwiftTerm に実験的 Metal レンダラー (`setUseMetal`) が既にあり、libghostty 移行の理由にならない

## Decision

libghostty へは移行せず、Ghostty テーマ形式のパーサ (`GhosttyTheme`) を実装して SwiftTerm の色 API に適用する。

- 対応: `background` / `foreground` / `cursor-color` / `selection-background` / `palette N=COLOR` / `theme` 参照 (ユーザー themes ディレクトリ → Ghostty.app 同梱テーマ) / `dark:...,light:...` のシステム外観連動。優先順位は Ghostty 公式意味論 (theme が先、ユーザー config が上書き) に合わせる
- SwiftTerm 1.13.0 の実 API 制約に合わせる: パレット適用は `installColors` (16 要素)。index 16..255 は `Terminal.ansi256PaletteStrategy = .xterm` (rebuild が走る computed プロパティ経由) を **palette の有無に関わらず apply の先頭で固定**し、Ghostty 標準の xterm 256 色と一致させる。既定の `.base16Lab` のままだと bg/fg 設定だけで 16..255 が LAB 補間に劣化するため
- `selection-foreground` は SwiftTerm に対応 API が無くパースのみ。palette の 16..255 明示上書きも SwiftTerm 公開 API の制約で反映されない (実在テーマ 463 件で使用例ゼロを確認済み)

## Consequences

- 良い点: SPM 1 行の安定依存のまま cmux/Ghostty とテーマ互換になる。`~/.config/ghostty/config` を編集して「表示 > テーマを再読み込み」で反映できる
- 悪い点: X11 名前色・3 桁 hex は未対応 (実在テーマでの使用が無いことを確認して割り切り)。libghostty が得意とする GPU 描画・Kitty Graphics・OSC 通知のネイティブ受信は得られない
- libghostty のフル API が安定リリースされたら移行を再評価する (issue #2 の中期方針)
