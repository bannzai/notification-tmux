import Foundation

/// tmux サーバの所在。ローカル、または ssh で接続するリモートホスト (issue #38)。
enum TmuxHost: Hashable {
    case local
    /// ssh の接続先 (`~/.ssh/config` の Host 名や user@host)。config の `remote-host` で指定する。
    case remote(String)

    /// 複合 ID (session / window の host 修飾) に使う識別子。
    /// ローカルは予約名 "local"。同名の ssh 接続先を定義した場合はローカルと区別できない (README に明記)。
    var id: String {
        switch self {
        case .local: return "local"
        case .remote(let sshDestination): return sshDestination
        }
    }

    /// id 文字列からの逆変換。
    init(id: String) {
        self = id == TmuxHost.local.id ? .local : .remote(id)
    }

    /// サイドバー・タブ・通知での表示名。ローカルは表示しないため nil。
    var displayName: String? {
        switch self {
        case .local: return nil
        case .remote(let sshDestination): return sshDestination
        }
    }
}

/// host をまたいで一意な複合 ID (`<hostID>:<要素>`) の組み立てと分解。
/// tmux は session 名の `:` を `_` へ置換し、window_id は `@数字` のため、要素側に `:` は現れない。
/// host 側 (IPv6 アドレス等) には `:` が含まれ得るので、分解は最後の `:` で行う。
enum TmuxID {
    static func make(hostID: String, element: String) -> String {
        "\(hostID):\(element)"
    }

    static func split(_ id: String) -> (hostID: String, element: String)? {
        guard let separatorIndex = id.lastIndex(of: ":") else { return nil }
        return (String(id[..<separatorIndex]), String(id[id.index(after: separatorIndex)...]))
    }
}

/// tmux の 1 window。サイドバーの行 1 つに対応する。
struct TmuxWindow: Identifiable, Equatable, Hashable {
    /// この window がある tmux サーバ。
    let host: TmuxHost
    /// tmux の window_id (例 "@42")。同一サーバ内でユニークかつ改名・並べ替えに影響されない。
    let windowID: String
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

    /// host をまたいで一意な識別子。バッジ台帳・選択状態のキー (issue #38: ローカルとリモートで @n が衝突するため)。
    var id: String { TmuxID.make(hostID: host.id, element: windowID) }
    /// この window が属する session の複合 ID。
    var sessionID: String { TmuxID.make(hostID: host.id, element: sessionName) }
}

/// tmux window の格子サイズ (列 × 行)。表示フォントのフィット計算 (issue #36) の入力。
struct TmuxWindowGrid: Equatable {
    /// window の列数 (#{window_width})。
    let cols: Int
    /// window の行数 (#{window_height})。
    let rows: Int
}

/// tmux の 1 session。cmux でいう workspace に対応する。
struct TmuxSession: Identifiable, Equatable, Hashable {
    /// この session がある tmux サーバ。
    let host: TmuxHost
    /// session 名。同一サーバ内で一意。
    let name: String
    /// この session に attach しているクライアント数。
    let attachedClients: Int
    /// session 配下の window (index 昇順)。
    var windows: [TmuxWindow]

    /// host をまたいで一意な識別子。サイドバー保存順・選択状態のキー。
    var id: String { TmuxID.make(hostID: host.id, element: name) }
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
    /// `display-message -p` 用。attach 中 session のカレント window の格子サイズを取得する。
    static let windowGridFormat = "#{window_width}\u{1f}#{window_height}"

