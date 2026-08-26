package main

import "testing"

func sample() []Notification {
	return []Notification{
		{Session: "work", WindowID: "@1", WindowIndex: "0", WindowName: "Claude-Work", PaneID: "%1"},
		{Session: "work", WindowID: "@2", WindowIndex: "1", WindowName: "build", PaneID: "%2"},
		{Session: "personal", WindowID: "@3", WindowIndex: "0", WindowName: "notes", PaneID: "%3"},
	}
}

func TestGroupBySessionPreservesOrderAndCounts(t *testing.T) {
	groups := groupBySession(sample())

	if len(groups) != 2 {
		t.Fatalf("session の数が合わない: %+v", groups)
	}
	if groups[0].Session != "work" || len(groups[0].Items) != 2 {
		t.Errorf("先頭グループが誤り: %+v", groups[0])
	}
	if groups[1].Session != "personal" || len(groups[1].Items) != 1 {
		t.Errorf("2 番目のグループが誤り: %+v", groups[1])
	}
	if groups[0].Items[0].WindowID != "@1" || groups[0].Items[1].WindowID != "@2" {
		t.Errorf("グループ内の window 順が入れ替わっている: %+v", groups[0].Items)
	}
}

func TestGroupBySessionKeepsSeparatedSessionTogether(t *testing.T) {
	// list-panes は session 順に並ぶが、間に別 session が挟まっても見出しは 1 つにまとめる
	items := []Notification{
		{Session: "a", WindowID: "@1"},
		{Session: "b", WindowID: "@2"},
		{Session: "a", WindowID: "@3"},
	}

	groups := groupBySession(items)
	if len(groups) != 2 || groups[0].Session != "a" || len(groups[0].Items) != 2 {
		t.Fatalf("同じ session がまとまっていない: %+v", groups)
	}
}

func TestGroupBySessionEmpty(t *testing.T) {
	if groups := groupBySession(nil); groups != nil {
		t.Fatalf("通知が無いのにグループが生えた: %+v", groups)
	}
}

func TestFilterNotificationsEmptyQueryPassesThrough(t *testing.T) {
	items := sample()
	if got := filterNotifications(items, ""); len(got) != len(items) {
		t.Fatalf("空クエリで件数が変わった: %d", len(got))
	}
}

func TestFilterNotificationsMatchesWindowNameIgnoringCase(t *testing.T) {
	got := filterNotifications(sample(), "claude")
	if len(got) != 1 || got[0].WindowID != "@1" {
		t.Fatalf("window 名への大文字小文字無視の一致が誤り: %+v", got)
	}
}

func TestFilterNotificationsMatchesSessionName(t *testing.T) {
	got := filterNotifications(sample(), "WORK")
	if len(got) != 2 {
		t.Fatalf("session 名で 2 件に絞れていない: %+v", got)
	}
	for _, item := range got {
		if item.Session != "work" {
			t.Errorf("別 session が混ざっている: %+v", item)
		}
	}
}

func TestFilterNotificationsNoMatch(t *testing.T) {
	if got := filterNotifications(sample(), "存在しない"); len(got) != 0 {
		t.Fatalf("一致しないはずが %+v", got)
	}
}
