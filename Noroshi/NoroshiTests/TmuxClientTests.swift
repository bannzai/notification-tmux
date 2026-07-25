import XCTest
@testable import Noroshi

/// TmuxClient の locale 注入 (ADR 0008) と、ssh 経由実行のコマンド組み立て (issue #38) を検証する。
/// 実際に ssh 接続はせず、argv の組み立てだけを純粋に確認する。
final class TmuxClientTests: XCTestCase {
    func testChildEnvironmentはlocale未設定ならLC_CTYPEにUTF8を注入する() {
        let environment = TmuxClient.childEnvironment(base: ["PATH": "/usr/bin", "HOME": "/Users/x"])
        XCTAssertEqual(environment["LC_CTYPE"], "en_US.UTF-8")
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["HOME"], "/Users/x")
    }

    func testChildEnvironmentはLANGがあれば何も変えない() {
        let base = ["LANG": "ja_JP.UTF-8", "PATH": "/usr/bin"]
        XCTAssertEqual(TmuxClient.childEnvironment(base: base), base)
    }

    func testChildEnvironmentはLC_ALLがあれば何も変えない() {
        let base = ["LC_ALL": "C"]
        XCTAssertEqual(TmuxClient.childEnvironment(base: base), base)
    }

    func testChildEnvironmentはLC_CTYPEがあれば何も変えない() {
        let base = ["LC_CTYPE": "en_US.UTF-8"]
        XCTAssertEqual(TmuxClient.childEnvironment(base: base), base)
    }

    // MARK: - shellQuote

    func testShellQuoteはリモートshellのメタ文字を無害化する() {
        XCTAssertEqual(TmuxClient.shellQuote("plain"), "'plain'")
        XCTAssertEqual(TmuxClient.shellQuote("#{session_name}"), "'#{session_name}'")
        XCTAssertEqual(TmuxClient.shellQuote("with space"), "'with space'")
        // 埋め込み single quote は '\'' で連結する
        XCTAssertEqual(TmuxClient.shellQuote("it's"), "'it'\\''s'")
    }

    // MARK: - argv 組み立て

    func testTmuxArgvローカルはバイナリ直接実行() {
        let argv = TmuxClient(binaryPath: "/opt/homebrew/bin/tmux").tmuxArgv(["list-sessions", "-F", "#{session_name}"])
        XCTAssertEqual(argv, ["/opt/homebrew/bin/tmux", "list-sessions", "-F", "#{session_name}"])
    }

    func testTmuxArgvローカルのenvフォールバックはtmuxを前置する() {
        let argv = TmuxClient(binaryPath: "/usr/bin/env").tmuxArgv(["list-sessions"])
        XCTAssertEqual(argv, ["/usr/bin/env", "tmux", "list-sessions"])
    }

    func testTmuxArgvリモートはssh経由でクオートとUTF8フラグを付ける() throws {
        let argv = TmuxClient(binaryPath: "/opt/homebrew/bin/tmux", host: .remote("dev-machine"))
            .tmuxArgv(["list-windows", "-a", "-F", TmuxFormat.windowFormat])
        XCTAssertEqual(argv.first, "/usr/bin/ssh")
        // 非対話実行の前提: 鍵認証 (BatchMode) と接続の多重化 (ControlMaster)
        XCTAssertTrue(argv.contains("BatchMode=yes"))
        XCTAssertTrue(argv.contains(where: { $0.hasPrefix("ControlPath=") }))
        // 接続先の後に tmux -u が続く (リモート locale 不定でも 0x1F がサニタイズされないため)
        let hostIndex = try XCTUnwrap(argv.firstIndex(of: "dev-machine"))
        XCTAssertEqual(argv[hostIndex + 1], "tmux")
        XCTAssertEqual(argv[hostIndex + 2], "-u")
        // リモート shell で `#{` がコメント扱いされないよう引数はクオートされる
        XCTAssertEqual(argv[hostIndex + 3], "'list-windows'")
        XCTAssertTrue(try XCTUnwrap(argv.last).hasPrefix("'#{session_name}"))
    }

    // MARK: - attach コマンド

    func testAttachCommandローカルはtmuxを直接attachする() {
        let command = TmuxClient(binaryPath: "/opt/homebrew/bin/tmux").attachCommand(sessionName: "Focus")
        XCTAssertEqual(command.executable, "/opt/homebrew/bin/tmux")
        XCTAssertEqual(command.arguments, ["attach-session", "-f", "ignore-size", "-t", "=Focus"])
    }

    func testAttachCommandローカルのenvフォールバックはtmuxを前置する() {
        let command = TmuxClient(binaryPath: "/usr/bin/env").attachCommand(sessionName: "Focus")
        XCTAssertEqual(command.executable, "/usr/bin/env")
        XCTAssertEqual(command.arguments, ["tmux", "attach-session", "-f", "ignore-size", "-t", "=Focus"])
    }

    func testAttachCommandリモートはtty記録とexec付きのssh起動になる() throws {
        let command = TmuxClient(host: .remote("dev-machine")).attachCommand(sessionName: "my session")
        XCTAssertEqual(command.executable, "/usr/bin/ssh")
        // 対話 attach のため tty を割り当てる
        XCTAssertEqual(command.arguments.first, "-t")
        XCTAssertTrue(command.arguments.contains("dev-machine"))
        // リモートコマンド: client tty の記録 (switch-client 用) -> exec で tmux へ置き換え。
        // 空白入り session 名もリモート shell で 1 引数になるようクオートされる
        XCTAssertEqual(
            command.arguments.last,
            "tty > \"$HOME/.noroshi-client-tty\" && exec tmux -u attach-session -f ignore-size -t '=my session'"
        )
    }
}
