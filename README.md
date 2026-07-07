# notification-tmux (NTMUX)

通知センター付き tmux フロントエンド macOS アプリ。

- サイドバーに tmux の session(workspace) / window 一覧を表示する
- Claude Code の Stop hook から `ntmux://stop?session=<name>&window=@n` を受けて該当 window にバッジ数字を付ける（Dock アイコンには未読合計）
- バッジのある window をクリックすると、その session のターミナルを表示して `tmux select-window` で該当 window まで開く
- ターミナルは [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) の PTY で `tmux attach-session` する。session ごとに attach を維持するので切り替えは即時

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
