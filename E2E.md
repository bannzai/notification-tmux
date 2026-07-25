# E2E 動作確認手順

Noroshi の変更後は、ユニットテストだけで完了にせず、実 tmux と起動中のアプリで確認する。

## 事前準備

専用の tmux session を作成し、ユーザーが作業中の session には接続しない。

```sh
tmux new-session -d -s noroshi-e2e
tmux new-window -t noroshi-e2e -n notification
tmux list-windows -t noroshi-e2e -F '#{session_name} #{window_id} #{window_name}'
```

出力から session 名と window ID (`@数字`) を控える。

## 実行手順

1. `make run` を実行してビルドし、Noroshi.app を起動する。
2. Noroshi のウィンドウを最前面に表示する。
3. サイドバーに実 tmux の `noroshi-e2e` session と window が表示され、右側に terminal が表示されることを確認する。
4. 控えた値を使って通知 URL を実行する。

   ```sh
   open -g "noroshi://stop?session=noroshi-e2e&window=@<window_id>"
   ```

5. 対象 window に未読バッジが付き、対象 window を選択するとバッジが消えることを確認する。
6. タブが関係する変更では、「移動 > 新規タブ」(cmd+T) でタブバーが表示され、タブ切替 (ctrl+tab) で選択 session がタブごとに保たれ、「File > タブを閉じる」(cmd+W) で閉じられることを確認する。
7. リモートホスト (ssh) が関係する変更では、鍵認証で入れる ssh 先がある場合のみ `~/.config/noroshi/config` に `remote-host = <host>` を追記し、リモート session の一覧表示・attach・切替を確認する (確認後に追記を戻す)。ssh 先が無い環境ではユニットテストとローカル経路の確認までとし、報告に未検証と明記する。
8. 日本語 IME が関係する変更では、変換前の文字列がキャレット付近に表示され、文字を短縮・削除したときに古い文字が残らないことを確認する。
9. 確認結果を残すため、Noroshi の画面が見える状態でスクリーンショットを撮る。

   ```sh
   mkdir -p tmp/e2e
   screencapture -x tmp/e2e/noroshi-e2e.png
   ```

   `screencapture -x` は画面全体を撮影するため、Noroshi を最前面にしてから実行する。ウィンドウ単位で撮影する場合は `screencapture -l <window_id> -x tmp/e2e/noroshi-e2e.png` を使う。

## 並列実行時の注意

worktree が分かれていても、Agent 間で macOS の GUI セッション、最前面ウィンドウ、同じ bundle identifier の Noroshi、tmux サーバは共有される。複数 Agent が同時に E2E を実行すると、最前面や入力先を取り合い、別の Agent の画面を撮影する可能性がある。

- E2E とスクリーンショットは同じ GUI セッションで同時に実行しない。
- 可能なら Agent ごとに専用 tmux session と専用 macOS ユーザーセッションを使う。
- `screencapture -l` を使う場合も、対象ウィンドウが最小化・非表示になっていないことを確認する。

## PR / Issue へのスクリーンショット添付

リポジトリ owner が `bannzai` の場合だけ、`gh-r2-image` を使って R2 にアップロードする。owner は次で確認する。

```sh
gh repo view --json owner -q .owner.login
```

`bannzai` と表示された場合:

```sh
gh-r2-image upload --no-copy --width 600 tmp/e2e/noroshi-e2e.png
```

出力された Markdown または HTML を PR / Issue の本文へ貼り付ける。`--no-copy` は必ず付ける。owner が `bannzai` 以外の場合は R2 へアップロードせず、本文にスクリーンショットの確認結果を文章で記載する。

## 後片付け

```sh
tmux kill-session -t noroshi-e2e
```
