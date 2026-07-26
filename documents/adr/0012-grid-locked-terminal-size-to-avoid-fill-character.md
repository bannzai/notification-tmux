# 0012. terminal の寸法を window 格子に固定し、fill-character の敷き詰めを防ぐ

## Status

Accepted

## Context

Noroshi は `attach-session -f ignore-size` で attach する (ADR 0009)。window の格子サイズが Noroshi の terminal 格子より**小さい**場合、tmux は client の余った領域へ fill-character (既定 `·`) を敷き詰めるため、画面の右端と下部が `·` で埋まる (issue #60)。detach 状態で作られた session (`default-size` の 80x24) や、小さい端末で使っている session を表示すると顕著になる。

ADR 0009 のフォント自動縮小は「window が client より大きい」方向の対策で、この逆方向は未対応だった。

検討した代替案:

- **`fill-character ' '` を設定する**: tmux サーバの window オプションを書き換えることになり、Noroshi 終了後も残る・ユーザー自身の設定を上書きする・リモート host にも波及する。他 client へ影響を出さない方針 (ADR 0001, 0009) に反するため採らない
- **フォントの自動拡大で格子を window へ近づける**: 縦横比が一致しない限り余白は残り、小さい window で巨大なフォントになるため採らない
- **`resize-window` / `window-size` の変更**: 他 client へ影響するため採らない (ADR 0009 と同じ理由)

## Decision

attach 方式は変えず、表示側で terminal view の frame を「window 格子 + status line がちょうど収まる寸法」へ固定する。client の格子が window に一致するため、tmux に余白 (fill 対象領域) 自体が生まれない。

- 寸法は `TerminalFontFit.constrainedViewSize` が「セル寸法 × 格子 + scroller 幅」で求める。行数は `#{window_height}` に `#{status}` から解決した status line 行数を加える (client は window と status line を合わせて表示するため。フィット計算 (ADR 0009) も同じ行数を使う)
- Auto Layout の優先度差で実現する: コンテナ全面フィル (defaultLow) < 格子固定 (defaultHigh) < コンテナの縁 (required)。格子が不明な間は従来どおり全面へ広がり、window がコンテナより大きい間は格子固定が負けてコンテナ全面 (ADR 0009 のパン許容と同じ状態) に留まる
- terminal が覆わなくなった余白は、コンテナ (`TerminalContainerView`) が terminal と同じ背景色 (`nativeBackgroundColor`) で塗る
- コンテナ拡大時は terminal の frame が変わらず再フィットが走らないため、コンテナ側の `setFrameSize` でも `scheduleRefitFont` を呼ぶ

## Consequences

- 良い点: window が小さくても余白が `·` で埋まらず、terminal の背景色として見える
- 良い点: client と window の格子が一致するため、桁数不一致による折返し崩れ (ADR 0006 が防御していた症状) が「window がコンテナに収まる」通常ケースでは起きなくなる
- 良い点: tmux サーバ側の設定・window サイズには一切影響しない
- 注意点: `#{status}` を format で解決できない (空文字を返す) 古い tmux では格子不明として扱い、フォントフィットも格子固定も行わない (ignore-size が要求する tmux 3.2+ では解決できる)
- 注意点: 格子はポーリング (2 秒) 追随のため、他 client での resize 直後は一時的に余白へ fill が見えることがある
