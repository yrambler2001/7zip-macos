// WinCombo.swift -- combo boxes drawn as Windows 11 draws 7zFM's (feel3, the user's finding 2:
// "the Language selector and the selects on the Options > 7-Zip tab: text vertically centred and
// not left-aligned like Windows").
//
// AppKit's pop-up button on macOS 26 is a grey capsule with the title centred and a double arrow;
// its combo box a rounded field with a blue button. 7zFM's are themed comctl32 v6 combo boxes,
// measured at 96 dpi on the Windows 11 PC (reports/feel3.md §2, feel3-data/win/cmb-*.png and
// wincompare-dlgfeel-{options-5,compress,copy}-win.png):
//
//   CBS_DROPDOWNLIST (a "select"), 21 px high:
//     normal    border (210) with a (188) bottom line, fill (253)
//     hover     border (0,120,212) with a (0,108,190) bottom line, fill (229,241,251)
//     focused   border (165,191,210) with a (147,171,188) bottom line, fill (248,250,253), and a
//               dotted focus rectangle from x+3, y+3 to 20 px before the right edge, y-3
//     disabled  border (234), fill (250), text (109), chevron (189)
//   CBS_DROPDOWN (an edit with a list), 21 px high:
//     normal    border (141), fill (255); focused border (0,120,212); the 19 px button part
//               (252) while the mouse is over the control
//   both:
//     the text 4 px from the left edge, its baseline 15 px below the top (cap height 9 from y+6);
//     the chevron an 8 x 4 px "v" of 1 px antialiased lines, (110), its centre 9.5 px from the
//     right edge, its top row 8 px below the top.
//
// The look is drawn here; the behaviour (menu, field editor, list) stays AppKit's.

import AppKit

enum WinCombo {

    enum State { case normal, hover, focused, disabled }

    static let height: CGFloat = 21
    static let textX: CGFloat = 4
    static let baseline: CGFloat = 15
    static let chevronFromRight: CGFloat = 9.5
    static let chevronTop: CGFloat = 8
    static let editButtonWidth: CGFloat = 19

    private static func c(_ v: CGFloat) -> NSColor { WinChrome.gray(v) }
    private static func d(_ light: NSColor, _ dark: NSColor) -> NSColor { WinChrome.dynamic(light, dark) }

    static let listFill = d(c(253), .controlBackgroundColor)
    static let listBorder = d(c(210), .separatorColor)
    static let listBottom = d(c(188), .separatorColor)
    static let hoverFill = d(WinChrome.rgb(229, 241, 251), .controlBackgroundColor)
    static let hoverBorder = d(WinChrome.rgb(0, 120, 212), .controlAccentColor)
    static let hoverBottom = d(WinChrome.rgb(0, 108, 190), .controlAccentColor)
    static let focusFill = d(WinChrome.rgb(248, 250, 253), .controlBackgroundColor)
    static let focusBorder = d(WinChrome.rgb(165, 191, 210), .keyboardFocusIndicatorColor)
    static let focusBottom = d(WinChrome.rgb(147, 171, 188), .keyboardFocusIndicatorColor)
    static let disabledFill = d(c(250), .controlBackgroundColor)
    static let disabledBorder = d(c(234), .separatorColor)
    static let disabledText = d(c(109), .disabledControlTextColor)
    static let disabledChevron = d(c(189), .tertiaryLabelColor)
    static let text = WinChrome.text
    static let chevron = d(c(110), .secondaryLabelColor)
    static let editFill = d(c(255), .textBackgroundColor)
    static let editBorder = d(c(141), .separatorColor)
    static let editFocusBorder = d(WinChrome.rgb(0, 120, 212), .controlAccentColor)
    static let editButtonHover = d(c(252), .controlBackgroundColor)

    /// A rect `r` of a view with `flipped` geometry, `dy` px from the top, `h` high.
    static func band(_ r: NSRect, flipped: Bool, top dy: CGFloat, height h: CGFloat) -> NSRect {
        NSRect(x: r.minX, y: flipped ? r.minY + dy : r.maxY - dy - h, width: r.width, height: h)
    }

