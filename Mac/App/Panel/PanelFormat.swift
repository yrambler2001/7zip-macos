// PanelFormat.swift -- panel-side presentation helpers that need AppKit: column alignment
// (GetColumnAlign, PanelItems.cpp:53-88) and the item-info block of the Copy dialog
// (GetItemsInfoString, App.cpp:500-547). The shared Support/Formatting.swift owns the cell text
// itself and is not edited by this scope (00-orchestration.md, additive-only rule).

import AppKit
import SevenZipKit

enum PanelFormat {

    /// GetColumnAlign: strings and times left, numbers, sizes and booleans right (VT_BOOL is in the
    /// LVCFMT_RIGHT group, PanelItems.cpp:64-76; 7zFM 25.01 shows "Encrypted" right-aligned --
    /// Mac/docs/reports/wincompare.md).
    static func alignment(for varType: SZVarType, propID: SZPropID) -> NSTextAlignment {
        if propID == .name || propID == .path || propID == .prefix { return .left }
        switch varType {
        case .UI1, .UI2, .UI4, .UI8, .I2, .I4, .I8, .bool: return .right
        case .fileTime: return .left
        default: return Formatting.sizePropIDs.contains(propID) ? .right : .left
        }
    }

    /// GetItemsInfoString (App.cpp:500-547), line for line:
    ///
    ///     Folders: 1    ( 2 710 bytes )      AddValuePair2, only when there are folders; the
    ///     Files: 2    ( 101 234 bytes )      "( ... )" part only when every size is defined
    ///     Size: 103 944 bytes                AddValuePair1, only when both sums are non-zero
    ///                                        an empty line
    ///     /path/of/the/folder/               _currentFolderPrefix
    ///       a.txt                            up to kCopyDialog_NumInfoLines - 6 = 5 rel paths,
    ///       sub/                             folders with a separator, then "  ..."
    ///
    /// The earlier port listed the names first and the counts after them; 7zFM 25.01 shows the
    /// order above (Mac/docs/reports/wincompare.md, dlg-copy).
    static func itemsInfo(rows: [PanelRow], folderPrefix: String) -> String {
        var numDirs: UInt64 = 0, numFiles: UInt64 = 0
        var dirsSize: UInt64? = 0, filesSize: UInt64? = 0
        for row in rows {
            let defined = !row.isDirectory || row.sortKeys[.size] != nil
            if row.isDirectory {
                numDirs += 1
                dirsSize = defined ? dirsSize.map { $0 &+ row.size } : nil
            } else {
                numFiles += 1
                filesSize = defined ? filesSize.map { $0 &+ row.size } : nil
            }
        }
        func bytes(_ size: UInt64) -> String {                 // IDS_FILE_SIZE 3504 "{0} bytes"
            Lang.format(Lang.get(3504, "{0} bytes"), Formatting.size(size))
        }
        var info = ""
        func pair2(_ lang: UInt32, _ fallback: String, _ num: UInt64, _ size: UInt64?) {   // AddValuePair2
            guard num != 0 else { return }
            var value = Formatting.size(num)
            if let size { value += "    ( " + bytes(size) + " )" }
            info += Bidi.labelValue(Lang.text(lang, fallback), value) + "\n"
        }
        pair2(1031, "Folders", numDirs, dirsSize)              // IDS_PROP_FOLDERS
        pair2(1032, "Files", numFiles, filesSize)              // IDS_PROP_FILES
        var numDefined = 0
        if let dirsSize, dirsSize != 0 { numDefined += 1 }
        if let filesSize, filesSize != 0 { numDefined += 1 }
        if numDefined == 2, let dirsSize, let filesSize {      // AddValuePair1(IDS_PROP_SIZE)
            info += Bidi.labelValue(Lang.text(1007, "Size"), bytes(dirsSize &+ filesSize)) + "\n"
        }
        info += "\n" + folderPrefix
        let shown = rows.prefix(5)                             // kCopyDialog_NumInfoLines (11) - 6
        for row in shown {
            info += "\n  " + Bidi.isolate(row.prefix + row.name + (row.isDirectory ? "/" : ""))
        }
        if shown.count != rows.count { info += "\n  ..." }
        return info
    }
}
