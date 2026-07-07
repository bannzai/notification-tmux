import SwiftUI

/// 通知センターを兼ねるサイドバー。session(workspace) ごとに window を列挙し、未読バッジを数字で表示する。
struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            ForEach(appState.sessions) { session in
                Section {
                    ForEach(session.windows) { window in
                        WindowRow(window: window, badge: appState.badges[window.id] ?? 0) {
                            appState.open(window: window)
                        }
                    }
                } header: {
                    SessionHeader(
                        session: session,
                        badge: appState.badgeCount(for: session),
                        isSelected: session.name == appState.selectedSessionName
                    ) {
                        appState.selectedSessionName = session.name
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let error = appState.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
    }
}

/// session 行。クリックでその session の terminal を表示する。
struct SessionHeader: View {
    /// 表示する session。
    let session: TmuxSession
    /// session 配下の未読数合計。
    let badge: Int
    /// terminal 表示中の session かどうか。
    let isSelected: Bool
    /// クリック時の動作。
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Text(session.name)
                    .fontWeight(isSelected ? .bold : .regular)
                Spacer()
                BadgeLabel(count: badge)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// window 行。クリックで該当 window までジャンプする (通知センターのタップに相当)。
struct WindowRow: View {
    /// 表示する window。
    let window: TmuxWindow
    /// この window の未読数。
    let badge: Int
    /// クリック時の動作。
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(String(window.index))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(window.name)
                    .lineLimit(1)
                if window.isActive {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
                Spacer()
                BadgeLabel(count: badge)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 未読数の赤バッジ。0 のときは何も表示しない。
struct BadgeLabel: View {
    /// 表示する未読数。
    let count: Int

    var body: some View {
        if count > 0 {
            Text(String(count))
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.red))
        }
    }
}
