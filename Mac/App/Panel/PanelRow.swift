// PanelRow.swift -- one list row, built on the panel queue from an SZFolder item and read on
// the main thread. Cell texts are rendered once per load (SetItemText equivalent,
// 01 §3.12). Foundation + SevenZipKit only: this file is also compiled into the unit-test
// target, so it must not import AppKit.

import Foundation
import SevenZipKit

struct PanelRow {
    /// Index in the SZFolder, or -1 for the ".." row (kParentIndex).
    let engineIndex: Int
    let name: String
    let displayName: String
    let isDirectory: Bool
    let size: UInt64
    /// kpidPrefix in flat view ("" otherwise); the third sort key (01 §3.3).
    let prefix: String
    /// kpidIsDeleted: such rows are drawn in red (01 §3.6).
    let isDeleted: Bool
    /// True for a bundle/package directory: shown with a document icon (fsfolder api §4).
    let isPackage: Bool
    /// Absolute file-system path, "" inside an archive.
    let fullPath: String
    /// Cell text per column PROPID.
    let cells: [SZPropID: String]
    /// Typed sort keys per PROPID (NSNumber / Date / String).
    let sortKeys: [SZPropID: Any]

    init(engineIndex: Int, name: String, displayName: String, isDirectory: Bool, size: UInt64,
         prefix: String = "", isDeleted: Bool = false, isPackage: Bool = false, fullPath: String = "",
         cells: [SZPropID: String] = [:], sortKeys: [SZPropID: Any] = [:]) {
        self.engineIndex = engineIndex
        self.name = name
        self.displayName = displayName
        self.isDirectory = isDirectory
        self.size = size
        self.prefix = prefix
        self.isDeleted = isDeleted
        self.isPackage = isPackage
        self.fullPath = fullPath
        self.cells = cells
        self.sortKeys = sortKeys
    }

    static let parent = PanelRow(engineIndex: -1, name: "..", displayName: "..", isDirectory: true, size: 0)

    var isParentRow: Bool { engineIndex < 0 }

    /// Extension used by "Select by type" and the kpidExtension sort (no leading dot).
    var pathExtension: String { (name as NSString).pathExtension }
}

/// The sort the rows of a snapshot were built with.
struct PanelSortParams: Equatable {
    var sortID: SZPropID = .name
    var ascending = true
    var flatMode = false
}

/// The panel's sort parameters, read on the panel queue while the main thread may change them.
final class PanelSortState {
    private let lock = NSLock()
    private var params = PanelSortParams()

    var value: PanelSortParams {
        lock.lock(); defer { lock.unlock() }
        return params
    }

    func set(_ new: PanelSortParams) {
        lock.lock(); params = new; lock.unlock()
    }
}

/// Snapshot of a loaded folder handed from the panel queue to the main thread.
struct PanelSnapshot {
    let fullPath: String
    /// File-system directory to persist as PanelPath: the folder itself, or for archive folders
    /// the directory of the outermost archive (CApp::Save uses _parentFolders[0].ParentFolderPath).
    let fileSystemPath: String
    /// Folder type ID used as the column-layout key: "FSFolder", "FSDrives", "RootFolder",
    /// "7-Zip.<type>" (01b §5.3).
    let folderType: String
    let isRoot: Bool
    let isArchive: Bool
    let isFileSystem: Bool
    let isReadOnly: Bool
    /// kpidIsHash on the folder: a hash folder disables most File-menu commands (01 §2.1).
    let isHashFolder: Bool
    /// True when any folder of the chain is read-only (CheckBeforeUpdate, 01 §2.8).
    let chainIsReadOnly: Bool
    let columns: [SZPropertyInfo]
    let rows: [PanelRow]
    let supportsFlatMode: Bool
    let supportsOperations: Bool
    let supportsChangeNotification: Bool
    /// Path of the outermost archive file, "" when the panel is not inside an archive.
    let archivePath: String
    /// The volumes list (folder type "FSDrives").
    let isVolumesFolder: Bool
    /// PROPIDs hidden by default for this folder type (GetColumnVisible, 01 §3.2).
    let hiddenByDefault: Set<UInt32>
    /// True when the folder implements IFolderCompare (archive folders do), so the rows were
    /// sorted on the panel queue with the folder's own comparison (01 §3.3).
    let supportsCompare: Bool
    /// (sortID, ascending, flatMode) the rows were sorted with.
    let sortParams: PanelSortParams
    /// A file-system folder on a volume that tells "A" from "a" (01 §9 #24). Windows matches masks
    /// and compares paths without case; on macOS that depends on the volume. Archives follow the
    /// engine (g_CaseSensitive is false on macOS), so this is false for them.
    var isCaseSensitive = false

    /// Number of items excluding the ".." row (the Windows "total" of the status bar).
    var itemCount: Int { rows.reduce(0) { $1.isParentRow ? $0 : $0 + 1 } }
}
