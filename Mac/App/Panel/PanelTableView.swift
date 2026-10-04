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

    /// SPI_GETWHEELSCROLLLINES = 3 on the reference PC: one wheel notch scrolls 3 rows there
    /// (LVM_GETTOPINDEX 0 -> 3 -> 6, recheck §3); NSTableView makes it one row.
    override func tile() {
        super.tile()
        let step = rowHeight * 3
        if let scroll = enclosingScrollView, scroll.verticalLineScroll != step { scroll.verticalLineScroll = step }
    }

    override func keyDown(with event: NSEvent) {
        cancelSlowClickRename()
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
        cancelSlowClickRename()
        cancelHoverSelect()
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
        if let panel, !panel.usesAlternativeSelection, !isOnItem(point, row: row) {
            trackRubberBand(from: point, event: event)        // the list's background: a marquee
            return
        }
        if let panel, row >= 0 { panel.noteClickedRow(row) }
        // The slow second click (LVS_EDITLABELS): the item was the only selected one and focused
        // before this click, and the click is on its label.
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let mayRename = !Settings.singleClick && event.clickCount == 1 && mods.isEmpty && row >= 0
            && panel.map { !$0.usesAlternativeSelection && $0.selectedIndexes == IndexSet(integer: row)
                           && $0.focusedIndex == row } == true
            && labelHitRect(row: row).contains(point)
        super.mouseDown(with: event)
        // NSTableView returns on mouse-up; a drag or a move off the label is not a click.
        if mayRename, let up = NSApp.currentEvent, up.type == .leftMouseUp,
           hypot(up.locationInWindow.x - event.locationInWindow.x, up.locationInWindow.y - event.locationInWindow.y) < 4,
           panel?.selectedIndexes == IndexSet(integer: row) {
            scheduleSlowClickRename(row: row)
        }
    }

    // MARK: The slow second click and Single-click hover (recheck2, measured on 7zFM 26.03)
    //
    // Slow click (SingleClick off, recheck2-data/win/log.txt "slow-*"): a click on the label of the
    // item that is already the only selected and focused one starts the in-place rename when no
    // second click follows within the double-click time (GetDoubleClickTime 550 ms there: the edit
    // appeared between +550 and +650 ms). A double-click opens instead; a click on the icon, on
    // another column, or on one of several selected items starts nothing.
    //
    // Hover (SingleClick on: LVS_EX_ONECLICKACTIVATE | LVS_EX_TRACKSELECT, "sc1-*"): over an item's
    // icon or label the cursor is the hand at once and the item is hot (nothing is drawn for it);
    // after SPI_GETMOUSEHOVERTIME (400 ms) of rest it becomes the selected and focused item. Over
    // another column, the background or outside the list nothing happens. The "Underline" option
    // (LVS_EX_UNDERLINEHOT) is commented out of 7zFM 26.03 (App.cpp:88-92), so nothing is
    // underlined either way.

    private var slowClickTimer: Timer?
    private var hoverTimer: Timer?
    private var hoverRow = -1
    private var hoverArea: NSTrackingArea?
    /// SPI_GETMOUSEHOVERTIME on the reference PC; macOS has no such setting.
    static let hoverSelectDelay: TimeInterval = 0.4

    /// LVHT_ONITEMLABEL: the label's fill in the Name column (the whole Name cell's text part).
    func labelHitRect(row: Int) -> NSRect {
        guard let panel, row >= 0, row < numberOfRows, row < panel.rows.count,
              let index = tableColumns.firstIndex(where: { PanelViewController.propID(of: $0) == .name }) else { return .zero }
        let rowRect = rect(ofRow: row)
        let column = rect(ofColumn: index)
        let fill = PanelMetrics.labelFill(columnMinX: column.minX, columnMaxX: column.maxX, text: panel.rows[row].displayName)
        return NSRect(x: fill.start, y: rowRect.minY, width: max(0, fill.end - fill.start), height: rowRect.height)
    }

    private func scheduleSlowClickRename(row: Int) {
        let timer = Timer(timeInterval: NSEvent.doubleClickInterval, repeats: false) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            self.slowClickTimer = nil
            guard panel.selectedIndexes == IndexSet(integer: row), panel.focusedIndex == row,
                  NSEvent.pressedMouseButtons == 0 else { return }
            panel.renameFocusedItem()
        }
        RunLoop.main.add(timer, forMode: .common)
        slowClickTimer = timer
    }

    func cancelSlowClickRename() {
        slowClickTimer?.invalidate()
        slowClickTimer = nil
    }

    /// True while a slow click waits for the double-click time (tests).
    var hasPendingSlowClickRename: Bool { slowClickTimer != nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                                                         .activeInActiveApp, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// The row whose item area (icon and label, or the whole row with FullRow) is under `point`.
    private func hotRow(at point: NSPoint) -> Int {
        let row = self.row(at: point)
        return isOnItem(point, row: row) ? row : -1
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard Settings.singleClick else { cancelHoverSelect(); return }
        let row = hotRow(at: convert(event.locationInWindow, from: nil))
        (row >= 0 ? NSCursor.pointingHand : NSCursor.arrow).set()
        guard row != hoverRow else { return }
        cancelHoverSelect()
        hoverRow = row
        guard row >= 0 else { return }
        let timer = Timer(timeInterval: Self.hoverSelectDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.hoverTimer = nil
            self.hoverSelect(row)
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    override func cursorUpdate(with event: NSEvent) {
        if Settings.singleClick, hotRow(at: convert(event.locationInWindow, from: nil)) >= 0 {
            NSCursor.pointingHand.set()
        } else {
            super.cursorUpdate(with: event)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        cancelHoverSelect()
        hoverRow = -1
    }

    private func cancelHoverSelect() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    /// LVS_EX_TRACKSELECT: the item rested on becomes the selected and focused one.
    func hoverSelect(_ row: Int, checkPointer: Bool = true) {
        guard Settings.singleClick, let panel, row >= 0, row < panel.rows.count,
              NSEvent.pressedMouseButtons == 0, panel.renamingRow == nil else { return }
        if checkPointer, let window, hotRow(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)) != row {
            return
        }
        panel.setFocus(row)
    }

    /// True while a hover waits for the hover time (tests).
    var hasPendingHoverSelect: Bool { hoverTimer != nil }

    // MARK: Rubber band (LVS_REPORT marquee, listfeel.md §6)

    /// The item's own area in row `row`, in table coordinates (`PanelRowView.itemHitRect`): the
    /// whole row with FullRow, else the icon plus the label's fill. Computed without a row view so
    /// rows scrolled out of sight are hit too.
    func itemHitRect(row: Int) -> NSRect {
        guard let panel, row >= 0, row < numberOfRows else { return .zero }
        let rowRect = rect(ofRow: row)
        if Settings.fullRow {
            let last = tableColumns.indices.last.map { rect(ofColumn: $0).maxX } ?? rowRect.maxX
            return NSRect(x: rowRect.minX, y: rowRect.minY, width: max(0, last - rowRect.minX), height: rowRect.height)
        }
        guard let index = tableColumns.firstIndex(where: { PanelViewController.propID(of: $0) == .name }),
              row < panel.rows.count else { return .zero }
        let column = rect(ofColumn: index)
        let fill = PanelMetrics.labelFill(columnMinX: column.minX, columnMaxX: column.maxX, text: panel.rows[row].displayName)
        let start = min(column.minX + PanelMetrics.iconX, fill.start)
        return NSRect(x: start, y: rowRect.minY, width: max(0, fill.end - start), height: rowRect.height)
    }

    /// LVHT_ONITEM: a mouse-down here selects / drags the item; anywhere else in the list it is
    /// the background, where a drag draws the rubber band (measured: the Size cell, the blank part
    /// of the name column, right of the last column and below the rows, FullRow off; only right of
    /// the columns and below the rows with FullRow on).
    func isOnItem(_ point: NSPoint, row: Int) -> Bool {
        row >= 0 && itemHitRect(row: row).contains(point)
    }

    /// The rows whose item area meets `rect` (the marquee selects by LVIR_SELECTBOUNDS, or the
    /// full row with FullRow).
    func rowsHit(by rect: NSRect) -> IndexSet {
        var result = IndexSet()
        let range = rows(in: rect)
        guard range.length > 0 else { return result }
        for row in range.location..<(range.location + range.length) where itemHitRect(row: row).intersects(rect) {
            result.insert(row)
        }
        return result
    }

    /// The dotted marquee (DrawFocusRect), drawn over the rows while the button is held.
    private final class RubberBandView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            PanelSelectionStyle.drawFocusRectangle(bounds, onHighlight: false)
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    /// The marquee: a click on the background clears the selection (Cmd / Shift keep it), a drag
    /// past SM_CXDRAG / SM_CYDRAG (4 px) draws the dotted rectangle and selects the rows it meets,
    /// live; Cmd toggles them against the previous selection (Ctrl on Windows), Shift adds them.
    /// The list scrolls when the pointer leaves it.
    private func trackRubberBand(from start: NSPoint, event: NSEvent) {
        guard let window else { return }
        window.makeFirstResponder(self)
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let toggle = mods.contains(.command)
        let extend = mods.contains(.shift)
        let initial = selectedRowIndexes
        if !toggle && !extend { deselectAll(nil) }
        let band = RubberBandView(frame: .zero)
        var dragging = false
        var lastDrag = event
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents(); band.removeFromSuperview() }
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if next.type == .leftMouseUp { break }
            if next.type == .leftMouseDragged { lastDrag = next } else if dragging { autoscroll(with: lastDrag) }
            let point = convert(lastDrag.locationInWindow, from: nil)
            if !dragging {
                guard abs(point.x - start.x) > 4 || abs(point.y - start.y) > 4 else { continue }
                dragging = true
                addSubview(band)
            }
            let rect = NSRect(x: min(start.x, point.x), y: min(start.y, point.y),
                              width: abs(point.x - start.x), height: abs(point.y - start.y))
            band.frame = rect.insetBy(dx: -0.5, dy: -0.5).integral
            band.needsDisplay = true
            let hit = rowsHit(by: rect)
            let selection = toggle ? initial.symmetricDifference(hit) : (extend ? initial.union(hit) : hit)
            if selection != selectedRowIndexes { selectRowIndexes(selection, byExtendingSelection: false) }
        }
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

    /// Where the label starts (after the icon) and where its fill ends: LVIR_LABEL clipped to the
    /// text, i.e. 2 px before the text and 6 px after it (PanelMetrics, listfeel.md §3).
    private var labelSpan: (start: CGFloat, textEnd: CGFloat)? {
        guard let column = nameColumnRect else { return nil }
        let name = panel.flatMap { rowIndex >= 0 && rowIndex < $0.rows.count ? $0.rows[rowIndex].displayName : nil } ?? ""
        let fill = PanelMetrics.labelFill(columnMinX: column.minX, columnMaxX: column.maxX, text: name)
        return (fill.start, fill.end)
    }

    /// Where the fill goes (and the focus rectangle): from the label to the end of the row
    /// (FullRow) or the label only (LVIR_LABEL clipped to the text).
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
