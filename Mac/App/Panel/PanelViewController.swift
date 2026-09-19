// PanelViewController.swift -- one 7zFM panel (CPanel, Panel.cpp / PanelItems.cpp): the address
// bar with the "Up" button and an editable path combo, the four view modes (details table plus a
// collection view for large icons / small icons / list), the folder's columns, selection, and the
// panel's own status bar. The SZFolder is owned by this panel's serial queue; the main thread only
// sees PanelSnapshot / PanelRow copies.
//
// Parity: 01-fm-feature-inventory.md §3.1, §3.2, §3.6, §3.12, §3.17; navigation in
// PanelNavigation.swift, operations in PanelOperations.swift, context menu in
// PanelContextMenu.swift, drag & drop and the clipboard in PanelDragDrop.swift.

import Cocoa
import SevenZipKit

protocol PanelDelegate: AnyObject {
    func panelDidBecomeActive(_ panel: PanelViewController)
    func panelDidChangeFolder(_ panel: PanelViewController)
    /// Tab in the list: switch the focused panel (CPanelCallbackImp::OnTab).
    func panelWantsNextPanel(_ panel: PanelViewController)
    /// F9 from the list (SwitchOnOffOnePanel) and Ctrl+W / Cmd+W (close the window, 01 §3.7).
    func panelWantsOnePanelToggle(_ panel: PanelViewController)
    func panelWantsWindowClose(_ panel: PanelViewController)
    /// Alt+Up / Alt+Left / Alt+Right (OnSetSameFolder / OnSetSubFolder, 01 §3.8).
    func panel(_ panel: PanelViewController, setOtherPanelPath path: String)
    /// Alt+F1 / Alt+F2: focus the address bar of panel 0 / 1.
    func panel(_ panel: PanelViewController, focusAddressBarOfPanel index: Int)
    /// F5 / F6 (CApp::OnCopy) -- the window owns the copy/move flow.
    func panel(_ panel: PanelViewController, copyOrMove move: Bool, copyToSame: Bool)
    /// Number keys with Alt: favorites (CPanel::SetBookmark / OpenBookmark).
    func panel(_ panel: PanelViewController, bookmark index: Int, set: Bool)
}

final class PanelViewController: NSViewController, NSMenuItemValidation {

    let panelIndex: Int
    weak var delegate: PanelDelegate?

    // MARK: engine side (panel queue only)
    let queue: DispatchQueue
    /// Only ever assigned and used on `queue` (the engine's COM refcounts are not atomic).
    var folder: SZFolder?
    /// Password of the open archive chain, remembered like CFolderLink::Password.
    var rememberedPassword: String?
    /// Set while an operation owns the folder on another thread (CDisableTimerProcessing).
    private(set) var isOperating = false

    // MARK: main-thread state
    private(set) var snapshot: PanelSnapshot?
    private(set) var rows: [PanelRow] = []
    var columnsModel = PanelColumnsModel(properties: [], folderType: "", isFileSystem: false,
                                                      hiddenByDefault: [], layout: nil)
    private var folderTypeOfColumns = ""
    private(set) var listViewMode = 3                       // _listViewMode, 3 = details
    private(set) var flatModeForDisk = false                // _flatModeForDisk
    private(set) var flatModeForArc = false                 // _flatModeForArc
    var isActive = false { didSet { updateActiveHighlight() } }
    /// AlternativeSelection mode keeps its own vector (_selectedStatusVector, 01 §3.6).
    private var mySelected = Set<Int>()
    private var alternativeSelection = Settings.alternativeSelection
    /// The row with the caret. NSTableView has no separate focus, so the panel tracks it.
    var focusedIndex = -1
    /// Shift key-down anchor (_prevFocusedItem, 01 §3.7).
    var selectionAnchor = -1
    /// Per-panel navigation stack (macOS addition; 7zFM has no Back/Forward, 01 §9).
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var suppressHistory = false
    private var fsIconCache: [String: NSImage] = [:]
    /// Row whose name cell is being edited in place (OnBeginLabelEdit / OnEndLabelEdit).
    var renamingRow: Int?
    private var isApplyingSettings = false
    private var pendingFocusName: String?
    private var pendingSelectionMask: String?

