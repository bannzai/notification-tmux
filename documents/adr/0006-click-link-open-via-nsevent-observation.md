# 0006. ターミナルのリンククリックはNSEvent観測と自前検出器で開く

## Status

Accepted

## Context

issue #25 で、ターミナル表示上の URL（http/https）とファイルパス（絶対・`~`・相対）を素のクリックで開く機能が必要になった。実装には次の制約がある。

- SwiftTerm 1.13.0 の `mouseDown` / `mouseUp` は `public`（非 `open`）のため、別モジュールの subclass から override できない（[ADR 0003](0003-nsevent-monitor-for-swiftterm-mouse-reporting.md) と同じ制約）
- tmux がマウスレポートを要求している間、クリックの press / release は tmux へ届く必要がある。up だけ消費すると press-without-release の不整合が起き、down を消費するとローカル選択の開始が壊れる
- SwiftTerm には暗黙リンク検出（`linkMatch`）と `requestOpenLink` による自動オープンが組み込まれているが、判定ロジックは internal で挙動を制御できない。実機検証では、tmux window と Noroshi クライアントの桁数不一致時に崩れたバッファテキストから不正な URL（`examphttps://example.com`）を開いた
- 折返し継続の判定に必要な `BufferLine.isWrapped` は internal で参照できない。「行が右端まで埋まっていたら継続」というセル充填ヒューリスティックは、桁数不一致時に無関係な隣接行を誤結合した
- 相対パスはターミナル側の作業ディレクトリを知らないと解決できない

## Decision

1. **クリック検出は既存の NSEvent local monitor の拡張で行い、イベントは消費しない**。`.leftMouseDown` で押下セルを記録し、`.leftMouseUp` が同一セルなら（ドラッグ選択でない）クリックとみなしてリンクを開く。down / up とも常に素通しするため、tmux へのマウスレポート整合と SwiftTerm のローカル選択はそのまま保たれる
2. **リンク検出は SwiftTerm 組み込みでなく自前の純粋ロジック（`TerminalLinkDetector`）で行う**。http/https 限定・スキーム直前の後方走査・二重 `://` の拒否・存在確認前提のパス分類を自分で制御し、ユニットテスト可能にする。SwiftTerm の暗黙リンク自動オープンは `linkHighlightMode = .alwaysWithModifier` で抑止する（暗黙マッチは修飾キーの有無に関わらずクリック対象にならない唯一の公開 API レバー。`requestOpenLink` の subclass 実装は protocol witness が extension デフォルトへ静的束縛されるため機能しない）
3. **折返し判定は public な `Terminal.getText` の改行挿入規則を実折返しのオラクルとして使う**。`getText` は wrapped 境界では改行を挟まず、ハード改行境界でのみ `\n` を挟む（getSelectedLines が `isWrapped` を参照して `LineFragment.newLine` を挿入する実装を一次ソースで確認）。隣接 2 行の `getText` 結果に `\n` が含まれるかで折返し継続を判定でき、セル充填ヒューリスティックの誤結合（桁数不一致時）を根本的に排除する。加えて、クリック位置のトークンが行端に接する方向にだけ結合を広げる
4. **相対パスは表示中 session のアクティブ pane の `pane_current_path`（tmux 照会）基準で解決し、ファイルの存在確認を誤検出の安全弁にする**。存在しないパスは何もしないため、`/` を含むトークンを広めに候補にしても誤オープンには至らない。tmux 照会と存在確認は subprocess / IO を伴うため main actor の外で行い、`NSWorkspace.open` だけ main で行う

## Consequences

- 良い点: tmux のマウスレポート・pane 操作・ローカル選択と共存したまま素のクリックでリンクが開く。検出ロジックが純粋関数のためユニットテストで網羅でき、SwiftTerm 内部実装（internal API）への依存もない
- 良い点: 桁数不一致（`attach -f ignore-size` のため単一クライアントでも起き得る）で崩れた表示から不正 URL を開く事故を、実折返し判定 + 二重スキーム拒否の二段で防ぐ
- 悪い点: クリックは観測のみのため、リンクを開くクリックも従来どおり tmux / SwiftTerm に届く（tmux マウスモード有効時はリンクオープンと pane 側の反応が同時に起きる）。これは「素のクリックで開く」要件とのトレードオフとして受け入れる
- 悪い点: 検出器は崩れ得る表示バッファを読むため、崩れが偶然クリーンな http/https トークンを形成した場合は誤った URL を開き得る（露出は上記二段で大幅に低減）
- OSC 8 の明示ハイパーリンクは `.alwaysWithModifier` により Cmd+クリックで SwiftTerm 経由のまま開く（意図された動作として残す）
- `getText` の改行挿入規則という SwiftTerm の暗黙仕様に依存する。feed ベースの回帰テスト 2 件（自動折返し境界 / ハード改行境界）で仕様変化を検知する
