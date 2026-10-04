// PanelSelectionStyle.swift -- how the panel's list draws selection, focus and grid lines, matched
// to the real 7zFM 25.01 list control on Windows 11 (Mac/docs/reports/selcolors.md, captures in
// selcolors-data/win/). The list is a plain SysListView32 (Panel.cpp:391-416): no Explorer theme,
// no LVS_SHOWSELALWAYS (it is commented out there), so:
//
//   * a selected item is filled with COLOR_HIGHLIGHT (0,120,212) and drawn in COLOR_HIGHLIGHTTEXT
//     (white), and its icon is blended 50 % with the highlight (ILD_BLEND50: a grey 173 icon pixel
//     reads 86,146,192);
//   * LVS_EX_FULLROWSELECT on (Options > Settings "Full row select", FullRow): the fill runs from
//     the label (after the icon) to the end of the row; off: only the name's text is filled, and the
//     other columns keep their normal colours. The macOS port used to fill only the name column but
//     let AppKit draw every cell in "emphasized" white, which was the white-on-white bug;
//   * the selection is drawn only while the list has the keyboard focus. When the other panel, the
//     address bar or another window has it, 7zFM draws no selection at all (inactive panel and
//     inactive window captures); the status bar still counts it;
//   * the focused item has the dotted focus rectangle, around the label (or the full-row fill), in
//     XOR: black dots on white, (255,135,43) dots on the highlight;
//   * LVS_EX_GRIDLINES: 1 px lines in (240,240,240);
//   * no hover (hot-track) highlight: LVS_EX_TRACKSELECT is set only with "Single-click".
//
// Dark mode has no Windows counterpart (7zFM has no dark theme). The port keeps the same highlight
// and white text there (contrast 4.5:1, the WCAG AA minimum), so a selection looks the same in both
// appearances; grid lines become a faint white, the AlternativeSelection pink a dark red so the
// white text stays readable (01 §3.6).

import Cocoa

enum PanelSelectionStyle {

    /// COLOR_HIGHLIGHT on Windows 11, measured in every capture (selcolors.md §2).
    static let highlight = NSColor(srgbRed: 0, green: 120 / 255, blue: 212 / 255, alpha: 1)
    /// COLOR_HIGHLIGHTTEXT.
    static let highlightText = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    /// The XOR focus rectangle over the highlight.
    static let focusOnHighlight = NSColor(srgbRed: 1, green: 135 / 255, blue: 43 / 255, alpha: 1)
    /// The XOR focus rectangle over the list background: black in light, white in dark.
    static let focusOnBackground = WinChrome.text            // (0,0,0) dots on the white list
    /// LVS_EX_GRIDLINES.
    static let grid = dynamic(light: NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 240 / 255, alpha: 1),
                              dark: NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.12))
    /// AlternativeSelection rows (OnCustomDraw, RGB(255,192,192), PanelListNotify.cpp:721).
    static let mySelected = dynamic(light: NSColor(srgbRed: 1, green: 192 / 255, blue: 192 / 255, alpha: 1),
                                    dark: NSColor(srgbRed: 120 / 255, green: 48 / 255, blue: 48 / 255, alpha: 1))
    /// Text of a row that is not highlighted: kpidIsDeleted items in red, everything else normal.
    /// COLOR_WINDOWTEXT (0,0,0), not AppKit's 85 % labelColor (recheck §2); deleted items
    /// RGB(255,0,0) (OnCustomDraw).
    static func normalText(isDeleted: Bool) -> NSColor { isDeleted ? deletedText : WinChrome.text }
    static let deletedText = WinChrome.dynamic(WinChrome.rgb(255, 0, 0), .systemRed)
    /// The name label's padding around its text inside the fill (the LVIR_LABEL rect).
    static let labelPadding: CGFloat = 2

    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// ILD_BLEND50 with the highlight: the icon's opaque pixels half icon, half highlight.
    static func blended(_ image: NSImage) -> NSImage {
        let result = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            highlight.withAlphaComponent(0.5).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
        result.accessibilityDescription = image.accessibilityDescription
        return result
    }

    /// A dotted 1 px focus rectangle (DrawFocusRect) just inside `rect`.
    static func drawFocusRectangle(_ rect: NSRect, onHighlight: Bool) {
        guard rect.width > 2, rect.height > 2 else { return }
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.setLineDash([1, 1], count: 2, phase: 0)
        (onHighlight ? focusOnHighlight : focusOnBackground).setStroke()
        path.stroke()
    }
}

/// A Details cell. AppKit sets `backgroundStyle = .emphasized` on every cell of a selected row,
/// which turns `labelColor` text white whether or not anything blue is drawn behind it; with
/// "Full row select" off only the name has a fill, so Size, Modified and the rest were white on
/// white (the selcolors bug). The cell therefore stays `.normal` and takes its colours from the
/// panel's own rule, `PanelViewController.cellIsHighlighted(row:isName:)`.
final class PanelCellView: NSTableCellView {

    var isDeleted = false
    var isNameCell = false
    /// Name cells: makes the text field span the column while it is edited in place.
    var editingConstraint: NSLayoutConstraint?
    /// The unblended icon; `imageView.image` is this or its ILD_BLEND50 form.
    var baseImage: NSImage?
    private(set) var isHighlighted = false

    override var backgroundStyle: NSView.BackgroundStyle {
        get { super.backgroundStyle }
        set { super.backgroundStyle = .normal }
    }

    func applyColors(highlighted: Bool) {
        isHighlighted = highlighted
        textField?.textColor = highlighted ? PanelSelectionStyle.highlightText
                                           : PanelSelectionStyle.normalText(isDeleted: isDeleted)
        if isNameCell, let baseImage {
            imageView?.image = highlighted ? PanelSelectionStyle.blended(baseImage) : baseImage
        }
    }
}

// MARK: - The panel's side of the rule

extension PanelViewController {

    /// GetFocus() == the list: the window is key and its first responder is this panel's list
    /// (the Details table or the icon view). Only then is the selection drawn.
    var listHasKeyboardFocus: Bool {
        if let forced = listFocusOverride { return forced }
        guard isViewLoaded, let window = view.window, window.isKeyWindow else { return false }
        let responder = window.firstResponder
        return responder === tableView || (iconView != nil && responder === iconView.collectionView)
    }

    /// A Details cell is drawn white on the highlight: its row is selected, the list has the focus,
    /// and the fill covers it (the name always, the other columns with FullRow).
    func cellIsHighlighted(row: Int, isName: Bool) -> Bool {
        guard listHasKeyboardFocus, tableView.isRowSelected(row) else { return false }
        return isName || Settings.fullRow
    }

    /// Re-colour and redraw every visible row and icon after a selection, focus or setting change.
    func refreshSelectionAppearance() {
        guard isViewLoaded else { return }
        tableView.enumerateAvailableRowViews { view, _ in
            (view as? PanelRowView)?.updateCellColors()
            view.needsDisplay = true
        }
        iconView?.refreshItemAppearance()
    }
}
