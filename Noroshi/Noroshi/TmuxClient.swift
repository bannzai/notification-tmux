import Foundation

/// tmux コマンドの実行失敗。stderr をそのまま保持する。
enum TmuxClientError: Error, CustomStringConvertible {
    case commandFailed(status: Int32, stderr: String)
    case clientNotFound(pid: Int32)
    case sessionNotFound(name: String)
    case remoteClientTTYMissing(host: String)

    var description: String {
        switch self {
        case .commandFailed(let status, let stderr):
            return "tmux exited with status \(status): \(stderr)"
        case .clientNotFound(let pid):
            return "tmux client for pid \(pid) was not found"
        case .sessionNotFound(let name):
            return "tmux session \(name) was not found"
        case .remoteClientTTYMissing(let host):
            return "noroshi client tty is not recorded on \(host)"
        }
    }

    /// tmux server 自体が停止している (no-server) ことを表すエラーか。
    /// kill-server や最後の session を閉じた時に server ごと終了すると tmux はこのエラーを返す。
    /// この場合はサイドバーの session を空にして消えた session への再 attach ループを止める判断に使う。
    /// リモート host でも stderr は ssh を素通しするため同じ判定が使える。
    var isNoServer: Bool {
        switch self {
        case .commandFailed(_, let stderr):
            return stderr.contains("no server running") || stderr.contains("error connecting")
        case .clientNotFound, .sessionNotFound, .remoteClientTTYMissing:
            return false
        }
    }
}

/// tmux CLI のラッパ。attach 以外の照会・操作コマンドはすべてここを経由する。
/// host が remote の場合は同じコマンドを `ssh <host> tmux ...` として実行する (issue #38)。
struct TmuxClient {
    /// ローカル tmux バイナリの絶対パス。既知パスに無い場合は /usr/bin/env。リモート実行では使わない。
    let binaryPath: String
    /// コマンドの実行先 tmux サーバ。
    let host: TmuxHost

    // 既定値で binaryPath を解決するために定義している (memberwise init と同等の代入のみ)
    init(binaryPath: String = TmuxClient.resolveBinaryPath(), host: TmuxHost = .local) {
        self.binaryPath = binaryPath
        self.host = host
    }

    /// tmux バイナリを Apple Silicon / Intel の homebrew 既知パスから解決する。無ければ /usr/bin/env で PATH に委ねる。
    static func resolveBinaryPath() -> String {
        ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
    }

    /// ssh クライアントのパス。macOS 標準搭載のため固定。
    static let sshPath = "/usr/bin/ssh"

    /// リモート attach ラッパが client tty を記録するリモート側ファイル ($HOME 直下)。
    /// リモートでは PID で自分の tmux client を特定できないため、attach 時に記録した tty を
    /// `switch-client -c` の対象に使う (issue #38)。
    static let remoteClientTTYFile = ".noroshi-client-tty"

    /// リモートの Stop hook が通知を書き込む socket のリモート側ファイル名 ($HOME 直下、issue #39)。
    static let remoteStopSocketFile = ".noroshi.sock"

    /// 非対話 ssh 実行の共通オプション。
    /// - BatchMode: 鍵認証前提。パスワードプロンプトでポーリングや attach を止めない
    /// - ConnectTimeout=5: 落ちている host への接続で 2 秒ポーリングを長時間塞がない実用値
    /// - ControlMaster/ControlPath/ControlPersist=600: 接続を多重化し 2 回目以降を数十 ms にする (issue #38)。
    ///   600 秒はポーリング間隔 (2 秒) より十分長く、attach 終了後もしばらく再接続を速く保つ値
    static func sshBatchOptions() -> [String] {
        [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ControlMaster=auto",
            // NSTemporaryDirectory はユーザー専用 (mode 700) のため socket の作成先として安全。%C でパス長も一定に収まる。
            "-o", "ControlPath=\(NSTemporaryDirectory())noroshi-ssh-%C",
            "-o", "ControlPersist=600",
        ]
    }