    /// The box of a CBS_DROPDOWNLIST (`editable` false) or a CBS_DROPDOWN.
    static func drawBox(_ r: NSRect, flipped: Bool, editable: Bool, state: State, hovered: Bool) {
        let fill: NSColor, border: NSColor, bottom: NSColor
        if editable {
            fill = state == .disabled ? disabledFill : editFill
            border = state == .disabled ? disabledBorder : (state == .focused ? editFocusBorder : editBorder)
            bottom = border
        } else {
            switch state {
            case .normal: (fill, border, bottom) = (listFill, listBorder, listBottom)
            case .hover: (fill, border, bottom) = (hoverFill, hoverBorder, hoverBottom)
            case .focused: (fill, border, bottom) = (focusFill, focusBorder, focusBottom)
            case .disabled: (fill, border, bottom) = (disabledFill, disabledBorder, disabledBorder)
            }
        }
        fill.setFill()
        r.fill()
        if editable, hovered, state != .disabled {
            editButtonHover.setFill()
            NSRect(x: r.maxX - 1 - editButtonWidth, y: r.minY + 1, width: editButtonWidth, height: r.height - 2).fill()
        }
        border.setFill()
        r.frame(withWidth: 1)
        bottom.setFill()
        band(r, flipped: flipped, top: r.height - 1, height: 1).insetBy(dx: 1, dy: 0).fill()
        drawChevron(r, flipped: flipped, color: state == .disabled ? disabledChevron : chevron)
    }

    /// The 8 x 4 "v": rows at x 0/7, 1/6, 2/5, 3/4 (antialiased in the captures; here a 1 pt
    /// stroke through the pixel centres gives the same ink).
    static func drawChevron(_ r: NSRect, flipped: Bool, color: NSColor) {
        let cx = r.maxX - chevronFromRight
        let top = flipped ? r.minY + chevronTop + 0.5 : r.maxY - chevronTop - 0.5
        let bottom = flipped ? top + 3 : top - 3
        let path = NSBezierPath()
        path.move(to: NSPoint(x: cx - 3.5, y: top))
        path.line(to: NSPoint(x: cx, y: bottom))
        path.line(to: NSPoint(x: cx + 3.5, y: top))
        path.lineWidth = 1
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// Where a line of `font` goes so its baseline is `baseline` px below the box's top.
    static func textOrigin(_ r: NSRect, flipped: Bool, font: NSFont) -> NSPoint {
        if flipped {
            return NSPoint(x: r.minX + textX, y: r.minY + baseline - font.ascender)
        }
        return NSPoint(x: r.minX + textX, y: r.maxY - baseline + font.descender)
    }

    static func drawText(_ text: String, in r: NSRect, flipped: Bool, font: NSFont, color: NSColor, maxX: CGFloat) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let origin = textOrigin(r, flipped: flipped, font: font)
        let lineHeight = ceil(font.ascender - font.descender)
        let rect = NSRect(x: origin.x, y: origin.y, width: max(0, maxX - origin.x), height: lineHeight)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        (text as NSString).draw(at: origin, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The dotted focus rectangle of a focused CBS_DROPDOWNLIST (DrawFocusRect: 1 on, 1 off).
    static func drawFocusRect(_ r: NSRect) {
        let f = NSRect(x: r.minX + 3, y: r.minY + 3, width: r.width - 3 - 20, height: r.height - 6)
        PanelSelectionStyle.drawFocusRectangle(f, onHighlight: false)
    }
}

/// The Swift half of an `NSCell` copy (reports/okcancel.md §4).
///
/// `-[NSCell copyWithZone:]` duplicates the instance bitwise (NSCopyObject), Swift stored
/// properties included, but does not retain what they point to. AppKit copies cells all the time
/// (a header while it draws or tracks, the accessibility snapshot XCUITest and VoiceOver read, a
/// pop-up's menu), so every copy that is freed released an object its original still used: a
/// header's `titleFont` (the shared list font -- the next `PanelMetrics.listFont` crashed), the
/// address combo's icon, a drop-down's hover owner. A cell subclass with a stored reference calls
/// `adopt` for it in `copy(with:)`, which gives the copy the reference it already holds.
enum CellCopy {
    static func adopt(_ object: AnyObject?) {
        if let object { _ = Unmanaged.passUnretained(object).retain() }
    }
}

/// Lets a cell follow the mouse: the owner of the control's tracking area.
///
/// An `NSResponder`, not a plain `NSObject` (reports/okcancel.md). AppKit sends a tracking area's
/// owner the Objective-C selectors `mouseEntered:` / `mouseExited:`. As an `NSObject` with
/// `@objc func mouseEntered(with:)` this class answered `mouseEnteredWith:` instead, so the first
/// time the mouse crossed a combo of a key dialog AppKit raised "unrecognized selector". Inside
/// `NSApp.runModal(for:)` that exception unwound the modal session (caught by the context menu's
/// tracking session or by `-[NSApplication run]`) and left the dialog on screen with no session:
/// OK / Cancel called `stopModal()` for nothing, while Help and the close box still worked --
/// "SOMETIMES OK and Cancel don't work". Overriding the responder methods makes the selectors
/// right by construction, and NSResponder answers every other tracking-area message too.
final class WinComboHover: NSResponder {
    weak var control: NSControl?
    private(set) var isInside = false

    func attach(to control: NSControl) {
        self.control = control
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        control.addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) { isInside = true; control?.needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isInside = false; control?.needsDisplay = true }
}

/// CBS_DROPDOWN: an NSComboBox drawn as the Windows edit-with-list. Used by every dialog combo
/// that has an edit (Copy / Move, Extract, Add to Archive's name and volume, Split, Link, Create
/// Folder / File).
final class WinComboBox: NSComboBox {
    override class var cellClass: AnyClass? {
        get { WinComboBoxCell.self }
        set { _ = newValue }
    }

    let hover = WinComboHover()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        focusRingType = .none
        hover.attach(to: self)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        focusRingType = .none
        hover.attach(to: self)
    }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: WinCombo.height) }

    override func draw(_ dirtyRect: NSRect) {
        cell?.draw(withFrame: bounds, in: self)
    }
}

