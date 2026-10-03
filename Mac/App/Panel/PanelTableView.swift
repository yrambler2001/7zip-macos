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
        enumerateAvailableRowViews { view, _ in view.needsDisplay = true }
    }

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

/// Custom draw (OnCustomDraw, PanelListNotify.cpp:698-757) plus the FullRow setting.
final class PanelRowView: NSTableRowView {

    weak var panel: PanelViewController?
    var rowIndex = -1
    var isMySelected = false

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isMySelected {
            NSColor(calibratedRed: 1.0, green: 192.0 / 255.0, blue: 192.0 / 255.0, alpha: 1.0).setFill()
            bounds.fill()
        }
        drawFocusRectangle()
    }

    /// The list control's dotted focus rectangle around a focused item that is not selected
    /// (a folder just opened: "0 / N object(s) selected", winmatch). Only while the list has the
    /// keyboard focus, as on Windows; around the name cell unless FullRow is on.
    private func drawFocusRectangle() {
        guard let panel, !isSelected, rowIndex >= 0, panel.focusedIndex == rowIndex else { return }
        let table = panel.tableView
        guard window?.firstResponder === table, table.numberOfColumns > 0 else { return }
        var rect = bounds
        if !Settings.fullRow {
            rect = table.rect(ofColumn: 0)
            rect.origin.y = bounds.minY
            rect.size.height = bounds.height
            rect = rect.intersection(bounds)
        }
        let path = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        path.lineWidth = 1
        path.setLineDash([1, 1], count: 2, phase: 0)
        NSColor.labelColor.setStroke()
        path.stroke()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        // LVS_EX_FULLROWSELECT off: only the name column is highlighted, as on Windows.
        if Settings.fullRow || panel == nil {
            super.drawSelection(in: dirtyRect)
            return
        }
        guard let table = panel?.tableView, table.numberOfColumns > 0 else {
            super.drawSelection(in: dirtyRect)
            return
        }
        var rect = table.rect(ofColumn: 0)
        rect.origin.y = bounds.minY
        rect.size.height = bounds.height
        NSColor.selectedContentBackgroundColor.setFill()
        rect.intersection(bounds).fill()
    }
}
