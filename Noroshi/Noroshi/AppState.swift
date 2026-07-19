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

/// アプリ全体の状態。session 一覧・未読バッジ・通知履歴・選択中 session を持つ。
/// ObservableObject を要求する SwiftUI のためクラスにしている。
@MainActor
final class AppState: ObservableObject {
    /// 通知履歴の保持上限。超えた分は古いものから捨てる (メモリのみ)。
    static let notificationHistoryLimit = 1000

    /// サイドバーへ追加した session 名と表示順を永続化する UserDefaults キー。
    /// 以前の全 session 自動追加用キーとは分け、初回は空のサイドバーから明示的に選べるようにする。
    private static let sidebarSessionNamesDefaultsKey = "noroshi.sidebarSessionNames"

    /// tmux から取得した session 一覧 (tmux の list-sessions 順)。表示順は displaySessions が解決する。
    @Published private(set) var sessions: [TmuxSession] = []
    /// ユーザーがサイドバーへ追加した session 名 (表示順)。UserDefaults に永続化する。
    /// 消えた session 名も残し、同名 session が再作成されたら再表示する。
    @Published private(set) var sidebarSessionNames: [String]
    /// windowID -> 未読数。Stop イベントで加算し、window を開いたらクリアする。
    @Published private(set) var badges: [String: Int] = [:]
    /// terminal を表示中の session 名。nil なら未選択。
    @Published private(set) var selectedSessionName: String?
    /// サイドバーで選択表示する window ID。クリック直後もポーリングを待たずに表示へ反映する。
    @Published private(set) var selectedWindowID: String?
    /// 折りたたみ中の session 名。未収録なら展開状態。
    @Published private(set) var collapsedSessionNames: Set<String> = []
    /// メニューから View へ配送する最新のフォーカス要求。
    @Published private(set) var focusRequest: AppFocusRequest?
    /// 直近の tmux コマンド失敗。エラーメッセージは加工せずそのまま表示する。
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
    /// サイドバー下部のフィルタ入力。session 名・window 名・index を部分一致で絞り込む。
    @Published var sidebarQuery: String = ""
    /// 通知フィルタ。true のとき未読 (badge > 0) の window だけをサイドバーに表示する。
    @Published var showsNotifiedOnly: Bool = false

    /// Stop イベントの受信履歴 (古い順)。「最新の通知へジャンプ」の発生順解決に使う。バッジ台帳とは独立。
    private var notifications: [NotificationRecord] = []
    /// tmux CLI ラッパ。
    private let client: TmuxClient
    /// サイドバーへ追加した session 名の保存先。
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

    // テストからダミー binaryPath の client を注入するために定義している
    init(client: TmuxClient = TmuxClient(), defaults: UserDefaults = .standard) {
        self.client = client
        self.defaults = defaults
        self.sidebarSessionNames = defaults.stringArray(forKey: Self.sidebarSessionNamesDefaultsKey) ?? []
    }

    /// サイドバー・cmd+数字・session 隣接移動が共通で使う表示順の session 名。
    /// 追加済みの保存順から、現存していて表示できる session 名だけを解決する。
    var displaySessionNames: [String] {
        NoroshiNavigation.displayedSessionNames(savedOrder: sidebarSessionNames, currentNames: sessions.map(\.name))
    }

    /// 表示順に並べ替えた session。サイドバーはこれを列挙する。
    var displaySessions: [TmuxSession] {
        let sessionsByName = Dictionary(uniqueKeysWithValues: sessions.map { ($0.name, $0) })
        return displaySessionNames.compactMap { sessionsByName[$0] }
    }

    /// picker に並べる未追加の現存 session。tmux の一覧順を保つ。
    var availableSessions: [TmuxSession] {
        let addedNames = Set(sidebarSessionNames)
        return sessions.filter { !addedNames.contains($0.name) }
    }

    /// サイドバーが実際に列挙する session。表示順の displaySessions にフィルタ (テキスト + 通知) を適用する。
    var filteredDisplaySessions: [TmuxSession] {
        SidebarFilter.filteredSessions(displaySessions, query: sidebarQuery, showsNotifiedOnly: showsNotifiedOnly, badges: badges)
    }

    /// コマンドパレットが列挙する候補。表示順の session ごとに、session 行 → 配下 window 行の順で平坦化する。
    var paletteItems: [PaletteItem] {
        displaySessions.flatMap { session in
            [PaletteItem(kind: .session(name: session.name), badge: badgeCount(for: session))]
                + session.windows.map { PaletteItem(kind: .window($0), badge: badges[$0.id] ?? 0) }
        }
    }

