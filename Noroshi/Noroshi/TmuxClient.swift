import Foundation

/// tmux コマンドの実行失敗。stderr をそのまま保持する。
enum TmuxClientError: Error, CustomStringConvertible {
    case commandFailed(status: Int32, stderr: String)

    var description: String {
        switch self {
        case .commandFailed(let status, let stderr):
            return "tmux exited with status \(status): \(stderr)"
        }
    }

    /// tmux server 自体が停止している (no-server) ことを表すエラーか。
    /// kill-server や最後の session を閉じた時に server ごと終了すると tmux はこのエラーを返す。
    /// この場合はサイドバーの session を空にして消えた session への再 attach ループを止める判断に使う。
    var isNoServer: Bool {
        switch self {
        case .commandFailed(_, let stderr):
            return stderr.contains("no server running") || stderr.contains("error connecting")
        }
    }
}

/// tmux CLI のラッパ。attach 以外の照会・操作コマンドはすべてここを経由する。
struct TmuxClient {
    /// tmux バイナリの絶対パス。既知パスに無い場合は /usr/bin/env。
    let binaryPath: String

    // 既定値で binaryPath を解決するために定義している (memberwise init と同等の代入のみ)
    init(binaryPath: String = TmuxClient.resolveBinaryPath()) {
        self.binaryPath = binaryPath
    }

    /// tmux バイナリを Apple Silicon / Intel の homebrew 既知パスから解決する。無ければ /usr/bin/env で PATH に委ねる。
    static func resolveBinaryPath() -> String {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
    }

    /// tmux をサブプロセスとして同期実行し stdout を返す。非 0 終了は TmuxClientError。
    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = binaryPath.hasSuffix("env") ? ["tmux"] + arguments : arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TmuxClientError.commandFailed(
                status: process.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    /// 全 session とその window 一覧を取得する。
    func fetchSessions() throws -> [TmuxSession] {
        let grouped = Dictionary(
            grouping: try run(["list-windows", "-a", "-F", TmuxFormat.windowFormat])
                .split(separator: "\n")
                .compactMap { TmuxFormat.parseWindowLine(String($0)) },
            by: \.sessionName
        )
        return try run(["list-sessions", "-F", TmuxFormat.sessionFormat])
            .split(separator: "\n")
            .compactMap { line in
                guard let (name, attached) = TmuxFormat.parseSessionLine(String(line)) else { return nil }
                return TmuxSession(id: name, attachedClients: attached,
                                   windows: (grouped[name] ?? []).sorted { $0.index < $1.index })
            }
    }

    /// window_id (@n) を指定して、その window が属する session のカレント window を切り替える。
    /// window_id はサーバ全体で一意なので session 指定は不要。
    func selectWindow(id: String) throws {
        try run(["select-window", "-t", id])
    }

    /// session のカレント window を次の window に切り替える (末尾↔先頭で循環; tmux ネイティブ挙動)。
    func nextWindow(session: String) throws {
        try run(["next-window", "-t", "=\(session)"])
    }

    /// session のカレント window を前の window に切り替える (先頭↔末尾で循環; tmux ネイティブ挙動)。
    func previousWindow(session: String) throws {
        try run(["previous-window", "-t", "=\(session)"])
    }

    /// session のカレント window 内で、アクティブ pane を次 (offset >= 0) / 前 (offset < 0) の pane に移す (循環)。
    /// pane index トークン `.+` / `.-` を使う (man tmux TARGET SYNTAX)。
    func selectPane(session: String, offset: Int) throws {
        try run(["select-pane", "-t", "=\(session):.\(offset >= 0 ? "+" : "-")"])
    }

    /// session のカレント window の window_id (@n) を返す。移動後のバッジクリア対象の特定に使う。
    func activeWindowID(session: String) throws -> String {
        try run(["display-message", "-p", "-t", "=\(session):", "#{window_id}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
