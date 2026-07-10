import AppKit
import SwiftTerm
import XCTest

@testable import Noroshi

/// GhosttyTheme のパース・256 色補完・theme 解決・SwiftTerm への適用を検証する。
/// ユーザーの実 config には依存せず、一時ディレクトリに fixture を書いて確認する。
final class GhosttyThemeTests: XCTestCase {
    // MARK: - ヘルパ

    /// 8bit 成分から期待値の SwiftTerm.Color (16bit = 8bit*257) を作る。
    private func color8(_ red: Int, _ green: Int, _ blue: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
    }

    /// 一時ディレクトリを作り、テスト終了時に破棄する。
    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - 基本キーのパース

    func testParsesBasicKeys() {
        let (theme, themeRef) = GhosttyTheme.parse(configText: """
        background = #303446
        foreground = #c6d0f5
        cursor-color = #f2d5cf
        selection-background = #626880
        selection-foreground = #c6d0f5
        """)
        XCTAssertNil(themeRef)
        XCTAssertEqual(theme.background, color8(0x30, 0x34, 0x46))
        XCTAssertEqual(theme.foreground, color8(0xc6, 0xd0, 0xf5))
        XCTAssertEqual(theme.cursorColor, color8(0xf2, 0xd5, 0xcf))
        XCTAssertEqual(theme.selectionBackground, color8(0x62, 0x68, 0x80))
        XCTAssertEqual(theme.selectionForeground, color8(0xc6, 0xd0, 0xf5))
    }

    func testIgnoresCommentsBlankAndInvalidLines() {
        let (theme, _) = GhosttyTheme.parse(configText: """
        # これはコメント
          # インデント付きコメント

        background = #010203
        this-line-has-no-equals-sign
        unknown-key = whatever
        foreground = not-a-color
        = valueWithoutKey
        """)
        XCTAssertEqual(theme.background, color8(0x01, 0x02, 0x03))
        // 未知キー・不正色・key 無し・= 無しはすべて無視され、foreground は不正値なので未設定のまま
        XCTAssertNil(theme.foreground)
    }

    // MARK: - hex 変換

    func testParsesHexWithAndWithoutHash() {
        XCTAssertEqual(GhosttyTheme.parseColor("#ffffff"), color8(255, 255, 255))
        XCTAssertEqual(GhosttyTheme.parseColor("ffffff"), color8(255, 255, 255))
        XCTAssertEqual(GhosttyTheme.parseColor("#000000"), color8(0, 0, 0))
        XCTAssertEqual(GhosttyTheme.parseColor("  #51576D  "), color8(0x51, 0x57, 0x6d))
    }

    func testHexScalesTo16Bit() {
        // 0x51 = 81, 81 * 257 = 20817
        let color = GhosttyTheme.parseColor("#515151")
        XCTAssertEqual(color?.red, 20817)
        XCTAssertEqual(color?.green, 20817)
        XCTAssertEqual(color?.blue, 20817)
    }

    func testRejectsNonHexColors() {
        XCTAssertNil(GhosttyTheme.parseColor("red"))          // X11 名前色は未対応
        XCTAssertNil(GhosttyTheme.parseColor("#fff"))         // 3桁 hex は未対応
        XCTAssertNil(GhosttyTheme.parseColor("#gggggg"))      // 不正 hex
        XCTAssertNil(GhosttyTheme.parseColor("#1234567"))     // 桁数超過
    }

    // MARK: - palette パース + 256 色補完

    func testParsesPaletteEntries() {
        let (theme, _) = GhosttyTheme.parse(configText: """
        palette = 0=#000000
        palette = 15=#d0d0d0
        palette = 256=#ffffff
        palette = -1=#ffffff
        palette = abc=#ffffff
        """)
        XCTAssertEqual(theme.palette[0], color8(0, 0, 0))
        XCTAssertEqual(theme.palette[15], color8(0xd0, 0xd0, 0xd0))
        // 範囲外 (256, -1) と不正 index (abc) は無視される
        XCTAssertNil(theme.palette[256])
        XCTAssertEqual(theme.palette.count, 2)
    }

