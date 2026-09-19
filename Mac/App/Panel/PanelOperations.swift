// PanelOperations.swift -- the panel's file operations (PanelOperations.cpp, PanelCopy.cpp,
// PanelMenu.cpp Properties): delete to the Trash or permanently, in-place rename, create folder,
// create file, the comment editor, the Properties dialog, F3 on a folder (CalcItemFullSize) and
// the copy / move execution used by F5 / F6, the clipboard and drag & drop.
//
// Every engine call goes through the shared runner (Mac/docs/api/opsinfra.md): the panel queue is
// parked for the duration, so the folder is touched by exactly one thread.
//
// Parity: 01-fm-feature-inventory.md §3.10, §3.11; 01b §4.4, §4.11.

import Cocoa
import SevenZipKit

extension PanelViewController {

    // MARK: - Delete (PanelOperations.cpp:112-262)

    func deleteItems(toTrash: Bool) {
        guard let snap = snapshot else { return }
        guard snap.supportsOperations else { showUnsupportedOperation(); return }
        guard checkBeforeUpdate() else { return }
        let indices = operatedRowIndices()
        guard !indices.isEmpty else { return }
        let targets = indices.map { rows[$0] }
        // A file-system delete to the Trash is undoable, so 7zFM asks nothing there
        // (SHFileOperation FOF_ALLOWUNDO); everything else is confirmed (01 §3.11).
        if !(snap.isFileSystem && toTrash), !confirmDelete(targets) { return }

        let engineIndices = targets.map { NSNumber(value: $0.engineIndex) }
        let firstRow = indices.min() ?? 0
        var options = OperationRunner.Options(title: Lang.text(6106, "Deleting"))
        options.mainTitle = Lang.text(6107, "Error deleting file or folder")   // IDS_ERROR_DELETING
        options.initialStatus = .deleting
        let result = runFolderOperation(options) { folder, runner -> Bool in
            if let fs = folder as? SZFileSystemFolder {
                try fs.deleteItems(at: engineIndices, toTrash: toTrash, delegate: runner)
            } else {
                try folder.deleteItems(at: engineIndices, progress: runner)
            }
            return true
        }
        if case .success = result {
            refreshAfterOperation(focusRow: firstRow)
        } else {
            refreshAfterOperation(focusRow: firstRow)
        }
    }

