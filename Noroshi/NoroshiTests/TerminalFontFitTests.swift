import AppKit
import SwiftTerm
import XCTest

@testable import Noroshi

/// フォントのフィット計算 (issue #36) のユニットテスト。
/// 判定境界はサイズに比例する合成メトリクスで厳密に検証し、
/// 実フォントに対しては SwiftTerm の格子計算との一致を確認する。
final class TerminalFontFitTests: XCTestCase {
    /// セル寸法をサイズに比例させる合成メトリクス。幅 = size * 0.6, 高さ = size * 2。
    private func syntheticCell(_ size: CGFloat) -> CGSize {
        CGSize(width: size * 0.6, height: size * 2)
    }

    func testFittedSizeReturnsPreferredWhenGridFits() {
        // 幅 (615 - 15) / (10 * 0.6) = 100 cols ≥ 80、高さ 400 / (10 * 2) = 20 rows ≥ 20 で収まる。
        XCTAssertEqual(
            TerminalFontFit.fittedSize(
                preferred: 10,
                grid: TmuxWindowGrid(cols: 80, rows: 20, statusRows: 0),
                viewSize: CGSize(width: 615, height: 400),
                scrollerWidth: 15,
                cellSize: syntheticCell),
            10)
    }

    func testFittedSizeShrinksUntilColumnsFit() {
        // 600 / (size * 0.6) ≥ 120 を満たす最大の 0.5 刻みは 8.0 (8.5 では 117 cols で不足)。
        XCTAssertEqual(
            TerminalFontFit.fittedSize(
                preferred: 10,
                grid: TmuxWindowGrid(cols: 120, rows: 10, statusRows: 0),
                viewSize: CGSize(width: 615, height: 400),
                scrollerWidth: 15,
                cellSize: syntheticCell),
            8.0)
    }

    func testFittedSizeShrinksUntilRowsFit() {
        // 400 / (size * 2) ≥ 25 を満たす最大の 0.5 刻みは 8.0 (8.5 では 23 rows で不足)。
        XCTAssertEqual(
            TerminalFontFit.fittedSize(
                preferred: 10,
                grid: TmuxWindowGrid(cols: 10, rows: 25, statusRows: 0),
                viewSize: CGSize(width: 615, height: 400),
                scrollerWidth: 15,
                cellSize: syntheticCell),
            8.0)
    }

    func testFittedSizeStopsAtMinimum() {
        // 400 / (size * 2) ≥ 40 には size ≤ 5 が必要だが、下限 6 で止まる。
        XCTAssertEqual(
            TerminalFontFit.fittedSize(
                preferred: 10,
                grid: TmuxWindowGrid(cols: 10, rows: 40, statusRows: 0),
                viewSize: CGSize(width: 615, height: 400),
                scrollerWidth: 15,
                cellSize: syntheticCell),
            TerminalFontFit.minimumFontSize)
    }

    func testFittedSizeCountsStatusRows() {
        // window 20 行だけなら 400 / (10 * 2) = 20 rows で収まるが、status line 1 行分を足すと
        // 400 / (size * 2) ≥ 21 を満たす最大の 0.5 刻み 9.5 まで縮む。
        XCTAssertEqual(
            TerminalFontFit.fittedSize(
                preferred: 10,
                grid: TmuxWindowGrid(cols: 80, rows: 20, statusRows: 1),
                viewSize: CGSize(width: 615, height: 400),
                scrollerWidth: 15,
                cellSize: syntheticCell),
            9.5)
    }

    func testFittedSizeKeepsPreferredAtOrBelowMinimum() {
        XCTAssertEqual(
            TerminalFontFit.fittedSize(
                preferred: 5,
                grid: TmuxWindowGrid(cols: 1000, rows: 1000, statusRows: 1),
                viewSize: CGSize(width: 615, height: 400),
                scrollerWidth: 15,
                cellSize: syntheticCell),
            5)
    }

    func testConstrainedViewSizeYieldsExactGrid() {
        // 格子固定寸法 (issue #60) を SwiftTerm の processSizeChange と同じ式に通すと、
        // 列 = window 列、行 = window 行 + status 行にちょうど一致する (余白セルが生まれない)。
        for (grid, fontSize) in [
            (TmuxWindowGrid(cols: 80, rows: 24, statusRows: 1), CGFloat(10)),
            (TmuxWindowGrid(cols: 209, rows: 60, statusRows: 0), 7.5),
            (TmuxWindowGrid(cols: 163, rows: 53, statusRows: 2), 6),
        ] {
            let cell = syntheticCell(fontSize)
            let size = TerminalFontFit.constrainedViewSize(grid: grid, cell: cell, scrollerWidth: 15)
            XCTAssertEqual(Int((size.width - 15) / cell.width), grid.cols, "cols for \(grid)")
            XCTAssertEqual(Int(size.height / cell.height), grid.rows + grid.statusRows, "rows for \(grid)")
        }
    }

    /// cellSize が SwiftTerm の格子計算 (resetFont: cols = frame.width / cellWidth) と一致することを確認する。
    /// 式 (ピクセル格子への切り上げスナップ含む) がずれると「収まる」と判定したサイズで実際には列が足りず、見切れが再発する。
    @MainActor
    func testCellSizeMatchesSwiftTermGridCalculation() {
        let view = MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        // window の無いテスト環境では SwiftTerm の backingScaleFactor() は NSScreen.main へフォールバックする。
        let scale = NSScreen.main?.backingScaleFactor ?? 1
        for size in [CGFloat(9), 11.5, 14] {
            view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let cell = TerminalFontFit.cellSize(of: view.font, scale: scale)
            XCTAssertEqual(view.getTerminal().cols, Int(800 / cell.width), "font size \(size)")
            XCTAssertEqual(view.getTerminal().rows, Int(600 / cell.height), "font size \(size)")
        }
    }
}
