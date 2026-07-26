import Foundation

/// Drag & Drop やファイル選択で受け取ったファイルパスを、terminal のプロンプトへ挿入する 1 行テキストへ変換する (issue #41)。
/// attach 先 pane の Claude Code などがそのまま引数・添付パスとして読める形にする。
enum TerminalFileDrop {
    /// クオート無しでシェルへ渡しても安全な文字の集合。
    /// POSIX シェルでエスケープ不要な英数字と、パスに常用される `/ . _ -` に限定する。
    /// これ以外 (空白・引用符・日本語など) を含むパスは単一引用符で包む。
    private static let shellSafeCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/._-")

    /// パス群をシェルエスケープして空白区切りで連結した挿入テキストを返す。
    /// 末尾にスペースを 1 つ付けるのは、続けてプロンプトを打てるようにし、
    /// 連続ドロップでパス同士が結合しないようにするため (iTerm2 のファイルドロップと同じ挙動)。
    /// 制御文字 (Unicode Cc) を含むパスは挿入対象から除外する。macOS のファイル名には制御文字が使え、
    /// 挿入テキストは PTY の行エディタがシェルのクオート解釈より先に制御バイトとして解釈するため、
    /// Ctrl-U + コマンド + 改行のようなファイル名がプロンプト消去やコマンド実行になるのをクオートでは防げない。
    static func insertionText(paths: [String]) -> String {
        let insertablePaths = paths.filter { path in
            !path.unicodeScalars.contains { $0.properties.generalCategory == .control }
        }
        guard !insertablePaths.isEmpty else { return "" }
        return insertablePaths.map(escape).joined(separator: " ") + " "
    }

    /// シェルとして安全な文字だけなら素通しし、それ以外を含むパスは単一引用符で包む。
    /// 単一引用符自体は `'\''` (引用終了 + エスケープした引用符 + 引用再開) に置き換える POSIX の定石を使う。
    private static func escape(path: String) -> String {
        guard path.unicodeScalars.contains(where: { !shellSafeCharacters.contains($0) }) else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
