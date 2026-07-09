import AppKit
import Combine
import SwiftUI

/// アプリ全体の状態。session 一覧・未読バッジ・通知履歴・選択中 session を持つ。
/// ObservableObject を要求する SwiftUI のためクラスにしている。
@MainActor
final class AppState: ObservableObject {
    /// 通知履歴の保持上限。超えた分は古いものから捨てる (メモリのみ)。
    static let notificationHistoryLimit = 1000

    /// tmux から取得した session 一覧。
    @Published private(set) var sessions: [TmuxSession] = []
    /// windowID -> 未読数。Stop イベントで加算し、window を開いたらクリアする。
    @Published private(set) var badges: [String: Int] = [:]
    /// terminal を表示中の session 名。nil なら未選択。
    @Published var selectedSessionName: String?
    /// 直近の tmux コマンド失敗。エラーメッセージは加工せずそのまま表示する。
    @Published var lastError: String?

    /// Stop イベントの受信履歴 (古い順)。「最新の通知へジャンプ」の発生順解決に使う。バッジ台帳とは独立。
    private var notifications: [NotificationRecord] = []
    /// tmux CLI ラッパ。
    private let client: TmuxClient
    /// 一覧ポーリングのループ。
    private var pollTask: Task<Void, Never>?

    // テストからダミー binaryPath の client を注入するために定義している
    init(client: TmuxClient = TmuxClient()) {
        self.client = client
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
        do {
            let fetched = try await Task.detached(priority: .utility) { try client.fetchSessions() }.value
            // 変化が無い時は再代入せず、2 秒ポーリング由来の不要な再描画 (terminal のフォーカス奪取等) を避ける。
            if fetched != sessions { sessions = fetched }
            lastError = nil
            let alive = Set(fetched.flatMap(\.windows).map(\.id))
            badges = badges.filter { alive.contains($0.key) }
            // 未選択、または選択中の session が消えた (kill 等) 場合は先頭にフォールバックする。
            // これが「消えた session への再 attach ループ」を止めるガード (単一 attach の TerminalSessionManager と対で機能する)。
            if selectedSessionName == nil || !fetched.contains(where: { $0.name == selectedSessionName }) {
                selectedSessionName = fetched.first?.name
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
            if !badges.isEmpty { badges = [:] }
            updateDockBadge()
        }
    }

    /// Stop hook 由来のイベントを適用し、該当 window の未読数を 1 増やして履歴に記録する。
    func apply(event: StopEvent) {
        badges[event.windowID, default: 0] += 1
        notifications.append(NotificationRecord(windowID: event.windowID, receivedAt: Date()))
        if notifications.count > Self.notificationHistoryLimit {
            notifications.removeFirst(notifications.count - Self.notificationHistoryLimit)
        }
        updateDockBadge()
    }

    /// session 配下の未読数合計。session 行のバッジに使う。
    func badgeCount(for session: TmuxSession) -> Int {
        session.windows.reduce(0) { $0 + (badges[$1.id] ?? 0) }
    }

    /// window を開く: session の terminal を表示し、tmux 側のカレント window を切り替え、未読をクリアする。
    func open(window: TmuxWindow) {
        selectedSessionName = window.sessionName
        clearBadge(windowID: window.id)
        let client = self.client
        Task.detached(priority: .userInitiated) {
            do {
                try client.selectWindow(id: window.id)
            } catch {
                await MainActor.run { self.lastError = "\(error)" }
            }
        }
    }

    /// 表示順で displayIndex 番目 (0 始まり) の session に切り替える (cmd+1..9)。
    func selectSession(atDisplayIndex displayIndex: Int) {
        if let name = NoroshiNavigation.sessionName(in: sessions.map(\.name), atDisplayIndex: displayIndex) {
            selectedSessionName = name
        }
    }

    /// 表示順で offset (次: +1 / 前: -1) 隣の session に循環で切り替える (cmd+shift+j/k)。
    func selectAdjacentSession(_ offset: Int) {
        if let name = NoroshiNavigation.adjacentSessionName(in: sessions.map(\.name), from: selectedSessionName, offset: offset) {
            selectedSessionName = name
        }
    }

    /// 表示中 session のカレント window を次 (+1) / 前 (-1) に移す (cmd+j/k)。
    /// 移動後、新しいアクティブ window のバッジをクリアして一覧を更新する。
    func moveWindow(_ offset: Int) {
        guard let session = selectedSessionName else { return }
        let client = self.client
        Task.detached(priority: .userInitiated) {
            do {
                if offset >= 0 {
                    try client.nextWindow(session: session)
                } else {
                    try client.previousWindow(session: session)
                }
                let windowID = try client.activeWindowID(session: session)
                await MainActor.run { self.clearBadge(windowID: windowID) }
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
              let window = sessions.flatMap(\.windows).first(where: { $0.id == windowID }) else { return }
        open(window: window)
    }

    /// 指定 window の未読をクリアする。
    func clearBadge(windowID: String) {
        badges[windowID] = nil
        updateDockBadge()
    }

    /// Dock アイコンのバッジに未読合計を反映する。0 なら消す。
    private func updateDockBadge() {
        let total = badges.values.reduce(0, +)
        NSApp.dockTile.badgeLabel = total > 0 ? String(total) : ""
    }
}