final class WinComboBoxCell: NSComboBoxCell {

    /// The text area: 4 px in (the field editor adds its own 2 px line padding), up to the button,
    /// one line whose baseline is 15 px below the top.
    func textRect(_ frame: NSRect, in view: NSView) -> NSRect {
        let font = self.font ?? DialogMetrics.font
        let origin = WinCombo.textOrigin(frame, flipped: view.isFlipped, font: font)
        let h = ceil(font.ascender - font.descender) + 1
        let y = view.isFlipped ? origin.y : origin.y - 1
        return NSRect(x: origin.x - 2, y: y, width: max(0, frame.maxX - WinCombo.editButtonWidth - 1 - (origin.x - 2)), height: h)
    }

    /// NSComboBoxCell insets the rect drawingRect(forBounds:) returns once more for its bezel
    /// before it places the field editor (measured in DlgFeelSnapshots' Copy dialog: the
    /// selection started 5 px right of and 2 px below the text rect), so the editor's rect is the
    /// text rect moved back by that much -- the selection then starts 3 px in and 3 px down, as on
    /// Windows (wincompare-dlgfeel-copy-win.png).
    static let bezelShift = NSSize(width: -5, height: -2)

    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        guard let view = controlView else { return rect }
        let r = textRect(rect, in: view)
        let dy = view.isFlipped ? Self.bezelShift.height : -Self.bezelShift.height
        return NSRect(x: r.minX + Self.bezelShift.width, y: r.minY + dy, width: r.width - Self.bezelShift.width, height: r.height)
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect { drawingRect(forBounds: rect) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let control = controlView as? NSControl
        let editing = control?.currentEditor() != nil
        let state: WinCombo.State = !isEnabled ? .disabled : (editing ? .focused : .normal)
        let hovered = (controlView as? WinComboBox)?.hover.isInside ?? false
        WinCombo.drawBox(cellFrame, flipped: controlView.isFlipped, editable: true, state: state, hovered: hovered)
        guard !editing else { return }
        WinCombo.drawText(stringValue, in: cellFrame, flipped: controlView.isFlipped, font: font ?? DialogMetrics.font,
                          color: isEnabled ? WinCombo.text : WinCombo.disabledText,
                          maxX: cellFrame.maxX - WinCombo.editButtonWidth - 1)
    }

    // The field editor's frame comes from drawingRect(forBounds:) above (NSTextFieldCell asks
    // it in edit / select), so edit and select get the whole cell rect.
}
