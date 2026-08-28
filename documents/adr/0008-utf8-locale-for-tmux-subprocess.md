# 0008. tmux 子プロセスに UTF-8 locale を明示する

## Status

Accepted (GUI 版 Noroshi.app の決定。GUI 版は issue #76 で削除したため、現行の suzu には適用されない。記録として残す)

## Context

Finder・Spotlight・Dock から起動した app は launchd の最小環境変数で動き、`LANG` / `LC_ALL` / `LC_CTYPE` を持たない。この環境で tmux CLI を実行すると、tmux はクライアントを非 UTF-8 として扱い、出力中の非印字文字を `_` へサニタイズする。

Noroshi は一覧取得の `-F` format にフィールド区切りとして ASCII Unit Separator 0x1F (`TmuxFormat.fieldSeparator`) を使っているため、この置換で区切りが失われる。コマンド自体は exit 0 のままなのでエラー経路に乗らず、「エラー表示なしで session 0 件」という症状になる (issue #34 で `make install` した app を Spotlight から起動して発覚)。

シェルから `make run` / `open` で起動した場合は、呼び出し元シェルの環境変数 (LANG 等) が app に引き継がれるため顕在化しない。実測では次のとおり区切りバイトが変わる。

| 実行環境 | `-F '#{session_name}\x1f...'` の区切り |
| --- | --- |
| LANG なし・TMUX なし (launchd 起動相当) | `0x5f` (`_` に化ける) |
| `LANG=ja_JP.UTF-8` あり | `0x1f` (正常) |
| `TMUX` あり | `0x1f` (正常) |

## Decision

`TmuxClient.run` の子プロセス環境を `TmuxClient.childEnvironment` で組み立て、`LC_ALL` / `LC_CTYPE` / `LANG` のいずれも無い時だけ `LC_CTYPE=en_US.UTF-8` を追加する。

- 文字種 locale は LC_ALL > LC_CTYPE > LANG の優先で決まる (POSIX) ため、いずれかが既にあればユーザーの設定を尊重する
- 値は PTY 側の既定と揃える。ターミナル attach (SwiftTerm の `LocalProcess`) は environment 未指定時に `Terminal.getEnvironmentVariables` が常に `LANG=en_US.UTF-8` を設定しており、同じ問題を持たないため対処不要
- 区切り文字を印字可能文字へ変える案は、session/window 名に混入し得ない文字が他に無いため採らない

## Consequences

- 良い点: Spotlight・Dock・`noroshi://` の cold launch など、シェルを経由しない起動でも一覧が取得できる
- 良い点: ユーザーが明示した locale 設定はそのまま尊重される
- 注意点: ユーザーが非 UTF-8 locale (例: `LANG=C`) を明示している環境では従来どおりサニタイズが起きる。その場合は設定由来として許容する
