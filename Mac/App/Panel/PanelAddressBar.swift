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

    /// VIEW_PARENTFOLDER of comctl32's IDB_VIEW_SMALL_COLOR (Panel.cpp:447, 490-491): Windows
    /// artwork, not in the 7-Zip sources, so it is drawn here as a look-alike in the same 16 x 16
    /// cell (recheck2.md section 3; recheck-data/win/fresh-screen.png x 14...29, y 108...123): an
    /// open yellow folder -- the back with its tab at the left, the front flap slanting up to the
    /// right -- and a green arrow over it, its head at the top (tip at x 7.5), its stem leaning
    /// down to the left into the folder. Disabled: the grey the toolbar gives a disabled bitmap.
    static func drawIcon(at o: NSPoint, enabled: Bool) {
        func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
            enabled ? WinChrome.rgb(r, g, b) : WinChrome.gray((r * 0.3 + g * 0.59 + b * 0.11) * 0.55 + 100)
        }
        func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: o.x + x, y: o.y + y) }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // the folder's back: tab at x 2...4 on row 4, top edge on row 5, left edge x 1 down to row 15
        let back = NSBezierPath()
        back.move(to: p(1.5, 15.5)); back.line(to: p(1.5, 5.5)); back.line(to: p(2.5, 4.5))
        back.line(to: p(4.5, 4.5)); back.line(to: p(5.5, 5.5)); back.line(to: p(13.5, 5.5))
        back.line(to: p(13.5, 8.5)); back.line(to: p(11.5, 15.5)); back.close()
        NSGradient(starting: c(255, 253, 214), ending: c(255, 236, 160))?.draw(in: back, angle: 90)
        c(228, 187, 66).setStroke()
        back.lineWidth = 1
        back.stroke()

        // the front flap: from (2,9) up to (13.5,7.5), down to (11.5,13.5) and (1.5,15.5)
        let flap = NSBezierPath()
        flap.move(to: p(2.5, 9.0)); flap.line(to: p(13.6, 7.6)); flap.line(to: p(11.6, 13.4))
        flap.line(to: p(2.0, 15.4)); flap.close()
        NSGradient(starting: c(255, 248, 190), ending: c(255, 226, 130))?.draw(in: flap, angle: 90)
        c(232, 196, 84).setStroke()
        flap.lineWidth = 0.9
        flap.stroke()
        // its darker bottom edge (214,168,0)
        let bottom = NSBezierPath()
        bottom.move(to: p(2.6, 15.0)); bottom.line(to: p(11.4, 13.1))
        bottom.lineWidth = 1
        c(214, 168, 0).setStroke()
        bottom.stroke()

        // the arrow: tip (7.6, 0.3), head corners on row 4 at x 4.8 and 13.8, the stem from
        // x 7.9...11.6 under the head leaning to x 6.8...8.8 at row 12.6
        let arrow = NSBezierPath()
        arrow.move(to: p(7.6, 0.3))
        arrow.line(to: p(13.9, 4.9))
        arrow.line(to: p(11.7, 4.9))
        arrow.curve(to: p(9.0, 12.7), controlPoint1: p(11.6, 8.0), controlPoint2: p(10.2, 10.8))
        arrow.line(to: p(6.7, 12.7))
        arrow.curve(to: p(8.0, 4.9), controlPoint1: p(7.6, 10.4), controlPoint2: p(8.1, 7.6))
        arrow.line(to: p(4.8, 4.9))
        arrow.close()
        let gradient = NSGradient(colors: [c(0, 134, 4), c(120, 222, 74), c(150, 238, 104), c(40, 160, 30)],
                                  atLocations: [0, 0.45, 0.6, 1], colorSpace: .sRGB)
        gradient?.draw(in: arrow, angle: 0)
        c(0, 122, 3).setStroke()
        arrow.lineWidth = 0.9
        arrow.lineJoinStyle = .round
        arrow.stroke()
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
