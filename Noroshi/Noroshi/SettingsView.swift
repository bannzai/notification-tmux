import AppKit
import Combine
import SwiftTerm
import SwiftUI

/// Cmd+, で開く設定ウィンドウ。フォント・テーマ・色を調整し、変更を即時に
/// `~/.config/noroshi/config` へ書き戻して terminal に反映する (issue #9)。
/// SwiftUI の `Settings` シーンに載せると Cmd+, が自動でバインドされる。
struct SettingsView: View {
    @StateObject private var model = SettingsModel()

    var body: some View {
        Form {
            Section("フォント") {
                // 先頭に「システム既定」(= font-family 未設定) を置く。
                Picker("フォントファミリ", selection: Binding(
                    get: { model.fontFamily },
                    set: { model.setFontFamily($0) }
                )) {
                    Text("システム既定").tag(SettingsModel.unsetFontFamily)
                    ForEach(model.fontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                Picker("文字の太さ", selection: Binding(
                    get: { model.fontStyle },
                    set: { model.setFontStyle($0) }
                )) {
                    Text("フォント既定").tag(SettingsModel.unsetFontStyle)
                    ForEach(SettingsModel.fontStyleOptions, id: \.self) { style in
                        Text(style).tag(style)
                    }
                }
                Stepper(value: Binding(
                    get: { model.fontSize },
                    set: { model.setFontSize($0) }
                ), in: SettingsModel.fontSizeRange, step: 1) {
                    Text("フォントサイズ: \(Int(model.fontSize)) pt")
                }
            }

            Section("テーマ") {
                // 先頭に「未設定」(= theme 未設定) を置く。
                Picker("テーマ", selection: Binding(
                    get: { model.themeName },
                    set: { model.setTheme($0) }
                )) {
                    Text("未設定").tag(SettingsModel.unsetTheme)
                    ForEach(model.themeNames, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
            }

            Section("色") {
                ColorPicker("背景", selection: Binding(
                    get: { model.background }, set: { model.setColor(.background, $0) }))
                ColorPicker("文字", selection: Binding(
                    get: { model.foreground }, set: { model.setColor(.foreground, $0) }))
                ColorPicker("カーソル", selection: Binding(
                    get: { model.cursorColor }, set: { model.setColor(.cursorColor, $0) }))
                ColorPicker("選択範囲", selection: Binding(
                    get: { model.selectionBackground }, set: { model.setColor(.selectionBackground, $0) }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 400)
    }
}

/// 設定ウィンドウの状態と書き戻しを担うモデル。
/// 起点テキストは優先 config (noroshi 優先・無ければ ghostty) を種にし、書き戻し先は常に noroshi config。
/// これにより noroshi config を持たない既存ユーザーでも、最初の編集で ghostty の内容を失わない。
@MainActor
final class SettingsModel: ObservableObject {
    /// 設定できる色キー。config のキー名と対応させる。
    enum ColorKey {
        case background, foreground, cursorColor, selectionBackground

        var configKey: String {
            switch self {
            case .background: return "background"
            case .foreground: return "foreground"
            case .cursorColor: return "cursor-color"
            case .selectionBackground: return "selection-background"
            }
        }
    }

    /// フォントファミリ。空文字 = システム既定 (font-family 未設定)。
    @Published var fontFamily: String
    /// 通常文字のフォントスタイル。空文字 = フォント既定 (font-style 未設定)。
    @Published var fontStyle: String
    /// フォントサイズ (pt)。未設定時は既定サイズを表示する。
    @Published var fontSize: Double
    /// テーマ名。空文字 = 未設定。
    @Published var themeName: String
    /// 現在の解決済み配色。ColorPicker の初期表示と、テーマ変更後の更新に使う。
    /// SwiftTerm も `Color` を定義するため、UI 側の色は SwiftUI.Color で明示する。
    @Published var background: SwiftUI.Color
    @Published var foreground: SwiftUI.Color
    @Published var cursorColor: SwiftUI.Color
    @Published var selectionBackground: SwiftUI.Color

    /// フォント Picker の候補 (実在ファミリ)。
    let fontFamilies: [String]
    /// テーマ Picker の候補 (探索で見つかったテーマ名)。
    let themeNames: [String]

    /// 未設定を表すセンチネル値。
    static let unsetFontFamily = ""
    static let unsetFontStyle = ""
    static let unsetTheme = ""
    static let fontStyleOptions = ["Regular", "Medium", "Semibold", "Bold"]
    /// font-size 未設定時に表示する既定サイズ (SwiftTerm の既定 = システムフォントサイズ)。
    static let defaultFontSize = Double(NSFont.systemFontSize)
    /// Stepper の範囲。
    static let fontSizeRange = 8.0...32.0

    /// 書き戻しの working buffer (config ファイルの現在テキスト)。
    private var configText: String

    init() {
        let text = NoroshiConfig.readPreferredConfigText()
        configText = text
        let (configTheme, themeRef) = GhosttyTheme.parse(configText: text)
        let resolved = GhosttyTheme.resolve(
            configText: text,
            themesDirectories: NoroshiConfig.themesDirectories(),
            prefersDark: Self.systemPrefersDark()
        )
        fontFamily = configTheme.fontFamily ?? Self.unsetFontFamily
        fontStyle = configTheme.fontStyle ?? Self.unsetFontStyle
        fontSize = configTheme.fontSize ?? Self.defaultFontSize
        themeName = themeRef ?? Self.unsetTheme
        background = Self.color(resolved.background) ?? .black
        foreground = Self.color(resolved.foreground) ?? .white
        cursorColor = Self.color(resolved.cursorColor) ?? .white
        selectionBackground = Self.color(resolved.selectionBackground) ?? .gray
        fontFamilies = NSFontManager.shared.availableFontFamilies
        themeNames = NoroshiConfig.availableThemeNames()
    }

    // MARK: - 変更の書き戻し

    /// フォントファミリを変更する。空文字 (システム既定) を選んだら font-family キーを削除する。
    func setFontFamily(_ new: String) {
        fontFamily = new
        if new.isEmpty {
            write(set: [:], remove: ["font-family"])
        } else {
            write(set: ["font-family": new], remove: [])
        }
    }

    /// 通常文字の太さを変更する。フォント既定を選んだら font-style キーを削除する。
    func setFontStyle(_ new: String) {
        fontStyle = new
        if new.isEmpty {
            write(set: [:], remove: ["font-style"])
        } else {
            write(set: ["font-style": new], remove: [])
        }
    }

    /// フォントサイズを変更する。%g で末尾ゼロを落とし、整数/小数を自然に書く。
    func setFontSize(_ new: Double) {
        fontSize = new
        write(set: ["font-size": String(format: "%g", new)], remove: [])
    }

    /// テーマを変更する。テーマを選んだら明示色 4 キーを削除する
    /// (config の明示色が theme を上書きし混乱を招くため)。未設定を選んだら theme キーを削除する。
    func setTheme(_ new: String) {
        themeName = new
        if new.isEmpty {
            write(set: [:], remove: ["theme"])
        } else {
            write(set: ["theme": new],
                  remove: ["background", "foreground", "cursor-color", "selection-background"])
        }
        refreshResolvedColors()
    }

    /// 個別の色を変更する。theme は残し、その色キーだけを上書きする。
    func setColor(_ key: ColorKey, _ color: SwiftUI.Color) {
        switch key {
        case .background: background = color
        case .foreground: foreground = color
        case .cursorColor: cursorColor = color
        case .selectionBackground: selectionBackground = color
        }
        write(set: [key.configKey: Self.hex(color)], remove: [])
    }

    // MARK: - 内部

    /// working buffer を更新して noroshi config へ書き込み、terminal に再適用する。
    private func write(set: [String: String], remove: Set<String>) {
        configText = NoroshiConfigEditor.apply(to: configText, set: set, remove: remove)
        do {
            try NoroshiConfig.writeConfigText(configText)
            TerminalSessionManager.shared.reloadTheme()
            PlainTerminalManager.shared.reloadTheme()
        } catch {
            // 書き込み失敗は致命的ではない (次回操作で再試行される)。ログのみ残す。
            NSLog("noroshi: 設定の書き込みに失敗: \(error)")
        }
    }

    /// テーマ変更後、解決済みの配色を ColorPicker に反映する。
    /// programmatic な代入なので Binding の set は呼ばれず、書き戻しのループは起きない。
    private func refreshResolvedColors() {
        let resolved = GhosttyTheme.resolve(
            configText: configText,
            themesDirectories: NoroshiConfig.themesDirectories(),
            prefersDark: Self.systemPrefersDark()
        )
        background = Self.color(resolved.background) ?? background
        foreground = Self.color(resolved.foreground) ?? foreground
        cursorColor = Self.color(resolved.cursorColor) ?? cursorColor
        selectionBackground = Self.color(resolved.selectionBackground) ?? selectionBackground
    }

    /// システムの外観がダークかどうか。theme の light/dark 記法の選択に使う。
    private static func systemPrefersDark() -> Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// SwiftTerm.Color (16bit 成分) を SwiftUI.Color にする。GhosttyTheme.nsColor と同じ deviceRGB 換算。
    private static func color(_ color: SwiftTerm.Color?) -> SwiftUI.Color? {
        guard let color else { return nil }
        return SwiftUI.Color(nsColor: NSColor(
            deviceRed: CGFloat(color.red) / 65535.0,
            green: CGFloat(color.green) / 65535.0,
            blue: CGFloat(color.blue) / 65535.0,
            alpha: 1.0))
    }

    /// SwiftUI.Color を Ghostty 形式の `#rrggbb` にする。deviceRGB に変換して 8bit 成分を書き出す。
    private static func hex(_ color: SwiftUI.Color) -> String {
        let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.black
        let red = Int((ns.redComponent * 255).rounded())
        let green = Int((ns.greenComponent * 255).rounded())
        let blue = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02x%02x%02x", red, green, blue)
    }
}
