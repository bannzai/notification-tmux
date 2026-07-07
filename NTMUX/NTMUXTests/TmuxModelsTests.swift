import XCTest
@testable import NTMUX

/// tmux フォーマット出力のパーサ・StopEvent URL・バッジ台帳のユニットテスト。
/// AppState.open(window:) は実 tmux へ select-window を発行するため、ユーザーの tmux 状態を変更しないようここでは呼ばない。
final class TmuxModelsTests: XCTestCase {
    func testParseWindowLine() {
        let window = TmuxFormat.parseWindowLine("Focus\u{1f}@18\u{1f}3\u{1f}fix-screenshot\u{1f}1\u{1f}3")
        XCTAssertEqual(window?.sessionName, "Focus")
        XCTAssertEqual(window?.id, "@18")
        XCTAssertEqual(window?.index, 3)
        XCTAssertEqual(window?.name, "fix-screenshot")
        XCTAssertEqual(window?.isActive, true)
        XCTAssertEqual(window?.paneCount, 3)
    }

    func testParseWindowLineWithPipeInName() {
        let window = TmuxFormat.parseWindowLine("sukidayo/Riamo\u{1f}@5\u{1f}0\u{1f}a|b|c\u{1f}0\u{1f}1")
        XCTAssertEqual(window?.name, "a|b|c")
        XCTAssertEqual(window?.sessionName, "sukidayo/Riamo")
        XCTAssertEqual(window?.isActive, false)
    }

    func testParseWindowLineInvalid() {
        XCTAssertNil(TmuxFormat.parseWindowLine(""))
        XCTAssertNil(TmuxFormat.parseWindowLine("only-one-field"))
        XCTAssertNil(TmuxFormat.parseWindowLine("s\u{1f}not-window-id\u{1f}0\u{1f}n\u{1f}1\u{1f}1"))
        XCTAssertNil(TmuxFormat.parseWindowLine("s\u{1f}@1\u{1f}x\u{1f}n\u{1f}1\u{1f}1"))
    }

    func testParseSessionLine() {
        let parsed = TmuxFormat.parseSessionLine("Focus\u{1f}2")
        XCTAssertEqual(parsed?.name, "Focus")
        XCTAssertEqual(parsed?.attached, 2)
        XCTAssertNil(TmuxFormat.parseSessionLine("no-separator"))
    }

    func testStopEventFromURL() throws {
        let event = StopEvent(url: try XCTUnwrap(URL(string: "ntmux://stop?session=Focus&window=@18")))
        XCTAssertEqual(event?.sessionName, "Focus")
        XCTAssertEqual(event?.windowID, "@18")
    }

    func testStopEventFromURLWithEncodedSession() throws {
        XCTAssertEqual(
            StopEvent(url: try XCTUnwrap(URL(string: "ntmux://stop?session=sukidayo%2FRiamo&window=@5")))?.sessionName,
            "sukidayo/Riamo"
        )
    }

    func testStopEventRejectsInvalidURL() throws {
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "ntmux://other?session=a&window=@1"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "https://stop?session=a&window=@1"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "ntmux://stop?session=a&window=1"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "ntmux://stop?session=a"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "ntmux://stop?window=@1"))))
    }

    @MainActor
    func testBadgeApplyAndClear() throws {
        let state = AppState(client: TmuxClient(binaryPath: "/usr/bin/false"))
        let event = try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "ntmux://stop?session=Focus&window=@18"))))
        state.apply(event: event)
        state.apply(event: event)
        XCTAssertEqual(state.badges["@18"], 2)
        state.clearBadge(windowID: "@18")
        XCTAssertNil(state.badges["@18"])
    }
}
