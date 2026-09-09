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

CI (`.github/workflows/ci-e2e.yml`) でも同じ verify.sh が tmux 3.6a (必須) と 3.4 / Homebrew 最新版 (参考) で走る。
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

## iOS アプリ (SuzuiOS)

`SuzuiOS/SuzuiOS.xcodeproj` (scheme `SuzuiOS`) は suzu の通知を iPhone から扱うクライアントの雛形。動作確認はすべて GitHub Actions の macOS runner 上で行い、ローカル simulator (`sim-boot`) を完了基準にしない。

### 単体テスト (CI)

`.github/workflows/ci-ios.yml` が `SuzuiOS/**` の変更を含む PR ごとに `xcodebuild test` (iOS Simulator) を回す。完了基準は PR のこの job が green であること。ログは artifact `ios-test-log` に残る。手元で同じことを試す場合は次を実行する (simulator は起動しない)。

```sh
xcodebuild build-for-testing -project SuzuiOS/SuzuiOS.xcodeproj -scheme SuzuiOS \
  -destination 'generic/platform=iOS Simulator' -derivedDataPath tmp/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

### UI の確認 (simtunnel)

画面の確認・操作・スクリーンショットは `/ios-simulator` skill を起点にし、特別な理由がない限り simtunnel (GitHub Actions macOS runner 上のリモート iOS Simulator。仕組みの SSOT は https://github.com/bannzai/simtunnel の PROJECT.md) で行う。caller workflow は `.github/workflows/simulator-session.yml` (`workflow_dispatch` のみ) で、`bannzai/simtunnel` の reusable workflow `session.yml` を commit SHA 固定で呼び、runner 上で `SuzuiOS` をビルドして Simulator に install / launch し、WebDriverAgent を起動して tailnet に参加する。

前提 (リポジトリ管理者の初回セットアップ):

1. リポジトリが public であること (macOS runner が無料になる。private では 10 倍の課金対象)
2. Tailscale 側で、このリポジトリの OIDC subject を許可する trust credential が発行済みであること (共有の owner ワイルドカード credential を使う場合、リポジトリの OIDC subject を immutable ID 形式に opt-in する: `gh api -X PUT repos/bannzai/notification-tmux/actions/oidc/customization/sub -F use_default=true -F use_immutable_subject=true`)
3. Actions secrets `TS_OIDC_CLIENT_ID` / `TS_OIDC_AUDIENCE` (整備済みの caller repo と同じ値) を登録する。空のまま実行すると空値で上書きされるため、登録前に非空を確認する

   ```sh
   [ -n "$TS_OIDC_CLIENT_ID" ] || { echo "TS_OIDC_CLIENT_ID is empty" >&2; exit 1; }
   [ -n "$TS_OIDC_AUDIENCE" ] || { echo "TS_OIDC_AUDIENCE is empty" >&2; exit 1; }
   gh secret set TS_OIDC_CLIENT_ID -R bannzai/notification-tmux --body "$TS_OIDC_CLIENT_ID"
   gh secret set TS_OIDC_AUDIENCE -R bannzai/notification-tmux --body "$TS_OIDC_AUDIENCE"
   ```

セッションの起動・確認・終了 (操作する Mac が tailnet に接続済みであることが前提。セッション名は `suzu-<worktree 名>` のように repo 横断で衝突しない名前にする):

```sh
# 検証対象のブランチを push してから起動する (--ref を省略すると main がビルドされる)
SIMTUNNEL_REPO=bannzai/notification-tmux ~/ghq/github.com/bannzai/simtunnel/local/simtunnel up suzu-issue-90 --ref <ブランチ> --wait

# WDA が ready であることを確認し、スクリーンショットを取る
bash ~/.claude/skills/ios-simulator/scripts/ios-wda.sh --session suzu-issue-90 status
bash ~/.claude/skills/ios-simulator/scripts/ios-wda.sh --session suzu-issue-90 shot ./tmp/screen.jpg

# 終了 (放置しても duration_minutes で自動終了するが、macOS runner の並列上限を CI と共有するため放置しない)
SIMTUNNEL_REPO=bannzai/notification-tmux ~/ghq/github.com/bannzai/simtunnel/local/simtunnel down suzu-issue-90
```

初回は WebDriverAgent のビルドキャッシュが無く準備に 15〜26 分かかる。確認結果を残す場合はスクリーンショットを PR に添付する。ローカル simulator (`sim-boot`) に倒してよいのは `/ios-simulator` skill Phase 1 が定める条件 (Maestro / XCUITest / `xcrun simctl` が検証の本体・検証対象が未 push・tailnet 未接続・repo が private・Secrets 未登録 等) に当たる場合だけで、その時は理由を PR に明記する。
