import XCTest

@testable import Noroshi

/// 素のターミナル (issue #54) のシェル解決と、シェル終了時のタブ後始末のユニットテスト。
/// 実際にシェルプロセスを起動する PlainTerminalManager.terminalView は呼ばず、純粋ロジックと
/// AppState のタブ操作だけを検証する。
final class PlainTerminalTests: XCTestCase {
    /// 実 tmux・実 config に触れない AppState を作る。
    @MainActor
    private func makeState(defaults: UserDefaults) -> AppState {
        AppState(client: TmuxClient(binaryPath: "/usr/bin/false"), defaults: defaults, remoteHosts: { [] })
    }

    // MARK: - PlainTerminalShell

    func testResolvePrefersExecutablePasswdShell() {
        XCTAssertEqual(
            PlainTerminalShell.resolve(passwdShell: "/opt/homebrew/bin/fish", environmentShell: "/bin/bash", isExecutable: { _ in true }),
            "/opt/homebrew/bin/fish")
    }

    func testResolveFallsBackToEnvironmentShellWhenPasswdShellIsNotExecutable() {
        XCTAssertEqual(
            PlainTerminalShell.resolve(
                passwdShell: "/gone/fish", environmentShell: "/bin/bash", isExecutable: { $0 == "/bin/bash" }),
            "/bin/bash")
    }

    func testResolveFallsBackToZshWhenNoCandidateIsExecutable() {
        XCTAssertEqual(
            PlainTerminalShell.resolve(passwdShell: nil, environmentShell: "", isExecutable: { _ in false }),
            "/bin/zsh")
    }

    // MARK: - NoroshiNavigation.plainTerminalExitAction

    func testExitActionClosesTabWhenOtherTabsRemain() {
        let exitedTab = TerminalTab(id: UUID(), sessionID: nil, windowID: nil)
        let tabs = [TerminalTab(id: UUID(), sessionID: "local:work", windowID: nil), exitedTab]
        XCTAssertEqual(NoroshiNavigation.plainTerminalExitAction(tabs: tabs, tabID: exitedTab.id), .close(index: 1))
    }

    func testExitActionReplacesLastTab() {
        let exitedTab = TerminalTab(id: UUID(), sessionID: nil, windowID: nil)
        XCTAssertEqual(NoroshiNavigation.plainTerminalExitAction(tabs: [exitedTab], tabID: exitedTab.id), .replace(index: 0))
    }

    func testExitActionIgnoresTabShowingSession() {
        // session 表示中のタブは、バックグラウンドでシェルだけが終了してもタブを閉じない。
        let sessionTab = TerminalTab(id: UUID(), sessionID: "local:work", windowID: nil)
        let tabs = [sessionTab, TerminalTab(id: UUID(), sessionID: nil, windowID: nil)]
        XCTAssertEqual(NoroshiNavigation.plainTerminalExitAction(tabs: tabs, tabID: sessionTab.id), .ignore)
    }

    func testExitActionIgnoresUnknownTab() {
        let tabs = [TerminalTab(id: UUID(), sessionID: nil, windowID: nil)]
        XCTAssertEqual(NoroshiNavigation.plainTerminalExitAction(tabs: tabs, tabID: UUID()), .ignore)
    }

    // MARK: - AppState.handlePlainTerminalExit

    @MainActor
    func testHandlePlainTerminalExitClosesExitedTab() throws {
        let suiteName = "PlainTerminalTests.close.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = makeState(defaults: defaults)
        state.addTab()
        let survivingTabID = state.tabs[0].id

        state.handlePlainTerminalExit(tabID: state.tabs[1].id)

        XCTAssertEqual(state.tabs.map(\.id), [survivingTabID])
        XCTAssertEqual(state.activeTabIndex, 0)
    }

    @MainActor
    func testHandlePlainTerminalExitReplacesLastTabWithFreshTab() throws {
        let suiteName = "PlainTerminalTests.replace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = makeState(defaults: defaults)
        let exitedTabID = state.activeTab.id

        state.handlePlainTerminalExit(tabID: exitedTabID)

        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertNotEqual(state.activeTab.id, exitedTabID)
        XCTAssertNil(state.activeTab.sessionID)
    }
}
