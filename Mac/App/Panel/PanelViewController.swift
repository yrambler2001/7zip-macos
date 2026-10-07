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
    /// The window a panel belongs to, whether or not its view is currently installed in it. A panel
    /// closed with F9 is kept alive and reused, so `view.window` is nil while it still has an owner;
    /// this is the window its sheets go on (`ErrorAlert`, fastui section 6.10).
    var panelHostWindow: NSWindow? { get }
}

final class PanelViewController: NSViewController, NSMenuItemValidation {

    let panelIndex: Int
    weak var delegate: PanelDelegate?

    // MARK: engine side (panel queue only)
    let queue: DispatchQueue
    /// Only ever assigned and used on `queue` (the engine's COM refcounts are not atomic).
    var folder: SZFolder? {
        didSet { archiveLevel.set(folder?.archive) }
    }
    /// The innermost archive level of `folder`, readable from any thread (PanelArchiveOpen.swift).
    let archiveLevel = PanelArchiveLevel()
    /// CFolderLink::Password of the innermost archive level (`_parentFolders.Back()`): every level
    /// keeps its own (`SZArchive.password`), so leaving a level forgets its password and an
    /// unrelated archive never inherits one (01 §8.7, 01b §4.16). Setting it outside an archive
    /// does nothing.
    var rememberedPassword: String? {
        get { archiveLevel.current?.password }
        set { archiveLevel.current?.password = newValue }
    }
    /// Set while an operation owns the folder on another thread (CDisableTimerProcessing).
    private(set) var isOperating = false
    /// > 0 while this panel's queue is blocked waiting for a block it put on the main thread (the
    /// archive open's progress, a nested write-back): the queue cannot run a park block then, and
    /// does not need to, because it is not touching the folder. `parkPanels(showing:)` skips it.
    /// Main thread only.
    var queueHeldForMain = 0
    /// Set once the nested archives of the chain were closed for good (window close / quit), so
    /// the write-back question is asked only once (PanelNestedArchives.swift).
    var nestedArchivesClosedForShutdown = false

    // MARK: main-thread state
    private(set) var snapshot: PanelSnapshot?
    var rows: [PanelRow] = []
    var columnsModel = PanelColumnsModel(properties: [], folderType: "", isFileSystem: false,
                                                      hiddenByDefault: [], layout: nil)
    private var folderTypeOfColumns = ""
    /// The time columns' default width the columns were built with (datecols): View > Time changes it.
    private var timeWidthOfColumns = 0
    private(set) var listViewMode = 3                       // _listViewMode, 3 = details
    private(set) var flatModeForDisk = false                // _flatModeForDisk
    private(set) var flatModeForArc = false                 // _flatModeForArc
    var isActive = false { didSet { updateActiveHighlight() } }
    /// AlternativeSelection mode keeps its own vector (_selectedStatusVector, 01 §3.6).
    private var mySelected = Set<Int>()
    private var alternativeSelection = Settings.alternativeSelection
    /// The row with the caret. NSTableView has no separate focus, so the panel tracks it, and
    /// `PanelRowView` draws the focus rectangle of an unselected focused row (winmatch).
    var focusedIndex = -1 {
        didSet {
            guard focusedIndex != oldValue, isViewLoaded else { return }
            refreshSelectionAppearance()
        }
    }
    /// Tests only: pretend the list has (true) or lacks (false) the keyboard focus, which decides
    /// whether the selection is drawn (`listHasKeyboardFocus`, PanelSelectionStyle).
    var listFocusOverride: Bool? { didSet { if isViewLoaded { refreshSelectionAppearance() } } }
    /// Shift key-down anchor (_prevFocusedItem, 01 §3.7).
    var selectionAnchor = -1
    /// True while `setSelectedIndexes` changes the selection (the focus is not moved then).
    var isSettingSelection = false
    /// Per-panel navigation stack (macOS addition; 7zFM has no Back/Forward, 01 §9).
    private var backStack: [String] = []
    private var forwardStack: [String] = []
    private var suppressHistory = false
    private var fsIconCache: [String: NSImage] = [:]
    /// Row whose name cell is being edited in place (OnBeginLabelEdit / OnEndLabelEdit).
    var renamingRow: Int?
    private var isApplyingSettings = false
    /// Sort parameters the panel queue may read while the main thread changes them (01 §3.3).
    let sortState = PanelSortState()
    /// Incremented by every apply(): a queued sort whose generation is stale is dropped.
    private(set) var loadGeneration = 0
    private var needsQueueResort = false
    /// Tag chosen in the Control-drag menu (NDragMenu) and the files a dropped
    /// "Add to archive..." applies to, read by the `compress` scope through this scope's API.
    var dragMenuTag = -1
    var pendingCompressTarget: PanelContextTarget?
    private var pendingFocusName: String?
    private var pendingSelectionMask: String?
    /// A reload asked for while this panel was closed (F9), replayed by `panelDidBecomeVisible()`.
    /// 7zFM does not poll or redraw a hidden panel either -- `CPanel::OnTimer` belongs to the panel
    /// that is on screen -- and a panel with no window has nowhere to put a message box.
    private var needsReloadWhenShown = false

