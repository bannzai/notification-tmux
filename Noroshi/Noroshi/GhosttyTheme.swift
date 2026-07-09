import AppKit
import SwiftTerm

/// Ghostty の設定ファイル (`~/.config/ghostty/config` と参照先 theme) をパースして得た配色。
/// SwiftTerm の TerminalView に流し込むことで cmux/Ghostty と同じ見た目を再現する。
/// 各スカラー色は未指定なら nil で、apply では指定された項目だけを適用する (部分適用)。
struct GhosttyTheme {
    /// 背景色 (`background`)。
    let background: SwiftTerm.Color?
    /// 前景色 (`foreground`、文字色)。
    let foreground: SwiftTerm.Color?
    /// カーソル色 (`cursor-color`)。
    let cursorColor: SwiftTerm.Color?
    /// 選択範囲の背景色 (`selection-background`)。
    let selectionBackground: SwiftTerm.Color?
    /// 選択範囲の前景色 (`selection-foreground`)。SwiftTerm 1.13.0 に対応 API が無いため保持のみで apply では使わない。
    let selectionForeground: SwiftTerm.Color?
    /// 明示指定された palette エントリ (index 0..255 -> 色)。未指定 index は `ansi256Palette` が標準式で補完する。
    let palette: [Int: SwiftTerm.Color]
    /// フォントファミリ (`font-family`)。config レベルで読む (theme ファイル内対応は不要)。未指定なら nil。
    let fontFamily: String?
    /// フォントサイズ (`font-size`、pt)。未指定なら nil。
    let fontSize: Double?

    // MARK: - Public API

    /// 既定 config (noroshi config を優先し、無ければ ghostty config にフォールバック) を起点にテーマを解決する。
    /// config が無い・読めない場合は nil。パス解決は NoroshiConfig に集約している。
    static func load() -> GhosttyTheme? {
        load(configPath: NoroshiConfig.resolvedConfigPath(),
             themesDirectories: NoroshiConfig.themesDirectories(),
             prefersDark: systemPrefersDark())
    }

    /// SwiftTerm の TerminalView (実体は LocalProcessTerminalView) に色を適用する。
    /// nil の項目は触らないため、部分指定のテーマは指定された項目だけを反映する。
    func apply(to terminal: TerminalView) {
        // palette の有無に関わらず 16..255 を Ghostty と同じ xterm 標準生成に固定する。
        // 既定戦略の base16Lab は 16..255 を base16 から LAB 補間するため Ghostty と一致せず、
        // さらに base16Lab 下では bg/fg 設定のたびに 16..255 が LAB 再補間されて劣化する。
        // computed プロパティ経由で設定して即時 rebuild を起こす (options への直接代入では rebuild が走らない)。
        terminal.getTerminal().ansi256PaletteStrategy = .xterm
        if let background { terminal.nativeBackgroundColor = Self.nsColor(background) }
        if let foreground { terminal.nativeForegroundColor = Self.nsColor(foreground) }
        if let cursorColor { terminal.caretColor = Self.nsColor(cursorColor) }
        if let selectionBackground { terminal.selectedTextBackgroundColor = Self.nsColor(selectionBackground) }
        // selection-foreground は SwiftTerm 1.13.0 に対応 API が無いため適用しない (NOTES.md 参照)
        guard !palette.isEmpty else { return }
        // installColors は 16 色 (ANSI 0..15) を受け取り、上で固定した xterm 戦略で 16..255 を再生成する。
        terminal.installColors(Array(Self.ansi256Palette(explicit: palette).prefix(16)))
    }

    // MARK: - 解決 (config -> theme マージ)

    /// 任意のパスの config を読んで解決する。テスト・default 経路の共通実装。
    /// config を読めなければ nil。
    static func load(configPath: String, themesDirectories: [String], prefersDark: Bool) -> GhosttyTheme? {
        guard let configText = try? String(contentsOf: URL(fileURLWithPath: configPath), encoding: .utf8) else {
            return nil
        }
        return resolve(configText: configText, themesDirectories: themesDirectories, prefersDark: prefersDark)
    }

