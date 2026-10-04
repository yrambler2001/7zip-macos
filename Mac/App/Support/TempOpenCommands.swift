// TempOpenCommands.swift -- the View / Edit / Open Outside / Diff commands and the
// lazy-extraction hook the `panel` scope uses for dragging archive members out to Finder.
//
// Windows equivalents (01-fm-feature-inventory.md §3.8, §3.11, §3.15; PROGRESS.md §4.6, §4.7):
//   IDM_FILE_VIEW 543 / IDM_FILE_EDIT 544  CPanel::EditItem(useEditor) (PanelItems.cpp:1043-1082)
//   IDM_OPEN_OUTSIDE 542                   CPanel::OpenFolderExternal / OpenItemOutside
//   IDM_DIFF 554                           CApp::DiffFiles (PanelItemOpen.cpp:747-815)
//   drag-out                               CPanel::OnDrag's deferred HDROP (PanelDrag.cpp:630)

import AppKit
import SevenZipKit

enum ItemOpenCommands {

    // MARK: - View (F3) / Edit (F4)

    /// EditItem(useEditor): a file-system file goes straight to the Viewer / Editor; an item
    /// inside an archive goes through the temp folder (OpenItemInArchive with editMode).
    static func open(useEditor: Bool) {
        guard let context = ActiveContext.current() else { return }
        guard let index = context.indices.first, let name = context.names.first else { return }

        if context.isFileSystem {
            guard let path = context.paths.first else { return }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                // F3 on a folder is the panel's CalcItemFullSize command, not an open.
                NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                return
            }
            if !start([path], useEditor: useEditor, checkName: name, parent: context.window) {
                cannotStartEditor(parent: context.window)
            }
            return
        }
        guard context.isArchive else { return }
        openInsideArchive(context: context, index: index, name: name, editMode: useEditor)
    }

    /// IDM_OPEN_OUTSIDE 542: hand the item to the system default application. A folder inside an
    /// archive is extracted to a temp folder first and the folder itself is revealed
    /// (OpenFolderExternal, PanelItemOpen.cpp:835).
    static func openOutside() {
        guard let context = ActiveContext.current() else { return }
        openOutside(context: context)
    }

    /// Open Outside for the first item of an explicit context -- the panel builds one per
    /// operated row (OpenSelectedItems(false) opens every one, PanelItems.cpp:1096-1136).
    static func openOutside(context: OperationContext) {
        guard let index = context.indices.first, let name = context.names.first else { return }

        if context.isFileSystem {
            guard let path = context.paths.first else { return }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                NSWorkspace.shared.open(URL(fileURLWithPath: path))   // -> Finder
                return
            }
            if SuspiciousName.looksDangerous(name),
               !SuspiciousName.confirm(name, parent: context.window) { return }
            ExternalTool.openWithSystemDefault([URL(fileURLWithPath: path)])
            return
        }
        guard context.isArchive else { return }
        openInsideArchive(context: context, index: index, name: name, editMode: false,
                          useSystemDefault: true)
    }

    // MARK: - Diff

    /// CApp::DiffFiles: needs a Diff tool and two items. Items inside an archive are extracted to
    /// temp first (with `tryExternal = false`, i.e. only their paths are used).
    static func diff() {
        guard let context = ActiveContext.current() else { return }
        guard !Settings.diffPath.isEmpty else { return }       // IDM_DIFF is hidden without it
        guard context.indices.count == 2 else {
            showError(Lang.text(3015, "Select files"), parent: context.window)
            return
        }
        if context.isFileSystem {
            guard context.paths.count == 2 else { return }
            if !ExternalTool.open(context.paths, with: .diff) { cannotStartEditor(parent: context.window) }
            return
        }
        guard context.isArchive else { return }

        // Both items into one temp folder pair, then run the tool on the two paths.
        var extracted: [SZTempFile] = []
        for index in context.indices {
            guard let file = extractToTemp(context: context, index: index, editMode: false) else {
                for file in extracted { SZTempOpen.removeTemporaryDirectory(atPath: file.directoryPath) }
                return
            }
            extracted.append(file)
        }
        if !ExternalTool.open(extracted.map(\.filePath), with: .diff) {
            cannotStartEditor(parent: context.window)
        }
        // The diff tool only reads the files; 7zFM keeps the temp folders until the app quits, so
        // the sessions are tracked without a write-back offer.
        let displayPath = context.displayPath
        for file in extracted {
            let session = TempOpenSession(tempFile: file, folder: context.folder,
                                          archiveIsReadOnly: true, displayPath: displayPath,
                                          window: context.window)
            TempOpenManager.shared.track(session)
            session.startWatching(launchedApplication: nil)
        }
    }

    /// CApp::DiffFiles(path1, path2): run the configured Diff tool on two file-system paths,
    /// IDS_CANNOT_START_EDITOR 3011 when it does not start. Nothing happens without a Diff tool
    /// (ReadRegDiff empty), which is also when IDM_DIFF is hidden.
    static func diff(paths: [String], parent: NSWindow?) {
        guard !Settings.diffPath.isEmpty, paths.count == 2 else { return }
        if !ExternalTool.open(paths, with: .diff) { cannotStartEditor(parent: parent) }
    }

    // MARK: - inside an archive

    private static func openInsideArchive(context: OperationContext, index: Int, name: String,
                                          editMode: Bool, useSystemDefault: Bool = false) {
        // Step 3: a read-only archive cannot take an edit back, so warn before starting.
        if editMode, context.folder.isReadOnly {
            WinMessageBox.run(Lang.format(Lang.text(3010, "Cannot update file '{0}'"), name),
                              icon: .error, owner: context.window)
        }
        guard let file = extractToTemp(context: context, index: index, editMode: editMode) else { return }

        if file.isDirectory {
            // OpenFolderExternal: show the extracted subtree in Finder.
            NSWorkspace.shared.open(URL(fileURLWithPath: file.filePath))
            trackSession(file: file, context: context, application: nil)
            return
        }
        if SuspiciousName.looksDangerous(name), !SuspiciousName.confirm(name, parent: context.window) {
            SZTempOpen.removeTemporaryDirectory(atPath: file.directoryPath)
            return
        }

        let started: Bool
        if useSystemDefault {
            started = ExternalTool.openWithSystemDefault([URL(fileURLWithPath: file.filePath)]) { app in
                trackSession(file: file, context: context, application: app)
            }
        } else {
            started = start([file.filePath], useEditor: editMode, checkName: nil,
                            parent: context.window) { app in
                trackSession(file: file, context: context, application: app)
            }
        }
        if !started {
            SZTempOpen.removeTemporaryDirectory(atPath: file.directoryPath)
            cannotStartEditor(parent: context.window)
        }
    }

    private static func trackSession(file: SZTempFile, context: OperationContext,
                                     application: NSRunningApplication?) {
        let session = TempOpenSession(tempFile: file, folder: context.folder,
                                      archiveIsReadOnly: context.folder.isReadOnly,
                                      displayPath: context.displayPath, window: context.window)
        TempOpenManager.shared.track(session)
        session.startWatching(launchedApplication: application)
    }

    /// Step 2 of OpenItemInArchive, under the Progress dialog (WaitMode: no dialog for a small
    /// item that finishes in under 500 ms).
    private static func extractToTemp(context: OperationContext, index: Int, editMode: Bool) -> SZTempFile? {
        var runnerOptions = OperationRunner.Options(title: Lang.text(3300, "Extracting"))
        runnerOptions.initialStatus = .extracting
        runnerOptions.parentWindow = context.window
        runnerOptions.titleFileName = context.displayPath

        let folder = context.folder
        let archivePath = ExtractCommands.realFileSystemPath(context.displayPath)
        // WriteZone: an item opened from an archive is treated as mode kAll on Windows
        // (PanelItemOpen.cpp writes the Zone.Identifier for opened items), so the archive's
        // quarantine attribute is propagated unless the user turned the option off.
        let zoneMode: SZZoneIDMode = Settings.writeZoneIdExtract == 0 ? .none : .all

        runnerOptions.password = folder.archive?.password        // fl.Password of this level
        let parking = PanelViewController.parkPanels(showing: folder)
        defer { parking.release() }
        let result = OperationRunner.run(runnerOptions) { runner -> SZTempFile in
            parking.waitUntilParked()
            defer { PanelViewController.rememberPassword(of: runner, in: folder) }
            let levels = folder.arcProps?.levelCount ?? 1
            return try SZTempOpen.extractItem(at: index, of: folder, archiveFilePath: archivePath,
                                              archiveLevelCount: levels, zoneMode: zoneMode,
                                              progress: runner)
        }
        switch result {
        case .success(let file): return file
        case .failure: return nil          // cancelled silently, or the runner showed the alert
        }
    }

    // MARK: - helpers

    private static func start(_ paths: [String], useEditor: Bool, checkName: String?,
                              parent: NSWindow?,
                              completion: ((NSRunningApplication?) -> Void)? = nil) -> Bool {
        if let name = checkName, SuspiciousName.looksDangerous(name),
           !SuspiciousName.confirm(name, parent: parent) {
            return true                     // the user said no; nothing failed
        }
        return ExternalTool.open(paths, with: useEditor ? .editor : .viewer, completion: completion)
    }

    private static func cannotStartEditor(parent: NSWindow?) {
        showError(Lang.text(3011, "Cannot start editor"), parent: parent)
    }

    /// IDS_CANNOT_START_EDITOR: "7-Zip", MB_OK | MB_ICONSTOP (PanelItemOpen.cpp:742).
    private static func showError(_ text: String, parent: NSWindow?) {
        WinMessageBox.run(text, icon: .error, owner: parent)
    }
}

