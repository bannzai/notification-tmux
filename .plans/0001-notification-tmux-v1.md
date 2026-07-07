# notification-tmux v1: 通知センター付き tmux フロントエンド macOS アプリ

## Context

cmux + tmux の現行構成を置き換える、tmux 専用の軽量 macOS フロントエンドを新規開発する。

- 現状: cmux の workspace = tmux の session（GitHub リポジトリ毎）。Claude Code hooks で通知を送っている
- 不満 1: cmux が重い（30GB 級のメモリ消費）
- 不満 2: 通知をタップしてもその session の window までは開かない。cmux は tmux 専用ソフトではないのでそこまでやらない

### v1 の要件（ユーザー回答で確定）

1. ターミナル: **SwiftTerm** を組み込み、workspace(=tmux session) ごとに PTY で `tmux attach-session` する
2. 通知センター: **サイドバーの workspace/window にバッジ数字**。Claude Code の Stop hook イベントで加算
3. バッジのある項目をクリックしたら **tmux の window レベルまで開く**（該当 session の terminal を表示し `select-window`）
4. macOS 専用（このマシンは macOS 26.2 / tmux 3.6a / Xcode 26 系）

### 調査で確定した設計根拠（research-tmux-hooks / research-swiftterm の実機検証結果）

- window の識別子は **window ID (`@n`)** を SSOT にする。tmux サーバ全体でユニークで、session/window の改名・並べ替えに影響されない。`select-window -t @n` は session プレフィックス不要で一意解決される（man tmux TARGET SYNTAX で確認）
- session のカレント window は **session 単位**で 1 つ。本アプリは session ごとに専属クライアント（PTY）を持つため `switch-client` は不要で、`select-window -t @n` だけで表示が切り替わる
  - 注意: 同じ session に cmux 等の別クライアントが attach していると、`select-window` はそのクライアントの表示も切り替える（tmux の仕様）。v1 は許容（本アプリは cmux の置き換えが目的）。併用したくなったら session group（`new-session -t`）で分離する
- `window_flags`（`*!Z` 等の合成文字列）はパースせず、**個別 bool 変数**（`window_active` / `window_bell_flag` 等）をフォーマット文字列に列挙する
- Claude Code Stop hook の stdin JSON には tmux 位置情報が無いが、hook プロセスは `$TMUX_PANE` を継承する。実機確認済みの一手で解決する:
  `tmux display-message -p -t "$TMUX_PANE" '#{session_name}|#{window_id}'`
- アプリへのイベント伝達は **URL スキーム + `open -g`**。`-g` は「フォアグラウンド化しない」の意味で、起動中ならハンドラだけ呼ばれ、未起動なら背面で起動される（man open で確認）。バッジだけ更新してフォーカスを奪わない要件に合致
- 既存の cmux 向け hooks（`@claude-waiting` オプション、`claude-hook-notify` の OSC 777）とは独立の副作用なので、**Stop hooks 配列の末尾に 1 エントリ追記するだけ**で非破壊に共存できる
- 一覧の更新は v1 ではポーリング（2 秒間隔の `list-windows -a`。フォーマット出力のみで軽量）。tmux `set-hook -g`（session-created / window-linked 等）+ `run-shell -b` によるイベント駆動化は v1.1 で検討
- SwiftTerm は **v1.13.0**（SPM、product 名 `SwiftTerm`、macOS 11+）。`LocalProcessTerminalView.startProcess(executable:args:environment:execName:currentDirectory:)` が forkpty ベースで PTY を張る。フレーム変更だけで PTY の winsize 更新まで自動伝播する（`setFrameSize` オーバーライド済み）
- SwiftTerm のデフォルト環境変数に **PATH は含まれない**（ソースで確認）。本アプリは tmux を絶対パスで exec し、attach 先のプロセス環境は tmux サーバ側のものなので実害はない
- App Sandbox は**完全に無効**にする（SwiftTerm 公式ドキュメントコメントと公式サンプルの空 entitlements で確認）。entitlements を作らないことで実現する
- 非表示の `LocalProcessTerminalView` も attach と VT パースは継続する（描画のみ AppKit がスキップ）。session ごとにビューを生かしたまま保持し、切り替えはコンテナへの付け替えで行う。破棄は明示的に `terminate()`
- ターミナルへの文字入力はプログラム的には `send()`（`feed()` は表示バッファ書き込みのみで子プロセスに届かない。issue #288 で確認済みのハマりどころ）
- ユニットテストは app を TEST_HOST にする。テスト実行時にアプリがポーリングや tmux attach を始めてユーザーの tmux（クライアントサイズ等）へ影響しないよう、`XCTestConfigurationFilePath` 環境変数を見て UI 起動をスキップする

