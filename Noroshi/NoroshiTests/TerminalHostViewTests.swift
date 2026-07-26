import AppKit
import SwiftTerm
import XCTest

@testable import Noroshi

@MainActor
final class TerminalHostViewTests: XCTestCase {
    func testMarkedTextIsPreviewedAndShortenedWithoutKeepingOldText() throws {
        let view = MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        view.setMarkedText("にほんご", selectedRange: NSRange(location: 4, length: 0), replacementRange: noRange)

        XCTAssertTrue(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 4))
        XCTAssertEqual(try markedTextOverlay(in: view).stringValue, "にほんご")

        view.setMarkedText("にほん", selectedRange: NSRange(location: 3, length: 0), replacementRange: noRange)

        XCTAssertEqual(view.markedRange(), NSRange(location: 0, length: 3))
        XCTAssertEqual(try markedTextOverlay(in: view).stringValue, "にほん")
    }

    func testNSStringMarkedTextIsPreviewedAndEmptyTextRemovesPreview() throws {
        let view = MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))

        view.setMarkedText(NSString(string: "にほんご"), selectedRange: NSRange(location: 4, length: 0), replacementRange: noRange)
        XCTAssertEqual(try markedTextOverlay(in: view).stringValue, "にほんご")

        view.setMarkedText(NSString(string: ""), selectedRange: NSRange(location: 0, length: 0), replacementRange: noRange)
        XCTAssertFalse(view.hasMarkedText())
        XCTAssertFalse(view.subviews.contains { $0 is NSTextField && ($0 as? NSTextField)?.stringValue == "にほんご" })
    }

    func testUnmarkTextRemovesPreviewAndMarkedState() {
        let view = MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0), replacementRange: noRange)

        view.unmarkText()

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), noRange)
        XCTAssertFalse(view.subviews.contains { $0 is NSTextField && ($0 as? NSTextField)?.stringValue == "日本語" })
    }

    func testInsertTextClearsPreviewAndMarkedState() {
        let view = MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0), replacementRange: noRange)

        view.insertText("日本語", replacementRange: noRange)

        XCTAssertFalse(view.hasMarkedText())
        XCTAssertEqual(view.markedRange(), noRange)
        XCTAssertFalse(view.subviews.contains { $0 is NSTextField && ($0 as? NSTextField)?.stringValue == "日本語" })
    }

    func testTextInputRangesExposeCompositionAndCursorPosition() throws {
        let view = MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 0))

        view.setMarkedText("日本語", selectedRange: NSRange(location: 3, length: 0), replacementRange: noRange)

        var actualRange = NSRange(location: NSNotFound, length: 0)
        let substring = view.attributedSubstring(
            forProposedRange: NSRange(location: 1, length: 2),
            actualRange: &actualRange
        )
        XCTAssertEqual(actualRange, NSRange(location: 1, length: 2))
        XCTAssertEqual(try XCTUnwrap(substring).string, "本語")
        XCTAssertEqual(
            Set(view.validAttributesForMarkedText()),
            Set([.underlineStyle, .markedClauseSegment, .glyphInfo])
        )
    }

    /// SwiftTerm が自動折返しした継続行は getText で改行を挟まない。wrapsToNextRow が実 wrap を検出する前提の確認。
    func testAutoWrappedBoundaryHasNoNewlineInGetText() {
        let view = MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = view.getTerminal()
        terminal.feed(text: String(repeating: "x", count: terminal.cols) + "yy")
        XCTAssertFalse(terminal.getText(
            start: Position(col: 0, row: terminal.buffer.yDisp),
            end: Position(col: terminal.cols, row: terminal.buffer.yDisp + 1)).contains("\n"))
    }

    /// SwiftTerm の font setter (resetFont) は scroller 幅を引かずに cols を計算し、同じ frame での setFrameSize は
    /// processSizeChange が scroller 幅を引いた必ず小さい cols へ再リサイズする前提の確認。applyFont はこの差分で
    /// 実サイズ変更 (SIGWINCH) を起こし、font setter の softReset で tmux とずれたスクロール領域を全再描画で
    /// 再同期させる (ADR 0010)。この差分が無くなると同一格子の font 変更で tmux が再同期されず画面が崩れる。
    func testSetFrameSizeAfterFontChangeShrinksColsByScrollerWidth() {
        let view = MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        let cell = TerminalFontFit.cellSize(
            of: view.font, scale: view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        XCTAssertEqual(view.getTerminal().cols, Int(800 / cell.width))

        view.setFrameSize(view.frame.size)

        XCTAssertEqual(
            view.getTerminal().cols,
            Int((800 - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)) / cell.width))
        XCTAssertLessThan(view.getTerminal().cols, Int(800 / cell.width))
    }

    /// ハード改行 (\r\n) 境界は getText で "\n" を挟む。桁数不一致でクリップ描画された非折返し行が結合されない根拠。
    func testHardNewlineBoundaryHasNewlineInGetText() {
        let view = MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let terminal = view.getTerminal()
        terminal.feed(text: "aaa\r\nbbb")
        XCTAssertTrue(terminal.getText(
            start: Position(col: 0, row: terminal.buffer.yDisp),
            end: Position(col: terminal.cols, row: terminal.buffer.yDisp + 1)).contains("\n"))
    }

    /// ファイルドロップを受け入れる前提となる dragged type 登録の確認 (issue #41)。
    /// SwiftTerm 本体は登録しないため、subclass の init で file URL が登録されていることを検証する。
    func testFileURLDraggedTypeIsRegistered() {
        XCTAssertTrue(
            MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
                .registeredDraggedTypes.contains(.fileURL))
    }

    private var noRange: NSRange {
        NSRange(location: NSNotFound, length: 0)
    }

    private func markedTextOverlay(in view: MouseReportingTerminalView) throws -> NSTextField {
        try XCTUnwrap(view.subviews.compactMap { $0 as? NSTextField }.first { !$0.stringValue.isEmpty })
    }
}
