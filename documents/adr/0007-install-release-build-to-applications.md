# 0007. 普段使いは /Applications への Release ビルド配置で行う

## Status

Accepted

## Context

開発中の Noroshi を macOS で普段使いしたい (issue #34)。配置方法の候補は2つあった。

1. worktree のビルド成果物 (`tmp/DerivedData/Build/Products/Debug/Noroshi.app`) を直接開き続ける
2. ビルドした app を Applications ディレクトリに配置する

worktree 直接参照には次の問題がある。

- `make clean`・ブランチ切替・worktree 削除で app が消え、普段使いが開発作業の影響を受ける
- 最適化なしの Debug ビルドを常用することになる
- 複数 worktree の DerivedData に同じ bundle identifier (`com.bannzai.Noroshi`) の app が並び、アプリ未起動時に `noroshi://` を開いたとき LaunchServices がどのビルドを起動するか不安定になる

## Decision

`make install` で Release ビルドを `/Applications/Noroshi.app` へ配置する。

- `/Applications` は macOS の GUI アプリの標準配置場所で、Spotlight・Dock・ログイン項目から起動できる。admin グループのユーザーは sudo なしで書き込める (`drwxrwxr-x root admin`)
- `~/Applications` (ユーザー単位の配置場所) も検討したが、普段使いするアプリの置き場所を標準の 1 箇所に揃えるため `/Applications` にする
- 配置後に `lsregister -f` で LaunchServices に登録し、アプリ未起動時の `noroshi://` が DerivedData 内の開発ビルドではなく配置済み app を起動するようにする
- 更新は `make install` の再実行で行う。既存の配置先を削除してから `ditto` でコピーし直すため冪等

## Consequences

- 良い点: 開発ツリーの clean・rebuild・worktree 削除の影響を受けずに普段使いできる
- 良い点: 最適化ありの Release ビルドを常用できる
- 良い点: アプリ未起動時の `noroshi://` の起動先が配置済み app に安定する
- 悪い点: 修正を普段使いへ反映するには `make install` の再実行が必要 (自動では追随しない)
- 悪い点: admin グループでないユーザーは `/Applications` へ書き込めず `make install` が失敗する (このリポジトリは個人開発のため許容する)
- 注意点: 配置済み app が起動中のまま `make run` しても、`open` は同じ bundle identifier の起動中インスタンスを前面化するだけで開発ビルドは起動しない。開発ビルドの動作確認時は普段使いの Noroshi を終了してから `make run` する
