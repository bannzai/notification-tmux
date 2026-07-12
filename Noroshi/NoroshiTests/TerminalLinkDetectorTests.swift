import XCTest
@testable import Noroshi

/// ターミナル表示テキストからのリンク検出 (TerminalLinkDetector) の純粋ロジックのユニットテスト。
/// URL / ファイルパスの検出、折返し行の結合、パス解決を検証する。UI・実 tmux・ファイルシステムに依存しない。
final class TerminalLinkDetectorTests: XCTestCase {
    /// line 内の substring 先頭の文字オフセット。手計算での列指定ミスを避けるためのヘルパ。
    private func column(of substring: String, in line: String) -> Int {
        line.distance(from: line.startIndex, to: line.range(of: substring)!.lowerBound)
    }

    // MARK: - URL 検出

    func testDetectsHTTPSURLWhenClickInsideToken() {
        // トークン内をクリックしたら https URL を検出する
        let line = "open https://example.com now"
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: "example", in: line)),
            .url(URL(string: "https://example.com")!))
    }

    func testDetectsHTTPURLAtLineStart() {
        // 行頭の http URL を検出する
        let line = "http://localhost:3000/path"
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: line, column: 0),
            .url(URL(string: "http://localhost:3000/path")!))
    }

    func testStripsTrailingPunctuationFromURL() {
        // 文末約物付きの URL は末尾の約物を除いて検出する
        let line = "see https://example.com/a."
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: "https", in: line)),
            .url(URL(string: "https://example.com/a")!))
    }

    func testDetectsURLInParentheses() {
        // 括弧書きの URL は先頭の括弧を跨がず、末尾の括弧を除いて検出する
        let line = "(https://example.com)"
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: "example", in: line)),
            .url(URL(string: "https://example.com")!))
    }

    func testDoesNotDetectURLWhenClickBeforeScheme() {
        // URL の手前 (先頭括弧) をクリックした場合は URL 扱いにしない
        XCTAssertNil(TerminalLinkDetector.detectLink(logicalLine: "(https://example.com)", column: 0))
    }

    func testIgnoresNonHTTPScheme() {
        // http / https 以外のスキーム (ftp://) は URL としてもパスとしても検出しない
        XCTAssertNil(TerminalLinkDetector.detectLink(logicalLine: "ftp://example.com", column: 0))
    }

    func testDoesNotDetectSchemeWithGluedPrefix() {
        // スキーム直前に文字が接着したトークン (桁数不一致の折返し誤結合で生じ得る) は URL 扱いしない。自前検出器の潔白確認。
        let line = "examphttps://example.com"
        XCTAssertNil(TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: "https", in: line)))
    }

    func testRejectsDoubleSchemeGluedToken() {
        // :// が2度現れる糊付きトークン (https://examphttps://example.com) は先頭クリックでも後半クリックでも nil
        let line = "https://examphttps://example.com"
        XCTAssertNil(TerminalLinkDetector.detectLink(logicalLine: line, column: 3))
        XCTAssertNil(TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: "example", in: line)))
    }

    func testAcceptsSingleSchemeURLWithColonPort() {
        // scheme 区切りの :// が1つなら port 付き (コロンを含む) でも従来どおり検出する (二重 scheme ガードの偽陽性防止)
        let line = "http://localhost:8080/a"
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: line, column: 0),
            .url(URL(string: "http://localhost:8080/a")!))
    }

    func testReturnsNilWhenClickOnWhitespace() {
        // 空白上のクリックはトークン外なので nil
        let line = "a https://example.com b"
        XCTAssertNil(TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: " https", in: line)))
    }

    func testReturnsNilForLineWithoutLink() {
        // リンクを含まない行は nil
        XCTAssertNil(TerminalLinkDetector.detectLink(logicalLine: "just some text here", column: 5))
    }

    // MARK: - パス検出

    func testDetectsAbsolutePath() {
        // 絶対パスを検出する
        let line = "cat /etc/hosts done"
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: "/etc", in: line)),
            .path("/etc/hosts"))
    }

    func testDetectsTildePath() {
        // ~ 始まりのパスを検出する
        let line = "vim ~/.zshrc"
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: "~/", in: line)),
            .path("~/.zshrc"))
    }

    func testDetectsDotRelativePath() {
        // ./ 始まりの相対パスを検出する
        let line = "open ./foo.txt"
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: "./foo", in: line)),
            .path("./foo.txt"))
    }

    func testDetectsParentRelativePath() {
        // ../ 始まりの相対パスを検出する
        let line = "cd ../sibling"
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: "../", in: line)),
            .path("../sibling"))
    }

    func testDetectsSlashContainingRelativePath() {
        // / を含む相対パス (foo/bar 形式) を検出する
        let line = "edit src/main.swift please"
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: "src/", in: line)),
            .path("src/main.swift"))
    }

    func testStripsTrailingPunctuationFromPath() {
        // 文末約物付きのパスは末尾の約物を除いて検出する
        let line = "see /var/log/system.log."
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: line, column: column(of: "/var", in: line)),
            .path("/var/log/system.log"))
    }

    func testDoesNotDetectBareWordAsPath() {
        // / を含まない単語はパス扱いしない
        XCTAssertNil(TerminalLinkDetector.detectLink(logicalLine: "README and text", column: 0))
    }

    // MARK: - 基準ディレクトリ要否

    func testRequiresBaseDirectoryOnlyForRelativePaths() {
        // 絶対パス・~ は基準不要、それ以外の相対パスは基準が必要
        XCTAssertFalse(TerminalLinkDetector.requiresBaseDirectory("/etc/hosts"))
        XCTAssertFalse(TerminalLinkDetector.requiresBaseDirectory("~/.zshrc"))
        XCTAssertTrue(TerminalLinkDetector.requiresBaseDirectory("./foo"))
        XCTAssertTrue(TerminalLinkDetector.requiresBaseDirectory("../foo"))
        XCTAssertTrue(TerminalLinkDetector.requiresBaseDirectory("src/main.swift"))
    }

    // MARK: - パス解決

    func testResolvesAbsolutePathUnchanged() {
        XCTAssertEqual(
            TerminalLinkDetector.resolvePath("/a/b/c", homeDirectory: "/Users/x", baseDirectory: nil),
            "/a/b/c")
    }

    func testExpandsTildeOnly() {
        XCTAssertEqual(
            TerminalLinkDetector.resolvePath("~", homeDirectory: "/Users/x", baseDirectory: nil),
            "/Users/x")
    }

    func testExpandsTildePath() {
        XCTAssertEqual(
            TerminalLinkDetector.resolvePath("~/.zshrc", homeDirectory: "/Users/x", baseDirectory: nil),
            "/Users/x/.zshrc")
    }

    func testResolvesDotRelativeAgainstBase() {
        XCTAssertEqual(
            TerminalLinkDetector.resolvePath("./foo.txt", homeDirectory: "/Users/x", baseDirectory: "/work/dir"),
            "/work/dir/foo.txt")
    }

    func testResolvesParentRelativeAgainstBase() {
        XCTAssertEqual(
            TerminalLinkDetector.resolvePath("../foo", homeDirectory: "/Users/x", baseDirectory: "/work/dir"),
            "/work/foo")
    }

    func testResolvesSlashRelativeAgainstBase() {
        XCTAssertEqual(
            TerminalLinkDetector.resolvePath("src/main.swift", homeDirectory: "/Users/x", baseDirectory: "/work/dir"),
            "/work/dir/src/main.swift")
    }

    func testReturnsNilForRelativePathWithoutBase() {
        XCTAssertNil(
            TerminalLinkDetector.resolvePath("foo/bar", homeDirectory: "/Users/x", baseDirectory: nil))
    }

    func testStandardizesDotComponentsInAbsolutePath() {
        // 絶対パス内の . / .. を正規化する
        XCTAssertEqual(
            TerminalLinkDetector.resolvePath("/a/./b/../c", homeDirectory: "/Users/x", baseDirectory: nil),
            "/a/c")
    }

    // MARK: - 折返し行の結合

    func testJoinsNothingForSingleUnwrappedRow() {
        // 右端まで埋まっていない単一行はそのまま論理行になる
        let logical = TerminalLinkDetector.logicalLine(
            rowTexts: ["hello world"], filledToEdge: [false], clickRow: 0, clickColumnInRow: 6)
        XCTAssertEqual(logical?.text, "hello world")
        XCTAssertEqual(logical?.column, 6)
    }

    func testJoinsWrappedRowsAndKeepsClickColumnOnContinuation() {
        // 右端まで埋まった行の次行を継続として結合し、継続行クリックの論理列を求める
        let logical = TerminalLinkDetector.logicalLine(
            rowTexts: ["abcdefghij", "klm"], filledToEdge: [true, false], clickRow: 1, clickColumnInRow: 1)
        XCTAssertEqual(logical?.text, "abcdefghijklm")
        XCTAssertEqual(logical?.column, 11)
    }

    func testJoinsWrappedRowsWhenClickOnFirstRow() {
        // 先頭行クリックでも継続行まで結合し、論理列は先頭行内オフセットのまま
        let logical = TerminalLinkDetector.logicalLine(
            rowTexts: ["abcdefghij", "klm"], filledToEdge: [true, false], clickRow: 0, clickColumnInRow: 2)
        XCTAssertEqual(logical?.text, "abcdefghijklm")
        XCTAssertEqual(logical?.column, 2)
    }

    func testReturnsNilForOutOfRangeClickRow() {
        // 範囲外の clickRow は nil
        XCTAssertNil(TerminalLinkDetector.logicalLine(
            rowTexts: ["a", "b"], filledToEdge: [false, false], clickRow: 5, clickColumnInRow: 0))
    }

    func testDetectsURLSplitAcrossWrapBoundary() {
        // 折返しで分断された URL を結合してから検出できる
        let logical = TerminalLinkDetector.logicalLine(
            rowTexts: ["see https://ex", "ample.com/x no"],
            filledToEdge: [true, false], clickRow: 1, clickColumnInRow: 0)!
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: logical.text, column: logical.column),
            .url(URL(string: "https://example.com/x")!))
    }

    // MARK: - 折返し結合の行端ガード (誤結合防止)

    func testRightAnchoredTokenJoinsDownward() {
        // 右端まで達したトークンは下方向へ結合し、折返しで分断された URL を先頭行クリックでも検出できる
        let logical = TerminalLinkDetector.logicalLine(
            rowTexts: ["see https://ex", "ample.com/x no"],
            filledToEdge: [true, false], clickRow: 0, clickColumnInRow: 10)!
        XCTAssertEqual(logical.text, "see https://example.com/x no")
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: logical.text, column: logical.column),
            .url(URL(string: "https://example.com/x")!))
    }

    func testMiddleTokenDoesNotJoinAdjacentRows() {
        // 行の途中に収まるトークンは、右端まで充填された行でも隣接行と結合しない (誤結合露出の低減)
        let logical = TerminalLinkDetector.logicalLine(
            rowTexts: ["aa https://ex.com bb", "cc.com/x dd"],
            filledToEdge: [true, false], clickRow: 0, clickColumnInRow: 3)!
        XCTAssertEqual(logical.text, "aa https://ex.com bb")
        XCTAssertEqual(
            TerminalLinkDetector.detectLink(logicalLine: logical.text, column: logical.column),
            .url(URL(string: "https://ex.com")!))
    }

    func testJoinedGluedSchemeAcrossWrapReturnsNil() {
        // 行端ガードを通って結合しても、スキーム直前に文字が接着したトークンは URL 扱いされず nil
        let logical = TerminalLinkDetector.logicalLine(
            rowTexts: ["examphttps", "://example.com"],
            filledToEdge: [true, false], clickRow: 1, clickColumnInRow: 0)!
        XCTAssertEqual(logical.text, "examphttps://example.com")
        XCTAssertNil(TerminalLinkDetector.detectLink(logicalLine: logical.text, column: logical.column))
    }
}
