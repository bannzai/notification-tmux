import AppKit
import Combine
import SwiftUI

/// メニューショートカットから移すフォーカス先。
enum AppFocusTarget: Equatable {
    case sidebar
    case terminal
}

/// 同じフォーカス先への連続要求も View へ伝えるためのイベント。
struct AppFocusRequest: Equatable {
    let sequence: Int
    let target: AppFocusTarget
}

/// アプリ全体の状態。session 一覧・未読バッジ・通知履歴・タブごとの選択中 session を持つ。
/// session/window の識別子はすべて host 込みの複合 ID (TmuxID) で扱う (issue #38)。
/// ObservableObject を要求する SwiftUI のためクラスにしている。
@MainActor
final class AppState: ObservableObject {
    /// 通知履歴の保持上限。超えた分は古いものから捨てる (メモリのみ)。
    static let notificationHistoryLimit = 1000

    /// サイドバーへ追加した session と表示順を永続化する UserDefaults キー。
    /// 旧形式 (ローカル session 名のみ) の値も同じキーのまま複合 ID へ移行する。
    private static let sidebarSessionNamesDefaultsKey = "noroshi.sidebarSessionNames"

    /// tmux から取得した全 host の session 一覧 (ローカル → config の remote-host 順)。表示順は displaySessions が解決する。
    @Published private(set) var sessions: [TmuxSession] = []
    /// ユーザーがサイドバーへ追加した session ID (表示順)。UserDefaults に永続化する。
    /// 消えた session の ID も残し、同名 session が再作成されたら再表示する。
    @Published private(set) var sidebarSessionIDs: [String]
    /// TmuxWindow.id -> 未読数。Stop イベントで加算し、window を開いたらクリアする。
    @Published private(set) var badges: [String: Int] = [:]
    /// terminal 表示のタブ (issue #40)。常に 1 枚以上あり、選択状態はアクティブタブが持つ。
    @Published private(set) var tabs: [TerminalTab] = [TerminalTab(id: UUID(), sessionID: nil, windowID: nil)]
    /// tabs の中で表示中のタブ index。タブ操作以外では変化しない。
    @Published private(set) var activeTabIndex = 0
    /// 折りたたみ中の session ID。未収録なら展開状態。
    @Published private(set) var collapsedSessionIDs: Set<String> = []
    /// メニューから View へ配送する最新のフォーカス要求。
    @Published private(set) var focusRequest: AppFocusRequest?
    /// 直近の tmux コマンド失敗 (host ごとに 1 行)。エラーメッセージは加工せずそのまま表示する。
    @Published var lastError: String?
    /// コマンドパレット (cmd+P) の表示状態。true の間だけ terminal の上にオーバーレイを重ねる。
    @Published var isPalettePresented = false
    /// サイドバーがキーボードフォーカスを持っているか。true の間は terminal がフォーカスを奪わず、
    /// ↑↓ でのサイドバーナビゲーションを session 切替をまたいで継続できるようにする (issue #30)。
    @Published var isSidebarFocused = false
    /// サイドバー列の表示状態。cmd+B のトグルと NavigationSplitView の双方向同期に使う。
    @Published var sidebarVisibility: NavigationSplitViewVisibility = .all
    /// Cmd 長押しガイド (cmd+1..9 の対象表示) の表示状態。true の間サイドバーの session 行に番号バッジを重ねる。
    @Published private(set) var isShortcutGuidePresented = false
    /// サイドバー下部のフィルタ入力。session 名・host 名・window 名・index を部分一致で絞り込む。
    @Published var sidebarQuery: String = ""
    /// 通知フィルタ。true のとき未読 (badge > 0) の window だけをサイドバーに表示する。
    @Published var showsNotifiedOnly: Bool = false

    /// terminal を表示中の session ID (アクティブタブの選択)。nil なら未選択。
    /// タブが選択状態の SSOT のため、stored ではなくアクティブタブへの参照にしている。
    private(set) var selectedSessionID: String? {
        get { tabs[activeTabIndex].sessionID }
        set { tabs[activeTabIndex].sessionID = newValue }
    }

    /// サイドバーで選択表示する window ID (アクティブタブの選択)。クリック直後もポーリングを待たずに表示へ反映する。
    private(set) var selectedWindowID: String? {
        get { tabs[activeTabIndex].windowID }
        set { tabs[activeTabIndex].windowID = newValue }
    }

