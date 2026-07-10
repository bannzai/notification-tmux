import AppKit
import SwiftTerm
import SwiftUI

/// Ghostty の font-family / font-style を AppKit のフォントへ解決する。
/// 指定ファミリが利用できない場合も、style に対応する等幅システムフォントへフォールバックする。
enum TerminalFontResolver {
    static func resolve(family: String?, style: String?, size: CGFloat, base: NSFont) -> NSFont {
        if let family, !family.isEmpty {
            if let font = font(family: family, style: style, size: size) {
                return font
            }
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight(for: style) ?? .regular)
        }

        guard let weight = weight(for: style) else {
            return NSFont(descriptor: base.fontDescriptor, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    private static func font(family: String, style: String?, size: CGFloat) -> NSFont? {
        if let style, !style.isEmpty,
           let member = NSFontManager.shared.availableMembers(ofFontFamily: family)?.first(where: {
               guard $0.count > 1, let memberStyle = $0[1] as? String else { return false }
               return memberStyle.caseInsensitiveCompare(style) == .orderedSame
           }),
           let postScriptName = member.first as? String,
           let exact = NSFont(name: postScriptName, size: size)
        {
            return exact
        }

        let managerWeight = fontManagerWeight(for: style) ?? 5
        return NSFontManager.shared.font(withFamily: family, traits: [], weight: managerWeight, size: size)
    }

    private static func fontManagerWeight(for style: String?) -> Int? {
        switch style?.lowercased() {
        case "regular": return 5
        case "medium": return 6
        case "semibold", "demibold": return 8
        case "bold": return 9
        default: return nil
        }
    }

    private static func weight(for style: String?) -> NSFont.Weight? {
        switch style?.lowercased() {
        case "regular": return .regular
        case "medium": return .medium
        case "semibold", "demibold": return .semibold
        case "bold": return .bold
        default: return nil
        }
    }
}

/// tmux のようにマウスレポートを有効化した相手へ、SwiftTerm 1.13.0 が取りこぼす
/// ホイールスクロールと buttonEventTracking (DECSET 1002) のドラッグ motion を SGR レポートとして送出する
/// terminal view。SwiftTerm 本体 (checkouts) は改変不可で、かつ TerminalView の
/// scrollWheel / mouseDragged は `public`(非 `open`) override のため別モジュールから再 override できない。
/// そのため TerminalSessionManager 側の NSEvent local monitor から本 view の public メソッドを呼んで補う。
///
/// SwiftTerm 1.13.0 の取りこぼし箇所 (Mac/MacTerminalView.swift):
/// - scrollWheel はマウスモードを一切見ずに常にローカルスクロールバックを操作し、レポートを送らない。
///   tmux 側にホイールが届かず copy-mode スクロールが起きない。
/// - mouseDragged は `mouseMode.sendMotionEvent()` (anyEvent=1003 のみ true) が偽だと早期 return し、
///   buttonEventTracking (1002) のドラッグ motion を送らない。tmux の pane 境界ドラッグ (resize) が効かない。
final class MouseReportingTerminalView: LocalProcessTerminalView {
    /// 精密スクロール (トラックパッド) の端数を貯め、セル高ごとに 1 tick へ量子化するための累積値。
    private var scrollAccumulator: CGFloat = 0

    /// attach 先がマウスレポート (DECSET 1000/1002/1003) を要求している状態か。
    /// false のときはローカルスクロールバックへ委ねるべきで、ホイールレポートは送らない。
    var isMouseReportingActive: Bool {
        allowMouseReporting && getTerminal().mouseMode != .off
    }

    /// buttonEventTracking (1002) で、SwiftTerm が送らないドラッグ motion をこちらで補う必要がある状態か。
    var wantsDragMotionReport: Bool {
        allowMouseReporting && getTerminal().mouseMode == .buttonEventTracking
    }

    /// スクロールバックへ委ねる直前に累積端数を捨てる。次にレポートへ戻ったとき古い端数を持ち越さないため。
    func resetScrollAccumulator() {
        scrollAccumulator = 0
    }

    /// ホイールイベントを SGR マウスレポートとして送る。セル高ごとに 1 tick を送出する。
    func reportScroll(with event: NSEvent) {
        let cell = cellSize()
        // 行ベース (マウスホイール) は 1 delta ≒ 1 行、精密 (トラックパッド) は移動量 (pt) をセル高で割って行数化する。
        scrollAccumulator += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY * cell.height
        let ticks = Int(scrollAccumulator / cell.height)
        guard ticks != 0 else { return }
        scrollAccumulator -= CGFloat(ticks) * cell.height
        // xterm はホイールを button press として報告する (motion ではない)。上方向 = button4 (64), 下方向 = button5 (65)。
        let flags = getTerminal().encodeButton(
            button: ticks > 0 ? 4 : 5,
            release: false,
            shift: event.modifierFlags.contains(.shift),
            meta: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control))
        let hit = gridPosition(for: event, cell: cell)
        for _ in 0 ..< abs(ticks) {
            getTerminal().sendEvent(buttonFlags: flags, x: hit.col, y: hit.row, pixelX: 0, pixelY: 0)
        }
    }

    /// ドラッグ中の位置を SGR マウス motion レポートとして送る。pane 境界 resize などの button-motion 追従に使う。
    func reportDragMotion(with event: NSEvent) {
        let hit = gridPosition(for: event, cell: cellSize())
        getTerminal().sendMotion(
            buttonFlags: getTerminal().encodeButton(
                button: event.buttonNumber,
                release: false,
                shift: event.modifierFlags.contains(.shift),
                meta: event.modifierFlags.contains(.option),
                control: event.modifierFlags.contains(.control)),
            x: hit.col, y: hit.row, pixelX: 0, pixelY: 0)
    }

    /// 表示中フォントの 1 セル寸法 (pt)。getOptimalFrameSize() は width=cell*cols+scroller幅 / height=cell*rows を返すため逆算する。
    private func cellSize() -> CGSize {
        let optimal = getOptimalFrameSize()
        return CGSize(
            width: (optimal.width - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)) / CGFloat(getTerminal().cols),
            height: optimal.height / CGFloat(getTerminal().rows))
    }