### v1 で確定する細部（ユーザー就寝中のため自己判断。すべて可逆）

| 項目 | 決定 | 理由 |
| --- | --- | --- |
| アプリ名 / Bundle ID | `NotificationTmux` / `com.bannzai.NotificationTmux` | リポジトリ名に合わせる（造語を作らない） |
| URL スキーム | `nottmux://` | 短く衝突しにくい |
| プロジェクト生成 | XcodeGen (`project.yml`) | 生成物の diff 管理がしやすくエージェント開発向き。ローカルに導入済み |
| Deployment Target | macOS 15.0 | SwiftTerm の要件を満たしつつ古すぎない |
| App Sandbox | 無効 | homebrew の tmux を PTY で exec するため。App Store 配布はしない |
| tmux バイナリ解決 | `/opt/homebrew/bin/tmux` → `/usr/local/bin/tmux` → `PATH` の順で探索 | Apple Silicon / Intel 両対応 |
| バッジのクリア条件 | その window をアプリ内で選択（表示）したとき | 最小で直感的。既読管理はしない |
| Dock バッジ | 全 window の未読合計を表示 | アプリ非表示時にも気づける |
| 通知履歴の永続化 | しない（メモリのみ） | v1 スコープ外。再起動でバッジはリセット |

## アーキテクチャ

```
Claude Code (tmux pane 内)
  └─ Stop hook ─▶ scripts/notification-tmux-hook-stop
                    ├─ $TMUX_PANE → tmux display-message で session|window_id を解決
                    └─ open -g "nottmux://stop?session=<name>&window=@<n>"
                                       │
NotificationTmux.app ◀────────────────┘ (onOpenURL)
  ├─ AppState (ObservableObject)
  │    ├─ sessions: [TmuxSession]  ← TmuxClient が 2 秒ポーリング
  │    ├─ badges: [WindowID: Int]  ← URL イベントで加算 / window 表示でクリア
  │    └─ selection: (session, windowID)
  ├─ Sidebar (SwiftUI List) — session → window ツリー + バッジ数字
  └─ TerminalHostView (NSViewRepresentable)
       └─ session ごとに LocalProcessTerminalView をキャッシュ
            └─ PTY: tmux attach-session -t <session>
                     （window 切替は tmux select-window -t @n）
```

## 変更ファイル一覧

| パス | 種別 | 概要 |
| --- | --- | --- |
| `project.yml` | 新規 | XcodeGen 定義。SwiftTerm SPM 依存、sandbox 無効、URL スキーム登録 |
| `NotificationTmux/NotificationTmuxApp.swift` | 新規 | @main。onOpenURL で stop イベント受信、Dock バッジ更新 |
| `NotificationTmux/Models/TmuxModels.swift` | 新規 | TmuxSession / TmuxWindow / StopEvent。フォーマット出力のパーサ |
| `NotificationTmux/Services/TmuxClient.swift` | 新規 | tmux CLI ラッパ（list-sessions / list-windows / select-window / バイナリ解決） |
| `NotificationTmux/State/AppState.swift` | 新規 | 一覧ポーリング、バッジ台帳、選択状態、イベント適用 |
| `NotificationTmux/Views/ContentView.swift` | 新規 | NavigationSplitView。サイドバー + ターミナル |
| `NotificationTmux/Views/SidebarView.swift` | 新規 | session/window ツリーとバッジ表示、クリックでジャンプ |
| `NotificationTmux/Views/TerminalHostView.swift` | 新規 | SwiftTerm の NSViewRepresentable ラップと session ごとのビューキャッシュ |
| `NotificationTmux/Info.plist`（project.yml 内で定義） | 新規 | CFBundleURLTypes: nottmux |
| `NotificationTmuxTests/TmuxModelsTests.swift` | 新規 | パーサ / StopEvent URL / バッジ台帳のユニットテスト |
| `scripts/notification-tmux-hook-stop` | 新規 | Claude Stop hook から呼ぶ通知スクリプト（冪等・既存 hooks 非破壊） |
| `.claude/rules/plan-checklist.md` | 新規（作成済み） | プランチェックリスト |
| `.gitignore` | 新規（作成済み） | Xcode / SwiftPM / tmp |
| `README.md` | 新規 | セットアップ手順（xcodegen generate → build → hooks 追記） |
| `~/.claude/settings.json`（castle 管理・リポジトリ外） | 変更 | Stop hooks 配列末尾に scripts/notification-tmux-hook-stop 呼び出しを 1 エントリ追記 |