    /// リモート shell (POSIX sh/bash/zsh) 向けの single quote エスケープ。
    /// ssh はリモートコマンドを空白結合して相手 shell に渡すため、`#{...}` (コメント扱い) や空白入り session 名を守る。
    static func shellQuote(_ argument: String) -> String {
        "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// tmux サブコマンドを実行する argv (先頭が実行ファイル)。
    /// リモートは `tmux -u` を付ける: ssh 非対話 shell は locale が不定で、非 UTF-8 扱いになると
    /// tmux がフォーマット出力中の 0x1F 区切りを `_` にサニタイズするため (tmux 3.2a で実測、issue #34 と同根)。
    func tmuxArgv(_ arguments: [String]) -> [String] {
        switch host {
        case .local:
            return [binaryPath] + (binaryPath.hasSuffix("env") ? ["tmux"] : []) + arguments
        case .remote(let sshDestination):
            return [Self.sshPath] + Self.sshBatchOptions() + [sshDestination, "tmux", "-u"]
                + arguments.map(Self.shellQuote)
        }
    }

    /// SwiftTerm.startProcess に渡す attach コマンド (実行ファイルと引数)。
    /// - ローカル: `tmux attach-session -f ignore-size -t =<name>`
    /// - リモート: `ssh -t <host> 'tty > ~/.noroshi-client-tty && exec tmux -u attach-session ...'`。
    ///   tty の記録は switch-client 用 (issue #38)、`-u` は UTF-8 表示をリモート locale に依存させないため。
    /// `=` プレフィックスは session 名の完全一致を強制し、`-f ignore-size` は他 client の window を resize しないため。
    func attachCommand(sessionName: String) -> (executable: String, arguments: [String]) {
        switch host {
        case .local:
            return (binaryPath,
                    (binaryPath.hasSuffix("env") ? ["tmux"] : [])
                        + ["attach-session", "-f", "ignore-size", "-t", "=\(sessionName)"])
        case .remote(let sshDestination):
            return (Self.sshPath,
                    ["-t"] + Self.sshBatchOptions() + [
                        sshDestination,
                        "tty > \"$HOME/\(Self.remoteClientTTYFile)\" && exec tmux -u attach-session -f ignore-size -t \(Self.shellQuote("=" + sessionName))",
                    ])
        }
    }

    /// tmux 子プロセスに渡す環境変数 (ADR 0008)。
    /// Finder/Spotlight 起動 (launchd 環境) には locale 変数が無く、tmux が非 UTF-8 クライアント扱いに
    /// なって出力中の制御文字 (`TmuxFormat.fieldSeparator` 0x1F) を `_` へサニタイズするため、
    /// exit 0 のまま一覧のパースが全滅する (issue #34)。locale 未設定の時だけ UTF-8 を明示する。
    static func childEnvironment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        // 文字種 locale は LC_ALL > LC_CTYPE > LANG の優先で決まる (POSIX) ため、いずれかがあれば
        // ユーザー設定を尊重する。値は PTY 側の既定 (SwiftTerm getEnvironmentVariables) と同じ en_US.UTF-8。
        guard base["LC_ALL"] == nil, base["LC_CTYPE"] == nil, base["LANG"] == nil else { return base }
        var environment = base
        environment["LC_CTYPE"] = "en_US.UTF-8"
        return environment
    }