    /// `windowFormat` で出力された 1 行を host 上の TmuxWindow にする。形式が合わない行は nil。
    static func parseWindowLine(_ line: String, host: TmuxHost = .local) -> TmuxWindow? {
        let parts = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6,
              parts[1].hasPrefix("@"),
              let index = Int(parts[2]),
              let panes = Int(parts[5]) else { return nil }
        return TmuxWindow(host: host, windowID: parts[1], sessionName: parts[0], index: index,
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

    /// `windowGridFormat` で出力された 1 行を TmuxWindowGrid にする。形式が合わない行は nil。
    static func parseWindowGridLine(_ line: String) -> TmuxWindowGrid? {
        let parts = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2,
              let cols = Int(parts[0]),
              let rows = Int(parts[1]),
              cols > 0, rows > 0
        else { return nil }
        return TmuxWindowGrid(cols: cols, rows: rows)
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

/// Claude Code の Stop hook から届く通知イベント。
/// ローカルは `noroshi://stop?session=<name>&window=@n` の URL スキーム、
/// リモートは ssh -R でフォワードされた socket 経由の同形式クエリで届く (issue #39)。
struct StopEvent: Equatable {
    /// 発火元の tmux サーバ。
    let host: TmuxHost
    /// 発火元 tmux session 名。
    let sessionName: String
    /// 発火元 tmux window の window_id (@n)。
    let windowID: String

    /// 発火元 session の複合 ID (TmuxSession.id と同形式)。
    var sessionID: String { TmuxID.make(hostID: host.id, element: sessionName) }
    /// バッジ台帳のキー (TmuxWindow.id と同形式)。
    var windowKey: String { TmuxID.make(hostID: host.id, element: windowID) }

    // URL スキーム / socket 経由の入力だけを受け付けるバリデーションのため failable init にしている
    init?(url: URL) {
        guard url.scheme == "noroshi", url.host == "stop" else { return nil }
        // `host` クエリはデバッグ用にリモート発火を模擬する入口 (通常のローカル hook は付けない)
        self.init(queryItems: URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, hostOverride: nil)
    }

    /// リモート socket が受信した 1 行 (`session=<enc>&window=@n`) をイベントにする。
    /// 受信経路 (host ごとの listener) が発火元 host を確定するため、クエリの host より優先する。
    init?(payload: String, from host: TmuxHost) {
        self.init(
            queryItems: URLComponents(string: "noroshi://stop?" + payload.trimmingCharacters(in: .whitespacesAndNewlines))?.queryItems,
            hostOverride: host)
    }

    // クエリのバリデーションを URL / socket 経路で共有するため定義している
    private init?(queryItems: [URLQueryItem]?, hostOverride: TmuxHost?) {
        guard let queryItems,
              let session = queryItems.first(where: { $0.name == "session" })?.value,
              let window = queryItems.first(where: { $0.name == "window" })?.value,
              !session.isEmpty,
              window.hasPrefix("@")
        else { return nil }
        host = hostOverride
            ?? queryItems.first(where: { $0.name == "host" })?.value.flatMap { $0.isEmpty ? nil : TmuxHost(id: $0) }
            ?? .local
        sessionName = session
        windowID = window
    }

    /// macOS 通知の userInfo から Stop イベントを復元する。host 未収録の旧通知はローカル扱い。
    init?(userInfo: [AnyHashable: Any]) {
        guard let session = userInfo["session"] as? String,
              let window = userInfo["window"] as? String,
              !session.isEmpty,
              window.hasPrefix("@")
        else { return nil }
        host = (userInfo["host"] as? String).flatMap { $0.isEmpty ? nil : TmuxHost(id: $0) } ?? .local
        sessionName = session
        windowID = window
    }

    /// macOS 通知へ保存できる property list 形式の値。
    var userInfo: [String: String] {
        ["session": sessionName, "window": windowID, "host": host.id]
    }
}

/// Noroshi が attach している tmux client。PID で SwiftTerm の子プロセスと対応付ける (ローカル host のみ)。
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
    /// 通知が発火した window の複合 ID (TmuxWindow.id)。
    let windowID: String
    /// 受信時刻。
    let receivedAt: Date
}

/// terminal 表示のタブ 1 枚 (issue #40)。タブごとに選択中の session/window を保持する。
struct TerminalTab: Identifiable, Equatable {
    let id: UUID
    /// このタブで表示する session の複合 ID (TmuxSession.id)。nil は未選択。
    var sessionID: String?
    /// このタブでサイドバー選択表示する window の複合 ID (TmuxWindow.id)。
    var windowID: String?
}

/// session/window の移動先を計算する純粋ロジック。実 tmux に依存しないためユニットテスト可能。
enum NoroshiNavigation {
    /// サイドバーのキーボードナビゲーション (↑↓) が辿る行。表示順の session 行と展開中の window 行。
    enum SidebarRow: Equatable {
        /// session 行。値は複合 session ID。
        case session(id: String)
        /// window 行。
        case window(TmuxWindow)
    }

    /// サイドバーの表示行 (session 行 + 折りたたまれていない session の window 行) を上から順に平坦化し、
    /// current から offset 隣の行を返す (端では停止)。current が nil または表示行に無い場合は先頭行を返す。
    static func adjacentSidebarRow(
        in sessions: [TmuxSession],
        collapsedSessionIDs: Set<String>,
        from current: SidebarRow?,
        offset: Int
    ) -> SidebarRow? {
        let rows = sessions.flatMap { session -> [SidebarRow] in
            [.session(id: session.id)]
                + (collapsedSessionIDs.contains(session.id) ? [] : session.windows.map(SidebarRow.window))
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
        availableIDs: Set<String>
    ) -> Bool {
        guard let attached, availableIDs.contains(attached) else { return false }
        return attached != selected && managed == selected
    }

    /// 表示順 sessionIDs の中で current から offset だけ移動した session ID を返す (末尾↔先頭で循環)。
    /// current が nil または一覧に無い場合は先頭を返す。
    static func adjacentSessionID(in sessionIDs: [String], from current: String?, offset: Int) -> String? {
        guard !sessionIDs.isEmpty else { return nil }
        guard let current, let currentIndex = sessionIDs.firstIndex(of: current) else { return sessionIDs.first }
        let count = sessionIDs.count
        return sessionIDs[((currentIndex + offset) % count + count) % count]
    }

    /// 表示順 sessionIDs の displayIndex 番目 (0 始まり) の session ID。範囲外は nil。
    static func sessionID(in sessionIDs: [String], atDisplayIndex displayIndex: Int) -> String? {
        sessionIDs.indices.contains(displayIndex) ? sessionIDs[displayIndex] : nil
    }

    /// 通知履歴 (古い順) とバッジ台帳から、最も新しく受信しかつ未読が残っている windowID を返す。
    /// 同じ window が複数回通知されても、最新の受信を採用する。
    static func latestUnreadWindowID(history: [NotificationRecord], badges: [String: Int]) -> String? {
        history.last(where: { (badges[$0.windowID] ?? 0) > 0 })?.windowID
    }

    /// 現存 session ID currentIDs から、サイドバーに表示する session ID を返す。
    /// - savedOrder (並べ替え済みの保存順) にある session を保存順で先頭に並べる。
    /// - savedOrder に無い session も currentIDs の順で末尾に足し、自動表示する (issue #47)。
    /// - hiddenIDs (「サイドバーから削除」した session) は表示しない。
    /// - 消えた session は表示からだけ外し、savedOrder 自体には残す (同名で復活したら同じ位置に表示するため)。
    /// - savedOrder に重複があっても先勝ちで 1 つに畳む。
    static func displayedSessionIDs(savedOrder: [String], currentIDs: [String], hiddenIDs: Set<String>) -> [String] {
        let currentIDSet = Set(currentIDs)
        var seenIDs = Set<String>()
        return (savedOrder.filter(currentIDSet.contains) + currentIDs)
            .filter { !hiddenIDs.contains($0) && seenIDs.insert($0).inserted }
    }

    /// タブを閉じた後のアクティブタブ index を返す (issue #40)。
    /// 閉じた位置より左がアクティブなら変わらず、アクティブ自身または右を閉じた場合は範囲内へ収める。
    static func activeTabIndexAfterClosing(at closedIndex: Int, activeIndex: Int, remainingCount: Int) -> Int {
        closedIndex < activeIndex ? activeIndex - 1 : min(activeIndex, remainingCount - 1)
    }

    /// 素のターミナルのシェル終了時にタブへ行う後始末 (issue #54)。
    enum PlainTerminalExitAction: Equatable {
        /// タブを閉じる。
        case close(index: Int)
        /// 最後の 1 枚は閉じられないため、新しい空タブ (新しいシェル) へ置き換える。
        case replace(index: Int)
        /// 何もしない。
        case ignore
    }

    /// シェルが終了したタブの扱いを決める。Terminal.app と同様にタブを閉じる。
    /// session 表示中のタブ (シェルだけがバックグラウンドで終了した) と既に閉じられたタブは何もしない。
    static func plainTerminalExitAction(tabs: [TerminalTab], tabID: UUID) -> PlainTerminalExitAction {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].sessionID == nil else { return .ignore }
        return tabs.count > 1 ? .close(index: index) : .replace(index: index)
    }
}
