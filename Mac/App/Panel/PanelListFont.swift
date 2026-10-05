// PanelListFont.swift -- the hidden `FM.ListFont` setting (feel3, the user's finding 4: "the font
// looks smaller than Windows, especially in the file list").
//
// 7zFM draws its list, header, status bar, address bar, toolbar labels and dialogs in Segoe UI
// 9 pt (WM_GETFONT: height -12 at 96 dpi). Segoe UI cannot be bundled (Microsoft's licence), so
// the port uses a stand-in; listfeel chose Helvetica Neue 11, which has Segoe's *advance widths*
// to within a pixel on three strings -- but Windows renders Segoe's caps 9 px and its x-height
// 6 px tall at that size (hinting), and Helvetica Neue 11 has 7.9 / 5.7 pt. The user is to choose;
// these are the candidates, each matched to Segoe UI two ways (measured, reports/feel3.md §4):
//
//   by height  cap height + x-height = 15 px (Windows' rendered 9 + 6)
//   by width   the summed advance widths of 23 list strings (names, sizes, dates, the header,
//              the alphabet; GetTextExtentPoint32 on the PC) equal Segoe UI's 1 378 px
//
// `defaults write com.yrambler2001.7zip FM.ListFont <key>` picks one at the next launch:
// a candidate key below, or any "<font name>:<size>" ("Arial:12.5", "system:12"). No value or an
// unknown one keeps the default, Helvetica Neue 11.

import AppKit

struct ListFontCandidate {
    let key: String
    /// A PostScript name, or "system" for the system font (SF Pro) with no tracking change.
    let fontName: String
    let size: CGFloat
    let label: String
}

enum ListFontChoice {

    static let settingsKey = "FM.ListFont"
    static let defaultFontName = "HelveticaNeue"
    static let defaultSize: CGFloat = 11

    static let candidates: [ListFontCandidate] = [
        ListFontCandidate(key: "helvetica-neue-byheight", fontName: "HelveticaNeue", size: 12.2, label: "Helvetica Neue 12.2"),
        ListFontCandidate(key: "helvetica-neue-bywidth", fontName: "HelveticaNeue", size: 11.5, label: "Helvetica Neue 11.5"),
        ListFontCandidate(key: "sf-pro-byheight", fontName: "system", size: 12.2, label: "SF Pro 12.2"),
        ListFontCandidate(key: "sf-pro-bywidth", fontName: "system", size: 10.8, label: "SF Pro 10.8"),
        ListFontCandidate(key: "arial-byheight", fontName: "ArialMT", size: 12.2, label: "Arial 12.2"),
        ListFontCandidate(key: "arial-bywidth", fontName: "ArialMT", size: 11.6, label: "Arial 11.6"),
        ListFontCandidate(key: "lucida-grande-byheight", fontName: "LucidaGrande", size: 12.0, label: "Lucida Grande 12"),
        ListFontCandidate(key: "lucida-grande-bywidth", fontName: "LucidaGrande", size: 10.5, label: "Lucida Grande 10.5"),
    ]

    /// Tests set this to render with a candidate without touching the settings.
    static var override: NSFont? { didSet { cached = nil } }

    private static var cached: NSFont?

    /// The list font for this launch.
    static var current: NSFont {
        if let override { return override }
        if let cached { return cached }
        let font = resolve(Settings.string(settingsKey))
        cached = font
        return font
    }

    static func font(name: String, size: CGFloat) -> NSFont? {
        if name.lowercased() == "system" { return NSFont.systemFont(ofSize: size) }
        return NSFont(name: name, size: size)
    }

    static func resolve(_ value: String?) -> NSFont {
        let fallback = font(name: defaultFontName, size: defaultSize)
            ?? NSFont.monospacedDigitSystemFont(ofSize: defaultSize, weight: .regular)
        guard let value, !value.isEmpty else { return fallback }
        if let c = candidates.first(where: { $0.key == value }) {
            return font(name: c.fontName, size: c.size) ?? fallback
        }
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        if parts.count == 2, let size = Double(parts[1]), size >= 6, size <= 30,
           let font = font(name: parts[0], size: CGFloat(size)) {
            return font
        }
        return fallback
    }
}
