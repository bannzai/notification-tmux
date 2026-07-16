import SwiftUI

/// ルート画面。左に通知センター兼サイドバー、右に選択中 session の terminal。
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            if let sessionName = appState.selectedSessionName {
                TerminalHostView(sessionName: sessionName, takesFocus: !appState.isSidebarFocused)
            } else if !appState.sessions.isEmpty {
                ContentUnavailableView(
                    "session を追加してください",
                    systemImage: "sidebar.left",
                    description: Text("サイドバー下部の＋から表示する tmux session を選べます")
                )
            } else {
                ContentUnavailableView(
                    "tmux session がありません",
                    systemImage: "terminal",
                    description: Text(appState.lastError ?? "tmux server が起動していないか、session が 0 個です")
                )
            }
        }
        .overlay {
            if appState.isPalettePresented {
                CommandPaletteView()
            }
        }
        .onChange(of: appState.focusRequest) { _, request in
            guard request?.target == .terminal else { return }
            TerminalSessionManager.shared.focusTerminal()
        }
    }
}
