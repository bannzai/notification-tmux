import XCTest

@testable import Noroshi

final class TerminalFileDropTests: XCTestCase {
    func testPlainAbsolutePathIsInsertedAsIsWithTrailingSpace() {
        XCTAssertEqual(
            TerminalFileDrop.insertionText(paths: ["/Users/bannzai/image.png"]),
            "/Users/bannzai/image.png ")
    }

    func testPathContainingSpacesAndJapaneseIsSingleQuoted() {
        XCTAssertEqual(
            TerminalFileDrop.insertionText(paths: ["/Users/bannzai/Desktop/スクリーンショット 2026-07-25 10.00.00.png"]),
            "'/Users/bannzai/Desktop/スクリーンショット 2026-07-25 10.00.00.png' ")
    }

    func testSingleQuoteInPathIsEscapedWithPosixIdiom() {
        XCTAssertEqual(
            TerminalFileDrop.insertionText(paths: ["/tmp/it's.png"]),
            "'/tmp/it'\\''s.png' ")
    }

    func testMultiplePathsAreJoinedBySingleSpaces() {
        XCTAssertEqual(
            TerminalFileDrop.insertionText(paths: ["/a.png", "/b 1.png"]),
            "/a.png '/b 1.png' ")
    }

    func testEmptyPathsProduceEmptyText() {
        XCTAssertEqual(TerminalFileDrop.insertionText(paths: []), "")
    }
}
