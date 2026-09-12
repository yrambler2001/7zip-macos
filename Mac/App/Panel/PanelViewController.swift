// PanelViewController.swift -- one 7zFM panel (CPanel): address bar with "Up" button and an
// editable path combo box, the details list (NSTableView with the folder's columns), and the
// panel's own status bar. The SZFolder is owned by this panel's serial queue; the main thread
// only sees PanelSnapshot copies.

import Cocoa
import SevenZipKit

protocol PanelDelegate: AnyObject {
    func panelDidBecomeActive(_ panel: PanelViewController)
    func panelDidChangeFolder(_ panel: PanelViewController)
}

final class PanelViewController: NSViewController, NSMenuItemValidation {

    let panelIndex: Int
    weak var delegate: PanelDelegate?

    // MARK: engine side (queue only)
    private let queue: DispatchQueue
    private var folder: SZFolder?

    // MARK: main-thread state
    private(set) var snapshot: PanelSnapshot?
    private var rows: [PanelRow] = []
    private var columns: [SZPropertyInfo] = []
    private var folderTypeOfColumns = ""
    private(set) var sortPropID: SZPropID = .name          // _sortID
    private(set) var ascending = true                       // _ascending
    private(set) var flatMode = false
    private(set) var listViewMode = 3                       // _listViewMode (only details is rendered)
    var isActive = false { didSet { updateActiveHighlight() } }
    private var loadGeneration = 0

    /// Address-bar path of the current folder ("" for the root).
    var currentPath: String { snapshot?.fullPath ?? "" }
    /// Path saved as PanelPath<N> (SavePanelPath): the file-system folder, or the directory of the
    /// outermost archive when browsing inside one.
    var pathToPersist: String { snapshot?.fileSystemPath ?? "" }

    // MARK: views
    private let pathBar = PathBarView()
    private let upButton = NSButton()
    private let pathCombo = NSComboBox()
    private let scrollView = NSScrollView()
    private let tableView = PanelTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let timestampLevel: SZTimestampLevel = SZTimestampLevel(rawValue: Settings.timestampLevel) ?? .min

    init(index: Int) {
        panelIndex = index
        queue = DispatchQueue(label: "com.yrambler2001.7zip.panel\(index)", qos: .userInitiated)
        super.init(nibName: nil, bundle: nil)
        flatMode = Settings.flatView(index)
        listViewMode = Settings.listMode(index)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - View construction (CPanel::OnCreate, Panel.cpp:383-597)

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        // header: [Up] [path combo]
        upButton.bezelStyle = .texturedRounded
        upButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: Lang.text(735, "Up One Level"))
        upButton.toolTip = Lang.text(735, "Up One Level")   // kParentFolderID button
        upButton.target = self
        upButton.action = #selector(upButtonClicked(_:))
        upButton.setContentHuggingPriority(.required, for: .horizontal)

        pathCombo.isEditable = true
        pathCombo.completes = true
        pathCombo.usesDataSource = false
        pathCombo.numberOfVisibleItems = 12
        pathCombo.target = self
        pathCombo.action = #selector(pathComboAction(_:))
        pathCombo.delegate = self
        pathCombo.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let header = NSStackView(views: [upButton, pathCombo])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        header.translatesAutoresizingMaskIntoConstraints = false
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.addSubview(header)

        // list
        tableView.keyHandler = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.gridStyleMask = Settings.showGrid ? [.solidHorizontalGridLineMask, .solidVerticalGridLineMask] : []
        tableView.rowHeight = 20
        tableView.intercellSpacing = NSSize(width: 6, height: 2)
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.headerView = NSTableHeaderView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // status bar (each panel owns one, 1.2)
        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let status = NSView()
        status.translatesAutoresizingMaskIntoConstraints = false
        status.addSubview(statusLabel)

