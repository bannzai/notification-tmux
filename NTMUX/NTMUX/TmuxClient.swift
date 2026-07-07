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
}