## ファイルごとの実装コード提案

### `project.yml`

```yaml
name: NotificationTmux
options:
  bundleIdPrefix: com.bannzai
  deploymentTarget:
    macOS: "15.0"
settings:
  base:
    SWIFT_VERSION: "5.0"
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGN_STYLE: Manual
    ENABLE_HARDENED_RUNTIME: NO
packages:
  SwiftTerm:
    url: https://github.com/migueldeicaza/SwiftTerm
    from: 1.13.0
targets:
  NotificationTmux:
    type: application
    platform: macOS
    sources:
      - NotificationTmux
    dependencies:
      - package: SwiftTerm
    info:
      path: NotificationTmux/Info.plist
      properties:
        CFBundleURLTypes:
          - CFBundleURLName: com.bannzai.NotificationTmux
            CFBundleURLSchemes:
              - nottmux
        LSApplicationCategoryType: public.app-category.developer-tools
  NotificationTmuxTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - NotificationTmuxTests
    dependencies:
      - target: NotificationTmux
    settings:
      base:
        TEST_HOST: "$(BUILT_PRODUCTS_DIR)/NotificationTmux.app/Contents/MacOS/NotificationTmux"
        BUNDLE_LOADER: "$(TEST_HOST)"
schemes:
  NotificationTmux:
    build:
      targets:
        NotificationTmux: all
    test:
      targets:
        - NotificationTmuxTests
```

- Sandbox 無効は「entitlements を一切作らない」ことで実現（SwiftTerm 公式サンプルと同じ）
- 署名はローカル実行専用の ad-hoc (`CODE_SIGN_IDENTITY: "-"`)

### `NotificationTmux/Models/TmuxModels.swift`

パーサと StopEvent。区切り文字は window 名等に混入し得ない ASCII Unit Separator `\u{1f}`。

```swift
import Foundation

struct TmuxWindow: Identifiable, Equatable, Hashable {
    let id: String        // tmux の window_id (例 "@42")。サーバ全体でユニークな SSOT
    let sessionName: String
    let index: Int
    let name: String
    let isActive: Bool
    let paneCount: Int
}

struct TmuxSession: Identifiable, Equatable, Hashable {
    let id: String        // session_name
    let attachedClients: Int
    var windows: [TmuxWindow]
    var name: String { id }
}

enum TmuxFormat {
    static let fieldSeparator: Character = "\u{1f}"

    // window_flags は合成文字列 (`*!Z` 等) でパースが不安定なため、個別の bool 変数を列挙する
    static let windowFormat = "#{session_name}\u{1f}#{window_id}\u{1f}#{window_index}\u{1f}#{window_name}\u{1f}#{window_active}\u{1f}#{window_panes}"
    static let sessionFormat = "#{session_name}\u{1f}#{session_attached}"

    static func parseWindowLine(_ line: String) -> TmuxWindow? {
        let parts = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 6,
              parts[1].hasPrefix("@"),
              let index = Int(parts[2]),
              let panes = Int(parts[5]) else { return nil }
        return TmuxWindow(id: parts[1], sessionName: parts[0], index: index,
                          name: parts[3], isActive: parts[4] == "1", paneCount: panes)
    }

    static func parseSessionLine(_ line: String) -> (name: String, attached: Int)? {
        let parts = line.split(separator: fieldSeparator, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let attached = Int(parts[1]) else { return nil }
        return (parts[0], attached)
    }
}

// nottmux://stop?session=<name>&window=@n
struct StopEvent: Equatable {
    let sessionName: String
    let windowID: String

    init?(url: URL) {
        guard url.scheme == "nottmux",
              url.host == "stop",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let session = components.queryItems?.first(where: { $0.name == "session" })?.value,
              let window = components.queryItems?.first(where: { $0.name == "window" })?.value,
              !session.isEmpty,
              window.hasPrefix("@")
        else { return nil }
        sessionName = session
        windowID = window
    }
}
```

