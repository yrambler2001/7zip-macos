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

    /// GetItemsInfoString (App.cpp:500-547): at most 5 names, then Folders / Files / Size, which
    /// together fit the dialog's kCopyDialog_NumInfoLines = 11 lines.
    static func itemsInfo(rows: [PanelRow]) -> String {
        var lines: [String] = []
        // Each name and each "label: value" pair is bidi-isolated, so a right-to-left translation
        // keeps "label: value" order in the left-to-right dialog (`Bidi`, requests.md).
        for row in rows.prefix(5) { lines.append(Bidi.isolate(row.name)) }
        if rows.count > 5 { lines.append("...") }
        let folders = rows.reduce(0) { $1.isDirectory ? $0 + 1 : $0 }
        let files = rows.count - folders
        let size = rows.reduce(UInt64(0)) { $0 &+ $1.size }
        lines.append("")
        if folders > 0 { lines.append(Bidi.labelValue(Lang.text(1031, "Folders"), "\(folders)")) }
        if files > 0 { lines.append(Bidi.labelValue(Lang.text(1032, "Files"), "\(files)")) }
        lines.append(Bidi.labelValue(Lang.text(1007, "Size"), Formatting.size(size)))
        return lines.joined(separator: "\n")
    }
}
