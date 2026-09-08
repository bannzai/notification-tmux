import SwiftUI

// suzu の通知を iPhone から扱う iOS クライアントの雛形。
// simtunnel (GitHub Actions macOS runner 上の iOS Simulator) の caller workflow のビルド対象として置く (issue #90)
@main
struct SuzuiOSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
