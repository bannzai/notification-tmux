import SwiftTerm
import XCTest

@testable import Noroshi

/// NoroshiConfig の config パス優先順位 (noroshi 優先 / 無ければ ghostty フォールバック) を検証する。
/// ユーザーの実 ~/.config には依存せず、注入した fileExists か一時ディレクトリで確認する。
final class NoroshiConfigTests: XCTestCase {
    private func color8(_ red: Int, _ green: Int, _ blue: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - パス優先順位 (fileExists 注入)

    func testPrefersNoroshiConfigWhenItExists() {
        let result = NoroshiConfig.preferredConfigPath(
            noroshiConfigPath: "/config/noroshi/config",
            ghosttyConfigPath: "/config/ghostty/config",
            fileExists: { $0 == "/config/noroshi/config" }
        )
        XCTAssertEqual(result, "/config/noroshi/config")
    }

    func testFallsBackToGhosttyConfigWhenNoroshiMissing() {
        let result = NoroshiConfig.preferredConfigPath(
            noroshiConfigPath: "/config/noroshi/config",
            ghosttyConfigPath: "/config/ghostty/config",
            fileExists: { _ in false }  // どちらも存在しない → ghostty へフォールバック
        )
        XCTAssertEqual(result, "/config/ghostty/config")
    }

    // MARK: - 実ファイルでの優先順位 + load 経路

    func testPrefersNoroshiConfigContentOnDisk() throws {
        let dir = try makeTempDirectory()
        let noroshi = dir.appendingPathComponent("noroshi-config")
        let ghostty = dir.appendingPathComponent("ghostty-config")
        try "background = #111111".write(to: noroshi, atomically: true, encoding: .utf8)
        try "background = #222222".write(to: ghostty, atomically: true, encoding: .utf8)

        // 実 fileExists で noroshi が優先される
        let path = NoroshiConfig.preferredConfigPath(
            noroshiConfigPath: noroshi.path, ghosttyConfigPath: ghostty.path)
        XCTAssertEqual(path, noroshi.path)
        // 優先パスの内容を load が読むことも確認
        let theme = GhosttyTheme.load(configPath: path, themesDirectories: [], prefersDark: true)
        XCTAssertEqual(theme?.background, color8(0x11, 0x11, 0x11))
    }

    func testFallsBackToGhosttyContentWhenNoroshiMissingOnDisk() throws {
        let dir = try makeTempDirectory()
        let noroshi = dir.appendingPathComponent("noroshi-config")  // 作らない
        let ghostty = dir.appendingPathComponent("ghostty-config")
        try "background = #222222".write(to: ghostty, atomically: true, encoding: .utf8)

        let path = NoroshiConfig.preferredConfigPath(
            noroshiConfigPath: noroshi.path, ghosttyConfigPath: ghostty.path)
        XCTAssertEqual(path, ghostty.path)
        let theme = GhosttyTheme.load(configPath: path, themesDirectories: [], prefersDark: true)
        XCTAssertEqual(theme?.background, color8(0x22, 0x22, 0x22))
    }
}
