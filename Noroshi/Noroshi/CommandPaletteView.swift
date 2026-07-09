import AppKit
import SwiftTerm
import SwiftUI

// SwiftTerm も Color 型を公開しており SwiftUI.Color と衝突するため、本ファイル内の Color を SwiftUI 側に固定する。
private typealias Color = SwiftUI.Color

/// コマンドパレット (cmd+P) に並ぶ 1 候補。session 行または window 行。
struct PaletteItem: Identifiable, Equatable {
    /// 候補の種別。表示・遷移先の分岐に使う。値として元オブジェクトを保持し、表示文字列は算出する。
    enum Kind: Equatable {
        /// session 行。値は session 名。
        case session(name: String)
        /// window 行。値は対象 window。
        case window(TmuxWindow)
    }

    /// 候補の種別と元データ。
    let kind: Kind
    /// 未読バッジ数 (session 行は配下 window の合計、window 行は自身の未読数)。
    let badge: Int

    /// 一覧内で一意な識別子。session 行は session 名、window 行は window_id (@n) で衝突しない。
    var id: String {
        switch kind {
        case .session(let name): return name
        case .window(let window): return window.id
        }
    }

    /// fuzzy マッチ対象の文字列。session 行は session 名、window 行は "session名 window名" で
    /// session 名でも window 名でも絞り込めるようにする。
    var matchText: String {
        switch kind {
        case .session(let name): return name
        case .window(let window): return "\(window.sessionName) \(window.name)"
        }
    }
}

/// コマンドパレットの絞り込み・スコアリングの純粋ロジック。UI・実 tmux に依存しないためユニットテスト可能。
enum PaletteSearch {
    /// query が candidate の (大文字小文字無視) サブシーケンスならスコアを返す。一致しなければ nil。
    /// スコアは高いほど良い: 連続一致・先頭一致・単語境界の直後を優遇する簡素な加点方式。
    /// query が空なら常に 0 (空は任意文字列のサブシーケンス)。
    static func score(query: String, candidate: String) -> Int? {
        let queryChars = Array(query.lowercased())
        guard !queryChars.isEmpty else { return 0 }
        let candidateChars = Array(candidate.lowercased())
        var score = 0
        var queryIndex = 0
        var previousMatchIndex = -2
        for (candidateIndex, character) in candidateChars.enumerated() {
            guard queryIndex < queryChars.count, character == queryChars[queryIndex] else { continue }
            score += 1
            if candidateIndex == 0 {
                score += 5
            } else if isBoundary(candidateChars[candidateIndex - 1]) {
                score += 3
            }
            if candidateIndex == previousMatchIndex + 1 {
                score += 3
            }
            previousMatchIndex = candidateIndex
            queryIndex += 1
        }
        return queryIndex == queryChars.count ? score : nil
    }

    /// query が空 (空白のみ含む) なら items を表示順のまま返し、非空ならサブシーケンス一致する候補だけを
    /// スコア降順で返す。同点は元の並び (表示順) を保つ安定な結果にする。
    static func filter(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        return items.enumerated().compactMap { order, item -> (item: PaletteItem, score: Int, order: Int)? in
            guard let score = score(query: trimmed, candidate: item.matchText) else { return nil }
            return (item, score, order)
        }
        .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        .map(\.item)
    }

    /// 単語境界とみなす文字。直後の一致に境界ボーナスを与える。
    private static func isBoundary(_ character: Character) -> Bool {
        character == " " || character == "/" || character == "-" || character == "_" || character == "."
    }
}

/// cmd+P で開く VSCode Quick Open 風のコマンドパレット。ターミナルの上に重なる上部中央のフローティングパネル。
/// 検索フィールド + 絞り込み結果リストを持ち、↑↓ で選択移動・Enter で決定・Esc/背景タップで閉じる。
struct CommandPaletteView: View {
    @EnvironmentObject var appState: AppState
    /// 検索クエリ。
    @State private var query = ""
    /// results 内で選択中の行 index。クエリ変更時に 0 へ戻す。
    @State private var selectedIndex = 0
    /// 検索フィールドのフォーカス。表示時に true にして terminal から奪う。
    @FocusState private var isSearchFocused: Bool