    /// Stop イベントの受信履歴 (古い順)。「最新の通知へジャンプ」の発生順解決に使う。バッジ台帳とは独立。
    private var notifications: [NotificationRecord] = []
    /// ローカル tmux の CLI ラッパ。リモート host 用の client は client(for:) が同じ binaryPath で作る。
    private let client: TmuxClient
    /// config からリモート host 一覧を読む。ポーリングごとに評価し、config 編集を再起動なしで反映する。
    private let remoteHostsProvider: @Sendable () -> [String]
    /// サイドバーへ追加した session ID の保存先。
    private let defaults: UserDefaults
    /// 一覧ポーリングのループ。
    private var pollTask: Task<Void, Never>?
    /// `select-window` 完了待ちの window ID。ポーリングが古い active window を返しても選択表示を戻さないために保持する。
    private var requestedWindowID: String?
    /// 同じフォーカス先への連続操作を別イベントとして配送する連番。
    private var focusRequestSequence = 0
    /// Cmd 長押しガイドの表示待ちタスク。holdDuration 前に cmd が離されたらキャンセルする。
    private var shortcutGuideDelayTask: Task<Void, Never>?
    /// flagsChanged のローカルモニタ。多重登録を防ぐため保持する。
    private var modifierFlagsMonitor: Any?
    // テストから現在の修飾キー状態を差し替えるために var にしている。実行時は実キー状態を参照する。
    var currentModifierFlags: () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }

    // テストからダミー binaryPath の client / 固定のリモート host 一覧を注入するために定義している
    init(client: TmuxClient = TmuxClient(),
         defaults: UserDefaults = .standard,
         remoteHosts: @escaping @Sendable () -> [String] = { NoroshiConfig.remoteHosts() })
    {
        self.client = client
        self.defaults = defaults
        self.remoteHostsProvider = remoteHosts
        // 旧形式 (ローカル session 名のみ) を複合 ID へ移行する。tmux の session 名は ":" を含まないため判別できる。
        self.sidebarSessionIDs = (defaults.stringArray(forKey: Self.sidebarSessionNamesDefaultsKey) ?? [])
            .map { $0.contains(":") ? $0 : TmuxID.make(hostID: TmuxHost.local.id, element: $0) }
    }

    /// host に応じた tmux CLI ラッパ。ローカルは注入された client をそのまま使う (テストのダミー binaryPath を保つため)。
    private func client(for host: TmuxHost) -> TmuxClient {
        host == .local ? client : TmuxClient(binaryPath: client.binaryPath, host: host)
    }

    /// ID から現在の session を解決する。
    func session(id: String) -> TmuxSession? {
        sessions.first(where: { $0.id == id })
    }

    /// アクティブタブで表示中の session。消えた session を選択中なら nil。
    var selectedSession: TmuxSession? {
        selectedSessionID.flatMap { session(id: $0) }
    }

    /// サイドバー・cmd+数字・session 隣接移動が共通で使う表示順の session ID。
    /// 追加済みの保存順から、現存していて表示できる session ID だけを解決する。
    var displaySessionIDs: [String] {
        NoroshiNavigation.displayedSessionIDs(savedOrder: sidebarSessionIDs, currentIDs: sessions.map(\.id))
    }

    /// 表示順に並べ替えた session。サイドバーはこれを列挙する。
    var displaySessions: [TmuxSession] {
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        return displaySessionIDs.compactMap { sessionsByID[$0] }
    }

    /// picker に並べる未追加の現存 session。一覧順 (ローカル → remote-host 順、各 host 内は tmux の一覧順) を保つ。
    var availableSessions: [TmuxSession] {
        let addedIDs = Set(sidebarSessionIDs)
        return sessions.filter { !addedIDs.contains($0.id) }
    }

    /// サイドバーが実際に列挙する session。表示順の displaySessions にフィルタ (テキスト + 通知) を適用する。
    var filteredDisplaySessions: [TmuxSession] {
        SidebarFilter.filteredSessions(displaySessions, query: sidebarQuery, showsNotifiedOnly: showsNotifiedOnly, badges: badges)
    }

    /// コマンドパレットが列挙する候補。表示順の session ごとに、session 行 → 配下 window 行の順で平坦化する。
    var paletteItems: [PaletteItem] {
        displaySessions.flatMap { session in
            [PaletteItem(kind: .session(session), badge: badgeCount(for: session))]
                + session.windows.map { PaletteItem(kind: .window($0), badge: badges[$0.id] ?? 0) }
        }
    }

    /// サイドバーのドラッグ&ドロップによる session 並べ替えを表示順に反映し、永続化する。
    func moveSessions(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = displaySessionIDs
        reordered.move(fromOffsets: source, toOffset: destination)
        // 消えていて現在は表示できない session ID を末尾に残し、復活時に選択状態を失わないようにする。
        let hiddenIDs = sidebarSessionIDs.filter { !reordered.contains($0) }
        saveSidebarSessionIDs(reordered + hiddenIDs)
    }

    /// picker で選んだ session をサイドバー末尾へ追加して保存する。追加済みなら何もしない (冪等)。
    func addSessionToSidebar(_ sessionID: String) {
        guard sessions.contains(where: { $0.id == sessionID }),
              !sidebarSessionIDs.contains(sessionID) else { return }
        saveSidebarSessionIDs(sidebarSessionIDs + [sessionID])
        if selectedSessionID == nil {
            selectedSessionID = sessionID
            synchronizeSelectedWindow()
        }
    }

    /// session をサイドバーから外して保存する。未追加なら何もしない (冪等)。
    func removeSessionFromSidebar(_ sessionID: String) {
        let updated = sidebarSessionIDs.filter { $0 != sessionID }
        guard updated != sidebarSessionIDs else { return }
        if let removedSession = session(id: sessionID) {
            let removedWindowIDs = Set(removedSession.windows.map(\.id))
            badges = badges.filter { !removedWindowIDs.contains($0.key) }
            updateDockBadge()
        }
        saveSidebarSessionIDs(updated)
        if selectedSessionID == sessionID {
            selectedSessionID = displaySessionIDs.first
            synchronizeSelectedWindow()
        }
    }

    /// session の折りたたみ状態を更新する。同じ状態への再設定は何もしない (冪等)。
    func setSessionExpanded(_ sessionID: String, isExpanded: Bool) {
        var updated = collapsedSessionIDs
        if isExpanded {
            updated.remove(sessionID)
        } else {
            updated.insert(sessionID)
        }
        guard updated != collapsedSessionIDs else { return }
        collapsedSessionIDs = updated
    }

    /// session を選択し、必要ならサイドバー上でも展開する。
    func selectSession(id sessionID: String, expand: Bool = false) {
        guard displaySessionIDs.contains(sessionID) else { return }
        selectedSessionID = sessionID
        if expand {
            setSessionExpanded(sessionID, isExpanded: true)
        }
        synchronizeSelectedWindow()
    }

    /// フォーカス要求は同じ対象への連続ショートカットも毎回配送する必要があるため、意図的に連番を進める。
    func requestFocus(_ target: AppFocusTarget) {
        focusRequestSequence += 1
        focusRequest = AppFocusRequest(sequence: focusRequestSequence, target: target)
    }

    /// サイドバーの表示/非表示を切り替える (cmd+B)。
    func toggleSidebar() {
        sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
    }

    // MARK: - タブ (issue #40)

    /// 新しい空タブを開いて表示する (cmd+T)。ユーザー操作ごとに 1 枚増えるため意図的に非冪等。
    func addTab() {
        tabs.append(TerminalTab(id: UUID(), sessionID: nil, windowID: nil))
        activeTabIndex = tabs.count - 1
    }

    /// index のタブへ表示を切り替える。範囲外は何もしない。
    func selectTab(at index: Int) {
        guard tabs.indices.contains(index), index != activeTabIndex else { return }
        activeTabIndex = index
    }

    /// 表示順で offset (次: +1 / 前: -1) 隣のタブに循環で切り替える (ctrl+tab / ctrl+shift+tab)。
    func selectAdjacentTab(_ offset: Int) {
        guard tabs.count > 1 else { return }
        selectTab(at: ((activeTabIndex + offset) % tabs.count + tabs.count) % tabs.count)
    }

    /// index のタブを閉じる。最後の 1 枚は閉じない (ウィンドウを閉じる操作に委ねる)。
    func closeTab(at index: Int) {
        guard tabs.count > 1, tabs.indices.contains(index) else { return }
        tabs.remove(at: index)
        activeTabIndex = NoroshiNavigation.activeTabIndexAfterClosing(
            at: index, activeIndex: activeTabIndex, remainingCount: tabs.count)
    }

    // MARK: - ポーリング

    /// session/window 一覧のポーリングを開始する。多重起動しない (冪等)。
    func startPolling(interval: TimeInterval = 2.0) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    /// 全 host (ローカル + config の remote-host) から一覧を取り直し、消えた window のバッジを掃除する。
    /// host ごとに独立して更新し、失敗した host は前回の一覧とバッジを据え置く (ssh の一時断でリモートの表示を消さないため)。
    func refresh() async {
        let localClient = self.client
        let remoteHostsProvider = self.remoteHostsProvider
        let attachedClientPID = TerminalSessionManager.shared.attachedHost == .local
            ? TerminalSessionManager.shared.attachedClientPID : nil
        let managedHost = TerminalSessionManager.shared.managedHost
        let managedSessionName = TerminalSessionManager.shared.managedSessionName
        let managedSessionID = TerminalSessionManager.shared.managedSessionID

        let outcome = await Task.detached(priority: .utility) {
            () -> (hosts: [TmuxHost],
                   results: [(host: TmuxHost, sessions: [TmuxSession]?, errorDescription: String?)],
                   attachedSessionName: String?,
                   grid: TmuxWindowGrid?) in
            let hosts: [TmuxHost] = [.local] + remoteHostsProvider().map(TmuxHost.remote)
            // host ごとの取得を並行させ、遅い ssh がポーリング全体を直列に遅らせないようにする。
            let fetched = await withTaskGroup(of: (Int, Result<[TmuxSession], Error>).self) { group in
                for (index, host) in hosts.enumerated() {
                    group.addTask {
                        (index, Result { try TmuxClient(binaryPath: localClient.binaryPath, host: host).fetchSessions() })
                    }
                }
                var resultsByIndex = [Int: Result<[TmuxSession], Error>]()
                for await (index, result) in group {
                    resultsByIndex[index] = result
                }
                return hosts.indices.map { resultsByIndex[$0]! }
            }
            let results = zip(hosts, fetched).map { host, result -> (TmuxHost, [TmuxSession]?, String?) in
                switch result {
                case .success(let hostSessions):
                    return (host, hostSessions, nil)
                case .failure(let error):
                    // server 停止 (no-server) は「session 0 個」として成功に倒し、消えた session への再 attach ループを止める。
                    if (error as? TmuxClientError)?.isNoServer == true {
                        return (host, [], nil)
                    }
                    return (host, nil, host.displayName.map { "\($0): \(error)" } ?? "\(error)")
                }
            }
            // 表示中 session への追随と格子取得は best-effort (失敗しても一覧の更新は継続する)。
            let attachedSession = attachedClientPID.flatMap { try? localClient.attachedClient(pid: $0)?.sessionName }
            let gridHost: TmuxHost? = attachedSession != nil ? .local : managedHost
            let gridSession = attachedSession ?? managedSessionName
            // 表示中 window の格子サイズ (フォントのフィット計算用; issue #36)。
            let grid: TmuxWindowGrid? = {
                guard let gridHost, let gridSession else { return nil }
                return try? TmuxClient(binaryPath: localClient.binaryPath, host: gridHost).windowGrid(session: gridSession)
            }()
            return (hosts, results, attachedSession, grid)
        }.value

        TerminalSessionManager.shared.updateWindowGrid(outcome.grid)

        var mergedSessions: [TmuxSession] = []
        var errorMessages: [String] = []
        var succeededHostIDs = Set<String>()
        let previousSessionsByHost = Dictionary(grouping: sessions, by: \.host)
        for (host, hostSessions, errorDescription) in outcome.results {
            if let hostSessions {
                mergedSessions += hostSessions
                succeededHostIDs.insert(host.id)
            } else {
                mergedSessions += previousSessionsByHost[host] ?? []
                if let errorDescription { errorMessages.append(errorDescription) }
            }
        }
        // 変化が無い時は再代入せず、2 秒ポーリング由来の不要な再描画 (terminal のフォーカス奪取等) を避ける。
        if mergedSessions != sessions { sessions = mergedSessions }
        // 同一エラーの再代入は objectWillChange を無駄に発火させるため値が変わった時だけ更新する。
        let errorMessage = errorMessages.isEmpty ? nil : errorMessages.joined(separator: "\n")
        if lastError != errorMessage { lastError = errorMessage }

        // バッジ掃除は取得に成功した host の分だけ行う。失敗中の host は据え置き、config から消えた host は破棄する。
        let configuredHostIDs = Set(outcome.hosts.map(\.id))
        let alive = Set(mergedSessions.flatMap(\.windows).map(\.id))
        badges = badges.filter { key, _ in
            guard let keyHostID = TmuxID.split(key)?.hostID else { return false }
            if succeededHostIDs.contains(keyHostID) { return alive.contains(key) }
            return configuredHostIDs.contains(keyHostID)
        }

        // リモート通知の受信路 (issue #39) を config の host 集合に冪等に一致させる。
        RemoteStopReceiver.shared.reconcile(
            hostNames: outcome.hosts.compactMap(\.displayName)
        ) { [weak self] event in
            self?.receiveStopEvent(event)
        }

        // 未選択、または選択中の session が消えた (kill 等) 場合は表示順の先頭にフォールバックする。
        // これが「消えた session への再 attach ループ」を止めるガード (単一 attach の TerminalSessionManager と対で機能する)。
        let attachedSessionID = outcome.attachedSessionName.map { TmuxID.make(hostID: TmuxHost.local.id, element: $0) }
        if NoroshiNavigation.shouldFollowAttachedSession(
            selected: selectedSessionID,
            managed: managedSessionID,
            attached: attachedSessionID,
            availableIDs: Set(displaySessionIDs)),
            let attachedSessionName = outcome.attachedSessionName,
            let attachedSessionID
        {
            // prefix+L / choose-tree 等、tmux内で行われたsession切替をアプリ側の選択へ反映する (ローカル attach のみ)。
            // manager側も先に同期し、View更新時に同じsessionへswitchし直して履歴を壊さないようにする。
            TerminalSessionManager.shared.synchronizeCurrentSession(host: .local, sessionName: attachedSessionName)
            selectedSessionID = attachedSessionID
        } else if selectedSessionID.map({ !displaySessionIDs.contains($0) }) ?? true {
            selectedSessionID = displaySessionIDs.first
        }
        if let requestedWindowID,
           mergedSessions.lazy.flatMap(\.windows).contains(where: { $0.id == requestedWindowID })
        {
            selectedWindowID = requestedWindowID
        } else {
            requestedWindowID = nil
            synchronizeSelectedWindow()
        }
        updateDockBadge()
    }

    // MARK: - Stop イベント

    /// Stop イベントの共通受け口 (URL スキーム / リモート socket)。
    /// サイドバー追加済み session のイベントだけをバッジへ反映し、macOS 標準通知を配信する。
    func receiveStopEvent(_ event: StopEvent) {
        guard sidebarSessionIDs.contains(event.sessionID) else { return }
        apply(event: event)
        NotificationService.shared.deliver(event: event, window: window(id: event.windowKey))
    }

    /// 追加済み session の Stop hook イベントだけを適用し、該当 window の未読数を 1 増やして履歴に記録する。
    func apply(event: StopEvent) {
        guard sidebarSessionIDs.contains(event.sessionID) else { return }
        badges[event.windowKey, default: 0] += 1
        notifications.append(NotificationRecord(windowID: event.windowKey, receivedAt: Date()))
        if notifications.count > Self.notificationHistoryLimit {
            notifications.removeFirst(notifications.count - Self.notificationHistoryLimit)
        }
        updateDockBadge()
    }

    /// 指定IDのwindowを現在の一覧から返す。通知本文と通知タップの遷移先解決に使う。
    func window(id: String) -> TmuxWindow? {
        sessions.lazy.flatMap(\.windows).first(where: { $0.id == id })
    }

    /// macOS通知をタップした時に対象windowを開く。一覧に無ければ一度更新してから解決する。
    func open(event: StopEvent) {
        guard sidebarSessionIDs.contains(event.sessionID) else { return }
        Task {
            if let window = window(id: event.windowKey) {
                open(window: window)
                return
            }
            await refresh()
            if let window = window(id: event.windowKey) {
                open(window: window)
            }
        }
    }

    /// 新規sessionの開始フォルダを選ぶPickerを表示する。同時に複数のPickerは開かない。
    /// 作成先はローカル tmux (リモート host での新規作成は対象外)。
    func presentNewSessionPicker() {
        guard !NSApp.windows.contains(where: { $0 is NSOpenPanel }) else { return }
        let panel = NSOpenPanel()
        panel.title = "新規tmux session"
        panel.message = "sessionを開始するフォルダを選択してください"
        panel.prompt = "作成"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let directory = panel.url else { return }
            Task { @MainActor in
                self?.createSession(directory: directory)
            }
        }
    }

    /// ユーザーの明示操作ごとに新しいtmux sessionを作るため、意図的に非冪等。
    /// TmuxClient側で既存名を避け、作成済みsessionを上書きしない。
    private func createSession(directory: URL) {
        let client = self.client
        Task.detached(priority: .userInitiated) {
            do {
                let sessionName = try client.createSession(directory: directory)
                await self.refresh()
                await MainActor.run {
                    let sessionID = TmuxID.make(hostID: TmuxHost.local.id, element: sessionName)
                    self.addSessionToSidebar(sessionID)
                    self.selectSession(id: sessionID, expand: true)
                }
            } catch {
                await MainActor.run { self.lastError = "\(error)" }
            }
        }
    }

    /// session 配下の未読数合計。session 行のバッジに使う。
    func badgeCount(for session: TmuxSession) -> Int {
        session.windows.reduce(0) { $0 + (badges[$1.id] ?? 0) }
    }

    /// window を開く: session の terminal を表示し、tmux 側のカレント window を切り替え、未読をクリアする。
    func open(window: TmuxWindow) {
        selectedSessionID = window.sessionID
        selectedWindowID = window.id
        requestedWindowID = window.id
        setSessionExpanded(window.sessionID, isExpanded: true)
        clearBadge(windowID: window.id)
        let client = self.client(for: window.host)
        let rawWindowID = window.windowID
        Task.detached(priority: .userInitiated) {
            do {
                try client.selectWindow(id: rawWindowID)
                await self.refresh()
                await MainActor.run {
                    guard self.requestedWindowID == window.id else { return }
                    self.requestedWindowID = nil
                    self.synchronizeSelectedWindow()
                }
            } catch {
                await MainActor.run {
                    if self.requestedWindowID == window.id {
                        self.requestedWindowID = nil
                        self.synchronizeSelectedWindow()
                    }
                    self.lastError = "\(error)"
                }
            }
        }
    }

    /// コマンドパレットで候補を決定したときの遷移。session 行は選択、window 行は open (session 切替 + select-window + バッジクリア)。
    func activate(paletteItem: PaletteItem) {
        switch paletteItem.kind {
        case .session(let session): selectSession(id: session.id, expand: true)
        case .window(let window): open(window: window)
        }
    }

    /// 表示順で displayIndex 番目 (0 始まり) の session に切り替える (cmd+1..9)。
    func selectSession(atDisplayIndex displayIndex: Int) {
        if let sessionID = NoroshiNavigation.sessionID(in: displaySessionIDs, atDisplayIndex: displayIndex) {
            selectSession(id: sessionID, expand: true)
        }
    }

    /// 表示順で offset (次: +1 / 前: -1) 隣の session に循環で切り替える (cmd+shift+j/k)。host をまたいでも同じ操作で切り替わる。
    func selectAdjacentSession(_ offset: Int) {
        if let sessionID = NoroshiNavigation.adjacentSessionID(in: displaySessionIDs, from: selectedSessionID, offset: offset) {
            selectSession(id: sessionID, expand: true)
        }
    }

    /// 表示中 session のカレント window を次 (+1) / 前 (-1) に移す (cmd+shift+] / cmd+shift+[)。
    /// 移動後、新しいアクティブ window のバッジをクリアして一覧を更新する。
    func moveWindow(_ offset: Int) {
        guard let session = selectedSession else { return }
        setSessionExpanded(session.id, isExpanded: true)
        let client = self.client(for: session.host)
        let sessionName = session.name
        let hostID = session.host.id
        Task.detached(priority: .userInitiated) {
            do {
                if offset >= 0 {
                    try client.nextWindow(session: sessionName)
                } else {
                    try client.previousWindow(session: sessionName)
                }
                let windowID = TmuxID.make(hostID: hostID, element: try client.activeWindowID(session: sessionName))
                await MainActor.run {
                    self.selectedWindowID = windowID
                    self.clearBadge(windowID: windowID)
                }
                await self.refresh()
            } catch {
                await MainActor.run { self.lastError = "\(error)" }
            }
        }
    }

    /// 表示中 session のカレント window 内で、アクティブ pane を次 (+1) / 前 (-1) に移す (cmd+] / cmd+[)。
    func movePane(_ offset: Int) {
        guard let session = selectedSession else { return }
        let client = self.client(for: session.host)
        let sessionName = session.name
        Task.detached(priority: .userInitiated) {
            do {
                try client.selectPane(session: sessionName, offset: offset)
            } catch {
                await MainActor.run { self.lastError = "\(error)" }
            }
        }
    }

    /// 最も新しく受信しかつ未読が残っている window へジャンプする (cmd+shift+n)。
    /// 該当 window が現在の一覧に存在しない場合は何もしない。
    func openLatestNotified() {
        guard let windowID = NoroshiNavigation.latestUnreadWindowID(history: notifications, badges: badges),
              let window = displaySessions.flatMap(\.windows).first(where: { $0.id == windowID }) else { return }
        open(window: window)
    }

    /// 指定 window の未読をクリアする。
    func clearBadge(windowID: String) {
        badges[windowID] = nil
        updateDockBadge()
    }

    /// Cmd 長押しガイドのため修飾キーの変化の監視を開始する。多重登録しない (冪等)。
    func startShortcutGuideMonitoring() {
        guard modifierFlagsMonitor == nil else { return }
        modifierFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleModifierFlagsChanged(event.modifierFlags)
            return event
        }
        // cmd を押したままアプリを離れる (cmd+tab 等) と離しイベントを受け取れないため、非アクティブ化で必ず閉じる。
        NotificationCenter.default.addObserver(
            forName: NSApplication.willResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleModifierFlagsChanged([]) }
        }
    }

    /// 修飾キーの変化からガイドの表示/非表示を決める。cmd 単独が holdDuration 続いたら表示し、崩れたら閉じる。
    func handleModifierFlagsChanged(_ flags: NSEvent.ModifierFlags) {
        if ShortcutGuide.isCommandOnly(flags) {
            guard shortcutGuideDelayTask == nil, !isShortcutGuidePresented else { return }
            shortcutGuideDelayTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(ShortcutGuide.holdDuration))
                guard let self, !Task.isCancelled else { return }
                self.shortcutGuideDelayTask = nil
                // 待機中に flagsChanged を取りこぼしても (cmd+tab でのアプリ切替等) 誤表示しないよう、
                // 表示直前にも実際のキー状態を確かめる。
                guard ShortcutGuide.isCommandOnly(self.currentModifierFlags()) else { return }
                self.isShortcutGuidePresented = true
            }
        } else {
            shortcutGuideDelayTask?.cancel()
            shortcutGuideDelayTask = nil
            isShortcutGuidePresented = false
        }
    }

    /// 追加済み session ID をメモリと UserDefaults へ同時に反映する。
    private func saveSidebarSessionIDs(_ sessionIDs: [String]) {
        sidebarSessionIDs = sessionIDs
        defaults.set(sessionIDs, forKey: Self.sidebarSessionNamesDefaultsKey)
    }

    /// 現在選択中 session の active window を、サイドバーの選択表示へ同期する。
    private func synchronizeSelectedWindow() {
        selectedWindowID = selectedSession?.windows.first(where: \.isActive)?.id
    }

    /// Dock アイコンのバッジに未読合計を反映する。0 なら消す。
    private func updateDockBadge() {
        let total = badges.values.reduce(0, +)
        NSApp.dockTile.badgeLabel = total > 0 ? String(total) : ""
    }
}
