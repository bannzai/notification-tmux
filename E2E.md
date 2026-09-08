# E2E (CI で検証する範囲)

suzu の変更は PR を作成し、その変更で起動した CI の必須 job がすべて green であることを完了基準にする。ローカルでの手動確認 (普段の端末で `suzu start` して目で見る等) は求めない。

CI は `suzu/**`・`Makefile`・各 workflow ファイルの変更で起動する (`paths` フィルタ)。これらに触れない PR (ドキュメントのみ等) では ci-test / ci-e2e は起動せず、起動した job が無いことがそのまま完了基準になる。

## CI で何が検証されるか

### ci-test (`.github/workflows/ci-test.yml`)

`gofmt -l suzu` の差分が無いこと、`make test-cli` (go vet + 単体テスト)、`make build-cli` が通ること。

### ci-e2e (`.github/workflows/ci-e2e.yml`)

`make verify-cli` で `suzu/verify.sh` を実行する。verify.sh は隔離 socket の tmux だけを使い (内側の代役・suzu が構築する外側・端末エミュレータの代役・余分な実 client の 4 つ)、runner の tmux 設定には触れない。全項目 PASS で exit 0。失敗時は最初の失敗時点の状態 (外側 pane・サイドバー画面・内側 session・hook・キー) を標準出力に dump するので、切り分けは CI のログで行う。ログだけで足りない時に限り、手元で `make verify-cli` を実行すると同じ検査を再現できる。

必須 job は `ci-e2e.yml` で `continue-on-error` を付けていない job (ユーザー環境と同じ tmux 3.6a を公式 tarball からビルドしたもの)。apt の 3.4 と Homebrew 最新版は参考 job で、落ちても PR を止めない。必須 job では通知一覧・フィルタ入力中・狭い画面でのスクロール・Claude / Watchers セクションの代表状態を `freeze` で PNG にし、`suzu-sidebar-screenshots` artifact として 14 日間保存する。

verify.sh が検証する対象 (各節の詳細は verify.sh の `=== N. ... ===` 見出しと PASS メッセージを正とする):

- 額縁の構築と冪等性: `suzu start` で外側が左右 2 pane になる、再実行で pane が増えず外側の設定が再適用される、内側への prefix バインド (`prefix + N` / `prefix + b`) と after-set-option hook の注入、detach 等で消えた内側 pane の作り直し
- 通知: `@claude-waiting` の set / unset がサイドバーの session 見出し・window 行・件数・pane プレビューに反映される (非 attach session への push 経路、複数 pane の window では通知元 pane をプレビュー、名前で target にできない session へのジャンプ)
- 実キー経路: 端末エミュレータの代役の pane へ `send-keys` で書き込み、外側を素通りして内側へ届くこと (`prefix + c` で内側の window が増える、実端末のタイトルに内側のタイトルが出る)
- フォーカスと描画: `prefix + N` の往復、`q` / `Esc` で内側へ戻る、非アクティブ側が暗く描画される、太罫線の境界線
- ジャンプ: `Enter` で右 pane の client だけが対象 window へ切り替わり、他の実 client は切り替わらない。フォーカスはサイドバーに留まる
- 一覧の操作: `j` / `k` で選択とプレビューが移る、`/` によるフィルタ (確定・`Esc` で解除・入力中の `ctrl+n`)、狭い画面でのスクロールとインジケータ、pane 幅を超える window 名・プレビュー行の切り詰め
- 表示/非表示: 内側・サイドバーの両方からの `prefix + b` と `suzu toggle`。開いた時にサイドバーへフォーカスが当たる
- セクション: プロセス名で一致する pane (Claude 組み込み・設定ファイルの汎用 section) が並び、実行中 / 入力待ちの判定が切り替わる、セクションの行からのジャンプが検出 pane を select-pane する、プロセス終了で消える
- コピーモード: `prefix + [` が外側を素通りして内側がコピーモードに入り、選択・コピーした行が内側の paste buffer に入る。外側の pane はコピーモードに入らない
- OSC52: 内側のコピーで出る OSC52 が外側を透過し、実端末の代役の pane 出力 (`pipe-pane` で捕捉) に選択した行の base64 として現れる
- マウス: 実端末が送る SGR シーケンス (`CSI < ボタン ; 列 ; 行 M/m`) を書き込み、サイドバーのクリックでフォーカスが左へ、右 pane のクリックで右へ移る、右 pane のホイールが内側 tmux に届く
- `suzu serve` (HTTP/SSE): curl を iPhone の代役にして、トークン無しの拒否、`/?token=` の cookie 化、通知一覧の取得、`@claude-waiting` の設定・解除が SSE で届く、ボタン相当の POST (ホワイトリスト外のキーは 400・通知に無い pane は 404) が隔離 tmux にジャンプ・キー送信を行う、終了後にプロセスが残らない
- `suzu stop`: 自分が入れたバインド・hook・外側 session だけを片付け、ユーザー自身のバインド・hook・同じ socket の無関係な session・内側 server には触れない。suzu のものでないバインドの上書き時は警告する
- 起動経路: tty から `suzu start` すると外側へ attach する、tmux の中からの起動は二重ネストのガードで止まる
- 壊れた socket からの自己修復: server が死んで socket ファイルだけ残った状態・socket でないファイルで塞がれた状態 (macOS 固有。Linux では tmux 自身が片付ける) からの起動、修復できない時の tmux の stderr と対処ヒントの表示

## GHA で再現できない対象外の項目

次は端末エミュレータやブラウザの側の実装に依存し、GitHub Actions の runner (端末エミュレータも IME も無い) では再現できないため CI の対象外とする。手動確認の手順としては残さない。これらに関係する変更でも、完了基準は上記の CI green で変わらない。

- 日本語 IME の変換前文字列の描画: 変換前文字列は端末エミュレータが描くもので、tmux の中には現れない。verify.sh の端末代役 (tmux の pane) には IME が無い
- OSC52 を受けた端末がシステムのクリップボードへ書き込むか: 端末エミュレータの実装。verify.sh が確かめるのは OSC52 が実端末 (の代役) に届くところまで
- 端末がマウス操作を SGR シーケンスとして送るか: 端末エミュレータの実装。verify.sh はシーケンスを直接書き込んで、届いた後の suzu と tmux の挙動を検証する
- `suzu/web/index.html` のブラウザ描画: E2E にブラウザが無い。HTTP/SSE とボタン操作の経路は curl で検証する。ブラウザ表示の検証が必要になった時は runner 上の headless ブラウザを使う経路を別途検討する

次は再現できないのではなく、まだ CI の必須 job に入っていない項目。追加されるまでも完了基準は上記の CI green のままで、ローカルでの代替確認は求めない。

- macOS + Homebrew の tmux での実行: リポジトリが private の間は macOS runner が課金対象になるため、public 化 (#85) の後に macOS job を追加して必須にする (#86)。それまでは Linuxbrew の参考 job が代役
- リモート ssh host の経路 (#75 / #80): 機能自体が未マージで main に存在しない。マージ後に runner 上の sshd で verify.sh に追加する (#87)
