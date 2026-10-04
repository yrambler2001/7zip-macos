// PanelListViews.swift -- the two list widgets behind the four view modes: the details table
// (report mode, the folder's columns) and the collection view used by Large Icons / Small Icons /
// List (01 §3.1, §9 #14). Cell text comes from PanelRow (rendered once per load, SetItemText),
// the red text of kpidIsDeleted items and the AlternativeSelection background are in
// PanelTableView.swift.

import Cocoa
import SevenZipKit

// MARK: - Details table

extension PanelViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("panelRow")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? PanelRowView) ?? PanelRowView()
        view.identifier = identifier
        view.panel = self
        view.rowIndex = row
        view.isMySelected = isMySelected(row)
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < rows.count else { return nil }
        let item = rows[row]
        guard let pid = PanelViewController.propID(of: tableColumn) else { return nil }
        let isName = pid == .name
        let alignment: NSTextAlignment = isName ? .left
            : (columnsModel.columns.first { $0.propID == pid }.map { PanelFormat.alignment(for: $0.varType, propID: pid) } ?? .left)
        // One reuse pool per layout: the margins depend on the side the text is aligned to.
        let identifier = NSUserInterfaceItemIdentifier(isName ? "name" : "text\(alignment.rawValue)")
        let cell: PanelCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? PanelCellView {
            cell = reused
        } else {
            cell = PanelViewController.makeListCell(identifier: identifier, isName: isName, alignment: alignment)
        }
        if isName {
            cell.textField?.stringValue = item.displayName
            cell.textField?.alignment = .left
            cell.baseImage = icon(for: item)
            cell.textField?.isEditable = false                    // label editing starts on F2 only
            cell.editingConstraint?.isActive = false
        } else {
            cell.textField?.stringValue = item.cells[pid] ?? ""
            cell.textField?.alignment = alignment
        }
        // kpidIsDeleted rows are drawn in red (OnCustomDraw, 01 §3.6); a highlighted cell is white
        // on the highlight (PanelSelectionStyle).
        cell.isDeleted = item.isDeleted
        cell.applyColors(highlighted: cellIsHighlighted(row: row, isName: isName))
        return cell
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let pid = PanelViewController.propID(of: tableColumn) else { return }
        sort(by: pid)                                             // OnColumnClick (PanelSort.cpp:281)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !usesAlternativeSelection {
            let selected = tableView.selectedRowIndexes
            if !isSettingSelection, let last = selected.last, !selected.contains(focusedIndex) { focusedIndex = last }
            iconView.setSelectionIndexes(selected)
        } else if tableView.selectedRow >= 0 {
            focusedIndex = tableView.selectedRow
        }
        refreshStatusBar()                                        // OnItemChanged (01 §3.12)
        refreshSelectionAppearance()
    }

    func tableViewColumnDidMove(_ notification: Notification) { saveColumnLayout() }
    func tableViewColumnDidResize(_ notification: Notification) { saveColumnLayout() }
}

// MARK: - Details cells (PanelMetrics: 7zFM 26.03's list geometry)

extension PanelViewController {

