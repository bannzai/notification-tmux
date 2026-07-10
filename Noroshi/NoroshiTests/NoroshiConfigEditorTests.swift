import XCTest

@testable import Noroshi

/// NoroshiConfigEditor の置換・追記・削除・保持・冪等性を検証する。純粋関数なのでファイル入出力には依存しない。
final class NoroshiConfigEditorTests: XCTestCase {
    func testReplacesExistingKeyInPlace() {
        let out = NoroshiConfigEditor.apply(
            to: "background = #000000\nfont-size = 12\n",
            set: ["font-size": "14"], remove: [])
        XCTAssertEqual(out, "background = #000000\nfont-size = 14\n")
    }

    func testAppendsMissingKeyAtEnd() {
        let out = NoroshiConfigEditor.apply(
            to: "background = #000000\n",
            set: ["theme": "MyTheme"], remove: [])
        XCTAssertEqual(out, "background = #000000\ntheme = MyTheme\n")
    }

    func testRemovesKey() {
        let out = NoroshiConfigEditor.apply(
            to: "theme = Old\nbackground = #000000\n",
            set: [:], remove: ["background"])
        XCTAssertEqual(out, "theme = Old\n")
    }

    func testPreservesCommentsBlankLinesAndUnknownKeys() {
        let input = "# コメント\n\nunknown-key = keep\npalette = 0=#000000\nfont-size = 12\n"
        let out = NoroshiConfigEditor.apply(to: input, set: ["font-size": "16"], remove: [])
        XCTAssertEqual(out, "# コメント\n\nunknown-key = keep\npalette = 0=#000000\nfont-size = 16\n")
    }

    func testDeduplicatesRepeatedKeyKeepingFirstPosition() {
        let input = "font-size = 1\nbackground = #000000\nfont-size = 2\n"
        let out = NoroshiConfigEditor.apply(to: input, set: ["font-size": "9"], remove: [])
        // 最初の位置で置換し、残りの重複は削除する
        XCTAssertEqual(out, "font-size = 9\nbackground = #000000\n")
    }

    func testThemeSelectionSemanticsWriteThemeAndDropExplicitColors() {
        // テーマを選んだら theme を書き、明示色 4 キーを削除する (Ghostty 準拠の意味論)
        let input = """
        background = #111111
        foreground = #222222
        cursor-color = #333333
        selection-background = #444444

        """
        let out = NoroshiConfigEditor.apply(
            to: input,
            set: ["theme": "Catppuccin Frappe"],
            remove: ["background", "foreground", "cursor-color", "selection-background"])
        XCTAssertEqual(out, "theme = Catppuccin Frappe\n")
    }

    func testAppendsToEmptyText() {
        let out = NoroshiConfigEditor.apply(to: "", set: ["theme": "X"], remove: [])
        XCTAssertEqual(out, "theme = X\n")
    }

    func testHandlesTextWithoutTrailingNewline() {
        let out = NoroshiConfigEditor.apply(to: "background = #000000", set: ["font-size": "14"], remove: [])
        XCTAssertEqual(out, "background = #000000\nfont-size = 14\n")
    }

    func testIsIdempotent() {
        let input = "# c\nbackground = #000000\nfont-size = 12\n"
        let set = ["font-size": "16", "theme": "X"]
        let remove: Set<String> = ["background"]
        let once = NoroshiConfigEditor.apply(to: input, set: set, remove: remove)
        let twice = NoroshiConfigEditor.apply(to: once, set: set, remove: remove)
        XCTAssertEqual(once, twice)
    }
}
