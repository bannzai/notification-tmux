# NTMUX v1 開発で得た知見まとめ

作り直し (v2) を想定して、実機検証で確定した事実・ハマりどころ・設計判断を記録する。
「確認済み」は実機またはソースコード一次情報で検証したもの。

## 1. tmux 連携

### window の識別子は window_id (`@n`) 一択
- `@n` は tmux サーバ全体でユニークで、session/window の改名・並べ替え・index 変更の影響を受けない (確認済み)
- `select-window -t @18` のように **session プレフィックスなしで一意解決される** (man tmux TARGET SYNTAX)
- pane も同様に pane_id (`%n`) がサーバ全体でユニーク。pane レベルの機能を作るならこれを SSOT にする

### フォーマット文字列のパース
- 区切り文字は ASCII Unit Separator `\u{1f}` を使う。window 名には `|` や空白が普通に入るため
- `#{window_flags}` (`*!Z` 等の合成文字列) はパースしない。`#{window_active}` `#{window_bell_flag}` `#{window_zoomed_flag}` 等の**個別 bool 変数を列挙**する方が安定 (確認済み)
- 実際に使ったフォーマット:
  - window: `#{session_name}\u{1f}#{window_id}\u{1f}#{window_index}\u{1f}#{window_name}\u{1f}#{window_active}\u{1f}#{window_panes}`
  - session: `#{session_name}\u{1f}#{session_attached}`

### session / client / window 切替の意味論
- **session のカレント window は session 単位で 1 つ** (client 単位ではない)。`select-window` は同じ session に attach している全クライアントの表示を切り替える
- NoroshiはPTY clientを1本だけattachし、session切替には`switch-client -c <client_tty> -t =<session>`を使う。SwiftTermの子PIDと`#{client_pid}`を照合して自clientのttyを特定する
- 同じclientを維持することで、tmux標準の`switch-client -l`（既定bindは`prefix + L`）が直前sessionへ戻れる。tmux内で変わった接続先は`#{session_name}`のポーリングでサイドバーへ反映する
- cmux 等の別クライアントが同じ session に attach していると `select-window` はそちらの表示も変える。分離したければ **session group** (`tmux new-session -t <対象>`): window 群を共有しつつカレント window を独立に持てる
- attach の target は `=` プレフィックスで完全一致にする: `attach-session -t =<name>` (前方一致の誤爆防止)
- tmux 3.1+ の既定 `window-size latest` により、小さいクライアントを attach しっぱなしにしても「最後に操作したクライアント」基準でサイズが決まる

### 一覧のリアルタイム更新
- v1 は 2 秒ポーリング (`list-windows -a`)。フォーマット出力のみで軽量、40 session / 100+ window でも問題なし
- イベント駆動にするなら `tmux set-hook -g` (session-created / session-closed / window-linked / window-unlinked / window-renamed / client-session-changed) + `run-shell -b`。hook はサーバプロセス内で走るので重い処理は必ず `-b` (バックグラウンド)

## 2. Claude Code hooks 連携

### Stop hook から tmux 上の位置を特定する方法 (確認済み)
- Stop hook の stdin JSON (`session_id` / `transcript_path` / `cwd` / `hook_event_name` 等) に **tmux の位置情報は無い**
- hook プロセスは Claude Code の親シェル (tmux pane 内) から `$TMUX_PANE` を継承する。これで解決:
  ```bash
  tmux display-message -p -t "$TMUX_PANE" '#{session_name}'
  tmux display-message -p -t "$TMUX_PANE" '#{window_id}'
  ```
- 2 回に分けて呼べば区切り文字問題も起きない。`$TMUX_PANE` 空 (tmux 外) はガードして exit 0
- session 名は空白・記号を含み得るので URL に載せる時は `jq -sRr @uri` でエンコード

### 既存 hooks を壊さない差し込み方
- settings.json の hooks は**配列内で並列実行**される。既存の Stop hooks 配列の末尾に 1 エントリ追加するだけで、既存の通知 (cmux 向け OSC 777 等) と非破壊に共存できる
- hook スクリプトは「Claude 側を絶対にブロックしない」を最優先: 前提が欠けたら黙って exit 0、`open` の失敗も `|| true`

### macOS アプリへのイベント伝達は URL スキーム + `open -g`
- `-g` は「フォアグラウンドに持ち上げない」: 起動中ならハンドラだけ呼ばれ、未起動なら**背面で起動される** (man open で確認)。バッジだけ更新してフォーカスを奪わない要件に合致
- URL スキームは LaunchServices にアプリ初回起動時に登録される。ビルドし直して場所が変わったら一度 `open <app>` すれば良い

## 3. SwiftTerm (v1.13.0)

### 基本
- SPM: `https://github.com/migueldeicaza/SwiftTerm`, product 名 `SwiftTerm`, macOS 11+
- `LocalProcessTerminalView.startProcess(executable:args:environment:execName:currentDirectory:)` が forkpty まで面倒を見る
- フレーム変更だけで PTY の winsize 更新まで自動伝播する (`setFrameSize` オーバーライド済み)。SwiftUI 側は AutoLayout に任せるだけ