    func testAnsi256PaletteDefaultsMatchXtermFormula() {
        let palette = GhosttyTheme.ansi256Palette(explicit: [:])
        XCTAssertEqual(palette.count, 256)
        // 0..15: xterm 標準 16 色 (代表: 黒・赤・白)
        XCTAssertEqual(palette[0], color8(0, 0, 0))
        XCTAssertEqual(palette[1], color8(205, 0, 0))
        XCTAssertEqual(palette[15], color8(255, 255, 255))
        // 16..231: 6x6x6 キューブ (成分 [0,95,135,175,215,255])
        XCTAssertEqual(palette[16], color8(0, 0, 0))       // i=0
        XCTAssertEqual(palette[21], color8(0, 0, 255))     // i=5 純青
        XCTAssertEqual(palette[231], color8(255, 255, 255)) // i=215 純白
        // 232..255: グレースケール (8+10*i)
        XCTAssertEqual(palette[232], color8(8, 8, 8))
        XCTAssertEqual(palette[255], color8(238, 238, 238))
    }

    func testAnsi256PaletteAppliesExplicitOverridesAnywhere() {
        let palette = GhosttyTheme.ansi256Palette(explicit: [
            0: color8(0x12, 0x34, 0x56),    // ANSI 0..15 の上書き
            16: color8(0xff, 0xff, 0xff),   // キューブ領域の上書き
            232: color8(0x11, 0x22, 0x33),  // グレースケール領域の上書き
        ])
        XCTAssertEqual(palette[0], color8(0x12, 0x34, 0x56))
        XCTAssertEqual(palette[16], color8(0xff, 0xff, 0xff))
        XCTAssertEqual(palette[232], color8(0x11, 0x22, 0x33))
        // 上書きしていない位置は標準式のまま
        XCTAssertEqual(palette[21], color8(0, 0, 255))
    }

    // MARK: - 後勝ち / 累積

    func testLastWinsForScalarsAndAccumulatesPalette() {
        let (theme, _) = GhosttyTheme.parse(configText: """
        background = #111111
        background = #222222
        palette = 0=#aaaaaa
        palette = 1=#bbbbbb
        palette = 0=#cccccc
        """)
        // スカラーは後勝ち
        XCTAssertEqual(theme.background, color8(0x22, 0x22, 0x22))
        // palette は累積、同 index は後勝ち
        XCTAssertEqual(theme.palette[0], color8(0xcc, 0xcc, 0xcc))
        XCTAssertEqual(theme.palette[1], color8(0xbb, 0xbb, 0xbb))
    }

    // MARK: - theme 解決 + 優先順位

    func testResolvesNamedThemeFromDirectory() throws {
        let themesDir = try makeTempDirectory()
        try """
        background = #303446
        foreground = #c6d0f5
        palette = 0=#51576d
        """.write(to: themesDir.appendingPathComponent("MyTheme"), atomically: true, encoding: .utf8)

        let theme = GhosttyTheme.resolve(
            configText: "theme = MyTheme",
            themesDirectories: [themesDir.path],
            prefersDark: true
        )
        XCTAssertEqual(theme.background, color8(0x30, 0x34, 0x46))
        XCTAssertEqual(theme.foreground, color8(0xc6, 0xd0, 0xf5))
        XCTAssertEqual(theme.palette[0], color8(0x51, 0x57, 0x6d))
    }