// MARK: - the lazy-extraction hook for the panel scope (drag-out to Finder)

/// What `panel` needs for `NSFilePromiseProvider` and for a plain drag of archive members to
/// Finder (01 §3.15, 03 §4.1, PROGRESS.md §4.7): extraction is deferred until the drop, then the
/// items are written either straight into the destination Finder supplies, or into a `7zE` temp
/// folder whose paths are handed over.
///
/// Documented for the panel scope in `Mac/docs/api/extract.md`.
enum ArchiveDragOut {

    /// One promised / dropped item.
    struct Item {
        /// Index in the source archive folder.
        let index: Int
        /// The name the receiver sees (the archive item's name).
        let name: String
    }

    /// Extracts `indices` of `folder` into `directory`, keeping the paths relative to the source
    /// folder (`kCurPaths`, which is what `CAgentFolder::CopyTo` uses for a drag). Blocking work
    /// runs on the Progress dialog's worker thread.
    ///
    /// - Parameters:
    ///   - directory: the destination. Pass nil to get a fresh `7zE<hex>` temp folder, which the
    ///     caller must remove with `removeTemporaryDirectory(_:)` once the receiver is done.
    ///   - showsProgress: false keeps the Progress dialog hidden for a run that finishes in under
    ///     500 ms (WaitMode), which is what a drag of a few small files does.
    ///   - password: the password the caller has already been given for this archive chain
    ///     (7zFM remembers it per `CFolderLink`), so dragging out of an archive the panel has
    ///     unlocked does not ask a second time. nil = ask if the engine needs one.
    /// - Returns: the destination directory and the extracted top-level paths, or nil when the
    ///   user cancelled (the runner has already reported any error).
    @discardableResult
    static func extract(indices: [Int], from folder: SZFolder, to directory: String? = nil,
                        archiveDisplayPath: String = "", parentWindow: NSWindow? = nil,
                        overwriteMode: SZOverwriteMode = .overwrite,
                        password: String? = nil)
        -> (directory: String, paths: [String])? {

        let destination: String
        if let directory {
            destination = directory
        } else {
            guard let temp = try? SZTempOpen.createTemporaryDirectory(
                prefix: SZTempOpen.extractDirectoryPrefix) else { return nil }
            destination = temp
        }

        let names = indices.map { folder.nameOfItem(at: $0) }

        var runnerOptions = OperationRunner.Options(title: Lang.text(6004, "Copying..."))
        runnerOptions.initialStatus = .extracting
        runnerOptions.parentWindow = parentWindow
        runnerOptions.titleFileName = archiveDisplayPath
        runnerOptions.password = password       // PasswordIsDefined: the runner answers without asking
        let numbers = indices.map { NSNumber(value: $0) }
        let result = OperationRunner.run(runnerOptions) { runner -> SZOperationSummary in
            try folder.extractItems(at: numbers, toPath: destination, pathMode: .curPaths,
                                    overwriteMode: overwriteMode, testMode: false, progress: runner)
        }
        switch result {
        case .success:
            return (destination, names.map { (destination as NSString).appendingPathComponent($0) })
        case .failure:
            if directory == nil { SZTempOpen.removeTemporaryDirectory(atPath: destination) }
            return nil
        }
    }

