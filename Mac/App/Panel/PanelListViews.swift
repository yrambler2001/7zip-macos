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
        let identifier = NSUserInterfaceItemIdentifier(isName ? "name" : "text")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            if isName {
                let image = NSImageView()
                image.translatesAutoresizingMaskIntoConstraints = false
                image.setAccessibilityElement(false)
                cell.addSubview(image)
                cell.imageView = image
                NSLayoutConstraint.activate([
                    image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                    image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                    image.widthAnchor.constraint(equalToConstant: 16),
                    image.heightAnchor.constraint(equalToConstant: 16),
                    text.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 4),
                ])
            } else {
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2).isActive = true
            }
            NSLayoutConstraint.activate([
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        if isName {
            cell.textField?.stringValue = item.displayName
            cell.textField?.alignment = .left
            cell.imageView?.image = icon(for: item)
            cell.textField?.isEditable = false                    // label editing starts on F2 only
        } else {
            cell.textField?.stringValue = item.cells[pid] ?? ""
            if let info = columnsModel.columns.first(where: { $0.propID == pid }) {
                cell.textField?.alignment = PanelFormat.alignment(for: info.varType, propID: pid)
            }
        }
        // kpidIsDeleted rows are drawn in red (OnCustomDraw, 01 §3.6).
        cell.textField?.textColor = item.isDeleted ? .systemRed : .labelColor
        return cell
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        guard let pid = PanelViewController.propID(of: tableColumn) else { return }
        sort(by: pid)                                             // OnColumnClick (PanelSort.cpp:281)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if !usesAlternativeSelection {
            let selected = tableView.selectedRowIndexes
            if let last = selected.last, !selected.contains(focusedIndex) { focusedIndex = last }
            iconView.setSelectionIndexes(selected)
        } else if tableView.selectedRow >= 0 {
            focusedIndex = tableView.selectedRow
        }
        refreshStatusBar()                                        // OnItemChanged (01 §3.12)
    }

    func tableViewColumnDidMove(_ notification: Notification) { saveColumnLayout() }
    func tableViewColumnDidResize(_ notification: Notification) { saveColumnLayout() }
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

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // CBN_SELENDOK: binding happens in the action (Enter / selection commit).
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
        collectionView.register(PanelCollectionItem.self,
                                forItemWithIdentifier: PanelCollectionItem.identifier)
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
        collectionView.collectionViewLayout = layout
        collectionView.reloadData()
    }

    var isLargeIcons: Bool { mode == 0 }

    func reloadData() {
        guard !isHidden else { return }
        collectionView.reloadData()
    }

    var selectionIndexes: IndexSet {
        IndexSet(collectionView.selectionIndexPaths.map { $0.item })
    }

    func setSelectionIndexes(_ indexes: IndexSet) {
        let paths = Set(indexes.map { IndexPath(item: $0, section: 0) })
        collectionView.selectionIndexPaths = paths
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
        let item = collectionView.makeItem(withIdentifier: PanelCollectionItem.identifier, for: indexPath)
        guard let cell = item as? PanelCollectionItem, let panel, indexPath.item < panel.rows.count else { return item }
        let row = panel.rows[indexPath.item]
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
}

/// The collection view forwards the panel key map and activates on a double click.
final class PanelCollectionView: NSCollectionView {

    weak var panel: PanelViewController?

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let panel { panel.delegate?.panelDidBecomeActive(panel) }
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

    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var mySelected = false

    override func loadView() {
        let root = ItemBackgroundView()
        root.owner = self
        root.translatesAutoresizingMaskIntoConstraints = false
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
        icon.image = image
        label.stringValue = name
        label.textColor = isDeleted ? .systemRed : .labelColor
        self.mySelected = mySelected
        layout(large: large)
        view.needsDisplay = true
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
        didSet { view.needsDisplay = true }
    }

    fileprivate var drawsSelection: Bool { isSelected }
    fileprivate var drawsMySelection: Bool { mySelected }

    /// Selection and the AlternativeSelection background, drawn like the table's row view.
    private final class ItemBackgroundView: NSView {
        weak var owner: PanelCollectionItem?

        override func draw(_ dirtyRect: NSRect) {
            if owner?.drawsMySelection == true {
                NSColor(calibratedRed: 1.0, green: 192.0 / 255.0, blue: 192.0 / 255.0, alpha: 1.0).setFill()
                bounds.fill()
            }
            if owner?.drawsSelection == true {
                NSColor.selectedContentBackgroundColor.setFill()
                bounds.fill()
            }
        }
    }
}
