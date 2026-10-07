// PanelNavigation.swift -- BindToPath and everything that changes the current folder
// (PanelFolderChange.cpp, PanelItemOpen.cpp, PanelItems.cpp OpenSelectedItems): the address bar
// with its breadcrumb drop-down, parent / root / volumes, opening items and archives (nested
// archives included), the folder history dialog, the favorites, and the two-panel helpers.
//
// Parity: 01-fm-feature-inventory.md §3.5, §3.8, §3.9.

import Cocoa
import SevenZipKit

extension PanelViewController {

    /// Extensions that Enter always opens externally, never as an archive
    /// (kStartExtensions, PanelItemOpen.cpp:633-660).
    static let startExtensions: Set<String> = [
        "exe", "bat", "ps1", "com", "lnk", "chm", "msi", "doc", "dot", "xls", "ppt", "pps", "wps",
        "wpt", "wks", "xlr", "wdb", "vsd", "pub", "docx", "docm", "dotx", "dotm", "xlsx", "xlsm",
        "xltx", "xltm", "xlsb", "xps", "xlam", "pptx", "pptm", "potx", "potm", "ppam", "ppsx",
        "ppsm", "vsdx", "xsn", "mpp", "msg", "dwf", "flv", "swf", "epub", "odt", "ods", "wb3",
        "pdf", "ps", "txt", "xml", "xsd", "xsl", "xslt", "hxk", "hxc", "htm", "html", "xhtml",
        "xht", "mht", "mhtml", "htw", "asp", "aspx", "css", "cgi", "jsp", "shtml", "h", "hpp",
        "hxx", "c", "cpp", "cxx", "m", "mm", "go", "swift", "awk", "sed", "hta", "js", "json",
        "php", "php3", "php4", "php5", "phptml", "pl", "pm", "py", "pyo", "rb", "tcl", "ts",
        "vbs", "asm", "mak", "clw", "csproj", "vcproj", "sln", "dsp", "dsw",
    ]

    /// kExeExtensions (PanelItemOpen.cpp:629) -- used by the IsVirus_Message check.
    static let exeExtensions: Set<String> = ["exe", "bat", "ps1", "com", "lnk"]

    static let maxOpenItems = 20            // kMaxOpenItems (PanelItems.cpp:1096)

    // MARK: - BindToPathAndRefresh

