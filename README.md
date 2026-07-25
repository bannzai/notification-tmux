# Noroshi (狼煙)

通知センター付き tmux フロントエンド macOS アプリ（旧 NTMUX / notification-tmux）。

Claude Code が Stop すると狼煙が上がり、その狼煙が上がった window へ駆けつける、という体験から Noroshi と名付けた。

- サイドバーに tmux の session(workspace) / window 一覧をツリー表示する
- リモートホスト (ssh) の tmux session も同じサイドバーで一覧・attach・切替できる（issue #38。config の `remote-host` で宣言、後述）
- Claude Code の Stop hook から `noroshi://stop?session=<name>&window=@n` を受けて該当 window にバッジ数字を付け、macOS標準通知を表示する（Dock アイコンには未読合計）。リモート session の Stop hook も `ssh -R` フォワード経由で同じバッジになる（issue #39）
- バッジのある window はクリック、またはショートカットキーでジャンプできる。ジャンプすると該当 session のターミナルを表示して `tmux select-window` で該当 window まで開く
- `cmd+T` のタブでローカル/リモートの session を並べて持ち、タブごとの選択を切り替えられる（issue #40）
- ターミナルは [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) の PTY で `tmux attach-session`（リモートは `ssh -t <host> tmux attach-session`）する。表示中の session だけを attach する単一 attach 方式（後述）

## 技術構成

| レイヤ | 採用技術 | 役割 |
| --- | --- | --- |
| UI | SwiftUI (`Window` シーン + `NavigationSplitView`) | サイドバー (通知センター兼 workspace 一覧) と detail (ターミナル) |
| ターミナル描画 | SwiftTerm 1.13.0 (SPM) の `LocalProcessTerminalView` | forkpty で `tmux attach-session -t =<session>` (リモートは `ssh -t`) した PTY を VT100/xterm エミュレーションで描画。Ghostty テーマの配色を適用 |
| tmux 連携 | `Process` で tmux CLI を実行 (`TmuxClient`) | 2秒ポーリングで一覧構築、`select-window`でwindow移動、`switch-client`で同一clientのsession切替。リモート host は同じコマンドを `ssh <host> tmux -u ...` でラップ (ADR 0010) |
| 通知イベント | URL スキーム `noroshi://` + `UserNotifications` | Stop hook → LaunchServices → `onOpenURL` → macOS標準通知。通知タップで対象windowへ移動。リモートは `ssh -R` フォワードの unix socket 経由 (`RemoteStopReceiver`) |
| 状態管理 | `AppState: ObservableObject` (@MainActor) | session 一覧・バッジ台帳 (複合 windowID → 未読数)・通知履歴・タブごとの選択状態 |
| ショートカット | SwiftUI `Commands` (`NavigationCommands`) | session/window/pane 移動、最新通知へのジャンプ、テーマ再読み込み |
| テスト | XCTest (app を TEST_HOST とするユニットテスト) | パーサ / URL イベント / バッジ台帳 / Ghostty テーマ解決 / ナビゲーション計算 |

### データフロー

```
Claude Code (tmux pane 内で動作)
  └─ Stop hook ─▶ scripts/noroshi-hook-stop
                    ├─ $TMUX_PANE → tmux display-message で session名 / window_id (@n) を解決
                    └─ open -g "noroshi://stop?session=<name>&window=@n"   # フォーカスを奪わない
                                        │
Noroshi.app ◀────────────────────────────┘ (onOpenURL)
  ├─ AppState
  │    ├─ sessions: [TmuxSession]     ← TmuxClient が 2 秒ポーリング
  │    ├─ badges: [windowID: Int]     ← stop イベントで加算 / window を開いたらクリア
  │    ├─ notifications: [NotificationRecord] ← 「最新の通知へジャンプ」の発生順解決に使用
  │    └─ selectedSessionName
  ├─ SidebarView — session → window ツリー + バッジ数字 (クリックで AppState.open(window:))
  ├─ NotificationService — macOS標準通知を表示し、タップを AppState.open(event:) へ戻す
  └─ TerminalHostView (NSViewRepresentable)
       └─ TerminalSessionManager (単一 attach) が表示中 session の LocalProcessTerminalView を保持
            └─ PTY: tmux attach-session -t =<session>
                     (session 切替時は同じclientを switch-client。prefix+L の履歴も保持)
```