### `NotificationTmux/Services/TmuxClient.swift`

```swift
import Foundation

enum TmuxClientError: Error, CustomStringConvertible {
    case commandFailed(status: Int32, stderr: String)

    var description: String {
        switch self {
        case .commandFailed(let status, let stderr):
            return "tmux exited with status \(status): \(stderr)"
        }
    }
}

struct TmuxClient {
    let binaryPath: String

    init(binaryPath: String = TmuxClient.resolveBinaryPath()) {
        self.binaryPath = binaryPath
    }

    static func resolveBinaryPath() -> String {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
    }

    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        // 既知パスに tmux が無い場合は /usr/bin/env 経由で PATH 解決に委ねる
        process.arguments = binaryPath.hasSuffix("env") ? ["tmux"] + arguments : arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TmuxClientError.commandFailed(
                status: process.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }

    func fetchSessions() throws -> [TmuxSession] {
        let sessionsOut = try run(["list-sessions", "-F", TmuxFormat.sessionFormat])
        let windowsOut = try run(["list-windows", "-a", "-F", TmuxFormat.windowFormat])
        let windows = windowsOut.split(separator: "\n").compactMap { TmuxFormat.parseWindowLine(String($0)) }
        let grouped = Dictionary(grouping: windows, by: \.sessionName)
        return sessionsOut.split(separator: "\n").compactMap { line in
            guard let (name, attached) = TmuxFormat.parseSessionLine(String(line)) else { return nil }
            return TmuxSession(id: name, attachedClients: attached,
                               windows: (grouped[name] ?? []).sorted { $0.index < $1.index })
        }
    }

    // window_id (@n) はサーバ全体で一意なので session 指定は不要
    func selectWindow(id: String) throws {
        try run(["select-window", "-t", id])
    }
}
```

### `NotificationTmux/State/AppState.swift`

```swift
import AppKit
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var sessions: [TmuxSession] = []
    @Published private(set) var badges: [String: Int] = [:]   // windowID -> 未読数
    @Published var selectedSessionName: String?
    @Published var lastError: String?

    private let client: TmuxClient
    private var pollTask: Task<Void, Never>?

    init(client: TmuxClient = TmuxClient()) {
        self.client = client
    }

    func startPolling(interval: TimeInterval = 2.0) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refresh() async {
        let client = self.client
        do {
            let fetched = try await Task.detached(priority: .utility) { try client.fetchSessions() }.value
            sessions = fetched
            lastError = nil
            let alive = Set(fetched.flatMap(\.windows).map(\.id))
            badges = badges.filter { alive.contains($0.key) }
            if selectedSessionName == nil { selectedSessionName = fetched.first?.name }
            updateDockBadge()
        } catch {
            lastError = "\(error)"
        }
    }

    func apply(event: StopEvent) {
        badges[event.windowID, default: 0] += 1
        updateDockBadge()
    }

    func badgeCount(for session: TmuxSession) -> Int {
        session.windows.reduce(0) { $0 + (badges[$1.id] ?? 0) }
    }

    // window クリック: session の terminal を表示し select-window、バッジをクリア
    func open(window: TmuxWindow) {
        selectedSessionName = window.sessionName
        clearBadge(windowID: window.id)
        let client = self.client
        Task.detached(priority: .userInitiated) {
            do {
                try client.selectWindow(id: window.id)
            } catch {
                await MainActor.run { self.lastError = "\(error)" }
            }
        }
    }

    func clearBadge(windowID: String) {
        badges[windowID] = nil
        updateDockBadge()
    }

    private func updateDockBadge() {
        let total = badges.values.reduce(0, +)
        NSApp.dockTile.badgeLabel = total > 0 ? String(total) : ""
    }
}
```

### `NotificationTmux/Views/TerminalHostView.swift`

session ごとの `LocalProcessTerminalView` を生かしたまま保持し、表示切り替えはコンテナへの付け替えで行う。

