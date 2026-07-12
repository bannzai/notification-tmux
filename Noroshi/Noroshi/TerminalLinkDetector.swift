import Foundation

/// クリックされた位置のテキストから開くべきリンクを判定した結果。
/// 存在確認・実際の open は副作用のため呼び出し側 (TerminalSessionManager) が行い、
/// ここでは純粋な検出・パス解決だけを担う。
enum TerminalLink: Equatable {
    /// http / https の URL。デフォルトブラウザで開く対象。
    case url(URL)
    /// ファイルパス候補 (末尾約物を除去済みの生トークン)。resolvePath で絶対パスへ解決し、存在確認してから開く。
    case path(String)
}

/// ターミナル表示テキストからクリック位置のリンク (URL / ファイルパス) を検出する純粋ロジックの名前空間。
/// UI・実 tmux・ファイルシステムに一切依存しない。折返し行の結合ヒューリスティックとパス解決の純粋部分もここに置く。
enum TerminalLinkDetector {
    /// 末尾から取り除く約物。URL・パスが括弧書き・文末にある場合に混入する記号を落とす。
    private static let trailingPunctuation: Set<Character> = [")", "]", ".", ",", ">", "\"", "'", ";"]

    /// 折返し行を結合して論理行を組み立て、クリック位置の論理列を求める。
    /// rowTexts[i] は画面行 i のテキスト、filledToEdge[i] は行 i の次行 (i+1) が同じ論理行の折返し継続かを表す
    /// (呼び出し側が実 wrap 情報を渡す。名前は歴史的経緯で filledToEdge のまま)。継続とみなした境界を clickRow から
    /// 上下へ結合する (結合は可視画面内に限定)。clickColumnInRow は rowTexts[clickRow] 内のクリック文字オフセット。範囲外の clickRow では nil。
    static func logicalLine(
        rowTexts: [String],
        filledToEdge: [Bool],
        clickRow: Int,
        clickColumnInRow: Int
    ) -> (text: String, column: Int)? {
        guard rowTexts.indices.contains(clickRow), filledToEdge.count == rowTexts.count else { return nil }
        // クリック行単体でクリック位置のトークンが行端に接する方向にだけ結合を広げる。行の途中に収まるトークンは
        // 折返しの継続になり得ないため、桁数不一致で隣接行が誤って右端まで詰まって見える時に無関係な隣接行と結合する露出を抑える。
        let anchors = tokenEdgeAnchors(in: rowTexts[clickRow], column: clickColumnInRow, rowFilledToEdge: filledToEdge[clickRow])
        var start = clickRow
        while anchors.left, start > 0, filledToEdge[start - 1] { start -= 1 }
        var end = clickRow
        while anchors.right, end < rowTexts.count - 1, filledToEdge[end] { end += 1 }
        return (
            rowTexts[start...end].joined(),
            rowTexts[start..<clickRow].reduce(0) { $0 + $1.count } + clickColumnInRow
        )
    }

    /// クリック行内のクリック位置のトークンが行端に接しているか。
    /// left = 先頭 (列 0) から始まる (上方向の折返し継続になり得る)、right = 末尾まで達しかつ行が右端まで充填 (下方向へ継続し得る)。
    /// どちらにも接さない (行の途中に収まる) トークンは折返し結合の対象外とする。
    private static func tokenEdgeAnchors(in rowText: String, column: Int, rowFilledToEdge: Bool) -> (left: Bool, right: Bool) {
        let characters = Array(rowText)
        var index = 0
        while index < characters.count {
            guard !characters[index].isWhitespace else { index += 1; continue }
            let tokenStart = index
            while index < characters.count, !characters[index].isWhitespace { index += 1 }
            guard tokenStart <= column, column < index else { continue }
            return (tokenStart == 0, index == characters.count && rowFilledToEdge)
        }
        return (false, false)
    }

