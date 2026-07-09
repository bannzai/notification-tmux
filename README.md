# Noroshi (狼煙)

通知センター付き tmux フロントエンド macOS アプリ（旧 NTMUX / notification-tmux）。

Claude Code が Stop すると狼煙が上がり、その狼煙が上がった window へ駆けつける、という体験から Noroshi と名付けた。

- サイドバーに tmux の session(workspace) / window 一覧をツリー表示する
- Claude Code の Stop hook から `noroshi://stop?session=<name>&window=@n` を受けて該当 window にバッジ数字を付ける（Dock アイコンには未読合計）
- バッジのある window はクリック、またはショートカットキーでジャンプできる。ジャンプすると該当 session のターミナルを表示して `tmux select-window` で該当 window まで開く
- ターミナルは [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) の PTY で `tmux attach-session` する。表示中の session だけを attach する単一 attach 方式（後述）

## 技術構成

| レイヤ | 採用技術 | 役割 |
| --- | --- | --- |
| UI | SwiftUI (`Window` シーン + `NavigationSplitView`) | サイドバー (通知センター兼 workspace 一覧) と detail (ターミナル) |
| ターミナル描画 | SwiftTerm 1.13.0 (SPM) の `LocalProcessTerminalView` | forkpty で `tmux attach-session -t =<session>` した PTY を VT100/xterm エミュレーションで描画。Ghostty テーマの配色を適用 |
| tmux 連携 | `Process` で tmux CLI を実行 (`TmuxClient`) | `list-sessions` / `list-windows -a` の 2 秒ポーリングで一覧構築、`select-window -t @n` でジャンプ |
| 通知イベント | URL スキーム `noroshi://` + `open -g` | Claude Code Stop hook → シェルスクリプト → LaunchServices → `onOpenURL` |
| 状態管理 | `AppState: ObservableObject` (@MainActor) | session 一覧・バッジ台帳 (windowID → 未読数)・通知履歴・選択状態 |
| ショートカット | SwiftUI `Commands` (`NavigationCommands`) | session/window/pane 移動、最新通知へのジャンプ、テーマ再読み込み |
| テスト | XCTest (app を TEST_HOST とするユニットテスト) | パーサ / URL イベント / バッジ台帳 / Ghostty テーマ解決 / ナビゲーション計算 |

### データフロー

```
Claude Code (tmux pane 内で動作)
  └─ Stop hook ─▶ scripts/noroshi-hook-stop
                    ├─ $TMUX_PANE → tmux display-message で session名 / window_id (@n) を解決
                    └─ open -g "noroshi://stop?session=<name>&window=@n"   # フォーカスを奪わない
                                        │
Noroshi.app ◀────────────────────────────┘ (onOpenURL)
  ├─ AppState
  │    ├─ sessions: [TmuxSession]     ← TmuxClient が 2 秒ポーリング
  │    ├─ badges: [windowID: Int]     ← stop イベントで加算 / window を開いたらクリア
  │    ├─ notifications: [NotificationRecord] ← 「最新の通知へジャンプ」の発生順解決に使用
  │    └─ selectedSessionName
  ├─ SidebarView — session → window ツリー + バッジ数字 (クリックで AppState.open(window:))
  └─ TerminalHostView (NSViewRepresentable)
       └─ TerminalSessionManager (単一 attach) が表示中 session の LocalProcessTerminalView を保持
            └─ PTY: tmux attach-session -t =<session>
                     (session 切替時は直前の view を terminate して破棄し、新しい session に attach)
```

### 設計上のポイント

- **window の識別子は tmux の window_id (`@n`) を SSOT にする**。サーバ全体でユニークで、session/window の改名・並べ替えの影響を受けない
- **単一 attach 方式**（issue #6）: 常時 attach する terminal client は最大 1 本に限定し、表示中の session だけを attach する。session を切り替えると直前の view を `terminate()` して破棄してから新しい session に attach する。非表示 view を生かし続けないことで、attach client / VT パース / スクロールバックの多重コストを避ける
- **独自 config + Ghostty テーマ対応**: アプリ独自の設定ファイル `~/.config/noroshi/config`（`XDG_CONFIG_HOME` を尊重、無ければ `~/.config/ghostty/config` にフォールバック）と、そこから参照される theme ファイルを読み、Ghostty と同じ意味論（theme が先に読まれ config の直接指定が上書きする）でマージした配色を SwiftTerm に適用する。ファイル形式は Ghostty config 互換で、`font-family` / `font-size` も反映する。config 編集後は再起動せず、メニュー「表示 > テーマを再読み込み」(cmd+shift+r) で反映できる。詳細は [ADR 0004](documents/adr/0004-noroshi-config-file.md) を参照
- App Sandbox は無効 (homebrew の tmux を PTY で exec するため。SwiftTerm 公式の推奨)
- 詳細な知見・ハマりどころは [docs/knowledge.md](docs/knowledge.md) を参照（v1 開発時の記録）

### キーボードショートカット

マウスなしで session/window/pane を移動できる。メニューの keyEquivalent は first responder (SwiftTerm) の keyDown より先に処理されるため、cmd 系のショートカットが SwiftTerm に食われることはない。

