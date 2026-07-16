# CLAUDE.md

## 機能追加

- ユーザーが操作する機能を追加する時は、キーボードショートカットをセットで用意すること (issue #29)。メニューコマンドの追加先は `Noroshi/Noroshi/NoroshiApp.swift` の `NavigationCommands`。既存ショートカットと衝突しないことを確認する

## 動作確認

- 変更後は必ず [E2E.md](E2E.md) の手順で動作確認すること。ユニットテスト (`make test`) だけで完了としない
