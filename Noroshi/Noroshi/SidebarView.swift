import AppKit
import SwiftUI

/// 通知センターを兼ねるサイドバー。session(workspace) ごとに window を列挙し、未読バッジを数字で表示する。
/// リモート host (issue #38) の session も同じツリーに並び、host 名のラベルで区別する。
/// session はドラッグ&ドロップで並べ替えられ、順序は AppState (UserDefaults) に永続化される。
struct SidebarView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var focusedItem: FocusedItem?

    private enum FocusedItem: Hashable {
        case session(String)
        case window(String)
        case filter
    }

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
                DisclosureGroup(isExpanded: expansionBinding(for: session.id)) {
                    ForEach(session.windows) { window in
                        WindowRow(
                            window: window,
                            badge: appState.badges[window.id] ?? 0,
                            isSelected: window.id == appState.selectedWindowID
                        ) {
                            appState.open(window: window)
                        }
                        .focused($focusedItem, equals: .window(window.id))
                    }
                } label: {
                    SessionHeader(
                        session: session,
                        badge: appState.badgeCount(for: session),
                        isSelected: session.id == appState.selectedSessionID
                    ) {
                        appState.selectSession(id: session.id)
                    }
                    .focused($focusedItem, equals: .session(session.id))
                    .onKeyPress(.leftArrow) {
                        appState.setSessionExpanded(session.id, isExpanded: false)
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        appState.setSessionExpanded(session.id, isExpanded: true)
                        return .handled
                    }
                    .contextMenu {
                        Button("サイドバーから削除", role: .destructive) {
                            appState.removeSessionFromSidebar(session.id)
                        }
                    }
                    // Cmd 長押し中に cmd+数字 の対象を示すガイド。フィルタ中も番号は全体の表示順 (cmd+1..9 の実際の遷移先) で振る。
                    .overlay(alignment: .trailing) {
                        if appState.isShortcutGuidePresented,
                           let guideNumber = appState.displaySessionIDs.firstIndex(of: session.id)
                               .flatMap(ShortcutGuide.guideNumber(forDisplayIndex:))
                        {
                            ShortcutGuideBadge(number: guideNumber)
                                .padding(.trailing, 4)
                        }
                    }
                }
            }
            // フィルタ中は表示 index と全体順 (displaySessionIDs) がずれ保存順が壊れるため、並べ替えを無効化する。
            .onMove(perform: isFiltering ? nil : { source, destination in
                appState.moveSessions(fromOffsets: source, toOffset: destination)
            })
        }
        .listStyle(.sidebar)
        // List 標準のフォーカス移動は行 (Button) 間で機能しないため、↑↓ を自前で処理して
        // フォーカスと選択を表示順の隣の行へ動かす (issue #30)。
        .onKeyPress(.upArrow) { moveSidebarSelection(-1) }
        .onKeyPress(.downArrow) { moveSidebarSelection(1) }
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
        .onChange(of: appState.focusRequest) { _, request in
            guard request?.target == .sidebar else { return }
            focusedItem = appState.selectedSessionID.map(FocusedItem.session)
                ?? appState.displaySessionIDs.first.map(FocusedItem.session)
        }
        // フォーカスの所在だけを追跡し、フォーカス変化そのものでは選択 (= attach) を変えない (issue #57):
        // cmd+opt+s のサイドバーフォーカスや Full Keyboard Access の Tab 移動・システムのフォーカス再割り当てが
        // session 未選択のタブ (起動直後・新規タブ) に先頭 session を勝手に attach してしまうため。
        // ↑↓ ナビゲーションの選択追従 (issue #30) は moveSidebarSelection が明示的に行う。
        .onChange(of: focusedItem) { _, item in
            appState.isSidebarFocused = item != nil
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
                .focused($focusedItem, equals: .filter)
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
            Menu {
                if appState.availableSessions.isEmpty {
                    Text("非表示の session はありません")
                } else {
                    sessionPickerItems
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("非表示にした session をサイドバーへ戻す")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// 再表示 picker の候補行 (非表示中の session)。リモート host がある場合だけ host ごとの Section で区切る (issue #38)。
    @ViewBuilder
    private var sessionPickerItems: some View {
        let hosts = appState.availableSessions.map(\.host).reduce(into: [TmuxHost]()) { hosts, host in
            if !hosts.contains(host) { hosts.append(host) }
        }
        if hosts == [.local] {
            ForEach(appState.availableSessions) { session in
                Button(session.name) {
                    appState.addSessionToSidebar(session.id)
                }
            }
        } else {
            ForEach(hosts, id: \.self) { host in
                Section(host.displayName ?? "ローカル") {
                    ForEach(appState.availableSessions.filter { $0.host == host }) { session in
                        Button(session.name) {
                            appState.addSessionToSidebar(session.id)
                        }
                    }
                }
            }
        }
    }

    /// ↑↓ でフォーカスを表示順の隣の行へ移し、選択と terminal 表示を移動先へ追従させる (issue #30)。
    /// フォーカス変化そのものは選択を変えないため (issue #57)、ユーザーの明示操作であるここで選択する。
    /// フィルタ入力中は入力操作を妨げないよう処理しない。
    private func moveSidebarSelection(_ offset: Int) -> KeyPress.Result {
        guard focusedItem != .filter else { return .ignored }
        switch NoroshiNavigation.adjacentSidebarRow(
            in: appState.filteredDisplaySessions,
            collapsedSessionIDs: isFiltering ? [] : appState.collapsedSessionIDs,
            from: currentSidebarRow,
            offset: offset)
        {
        case .session(let sessionID):
            focusedItem = .session(sessionID)
            if sessionID != appState.selectedSessionID {
                appState.selectSession(id: sessionID)
            }
        case .window(let window):
            focusedItem = .window(window.id)
            if window.id != appState.selectedWindowID {
                appState.open(window: window)
            }
        case nil: return .ignored
        }
        return .handled
    }

    /// ↑↓ の起点となる行。フォーカス行を優先し、行以外にフォーカスがある場合は選択状態から解決する。
    private var currentSidebarRow: NoroshiNavigation.SidebarRow? {
        switch focusedItem {
        case .session(let sessionID):
            return .session(id: sessionID)
        case .window(let windowID):
            return appState.window(id: windowID).map(NoroshiNavigation.SidebarRow.window)
        case .filter, nil:
            if let window = appState.selectedWindowID.flatMap(appState.window(id:)) {
                return .window(window)
            }
            return appState.selectedSessionID.map { .session(id: $0) }
        }
    }

    /// session の展開状態への Binding。フィルタ中は一致 window を隠さないよう常に展開扱いにする。
    /// 非フィルタ時は collapsedSessionIDs に無ければ展開扱い。
    private func expansionBinding(for sessionID: String) -> Binding<Bool> {
        Binding(
            get: { isFiltering || !appState.collapsedSessionIDs.contains(sessionID) },
            set: { isExpanded in
                appState.setSessionExpanded(sessionID, isExpanded: isExpanded)
            }
        )
    }
}

/// session 行 (DisclosureGroup のラベル)。クリックでその session の terminal を表示する。
/// リモート session は host 名のラベルを添えて区別する。
struct SessionHeader: View {
    /// 表示する session。
    let session: TmuxSession
    /// session 配下の未読数合計。
    let badge: Int
    /// terminal 表示中の session かどうか。選択中はmacOS標準の選択色で強調する。
    let isSelected: Bool
    /// クリック時の動作。
    let action: () -> Void

    private var selectedBackground: Color { Color(nsColor: .selectedContentBackgroundColor) }
    private var selectedForeground: Color { Color(nsColor: .selectedMenuItemTextColor) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: session.host.displayName == nil ? "terminal" : "network")
                    .foregroundStyle(isSelected ? selectedForeground : .secondary)
                Text(session.name)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? selectedForeground : .primary)
                if let hostName = session.host.displayName {
                    Text(hostName)
                        .font(.caption2)
                        .lineLimit(1)
                        .foregroundStyle(isSelected ? selectedForeground.opacity(0.75) : .secondary)
                }
                Spacer()
                BadgeLabel(count: badge)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).fill(selectedBackground)
                }
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
    /// 選択中 session の tmux アクティブ window (= いま表示中の window) かどうか。標準の選択色で強調する。
    let isSelected: Bool
    /// クリック時の動作。
    let action: () -> Void

    private var selectedBackground: Color { Color(nsColor: .selectedContentBackgroundColor) }
    private var selectedForeground: Color { Color(nsColor: .selectedMenuItemTextColor) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // 選択中session以外のactive window番号は青くせず、実際に表示中のwindowだけ選択色にする。
                Text(String(window.index))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? selectedForeground : .secondary)
                Text(window.name)
                    .lineLimit(1)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? selectedForeground : .primary)
                Spacer()
                BadgeLabel(count: badge)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 6).fill(selectedBackground)
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
