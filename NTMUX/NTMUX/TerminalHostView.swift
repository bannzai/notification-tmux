import AppKit
import SwiftTerm
import SwiftUI

/// session ごとの LocalProcessTerminalView を生かしたまま保持するキャッシュ。
/// 非表示でも attach と VT パースは継続する (SwiftTerm の仕様)。
/// NSObject 継承は LocalProcessTerminalViewDelegate が要求するため。
@MainActor
final class TerminalSessionManager: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalSessionManager()

    /// sessionName -> attach 済み terminal view。
    private var views: [String: LocalProcessTerminalView] = [:]

    /// session に attach した terminal view を返す。未作成なら PTY で `tmux attach-session` して作る。
    func terminalView(for sessionName: String) -> LocalProcessTerminalView {
        if let view = views[sessionName] { return view }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.processDelegate = self
        // `=` プレフィックスで session 名の完全一致を強制 (前方一致による誤 attach を防ぐ)
        view.startProcess(
            executable: TmuxClient.resolveBinaryPath(),
            args: TmuxClient.resolveBinaryPath().hasSuffix("env")
                ? ["tmux", "attach-session", "-t", "=\(sessionName)"]
                : ["attach-session", "-t", "=\(sessionName)"]
        )
        views[sessionName] = view
        return view
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// attach プロセス終了 (session kill / detach) でエントリを破棄し、次回表示時に再 attach させる。
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if let entry = views.first(where: { $0.value === source }) {
            views[entry.key] = nil
        }
    }
}

/// 選択中 session の terminal を表示する SwiftUI ラッパ。
/// session 切り替えは view の破棄ではなくコンテナへの付け替えで行い、attach を維持する。
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
