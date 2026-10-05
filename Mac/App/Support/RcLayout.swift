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

    /// Each added control's place in its template: Windows' Tab order is the template's control
    /// order (the dialog's z-order) over the WS_TABSTOP controls (recheck §6, measured with Tab on
    /// every 7zFM dialog). `install` turns it into the window's key view loop.
    var templateOrder: [ObjectIdentifier: (view: NSView, order: Double)] = [:]

    /// Puts a view placed by hand (a list in its scroll view, a control with no template entry)
    /// into the Tab order at control `id`'s place, or just after it.
    func tabStop(_ view: NSView, _ dialog: RcDialog, _ id: Int, nth: Int = 0, after: Bool = false) {
        let indices = dialog.template.controls.indices.filter { dialog.template.controls[$0].id == id }
        guard nth < indices.count else { return }
        templateOrder[ObjectIdentifier(view)] = (view, Double(indices[nth]) + (after ? 0.5 : 0))
    }

    /// OnSize: called with the new client size whenever the window resizes the form (the
    /// resizable dialogs move their controls here, as their CDialog::OnSize does).
    var onResize: ((NSSize) -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?(newSize)
    }
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

    /// EnableItem on a group box greys its title.
    var isEnabled = true {
        didSet { titleField.textColor = isEnabled ? .labelColor : .disabledControlTextColor }
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
        RcPlace.label(titleField, NSRect(x: 8, y: 0, width: w, height: 13))
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

    /// A one-line static is 13 px; its frame is 14 high so the first line's descenders show and
    /// nothing of a wrapped second line does. A taller static keeps its height.
    static func labelFrame(_ r: NSRect) -> NSRect {
        NSRect(x: r.minX - labelInset, y: r.minY + labelTop, width: r.width + 2 * labelInset,
               height: r.height <= 13 ? 14 : r.height)
    }

    /// LTEXT / RTEXT / CTEXT (SS_LEFT ...): Windows breaks the text at word boundaries inside the
    /// rect and shows only the lines that fit -- a one-line static whose text is too long shows
    /// the words that fit on its first line, never an ellipsis.
    static func label(_ f: NSTextField, _ r: NSRect) {
        let bold = f.font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
        f.font = bold ? DialogMetrics.boldFont : DialogMetrics.font
        f.cell?.wraps = true
        f.cell?.truncatesLastVisibleLine = false
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 0
        f.preferredMaxLayoutWidth = r.width
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
        WinPopUpButtonCell.adopt(p)
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
        let indices = dialog.template.controls.indices.filter { dialog.template.controls[$0].id == id }
        if nth < indices.count { templateOrder[ObjectIdentifier(view)] = (view, Double(indices[nth])) }
        return view
    }
}

extension RcPlace {
    /// Makes `form` the window's client area at `size` and centres the window on its owner, as
    /// DS_CENTER does (DialogKit.center). A fixed dialog cannot be resized; a resizable one starts
    /// at its template size, which is also its smallest (OnSize never lays out anything smaller).
    static func install(_ form: NSView, in window: NSWindow, size: NSSize, parent: NSWindow?) {
        form.frame = NSRect(origin: .zero, size: size)
        window.contentView = form
        window.setContentSize(size)
        if window.styleMask.contains(.resizable) {
            window.contentMinSize = size
        } else {
            window.contentMinSize = size
            window.contentMaxSize = size
        }
        DialogKit.center(window, over: parent)
        (form as? RcFormView)?.applyTemplateTabOrder(in: window)
    }
}

extension RcFormView {
    /// The key view loop in template order: edit fields, combos, buttons, check boxes, lists;
    /// never a static. A Tab from the last goes back to the first, as in a Win32 dialog.
    func applyTemplateTabOrder(in window: NSWindow) {
        var previousWasRadio = false
        let stops: [NSView] = templateOrder.values.sorted { $0.order < $1.order }.compactMap { entry in
            let v = entry.view
            // A run of radio buttons is one Tab stop (WS_GROUP), arrows move inside it.
            let isRadio = (v as? NSButton).map { ($0.cell?.value(forKey: "buttonType") as? UInt) == 4 } ?? false
            defer { previousWasRadio = isRadio }
            if isRadio && previousWasRadio { return nil }
            if let scroll = v as? NSScrollView { return scroll.documentView }
            if let field = v as? NSTextField, !(v is NSComboBox) { return field.isEditable || field.isSelectable ? field : nil }
            if v is NSControl || v is NSTableView || v is NSCollectionView { return v }
            return nil
        }
        guard stops.count > 1 else { return }
        window.autorecalculatesKeyViewLoop = false
        for (i, v) in stops.enumerated() { v.nextKeyView = stops[(i + 1) % stops.count] }
    }
}

/// A drop-down list (CBS_DROPDOWNLIST) as Windows 11 draws it (WinCombo.swift, reports/feel3.md
/// §2): the themed box in its normal / hover / focused / disabled colours, the chevron, and the
/// text left-aligned 4 px in with its baseline 15 px below the top -- AppKit's own pop-up centres
/// the title in a capsule. The menu that opens stays AppKit's.
final class WinPopUpButtonCell: NSPopUpButtonCell {

    static let textInset: CGFloat = WinCombo.textX
    static let buttonWidth: CGFloat = 17

