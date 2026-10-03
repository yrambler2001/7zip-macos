// PanelTableView.swift -- the details list and the panel's key map (CPanel::OnKeyDown,
// PanelKey.cpp:39-357, and CMyListView::OnMessage, Panel.cpp:163-226). Windows Ctrl becomes
// Command, the F-keys keep their meaning, and the documented exception is Ctrl+W / Cmd+W, which
// closes the whole window (01 §3.7, §9 #30). Keys that the menu bar already owns as a key
// equivalent (Cmd+...) are left to the menu, which sends the same selector down the responder
// chain; the combinations the menu does not bind are handled here.
//
// Also here: the header view (right-click opens the column menu, 01 §2.8) and the row view with
// the two custom-draw rules of 01 §3.6 (AlternativeSelection rows RGB(255,192,192), kpidIsDeleted
// items in red).

import Cocoa
import SevenZipKit

protocol PanelTableViewKeyHandler: AnyObject {
    func tableViewOpenSelection(_ tableView: PanelTableView, outside: Bool)
    func tableViewGoUp(_ tableView: PanelTableView)
    func tableViewGoRoot(_ tableView: PanelTableView)
    func tableViewDidBecomeFirstResponder(_ tableView: PanelTableView)
}

final class PanelTableView: NSTableView {

    weak var keyHandler: PanelTableViewKeyHandler?
    weak var panel: PanelViewController?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { keyHandler?.tableViewDidBecomeFirstResponder(self) }
        if ok { redrawRowViews() }              // the focus rectangle follows the keyboard focus
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { redrawRowViews() }
        return ok
    }

    private func redrawRowViews() {
        if let panel { panel.refreshSelectionAppearance() } else {
            enumerateAvailableRowViews { view, _ in view.needsDisplay = true }
        }
    }

    /// The selection is drawn only while the list has the keyboard focus, which it loses with the
    /// window's key status too (no LVS_SHOWSELALWAYS, selcolors).
    private var keyObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach { NotificationCenter.default.removeObserver($0) }
        keyObservers = []
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in self?.redrawRowViews()
            })
        }
    }

    deinit { keyObservers.forEach { NotificationCenter.default.removeObserver($0) } }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if panel?.handleListKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    /// NM_RCLICK (PanelItems.cpp:1385): the list context menu, positioned at the click.
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let panel else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0 {
            if !panel.selectedIndexes.contains(row) {
                panel.setFocus(row)
            } else {
                panel.setFocus(row, extendingSelection: true)
            }
        }
        return panel.makeItemContextMenu()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if let panel, panel.usesAlternativeSelection, row >= 0 {
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if mods.contains(.command) {                       // Ctrl+click toggles (01 §3.6)
                panel.setFocus(row, extendingSelection: true)
                panel.toggleMySelection(row)
                return
            }
            if mods.contains(.shift) {                         // Shift+click selects a range
                panel.selectRange(to: row)
                return
            }
        }
        if let panel, row >= 0 { panel.noteClickedRow(row) }
        super.mouseDown(with: event)
    }

    override func makeView(withIdentifier identifier: NSUserInterfaceItemIdentifier, owner: Any?) -> NSView? {
        super.makeView(withIdentifier: identifier, owner: owner)
    }
}

/// Right-click on the header opens the column menu (ShowColumnsContextMenu, PanelItems.cpp:1396).
final class PanelTableHeaderView: NSTableHeaderView {
    override func menu(for event: NSEvent) -> NSMenu? {
        (tableView as? PanelTableView)?.panel?.makeColumnsContextMenu()
    }
}

/// Custom draw (OnCustomDraw, PanelListNotify.cpp:698-757) plus the FullRow setting, drawn as the
/// Windows list control draws it (PanelSelectionStyle.swift, selcolors.md).
final class PanelRowView: NSTableRowView {

    weak var panel: PanelViewController?
    var rowIndex = -1
    var isMySelected = false

    override var isSelected: Bool { didSet { if isSelected != oldValue { updateCellColors() } } }
    override var isEmphasized: Bool { didSet { if isEmphasized != oldValue { updateCellColors() } } }
    override var isTargetForDropOperation: Bool {
        didSet { if isTargetForDropOperation != oldValue { updateCellColors(); needsDisplay = true } }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if let cell = subview as? PanelCellView { cell.applyColors(highlighted: highlightCovers(cell)) }
    }

