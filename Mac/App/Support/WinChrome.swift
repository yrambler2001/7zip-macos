// WinChrome.swift -- the colours 7zFM 26.03's window chrome is drawn with on Windows 11 at 96 dpi,
// read from raw pixels of fresh-default captures (Mac/docs/reports/recheck.md §2,
// recheck-data/win/fresh-screen.png, two-screen.png) and from GetSysColor (syscolors.txt).
//
// 7zFM has no dark theme; in the dark appearance every colour falls back to the AppKit colour that
// plays the same role, so the dark look stays the one the port already had.

import AppKit

enum WinChrome {

    static func dynamic(_ light: NSColor, _ dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    static func gray(_ v: CGFloat) -> NSColor { rgb(v, v, v) }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    /// COLOR_BTNFACE (240,240,240): the main window's client background (around the toolbar, the
    /// splitter's 4 px, the status bar) and every dialog's background. AppKit's windowBackgroundColor
    /// is white on macOS 26.
    static let face = dynamic(gray(240), .windowBackgroundColor)

    /// COLOR_WINDOW: the list, the address band and the combo's field.
    static let window = dynamic(gray(255), .textBackgroundColor)

    /// COLOR_WINDOWTEXT / COLOR_BTNTEXT (0,0,0): list, toolbar and status-bar text. AppKit's
    /// labelColor is 85 % black.
    static let text = dynamic(gray(0), .labelColor)

    /// The themed WS_EX_CLIENTEDGE of the list: a 1 px (130,135,144) line, then 1 px of the
    /// window colour, so the header starts 2 px in (SysHeader32 @2,78 in a list @0,76).
    static let listBorder = dynamic(rgb(130, 135, 144), .separatorColor)

    /// msctls_statusbar32: a 1 px (215,215,215) line on top and the part dividers.
    static let statusLine = dynamic(gray(215), .separatorColor)

    /// The address combo's 1 px border (ComboBoxEx32, 24 px high).
    static let comboBorder = dynamic(gray(141), .separatorColor)

    /// The combo's drop-down chevron.
    static let comboArrow = dynamic(gray(96), .secondaryLabelColor)

    /// ReBar band border (RBS_BANDBORDERS) after the Up button: shadow, then light.
    static let bandBorderShadow = dynamic(gray(180), .separatorColor)
    static let bandBorderLight = dynamic(rgb(244, 247, 252), .clear)
    /// The band's bottom edge under the Up button.
    static let bandBottom = dynamic(gray(220), .separatorColor)

    // MARK: geometry (px = pt)

    /// The address band (ReBarWindow32): 24 px high.
    static let bandHeight: CGFloat = 24
    /// The Up button's toolbar (ToolbarWindow32 1002): @2,1 23 x 22 in the band.
    static let upButtonRect = NSRect(x: 2, y: 1, width: 23, height: 22)
    /// ComboBoxEx32 1003 starts at x 33 and runs to the band's right edge.
    static let comboX: CGFloat = 33
    /// The status bar: 23 px including its top line; dividers 1 px at a part's right edge - 1,
    /// rows 2..21; text ink 2 px into a part.
    static let statusHeight: CGFloat = 23
}
