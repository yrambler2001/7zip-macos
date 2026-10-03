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
            var folderObject: SZFolder? = nil
            var failure: NSError? = nil
            do {
                folderObject = try SZFolder.folder(forPath: expanded, formatHint: formatHint,
                                                   passwordDelegate: self)
                if let folderObject, folderObject.supportsFlatMode {
                    let flat = folderObject.isArchive ? self.flatModeForArc : self.flatModeForDisk
                    if flat {
                        folderObject.flatMode = true
                        try folderObject.loadItems()
                    }
                }
            } catch let error as NSError {
                failure = error
                if fallbackToRoot { folderObject = SZRootFolder.makeRootFolder() }
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
                completion?(failure == nil)
            }
        }
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
                if row.isDirectory && !(row.isPackage && isFS && !insideOnly) {
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
                // try the file as an archive (CPanel::OpenItemAsArchive)
                do {
                    let archive = try SZArchiveOpener.openArchive(in: folder, itemIndex: engineIndex,
                                                                  formatHint: formatHint,
                                                                  passwordDelegate: self)
                    let root = try archive.rootFolder()
                    self.folder = root
                    if root.supportsFlatMode, self.flatModeForArc {
                        root.flatMode = true
                        try root.loadItems()
                    }
                    let snap = self.makeSnapshot(root)
                    DispatchQueue.main.async { self.apply(snap, selectNames: []) }
                } catch {
                    let code = (error as NSError).code
                    // Not an archive: start it externally -- straight from disk in a file-system
                    // folder, through a 7zO temp copy inside an archive (OpenItemInArchive with
                    // tryExternal, PanelItemOpen.cpp).
                    if !insideOnly && code == SZError.Code.notArchive.rawValue {
                        self.openExternally(row)
                    } else if code != SZError.Code.cancelled.rawValue {
                        throw error
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
        // (indent, path): the indent mirrors AddComboBoxItem's per-level indentation. The icons
        // Windows draws next to each entry have no NSComboBox equivalent (a plain string list).
        var entries: [(Int, String)] = []
        let current = currentPath
        if !current.isEmpty {
            var chain: [String] = [current]
            var path = current
            if path.hasSuffix("/") { path.removeLast() }
            while !path.isEmpty, path != "/" {
                path = (path as NSString).deletingLastPathComponent
                if path.isEmpty { break }
                chain.append(path == "/" ? "/" : path + "/")
                if path == "/" { break }
            }
            // the current path first, then its parents, indentation growing with the level
            let deepest = chain.count - 1
            entries.append((deepest, chain[0]))
            for (level, ancestor) in chain.dropFirst().enumerated().reversed() {
                entries.append((deepest - level - 1, ancestor))
            }
        }
        entries.append((0, NSHomeDirectory() + "/Documents/"))       // IDS_DOCUMENTS 7102
        entries.append((0, "/"))                                    // IDS_COMPUTER 7100
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil,
                                                        options: [.skipHiddenVolumes]) ?? [] {
            entries.append((1, url.path.hasSuffix("/") ? url.path : url.path + "/"))
        }
        for path in Settings.folderHistory.prefix(20) where !entries.contains(where: { $0.1 == path }) {
            entries.append((0, path))
        }
        pathCombo.removeAllItems()
        var seen = Set<String>()
        for (indent, path) in entries where !path.isEmpty && seen.insert(path).inserted {
            pathCombo.addItem(withObjectValue: String(repeating: "   ", count: max(0, indent)) + path)
        }
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

    func passwordForArchive(atPath path: String) -> String? {
        if let remembered = rememberedPassword { return remembered }
        var result: String?
        let ask = { [self] in
            result = PasswordDialog.askPassword(forPath: path, parent: self.view.window)
        }
        if Thread.isMainThread { ask() } else { DispatchQueue.main.sync(execute: ask) }
        if let result { rememberedPassword = result }      // CFolderLink remembers it
        return result
    }
}