    let hover = WinComboHover()

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        NSRect(x: rect.minX + Self.textInset, y: rect.minY, width: max(0, rect.width - Self.textInset - Self.buttonWidth),
               height: rect.height)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView) {
        let flipped = controlView.isFlipped
        let window = controlView.window
        let focused = window?.isKeyWindow == true && window?.firstResponder === controlView
        let state: WinCombo.State = !isEnabled ? .disabled
            : (hover.isInside || isHighlighted ? .hover : (focused ? .focused : .normal))
        WinCombo.drawBox(cellFrame, flipped: flipped, editable: false, state: state, hovered: hover.isInside)
        WinCombo.drawText(titleOfSelectedItem ?? "", in: cellFrame, flipped: flipped, font: font ?? DialogMetrics.font,
                          color: isEnabled ? WinCombo.text : WinCombo.disabledText,
                          maxX: cellFrame.maxX - Self.buttonWidth)
        if focused, state != .disabled {
            var r = cellFrame
            if !flipped { r.origin.y = cellFrame.minY }
            WinCombo.drawFocusRect(r)
        }
    }

    /// Gives `popup` this cell, keeping its menu, selection, target / action and state.
    static func adopt(_ popup: NSPopUpButton) {
        guard let old = popup.cell as? NSPopUpButtonCell, !(old is WinPopUpButtonCell) else { return }
        let cell = WinPopUpButtonCell(textCell: "", pullsDown: old.pullsDown)
        let menu = old.menu
        let selected = old.indexOfSelectedItem
        cell.menu = menu
        cell.target = old.target
        cell.action = old.action
        cell.isEnabled = old.isEnabled
        cell.font = old.font
        cell.controlSize = old.controlSize
        cell.arrowPosition = old.arrowPosition
        cell.autoenablesItems = old.autoenablesItems
        cell.tag = old.tag
        cell.alignment = .left                      // CBS_DROPDOWNLIST text is left-aligned
        popup.cell = cell
        popup.focusRingType = .none                 // the dotted focus rectangle is drawn instead
        cell.hover.attach(to: popup)
        if selected >= 0, selected < cell.numberOfItems { cell.selectItem(at: selected) }
    }
}

/// The pieces every resizable dialog's OnSize uses (CDialog::GetMargins(8), GetItemSizes,
/// MoveItem): the 8 DLU margins and "these buttons at the bottom right, in this order".
enum RcResize {
    static var mx: CGFloat { RcDialog.margin.width }
    static var my: CGFloat { RcDialog.margin.height }

    /// MoveItem(IDCANCEL, x, y ...); MoveItem(IDOK, x - mx - bx2, y ...): `buttons` from right to
    /// left, each `mx` apart, their bottom `my` above the client's. Returns the row's top (y).
    @discardableResult
    static func bottomRightButtons(_ buttons: [(NSButton, NSSize)], in size: NSSize) -> CGFloat {
        guard let height = buttons.first?.1.height else { return size.height }
        let y = size.height - my - height
        var x = size.width - mx
        for (button, buttonSize) in buttons {
            x -= buttonSize.width
            RcPlace.button(button, NSRect(x: x, y: y, width: buttonSize.width, height: buttonSize.height))
            x -= mx
        }
        return y
    }

    /// ChangeSubWindowSizeX: a control keeps its origin and height, takes a new width.
    static func setWidth(_ view: NSView, _ width: CGFloat, rect: NSRect) {
        var r = rect
        r.size.width = max(0, width)
        RcPlace.reframe(view, r)
    }
}

extension RcPlace {
    /// Puts `view` on a Windows rect by its kind (a re-layout from OnSize).
    static func reframe(_ view: NSView, _ r: NSRect) {
        switch view {
        case let p as NSPopUpButton: popup(p, r)
        case let c as NSComboBox: combo(c, r)
        case let b as NSButton:
            if b.cell is NSButtonCell, (b.cell as? NSButtonCell)?.bezelStyle == .rounded || b.bezelStyle == .rounded {
                button(b, r)
            } else {
                check(b, r)
            }
        case let f as NSTextField where f.isEditable || f.isBezeled: edit(f, r)
        case let f as NSTextField: label(f, r)
        case let g as WinGroupBox: group(g, r)
        default: view.frame = r
        }
    }
}

/// msctls_progress32 as Windows 11 draws it in 7zFM's progress window (dlg-progress-run.png):
/// a 1 px (200,200,200) frame, a (235,235,235) track and a (0,138,17) bar, no animation.
final class WinProgressBar: NSView {
    var minValue: Double = 0 { didSet { needsDisplay = true } }
    var maxValue: Double = 1 { didSet { needsDisplay = true } }
    var doubleValue: Double = 0 { didSet { needsDisplay = true } }
    var isIndeterminate = false

    private static func color(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: 1)
        }
    }
    static let frameColor = color((200, 200, 200), (90, 90, 90))
    static let trackColor = color((235, 235, 235), (50, 50, 50))
    static let barColor = color((0, 138, 17), (0, 160, 30))

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func accessibilityValue() -> Any? { doubleValue }
    override func accessibilityMinValue() -> Any? { minValue }
    override func accessibilityMaxValue() -> Any? { maxValue }

    override func draw(_ dirtyRect: NSRect) {
        let b = bounds
        Self.frameColor.setFill()
        b.fill()
        let inner = b.insetBy(dx: 1, dy: 1)
        Self.trackColor.setFill()
        inner.fill()
        let span = maxValue - minValue
        guard span > 0 else { return }
        let fraction = min(1, max(0, (doubleValue - minValue) / span))
        Self.barColor.setFill()
        NSRect(x: inner.minX, y: inner.minY, width: (inner.width * fraction).rounded(), height: inner.height).fill()
    }
}
