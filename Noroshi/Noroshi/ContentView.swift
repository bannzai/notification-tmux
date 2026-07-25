import SwiftUI

/// ルート画面。左に通知センター兼サイドバー、右に選択中 session の terminal (タブ付き)。
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView(columnVisibility: $appState.sidebarVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                // タブ 1 枚の間は従来と同じ見た目を保つため、2 枚以上の時だけタブバーを出す (issue #40)。
                if appState.tabs.count > 1 {
                    TerminalTabBar()
                    Divider()
                }
                detailContent
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

    /// アクティブタブの中身。session 選択済みなら terminal、未選択・消滅時は案内を表示する。
    @ViewBuilder
    private var detailContent: some View {
        if let session = appState.selectedSession {
            TerminalHostView(host: session.host, sessionName: session.name, takesFocus: !appState.isSidebarFocused)
        } else if !appState.sessions.isEmpty {
            ContentUnavailableView(
                "session を選択してください",
                systemImage: "sidebar.left",
                description: Text("サイドバーの session を選ぶか、下部の＋で表示する tmux session を追加できます")
            )
        } else {
            ContentUnavailableView(
                "tmux session がありません",
                systemImage: "terminal",
                description: Text(appState.lastError ?? "tmux server が起動していないか、session が 0 個です")
            )
        }
    }
}

/// terminal 上部のタブバー (issue #40)。クリックで表示タブを切り替え、× で閉じる。
struct TerminalTabBar: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(appState.tabs.enumerated()), id: \.element.id) { index, tab in
                        TerminalTabItem(
                            title: title(for: tab),
                            hostName: hostName(for: tab),
                            isActive: index == appState.activeTabIndex,
                            select: { appState.selectTab(at: index) },
                            close: { appState.closeTab(at: index) }
                        )
                    }
                }
                .padding(.horizontal, 6)
            }
            Button {
                appState.addTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .padding(.trailing, 8)
            .help("新規タブ (⌘T)")
        }
        .padding(.vertical, 4)
        .background(.bar)
    }

    /// タブの表示名。session 名を使い、session が消えていても複合 ID から名前部分を出す。未選択は「新規タブ」。
    private func title(for tab: TerminalTab) -> String {
        guard let sessionID = tab.sessionID else { return "新規タブ" }
        return appState.session(id: sessionID)?.name ?? TmuxID.split(sessionID)?.element ?? sessionID
    }

    /// タブに添えるリモート host 名。ローカルは nil。
    private func hostName(for tab: TerminalTab) -> String? {
        guard let sessionID = tab.sessionID else { return nil }
        return appState.session(id: sessionID)?.host.displayName
            ?? TmuxID.split(sessionID).flatMap { TmuxHost(id: $0.hostID).displayName }
    }
}

/// タブバーの 1 タブ。アクティブタブは強調背景で示す。
struct TerminalTabItem: View {
    /// タブの表示名。
    let title: String
    /// リモート host 名 (ローカルは nil)。
    let hostName: String?
    /// 表示中のタブかどうか。
    let isActive: Bool
    /// タブクリック時の動作。
    let select: () -> Void
    /// × ボタンの動作。
    let close: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 4) {
                if let hostName {
                    Image(systemName: "network")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(hostName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .font(.caption)
                    .fontWeight(isActive ? .semibold : .regular)
                    .lineLimit(1)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("タブを閉じる (⌘W)")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                if isActive {
                    RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .selectedControlColor))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