    /// 論理行テキストとクリック文字列 (column) から、その列を範囲に含むリンクを検出する。
    /// 空白区切りトークンのうち column を含むものを分類し、URL 判定をパス判定より優先する。リンクでなければ nil。
    static func detectLink(logicalLine: String, column: Int) -> TerminalLink? {
        let characters = Array(logicalLine)
        var index = 0
        while index < characters.count {
            guard !characters[index].isWhitespace else { index += 1; continue }
            let tokenStart = index
            while index < characters.count, !characters[index].isWhitespace { index += 1 }
            guard tokenStart <= column, column < index else { continue }
            return classify(String(characters[tokenStart..<index]), clickOffsetInToken: column - tokenStart)
        }
        return nil
    }

    /// パス候補が基準ディレクトリ (アクティブ pane のカレントパス) を必要とする相対パスか。
    /// 絶対パス (`/`) と `~` 展開は基準不要なので false。相対パス検出時だけ tmux 照会を発生させる判定に使う。
    static func requiresBaseDirectory(_ path: String) -> Bool {
        !(path.hasPrefix("/") || path.hasPrefix("~"))
    }

    /// パス候補を絶対パスへ解決する純粋関数。存在確認はしない。
    /// 絶対パスはそのまま、`~` は homeDirectory へ展開、相対パスは baseDirectory 基準で解決し `.`/`..` を正規化する。
    /// 相対パスなのに baseDirectory が nil の場合は解決できず nil を返す。
    static func resolvePath(_ path: String, homeDirectory: String, baseDirectory: String?) -> String? {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        if path == "~" {
            return homeDirectory
        }
        if path.hasPrefix("~/") {
            return URL(fileURLWithPath: homeDirectory + String(path.dropFirst(1))).standardizedFileURL.path
        }
        guard let baseDirectory else { return nil }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: baseDirectory, isDirectory: true))
            .standardizedFileURL.path
    }

    /// 単一トークンを URL / パス / 非リンクに分類する。`://` を持つトークンは URL 扱いとし、http/https 以外はパスへ落とさず対象外にする (URL 優先)。
    /// clickOffsetInToken はトークン先頭からのクリック文字オフセットで、URL はその部分文字列上をクリックした時だけ対象にする。
    private static func classify(_ token: String, clickOffsetInToken: Int) -> TerminalLink? {
        if let separator = token.range(of: "://") {
            var schemeStart = separator.lowerBound
            while schemeStart > token.startIndex,
                  isSchemeCharacter(token[token.index(before: schemeStart)]) {
                schemeStart = token.index(before: schemeStart)
            }
            let scheme = token[schemeStart..<separator.lowerBound]
            let candidate = stripTrailingPunctuation(String(token[schemeStart...]))
            guard scheme == "http" || scheme == "https",
                  // 折返し誤結合で生じる糊付きトークン (例 https://examphttps://example.com) を拒否する。
                  // 正規 URL に生の :// が2度現れることは実質なく (query は percent-encode される)、scheme 区切りの :// は1つだけ。
                  candidate.components(separatedBy: "://").count == 2,
                  clickOffsetInToken >= token.distance(from: token.startIndex, to: schemeStart),
                  clickOffsetInToken < token.distance(from: token.startIndex, to: schemeStart) + candidate.count,
                  let url = URL(string: candidate),
                  url.host?.isEmpty == false
            else { return nil }
            return .url(url)
        }
        let path = stripTrailingPunctuation(token)
        guard path.hasPrefix("/") || path.hasPrefix("~") || path.contains("/") else { return nil }
        return .path(path)
    }

    /// URL スキーム名を構成しうる文字か (RFC 3986 の scheme 文字集合)。`://` 直前のスキーム範囲を後方走査で切り出すのに使う。
    private static func isSchemeCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "+" || character == "-" || character == "."
    }

    /// トークン末尾の約物 (trailingPunctuation) を連続する限り取り除く。
    private static func stripTrailingPunctuation(_ token: String) -> String {
        var end = token.endIndex
        while end > token.startIndex, trailingPunctuation.contains(token[token.index(before: end)]) {
            end = token.index(before: end)
        }
        return String(token[..<end])
    }
}
