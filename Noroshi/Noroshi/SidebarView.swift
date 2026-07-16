import AppKit
import SwiftUI

/// 通知センターを兼ねるサイドバー。session(workspace) ごとに window を列挙し、未読バッジを数字で表示する。
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
                DisclosureGroup(isExpanded: expansionBinding(for: session.name)) {
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
                        isSelected: session.name == appState.selectedSessionName
                    ) {
                        appState.selectSession(named: session.name)
                    }
                    .focused($focusedItem, equals: .session(session.name))
                    .onKeyPress(.leftArrow) {
                        appState.setSessionExpanded(session.name, isExpanded: false)
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        appState.setSessionExpanded(session.name, isExpanded: true)
                        return .handled
                    }
                    .contextMenu {
                        Button("サイドバーから削除", role: .destructive) {
                            appState.removeSessionFromSidebar(session.name)
                        }
                    }
                    // Cmd 長押し中に cmd+数字 の対象を示すガイド。フィルタ中も番号は全体の表示順 (cmd+1..9 の実際の遷移先) で振る。
                    .overlay(alignment: .trailing) {
                        if appState.isShortcutGuidePresented,
                           let guideNumber = appState.displaySessionNames.firstIndex(of: session.name)
                               .flatMap(ShortcutGuide.guideNumber(forDisplayIndex:))
                        {
                            ShortcutGuideBadge(number: guideNumber)
                                .padding(.trailing, 4)
                        }
                    }
                }
            }
            // フィルタ中は表示 index と全体順 (displaySessionNames) がずれ保存順が壊れるため、並べ替えを無効化する。
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
            focusedItem = appState.selectedSessionName.map(FocusedItem.session)
                ?? appState.displaySessionNames.first.map(FocusedItem.session)
        }
        // ↑↓ (moveSidebarSelection) や Tab で移ったフォーカスを選択へ反映し、
        // ハイライトと terminal 表示をフォーカス行へ追従させる (issue #30)。
        .onChange(of: focusedItem) { _, item in
            appState.isSidebarFocused = item != nil
            switch item {
            case .session(let sessionName):
                guard sessionName != appState.selectedSessionName else { return }
                appState.selectSession(named: sessionName)
            case .window(let windowID):
                guard windowID != appState.selectedWindowID,
                      let window = appState.window(id: windowID) else { return }
                appState.open(window: window)
            case .filter, nil:
                break
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
                    Text("追加できる session はありません")
                } else {
                    ForEach(appState.availableSessions) { session in
                        Button(session.name) {
                            appState.addSessionToSidebar(session.name)
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("session をサイドバーに追加")
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// ↑↓ でフォーカスを表示順の隣の行へ移す。選択への反映は focusedItem の onChange が行う。
    /// フィルタ入力中は入力操作を妨げないよう処理しない。
    private func moveSidebarSelection(_ offset: Int) -> KeyPress.Result {
        guard focusedItem != .filter else { return .ignored }
        switch NoroshiNavigation.adjacentSidebarRow(
            in: appState.filteredDisplaySessions,
            collapsedSessionNames: isFiltering ? [] : appState.collapsedSessionNames,
            from: currentSidebarRow,
            offset: offset)
        {
        case .session(let sessionName): focusedItem = .session(sessionName)
        case .window(let window): focusedItem = .window(window.id)
        case nil: return .ignored
        }
        return .handled
    }

    /// ↑↓ の起点となる行。フォーカス行を優先し、行以外にフォーカスがある場合は選択状態から解決する。
    private var currentSidebarRow: NoroshiNavigation.SidebarRow? {
        switch focusedItem {
        case .session(let sessionName):
            return .session(name: sessionName)
        case .window(let windowID):
            return appState.window(id: windowID).map(NoroshiNavigation.SidebarRow.window)
        case .filter, nil:
            if let window = appState.selectedWindowID.flatMap(appState.window(id:)) {
                return .window(window)
            }
            return appState.selectedSessionName.map { .session(name: $0) }
        }
    }

    /// session の展開状態への Binding。フィルタ中は一致 window を隠さないよう常に展開扱いにする。
    /// 非フィルタ時は collapsedSessionNames に無ければ展開扱い。
    private func expansionBinding(for sessionName: String) -> Binding<Bool> {
        Binding(
            get: { isFiltering || !appState.collapsedSessionNames.contains(sessionName) },
            set: { isExpanded in
                appState.setSessionExpanded(sessionName, isExpanded: isExpanded)
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
    /// terminal 表示中の session かどうか。選択中はmacOS標準の選択色で強調する。
    let isSelected: Bool
    /// クリック時の動作。
    let action: () -> Void

    private var selectedBackground: Color { Color(nsColor: .selectedContentBackgroundColor) }
    private var selectedForeground: Color { Color(nsColor: .selectedMenuItemTextColor) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .foregroundStyle(isSelected ? selectedForeground : .secondary)
                Text(session.name)
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