    var sortPropID: SZPropID { columnsModel.sortID }
    var ascending: Bool { columnsModel.ascending }
    var flatMode: Bool { (snapshot?.isArchive ?? false) ? flatModeForArc : flatModeForDisk }
    var timestampLevel: SZTimestampLevel { SZTimestampLevel(rawValue: Settings.timestampLevel) ?? .min }

    /// Address-bar path of the current folder ("" for the root).
    var currentPath: String { snapshot?.fullPath ?? "" }
    /// Path saved as PanelPath<N> (SavePanelPath): the file-system folder, or the directory of the
    /// outermost archive when browsing inside one.
    var pathToPersist: String { snapshot?.fileSystemPath ?? "" }

    // MARK: views
    let pathBar = PathBarView()
    private let upButton = NSButton()
    let pathCombo = NSComboBox()
    private let folderIcon = NSImageView()
    private let listContainer = NSView()
    private let scrollView = NSScrollView()
    let tableView = PanelTableView()
    private(set) var iconView: PanelIconView!
    private let statusLabel = NSTextField(labelWithString: "")

    init(index: Int) {
        panelIndex = index
        queue = DispatchQueue(label: "com.yrambler2001.7zip.panel\(index)", qos: .userInitiated)
        super.init(nibName: nil, bundle: nil)
        flatModeForArc = Settings.flatView(index)           // FlatViewArc<N> (01 §3.4)
        listViewMode = max(0, min(3, Settings.listMode(index)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - View construction (CPanel::OnCreate, Panel.cpp:383-597)

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        upButton.bezelStyle = .texturedRounded
        upButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: Lang.text(735, "Up One Level"))
        upButton.toolTip = Lang.text(735, "Up One Level")   // kParentFolderID button
        upButton.target = self
        upButton.action = #selector(upButtonClicked(_:))
        upButton.setContentHuggingPriority(.required, for: .horizontal)

        folderIcon.imageScaling = .scaleProportionallyDown
        folderIcon.setContentHuggingPriority(.required, for: .horizontal)
        folderIcon.setAccessibilityElement(false)

        pathCombo.isEditable = true
        pathCombo.completes = true
        pathCombo.usesDataSource = false
        pathCombo.numberOfVisibleItems = 16
        pathCombo.target = self
        pathCombo.action = #selector(pathComboAction(_:))
        pathCombo.delegate = self
        pathCombo.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)

        let header = NSStackView(views: [upButton, folderIcon, pathCombo])
        header.orientation = .horizontal
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 5, left: 6, bottom: 5, right: 6)
        header.translatesAutoresizingMaskIntoConstraints = false
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.addSubview(header)

        // details list
        tableView.keyHandler = self
        tableView.panel = self
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = !alternativeSelection
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
        tableView.action = #selector(singleClicked(_:))
        tableView.headerView = PanelTableHeaderView()
        tableView.registerForDraggedTypes(PanelDragDrop.acceptedTypes)
        tableView.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        tableView.setDraggingSourceOperationMask([.copy], forLocal: false)
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // icon / small icon / list modes (NSCollectionView, 01 §3.1)
        iconView = PanelIconView(panel: self)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.isHidden = true

        listContainer.translatesAutoresizingMaskIntoConstraints = false
        listContainer.addSubview(scrollView)
        listContainer.addSubview(iconView)

