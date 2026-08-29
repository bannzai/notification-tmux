package main

import "strings"

// 通知一覧を session ごとにまとめた表示単位。session 見出し + その配下の window 行になる
type sessionGroup struct {
	Session string
	Items   []Notification
}

// session 名 (リモートは host 付き)・window 名・セクション名への大文字小文字を無視した部分一致で絞り込む。
// 空クエリは素通しし、一致が無い session は呼び出し側のグループ化で見出しごと消える。
// セクション名も対象にするのは、"/claude" で Claude セクションだけを残せるようにするため
func filterNotifications(items []Notification, query string) []Notification {
	if query == "" {
		return items
	}
	needle := strings.ToLower(query)
	var matched []Notification
	for _, item := range items {
		if strings.Contains(strings.ToLower(item.sessionLabel()), needle) ||
			strings.Contains(strings.ToLower(item.WindowName), needle) ||
			strings.Contains(strings.ToLower(item.Section), needle) {
			matched = append(matched, item)
		}
	}
	return matched
}

// 通知 (Section が空) と各セクションが連続して並んでいる前提で、Section の切り替わりで区切る
func splitBySection(items []Notification) []paneSection {
	var sections []paneSection
	for _, item := range items {
		if len(sections) == 0 || sections[len(sections)-1].Title != item.Section {
			sections = append(sections, paneSection{Title: item.Section})
		}
		last := &sections[len(sections)-1]
		last.Items = append(last.Items, item)
	}
	return sections
}

// list-panes の出力順 (= host の並び → tmux の session 順) を保ったまま session でまとめる。
// 同名 session が host をまたいで衝突しないよう host と組にしてまとめる。
// Session は見出しの表示名 (リモートは host:session)
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
