import XCTest
@testable import Noroshi

/// サイドバーの絞り込み (SidebarFilter) の純粋ロジックのユニットテスト。
/// テキストクエリ・通知フィルタ単独・両者の AND 合成・0 件ケースを検証する。UI・実 tmux に依存しない。
final class SidebarFilterTests: XCTestCase {
    /// テスト用の window を作る。
    private func window(id: String, session: String, index: Int, name: String) -> TmuxWindow {
        TmuxWindow(id: id, sessionName: session, index: index, name: name, isActive: false, paneCount: 1)
    }

    /// 2 session (Focus: build/test, Riamo: deploy) のサンプル一覧。
    private func sampleSessions() -> [TmuxSession] {
        [
            TmuxSession(id: "Focus", attachedClients: 1, windows: [
                window(id: "@1", session: "Focus", index: 0, name: "build"),
                window(id: "@2", session: "Focus", index: 1, name: "test"),
            ]),
            TmuxSession(id: "Riamo", attachedClients: 0, windows: [
                window(id: "@3", session: "Riamo", index: 0, name: "deploy"),
            ]),
        ]
    }

    func testEmptyQueryAndNoFilterReturnsAll() {
        let result = SidebarFilter.filteredSessions(sampleSessions(), query: "", showsNotifiedOnly: false, badges: [:])
        XCTAssertEqual(result.map(\.name), ["Focus", "Riamo"])
        XCTAssertEqual(result.flatMap(\.windows).map(\.id), ["@1", "@2", "@3"])
        // 空白のみのクエリも空扱い
        let blank = SidebarFilter.filteredSessions(sampleSessions(), query: "   ", showsNotifiedOnly: false, badges: [:])
        XCTAssertEqual(blank.flatMap(\.windows).map(\.id), ["@1", "@2", "@3"])
    }

    func testSessionNameMatchKeepsAllWindows() {
        // session 名一致は配下 window を全表示する
        let result = SidebarFilter.filteredSessions(sampleSessions(), query: "focus", showsNotifiedOnly: false, badges: [:])
        XCTAssertEqual(result.map(\.name), ["Focus"])
        XCTAssertEqual(result.flatMap(\.windows).map(\.id), ["@1", "@2"])
    }

    func testWindowNameMatchNarrowsToMatchingWindows() {
        // session 名は非一致だが window 名一致 -> その window だけに絞る
        let result = SidebarFilter.filteredSessions(sampleSessions(), query: "build", showsNotifiedOnly: false, badges: [:])
        XCTAssertEqual(result.map(\.name), ["Focus"])
        XCTAssertEqual(result.flatMap(\.windows).map(\.id), ["@1"])
    }

    func testCaseInsensitiveMatch() {
        let result = SidebarFilter.filteredSessions(sampleSessions(), query: "DEPLOY", showsNotifiedOnly: false, badges: [:])
        XCTAssertEqual(result.map(\.name), ["Riamo"])
        XCTAssertEqual(result.flatMap(\.windows).map(\.id), ["@3"])
    }

    func testIndexStringMatch() {
        // index 文字列 ("1") でも window を絞り込める
        let result = SidebarFilter.filteredSessions(sampleSessions(), query: "1", showsNotifiedOnly: false, badges: [:])
        XCTAssertEqual(result.map(\.name), ["Focus"])
        XCTAssertEqual(result.flatMap(\.windows).map(\.id), ["@2"])
    }

    func testJapaneseWindowNameMatch() {
        let sessions = [
            TmuxSession(id: "作業", attachedClients: 1, windows: [
                window(id: "@10", session: "作業", index: 0, name: "ビルド"),
                window(id: "@11", session: "作業", index: 1, name: "テスト"),
            ]),
        ]
        let result = SidebarFilter.filteredSessions(sessions, query: "テスト", showsNotifiedOnly: false, badges: [:])
        XCTAssertEqual(result.flatMap(\.windows).map(\.id), ["@11"])
    }

    func testNoMatchReturnsEmpty() {
        let result = SidebarFilter.filteredSessions(sampleSessions(), query: "xyz", showsNotifiedOnly: false, badges: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testNotifiedOnlyKeepsUnreadWindows() {
        // 通知フィルタ単独: badge > 0 の window だけを残し、未読の無い session は落とす
        let result = SidebarFilter.filteredSessions(sampleSessions(), query: "", showsNotifiedOnly: true, badges: ["@2": 1])
        XCTAssertEqual(result.map(\.name), ["Focus"])
        XCTAssertEqual(result.flatMap(\.windows).map(\.id), ["@2"])
    }

    func testNotifiedOnlyWithNoUnreadReturnsEmpty() {
        let result = SidebarFilter.filteredSessions(sampleSessions(), query: "", showsNotifiedOnly: true, badges: [:])
        XCTAssertTrue(result.isEmpty)
    }

    func testQueryAndNotifiedAreCombinedWithAnd() {
        // session 名一致 (全 window 候補) でも、通知フィルタで未読 window だけに絞る
        let sessionMatch = SidebarFilter.filteredSessions(sampleSessions(), query: "focus", showsNotifiedOnly: true, badges: ["@1": 2])
        XCTAssertEqual(sessionMatch.map(\.name), ["Focus"])
        XCTAssertEqual(sessionMatch.flatMap(\.windows).map(\.id), ["@1"])
        // クエリ一致 window に未読が無ければ 0 件 (AND なので通知フィルタで全滅)
        let noneUnread = SidebarFilter.filteredSessions(sampleSessions(), query: "build", showsNotifiedOnly: true, badges: ["@2": 1])
        XCTAssertTrue(noneUnread.isEmpty)
    }
}