### 設計上のポイント

- **識別子は host 込みの複合 ID (`<host>:<要素>`) を SSOT にする**（issue #38）。window は tmux の window_id (`@n`)、session は session 名を要素とし、ローカル (`local:`) とリモート (`<ssh接続先>:`) で衝突しない。バッジ台帳・サイドバー保存順・選択状態はすべてこのキー。詳細は [ADR 0010](documents/adr/0010-remote-tmux-over-ssh.md) を参照
- **リモートホスト対応**（issue #38 / #39）: config の `remote-host` で宣言した ssh 接続先の tmux を、同じ CLI コマンドの ssh ラップ（`ControlMaster` で多重化、`tmux -u` で locale 非依存）で一覧・操作する。attach は `ssh -t` + リモート側への tty 記録で行い、同一 host 内の切替は記録した tty への `switch-client`。リモートの Stop hook は `ssh -R` でフォワードした `~/.noroshi.sock` 経由で届く（切断中の通知は取りこぼす）。鍵認証 (ssh-agent) と、リモート非対話 shell の PATH で tmux が見えることが前提
- **単一 attach 方式**（issue #6 / #20）: terminal clientは常時最大1本。session切替は同じclientへの`switch-client`で行い、非表示viewを増やさずtmuxの直前session履歴も保持する。host をまたぐ切替だけは client を引き継げないため attach を作り直す。詳細は [ADR 0005](documents/adr/0005-switch-client-for-session-navigation.md) を参照
- **タブは選択状態のタブ化**（issue #40）: タブごとに選択中の session/window を持ち、attach は単一 attach のまま。タブが 2 枚以上の時だけ terminal 上部にタブバーを表示する
- **表示フォントの自動フィット**（issue #36）: attach は `-f ignore-size`（他 client の window を resize しないため）なので、window が Noroshi の terminal 格子より大きいと tmux のカーソル追従パンで端が見切れる。attach 中 window の格子 (cols × rows) を取得し、設定フォントサイズを上限に必要な分だけ縮小して window 全体を表示する。詳細は [ADR 0009](documents/adr/0009-font-auto-fit-for-ignore-size-attach.md) を参照
- **独自 config + Ghostty テーマ対応**: アプリ独自の設定ファイル `~/.config/noroshi/config`（`XDG_CONFIG_HOME` を尊重、無ければ `~/.config/ghostty/config` にフォールバック）と、そこから参照される theme ファイルを読み、Ghostty と同じ意味論（theme が先に読まれ config の直接指定が上書きする）でマージした配色を SwiftTerm に適用する。ファイル形式は Ghostty config 互換で、`font-family` / `font-style` / `font-size` も反映する。config 編集後は再起動せず、メニュー「表示 > テーマを再読み込み」(cmd+shift+r) で反映できる。詳細は [ADR 0004](documents/adr/0004-noroshi-config-file.md) を参照
- App Sandbox は無効 (homebrew の tmux を PTY で exec するため。SwiftTerm 公式の推奨)
- 詳細な知見・ハマりどころは [docs/knowledge.md](docs/knowledge.md) を参照（v1 開発時の記録）

### キーボードショートカット

マウスなしで session/window/pane を移動できる。メニューの keyEquivalent は first responder (SwiftTerm) の keyDown より先に処理されるため、cmd 系のショートカットが SwiftTerm に食われることはない。