    /// The paths a promise provider must report *before* anything is extracted, so Finder can
    /// show them while the drag is in flight.
    static func promisedNames(indices: [Int], from folder: SZFolder) -> [String] {
        indices.map { folder.nameOfItem(at: $0) }
    }

    /// Removes a `7zE` folder handed out by `extract(indices:from:to:)`.
    static func removeTemporaryDirectory(_ path: String) {
        SZTempOpen.removeTemporaryDirectory(atPath: path)
    }
}

// MARK: - menu selectors

extension MainWindowController {

    /// IDM_FILE_VIEW 543 (F3).
    @objc func fileView(_ sender: Any?) { ItemOpenCommands.open(useEditor: false) }

    /// IDM_FILE_EDIT 544 (F4).
    @objc func fileEdit(_ sender: Any?) { ItemOpenCommands.open(useEditor: true) }

    /// IDM_DIFF 554. One item selected in each of two panels compares the two (CApp::DiffFiles,
    /// PanelItemOpen.cpp:766-788); `diffRequest()` is the panel scope's half of that rule
    /// (Mac/App/Commands/PanelContextActions.swift). Everything else is the single-panel path.
    @objc func fileDiff(_ sender: Any?) {
        switch diffRequest() {
        case .singlePanel:
            ItemOpenCommands.diff()
        case .unsupported:
            focusedPanel.showUnsupportedOperation()
        case .paths(let first, let second):
            ItemOpenCommands.diff(paths: [first, second], parent: window)
        }
    }
}
