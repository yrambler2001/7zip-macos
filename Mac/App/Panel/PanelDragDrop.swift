// PanelDragDrop.swift -- drag & drop (PanelDrag.cpp) and the clipboard (PanelMenu.cpp:427-489).
//
// The Windows mechanism is two-phase: the source offers an HDROP of names that will exist and the
// files are extracted only when the target asks for them. macOS has the same shape:
// `NSFilePromiseProvider` for items inside an archive (extraction runs on the drop, into the
// receiver's directory or a 7zE temp folder) and plain file URLs for file-system items.
//
// Parity: 01-fm-feature-inventory.md §3.15, §3.16, §9 #12, #13; 03 §4.1, §4.2.

import Cocoa
import UniformTypeIdentifiers
import SevenZipKit

/// The answer of the Control-drag menu (NDragMenu's g_Pairs).
enum PanelDropChoice {
    case copy, move, addToArchive, cancel

    var tag: Int {
        switch self {
        case .copy: return 1
        case .move: return 2
        case .addToArchive: return 3
        case .cancel: return 4
        }
    }

    init(tag: Int) {
        switch tag {
        case 1: self = .copy
        case 2: self = .move
        case 3: self = .addToArchive
        default: self = .cancel
        }
    }
}

enum PanelDragDrop {

    /// Private type that identifies a drag started in one of our own panels
    /// ("7-Zip::SetTransfer" equivalent).
    ///
    /// Named after the **running** bundle identifier, not a literal: the general pasteboard is
    /// system-wide, so two copies of the app built with different identifiers would otherwise
    /// treat each other's copy and cut as their own (`Mac/docs/test-support-contract.md`, "Running
    /// several instances at once"). For the shipped identifier the strings are unchanged.
    static let internalType =
        NSPasteboard.PasteboardType("\(SevenZipBundle.runningAppIdentifier).panel-items")
    /// Marks a clipboard set by Cut (Windows 7zFM has no Cut; macOS expects one, 01 §9 #13).
    static let cutMarkerType =
        NSPasteboard.PasteboardType("\(SevenZipBundle.runningAppIdentifier).cut")

    static var acceptedTypes: [NSPasteboard.PasteboardType] { [.fileURL, internalType] }

    /// The drag in flight, so a drop into another panel knows who the source is.
    final class Session {
        weak var panel: PanelViewController?
        let rowIndices: [Int]
        let isArchiveSource: Bool
        let tempDirectory: String?
        init(panel: PanelViewController, rowIndices: [Int], isArchiveSource: Bool, tempDirectory: String?) {
            self.panel = panel
            self.rowIndices = rowIndices
            self.isArchiveSource = isArchiveSource
            self.tempDirectory = tempDirectory
        }
    }

    static var current: Session?

    static func pasteboardHasFileURLs() -> Bool {
        NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                          options: [.urlReadingFileURLsOnly: true])
    }

    /// <Temp>/7zE<8 hex>/ -- the drag & drop / copy temp folder (kTempDirPrefix "7zE").
    static func makeTempDirectory(prefix: String = "7zE") -> String? {
        let name = prefix + String(format: "%08X", UInt32.random(in: 0...UInt32.max))
        // Per-instance temp root, so two instances cannot see each other's 7zE folders
        // (Mac/docs/api/resetcmd.md section 3).
        let path = (TestSupport.temporaryDirectory as NSString).appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        } catch {
            return nil
        }
    }
}

// MARK: - Drag source and drop target

extension PanelViewController {

