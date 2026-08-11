import LicenseList
import SwiftUI

/// 依存 OSS の名称とライセンス本文を表示するウィンドウ。
/// 一覧は LicenseList の build tool plugin が SwiftPM の解決結果 (DerivedData の SourcePackages) から
/// ビルドのたびに生成するため、依存の追加・更新に自動で追従する (手書きの固定一覧を持たない)。
struct LicenseWindowView: View {
    /// `openWindow(id:)` からこのウィンドウを開くための識別子。
    static let windowID = "license"

    var body: some View {
        NavigationStack {
            LicenseListView()
                // ライセンス本文を読んだ後にリポジトリ本体も辿れるよう、リンク付きのスタイルを選ぶ。
                .licenseViewStyle(.withRepositoryAnchorLink)
                .navigationTitle("OSS ライセンス")
        }
        // ライセンス本文 (LicenseList は macOS で .body フォントを使う) が数語ごとに折り返されず、
        // 一覧側ではライブラリ名が一画面に収まる大きさを最小値にする。
        .frame(minWidth: 560, minHeight: 420)
    }
}
