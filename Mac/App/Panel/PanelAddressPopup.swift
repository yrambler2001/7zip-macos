// PanelAddressPopup.swift -- the address bar's dropped list as 7zFM 26.03 draws it (feel3, the
// user's finding 6: "Windows shows icons for each entry, highlights the row under the mouse, and
// its rows are taller").
//
// 7zFM's address bar is a ComboBoxEx32 (Panel.cpp:521-536); its dropped list is a ComboLBox the
// width of the combo, right under it, whose items are the CBN_DROPDOWN entries of
// PanelFolderChange.cpp:627-760 (AddComboBoxItem: an image from the system image list and an
// indent). Measured at 96 dpi (feel3-data/win/addr-dropped.png, addr-hover1/4.png, log.txt):
//
//   * the list: the combo's x and width, its top on the combo's bottom; a 1 px (0,120,215) border,
//     white, 18 px items (LB_GETITEMHEIGHT 18), no scroll bar for the usual 10-20 entries;
//   * an item: the 16 x 16 icon 4 px + 10 px per indent level from the list's left edge, 1 px below
//     the item's top; the name (Segoe UI 9) 20 px after the icon's left edge, its baseline 14 px
//     below the item's top;
//   * nothing is highlighted when the list opens (CB_GETCURSEL -1); the item under the mouse is
//     highlighted (0,120,215) from 2 px inside the list's left edge to 2 px before its right edge,
//     its text white, with the dotted focus rectangle on it; the highlight follows the mouse;
//   * a click on an item binds its path at once (CBN_SELENDOK) and focuses the file list; Esc or a
//     click elsewhere closes the list; Up / Down move the highlight and Enter picks it.
//
// NSComboBox's own list can show neither icons nor a hover highlight, so the list is drawn here
// and the combo keeps only the edit (AddressComboBox opens this list from its arrow).

import AppKit

/// One row of the dropped list.
struct AddressPopupItem {
    let name: String
    let level: Int
    let icon: NSImage?
}

enum AddressPopupMetrics {
    static let rowHeight: CGFloat = 18
    static let border: CGFloat = 1
    static let iconX: CGFloat = 4
    static let indent: CGFloat = 10
    static let iconTop: CGFloat = 1
    static let textFromIcon: CGFloat = 20
    static let baseline: CGFloat = 14
    static let highlightInset: CGFloat = 2
    static let maxVisibleRows = 30

    static let borderColor = WinChrome.dynamic(WinChrome.rgb(0, 120, 215), .controlAccentColor)
    static let highlight = WinChrome.dynamic(WinChrome.rgb(0, 120, 215), .selectedContentBackgroundColor)
    static let highlightText = WinChrome.dynamic(.white, .alternateSelectedControlTextColor)
}

/// The list's content: draws the rows, follows the mouse.
final class AddressPopupListView: NSView {

    var items: [AddressPopupItem] = [] { didSet { invalidateIntrinsicContentSize(); needsDisplay = true; rowElements = nil } }
    var font: NSFont = PanelMetrics.listFont
    /// The highlighted row (CB_GETCURSEL); -1 when the list opens.
    var hot = -1 { didSet { if hot != oldValue { needsDisplay = true } } }
    var onPick: ((Int) -> Void)?
    private var trackingArea: NSTrackingArea?
    private var rowElements: [NSAccessibilityElement]?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: CGFloat(items.count) * AddressPopupMetrics.rowHeight)
    }

    func row(at point: NSPoint) -> Int {
        guard point.y >= 0, bounds.contains(point) else { return -1 }
        let r = Int(point.y / AddressPopupMetrics.rowHeight)
        return r < items.count ? r : -1
    }

    func rowRect(_ row: Int) -> NSRect {
        NSRect(x: 0, y: CGFloat(row) * AddressPopupMetrics.rowHeight, width: bounds.width, height: AddressPopupMetrics.rowHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0 { hot = r }                           // the list keeps the last row the mouse was on
    }

    override func mouseDown(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0 { hot = r }
    }

    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func mouseUp(with event: NSEvent) {
        let r = row(at: convert(event.locationInWindow, from: nil))
        if r >= 0 { onPick?(r) }
    }

    override func draw(_ dirtyRect: NSRect) {
        WinChrome.window.setFill()
        dirtyRect.fill()
        let m = AddressPopupMetrics.self
        for (i, item) in items.enumerated() {
            let rr = rowRect(i)
            guard rr.intersects(dirtyRect) else { continue }
            let isHot = i == hot
            if isHot {
                // 2 px in from the list's edges: the border is outside this view, so 1 px here.
                let fill = NSRect(x: m.highlightInset - m.border, y: rr.minY,
                                  width: rr.width - 2 * (m.highlightInset - m.border), height: rr.height)
                m.highlight.setFill()
                fill.fill()
                PanelSelectionStyle.drawFocusRectangle(fill, onHighlight: true)
            }
            let iconX = m.iconX - m.border + CGFloat(item.level) * m.indent
            if let icon = item.icon {
                let iconRect = NSRect(x: iconX, y: rr.minY + m.iconTop, width: 16, height: 16)
                // ILD_SELECTED: on the highlight the image list blends the icon 50 % with it.
                let drawn = isHot ? Self.blended(icon, with: m.highlight) : icon
                drawn.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: isHot ? m.highlightText : WinChrome.text,
            ]
            let origin = NSPoint(x: iconX + m.textFromIcon, y: rr.minY + m.baseline - font.ascender)
            (item.name as NSString).draw(at: origin, withAttributes: attributes)
        }
    }

    static func blended(_ icon: NSImage, with color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            icon.draw(in: rect)
            color.withAlphaComponent(0.5).setFill()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    // MARK: accessibility: one element per row, pressable

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .list }
    override func accessibilityIdentifier() -> String { "address-dropdown" }

    override func accessibilityChildren() -> [Any]? {
        if let rowElements { return rowElements }
        let elements: [NSAccessibilityElement] = items.indices.map { i in
            let element = AddressPopupRowElement()
            element.list = self
            element.index = i
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(items[i].name)
            element.setAccessibilityValue(items[i].name)
            element.setAccessibilityIdentifier("address-dropdown-\(i)")
            element.setAccessibilityParent(self)
            return element
        }
        rowElements = elements
        return elements
    }
}