    func testUserConfigOverridesTheme() throws {
        let themesDir = try makeTempDirectory()
        try """
        background = #000000
        foreground = #111111
        palette = 0=#aaaaaa
        """.write(to: themesDir.appendingPathComponent("Base"), atomically: true, encoding: .utf8)

        // config は theme を参照しつつ background と palette 0 を上書きする
        let theme = GhosttyTheme.resolve(
            configText: """
            theme = Base
            background = #ffffff
            palette = 0=#bbbbbb
            palette = 1=#cccccc
            """,
            themesDirectories: [themesDir.path],
            prefersDark: true
        )
        // config が theme を上書き
        XCTAssertEqual(theme.background, color8(0xff, 0xff, 0xff))
        // config が指定しない foreground は theme の値
        XCTAssertEqual(theme.foreground, color8(0x11, 0x11, 0x11))
        // palette: 同 index は config 優先、theme のみ/config のみは両方残る
        XCTAssertEqual(theme.palette[0], color8(0xbb, 0xbb, 0xbb))
        XCTAssertEqual(theme.palette[1], color8(0xcc, 0xcc, 0xcc))
    }

    func testResolvesThemeByAbsolutePath() throws {
        let dir = try makeTempDirectory()
        let themePath = dir.appendingPathComponent("custom.theme")
        try "background = #abcdef".write(to: themePath, atomically: true, encoding: .utf8)

        let theme = GhosttyTheme.resolve(
            configText: "theme = \(themePath.path)",
            themesDirectories: [],
            prefersDark: true
        )
        XCTAssertEqual(theme.background, color8(0xab, 0xcd, 0xef))
    }

    func testUnresolvableThemeLeavesConfigValues() {
        // theme が見つからなくても config 自身の指定は残る
        let theme = GhosttyTheme.resolve(
            configText: """
            theme = NonExistentTheme
            background = #123456
            """,
            themesDirectories: ["/nonexistent/dir"],
            prefersDark: true
        )
        XCTAssertEqual(theme.background, color8(0x12, 0x34, 0x56))
    }

    // MARK: - light/dark 記法

    func testSelectsThemeVariantByAppearance() {
        XCTAssertEqual(
            GhosttyTheme.selectThemeVariant("dark:Catppuccin Frappe,light:Catppuccin Latte", prefersDark: true),
            "Catppuccin Frappe"
        )
        XCTAssertEqual(
            GhosttyTheme.selectThemeVariant("dark:Catppuccin Frappe,light:Catppuccin Latte", prefersDark: false),
            "Catppuccin Latte"
        )
        // 記法でない単一名はそのまま
        XCTAssertEqual(GhosttyTheme.selectThemeVariant("Catppuccin Frappe", prefersDark: true), "Catppuccin Frappe")
    }

    // MARK: - load (ファイル入出力)

    func testLoadReturnsNilWhenConfigMissing() {
        XCTAssertNil(GhosttyTheme.load(
            configPath: "/definitely/not/here/config",
            themesDirectories: [],
            prefersDark: true
        ))
    }

    func testLoadReadsConfigFile() throws {
        let dir = try makeTempDirectory()
        let configPath = dir.appendingPathComponent("config")
        try "background = #010203".write(to: configPath, atomically: true, encoding: .utf8)

        let theme = GhosttyTheme.load(configPath: configPath.path, themesDirectories: [], prefersDark: true)
        XCTAssertEqual(theme?.background, color8(0x01, 0x02, 0x03))
    }

    // MARK: - font-family / font-style / font-size

    func testParsesFontKeys() {
        let (theme, _) = GhosttyTheme.parse(configText: """
        font-family = JetBrains Mono
        font-style = Bold
        font-size = 14
        """)
        XCTAssertEqual(theme.fontFamily, "JetBrains Mono")
        XCTAssertEqual(theme.fontStyle, "Bold")
        XCTAssertEqual(theme.fontSize, 14)
    }

    func testFontSizeParsesDecimal() {
        let (theme, _) = GhosttyTheme.parse(configText: "font-size = 13.5")
        XCTAssertEqual(theme.fontSize, 13.5)
    }

    func testFontKeysIgnoreEmptyAndInvalidValues() {
        let (theme, _) = GhosttyTheme.parse(configText: """
        font-family =
        font-style =
        font-size = not-a-number
        """)
        XCTAssertNil(theme.fontFamily)  // 空値は未設定扱い
        XCTAssertNil(theme.fontStyle)   // 空値は未設定扱い
        XCTAssertNil(theme.fontSize)    // 数値でない値は無視
    }

