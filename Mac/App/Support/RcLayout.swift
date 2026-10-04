// RcLayout.swift -- dialogs laid out from their Windows .rc templates (dlgfeel).
//
// Every 7zFM / 7zG dialog is a resource template in dialog units (DLUs). Windows creates each
// control at MulDiv(x, baseX, 4), MulDiv(y, baseY, 8) with the size converted the same way, where
// (baseX, baseY) are the dialog font's base units. 7zFM's dialogs use "MS Shell Dlg" 8 pt, whose
// base units at 96 dpi are 6 x 13 (measured: IDD_ABOUT's 160 x 160 DLU template is a 240 x 260 px
// client area, IDD_COMPRESS's 416 x 336 one is 624 x 546; reports/dlgfeel.md section 1). One
// Windows pixel at 96 dpi is one macOS point, as everywhere else in the port.
//
// `RcTemplates.all` (generated from the .rc files by Mac/scripts/make-rc-layout.py) holds every
// template; `RcDialog` turns one into point rects, and `RcPlace` puts an AppKit control on such a
// rect so that what it draws lands where the Windows control draws: the text of a static at the
// rect's left edge, a check box's box at the left of its rect, a combo box 21 px high, and so on.
// The offsets were measured from Windows 11 captures of 7zFM 26.03 and from renders of the AppKit
// controls (DlgFeelTests).

import AppKit

// MARK: - the template model (filled by RcTemplates.swift)

enum RcKind {
    case ltext, rtext, ctext, push, defPush, group, check, radio, edit, comboList, comboEdit
    case listBox, listView, icon, upDown, progress, other
}

struct RcControl {
    let id: Int
    let kind: RcKind
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let text: String
    var password: Bool = false
    var multiline: Bool = false
}

struct RcTemplate {
    let id: Int
    let caption: String
    let width: Int
    let height: Int
    /// WS_THICKFRAME in the template's style (MY_MODAL_RESIZE_DIALOG_STYLE).
    let resizable: Bool
    let controls: [RcControl]
}

enum RcTemplates {
    static func template(_ id: Int) -> RcTemplate {
        guard let t = all[id] else { preconditionFailure("no .rc template \(id)") }
        return t
    }
}

// MARK: - dialog units

enum DLU {
    /// The base units of MS Shell Dlg 8 pt at 96 dpi.
    static let baseX = 6
    static let baseY = 13

    /// Windows' MulDiv: a * b / c rounded half away from zero.
    static func mulDiv(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a * b
        return p >= 0 ? (p + c / 2) / c : -((-p + c / 2) / c)
    }

    static func x(_ v: Int) -> CGFloat { CGFloat(mulDiv(v, baseX, 4)) }
    static func y(_ v: Int) -> CGFloat { CGFloat(mulDiv(v, baseY, 8)) }
}

/// One template in points, top-left origin (a flipped container), exactly the pixels Windows uses.
struct RcDialog {
    let template: RcTemplate

    init(_ id: Int) { template = RcTemplates.template(id) }

    /// The client area.
    var size: NSSize { NSSize(width: DLU.x(template.width), height: DLU.y(template.height)) }

    /// The `nth` control with this id (several statics share -1).
    func control(_ id: Int, _ nth: Int = 0) -> RcControl {
        let matches = template.controls.filter { $0.id == id }
        guard nth < matches.count else { preconditionFailure("template \(template.id) has no control \(id) #\(nth)") }
        return matches[nth]
    }

    func rect(_ id: Int, _ nth: Int = 0) -> NSRect { Self.rect(of: control(id, nth)) }

    static func rect(of c: RcControl) -> NSRect {
        NSRect(x: DLU.x(c.x), y: DLU.y(c.y), width: DLU.x(c.width), height: DLU.y(c.height))
    }

    /// The margin GetMargins(8) gives OnSize: 8 DLUs.
    static var margin: NSSize { NSSize(width: DLU.x(8), height: DLU.y(8)) }
}

// MARK: - the dialog font and colours

