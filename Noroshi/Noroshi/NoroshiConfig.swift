import Foundation

/// Noroshi 独自設定ファイル (`~/.config/noroshi/config`) のパス解決と入出力を集約する。
/// ファイル形式は Ghostty config 互換の `key = value` で、パースは GhosttyTheme に委ねる (documents/adr/0004 参照)。
/// テーマ探索は noroshi → ghostty → Ghostty.app 同梱の順。
/// 既存ユーザー (ghostty のみ) の挙動を壊さないため、noroshi config が無ければ ghostty config にフォールバックする。
enum NoroshiConfig {
    /// XDG_CONFIG_HOME (未設定なら `~/.config`) を基点とした設定ディレクトリの親。
    static func configHome() -> String {
        ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? (NSHomeDirectory() + "/.config")
    }

    /// Noroshi 独自 config のパス。書き戻し先はここに固定する。
    static func noroshiConfigPath() -> String { configHome() + "/noroshi/config" }

    /// フォールバック先の Ghostty config のパス。
    static func ghosttyConfigPath() -> String { configHome() + "/ghostty/config" }

    /// テーマ名解決の探索ディレクトリ (優先順)。noroshi → ghostty → Ghostty.app 同梱。
    static func themesDirectories() -> [String] {
        [configHome() + "/noroshi/themes",
         configHome() + "/ghostty/themes",
         "/Applications/Ghostty.app/Contents/Resources/ghostty/themes"]
    }

    /// 実際に読む config パスを決める。noroshi config が存在すればそれ、無ければ ghostty config。
    /// fileExists を注入可能にして、実ファイルシステムに依存せずテストで純粋に検証できるようにする。
    static func preferredConfigPath(
        noroshiConfigPath: String,
        ghosttyConfigPath: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        fileExists(noroshiConfigPath) ? noroshiConfigPath : ghosttyConfigPath
    }

    /// 既定の読み込み対象 config パス (上の優先順位を実ファイルシステムで解決)。
    static func resolvedConfigPath() -> String {
        preferredConfigPath(noroshiConfigPath: noroshiConfigPath(), ghosttyConfigPath: ghosttyConfigPath())
    }

    /// 設定ウィンドウの表示・書き戻しの起点にする現在のテキストを読む。
    /// noroshi config が無い既存ユーザーでも配色を失わないよう、優先パス (noroshi 優先・無ければ ghostty) の
    /// 内容を種にする。書き戻し先は常に noroshi config なので、最初の編集で ghostty の内容が noroshi に引き継がれる。
    /// 読めない場合は空文字。
    static func readPreferredConfigText() -> String {
        (try? String(contentsOf: URL(fileURLWithPath: resolvedConfigPath()), encoding: .utf8)) ?? ""
    }

    /// noroshi config へテキストを書き込む。親ディレクトリが無ければ作成する (冪等)。
    static func writeConfigText(_ text: String) throws {
        let path = noroshiConfigPath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    /// 探索ディレクトリから見つかるテーマファイル名の一覧 (重複除去・ソート)。設定ウィンドウのテーマ Picker 用。
    /// ディレクトリが無ければスキップする。隠しファイルは除外する。
    static func availableThemeNames() -> [String] {
        var names = Set<String>()
        for dir in themesDirectories() {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where !entry.hasPrefix(".") {
                names.insert(entry)
            }
        }
        return names.sorted()
    }
}
