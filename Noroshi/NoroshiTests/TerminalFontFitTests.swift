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
                grid: TmuxWindowGrid(cols: 80, rows: 20),
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
                grid: TmuxWindowGrid(cols: 120, rows: 10),
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
                grid: TmuxWindowGrid(cols: 10, rows: 25),
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
                grid: TmuxWindowGrid(cols: 10, rows: 40),
                viewSize: CGSize(width: 615, height: 400),
                scrollerWidth: 15,
                cellSize: syntheticCell),
            TerminalFontFit.minimumFontSize)
    }

    func testFittedSizeKeepsPreferredAtOrBelowMinimum() {
        XCTAssertEqual(
            TerminalFontFit.fittedSize(
                preferred: 5,
                grid: TmuxWindowGrid(cols: 1000, rows: 1000),
                viewSize: CGSize(width: 615, height: 400),
                scrollerWidth: 15,
                cellSize: syntheticCell),
            5)
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
