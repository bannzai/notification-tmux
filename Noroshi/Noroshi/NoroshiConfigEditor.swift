import Foundation

/// Noroshi config (`key = value` テキスト) の書き戻しを行う純粋・テスト可能なエディタ。
/// 元テキストに対して {設定するキー: 値} と {削除するキー} を適用し、新テキストを返す。
///
/// 意味論:
/// - 既存の `key = value` 行はその位置で置換する。同一キーが複数行あれば最初を置換し、残りは削除する。
/// - 元テキストに無い設定キーは末尾に追記する (順序はソートで決定的にし、冪等性を保つ)。
/// - 削除キーは全出現を落とす。
/// - コメント行 (`#`)・空行・`=` を含まない行・設定/削除対象でないキー (palette 等) はそのまま保持する。
/// - 冪等: 同じ入力 (元テキスト・set・remove) なら常に同じ出力になる。
enum NoroshiConfigEditor {
    /// 元テキストにキーの設定・削除を適用した新テキストを返す。
    /// 出力は非空なら末尾を単一改行に正規化する (config ファイルの慣習に合わせる)。
    static func apply(to text: String, set: [String: String], remove: Set<String>) -> String {
        // 末尾改行を 1 つだけ剥がして行配列にする (再結合時に付け直す)。空テキストは空配列。
        var lines: [String]
        if text.isEmpty {
            lines = []
        } else {
            lines = text.components(separatedBy: "\n")
            if text.hasSuffix("\n") { lines.removeLast() }
        }

        var placed = Set<String>()   // set のうち、本文中で既に置換済みのキー
        var result: [String] = []
        for line in lines {
            guard let key = lineKey(line) else {
                result.append(line)   // コメント・空行・`=` 無し行はそのまま
                continue
            }
            if remove.contains(key) {
                continue              // 削除対象は全出現を落とす
            }
            if let value = set[key] {
                if placed.contains(key) { continue }  // 同一キーの 2 回目以降は落とす (最初だけ残す)
                placed.insert(key)
                result.append("\(key) = \(value)")
            } else {
                result.append(line)   // 設定・削除対象でないキー行はそのまま
            }
        }

        // 本文に無かった設定キーを末尾に追記する。順序はソートで決定的にして冪等性を保つ。
        for key in set.keys.sorted() where !placed.contains(key) {
            result.append("\(key) = \(set[key]!)")
        }

        let joined = result.joined(separator: "\n")
        return joined.isEmpty ? joined : joined + "\n"
    }

    /// 行のキーを返す。空行・`#` コメント・`=` を含まない行は nil (GhosttyTheme.parseLine と同じ意味論)。
    private static func lineKey(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let equalIndex = trimmed.firstIndex(of: "=") else {
            return nil
        }
        let key = trimmed[..<equalIndex].trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : key
    }
}