    /// The selection fill is drawn: selected while the list has the keyboard focus, or the drop
    /// target of a drag (LVIS_DROPHILITED looks the same).
    var drawsHighlight: Bool {
        guard let panel else { return isSelected }
        return (isSelected && panel.listHasKeyboardFocus) || isTargetForDropOperation
    }

    private func highlightCovers(_ cell: PanelCellView) -> Bool {
        drawsHighlight && (cell.isNameCell || Settings.fullRow)
    }

    func updateCellColors() {
        for case let cell as PanelCellView in subviews { cell.applyColors(highlighted: highlightCovers(cell)) }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isMySelected {
            PanelSelectionStyle.mySelected.setFill()
            bounds.fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawFocusRectangle()
    }

    /// The name column's rect in this row, or nil when it is hidden.
    private var nameColumnRect: NSRect? {
        guard let table = panel?.tableView else { return nil }
        guard let index = table.tableColumns.firstIndex(where: { PanelViewController.propID(of: $0) == .name }) else { return nil }
        var rect = table.rect(ofColumn: index)
        rect.origin.y = bounds.minY
        rect.size.height = bounds.height
        return rect
    }

    /// Where the label starts (after the icon) and where the name's text ends, from the name cell
    /// itself when it is on screen.
    private var labelSpan: (start: CGFloat, textEnd: CGFloat)? {
        guard let column = nameColumnRect else { return nil }
        var start = column.minX + PanelSelectionStyle.nameIconSlot
        var end = column.maxX
        if let table = panel?.tableView,
           let index = table.tableColumns.firstIndex(where: { PanelViewController.propID(of: $0) == .name }),
           let cell = table.view(atColumn: index, row: rowIndex, makeIfNecessary: false) as? NSTableCellView,
           let field = cell.textField {
            let frame = field.convert(field.bounds, to: self)
            start = frame.minX - PanelSelectionStyle.labelPadding
            end = min(end, frame.minX + min(field.intrinsicContentSize.width, frame.width)
                      + PanelSelectionStyle.labelPadding)
        }
        return (max(column.minX, start), end)
    }

    /// Where the fill goes (and the focus rectangle): from the label to the end of the row
    /// (FullRow) or the label only (LVIR_LABEL: the name's text plus 2 pt either side).
    var highlightRect: NSRect {
        guard panel != nil else { return bounds }
        guard let span = labelSpan else { return Settings.fullRow ? bounds : .zero }
        let end = Settings.fullRow ? bounds.maxX : span.textEnd
        return NSRect(x: span.start, y: bounds.minY, width: max(0, end - span.start), height: bounds.height)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard panel != nil else { super.drawSelection(in: dirtyRect); return }
        guard drawsHighlight else { return }                 // no LVS_SHOWSELALWAYS
        fillHighlight()
    }

    override func drawDraggingDestinationFeedback(in dirtyRect: NSRect) {
        guard panel != nil else { super.drawDraggingDestinationFeedback(in: dirtyRect); return }
        fillHighlight()
    }

    private func fillHighlight() {
        PanelSelectionStyle.highlight.setFill()
        if Settings.fullRow, let column = nameColumnRect, column.minX > bounds.minX {
            // The name column was dragged away from the left: the columns before it are filled too.
            NSRect(x: bounds.minX, y: bounds.minY, width: column.minX - bounds.minX, height: bounds.height).fill()
            highlightRect.fill()
        } else {
            highlightRect.fill()
        }
    }

    /// The list control's dotted focus rectangle around the focused item, selected or not, while
    /// the list has the keyboard focus (winmatch, selcolors): around the label, or around the
    /// full-row fill with FullRow.
    private func drawFocusRectangle() {
        guard let panel, rowIndex >= 0, panel.focusedIndex == rowIndex, panel.listHasKeyboardFocus,
              panel.tableView.numberOfColumns > 0 else { return }
        PanelSelectionStyle.drawFocusRectangle(highlightRect, onHighlight: drawsHighlight)
    }
}
