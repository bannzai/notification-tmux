# 0010. font 変更直後に setFrameSize を呼び直し、実サイズ変更で tmux を再同期する

## Status

Accepted (GUI 版 Noroshi.app の決定。GUI 版は issue #76 で削除したため、現行の suzu には適用されない。記録として残す)

## Context

Claude Code のような連続スクロール出力を tmux 内で動かすと、Noroshi の画面が崩れてステータスラインごと下から競り上がる symptom が起きた。原因は次の連鎖 (すべて一次ソースで確認):

1. Noroshi はフォント自動フィット (ADR 0009) で `view.font` を代入する。SwiftTerm 1.13.0 の font setter は `resetFont()` → `TerminalView.resize()` 経由で無条件に `terminal.softReset()` を呼び、スクロール領域 (DECSTBM)・カーソル表示・SGR 属性を接続先へ知らせずリセットする
2. `Terminal.resize` は格子が同一なら early return する。フィットは 0.5pt 刻みでセル寸法をピクセル格子へ切り上げスナップするため、隣接ステップの font 変更が同一格子に落ちることがあり、この場合 PTY への TIOCSWINSZ が同値になり SIGWINCH が配送されない
3. tmux (3.2a tty.c) はクライアント端末のスクロール領域を `tty->rupper/rlower` にキャッシュし、`tty_region` は同値なら DECSTBM を再送しない。キャッシュ破棄 (`tty_invalidate`) はクライアントの実サイズ変更 (`tty_resize`) 時のみ
4. 結果、同一格子の font 変更後は「pane のスクロール領域が設定済み」と信じた tmux が領域下端へ LF を送り続け、実際は全画面スクロールになる。tmux は自分が変えたと思う行しか再描画しないため、ステータスラインの残像が 1 行ずつ積み上がる

検討した代替案:

- **SwiftTerm の resetFont / softReset を修正する**: checkouts はピン済みで改変不可 (ADR 0002 と同じ制約)
- **同一格子になる font 変更をスキップする**: テーマ再読み込みで書体だけ変えたい場合に適用されなくなる。また softReset が走る他の経路を将来塞げない
- **font 変更後に tmux CLI で `refresh-client` を送る**: 全再描画はされるが `tty_invalidate` が呼ばれず、SGR・カーソル可視のキャッシュずれが残り得る。非同期のサブプロセス実行も増える

## Decision

`applyFont` で `view.font` を代入した直後に、同じ frame で `view.setFrameSize(view.frame.size)` を呼び直す。

- SwiftTerm の `resetFont` は cols を `frame.width / cellWidth` (scroller 幅を引かない) で計算し、`processSizeChange` は scroller 幅 (`.legacy` 固定 15pt) を引いて計算する。セル幅が scroller 幅より狭い現実的なフォントでは cols が必ず 1 列以上減るため、直接呼び出しの `setFrameSize` → `processSizeChange` が実サイズ変更として TIOCSWINSZ 差分 → SIGWINCH を確実に起こす
- tmux は `MSG_RESIZE` で `tty_resize` → `tty_invalidate` (スクロール領域・カーソル・SGR の全キャッシュ破棄 + SGR0 送出) と `server_redraw_client` (全再描画) を行うため、softReset で生じたずれが完全に解消される
- 副次効果として、font 変更直後に scroller の下へ隠れていた幻の 1〜2 列も即時解消される (ステータスライン右端の時計が隠れる問題)

## Consequences

- 良い点: font 変更のたびに tmux と端末エミュレータの状態が必ず再同期され、Claude Code 等の連続スクロール中でも崩れが持続しない
- 良い点: tmux CLI 呼び出しを増やさず、AppKit / SwiftTerm の公開 API だけで閉じる
- 注意点: font 変更ごとにリサイズと全再描画が 1 回余分に走る。font 変更は window 格子の変化時のみで頻度が低く、実害はない
- 注意点: cols 差分の保証は「セル幅 < scroller 幅 15pt」(フォント約 25pt 未満) と SwiftTerm 1.13.0 の resetFont の実装に依存する。SwiftTerm を更新して resetFont が scroller 幅を引くようになった場合、この方式では同一格子の font 変更を再同期できなくなるため再検討する
