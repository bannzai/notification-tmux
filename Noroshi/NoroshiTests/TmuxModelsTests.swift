import XCTest
import UserNotifications
@testable import Noroshi

/// tmux フォーマット出力のパーサ・複合 ID・StopEvent・バッジ台帳・通知履歴解決・隣接計算・タブ操作のユニットテスト。
/// 実 tmux へ副作用を出すメソッド (AppState.open / moveWindow / movePane など) はユーザーの tmux 状態を
/// 変更するためここでは呼ばない。移動先の決定は純粋ロジック (NoroshiNavigation) を直接検証する。
final class TmuxModelsTests: XCTestCase {
    /// 実 tmux・実 config に触れない AppState を作る。
    @MainActor
    private func makeState(defaults: UserDefaults) -> AppState {
        AppState(client: TmuxClient(binaryPath: "/usr/bin/false"), defaults: defaults, remoteHosts: { [] })
    }

    /// 実 tmux の代わりに固定の一覧を返す偽 tmux スクリプトを作る (refresh の選択挙動をユーザーの実 session に触れず検証するため)。
    /// sessionsFile へ 1 行 1 session 名を書くと list-sessions / list-windows がそれを返し、
    /// 空にすると no-server エラーを返して server 停止を再現する。
    private func makeFakeTmuxScript() throws -> (binaryPath: String, sessionsFile: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noroshi-fake-tmux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let sessionsFile = directory.appendingPathComponent("sessions.txt")
        let scriptURL = directory.appendingPathComponent("tmux")
        // \037 は TmuxFormat.fieldSeparator (0x1F) の octal エスケープ。
        try """
        #!/bin/sh
        SESSIONS_FILE="\(sessionsFile.path)"
        if [ ! -s "$SESSIONS_FILE" ]; then
          echo "no server running on /tmp/noroshi-fake" >&2
          exit 1
        fi
        case "$1" in
        list-windows)
          i=1
          while IFS= read -r name; do
            printf '%s\\037@%s\\0370\\037main\\0371\\0371\\n' "$name" "$i"
            i=$((i+1))
          done < "$SESSIONS_FILE"
          ;;
        list-sessions)
          while IFS= read -r name; do
            printf '%s\\0370\\n' "$name"
          done < "$SESSIONS_FILE"
          ;;
        esac
        """.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        return (scriptURL.path, sessionsFile)
    }

    // MARK: - TmuxHost / TmuxID

    func testTmuxHostIDRoundTrip() {
        XCTAssertEqual(TmuxHost.local.id, "local")
        XCTAssertEqual(TmuxHost.remote("dev-machine").id, "dev-machine")
        XCTAssertEqual(TmuxHost(id: "local"), .local)
        XCTAssertEqual(TmuxHost(id: "dev-machine"), .remote("dev-machine"))
        XCTAssertNil(TmuxHost.local.displayName)
        XCTAssertEqual(TmuxHost.remote("dev-machine").displayName, "dev-machine")
    }

    func testTmuxIDMakeAndSplit() throws {
        XCTAssertEqual(TmuxID.make(hostID: "local", element: "@5"), "local:@5")
        let split = try XCTUnwrap(TmuxID.split("local:@5"))
        XCTAssertEqual(split.hostID, "local")
        XCTAssertEqual(split.element, "@5")
        // host 側に ":" を含む (IPv6 等) 場合も、要素側は ":" を含まないため最後の ":" で分解できる
        let ipv6 = try XCTUnwrap(TmuxID.split("fe80::1:@12"))
        XCTAssertEqual(ipv6.hostID, "fe80::1")
        XCTAssertEqual(ipv6.element, "@12")
        XCTAssertNil(TmuxID.split("no-separator"))
    }

    // MARK: - パーサ