    /// BindToPathAndRefresh (PanelFolderChange.cpp:315): opens `path` ("" = root). A wildcard in
    /// the last component opens the parent and uses the component as the selection mask; a file on
    /// the way is opened as an archive and binding continues inside it (nested archives included,
    /// handled by SZFolder.folder(forPath:)).
    /// - Parameter reportErrors: false logs a failed bind instead of showing it. Used by
    ///   `resetForTest`, which must not leave a sheet up after the reset has closed everything.
    func navigate(to path: String, formatHint: String? = nil, fallbackToRoot: Bool = true,
                  select name: String? = nil, focusListOnSuccess: Bool = false,
                  reportErrors: Bool = true,
                  completion: ((Bool) -> Void)? = nil) {
        var target = path
        var mask: String? = nil
        let last = (path as NSString).lastPathComponent
        if PanelMask.containsWildcard(last) {
            mask = last
            target = (path as NSString).deletingLastPathComponent
            if target.isEmpty { target = "/" }
        }
        setPendingFocus(name: name, selectionMask: mask)
        let expanded = (target as NSString).expandingTildeInPath
        runOnQueue { [self] in
            // BindToPath starts with CloseOpenFolders: every nested level is closed -- and a
            // modified one written back into its parent -- before the new chain is opened, so the
            // new chain sees the updated parent (PanelNestedArchives.swift, 01 §3.8).
            self.leaveNestedArchives(from: self.folder, to: nil)
            let leavingChain = Self.archiveChain(of: self.folder)
            var folderObject: SZFolder? = nil
            var failure: NSError? = nil
            var levelErrors: String? = nil
            let bind: (SZProgressDelegate?) throws -> SZFolder = { [self] progress in
                let bound = try SZFolder.folder(forPath: expanded, formatHint: formatHint,
                                                passwordDelegate: self, progress: progress)
                if bound.supportsFlatMode {
                    let flat = bound.isArchive ? self.flatModeForArc : self.flatModeForDisk
                    if flat {
                        bound.flatMode = true
                        try bound.loadItems()
                    }
                }
                return bound
            }
            let outcome: Result<SZFolder, Error>
            if Self.bindNeedsNoArchiveOpen(expanded) {
                outcome = Result { try bind(nil) }
            } else {
                // An archive on the path: CFfpOpen's "Opening" progress (PanelArchiveOpen.swift).
                outcome = self.runArchiveOpen(name: (expanded as NSString).lastPathComponent) { try bind($0) }
            }
            switch outcome {
            case .success(let bound):
                folderObject = bound
                // BindToPath keeps the CFolderLinks the new path is still inside, passwords
                // included (PanelFolderChange.cpp:88-125); this port re-opened them, so the
                // re-opened levels take the passwords back.
                for level in Self.archiveChain(of: bound) where level.password == nil {
                    level.password = leavingChain.first { $0.path == level.path && $0.password != nil }?.password
                }
                // CPanel::OpenAsArc shows ffp.ErrorMessage once the archive is entered.
                // Only for a level newly opened here: a re-bound level was entered before.
                levelErrors = Self.archiveChain(of: bound)
                    .filter { level in !leavingChain.contains { $0.path == level.path } }
                    .compactMap { $0.openErrorMessage }.first
            case .failure(let error as NSError):
                switch ArchiveOpenFailure(error) {
                case .cancelled:
                    // E_ABORT: silent, and the panel keeps what it showed.
                    failure = error
                case .notArchive(let file, _, _, _) where !file.isEmpty && !Self.isInsideArchivePath(file):
                    // BindToPath (PanelFolderChange.cpp:236-262): a file on the way that is not an
                    // archive binds its folder instead -- OpenAsArc without _Msg, so silently.
                    let directory = (file as NSString).deletingLastPathComponent
                    folderObject = try? SZFolder.folder(forPath: directory.isEmpty ? "/" : directory,
                                                        passwordDelegate: nil)
                    if folderObject == nil {
                        failure = error
                        if fallbackToRoot { folderObject = SZRootFolder.makeRootFolder() }
                    }
                default:
                    failure = error
                    if fallbackToRoot { folderObject = SZRootFolder.makeRootFolder() }
                }
            }
            if let folderObject { self.folder = folderObject }
            let snap = folderObject.map { self.makeSnapshot($0) }
            let silent = (fallbackToRoot && path.isEmpty) || !reportErrors
            DispatchQueue.main.async {
                if let failure, !silent, failure.code != SZError.Code.cancelled.rawValue {
                    self.showError(failure)
                } else if let failure, !reportErrors, failure.code != SZError.Code.cancelled.rawValue {
                    NSLog("7-Zip: panel %d could not open %@: %@", self.panelIndex, path,
                          failure.localizedDescription)
                }
                if snap == nil {
                    self.setPendingFocus(name: nil)      // a failed bind must not arm the next apply
                }
                if let snap {
                    self.apply(snap, selectNames: name.map { [$0] } ?? [])
                    if focusListOnSuccess && failure == nil { self.focusList() }
                }
                if let levelErrors, reportErrors { self.showError(message: levelErrors) }
                completion?(failure == nil)
            }
        }
    }