    /// event の位置を可視画面の 0-based セル座標へ変換する。SwiftTerm の calculateMouseHit と同じ式。
    private func gridPosition(for event: NSEvent, cell: CGSize) -> (col: Int, row: Int) {
        let point = convert(event.locationInWindow, from: nil)
        return (
            col: min(max(0, Int(point.x / cell.width)), getTerminal().cols - 1),
            row: min(max(0, Int((frame.height - point.y) / cell.height)), getTerminal().rows - 1))
    }
}

/// 表示中の session だけを attach する単一 attach 方式の terminal 管理 (issue #6 案 A)。
/// 常時 attach client は最大 1 本。session 切替時に直前の view を terminate して破棄し、新しい session に attach する。
/// 非表示 view を生かし続けないことで、attach client / VT パース / スクロールバックの多重コストを避ける。
/// NSObject 継承は LocalProcessTerminalViewDelegate が要求するため。
@MainActor
final class TerminalSessionManager: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalSessionManager()

    /// 現在 attach 中の session 名。単一 attach なので最大 1。
    private var currentSessionName: String?
    /// 現在 attach 中の terminal view。
    private var currentView: MouseReportingTerminalView?
    /// Ghostty config 由来の配色。起動時に一度読み、メニュー「テーマを再読み込み」で更新する。config が無ければ nil。
    private var theme = GhosttyTheme.load()
    /// ホイール / ドラッグを横取りして tmux へマウスレポートを送るための local event monitor。生成後は最大 1 本。
    private var mouseMonitor: Any?

    /// session に attach した terminal view を返す。別 session が表示中なら、その view を破棄してから新規 attach する。
    /// 同じ session の再要求では既存 view をそのまま返す (再 attach しない)。
    func terminalView(for sessionName: String) -> LocalProcessTerminalView {
        if currentSessionName == sessionName, let view = currentView {
            return view
        }
        if let old = currentView {
            old.terminate()
        }
        let view = makeTerminalView(for: sessionName)
        currentView = view
        currentSessionName = sessionName
        return view
    }

    /// session に attach する terminal view を 1 つ生成する。
    /// terminal view の生成箇所はこの 1 メソッドに集約している (後工程のテーマ適用の差し込み点)。
    private func makeTerminalView(for sessionName: String) -> MouseReportingTerminalView {
        installMouseMonitorIfNeeded()
        let view = MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.processDelegate = self
        // `=` プレフィックスで session 名の完全一致を強制 (前方一致による誤 attach を防ぐ)
        view.startProcess(
            executable: TmuxClient.resolveBinaryPath(),
            args: TmuxClient.resolveBinaryPath().hasSuffix("env")
                ? ["tmux", "attach-session", "-t", "=\(sessionName)"]
                : ["attach-session", "-t", "=\(sessionName)"]
        )
        theme?.apply(to: view)
        applyFont(theme, to: view)
        return view
    }

    /// Ghostty/Noroshi config を再読み込みして、表示中の view (単一 attach なので最大 1) に配色とフォントを再適用する。
    /// メニュー「テーマを再読み込み」や設定ウィンドウの変更から呼ぶ。config 編集を再起動なしで反映するため。
    func reloadTheme() {
        theme = GhosttyTheme.load()
        if let view = currentView {
            theme?.apply(to: view)
            applyFont(theme, to: view)
        }
    }

    /// 解決済み設定の font-family / font-style / font-size を TerminalView.font に反映する。
    /// すべて nil (未指定) のときは SwiftTerm の既定フォントを尊重して何もしない。
    /// family が実在しなければ等幅システムフォントへフォールバックする。
    /// font setter は selection 解除・レイアウト再計算の副作用があるため、値が変わる時だけ代入する (docs/knowledge.md)。
    private func applyFont(_ theme: GhosttyTheme?, to view: TerminalView) {
        guard let theme, theme.fontFamily != nil || theme.fontStyle != nil || theme.fontSize != nil else { return }
        let base = view.font
        let size = theme.fontSize.map { CGFloat($0) } ?? base.pointSize
        let font = TerminalFontResolver.resolve(
            family: theme.fontFamily,
            style: theme.fontStyle,
            size: size,
            base: base)
        if view.font.fontName != font.fontName || view.font.pointSize != font.pointSize {
            view.font = font
        }
    }

    /// ホイール / 左ドラッグを横取りする local event monitor を 1 度だけ張る。生成済みなら何もしない (冪等)。
    /// SwiftTerm の scrollWheel / mouseDragged は別モジュールから再 override できないため、
    /// view へ配送される前段でイベントを掴んでマウスレポート送出とローカル処理の抑止を行う。
    private func installMouseMonitorIfNeeded() {
        guard mouseMonitor == nil else { return }
        // NSEvent は Sendable でないため、MainActor 境界は Bool (消費したか) だけを跨がせ、
        // event / nil の選択は境界の外で行う。monitor は常に main スレッドで発火するので assumeIsolated は安全。
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged]) { event in
            MainActor.assumeIsolated {
                TerminalSessionManager.shared.reportMouseEventIfHandled(event)
            } ? nil : event
        }
    }

    /// 表示中 terminal view の上で起きたホイール / 左ドラッグならマウスレポートを送り、消費した (true) を返す。
    /// 対象外なら false を返し、呼び出し側でイベントを既定処理へ通す。
    private func reportMouseEventIfHandled(_ event: NSEvent) -> Bool {
        guard let view = currentView,
              event.window === view.window,
              view.bounds.contains(view.convert(event.locationInWindow, from: nil))
        else { return false }

        switch event.type {
        case .scrollWheel:
            guard view.isMouseReportingActive else {
                view.resetScrollAccumulator()
                return false
            }
            view.reportScroll(with: event)
            return true
        case .leftMouseDragged:
            guard view.wantsDragMotionReport else { return false }
            view.reportDragMotion(with: event)
            return true
        default:
            return false
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// attach プロセスが予期せず終了した (session kill / detach) ときの後始末。
    /// 切替で明示的に terminate() した view はここに来ない: SwiftTerm 1.13.0 の
    /// LocalProcess.terminate() は childMonitor を cancel するため processTerminated を発火しない。
    /// よって source が現在の view のときだけ attach を手放せばよい。
    /// 再表示は AppState.refresh() の先頭フォールバックが選択を生存 session に移すことで安全に行われる (再 attach ループ防止)。
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if source === currentView {
            currentView = nil
            currentSessionName = nil
        }
    }
}

/// 選択中 session の terminal を表示する SwiftUI ラッパ。
/// session 切り替え時は単一 attach 方式に従い、直前の view を破棄して新しい session に attach する。
struct TerminalHostView: NSViewRepresentable {
    /// 表示する tmux session 名。
    let sessionName: String

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(on: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        install(on: container)
    }

    /// sessionName の terminal view をコンテナに取り付け、新規取り付け時だけフォーカスを当てる。
    private func install(on container: NSView) {
        let terminal = TerminalSessionManager.shared.terminalView(for: sessionName)
        // superview が変わっていない (ポーリング由来の再描画) 場合は取り付けもフォーカス移動もしない。
        // 毎回 makeFirstResponder するとサイドバー等からフォーカスを奪ってしまうため新規取り付け時のみに限定する。
        guard terminal.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        // updateNSView の同期処理中に firstResponder を変えると SwiftUI の更新と競合するため次の runloop に回す
        DispatchQueue.main.async {
            if let window = terminal.window, window.firstResponder !== terminal {
                window.makeFirstResponder(terminal)
            }
        }
    }
}