    /// サイドバーのドラッグ&ドロップによる session 並べ替えを表示順に反映し、永続化する。
    func moveSessions(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = displaySessionNames
        reordered.move(fromOffsets: source, toOffset: destination)
        // 消えていて現在は表示できない session 名を末尾に残し、復活時に選択状態を失わないようにする。
        let hiddenNames = sidebarSessionNames.filter { !reordered.contains($0) }
        saveSidebarSessionNames(reordered + hiddenNames)
    }

    /// picker で選んだ session をサイドバー末尾へ追加して保存する。追加済みなら何もしない (冪等)。
    func addSessionToSidebar(_ sessionName: String) {
        guard sessions.contains(where: { $0.name == sessionName }),
              !sidebarSessionNames.contains(sessionName) else { return }
        saveSidebarSessionNames(sidebarSessionNames + [sessionName])
        if selectedSessionName == nil {
            selectedSessionName = sessionName
            synchronizeSelectedWindow()
        }
    }

    /// session をサイドバーから外して保存する。未追加なら何もしない (冪等)。
    func removeSessionFromSidebar(_ sessionName: String) {
        let updated = sidebarSessionNames.filter { $0 != sessionName }
        guard updated != sidebarSessionNames else { return }
        if let removedSession = sessions.first(where: { $0.name == sessionName }) {
            let removedWindowIDs = Set(removedSession.windows.map(\.id))
            badges = badges.filter { !removedWindowIDs.contains($0.key) }
            updateDockBadge()
        }
        saveSidebarSessionNames(updated)
        if selectedSessionName == sessionName {
            selectedSessionName = displaySessionNames.first
            synchronizeSelectedWindow()
        }
    }

    /// session の折りたたみ状態を更新する。同じ状態への再設定は何もしない (冪等)。
    func setSessionExpanded(_ sessionName: String, isExpanded: Bool) {
        var updated = collapsedSessionNames
        if isExpanded {
            updated.remove(sessionName)
        } else {
            updated.insert(sessionName)
        }
        guard updated != collapsedSessionNames else { return }
        collapsedSessionNames = updated
    }

