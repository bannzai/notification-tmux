import Foundation

/// tmux の 1 window。サイドバーの行 1 つに対応する。
struct TmuxWindow: Identifiable, Equatable, Hashable {
    /// tmux の window_id (例 "@42")。サーバ全体でユニークかつ改名・並べ替えに影響されない SSOT。
    let id: String
    /// この window が属する session 名。
    let sessionName: String
    /// session 内での window index。表示順に使う。
    let index: Int
    /// window 名。
    let name: String
    /// その session のカレント window かどうか。
    let isActive: Bool
    /// window 内の pane 数。
    let paneCount: Int
}

/// tmux の 1 session。cmux でいう workspace に対応する。
struct TmuxSession: Identifiable, Equatable, Hashable {
    /// session 名。tmux 上で一意なのでそのまま識別子にする。
    let id: String
    /// この session に attach しているクライアント数。
    let attachedClients: Int
    /// session 配下の window (index 昇順)。
    var windows: [TmuxWindow]

    /// 表示用の session 名。
    var name: String { id }
}

/// tmux のフォーマット文字列と、その出力のパーサ。
enum TmuxFormat {
    /// フィールド区切り。window 名等に混入し得ない ASCII Unit Separator。
    static let fieldSeparator: Character = "\u{1f}"

    /// `list-windows -a -F` 用。window_flags は合成文字列 (`*!Z` 等) でパースが不安定なため個別の bool 変数を列挙する。
    static let windowFormat = "#{session_name}\u{1f}#{window_id}\u{1f}#{window_index}\u{1f}#{window_name}\u{1f}#{window_active}\u{1f}#{window_panes}"
    /// `list-sessions -F` 用。
    static let sessionFormat = "#{session_name}\u{1f}#{session_attached}"

    /// `windowFormat` で出力された 1 行を TmuxWindow にする。形式が合わない行は nil。
    static func parseWindowLine(_ line: String) -> TmuxWindow? {
        let parts = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6,
              parts[1].hasPrefix("@"),
              let index = Int(parts[2]),
              let panes = Int(parts[5]) else { return nil }
        return TmuxWindow(id: parts[1], sessionName: parts[0], index: index,
                          name: parts[3], isActive: parts[4] == "1", paneCount: panes)
    }

    /// `sessionFormat` で出力された 1 行を (session 名, attach クライアント数) にする。形式が合わない行は nil。
    static func parseSessionLine(_ line: String) -> (name: String, attached: Int)? {
        let parts = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let attached = Int(parts[1]) else { return nil }
        return (parts[0], attached)
    }
}

/// Claude Code の Stop hook から `ntmux://stop?session=<name>&window=@n` で届く通知イベント。
struct StopEvent: Equatable {
    /// 発火元 tmux session 名。
    let sessionName: String
    /// 発火元 tmux window の window_id (@n)。
    let windowID: String

    // URL スキーム経由の入力だけを受け付けるバリデーションのため failable init にしている
    init?(url: URL) {
        guard url.scheme == "ntmux",
              url.host == "stop",
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let session = queryItems.first(where: { $0.name == "session" })?.value,
              let window = queryItems.first(where: { $0.name == "window" })?.value,
              !session.isEmpty,
              window.hasPrefix("@")
        else { return nil }
        sessionName = session
        windowID = window
    }
}
