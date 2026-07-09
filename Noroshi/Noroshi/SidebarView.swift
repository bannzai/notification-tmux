import SwiftUI

/// 通知センターを兼ねるサイドバー。session(workspace) ごとに window を列挙し、未読バッジを数字で表示する。
/// session はドラッグ&ドロップで並べ替えられ、順序は AppState (UserDefaults) に永続化される。
struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    /// 折りたたみ中の session 名。未収録 = 展開扱いで、既定はすべて展開し従来どおり window を常時表示する。
    @State private var collapsedSessionNames: Set<String> = []

    /// フィルタ (テキスト or 通知) が有効かどうか。有効時は一致 window が隠れないよう DisclosureGroup を強制展開する。
    private var isFiltering: Bool {
        !appState.sidebarQuery.trimmingCharacters(in: .whitespaces).isEmpty || appState.showsNotifiedOnly
    }

    var body: some View {
        List {
            if isFiltering && appState.filteredDisplaySessions.isEmpty {
                Text("一致なし")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // session を Section ではなく単一 ForEach の行 (DisclosureGroup) にすることで .onMove が効く。
            // .onMove は 1 つの ForEach データソース内の行入れ替えのみ対応し、Section 間の移動はできないため。
            ForEach(appState.filteredDisplaySessions) { session in
                DisclosureGroup(isExpanded: expansionBinding(for: session.name)) {
                    ForEach(session.windows) { window in
                        WindowRow(
                            window: window,
                            badge: appState.badges[window.id] ?? 0,
                            isSelected: window.isActive && session.name == appState.selectedSessionName
                        ) {
                            appState.open(window: window)
                        }
                    }
                } label: {
                    SessionHeader(
                        session: session,
                        badge: appState.badgeCount(for: session),
                        isSelected: session.name == appState.selectedSessionName
                    ) {
                        appState.selectedSessionName = session.name
                    }
                }
            }
            // フィルタ中は表示 index と全体順 (displaySessionNames) がずれ保存順が壊れるため、並べ替えを無効化する。
            .onMove(perform: isFiltering ? nil : { source, destination in
                appState.moveSessions(fromOffsets: source, toOffset: destination)
            })
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let error = appState.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                filterBar
            }
        }
    }

    /// Xcode のファイルナビゲータ風のフィルタバー。虫眼鏡 + 入力欄 + クリアボタン + 通知フィルタトグル。
    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("フィルタ", text: $appState.sidebarQuery)
                .textFieldStyle(.plain)
                .font(.caption)
            if !appState.sidebarQuery.isEmpty {
                Button {
                    appState.sidebarQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            Button {
                appState.showsNotifiedOnly.toggle()
            } label: {
                Image(systemName: "bell.badge")
                    .foregroundStyle(appState.showsNotifiedOnly ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help("通知が来ている window だけ表示")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// session の展開状態への Binding。フィルタ中は一致 window を隠さないよう常に展開扱いにする。
    /// 非フィルタ時は collapsedSessionNames に無ければ展開扱い。
    private func expansionBinding(for sessionName: String) -> Binding<Bool> {
        Binding(
            get: { isFiltering || !collapsedSessionNames.contains(sessionName) },
            set: { isExpanded in
                if isExpanded {
                    collapsedSessionNames.remove(sessionName)
                } else {
                    collapsedSessionNames.insert(sessionName)
                }
            }
        )
    }
}

/// session 行 (DisclosureGroup のラベル)。クリックでその session の terminal を表示する。
struct SessionHeader: View {
    /// 表示する session。
    let session: TmuxSession
    /// session 配下の未読数合計。
    let badge: Int
    /// terminal 表示中の session かどうか。選択中はアクセントカラーで強調する。
    let isSelected: Bool
    /// クリック時の動作。
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(session.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? Color.accentColor : .primary)
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
    /// 選択中 session の tmux アクティブ window (= いま表示中の window) かどうか。アクセント背景で強調する。
    let isSelected: Bool
    /// クリック時の動作。
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // tmux 上のアクティブ window は緑丸ではなく index の着色で控えめに示す (通知バッジとの誤認を避ける)。
                Text(String(window.index))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(window.isActive ? Color.accentColor : .secondary)
                Text(window.name)
                    .lineLimit(1)
                    .fontWeight(isSelected ? .semibold : .regular)
                Spacer()
                BadgeLabel(count: badge)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 6)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 未読数の赤い丸数字バッジ。0 のときは何も表示しない。
/// 1 桁は真円 (幅 = 高さ)、2 桁以上は横に伸びる Capsule になる (min 幅 = 高さ 18)。
struct BadgeLabel: View {
    /// 表示する未読数。
    let count: Int

    var body: some View {
        if count > 0 {
            Text(String(count))
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(.red))
        }
    }
}