    /// The path of an item inside an archive ("/a.zip/b.7z"): some ancestor is a file.
    static func isInsideArchivePath(_ path: String) -> Bool {
        var parent = (path as NSString).deletingLastPathComponent
        var isDirectory: ObjCBool = false
        while !parent.isEmpty && parent != "/" {
            if FileManager.default.fileExists(atPath: parent, isDirectory: &isDirectory) {
                return !isDirectory.boolValue
            }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return false
    }

    /// OpenParentFolder (PanelFolderChange.cpp:917): CloseOneLevel at an archive root, else
    /// BindToParentFolder; the child we came from becomes focused and selected.
    func goUp() {
        guard let snap = snapshot, !snap.isRoot else { return }
        var leaving = (snap.fullPath as NSString).lastPathComponent
        if leaving.isEmpty {
            leaving = ((snap.fullPath as NSString).deletingLastPathComponent as NSString).lastPathComponent
        }
        runOnQueue { [self] in
            guard let folder = self.folder else { return }
            do {
                let parent = try folder.bindToParentFolder()
                // CloseOneLevel -> OpenParentArchiveFolder: leaving a nested archive's root writes
                // a modified copy back into the parent, which is reloaded in place.
                self.leaveNestedArchives(from: folder, to: parent)
                self.folder = parent
                if parent.supportsFlatMode {
                    let flat = parent.isArchive ? self.flatModeForArc : self.flatModeForDisk
                    if parent.flatMode != flat {
                        parent.flatMode = flat
                        try parent.loadItems()
                    }
                }
                let snapshot = self.makeSnapshot(parent)
                DispatchQueue.main.async { self.apply(snapshot, select: leaving) }
            } catch {
                DispatchQueue.main.async { self.showError(error) }
            }
        }
    }

    /// OpenRootFolder (PanelFolderChange.cpp:1025)
    func goRoot() { navigate(to: "") }

    /// OpenDrivesFolder (PanelFolderChange.cpp:1043): the volumes list ("\" or "/" in the list).
    func openDrivesFolder() {
        runOnQueue { [self] in
            let volumes = SZRootFolder.makeVolumesFolder()
            do { try volumes.loadItems() } catch { }
            self.leaveNestedArchives(from: self.folder, to: volumes)     // CloseOpenFolders
            self.folder = volumes
            let snap = self.makeSnapshot(volumes)
            DispatchQueue.main.async { self.apply(snap, selectNames: []) }
        }
    }

    /// The current directory disappeared (fsfolder api §7 directoryWasRemoved): go up to the
    /// nearest existing folder instead of reloading an empty listing.
    func recoverFromRemovedDirectory() {
        guard let snap = snapshot else { return }
        var path = snap.fullPath
        if path.hasSuffix("/") { path.removeLast() }
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty, parent != "/",
              !FileManager.default.fileExists(atPath: parent) {
            parent = (parent as NSString).deletingLastPathComponent
        }
        navigate(to: parent.isEmpty ? "/" : parent, fallbackToRoot: true,
                 select: (path as NSString).lastPathComponent)
    }

    // MARK: - Opening items

    /// OpenSelectedItems (PanelItems.cpp:1096-1136).
    func openSelectedItems(tryInternal: Bool) {
        let indices = operatedRowIndices()
        if indices.count == 1, rows[indices[0]].isDirectory || rows[indices[0]].isParentRow {
            openRow(rows[indices[0]], insideOnly: false, formatHint: nil)
            return
        }
        if indices.isEmpty {
            if let focused = focusedRow(), focused.isParentRow { goUp() }
            return
        }
        if indices.count > Self.maxOpenItems {
            showError(message: Lang.text(3016, "Too many items"))     // IDS_TOO_MANY_ITEMS
            return
        }
        // A folder (or an archive) replaces the listing, so only the first one is entered and the
        // rest of the operated items are ignored -- upstream's dirIsStarted guard. With more than
        // one item every file is started externally: binding several archives in a row would each
        // rebind the panel and use the indices of a listing that is already gone.
        if let folderIndex = indices.first(where: { rows[$0].isDirectory }) {
            openRow(rows[folderIndex], insideOnly: false, formatHint: nil, tryInternal: tryInternal)
            return
        }
        for index in indices {
            openRow(rows[index], insideOnly: false, formatHint: nil,
                    tryInternal: tryInternal && indices.count == 1)
        }
    }

    /// OpenFocusedItemAsInternal(type) -- IDM_OPEN_INSIDE / _ONE ("*") / _PARSER ("#").
    func openSelection(insideOnly: Bool = false, formatHint: String? = nil) {
        guard let row = focusedRow() else { return }
        openRow(row, insideOnly: insideOnly, formatHint: formatHint)
    }

    /// OpenSelectedItems(false): hand the file(s) to the default application (IDM_OPEN_OUTSIDE).
    /// An item inside an archive goes through OpenItemInArchive: it is extracted to a `7zO` temp
    /// folder and that copy is opened, with the edit watched for a write-back (01 §3.8, §3.9) --
    /// the `extract` scope's `ItemOpenCommands.openOutside(context:)`.
    func openSelectionOutside() {
        guard let snap = snapshot, !snap.isHashFolder else { return }
        let indices = operatedRowIndices()
        if indices.count > Self.maxOpenItems {
            showError(message: Lang.text(3016, "Too many items"))     // IDS_TOO_MANY_ITEMS
            return
        }
        if snap.isArchive {
            for index in indices {
                guard let context = operationContext(rowIndices: [index]) else { continue }
                ItemOpenCommands.openOutside(context: context)
            }
            return
        }
        guard snap.isFileSystem else { return }
        for row in indices.map({ rows[$0] }) where !row.fullPath.isEmpty {
            guard confirmSuspiciousName(row.name) else { continue }
            NSWorkspace.shared.open(URL(fileURLWithPath: row.fullPath))
        }
    }

    /// OpenItem (PanelItemOpen.cpp:973-1030).
    func openRow(_ row: PanelRow, insideOnly: Bool, formatHint: String?, tryInternal: Bool = true) {
        if row.isParentRow { goUp(); return }
        let engineIndex = row.engineIndex
        let isFS = snapshot?.isFileSystem ?? false
        let ext = row.pathExtension.lowercased()
        // DoItemAlwaysStart applies inside archives too (PanelItemOpen.cpp:993, :1503): a .docx in
        // a zip is started, not opened as an archive.
        let alwaysStart = !row.isDirectory && Self.startExtensions.contains(ext)
        runOnQueue { [self] in
            guard let folder = self.folder else { return }
            do {
                // Every directory is a folder (IsItem_Folder -> OpenFolder, PanelItems.cpp:1090-1091),
                // an app bundle or another package included: 7zFM has no packages, and a .app tried as
                // an archive failed with E_FAIL (fix111). Open Outside (Shift+Enter) launches it.
                if row.isDirectory {
                    let sub = try folder.bindToFolder(at: engineIndex)
                    self.folder = sub
                    if sub.supportsFlatMode {
                        let flat = sub.isArchive ? self.flatModeForArc : self.flatModeForDisk
                        if flat { sub.flatMode = true; try sub.loadItems() }
                    }
                    let snap = self.makeSnapshot(sub)
                    DispatchQueue.main.async { self.apply(snap, selectNames: []) }
                    return
                }
                if alwaysStart && !insideOnly {
                    self.openExternally(row)
                    return
                }
                if !tryInternal && !insideOnly {
                    self.openExternally(row)
                    return
                }
                // try the file as an archive: OpenAsArc_Index / OpenItemInArchive's tryAsArchive
                // half, under the "Opening" progress (PanelArchiveOpen.swift).
                let virtualPath = isFS && !row.fullPath.isEmpty ? row.fullPath : folder.fullPath + row.name
                let opened = self.runArchiveOpen(name: row.name) { progress -> SZFolder in
                    let archive = try SZArchiveOpener.openArchive(in: folder, itemIndex: engineIndex,
                                                                  formatHint: formatHint,
                                                                  passwordDelegate: self, progress: progress)
                    let root = try archive.rootFolder()
                    if root.supportsFlatMode, self.flatModeForArc {
                        root.flatMode = true
                        try root.loadItems()
                    }
                    return root
                }
                switch opened {
                case .success(let root):
                    self.folder = root
                    let snap = self.makeSnapshot(root)
                    let levelErrors = root.archive?.openErrorMessage
                    DispatchQueue.main.async {
                        self.apply(snap, selectNames: [])
                        // CPanel::OpenAsArc: MessageBox_Error(ErrorMessage) after entering.
                        if let levelErrors { self.showError(message: levelErrors) }
                    }
                case .failure(let error):
                    let failure = ArchiveOpenFailure(error)
                    // OpenAsArc_Msg: a box for an encrypted archive or a real error, nothing for a
                    // plain "not an archive" or a cancel.
                    if let message = failure.panelMessage(virtualPath: virtualPath) {
                        DispatchQueue.main.async { self.showError(message: message) }
                    }
                    // OpenItem / OpenItemInArchive: only S_FALSE goes on to start the file
                    // externally (straight from disk in a file-system folder, through a 7zO temp
                    // copy inside an archive) -- and only when the command allows it.
                    if case .notArchive = failure, !insideOnly {
                        self.openExternally(row)
                    }
                }
            } catch {
                DispatchQueue.main.async { self.showError(error) }
            }
        }
    }

    /// StartApplication (PanelItemOpen.cpp:817) after the IsVirus_Message check.
    private func openExternally(_ row: PanelRow) {
        let path = row.fullPath
        guard !path.isEmpty else {
            // Inside an archive: OpenItemInArchive's tryExternal half -- extract the item to a 7zO
            // temp folder and open that copy (ItemOpenCommands, the extract scope's temp-open).
            DispatchQueue.main.async {
                guard let index = self.rows.firstIndex(where: { $0.engineIndex == row.engineIndex && $0.name == row.name }),
                      let context = self.operationContext(rowIndices: [index]) else {
                    self.showUnsupportedOperation()
                    return
                }
                ItemOpenCommands.openOutside(context: context)
            }
            return
        }
        DispatchQueue.main.async {
            guard self.confirmSuspiciousName(row.name) else { return }
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
    }

    /// IsVirus_Message (PanelItemOpen.cpp:867): 5+ consecutive spaces, an RLO override, or an
    /// executable extension hidden behind trailing dots and spaces asks for confirmation (3012).
    func confirmSuspiciousName(_ name: String) -> Bool {
        // One list and one text for every caller: SuspiciousName (TempOpen.swift) carries the
        // macOS executables of 01 §9 #27 as well.
        guard SuspiciousName.looksDangerous(name) else { return true }
        return SuspiciousName.confirm(name, parent: hostWindow)
    }

    // MARK: - Address bar drop-down (01 §3.9)

    /// CBN_DROPDOWN (OnComboBoxCommand, PanelFolderChange.cpp:627-837): one entry per path
    /// component with the current path first, then Documents and Computer with the volumes.
    func rebuildAddressDropdown() {
        let entries = AddressDropdown.entries(currentPath: currentPath,
                                              documents: NSHomeDirectory() + "/Documents/",
                                              volumes: FileManager.default.mountedVolumeURLs(
                                                includingResourceValuesForKeys: nil,
                                                options: [.skipHiddenVolumes])?.map { $0.path } ?? [])
        addressDropdownPaths = entries.map { $0.path }
        addressDropdownEntries = entries
        // The list is AddressPopup's (feel3); NSComboBox's own list stays empty.
        pathCombo.removeAllItems()
    }

    /// CBN_DROPDOWN from the arrow (or Alt+Down / F4): build the entries and open the Windows-
    /// style list under the combo (PanelAddressPopup.swift).
    func showAddressPopup() {
        if let open = AddressPopup.current, open.isOpen {
            open.close()
            return
        }
        rebuildAddressDropdown()
        let items = addressDropdownEntries.map {
            AddressPopupItem(name: $0.name, level: $0.level, icon: AddressDropdown.icon(for: $0))
        }
        AddressPopup.show(below: pathCombo, items: items, font: PanelMetrics.listFont) { [weak self] index in
            self?.commitAddressDropdownEntry(at: index)
        }
    }

    /// CBN_SELENDOK: bind the entry's path (ComboBoxPaths[index]) and focus the list.
    func commitAddressDropdownEntry(at index: Int) {
        guard index >= 0, index < addressDropdownPaths.count else { return }
        let path = addressDropdownPaths[index]
        navigate(to: path, fallbackToRoot: false, focusListOnSuccess: true)
    }

    // MARK: - Folders history and favorites (01 §3.5)

    /// FoldersHistory (PanelFolderChange.cpp:866-892): the ListView dialog, Del removes an entry.
    func showFoldersHistory() {
        var options = ListViewDialogOptions()
        options.title = Lang.text(6601, "Folders History")           // IDS_FOLDERS_HISTORY
        options.strings = Settings.folderHistory
        options.numColumns = 1
        options.selectFirst = true
        options.deleteIsAllowed = true
        let result = ListViewDialog.run(options, parent: view.window)
        if result.stringsWereChanged {
            Settings.folderHistory = result.strings
        }
        guard result.accepted, result.focusedItemIndex >= 0, result.focusedItemIndex < result.strings.count else { return }
        navigate(to: result.strings[result.focusedItemIndex], fallbackToRoot: false)
    }

    /// SetBookmark(i) stores _currentFolderPrefix; OpenBookmark(i) binds it.
    func setBookmark(_ index: Int) {
        guard (0..<10).contains(index) else { return }
        var list = Settings.folderShortcuts
        while list.count < 10 { list.append("") }
        list[index] = currentPath
        Settings.folderShortcuts = list
    }

    func openBookmark(_ index: Int) {
        guard (0..<10).contains(index) else { return }
        let list = Settings.folderShortcuts
        guard index < list.count, !list[index].isEmpty else { return }
        navigate(to: list[index], fallbackToRoot: false)
    }

    // MARK: - Two-panel helpers (App.cpp:858-912)

    /// OnSetSubFolder (Alt+Left / Alt+Right): the other panel binds to the focused sub-folder.
    func setOtherPanelToFocusedSubFolder() {
        guard let focused = focusedRow(), !focused.isParentRow else { return }
        let base = currentPath
        let path = focused.fullPath.isEmpty ? base + focused.name : focused.fullPath
        delegate?.panel(self, setOtherPanelPath: focused.isDirectory ? path + "/" : path)
    }
}

// MARK: - Password prompt (CPasswordDialog for the worker thread, ExtractCallback.cpp:218)

extension PanelViewController: SZPasswordDelegate {

    /// COpenArchiveCallback::Open_CryptoGetTextPassword (OpenCallback.cpp:63-80): a fresh CFfpOpen
    /// asks for each archive level (Encrypted starts false, FileFolderPluginOpen.h); the answer is
    /// kept on that level by the bridge (`SZArchive.password`). The one exception is a level of the
    /// chain being left that is opened again (`reusablePassword`). The level whose item is being
    /// copied out pre-seeds its own password in the bridge, so this is not asked for it.
    func passwordForArchive(atPath path: String) -> String? {
        if let reused = reusablePassword(forArchivePath: path) { return reused }
        var result: String?
        let ask = { [self] in
            result = PasswordDialog.askPassword(forPath: path, parent: self.hostWindow)
        }
        if Thread.isMainThread { ask() } else { DispatchQueue.main.sync(execute: ask) }
        return result
    }
}