### ハマりどころ (すべてソース or issue で確認済み)
- **デフォルト環境変数に PATH が入らない** (意図的にコメントアウトされている)。絶対パスで exec するか、ログインシェル経由 (`execName: "-zsh"`) にする。tmux attach は attach 先の環境がサーバ側なので実害なし
- **`feed()` と `send()` の混同**: `feed()` は表示バッファへの書き込みのみで子プロセスに届かない。プロセスに入力を送るのは `send()` (issue #288)
- **App Sandbox は完全無効が公式の立場**。公式サンプル (MacTerminal) の entitlements は空 dict。entitlements を作らない or `ENABLE_APP_SANDBOX = NO`
- **非表示ビューでも attach と VT パースは継続する** (描画だけ AppKit がスキップ)。そのためNoroshiはviewをsessionごとにキャッシュせず、同じ1個のview/clientを`switch-client`して使う。client特定に失敗した場合だけ旧viewを`terminate()`して再attachする
- `processTerminated(exitCode:)` の exitCode は IO エラー時に nil。tmux の detach とプロセス死をこのコールバックだけでは区別できない
- フォーカスは `window.makeFirstResponder(terminalView)` を呼ぶだけで良い (acceptsFirstResponder 等は実装済み)。ただし **updateNSView の同期処理中に呼ぶと SwiftUI の更新と競合する**ので `DispatchQueue.main.async` で次の runloop に回す
- `font` の setter は selection 解除と再計算の副作用があるので、SwiftUI の更新のたびに無条件代入しない
- IME: NSTextInputClient 準拠で基本動作するが、変換中テキストのオーバーレイ表示に改善余地 (PR #561 が open)。日本語入力は実機確認を推奨
- `optionAsMetaKey` (既定 true) / `allowMouseReporting` (既定 true) は用途に応じて切り替え UI を用意すべきとソースコメントに明記

## 4. macOS アプリ (SwiftUI / Xcode 26)

- **WindowGroup は URL イベントごとに新規ウィンドウを開く**。単一ウィンドウアプリは `Window("...", id: "...")` シーンにする (実機で遭遇したバグ)
- `onOpenURL` は `open -g` (バックグラウンド配送) でも呼ばれる
- Dock バッジは `NSApp.dockTile.badgeLabel`
- **Xcode 26 の新規プロジェクトは folder-synchronized (PBXFileSystemSynchronizedRootGroup)**。フォルダに .swift を置くだけでターゲットに入る。pbxproj の手編集は SPM パッケージ参照の追加程度で済む
  - 必要な追加: `PBXBuildFile` (productRef) + Frameworks phase + `packageProductDependencies` + `XCRemoteSwiftPackageReference` + `XCSwiftPackageProductDependency`
- **`GENERATE_INFOPLIST_FILE = YES` と `INFOPLIST_FILE` は併用可能でマージされる**。CFBundleURLTypes のような配列キーは INFOPLIST_KEY_* にできないので部分 Info.plist を書く。synchronized フォルダの外に置くこと
- Xcode 26 テンプレートは `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`。バックグラウンドで Process を回す設計なら `nonisolated` に変えて明示 @MainActor 方式にする方が素直
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES` (テンプレート既定) だと `@Published` に **明示的な `import Combine` が必要**
- **Metal Toolchain は Xcode 26 で別ダウンロード**。SwiftTerm は Shaders.metal を含むため無いとビルド不能: `xcodebuild -downloadComponent MetalToolchain` (約 700MB)
- ユニットテストは app が TEST_HOST になり**アプリが実際に起動する**。ポーリングや tmux attach が走らないよう `ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"]` でガード
- zsh はデフォルトで `>` の上書きを拒否する (NO_CLOBBER)。ログ保存は `>|` を使うかファイル名を変える

## 5. 検証手法

- アクセシビリティ権限があれば `osascript` の System Events で実クリック検証ができる。SwiftUI の List row 内 Button は `click at {x, y}` で AX ツリー上の button として解決される
- キー入力の end-to-end 検証: System Events の `keystroke` → アプリ → PTY → `tmux capture-pane -p` で到達確認
- tmux の状態検証はユーザーの実 session に触れない専用 session を作る (`tmux new-session -d -s <test名>`)。sidebar の先頭に出したければ辞書順で先頭になる名前にする
- スクリーンショットは `screencapture -x` (画面収録権限が必要)

## 6. 設計判断の記録

| 判断 | 理由 |
| --- | --- |
| バッジのクリア条件 = その window をアプリ内で開いた時 | 最小で直感的。既読管理はしない |
| バッジはメモリのみ (再起動でリセット) | v1 スコープ。永続化するなら履歴 (どの window で何時に発生) ごと保存したい |
| 一覧はポーリング (2s) | 実装が単純で 100+ window でも軽い。イベント駆動化は set-hook で可能 (上記) |
| 通知イベントの重複抑止はしない | hook の発火回数 (Stop 1 回 = 1 通知) に委ねる。スクリプトは状態レス |
| session の自動選択・自動 attach はしない (issue #48) | 起動時は未選択のまま、選択 session の kill 時は選択解除のみ。自動 attach すると ssh ごしに起動した tmux session を勝手に掴んでしまう |
| サイドバーへのフォーカス移動では選択・attach しない (issue #57) | cmd+opt+s や Full Keyboard Access の Tab 移動・システムのフォーカス再割り当てが、session 未選択のタブ (起動直後・新規タブ) に先頭 session を勝手に attach してしまう。選択を変えるのは明示操作 (クリック / ↑↓ ナビゲーション / cmd+数字 等) のみ |

## 7. 実測値

- メモリ: NTMUX RSS ≈ 126MB (session 40+ / window 100+ 環境で 1 session attach 時)。cmux は同環境で 30GB 級だった
- ユニットテスト 8 件: 0.02 秒
- クリック → tmux select-window 反映: 体感即時 (2 秒ポーリングを待たず attach 済み PTY の再描画で反映される)