    var sortPropID: SZPropID { columnsModel.sortID }
    var ascending: Bool { columnsModel.ascending }
    var flatMode: Bool { (snapshot?.isArchive ?? false) ? flatModeForArc : flatModeForDisk }
    var timestampLevel: SZTimestampLevel { SZTimestampLevel(rawValue: Settings.timestampLevel) ?? .min }

    /// Address-bar path of the current folder ("" for the root).
    var currentPath: String { snapshot?.fullPath ?? "" }
    /// Path saved as PanelPath<N> (SavePanelPath): the file-system folder, or the directory of the
    /// outermost archive when browsing inside one.
    var pathToPersist: String { snapshot?.fileSystemPath ?? "" }

    /// Where the last Properties command went (PanelFinderInfo.swift); read by tests.
    var lastPropertiesRoute: FinderInfo.Route?
    /// ComboBoxPaths: the path each address drop-down entry binds (PanelAddressDropdown.swift).
    var addressDropdownPaths: [String] = []
    /// The entries behind `addressDropdownPaths` (names, levels, icon kinds) for AddressPopup.
    var addressDropdownEntries: [AddressDropdown.Entry] = []

    // MARK: views
    let pathBar = PathBarView()
    private let upButton = PanelUpButton()
    let pathCombo = AddressComboBox()
    /// The list's themed WS_EX_CLIENTEDGE (recheck §2): a 1 px line, 1 px of white, then the list.
    private let listFrame = PanelListFrameView()
    private let listContainer = NSView()
    private let scrollView = WinScrollView()
    let tableView = PanelTableView()
    private(set) var iconView: PanelIconView!
    /// Section 0 of the status bar ("N / M object(s) selected"); sections 1-3 follow it.
    private let statusLabel = NSTextField(labelWithString: "")
    /// Sections 1-3: selected size, focused item size, focused item time (Refresh_StatusBar).
    let statusSections = [NSTextField(labelWithString: ""), NSTextField(labelWithString: ""),
                          NSTextField(labelWithString: "")]
    /// The right edges of sections 0-2 (Panel.cpp CreateStatusBar: `{220, 320, 420, -1}`), in points,
    /// the two size parts widened for SF Pro's "9 999 999 999 999" (datecols, PanelMetrics).
    static var statusSectionEdges: [CGFloat] { PanelMetrics.statusSectionEdges }
    /// The dividers in front of sections 1-3.
    private var statusDividers: [NSView] = []
    /// The first part's text from the status bar's left edge; moved in at the window's rounded
    /// corner (PanelMetrics.statusLeadingInset, fix111).
    private var statusLabelLeading: NSLayoutConstraint?

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

        upButton.setAccessibilityLabel(Lang.text(735, "Up One Level"))
        upButton.toolTip = Lang.text(735, "Up One Level")   // kParentFolderID button
        upButton.target = self
        upButton.action = #selector(upButtonClicked(_:))
        upButton.translatesAutoresizingMaskIntoConstraints = false

        pathCombo.isEditable = true
        pathCombo.completes = true
        pathCombo.usesDataSource = false
        pathCombo.numberOfVisibleItems = 16
        pathCombo.target = self
        pathCombo.action = #selector(pathComboAction(_:))
        pathCombo.delegate = self
        pathCombo.onDropDown = { [weak self] in self?.showAddressPopup() }
        pathCombo.font = PanelMetrics.listFont          // the GUI font, as the list (recheck §2)
        pathCombo.isBordered = false
        pathCombo.translatesAutoresizingMaskIntoConstraints = false
        // The address bar's ComboBoxEx draws no focus ring on Windows; the caret and the selected
        // text are the only focus cue (listfeel.md §9). The keyboard focus itself is unchanged.
        pathCombo.focusRingType = .none

