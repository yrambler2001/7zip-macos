// MainWindowController.swift -- the 7zFM main window (FM.cpp WndProc, App.cpp CApp): toolbar
// with the seven buttons, one or two panels in a split view, window/panel persistence.

import Cocoa
import SevenZipKit

final class MainWindowController: NSWindowController, NSWindowDelegate, NSSplitViewDelegate, NSToolbarDelegate,
                                 NSMenuItemValidation, NSUserInterfaceValidations, PanelDelegate {

    private let splitView = PanelSplitView()
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

    /// PanelDelegate: the window a panel belongs to even while its view is out of the split view, so
    /// a closed panel still has a sheet parent instead of raising an ownerless app-modal alert
    /// (`ErrorAlert`, `Mac/docs/reports/fastui.md` section 6.10).
    var panelHostWindow: NSWindow? { window }

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
        // Quit without closing the window (Cmd+Q): the nested-archive write-back of
        // windowWillClose runs here instead (PanelNestedArchives.swift, 01 §3.8).
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                for panel in self?.panels ?? [] { panel.closeNestedArchivesForShutdown() }
            }
        }
        window.delegate = self
        TestAnimations.apply(to: window)
        // Signal 2 of the test-support contract: the reset generation, "0" before the first reset.
        // Only under SZ_TEST_SUPPORT, so a shipped window's accessibility value is untouched.
        if TestSupport.isEnabled {
            window.setAccessibilityValue(TestResetCoordinator.initialAccessibilityValue)
        }
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
        toolbar.isVisible = (toolbarsMask & 12) != 0
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
        // `zoom(_:)` goes through setFrame(_:display:animate:), whose duration is NSWindowResizeTime.
        if Settings.maximized { TestAnimations.withoutAnimation { window.zoom(nil) } }
        startRefreshTimer()
    }

    /// Command-line path (FM.cpp:975-1014): panel 0 opens it. An existing **file** is opened as an
    /// archive (needOpenArc); if that fails, 7zFM shows "Error" -- IDS_CANT_OPEN_ARCHIVE 3005 or
    /// IDS_CANT_OPEN_ENCRYPTED_ARCHIVE 3006 with the path, then the non-open level's text -- and
    /// WM_CREATE returns -1, so the window never appears and the process ends. Here the window is
    /// closed when it was created for this path (`closesWindowOnFailure`; for the only window that
    /// ends the app, as on Windows); a window that was already showing something keeps it. A
    /// cancelled open (E_ABORT) closes the same way without a box. A path that does not exist binds
    /// its nearest existing folder, as BindToPath's walk up does (PanelFolderChange.cpp:151-190).
    func openStartupPath(_ path: String, formatHint: String?, closesWindowOnFailure: Bool = false) {
        var full = (path as NSString).isAbsolutePath ? path : FileManager.default.currentDirectoryPath + "/" + path
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: full, isDirectory: &isDirectory), !isDirectory.boolValue {
            panels[0].openLaunchArchive(full, formatHint: formatHint) { [weak self] failure in
                guard let self, let failure else { return }
                if let message = failure.launchMessage(fullPath: full) {
                    let alert = ErrorAlert.make(message: message, style: .critical)
                    if closesWindowOnFailure {
                        _ = ErrorAlert.run(alert, on: nil)        // MessageBoxW(NULL, ...): no owner
                    } else {
                        ErrorAlert.present(alert, on: self.window)
                    }
                }
                if closesWindowOnFailure { self.window?.close() }
            }
            return
        }
        while !full.isEmpty, full != "/", !manager.fileExists(atPath: full) {
            full = (full as NSString).deletingLastPathComponent
        }
        panels[0].navigate(to: full.isEmpty ? "/" : full, formatHint: formatHint)
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
        // CPanel's destructor closes every archive level: a modified nested archive is offered
        // for write-back into its parent (PanelNestedArchives.swift, 01 §3.8).
        for panel in panels { panel.closeNestedArchivesForShutdown() }
        // A closed window needs no toolbar, and leaving one behind is not free: `NSToolbar`'s
        // `removeItem(at:)` indexes the *displayed* items, while `toolbar.items` still holds every
        // item, so anything that rebuilds toolbars by walking `NSApp.windows` -- which
        // `OptionsPostApply.reloadLangItems()` does, and step 3 of `sevenzip://test/reset` calls --
        // throws `NSInternalInconsistencyException` on a window that has no layout any more. Filed
        // for `options` in `Mac/docs/requests.md`; this is the half that belongs here.
        window?.toolbar = nil
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
        let minimum = min(Self.panelSizeMin, usable / 2)
        let position = min(max(usable * CGFloat(splitterRatio), minimum), usable - minimum)
        // SZ_DISABLE_ANIMATIONS: the divider move and the subview adjustment are the split view's
        // two animatable steps, so both go inside one zero-duration grouping.
        TestAnimations.withoutAnimation {
            splitView.adjustSubviews()
            splitView.setPosition(position, ofDividerAt: 0)
        }
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
        TestAnimations.withoutAnimation {
            for (index, panel) in panels.enumerated() where !splitView.arrangedSubviews.contains(panel.view) {
                let position = min(index, splitView.arrangedSubviews.count)
                splitView.insertArrangedSubview(panel.view, at: position)
            }
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
        // A panel that was closed did not reload while it had no window (PanelViewController.reload),
        // so whatever it missed -- a language switch, an Options apply, the View menu's timestamp
        // level -- is applied now that it is back on screen.
        for panel in visiblePanels { panel.panelDidBecomeVisible() }
    }

    func switchOnOffOnePanel() {
        if numPanels == 1 {
            showSecondPanel()
        } else {
            // close the non-focused panel (it is kept alive and reused later)
            let closing = focusedPanelIndex == 0 ? 1 : 0
            captureSplitterRatio()              // reopening restores what the user last set
            Settings.splitterPos = splitterRatio
            TestAnimations.withoutAnimation {
                splitView.removeArrangedSubview(panels[closing].view)
                panels[closing].view.removeFromSuperview()
            }
            numPanels = 1
            setFocusedPanel(focusedPanelIndex == 0 ? 0 : 1)
        }
        focusedPanel.focusList()
    }

    // MARK: - Test support: rebuild the window's state in place (Mac/docs/api/resetcmd.md)

    /// Step 4 of `sevenzip://test/reset`. Everything the window itself owns comes back from the
    /// (possibly just replaced) settings domain, the panel count becomes what the request asks for,
    /// and every panel -- including one that is currently hidden, so nothing survives in it -- is
    /// rebuilt at its requested path. `completion` runs on the main thread once **all** the panels
    /// have finished binding, because a panel binds on its own serial queue.
    func resetForTest(_ request: TestResetRequest, completion: @escaping () -> Void) {
        autoRefresh = Settings.autoRefresh
        toolbarsMask = Settings.toolbarsMask
        reloadToolbars()
        splitterRatio = Settings.splitterPos

        let wanted = min(max(request.panelCount ?? Settings.numPanels, 1), 2)
        if wanted == 2, numPanels == 1 {
            showSecondPanel()
        } else if wanted == 1, numPanels == 2 {
            // Not switchOnOffOnePanel(): that one closes the *non-focused* panel and persists the
            // divider, while a reset always leaves panel 0 on screen and panel 1 closed.
            TestAnimations.withoutAnimation {
                splitView.removeArrangedSubview(panels[1].view)
                panels[1].view.removeFromSuperview()
            }
            numPanels = 1
        }
        setFocusedPanel(0)
        applySplitterRatio()

        var remaining = panels.count
        let done = {
            remaining -= 1
            if remaining == 0 { completion() }
        }
        for (index, panel) in panels.enumerated() {
            let path = request.panelPaths[index] ?? Settings.panelPath(index) ?? NSHomeDirectory()
            panel.resetForTest(to: path, viewMode: request.viewMode) { _ in done() }
        }
        if panels.isEmpty { completion() }
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
        // App.cpp AddButton: the 7-Zip bitmaps, 48x36 IDB_* with "Large Buttons", else the 24x24
        // IDB_*2 (01 §1.3, §9 #15), RGB(255,0,255) masked. SF Symbols only if an asset is missing.
        let large = (toolbarsMask & 2) != 0
        item.image = Self.toolbarBitmap(itemIdentifier, large: large)
            ?? NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = nil          // responder chain; disabled while nobody implements the action
        item.action = action
        item.isBordered = true
        return item
    }

    /// The toolbar bitmap for an item: IDB_ADD 100 ... IDB_INFO 106 (48x36) or IDB_ADD2 150 ...
    /// IDB_INFO2 156 (24x24), converted from CPP/7zip/UI/FileManager/*.bmp into the asset catalog.
    static func toolbarBitmap(_ id: NSToolbarItem.Identifier, large: Bool) -> NSImage? {
        let names: [NSToolbarItem.Identifier: String] = [
            .szAdd: "add", .szExtract: "extract", .szTest: "test", .szCopy: "copy",
            .szMove: "move", .szDelete: "delete", .szInfo: "info",
        ]
        guard let name = names[id] else { return nil }
        return NSImage(named: "toolbar-\(name)-\(large ? "large" : "small")")
    }

    private func reloadToolbars() {
        guard let toolbar = window?.toolbar else { return }
        while !toolbar.items.isEmpty { toolbar.removeItem(at: 0) }
        for (i, id) in visibleToolbarItems.enumerated() { toolbar.insertItem(withItemIdentifier: id, at: i) }
        toolbar.displayMode = (toolbarsMask & 1) != 0 ? .iconAndLabel : .iconOnly
        // MoveSubWindows: the toolbar takes room only while one of the two toolbars is on (01 §1.2).
        toolbar.isVisible = (toolbarsMask & 12) != 0
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
    @objc func viewToolbarsLargeButtons(_ sender: Any?) { toolbarsMask ^= 2; reloadToolbars() }       // IDM_VIEW_TOOLBARS_LARGE_BUTTONS 752: IDB_* 48x36 vs IDB_*2 24x24
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
            return fileMenuRule(action) ?? true
        }
    }

    /// The CFileMenu::Load rules (MyLoadMenu.cpp:588-734, 01 §2.1) for the File-menu items whose
    /// handler lives on the window rather than on the panel; nil = not a File-menu item.
    ///   IDM_SPLIT 549 / IDM_COMBINE 550   enabled only for isOneFsFile
    ///   IDM_DIFF 554                      disabled in a hash folder (hidden without a Diff tool)
    ///   IDM_LINK 558                      exactly one operated item, not in a hash folder
    ///   CRC popup (IDM_CRC32 102 ...)     always enabled
    func fileMenuRule(_ action: Selector?) -> Bool? {
        let panel = focusedPanel
        let snap = panel.snapshot
        let operated = panel.operatedRowIndices().map { panel.rows[$0] }
        let isHash = snap?.isHashFolder ?? false
        switch action {
        case #selector(MenuActions.fileSplit(_:)), #selector(MenuActions.fileCombine(_:)):
            let isOneFsFile = (snap?.isFileSystem ?? false) && operated.count == 1 && !operated[0].isDirectory
            return isOneFsFile
        case #selector(MenuActions.fileDiff(_:)):
            return !isHash
        case #selector(MenuActions.fileLink(_:)):
            return operated.count == 1 && !isHash
        case #selector(MenuActions.fileCalculateHash(_:)):
            return true
        default:
            return nil
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(fileCopyTo(_:)), #selector(fileMoveTo(_:)):
            return windowActionIsEnabled(item.action)
        case #selector(MenuActions.fileDiff(_:)):
            // ReadRegDiff empty -> IDM_DIFF is removed from the menu (MyLoadMenu.cpp:672-676).
            item.isHidden = Settings.diffPath.isEmpty
            return windowActionIsEnabled(item.action)
        case #selector(MenuActions.fileSplit(_:)), #selector(MenuActions.fileCombine(_:)),
             #selector(MenuActions.fileLink(_:)):
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

/// The two-panel splitter: kSplitterWidth = 4 (FM.cpp, 01 §1.2) instead of AppKit's 9 pt thick
/// divider, drawn as a plain separator line in its middle.
final class PanelSplitView: NSSplitView {
    override var dividerThickness: CGFloat { 4 }
    override func drawDivider(in rect: NSRect) {
        NSColor.separatorColor.setFill()
        NSRect(x: rect.midX - 0.5, y: rect.minY, width: 1, height: rect.height).fill()
    }
}
