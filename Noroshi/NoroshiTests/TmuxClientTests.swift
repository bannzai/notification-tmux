import XCTest
@testable import Noroshi

/// TmuxClient.childEnvironment の locale 注入 (ADR 0008) を検証する。
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
}