        // The band (PanelAddressBar.swift): the Up button @2,1 23 x 22, the combo from x 33, 24 px.
        pathBar.translatesAutoresizingMaskIntoConstraints = false
        pathBar.addSubview(upButton)
        pathBar.addSubview(pathCombo)

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
        tableView.gridColor = PanelSelectionStyle.grid               // LVS_EX_GRIDLINES (240,240,240)
        // 7zFM 26.03's list: 19 px rows with no gap, the cells draw their own margins, a 24 px
        // header (PanelMetrics, listfeel.md §2).
        tableView.rowHeight = PanelMetrics.rowHeight
        tableView.intercellSpacing = .zero
        tableView.style = .plain
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked(_:))
        tableView.action = #selector(singleClicked(_:))
        tableView.headerView = PanelTableHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: PanelMetrics.headerHeight))
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

        // status bar (each panel owns one, 01 §1.2), as msctls_statusbar32 draws it on Windows 11
        // (recheck §2): 23 px with a 1 px (215) line on top, COLOR_BTNFACE, the GUI font in black,
        // a part's text 2 px in, 1 px (215) dividers at a part's right edge - 1 on rows 2..21.
        statusLabel.font = PanelMetrics.listFont
        statusLabel.textColor = WinChrome.text
        statusLabel.lineBreakMode = .byTruncatingMiddle
        Bidi.makeLeftToRight(statusLabel)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        let status = NSView()
        status.translatesAutoresizingMaskIntoConstraints = false
        status.clipsToBounds = true          // a narrow panel cuts the sections, as a Win32 status bar does
        status.addSubview(statusLabel)
        // 01 §1.2 "Status bar": four parts with fixed right edges, a divider after each of the
        // first three; the last one takes the rest.
        let textBaseline: CGFloat = 16       // ink rows 7..15 under the line: baseline 16 px down
        var statusConstraints: [NSLayoutConstraint] = []
        for (i, label) in statusSections.enumerated() {
            label.font = statusLabel.font
            label.textColor = WinChrome.text
            label.lineBreakMode = .byTruncatingTail
            Bidi.makeLeftToRight(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            status.addSubview(label)
            let left = Self.statusSectionEdges[i]
            statusConstraints.append(label.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: left + 1))
            statusConstraints.append(label.firstBaselineAnchor.constraint(equalTo: status.topAnchor, constant: textBaseline))
            if i + 1 < statusSections.count {
                statusConstraints.append(label.widthAnchor.constraint(lessThanOrEqualToConstant:
                    Self.statusSectionEdges[i + 1] - left - 2))
            } else {
                statusConstraints.append(label.trailingAnchor.constraint(lessThanOrEqualTo: status.trailingAnchor, constant: -2))
            }
            let divider = PanelColorView(WinChrome.statusLine)
            status.addSubview(divider)
            statusDividers.append(divider)
            statusConstraints += [
                divider.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: left - 1),
                divider.widthAnchor.constraint(equalToConstant: 1),
                divider.topAnchor.constraint(equalTo: status.topAnchor, constant: 1),
                divider.heightAnchor.constraint(equalToConstant: 20),
            ]
        }

        let statusLine = PanelColorView(WinChrome.statusLine)
        listFrame.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(pathBar)
        root.addSubview(listFrame)
        root.addSubview(listContainer)
        root.addSubview(statusLine)
        root.addSubview(status)

        let inset = PanelListFrameView.inset
        NSLayoutConstraint.activate([
            pathBar.topAnchor.constraint(equalTo: root.topAnchor),
            pathBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pathBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pathBar.heightAnchor.constraint(equalToConstant: WinChrome.bandHeight),
            upButton.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor, constant: WinChrome.upButtonRect.minX),
            upButton.topAnchor.constraint(equalTo: pathBar.topAnchor, constant: WinChrome.upButtonRect.minY),
            upButton.widthAnchor.constraint(equalToConstant: WinChrome.upButtonRect.width),
            upButton.heightAnchor.constraint(equalToConstant: WinChrome.upButtonRect.height),
            pathCombo.leadingAnchor.constraint(equalTo: pathBar.leadingAnchor, constant: WinChrome.comboX),
            pathCombo.trailingAnchor.constraint(equalTo: pathBar.trailingAnchor),
            pathCombo.topAnchor.constraint(equalTo: pathBar.topAnchor),
            pathCombo.heightAnchor.constraint(equalToConstant: WinChrome.bandHeight),
            listFrame.topAnchor.constraint(equalTo: pathBar.bottomAnchor),
            listFrame.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listFrame.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listFrame.bottomAnchor.constraint(equalTo: statusLine.topAnchor),
            listContainer.topAnchor.constraint(equalTo: listFrame.topAnchor, constant: inset),
            listContainer.leadingAnchor.constraint(equalTo: listFrame.leadingAnchor, constant: inset),
            listContainer.trailingAnchor.constraint(equalTo: listFrame.trailingAnchor, constant: -inset),
            listContainer.bottomAnchor.constraint(equalTo: listFrame.bottomAnchor, constant: -inset),
            scrollView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            iconView.topAnchor.constraint(equalTo: listContainer.topAnchor),
            iconView.bottomAnchor.constraint(equalTo: listContainer.bottomAnchor),
            iconView.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor),
            iconView.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor),
            statusLine.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusLine.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusLine.heightAnchor.constraint(equalToConstant: 1),
            status.topAnchor.constraint(equalTo: statusLine.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.heightAnchor.constraint(equalToConstant: WinChrome.statusHeight - 1),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: Self.statusSectionEdges[0] - 2),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: status.trailingAnchor, constant: -2),
            statusLabel.firstBaselineAnchor.constraint(equalTo: status.topAnchor, constant: textBaseline),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 120),   // kPanelSizeMin
        ])
        let leading = statusLabel.leadingAnchor.constraint(equalTo: status.leadingAnchor,
                                                           constant: PanelMetrics.statusTextOrigin)
        statusLabelLeading = leading
        statusConstraints.append(leading)
        NSLayoutConstraint.activate(statusConstraints)
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
        center.addObserver(self, selector: #selector(languageDidChange(_:)),
                           name: Settings.Group.language.notificationName, object: nil)
    }

    /// ReloadLangItems (01 §1.1, 01b §4.22): the column titles and the status-bar template come
    /// from the lang file, so a language switch re-creates the columns and reloads.
    @objc private func languageDidChange(_ note: Notification) {
        upButton.toolTip = Lang.text(735, "Up One Level")
        folderTypeOfColumns = ""
        reload(keepScroll: true)
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
        let grid: NSTableView.GridLineStyle = Settings.showGrid ? [.solidHorizontalGridLineMask, .solidVerticalGridLineMask] : []
        if tableView.gridStyleMask != grid {
            tableView.gridStyleMask = grid
            // theme: each NSTableRowView keeps the grid style it was handed when the table added
            // it, and draws its lines from that copy; the rows on screen kept their old lines (or
            // none) until they were scrolled away. Re-creating them hands every row the new style.
            tableView.reloadData()
        }
        let alternative = Settings.alternativeSelection
        if alternative != alternativeSelection {
            alternativeSelection = alternative
            tableView.allowsMultipleSelection = !alternative
            mySelected.removeAll()
        }
        tableView.needsDisplay = true
        refreshSelectionAppearance()                        // FullRow: which cells are highlighted
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
        cancelRenameEditing()                               // recheck2: no edit outlives the change
        guard let folder else { return nil }
        // The park block only *enqueues* behind whatever the panel queue is already running, so
        // the worker waits until it is actually parked before it touches the folder.
        let parked = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        queue.async {                                       // CDisableTimerProcessing equivalent
            parked.signal()
            release.wait()
        }
        isOperating = true
        var opts = options
        if opts.parentWindow == nil { opts.parentWindow = view.window }
        let result = OperationRunner.run(opts) { runner in
            parked.wait()
            return try work(folder, runner)
        }
        isOperating = false
        release.signal()
        return result
    }

    // MARK: - Parking for the command scopes

    static let parkTimeout: TimeInterval = 2

    /// What `parkPanels(showing:)` hands back: the worker waits for the park, the main thread
    /// releases it once `OperationRunner.run` has returned.
    final class FolderParking {
        fileprivate let panels: [PanelViewController]
        private let parked = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)

        fileprivate init(panels: [PanelViewController]) {
            self.panels = panels
            for panel in panels {
                panel.isOperating = true                    // CDisableTimerProcessing
                panel.queue.async { [parked, released] in
                    parked.signal()
                    released.wait()
                }
            }
        }

        /// Worker side: returns once every affected panel queue is idle in its park block. A queue
        /// that does not get there within `parkTimeout` is busy with a block that is itself waiting
        /// for the main thread (which the operation's own modal session is holding), so the
        /// operation goes ahead rather than deadlock; its park block still runs, and returns at
        /// once, when the queue gets to it.
        func waitUntilParked() {
            let deadline = DispatchTime.now() + PanelViewController.parkTimeout
            for _ in panels where parked.wait(timeout: deadline) == .timedOut {
                NSLog("7-Zip: a panel queue did not park within %.1f s", PanelViewController.parkTimeout)
                return
            }
        }

        /// Main side, after the operation.
        func release() {
            for panel in panels { panel.isOperating = false }
            for _ in panels { released.signal() }
        }
    }

    /// The `runFolderOperation` ownership rule for a command scope that got its folder from
    /// `ActiveContext` (extract, compress, temp-open): every panel whose archive chain contains the
    /// folder's archive is parked, so no refresh, sort or navigation block of that panel touches a
    /// folder of the same archive while the operation's worker does (opsinfra api §1; the
    /// engine's COM reference counts are not atomic). A file-system folder needs nothing: it is
    /// not shared with the panel's own objects. Main thread only.
    static func parkPanels(showing folder: SZFolder) -> FolderParking {
        guard let archive = folder.archive else { return FolderParking(panels: []) }
        let panels = NSApp.windows
            .compactMap { $0.windowController as? MainWindowController }
            .flatMap { $0.panels }
            .filter { $0.queueHeldForMain == 0 }
            .filter { panel in
                var level = panel.archiveLevel.current
                var seen = 0
                while let current = level, seen < 64 {
                    if current === archive { return true }
                    level = current.outerFolder?.archive
                    seen += 1
                }
                return false
            }
        return FolderParking(panels: panels)
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
                                 cells: cells, sortKeys: keys,
                                 // OnRefreshStatusBar's date: level SEC, not the list's (datecols)
                                 statusTime: (level == .sec ? cells[.mtime] : nil)
                                     ?? folder.displayStringOfItem(at: i, propID: .mtime, timestampLevel: .sec)))
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
        // Sorting happens here, on the queue, so IFolderCompare (which archive folders implement)
        // can be used; the main thread only re-sorts when its parameters changed meanwhile.
        let params = sortState.value
        let supportsCompare = folder.supportsCompare
        let compare: ((Int, Int, SZPropID) -> Int)? = supportsCompare
            ? { i, j, pid in folder.compareItem(at: i, with: j, propID: pid) }
            : nil
        rows = PanelSorting.sorted(rows: rows, sortID: params.sortID, ascending: params.ascending,
                                   flatMode: params.flatMode, folderCompare: compare)
        let isHash = (folder.folderProperty(forID: .isHash) as? NSNumber)?.boolValue ?? false
        let hidden: Set<UInt32> = isFS
            ? Set(SZFileSystemFolder.defaultHiddenPropIDs.map { $0.uint32Value })
            : []
        var snapshot = PanelSnapshot(fullPath: folder.fullPath,
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
                             hiddenByDefault: hidden,
                             supportsCompare: supportsCompare,
                             sortParams: params)
        snapshot.isCaseSensitive = isFS && SZFolder.volumeIsCaseSensitive(atPath: folder.fullPath)
        return snapshot
    }

    // MARK: - Applying a snapshot (RefreshListCtrl, PanelItems.cpp:467-960)

    func apply(_ snap: PanelSnapshot, select name: String? = nil) {
        apply(snap, selectNames: name.map { [$0] } ?? [], focusName: name)
    }

    func apply(_ snap: PanelSnapshot, selectNames: [String], focusName: String? = nil, keepScroll: Bool = false) {
        let previousPath = snapshot?.fullPath
        loadGeneration += 1
        let scroll = scrollView.contentView.bounds.origin
        snapshot = snap
        rows = snap.rows
        fsIconCache.removeAll(keepingCapacity: true)
        if snap.folderType != folderTypeOfColumns {
            saveColumnLayout()                              // SaveListViewInfo before rebuilding
            PanelColumnsModel.timeWidth = PanelMetrics.timeColumnWidth   // sffont: the font's date width
            PanelColumnsModel.timeWidthDefaults = PanelMetrics.timeColumnDefaults
            PanelColumnsModel.sizeColumnIDs = Formatting.sizePropIDs
            PanelColumnsModel.sizeWidth = PanelMetrics.sizeColumnWidth
            timeWidthOfColumns = PanelColumnsModel.timeWidth
            columnsModel = PanelColumnsModel(properties: snap.columns, folderType: snap.folderType,
                                             isFileSystem: snap.isFileSystem,
                                             hiddenByDefault: snap.hiddenByDefault,
                                             layout: Settings.columnLayout(forFolderType: snap.folderType))
            folderTypeOfColumns = snap.folderType
            rebuildColumns()
            sortState.set(PanelSortParams(sortID: columnsModel.sortID, ascending: columnsModel.ascending,
                                          flatMode: flatMode))
        } else if columnsModel.columns.count != snap.columns.filter({ $0.propID != .isDir }).count {
            // flat mode adds/removes kpidPrefix (fsfolder api §2)
            columnsModel = PanelColumnsModel(properties: snap.columns, folderType: snap.folderType,
                                             isFileSystem: snap.isFileSystem,
                                             hiddenByDefault: snap.hiddenByDefault,
                                             layout: columnsModel.layout())
            rebuildColumns()
        }
        followTimeColumnDefault()
        if snap.sortParams != currentSortParams() {
            if snap.supportsCompare {
                resortRows()                          // a value-only pass now; the queue re-sorts below
                needsQueueResort = true
            } else {
                resortRows()
            }
        }
        var names = selectNames
        if let mask = pendingSelectionMask {                 // wildcard in the bound path (01 §3.8)
            pendingSelectionMask = nil
            let caseSensitive = snap.isCaseSensitive
            names = rows.filter { !$0.isParentRow && PanelMask.matches(mask: mask, name: $0.name, caseSensitive: caseSensitive) }
                .map { $0.name }
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
        if needsQueueResort {
            needsQueueResort = false
            sort(by: columnsModel.sortID, toggle: false)   // re-sort with IFolderCompare
        }
    }

    /// Reloads whichever view mode is on screen.
    func reloadList() {
        tableView.reloadData()
        iconView.reloadData()
    }

    /// View > Time (IDM_VIEW_TIME 761 + k, IDM_VIEW_TIME_UTC 799) changed how long a date is: a
    /// time column still at the previous default width takes the new one, so the dates stay whole;
    /// a width the user chose is kept (datecols).
    private func followTimeColumnDefault() {
        guard timeWidthOfColumns != 0 else { return }
        let width = PanelMetrics.timeColumnWidth
        guard width != timeWidthOfColumns else { return }
        let old = timeWidthOfColumns
        timeWidthOfColumns = width
        PanelColumnsModel.timeWidth = width
        var changed = false
        for column in tableView.tableColumns {
            guard let pid = Self.propID(of: column),
                  columnsModel.columns.first(where: { $0.propID == pid })?.varType == .fileTime,
                  Int(column.width.rounded()) == old else { continue }
            column.width = CGFloat(width)
            changed = true
        }
        if changed { saveColumnLayout() }
    }

    private func rebuildColumns() {
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for info in columnsModel.visibleColumns { tableView.addTableColumn(Self.makeTableColumn(info)) }
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

    func currentSortParams() -> PanelSortParams {
        PanelSortParams(sortID: columnsModel.sortID, ascending: columnsModel.ascending, flatMode: flatMode)
    }

    /// Main-thread sort (no IFolderCompare -- only the value comparison).
    func resortRows() {
        rows = PanelSorting.sorted(rows: rows, sortID: columnsModel.sortID, ascending: columnsModel.ascending,
                                   flatMode: flatMode, folderCompare: nil)
    }

    /// SortItemsWithPropID (PanelSort.cpp:256-279). A folder that implements IFolderCompare is
    /// asked on the panel queue; everything else is ordered from the snapshot's values.
    func sort(by propID: SZPropID, toggle: Bool = true) {
        let names = selectedNames()
        let focus = focusedRow()?.name
        if toggle { columnsModel.sort(by: propID) }
        let params = currentSortParams()
        sortState.set(params)
        updateSortIndicator()
        Settings.setColumnLayout(columnsModel.layout(), forFolderType: folderTypeOfColumns)
        if snapshot?.supportsCompare == true {
            let unsorted = rows                       // a value copy: the queue never sees `rows`
            let generation = loadGeneration
            runOnQueue { [self] in
                guard let folder = self.folder, folder.itemCount >= unsorted.count else { return }
                let sorted = PanelSorting.sorted(rows: unsorted, sortID: params.sortID,
                                                 ascending: params.ascending, flatMode: params.flatMode) { i, j, pid in
                    folder.compareItem(at: i, with: j, propID: pid)
                }
                DispatchQueue.main.async {
                    guard generation == self.loadGeneration else { return }   // the folder moved on
                    self.rows = sorted
                    self.reloadList()
                    self.restoreSelection(names: names, focusName: focus)
                }
            }
            return
        }
        resortRows()
        reloadList()
        restoreSelection(names: names, focusName: focus)
    }

    /// 7zFM draws no sort arrow and no highlighted column in the header: CPanel never sets
    /// HDF_SORTUP / HDF_SORTDOWN (no use anywhere in CPP/7zip/UI/FileManager; the fresh-default
    /// capture shows a plain "Name" header). The port used to show the AppKit triangle.
    private func updateSortIndicator() {
        for column in tableView.tableColumns { tableView.setIndicatorImage(nil, in: column) }
        tableView.highlightedTableColumn = nil
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
        defer { sortState.set(PanelSortParams(sortID: columnsModel.sortID, ascending: columnsModel.ascending, flatMode: flat)) }
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

    // MARK: - Test support: rebuild this panel in place (ai/api/resetcmd.md)

    /// Step 4 of `sevenzip://test/reset`, for one panel. Selection, sort order, view mode and flat
    /// mode go back to their defaults, the navigation stacks and the remembered password are
    /// dropped, and the panel binds to `path` again.
    ///
    /// **The folder chain is released on the panel's own queue.** `SZFolder` wraps engine COM
    /// objects whose reference counts are plain `++`/`--` (`Z7_COM_USE_ATOMIC` is not defined, see
    /// `ai/api/opsinfra.md` section 4), so the object must be deallocated by the one thread
    /// that owns it. `folder = nil` therefore goes through `runOnQueue`, and the `navigate` below
    /// enqueues behind it on the same serial queue, so the old chain is gone before the new one is
    /// built. A reset always waits for `OperationRunner.hasActiveOperation` to go false first, so
    /// no worker can still be holding the folder when this runs.
    func resetForTest(to path: String, viewMode: Int?, completion: @escaping (Bool) -> Void) {
        killSelection()
        rememberedPassword = nil
        pendingCompressTarget = nil
        dragMenuTag = -1
        renamingRow = nil
        selectionAnchor = -1
        focusedIndex = -1
        setPendingFocus(name: nil)
        backStack.removeAll()
        forwardStack.removeAll()
        flatModeForDisk = false                           // _flatModeForDisk is not persisted
        flatModeForArc = Settings.flatView(panelIndex)     // FlatViewArc<N> (01 section 3.4)
        let mode = max(0, min(3, viewMode ?? Settings.listMode(panelIndex)))
        listViewMode = mode
        Settings.setListMode(mode, panelIndex)
        applyListViewMode()
        // Forget the cached column model so the next apply() rebuilds it -- and with it the sort
        // order -- from the settings domain as it now stands (`FM.Columns.<FolderTypeID>`).
        folderTypeOfColumns = ""
        needsReloadWhenShown = false                       // the navigate below supersedes it
        runOnQueue { [self] in self.folder = nil }
        // `reportErrors: false`: a reset must not leave a sheet up. Its own step 1 has just closed
        // every dialog, so an error raised by step 4 would survive the reset and greet the next test
        // instead (`ai/api/resetcmd.md` section 4). The failure is logged and the panel falls
        // back to the root, which is what a reset to a vanished path should do.
        navigate(to: path, fallbackToRoot: true, reportErrors: false, completion: completion)
    }

    // MARK: - Visibility (SwitchOnOffOnePanel keeps the closed panel alive)

    /// True while this panel's view is installed in a window. False for a panel closed with F9,
    /// which stays in `MainWindowController.panels` so it can be reopened with its state (7zFM hides
    /// the non-focused panel; it does not destroy the `CPanel`).
    var isPanelVisible: Bool { isViewLoaded && view.window != nil }

    /// The window this panel's sheets belong to: its own window while it is on screen, and otherwise
    /// the window that owns it. Never nil just because the panel is closed -- that mistake is what
    /// `ErrorAlert` exists to prevent (`ai/reports/fastui.md` section 6.10).
    var hostWindow: NSWindow? { (isViewLoaded ? view.window : nil) ?? delegate?.panelHostWindow }

    /// Called by `MainWindowController` when this panel's view goes back into the split view. A
    /// reload that was deferred while the panel was closed runs now, when there is a window to draw
    /// it in and a window to put an error on.
    func panelDidBecomeVisible() {
        guard needsReloadWhenShown else { return }
        needsReloadWhenShown = false
        reload(keepScroll: true)
    }

    // MARK: - Reload

    /// OnReload / RefreshListCtrl_SaveFocused: reload items, keep focus and selection by name.
    ///
    /// A closed panel defers instead: the listing it would build cannot be seen, the engine call is
    /// wasted, and -- the reason this guard exists -- a failed reload of a folder that has since been
    /// deleted used to report the error with nowhere to put it. Every route that reloads *every*
    /// panel rather than the visible ones (the View menu's timestamp items, an Options apply, a
    /// language switch, `ActiveContext.refreshAll()`) goes through here.
    func reload(keepScroll: Bool = false) {
        guard isPanelVisible else { needsReloadWhenShown = true; return }
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
    ///
    /// `MainWindowController` only ticks `visiblePanels`, and the guard says so here as well so the
    /// rule holds for any caller: a closed panel is not polled, exactly as 7zFM's per-panel timer is
    /// not.
    func refreshIfChanged() {
        guard isPanelVisible, !isOperating else { return }
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
            refreshMySelectionHighlight()
            iconView.reloadData()
        } else {
            // A selection command (Select All, Invert, a mask) leaves the focus where it is, as
            // the list control does (Num * on 7zFM keeps the focused item, recheck §3).
            isSettingSelection = true
            tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            iconView.setSelectionIndexes(indexes)
            isSettingSelection = false
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

    /// The rows the list control itself has selected: in AlternativeSelection mode that is the
    /// cursor row, not the marked items (`_listView.IsItemSelected`).
    var listSelectedIndexes: IndexSet {
        listViewMode == 3 ? tableView.selectedRowIndexes : iconView.selectionIndexes
    }

    /// Get_ItemIndices_Operated: the list indices the commands work on.
    func operatedRowIndices() -> [Int] {
        PanelOperatedItems.operated(rows: rows, selected: selectedIndexes, focused: focusedIndex,
                                    focusedIsListSelected: listSelectedIndexes.contains(focusedIndex))
    }

    /// Get_ItemIndices_OperSmart: nothing operated means the whole folder (App.cpp OnCopy).
    func operatedSmartRowIndices() -> [Int] {
        PanelOperatedItems.operatedSmart(rows: rows, selected: selectedIndexes, focused: focusedIndex,
                                         focusedIsListSelected: listSelectedIndexes.contains(focusedIndex))
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
        } else if let firstItem = rows.firstIndex(where: { !$0.isParentRow }) {
            focus = firstItem                       // the ".." row is never the default focus
        } else if !rows.isEmpty {
            focus = 0
        }
        focusedIndex = focus
        // RefreshListCtrl (PanelItems.cpp:900-930) selects only the items it was asked to keep;
        // with none, the focused item is *not* selected -- a folder just opened says
        // "0 / N object(s) selected" (winmatch). AlternativeSelection's cursor is list-selected.
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
        refreshMySelectionHighlight()
        iconView.reloadData()
        refreshStatusBar()
    }

    /// Row views keep their own copy of the flag, so they are updated in place (01 §3.6).
    private func refreshMySelectionHighlight() {
        tableView.enumerateAvailableRowViews { view, row in
            guard let rowView = view as? PanelRowView else { return }
            rowView.isMySelected = mySelected.contains(row)
            rowView.needsDisplay = true
        }
    }

    // MARK: - Status bar (Refresh_StatusBar, PanelListNotify.cpp:759-820)

    func refreshStatusBar() {
        let total = rows.reduce(0) { $1.isParentRow ? $0 : $0 + 1 }
        let operated = operatedRowIndices().map { rows[$0] }
        let template = Lang.get(3002, "{0} object(s) selected")   // IDS_N_SELECTED_ITEMS
        // Part 0: "N / M object(s) selected"; part 1: the operated items' size.
        statusLabel.stringValue = Bidi.isolate(Lang.format(template, "\(operated.count) / \(total)"))
        statusSections[0].stringValue = operated.isEmpty
            ? "" : Formatting.size(operated.reduce(UInt64(0)) { $0 &+ $1.size })
        // Parts 2 and 3 only when something is selected and the focused row is not "..".
        if !selectedIndexes.isEmpty, let focused = focusedRow(), !focused.isParentRow {
            statusSections[1].stringValue = Formatting.size(focused.size)
            statusSections[2].stringValue = focused.statusTime          // PanelListNotify.cpp:812
        } else {
            statusSections[1].stringValue = ""
            statusSections[2].stringValue = ""
        }
    }

    /// A section that starts beyond a narrow panel's edge is not there at all (a Win32 status bar
    /// part past the window edge is not drawn), rather than a view hanging outside the window.
    override func viewDidLayout() {
        super.viewDidLayout()
        let width = view.bounds.width
        for (i, edge) in Self.statusSectionEdges.enumerated() {
            let hidden = edge + 12 > width
            if statusSections[i].isHidden != hidden { statusSections[i].isHidden = hidden }
            if statusDividers[i].isHidden != hidden { statusDividers[i].isHidden = hidden }
        }
        updateStatusLeadingInset()
    }

    /// The first part's text keeps Windows' place (ink 2 px into the part), moved in by as much as
    /// the window's rounded bottom-left corner reaches over it when this panel's status bar starts
    /// at the window's left edge (fix111): Windows 11 draws the client area inside a 1 px border
    /// with an 8 px corner, so its text clears the frame; a macOS window has no border and a 10 pt
    /// (16 pt on macOS 26) corner, which cut into the first digit.
    func updateStatusLeadingInset() {
        guard let leading = statusLabelLeading else { return }
        var atCorner = false
        if let window = view.window, !window.styleMask.contains(.fullScreen) {
            atCorner = abs(view.convert(NSPoint.zero, to: nil).x) < 0.5     // the parts run left to right
        }
        let constant = PanelMetrics.statusTextOrigin + (atCorner ? PanelMetrics.statusCornerInset : 0)
        if leading.constant != constant { leading.constant = constant }
    }

    /// The four status-bar parts as shown, for tests and accessibility.
    var statusBarTexts: [String] { [statusLabel.stringValue] + statusSections.map(\.stringValue) }

    // MARK: - Errors

    func showError(_ error: Error) {
        let message = (error as NSError).localizedDescription
        showError(message: message)
    }

    /// A panel's error is a **sheet of the window that owns the panel**, never an app-modal alert.
    ///
    /// It used to branch on `view.window` and fall back to `NSAlert.runModal()`, which wedged the
    /// whole app whenever a closed panel reported an error: see `ErrorAlert` and
    /// `ai/reports/fastui.md` section 6.10. A panel that is out of the split view still belongs
    /// to the main window, which `hostWindow` asks the delegate for, so there is a sheet parent even
    /// then; with no window anywhere the message goes to the log.
    func showError(message: String) {
        ErrorAlert.present(message, on: hostWindow)
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
        // The address-bar icon is a 16 pt slot (the combo's small icon); a symbol or file icon
        // comes at its own size (19 pt for the folder symbol), so a 16 pt copy is shown instead
        // of letting AppKit scale it on every panel (requests.md, `fastui` -> `panel`).
        let sized = PanelIcons.addressBarIcon(for: snap).map { icon -> NSImage in
            let copy = (icon.copy() as? NSImage) ?? icon
            copy.size = NSSize(width: 16, height: 16)
            return copy
        }
        pathCombo.addressCell?.icon = sized
        pathCombo.needsDisplay = true
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
        // Return on an entry chosen in the drop-down with the arrow keys binds that entry's path,
        // not its (indented) name (CBN_SELENDOK).
        let index = pathCombo.indexOfSelectedItem
        if index >= 0, index < addressDropdownPaths.count,
           (pathCombo.itemObjectValue(at: index) as? String) == pathCombo.stringValue {
            commitAddressDropdownEntry(at: index)
            return
        }
        let text = pathCombo.stringValue.trimmingCharacters(in: .whitespaces)
        navigate(to: text, fallbackToRoot: false, focusListOnSuccess: true)
    }

    // MARK: - Navigation history (per panel; macOS addition)

    private func noteFolderVisited(_ path: String, previous: String?) {
        Settings.addToFolderHistory(path)                    // CFolderHistory (01 §3.5)
        // The drop-down holds only what CBN_DROPDOWN builds (the path's components, Documents,
        // Computer, the volumes), never the history: 7zFM keeps that in the Folders History
        // dialog (Alt+F12) and the port did too, besides (listfeel.md §9).
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

/// The address band (ReBarWindow32): white, with the RBS_BANDBORDERS edge after the Up button
/// (recheck §2). 7zFM draws nothing here for the active panel; only the keyboard focus tells.
final class PathBarView: NSView {
    var isActive = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        WinChrome.window.setFill()
        bounds.fill()
        let x = WinChrome.comboX
        WinChrome.bandBorderShadow.setFill()
        NSRect(x: x - 2, y: 0, width: 1, height: bounds.height).fill()
        WinChrome.bandBorderLight.setFill()
        NSRect(x: x - 1, y: 0, width: 1, height: bounds.height).fill()
        WinChrome.bandBottom.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: x - 2, height: 1).fill()
    }
}

/// A plain filled rectangle (status-bar line and dividers).
final class PanelColorView: NSView {
    let color: NSColor
    init(_ color: NSColor) {
        self.color = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}

/// The list's themed client edge: a 1 px (130,135,144) line, then the window colour; the list
/// sits `inset` inside (SysHeader32 @2,78 in a SysListView32 @0,76).
final class PanelListFrameView: NSView {
    static let inset: CGFloat = 2
    override func draw(_ dirtyRect: NSRect) {
        WinChrome.window.setFill()
        bounds.fill()
        WinChrome.listBorder.setFill()
        bounds.frame(withWidth: 1)
    }
}