    /// LVN_BEGINDRAG -> OnDrag: FS items go as file URLs, archive items as file promises whose
    /// extraction is deferred to the drop (01 §3.15).
    @objc func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        dragPasteboardWriter(forRow: row)
    }

    @objc func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                         willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        dragSessionWillBegin(session, rowIndexes: rowIndexes)
    }

    @objc func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragSessionEnded(operation: operation)
    }

    /// CDropTarget::DragOver + GetEffect (PanelDrag.cpp:1927, :2066): a folder row under the
    /// cursor is the target sub-folder, otherwise the panel's folder; ".." and the source panel's
    /// own folder are refused. Option = copy, Command = move, otherwise move on the same volume.
    @objc func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                         proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation)
    -> NSDragOperation {
        let (targetRow, effect) = validateListDrop(info: info, proposedRow: dropOperation == .above ? -1 : row)
        tableView.setDropRow(targetRow, dropOperation: .on)
        return effect
    }

    @objc func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                         dropOperation: NSTableView.DropOperation) -> Bool {
        acceptListDrop(info: info, proposedRow: dropOperation == .above ? -1 : row)
    }

    // MARK: The list-widget-independent half (Details table and the icon / list modes alike)

    /// The pasteboard item for one dragged row, nil for ".." or a folder without IFolderOperations.
    func dragPasteboardWriter(forRow row: Int) -> NSPasteboardWriting? {
        guard let snap = snapshot, snap.supportsOperations, row >= 0, row < rows.count else { return nil }
        let item = rows[row]
        guard !item.isParentRow else { return nil }
        if !item.fullPath.isEmpty {
            return NSURL(fileURLWithPath: item.fullPath)
        }
        let type: UTType = item.isDirectory
            ? .folder
            : (UTType(filenameExtension: item.pathExtension) ?? .data)
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = ["name": item.name, "index": item.engineIndex]
        return provider
    }

    func dragSessionWillBegin(_ session: NSDraggingSession, rowIndexes: IndexSet) {
        let indices = rowIndexes.filter { $0 < rows.count && !rows[$0].isParentRow }
        PanelDragDrop.current = PanelDragDrop.Session(panel: self, rowIndices: indices,
                                                     isArchiveSource: snapshot?.isArchive ?? false,
                                                     tempDirectory: nil)
        session.draggingFormation = .list
    }

    func dragSessionEnded(operation: NSDragOperation) {
        PanelDragDrop.current = nil
        if operation == .move { refreshAfterOperation() }
    }

    /// The row a drop would go into (-1 = the panel's folder) and the effect. `proposedRow` is the
    /// row under the cursor, or -1 when the cursor is between rows / over the background.
    func validateListDrop(info: NSDraggingInfo, proposedRow: Int) -> (row: Int, effect: NSDragOperation) {
        guard let snap = snapshot, snap.supportsOperations, !snap.chainIsReadOnly else { return (-1, []) }
        let targetRow = dropTargetRow(proposedRow)
        if targetRow < 0, let session = PanelDragDrop.current, session.panel === self { return (-1, []) }
        return (targetRow, dropEffect(info: info, targetPath: dropTargetPath(row: targetRow)))
    }

    /// CDropTarget::Drop for a drop on the list.
    func acceptListDrop(info: NSDraggingInfo, proposedRow: Int) -> Bool {
        let targetRow = dropTargetRow(proposedRow)
        let target = dropTargetPath(row: targetRow)
        let effect = dropEffect(info: info, targetPath: target)
        let move = effect.contains(.move) && !(snapshot?.isArchive ?? false)
        return performDrop(info: info, targetRow: targetRow, targetPath: target, move: move)
    }

    /// Only a real folder row is a drop target; anything else means the panel's own folder.
    private func dropTargetRow(_ row: Int) -> Int {
        guard row >= 0, row < rows.count, rows[row].isDirectory, !rows[row].isParentRow else { return -1 }
        return row
    }

    /// Destination of a drop: the folder of the highlighted row, else this panel's folder.
    private func dropTargetPath(row: Int) -> String {
        guard let snap = snapshot else { return "" }
        if row >= 0, row < rows.count, rows[row].isDirectory, !rows[row].isParentRow {
            let item = rows[row]
            return item.fullPath.isEmpty ? snap.fullPath + item.name + "/" : item.fullPath + "/"
        }
        return snap.fullPath
    }

    private func dropEffect(info: NSDraggingInfo, targetPath: String) -> NSDragOperation {
        guard let snap = snapshot else { return [] }
        let mods = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if snap.isArchive { return .copy }                      // forced copy into an archive
        if mods.contains(.option) { return .copy }
        if mods.contains(.command) { return .move }
        // default: move inside one volume, copy across volumes (IsItSameDrive)
        if let session = PanelDragDrop.current, let source = session.panel {
            if source === self { return .move }
            if let a = source.snapshot, a.isFileSystem, snap.isFileSystem,
               volumeIdentifier(of: a.fullPath) == volumeIdentifier(of: targetPath) {
                return .move
            }
            return .copy
        }
        let sources = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                         options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if let first = sources.first, snap.isFileSystem,
           volumeIdentifier(of: first.path) == volumeIdentifier(of: targetPath) {
            return .move
        }
        return .copy
    }

    private func volumeIdentifier(of path: String) -> String {
        let url = URL(fileURLWithPath: path)
        if let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey]),
           let identifier = values.volumeIdentifier as? NSObject {
            return identifier.description
        }
        return "?"
    }

    /// NDragMenu (PanelDrag.cpp:340-385): the right-button drag menu. macOS drags have no right
    /// button, so it is offered on a Control-drag (01 §9 #12).
    private func askDragMenu(isArchiveTarget: Bool) -> PanelDropChoice {
        let menu = NSMenu()
        func add(_ title: String, _ choice: PanelDropChoice) {
            let item = NSMenuItem(title: title, action: #selector(dragMenuChoice(_:)), keyEquivalent: "")
            item.target = self
            item.tag = choice.tag
            menu.addItem(item)
        }
        add(Lang.text(6000, "Copy"), .copy)                              // k_Copy_Base
        add(Lang.text(6001, "Move"), .move)
        if isArchiveTarget { add(Lang.text(6002, "Copy to"), .copy) }    // k_Copy_ToArc
        add(Lang.text(2324, "Add to archive..."), .addToArchive)         // IDS_CONTEXT_COMPRESS
        menu.addItem(.separator())
        add(Lang.text(402, "Cancel"), .cancel)                           // k_Cancel
        dragMenuTag = PanelDropChoice.cancel.tag
        let location = view.window?.mouseLocationOutsideOfEventStream ?? .zero
        menu.popUp(positioning: nil, at: view.convert(location, from: nil), in: view)
        return PanelDropChoice(tag: dragMenuTag)
    }

    @objc private func dragMenuChoice(_ sender: Any?) {
        dragMenuTag = (sender as? NSMenuItem)?.tag ?? -1
    }

    /// CDropTarget::Drop (PanelDrag.cpp:2400+).
    private func performDrop(info: NSDraggingInfo, targetRow: Int, targetPath: String, move: Bool) -> Bool {
        guard let snap = snapshot else { return false }
        var move = move
        if NSEvent.modifierFlags.contains(.control) {
            switch askDragMenu(isArchiveTarget: snap.isArchive) {
            case .copy: move = false
            case .move: move = true
            case .addToArchive:
                return compressDroppedFiles(info: info)
            case .cancel: return false
            }
        }
        // A drop from one of our panels: the source does the work, because only it can extract
        // from its archive and show the progress (SendToSource_TargetPath_enable).
        if let session = PanelDragDrop.current, let source = session.panel, source !== self || targetRow >= 0 {
            if snap.isArchive {
                // into an archive: confirm, then CopyFrom on this panel
                guard confirmCopyToArchive() else { return false }
                let paths = session.rowIndices.compactMap { index -> String? in
                    let row = source.rows[index]
                    return row.fullPath.isEmpty ? nil : row.fullPath
                }
                if paths.isEmpty {
                    // archive -> archive (PROGRESS §4.7): the source extracts into a 7zE temp
                    // folder and this panel adds what landed there, as F5 does
                    // (CApp::OnCopy's two-archive case, 01 §3.10).
                    guard let temp = PanelDragDrop.makeTempDirectory() else { return false }
                    defer { try? FileManager.default.removeItem(atPath: temp) }
                    let rowIndices = session.rowIndices
                    guard source.copyItemsOut(rowIndices: rowIndices, to: temp + "/", move: false) else { return false }
                    let names = (try? FileManager.default.contentsOfDirectory(atPath: temp)) ?? []
                    let extracted = names.map { (temp as NSString).appendingPathComponent($0) }
                    guard !extracted.isEmpty, copyItemsIn(paths: extracted, move: false) else { return false }
                    if move { source.deleteItems(rowIndices: rowIndices, toTrash: false, confirm: false) }
                    return true
                }
                return copyItemsIn(paths: paths, move: move)
            }
            let ok = source.copyItemsOut(rowIndices: session.rowIndices, to: targetPath, move: move)
            if ok { refreshAfterOperation() }
            return ok
        }
        // A drop from Finder (or any other app): plain file URLs.
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let paths = urls.map { $0.path }
        guard !paths.isEmpty else { return false }
        if snap.isArchive {
            guard confirmCopyToArchive() else { return false }
            return copyItemsIn(paths: paths, move: move)
        }
        return copyFileSystemItems(paths: paths, toDirectory: targetPath, move: move)
    }

    /// IDS_CONFIRM_FILE_COPY 6010 / IDS_WANT_TO_COPY_FILES 6011.
    private func confirmCopyToArchive() -> Bool {
        let alert = NSAlert()
        alert.messageText = Lang.text(6010, "Confirm File Copy")
        alert.informativeText = Lang.text(6011, "Are you sure you want to copy files to archive")
        alert.alertStyle = .informational
        alert.addButton(withTitle: Lang.text(406, "Yes"))
        alert.addButton(withTitle: Lang.text(407, "No"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - File promises (lazy extraction on drop, 01 §3.15 / §4.7)

extension PanelViewController: NSFilePromiseProviderDelegate {

    /// The name Finder shows while the drag is in flight. `ArchiveDragOut.promisedNames`
    /// (extract api §5) is the same string read straight off the folder; the row's cached name
    /// is used instead because it was captured on the panel queue and the folder must not be
    /// touched from the main thread (panel api §1).
    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider,
                             fileNameForType fileType: String) -> String {
        (filePromiseProvider.userInfo as? [String: Any])?["name"] as? String ?? "item"
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                             completionHandler: @escaping (Error?) -> Void) {
        guard let info = filePromiseProvider.userInfo as? [String: Any],
              let index = info["index"] as? Int else {
            completionHandler(SZErrors.error(with: .invalidArgument, message: "no item"))
            return
        }
        // This runs on `promiseQueue`, off the main thread. Park the panel queue from *here*
        // (never from the main thread, which the extraction itself needs) so exactly one thread
        // touches the folder while ArchiveDragOut runs -- the ownership rule of
        // runFolderOperation / opsinfra api §1.
        let directory = url.deletingLastPathComponent().path
        var ok = false
        if Thread.isMainThread {
            ok = extractForPromise(engineIndex: index, toDirectory: directory)   // cannot park
        } else {
            let parked = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            runOnQueue { parked.signal(); release.wait() }
            parked.wait()
            DispatchQueue.main.sync { ok = self.extractForPromise(engineIndex: index, toDirectory: directory) }
            release.signal()
        }
        completionHandler(ok ? nil : SZErrors.error(with: .engine, message: "extraction failed"))
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        PanelViewController.promiseQueue
    }

    static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.yrambler2001.7zip.filePromise"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    /// `ArchiveDragOut.extract` (extract api §5) is the one lazy-extraction path for a drag-out:
    /// `kCurPaths` relative to the folder being dragged from (what `CAgentFolder::CopyTo` does
    /// for a drag, so a dragged directory keeps its subtree), the shared Progress dialog in
    /// WaitMode and the error reporting included. Main thread, with the panel queue parked by the
    /// caller above.
    /// `rememberedPassword` is what the panel was given when it opened this archive chain
    /// (CFolderLink, PanelNavigation.passwordForArchive); passing it means a drag out of an
    /// archive that is already unlocked does not raise a second prompt (Mac/docs/requests.md,
    /// `cleanup` -> `extract`).
    func extractForPromise(engineIndex: Int, toDirectory directory: String) -> Bool {
        guard let folder = currentFolderForContext() else { return false }
        let destination = directory.hasSuffix("/") ? directory : directory + "/"
        return ArchiveDragOut.extract(indices: [engineIndex], from: folder, to: destination,
                                      archiveDisplayPath: currentPath,
                                      parentWindow: view.window,
                                      overwriteMode: .overwrite,
                                      password: rememberedPassword) != nil
    }
}

// MARK: - "Add to archive..." from a drop (CompressDropFiles, PanelDrag.cpp:2817-2981)

extension PanelViewController {

    /// The dropped names -- not the panel's selection -- are handed to the `compress` scope's
    /// "Add to archive..." with the dialog (`CompressFiles(destPath, CreateArchiveName(names), "",
    /// names, email = false, showDialog = true)`).
    func compressDroppedFiles(info: NSDraggingInfo) -> Bool {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                      options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let context = dropCompressContext(paths: urls.map { $0.path }) else { return false }
        CompressCommands.addToArchive(context: context, showDialog: true, email: false)
        return true
    }

    /// The `OperationContext` of a background drop: the dropped paths as the operated items and the
    /// archive's folder as `folderPath`. That folder is the dropped files' own folder, except that
    /// names living in a 7zE / 7zO temp folder must not be archived into temp, so the destination
    /// becomes this panel's folder (AreThereNamesFromTemp, PanelDrag.cpp:2794) -- or the home
    /// folder when the panel does not show a file-system folder.
    func dropCompressContext(paths: [String]) -> OperationContext? {
        guard !paths.isEmpty, let folder = currentFolderForContext() else { return nil }
        let temp = TestSupport.temporaryDirectory
        var destination: String
        if paths.contains(where: { $0.hasPrefix(temp) }) {
            destination = (snapshot?.isFileSystem ?? false) ? (snapshot?.fullPath ?? "") : NSHomeDirectory()
        } else {
            destination = (paths[0] as NSString).deletingLastPathComponent
        }
        if !destination.hasSuffix("/") { destination += "/" }
        return OperationContext(folder: folder,
                                displayPath: destination,
                                isArchive: false,
                                isFileSystem: true,
                                indices: [],
                                names: paths.map { ($0 as NSString).lastPathComponent },
                                paths: paths,
                                folderPath: destination,
                                otherPanelPath: nil,
                                window: hostWindow)
    }
}

// MARK: - Clipboard (EditCopy / EditCut / EditPaste, 01 §3.16)

extension PanelViewController {

    /// EditCopy: the selected item *names* as text lines, plus file URLs for file-system items so
    /// Finder can paste them (01 §3.16, §9 #13).
    @objc func copy(_ sender: Any?) {
        let items = operatedRowIndices().map { rows[$0] }
        guard !items.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let urls = items.filter { !$0.fullPath.isEmpty }.map { NSURL(fileURLWithPath: $0.fullPath) }
        if !urls.isEmpty { pasteboard.writeObjects(urls) }
        pasteboard.setString(items.map { $0.name }.joined(separator: "\n"), forType: .string)
    }

    /// EditCut is a no-op on Windows; here it marks the clipboard so Paste moves.
    @objc func cut(_ sender: Any?) {
        copy(sender)
        NSPasteboard.general.setString("1", forType: PanelDragDrop.cutMarkerType)
    }

    /// EditPaste = CopyFromNoAsk of the pasteboard's file URLs (01 §3.16 macOS variant).
    @objc func paste(_ sender: Any?) {
        guard let snap = snapshot, snap.supportsOperations, checkBeforeUpdate() else { return }
        let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self],
                                                    options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let paths = urls.map { $0.path }
        guard !paths.isEmpty else { return }
        let move = NSPasteboard.general.string(forType: PanelDragDrop.cutMarkerType) == "1"
        if snap.isArchive {
            guard confirmCopyToArchive() else { return }
            _ = copyItemsIn(paths: paths, move: move)
        } else {
            _ = copyFileSystemItems(paths: paths, toDirectory: snap.fullPath, move: move)
        }
        if move { NSPasteboard.general.clearContents() }
    }
}
