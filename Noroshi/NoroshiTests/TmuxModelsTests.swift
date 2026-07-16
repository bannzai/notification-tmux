import XCTest
import UserNotifications
@testable import Noroshi

/// tmux フォーマット出力のパーサ・StopEvent URL・バッジ台帳・通知履歴解決・隣接計算のユニットテスト。
/// 実 tmux へ副作用を出すメソッド (AppState.open / moveWindow / movePane など) はユーザーの tmux 状態を
/// 変更するためここでは呼ばない。移動先の決定は純粋ロジック (NoroshiNavigation) を直接検証する。
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

    func testStopEventFromURL() throws {
        let event = StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Focus&window=@18")))
        XCTAssertEqual(event?.sessionName, "Focus")
        XCTAssertEqual(event?.windowID, "@18")
    }

    func testStopEventFromURLWithEncodedSession() throws {
        XCTAssertEqual(
            StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=sukidayo%2FRiamo&window=@5")))?.sessionName,
            "sukidayo/Riamo"
        )
    }

    func testStopEventNotificationUserInfoRoundTrip() throws {
        let original = try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Focus&window=@18"))))
        XCTAssertEqual(StopEvent(userInfo: original.userInfo), original)
        XCTAssertNil(StopEvent(userInfo: ["session": "Focus", "window": "18"]))
    }

    @MainActor
    func testNativeNotificationContentContainsWindowAndTapDestination() throws {
        let event = try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Focus&window=@18"))))
        let window = TmuxWindow(
            id: "@18", sessionName: "Focus", index: 3,
            name: "build", isActive: false, paneCount: 1)

        let content = NotificationService.makeContent(event: event, window: window)

        XCTAssertEqual(content.title, "Focus")
        XCTAssertEqual(content.body, "[3] build で処理が停止しました")
        XCTAssertEqual(StopEvent(userInfo: content.userInfo), event)
        XCTAssertEqual(content.sound, .default)
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

    @MainActor
    func testBadgeApplyAndClear() throws {
        let suiteName = "TmuxModelsTests.testBadgeApplyAndClear.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["Focus"], forKey: "noroshi.sidebarSessionNames")
        let state = AppState(client: TmuxClient(binaryPath: "/usr/bin/false"), defaults: defaults)
        let event = try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Focus&window=@18"))))
        state.apply(event: event)
        state.apply(event: event)
        XCTAssertEqual(state.badges["@18"], 2)
        state.clearBadge(windowID: "@18")
        XCTAssertNil(state.badges["@18"])
    }

    @MainActor
    func testBadgeIgnoresSessionNotAddedToSidebar() throws {
        let suiteName = "TmuxModelsTests.testBadgeIgnoresSessionNotAddedToSidebar.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(client: TmuxClient(binaryPath: "/usr/bin/false"), defaults: defaults)
        let event = try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Hidden&window=@19"))))

        state.apply(event: event)

        XCTAssertNil(state.badges["@19"])
    }

    @MainActor
    func testSessionExpansionStateIsIdempotent() throws {
        let suiteName = "TmuxModelsTests.testSessionExpansionStateIsIdempotent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(client: TmuxClient(binaryPath: "/usr/bin/false"), defaults: defaults)

        state.setSessionExpanded("Focus", isExpanded: false)
        state.setSessionExpanded("Focus", isExpanded: false)
        XCTAssertEqual(state.collapsedSessionNames, ["Focus"])

        state.setSessionExpanded("Focus", isExpanded: true)
        state.setSessionExpanded("Focus", isExpanded: true)
        XCTAssertTrue(state.collapsedSessionNames.isEmpty)
    }

    @MainActor
    func testRepeatedFocusRequestsAreDeliveredAsSeparateEvents() throws {
        let suiteName = "TmuxModelsTests.testRepeatedFocusRequestsAreDeliveredAsSeparateEvents.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(client: TmuxClient(binaryPath: "/usr/bin/false"), defaults: defaults)

        state.requestFocus(.sidebar)
        let first = try XCTUnwrap(state.focusRequest)
        state.requestFocus(.sidebar)
        let second = try XCTUnwrap(state.focusRequest)

        XCTAssertEqual(first.target, .sidebar)
        XCTAssertEqual(second.target, .sidebar)
        XCTAssertEqual(second.sequence, first.sequence + 1)
    }

    func testLatestUnreadWindowID() {
        let base = Date(timeIntervalSince1970: 1_000)
        let history = [
            NotificationRecord(windowID: "@1", receivedAt: base),
            NotificationRecord(windowID: "@2", receivedAt: base.addingTimeInterval(1)),
            NotificationRecord(windowID: "@1", receivedAt: base.addingTimeInterval(2)),
        ]
        // @1 と @2 が未読 -> 最新受信は @1 (base+2)
        XCTAssertEqual(NoroshiNavigation.latestUnreadWindowID(history: history, badges: ["@1": 2, "@2": 1]), "@1")
        // @1 を既読化 -> @2 が残る
        XCTAssertEqual(NoroshiNavigation.latestUnreadWindowID(history: history, badges: ["@2": 1]), "@2")
        // すべて既読 -> nil
        XCTAssertNil(NoroshiNavigation.latestUnreadWindowID(history: history, badges: [:]))
        // 履歴なし -> nil
        XCTAssertNil(NoroshiNavigation.latestUnreadWindowID(history: [], badges: ["@1": 1]))
    }

    func testTmuxClientErrorIsNoServer() {
        // server 停止時に tmux が返す代表的な stderr は no-server 扱い
        XCTAssertTrue(TmuxClientError.commandFailed(status: 1, stderr: "no server running on /tmp/tmux-501/default").isNoServer)
        XCTAssertTrue(TmuxClientError.commandFailed(status: 1, stderr: "error connecting to /tmp/tmux-501/default (No such file or directory)").isNoServer)
        // それ以外 (一時的な失敗・空 stderr) は no-server ではない
        XCTAssertFalse(TmuxClientError.commandFailed(status: 1, stderr: "can't find session: foo").isNoServer)
        XCTAssertFalse(TmuxClientError.commandFailed(status: 1, stderr: "").isNoServer)
    }

    func testAdjacentSessionName() {
        let names = ["A", "B", "C"]
        XCTAssertEqual(NoroshiNavigation.adjacentSessionName(in: names, from: "A", offset: 1), "B")
        XCTAssertEqual(NoroshiNavigation.adjacentSessionName(in: names, from: "C", offset: 1), "A") // 末尾 -> 先頭
        XCTAssertEqual(NoroshiNavigation.adjacentSessionName(in: names, from: "A", offset: -1), "C") // 先頭 -> 末尾
        XCTAssertEqual(NoroshiNavigation.adjacentSessionName(in: names, from: nil, offset: 1), "A")
        XCTAssertEqual(NoroshiNavigation.adjacentSessionName(in: names, from: "missing", offset: 1), "A")
        XCTAssertNil(NoroshiNavigation.adjacentSessionName(in: [], from: "A", offset: 1))
    }

    func testAttachedSessionFollowDistinguishesTmuxSwitchFromPendingAppSelection() {
        let available: Set<String> = ["A", "B"]
        // appとmanagerがBで一致し、clientだけAへ変わった = prefix+L等のtmux内操作。
        XCTAssertTrue(NoroshiNavigation.shouldFollowAttachedSession(
            selected: "B", managed: "B", attached: "A", availableNames: available))
        // appがBを選んだ直後だがmanager/clientはまだA = View更新待ちなのでAへ戻さない。
        XCTAssertFalse(NoroshiNavigation.shouldFollowAttachedSession(
            selected: "B", managed: "A", attached: "A", availableNames: available))
        // 消えたsessionや同一sessionは追随対象ではない。
        XCTAssertFalse(NoroshiNavigation.shouldFollowAttachedSession(
            selected: "B", managed: "B", attached: "C", availableNames: available))
        XCTAssertFalse(NoroshiNavigation.shouldFollowAttachedSession(
            selected: "B", managed: "B", attached: "B", availableNames: available))
    }

    func testAdjacentSidebarRowTraversesSessionsAndExpandedWindows() {
        let windowA1 = TmuxWindow(id: "@1", sessionName: "A", index: 0, name: "a1", isActive: true, paneCount: 1)
        let windowA2 = TmuxWindow(id: "@2", sessionName: "A", index: 1, name: "a2", isActive: false, paneCount: 1)
        let windowB1 = TmuxWindow(id: "@3", sessionName: "B", index: 0, name: "b1", isActive: true, paneCount: 1)
        let sessions = [
            TmuxSession(id: "A", attachedClients: 0, windows: [windowA1, windowA2]),
            TmuxSession(id: "B", attachedClients: 0, windows: [windowB1]),
        ]

        // session 行 -> 配下の window 行 -> 次の session 行の順で下る
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionNames: [], from: .session(name: "A"), offset: 1),
            .window(windowA1))
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionNames: [], from: .window(windowA2), offset: 1),
            .session(name: "B"))
        // 逆順も同じ経路を上る
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionNames: [], from: .session(name: "B"), offset: -1),
            .window(windowA2))
        // 端では停止する (循環しない)
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionNames: [], from: .session(name: "A"), offset: -1),
            .session(name: "A"))
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionNames: [], from: .window(windowB1), offset: 1),
            .window(windowB1))
        // 折りたたみ中 session の window は辿らない
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionNames: ["A"], from: .session(name: "A"), offset: 1),
            .session(name: "B"))
        // 起点が nil / 表示行に無い場合は先頭行へ
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionNames: [], from: nil, offset: 1),
            .session(name: "A"))
        XCTAssertEqual(
            NoroshiNavigation.adjacentSidebarRow(in: sessions, collapsedSessionNames: ["A"], from: .window(windowA1), offset: 1),
            .session(name: "A"))
        // 表示行が無ければ nil
        XCTAssertNil(NoroshiNavigation.adjacentSidebarRow(in: [], collapsedSessionNames: [], from: nil, offset: 1))
    }

    func testSessionNameAtDisplayIndex() {
        let names = ["A", "B", "C"]
        XCTAssertEqual(NoroshiNavigation.sessionName(in: names, atDisplayIndex: 0), "A")
        XCTAssertEqual(NoroshiNavigation.sessionName(in: names, atDisplayIndex: 2), "C")
        XCTAssertNil(NoroshiNavigation.sessionName(in: names, atDisplayIndex: 3))
        XCTAssertNil(NoroshiNavigation.sessionName(in: names, atDisplayIndex: -1))
    }

    func testDisplayedSessionNames() {
        // 追加済み session だけを保存順で返し、未追加の新規 session (D) は自動追加しない
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionNames(savedOrder: ["C", "A", "B"], currentNames: ["A", "B", "C", "D"]),
            ["C", "A", "B"]
        )
        // 消えた session (X) は表示結果から落とす
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionNames(savedOrder: ["X", "A", "B"], currentNames: ["A", "B"]),
            ["A", "B"]
        )
        // 保存順が空なら、現存 session があっても空
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionNames(savedOrder: [], currentNames: ["A", "B"]),
            []
        )
        // 現存が空なら空
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionNames(savedOrder: ["A", "B"], currentNames: []),
            []
        )
        // 保存順の重複は先勝ちで 1 つに畳む
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionNames(savedOrder: ["A", "A", "B"], currentNames: ["A", "B"]),
            ["A", "B"]
        )
        // 全 session が未追加なら空
        XCTAssertEqual(
            NoroshiNavigation.displayedSessionNames(savedOrder: ["Z"], currentNames: ["A", "B"]),
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
