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
    /// IME が変換中の未確定文字。SwiftTerm 1.13.0 では macOS 側の marked text 描画が未実装なためここで保持する。
    private var markedTextStorage: NSAttributedString?
    /// 未確定文字を terminal のキャレット位置に表示する overlay。
    private var markedTextOverlay: NSTextField?

    // MARK: - NSTextInputClient

    /// IME が確定文字を送る直前に未確定文字の overlay を片付ける。
    override func insertText(_ string: Any, replacementRange: NSRange) {
        clearMarkedText()
        super.insertText(string, replacementRange: replacementRange)
    }

    /// IME の未確定文字を更新し、terminal には送らずキャレット上に preview する。
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let attributed as NSAttributedString:
            markedTextStorage = attributed.length > 0 ? attributed : nil
        case let nsString as NSString:
            markedTextStorage = nsString.length > 0 ? NSAttributedString(string: nsString as String) : nil
        case let plain as String:
            markedTextStorage = plain.isEmpty ? nil : NSAttributedString(string: plain)
        default:
            markedTextStorage = nil
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        updateMarkedTextOverlay()
    }

    /// IME が変換を終了したら overlay を確実に外し、削除済み文字の残像を残さない。
    override func unmarkText() {
        clearMarkedText()
        super.unmarkText()
    }

    /// 選択範囲がないときも IME が入力位置を特定できるよう、現在の cursor 位置を返す。
    override func selectedRange() -> NSRange {
        let selection = super.selectedRange()
        guard selection.location == NSNotFound else { return selection }
        let terminal = getTerminal()
        return NSRange(location: terminal.buffer.y * terminal.cols + terminal.buffer.x, length: 0)
    }

    override func markedRange() -> NSRange {
        guard let markedTextStorage else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: markedTextStorage.length)
    }

    override func hasMarkedText() -> Bool {
        markedTextStorage != nil
    }

    override func attributedSubstring(
        forProposedRange range: NSRange,
        actualRange: NSRangePointer?
    ) -> NSAttributedString? {
        guard let markedTextStorage,
              range.location != NSNotFound,
              range.location < markedTextStorage.length
        else { return nil }
        let clampedRange = NSRange(
            location: range.location,
            length: min(range.length, markedTextStorage.length - range.location)
        )
        guard clampedRange.length > 0 else { return nil }
        actualRange?.pointee = clampedRange
        return markedTextStorage.attributedSubstring(from: clampedRange)
    }

    override func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        [.underlineStyle, .markedClauseSegment, .glyphInfo]
    }

    /// 未確定文字の内容と長さに合わせて overlay を更新する。空なら再描画のため view 階層から取り除く。
    private func updateMarkedTextOverlay() {
        guard let markedTextStorage, markedTextStorage.length > 0 else {
            markedTextOverlay?.removeFromSuperview()
            markedTextOverlay = nil
            return
        }

        let overlay: NSTextField
        if let markedTextOverlay {
            overlay = markedTextOverlay
        } else {
            overlay = NSTextField(labelWithString: "")
            overlay.isBezeled = false
            overlay.isEditable = false
            overlay.drawsBackground = true
            overlay.wantsLayer = true
            overlay.layer?.cornerRadius = 3
            addSubview(overlay, positioned: .above, relativeTo: nil)
            markedTextOverlay = overlay
        }

        overlay.backgroundColor = nativeBackgroundColor.withAlphaComponent(0.9)
        let displayString = NSMutableAttributedString(attributedString: markedTextStorage)
        displayString.addAttributes([
            .font: font,
            .foregroundColor: nativeForegroundColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ], range: NSRange(location: 0, length: displayString.length))
        overlay.attributedStringValue = displayString
        overlay.sizeToFit()
        overlay.frame.origin = caretFrame.origin
        if overlay.frame.maxX > bounds.maxX {
            overlay.frame.origin.x = max(0, bounds.maxX - overlay.frame.width)
        }
    }

    /// 呼び出しを重ねても同じ空状態に収束する後始末。
    private func clearMarkedText() {
        markedTextStorage = nil
        updateMarkedTextOverlay()
    }

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

    /// フルスクリーン切替やウィンドウリサイズで表示領域が変わったら、window 格子が収まるフォントへ再フィットする (issue #36)。
    /// setFrameSize は AppKit/SwiftUI のレイアウトパス中に呼ばれ、その最中の font 変更 (再 resize) は
    /// View 更新と競合してクラッシュし得るため、次の runloop へ合流させて実行する。
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        TerminalSessionManager.shared.scheduleRefitFont()
    }

    /// 表示中フォントの 1 セル寸法 (pt)。getOptimalFrameSize() は width=cell*cols+scroller幅 / height=cell*rows を返すため逆算する。
    /// リンククリック検出のため TerminalSessionManager (同一ファイル) から参照するので fileprivate。
    fileprivate func cellSize() -> CGSize {
        let optimal = getOptimalFrameSize()
        return CGSize(
            width: (optimal.width - NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)) / CGFloat(getTerminal().cols),
            height: optimal.height / CGFloat(getTerminal().rows))
    }

    /// event の位置を可視画面の 0-based セル座標へ変換する。SwiftTerm の calculateMouseHit と同じ式。
    /// リンククリック検出のため TerminalSessionManager (同一ファイル) から参照するので fileprivate。
    fileprivate func gridPosition(for event: NSEvent, cell: CGSize) -> (col: Int, row: Int) {
        let point = convert(event.locationInWindow, from: nil)
        return (
            col: min(max(0, Int(point.x / cell.width)), getTerminal().cols - 1),
            row: min(max(0, Int((frame.height - point.y) / cell.height)), getTerminal().rows - 1))
    }
}

