import SwiftUI

/// 通知センター付き tmux フロントエンド。
/// Claude Code の Stop hook から `ntmux://stop?...` を受けてサイドバーにバッジを付ける。
@main
struct NTMUXApp: App {
    @StateObject private var appState = AppState()

    /// TEST_HOST としてユニットテストから起動されたかどうか。
    /// テスト実行時はポーリングや tmux attach でユーザーの tmux 環境 (クライアントサイズ等) に影響を与えないよう UI を起動しない。
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        // WindowGroup だと URL イベントごとに新規ウィンドウが開くため、単一ウィンドウの Window シーンにする
        Window("NTMUX", id: "main") {
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
    }
}