```swift
import AppKit
import SwiftTerm
import SwiftUI

// 非表示でも attach と VT パースは継続する (SwiftTerm の仕様)。
// attach プロセスが終了 (session kill / detach) したらエントリを破棄し、次回表示時に再 attach する
@MainActor
final class TerminalSessionManager: NSObject, LocalProcessTerminalViewDelegate {
    static let shared = TerminalSessionManager()

    private var views: [String: LocalProcessTerminalView] = [:]

    func terminalView(for sessionName: String) -> LocalProcessTerminalView {
        if let view = views[sessionName] { return view }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.processDelegate = self
        // `=` プレフィックスで session 名の完全一致を強制 (前方一致による誤 attach を防ぐ)
        view.startProcess(
            executable: TmuxClient.resolveBinaryPath(),
            args: ["attach-session", "-t", "=\(sessionName)"]
        )
        views[sessionName] = view
        return view
    }

    // MARK: - LocalProcessTerminalViewDelegate
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if let entry = views.first(where: { $0.value === source }) {
            views[entry.key] = nil
        }
    }
}

struct TerminalHostView: NSViewRepresentable {
    let sessionName: String

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        install(on: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        install(on: container)
    }

    private func install(on container: NSView) {
        let terminal = TerminalSessionManager.shared.terminalView(for: sessionName)
        if terminal.superview !== container {
            container.subviews.forEach { $0.removeFromSuperview() }
            terminal.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                terminal.topAnchor.constraint(equalTo: container.topAnchor),
                terminal.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        // updateNSView の同期処理中に firstResponder を変えると SwiftUI の更新と競合するため次の runloop に回す
        DispatchQueue.main.async {
            if let window = terminal.window, window.firstResponder !== terminal {
                window.makeFirstResponder(terminal)
            }
        }
    }
}
```

### `NotificationTmux/Views/SidebarView.swift`

```swift
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List {
            ForEach(appState.sessions) { session in
                Section {
                    ForEach(session.windows) { window in
                        WindowRow(
                            window: window,
                            badge: appState.badges[window.id] ?? 0
                        ) {
                            appState.open(window: window)
                        }
                    }
                } header: {
                    SessionHeader(
                        session: session,
                        badge: appState.badgeCount(for: session),
                        isSelected: session.name == appState.selectedSessionName
                    ) {
                        appState.selectedSessionName = session.name
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            if let error = appState.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
        }
    }
}

struct SessionHeader: View {
    let session: TmuxSession
    let badge: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                Text(session.name)
                    .fontWeight(isSelected ? .bold : .regular)
                Spacer()
                BadgeLabel(count: badge)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct WindowRow: View {
    let window: TmuxWindow
    let badge: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("\(window.index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(window.name)
                    .lineLimit(1)
                if window.isActive {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
                Spacer()
                BadgeLabel(count: badge)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct BadgeLabel: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text(String(count))
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(.red))
        }
    }
}
```

### `NotificationTmux/Views/ContentView.swift`

```swift
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            if let name = appState.selectedSessionName {
                TerminalHostView(sessionName: name)
            } else {
                ContentUnavailableView(
                    "tmux session がありません",
                    systemImage: "terminal",
                    description: Text(appState.lastError ?? "tmux server が起動していないか、session が 0 個です")
                )
            }
        }
    }
}
```

### `NotificationTmux/NotificationTmuxApp.swift`

```swift
import SwiftUI

@main
struct NotificationTmuxApp: App {
    @StateObject private var appState = AppState()

    // TEST_HOST としてユニットテストから起動された場合は、ポーリングや tmux attach で
    // ユーザーの tmux 環境 (クライアントサイズ等) に影響を与えないよう UI を起動しない
    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    var body: some Scene {
        WindowGroup {
            if isRunningTests {
                Text("Running tests")
            } else {
                ContentView()
                    .environmentObject(appState)
                    .onOpenURL { url in
                        guard let event = StopEvent(url: url) else { return }
                        appState.apply(event: event)
                    }
                    .task { appState.startPolling() }
                    .frame(minWidth: 900, minHeight: 560)
            }
        }
    }
}
```

### `NotificationTmuxTests/TmuxModelsTests.swift`

