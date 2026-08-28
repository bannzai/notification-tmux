package main

import "strings"

// 通知一覧を session ごとにまとめた表示単位。session 見出し + その配下の window 行になる。
// Session は見出しの表示名 (リモートは host:session)
type sessionGroup struct {
	Session string
	Items   []Notification
}

// session 名 (リモートは host 付き) か window 名への大文字小文字を無視した部分一致で絞り込む。
// 空クエリは素通しし、一致が無い session は呼び出し側のグループ化で見出しごと消える
func filterNotifications(items []Notification, query string) []Notification {
	if query == "" {
		return items
	}
	needle := strings.ToLower(query)
	var matched []Notification
	for _, item := range items {
		if strings.Contains(strings.ToLower(item.sessionLabel()), needle) ||
			strings.Contains(strings.ToLower(item.WindowName), needle) {
			matched = append(matched, item)
		}
	}
	return matched
}

// list-panes の出力順 (= host の並び → tmux の session 順) を保ったまま session でまとめる。
// 同名 session が host をまたいで衝突しないよう host と組にしてまとめる
func groupBySession(items []Notification) []sessionGroup {
	var groups []sessionGroup
	at := map[string]int{}
	for _, item := range items {
		groupKey := item.Host + fieldSeparator + item.Session
		index, ok := at[groupKey]
		if !ok {
			index = len(groups)
			at[groupKey] = index
			groups = append(groups, sessionGroup{Session: item.sessionLabel()})
		}
		groups[index].Items = append(groups[index].Items, item)
	}
	return groups
}