        let topLine = NSBox(); topLine.boxType = .separator; topLine.translatesAutoresizingMaskIntoConstraints = false
        let statusLine = NSBox(); statusLine.boxType = .separator; statusLine.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(pathBar)
        root.addSubview(topLine)
        root.addSubview(scrollView)
        root.addSubview(statusLine)
        root.addSubview(status)

        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: root.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.topAnchor.constraint(equalTo: pathBar.topAnchor),
            header.bottomAnchor.constraint(equalTo: pathBar.bottomAnchor),
            header.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor),
            topLine.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusLine.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            statusLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.topAnchor.constraint(equalTo: statusLine.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: 22),
            statusLabel.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: status.trailingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: status.centerYAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),   // kPanelSizeMin
        ])
        view = root
        updateActiveHighlight()
    }

    private func updateActiveHighlight() {
        pathBar.isActive = isActive
        guard isViewLoaded else { return }
        pathBar.needsDisplay = true
    }

    // MARK: - Public navigation API (main thread)

    /// BindToPathAndRefresh: opens `path` (empty = root); falls back to the root on failure.
    func navigate(to path: String, formatHint: String? = nil, fallbackToRoot: Bool = true, select name: String? = nil) {
        // formatHint (-t<type> on the command line) applies to the archive open; folderForPath
        // detects the type itself, so the hint is accepted for parity and currently unused.
        runOnQueue { [self] in
            self.performNavigate(path: path, fallbackToRoot: fallbackToRoot, selectName: name)
        }
    }

    /// Queue side of navigate(to:).
    private func performNavigate(path: String, fallbackToRoot: Bool, selectName: String?) {
        var target: SZFolder? = nil
        var failure: NSError? = nil
        do {
            target = try SZFolder.folder(forPath: path, passwordDelegate: self)
        } catch let e as NSError {
            failure = e
            if fallbackToRoot { target = SZRootFolder.makeRootFolder() }
        }
        if let t = target { folder = t }
        let snap: PanelSnapshot? = target.map { makeSnapshot($0) }
        let silent = fallbackToRoot && path.isEmpty
        DispatchQueue.main.async {
            if let f = failure, !silent { self.showError(f) }
            if let s = snap { self.apply(s, select: selectName) }
        }
    }

    /// OpenParentFolder (PanelFolderChange.cpp:917): go up and focus the folder we came from.
    func goUp() {
        guard let snap = snapshot, !snap.isRoot else { return }
        let leaving = (snap.fullPath as NSString).lastPathComponent
        runOnQueue { [self] in
            guard let folder = self.folder else { return }
            do {
                let parent = try folder.bindToParentFolder()
                self.folder = parent
                let s = self.makeSnapshot(parent)
                DispatchQueue.main.async { self.apply(s, select: leaving) }
            } catch {
                DispatchQueue.main.async { self.showError(error) }
            }
        }
    }

    /// OpenRootFolder (PanelFolderChange.cpp:1025)
    func goRoot() {
        navigate(to: "")
    }

    /// OnReload / RefreshListCtrl_SaveFocused: reload items, keep the selection by name.
    func reload() {
        let selected = selectedNames()
        runOnQueue { [self] in
            guard let folder = self.folder else { return }
            do {
                try folder.loadItems()
                let s = self.makeSnapshot(folder)
                DispatchQueue.main.async { self.apply(s, selectNames: selected) }
            } catch {
                DispatchQueue.main.async { self.showError(error) }
            }
        }
    }

    /// Timer poll (PanelListNotify / kTimerElapse): reload when the folder reports a change.
    func refreshIfChanged() {
        runOnQueue { [self] in
            guard let folder = self.folder, folder.wasChanged else { return }
            DispatchQueue.main.async { self.reload() }
        }
    }

    /// OpenSelectedItems / OpenFocusedItemAsInternal. `formatHint`: nil = auto, "*" / "#" / type.
    func openSelection(insideOnly: Bool = false, formatHint: String? = nil) {
        guard let row = focusedRow() else { return }
        openRow(row, insideOnly: insideOnly, formatHint: formatHint)
    }

    /// OpenSelectedItems(false): hand the file(s) to the default application (IDM_OPEN_OUTSIDE).
    func openSelectionOutside() {
        guard let snap = snapshot, snap.isFileSystem else { return }
        let base = snap.fullPath
        for row in selectedRows() where !row.isParentRow {
            NSWorkspace.shared.open(URL(fileURLWithPath: base + row.name))
        }
    }

    func setFlatMode(_ flat: Bool) {
        flatMode = flat
        Settings.setFlatView(flat, panelIndex)
        runOnQueue { [self] in
            guard let folder = self.folder, folder.supportsFlatMode else { return }
            folder.flatMode = flat
            do {
                try folder.loadItems()
                let s = self.makeSnapshot(folder)
                DispatchQueue.main.async { self.apply(s, selectNames: []) }
            } catch {
                DispatchQueue.main.async { self.showError(error) }
            }
        }
    }

    func setListViewMode(_ mode: Int) {
        // Only the details view is rendered in Wave 1; the mode is persisted for parity.
        listViewMode = mode
        Settings.setListMode(mode, panelIndex)
    }

    /// SortItemsWithPropID (PanelSort.cpp:256-279)
    func sort(by propID: SZPropID) {
        if propID == sortPropID {
            ascending.toggle()
        } else {
            sortPropID = propID
            ascending = ![SZPropID.size, .packSize, .ctime, .atime, .mtime].contains(propID)
        }
        let selected = selectedNames()
        resortRows()
        tableView.reloadData()
        restoreSelection(names: selected)
        updateSortIndicator()
    }

    func selectAll() { tableView.selectAll(nil); refreshStatusBar() }
    func deselectAll() { tableView.deselectAll(nil); refreshStatusBar() }
    func invertSelection() {
        let all = IndexSet(0..<rows.count)
        let current = tableView.selectedRowIndexes
        tableView.selectRowIndexes(all.subtracting(current), byExtendingSelection: false)
        refreshStatusBar()
    }

    func focusList() {
        view.window?.makeFirstResponder(tableView)
    }

    func focusPathBar() {   // Alt+F1 / Alt+F2 (App.cpp:49 SetFocusToPath)
        view.window?.makeFirstResponder(pathCombo)
    }

    // MARK: - Queue helpers

    private func runOnQueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// Reads everything the main thread needs from the folder (queue only).
    private func makeSnapshot(_ folder: SZFolder) -> PanelSnapshot {
        let props = folder.properties.filter { $0.propID != .isDir }
        let columnIDs = props.map { $0.propID }
        var rows: [PanelRow] = []
        let n = folder.itemCount
        rows.reserveCapacity(n + 1)
        let isRoot = folder.isRootFolder
        if Settings.showDots && !isRoot { rows.append(.parent) }
        for i in 0..<n {
            let name = folder.nameOfItem(at: i)
            let isDir = folder.isDirectory(at: i)
            let size = folder.sizeOfItem(at: i)
            var cells: [SZPropID: String] = [:]
            var keys: [SZPropID: Any] = [:]
            for pid in columnIDs {
                if pid == .name {
                    cells[pid] = Formatting.displayName(name)
                    continue
                }
                cells[pid] = Formatting.cellText(folder: folder, index: i, propID: pid, level: timestampLevel)
                if let v = folder.propertyOfItem(at: i, propID: pid) { keys[pid] = v }
            }
            rows.append(PanelRow(engineIndex: i, name: name, displayName: Formatting.displayName(name),
                                 isDirectory: isDir, size: size, cells: cells, sortKeys: keys))
        }
        var fsFolder: SZFolder = folder
        while let outer = fsFolder.archive?.outerFolder { fsFolder = outer }
        return PanelSnapshot(fullPath: folder.fullPath, fileSystemPath: fsFolder.isArchive ? "" : fsFolder.fullPath,
                             folderType: folder.folderType, isRoot: isRoot,
                             isArchive: folder.isArchive, isFileSystem: folder.isFileSystem,
                             isReadOnly: folder.isReadOnly, columns: props, rows: rows,
                             supportsFlatMode: folder.supportsFlatMode)
    }

    private func openRow(_ row: PanelRow, insideOnly: Bool, formatHint: String?) {
        if row.isParentRow { goUp(); return }
        let engineIndex = row.engineIndex
        runOnQueue { [self] in
            guard let folder = self.folder else { return }
            do {
                if row.isDirectory {
                    let sub = try folder.bindToFolder(at: engineIndex)
                    self.folder = sub
                    let s = self.makeSnapshot(sub)
                    DispatchQueue.main.async { self.apply(s, select: nil) }
                    return
                }
                // a file: try it as an archive (CPanel::OpenItemAsArchive)
                do {
                    let archive = try SZArchiveOpener.openArchive(in: folder, itemIndex: engineIndex,
                                                                  formatHint: formatHint, passwordDelegate: self)
                    let root = try archive.rootFolder()
                    self.folder = root
                    let s = self.makeSnapshot(root)
                    DispatchQueue.main.async { self.apply(s, select: nil) }
                } catch {
                    let code = (error as NSError).code
                    if !insideOnly && folder.isFileSystem && code == SZError.Code.notArchive.rawValue {
                        // not an archive: open with the default application (OpenItemInside falls back to outside)
                        let path = folder.fullPath + row.name
                        DispatchQueue.main.async { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
                    } else if code != SZError.Code.cancelled.rawValue {
                        throw error
                    }
                }
            } catch {
                DispatchQueue.main.async { self.showError(error) }
            }
        }
    }

    // MARK: - Applying a snapshot (RefreshListCtrl, PanelItems.cpp:467-960)

    private func apply(_ snap: PanelSnapshot, select name: String?) {
        apply(snap, selectNames: name.map { [$0] } ?? [])
    }

    private func apply(_ snap: PanelSnapshot, selectNames: [String]) {
        snapshot = snap
        rows = snap.rows
        if snap.folderType != folderTypeOfColumns {
            rebuildColumns(snap)
            // default sort: name ascending for FS/archive folders, natural order for the others (PanelItems.cpp)
            if snap.folderType == "FSFolder" || snap.folderType.hasPrefix("7-Zip.") {
                sortPropID = .name
            } else {
                sortPropID = .noProperty
            }
            ascending = true
        }
        resortRows()
        tableView.reloadData()
        if !selectNames.isEmpty {
            restoreSelection(names: selectNames)
        } else if rows.count > 0 {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView.scrollRowToVisible(0)
        }
        pathCombo.stringValue = snap.fullPath
        if !snap.fullPath.isEmpty && !pathCombo.objectValues.contains(where: { ($0 as? String) == snap.fullPath }) {
            pathCombo.insertItem(withObjectValue: snap.fullPath, at: 0)
            if pathCombo.numberOfItems > 100 { pathCombo.removeItem(at: pathCombo.numberOfItems - 1) }
        }
        Settings.addToFolderHistory(snap.fullPath)
        upButton.isEnabled = !snap.isRoot
        updateSortIndicator()
        refreshStatusBar()
        delegate?.panelDidChangeFolder(self)
    }

    private func rebuildColumns(_ snap: PanelSnapshot) {
        for c in tableView.tableColumns { tableView.removeTableColumn(c) }
        columns = snap.columns
        folderTypeOfColumns = snap.folderType
        let hidden = snap.isFileSystem ? SZFileSystemFolder.defaultHiddenPropIDs : []
        for info in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(info.propID.rawValue)))
            column.title = info.localizedName
            // kpidName 160 px / others 100 px in 7zFM at 96 dpi; the system font needs more room
            switch info.varType {
            case .fileTime: column.width = 140
            default: column.width = info.propID == .name ? 220 : 100
            }
            column.minWidth = 40
            column.isHidden = hidden.contains(NSNumber(value: info.propID.rawValue))
            column.headerCell.alignment = Formatting.alignment(for: info)
            tableView.addTableColumn(column)
        }
    }

    private func resortRows() {
        let pid = sortPropID
        let asc = ascending
        rows.sort { a, b in
            if a.isParentRow != b.isParentRow { return a.isParentRow }          // ".." always first
            if pid != .noProperty && a.isDirectory != b.isDirectory { return a.isDirectory }   // dirs first
            var r = 0
            if pid != .noProperty {
                r = Self.compare(a, b, pid)
                if r == 0 && pid != .name { r = Self.compare(a, b, .name) }
            } else {
                r = a.engineIndex < b.engineIndex ? -1 : (a.engineIndex > b.engineIndex ? 1 : 0)
                return r < 0
            }
            if r == 0 { r = a.engineIndex < b.engineIndex ? -1 : 1 }
            return asc ? r < 0 : r > 0
        }
    }

    /// CompareItems2 property comparison (PanelSort.cpp:98-177)
    private static func compare(_ a: PanelRow, _ b: PanelRow, _ pid: SZPropID) -> Int {
        switch pid {
        case .name, .path, .extension:
            if pid == .extension {
                return SZFolder.compareFileName((a.name as NSString).pathExtension, with: (b.name as NSString).pathExtension)
            }
            return SZFolder.compareFileName(a.name, with: b.name)
        case .size:
            return a.size < b.size ? -1 : (a.size > b.size ? 1 : 0)
        default:
            let x = a.sortKeys[pid], y = b.sortKeys[pid]
            switch (x, y) {
            case (nil, nil): return 0
            case (nil, _): return -1
            case (_, nil): return 1
            case let (n1 as NSNumber, n2 as NSNumber): return n1.compare(n2).rawValue
            case let (d1 as Date, d2 as Date): return d1.compare(d2).rawValue
            case let (s1 as String, s2 as String): return SZFolder.compareFileName(s1, with: s2)
            default: return 0
            }
        }
    }

    private func updateSortIndicator() {
        for column in tableView.tableColumns {
            let pid = SZPropID(rawValue: UInt32(column.identifier.rawValue) ?? 0) ?? .noProperty
            if pid == sortPropID && sortPropID != .noProperty {
                tableView.setIndicatorImage(NSImage(named: ascending ? "NSAscendingSortIndicator" : "NSDescendingSortIndicator"), in: column)
                tableView.highlightedTableColumn = column
            } else {
                tableView.setIndicatorImage(nil, in: column)
            }
        }
        if sortPropID == .noProperty { tableView.highlightedTableColumn = nil }
    }

    // MARK: - Selection helpers

    private func focusedRow() -> PanelRow? {
        let r = tableView.selectedRow
        guard r >= 0, r < rows.count else { return nil }
        return rows[r]
    }

    private func selectedRows() -> [PanelRow] {
        tableView.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    private func selectedNames() -> [String] {
        selectedRows().map { $0.name }
    }

    private func restoreSelection(names: [String]) {
        let set = Set(names)
        var indexes = IndexSet()
        for (i, row) in rows.enumerated() where set.contains(row.name) { indexes.insert(i) }
        if indexes.isEmpty && rows.count > 0 { indexes.insert(0) }
        tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        if let first = indexes.first { tableView.scrollRowToVisible(first) }
    }

    /// Refresh_StatusBar (PanelListNotify.cpp:759-820)
    private func refreshStatusBar() {
        let total = rows.filter { !$0.isParentRow }.count
        var operated = selectedRows().filter { !$0.isParentRow }
        if operated.isEmpty, let f = focusedRow(), !f.isParentRow { operated = [f] }
        let template = Lang.get(3002, "{0} object(s) selected")   // IDS_N_SELECTED_ITEMS
        var parts = [Lang.format(template, "\(operated.count) / \(total)")]
        if !operated.isEmpty {
            parts.append(Formatting.size(operated.reduce(UInt64(0)) { $0 &+ $1.size }))
        }
        if tableView.numberOfSelectedRows > 0, let f = focusedRow(), !f.isParentRow {
            parts.append(Formatting.size(f.size))
            if let m = f.cells[.mtime], !m.isEmpty { parts.append(m) }
        }
        statusLabel.stringValue = parts.joined(separator: "    ")
    }

    private func showError(_ error: Error) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = Lang.text(3007, "Error")   // IDS_ERROR? falls back to "Error"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window)
    }

    // MARK: - Actions

    @objc private func upButtonClicked(_ sender: Any?) { goUp() }

    @objc private func doubleClicked(_ sender: Any?) {
        // NM_DBLCLK on the header area gives row -1
        if tableView.clickedRow >= 0 { openSelection() }
    }

    @objc private func pathComboAction(_ sender: Any?) {
        let text = pathCombo.stringValue.trimmingCharacters(in: .whitespaces)
        navigate(to: text, fallbackToRoot: false)
        focusList()
    }

    // MARK: Menu commands reachable through the responder chain

    @objc func fileOpen(_ sender: Any?) { openSelection() }                                   // IDM_OPEN
    @objc func fileOpenInside(_ sender: Any?) { openSelection(insideOnly: true) }             // IDM_OPEN_INSIDE
    @objc func fileOpenInsideOne(_ sender: Any?) { openSelection(insideOnly: true, formatHint: "*") }    // IDM_OPEN_INSIDE_ONE
    @objc func fileOpenInsideParser(_ sender: Any?) { openSelection(insideOnly: true, formatHint: "#") } // IDM_OPEN_INSIDE_PARSER
    @objc func fileOpenOutside(_ sender: Any?) { openSelectionOutside() }                      // IDM_OPEN_OUTSIDE
    @objc func editSelectAll(_ sender: Any?) { selectAll() }                                  // IDM_SELECT_ALL
    @objc func editDeselectAll(_ sender: Any?) { deselectAll() }                              // IDM_DESELECT_ALL
    @objc func editInvertSelection(_ sender: Any?) { invertSelection() }                      // IDM_INVERT_SELECTION
    @objc func viewArrangeByName(_ sender: Any?) { sort(by: .name) }                          // IDM_VIEW_ARANGE_BY_NAME
    @objc func viewArrangeByType(_ sender: Any?) { sort(by: .extension) }                     // IDM_VIEW_ARANGE_BY_TYPE
    @objc func viewArrangeByDate(_ sender: Any?) { sort(by: .mtime) }                         // IDM_VIEW_ARANGE_BY_DATE
    @objc func viewArrangeBySize(_ sender: Any?) { sort(by: .size) }                          // IDM_VIEW_ARANGE_BY_SIZE
    @objc func viewArrangeNoSort(_ sender: Any?) { sort(by: .noProperty) }                    // IDM_VIEW_ARANGE_NO_SORT
    @objc func viewFlatView(_ sender: Any?) { setFlatMode(!flatMode) }                        // IDM_VIEW_FLAT_VIEW
    @objc func viewOpenRootFolder(_ sender: Any?) { goRoot() }                                // IDM_OPEN_ROOT_FOLDER
    @objc func viewOpenParentFolder(_ sender: Any?) { goUp() }                                // IDM_OPEN_PARENT_FOLDER
    @objc func viewRefresh(_ sender: Any?) { reload() }                                       // IDM_VIEW_REFRESH
    @objc func viewLargeIcons(_ sender: Any?) { setListViewMode(0) }                          // IDM_VIEW_LARGE_ICONS
    @objc func viewSmallIcons(_ sender: Any?) { setListViewMode(1) }                          // IDM_VIEW_SMALL_ICONS
    @objc func viewList(_ sender: Any?) { setListViewMode(2) }                                // IDM_VIEW_LIST
    @objc func viewDetails(_ sender: Any?) { setListViewMode(3) }                             // IDM_VIEW_DETAILS

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(viewOpenParentFolder(_:)): return !(snapshot?.isRoot ?? true)
        case #selector(fileOpenOutside(_:)): return snapshot?.isFileSystem ?? false
        case #selector(viewFlatView(_:)):
            item.state = flatMode ? .on : .off
            return snapshot?.supportsFlatMode ?? false
        case #selector(viewArrangeByName(_:)): item.state = sortPropID == .name ? .on : .off
        case #selector(viewArrangeByType(_:)): item.state = sortPropID == .extension ? .on : .off
        case #selector(viewArrangeByDate(_:)): item.state = sortPropID == .mtime ? .on : .off
        case #selector(viewArrangeBySize(_:)): item.state = sortPropID == .size ? .on : .off
        case #selector(viewArrangeNoSort(_:)): item.state = sortPropID == .noProperty ? .on : .off
        case #selector(viewLargeIcons(_:)): item.state = listViewMode == 0 ? .on : .off
        case #selector(viewSmallIcons(_:)): item.state = listViewMode == 1 ? .on : .off
        case #selector(viewList(_:)): item.state = listViewMode == 2 ? .on : .off
        case #selector(viewDetails(_:)): item.state = listViewMode == 3 ? .on : .off
        default: break
        }
        return true
    }
}

