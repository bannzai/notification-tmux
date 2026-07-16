import AppKit
import SwiftUI
import UserNotifications

/// 通知センター付き tmux フロントエンド Noroshi。
/// Claude Code の Stop hook から `noroshi://stop?...` を受けてサイドバーにバッジを付ける。
@main
struct NoroshiApp: App {
    @StateObject private var appState: AppState

    init() {
        let appState = AppState()
        _appState = StateObject(wrappedValue: appState)
        // 通知タップによるcold launchを取りこぼさないよう、Scene構築前にdelegateと遷移先を登録する。
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        NotificationService.shared.configure { [weak appState] event in
            appState?.open(event: event)
        }
    }

    /// TEST_HOST としてユニットテストから起動されたかどうか。
    /// テスト実行時はポーリングや tmux attach でユーザーの tmux 環境 (クライアントサイズ等) に影響を与えないよう UI を起動しない。
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        // WindowGroup だと URL イベントごとに新規ウィンドウが開くため、単一ウィンドウの Window シーンにする
        Window("Noroshi", id: "main") {
            if isRunningTests {
                Text("Running tests")
            } else {
                ContentView()
                    .environmentObject(appState)
                    .onOpenURL { url in
                        guard let event = StopEvent(url: url),
                              appState.sidebarSessionNames.contains(event.sessionName) else { return }
                        appState.apply(event: event)
                        NotificationService.shared.deliver(
                            event: event,
                            window: appState.window(id: event.windowID))
                    }
                    .task {
                        appState.startPolling()
                    }
                    .frame(minWidth: 900, minHeight: 560)
            }
        }
        .commands {
            NavigationCommands(appState: appState)
        }

        // Settings シーンを載せると SwiftUI が Cmd+, を自動でバインドする (issue #9)。
        Settings {
            SettingsView()
        }
    }
}

/// マウスなしで session/window/pane を移動するためのメニューコマンド (issue #3)。
/// メニューの keyEquivalent は first responder (SwiftTerm) の keyDown より先に処理されるため、
/// cmd 系のショートカットを SwiftTerm に食われずに横取りできる。
/// テーマ再読み込み等のメニューを後から足す場合は、この body に CommandMenu を追加する。
struct NavigationCommands: Commands {
    /// 移動操作の委譲先。
    @ObservedObject var appState: AppState

    var body: some Commands {
        // cmd+P は標準の Print と衝突するため、Print 系メニューを空で置き換えて cmd+P をコマンドパレットへ解放する。
        CommandGroup(replacing: .printItem) {}

        CommandMenu("移動") {
            Button("新規 session") { appState.presentNewSessionPicker() }
                .keyboardShortcut("n", modifiers: .command)

            Divider()

            Button("コマンドパレット") { appState.isPalettePresented.toggle() }
                .keyboardShortcut("p", modifiers: .command)

            Divider()

            Button("サイドバーにフォーカス") { appState.requestFocus(.sidebar) }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("ターミナルにフォーカス") { appState.requestFocus(.terminal) }
                .keyboardShortcut("t", modifiers: [.command, .option])

            Divider()

            Button("次の window") { appState.moveWindow(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("前の window") { appState.moveWindow(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])

            Divider()

            Button("次の session") { appState.selectAdjacentSession(1) }
                .keyboardShortcut("j", modifiers: [.command, .shift])
            Button("前の session") { appState.selectAdjacentSession(-1) }
                .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button("次の pane") { appState.movePane(1) }
                .keyboardShortcut("]", modifiers: .command)
            Button("前の pane") { appState.movePane(-1) }
                .keyboardShortcut("[", modifiers: .command)

            Divider()

            Button("最新の通知へジャンプ") { appState.openLatestNotified() }
                .keyboardShortcut("n", modifiers: [.command, .shift])

            Divider()

            ForEach(1...9, id: \.self) { number in
                Button("session \(number)") { appState.selectSession(atDisplayIndex: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }

        CommandMenu("表示") {
            Button(appState.sidebarVisibility == .detailOnly ? "サイドバーを表示" : "サイドバーを非表示") {
                appState.toggleSidebar()
            }
            .keyboardShortcut("b", modifiers: .command)

            Divider()

            Button("テーマを再読み込み") { TerminalSessionManager.shared.reloadTheme() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}

/// StopイベントをmacOS標準通知として配信し、通知タップを対象windowへの遷移へ戻す。
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    private var isConfigured = false
    private var isAuthorizationResolved = false
    private var isAuthorized = false
    private var pendingNotifications: [(event: StopEvent, window: TmuxWindow?)] = []
    private var onOpen: ((StopEvent) -> Void)?

    /// delegateと通知許可要求を一度だけ設定する。View再生成から複数回呼ばれても同じ状態に収束する。
    func configure(onOpen: @escaping (StopEvent) -> Void) {
        self.onOpen = onOpen
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        guard !isConfigured else { return }
        isConfigured = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                let service = NotificationService.shared
                service.isAuthorizationResolved = true
                service.isAuthorized = granted
                let pending = service.pendingNotifications
                service.pendingNotifications.removeAll()
                guard granted else { return }
                for item in pending {
                    service.schedule(event: item.event, window: item.window)
                }
            }
        }
    }

    /// Stopイベント1件につき通知1件を配信するため、イベント識別子にはUUIDを使う。
    /// 同じwindowから連続して通知されても各Stopを通知する必要があり、意図的に非冪等。
    func deliver(event: StopEvent, window: TmuxWindow?) {
        guard isAuthorizationResolved else {
            pendingNotifications.append((event, window))
            return
        }
        guard isAuthorized else { return }
        schedule(event: event, window: window)
    }

    private func schedule(event: StopEvent, window: TmuxWindow?) {
        let content = Self.makeContent(event: event, window: window)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// 通知の表示内容とタップ遷移用userInfoを組み立てる。副作用を持たずユニットテスト可能。
    static func makeContent(event: StopEvent, window: TmuxWindow?) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = event.sessionName
        if let window {
            content.body = "[\(window.index)] \(window.name) で処理が停止しました"
        } else {
            content.body = "処理が停止しました"
        }
        content.sound = .default
        content.userInfo = event.userInfo
        return content
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        guard let event = StopEvent(userInfo: response.notification.request.content.userInfo) else {
            completionHandler()
            return
        }
        Task { @MainActor in
            NSApp.activate(ignoringOtherApps: true)
            let mainWindow = NSApp.windows.first(where: { $0.title == "Noroshi" })
                ?? NSApp.windows.first(where: { !($0 is NSPanel) })
            mainWindow?.makeKeyAndOrderFront(nil)
            NotificationService.shared.onOpen?(event)
            completionHandler()
        }
    }
}
