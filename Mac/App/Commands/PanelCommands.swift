// PanelCommands.swift -- CApp::OnCopy (App.cpp:565-856): F5 / F6, the toolbar Copy / Move buttons
// and File > Copy To... / Move To..., plus the frozen OperationContext provider the command scopes
// read (Mac/App/Support/OperationContext.swift).
//
// Parity: 01-fm-feature-inventory.md §3.10, 01b §4.5.

import Cocoa
import SevenZipKit

extension MainWindowController {

    // MARK: - Copy / Move (F5 / F6)

    /// OnCopy(move, copyToSame, srcPanelIndex).
    func performCopyOrMove(move: Bool, copyToSame: Bool) {
        let source = focusedPanel
        guard let sourceSnapshot = source.snapshot else { return }
        let rowIndices = source.operatedRowIndices()
        guard !rowIndices.isEmpty else { return }
        guard sourceSnapshot.supportsOperations else {
            source.showUnsupportedOperation()
            return
        }
        if move, sourceSnapshot.chainIsReadOnly {
            source.showUnsupportedOperation()                       // CheckBeforeUpdate
            return
        }
        let destinationPanel = otherPanel(of: source)
        let destinationSnapshot = (numPanels == 2 && !copyToSame) ? destinationPanel?.snapshot : nil

        // Destination proposal (01 §3.10 step 3).
        let proposal: String
        if copyToSame {
            proposal = sourceSnapshot.fullPath
        } else if let destinationSnapshot {
            proposal = destinationSnapshot.fullPath
        } else {
            proposal = sourceSnapshot.fullPath
        }
        let info = PanelFormat.itemsInfo(rows: rowIndices.map { source.rows[$0] }, folderPrefix: sourceSnapshot.fullPath)
        guard let typed = CopyMoveDialog.run(move: move, value: proposal, history: Settings.copyHistory,
                                             info: info, parent: window) else { return }
        var destination = typed.trimmingCharacters(in: .whitespaces)
        guard !destination.isEmpty else { return }

        // FS -> archive: the destination is the other panel's archive folder, so the *target*
        // panel re-packs (IFolderOperations::CopyFrom).
        if let destinationSnapshot, destinationSnapshot.isArchive, destination == destinationSnapshot.fullPath,
           let destinationPanel {
            let paths = rowIndices.map { source.rows[$0] }.compactMap { $0.fullPath.isEmpty ? nil : $0.fullPath }
            guard paths.count == rowIndices.count else {
                copyArchiveToArchive(source: source, rowIndices: rowIndices, destination: destinationPanel, move: move)
                return
            }
            if destinationPanel.copyItemsIn(paths: paths, move: move) {
                Settings.addToCopyHistory(destination)
                if move { source.refreshAfterOperation() }
                source.killSelection()
            }
            return
        }

        destination = (destination as NSString).expandingTildeInPath
        if !(destination as NSString).isAbsolutePath {
            // relative paths are resolved against the source file-system folder
            let base = sourceSnapshot.isFileSystem ? sourceSnapshot.fullPath : sourceSnapshot.fileSystemPath
            destination = (base as NSString).appendingPathComponent(destination)
        }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        let exists = manager.fileExists(atPath: destination, isDirectory: &isDirectory)
        var finalPath = destination
        if exists && isDirectory.boolValue {
            finalPath = destination.hasSuffix("/") ? destination : destination + "/"
        } else if exists {
            // an existing file: only a single item may be copied onto it
            if rowIndices.count != 1 {
                source.showError(message: Lang.text(6008, "The operation is not supported."))
                return
            }
        } else {
            let parent = (destination as NSString).deletingLastPathComponent
            let single = rowIndices.count == 1
            if manager.fileExists(atPath: parent) && single && !destination.hasSuffix("/") {
                finalPath = destination                              // rename-on-copy
            } else {
                do {
                    try manager.createDirectory(atPath: destination, withIntermediateDirectories: true)
                } catch {
                    source.showError(error)
                    return
                }
                finalPath = destination.hasSuffix("/") ? destination : destination + "/"
            }
        }
        // App.cpp:663-668: the destination is the folder the items are in. Compared the way the
        // volume compares names (01 §9 #24): without case unless the volume tells case apart.
        if sourceSnapshot.isFileSystem, finalPath.hasSuffix("/"),
           Self.samePath(finalPath, sourceSnapshot.fullPath) {
            source.showError(message: "Cannot copy files onto itself")    // not a lang string on Windows
            return
        }
        if source.copyItemsOut(rowIndices: rowIndices, to: finalPath, move: move) {
            Settings.addToCopyHistory(finalPath)
            destinationPanel?.refreshAfterOperation()
            if numPanels == 1 { source.refreshAfterOperation() }
        }
    }