    /// session を選択し、必要ならサイドバー上でも展開する。
    func selectSession(named sessionName: String, expand: Bool = false) {
        guard displaySessionNames.contains(sessionName) else { return }
        selectedSessionName = sessionName
        if expand {
            setSessionExpanded(sessionName, isExpanded: true)
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

    /// 追加済み session 名をメモリと UserDefaults へ同時に反映する。
    private func saveSidebarSessionNames(_ names: [String]) {
        sidebarSessionNames = names
        defaults.set(names, forKey: Self.sidebarSessionNamesDefaultsKey)
    }

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

    /// tmux から一覧を取り直し、消えた window のバッジを掃除する。
    func refresh() async {
        let client = self.client
        let attachedClientPID = TerminalSessionManager.shared.attachedClientPID
        let managedSessionName = TerminalSessionManager.shared.managedSessionName
        do {
            let (fetched, attachedSessionName, windowGrid) = try await Task.detached(priority: .utility) {
                let sessions = try client.fetchSessions()
                let attachedSession = try attachedClientPID.flatMap { try client.attachedClient(pid: $0)?.sessionName }
                // 表示中 window の格子サイズ (フォントのフィット計算用; issue #36)。
                // 取得失敗は「フィットしない」へ倒すだけなので一覧の更新は継続する。
                let grid = (attachedSession ?? managedSessionName).flatMap { try? client.windowGrid(session: $0) }
                return (sessions, attachedSession, grid)
            }.value
            TerminalSessionManager.shared.updateWindowGrid(windowGrid)
            // 変化が無い時は再代入せず、2 秒ポーリング由来の不要な再描画 (terminal のフォーカス奪取等) を避ける。
            if fetched != sessions { sessions = fetched }
            lastError = nil
            let alive = Set(fetched.flatMap(\.windows).map(\.id))
            badges = badges.filter { alive.contains($0.key) }
            // 未選択、または選択中の session が消えた (kill 等) 場合は表示順の先頭にフォールバックする。
            // これが「消えた session への再 attach ループ」を止めるガード (単一 attach の TerminalSessionManager と対で機能する)。
            if NoroshiNavigation.shouldFollowAttachedSession(
                selected: selectedSessionName,
                managed: managedSessionName,
                attached: attachedSessionName,
                availableNames: Set(displaySessionNames)),
               let attachedSessionName
            {
                // prefix+L / choose-tree 等、tmux内で行われたsession切替をアプリ側の選択へ反映する。
                // manager側も先に同期し、View更新時に同じsessionへswitchし直して履歴を壊さないようにする。
                TerminalSessionManager.shared.synchronizeCurrentSessionName(attachedSessionName)
                selectedSessionName = attachedSessionName
            } else if selectedSessionName.map({ !displaySessionNames.contains($0) }) ?? true {
                selectedSessionName = displaySessionNames.first
            }
            if let requestedWindowID,
               fetched.lazy.flatMap(\.windows).contains(where: { $0.id == requestedWindowID })
            {
                selectedWindowID = requestedWindowID
            } else {
                requestedWindowID = nil
                synchronizeSelectedWindow()
            }
            updateDockBadge()
        } catch {
            // 同一エラーの再代入は objectWillChange を無駄に発火させるため値が変わった時だけ更新する。
            let message = "\(error)"
            if lastError != message { lastError = message }
            // server 停止 (no-server) 時は消えた session を残さず「session なし」に統一し、
            // 2 秒ごとに即失敗する attach の spawn を止める。一時的なエラーでは従来どおり sessions を保持する。
            guard (error as? TmuxClientError)?.isNoServer == true else { return }
            if !sessions.isEmpty { sessions = [] }
            if selectedSessionName != nil { selectedSessionName = nil }
            if selectedWindowID != nil { selectedWindowID = nil }
            requestedWindowID = nil
            if !badges.isEmpty { badges = [:] }
            updateDockBadge()
        }
    }

    /// 追加済み session の Stop hook イベントだけを適用し、該当 window の未読数を 1 増やして履歴に記録する。
    func apply(event: StopEvent) {
        guard sidebarSessionNames.contains(event.sessionName) else { return }
        badges[event.windowID, default: 0] += 1
        notifications.append(NotificationRecord(windowID: event.windowID, receivedAt: Date()))
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
        guard sidebarSessionNames.contains(event.sessionName) else { return }
        Task {
            if let window = window(id: event.windowID) {
                open(window: window)
                return
            }
            await refresh()
            if let window = window(id: event.windowID) {
                open(window: window)
            }
        }
    }

    /// 新規sessionの開始フォルダを選ぶPickerを表示する。同時に複数のPickerは開かない。
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
                    self.addSessionToSidebar(sessionName)
                    self.selectSession(named: sessionName, expand: true)
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
        selectedSessionName = window.sessionName
        selectedWindowID = window.id
        requestedWindowID = window.id
        setSessionExpanded(window.sessionName, isExpanded: true)
        clearBadge(windowID: window.id)
        let client = self.client
        Task.detached(priority: .userInitiated) {
            do {
                try client.selectWindow(id: window.id)
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
        case .session(let name): selectSession(named: name, expand: true)
        case .window(let window): open(window: window)
        }
    }

    /// 表示順で displayIndex 番目 (0 始まり) の session に切り替える (cmd+1..9)。
    func selectSession(atDisplayIndex displayIndex: Int) {
        if let name = NoroshiNavigation.sessionName(in: displaySessionNames, atDisplayIndex: displayIndex) {
            selectSession(named: name, expand: true)
        }
    }

    /// 表示順で offset (次: +1 / 前: -1) 隣の session に循環で切り替える (cmd+shift+j/k)。
    func selectAdjacentSession(_ offset: Int) {
        if let name = NoroshiNavigation.adjacentSessionName(in: displaySessionNames, from: selectedSessionName, offset: offset) {
            selectSession(named: name, expand: true)
        }
    }

    /// 表示中 session のカレント window を次 (+1) / 前 (-1) に移す (cmd+shift+] / cmd+shift+[)。
    /// 移動後、新しいアクティブ window のバッジをクリアして一覧を更新する。
    func moveWindow(_ offset: Int) {
        guard let session = selectedSessionName else { return }
        setSessionExpanded(session, isExpanded: true)
        let client = self.client
        Task.detached(priority: .userInitiated) {
            do {
                if offset >= 0 {
                    try client.nextWindow(session: session)
                } else {
                    try client.previousWindow(session: session)
                }
                let windowID = try client.activeWindowID(session: session)
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
        guard let session = selectedSessionName else { return }
        let client = self.client
        Task.detached(priority: .userInitiated) {
            do {
                try client.selectPane(session: session, offset: offset)
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

    /// 現在選択中 session の active window を、サイドバーの選択表示へ同期する。
    private func synchronizeSelectedWindow() {
        selectedWindowID = sessions
            .first(where: { $0.name == selectedSessionName })?
            .windows.first(where: \.isActive)?.id
    }

    /// Dock アイコンのバッジに未読合計を反映する。0 なら消す。
    private func updateDockBadge() {
        let total = badges.values.reduce(0, +)
        NSApp.dockTile.badgeLabel = total > 0 ? String(total) : ""
    }
}