    /// config テキストを起点に theme を解決し、Ghostty の意味論でマージする。
    /// Ghostty は theme を先に読み、config 側の直接指定が theme を上書きする
    /// (出典: https://ghostty.org/docs/features/theme "Themes are loaded first and any conflicting options in the user configuration will override the theme")。
    static func resolve(configText: String, themesDirectories: [String], prefersDark: Bool) -> GhosttyTheme {
        let (configTheme, themeRef) = parse(configText: configText)
        guard let themeRef,
              let themeText = loadThemeText(ref: themeRef, themesDirectories: themesDirectories, prefersDark: prefersDark)
        else {
            return configTheme
        }
        // theme ファイル自身の theme 参照は辿らない (Ghostty の theme ファイルは他 theme を参照しない)
        return parse(configText: themeText).theme.overlaid(by: configTheme)
    }

    /// base の上に override を重ねる。override 側で指定された値が勝ち、palette は index 単位で override 優先の累積。
    func overlaid(by override: GhosttyTheme) -> GhosttyTheme {
        GhosttyTheme(
            background: override.background ?? background,
            foreground: override.foreground ?? foreground,
            cursorColor: override.cursorColor ?? cursorColor,
            selectionBackground: override.selectionBackground ?? selectionBackground,
            selectionForeground: override.selectionForeground ?? selectionForeground,
            palette: palette.merging(override.palette) { _, overrideColor in overrideColor },
            fontFamily: override.fontFamily ?? fontFamily,
            fontSize: override.fontSize ?? fontSize
        )
    }

    // MARK: - パース

