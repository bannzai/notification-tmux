# 0004. Noroshi 独自設定ファイル (~/.config/noroshi/config) を導入する

## Status

Accepted

## Context

フォントや色を GUI から調整したい (issue #9)。これまで配色は `~/.config/ghostty/config` を直接読んでいた (ADR 0002) が、以下の課題があった。

- Noroshi の設定を書き戻す先が無い。ghostty config を Noroshi が書き換えるのは越権で、ユーザーの Ghostty 環境を壊しかねない
- フォント (`font-family` / `font-size`) は ADR 0002 のパーサが未対応だった
- issue #9 は「libghostty (Ghostty) 形式のパーサは生かしつつ、アプリ独自の設定ファイルに移植する」方針を求めている

## Decision

Ghostty config 形式 (`key = value`) 互換のアプリ独自設定ファイル `~/.config/noroshi/config` (`XDG_CONFIG_HOME` を尊重) を導入する。

- **パーサ互換の維持**: パースは既存の `GhosttyTheme.parse` / `resolve` をそのまま使う。`font-family` / `font-size` を config レベルのキーとして追加でパースする (Ghostty と同名キー)。theme ファイル内のフォント対応は不要
- **ghostty config へのフォールバック**: 既定の読み込みは noroshi config を優先し、無ければ従来どおり ghostty config を読む (`NoroshiConfig.preferredConfigPath`)。noroshi config を持たない既存ユーザーの挙動を壊さない。テーマ探索順は noroshi themes → ghostty themes → Ghostty.app 同梱
- **フォント適用**: 解決済みの `font-family` / `font-size` から `NSFont` を作り SwiftTerm の `TerminalView.font` に設定する。未指定なら既定フォントを尊重して触らない。family が実在しなければ等幅システムフォントにフォールバックする。`font` setter は selection 解除・再計算の副作用があるため、値が変わる時だけ代入する
- **GUI 書き戻しの意味論** (Cmd+, の設定ウィンドウ): 変更を即時に noroshi config へ書き戻し、terminal に再適用する。書き戻しは純粋・テスト可能な `NoroshiConfigEditor` (元テキスト + 設定/削除キー → 新テキスト、冪等) が担う
  - テーマを選んだら `theme = <name>` を書き、明示色 4 キー (background / foreground / cursor-color / selection-background) を削除する。Ghostty では config の明示色が theme を上書きする (ADR 0002) ため、残すと混乱するため
  - 個別色・フォントを変えたら該当キーだけを書く (theme は残す)
  - 「未設定」を選んだら該当キーを削除する
- **移植スクリプト**: `scripts/noroshi-port-ghostty-config` が ghostty config から Noroshi が理解するキーだけを抽出して noroshi config を生成する。出力先が既にある場合は `--force` 無しでは上書きしない (冪等・安全)

## Consequences

- 良い点: Noroshi が自分の設定ファイルを安全に読み書きできる。ghostty config には一切触れない。Ghostty 形式・パーサ互換を保つため、テーマファイルや移植した config はそのまま流用できる
- 悪い点: noroshi config が存在すると ghostty config は読まれなくなる (フォールバックは noroshi 不在時のみ)。ghostty 側の後からの変更を取り込みたい場合は移植スクリプトを再実行する必要がある
- パーサの色対応範囲は ADR 0002 のまま (X11 名前色・3 桁 hex は未対応)。フォントは family 名解決を `NSFontManager` に委ね、解決できなければ等幅システムフォントへフォールバックする
