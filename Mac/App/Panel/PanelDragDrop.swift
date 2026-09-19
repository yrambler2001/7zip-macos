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

enum PanelDragDrop {

    /// Private type that identifies a drag started in one of our own panels
    /// ("7-Zip::SetTransfer" equivalent).
    static let internalType = NSPasteboard.PasteboardType("com.yrambler2001.7zip.panel-items")
    /// Marks a clipboard set by Cut (Windows 7zFM has no Cut; macOS expects one, 01 §9 #13).
    static let cutMarkerType = NSPasteboard.PasteboardType("com.yrambler2001.7zip.cut")

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
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(name)
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
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard let snap = snapshot, snap.supportsOperations, row < rows.count else { return nil }
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

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        let indices = rowIndexes.filter { $0 < rows.count && !rows[$0].isParentRow }
        PanelDragDrop.current = PanelDragDrop.Session(panel: self, rowIndices: indices,
                                                     isArchiveSource: snapshot?.isArchive ?? false,
                                                     tempDirectory: nil)
        session.draggingFormation = .list
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        PanelDragDrop.current = nil
        if operation == .move { refreshAfterOperation() }
    }

    /// CDropTarget::DragOver + GetEffect (PanelDrag.cpp:1927, :2066): a folder row under the
    /// cursor is the target sub-folder, otherwise the panel's folder; ".." and the source panel's
    /// own folder are refused. Option = copy, Command = move, otherwise move on the same volume.
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation)
    -> NSDragOperation {
        guard let snap = snapshot, snap.supportsOperations, !snap.chainIsReadOnly else { return [] }
        var targetRow = row
        if dropOperation == .above { targetRow = -1 }
        if targetRow >= 0, targetRow < rows.count, !rows[targetRow].isDirectory || rows[targetRow].isParentRow {
            targetRow = -1
        }
        if targetRow < 0 {
            tableView.setDropRow(-1, dropOperation: .on)
            if let session = PanelDragDrop.current, session.panel === self { return [] }
        } else {
            tableView.setDropRow(targetRow, dropOperation: .on)
        }
        return dropEffect(info: info, targetPath: dropTargetPath(row: targetRow))
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        var targetRow = row
        if dropOperation == .above { targetRow = -1 }
        if targetRow >= 0, targetRow < rows.count, !rows[targetRow].isDirectory || rows[targetRow].isParentRow {
            targetRow = -1
        }
        let target = dropTargetPath(row: targetRow)
        let effect = dropEffect(info: info, targetPath: target)
        let move = effect.contains(.move) && !(snapshot?.isArchive ?? false)
        return performDrop(info: info, targetRow: targetRow, targetPath: target, move: move)
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

    /// CDropTarget::Drop (PanelDrag.cpp:2400+).
    private func performDrop(info: NSDraggingInfo, targetRow: Int, targetPath: String, move: Bool) -> Bool {
        guard let snap = snapshot else { return false }
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
                guard !paths.isEmpty else { showUnsupportedOperation(); return false }
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
        let directory = url.deletingLastPathComponent().path
        DispatchQueue.main.async { [weak self] in
            guard let self else { completionHandler(nil); return }
            let ok = self.extractForPromise(engineIndex: index, toDirectory: directory)
            completionHandler(ok ? nil : SZErrors.error(with: .engine, message: "extraction failed"))
        }
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

    /// CopyTo of one item into the receiver's directory, with the shared progress dialog.
    func extractForPromise(engineIndex: Int, toDirectory directory: String) -> Bool {
        var options = OperationRunner.Options(title: Lang.text(6004, "Copying"))
        options.initialStatus = .extracting
        options.password = rememberedPassword
        let destination = directory.hasSuffix("/") ? directory : directory + "/"
        let result = runFolderOperation(options) { folder, runner -> Bool in
            try folder.copyItems(at: [NSNumber(value: engineIndex)], toPath: destination, progress: runner)
            return true
        }
        if case .success = result { return true }
        return false
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