```swift
import XCTest
@testable import NotificationTmux

final class TmuxModelsTests: XCTestCase {
    func testParseWindowLine() {
        let line = "Focus\u{1f}@18\u{1f}3\u{1f}fix-screenshot\u{1f}1\u{1f}3"
        let window = TmuxFormat.parseWindowLine(line)
        XCTAssertEqual(window?.sessionName, "Focus")
        XCTAssertEqual(window?.id, "@18")
        XCTAssertEqual(window?.index, 3)
        XCTAssertEqual(window?.name, "fix-screenshot")
        XCTAssertEqual(window?.isActive, true)
        XCTAssertEqual(window?.paneCount, 3)
    }

    func testParseWindowLineWithPipeInName() {
        let line = "sukidayo/Riamo\u{1f}@5\u{1f}0\u{1f}a|b|c\u{1f}0\u{1f}1"
        let window = TmuxFormat.parseWindowLine(line)
        XCTAssertEqual(window?.name, "a|b|c")
        XCTAssertEqual(window?.sessionName, "sukidayo/Riamo")
    }

    func testParseWindowLineInvalid() {
        XCTAssertNil(TmuxFormat.parseWindowLine(""))
        XCTAssertNil(TmuxFormat.parseWindowLine("only-one-field"))
        XCTAssertNil(TmuxFormat.parseWindowLine("s\u{1f}not-window-id\u{1f}0\u{1f}n\u{1f}1\u{1f}1"))
    }

    func testParseSessionLine() {
        let parsed = TmuxFormat.parseSessionLine("Focus\u{1f}2")
        XCTAssertEqual(parsed?.name, "Focus")
        XCTAssertEqual(parsed?.attached, 2)
    }

    func testStopEventFromURL() throws {
        let url = try XCTUnwrap(URL(string: "nottmux://stop?session=Focus&window=@18"))
        let event = StopEvent(url: url)
        XCTAssertEqual(event?.sessionName, "Focus")
        XCTAssertEqual(event?.windowID, "@18")
    }

    func testStopEventFromURLWithEncodedSession() throws {
        let url = try XCTUnwrap(URL(string: "nottmux://stop?session=sukidayo%2FRiamo&window=@5"))
        XCTAssertEqual(StopEvent(url: url)?.sessionName, "sukidayo/Riamo")
    }

    func testStopEventRejectsInvalidURL() throws {
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "nottmux://other?session=a&window=@1"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "https://stop?session=a&window=@1"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "nottmux://stop?session=a&window=1"))))
        XCTAssertNil(StopEvent(url: try XCTUnwrap(URL(string: "nottmux://stop?session=a"))))
    }

    @MainActor
    func testBadgeApplyAndClear() throws {
        let state = AppState()
        let url = try XCTUnwrap(URL(string: "nottmux://stop?session=Focus&window=@18"))
        let event = try XCTUnwrap(StopEvent(url: url))
        state.apply(event: event)
        state.apply(event: event)
        XCTAssertEqual(state.badges["@18"], 2)
        state.clearBadge(windowID: "@18")
        XCTAssertNil(state.badges["@18"])
    }
}
```

- `AppState.open(window:)` は実 tmux へ `select-window` を発行するためユニットテストでは呼ばない（ユーザーの tmux 状態を変更しないため）。バッジ加算/クリアのロジックのみをテストする

### `scripts/notification-tmux-hook-stop`

```bash
#!/bin/bash
# Claude Code の Stop hook から呼ばれ、発火元の tmux session/window を
# NotificationTmux.app に URL スキームで通知する。
# このスクリプト自体は状態を持たない。ただし冪等ではない: 1 回の呼び出しが
# アプリ側のバッジを 1 加算する「イベント通知」であり、重複実行の抑止は
# hook の発火回数 (Stop 1 回につき 1 回) に委ねるため。
# tmux 外や tmux/アプリ不在の環境では何もせず正常終了する (Claude 側を絶対にブロックしない)。
set -u

[ -n "${TMUX_PANE:-}" ] || exit 0
command -v tmux >/dev/null 2>&1 || exit 0

session=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || exit 0
window=$(tmux display-message -p -t "$TMUX_PANE" '#{window_id}' 2>/dev/null) || exit 0
[ -n "$session" ] && [ -n "$window" ] || exit 0

# session 名は空白や記号を含み得るため URL エンコードする (jq 不在時は素通しにフォールバック)
if command -v jq >/dev/null 2>&1; then
  session_enc=$(printf %s "$session" | jq -sRr @uri)
else
  session_enc=$session
fi

# -g: アプリをフォアグラウンド化せずに URL イベントを届ける (未起動なら背面で起動)
open -g "nottmux://stop?session=${session_enc}&window=${window}" 2>/dev/null || true
exit 0
```