enum DialogMetrics {
    /// 7zFM 26.03 draws its dialog text in Segoe UI 9 pt (the captures: cap height 9, "Compression
    /// level:" 98 px). macOS has no Segoe UI; Helvetica Neue 11 has its advance widths to within a
    /// pixel (the same choice as the list, PanelMetrics.listFont, reports/listfeel.md section 2).
    static let font: NSFont = PanelMetrics.listFont
    static let boldFont: NSFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)

    /// A group box's frame: (227, 227, 227) on the (243, 243, 243) dialog face in the light theme.
    static let groupLine = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.16) : NSColor(srgbRed: 227 / 255, green: 227 / 255, blue: 227 / 255, alpha: 1)
    }
}

// MARK: - containers

/// The client area of a dialog: flipped, so frames read like the .rc (top-left origin).
class RcFormView: NSView {
    override var isFlipped: Bool { true }
}

/// GROUPBOX (BS_GROUPBOX) as Windows 11 draws it: a one-pixel frame whose top edge runs through the
/// middle of the title's first line, the title 8 px in, and the frame cut 1 px either side of it.
/// Measured on IDD_COMPRESS's "Options" (4011): rect 336,130 276x104 -> top line y 136, bottom
/// line y 232, right line x 611, title ink from x 345, gap x 343-382.
final class WinGroupBox: NSView {
    let titleField: NSTextField

    var title: String {
        get { titleField.stringValue }
        set { titleField.stringValue = newValue; needsLayout = true; needsDisplay = true }
    }

    init(title: String) {
        titleField = RcPlace.makeLabel(title)
        super.init(frame: .zero)
        addSubview(titleField)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let w = min(ceil(titleField.attributedStringValue.size().width), max(0, bounds.width - 16))
        titleField.frame = RcPlace.labelFrame(NSRect(x: 8, y: 0, width: w, height: 13))
        setAccessibilityLabel(titleField.stringValue)
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        guard r.width > 2, r.height > 8 else { return }
        let top: CGFloat = 6, bottom = r.height - 2, right = r.width - 1
        let titleWidth = titleField.stringValue.isEmpty ? 0 : ceil(titleField.attributedStringValue.size().width)
        let gapFrom: CGFloat = 7, gapTo = titleWidth > 0 ? 8 + titleWidth + 2 : 7
        DialogMetrics.groupLine.setFill()
        // top, split around the title
        NSRect(x: 0, y: top, width: gapFrom, height: 1).fill()
        if right + 1 > gapTo { NSRect(x: gapTo, y: top, width: right + 1 - gapTo, height: 1).fill() }
        NSRect(x: 0, y: top, width: 1, height: bottom - top + 1).fill()           // left
        NSRect(x: right, y: top, width: 1, height: bottom - top + 1).fill()       // right
        NSRect(x: 0, y: bottom, width: right + 1, height: 1).fill()               // bottom
    }
}

// MARK: - placing AppKit controls on Windows rects

enum RcPlace {

    // A static's text starts at its rect's left edge on Windows; an NSTextField label draws it
    // `labelInset` in from its frame, so the frame starts that much to the left.
    static let labelInset: CGFloat = 2
    // The first baseline of a static's 9 pt Segoe UI line is 11 px below the rect's top on Windows
    // (cap top 2 px below, cap height 9). The label's frame top is moved so Helvetica Neue's
    // baseline lands there.
    static let labelTop: CGFloat = 1

