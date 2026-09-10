# AGENTS.md

## 機能追加

- ユーザーが操作する機能には、既存キーと衝突しないキー操作とフッターの案内を用意する (issue #29)。内側 tmux から呼ぶ操作は `suzu start` が注入する prefix バインドにも用意する

## 動作確認

- 変更後は必ず [E2E.md](E2E.md) の手順で動作確認すること。ユニットテスト (`make test-cli`) だけで完了としない
- iOS アプリ (`SuzuiOS/`) の変更は、単体テストを CI (`.github/workflows/ci-ios.yml` の `xcodebuild test`) で、UI の確認を `/ios-simulator` skill を起点にした simtunnel (GitHub Actions macOS runner 上のリモート iOS Simulator。起動 workflow: `.github/workflows/simulator-session.yml`) で行う。ローカル simulator (`sim-boot`) を完了基準にしない。手順とローカルに倒してよい条件は [E2E.md](E2E.md)「iOS アプリ (SuzuiOS)」を参照する

<!-- ai-review-config begin -->
<!--
このブロックは自動生成です。直接編集せず、テンプレートを更新してから再生成してください。
内容は AI コードレビュー時の挙動指示であり、コードベース自体への規約ではありません。
-->

## レビュー時の応答スタイル

- 応答は日本語で行う

## レビュー範囲外

以下は自動レビューで指摘しない (別の検出経路があるため):

- コンパイルエラー・型エラー (ローカル/CI のビルドで検出される)
- Lint/フォーマット違反 (リンター・フォーマッターで検出される)
<!-- ai-review-config end -->