    /// A Details cell laid out as the Windows list draws it: in the name column the icon at
    /// LVIR_ICON (x 4, 1 px from the top) and the text 2 px into LVIR_LABEL (x 20); in the other
    /// columns the text 6 px from the edge it is aligned to (listfeel.md §2).
    static func makeListCell(identifier: NSUserInterfaceItemIdentifier, isName: Bool,
                             alignment: NSTextAlignment) -> PanelCellView {
        let cell = PanelCellView()
        cell.identifier = identifier
        cell.isNameCell = isName
        let text = NSTextField(labelWithString: "")
        text.font = PanelMetrics.listFont
        text.lineBreakMode = .byTruncatingTail
        text.alignment = alignment
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        let inset = PanelMetrics.textFieldInset
        var constraints = [text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
        if isName {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            image.setAccessibilityElement(false)
            cell.addSubview(image)
            cell.imageView = image
            constraints += [
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: PanelMetrics.iconX),
                image.topAnchor.constraint(equalTo: cell.topAnchor, constant: PanelMetrics.iconTop),
                image.widthAnchor.constraint(equalToConstant: PanelMetrics.iconSize),
                image.heightAnchor.constraint(equalToConstant: PanelMetrics.iconSize),
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor,
                                              constant: PanelMetrics.labelX + PanelMetrics.labelTextInset - inset),
                // The name's field is as wide as its text (cut at the column's end): the item is
                // the icon and the text, not the whole column (LVHT_ONITEM, the rubber band), and
                // a click on the field -- VoiceOver's or XCUITest's, at its centre -- is on the item.
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -inset),
            ]
            text.setContentHuggingPriority(.required, for: .horizontal)
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            // While the name is edited in place (F2) the field spans the column.
            cell.editingConstraint = text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -inset)
        } else {
            // The full margin on the aligned side; on the other side the text may run up to the
            // column's edge before it is cut, as a date in a 100 px column does on Windows.
            let pad = PanelMetrics.subitemPadding - inset
            let leading: CGFloat = alignment == .right ? 0 : pad
            let trailing: CGFloat = alignment == .right ? pad : 0
            constraints += [
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -trailing),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }
}

// MARK: - Keys, focus, address combo

extension PanelViewController: PanelTableViewKeyHandler, NSComboBoxDelegate, NSTextFieldDelegate {

    func tableViewOpenSelection(_ tableView: PanelTableView, outside: Bool) {
        if outside { openSelectionOutside() } else { openSelection() }
    }

    func tableViewGoUp(_ tableView: PanelTableView) { goUp() }
    func tableViewGoRoot(_ tableView: PanelTableView) { goRoot() }

    func tableViewDidBecomeFirstResponder(_ tableView: PanelTableView) {
        delegate?.panelDidBecomeActive(self)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        delegate?.panelDidBecomeActive(self)
    }

    /// Esc in the address edit restores _currentFolderPrefix and focuses the list; Tab focuses the
    /// list; Enter binds (CBEN_ENDEDIT / OnNotifyComboBoxEnter, 01 §3.7).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === pathCombo else { return false }
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            pathCombo.stringValue = currentPath
            focusList()
            return true
        case #selector(NSResponder.insertTab(_:)):
            focusList()
            return true
        default:
            return false
        }
    }

    /// CBN_DROPDOWN: rebuild the breadcrumb list every time it opens (01 §3.9).
    func comboBoxWillPopUp(_ notification: Notification) {
        rebuildAddressDropdown()
    }

    /// CBN_SELENDOK (PanelFolderChange.cpp:803-822): an entry picked in the drop-down binds its
    /// path at once and focuses the list. A mouse pick commits on the click; moving through the
    /// open list with the arrow keys only previews the entry, and Return commits it (the
    /// combo's action), as Windows sends CBN_SELENDOK only when the list closes on a choice.
    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSComboBox) === pathCombo else { return }
        let index = pathCombo.indexOfSelectedItem
        guard index >= 0, AddressDropdown.isCommitEvent(NSApp.currentEvent) else { return }
        commitAddressDropdownEntry(at: index)
    }
}

// MARK: - Large icons / small icons / list (NSCollectionView)

final class PanelIconView: NSView {

    private(set) weak var panel: PanelViewController?
    let scrollView = NSScrollView()
    let collectionView = PanelCollectionView()
    private var mode = 0