    /// 設定テキストをパースして (テーマ, `theme` キーの値) を返す。
    /// 空行・`#` コメント・不正な行・未知キーは黙って無視する。同一スカラーキーは後勝ち、palette は index 単位で累積。
    static func parse(configText: String) -> (theme: GhosttyTheme, themeRef: String?) {
        var background, foreground, cursorColor, selectionBackground, selectionForeground: SwiftTerm.Color?
        var palette: [Int: SwiftTerm.Color] = [:]
        var fontFamily: String?
        var fontSize: Double?
        var themeRef: String?
        for rawLine in configText.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let (key, value) = parseLine(String(rawLine)) else { continue }
            switch key {
            case "theme": themeRef = value
            case "background": background = parseColor(value) ?? background
            case "foreground": foreground = parseColor(value) ?? foreground
            case "cursor-color": cursorColor = parseColor(value) ?? cursorColor
            case "selection-background": selectionBackground = parseColor(value) ?? selectionBackground
            case "selection-foreground": selectionForeground = parseColor(value) ?? selectionForeground
            case "palette":
                if let entry = parsePaletteEntry(value) { palette[entry.index] = entry.color }
            // font-family / font-size は Ghostty と同名キー。空値・非数値は未設定のまま無視する。
            case "font-family": if !value.isEmpty { fontFamily = value }
            case "font-size": if let size = Double(value) { fontSize = size }
            default: break
            }
        }
        return (GhosttyTheme(background: background, foreground: foreground, cursorColor: cursorColor,
                             selectionBackground: selectionBackground, selectionForeground: selectionForeground,
                             palette: palette, fontFamily: fontFamily, fontSize: fontSize),
                themeRef)
    }

    /// `key = value` 行を (key, value) にする。空行・`#` コメント・`=` を含まない行は nil。
    static func parseLine(_ line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equalIndex = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<equalIndex].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        return (key, String(trimmed[trimmed.index(after: equalIndex)...]).trimmingCharacters(in: .whitespaces))
    }

    /// `palette` の値 (`N=#rrggbb`、N は 0..255) を (index, 色) にする。範囲外・不正色は nil。
    static func parsePaletteEntry(_ value: String) -> (index: Int, color: SwiftTerm.Color)? {
        guard let equalIndex = value.firstIndex(of: "="),
              let index = Int(value[..<equalIndex].trimmingCharacters(in: .whitespaces)),
              (0...255).contains(index),
              let color = parseColor(String(value[value.index(after: equalIndex)...]))
        else {
            return nil
        }
        return (index, color)
    }

    /// Ghostty の色値 (`#rrggbb` または `rrggbb`) を SwiftTerm.Color にする。
    /// Ghostty は X11 名前色も許容するが本実装は未対応で、hex 以外は nil を返す (NOTES.md 参照)。
    static func parseColor(_ raw: String) -> SwiftTerm.Color? {
        var hex = raw.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return color8(Int((value >> 16) & 0xff), Int((value >> 8) & 0xff), Int(value & 0xff))
    }

    // MARK: - palette 256 色補完

    /// 明示 palette エントリを標準 xterm 256 色ベースに重ねた 256 要素の配列を返す。
    /// 0..15: xterm 標準 16 色 / 16..231: 6x6x6 カラーキューブ (成分 [0,95,135,175,215,255]) / 232..255: グレースケール (8+10*i)。
    /// 明示エントリ (index 0..255) は該当位置を上書きする。SwiftTerm へは先頭 16 色を渡し、16..255 は xterm 戦略で再生成される。
    static func ansi256Palette(explicit: [Int: SwiftTerm.Color]) -> [SwiftTerm.Color] {
        var colors = xtermBase16
        let cube = [0, 95, 135, 175, 215, 255]
        for i in 0..<216 {
            colors.append(color8(cube[(i / 36) % 6], cube[(i / 6) % 6], cube[i % 6]))
        }
        for i in 0..<24 {
            colors.append(color8(8 + i * 10, 8 + i * 10, 8 + i * 10))
        }
        for (index, color) in explicit where (0...255).contains(index) {
            colors[index] = color
        }
        return colors
    }

    // MARK: - theme ファイル解決

    /// theme 参照 (名前 or パス) をファイルに解決してテキストを読む。
    /// `/` を含む値はパス (先頭 `~` 展開) としてそのまま、名前なら themesDirectories を順に探す。見つからなければ nil。
    static func loadThemeText(ref: String, themesDirectories: [String], prefersDark: Bool) -> String? {
        let name = selectThemeVariant(ref, prefersDark: prefersDark)
        let candidates = name.contains("/")
            ? [(name as NSString).expandingTildeInPath]
            : themesDirectories.map { $0 + "/" + name }
        for path in candidates {
            if let text = try? String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8) {
                return text
            }
        }
        return nil
    }

    /// `dark:Foo,light:Bar` 記法から appearance に応じた名前を選ぶ。記法でなければそのまま返す。
    /// (出典: https://ghostty.org/docs/features/theme `theme = dark:...,light:...`)
    static func selectThemeVariant(_ raw: String, prefersDark: Bool) -> String {
        let wanted = prefersDark ? "dark:" : "light:"
        let fallback = prefersDark ? "light:" : "dark:"
        let parts = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let match = parts.first(where: { $0.hasPrefix(wanted) }) {
            return String(match.dropFirst(wanted.count))
        }
        if let match = parts.first(where: { $0.hasPrefix(fallback) }) {
            return String(match.dropFirst(fallback.count))
        }
        return raw.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 既定パス / 変換ヘルパ

    /// palette 0..15 の xterm 標準 16 色。theme が palette を指定しない index の既定値。
    private static let xtermBase16: [SwiftTerm.Color] = [
        color8(0, 0, 0), color8(205, 0, 0), color8(0, 205, 0), color8(205, 205, 0),
        color8(0, 0, 238), color8(205, 0, 205), color8(0, 205, 205), color8(229, 229, 229),
        color8(127, 127, 127), color8(255, 0, 0), color8(0, 255, 0), color8(255, 255, 0),
        color8(92, 92, 255), color8(255, 0, 255), color8(0, 255, 255), color8(255, 255, 255),
    ]

    /// システムの外観がダークかどうか。theme の light/dark 記法の選択に使う。
    private static func systemPrefersDark() -> Bool {
        NSApplication.shared.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// 8bit 成分 (0..255) を Ghostty と同じ *257 スケールで SwiftTerm.Color にする。
    private static func color8(_ red: Int, _ green: Int, _ blue: Int) -> SwiftTerm.Color {
        SwiftTerm.Color(red: UInt16(red) * 257, green: UInt16(green) * 257, blue: UInt16(blue) * 257)
    }

    /// SwiftTerm.Color (16bit 成分) を SwiftTerm 自身と同じ deviceRGB 換算で NSColor にする。
    private static func nsColor(_ color: SwiftTerm.Color) -> NSColor {
        NSColor(deviceRed: CGFloat(color.red) / 65535.0,
                green: CGFloat(color.green) / 65535.0,
                blue: CGFloat(color.blue) / 65535.0,
                alpha: 1.0)
    }
}
