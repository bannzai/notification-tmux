import Foundation

/// サイドバーの絞り込み (テキストフィルタ + 通知フィルタ) の純粋ロジック。実 tmux・UI に依存しないためユニットテスト可能。
enum SidebarFilter {
    /// session 一覧をテキストクエリと通知フィルタで絞り込む。両条件は AND で合成する。
    /// - クエリも通知フィルタも無ければ sessions をそのまま返す。
    /// - session 名または host 名が部分一致した session は (通知フィルタが無ければ) 全 window を表示する。
    /// - session 名が一致しない session は、window 名または index 文字列が部分一致した window だけに絞る。
    /// - 通知フィルタが ON のときは、上記に加えて未読 (badge > 0) の window だけを残す。
    /// - 残る window が 0 の session は結果から除外する。
    static func filteredSessions(
        _ sessions: [TmuxSession],
        query: String,
        showsNotifiedOnly: Bool,
        badges: [String: Int]
    ) -> [TmuxSession] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespaces)
        guard !trimmedQuery.isEmpty || showsNotifiedOnly else { return sessions }
        return sessions.compactMap { session in
            let sessionNameMatches = !trimmedQuery.isEmpty
                && (session.name.localizedCaseInsensitiveContains(trimmedQuery)
                    || session.host.displayName?.localizedCaseInsensitiveContains(trimmedQuery) == true)
            var filteredWindows = session.windows
            if !trimmedQuery.isEmpty && !sessionNameMatches {
                filteredWindows = filteredWindows.filter { window in
                    window.name.localizedCaseInsensitiveContains(trimmedQuery)
                        || String(window.index).localizedCaseInsensitiveContains(trimmedQuery)
                }
            }
            if showsNotifiedOnly {
                filteredWindows = filteredWindows.filter { (badges[$0.id] ?? 0) > 0 }
            }
            guard !filteredWindows.isEmpty else { return nil }
            var filteredSession = session
            filteredSession.windows = filteredWindows
            return filteredSession
        }
    }
}