    /// tmux をサブプロセス (リモートは ssh 経由) として同期実行し stdout を返す。非 0 終了は TmuxClientError。
    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        try Self.execute(argv: tmuxArgv(arguments))
    }

    /// ssh 先で tmux 以外の任意コマンドを実行する。リモート host 専用 (ローカルでは呼ばない)。
    @discardableResult
    func runRemoteShell(_ command: String) throws -> String {
        guard case .remote(let sshDestination) = host else {
            preconditionFailure("runRemoteShell is only for remote hosts")
        }
        return try Self.execute(argv: [Self.sshPath] + Self.sshBatchOptions() + [sshDestination, command])
    }

    /// argv (先頭が実行ファイル) を同期実行し stdout を返す。非 0 終了は TmuxClientError。
    private static func execute(argv: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        process.environment = childEnvironment()
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
                .compactMap { TmuxFormat.parseWindowLine(String($0), host: host) },
            by: \.sessionName
        )
        return try run(["list-sessions", "-F", TmuxFormat.sessionFormat])
            .split(separator: "\n")
            .compactMap { line in
                guard let (name, attached) = TmuxFormat.parseSessionLine(String(line)) else { return nil }
                return TmuxSession(host: host, name: name, attachedClients: attached,
                                   windows: (grouped[name] ?? []).sorted { $0.index < $1.index })
            }
    }

    /// 指定フォルダを開始位置とするtmux sessionを、既存名と重ならない名前で新規作成する。
    /// ユーザーが明示的に新規sessionを要求する操作なので、この関数自体は意図的に非冪等。
    /// 名前決定は毎回最新の一覧から行い、同名sessionを上書きしない。
    func createSession(directory: URL) throws -> String {
        let existingNames: Set<String>
        do {
            existingNames = Set(try run(["list-sessions", "-F", "#{session_name}"])
                .split(separator: "\n")
                .map(String.init))
        } catch let error as TmuxClientError where error.isNoServer {
            existingNames = []
        }

        let name = TmuxSessionNaming.availableName(for: directory, existingNames: existingNames)
        try run(["new-session", "-d", "-s", name, "-c", directory.standardizedFileURL.path])
        return name
    }

    /// window_id (@n) を指定して、その window が属する session のカレント window を切り替える。
    /// window_id はサーバ全体で一意なので session 指定は不要。
    func selectWindow(id: String) throws {
        try run(["select-window", "-t", id])
    }

    /// SwiftTerm が起動したtmux clientのPIDから、client ttyと現在のsessionを取得する (ローカル host のみ)。
    func attachedClient(pid: Int32) throws -> TmuxAttachedClient? {
        try run(["list-clients", "-F", TmuxFormat.clientFormat])
            .split(separator: "\n")
            .compactMap { TmuxFormat.parseClientLine(String($0)) }
            .first(where: { $0.pid == pid })
    }

    /// 同じtmux clientを別sessionへ切り替える。clientを作り直さないため `prefix + L` の履歴が保たれる。
    func switchClient(pid: Int32, to session: String) throws {
        guard let attachedClient = try attachedClient(pid: pid) else {
            throw TmuxClientError.clientNotFound(pid: pid)
        }
        try run(["switch-client", "-c", attachedClient.tty, "-t", resolveSessionID(named: session)])
    }

    /// attach 時に記録したリモート側 tty の client を別 session へ切り替える (issue #38)。
    /// リモートの tmux client はローカルの子プロセスではないため、PID ではなく記録済み tty で特定する。
    func switchRemoteClient(to session: String) throws {
        let tty = try runRemoteShell("cat \"$HOME/\(Self.remoteClientTTYFile)\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard tty.hasPrefix("/dev/") else {
            throw TmuxClientError.remoteClientTTYMissing(host: host.id)
        }
        try run(["switch-client", "-c", tty, "-t", resolveSessionID(named: session)])
    }

    /// session名を安全なswitch-client targetへ解決する。
    /// switch-clientは`.`、`:`、`%`を含むtargetをpaneとして特別扱いするため、名前ではなくsession IDを渡す。
    private func resolveSessionID(named session: String) throws -> String {
        guard let sessionID = try run(["list-sessions", "-F", TmuxFormat.sessionIDFormat])
            .split(separator: "\n")
            .compactMap({ TmuxFormat.parseSessionIDLine(String($0)) })
            .first(where: { $0.name == session })?.id
        else {
            throw TmuxClientError.sessionNotFound(name: session)
        }
        return sessionID
    }

    /// session のカレント window 内で、アクティブ pane を次 (offset >= 0) / 前 (offset < 0) の pane に移す (循環)。
    /// pane index トークン `.+` / `.-` を使う (man tmux TARGET SYNTAX)。
    func selectPane(session: String, offset: Int) throws {
        try run(["select-pane", "-t", "=\(session):.\(offset >= 0 ? "+" : "-")"])
    }

    /// session のカレント window の格子サイズ (列 × 行) を返す。表示フォントのフィット計算 (issue #36) に使う。
    /// target は colon 付き `=session:` 形式で session のカレント window を指す。
    func windowGrid(session: String) throws -> TmuxWindowGrid? {
        TmuxFormat.parseWindowGridLine(
            try run(["display-message", "-p", "-t", "=\(session):", TmuxFormat.windowGridFormat])
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// session のアクティブ pane のカレントディレクトリを返す。クリックされた相対パスの解決基準に使う。
    /// target は windowGrid と同じ colon 付き `=session:` 形式にする。colon 無し `=session` は
    /// tmux 3.2a で pane 変数 `#{pane_current_path}` に空文字を返し、相対パス解決が全滅するため。
    func paneCurrentPath(session: String) throws -> String {
        try run(["display-message", "-p", "-t", "=\(session):", "#{pane_current_path}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