    init(panel: PanelViewController) {
        self.panel = panel
        super.init(frame: .zero)
        collectionView.panel = panel
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = true
        collectionView.allowsEmptySelection = true
        collectionView.backgroundColors = [.controlBackgroundColor]
        // Drag and drop as in Details view (01 §3.15): the same types, the same source masks.
        collectionView.registerForDraggedTypes(PanelDragDrop.acceptedTypes)
        collectionView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        collectionView.setDraggingSourceOperationMask([.copy], forLocal: false)
        collectionView.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        collectionView.autoresizingMask = [.width]
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        setMode(0)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// 0 = large icons, 1 = small icons, 2 = list (columns, horizontal scrolling like LVS_LIST).
    func setMode(_ mode: Int) {
        self.mode = mode
        let layout = NSCollectionViewFlowLayout()
        switch mode {
        case 0:
            layout.itemSize = NSSize(width: 104, height: 76)
            layout.scrollDirection = .vertical
        case 1:
            layout.itemSize = NSSize(width: 200, height: 20)
            layout.scrollDirection = .vertical
        default:
            layout.itemSize = NSSize(width: 200, height: 20)
            layout.scrollDirection = .horizontal
        }
        layout.minimumInteritemSpacing = 2
        layout.minimumLineSpacing = 2
        layout.sectionInset = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        // A vertically scrolling layout follows the clip view's width, a horizontal one (List
        // mode, LVS_LIST) its height.
        collectionView.autoresizingMask = layout.scrollDirection == .vertical ? [.width] : [.height]
        if let clip = scrollView.contentView.bounds.size as NSSize?, clip.width > 0, clip.height > 0 {
            collectionView.frame = NSRect(origin: .zero, size: clip)
        }
        collectionView.collectionViewLayout = layout
        collectionView.reloadData()
    }

    var isLargeIcons: Bool { mode == 0 }

    /// The document view must follow the clip view in the non-scrolling axis; an NSCollectionView
    /// added as a document view in code does not do that on its own.
    override func layout() {
        super.layout()
        let clip = scrollView.contentView.bounds.size
        guard clip.width > 1, clip.height > 1 else { return }
        var frame = collectionView.frame
        if mode == 2 {                                  // List: columns, horizontal scrolling
            frame.size.height = clip.height
            frame.size.width = max(frame.size.width, clip.width)
        } else {
            frame.size.width = clip.width
            frame.size.height = max(frame.size.height, clip.height)
        }
        if frame != collectionView.frame {
            collectionView.frame = frame
            collectionView.collectionViewLayout?.invalidateLayout()
        }
    }

    func reloadData() {
        guard !isHidden else { return }
        collectionView.reloadData()
        needsLayout = true
    }

    var selectionIndexes: IndexSet {
        IndexSet(collectionView.selectionIndexPaths.map { $0.item })
    }

    func setSelectionIndexes(_ indexes: IndexSet) {
        let paths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        collectionView.selectionIndexPaths = paths
    }

    /// Re-colour every visible item (selection, focus or key-window change; PanelSelectionStyle).
    func refreshItemAppearance() {
        guard !isHidden else { return }
        for item in collectionView.visibleItems() { (item as? PanelCollectionItem)?.updateAppearance() }
    }

    func scrollItemToVisible(_ index: Int) {
        guard let count = panel?.rows.count, index >= 0, index < count else { return }
        collectionView.scrollToItems(at: [IndexPath(item: index, section: 0)], scrollPosition: .nearestHorizontalEdge)
    }
}

extension PanelIconView: NSCollectionViewDataSource, NSCollectionViewDelegate {

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        panel?.rows.count ?? 0
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        // Items are created directly instead of dequeued: NSCollectionView's reuse pool raises an
        // uncatchable ObjC exception when the first dequeue happens before the view was laid out,
        // and a panel never shows more than a screenful of items at a time.
        let cell = PanelCollectionItem()
        guard let panel, indexPath.item < panel.rows.count else { return cell }
        let row = panel.rows[indexPath.item]
        cell.panel = panel
        cell.index = indexPath.item
        cell.configure(name: row.displayName,
                       icon: isLargeIcons ? panel.largeIcon(for: row) : panel.icon(for: row),
                       large: isLargeIcons, isDeleted: row.isDeleted, mySelected: panel.isMySelected(indexPath.item))
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let panel else { return }
        if let last = indexPaths.map({ $0.item }).max() { panel.noteClickedRow(last) }
        panel.refreshStatusBar()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        panel?.refreshStatusBar()
    }

