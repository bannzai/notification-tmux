# AGENTS.md

## 動作確認

- 変更後は必ず E2E で動作確認をすること。ユニットテスト (`make test`) だけで完了としない
  - `make run` でビルドして Noroshi.app を起動する
  - サイドバーに実 tmux の session/window 一覧が表示されることを確認する
  - `open -g "noroshi://stop?session=<session名>&window=@<window_id>"` で該当 window にバッジが付くことを確認する