    func testFontKeysDefaultToNil() {
        let (theme, _) = GhosttyTheme.parse(configText: "background = #303446")
        XCTAssertNil(theme.fontFamily)
        XCTAssertNil(theme.fontStyle)
        XCTAssertNil(theme.fontSize)
    }

    func testConfigFontOverridesThemeFont() throws {
        // theme ファイルにフォントがあっても config 側が優先する (overlaid の font 経路)
        let themesDir = try makeTempDirectory()
        try "font-style = Regular\nfont-size = 10".write(
            to: themesDir.appendingPathComponent("FontTheme"), atomically: true, encoding: .utf8)
        let theme = GhosttyTheme.resolve(
            configText: """
            theme = FontTheme
            font-style = Bold
            font-size = 20
            """,
            themesDirectories: [themesDir.path],
            prefersDark: true
        )
        XCTAssertEqual(theme.fontStyle, "Bold")
        XCTAssertEqual(theme.fontSize, 20)
    }

    // MARK: - SwiftTerm への適用

    func testApplyMapsColorsToTerminalView() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let (theme, _) = GhosttyTheme.parse(configText: """
        background = #303446
        foreground = #c6d0f5
        cursor-color = #f2d5cf
        selection-background = #626880
        palette = 0=#51576d
        """)
        theme.apply(to: view)

        assertDeviceRGB(view.nativeBackgroundColor, equals: (0x30, 0x34, 0x46))
        assertDeviceRGB(view.nativeForegroundColor, equals: (0xc6, 0xd0, 0xf5))
        assertDeviceRGB(view.caretColor, equals: (0xf2, 0xd5, 0xcf))
        assertDeviceRGB(view.selectedTextBackgroundColor, equals: (0x62, 0x68, 0x80))
        // palette を install した場合、16..255 を Ghostty と一致させるため xterm 戦略に固定される
        XCTAssertEqual(view.getTerminal().options.ansi256PaletteStrategy, .xterm)
    }

    func testApplyOnlyTouchesSpecifiedItems() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let baseline = view.nativeForegroundColor
        // background だけ指定したテーマ
        let (theme, _) = GhosttyTheme.parse(configText: "background = #123456")
        theme.apply(to: view)
        assertDeviceRGB(view.nativeBackgroundColor, equals: (0x12, 0x34, 0x56))
        // foreground は触られていない
        XCTAssertEqual(view.nativeForegroundColor, baseline)
    }

    func testApplyForcesXtermStrategyWithoutPalette() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        // palette を持たない (background/foreground だけの) 最小構成のテーマ
        let (theme, _) = GhosttyTheme.parse(configText: """
        background = #303446
        foreground = #c6d0f5
        """)
        theme.apply(to: view)
        // palette の有無に関わらず 16..255 を Ghostty と同じ xterm 標準生成に固定する
        XCTAssertEqual(view.getTerminal().options.ansi256PaletteStrategy, .xterm)
    }

    /// NSColor を deviceRGB に変換して 8bit 成分が期待値と一致するか検証する。
    private func assertDeviceRGB(_ color: NSColor, equals expected: (Int, Int, Int),
                                 file: StaticString = #filePath, line: UInt = #line) {
        guard let rgb = color.usingColorSpace(.deviceRGB) else {
            return XCTFail("deviceRGB へ変換できない: \(color)", file: file, line: line)
        }
        XCTAssertEqual(Int((rgb.redComponent * 255).rounded()), expected.0, file: file, line: line)
        XCTAssertEqual(Int((rgb.greenComponent * 255).rounded()), expected.1, file: file, line: line)
        XCTAssertEqual(Int((rgb.blueComponent * 255).rounded()), expected.2, file: file, line: line)
    }
}