    /// The confirmation of 01 §3.11: captions 6100 / 6101 / 6102, texts 6103 / 6104 / 6105.
    private func confirmDelete(_ targets: [PanelRow]) -> Bool {
        let alert = NSAlert()
        if targets.count == 1 {
            let row = targets[0]
            alert.messageText = row.isDirectory ? Lang.text(6101, "Confirm Folder Delete")
                                                : Lang.text(6100, "Confirm File Delete")
            let template = row.isDirectory
                ? Lang.get(6104, "Are you sure you want to delete the folder '{0}'?")
                : Lang.get(6103, "Are you sure you want to delete '{0}'?")
            alert.informativeText = Lang.format(template, row.name)
        } else {
            alert.messageText = Lang.text(6102, "Confirm Multiple File Delete")
            alert.informativeText = Lang.format(Lang.get(6105, "Are you sure you want to delete these {0} items?"),
                                               "\(targets.count)")
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: Lang.text(406, "Yes"))
        alert.addButton(withTitle: Lang.text(407, "No"))
        if let window = view.window {
            // A sheet cannot answer synchronously here, so the confirmation is app-modal, like
            // 7zFM's MessageBoxW.
            alert.window.appearance = window.appearance
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Rename (PanelOperations.cpp:478, in-place label editing)

    func renameFocusedItem() {
        guard let snap = snapshot, snap.supportsOperations else { showUnsupportedOperation(); return }
        guard checkBeforeUpdate() else { return }
        let index = focusedIndex
        guard index >= 0, index < rows.count, !rows[index].isParentRow else { return }
        guard listViewMode == 3 else {                        // icon modes: ask in a Combo dialog
            renameWithDialog(index)
            return
        }
        let identifier = NSUserInterfaceItemIdentifier(String(SZPropID.name.rawValue))
        let column = tableView.column(withIdentifier: identifier)
        guard column >= 0 else { renameWithDialog(index); return }
        tableView.scrollRowToVisible(index)
        guard let cell = tableView.view(atColumn: column, row: index, makeIfNecessary: true) as? NSTableCellView,
              let field = cell.textField else { renameWithDialog(index); return }
        renamingRow = index
        field.stringValue = rows[index].name
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.backgroundColor = .textBackgroundColor
        field.drawsBackground = true
        field.delegate = self
        view.window?.makeFirstResponder(field)
    }

    private func renameWithDialog(_ index: Int) {
        let old = rows[index].name
        guard let name = ComboDialog.run(title: Lang.text(545, "Rename"), label: Lang.text(1004, "Name"),
                                         value: old, strings: [], parent: view.window) else { return }
        performRename(index: index, to: name)
    }

    /// OnEndLabelEdit (PanelListNotify.cpp:549+): empty or unchanged is ignored, a relative path
    /// moves the item into a sub-folder (CorrectFsPath), errors report IDS_ERROR_RENAMING 6009.
    func performRename(index: Int, to newName: String) {
        guard index >= 0, index < rows.count else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let old = rows[index].name
        guard !trimmed.isEmpty, trimmed != old else { reload(); return }
        let last = (trimmed as NSString).lastPathComponent
        guard last != ".", last != ".." else {               // IsCorrectFsName
            showError(message: Lang.text(6009, "Error renaming file or folder"))
            return
        }
        let engineIndex = rows[index].engineIndex
        var options = OperationRunner.Options(title: Lang.text(6006, "Renaming"))
        options.mainTitle = Lang.text(6009, "Error renaming file or folder")
        options.initialStatus = .renaming
        let result = runFolderOperation(options) { folder, runner -> Bool in
            try folder.renameItem(at: engineIndex, to: trimmed, progress: runner)
            return true
        }
        if case .success = result {
            refreshAfterOperation(selectNames: [(trimmed as NSString).lastPathComponent])
        } else {
            reload()
        }
    }

    // MARK: - Create folder / file (PanelOperations.cpp:363-476)

    func createFolder() {
        guard let snap = snapshot, snap.supportsOperations else { showUnsupportedOperation(); return }
        guard checkBeforeUpdate() else { return }
        guard let name = ComboDialog.run(title: Lang.text(6300, "Create Folder"),
                                         label: Lang.text(6302, "Folder name:"),
                                         value: Lang.text(6304, "New Folder"),
                                         strings: [], parent: view.window),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var options = OperationRunner.Options(title: Lang.text(6300, "Create Folder"))
        options.mainTitle = Lang.text(6306, "Cannot create folder")     // IDS_CREATE_FOLDER_ERROR
        let result = runFolderOperation(options) { folder, runner -> Bool in
            try folder.createFolder(named: name, progress: runner)
            return true
        }
        if case .success = result {
            refreshAfterOperation(selectNames: [(name as NSString).lastPathComponent])
        }
    }

    func createFile() {
        guard let snap = snapshot, snap.supportsOperations else { showUnsupportedOperation(); return }
        guard checkBeforeUpdate() else { return }
        guard let name = ComboDialog.run(title: Lang.text(6301, "Create File"),
                                         label: Lang.text(6303, "File name:"),
                                         value: Lang.text(6305, "New File"),
                                         strings: [], parent: view.window),
              !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var options = OperationRunner.Options(title: Lang.text(6301, "Create File"))
        options.mainTitle = Lang.text(6307, "Cannot create file")       // IDS_CREATE_FILE_ERROR
        let result = runFolderOperation(options) { folder, runner -> Bool in
            try folder.createFile(named: name, progress: runner)
            return true
        }
        if case .success = result {
            refreshAfterOperation(selectNames: [(name as NSString).lastPathComponent])
        }
    }

    // MARK: - Comment (PanelOperations.cpp:487+, Ctrl+Z)

    func changeComment() {
        guard let snap = snapshot, snap.supportsOperations, !snap.isHashFolder else {
            showUnsupportedOperation()
            return
        }
        guard checkBeforeUpdate() else { return }
        let index = focusedIndex
        guard index >= 0, index < rows.count, !rows[index].isParentRow else { return }
        let engineIndex = rows[index].engineIndex
        let current = rows[index].cells[.comment] ?? ""
        guard let comment = CommentDialog.run(value: current, parent: view.window) else { return }
        var options = OperationRunner.Options(title: Lang.text(6400, "Comment"))
        options.mainTitle = Lang.text(6008, "The operation is not supported.")
        let result = runFolderOperation(options) { folder, runner -> Bool in
            try folder.setComment(comment, forItemAt: engineIndex, progress: runner)
            return true
        }
        if case .success = result { refreshAfterOperation() }
    }

    // MARK: - Calculate full size (F3 on a folder / Space, 01 §3.11)

    func calcFocusedItemSize() {
        let indices = operatedRowIndices()
        guard !indices.isEmpty else { return }
        let engineIndices = indices.map { NSNumber(value: rows[$0].engineIndex) }
        let names = indices.map { rows[$0].name }
        var options = OperationRunner.Options(title: Lang.text(7500, "Checksum"))
        options.initialStatus = .scanning
        options.mainTitle = "7-Zip"
        let result = runFolderOperation(options) { folder, runner -> Bool in
            if let fs = folder as? SZFileSystemFolder {
                for index in engineIndices {
                    try fs.calculateFullSize(at: index.intValue, delegate: runner)
                }
            } else {
                _ = try folder.calcSize(at: engineIndices, progress: runner)
            }
            return true
        }
        guard case .success = result else { return }
        refreshAfterOperation(selectNames: names)
    }

    // MARK: - Properties (PanelMenu.cpp:172-423, Alt+Enter / toolbar Info)

    func showProperties() {
        guard let snap = snapshot else { return }
        let indices = operatedRowIndices()
        let engineIndices = indices.map { rows[$0].engineIndex }
        let level = timestampLevel
        runOnQueue { [self] in
            guard let folder = self.folder else { return }
            let lines = PanelProperties.build(folder: folder, itemIndices: engineIndices,
                                              snapshot: snap, level: level)
            DispatchQueue.main.async {
                PropertiesDialog.show(lines: lines, parent: self.view.window)
            }
        }
    }

    // MARK: - Copy / move (PanelCopy.cpp:182-450)

    /// CopyTo: copy or move the operated items out of this folder into `destination`
    /// (a directory path; the bridge keeps the trailing "/" meaning "into this folder").
    @discardableResult
    func copyItemsOut(rowIndices: [Int], to destination: String, move: Bool) -> Bool {
        guard let snap = snapshot, snap.supportsOperations else { showUnsupportedOperation(); return false }
        if move, !checkBeforeUpdate() { return false }
        let engineIndices = rowIndices.map { NSNumber(value: rows[$0].engineIndex) }
        guard !engineIndices.isEmpty else { return false }
        var options = OperationRunner.Options(title: move ? Lang.text(6005, "Moving") : Lang.text(6004, "Copying"))
        options.initialStatus = move ? .moving : .copying
        options.titleFileName = snap.archivePath
        options.password = rememberedPassword
        let result = runFolderOperation(options) { folder, runner -> Bool in
            if move {
                try folder.moveItems(at: engineIndices, toPath: destination, progress: runner)
            } else {
                try folder.copyItems(at: engineIndices, toPath: destination, progress: runner)
            }
            return true
        }
        guard case .success = result else { return false }
        killSelection()
        refreshAfterOperation()
        return true
    }

    /// CopyFrom / CopyFromNoAsk: bring outside files into this folder (paste, drop, FS -> archive).
    @discardableResult
    func copyItemsIn(paths: [String], move: Bool) -> Bool {
        guard let snap = snapshot, snap.supportsOperations else { showUnsupportedOperation(); return false }
        guard checkBeforeUpdate() else { return false }
        guard !paths.isEmpty else { return false }
        // The bridge takes names relative to one folder (IFolderOperations::CopyFrom).
        var groups: [String: [String]] = [:]
        for path in paths {
            let folderPath = (path as NSString).deletingLastPathComponent + "/"
            groups[folderPath, default: []].append((path as NSString).lastPathComponent)
        }
        var options = OperationRunner.Options(title: move ? Lang.text(6005, "Moving") : Lang.text(6004, "Copying"))
        options.initialStatus = move ? .moving : .copying
        options.titleFileName = snap.archivePath
        options.password = rememberedPassword
        let result = runFolderOperation(options) { folder, runner -> Bool in
            for (source, names) in groups {
                try folder.copyItems(named: names, fromFolderPath: source, moveMode: move, progress: runner)
            }
            return true
        }
        guard case .success = result else { return false }
        refreshAfterOperation(selectNames: paths.map { ($0 as NSString).lastPathComponent })
        return true
    }

    /// The file-system copy the *target* panel performs for a drop from Finder (CopyFsItems).
    @discardableResult
    func copyFileSystemItems(paths: [String], toDirectory directory: String, move: Bool) -> Bool {
        guard !paths.isEmpty else { return false }
        var options = OperationRunner.Options(title: move ? Lang.text(6005, "Moving") : Lang.text(6004, "Copying"))
        options.initialStatus = move ? .moving : .copying
        options.parentWindow = view.window
        let result = OperationRunner.run(options) { runner -> Bool in
            try SZFileSystemFolder.copy(paths: paths, toDirectory: directory, move: move, delegate: runner)
            return true
        }
        guard case .success = result else { return false }
        refreshAfterOperation(selectNames: paths.map { ($0 as NSString).lastPathComponent })
        return true
    }

    // MARK: - Refresh after an operation

    /// RefreshListCtrl_SaveFocused: reload and restore focus by name, or by position when the
    /// items are gone (focus goes to the item after the deleted range, 01 §3.11).
    func refreshAfterOperation(selectNames: [String] = [], focusRow: Int? = nil) {
        let names = selectNames
        let fallbackRow = focusRow
        runOnQueue { [self] in
            guard let folder = self.folder else { return }
            do {
                try folder.loadItems()
                let snap = self.makeSnapshot(folder)
                DispatchQueue.main.async {
                    self.apply(snap, selectNames: names, focusName: names.first)
                    if names.isEmpty, let row = fallbackRow {
                        self.setFocus(min(max(0, row), max(0, self.rows.count - 1)))
                    }
                }
            } catch {
                DispatchQueue.main.async { self.showError(error) }
            }
        }
    }
}