    func testParseWindowLine() {
        let window = TmuxFormat.parseWindowLine("Focus\u{1f}@18\u{1f}3\u{1f}fix-screenshot\u{1f}1\u{1f}3")
        XCTAssertEqual(window?.sessionName, "Focus")
        XCTAssertEqual(window?.windowID, "@18")
        XCTAssertEqual(window?.id, "local:@18")
        XCTAssertEqual(window?.sessionID, "local:Focus")
        XCTAssertEqual(window?.index, 3)
        XCTAssertEqual(window?.name, "fix-screenshot")
        XCTAssertEqual(window?.isActive, true)
        XCTAssertEqual(window?.paneCount, 3)
    }

    func testParseWindowLineOnRemoteHost() {
        let window = TmuxFormat.parseWindowLine("Focus\u{1f}@18\u{1f}0\u{1f}build\u{1f}0\u{1f}1", host: .remote("dev"))
        XCTAssertEqual(window?.host, .remote("dev"))
        XCTAssertEqual(window?.id, "dev:@18")
        XCTAssertEqual(window?.sessionID, "dev:Focus")
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

    func testParseWindowGridLine() {
        XCTAssertEqual(TmuxFormat.parseWindowGridLine("209\u{1f}60"), TmuxWindowGrid(cols: 209, rows: 60))
    }

    func testParseWindowGridLineInvalid() {
        XCTAssertNil(TmuxFormat.parseWindowGridLine(""))
        XCTAssertNil(TmuxFormat.parseWindowGridLine("209"))
        XCTAssertNil(TmuxFormat.parseWindowGridLine("x\u{1f}y"))
        XCTAssertNil(TmuxFormat.parseWindowGridLine("0\u{1f}60"))
        XCTAssertNil(TmuxFormat.parseWindowGridLine("209\u{1f}0"))
    }

    func testParseSessionIDLinePreservesPaneTargetCharactersInName() {
        let parsed = TmuxFormat.parseSessionIDLine("$12\u{1f}my.app:build%1")
        XCTAssertEqual(parsed?.id, "$12")
        XCTAssertEqual(parsed?.name, "my.app:build%1")
        XCTAssertNil(TmuxFormat.parseSessionIDLine("not-an-id\u{1f}Focus"))
    }

    func testParseClientLine() {
        XCTAssertEqual(
            TmuxFormat.parseClientLine("1234\u{1f}/dev/ttys001\u{1f}Focus"),
            TmuxAttachedClient(pid: 1234, tty: "/dev/ttys001", sessionName: "Focus")
        )
        XCTAssertNil(TmuxFormat.parseClientLine("not-a-pid\u{1f}/dev/ttys001\u{1f}Focus"))
        XCTAssertNil(TmuxFormat.parseClientLine("1234\u{1f}\u{1f}Focus"))
    }

    // MARK: - StopEvent

    func testStopEventFromURL() throws {
        let event = StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Focus&window=@18")))
        XCTAssertEqual(event?.host, .local)
        XCTAssertEqual(event?.sessionName, "Focus")
        XCTAssertEqual(event?.windowID, "@18")
        XCTAssertEqual(event?.sessionID, "local:Focus")
        XCTAssertEqual(event?.windowKey, "local:@18")
    }

    func testStopEventFromURLWithEncodedSession() throws {
        XCTAssertEqual(
            StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=sukidayo%2FRiamo&window=@5")))?.sessionName,
            "sukidayo/Riamo"
        )
    }

    func testStopEventFromURLWithHostParameter() throws {
        // host クエリはリモート発火をローカルから模擬するデバッグ用の入口
        let event = StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Focus&window=@18&host=dev")))
        XCTAssertEqual(event?.host, .remote("dev"))
        XCTAssertEqual(event?.windowKey, "dev:@18")
    }

    func testStopEventFromRemotePayload() {
        // リモート socket の 1 行。受信経路が host を確定するため、クエリの host より優先される
        let event = StopEvent(payload: "session=sukidayo%2FRiamo&window=@5\n", from: .remote("dev"))
        XCTAssertEqual(event?.host, .remote("dev"))
        XCTAssertEqual(event?.sessionName, "sukidayo/Riamo")
        XCTAssertEqual(event?.windowID, "@5")
        let overridden = StopEvent(payload: "session=a&window=@1&host=other", from: .remote("dev"))
        XCTAssertEqual(overridden?.host, .remote("dev"))
    }

    func testStopEventFromRemotePayloadInvalid() {
        XCTAssertNil(StopEvent(payload: "", from: .remote("dev")))
        XCTAssertNil(StopEvent(payload: "session=a", from: .remote("dev")))
        XCTAssertNil(StopEvent(payload: "session=a&window=1", from: .remote("dev")))
        XCTAssertNil(StopEvent(payload: "not a query at all \u{1f}", from: .remote("dev")))
    }

    func testStopEventNotificationUserInfoRoundTrip() throws {
        let original = try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Focus&window=@18"))))
        XCTAssertEqual(StopEvent(userInfo: original.userInfo), original)
        // リモート発イベントも host ごと復元される
        let remote = try XCTUnwrap(StopEvent(payload: "session=Focus&window=@18", from: .remote("dev")))
        XCTAssertEqual(StopEvent(userInfo: remote.userInfo), remote)
        // host 未収録の旧通知はローカル扱い
        XCTAssertEqual(StopEvent(userInfo: ["session": "Focus", "window": "@18"])?.host, .local)
        XCTAssertNil(StopEvent(userInfo: ["session": "Focus", "window": "18"]))
    }

    @MainActor
    func testNativeNotificationContentContainsWindowAndTapDestination() throws {
        let event = try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Focus&window=@18"))))
        let window = TmuxWindow(
            host: .local, windowID: "@18", sessionName: "Focus", index: 3,
            name: "build", isActive: false, paneCount: 1)

        let content = NotificationService.makeContent(event: event, window: window)

        XCTAssertEqual(content.title, "Focus")
        XCTAssertEqual(content.body, "[3] build で処理が停止しました")
        XCTAssertEqual(StopEvent(userInfo: content.userInfo), event)
        XCTAssertEqual(content.sound, .default)
    }

    @MainActor
    func testNativeNotificationTitleContainsRemoteHostName() throws {
        let event = try XCTUnwrap(StopEvent(payload: "session=Focus&window=@18", from: .remote("dev")))
        XCTAssertEqual(NotificationService.makeContent(event: event, window: nil).title, "Focus (dev)")
    }

    func testStopEventRejectsInvalidURL() throws {
        // ホスト不一致 / スキーム不一致 / window が @ で始まらない / パラメータ欠落 / 旧 ntmux スキーム
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://other?session=a&window=@1"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "https://stop?session=a&window=@1"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=a&window=1"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=a"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?window=@1"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "ntmux://stop?session=a&window=@1"))))
    }

    // MARK: - バッジ台帳 / AppState

    @MainActor
    func testSidebarSessionIDsMigratesLegacyLocalNames() throws {
        let suiteName = "TmuxModelsTests.testSidebarSessionIDsMigratesLegacyLocalNames.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // 旧形式 (session 名のみ) と新形式 (複合 ID) が混在しても、読み込み時にすべて複合 ID になる
        defaults.set(["Focus", "dev:Riamo"], forKey: "noroshi.sidebarSessionNames")
        let state = makeState(defaults: defaults)
        XCTAssertEqual(state.sidebarSessionIDs, ["local:Focus", "dev:Riamo"])
    }

    @MainActor
    func testBadgeApplyAndClear() throws {
        let suiteName = "TmuxModelsTests.testBadgeApplyAndClear.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = makeState(defaults: defaults)
        let event = try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Focus&window=@18"))))
        state.apply(event: event)
        state.apply(event: event)
        XCTAssertEqual(state.badges["local:@18"], 2)
        state.clearBadge(windowID: "local:@18")
        XCTAssertNil(state.badges["local:@18"])
    }

    @MainActor
    func testBadgeSeparatesSameSessionNameAcrossHosts() throws {
        let suiteName = "TmuxModelsTests.testBadgeSeparatesSameSessionNameAcrossHosts.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = makeState(defaults: defaults)
        // 同名 session でも host が違えば別バッジになる
        state.apply(event: try XCTUnwrap(StopEvent(payload: "session=Focus&window=@18", from: .remote("dev"))))
        state.apply(event: try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Focus&window=@18")))))
        XCTAssertEqual(state.badges, ["dev:@18": 1, "local:@18": 1])
    }

    @MainActor
    func testBadgeAppliesSessionNotInSavedOrder() throws {
        let suiteName = "TmuxModelsTests.testBadgeAppliesSessionNotInSavedOrder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = makeState(defaults: defaults)
        // 保存順 (表示順) に載っていない session のイベントも既定で受け付ける (issue #47)
        state.apply(event: try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Fresh&window=@19")))))

        XCTAssertEqual(state.badges["local:@19"], 1)
    }

    @MainActor
    func testBadgeIgnoresHiddenSessionAndPersistsHiddenIDs() throws {
        let suiteName = "TmuxModelsTests.testBadgeIgnoresHiddenSessionAndPersistsHiddenIDs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = makeState(defaults: defaults)
        // 「サイドバーから削除」した session のイベントは無視する (issue #47)
        state.removeSessionFromSidebar("local:Hidden")
        state.apply(event: try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Hidden&window=@19")))))

        XCTAssertNil(state.badges["local:@19"])
        // 非表示は UserDefaults に永続化され、別インスタンスでも維持される
        XCTAssertEqual(makeState(defaults: defaults).hiddenSessionIDs, ["local:Hidden"])
    }

    // MARK: - 自動 attach しない (issue #48)

    @MainActor
    func testRefreshDoesNotAutoSelectSessionOnLaunch() async throws {
        let suiteName = "TmuxModelsTests.testRefreshDoesNotAutoSelectSessionOnLaunch.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["local:Focus"], forKey: "noroshi.sidebarSessionNames")
        let fakeTmux = try makeFakeTmuxScript()
        try "Focus\n".write(to: fakeTmux.sessionsFile, atomically: true, encoding: .utf8)
        let state = AppState(client: TmuxClient(binaryPath: fakeTmux.binaryPath), defaults: defaults, remoteHosts: { [] })

        await state.refresh()

        // session が現存しサイドバーに表示されていても、ユーザーが選ぶまで自動選択 (自動 attach の起点) しない
        XCTAssertEqual(state.displaySessionIDs, ["local:Focus"])
        XCTAssertNil(state.selectedSessionID)
    }

    @MainActor
    func testRefreshClearsSelectionWhenSelectedSessionDisappears() async throws {
        let suiteName = "TmuxModelsTests.testRefreshClearsSelectionWhenSelectedSessionDisappears.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["local:A", "local:B"], forKey: "noroshi.sidebarSessionNames")
        let fakeTmux = try makeFakeTmuxScript()
        try "A\nB\n".write(to: fakeTmux.sessionsFile, atomically: true, encoding: .utf8)
        let state = AppState(client: TmuxClient(binaryPath: fakeTmux.binaryPath), defaults: defaults, remoteHosts: { [] })
        await state.refresh()
        state.selectSession(id: "local:A")
        XCTAssertEqual(state.selectedSessionID, "local:A")

        try "B\n".write(to: fakeTmux.sessionsFile, atomically: true, encoding: .utf8)
        await state.refresh()

        // 選択中 session の消滅 (kill 等) では選択を解除し、残った session へ自動フォールバック (自動 attach) しない
        XCTAssertEqual(state.displaySessionIDs, ["local:B"])
        XCTAssertNil(state.selectedSessionID)

        // 同名 session が復活 (ssh ごしの tmux 起動等) しても、未選択のままで自動 attach しない
        try "A\nB\n".write(to: fakeTmux.sessionsFile, atomically: true, encoding: .utf8)
        await state.refresh()
        XCTAssertNil(state.selectedSessionID)
    }

    @MainActor
    func testRemoveSelectedSessionFromSidebarClearsSelection() async throws {
        let suiteName = "TmuxModelsTests.testRemoveSelectedSessionFromSidebarClearsSelection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["local:A", "local:B"], forKey: "noroshi.sidebarSessionNames")
        let fakeTmux = try makeFakeTmuxScript()
        try "A\nB\n".write(to: fakeTmux.sessionsFile, atomically: true, encoding: .utf8)
        let state = AppState(client: TmuxClient(binaryPath: fakeTmux.binaryPath), defaults: defaults, remoteHosts: { [] })
        await state.refresh()
        state.selectSession(id: "local:A")

        state.removeSessionFromSidebar("local:A")

        // 表示中 session をサイドバーから外した時も、残った session へ自動で移って attach しない
        XCTAssertEqual(state.sidebarSessionIDs, ["local:B"])
        XCTAssertNil(state.selectedSessionID)
    }

    @MainActor
    func testSessionExpansionStateIsIdempotent() throws {
        let suiteName = "TmuxModelsTests.testSessionExpansionStateIsIdempotent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = makeState(defaults: defaults)

        state.setSessionExpanded("local:Focus", isExpanded: false)
        state.setSessionExpanded("local:Focus", isExpanded: false)
        XCTAssertEqual(state.collapsedSessionIDs, ["local:Focus"])

        state.setSessionExpanded("local:Focus", isExpanded: true)
        state.setSessionExpanded("local:Focus", isExpanded: true)
        XCTAssertTrue(state.collapsedSessionIDs.isEmpty)
    }

    @MainActor
    func testRepeatedFocusRequestsAreDeliveredAsSeparateEvents() throws {
        let suiteName = "TmuxModelsTests.testRepeatedFocusRequestsAreDeliveredAsSeparateEvents.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = makeState(defaults: defaults)

        state.requestFocus(.sidebar)
        let first = try XCTUnwrap(state.focusRequest)
        state.requestFocus(.sidebar)
        let second = try XCTUnwrap(state.focusRequest)

        XCTAssertEqual(first.target, .sidebar)
        XCTAssertEqual(second.target, .sidebar)
        XCTAssertEqual(second.sequence, first.sequence + 1)
    }

    // MARK: - タブ (issue #40)

    @MainActor
    func testAddSelectAndCloseTabs() throws {
        let suiteName = "TmuxModelsTests.testAddSelectAndCloseTabs.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = makeState(defaults: defaults)
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertEqual(state.activeTabIndex, 0)

        // 追加した空タブがアクティブになり、選択は持たない
        state.addTab()
        XCTAssertEqual(state.tabs.count, 2)
        XCTAssertEqual(state.activeTabIndex, 1)
        XCTAssertNil(state.selectedSessionID)

        // タブ切替は範囲内のみ。循環切替は前後に回る
        state.selectTab(at: 0)
        XCTAssertEqual(state.activeTabIndex, 0)
        state.selectTab(at: 9)
        XCTAssertEqual(state.activeTabIndex, 0)
        state.selectAdjacentTab(1)
        XCTAssertEqual(state.activeTabIndex, 1)
        state.selectAdjacentTab(1)
        XCTAssertEqual(state.activeTabIndex, 0)
        state.selectAdjacentTab(-1)
        XCTAssertEqual(state.activeTabIndex, 1)

        // アクティブタブを閉じると残ったタブへ移る。最後の 1 枚は閉じない
        state.closeTab(at: 1)
        XCTAssertEqual(state.tabs.count, 1)
        XCTAssertEqual(state.activeTabIndex, 0)
        state.closeTab(at: 0)
        XCTAssertEqual(state.tabs.count, 1)
    }

    func testActiveTabIndexAfterClosing() {
        // アクティブより左を閉じる -> 左へ 1 つ詰める
        XCTAssertEqual(NoroshiNavigation.activeTabIndexAfterClosing(at: 0, activeIndex: 2, remainingCount: 2), 1)
        // アクティブより右を閉じる -> 変わらない
        XCTAssertEqual(NoroshiNavigation.activeTabIndexAfterClosing(at: 2, activeIndex: 0, remainingCount: 2), 0)
        // アクティブ自身 (中間) を閉じる -> 同じ位置 (右隣が繰り上がる)
        XCTAssertEqual(NoroshiNavigation.activeTabIndexAfterClosing(at: 1, activeIndex: 1, remainingCount: 2), 1)
        // アクティブ自身 (末尾) を閉じる -> 新しい末尾
        XCTAssertEqual(NoroshiNavigation.activeTabIndexAfterClosing(at: 2, activeIndex: 2, remainingCount: 2), 1)
    }

    // MARK: - ナビゲーション純粋ロジック

    func testLatestUnreadWindowID() {
        let base = Date(timeIntervalSince1970: 1_000)
        let history = [
            NotificationRecord(windowID: "local:@1", receivedAt: base),
            NotificationRecord(windowID: "local:@2", receivedAt: base.addingTimeInterval(1)),
            NotificationRecord(windowID: "local:@1", receivedAt: base.addingTimeInterval(2)),
        ]
        // @1 と @2 が未読 -> 最新受信は @1 (base+2)
        XCTAssertEqual(NoroshiNavigation.latestUnreadWindowID(history: history, badges: ["local:@1": 2, "local:@2": 1]), "local:@1")
        // @1 を既読化 -> @2 が残る
        XCTAssertEqual(NoroshiNavigation.latestUnreadWindowID(history: history, badges: ["local:@2": 1]), "local:@2")
        // すべて既読 -> nil
        XCTAssertNil(NoroshiNavigation.latestUnreadWindowID(history: history, badges: [:]))
        // 履歴なし -> nil
        XCTAssertNil(NoroshiNavigation.latestUnreadWindowID(history: [], badges: ["local:@1": 1]))
    }

    func testTmuxClientErrorIsNoServer() {
        // server 停止時に tmux が返す代表的な stderr は no-server 扱い
        XCTAssertTrue(TmuxClientError.commandFailed(status: 1, stderr: "no server running on /tmp/tmux-501/default").isNoServer)
        XCTAssertTrue(TmuxClientError.commandFailed(status: 1, stderr: "error connecting to /tmp/tmux-501/default (No such file or directory)").isNoServer)
        // それ以外 (一時的な失敗・空 stderr) は no-server ではない
        XCTAssertFalse(TmuxClientError.commandFailed(status: 1, stderr: "can't find session: foo").isNoServer)
        XCTAssertFalse(TmuxClientError.commandFailed(status: 1, stderr: "").isNoServer)
        XCTAssertFalse(TmuxClientError.remoteClientTTYMissing(host: "dev").isNoServer)
    }

    func testAdjacentSessionID() {
        let sessionIDs = ["local:A", "dev:A", "local:C"]
        XCTAssertEqual(NoroshiNavigation.adjacentSessionID(in: sessionIDs, from: "local:A", offset: 1), "dev:A")
        XCTAssertEqual(NoroshiNavigation.adjacentSessionID(in: sessionIDs, from: "local:C", offset: 1), "local:A") // 末尾 -> 先頭
        XCTAssertEqual(NoroshiNavigation.adjacentSessionID(in: sessionIDs, from: "local:A", offset: -1), "local:C") // 先頭 -> 末尾
        XCTAssertEqual(NoroshiNavigation.adjacentSessionID(in: sessionIDs, from: nil, offset: 1), "local:A")
        XCTAssertEqual(NoroshiNavigation.adjacentSessionID(in: sessionIDs, from: "missing", offset: 1), "local:A")
        XCTAssertNil(NoroshiNavigation.adjacentSessionID(in: [], from: "local:A", offset: 1))
    }

    func testAdjacentWindowCrossesSessions() {
        let windowA1 = TmuxWindow(host: .local, windowID: "@1", sessionName: "A", index: 0, name: "a1", isActive: true, paneCount: 1)
        let windowA2 = TmuxWindow(host: .local, windowID: "@2", sessionName: "A", index: 1, name: "a2", isActive: false, paneCount: 1)
        let windowB1 = TmuxWindow(host: .remote("dev"), windowID: "@1", sessionName: "B", index: 0, name: "b1", isActive: true, paneCount: 1)
        let sessions = [
            TmuxSession(host: .local, name: "A", attachedClients: 0, windows: [windowA1, windowA2]),
            TmuxSession(host: .remote("dev"), name: "B", attachedClients: 0, windows: [windowB1]),
        ]

        // session 内の隣へ移動する
        XCTAssertEqual(NoroshiNavigation.adjacentWindow(in: sessions, from: windowA1.id, offset: 1), windowA2)
        // session の端では隣の session の window へ跨ぐ (host をまたいでも連続する; issue #52)
        XCTAssertEqual(NoroshiNavigation.adjacentWindow(in: sessions, from: windowA2.id, offset: 1), windowB1)
        XCTAssertEqual(NoroshiNavigation.adjacentWindow(in: sessions, from: windowB1.id, offset: -1), windowA2)
        // 全体の末尾↔先頭で循環する
        XCTAssertEqual(NoroshiNavigation.adjacentWindow(in: sessions, from: windowB1.id, offset: 1), windowA1)
        XCTAssertEqual(NoroshiNavigation.adjacentWindow(in: sessions, from: windowA1.id, offset: -1), windowB1)
        // 起点が nil / 一覧に無い場合は先頭 window へ
        XCTAssertEqual(NoroshiNavigation.adjacentWindow(in: sessions, from: nil, offset: 1), windowA1)
        XCTAssertEqual(NoroshiNavigation.adjacentWindow(in: sessions, from: "missing", offset: 1), windowA1)
        // window が無ければ nil
        XCTAssertNil(NoroshiNavigation.adjacentWindow(in: [], from: windowA1.id, offset: 1))
    }

    func testAttachedSessionFollowDistinguishesTmuxSwitchFromPendingAppSelection() {
        let available: Set<String> = ["local:A", "local:B"]
        // appとmanagerがBで一致し、clientだけAへ変わった = prefix+L等のtmux内操作。
        XCTAssertTrue(NoroshiNavigation.shouldFollowAttachedSession(
            selected: "local:B", managed: "local:B", attached: "local:A", availableIDs: available))
        // appがBを選んだ直後だがmanager/clientはまだA = View更新待ちなのでAへ戻さない。
        XCTAssertFalse(NoroshiNavigation.shouldFollowAttachedSession(
            selected: "local:B", managed: "local:A", attached: "local:A", availableIDs: available))
        // 消えたsessionや同一sessionは追随対象ではない。
        XCTAssertFalse(NoroshiNavigation.shouldFollowAttachedSession(
            selected: "local:B", managed: "local:B", attached: "local:C", availableIDs: available))
        XCTAssertFalse(NoroshiNavigation.shouldFollowAttachedSession(
            selected: "local:B", managed: "local:B", attached: "local:B", availableIDs: available))
    }

    func testAdjacentSidebarRowTraversesSessionsAndExpandedWindows() {
        let windowA1 = TmuxWindow(host: .local, windowID: "@1", sessionName: "A", index: 0, name: "a1", isActive: true, paneCount: 1)
        let windowA2 = TmuxWindow(host: .local, windowID: "@2", sessionName: "A", index: 1, name: "a2", isActive: false, paneCount: 1)
        let windowB1 = TmuxWindow(host: .remote("dev"), windowID: "@1", sessionName: "B", index: 0, name: "b1", isActive: true, paneCount: 1)
        let sessions = [
            TmuxSession(host: .local, name: "A", attachedClients: 0, windows: [windowA1, windowA2]),
            TmuxSession(host: .remote("dev"), name: "B", attachedClients: 0, windows: [windowB1]),
        ]

        // session 行 -> 配下の window 行 -> 次の session 行の順で下る (host をまたいでも連続する)
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionIDs: [], from: .session(id: "local:A"), offset: 1),
            .window(windowA1))
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionIDs: [], from: .window(windowA2), offset: 1),
            .session(id: "dev:B"))
        // 逆順も同じ経路を上る
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionIDs: [], from: .session(id: "dev:B"), offset: -1),
            .window(windowA2))
        // 端では停止する (循環しない)
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionIDs: [], from: .session(id: "local:A"), offset: -1),
            .session(id: "local:A"))
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionIDs: [], from: .window(windowB1), offset: 1),
            .window(windowB1))
        // 折りたたみ中 session の window は辿らない
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionIDs: ["local:A"], from: .session(id: "local:A"), offset: 1),
            .session(id: "dev:B"))
        // 起点が nil / 表示行に無い場合は先頭行へ
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionIDs: [], from: nil, offset: 1),
            .session(id: "local:A"))
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionIDs: ["local:A"], from: .window(windowA1), offset: 1),
            .session(id: "local:A"))
        // 表示行が無ければ nil
        XCTAssertNil(NoroshiNavigation.adjacentSidebarRow(in: [], collapsedSessionIDs: [], from: nil, offset: 1))
    }

    func testSessionIDAtDisplayIndex() {
        let sessionIDs = ["local:A", "local:B", "dev:C"]
        XCTAssertEqual(NoroshiNavigation.sessionID(in: sessionIDs, atDisplayIndex: 0), "local:A")
        XCTAssertEqual(NoroshiNavigation.sessionID(in: sessionIDs, atDisplayIndex: 2), "dev:C")
        XCTAssertNil(NoroshiNavigation.sessionID(in: sessionIDs, atDisplayIndex: 3))
        XCTAssertNil(NoroshiNavigation.sessionID(in: sessionIDs, atDisplayIndex: -1))
    }

    func testDisplayedSessionIDs() {
        // 保存順の session を先頭に、保存順に無い session (D) も現存順で末尾に自動表示する (issue #47)
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionIDs(savedOrder: ["local:C", "local:A", "dev:B"], currentIDs: ["local:A", "dev:B", "local:C", "local:D"], hiddenIDs: []),
            ["local:C", "local:A", "dev:B", "local:D"]
        )
        // 非表示の session は保存順 (B)・自動表示 (D) のどちらからも除く
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionIDs(savedOrder: ["local:A", "local:B"], currentIDs: ["local:A", "local:B", "local:C", "local:D"], hiddenIDs: ["local:B", "local:D"]),
            ["local:A", "local:C"]
        )
        // 消えた session (X) は表示結果から落とす
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionIDs(savedOrder: ["local:X", "local:A", "local:B"], currentIDs: ["local:A", "local:B"], hiddenIDs: []),
            ["local:A", "local:B"]
        )
        // 保存順が空でも現存 session をすべて表示する
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionIDs(savedOrder: [], currentIDs: ["local:A", "local:B"], hiddenIDs: []),
            ["local:A", "local:B"]
        )
        // 現存が空なら空
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionIDs(savedOrder: ["local:A", "local:B"], currentIDs: [], hiddenIDs: []),
            []
        )
        // 保存順の重複は先勝ちで 1 つに畳む
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionIDs(savedOrder: ["local:A", "local:A", "local:B"], currentIDs: ["local:A", "local:B"], hiddenIDs: []),
            ["local:A", "local:B"]
        )
        // 全 session が非表示なら空
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionIDs(savedOrder: [], currentIDs: ["local:A", "local:B"], hiddenIDs: ["local:A", "local:B"]),
            []
        )
    }


    func testAvailableSessionNameUsesDirectoryAndNextFreeSuffix() {
        let directory = URL(fileURLWithPath: "/Users/example/project")
        XCTAssertEqual(TmuxSessionNaming.availableName(for: directory, existingNames: []), "project")
        XCTAssertEqual(
            TmuxSessionNaming.availableName(
                for: directory,
                existingNames: ["project", "project-2", "project-4"]),
            "project-3"
        )

        XCTAssertEqual(
            TmuxSessionNaming.availableName(
                for: URL(fileURLWithPath: "/Users/example/my.app:demo"),
                existingNames: []),
            "my_app_demo"
        )
    }
}