private final class AddressPopupRowElement: NSAccessibilityElement {
    weak var list: AddressPopupListView?
    var index = 0

    override func accessibilityFrame() -> NSRect {
        guard let list, let window = list.window else { return .zero }
        return window.convertToScreen(list.convert(list.rowRect(index), to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        list?.onPick?(index)
        return true
    }
}

/// The dropped list's window and its lifetime: opened by the combo's arrow, closed by a pick, Esc,
/// a click outside or the owner window losing the key focus.
final class AddressPopup: NSObject {

    private(set) static var current: AddressPopup?

    let panel: NSPanel
    let list = AddressPopupListView()
    private let scroll = WinScrollView()
    private weak var combo: NSView?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var onPick: ((Int) -> Void)?

    var isOpen: Bool { panel.isVisible }

    private init(items: [AddressPopupItem], font: NSFont) {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true                      // ComboLBox has CS_DROPSHADOW
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.setAccessibilityIdentifier("address-dropdown-window")
        list.items = items
        list.font = font
        let content = AddressPopupBorderView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.documentView = list
        content.addSubview(scroll)
        panel.contentView = content
    }

    /// Opens the list under `combo` (screen coordinates from its window), `items` in order.
    @discardableResult
    static func show(below combo: NSView, items: [AddressPopupItem], font: NSFont,
                     onPick: @escaping (Int) -> Void) -> AddressPopup? {
        current?.close()
        guard let window = combo.window, !items.isEmpty else { return nil }
        let popup = AddressPopup(items: items, font: font)
        popup.combo = combo
        popup.onPick = onPick
        popup.list.onPick = { [weak popup] index in
            guard let popup else { return }
            let pick = popup.onPick
            popup.close()
            pick?(index)
        }
        let m = AddressPopupMetrics.self
        let comboRect = window.convertToScreen(combo.convert(combo.bounds, to: nil))
        let screen = window.screen?.visibleFrame ?? comboRect
        let fullHeight = CGFloat(items.count) * m.rowHeight
        let room = max(m.rowHeight, comboRect.minY - screen.minY - 2 * m.border)
        let height = min(fullHeight, min(room, CGFloat(m.maxVisibleRows) * m.rowHeight))
        let frame = NSRect(x: comboRect.minX, y: comboRect.minY - height - 2 * m.border,
                           width: comboRect.width, height: height + 2 * m.border)
        popup.panel.setFrame(frame, display: false)
        popup.scroll.frame = NSRect(x: m.border, y: m.border, width: frame.width - 2 * m.border, height: height)
        popup.list.frame = NSRect(x: 0, y: 0, width: popup.scroll.contentSize.width, height: fullHeight)
        popup.list.autoresizingMask = [.width]
        window.addChildWindow(popup.panel, ordered: .above)
        popup.panel.orderFront(nil)
        popup.installMonitors(owner: window)
        current = popup
        return popup
    }

    private func installMonitors(owner: NSWindow) {
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.window === self.panel { return event }
            // A click on the combo's arrow closes the list and is consumed (it would reopen it).
            if let combo = self.combo as? AddressComboBox, event.window === combo.window,
               combo.isOnArrow(combo.convert(event.locationInWindow, from: nil)) {
                self.close()
                return nil
            }
            self.close()
            return event
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }) { monitors.append(m) }
        let center = NotificationCenter.default
        for name in [NSWindow.didResignKeyNotification, NSWindow.willMoveNotification, NSWindow.didResizeNotification,
                     NSWindow.willCloseNotification] {
            observers.append(center.addObserver(forName: name, object: owner, queue: .main) { [weak self] _ in self?.close() })
        }
    }

    /// Up / Down move the highlight, Enter picks it, Esc closes; any other key closes the list
    /// and goes on to the edit.
    func handleKey(_ event: NSEvent) -> Bool {
        switch Int(event.keyCode) {
        case 125:                                               // Down
            list.hot = min(list.items.count - 1, list.hot + 1)
            list.scrollToVisible(list.rowRect(max(0, list.hot)))
            return true
        case 126:                                               // Up
            list.hot = max(0, list.hot - 1)
            list.scrollToVisible(list.rowRect(list.hot))
            return true
        case 36, 76:                                            // Return, Enter
            let index = list.hot
            let pick = onPick
            close()
            if index >= 0 { pick?(index) }
            return true
        case 53:                                                // Esc
            close()
            return true
        default:
            close()
            return false
        }
    }

    func close() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers = []
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if AddressPopup.current === self { AddressPopup.current = nil }
    }
}

/// The list's 1 px border.
private final class AddressPopupBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        WinChrome.window.setFill()
        bounds.fill()
        AddressPopupMetrics.borderColor.setFill()
        bounds.frame(withWidth: AddressPopupMetrics.border)
    }
}