### `README.md`

セットアップ手順（xcodegen generate → build → 起動 → hooks 追記）を記載する。ビルド成果物は `./tmp/DerivedData` に出す。

### `~/.claude/settings.json`（リポジトリ外・castle 管理）

`hooks.Stop[0].hooks` 配列の**末尾**に 1 エントリだけ追記する（既存の afplay / @claude-waiting / claude-hook-notify には触れない）:

```json
{
  "type": "command",
  "command": "/Users/bannzai/ghq/github.com/bannzai/notification-tmux/scripts/notification-tmux-hook-stop"
}
```

## 追記: ユーザー作成の NTMUX Xcode プロジェクトを採用（実装時の変更）

実装開始時点でユーザーが Xcode 26.5 で作成した `NTMUX/`（macOS App テンプレート、com.bannzai.NTMUX、Development Team 設定済み）がリポジトリに存在したため、XcodeGen 新規構成をやめてこれを土台に採用した。プラン本文からの差分:

| 項目 | プラン当初 | 採用 |
| --- | --- | --- |
| アプリ名 / Bundle ID | NotificationTmux / com.bannzai.NotificationTmux | **NTMUX / com.bannzai.NTMUX** |
| プロジェクト生成 | XcodeGen (project.yml) | **ユーザー作成の NTMUX.xcodeproj を直接編集**（Xcode 26 の folder-synchronized 形式のためソース追加はファイル配置のみで済む） |
| URL スキーム | nottmux:// | **ntmux://**（アプリ名に合わせた） |
| ソース配置 | NotificationTmux/ | NTMUX/NTMUX/（テスト: NTMUX/NTMUXTests/） |
| Deployment Target | macOS 15.0 | macOS 26.2（テンプレート既定のまま） |
| 署名 | ad-hoc | Automatic + Development Team（テンプレート既定のまま） |

pbxproj への変更: SwiftTerm 1.13.0 のパッケージ参照追加 / `ENABLE_APP_SANDBOX = NO`（SwiftTerm の要件）/ `INFOPLIST_FILE = Info.plist`（CFBundleURLTypes の合成用、GENERATE_INFOPLIST_FILE とマージされる）/ `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor → nonisolated`（バックグラウンドで tmux CLI を叩く設計のため、明示 @MainActor 方式に統一）。テンプレートの SwiftData ファイル (Item.swift) と Testing テンプレートは削除。xcodebuild 用に共有スキーム NTMUX を追加（test は unit テストのみ。UI テストはスコープ外）。

Metal Toolchain が未インストールで SwiftTerm の Shaders.metal がビルド不能だったため `xcodebuild -downloadComponent MetalToolchain` を実行した（環境セットアップ、コード変更なし）。

## チェックリスト

### 実装内容
- [ ] 変更対象ファイルごとに具体的なコード提案をコードブロックで記載している
- [ ] 既存コードのパターン・構成を確認し、同じパターンで実装している
- [ ] 変更範囲が必要最小限であること

### macOS アプリ (Swift / xcodebuild)
- [ ] `xcodebuild build` が成功する（ログ全文を `./tmp/build.log` に保存し `grep -i -e warning -e error` で全文検査。warning があれば報告に含める）
- [ ] `xcodebuild test` が全件パスする
- [ ] XcodeGen (`project.yml`) を変更した場合、`xcodegen generate` を実行して `.xcodeproj` を再生成している

### hooks / スクリプト（シェルスクリプトに変更がある場合）
- [ ] hook スクリプトは冪等である（冪等にできない場合は理由をコメントで明記）
- [ ] 既存の Claude hooks（cmux 通知等）の動作を壊していない

### 共通
- [ ] エラーメッセージはそのまま表示（加工・プレフィックス除去なし）