    /// Archive -> archive: extract into a 7zE temp folder, add from there, remove the temp folder
    /// (01 §3.10 step 6).
    private func copyArchiveToArchive(source: PanelViewController, rowIndices: [Int],
                                      destination: PanelViewController, move: Bool) {
        guard let temp = PanelDragDrop.makeTempDirectory() else { return }
        defer { try? FileManager.default.removeItem(atPath: temp) }
        guard source.copyItemsOut(rowIndices: rowIndices, to: temp + "/", move: false) else { return }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: temp)) ?? []
        let paths = names.map { (temp as NSString).appendingPathComponent($0) }
        guard destination.copyItemsIn(paths: paths, move: false) else { return }
        if move {
            // copyItemsOut killed the selection, so the rows captured before the copy are used.
            source.deleteItems(rowIndices: rowIndices, toTrash: false, confirm: false)
        }
    }

    /// CompareFileNames(a, b) == 0 for two file-system folder paths, on the volume of `b`.
    static func samePath(_ a: String, _ b: String) -> Bool {
        let x = a.hasSuffix("/") ? a : a + "/"
        let y = b.hasSuffix("/") ? b : b + "/"
        if SZFolder.volumeIsCaseSensitive(atPath: b) { return x == y }
        return x.compare(y, options: .caseInsensitive) == .orderedSame
    }

    func otherPanel(of panel: PanelViewController) -> PanelViewController? {
        guard numPanels == 2 else { return nil }
        return panels.first { $0 !== panel }
    }

    // MARK: - Menu commands owned by the window (both panels are needed)

    @objc func fileCopyTo(_ sender: Any?) { performCopyOrMove(move: false, copyToSame: false) }   // IDM_COPY_TO 546
    @objc func fileMoveTo(_ sender: Any?) { performCopyOrMove(move: true, copyToSame: false) }    // IDM_MOVE_TO 547
}

// MARK: - The frozen OperationContext contract (Mac/App/Support/OperationContext.swift)

extension MainWindowController: OperationContextProviding {

    func currentOperationContext() -> OperationContext? {
        focusedPanel.operationContext(rowIndices: focusedPanel.operatedRowIndices())
    }

    func refreshAfterOperation() {
        focusedPanel.refreshAfterOperation()
    }

    func refreshAllPanels() {
        for panel in panels { panel.refreshAfterOperation() }
    }
}

extension PanelViewController {

    /// The frozen `OperationContext` for an explicit set of this panel's rows. `ActiveContext`
    /// hands commands the focused panel's operated items; the panel uses this when it has to
    /// name the rows itself -- Open Outside of several archive members, one at a time.
    func operationContext(rowIndices: [Int]) -> OperationContext? {
        guard let snapshot, let folder = currentFolderForContext() else { return nil }
        let picked = rowIndices.filter { $0 >= 0 && $0 < rows.count }.map { rows[$0] }
        let window = hostWindow
        let controller = window?.windowController as? MainWindowController
        return OperationContext(folder: folder,
                                displayPath: snapshot.fullPath,
                                isArchive: snapshot.isArchive,
                                isFileSystem: snapshot.isFileSystem,
                                indices: picked.map { $0.engineIndex },
                                names: picked.map { $0.name },
                                paths: snapshot.isFileSystem ? picked.map { $0.fullPath } : [],
                                folderPath: snapshot.isFileSystem ? snapshot.fullPath : "",
                                otherPanelPath: controller?.otherPanel(of: self)?.snapshot?.fullPath,
                                window: window)
    }
}
