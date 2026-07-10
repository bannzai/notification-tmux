# 0005. 単一tmux clientをswitch-clientでsession切替する

## Status

Accepted

## Context

ADR 0001では、常時attachするtmux clientを最大1本に抑えるため、session切替ごとにSwiftTermのviewとclientを終了し、選択先へ再attachする方式を採用した。

しかしtmuxの`prefix + L`は、同じclientが直前に表示していたsessionへ戻る`switch-client -l`である。clientを再作成するとこの履歴が失われ、サイドバーからsessionを選択した後に直前のsessionへ戻れなかった。また、session切替のたびにPTYの生成と全画面再描画が発生していた。

SwiftTermの`LocalProcessTerminalView.process.shellPid`と、tmuxの`list-clients`が返す`#{client_pid}`を照合すれば、Noroshi自身のclient ttyを特定できる。

## Decision

SwiftTermのviewとtmux clientを1つだけ維持し、session切替は次のコマンドで同じclientの接続先を変更する。

```sh
tmux switch-client -c <client_tty> -t =<session>
```

- client ttyはSwiftTermの子PIDと`#{client_pid}`を照合して取得する
- tmux内の`prefix + L`やchoose-treeで接続先が変わった場合は、2秒ポーリングでclientの`#{session_name}`を取得し、アプリのsession選択へ反映する
- アプリの選択変更がSwiftUIのview更新を待っている間は、古いattach先で選択を戻さないよう、AppStateの選択とTerminalSessionManagerの反映済みsessionを比較する
- client特定前など`switch-client`できない場合は、表示継続を優先して従来どおりviewを終了し、選択先へ再attachする
- 常時attachするclientは引き続き最大1本とし、ADR 0001の性能上の制約を維持する

## Consequences

- 良い点: サイドバーでsessionを切り替えた後も`prefix + L`で直前のsessionへ戻れる
- 良い点: 通常のsession切替ではPTY生成と再attachが不要になり、同じterminal viewを再利用できる
- 良い点: tmux内からsessionを切り替えた場合もサイドバーの選択が追随する
- 良い点: client数、VTパース、描画対象はsession数にかかわらず最大1つのままになる
- 悪い点: session/window一覧の取得に加えて`list-clients`を2秒ごとに実行する
- 悪い点: client特定に失敗した切替では再attachへフォールバックするため、その切替に限って直前session履歴は保持されない
- 注意点: 同じSwiftTerm viewを複数sessionで使うため、過去出力を確実に参照する場合はtmuxのcopy-modeを使う
