// WinHeaderCell.swift -- a table header that draws its title in its own font (datecols).
//
// SysHeader32 draws its items in the list's / dialog's font (Segoe UI 9 on Windows, SF Pro 12.2
// here, reports/sffont.md). AppKit's NSTableHeaderCell ignores `font` and draws `stringValue` in
// the system's 11 pt header font (measured: "Modified" 45.8 pt wide in the main list's header,
// 50.2 pt in SF Pro 12.2), and the header puts its own 11 pt font back into `font` when the cell is
// installed; only an attributed title carries a font. This cell gives its title `titleFont`, its
// colour and alignment before it draws, whenever the title or font changed.

import Cocoa

class WinHeaderCell: NSTableHeaderCell {

    private static let marker = NSAttributedString.Key("SZWinHeaderTitle")

    /// The font the title is drawn in (`font` is not kept: the header resets it).
    var titleFont: NSFont?

    /// NSCell copied `titleFont` without retaining it (`CellCopy`, reports/okcancel.md).
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone)
        if let cell = copy as? WinHeaderCell { CellCopy.adopt(cell.titleFont) }
        return copy
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        applyFont()
        super.drawInterior(withFrame: cellFrame, in: controlView)
    }

    /// Re-applies `titleFont` to the title when it is not already drawn in it (a title set through
    /// `NSTableColumn.title` arrives as a plain string).
    func applyFont() {
        guard let font = titleFont else { return }
        let title = stringValue
        let current = attributedStringValue
        // A plain title reports the cell's font as its attribute too, but is not drawn in it: the
        // marker says the title is this cell's own attributed one.
        if current.length > 0, current.attribute(Self.marker, at: 0, effectiveRange: nil) != nil,
           (current.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) == font { return }
        if title.isEmpty { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byTruncatingTail
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, Self.marker: true]
        if let textColor { attributes[.foregroundColor] = textColor }
        attributedStringValue = NSAttributedString(string: title, attributes: attributes)
    }

    /// Gives `column` a header cell like its current one (title, alignment) that draws in `font`.
    static func install(on column: NSTableColumn, font: NSFont) {
        let old = column.headerCell
        let cell = WinHeaderCell(textCell: old.stringValue)
        cell.alignment = old.alignment
        cell.font = font
        cell.titleFont = font
        column.headerCell = cell
    }
}
