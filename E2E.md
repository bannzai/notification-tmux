# E2E 動作確認手順

suzu の変更後は、ユニットテスト (`make test-cli`) だけで完了にせず、実 tmux で確認する。

## 自動検証 (隔離 socket)

```sh
make verify-cli
```

suzu をビルドして `suzu/verify.sh` を実行する。verify.sh は隔離 socket の tmux だけを使い、普段の tmux (default socket) や `~/.tmux.conf` には触れない。全項目 PASS で exit 0。失敗時は最初の失敗時点の状態 (外側 pane・サイドバー画面・内側 session・hook・キー) を標準出力に dump する。

キー入力の実機経路も、端末エミュレータの代役 (隔離 socket の tmux) の pane へ `send-keys` で書き込む形で verify.sh が再現する。

- コピーモード: `prefix + [` が外側を素通りして内側がコピーモードに入り、選択・コピーした行が内側の paste buffer に入ること
- OSC52: 内側のコピーで出る OSC52 が外側を透過し、実端末の代役の pane 出力 (`pipe-pane` で捕捉) に選択した行の base64 として現れること
- マウス: 実端末が送る SGR シーケンス (`CSI < ボタン ; 列 ; 行 M/m`) を書き込み、サイドバーのクリックでフォーカスが左へ、右 pane のクリックで右へ移ること、右 pane のホイールが内側 tmux に届くこと
- `suzu serve` (HTTP/SSE): curl を iPhone の代役にして、トークン無しの拒否、通知一覧の取得、`@claude-waiting` の設定・解除が SSE で届くこと、ボタン相当の POST が隔離 tmux にジャンプ・キー送信を行うこと

CI (`.github/workflows/ci-e2e.yml`) でも同じ verify.sh が Linux の tmux 3.6a (必須)、macOS + Homebrew の最新版 (必須。ユーザーの実環境と同じ構成)、Linux の 3.4 (参考) で走る。
必須の tmux 3.6a では、通知一覧、フィルタ入力中、狭い画面でのスクロール、Claude / Watchers セクションの代表状態を `freeze` で PNG にし、`suzu-sidebar-screenshots` artifact として 14 日間保存する。

`suzu/web/index.html` のブラウザ描画は CI の対象外とする。HTTP/SSE とボタン操作の経路は curl で検証するが、ブラウザ表示の検証が必要になった時は runner 上の headless ブラウザを使う経路を別途検討する。

## 手動確認 (実端末)

verify.sh は IME (変換前文字列の描画) を対象外にしているため、日本語入力に関係する変更は普段の端末で確認する。次の 2 点は端末エミュレータ側の実装に依存するため verify.sh の対象外で、必要なら普段の端末で確認する。

- OSC52 を受けた端末が実際にシステムのクリップボードへ書き込むか (verify.sh が確かめるのは OSC52 が端末に届くところまで)
- 端末がマウス操作を SGR シーケンスとして送るか (verify.sh はシーケンスを直接書き込む)

1. `make cli` で `~/.local/bin/suzu` を更新する。
2. 新しい端末 (Alacritty 等) を開き `suzu start` を実行する。左にサイドバー、右に普段の tmux が表示される。既に外側が構築済みなら attach だけ行う (冪等)。`suzu status` で外側の状態を確認できる。
3. 内側 tmux で `prefix + N` を押すとサイドバーへフォーカスが移り、`q` / `Esc` / `prefix + N` で内側へ戻ることを確認する。`prefix + b` で表示/非表示が切り替わることを、内側フォーカス・サイドバーフォーカスの両方から確認する。
4. 通知は内側 tmux の pane option `@claude-waiting` で表現する。任意の pane で次を実行し、サイドバーに session 見出しと window 行が現れ、`Enter` で右 pane がその window へ切り替わることを確認する (フォーカスは左のまま)。解除すると一覧から消える。

   ```sh
   tmux set-option -p @claude-waiting "🔔test" && tmux set-option -w @claude-waiting "🔔test"
   tmux set-option -pu @claude-waiting && tmux set-option -wu @claude-waiting
   ```

5. 日本語入力が関係する変更では、右 pane のシェルで IME の変換前文字列が崩れずに表示されることを確認する。
6. 確認結果を残す場合は、サイドバー pane の描画をテキストで取得して PR に貼る。

   ```sh
   tmux -L suzu capture-pane -p -t "$(tmux -L suzu list-panes -t suzu:0 -f '#{@suzu-sidebar}' -F '#{pane_id}' | head -1)"
   ```

## 後片付け

`suzu stop` で外側の session を落とし、内側へ注入したキーバインドと hook を解除する。内側の session・window には触れない。普段使いの端末では `suzu start` を起動時に実行する設定 (Alacritty の `shell` 等) があれば、端末を開き直すだけで復帰する。

## リモート host (issue #75) の実機確認

鍵認証で入れる ssh 先がある場合のみ行う。無い環境では `make verify-cli` (ssh を隔離 socket の tmux へ差し替えた代役での検証) までとし、報告に未検証と明記する。

1. リモート側の準備: リモートの `~/.claude/settings.json` に、ローカルと同じ `@claude-waiting` を set する hook (`tmux set-option -p @claude-waiting "🔔" && tmux set-option -w @claude-waiting "🔔"`) を入れる。suzu 側の hook 注入や socket の転送は不要で、リモートの tmux に option が set されれば control mode の購読で届く。
2. `~/.config/suzu/config` に `remote-host = <host>` を追記する。remote-host はサイドバーの起動時に読むため、`suzu toggle` を 2 回 (閉じて開く) で読み直させる。
3. リモートの tmux (Claude Code の hook 相当) で `tmux set-option -p @claude-waiting '🔔'; tmux set-option -w @claude-waiting '🔔'` を実行し、サイドバーに `▸ <host>:<session> (1)` の見出しと window 行が出ること、選択するとリモート pane のプレビューが出ることを確認する。購読は tmux 内部の 1 秒タイマーで評価されるため、反映は最大約 1 秒遅れる。
4. サイドバーでその通知に Enter し、内側 tmux に `<host>:<session>` という名前の window が開いてリモート session に attach され、右 pane で前面になることを確認する。リモート側でも通知の window がカレントになっていること、もう一度 Enter しても window が増えず既存の window が選ばれることを確認する。
5. リモートで `tmux set-option -pu @claude-waiting; tmux set-option -wu @claude-waiting` (解除) し、サイドバーから消えることを確認する。
6. 存在しない host (例: `remote-host = no-such-host`) を追記して読み直し、サイドバーに `no-such-host: 未接続` が出て、ローカルと他の host の一覧が止まらないことを確認する。
7. 確認後に `remote-host` の追記を戻し、`suzu toggle` を 2 回で読み直す。
