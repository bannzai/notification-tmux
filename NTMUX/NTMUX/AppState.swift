import AppKit
import Combine
import SwiftUI

/// アプリ全体の状態。session 一覧・未読バッジ・選択中 session を持つ。
/// ObservableObject を要求する SwiftUI のためクラスにしている。
@MainActor
final class AppState: ObservableObject {
    /// tmux から取得した session 一覧。
    @Published private(set) var sessions: [TmuxSession] = []
    /// windowID -> 未読数。Stop イベントで加算し、window を開いたらクリアする。
    @Published private(set) var badges: [String: Int] = [:]
    /// terminal を表示中の session 名。nil なら未選択。
    @Published var selectedSessionName: String?
    /// 直近の tmux コマンド失敗。エラーメッセージは加工せずそのまま表示する。
    @Published var lastError: String?

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
            sessions = fetched
            lastError = nil
            let alive = Set(fetched.flatMap(\.windows).map(\.id))
            badges = badges.filter { alive.contains($0.key) }
            if selectedSessionName == nil { selectedSessionName = fetched.first?.name }
            updateDockBadge()
        } catch {
            lastError = "\(error)"
        }
    }

    /// Stop hook 由来のイベントを適用し、該当 window の未読数を 1 増やす。
    func apply(event: StopEvent) {
        badges[event.windowID, default: 0] += 1
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