    // MARK: Drag source (CPanel::OnDrag) -- the Details table's code path, per item

    func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>,
                        with event: NSEvent) -> Bool {
        guard let panel else { return false }
        return indexPaths.contains { panel.dragPasteboardWriter(forRow: $0.item) != nil }
    }

    func collectionView(_ collectionView: NSCollectionView,
                        pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        panel?.dragPasteboardWriter(forRow: indexPath.item)
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>) {
        panel?.dragSessionWillBegin(session, rowIndexes: IndexSet(indexPaths.map { $0.item }))
    }

    func collectionView(_ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
                        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation) {
        panel?.dragSessionEnded(operation: operation)
    }

    // MARK: Drop target (CDropTarget) -- a folder item is the target, anything else the panel

    func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
                        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>)
    -> NSDragOperation {
        guard let panel else { return [] }
        let proposed = proposedDropOperation.pointee == .on ? proposedDropIndexPath.pointee.item : -1
        let (row, effect) = panel.validateListDrop(info: draggingInfo, proposedRow: proposed)
        // A collection view has no "whole view" drop row; `.before` an item stands for the panel's
        // own folder (the table's drop row -1), `.on` a folder item for that sub-folder.
        proposedDropOperation.pointee = row >= 0 ? .on : .before
        return effect
    }

    func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
                        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
        guard let panel else { return false }
        return panel.acceptListDrop(info: draggingInfo, proposedRow: dropOperation == .on ? indexPath.item : -1)
    }
}

/// The collection view forwards the panel key map and activates on a double click.
final class PanelCollectionView: NSCollectionView {

    weak var panel: PanelViewController?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let panel { panel.delegate?.panelDidBecomeActive(panel) }
        if ok { panel?.refreshSelectionAppearance() }       // the selection shows with the focus
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { panel?.refreshSelectionAppearance() }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        if panel?.handleListKeyDown(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard let panel else { return }
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point) {
            panel.noteClickedRow(path.item)
            if event.clickCount == 2 || Settings.singleClick {
                panel.activateFocusedItem(modifiers: event.modifierFlags)
            }
        }
    }

    /// The item views, in item order. AppKit's own tree for a flow-layout collection view is one
    /// section element with **no** children, so without this the icon modes were empty to VoiceOver
    /// and XCUITest (`mac/uiverify`). Each item view is a Cell named after its item
    /// (`PanelCollectionItem.ItemBackgroundView`).
    override func accessibilityChildren() -> [Any]? {
        let items = indexPathsForVisibleItems().sorted().compactMap { item(at: $0)?.view }
        return items.isEmpty ? super.accessibilityChildren() : items
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let panel else { return super.menu(for: event) }
        let point = convert(event.locationInWindow, from: nil)
        if let path = indexPathForItem(at: point) {
            if !panel.selectedIndexes.contains(path.item) { panel.setFocus(path.item) }
        }
        return panel.makeItemContextMenu()
    }
}

/// One icon cell: 32 px icon above the name (large) or a 16 px icon left of it.
final class PanelCollectionItem: NSCollectionViewItem {

    static let identifier = NSUserInterfaceItemIdentifier("PanelCollectionItem")

    weak var panel: PanelViewController?
    var index = -1
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var mySelected = false
    private var isDeleted = false
    private var baseImage: NSImage?
    private var large = false

    override func loadView() {
        let root = ItemBackgroundView()
        root.owner = self
        // The collection view positions the item by frame, so this view must keep its
        // autoresizing translation (only its subviews use constraints).
        root.frame = NSRect(x: 0, y: 0, width: 104, height: 76)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        icon.setAccessibilityElement(false)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingMiddle
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        root.addSubview(icon)
        root.addSubview(label)
        view = root
        imageView = icon
        textField = label
    }

