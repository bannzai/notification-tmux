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
    /// session名を安全なswitch-client targetへ解決する`list-sessions -F`用。
    static let sessionIDFormat = "#{session_id}\u{1f}#{session_name}"
    /// `list-clients -F` 用。SwiftTerm の子 PID から Noroshi 自身の tmux client を特定する。
    static let clientFormat = "#{client_pid}\u{1f}#{client_tty}\u{1f}#{session_name}"

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

    /// `sessionIDFormat`で出力された1行を(session ID, session名)にする。形式が合わない行はnil。
    static func parseSessionIDLine(_ line: String) -> (id: String, name: String)? {
        let parts = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0].hasPrefix("$"), !parts[1].isEmpty else { return nil }
        return (parts[0], parts[1])
    }

    /// `clientFormat` で出力された 1 行を tmux client 情報にする。形式が合わない行は nil。
    static func parseClientLine(_ line: String) -> TmuxAttachedClient? {
        let parts = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3,
              let pid = Int32(parts[0]),
              !parts[1].isEmpty,
              !parts[2].isEmpty
        else { return nil }
        return TmuxAttachedClient(pid: pid, tty: parts[1], sessionName: parts[2])
    }
}

/// Claude Code の Stop hook から `noroshi://stop?session=<name>&window=@n` で届く通知イベント。
struct StopEvent: Equatable {
    /// 発火元 tmux session 名。
    let sessionName: String
    /// 発火元 tmux window の window_id (@n)。
    let windowID: String

    // URL スキーム経由の入力だけを受け付けるバリデーションのため failable init にしている
    init?(url: URL) {
        guard url.scheme == "noroshi",
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

    /// macOS 通知の userInfo から Stop イベントを復元する。
    init?(userInfo: [AnyHashable: Any]) {
        guard let session = userInfo["session"] as? String,
              let window = userInfo["window"] as? String,
              !session.isEmpty,
              window.hasPrefix("@")
        else { return nil }
        sessionName = session
        windowID = window
    }

    /// macOS 通知へ保存できる property list 形式の値。
    var userInfo: [String: String] {
        ["session": sessionName, "window": windowID]
    }
}

/// Noroshi が attach している tmux client。PID で SwiftTerm の子プロセスと対応付ける。
struct TmuxAttachedClient: Equatable {
    let pid: Int32
    let tty: String
    let sessionName: String
}

/// フォルダPickerから作るsession名を決定する純粋ロジック。
enum TmuxSessionNaming {
    /// フォルダ名を基準にし、既存名と重なる場合は `-2`, `-3` と連番を付ける。
    static func availableName(for directory: URL, existingNames: Set<String>) -> String {
        let directoryName = directory.standardizedFileURL.lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // tmuxは新規session名の`.`と`:`を`_`へ置換するため、返却名と実際のsession名を一致させる。
        let baseName = (directoryName.isEmpty ? "session" : directoryName)
            .replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        guard existingNames.contains(baseName) else { return baseName }

        var suffix = 2
        while existingNames.contains("\(baseName)-\(suffix)") {
            suffix += 1
        }
        return "\(baseName)-\(suffix)"
    }
}

/// Stop hook 由来の通知 1 件の受信記録。「最新の通知へジャンプ」(cmd+shift+n) の解決に使う。
/// バッジ台帳 (windowID -> 未読数) とは別に、発生順を保持するために持つ。
struct NotificationRecord: Equatable {
    /// 通知が発火した window の window_id (@n)。
    let windowID: String
    /// 受信時刻。
    let receivedAt: Date
}

/// session/window の移動先を計算する純粋ロジック。実 tmux に依存しないためユニットテスト可能。
enum NoroshiNavigation {
    /// サイドバーのキーボードナビゲーション (↑↓) が辿る行。表示順の session 行と展開中の window 行。
    enum SidebarRow: Equatable {
        /// session 行。
        case session(name: String)
        /// window 行。
        case window(TmuxWindow)
    }

    /// サイドバーの表示行 (session 行 + 折りたたまれていない session の window 行) を上から順に平坦化し、
    /// current から offset 隣の行を返す (端では停止)。current が nil または表示行に無い場合は先頭行を返す。
    static func adjacentSidebarRow(
        in sessions: [TmuxSession],
        collapsedSessionNames: Set<String>,
        from current: SidebarRow?,
        offset: Int
    ) -> SidebarRow? {
        let rows = sessions.flatMap { session -> [SidebarRow] in
            [.session(name: session.name)]
                + (collapsedSessionNames.contains(session.name) ? [] : session.windows.map(SidebarRow.window))
        }
        guard let current, let currentIndex = rows.firstIndex(of: current) else { return rows.first }
        return rows[max(0, min(rows.count - 1, currentIndex + offset))]
    }

    /// tmux clientの実接続先をアプリ選択へ反映すべきか判定する。
    /// managerとapp選択がずれている間はView更新待ちなので、古いattach先へ戻さない。
    static func shouldFollowAttachedSession(
        selected: String?,
        managed: String?,
        attached: String?,
        availableNames: Set<String>
    ) -> Bool {
        guard let attached, availableNames.contains(attached) else { return false }
        return attached != selected && managed == selected
    }

    /// 表示順 sessionNames の中で current から offset だけ移動した session 名を返す (末尾↔先頭で循環)。
    /// current が nil または一覧に無い場合は先頭を返す。
    static func adjacentSessionName(in sessionNames: [String], from current: String?, offset: Int) -> String? {
        guard !sessionNames.isEmpty else { return nil }
        guard let current, let currentIndex = sessionNames.firstIndex(of: current) else { return sessionNames.first }
        let count = sessionNames.count
        return sessionNames[((currentIndex + offset) % count + count) % count]
    }

    /// 表示順 sessionNames の displayIndex 番目 (0 始まり) の session 名。範囲外は nil。
    static func sessionName(in sessionNames: [String], atDisplayIndex displayIndex: Int) -> String? {
        sessionNames.indices.contains(displayIndex) ? sessionNames[displayIndex] : nil
    }

    /// 通知履歴 (古い順) とバッジ台帳から、最も新しく受信しかつ未読が残っている windowID を返す。
    /// 同じ window が複数回通知されても、最新の受信を採用する。
    static func latestUnreadWindowID(history: [NotificationRecord], badges: [String: Int]) -> String? {
        history.last(where: { (badges[$0.windowID] ?? 0) > 0 })?.windowID
    }

    /// サイドバーへ追加済みの session 名 savedOrder から、現在表示できる session 名を保存順で返す。
    /// - 消えた session は表示からだけ外し、savedOrder 自体には残す (同名で復活したら再表示するため)。
    /// - 未追加の新規 session は自動追加しない。
    /// - savedOrder に重複があっても先勝ちで 1 つに畳む。
    static func displayedSessionNames(savedOrder: [String], currentNames: [String]) -> [String] {
        let currentNameSet = Set(currentNames)
        var seenNames = Set<String>()
        return savedOrder.filter { currentNameSet.contains($0) && seenNames.insert($0).inserted }
    }
}
