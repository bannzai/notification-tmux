# 0011. SwiftTerm を CG レンダラの dirty 領域クリア修正を含む revision に pin する

## Status

Accepted

## Context

Claude Code の thinking 等で tmux pane が連続スクロールすると、Noroshi の画面にステータスラインの残像が積み上がる (issue #49)。原因は SwiftTerm v1.13.0 の macOS CoreGraphics レンダラの既知バグで、upstream #582 (commit d5ee56e) で修正済み (すべて一次ソースで確認):

1. `drawTerminalContents` は明示的な背景色を持つセルしか塗らず、既定背景セルは backing store の透明ピクセルに依存する。AppKit が backing store をクリアするのは全面再描画の時だけなので、部分再描画では前フレームのピクセルが残る
2. tmux は全幅 pane のスクロールに DECSTBM でステータス行を除いた制限リージョン (top=0, bottom=rows-2) を使う。SwiftTerm の `scroll()` は top=0 だと scrollback 経路 (yBase 前進 = viewport 全体のずれ) を取るのに、v1.13.0 の dirty 指定はリージョン端の行だけで、リージョン外 (ステータス行) は再描画されない
3. 結果、スクロールのたびにステータス行のピクセルが 1 行ずつずれた位置に残り、tmux が再描画するのは実ステータス行だけなので残像が積み上がる。行頭に前フレームのグリフが残る崩れも同根 (E2E で再現確認)

tmux 側の描画は正しく、ADR 0010 (スクロール領域キャッシュのずれ) とは別の、レンダラのみの不具合。修正 #582 は dirty rect の描画前クリアと、制限リージョン下端 1 セル分の invalidation 拡張で解消する。

検討した代替案:

- **v1.13.0 に #582 だけ backport した fork を持つ**: fork の維持と upstream 追随のコストが増える。checkouts 改変不可の方針 (ADR 0002) とも整合しない
- **Noroshi 側で回避する**: 描画は SwiftTerm 内部 (`drawTerminalContents` / dirty 管理) で完結し、公開 API から介入できない
- **branch (main) 追随で pin しない**: ビルド再現性が失われる

## Decision

SwiftTerm の依存指定を `upToNextMajor 1.13.0` から revision `d5ee56e` (修正 #582 を含む、当時の main 先端近傍) の固定 pin に変更する。v1.13.0 より後のリリースタグが未発行のため、リリース待ちではなく revision pin を採る。

v1.13.0..d5ee56e には Noroshi が補っていた挙動の upstream 実装が含まれるため、あわせて次を行う:

- **IME marked text 補完の削除**: upstream が同等の overlay 描画・NSTextInputClient 実装 (キャレット位置 fallback 含む) を持ったため、`MouseReportingTerminalView` の補完実装を削除する。残すと overlay が二重表示になる。既存のユニットテスト (TerminalHostViewTests) は継承した upstream 実装に対してそのまま通る
- **`scrollerStyle = .legacy` の明示**: upstream の既定が `.legacy` から `.overlay` に変わった。`cellSize()` / `TerminalFontFit` / ADR 0010 の再同期は `.legacy` 固定 15pt の scroller 幅を前提にしているため、view 生成時に `.legacy` を明示して前提を保つ
- **マウスレポート補完 (ADR 0003) は維持**: upstream も scrollWheel / ドラッグ motion のレポートを実装したが、NSEvent local monitor がイベントを view より先に消費するため二重送出にはならない。リンククリック検出 (ADR 0006) と一体の monitor 経路を維持する

## Consequences

- 良い点: issue #49 のステータスライン積み上がり・行頭残骸が解消される (同一条件の E2E で確認)
- 良い点: IME 補完が upstream 化され、Noroshi 側の独自実装が減る
- 注意点: revision pin のため自動でパッチが入らない。次回更新時は ADR 0010 の前提 (`resetFont` が scroller 幅を引かずに cols を計算する) の再確認が必要。d5ee56e 時点では維持されていることを確認済み
- 注意点: v1.13.0..d5ee56e には kitty keyboard protocol・DEC 2026 (synchronized output) 対応等の変更も含まれる。挙動差の確認は E2E.md の範囲で行った