        // status bar (each panel owns one, 01 §1.2)
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
        root.addSubview(listContainer)
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
            folderIcon.widthAnchor.constraint(equalToConstant: 16),
            folderIcon.heightAnchor.constraint(equalToConstant: 16),
            topLine.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            topLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            topLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listContainer.topAnchor.constraint(equalTo: topLine.bottomAnchor),
            listContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            iconView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            statusLine.topAnchor.constraint(equalTo: listContainer.bottomAnchor),
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
        applyListViewMode()
        updateActiveHighlight()
        observeSettings()
    }

    private func updateActiveHighlight() {
        pathBar.isActive = isActive
        guard isViewLoaded else { return }
        pathBar.needsDisplay = true
    }

    /// SetListSettings (App.cpp) -- the Options > Settings booleans and the View menu's timestamp
    /// level take effect immediately (01 §1.2, 01b §4.19).
    private func observeSettings() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(settingsDidChange(_:)),
                           name: Settings.Group.fm.notificationName, object: nil)
        center.addObserver(self, selector: #selector(settingsDidChange(_:)),
                           name: Settings.Group.view.notificationName, object: nil)
    }

    /// Only the settings that change what a panel shows are acted on. The panel itself writes
    /// FM.Columns.*, FM.FolderHistory, FM.ListMode* and FM.FlatViewArc*, which are also in the
    /// `.view` group, so reacting to those would reload in a loop.
    @objc private func settingsDidChange(_ note: Notification) {
        let key = note.userInfo?[Settings.keyUserInfoKey] as? String
        guard let group = note.userInfo?[Settings.groupUserInfoKey] as? Settings.Group else {
            applyListSettings()
            return
        }
        switch group {
        case .fm:                                   // the seven CFmSettings booleans (SetListSettings)
            applyListSettings()
        case .view:
            if key == "FM.TimestampLevel" || key == "FM.TimestampShowUTC" { reload(keepScroll: true) }
        default:
            break
        }
    }

    /// The seven CFmSettings booleans plus the timestamp level.
    func applyListSettings() {
        guard isViewLoaded, !isApplyingSettings else { return }
        isApplyingSettings = true
        defer { isApplyingSettings = false }
        tableView.gridStyleMask = Settings.showGrid ? [.solidHorizontalGridLineMask, .solidVerticalGridLineMask] : []
        let alternative = Settings.alternativeSelection
        if alternative != alternativeSelection {
            alternativeSelection = alternative
            tableView.allowsMultipleSelection = !alternative
            mySelected.removeAll()
        }
        tableView.needsDisplay = true
        reload()                                            // ShowDots / icons / timestamp level
    }

    var usesAlternativeSelection: Bool { alternativeSelection }

    /// The folder the active panel shows, for the frozen OperationContext contract. Read on the
    /// main thread but only ever *used* from an off-main operation (OperationContext.swift).
    func currentFolderForContext() -> SZFolder? { folder }

    // MARK: - Queue helpers

    func runOnQueue(_ work: @escaping () -> Void) {
        queue.async(execute: work)
    }

    /// Runs `work` under the shared operation runner while the panel queue is parked, so the
    /// folder is touched by exactly one thread (opsinfra api §1, §4 ownership rule).
    @discardableResult
    func runFolderOperation<T>(_ options: OperationRunner.Options,
                               work: @escaping (SZFolder, OperationRunner) throws -> T) -> Result<T, Error>? {
        guard let folder else { return nil }
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }                         // CDisableTimerProcessing equivalent
        isOperating = true
        var opts = options
        if opts.parentWindow == nil { opts.parentWindow = view.window }
        let result = OperationRunner.run(opts) { runner in try work(folder, runner) }
        isOperating = false
        gate.signal()
        return result
    }

    /// Reads everything the main thread needs from the folder (queue only).
    func makeSnapshot(_ folder: SZFolder) -> PanelSnapshot {
        let props = folder.properties.filter { $0.propID != .isDir }
        let columnIDs = props.map { $0.propID }
        let level = timestampLevel
        let isFS = folder.isFileSystem
        let fsFolderObject = folder as? SZFileSystemFolder
        var rows: [PanelRow] = []
        let n = folder.itemCount
        rows.reserveCapacity(n + 1)
        let isRoot = folder.isRootFolder
        if Settings.showDots && !isRoot { rows.append(.parent) }
        let flat = folder.flatMode
        for i in 0..<n {
            let name = folder.nameOfItem(at: i)
            let isDir = folder.isDirectory(at: i)
            var cells: [SZPropID: String] = [:]
            var keys: [SZPropID: Any] = [:]
            for pid in columnIDs {
                if pid == .name {
                    cells[pid] = Formatting.displayName(name)
                    keys[pid] = name
                    continue
                }
                cells[pid] = Formatting.cellText(folder: folder, index: i, propID: pid, level: level)
                if let v = folder.propertyOfItem(at: i, propID: pid) { keys[pid] = v }
            }
            let deleted = (folder.propertyOfItem(at: i, propID: .isDeleted) as? NSNumber)?.boolValue ?? false
            rows.append(PanelRow(engineIndex: i, name: name, displayName: Formatting.displayName(name),
                                 isDirectory: isDir, size: folder.sizeOfItem(at: i),
                                 prefix: flat ? folder.prefixOfItem(at: i) : "",
                                 isDeleted: deleted,
                                 isPackage: fsFolderObject?.isPackage(at: i) ?? false,
                                 fullPath: fsFolderObject?.fullPathOfItem(at: i) ?? "",
                                 cells: cells, sortKeys: keys))
        }
        // The outermost archive and the file-system folder that holds it (CFolderLink chain).
        var outer: SZFolder = folder
        var archivePath = ""
        var chainReadOnly = folder.isReadOnly
        while let archive = outer.archive {
            if archive.outerFolder == nil { archivePath = archive.path; break }
            archivePath = archive.path
            guard let next = archive.outerFolder else { break }
            outer = next
            chainReadOnly = chainReadOnly || outer.isReadOnly
        }
        let isHash = (folder.folderProperty(forID: .isHash) as? NSNumber)?.boolValue ?? false
        let hidden: Set<UInt32> = isFS
            ? Set(SZFileSystemFolder.defaultHiddenPropIDs.map { $0.uint32Value })
            : []
        return PanelSnapshot(fullPath: folder.fullPath,
                             fileSystemPath: archivePath.isEmpty ? (isFS ? folder.fullPath : "")
                                                                 : (archivePath as NSString).deletingLastPathComponent + "/",
                             folderType: folder.folderType, isRoot: isRoot,
                             isArchive: folder.isArchive, isFileSystem: isFS,
                             isReadOnly: folder.isReadOnly, isHashFolder: isHash,
                             chainIsReadOnly: chainReadOnly,
                             columns: props, rows: rows,
                             supportsFlatMode: folder.supportsFlatMode,
                             supportsOperations: folder.supportsOperations,
                             supportsChangeNotification: folder.supportsChangeNotification,
                             archivePath: archivePath,
                             isVolumesFolder: folder.folderType == "FSDrives",
                             hiddenByDefault: hidden)
    }

    // MARK: - Applying a snapshot (RefreshListCtrl, PanelItems.cpp:467-960)

    func apply(_ snap: PanelSnapshot, select name: String? = nil) {
        apply(snap, selectNames: name.map { [$0] } ?? [], focusName: name)
    }

    func apply(_ snap: PanelSnapshot, selectNames: [String], focusName: String? = nil, keepScroll: Bool = false) {
        let previousPath = snapshot?.fullPath
        let scroll = scrollView.contentView.bounds.origin
        snapshot = snap
        rows = snap.rows
        fsIconCache.removeAll(keepingCapacity: true)
        if snap.folderType != folderTypeOfColumns {
            saveColumnLayout()                              // SaveListViewInfo before rebuilding
            columnsModel = PanelColumnsModel(properties: snap.columns, folderType: snap.folderType,
                                             isFileSystem: snap.isFileSystem,
                                             hiddenByDefault: snap.hiddenByDefault,
                                             layout: Settings.columnLayout(forFolderType: snap.folderType))
            folderTypeOfColumns = snap.folderType
            rebuildColumns()
        } else if columnsModel.columns.count != snap.columns.filter({ $0.propID != .isDir }).count {
            // flat mode adds/removes kpidPrefix (fsfolder api §2)
            columnsModel = PanelColumnsModel(properties: snap.columns, folderType: snap.folderType,
                                             isFileSystem: snap.isFileSystem,
                                             hiddenByDefault: snap.hiddenByDefault,
                                             layout: columnsModel.layout())
            rebuildColumns()
        }
        resortRows()
        var names = selectNames
        if let mask = pendingSelectionMask {                 // wildcard in the bound path (01 §3.8)
            pendingSelectionMask = nil
            names = rows.filter { !$0.isParentRow && PanelMask.matches(mask: mask, name: $0.name) }.map { $0.name }
        }
        if let pending = pendingFocusName {
            pendingFocusName = nil
            if names.isEmpty { names = [pending] }
        }
        reloadList()
        restoreSelection(names: names, focusName: focusName ?? names.first)
        if keepScroll {
            scrollView.contentView.scroll(to: scroll)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        updateAddressBar(snap)
        if previousPath != snap.fullPath { noteFolderVisited(snap.fullPath, previous: previousPath) }
        upButton.isEnabled = !snap.isRoot
        updateSortIndicator()
        refreshStatusBar()
        delegate?.panelDidChangeFolder(self)
    }

    /// Reloads whichever view mode is on screen.
    func reloadList() {
        tableView.reloadData()
        iconView.reloadData()
    }

    private func rebuildColumns() {
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for info in columnsModel.visibleColumns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(info.propID.rawValue)))
            column.title = info.title
            column.width = CGFloat(info.width)
            column.minWidth = 24
            column.maxWidth = 2000
            column.headerCell.alignment = PanelFormat.alignment(for: info.varType, propID: info.propID)
            tableView.addTableColumn(column)
        }
    }

    /// SaveListViewInfo (PanelItems.cpp:1322): order, width, visibility, sort per folder type.
    func saveColumnLayout() {
        guard !folderTypeOfColumns.isEmpty, !columnsModel.columns.isEmpty else { return }
        var model = columnsModel
        for column in tableView.tableColumns {
            guard let pid = Self.propID(of: column) else { continue }
            model.setWidth(Int(column.width.rounded()), propID: pid)
        }
        let order = tableView.tableColumns.compactMap { Self.propID(of: $0) }
        if !order.isEmpty {
            var full = order
            full.append(contentsOf: model.columns.map { $0.propID }.filter { !order.contains($0) })
            model.reorder(to: full)
        }
        columnsModel = model
        Settings.setColumnLayout(model.layout(), forFolderType: folderTypeOfColumns)
    }

    static func propID(of column: NSTableColumn) -> SZPropID? {
        guard let raw = UInt32(column.identifier.rawValue) else { return nil }
        return SZPropID(rawValue: raw)
    }

    // MARK: - Sorting (PanelSort.cpp)

    func resortRows() {
        rows = PanelSorting.sorted(rows: rows, sortID: columnsModel.sortID, ascending: columnsModel.ascending,
                                   flatMode: flatMode, folderCompare: nil)
    }

    /// SortItemsWithPropID (PanelSort.cpp:256-279)
    func sort(by propID: SZPropID) {
        let names = selectedNames()
        let focus = focusedRow()?.name
        columnsModel.sort(by: propID)
        resortRows()
        reloadList()
        restoreSelection(names: names, focusName: focus)
        updateSortIndicator()
        Settings.setColumnLayout(columnsModel.layout(), forFolderType: folderTypeOfColumns)
    }

    private func updateSortIndicator() {
        for column in tableView.tableColumns {
            let pid = Self.propID(of: column)
            if pid == columnsModel.sortID && columnsModel.sortID != .noProperty {
                tableView.setIndicatorImage(NSImage(named: columnsModel.ascending ? "NSAscendingSortIndicator"
                                                                                  : "NSDescendingSortIndicator"), in: column)
                tableView.highlightedTableColumn = column
            } else {
                tableView.setIndicatorImage(nil, in: column)
            }
        }
        if columnsModel.sortID == .noProperty { tableView.highlightedTableColumn = nil }
    }

    // MARK: - View modes (SetListViewMode, Panel.cpp:871-892)

    func setListViewMode(_ mode: Int) {
        guard (0...3).contains(mode) else { return }
        let names = selectedNames()
        let focus = focusedRow()?.name
        listViewMode = mode
        Settings.setListMode(mode, panelIndex)
        applyListViewMode()
        reloadList()
        restoreSelection(names: names, focusName: focus)     // items and selection are preserved
    }

    private func applyListViewMode() {
        guard isViewLoaded else { return }
        let details = listViewMode == 3
        iconView.isHidden = details
        iconView.setMode(listViewMode)
        if details {
            view.window?.makeFirstResponder(tableView)
        } else {
            view.window?.makeFirstResponder(iconView.collectionView)
        }
    }

    // MARK: - Flat view (ChangeFlatMode, Panel.cpp:894-903)

    func setFlatMode(_ flat: Bool) {
        let isArchive = snapshot?.isArchive ?? false
        if isArchive {
            flatModeForArc = flat
            Settings.setFlatView(flat, panelIndex)          // only the arc flag persists (01 §3.4)
        } else {
            flatModeForDisk = flat
        }
        runOnQueue { [self] in
            guard let folder = self.folder, folder.supportsFlatMode else { return }
            folder.flatMode = flat
            do {
                try folder.loadItems()
                let snap = self.makeSnapshot(folder)
                DispatchQueue.main.async { self.apply(snap, selectNames: []) }
            } catch {
                DispatchQueue.main.async { self.showError(error) }
            }
        }
    }

    // MARK: - Reload

    /// OnReload / RefreshListCtrl_SaveFocused: reload items, keep focus and selection by name.
    func reload(keepScroll: Bool = false) {
        let names = selectedNames()
        let focus = focusedRow()?.name
        runOnQueue { [self] in
            guard let folder = self.folder else { return }
            do {
                folder.flatMode = self.flatModeValueForQueue(folder)
                try folder.loadItems()
                let snap = self.makeSnapshot(folder)
                DispatchQueue.main.async { self.apply(snap, selectNames: names, focusName: focus, keepScroll: keepScroll) }
            } catch {
                DispatchQueue.main.async { self.showError(error) }
            }
        }
    }

    private func flatModeValueForQueue(_ folder: SZFolder) -> Bool {
        guard folder.supportsFlatMode else { return false }
        return folder.isArchive ? flatModeForArc : flatModeForDisk
    }

    /// Timer poll (OnTimer, PanelItems.cpp:1458): reload when the folder reports a change; an FS
    /// folder that disappeared makes the panel go up instead (fsfolder api §7).
    func refreshIfChanged() {
        guard !isOperating else { return }
        runOnQueue { [self] in
            guard let folder = self.folder else { return }
            if let fs = folder as? SZFileSystemFolder, fs.directoryWasRemoved {
                DispatchQueue.main.async { self.recoverFromRemovedDirectory() }
                return
            }
            guard folder.supportsChangeNotification, folder.wasChanged else { return }
            DispatchQueue.main.async { self.reload(keepScroll: true) }
        }
    }

    // MARK: - Selection

    /// The list rows that are selected (view state, or the internal vector in AlternativeSelection).
    var selectedIndexes: IndexSet {
        if alternativeSelection { return IndexSet(mySelected.filter { $0 < rows.count }) }
        return listViewMode == 3 ? tableView.selectedRowIndexes : iconView.selectionIndexes
    }

    func setSelectedIndexes(_ indexes: IndexSet) {
        if alternativeSelection {
            mySelected = Set(indexes.filter { $0 >= 0 && $0 < rows.count && !rows[$0].isParentRow })
            tableView.needsDisplay = true
            iconView.reloadData()
        } else {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            iconView.setSelectionIndexes(indexes)
        }
        refreshStatusBar()
    }

    func selectedRows() -> [PanelRow] { selectedIndexes.compactMap { $0 < rows.count ? rows[$0] : nil } }
    func selectedNames() -> [String] { selectedRows().map { $0.name } }

    func focusedRow() -> PanelRow? {
        if focusedIndex >= 0 && focusedIndex < rows.count { return rows[focusedIndex] }
        if let first = selectedIndexes.first, first < rows.count { return rows[first] }
        return rows.isEmpty ? nil : rows[0]
    }

    /// Get_ItemIndices_Operated: the list indices the commands work on.
    func operatedRowIndices() -> [Int] {
        PanelOperatedItems.operated(rows: rows, selected: selectedIndexes, focused: focusedIndex)
    }

    /// The same as engine item indices.
    func operatedEngineIndices() -> [Int] {
        operatedRowIndices().map { rows[$0].engineIndex }
    }

    func setFocus(_ index: Int, extendingSelection: Bool = false) {
        guard index >= 0, index < rows.count else { return }
        focusedIndex = index
        if !extendingSelection { setSelectedIndexes(IndexSet(integer: index)) }
        scrollRowToVisible(index)
        refreshStatusBar()
    }

    func scrollRowToVisible(_ index: Int) {
        if listViewMode == 3 {
            tableView.scrollRowToVisible(index)
        } else {
            iconView.scrollItemToVisible(index)
        }
    }

    func restoreSelection(names: [String], focusName: String?) {
        let wanted = Set(names)
        var indexes = IndexSet()
        for (i, row) in rows.enumerated() where wanted.contains(row.name) && !row.isParentRow { indexes.insert(i) }
        var focus = -1
        if let focusName, let index = rows.firstIndex(where: { $0.name == focusName }) {
            focus = index
        } else if let first = indexes.first {
            focus = first
        } else if !rows.isEmpty {
            focus = 0
        }
        focusedIndex = focus
        if indexes.isEmpty && focus >= 0 && !alternativeSelection {
            indexes.insert(focus)
        }
        if alternativeSelection {
            mySelected = Set(indexes.filter { !rows[$0].isParentRow })
            if focus >= 0 { tableView.selectRowIndexes(IndexSet(integer: focus), byExtendingSelection: false) }
        } else {
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            iconView.setSelectionIndexes(indexes)
        }
        if focus >= 0 { scrollRowToVisible(focus) }
        refreshStatusBar()
    }

    func isMySelected(_ index: Int) -> Bool { alternativeSelection && mySelected.contains(index) }

    func toggleMySelection(_ index: Int) {
        guard index >= 0, index < rows.count, !rows[index].isParentRow else { return }
        if mySelected.contains(index) { mySelected.remove(index) } else { mySelected.insert(index) }
        tableView.needsDisplay = true
        iconView.reloadData()
        refreshStatusBar()
    }

    // MARK: - Status bar (Refresh_StatusBar, PanelListNotify.cpp:759-820)

    func refreshStatusBar() {
        let total = rows.reduce(0) { $1.isParentRow ? $0 : $0 + 1 }
        let operated = operatedRowIndices().map { rows[$0] }
        let template = Lang.get(3002, "{0} object(s) selected")   // IDS_N_SELECTED_ITEMS
        var parts = [Lang.format(template, "\(operated.count) / \(total)")]
        if !operated.isEmpty {
            parts.append(Formatting.size(operated.reduce(UInt64(0)) { $0 &+ $1.size }))
        } else {
            parts.append("")
        }
        // Parts 2 and 3 only when something is selected and the focused row is not "..".
        if !selectedIndexes.isEmpty, let focused = focusedRow(), !focused.isParentRow {
            parts.append(Formatting.size(focused.size))
            parts.append(focused.cells[.mtime] ?? "")
        }
        statusLabel.stringValue = parts.filter { !$0.isEmpty }.joined(separator: "    ")
    }

    // MARK: - Errors

    func showError(_ error: Error) {
        let message = (error as NSError).localizedDescription
        showError(message: message)
    }

    func showError(message: String) {
        let alert = NSAlert()
        alert.messageText = "7-Zip"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: Lang.text(401, "OK"))
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// MessageBox_Error_UnsupportOperation (01 §2.8): lang 6008.
    func showUnsupportedOperation() {
        showError(message: Lang.text(6008, "The operation is not supported."))
    }

    /// CheckBeforeUpdate (PanelMenu.cpp:882): a read-only folder in the chain refuses the update.
    func checkBeforeUpdate() -> Bool {
        guard let snap = snapshot else { return false }
        if !snap.supportsOperations { showUnsupportedOperation(); return false }
        if snap.chainIsReadOnly { showUnsupportedOperation(); return false }
        return true
    }

    // MARK: - Icons

    func icon(for row: PanelRow) -> NSImage {
        PanelIcons.icon(for: row, snapshot: snapshot, cache: &fsIconCache, large: false)
    }

    func largeIcon(for row: PanelRow) -> NSImage {
        PanelIcons.icon(for: row, snapshot: snapshot, cache: &fsIconCache, large: true)
    }

    // MARK: - Address bar

    private func updateAddressBar(_ snap: PanelSnapshot) {
        pathCombo.stringValue = snap.fullPath
        folderIcon.image = PanelIcons.addressBarIcon(for: snap)
    }

    func focusList() {
        view.window?.makeFirstResponder(listViewMode == 3 ? tableView : iconView.collectionView)
    }

    func focusPathBar() {   // Alt+F1 / Alt+F2 (App.cpp SetFocusToPath)
        view.window?.makeFirstResponder(pathCombo)
    }

    // MARK: - Actions

    @objc private func upButtonClicked(_ sender: Any?) { goUp() }

    @objc func doubleClicked(_ sender: Any?) {
        if tableView.clickedRow >= 0 {
            focusedIndex = tableView.clickedRow
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            activateFocusedItem(modifiers: flags)
        }
    }

    @objc private func singleClicked(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0 else { return }
        focusedIndex = row
        if Settings.singleClick {                            // LVS_EX_ONECLICKACTIVATE (01 §3.7)
            activateFocusedItem(modifiers: NSApp.currentEvent?.modifierFlags ?? [])
        }
        refreshStatusBar()
    }

    /// OnNotifyActivateItems (PanelListNotify.cpp:538-547).
    func activateFocusedItem(modifiers: NSEvent.ModifierFlags) {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
        if mods == .option {
            showProperties()
            return
        }
        let tryInternal = !mods.contains(.shift) || mods.contains(.option) || mods.contains(.command)
        openSelectedItems(tryInternal: tryInternal)
    }

    @objc private func pathComboAction(_ sender: Any?) {
        let text = pathCombo.stringValue.trimmingCharacters(in: .whitespaces)
        navigate(to: text, fallbackToRoot: false, focusListOnSuccess: true)
    }

    // MARK: - Navigation history (per panel; macOS addition)

    private func noteFolderVisited(_ path: String, previous: String?) {
        Settings.addToFolderHistory(path)                    // CFolderHistory (01 §3.5)
        if !pathCombo.objectValues.contains(where: { ($0 as? String) == path }) {
            pathCombo.insertItem(withObjectValue: path, at: 0)
            while pathCombo.numberOfItems > 100 { pathCombo.removeItem(at: pathCombo.numberOfItems - 1) }
        }
        guard !suppressHistory, let previous, previous != path else { return }
        backStack.append(previous)
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    func goBack() {
        guard let path = backStack.popLast() else { return }
        let current = currentPath
        suppressHistory = true
        navigate(to: path, fallbackToRoot: false) { [weak self] ok in
            self?.suppressHistory = false
            if ok { self?.forwardStack.append(current) } else { self?.backStack.append(path) }
        }
    }

    func goForward() {
        guard let path = forwardStack.popLast() else { return }
        let current = currentPath
        suppressHistory = true
        navigate(to: path, fallbackToRoot: false) { [weak self] ok in
            self?.suppressHistory = false
            if ok { self?.backStack.append(current) } else { self?.forwardStack.append(path) }
        }
    }

    func setPendingFocus(name: String?, selectionMask: String? = nil) {
        pendingFocusName = name
        pendingSelectionMask = selectionMask
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
