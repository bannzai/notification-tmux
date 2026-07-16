import AppKit
import SwiftUI

/// Cmd 長押しで cmd+1..9 の対象 session を示すガイドの表示判定。実キーイベントに依存しないためユニットテスト可能。
enum ShortcutGuide {
    /// ガイド表示までの長押し時間 (秒)。
    /// 短いと通常のショートカット入力 (cmd を押してすぐ別キーを押す) のたびにガイドがちらつき、
    /// 長いと長押ししてもガイドに気づけないため、その間を取った値。
    static let holdDuration: TimeInterval = 0.8

    /// cmd 単独押下かどうか。shift/option/control が混ざると cmd+数字とは別のショートカットなので対象外。
    /// capsLock 等の状態系フラグはショートカットの意味を変えないため無視する。
    static func isCommandOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.intersection([.command, .shift, .option, .control]) == [.command]
    }

    /// 表示順 displayIndex (0 始まり) の session に割り当てられた cmd+数字の数字。cmd+1..9 の範囲外は nil。
    static func guideNumber(forDisplayIndex displayIndex: Int) -> Int? {
        (0..<9).contains(displayIndex) ? displayIndex + 1 : nil
    }
}

/// Cmd 長押し中に対象 UI へ重ねる ⌘{数字} のフロートバッジ。
struct ShortcutGuideBadge: View {
    /// 表示するショートカットの数字 (1..9)。
    let number: Int

    var body: some View {
        Text("⌘\(number)")
            .font(.caption.monospacedDigit().bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.accentColor, lineWidth: 1))
            .shadow(radius: 1.5)
            .allowsHitTesting(false)
    }
}
