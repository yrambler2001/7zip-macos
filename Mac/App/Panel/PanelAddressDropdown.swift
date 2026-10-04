// PanelAddressDropdown.swift -- what the address bar's drop-down lists and when a pick in it
// navigates (CPanel::OnComboBoxCommand, PanelFolderChange.cpp:627-837; 01 §3.9).
//
// 7zFM 26.03 (listfeel-data/win1/combo-dropped.txt) lists, for C:\Users\...\Temp\szcmp\cmp\:
// "C:", "Users", "yrambler2001", "AppData", "Local", "Temp", "szcmp", "cmp" -- one entry per
// component, each indented one level deeper than the one before (AddComboBoxItem's indent) --
// then "Documents", "Computer", the drives one level in, and "Network". Each entry shows the
// component's *name*; the path it binds is kept apart (ComboBoxPaths). Picking one binds that
// path at once (CBN_SELENDOK) and focuses the list. There is no folder history in the list.
//
// On macOS the root component is "/", "Computer" is the virtual root ("" in BindToPath), the
// volumes are the mounted ones ("/" and /Volumes/...), and there is no "Network" entry (the root
// folder has no network item here, 01 §9).

import Cocoa

enum AddressDropdown {

    struct Entry: Equatable {
        let title: String       // the indented display text
        let path: String        // what BindToPath gets (ComboBoxPaths[i])
    }

    /// AddComboBoxItem's indentation, as leading spaces (an NSComboBox item is plain text).
    static let indentUnit = "   "

    static func entries(currentPath: String, documents: String, volumes: [String]) -> [Entry] {
        var result: [Entry] = []
        func add(_ name: String, _ indent: Int, _ path: String) {
            result.append(Entry(title: String(repeating: indentUnit, count: indent) + name, path: path))
        }
        if currentPath.hasPrefix("/") {
            add("/", 0, "/")                                    // the root prefix ("C:")
            var sum = "/"
            let parts = currentPath.split(separator: "/", omittingEmptySubsequences: true)
            for (i, part) in parts.enumerated() {
                sum += part + "/"
                add(String(part), i + 1, sum)
            }
        }
        add(Lang.text(7102, "Documents"), 0, documents)         // IDS_DOCUMENTS (RootFolder_GetName_Documents)
        add(Lang.text(7100, "Computer"), 0, "")                 // IDS_COMPUTER, the virtual root
        for volume in volumes {
            let path = volume.hasSuffix("/") ? volume : volume + "/"
            let name = path == "/" ? "/" : String(path.dropLast())
            add(name, 1, path)                                  // drives, one level in
        }
        return result
    }

    /// A drop-down entry commits (CBN_SELENDOK) when it was picked with the mouse. Arrow keys in
    /// the open list only move the selection (CBN_SELCHANGE), and Return commits through the
    /// combo's action instead.
    static func isCommitEvent(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp: return true
        default: return false
        }
    }
}
