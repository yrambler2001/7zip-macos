// PanelAddressBar.swift -- the panel's address band as 7zFM 26.03 draws it (Panel.cpp:440-580,
// CreateToolbarEx + ComboBoxEx32 in a ReBar; 01 §1.2), measured on Windows 11 at 96 dpi
// (Mac/docs/reports/recheck.md §2, recheck-data/win/fresh.txt and fresh-screen.png):
//
//   * the band: 24 px, white (the ReBar's band), no highlight for the active panel -- 7zFM marks
//     the active panel only with the keyboard focus;
//   * the Up button (ToolbarWindow32 1002, TBSTYLE_FLAT): @2,1 23 x 22, the comctl32
//     VIEW_PARENTFOLDER bitmap (a folder with a green up arrow), flat with the toolbar's hover and
//     pressed rectangles, disabled at the root (PanelItems.cpp:523);
//   * a RBS_BANDBORDERS edge after it: a (180) and a (244,247,252) column at x 31 / 32, and a (220)
//     line under it;
//   * the combo (ComboBoxEx32 1003): from x 33 to the band's end, 24 px, a 1 px (141) border, white,
//     the folder's 16 px icon 3 px in, the text 24 px in, a thin chevron near the right edge.

import AppKit

/// The Up button: flat, drawn here (no AppKit bezel).
final class PanelUpButton: NSButton {
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        setButtonType(.momentaryChange)
        refusesFirstResponder = true            // a toolbar button never takes the keyboard focus
        title = ""
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { WinChrome.upButtonRect.size }

    override var isEnabled: Bool { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = isHighlighted && isEnabled
        if isEnabled, pressed || isHovered {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            (pressed ? FMToolbarColors.pressedFill : FMToolbarColors.hoverFill).setFill()
            path.fill()
            (pressed ? FMToolbarColors.pressedBorder : FMToolbarColors.hoverBorder).setStroke()
            path.stroke()
        }
        let shift: CGFloat = pressed ? FMToolbarView.pressedOffset.width : 0
        let origin = NSPoint(x: floor((bounds.width - 16) / 2) + shift, y: floor((bounds.height - 16) / 2))
        Self.drawIcon(at: origin, enabled: isEnabled)
    }

    /// A folder with a green arrow pointing up, in the 16 x 16 cell of VIEW_PARENTFOLDER: the folder
    /// at the left and bottom, the arrow over its right half (colours from the capture). Drawn, not
    /// copied: the bitmap is part of Windows. Disabled: the grey the toolbar gives a disabled bitmap.
    static func drawIcon(at o: NSPoint, enabled: Bool) {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            enabled ? WinChrome.rgb(r, g, b) : WinChrome.gray((r * 0.3 + g * 0.59 + b * 0.11) * 0.55 + 100)
        }
        func px(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) { NSRect(x: o.x + x, y: o.y + y, width: w, height: h).fill() }
        // folder body: outline (221,175,52), fill (255,249,147) shading to (255,217,108)
        c(221, 175, 52).setFill()
        px(2, 4, 4, 1)                  // tab top
        px(1, 5, 1, 10); px(1, 15, 12, 1)
        px(6, 5, 7, 1)
        px(12, 6, 1, 9)
        c(255, 249, 147).setFill(); px(2, 6, 10, 4)
        c(255, 230, 140).setFill(); px(2, 10, 10, 3)
        c(255, 217, 108).setFill(); px(2, 13, 10, 2)
        c(255, 254, 199).setFill(); px(2, 5, 4, 1)
        // arrow: dark green outline (7,109,4), body (102,204,51) with a lighter core (126,227,75)
        c(7, 109, 4).setFill()
        px(9, 0, 2, 1); px(8, 1, 1, 1); px(11, 1, 1, 1)
        px(7, 2, 1, 1); px(12, 2, 1, 1); px(6, 3, 1, 1); px(13, 3, 1, 1)
        px(6, 4, 3, 1); px(11, 4, 3, 1)
        px(8, 5, 1, 7); px(11, 5, 1, 6); px(9, 12, 2, 1)
        c(102, 204, 51).setFill()
        px(9, 1, 2, 1); px(8, 2, 4, 1); px(7, 3, 6, 1); px(9, 4, 2, 8)
        c(126, 227, 75).setFill(); px(9, 3, 1, 8)
    }
}

/// The address combo's look: a ComboBoxEx32 border, the folder icon inside, the text 24 px in, a
/// flat chevron. The behaviour (editing, the drop-down list) stays NSComboBox's.
final class AddressComboCell: NSComboBoxCell {
    var icon: NSImage?

    /// Where the text goes: 24 px from the left (the Edit 1003 at x 57 in a combo at x 33), the
    /// arrow's 18 px at the right kept clear.
    static let textInsetLeft: CGFloat = 24
    static let arrowWidth: CGFloat = 18

    private func textRect(_ frame: NSRect) -> NSRect {
        var r = frame
        r.origin.x += Self.textInsetLeft - 2          // the field editor's own 2 pt line padding
        r.size.width = max(0, frame.width - Self.textInsetLeft - Self.arrowWidth)
        let h: CGFloat = 16
        r.origin.y = frame.minY + floor((frame.height - h) / 2)
        r.size.height = h
        return r
    }

    override func drawingRect(forBounds rect: NSRect) -> NSRect { textRect(rect) }
    override func titleRect(forBounds rect: NSRect) -> NSRect { textRect(rect) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        WinChrome.window.setFill()
        cellFrame.fill()
        WinChrome.comboBorder.setFill()
        cellFrame.frame(withWidth: 1)
        if let icon {
            let flipped = controlView.isFlipped
            let y = flipped ? cellFrame.minY + 4 : cellFrame.maxY - 4 - 16
            icon.draw(in: NSRect(x: cellFrame.minX + 3, y: y, width: 16, height: 16), from: .zero,
                      operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        // the chevron: a 1 px "v", 9 px wide, 5 px tall, centred in the last 18 px
        let cx = cellFrame.maxX - 9.5, cy = cellFrame.midY
        let path = NSBezierPath()
        let dy: CGFloat = controlView.isFlipped ? 1 : -1
        path.move(to: NSPoint(x: cx - 4, y: cy - 2 * dy))
        path.line(to: NSPoint(x: cx, y: cy + 2 * dy))
        path.line(to: NSPoint(x: cx + 4, y: cy - 2 * dy))
        path.lineWidth = 1
        WinChrome.comboArrow.setStroke()
        path.stroke()
        drawInterior(withFrame: cellFrame, in: controlView)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // while editing, the field editor draws the text
        guard (controlView as? NSControl)?.currentEditor() == nil else { return }
        super.drawInterior(withFrame: textRect(cellFrame), in: controlView)
    }

    override func edit(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                       delegate: Any?, event: NSEvent?) {
        super.edit(withFrame: textRect(rect), in: controlView, editor: textObj, delegate: delegate, event: event)
    }

    override func select(withFrame rect: NSRect, in controlView: NSView, editor textObj: NSText,
                         delegate: Any?, start selStart: Int, length selLength: Int) {
        super.select(withFrame: textRect(rect), in: controlView, editor: textObj, delegate: delegate,
                     start: selStart, length: selLength)
    }
}

/// The combo itself: draws through `AddressComboCell` and has the band's 24 px height.
final class AddressComboBox: NSComboBox {
    override class var cellClass: AnyClass? {
        get { AddressComboCell.self }
        set { _ = newValue }
    }

    var addressCell: AddressComboCell? { cell as? AddressComboCell }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: WinChrome.bandHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        cell?.draw(withFrame: bounds, in: self)
    }
}
