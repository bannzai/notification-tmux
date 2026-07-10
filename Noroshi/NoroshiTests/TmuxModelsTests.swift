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
        let state = AppState(client: TmuxClient(binaryPath: "/usr/bin/false"))
        let event = try XCTUnwrap(StopEvent(url: try XCTUnwrap(URL(string: "noroshi://stop?session=Focus&window=@18"))))
        state.apply(event: event)
        state.apply(event: event)
        XCTAssertEqual(state.badges["@18"], 2)
        state.clearBadge(windowID: "@18")
        XCTAssertNil(state.badges["@18"])
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

    func testSessionNameAtDisplayIndex() {
        let names = ["A", "B", "C"]
        XCTAssertEqual(NoroshiNavigation.sessionName(in: names, atDisplayIndex: 0), "A")
        XCTAssertEqual(NoroshiNavigation.sessionName(in: names, atDisplayIndex: 2), "C")
        XCTAssertNil(NoroshiNavigation.sessionName(in: names, atDisplayIndex: 3))
        XCTAssertNil(NoroshiNavigation.sessionName(in: names, atDisplayIndex: -1))
    }

    func testResolvedSessionOrder() {
        // 保存順を保ちつつ、新規 session (D) を末尾へ足す
        XCTAssertEqual(
            NoroshiNavigation.resolvedSessionOrder(savedOrder: ["C", "A", "B"], currentNames: ["A", "B", "C", "D"]),
            ["C", "A", "B", "D"]
        )
        // 消えた session (X) は結果から落とす
        XCTAssertEqual(
            NoroshiNavigation.resolvedSessionOrder(savedOrder: ["X", "A", "B"], currentNames: ["A", "B"]),
            ["A", "B"]
        )
        // 保存順が空なら現存順そのまま
        XCTAssertEqual(
            NoroshiNavigation.resolvedSessionOrder(savedOrder: [], currentNames: ["A", "B"]),
            ["A", "B"]
        )
        // 現存が空なら空 (server 停止時に順序を失わない掃除抑止は AppState 側の責務)
        XCTAssertEqual(
            NoroshiNavigation.resolvedSessionOrder(savedOrder: ["A", "B"], currentNames: []),
            []
        )
        // 保存順の重複は先勝ちで 1 つに畳む
        XCTAssertEqual(
            NoroshiNavigation.resolvedSessionOrder(savedOrder: ["A", "A", "B"], currentNames: ["A", "B"]),
            ["A", "B"]
        )
        // 全 session が保存順に無い場合も現存順で返す
        XCTAssertEqual(
            NoroshiNavigation.resolvedSessionOrder(savedOrder: ["Z"], currentNames: ["A", "B"]),
            ["A", "B"]
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
    }
}
