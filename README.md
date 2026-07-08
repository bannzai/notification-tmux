# notification-tmux (NTMUX)

通知センター付き tmux フロントエンド macOS アプリ。

- サイドバーに tmux の session(workspace) / window 一覧を表示する
- Claude Code の Stop hook から `ntmux://stop?session=<name>&window=@n` を受けて該当 window にバッジ数字を付ける（Dock アイコンには未読合計）
- バッジのある window をクリックすると、その session のターミナルを表示して `tmux select-window` で該当 window まで開く
- ターミナルは [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) の PTY で `tmux attach-session` する。session ごとに attach を維持するので切り替えは即時

## 技術構成

| レイヤ | 採用技術 | 役割 |
| --- | --- | --- |
| UI | SwiftUI (`Window` シーン + `NavigationSplitView`) | サイドバー (通知センター兼 workspace 一覧) と detail (ターミナル) |
| ターミナル描画 | SwiftTerm 1.13.0 (SPM) の `LocalProcessTerminalView` | forkpty で `tmux attach-session -t =<session>` した PTY を VT100/xterm エミュレーションで描画 |
| tmux 連携 | `Process` で tmux CLI を実行 (`TmuxClient`) | `list-sessions` / `list-windows -a` の 2 秒ポーリングで一覧構築、`select-window -t @n` でジャンプ |
| 通知イベント | URL スキーム `ntmux://` + `open -g` | Claude Code Stop hook → シェルスクリプト → LaunchServices → `onOpenURL` |
| 状態管理 | `AppState: ObservableObject` (@MainActor) | session 一覧・バッジ台帳 (windowID → 未読数)・選択状態 |
| テスト | XCTest (app を TEST_HOST とするユニットテスト) | パーサ / URL イベント / バッジ台帳 |

### データフロー

```
Claude Code (tmux pane 内で動作)
  └─ Stop hook ─▶ scripts/notification-tmux-hook-stop
                    ├─ $TMUX_PANE → tmux display-message で session名 / window_id (@n) を解決
                    └─ open -g "ntmux://stop?session=<name>&window=@n"   # フォーカスを奪わない
                                        │
NTMUX.app ◀─────────────────────────────┘ (onOpenURL)
  ├─ AppState
  │    ├─ sessions: [TmuxSession]     ← TmuxClient が 2 秒ポーリング
  │    ├─ badges: [windowID: Int]     ← stop イベントで加算 / window を開いたらクリア
  │    └─ selectedSessionName
  ├─ SidebarView — session → window ツリー + バッジ数字 (クリックで AppState.open(window:))
  └─ TerminalHostView (NSViewRepresentable)
       └─ TerminalSessionManager が session ごとに LocalProcessTerminalView をキャッシュ
            └─ PTY: tmux attach-session -t =<session>
                     (window 切替は tmux select-window -t @n。1 session = 1 client なので switch-client 不要)
```

### 設計上のポイント

- **window の識別子は tmux の window_id (`@n`) を SSOT にする**。サーバ全体でユニークで、session/window の改名・並べ替えの影響を受けない
- **session ごとに専属クライアント (PTY) を張る**ため、window ジャンプは `select-window -t @n` だけで完結する
- **非表示 session の terminal view も破棄しない**。SwiftTerm は非表示でも attach と VT パースを継続するので、切り替えは NSView の付け替えだけで即時
- App Sandbox は無効 (homebrew の tmux を PTY で exec するため。SwiftTerm 公式の推奨)
- 詳細な知見・ハマりどころは [docs/knowledge.md](docs/knowledge.md) を参照

### ディレクトリ構成

```
NTMUX/
  NTMUX.xcodeproj/          # Xcode 26 folder-synchronized 形式 (ファイル配置 = ターゲット追加)
  Info.plist                # CFBundleURLTypes (ntmux://)。GENERATE_INFOPLIST_FILE とマージされる
  NTMUX/
    NTMUXApp.swift          # @main。Window シーン、onOpenURL、テスト時 UI 起動ガード
    ContentView.swift       # NavigationSplitView
    SidebarView.swift       # session/window ツリー + バッジ
    TerminalHostView.swift  # SwiftTerm ラップと session ごとのビューキャッシュ
    AppState.swift          # ポーリング・バッジ台帳・選択状態
    TmuxClient.swift        # tmux CLI ラッパ
    TmuxModels.swift        # TmuxSession / TmuxWindow / StopEvent とパーサ
  NTMUXTests/
    TmuxModelsTests.swift
scripts/
  notification-tmux-hook-stop  # Claude Stop hook から呼ぶ通知スクリプト
.plans/                     # 実装プランと検証記録
docs/knowledge.md           # 作り直し用の知見まとめ
```

## 必要なもの

- macOS 26+ / Xcode 26+（初回ビルドで Metal Toolchain が無い場合は `xcodebuild -downloadComponent MetalToolchain`）
- tmux（homebrew: /opt/homebrew/bin/tmux または /usr/local/bin/tmux を自動解決）

## ビルドと起動

```bash
cd NTMUX
xcodebuild -project NTMUX.xcodeproj -scheme NTMUX -configuration Debug -derivedDataPath ../tmp/DerivedData build
open ../tmp/DerivedData/Build/Products/Debug/NTMUX.app
```

## テスト

```bash
cd NTMUX
xcodebuild -project NTMUX.xcodeproj -scheme NTMUX -derivedDataPath ../tmp/DerivedData test
```

## Claude Code hooks 連携

`~/.claude/settings.json` の `hooks.Stop` 配下の `hooks` 配列末尾に追記する（既存 hook とは独立に並列実行される）:

```json
{
  "type": "command",
  "command": "/Users/bannzai/ghq/github.com/bannzai/notification-tmux/scripts/notification-tmux-hook-stop"
}
```

スクリプトは tmux 外・アプリ未インストール環境では何もせず exit 0 する。動作確認は手動でも可能:

```bash
open -g "ntmux://stop?session=<session名>&window=@<window_id>"
```
