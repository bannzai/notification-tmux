# E2E 動作確認手順

suzu の変更後は、ユニットテスト (`make test-cli`) だけで完了にせず、実 tmux で確認する。

## 自動検証 (隔離 socket)

```sh
make verify-cli
```

suzu をビルドして `suzu/verify.sh` を実行する。verify.sh は隔離 socket の tmux だけを使い、普段の tmux (default socket) や `~/.tmux.conf` には触れない。全項目 PASS で exit 0。失敗時は最初の失敗時点の状態 (外側 pane・サイドバー画面・内側 session・hook・キー) を標準出力に dump する。

CI (`.github/workflows/ci-e2e.yml`) でも同じ verify.sh が tmux 3.6a (必須) と 3.4 / Homebrew 最新版 (参考) で走る。

## 手動確認 (実端末)

verify.sh はキー入力の実機経路 (IME・コピーモード・マウス・OSC52) を対象外にしているため、これらに関係する変更は普段の端末で確認する。

1. `make cli` で `~/.local/bin/suzu` を更新する。
2. 新しい端末 (Alacritty 等) を開き `suzu start` を実行する。左にサイドバー、右に普段の tmux が表示される。既に外側が構築済みなら attach だけ行う (冪等)。`suzu status` で外側の状態を確認できる。
3. 内側 tmux で `prefix + N` を押すとサイドバーへフォーカスが移り、`q` / `Esc` / `prefix + N` で内側へ戻ることを確認する。`prefix + b` で表示/非表示が切り替わることを、内側フォーカス・サイドバーフォーカスの両方から確認する。
4. 通知は内側 tmux の pane option `@claude-waiting` で表現する。任意の pane で次を実行し、サイドバーに session 見出しと window 行が現れ、`Enter` で右 pane がその window へ切り替わることを確認する (フォーカスは左のまま)。解除すると一覧から消える。

   ```sh
   tmux set-option -p @claude-waiting "🔔test" && tmux set-option -w @claude-waiting "🔔test"
   tmux set-option -pu @claude-waiting && tmux set-option -wu @claude-waiting
   ```

5. コピーモードが関係する変更では、内側で `prefix + [` に入り、選択・コピーした内容が実端末のクリップボードに入ること (OSC52 の透過) を確認する。
6. マウスが関係する変更では、サイドバーのクリックでフォーカスが左へ、右 pane のクリックで右へ移ること、右 pane のホイールスクロールが内側 tmux に届くことを確認する。
7. 日本語入力が関係する変更では、右 pane のシェルで IME の変換前文字列が崩れずに表示されることを確認する。
8. 確認結果を残す場合は、サイドバー pane の描画をテキストで取得して PR に貼る。

   ```sh
   tmux -L suzu capture-pane -p -t "$(tmux -L suzu list-panes -t suzu:0 -f '#{@suzu-sidebar}' -F '#{pane_id}' | head -1)"
   ```

## 後片付け

`suzu stop` で外側の session を落とし、内側へ注入したキーバインドと hook を解除する。内側の session・window には触れない。普段使いの端末では `suzu start` を起動時に実行する設定 (Alacritty の `shell` 等) があれば、端末を開き直すだけで復帰する。