    func configure(name: String, icon image: NSImage, large: Bool, isDeleted: Bool, mySelected: Bool) {
        baseImage = image
        label.stringValue = name
        view.setAccessibilityLabel(name)
        self.isDeleted = isDeleted
        self.mySelected = mySelected
        self.large = large
        layout(large: large)
        updateAppearance()
    }

    /// The icon modes draw selection as the list control does in LVS_ICON / LVS_SMALLICON /
    /// LVS_LIST (selcolors-data/win/*-large-*, *-small-*, *-list-*): the icon blended with the
    /// highlight, the label's text on the highlight in white, nothing while the list is unfocused.
    var drawsHighlight: Bool {
        (isSelected && (panel?.listHasKeyboardFocus ?? true)) || highlightState == .asDropTarget
    }

    func updateAppearance() {
        guard isViewLoaded else { return }
        let lit = drawsHighlight
        label.textColor = lit ? PanelSelectionStyle.highlightText : PanelSelectionStyle.normalText(isDeleted: isDeleted)
        if let baseImage { icon.image = lit ? PanelSelectionStyle.blended(baseImage) : baseImage }
        view.needsDisplay = true
    }

    /// The label rect (LVIR_LABEL): the text's width plus 2 pt either side, centred under a large
    /// icon, left-aligned after a small one.
    fileprivate var labelRect: NSRect {
        let frame = label.frame
        let width = min(frame.width, label.intrinsicContentSize.width) + 2 * PanelSelectionStyle.labelPadding
        let x = large ? frame.midX - width / 2 : frame.minX - PanelSelectionStyle.labelPadding
        return NSRect(x: x, y: frame.minY, width: width, height: frame.height).intersection(view.bounds)
    }

    fileprivate var drawsFocusRectangle: Bool {
        guard let panel, index >= 0 else { return false }
        return panel.focusedIndex == index && panel.listHasKeyboardFocus
    }

    private var installedConstraints: [NSLayoutConstraint] = []

    private func layout(large: Bool) {
        NSLayoutConstraint.deactivate(installedConstraints)
        if large {
            label.alignment = .center
            installedConstraints = [
                icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
                icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                icon.widthAnchor.constraint(equalToConstant: 32),
                icon.heightAnchor.constraint(equalToConstant: 32),
                label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 3),
                label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
            ]
        } else {
            label.alignment = .left
            installedConstraints = [
                icon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                icon.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 16),
                icon.heightAnchor.constraint(equalToConstant: 16),
                label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
                label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ]
        }
        NSLayoutConstraint.activate(installedConstraints)
    }

    override var isSelected: Bool {
        didSet { updateAppearance() }
    }

    override var highlightState: NSCollectionViewItem.HighlightState {
        didSet { updateAppearance() }
    }

    fileprivate var drawsMySelection: Bool { mySelected }

    /// Selection and the AlternativeSelection background, drawn like the table's row view.
    /// The item's root view is its accessibility element (a cell named after the item, selected as
    /// the item is). Without it the collection view's section reported **no children at all**, so
    /// the Large Icons / Small Icons / List modes were empty to VoiceOver and to XCUITest (measured
    /// by `mac/uiverify`: `CollectionView > Other` with nothing under it while four items showed).
    private final class ItemBackgroundView: NSView {
        weak var owner: PanelCollectionItem?

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .cell }
        override func isAccessibilitySelected() -> Bool { owner?.isSelected ?? false }

        override func draw(_ dirtyRect: NSRect) {
            guard let owner else { return }
            if owner.drawsMySelection {
                PanelSelectionStyle.mySelected.setFill()
                bounds.fill()
            }
            let label = owner.labelRect
            if owner.drawsHighlight {
                PanelSelectionStyle.highlight.setFill()
                label.fill()
            }
            if owner.drawsFocusRectangle {
                PanelSelectionStyle.drawFocusRectangle(label, onHighlight: owner.drawsHighlight)
            }
        }
    }
}
