// MainWindowController.swift -- the 7zFM main window (FM.cpp WndProc, App.cpp CApp): toolbar
// with the seven buttons, one or two panels in a split view, window/panel persistence.

import Cocoa
import SevenZipKit

final class MainWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSToolbarDelegate,
                                 NSMenuItemValidation, NSUserInterfaceValidations, PanelDelegate {

    private let splitView = NSSplitView()
    /// index 0 always exists; 1 is created on demand (SwitchOnOffOnePanel).
    private(set) var panels: [PanelViewController] = []
    private(set) var numPanels = 1
    private(set) var focusedPanelIndex = 0             // LastFocusedPanel
    private var refreshTimer: Timer?
    private var autoRefresh = Settings.autoRefresh     // AutoRefresh_Mode
    private var toolbarsMask = Settings.toolbarsMask

    /// FM.Panels.splitterPos -- the share of the *usable* width (the split view minus the divider)
    /// that panel 0 gets. This value is authoritative: the divider position is always derived from
    /// it, and it is only ever recomputed from the live subview frames after the user has dragged
    /// the divider. Deriving it during a layout pass is what collapsed the split, because a
    /// subview that has just been inserted still has a zero-width frame (Mac/docs/reports/polish.md).
    private var splitterRatio = 0.5
    private var isApplyingSplitter = false
    /// kPanelSizeMin (App.cpp): neither panel may be narrower than this.
    private static let panelSizeMin: CGFloat = 120

    var focusedPanel: PanelViewController { panels[min(focusedPanelIndex, panels.count - 1)] }

    /// The panels whose view is in the split view (one-panel mode hides the other one).
    var visiblePanels: [PanelViewController] {
        panels.filter { splitView.arrangedSubviews.contains($0.view) }
    }

    // Toolbar identifiers (App.cpp g_ArchiveButtons / g_StandardButtons)
    private static let archiveItems: [NSToolbarItem.Identifier] = [.szAdd, .szExtract, .szTest]
    private static let standardItems: [NSToolbarItem.Identifier] = [.szCopy, .szMove, .szDelete, .szInfo]

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "7-Zip"
        window.minSize = NSSize(width: 360, height: 240)
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        buildContent()
        buildToolbar()
        restoreState()
        ActiveContext.register(self)            // frozen contract: the command scopes read this
        NotificationCenter.default.addObserver(self, selector: #selector(viewSettingsDidChange(_:)),
                                               name: Settings.Group.view.notificationName, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// A change on the Options pages takes effect immediately (SetListSettings, 01b §4.19): the
    /// timestamp level and the auto-refresh flag live in the window, the seven list booleans in
    /// the panels (they observe the same notification themselves).
    @objc private func viewSettingsDidChange(_ note: Notification) {
        let key = note.userInfo?[Settings.keyUserInfoKey] as? String
        if key == nil || key == "FM.AutoRefresh" {
            autoRefresh = Settings.autoRefresh
        }
    }

    // MARK: - Layout (CApp::Create / MoveSubWindows)

    private func buildContent() {
        guard let window else { return }
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self
        splitView.translatesAutoresizingMaskIntoConstraints = false
        let content = MainWindowContentView()
        content.controller = self
        content.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: content.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])
        window.contentView = content
        panels = [makePanel(0)]
        splitView.addArrangedSubview(panels[0].view)
    }

    private func makePanel(_ index: Int) -> PanelViewController {
        let panel = PanelViewController(index: index)
        panel.delegate = self
        panel.view.translatesAutoresizingMaskIntoConstraints = false
        return panel
    }

    private func buildToolbar() {
        let toolbar = NSToolbar(identifier: "7zFMToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        toolbar.displayMode = (toolbarsMask & 1) != 0 ? .iconAndLabel : .iconOnly
        window?.toolbar = toolbar
        window?.toolbarStyle = .expanded
    }

    private var visibleToolbarItems: [NSToolbarItem.Identifier] {
        var ids: [NSToolbarItem.Identifier] = []
        if (toolbarsMask & 8) != 0 { ids += Self.archiveItems }
        if (toolbarsMask & 4) != 0 { ids += Self.standardItems }
        return ids
    }

    // MARK: - Startup / persistence (CWindowInfo, CApp::Save)

    private func restoreState() {
        guard let window else { return }
        if let frame = Settings.windowFrame, !frame.isEmpty {
            window.setFrame(NSRectFromString(frame), display: false)
        } else {
            window.center()
        }
        numPanels = Settings.numPanels
        focusedPanelIndex = min(Settings.currentPanel, numPanels - 1)
        splitterRatio = Settings.splitterPos
        if numPanels == 2 { showSecondPanel() }
        for (i, panel) in panels.enumerated() {
            // 7zFM starts in the root folder when nothing is stored; on macOS the home
            // directory is the natural first view (the root is one "Up" away).
            panel.navigate(to: Settings.panelPath(i) ?? NSHomeDirectory())
        }
        panels[0].isActive = focusedPanelIndex == 0
        if panels.count > 1 { panels[1].isActive = focusedPanelIndex == 1 }
        if Settings.maximized { window.zoom(nil) }
        startRefreshTimer()
    }

    /// Command-line path (FM.cpp:975-1012): panel 0 opens it; a file is opened as an archive.
    func openStartupPath(_ path: String, formatHint: String?) {
        let full = (path as NSString).isAbsolutePath ? path : FileManager.default.currentDirectoryPath + "/" + path
        panels[0].navigate(to: full, formatHint: formatHint)
    }

    func saveState() {
        guard let window else { return }
        Settings.windowFrame = NSStringFromRect(window.frame)
        Settings.maximized = window.isZoomed
        Settings.numPanels = numPanels
        Settings.currentPanel = focusedPanelIndex
        captureSplitterRatio()
        Settings.splitterPos = splitterRatio
        for (i, panel) in panels.enumerated() {
            Settings.setPanelPath(panel.pathToPersist, i)
            Settings.setListMode(panel.listViewMode, i)
            panel.saveColumnLayout()            // SaveListViewInfo (Panel.cpp:598-602)
        }
        Settings.autoRefresh = autoRefresh
        Settings.toolbarsMask = toolbarsMask
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        saveState()
    }

    func windowDidBecomeMain(_ notification: Notification) {
        ActiveContext.register(self)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeFirstResponder(nil)
        // The window only gets its real width here, so put the divider where the stored ratio
        // says once more; `splitterRatio` is unchanged, so this is idempotent.
        applySplitterRatio()
        DispatchQueue.main.async { [self] in
            applySplitterRatio()
            focusedPanel.focusList()
        }
    }

    // MARK: - Divider position (7zFM stores it as a ratio, CApp::Save / MoveSubWindows)

    /// The width the two panels share: everything but the divider.
    private var splitUsableWidth: CGFloat {
        max(splitView.bounds.width - splitView.dividerThickness, 0)
    }

    /// Puts the divider where `splitterRatio` says, never closer than kPanelSizeMin to either
    /// edge. `adjustSubviews()` first, because `setPosition(_:ofDividerAt:)` needs subview frames
    /// that already add up to the split view's width: called with a freshly inserted, zero-width
    /// subview it collapses *both* panels to zero (measured -- see Mac/docs/reports/polish.md).
    ///
    /// Only these two calls. Assigning the arranged subviews' frames by hand as a fallback looks
    /// safe and is not: the panels are constraint-driven, so a raw frame is not propagated to
    /// their own subviews, and the second panel comes up with its address bar, header and status
    /// line laid out for the width it had before -- all crammed into a strip at the top.
    @discardableResult
    private func applySplitterRatio() -> Bool {
        guard !isApplyingSplitter else { return true }       // setPosition can re-enter the layout
        guard numPanels == 2, splitView.arrangedSubviews.count == 2 else { return false }
        let usable = splitUsableWidth
        guard usable > 1 else { return false }
        isApplyingSplitter = true
        defer { isApplyingSplitter = false }
        splitView.adjustSubviews()
        let minimum = min(Self.panelSizeMin, usable / 2)
        let position = min(max(usable * CGFloat(splitterRatio), minimum), usable - minimum)
        splitView.setPosition(position, ofDividerAt: 0)
        return true
    }

    /// The user has dragged the divider: the frames are the truth now.
    private func captureSplitterRatio() {
        let views = splitView.arrangedSubviews
        guard numPanels == 2, views.count == 2 else { return }
        let usable = splitUsableWidth
        guard usable > 1 else { return }
        let ratio = Double(views[0].frame.width / usable)
        guard ratio > 0, ratio < 1 else { return }       // a degenerate pass must not be stored
        splitterRatio = ratio
    }

    // MARK: - Panels (CApp::SwitchOnOffOnePanel, App.cpp:360-380)

    private func showSecondPanel() {
        if panels.count < 2 {
            let panel = makePanel(1)
            panels.append(panel)
            panel.navigate(to: Settings.panelPath(1) ?? NSHomeDirectory())
        }
        // Either panel may be the one that was closed last time, so both views are put back in
        // their index order (SwitchOnOffOnePanel only ever hides the non-focused one).
        for (index, panel) in panels.enumerated() where !splitView.arrangedSubviews.contains(panel.view) {
            let position = min(index, splitView.arrangedSubviews.count)
            splitView.insertArrangedSubview(panel.view, at: position)
        }
        for panel in panels { panel.view.isHidden = false }
        numPanels = 2
        // Synchronously, on this turn of the run loop: the old code deferred the position with
        // `DispatchQueue.main.async`, and whether that block or the split view's own layout pass
        // ran first was a coin toss. When the block won, `setPosition` ran against a zero-width
        // new subview and left both panels at zero width -- the "2 Panels collapses" report.
        applySplitterRatio()
        // ... and let the new panel lay its own subviews out at the width it has just been given,
        // rather than on some later pass that may not come.
        splitView.layoutSubtreeIfNeeded()
    }

    func switchOnOffOnePanel() {
        if numPanels == 1 {
            showSecondPanel()
        } else {
            // close the non-focused panel (it is kept alive and reused later)
            let closing = focusedPanelIndex == 0 ? 1 : 0
            captureSplitterRatio()              // reopening restores what the user last set
            Settings.splitterPos = splitterRatio
            splitView.removeArrangedSubview(panels[closing].view)
            panels[closing].view.removeFromSuperview()
            numPanels = 1
            setFocusedPanel(focusedPanelIndex == 0 ? 0 : 1)
        }
        focusedPanel.focusList()
    }

    func setFocusedPanel(_ index: Int) {
        focusedPanelIndex = index
        for (i, panel) in panels.enumerated() { panel.isActive = i == index }
        refreshTitle()
    }

    /// CApp::RefreshTitle (App.cpp:963): the focused panel's path, "7-Zip" when empty.
    private func refreshTitle() {
        let path = focusedPanel.currentPath
        window?.title = path.isEmpty ? "7-Zip" : path
    }

    // MARK: PanelDelegate

    func panelDidBecomeActive(_ panel: PanelViewController) {
        if let i = panels.firstIndex(where: { $0 === panel }), i != focusedPanelIndex || !panel.isActive {
            setFocusedPanel(i)
        }
    }

    func panelDidChangeFolder(_ panel: PanelViewController) {
        if panel === focusedPanel { refreshTitle() }
    }

    /// OnTab: switch the focused panel in two-panel mode.
    func panelWantsNextPanel(_ panel: PanelViewController) {
        guard numPanels == 2, panels.count == 2 else { return }
        let next = panel === panels[0] ? 1 : 0
        setFocusedPanel(next)
        panels[next].focusList()
    }

    func panelWantsOnePanelToggle(_ panel: PanelViewController) { switchOnOffOnePanel() }

    func panelWantsWindowClose(_ panel: PanelViewController) { window?.performClose(nil) }

    /// OnSetSameFolder / OnSetSubFolder (App.cpp:858-912).
    func panel(_ panel: PanelViewController, setOtherPanelPath path: String) {
        guard numPanels == 2, let other = otherPanel(of: panel) else { return }
        other.navigate(to: path, fallbackToRoot: false)
    }

    func panel(_ panel: PanelViewController, focusAddressBarOfPanel index: Int) {
        guard index >= 0, index < panels.count, index < numPanels else { return }
        setFocusedPanel(index)
        panels[index].focusPathBar()
    }

    func panel(_ panel: PanelViewController, copyOrMove move: Bool, copyToSame: Bool) {
        if let index = panels.firstIndex(where: { $0 === panel }) { setFocusedPanel(index) }
        performCopyOrMove(move: move, copyToSame: copyToSame)
    }

    func panel(_ panel: PanelViewController, bookmark index: Int, set: Bool) {
        if set { panel.setBookmark(index) } else { panel.openBookmark(index) }
    }

    // MARK: - Auto refresh (kTimerElapse polling of IFolderWasChanged)

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.autoRefresh else { return }
            for panel in self.visiblePanels { panel.refreshIfChanged() }
        }
    }

    // MARK: - NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        min(Self.panelSizeMin, splitUsableWidth / 2)   // kPanelSizeMin, but never past the middle
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        let usable = splitUsableWidth
        return max(usable - Self.panelSizeMin, usable / 2)
    }

    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        // Keep the stored ratio while the window resizes (7zFM stores the position as a ratio).
        // The ratio comes from `splitterRatio`, never from the live frames: during the layout pass
        // that follows an insertion the new subview is still zero wide, which used to turn the
        // ratio into ~1.0 and flash a collapsed panel.
        if !applySplitterRatio() { splitView.adjustSubviews() }
    }

    /// A divider drag is the only thing that changes the ratio (the userInfo key is only there
    /// when the user moved a divider, AppKit's own layout passes leave it out).
    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        captureSplitterRatio()
    }

    // MARK: - NSToolbarDelegate (App.cpp CreateToolbar / ReloadToolbars)

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { visibleToolbarItems }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { Self.archiveItems + Self.standardItems }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        let (label, symbol, action): (String, String, Selector)
        switch itemIdentifier {
        case .szAdd: (label, symbol, action) = (Lang.text(7200, "Add"), "plus.rectangle.on.folder", #selector(MenuActions.toolbarAddToArchive(_:)))         // kMenuCmdID_Toolbar_Add 1070, IDS_ADD
        case .szExtract: (label, symbol, action) = (Lang.text(7201, "Extract"), "arrow.down.doc", #selector(MenuActions.toolbarExtractArchives(_:)))       // kMenuCmdID_Toolbar_Extract 1071, IDS_EXTRACT
        case .szTest: (label, symbol, action) = (Lang.text(7202, "Test"), "checkmark.seal", #selector(MenuActions.toolbarTestArchives(_:)))              // kMenuCmdID_Toolbar_Test 1072, IDS_TEST
        case .szCopy: (label, symbol, action) = (Lang.text(7203, "Copy"), "doc.on.doc", #selector(MenuActions.fileCopyTo(_:)))                          // IDM_COPY_TO 546, IDS_BUTTON_COPY
        case .szMove: (label, symbol, action) = (Lang.text(7204, "Move"), "arrow.right.doc.on.clipboard", #selector(MenuActions.fileMoveTo(_:)))        // IDM_MOVE_TO 547, IDS_BUTTON_MOVE
        case .szDelete: (label, symbol, action) = (Lang.text(7205, "Delete"), "trash", #selector(MenuActions.fileDelete(_:)))                           // IDM_DELETE 548, IDS_BUTTON_DELETE
        case .szInfo: (label, symbol, action) = (Lang.text(7206, "Info"), "info.circle", #selector(MenuActions.fileProperties(_:)))                    // IDM_PROPERTIES 551, IDS_BUTTON_INFO
        default: return nil
        }
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = nil          // responder chain; disabled while nobody implements the action
        item.action = action
        item.isBordered = true
        return item
    }

    private func reloadToolbars() {
        guard let toolbar = window?.toolbar else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (i, id) in visibleToolbarItems.enumerated() { toolbar.insertItem(withItemIdentifier: id, at: i) }
        toolbar.displayMode = (toolbarsMask & 1) != 0 ? .iconAndLabel : .iconOnly
        Settings.toolbarsMask = toolbarsMask
    }

    // MARK: - Menu commands on the window (OnMenuCommand, MyLoadMenu.cpp:805-964)

    @objc func viewTwoPanels(_ sender: Any?) { switchOnOffOnePanel() }                     // IDM_VIEW_TWO_PANELS 732 / F9

    @objc func viewAutoRefresh(_ sender: Any?) {                                            // IDM_VIEW_AUTO_REFRESH 738
        autoRefresh.toggle()
        Settings.autoRefresh = autoRefresh
    }

    @objc func viewArchiveToolbar(_ sender: Any?) { toolbarsMask ^= 8; reloadToolbars() }             // IDM_VIEW_ARCHIVE_TOOLBAR 750
    @objc func viewStandardToolbar(_ sender: Any?) { toolbarsMask ^= 4; reloadToolbars() }            // IDM_VIEW_STANDARD_TOOLBAR 751
    @objc func viewToolbarsLargeButtons(_ sender: Any?) { toolbarsMask ^= 2; reloadToolbars() }       // IDM_VIEW_TOOLBARS_LARGE_BUTTONS 752 (size is fixed on macOS; state kept)
    @objc func viewToolbarsShowButtonsText(_ sender: Any?) { toolbarsMask ^= 1; reloadToolbars() }    // IDM_VIEW_TOOLBARS_SHOW_BUTTONS_TEXT 753

    @objc func viewTimestampLevel(_ sender: Any?) {                                         // IDM_VIEW_TIME + k
        guard let level = (sender as? NSMenuItem)?.representedObject as? Int else { return }
        Settings.timestampLevel = level
        for panel in panels { panel.reload() }
    }

    @objc func viewTimeUTC(_ sender: Any?) {                                                // IDM_VIEW_TIME_UTC 799
        Settings.timestampShowUTC.toggle()
        SZFolder.timestampShowUTC = Settings.timestampShowUTC
        for panel in panels { panel.reload() }
    }

    @objc func favoritesSetBookmark(_ sender: Any?) {                                       // CPanel::SetBookmark
        guard let tag = (sender as? NSMenuItem)?.tag else { return }
        let i = tag - MainMenu.kMenuIDSetBookmark
        guard (0..<10).contains(i) else { return }
        focusedPanel.setBookmark(i)
    }

    @objc func favoritesOpenBookmark(_ sender: Any?) {                                      // CPanel::OpenBookmark
        guard let tag = (sender as? NSMenuItem)?.tag else { return }
        let i = tag - MainMenu.kMenuIDOpenBookmark
        guard (0..<10).contains(i) else { return }
        focusedPanel.openBookmark(i)
    }

    @objc func fileExit(_ sender: Any?) {                                                   // IDCLOSE -> WM_CLOSE
        window?.performClose(sender)
    }

    /// IDM_ABOUT 961 -> CAboutDialog (IDD_ABOUT 2900). The Wave 1 placeholder here was the
    /// standard macOS About panel, and `ToolsCommands.install()` retargeted both menu items at
    /// the real dialog once the app had launched -- which renamed them in the accessibility tree
    /// (Mac/docs/requests.md, `tools` -> `panel`). The item now points straight at the dialog.
    @objc func helpAbout(_ sender: Any?) {
        AboutDialog.show(parent: window)
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        windowActionIsEnabled(item.action)
    }

    /// The toolbar Copy / Move buttons follow the File-menu rules of 01 §2.1.
    private func windowActionIsEnabled(_ action: Selector?) -> Bool {
        switch action {
        case #selector(fileCopyTo(_:)):
            guard let snap = focusedPanel.snapshot else { return false }
            return snap.supportsOperations && !focusedPanel.operatedRowIndices().isEmpty && !snap.isHashFolder
        case #selector(fileMoveTo(_:)):
            guard let snap = focusedPanel.snapshot else { return false }
            return snap.supportsOperations && !snap.chainIsReadOnly
                && !focusedPanel.operatedRowIndices().isEmpty && !snap.isHashFolder
        default:
            return true
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(fileCopyTo(_:)), #selector(fileMoveTo(_:)):
            return windowActionIsEnabled(item.action)
        case #selector(viewTwoPanels(_:)): item.state = numPanels == 2 ? .on : .off
        case #selector(viewAutoRefresh(_:)): item.state = autoRefresh ? .on : .off
        case #selector(viewArchiveToolbar(_:)): item.state = (toolbarsMask & 8) != 0 ? .on : .off
        case #selector(viewStandardToolbar(_:)): item.state = (toolbarsMask & 4) != 0 ? .on : .off
        case #selector(viewToolbarsLargeButtons(_:)): item.state = (toolbarsMask & 2) != 0 ? .on : .off
        case #selector(viewToolbarsShowButtonsText(_:)): item.state = (toolbarsMask & 1) != 0 ? .on : .off
        case #selector(viewTimestampLevel(_:)):
            item.state = ((item.representedObject as? Int) == Settings.timestampLevel) ? .on : .off
        case #selector(viewTimeUTC(_:)): item.state = Settings.timestampShowUTC ? .on : .off
        case #selector(favoritesOpenBookmark(_:)):
            let i = item.tag - MainMenu.kMenuIDOpenBookmark
            return (0..<10).contains(i) && !Settings.folderShortcuts[i].isEmpty
        default: break
        }
        return true
    }
}

/// Dropping files on the window background (or the toolbar) is "Add to archive..."
/// (CompressDropFiles, PanelDrag.cpp:2817-2981, 01 §3.15).
final class MainWindowContentView: NSView {

    weak var controller: MainWindowController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        controller?.focusedPanel.compressDroppedFiles(info: sender) ?? false
    }
}

extension NSToolbarItem.Identifier {
    static let szAdd = NSToolbarItem.Identifier("sz.add")
    static let szExtract = NSToolbarItem.Identifier("sz.extract")
    static let szTest = NSToolbarItem.Identifier("sz.test")
    static let szCopy = NSToolbarItem.Identifier("sz.copy")
    static let szMove = NSToolbarItem.Identifier("sz.move")
    static let szDelete = NSToolbarItem.Identifier("sz.delete")
    static let szInfo = NSToolbarItem.Identifier("sz.info")
}
