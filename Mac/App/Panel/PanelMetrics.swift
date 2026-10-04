// PanelMetrics.swift -- the Details list's geometry and font, measured on a fresh-default 7zFM
// 26.03 at 96 dpi (Mac/docs/reports/listfeel.md §2, `listfeel-data/win1/fresh-fs.geom.txt`,
// LVM_GETITEMRECT / LVM_GETSUBITEMRECT / HDM_GETITEMRECT, and pixel measurements of the captures).
// One Windows pixel is one point here.
//
//   * rows are 19 px apart (LVIR_BOUNDS height; small icons 16 + the 12 px font's line), and the
//     header is 24 px high;
//   * the name cell: the 16 x 16 icon at x = 4 (LVIR_ICON), 1 px from the row's top; the label
//     (LVIR_LABEL, where the selection fill starts) at x = 20; the text 2 px into the label;
//   * the selection fill of the name (LVIR_SELECTBOUNDS minus the icon) is the text plus 2 px
//     before it and 6 px after it: "a.txt" (22 px) gets a 30 px fill;
//   * every other column draws its text 6 px from its edges (left- or right-aligned);
//   * the list font is Segoe UI 9 pt (WM_GETFONT: height -12, weight 400); its digits are
//     tabular. macOS has no Segoe UI. Helvetica Neue 11 pt has the same advance widths to within
//     a pixel ("2024-01-15 11:30" 88.1 pt against 88 px, "a.txt" 21.6 against 22,
//     "vol.7z.001" 50.1 against 51) and tabular digits by default, so dates and sizes line up in
//     their columns and a date fits the 100 px default width as it does on Windows. SF Pro at
//     11 pt is 5 % wider, and 17 % wider with monospaced digits (101 pt for the date).

import Cocoa

enum PanelMetrics {

    /// Row pitch (LVIR_BOUNDS height).
    static let rowHeight: CGFloat = 19
    /// SysHeader32 height.
    static let headerHeight: CGFloat = 24
    /// LVIR_ICON: x and size of the small icon in the name column, and its offset from the row top.
    static let iconX: CGFloat = 4
    static let iconSize: CGFloat = 16
    static let iconTop: CGFloat = 1
    /// LVIR_LABEL: where the label (and the selection fill) starts in the name column.
    static let labelX: CGFloat = 20
    /// The text's origin inside the label, and the fill after the text.
    static let labelTextInset: CGFloat = 2
    static let labelTrailing: CGFloat = 6
    /// The text margin of the other columns, on the side they are aligned to.
    static let subitemPadding: CGFloat = 6
    /// How far inside its frame an `NSTextField(labelWithString:)` starts its text: 0 (measured
    /// in ListFeelTests; the old layout assumed 2 and so left the name flush with the fill).
    static let textFieldInset: CGFloat = 0

    /// The list's font: Segoe UI 9 pt metrics with tabular digits (see the header comment).
    static let listFont: NSFont = NSFont(name: "HelveticaNeue", size: 11)
        ?? NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    /// The width the list font gives `text`.
    static func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: listFont]).width)
    }

    /// The selection fill of a name in a column starting at `columnMinX` (LVIR_LABEL clipped to the
    /// text: 2 px, the text, 6 px), never past the column's end.
    static func labelFill(columnMinX: CGFloat, columnMaxX: CGFloat, text: String) -> (start: CGFloat, end: CGFloat) {
        let start = min(columnMinX + labelX, columnMaxX)
        let end = min(columnMaxX, start + labelTextInset + textWidth(text) + labelTrailing)
        return (start, max(start, end))
    }
}
