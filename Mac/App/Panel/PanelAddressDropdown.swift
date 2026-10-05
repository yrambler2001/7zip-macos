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
        var name: String = ""   // the text the dropped list shows (AddressPopup)
        var level: Int = 0      // AddComboBoxItem's indent
        var kind: Kind = .folder
    }

    /// Which icon the dropped list gives an entry (AddComboBoxItem's GetRealIconIndex).
    enum Kind: Equatable { case folder, documents, computer, volume }

    /// AddComboBoxItem's indentation, as leading spaces (an NSComboBox item is plain text).
    static let indentUnit = "   "

    static func entries(currentPath: String, documents: String, volumes: [String]) -> [Entry] {
        var result: [Entry] = []
        func add(_ name: String, _ indent: Int, _ path: String, _ kind: Kind = .folder) {
            result.append(Entry(title: String(repeating: indentUnit, count: indent) + name, path: path,
                                name: name, level: indent, kind: kind))
        }
        if currentPath.hasPrefix("/") {
            add("/", 0, "/", .volume)                           // the root prefix ("C:")
            var sum = "/"
            let parts = currentPath.split(separator: "/", omittingEmptySubsequences: true)
            for (i, part) in parts.enumerated() {
                sum += part + "/"
                add(String(part), i + 1, sum)
            }
        }
        add(Lang.text(7102, "Documents"), 0, documents, .documents) // IDS_DOCUMENTS (RootFolder_GetName_Documents)
        add(Lang.text(7100, "Computer"), 0, "", .computer)      // IDS_COMPUTER, the virtual root
        for volume in volumes {
            let path = volume.hasSuffix("/") ? volume : volume + "/"
            let name = path == "/" ? "/" : String(path.dropLast())
            add(name, 1, path, .volume)                         // drives, one level in
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

extension AddressDropdown {

    /// The 16 x 16 icon of an entry: the system's icon for the path (a volume, Documents, a
    /// folder), 7-Zip's for an archive component, a folder for a component inside an archive,
    /// the computer for Computer -- what the shell's image list gives 7zFM.
    static func icon(for entry: Entry) -> NSImage? {
        let size = NSSize(width: 16, height: 16)
        func sized(_ image: NSImage?) -> NSImage? {
            guard let image, let copy = image.copy() as? NSImage else { return image }
            copy.size = size
            return copy
        }
        switch entry.kind {
        case .computer:
            return sized(NSImage(named: NSImage.computerName))
        case .documents, .volume:
            return sized(NSWorkspace.shared.icon(forFile: entry.path))
        case .folder:
            var isDirectory: ObjCBool = false
            let path = entry.path.count > 1 && entry.path.hasSuffix("/") ? String(entry.path.dropLast()) : entry.path
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue, let archive = PanelArchiveIcons.icon(forName: path, large: false) { return archive }
                return sized(NSWorkspace.shared.icon(forFile: path))
            }
            return sized(Icons.folder)
        }
    }
}