// MARK: - Table data source / delegate

extension PanelViewController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < rows.count else { return nil }
        let item = rows[row]
        let pid = SZPropID(rawValue: UInt32(tableColumn.identifier.rawValue) ?? 0) ?? .noProperty
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
            cell.imageView?.image = Icons.icon(forName: item.name, isDirectory: item.isDirectory)
        } else {
            cell.textField?.stringValue = item.cells[pid] ?? ""
            if let info = columns.first(where: { $0.propID == pid }) {
                cell.textField?.alignment = Formatting.alignment(for: info)
            }
        }
        return cell
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        // LVN_COLUMNCLICK -> OnColumnClick (PanelSort.cpp:281)
        let pid = SZPropID(rawValue: UInt32(tableColumn.identifier.rawValue) ?? 0) ?? .noProperty
        sort(by: pid)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        refreshStatusBar()
    }
}

// MARK: - Keys, focus, combo box

extension PanelViewController: PanelTableViewKeyHandler, NSComboBoxDelegate {

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
}

// MARK: - Password prompt (CPasswordDialog run for the worker thread, ExtractCallback.cpp:218)

extension PanelViewController: SZPasswordDelegate {

    func passwordForArchive(atPath path: String) -> String? {
        precondition(!Thread.isMainThread, "engine callbacks must not run on the main thread")
        var result: String?
        DispatchQueue.main.sync {
            let alert = NSAlert()
            alert.messageText = Lang.text(3800, "Enter password")          // IDD_PASSWORD
            alert.informativeText = (path as NSString).lastPathComponent
            alert.addButton(withTitle: Lang.text(401, "OK"))
            alert.addButton(withTitle: Lang.text(402, "Cancel"))
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            alert.accessoryView = field
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertFirstButtonReturn {
                result = field.stringValue
            }
        }
        return result
    }
}

// MARK: - Address bar background (active-panel highlight)

final class PathBarView: NSView {
    var isActive = false { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        (isActive ? NSColor.controlAccentColor.withAlphaComponent(0.18) : NSColor.windowBackgroundColor).setFill()
        bounds.fill()
        if isActive {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 0, width: bounds.width, height: 2).fill()
        }
    }
}
