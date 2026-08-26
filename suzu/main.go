// suzu: nested tmux の「額縁」と通知サイドバーを 1 つのバイナリで担う。
//
// 構成:
//
//	外側 tmux (別 socket。~/.tmux.conf を読まず outer.go の設定だけを入れる)
//	└─ session "suzu" / window 0 (1 枚固定)
//	   ├─ 左 pane: suzu sidebar (通知一覧の TUI)
//	   └─ 右 pane: TMUX= を外して内側 (普段の) tmux server へ attach
//
// フォーカス移動の役割分担 (外側はキーを 1 つも掴まない):
//
//	内側 → サイドバー: 内側 tmux の prefix + N (start が注入する run-shell バインド)
//	サイドバー → 内側: サイドバー側のキー処理 (prefix + N と q/Esc で戻る)
//	表示/非表示: 内側 tmux の prefix + b (start が注入する run-shell バインド)
//	マウスクリックでも両方向に移動できる (外側 mouse on)
//
// 環境変数 (すべて任意):
//
//	SUZU_OUTER_SOCKET      外側 socket 名 (default: suzu)
//	SUZU_INNER_TMUX        内側 server へ命令する時の tmux コマンド (default: tmux)
//	                       検証用に "tmux -L <隔離socket>" へ差し替えられる
//	SUZU_INNER_TMUX_CMD    右 pane で実行する内側への接続コマンド (default: $SUZU_INNER_TMUX attach)
//	SUZU_INNER_JUMP_KEY    内側に注入する「サイドバーへ」の prefix キー (default: N)
//	SUZU_INNER_TOGGLE_KEY  内側に注入する「表示/非表示」の prefix キー (default: b)
//	                       default が b なのは、ユーザーの ~/.tmux.conf と tmux の
//	                       デフォルト prefix table のどちらでも未使用だったため
//	SUZU_SIDEBAR_CMD       左 pane で実行するコマンド (default: <suzu の絶対パス> sidebar)
//	SUZU_SIDEBAR_WIDTH     サイドバーの幅 (default: 40)
//	SUZU_DOORBELL_FILE     @claude-waiting の変化をサイドバーへ知らせる touch 先
//	                       (default: ${XDG_STATE_HOME:-$HOME/.local/state}/suzu/doorbell)
package main

import (
	"fmt"
	"os"
)

const usage = `usage: suzu {start|stop|toggle|focus|status|sidebar}

  start    外側 tmux を構築して attach する (構築済みなら attach のみ = 冪等)。
           内側 tmux にジャンプキー・トグルキーと doorbell hook を注入する
           (メモリ上のみ。~/.tmux.conf は変更しない)
  stop     外側の suzu session を落とし、内側へ注入したキーバインドと hook を解除する
           (同じ socket の他の session、内側の session・window には一切触れない)
  toggle   サイドバーの表示/非表示を切り替える
  focus    {sidebar|inner|toggle} フォーカスを移す
  status   外側の状態を表示する
  sidebar  通知サイドバーの TUI (外側の左 pane が実行する内部サブコマンド)
`

func main() {
	cfg := loadConfig()
	if err := run(cfg, os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "エラー:", err)
		os.Exit(1)
	}
}

func run(cfg Config, args []string) error {
	command := ""
	if len(args) > 0 {
		command = args[0]
	}
	switch command {
	case "start":
		return cmdStart(cfg)
	case "stop":
		return cmdStop(cfg)
	case "toggle":
		return cmdToggle(cfg)
	case "focus":
		target := "toggle"
		if len(args) > 1 {
			target = args[1]
		}
		return cmdFocus(cfg, target)
	case "status":
		return cmdStatus(cfg)
	case "sidebar":
		return runSidebar(cfg)
	default:
		fmt.Fprint(os.Stderr, usage)
		os.Exit(64)
		return nil
	}
}
