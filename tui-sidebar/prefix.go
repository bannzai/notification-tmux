package main

import "strings"

// tmux 自身の既定 prefix。内側 server が落ちている等で show-options を引けない時と、
// 正規化できない prefix を引いた時の拠り所にする
const defaultPrefix = "C-b"

// サイドバーから内側へ戻る「prefix + jump key」の prefix 側。
// 内側 tmux が prefix + jump key でサイドバーへ移すのと対称にするため、
// 内側 server が実際に使っている prefix を写し取る
type prefixKey struct {
	// tmux 表記 (C-t)。フッターの案内に出す
	Display string
	// bubbletea の KeyMsg.String() 表記 (ctrl+t)。キー判定に使う
	Key string
}

func fetchInnerPrefix(cfg Config) prefixKey {
	out, err := output(cfg.innerCommand("show-options", "-gv", "prefix"))
	if err != nil {
		return normalizePrefix(defaultPrefix)
	}
	return normalizePrefix(strings.TrimSpace(out))
}

// None や F1 のような、bubbletea のキー表現へ写せない prefix は既定の C-b として扱う。
// prefix 無しにするとサイドバーから戻る手段が q/Esc だけになるため、無効化ではなく
// フォールバックを選ぶ
func normalizePrefix(raw string) prefixKey {
	if key, ok := bubbleteaKey(raw); ok {
		return prefixKey{Display: raw, Key: key}
	}
	key, _ := bubbleteaKey(defaultPrefix)
	return prefixKey{Display: defaultPrefix, Key: key}
}

func bubbleteaKey(raw string) (string, bool) {
	var modifier string
	switch {
	case strings.HasPrefix(raw, "C-"):
		modifier = "ctrl+"
	case strings.HasPrefix(raw, "M-"):
		modifier = "alt+"
	default:
		return "", false
	}
	rest := []rune(raw[2:])
	if len(rest) != 1 {
		return "", false
	}
	return modifier + strings.ToLower(string(rest)), true
}
