// PanelRow.swift -- one list row, built on the panel queue from an SZFolder item and read on
// the main thread. Cell texts are rendered once per load (SetItemText equivalent).

import Foundation
import SevenZipKit

struct PanelRow {
    /// Index in the SZFolder, or -1 for the ".." row (kParentIndex).
    let engineIndex: Int
    let name: String
    let displayName: String
    let isDirectory: Bool
    let size: UInt64
    /// Cell text per column PROPID.
    let cells: [SZPropID: String]
    /// Typed sort keys per PROPID (NSNumber / Date / String).
    let sortKeys: [SZPropID: Any]

    static let parent = PanelRow(engineIndex: -1, name: "..", displayName: "..", isDirectory: true,
                                 size: 0, cells: [:], sortKeys: [:])

    var isParentRow: Bool { engineIndex < 0 }
}

/// Snapshot of a loaded folder handed from the panel queue to the main thread.
struct PanelSnapshot {
    let fullPath: String
    /// File-system directory to persist as PanelPath: the folder itself, or for archive folders
    /// the directory of the outermost archive (CApp::Save uses _parentFolders[0].ParentFolderPath).
    let fileSystemPath: String
    let folderType: String
    let isRoot: Bool
    let isArchive: Bool
    let isFileSystem: Bool
    let isReadOnly: Bool
    let columns: [SZPropertyInfo]
    let rows: [PanelRow]
    let supportsFlatMode: Bool
}
