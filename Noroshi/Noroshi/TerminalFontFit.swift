import AppKit
import CoreText

/// tmux window 全体が terminal の格子に収まる描画フォントサイズを解決する純粋ロジック (issue #36)。
/// attach は ignore-size (他 client の window を resize しないため) なので、window が client の格子より
/// 大きいと tmux はカーソル追従で表示をパンし、端が見切れる。表示側のフォントを設定サイズを上限に
/// 必要な分だけ縮小し、格子を window 以上へ広げることで window 全体を可視にする。
enum TerminalFontFit {
    /// 縮小の下限 (pt)。macOS の小型システムフォント (NSFont.smallSystemFontSize = 11) より十分小さく、
    /// これ未満は判読できないため、収まらない残りは従来どおり tmux のパンに委ねる。
    static let minimumFontSize: CGFloat = 6

    /// 候補サイズの刻み (pt)。フォントは小数サイズを受け付けるが、0.5 刻みで格子 1〜2 列分の精度が出て実用上十分。
    static let sizeStep: CGFloat = 0.5

    /// preferred を上限に sizeStep 刻みで縮小しながら、window の格子と status line が収まる最大サイズを返す。
    /// 下限まで縮めても収まらない場合は下限を返す。preferred が下限以下ならユーザー設定を尊重してそのまま返す。
    /// cellSize にはフォントサイズ → 1 セル寸法の解決 (SwiftTerm と同じ式) を注入する。
    static func fittedSize(
        preferred: CGFloat,
        grid: TmuxWindowGrid,
        viewSize: CGSize,
        scrollerWidth: CGFloat,
        cellSize: (CGFloat) -> CGSize
    ) -> CGFloat {
        guard preferred > minimumFontSize else { return preferred }
        for size in stride(from: preferred, to: minimumFontSize, by: -sizeStep) {
            let cell = cellSize(size)
            guard cell.width > 0, cell.height > 0 else { continue }
            if Int((viewSize.width - scrollerWidth) / cell.width) >= grid.cols,
               Int(viewSize.height / cell.height) >= grid.rowsWithStatus
            {
                return size
            }
        }
        return minimumFontSize
    }

    /// window 格子 + status line がちょうど収まる terminal view の frame 寸法 (pt) を返す。
    /// terminal をこの寸法へ固定すると client の格子が window に一致し、余った領域へ tmux が
    /// fill-character (既定 `·`) を敷き詰める余地が無くなる (issue #60)。
    /// 0.25pt の上乗せは、セル寸法との積の浮動小数点誤差で SwiftTerm の Int() 切り捨て
    /// (processSizeChange) が 1 列/行少なく数えるのを防ぐため。最小フォント 6pt のセル幅 (約 3.6pt)
    /// より十分小さいので、格子が 1 列/行多くなることはない。
    static func constrainedViewSize(grid: TmuxWindowGrid, cell: CGSize, scrollerWidth: CGFloat) -> CGSize {
        CGSize(
            width: CGFloat(grid.cols) * cell.width + scrollerWidth + 0.25,
            height: CGFloat(grid.rowsWithStatus) * cell.height + 0.25)
    }

    /// SwiftTerm (AppleTerminalView.computeFontDimensions) と同じ式で 1 セルの寸法を求める。
    /// scale は描画先のピクセル密度 (backingScaleFactor)。SwiftTerm はセルの継ぎ目を避けるため
    /// 寸法をピクセル格子へ切り上げスナップしており、式がずれると「収まる」と判定したサイズで
    /// SwiftTerm の格子が 1 列少なく計算され、見切れが再発する。
    static func cellSize(of font: NSFont, scale: CGFloat) -> CGSize {
        CGSize(
            width: max(1, ceil(font.advancement(forGlyph: font.glyph(withName: "W")).width * scale) / scale),
            height: max(1, ceil(ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)) * scale) / scale))
    }
}
