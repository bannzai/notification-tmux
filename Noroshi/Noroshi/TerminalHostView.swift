import AppKit
import SwiftTerm
import SwiftUI

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
    private var currentView: LocalProcessTerminalView?
    /// こちらが切替で明示的に terminate した view。後から遅れて届く processTerminated を無視するため。
    private var intentionallyTerminated: Set<ObjectIdentifier> = []
    /// Ghostty config 由来の配色。起動時に一度読み、メニュー「テーマを再読み込み」で更新する。config が無ければ nil。
    private var theme = GhosttyTheme.load()

    /// session に attach した terminal view を返す。別 session が表示中なら、その view を破棄してから新規 attach する。
    /// 同じ session の再要求では既存 view をそのまま返す (再 attach しない)。
    func terminalView(for sessionName: String) -> LocalProcessTerminalView {
        if currentSessionName == sessionName, let view = currentView {
            return view
        }
        if let old = currentView {
            intentionallyTerminated.insert(ObjectIdentifier(old))
            old.terminate()
        }
        let view = makeTerminalView(for: sessionName)
        currentView = view
        currentSessionName = sessionName
        return view
    }

    /// session に attach する LocalProcessTerminalView を 1 つ生成する。
    /// terminal view の生成箇所はこの 1 メソッドに集約している (後工程のテーマ適用の差し込み点)。
    private func makeTerminalView(for sessionName: String) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.processDelegate = self
        // `=` プレフィックスで session 名の完全一致を強制 (前方一致による誤 attach を防ぐ)
        view.startProcess(
            executable: TmuxClient.resolveBinaryPath(),
            args: TmuxClient.resolveBinaryPath().hasSuffix("env")
                ? ["tmux", "attach-session", "-t", "=\(sessionName)"]
                : ["attach-session", "-t", "=\(sessionName)"]
        )
        theme?.apply(to: view)
        return view
    }

    /// Ghostty config を再読み込みして、表示中の view (単一 attach なので最大 1) に配色を再適用する。
    /// メニュー「テーマを再読み込み」から呼ぶ。config 編集を再起動なしで反映するため。
    func reloadTheme() {
        theme = GhosttyTheme.load()
        if let view = currentView { theme?.apply(to: view) }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// attach プロセス終了時の後始末。
    /// - こちらが切替で terminate した view: 無視する (期待どおりの終了)。
    /// - 表示中の view が予期せず死んだ (session kill / detach): 現在の attach を手放す。
    ///   再表示は AppState.refresh() の先頭フォールバックが選択を生存 session に移すことで安全に行われる (再 attach ループ防止)。
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if intentionallyTerminated.remove(ObjectIdentifier(source)) != nil {
            return
        }
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

    /// sessionName の terminal view をコンテナに取り付け、フォーカスを当てる。
    private func install(on container: NSView) {
        let terminal = TerminalSessionManager.shared.terminalView(for: sessionName)
        if terminal.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            terminal.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                terminal.topAnchor.constraint(equalTo: container.topAnchor),
                terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        // updateNSView の同期処理中に firstResponder を変えると SwiftUI の更新と競合するため次の runloop に回す
        DispatchQueue.main.async {
            if let window = terminal.window, window.firstResponder !== terminal {
                window.makeFirstResponder(terminal)
            }
        }
    }
}
