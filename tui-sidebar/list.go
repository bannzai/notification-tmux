package main

import "strings"

// 通知一覧を session ごとにまとめた表示単位。session 見出し + その配下の window 行になる
type sessionGroup struct {
	Session string
	Items   []Notification
}

// session 名か window 名への大文字小文字を無視した部分一致で絞り込む。
// 空クエリは素通しし、一致が無い session は呼び出し側のグループ化で見出しごと消える
func filterNotifications(items []Notification, query string) []Notification {
	if query == "" {
		return items
	}
	needle := strings.ToLower(query)
	var matched []Notification
	for _, item := range items {
		if strings.Contains(strings.ToLower(item.Session), needle) ||
			strings.Contains(strings.ToLower(item.WindowName), needle) {
			matched = append(matched, item)
		}
	}
	return matched
}

// list-panes の出力順 (= tmux の session 順) を保ったまま session でまとめる
func groupBySession(items []Notification) []sessionGroup {
	var groups []sessionGroup
	at := map[string]int{}
	for _, item := range items {
		index, ok := at[item.Session]
		if !ok {
			index = len(groups)
			at[item.Session] = index
			groups = append(groups, sessionGroup{Session: item.Session})
		}
		groups[index].Items = append(groups[index].Items, item)
	}
	return groups
}