| ショートカット | 動作 |
| --- | --- |
| `cmd+1` 〜 `cmd+9` | 表示順で該当番号の session に切り替える |
| `cmd+shift+]` | 表示中 session のカレント window を次に進める |
| `cmd+shift+[` | 表示中 session のカレント window を前に戻す |
| `cmd+shift+j` | 次の session に切り替える (循環) |
| `cmd+shift+k` | 前の session に切り替える (循環) |
| `cmd+option+s` | サイドバーの選択中 session にフォーカスする |
| `cmd+option+t` | ターミナルにフォーカスする |
| `cmd+n` | フォルダPickerを開き、そのフォルダを開始位置とする新規sessionを作る |
| `cmd+t` | 新規タブを開く (issue #40)。ローカル/リモートの session をタブで並べて切り替えられる |
| `cmd+w` | タブを閉じる (タブが 1 枚の時はウィンドウを閉じる) |
| `ctrl+tab` / `ctrl+shift+tab` | 次のタブ / 前のタブに切り替える (循環) |
| `cmd+shift+n` | 最も新しく受信し、かつ未読が残っている window へジャンプする |
| `cmd+]` | 表示中 session のカレント window 内でアクティブ pane を次へ移す |
| `cmd+[` | 表示中 session のカレント window 内でアクティブ pane を前へ移す |
| `cmd+shift+r` | テーマ設定を再読み込みして表示中 terminal に適用する |
| `cmd+,` | 設定ウィンドウ (フォント・テーマ・色) を開く |

### 設定 (フォント・テーマ・色)

`cmd+,` で設定ウィンドウを開き、フォント (family / style / size)・テーマ・色 (背景 / 文字 / カーソル / 選択範囲) を調整できる。文字の太さはフォント既定 / Regular / Medium / Semibold / Bold から選べる。変更は即時に `~/.config/noroshi/config` へ書き戻され、表示中の terminal に反映される。テーマを選ぶと明示色は消え、個別色を変えるとその色だけが上書きされる (Ghostty 準拠の意味論)。

既に Ghostty を使っている場合は、移植スクリプトで Noroshi が理解するキーだけを独自 config にコピーできる:

```bash
scripts/noroshi-port-ghostty-config          # ~/.config/ghostty/config → ~/.config/noroshi/config
scripts/noroshi-port-ghostty-config --force  # 出力先が既にある場合に上書き
```

抽出対象は `theme` / `background` / `foreground` / `cursor-color` / `selection-background` / `palette` / `font-family` / `font-style` / `font-size`。元の ghostty config には触れない。

### リモートホスト (ssh)

`~/.config/noroshi/config` に `remote-host` を書くと、その ssh 接続先の tmux session もサイドバーに並ぶ（複数可・記述順）。値は `ssh` コマンドにそのまま渡る接続先（`~/.ssh/config` の Host 名や `user@host`）。

```
remote-host = dev-machine
remote-host = user@build-server
```

前提と制約:

- 鍵認証 (ssh-agent) で非対話接続できること（`BatchMode=yes` で実行するためパスワード認証は使えない）
- `ssh <host> tmux -V` が通ること（リモートの非対話 shell の PATH に tmux があること）
- 接続は `ControlMaster=auto` + `ControlPersist=600` で自動的に多重化される（ポーリングごとの再接続はしない）
- ssh 接続先の名前が予約名 `local` の場合はローカルと区別できない
- リモート session 内のリンククリックは URL のみ開く（ファイルパスはローカルに存在しないため何も起きない）

config 編集は 2 秒ポーリングで自動反映される（再起動不要）。設計の詳細は [ADR 0010](documents/adr/0010-remote-tmux-over-ssh.md) を参照。

### ディレクトリ構成

```
Noroshi/
  Noroshi.xcodeproj/         # Xcode 26 folder-synchronized 形式 (ファイル配置 = ターゲット追加)
  Info.plist                 # CFBundleURLTypes (noroshi://)。GENERATE_INFOPLIST_FILE とマージされる
  Noroshi/
    NoroshiApp.swift         # @main。Window / Settings シーン、onOpenURL、NavigationCommands (ショートカット)、テスト時 UI 起動ガード
    ContentView.swift        # NavigationSplitView
    SidebarView.swift        # session/window ツリー + バッジ
    TerminalHostView.swift   # SwiftTerm ラップと単一 attach の TerminalSessionManager (配色・フォント適用)
    GhosttyTheme.swift       # Ghostty config/theme のパースとマージ、SwiftTerm への適用
    NoroshiConfig.swift      # 独自 config のパス解決 (noroshi 優先・ghostty フォールバック) と入出力
    NoroshiConfigEditor.swift # config テキストの書き戻し (キー設定・削除、冪等)
    SettingsView.swift       # cmd+, の設定ウィンドウ (フォント・テーマ・色)
    AppState.swift           # ポーリング (全 host)・バッジ台帳・通知履歴・タブ・選択状態・ショートカット操作
    TmuxClient.swift         # tmux CLI ラッパ (リモートは ssh 経由)
    TmuxModels.swift         # TmuxHost / TmuxSession / TmuxWindow / StopEvent / NoroshiNavigation とパーサ
    RemoteStopReceiver.swift # リモート Stop hook の受信路 (listener + ssh -R フォワード)
  NoroshiTests/
    TmuxModelsTests.swift
    GhosttyThemeTests.swift
    NoroshiConfigTests.swift       # config パス優先順位
    NoroshiConfigEditorTests.swift # 書き戻しエディタ
scripts/
  noroshi-hook-stop              # Claude Stop hook から呼ぶ通知スクリプト
  noroshi-port-ghostty-config    # ghostty config → noroshi config 移植スクリプト
.plans/                      # 実装プランと検証記録
docs/knowledge.md            # v1 開発時の知見まとめ (作り直し用)
```

## 必要なもの

- macOS 26+ / Xcode 26+（初回ビルドで Metal Toolchain が無い場合は `xcodebuild -downloadComponent MetalToolchain`）
- tmux（homebrew: /opt/homebrew/bin/tmux または /usr/local/bin/tmux を自動解決）

## ビルドと起動

```bash
cd Noroshi
xcodebuild -project Noroshi.xcodeproj -scheme Noroshi -configuration Debug -derivedDataPath ../tmp/DerivedData build
open ../tmp/DerivedData/Build/Products/Debug/Noroshi.app
```

## 普段使いする (インストール)

Release ビルドを `/Applications/Noroshi.app` に配置する。

```bash
make install
```

- 開発ツリーの `make clean` やブランチ切替の影響を受けず、Spotlight・Dock・ログイン項目から起動できる
- 更新も `make install` の再実行で行う (既存の app を置き換える)
- アンインストールは `rm -rf /Applications/Noroshi.app`
- 配置済み app が起動中は `make run` しても開発ビルドは起動しない (同じ bundle identifier のため)。開発ビルドの確認時は普段使いの Noroshi を終了してから実行する
- 配置方法の検討経緯は [ADR 0007](documents/adr/0007-install-release-build-to-applications.md) を参照

## テスト

```bash
cd Noroshi
xcodebuild -project Noroshi.xcodeproj -scheme Noroshi -derivedDataPath ../tmp/DerivedData test
```

## Claude Code hooks 連携

`~/.claude/settings.json` の `hooks.Stop` 配下の `hooks` 配列末尾に追記する（既存 hook とは独立に並列実行される）:

```json
{
  "type": "command",
  "command": "/Users/bannzai/ghq/github.com/bannzai/notification-tmux/scripts/noroshi-hook-stop"
}
```

※ リポジトリ名の GitHub 上の rename (`notification-tmux` → `noroshi`) は未実施。rename 後は clone パスが変わるため、上記コマンドパスも合わせて更新すること。

スクリプトは tmux 外・アプリ未インストール環境では何もせず exit 0 する。動作確認は手動でも可能:

```bash
open -g "noroshi://stop?session=<session名>&window=@<window_id>"
```

### リモートホストの Stop hook (issue #39)

`remote-host` で繋いだリモート session の Stop hook もバッジにできる。Noroshi が起動中、host ごとに `ssh -R` でリモートの `$HOME/.noroshi.sock` を Mac 側へフォワードしており、同じ `scripts/noroshi-hook-stop` が socket の有無で送信先を自動で切り替える（socket があれば socket へ、無ければ従来の `open noroshi://`）。

セットアップ: `scripts/noroshi-hook-stop` をリモートホストにコピーし、リモートの `~/.claude/settings.json` の `hooks.Stop` に追記する（Mac 側と同じ形式）。リモートに python3 または `nc -U` が使える netcat が必要（送信に使う）。

制約: Noroshi が起動していない間・ssh が切断されている間に発火した通知は届かず、再送されない。バッジは復帰後の新しい Stop から反映される。
