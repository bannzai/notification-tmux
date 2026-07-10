import SwiftUI

/// 通知センター付き tmux フロントエンド Noroshi。
/// Claude Code の Stop hook から `noroshi://stop?...` を受けてサイドバーにバッジを付ける。
@main
struct NoroshiApp: App {
    @StateObject private var appState = AppState()

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
                        guard let event = StopEvent(url: url) else { return }
                        appState.apply(event: event)
                    }
                    .task { appState.startPolling() }
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
            Button("コマンドパレット") { appState.isPalettePresented.toggle() }
                .keyboardShortcut("p", modifiers: .command)

            Divider()

            Button("次の window") { appState.moveWindow(1) }
                .keyboardShortcut("j", modifiers: .command)
            Button("前の window") { appState.moveWindow(-1) }
                .keyboardShortcut("k", modifiers: .command)

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
            Button("テーマを再読み込み") { TerminalSessionManager.shared.reloadTheme() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
    }
}
