import AppKit
import XCTest
@testable import Noroshi

final class TerminalFontResolverTests: XCTestCase {
    func testResolvesNamedStyleFromInstalledFamily() throws {
        let family = "Menlo"
        guard NSFontManager.shared.availableFontFamilies.contains(family) else {
            throw XCTSkip("Menlo is not installed")
        }
        let base = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let font = TerminalFontResolver.resolve(family: family, style: "Bold", size: 14, base: base)

        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(font.pointSize, 14)
    }

    func testUnavailableFamilyFallsBackWithRequestedWeight() {
        let base = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

        let font = TerminalFontResolver.resolve(
            family: "Font Family That Does Not Exist",
            style: "Bold",
            size: 13,
            base: base)

        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertEqual(font.pointSize, 13)
    }

    func testSizeOnlyPreservesBaseFont() {
        let base = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)

        let font = TerminalFontResolver.resolve(family: nil, style: nil, size: 15, base: base)

        XCTAssertEqual(font.fontName, base.fontName)
        XCTAssertEqual(font.pointSize, 15)
    }
}
