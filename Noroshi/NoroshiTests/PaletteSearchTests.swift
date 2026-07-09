import XCTest
@testable import Noroshi

/// コマンドパレットの絞り込み・スコアリング (PaletteSearch) と候補モデル (PaletteItem) のユニットテスト。
/// UI・実 tmux に依存しない純粋ロジックのみを検証する。
final class PaletteSearchTests: XCTestCase {
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
        let items = [
            PaletteItem(kind: .session(name: "Alpha"), badge: 0),
            PaletteItem(kind: .session(name: "Beta"), badge: 0),
        ]
        XCTAssertEqual(PaletteSearch.filter(items, query: "").map(\.id), ["Alpha", "Beta"])
        // 空白のみのクエリも空扱い
        XCTAssertEqual(PaletteSearch.filter(items, query: "   ").map(\.id), ["Alpha", "Beta"])
    }

    func testFilterSortsByScoreThenDisplayOrder() {
        let items = [
            PaletteItem(kind: .session(name: "xfoo"), badge: 0),
            PaletteItem(kind: .session(name: "foobar"), badge: 0),
        ]
        // "foo": 先頭一致の "foobar" が、非先頭一致の "xfoo" より上位
        XCTAssertEqual(PaletteSearch.filter(items, query: "foo").map(\.id), ["foobar", "xfoo"])
    }

    func testFilterExcludesNonMatches() {
        let items = [
            PaletteItem(kind: .session(name: "Focus"), badge: 0),
            PaletteItem(kind: .session(name: "Riamo"), badge: 0),
        ]
        XCTAssertEqual(PaletteSearch.filter(items, query: "ria").map(\.id), ["Riamo"])
    }

    func testJapaneseSessionName() {
        // 日本語もサブシーケンス一致し、順序違いは非一致
        XCTAssertNotNil(PaletteSearch.score(query: "サー", candidate: "サーバ"))
        XCTAssertNil(PaletteSearch.score(query: "バー", candidate: "サーバ"))
        let items = [
            PaletteItem(kind: .session(name: "作業"), badge: 0),
            PaletteItem(kind: .session(name: "サーバ"), badge: 0),
        ]
        XCTAssertEqual(PaletteSearch.filter(items, query: "サ").map(\.id), ["サーバ"])
    }

    func testWindowItemMatchesSessionAndWindowName() {
        let window = TmuxWindow(id: "@5", sessionName: "Focus", index: 2, name: "build", isActive: false, paneCount: 1)
        let item = PaletteItem(kind: .window(window), badge: 3)
        // window 行の id は window_id、マッチ対象は "session名 window名"
        XCTAssertEqual(item.id, "@5")
        XCTAssertNotNil(PaletteSearch.score(query: "focusbuild", candidate: item.matchText))
        XCTAssertNotNil(PaletteSearch.score(query: "build", candidate: item.matchText))
    }
}
