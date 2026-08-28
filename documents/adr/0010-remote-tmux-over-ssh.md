# 0010. リモート tmux は ssh コマンドラップ + host 複合 ID で統合する

## Status

Accepted (GUI 版 Noroshi.app の決定。GUI 版は issue #76 で削除したため、現行の suzu には適用されない。記録として残す)

## Context

リモートホストの tmux session をローカルと同じようにサイドバーで一覧・attach・切替したい (issue #38)。あわせて、リモートで動く Claude Code の Stop hook 通知バッジ (issue #39) と、ローカル/リモートの session を並行して開くタブ (issue #40) も必要になった。

課題は 4 つ:

1. tmux の識別子 (session 名 / `@n`) はサーバ内でしか一意でなく、ローカルとリモートで衝突する
2. 現行の client 特定は「SwiftTerm の子プロセス PID = tmux client PID」だが、リモートではローカルの子は `ssh` であり成立しない
3. ssh の非対話 shell は locale が不定で、tmux が非 UTF-8 client 扱いになるとフォーマット出力の 0x1F 区切りを `_` にサニタイズする (issue #34 と同根。tmux 3.2a で実測)
4. リモートの Stop hook は Mac の `noroshi://` URL スキームに届かない

## Decision

### 一覧・操作: tmux CLI を ssh でラップする

`TmuxClient` に `TmuxHost` (.local / .remote) を持たせ、リモートは同じ tmux サブコマンドを `ssh <host> tmux -u <引数...>` として実行する。引数はリモート shell 向けに single quote でエスケープする (`#{...}` がコメント扱いされるため)。`-u` は上記 3 のサニタイズ対策で、リモート実行にだけ付ける。

ssh は `BatchMode=yes` (鍵認証前提)、`ConnectTimeout=5`、`ControlMaster=auto` + `ControlPersist=600` (接続の多重化で 2 回目以降を数十 ms にする) を共通オプションにする。対象 host は config の `remote-host` キー (複数可) で宣言する。

### 識別子: host 複合 ID

session / window の識別子を `<hostID>:<要素>` (例 `local:Focus`, `dev:@5`) の複合 ID にする (`TmuxID`)。tmux が session 名の `:` を `_` に置換し window_id が `@数字` である一方、host 側 (IPv6 等) には `:` が含まれ得るため、分解は最後の `:` で行う。バッジ台帳・サイドバー保存順・選択状態はすべて複合 ID をキーにし、旧形式 (ローカル session 名のみ) の保存値は読み込み時に `local:` を付けて移行する。

### attach と切替: ssh -t + tty 記録

リモート attach は SwiftTerm から `ssh -t <host> 'tty > ~/.noroshi-client-tty && exec tmux -u attach-session -f ignore-size -t =<name>'` を起動する。記録した tty が「Noroshi の client」の特定子となり、同一 host 内の session 切替は `switch-client -c <tty>` で行う (PID マッチの代替)。host をまたぐ切替は client を引き継げないため view を作り直す。

リモートの switch は ssh の同期実行になるため View 更新中には行わず、非同期で投げて失敗時だけ attach を作り直す (`Process.waitUntilExit` の runloop 再入は ADR 0009 と同じ制約)。

### 通知経路: ssh -R + リモート unix socket

host ごとに 127.0.0.1 の TCP listener を開き、`ssh -N -R ~/.noroshi.sock:127.0.0.1:<port>` でリモートの `$HOME/.noroshi.sock` をフォワードする。Stop hook スクリプトは socket が存在すればそこへ `session=<enc>&window=@n` を 1 行書き、無ければ従来の `open noroshi://` を使う (同一スクリプトで両対応)。発火元 host は「どの host の listener が受けたか」で確定するため、リモート側は自分の host 名を知らなくてよい。切断中に発火した通知は取りこぼす (再送しない)。

### タブ: 単一 attach を維持した選択状態のタブ化

タブ (issue #40) は「タブごとの選択 (session/window)」だけを持ち、attach は従来どおり常時最大 1 本 (ADR 0001 / 0005 の単一 attach を維持)。タブ切替は選択の切替であり、同一 host なら switch-client、host をまたぐなら作り直しで追従する。ControlPersist により再接続は速い。

検討した代替案:

- **tmux control mode (-CC) や独自エージェントのリモート常駐**: 実装・配布コストが大きい。手動の `ssh` + `tmux attach` がそのまま動く前提を保てる CLI ラップを採る
- **タブごとに attach を常時保持**: 非表示タブの attach client / VT パース / スクロールバックの多重コストが単一 attach 採用 (issue #6) の意図に反するため採らない
- **通知のポーリング (リモート状態ファイル監視)**: 経路は単純だがレイテンシと ssh 実行回数が増える。attach と独立に張れる `-R` フォワードを採る

## Consequences

- 良い点: リモート対応が「コマンドの前に ssh を付ける」に閉じ、tmux の照会・操作コードはローカルと共通のまま
- 良い点: host 複合 ID により同名 session / 同番 window が衝突せず、バッジ・選択・保存順が host をまたいで一貫する
- 注意点: 鍵認証 (ssh-agent) による非対話接続と、リモート非対話 shell の PATH で tmux が見えることが前提
- 注意点: リモートの tty 記録は host ごとに 1 ファイルのため、同じリモートユーザーへ複数の Noroshi インスタンスが同時 attach すると switch 対象が後勝ちになる
- 注意点: ssh 切断中のリモート通知は失われる。回収が必要になったら再送 (リモート側スプール) を別途設計する
- 注意点: ローカルの複合 hostID は予約名 `local` のため、同名の ssh 接続先は区別できない
