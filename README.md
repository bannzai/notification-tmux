# Noroshi (狼煙) / suzu

Claude Code の通知を、普段の tmux の左に常駐するサイドバーへ集め、通知が上がった window へ駆けつけるための CLI ツール。バイナリ名は `suzu` (鈴)。

Claude Code が Stop すると狼煙が上がり、その狼煙が上がった window へ駆けつける、という体験から Noroshi と名付けた。macOS GUI アプリ (SwiftUI + SwiftTerm) だった版は、ターミナルエミュレータとしての調整 (描画・キーボード・IME・スクロール) のコストが大きく、issue #67 で nested tmux の TUI 版 (suzu) へ転換した。GUI 版のコードは issue #76 で削除し、設計の記録は [documents/adr/](documents/adr/) (GUI 版の決定) と [docs/knowledge.md](docs/knowledge.md) (v1 の知見) に残している。

## 仕組み

```
外側 tmux (別 socket -L suzu。~/.tmux.conf を読まず suzu/outer.go の設定だけを入れる)
└─ session "suzu" / window 0 (1 枚固定)
   ├─ 左 pane: suzu sidebar (通知一覧の TUI)
   └─ 右 pane: TMUX= を外して内側 (普段の) tmux server へ attach
```

- 外側 tmux は prefix を持たずキーを 1 つも掴まない (キーはすべて内側へ素通し)。内側でどれだけ window / session を移動してもサイドバーは動かない
- 通知の実体は内側 tmux の pane option `@claude-waiting`。Claude Code の hooks が `tmux set-option -p @claude-waiting "🔔..."` を書き、`suzu start` が内側へ注入する `after-set-option` hook が doorbell ファイルを touch する。サイドバーはそれを fsnotify で受けて一覧を再取得し、window の増減などツリーの変化は control mode client のイベントで受ける。定期ポーリングは行わない
- ジャンプは対象 session の current window を `select-window` で切り替え、右 pane の内側 client だけを `switch-client` でその session へ移す。普段の端末から内側へ attach している他の client の session は切り替えない (同じ session を見ている client からは current window の変更が見える)
- 既存ツールとの比較・アーキテクチャの選定は issue #67 を参照

## 必要なもの

- tmux 3.3 以降 (`allow-passthrough` を使う)。動作確認済みは 3.6a。CI では 3.4 (apt) と Homebrew 最新版も参考として実行する
- Go 1.25 以降 (ビルド時のみ)

## インストール

```sh
make cli
```

`suzu/bin/suzu` をビルドして `~/.local/bin/suzu` へ配置する (`~/.local/bin` を PATH に含める)。更新も `make cli` の再実行で行う。