| ショートカット | 動作 |
| --- | --- |
| `cmd+1` 〜 `cmd+9` | 表示順で該当番号の session に切り替える |
| `cmd+j` | 表示中 session のカレント window を次に進める |
| `cmd+k` | 表示中 session のカレント window を前に戻す |
| `cmd+shift+j` | 次の session に切り替える (循環) |
| `cmd+shift+k` | 前の session に切り替える (循環) |
| `cmd+shift+n` | 最も新しく受信し、かつ未読が残っている window へジャンプする |
| `cmd+]` | 表示中 session のカレント window 内でアクティブ pane を次へ移す |
| `cmd+[` | 表示中 session のカレント window 内でアクティブ pane を前へ移す |
| `cmd+shift+r` | テーマ設定を再読み込みして表示中 terminal に適用する |
| `cmd+,` | 設定ウィンドウ (フォント・テーマ・色) を開く |

### 設定 (フォント・テーマ・色)

`cmd+,` で設定ウィンドウを開き、フォント (family / size)・テーマ・色 (背景 / 文字 / カーソル / 選択範囲) を調整できる。変更は即時に `~/.config/noroshi/config` へ書き戻され、表示中の terminal に反映される。テーマを選ぶと明示色は消え、個別色を変えるとその色だけが上書きされる (Ghostty 準拠の意味論)。

既に Ghostty を使っている場合は、移植スクリプトで Noroshi が理解するキーだけを独自 config にコピーできる:

```bash
scripts/noroshi-port-ghostty-config          # ~/.config/ghostty/config → ~/.config/noroshi/config
scripts/noroshi-port-ghostty-config --force  # 出力先が既にある場合に上書き
```

抽出対象は `theme` / `background` / `foreground` / `cursor-color` / `selection-background` / `palette` / `font-family` / `font-size`。元の ghostty config には触れない。

### ディレクトリ構成

```
Noroshi/
  Noroshi.xcodeproj/         # Xcode 26 folder-synchronized 形式 (ファイル配置 = ターゲット追加)
  Info.plist                 # CFBundleURLTypes (noroshi://)。GENERATE_INFOPLIST_FILE とマージされる
  Noroshi/
    NoroshiApp.swift         # @main。Window / Settings シーン、onOpenURL、NavigationCommands (ショートカット)、テスト時 UI 起動ガード
    ContentView.swift        # NavigationSplitView
    SidebarView.swift        # session/window ツリー + バッジ
    TerminalHostView.swift   # SwiftTerm ラップと単一 attach の TerminalSessionManager (配色・フォント適用)
    GhosttyTheme.swift       # Ghostty config/theme のパースとマージ、SwiftTerm への適用
    NoroshiConfig.swift      # 独自 config のパス解決 (noroshi 優先・ghostty フォールバック) と入出力
    NoroshiConfigEditor.swift # config テキストの書き戻し (キー設定・削除、冪等)
    SettingsView.swift       # cmd+, の設定ウィンドウ (フォント・テーマ・色)
    AppState.swift           # ポーリング・バッジ台帳・通知履歴・選択状態・ショートカット操作
    TmuxClient.swift         # tmux CLI ラッパ
    TmuxModels.swift         # TmuxSession / TmuxWindow / StopEvent / NoroshiNavigation とパーサ
  NoroshiTests/
    TmuxModelsTests.swift
    GhosttyThemeTests.swift
    NoroshiConfigTests.swift       # config パス優先順位
    NoroshiConfigEditorTests.swift # 書き戻しエディタ
scripts/
  noroshi-hook-stop              # Claude Stop hook から呼ぶ通知スクリプト
  noroshi-port-ghostty-config    # ghostty config → noroshi config 移植スクリプト
.plans/                      # 実装プランと検証記録
docs/knowledge.md            # v1 開発時の知見まとめ (作り直し用)
```

## 必要なもの

- macOS 26+ / Xcode 26+（初回ビルドで Metal Toolchain が無い場合は `xcodebuild -downloadComponent MetalToolchain`）
- tmux（homebrew: /opt/homebrew/bin/tmux または /usr/local/bin/tmux を自動解決）

## ビルドと起動

```bash
cd Noroshi
xcodebuild -project Noroshi.xcodeproj -scheme Noroshi -configuration Debug -derivedDataPath ../tmp/DerivedData build
open ../tmp/DerivedData/Build/Products/Debug/Noroshi.app
```

## テスト

```bash
cd Noroshi
xcodebuild -project Noroshi.xcodeproj -scheme Noroshi -derivedDataPath ../tmp/DerivedData test
```

## Claude Code hooks 連携

`~/.claude/settings.json` の `hooks.Stop` 配下の `hooks` 配列末尾に追記する（既存 hook とは独立に並列実行される）:

```json
{
  "type": "command",
  "command": "/Users/bannzai/ghq/github.com/bannzai/notification-tmux/scripts/noroshi-hook-stop"
}
```

※ リポジトリ名の GitHub 上の rename (`notification-tmux` → `noroshi`) は未実施。rename 後は clone パスが変わるため、上記コマンドパスも合わせて更新すること。

スクリプトは tmux 外・アプリ未インストール環境では何もせず exit 0 する。動作確認は手動でも可能:

```bash
open -g "noroshi://stop?session=<session名>&window=@<window_id>"
```
