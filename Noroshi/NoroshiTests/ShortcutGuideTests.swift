import AppKit
import Combine
import SwiftUI
import XCTest

@testable import Noroshi

/// Cmd 長押しガイドの表示判定と cmd+B サイドバートグルのユニットテスト。
/// 実キーイベントの代わりに AppState.handleModifierFlagsChanged へ修飾キー状態を直接渡して検証する。
final class ShortcutGuideTests: XCTestCase {
    func testIsCommandOnly() {
        XCTAssertTrue(ShortcutGuide.isCommandOnly(.command))
        // capsLock 等の状態系フラグはショートカットの意味を変えないため cmd 単独として扱う。
        XCTAssertTrue(ShortcutGuide.isCommandOnly([.command, .capsLock]))
        XCTAssertFalse(ShortcutGuide.isCommandOnly([.command, .shift]))
        XCTAssertFalse(ShortcutGuide.isCommandOnly([.command, .option]))
        XCTAssertFalse(ShortcutGuide.isCommandOnly([.command, .control]))
        XCTAssertFalse(ShortcutGuide.isCommandOnly(.shift))
        XCTAssertFalse(ShortcutGuide.isCommandOnly([]))
    }

    func testGuideNumber() {
        XCTAssertEqual(ShortcutGuide.guideNumber(forDisplayIndex: 0), 1)
        XCTAssertEqual(ShortcutGuide.guideNumber(forDisplayIndex: 8), 9)
        XCTAssertNil(ShortcutGuide.guideNumber(forDisplayIndex: 9))
        XCTAssertNil(ShortcutGuide.guideNumber(forDisplayIndex: -1))
    }

    @MainActor
    func testShortcutGuidePresentsAfterHoldAndHidesOnRelease() async throws {
        let suiteName = "ShortcutGuideTests.testShortcutGuidePresentsAfterHoldAndHidesOnRelease.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(client: TmuxClient(binaryPath: "/usr/bin/false"), defaults: defaults)
        // テスト実行中は実キーが押されていないため、押しっぱなしの状態を注入する。
        state.currentModifierFlags = { .command }

        let presented = expectation(description: "ガイドが表示される")
        let cancellable = state.$isShortcutGuidePresented.filter { $0 }.sink { _ in presented.fulfill() }
        state.handleModifierFlagsChanged(.command)
        XCTAssertFalse(state.isShortcutGuidePresented)

        await fulfillment(of: [presented], timeout: 5)
        cancellable.cancel()
        XCTAssertTrue(state.isShortcutGuidePresented)

        state.handleModifierFlagsChanged([])
        XCTAssertFalse(state.isShortcutGuidePresented)
    }

    @MainActor
    func testShortcutGuideCancelledWhenReleasedBeforeHold() async throws {
        let suiteName = "ShortcutGuideTests.testShortcutGuideCancelledWhenReleasedBeforeHold.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(client: TmuxClient(binaryPath: "/usr/bin/false"), defaults: defaults)
        state.currentModifierFlags = { .command }

        state.handleModifierFlagsChanged(.command)
        state.handleModifierFlagsChanged([])
        // shift 等が混ざる場合も表示待ちを開始しない。
        state.handleModifierFlagsChanged([.command, .shift])

        try await Task.sleep(for: .seconds(ShortcutGuide.holdDuration + 0.5))
        XCTAssertFalse(state.isShortcutGuidePresented)
    }

    @MainActor
    func testShortcutGuideNotPresentedWhenActualKeyStateDiffers() async throws {
        let suiteName = "ShortcutGuideTests.testShortcutGuideNotPresentedWhenActualKeyStateDiffers.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(client: TmuxClient(binaryPath: "/usr/bin/false"), defaults: defaults)
        // cmd+tab でのアプリ切替等で離しイベントを取りこぼしても、実キー状態が cmd 単独でなければ表示しない。
        state.currentModifierFlags = { [] }

        state.handleModifierFlagsChanged(.command)

        try await Task.sleep(for: .seconds(ShortcutGuide.holdDuration + 0.5))
        XCTAssertFalse(state.isShortcutGuidePresented)
    }

    @MainActor
    func testToggleSidebar() throws {
        let suiteName = "ShortcutGuideTests.testToggleSidebar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(client: TmuxClient(binaryPath: "/usr/bin/false"), defaults: defaults)

        XCTAssertEqual(state.sidebarVisibility, .all)
        state.toggleSidebar()
        XCTAssertEqual(state.sidebarVisibility, .detailOnly)
        state.toggleSidebar()
        XCTAssertEqual(state.sidebarVisibility, .all)
    }
}