    static func makeLabel(_ text: String, alignment: NSTextAlignment = .left) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = DialogMetrics.font
        f.alignment = alignment
        f.lineBreakMode = .byClipping
        f.cell?.truncatesLastVisibleLine = false
        return f
    }

    /// A multi-line static (LTEXT taller than one line): Windows wraps it at word boundaries.
    static func makeWrappingLabel(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = DialogMetrics.font
        f.isSelectable = false
        return f
    }

    static func labelFrame(_ r: NSRect) -> NSRect {
        NSRect(x: r.minX - labelInset, y: r.minY + labelTop, width: r.width + 2 * labelInset, height: max(r.height, 16))
    }

    static func label(_ f: NSTextField, _ r: NSRect) {
        if f.font == nil || f.font == NSFont.systemFont(ofSize: NSFont.systemFontSize) { f.font = DialogMetrics.font }
        if f.maximumNumberOfLines != 1, f.lineBreakMode == .byWordWrapping || f.cell?.wraps == true {
            f.preferredMaxLayoutWidth = r.width
        }
        f.frame = labelFrame(r)
    }

    /// BS_AUTOCHECKBOX / BS_AUTORADIOBUTTON: the 13 px box at the rect's left edge, centred
    /// vertically, the text 3 px after it.
    static let checkX: CGFloat = 0
    static let checkY: CGFloat = 0

    static func check(_ b: NSButton, _ r: NSRect) {
        b.font = DialogMetrics.font
        b.controlSize = .small
        b.frame = NSRect(x: r.minX + checkX, y: r.minY + checkY, width: r.width, height: r.height)
    }

    /// CBS_DROPDOWNLIST: a 21 px box at the rect's top (the template height is the drop-down's).
    static let comboHeight: CGFloat = 21

    static func popup(_ p: NSPopUpButton, _ r: NSRect) {
        p.font = DialogMetrics.font
        p.controlSize = .small
        p.frame = NSRect(x: r.minX, y: r.minY, width: r.width, height: comboHeight)
    }

    /// CBS_DROPDOWN: an edit field with the list button, also 21 px.
    static func combo(_ c: NSComboBox, _ r: NSRect) {
        c.font = DialogMetrics.font
        c.controlSize = .small
        let h = max(comboHeight, c.intrinsicContentSize.height)
        c.frame = NSRect(x: r.minX, y: r.minY - ((h - comboHeight) / 2).rounded(.down), width: r.width, height: h)
    }

    /// EDITTEXT: the rect as it is (14 DLU = 23 px for a one-line field).
    static func edit(_ f: NSTextField, _ r: NSRect) {
        f.font = DialogMetrics.font
        f.controlSize = .small
        // The bezel draws a 1 px shadow outside its frame; Windows' border is the rect's edge.
        f.frame = r.insetBy(dx: 1, dy: 1)
    }

    /// PUSHBUTTON / DEFPUSHBUTTON: native push buttons (the user's exception) on the Windows rect.
    static func button(_ b: NSButton, _ r: NSRect) {
        b.font = DialogMetrics.font
        // The push bezel fills its frame's width; Windows 11 draws its button 1 px inside the rect.
        b.frame = r.insetBy(dx: 1, dy: 0)
    }

    static func group(_ g: WinGroupBox, _ r: NSRect) {
        g.frame = r
    }

    /// Puts a template's control rect on `view` according to the template's kind.
    static func place(_ view: NSView, _ c: RcControl) {
        let r = RcDialog.rect(of: c)
        switch (view, c.kind) {
        case (let f as NSTextField, .ltext), (let f as NSTextField, .rtext), (let f as NSTextField, .ctext):
            label(f, r)
        case (let b as NSButton, .check), (let b as NSButton, .radio):
            check(b, r)
        case (let p as NSPopUpButton, _):
            popup(p, r)
        case (let cb as NSComboBox, _):
            combo(cb, r)
        case (let f as NSTextField, .edit):
            edit(f, r)
        case (let b as NSButton, _):
            button(b, r)
        case (let g as WinGroupBox, _):
            group(g, r)
        default:
            view.frame = r
        }
    }
}

extension RcFormView {
    /// Adds `view` at the rect of control `id` (the `nth` with that id) of `dialog`.
    @discardableResult
    func add<V: NSView>(_ view: V, _ dialog: RcDialog, _ id: Int, _ nth: Int = 0) -> V {
        if view.superview !== self { addSubview(view) }
        RcPlace.place(view, dialog.control(id, nth))
        return view
    }
}