    /// クエリで絞り込んだ表示候補。
    private var results: [PaletteItem] {
        PaletteSearch.filter(appState.paletteItems, query: query)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.12)
                .ignoresSafeArea()
                .onTapGesture { close() }
            panel
                .frame(maxWidth: 560)
                .padding(.top, 64)
        }
        .onDisappear { returnFocusToTerminal() }
    }

    /// 検索フィールドと結果リストからなるフローティングパネル。
    private var panel: some View {
        VStack(spacing: 0) {
            TextField("session / window を検索", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($isSearchFocused)
                .onSubmit { activateSelection() }
            Divider()
            resultList
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(nsColor: .separatorColor)))
        .shadow(radius: 24, y: 8)
        .onKeyPress(.upArrow) { moveSelection(-1); return .handled }
        .onKeyPress(.downArrow) { moveSelection(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onChange(of: query) { selectedIndex = 0 }
        // onAppear 内で同期的に FocusState を立てると反映されないことがあるため次の runloop に回す。
        .onAppear { DispatchQueue.main.async { isSearchFocused = true } }
    }

    /// 絞り込み結果のスクロール可能なリスト。選択行が常に見えるよう追従スクロールする。
    @ViewBuilder
    private var resultList: some View {
        if results.isEmpty {
            Text("該当なし")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                            PaletteRow(item: item, isSelected: index == selectedIndex)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = index
                                    activateSelection()
                                }
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 320)
                .onChange(of: selectedIndex) {
                    if results.indices.contains(selectedIndex) {
                        proxy.scrollTo(results[selectedIndex].id, anchor: .center)
                    }
                }
            }
        }
    }

    /// 選択を offset 分動かす (範囲内にクランプ)。
    private func moveSelection(_ offset: Int) {
        guard !results.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + offset), results.count - 1)
    }

    /// 選択中の候補を決定し、パレットを閉じる。
    private func activateSelection() {
        guard results.indices.contains(selectedIndex) else { return }
        appState.activate(paletteItem: results[selectedIndex])
        close()
    }

    /// パレットを閉じる。terminal へのフォーカス復帰は onDisappear に集約する。
    private func close() {
        appState.isPalettePresented = false
    }

    /// 表示中 terminal を firstResponder に戻す。閉じ方 (Enter/Esc/cmd+P/背景タップ) に依らず onDisappear から呼ぶ。
    /// TerminalHostView の makeFirstResponder は新規 attach 時のみ発火するため、閉じただけでは terminal に戻らない。
    private func returnFocusToTerminal() {
        isSearchFocused = false
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
                  let terminal = firstTerminalView(in: window.contentView) else { return }
            window.makeFirstResponder(terminal)
        }
    }

    /// view 階層から最初の terminal view を探す。無ければ nil。
    private func firstTerminalView(in view: NSView?) -> LocalProcessTerminalView? {
        guard let view else { return nil }
        if let terminal = view as? LocalProcessTerminalView { return terminal }
        for subview in view.subviews {
            if let found = firstTerminalView(in: subview) { return found }
        }
        return nil
    }
}

/// コマンドパレットの 1 行。session 行か window 行かで表示を変え、選択中はアクセント背景で強調する。
struct PaletteRow: View {
    /// 表示する候補。
    let item: PaletteItem
    /// 選択中の行かどうか。
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .frame(width: 16)
            content
            Spacer()
            BadgeLabel(count: item.badge)
        }
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? Color.white : .primary)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor)
            }
        }
        .contentShape(Rectangle())
    }

    /// session 行 / window 行の主表示。
    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .session(let name):
            Text(name).fontWeight(.medium)
        case .window(let window):
            HStack(spacing: 4) {
                Text(window.sessionName).foregroundStyle(secondaryStyle)
                Text("›").foregroundStyle(secondaryStyle)
                Text(window.name)
                Text("\(window.index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(secondaryStyle)
            }
        }
    }

    /// 行アイコン。session は terminal、window は macwindow。
    private var iconName: String {
        switch item.kind {
        case .session: return "terminal"
        case .window: return "macwindow"
        }
    }

    /// 副次テキストの配色。選択中は白の淡色、非選択は secondary。
    private var secondaryStyle: Color {
        isSelected ? Color.white.opacity(0.75) : Color.secondary
    }
}