/// 表示中の session だけを attach する単一 attach 方式の terminal 管理 (issue #6)。
/// 常時 attach client は最大 1 本。session 切替時は同じ client を `switch-client` し、tmux の直前session履歴を保つ。
/// 非表示 view を増やさないことで、attach client / VT パース / スクロールバックの多重コストを避ける。
/// NSObject 継承は LocalProcessTerminalViewDelegate が要求するため。
@MainActor
final class TerminalSessionManager: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalSessionManager()

    /// 現在 attach 中の session 名。単一 attach なので最大 1。
    private var currentSessionName: String?
    /// 現在 attach 中の terminal view。
    private var currentView: MouseReportingTerminalView?
    /// attach済みclientの照会とsession切替に使うtmux CLIラッパ。
    private let tmuxClient = TmuxClient()
    /// Ghostty config 由来の配色。起動時に一度読み、メニュー「テーマを再読み込み」で更新する。config が無ければ nil。
    private var theme = GhosttyTheme.load()
    /// attach 中 session のカレント window の格子サイズ。フォントのフィット計算 (issue #36) に使う。不明 (取得失敗) なら縮小しない。
    private var windowGrid: TmuxWindowGrid?
    /// フォント未指定時の基準となる SwiftTerm 既定フォント。フィット縮小後の view.font を基準に
    /// 再解決すると縮小が累積するため、view 生成直後の未加工の値を保持する。
    private var baseFont: NSFont?
    /// scheduleRefitFont の合流フラグ。true の間は再フィットが予約済みで、追加の予約は行わない。
    private var pendingRefit = false
    /// ホイール / ドラッグを横取りして tmux へマウスレポートを送るための local event monitor。生成後は最大 1 本。
    private var mouseMonitor: Any?
    /// 左ボタン押下時のセル座標。押下と同一セルで離した場合だけクリックとみなしリンクを開くための記録。
    private var mouseDownCell: (col: Int, row: Int)?

    /// session に attach した terminal view を返す。別sessionなら同じclientをswitchして履歴を保持する。
    /// client特定前などswitchできない場合だけ、従来どおりviewを作り直して表示自体は継続する。
    func terminalView(for sessionName: String) -> LocalProcessTerminalView {
        if currentSessionName == sessionName, let view = currentView {
            return view
        }
        if let view = currentView {
            do {
                try tmuxClient.switchClient(pid: view.process.shellPid, to: sessionName)
                currentSessionName = sessionName
                fetchWindowGrid(for: sessionName)
                return view
            } catch {
                view.terminate()
                currentView = nil
                currentSessionName = nil
            }
        }
        let view = makeTerminalView(for: sessionName)
        currentView = view
        currentSessionName = sessionName
        return view
    }

    /// SwiftTermが起動したtmux clientのPID。まだattachしていなければnil。
    var attachedClientPID: Int32? {
        guard let view = currentView, view.process.running else { return nil }
        return view.process.shellPid
    }

    /// managerが最後に反映したsession名。AppStateの新しい選択がまだViewへ届いていない状態との判別に使う。
    var managedSessionName: String? { currentSessionName }

    /// `prefix + L` 等でtmux内からsessionが変わった時、管理中のsession名を実態へ合わせる。
    func synchronizeCurrentSessionName(_ sessionName: String) {
        guard currentView != nil else { return }
        currentSessionName = sessionName
    }

    /// 現在表示中の terminal を first responder にする。同じ view への再要求も同じ状態へ収束する (冪等)。
    func focusTerminal() {
        guard let view = currentView else { return }
        // SwiftUI の View 更新と first responder 変更が競合しないよう次の runloop に回す。
        DispatchQueue.main.async {
            if let window = view.window, window.firstResponder !== view {
                window.makeFirstResponder(view)
            }
        }
    }

    /// 表示コンテナが破棄されたとき、そのコンテナ内の現行 terminal を終了して attach を手放す。
    /// 別コンテナへ移動済みの view や再度の呼び出しでは何もしない (冪等)。
    func detachTerminal(from container: NSView) {
        guard let view = currentView, view.superview === container else { return }
        view.terminate()
        view.removeFromSuperview()
        currentView = nil
        currentSessionName = nil
    }

    /// session に attach する terminal view を 1 つ生成する。
    /// terminal view の生成箇所はこの 1 メソッドに集約している (後工程のテーマ適用の差し込み点)。
    private func makeTerminalView(for sessionName: String) -> MouseReportingTerminalView {
        installMouseMonitorIfNeeded()
        let view = MouseReportingTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        baseFont = view.font
        // 前の session の格子を引き継がず、取得完了までフィット無し (設定サイズのまま) で表示する。
        windowGrid = nil
        view.processDelegate = self
        // SwiftTerm 自身の暗黙 URL 検出による自動オープンを止める。リンクオープンは Noroshi が独自のクリック検出で行うため二重化させない。
        // .alwaysWithModifier では linkForClick が暗黙リンク (match.isExplicit == false) を常に nil 扱いにするので、
        // client と tmux window の桁数不一致で折返しが崩れた時に SwiftTerm が誤結合した URL を開く不具合を防げる (LinkHighlightMode に無効化 case が無いための代替)。
        view.linkHighlightMode = .alwaysWithModifier
        // `=` プレフィックスで session 名の完全一致を強制 (前方一致による誤 attach を防ぐ)
        // Noroshi の画面サイズで他 client の window を resize しないよう ignore-size で attach する。
        view.startProcess(
            executable: TmuxClient.resolveBinaryPath(),
            args: TmuxClient.resolveBinaryPath().hasSuffix("env")
                ? ["tmux", "attach-session", "-f", "ignore-size", "-t", "=\(sessionName)"]
                : ["attach-session", "-f", "ignore-size", "-t", "=\(sessionName)"]
        )
        theme?.apply(to: view)
        applyFont(to: view)
        fetchWindowGrid(for: sessionName)
        return view
    }

    /// Ghostty/Noroshi config を再読み込みして、表示中の view (単一 attach なので最大 1) に配色とフォントを再適用する。
    /// メニュー「テーマを再読み込み」や設定ウィンドウの変更から呼ぶ。config 編集を再起動なしで反映するため。
    func reloadTheme() {
        theme = GhosttyTheme.load()
        if let view = currentView {
            theme?.apply(to: view)
            applyFont(to: view)
        }
    }

    /// ポーリング等が取得した attach 中 window の格子サイズを反映し、変わっていれば表示フォントを再フィットする。
    /// 同じ値の再通知では何もしない (冪等)。
    func updateWindowGrid(_ grid: TmuxWindowGrid?) {
        guard grid != windowGrid else { return }
        windowGrid = grid
        refitFont()
    }

    /// 表示領域の変化 (フルスクリーン切替・ウィンドウリサイズ) に合わせて表示フォントを再フィットする。
    /// 同じ状態からの再計算は同じフォントへ収束する (冪等)。
    func refitFont() {
        if let view = currentView {
            applyFont(to: view)
        }
    }

    /// レイアウトパス中 (setFrameSize) からの再フィット要求を次の runloop へ 1 回に合流させて実行する。
    /// レイアウト中に font を変更すると SwiftUI の View 更新と競合するため、同期では行わない。
    func scheduleRefitFont() {
        guard !pendingRefit else { return }
        pendingRefit = true
        DispatchQueue.main.async {
            self.pendingRefit = false
            self.refitFont()
        }
    }

    /// attach 中 session のカレント window の格子サイズを tmux から取り直し、届いたら再フィットする。
    /// tmux CLI (Process.waitUntilExit) は runloop を回すため、View 更新中に同期実行せず必ず非同期で行う。
    /// 取得中に別 session へ切り替わっていた場合は古い格子を適用しない。
    private func fetchWindowGrid(for sessionName: String) {
        let tmuxClient = self.tmuxClient
        Task { @MainActor in
            let grid = await Task.detached(priority: .userInitiated) {
                try? tmuxClient.windowGrid(session: sessionName)
            }.value
            guard self.currentSessionName == sessionName else { return }
            self.updateWindowGrid(grid)
        }
    }

    /// 解決済み設定の font-family / font-style / font-size を、attach 中 window の格子が view に収まる
    /// サイズへ必要な分だけ縮小して TerminalView.font に反映する (issue #36)。設定が無い場合も
    /// SwiftTerm 既定フォントを基準に同じフィットを行う。family が実在しなければ等幅システムフォントへ
    /// フォールバックする。
    /// font setter は selection 解除・レイアウト再計算の副作用があるため、値が変わる時だけ代入する (docs/knowledge.md)。
    private func applyFont(to view: MouseReportingTerminalView) {
        guard let baseFont else { return }
        let preferred: NSFont
        if let theme, theme.fontFamily != nil || theme.fontStyle != nil || theme.fontSize != nil {
            preferred = TerminalFontResolver.resolve(
                family: theme.fontFamily,
                style: theme.fontStyle,
                size: theme.fontSize.map { CGFloat($0) } ?? baseFont.pointSize,
                base: baseFont)
        } else {
            preferred = baseFont
        }
        let font = fittedFont(preferred: preferred, in: view)
        if view.font.fontName != font.fontName || view.font.pointSize != font.pointSize {
            view.font = font
            // SwiftTerm の font setter (resetFont) は terminal.softReset() でスクロール領域等を tmux に知らせず
            // 全画面へ戻すため、格子が変わらない font 変更では SIGWINCH が発生せず tmux 側のスクロール領域
            // キャッシュが実状態とずれたままになり、pane スクロールのたびに画面全体がせり上がって崩れる。
            // resetFont は scroller 幅を引かずに cols を計算するので、同じ frame で setFrameSize を呼び直すと
            // processSizeChange が scroller 幅を引いた必ず異なる cols へ再リサイズし、実サイズ変更 (SIGWINCH)
            // として tmux の全キャッシュ破棄 (tty_invalidate) と全再描画を強制できる (ADR 0010)。
            view.setFrameSize(view.frame.size)
        }
    }

    /// window 格子が判明している場合、view の表示領域に格子全体が収まるサイズへ縮小したフォントを返す。
    /// 格子が不明、または既に収まる場合は preferred をそのまま返す。
    private func fittedFont(preferred: NSFont, in view: MouseReportingTerminalView) -> NSFont {
        guard let windowGrid else { return preferred }
        // SwiftTerm の backingScaleFactor() と同じフォールバックでピクセル密度を解決する (セル寸法のスナップ一致のため)。
        let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let size = TerminalFontFit.fittedSize(
            preferred: preferred.pointSize,
            grid: windowGrid,
            viewSize: view.frame.size,
            // SwiftTerm の processSizeChange は scroller 幅を引いた実効幅で列数を計算するため同じ幅を引く。
            scrollerWidth: NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy),
            cellSize: { TerminalFontFit.cellSize(of: NSFont(descriptor: preferred.fontDescriptor, size: $0) ?? preferred, scale: scale) })
        guard size != preferred.pointSize else { return preferred }
        return NSFont(descriptor: preferred.fontDescriptor, size: size) ?? preferred
    }

    /// ホイール / 左ドラッグを横取りする local event monitor を 1 度だけ張る。生成済みなら何もしない (冪等)。
    /// SwiftTerm の scrollWheel / mouseDragged は別モジュールから再 override できないため、
    /// view へ配送される前段でイベントを掴んでマウスレポート送出とローカル処理の抑止を行う。
    private func installMouseMonitorIfNeeded() {
        guard mouseMonitor == nil else { return }
        // NSEvent は Sendable でないため、MainActor 境界は Bool (消費したか) だけを跨がせ、
        // event / nil の選択は境界の外で行う。monitor は常に main スレッドで発火するので assumeIsolated は安全。
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { event in
            MainActor.assumeIsolated {
                TerminalSessionManager.shared.reportMouseEventIfHandled(event)
            } ? nil : event
        }
    }

    /// 表示中 terminal view の上で起きたホイール / 左ドラッグならマウスレポートを送り、消費した (true) を返す。
    /// 左クリック (押下と同一セルでの離し) はリンクを開くが、選択やマウスレポートを壊さないため消費せず false を返す。
    /// 対象外なら false を返し、呼び出し側でイベントを既定処理へ通す。
    private func reportMouseEventIfHandled(_ event: NSEvent) -> Bool {
        // terminal 外の押下でも記録を必ず作り直す。外で押して view 内の古い記録セルと同じ位置で
        // 離した場合に、下の guard を通過した up が古い記録とマッチしてリンクを誤って開くのを防ぐ。
        if event.type == .leftMouseDown { mouseDownCell = nil }
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
        case .leftMouseDown:
            // 押下セルを記録するだけで消費しない。SwiftTerm のローカル選択開始を壊さないため常に素通しする。
            mouseDownCell = view.gridPosition(for: event, cell: view.cellSize())
            return false
        case .leftMouseUp:
            // 押下と同一セルで離した (ドラッグ選択でない) 素のクリックだけリンクを開く。up は消費しない。
            defer { mouseDownCell = nil }
            guard let downCell = mouseDownCell,
                  downCell == view.gridPosition(for: event, cell: view.cellSize())
            else { return false }
            openLinkIfClicked(at: downCell, in: view)
            return false
        default:
            return false
        }
    }

    /// クリックされたセルのテキストからリンクを検出し、URL はブラウザ、存在するファイルパスは対応アプリで開く。
    /// monitor コールバックを止めないよう Task で非同期に検出し、実解決 (tmux 照会・存在確認) は open 側でメインスレッド外へ逃がす。
    /// 検出できない・存在しないパスでは何もしないため、同じクリックを繰り返しても副作用は open のみに閉じる。
    private func openLinkIfClicked(at cell: (col: Int, row: Int), in view: MouseReportingTerminalView) {
        Task { @MainActor in
            let terminal = view.getTerminal()
            // ワイド文字直後の code 0 スペーサを NUL 文字として混入させないため両変換で skipNullCellsFollowingWide を有効化し、
            // 行結合 (rowTexts) とクリック列 (clickColumnInRow) の文字空間での数え方を一致させる。
            // 行境界の折返し継続は SwiftTerm の実 wrap 情報 (wrapsToNextRow) で判定し、桁数不一致で tmux がクリップ描画した行の誤結合を防ぐ。
            guard let logicalLine = TerminalLinkDetector.logicalLine(
                rowTexts: (0 ..< terminal.rows).map { terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true) ?? "" },
                filledToEdge: (0 ..< terminal.rows).map { wrapsToNextRow(terminal, screenRow: $0) },
                clickRow: cell.row,
                clickColumnInRow: terminal.getLine(row: cell.row)?
                    .translateToString(trimRight: false, startCol: 0, endCol: cell.col, skipNullCellsFollowingWide: true).count ?? 0),
                let link = TerminalLinkDetector.detectLink(logicalLine: logicalLine.text, column: logicalLine.column)
            else { return }
            await open(link)
        }
    }

    /// 画面行 screenRow の次行 (screenRow+1) が折返し継続かを SwiftTerm の実 wrap 情報から推定する。
    /// getText は wrapped 境界で改行を挟まず、ハード改行境界では "\n" を挟む (SwiftTerm の getSelectedLines が
    /// isWrapped を見て newLine fragment を入れるため)。internal な isWrapped を公開 API だけで代替判定する。
    /// これにより tmux が桁数不一致でクリップ描画した (折返しでない) 行が隣接行と誤結合するのを防ぐ。
    /// getText の Position.row は絶対バッファ行なので画面行に buffer.yDisp を加える。
    private func wrapsToNextRow(_ terminal: Terminal, screenRow: Int) -> Bool {
        guard screenRow + 1 < terminal.rows else { return false }
        return !terminal.getText(
            start: Position(col: 0, row: screenRow + terminal.buffer.yDisp),
            end: Position(col: terminal.cols, row: screenRow + 1 + terminal.buffer.yDisp)
        ).contains("\n")
    }

    /// 検出済みリンクを開く。相対パスのときだけ表示中 session のアクティブ pane カレントパスを基準に解決し、存在するもののみ開く。
    /// paneCurrentPath の tmux CLI 同期実行と fileExists は Process ブロッキングを伴うため Task.detached でメインスレッド外へ逃がし、
    /// NSWorkspace.open だけ main で行う。MainActor 隔離の tmuxClient / currentSessionName は detached へ渡す前に取り出す。
    private func open(_ link: TerminalLink) async {
        switch link {
        case .url(let url):
            NSWorkspace.shared.open(url)
        case .path(let path):
            let tmuxClient = self.tmuxClient
            let sessionName = currentSessionName
            guard let resolved = await Task.detached(priority: .userInitiated, operation: { () -> String? in
                guard let resolved = TerminalLinkDetector.resolvePath(
                    path,
                    homeDirectory: NSHomeDirectory(),
                    baseDirectory: TerminalLinkDetector.requiresBaseDirectory(path)
                        ? sessionName.flatMap { try? tmuxClient.paneCurrentPath(session: $0) }
                        : nil),
                    FileManager.default.fileExists(atPath: resolved)
                else { return nil }
                return resolved
            }).value
            else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: resolved))
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
/// session 切り替え時は単一 attach 方式に従い、同じtmux clientの接続先を切り替える。
struct TerminalHostView: NSViewRepresentable {
    /// 表示する tmux session 名。
    let sessionName: String
    /// 新規取り付け・session 切替時に terminal へフォーカスを移してよいか。
    /// サイドバーがキーボード操作中 (フォーカス保持中) は false にし、↑↓ ナビゲーションからフォーカスを奪わない (issue #30)。
    let takesFocus: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(on: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        install(on: container)
    }

    /// session 未選択画面へ切り替わる際、非表示の tmux attach を残さない。
    static func dismantleNSView(_ container: NSView, coordinator: ()) {
        TerminalSessionManager.shared.detachTerminal(from: container)
    }

    /// sessionName の terminal view をコンテナに取り付け、新規取り付け時またはsession切替時にフォーカスを当てる。
    private func install(on container: NSView) {
        let manager = TerminalSessionManager.shared
        let didChangeSession = manager.managedSessionName != sessionName
        let terminal = manager.terminalView(for: sessionName)
        // ポーリング由来の再描画ではフォーカスを奪わず、同じviewをswitch-clientした場合だけterminalへ戻す。
        guard terminal.superview !== container else {
            if didChangeSession, takesFocus { manager.focusTerminal() }
            return
        }
        container.subviews.forEach { $0.removeFromSuperview() }
        terminal.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            terminal.topAnchor.constraint(equalTo: container.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        if takesFocus { manager.focusTerminal() }
    }
}
