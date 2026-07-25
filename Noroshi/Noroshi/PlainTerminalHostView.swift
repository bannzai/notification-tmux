import AppKit
import SwiftTerm
import SwiftUI

/// 素のターミナル (tmux に attach しないログインシェル) が起動するシェルの解決 (issue #54)。
enum PlainTerminalShell {
    /// passwd のログインシェル → SHELL 環境変数 → /bin/zsh の順で、実行可能な最初の候補を返す。
    /// /bin/zsh は macOS (Catalina 以降) の既定ログインシェルで常に存在するため、最終フォールバックにする。
    static func resolve(passwdShell: String?, environmentShell: String?, isExecutable: (String) -> Bool) -> String {
        [passwdShell, environmentShell].compactMap { $0 }.filter { !$0.isEmpty }.first(where: isExecutable) ?? "/bin/zsh"
    }

    /// 現在ユーザーの passwd エントリのログインシェル (chsh の設定値)。
    static func currentPasswdShell() -> String? {
        guard let passwd = getpwuid(getuid()), let shell = passwd.pointee.pw_shell else { return nil }
        return String(cString: shell)
    }
}

/// session 未選択のタブに表示する素のターミナル (ログインシェル) をタブごとに管理する (issue #54)。
/// tmux の単一 attach (TerminalSessionManager) と違い、タブを閉じるまでシェルを生かしたまま保持する:
/// タブ切替や session 選択で非表示になっても、シェル内で実行中のプロセス (ssh 越しの tmux 等) を切らないため。
/// NSObject 継承は LocalProcessTerminalViewDelegate が要求するため。
@MainActor
final class PlainTerminalManager: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = PlainTerminalManager()

    /// タブ ID -> 起動済みシェルの terminal view。
    private var terminalViews: [UUID: LocalProcessTerminalView] = [:]
    /// Ghostty config 由来の配色・フォント。起動時に一度読み、reloadTheme で更新する。config が無ければ nil。
    private var theme = GhosttyTheme.load()
    /// フォント解決の基準となる SwiftTerm 既定フォント。theme 変更の再解決が累積しないよう未加工の値を保持する。
    private var baseFont: NSFont?
    /// シェル終了時のタブ後始末の委譲先 (AppState.handlePlainTerminalExit)。
    private var onProcessExit: ((UUID) -> Void)?

    /// シェルが終了したタブの後始末を登録する。再登録しても最後の 1 つに収束する (冪等)。
    func configure(onProcessExit: @escaping (UUID) -> Void) {
        self.onProcessExit = onProcessExit
    }

    /// tabID の terminal view を返す。未生成ならログインシェルを起動して作る。同じ tabID には同じ view を返す (冪等)。
    func terminalView(for tabID: UUID) -> LocalProcessTerminalView {
        if let view = terminalViews[tabID] { return view }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        if baseFont == nil { baseFont = view.font }
        view.processDelegate = self
        applyThemeAndFont(to: view)
        // SwiftTerm の既定環境 (Terminal.getEnvironmentVariables) は PATH を含まないため、`-l` の
        // ログインシェルとして起動し、/etc/zprofile (path_helper) 経由で PATH を構築させる。
        view.startProcess(
            executable: PlainTerminalShell.resolve(
                passwdShell: PlainTerminalShell.currentPasswdShell(),
                environmentShell: ProcessInfo.processInfo.environment["SHELL"],
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) }),
            args: ["-l"],
            currentDirectory: NSHomeDirectory())
        terminalViews[tabID] = view
        return view
    }

    /// タブを閉じた時に、そのタブのシェルを終了して破棄する。未生成・破棄済みなら何もしない (冪等)。
    func closeTerminal(for tabID: UUID) {
        guard let view = terminalViews.removeValue(forKey: tabID) else { return }
        view.terminate()
        view.removeFromSuperview()
    }

    /// tabID の terminal を first responder にする。同じ view への再要求も同じ状態へ収束する (冪等)。
    func focusTerminal(for tabID: UUID) {
        guard let view = terminalViews[tabID] else { return }
        // SwiftUI の View 更新と first responder 変更が競合しないよう次の runloop に回す。
        DispatchQueue.main.async {
            if let window = view.window, window.firstResponder !== view {
                window.makeFirstResponder(view)
            }
        }
    }

    /// Ghostty/Noroshi config を再読み込みし、生成済みの全 terminal に配色とフォントを再適用する。
    func reloadTheme() {
        theme = GhosttyTheme.load()
        terminalViews.values.forEach { applyThemeAndFont(to: $0) }
    }

    /// 解決済み設定の配色とフォントを反映する。tmux の window 格子 (issue #36) と違い収める対象が無いため、フィット縮小は行わない。
    /// font setter は selection 解除・レイアウト再計算の副作用があるため、値が変わる時だけ代入する (docs/knowledge.md)。
    private func applyThemeAndFont(to view: LocalProcessTerminalView) {
        theme?.apply(to: view)
        guard let baseFont else { return }
        let font = TerminalFontResolver.preferred(theme: theme, base: baseFont)
        if view.font.fontName != font.fontName || view.font.pointSize != font.pointSize {
            view.font = font
        }
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    /// シェルが自分で終了した (exit 等) タブの view を破棄し、タブの後始末を AppState へ委譲する。
    /// closeTerminal で明示的に terminate() した view はここに来ない (SwiftTerm の terminate() は
    /// childMonitor を cancel するため processTerminated を発火しない)。
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let tabID = terminalViews.first(where: { $0.value === source })?.key else { return }
        terminalViews[tabID] = nil
        source.removeFromSuperview()
        onProcessExit?(tabID)
    }
}

/// session 未選択のタブ (起動直後・新規タブ・session 消滅) に素のターミナルを表示する SwiftUI ラッパ (issue #54)。
struct PlainTerminalHostView: NSViewRepresentable {
    /// 表示するタブの ID。タブごとに独立したシェルを保持する。
    let tabID: UUID
    /// 取り付け時に terminal へフォーカスを移してよいか。サイドバーのキーボード操作中は false (issue #30)。
    let takesFocus: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(on: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        install(on: container)
    }

    /// tabID のシェル terminal をコンテナへ取り付ける。タブ切替では前のタブの terminal を外すだけで、シェルは終了しない。
    private func install(on container: NSView) {
        let terminal = PlainTerminalManager.shared.terminalView(for: tabID)
        guard terminal.superview !== container else { return }
        container.subviews.forEach { $0.removeFromSuperview() }
        TerminalHostView.pin(terminal, in: container)
        if takesFocus { PlainTerminalManager.shared.focusTerminal(for: tabID) }
    }
}
