import XCTest
@testable import Noroshi

/// コマンドパレットの絞り込み・スコアリング (PaletteSearch) と候補モデル (PaletteItem) のユニットテスト。
/// UI・実 tmux に依存しない純粋ロジックのみを検証する。
final class PaletteSearchTests: XCTestCase {
    /// テスト用の session 候補を作る。
    private func sessionItem(host: TmuxHost = .local, name: String) -> PaletteItem {
        PaletteItem(kind: .session(TmuxSession(host: host, name: name, attachedClients: 0, windows: [])), badge: 0)
    }

    func testScoreMatchesSubsequenceCaseInsensitive() {
        // 大文字小文字を無視したサブシーケンスは一致
        XCTAssertNotNil(PaletteSearch.score(query: "fs", candidate: "Focus"))
        XCTAssertNotNil(PaletteSearch.score(query: "FOCUS", candidate: "focus"))
        // サブシーケンスでないもの・順序が逆のものは非一致
        XCTAssertNil(PaletteSearch.score(query: "xyz", candidate: "Focus"))
        XCTAssertNil(PaletteSearch.score(query: "sf", candidate: "Focus"))
    }

    func testScoreEmptyQueryIsZero() {
        XCTAssertEqual(PaletteSearch.score(query: "", candidate: "Focus"), 0)
    }

    func testPrefixAndConsecutiveScoreHigher() {
        // 先頭一致 + 連続一致 (Focus) の方が、散らばった一致 (xFxoxc) より高スコア
        let prefix = try? XCTUnwrap(PaletteSearch.score(query: "foc", candidate: "Focus"))
        let scattered = try? XCTUnwrap(PaletteSearch.score(query: "foc", candidate: "xFxoxc"))
        XCTAssertNotNil(prefix)
        XCTAssertNotNil(scattered)
        XCTAssertGreaterThan(prefix!, scattered!)
    }

    func testFilterEmptyQueryReturnsAllInDisplayOrder() {
        let items = [sessionItem(name: "Alpha"), sessionItem(name: "Beta")]
        XCTAssertEqual(PaletteSearch.filter(items, query: "").map(\.id), ["local:Alpha", "local:Beta"])
        // 空白のみのクエリも空扱い
        XCTAssertEqual(PaletteSearch.filter(items, query: "   ").map(\.id), ["local:Alpha", "local:Beta"])
    }

    func testFilterSortsByScoreThenDisplayOrder() {
        let items = [sessionItem(name: "xfoo"), sessionItem(name: "foobar")]
        // "foo": 先頭一致の "foobar" が、非先頭一致の "xfoo" より上位
        XCTAssertEqual(PaletteSearch.filter(items, query: "foo").map(\.id), ["local:foobar", "local:xfoo"])
    }

    func testFilterExcludesNonMatches() {
        let items = [sessionItem(name: "Focus"), sessionItem(name: "Riamo")]
        XCTAssertEqual(PaletteSearch.filter(items, query: "ria").map(\.id), ["local:Riamo"])
    }

    func testJapaneseSessionName() {
        // 日本語もサブシーケンス一致し、順序違いは非一致
        XCTAssertNotNil(PaletteSearch.score(query: "サー", candidate: "サーバ"))
        XCTAssertNil(PaletteSearch.score(query: "バー", candidate: "サーバ"))
        let items = [sessionItem(name: "作業"), sessionItem(name: "サーバ")]
        XCTAssertEqual(PaletteSearch.filter(items, query: "サ").map(\.id), ["local:サーバ"])
    }

    func testRemoteSessionMatchesByHostName() {
        // リモート session は host 名でも絞り込める (issue #38)
        let items = [sessionItem(name: "Focus"), sessionItem(host: .remote("dev-machine"), name: "Focus")]
        XCTAssertEqual(PaletteSearch.filter(items, query: "dev").map(\.id), ["dev-machine:Focus"])
        // 両者は id (複合 ID) が異なるため同名でも別候補として並ぶ
        XCTAssertEqual(PaletteSearch.filter(items, query: "focus").map(\.id), ["local:Focus", "dev-machine:Focus"])
    }

    func testWindowItemMatchesSessionAndWindowName() {
        let window = TmuxWindow(host: .local, windowID: "@5", sessionName: "Focus", index: 2, name: "build", isActive: false, paneCount: 1)
        let item = PaletteItem(kind: .window(window), badge: 3)
        // window 行の id は複合 window ID、マッチ対象は "session名 window名"
        XCTAssertEqual(item.id, "local:@5")
        XCTAssertNotNil(PaletteSearch.score(query: "focusbuild", candidate: item.matchText))
        XCTAssertNotNil(PaletteSearch.score(query: "build", candidate: item.matchText))
    }

    func testRemoteWindowItemMatchesHostName() {
        let window = TmuxWindow(host: .remote("dev"), windowID: "@5", sessionName: "Focus", index: 0, name: "build", isActive: false, paneCount: 1)
        let item = PaletteItem(kind: .window(window), badge: 0)
        XCTAssertEqual(item.id, "dev:@5")
        XCTAssertNotNil(PaletteSearch.score(query: "devbuild", candidate: item.matchText))
    }
}