リポジトリの public 化後は `go install github.com/bannzai/notification-tmux/suzu@latest` を配布経路にする予定 (issue #76 の後で扱う。現状は private のため未提供)。

## 使い方

```
suzu start    外側 tmux を構築して attach する (構築済みなら attach のみ = 冪等)。
              内側 tmux にジャンプキー・トグルキーと doorbell hook を注入する
              (メモリ上のみ。~/.tmux.conf は変更しない)
suzu stop     外側の suzu session を落とし、内側へ注入したキーバインドと hook を解除する
              (同じ socket の他の session、内側の session・window には一切触れない)
suzu toggle   サイドバーの表示/非表示を切り替える
suzu focus    {sidebar|inner|toggle} フォーカスを移す
suzu status   外側の状態を表示する
```

端末の起動時に額縁ごと開くには、端末のシェル起動コマンドで `suzu start` を先に実行する。Alacritty の例:

```toml
[terminal]
shell = { program = "/bin/zsh", args = ["-l", "-c", "~/.local/bin/suzu start; exec zsh -l"] }
```

detach で外側から戻ると後続の `exec zsh -l` が通常シェルになり、suzu 未インストール時もエラー表示の後シェルに落ちる。

右 pane の接続コマンドの既定値は `tmux attach` のため、内側 tmux に session が 1 つも無い状態 (再起動直後など) では右 pane が即座に終了して左右構成にならない。端末起動用の設定では、session が無ければ作る接続コマンドを `SUZU_INNER_TMUX_CMD` で指定するか、先に内側 session を作っておく。

```toml
[terminal]
shell = { program = "/bin/zsh", args = ["-l", "-c", "SUZU_INNER_TMUX_CMD='tmux new-session -A -s main' ~/.local/bin/suzu start; exec zsh -l"] }
```

### キー操作

内側 tmux (フォーカスが右) から:

| キー | 動作 |
| --- | --- |
| `prefix + N` | サイドバーへフォーカスを移す |
| `prefix + b` | サイドバーの表示/非表示を切り替える |

サイドバー (フォーカスが左) で:

| キー | 動作 |
| --- | --- |
| `j` / `k`、`↓` / `↑`、`C-n` / `C-p` | 選択を移動する (`C-n` / `C-p` は絞り込み入力中も効く) |
| `Enter` | 選択した window へ右 pane をジャンプさせる (フォーカスは左のまま) |
| `/` | session 名・window 名の部分一致で絞り込む。`Enter` で確定、`Esc` で解除、`C-u` で全消し、`C-w` で直前の単語を削除 |
| `q` / `Esc` / `prefix + N` | 内側へフォーカスを戻す (絞り込み中の `Esc` は解除を優先する) |
| `prefix + b` | サイドバーを閉じる |

prefix は内側 tmux の `prefix` オプションを写し取る (`None` や `F1` のような写せない prefix は `C-b` として扱う)。マウスクリックでも左右どちらへもフォーカスを移せる。`N` / `b` は環境変数で変えられる (後述)。

サイドバーは session 見出しの下に通知のある window を並べ、選択中の window は pane の末尾 10 行をプレビューする。

### Claude Code hooks 連携

suzu 自体は hook スクリプトを持たない。通知の表示・解除は `~/.claude/settings.json` の hooks から内側 tmux の pane option `@claude-waiting` を set / unset することで行う。`Stop` で set し、`UserPromptSubmit` で unset する最小構成:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -c '[ -n \"$TMUX\" ] && tmux set-option -p @claude-waiting \"🔔$(date +%H:%M)\" && tmux set-option -w @claude-waiting \"🔔$(date +%H:%M)\" || true'"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash -c '[ -n \"$TMUX\" ] && tmux set-option -pu @claude-waiting && tmux set-option -wu @claude-waiting || true'"
          }
        ]
      }
    ]
  }
}
```

- 値 (上の例では `🔔HH:MM`) がそのままサイドバーの window 行に表示される。Notification / PermissionRequest など他のイベントにも同じ形で足し、イベントごとに別の絵文字を使うと見分けやすい
- `-p` (pane) と `-w` (window) の両方に set する。suzu は pane ローカルに値を持つ pane を通知元として扱い、window option は同じ window の他の pane へ継承されるため status line 等の表示にも使える
- tmux 外で走る Claude Code では `$TMUX` が空のため何もしない

### 環境変数

すべて任意。`suzu start` がサイドバーや注入したキーバインドへ引き継ぐ。

| 変数 | 既定値 | 役割 |
| --- | --- | --- |
| `SUZU_OUTER_SOCKET` | `suzu` | 外側 socket 名 |
| `SUZU_INNER_TMUX` | `tmux` | 内側 server へ命令する時の tmux コマンド。検証用に `tmux -L <隔離socket>` へ差し替えられる |
| `SUZU_INNER_TMUX_CMD` | `$SUZU_INNER_TMUX attach` | 右 pane で実行する内側への接続コマンド |
| `SUZU_INNER_JUMP_KEY` | `N` | 内側に注入する「サイドバーへ」の prefix キー |
| `SUZU_INNER_TOGGLE_KEY` | `b` | 内側に注入する「表示/非表示」の prefix キー (既定が `b` なのは、ユーザーの `~/.tmux.conf` と tmux の既定 prefix table のどちらでも未使用だったため) |
| `SUZU_SIDEBAR_CMD` | `<suzu の絶対パス> sidebar` | 左 pane で実行するコマンド |
| `SUZU_SIDEBAR_WIDTH` | `40` | サイドバーの幅 |
| `SUZU_DOORBELL_FILE` | `${XDG_STATE_HOME:-$HOME/.local/state}/suzu/doorbell` | `@claude-waiting` の変化をサイドバーへ知らせる touch 先 |
| `SUZU_SSH_CMD` | `ssh -o BatchMode=yes -o ConnectTimeout=5 -o ControlMaster=auto ...` | リモート host へ接続する ssh コマンド (下記)。検証用に `tmux -L <隔離socket>` を実行する代役へ差し替えられる |

### リモート host (ssh 先) の tmux

`${XDG_CONFIG_HOME:-~/.config}/suzu/config` に `remote-host = <ssh 接続先>` を書くと (複数行で複数 host)、その host の tmux にある `@claude-waiting` の window もサイドバーに `▸ <host>:<session>` の見出しで並ぶ。設定はサイドバーの起動時に読むため、変更後は `suzu toggle` を 2 回 (閉じて開く) で読み直す。

- 一覧は `ssh <host> tmux -u list-panes ...`、更新の受信は host ごとの control mode client (`ssh <host> tmux -C attach`) と `refresh-client -B` の購読で行い、ポーリングはしない。リモート側の Claude Code hook はローカルと同じ `@claude-waiting` を set するだけでよく、suzu 側の hook 注入や socket の転送は要らない
- Enter で内側 tmux に `ssh -t <host> tmux attach -t <session>` を実行する window (`<host>:<session>`) を開き、既にあればそれを選ぶ
- 鍵認証 (ssh-agent) で入れること、リモートの非対話 shell の PATH で tmux が見えることが前提。繋がらない host は `<host>: 未接続` と出て、他の一覧は止まらない。`suzu serve` はローカルの通知だけを配る

## iPhone から通知ボタンで操作する (suzu serve)

TUI サイドバーの通知データ層を daemon (`suzu serve`) として起動すると、iPhone のブラウザで「通知一覧 + 専用ボタン」の画面が開き、ボタンをタップするだけで Mac 側の tmux へコマンドを流せる (issue #72)。SSH で TUI を触る必要はない。

- 通知ごとに pane のプレビュー (末尾 10 行) と、「ジャンプ」(該当 window へ `select-window` + `switch-client`)、定型キー (`Enter` / `Esc` / `y` / `n` / `1` / `2` / `3` を通知元 pane へ `send-keys`) のボタンが並ぶ
- 一覧の更新は SSE の push (サイドバーと同じ doorbell + control mode 基盤) で、ポーリングしない
- キー送信は誤タップ対策として 2 回タップ (1 回目で「y を送る?」に変わり、3 秒以内の 2 回目で送信) にしている

```bash
make cli
SUZU_SERVE_ADDR=$(tailscale ip -4):7788 suzu serve
# → suzu serve: http://100.x.y.z:7788/?token=<token>  この URL を iPhone で開く
```

- 到達性は Tailscale 等の閉じた網を前提にし、既定の待ち受けは `127.0.0.1:7788` (公開サーバーは立てない)。iPhone から届かせるには `SUZU_SERVE_ADDR` に Tailscale の IP を指定する
- 認証はトークン 1 本。`SUZU_SERVE_TOKEN` で固定でき、未指定なら生成して `${XDG_STATE_HOME:-~/.local/state}/suzu/serve-token` に保存し (0600)、再起動しても同じトークンを使う。起動時に URL に載せて表示する。初回に `/?token=...` を開くと cookie に保存され、以降は `/` だけで開ける。iOS の「ホーム画面に追加」にも対応 (manifest の start_url がトークンを持つため、追加後も認証し直しが要らない。トークンを変えた時はホーム画面のアプリを入れ直す)
- `suzu start` していなくても動く (`@claude-waiting` の変化を拾う doorbell hook は serve 自身も内側 tmux へ注入する)
- 送れるキーは固定のホワイトリストだけで、対象も「今の通知一覧に載っている pane」に限る。設計の詳細は `suzu/serve.go` 冒頭のコメントを参照

## 開発

```sh
make build-cli    # suzu/bin/suzu をビルドする
make test-cli     # go vet + go test
make verify-cli   # 隔離 socket の tmux だけを使う E2E (suzu/verify.sh)。普段の tmux には触れない
make cli          # ビルドして ~/.local/bin へ配置する
make clean        # ビルド成果物を消す
```

変更後の動作確認手順は [E2E.md](E2E.md) を参照。CI は `.github/workflows/ci-test.yml` (gofmt / vet / test / build) と `ci-e2e.yml` (verify.sh を tmux 3.6a / 3.4 / 最新版で実行) が Linux runner で走る。

### ディレクトリ構成

```
suzu/              # Go 実装 (各ファイル先頭のコメントが役割を説明する) と E2E の verify.sh
documents/adr/     # 設計判断の記録 (主に GUI 版 Noroshi.app の決定。0008 / 0009 は suzu にも引き継がれている。各 ADR の Status 参照)
docs/knowledge.md  # v1 (NTMUX) 開発時の tmux 連携の知見
```
