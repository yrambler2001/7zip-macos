// PanelIcons.swift -- the panel's icon rule (SetItemText, PanelListNotify.cpp:152-522, and
// LoadFullPathAndShow, PanelFolderChange.cpp:406-520): the real icon (IFolderGetSystemIconIndex,
// which the bridge leaves to the app -- Mac/docs/requests.md) for volume and root items, and for
// file-system items when ShowRealFileIcons is on; the icon by extension otherwise. The address bar shows the Computer, volume or archive-file icon.

import AppKit
import SevenZipKit

enum PanelIcons {

    static let smallSize = NSSize(width: 16, height: 16)
    static let largeSize = NSSize(width: 32, height: 32)

    static func icon(for row: PanelRow, snapshot: PanelSnapshot?, cache: inout [String: NSImage],
                     large: Bool) -> NSImage {
        let size = large ? largeSize : smallSize
        if row.isParentRow { return resized(Icons.folder, size) }
        // Real icons: the volumes list and the root always; a file-system folder only when the
        // user asked for them (ShowRealFileIcons, IDX_SETTINGS_SHOW_REAL_FILE_ICONS 2502): 7zFM
        // queries IFolderGetSystemIconIndex only `if (!Is_Slow_Icon_Folder() || _showRealFileIcons)`
        // (PanelItems.cpp:587), and Is_Slow_Icon_Folder() is IsFSFolder(). Off -- the Windows
        // default -- an FS item gets its icon by extension, like an archive item.
        let realIcon = showsRealIcons(isFileSystem: snapshot?.isFileSystem ?? false,
                                      isVolumesFolder: snapshot?.isVolumesFolder ?? false,
                                      isRoot: snapshot?.isRoot ?? false)
        if realIcon, !row.fullPath.isEmpty {
            let key = "\(large ? "L" : "S")\(row.fullPath)"
            if let cached = cache[key] { return cached }
            let image = NSWorkspace.shared.icon(forFile: row.fullPath)
            let sized = resized(image, size)
            cache[key] = sized
            return sized
        }
        if let snapshot, snapshot.isVolumesFolder || snapshot.isRoot {
            let symbol = snapshot.isRoot ? "desktopcomputer" : "externaldrive"
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                return resized(image, size)
            }
        }
        return resized(Icons.icon(forName: row.name, isDirectory: row.isDirectory), size)
    }

    /// `!Is_Slow_Icon_Folder() || _showRealFileIcons` (PanelItems.cpp:587, Panel.h:708): only a
    /// file-system folder is a "slow icon" folder; the root and the volumes list always show
    /// real icons.
    static func showsRealIcons(isFileSystem: Bool, isVolumesFolder: Bool, isRoot: Bool) -> Bool {
        let slowIconFolder = isFileSystem && !isVolumesFolder && !isRoot
        return !slowIconFolder || Settings.showRealFileIcons
    }

    /// The folder icon left of the address bar: Computer for the root, the volume icon for the
    /// volumes list, the archive file's icon inside an archive, else the folder's own icon.
    static func addressBarIcon(for snapshot: PanelSnapshot) -> NSImage? {
        if snapshot.isRoot {
            return NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)
        }
        if snapshot.isVolumesFolder {
            return NSImage(systemSymbolName: "externaldrive", accessibilityDescription: nil)
        }
        if !snapshot.archivePath.isEmpty {
            return resized(NSWorkspace.shared.icon(forFile: snapshot.archivePath), smallSize)
        }
        if snapshot.isFileSystem, !snapshot.fullPath.isEmpty {
            return resized(NSWorkspace.shared.icon(forFile: snapshot.fullPath), smallSize)
        }
        return resized(Icons.folder, smallSize)
    }

    private static func resized(_ image: NSImage, _ size: NSSize) -> NSImage {
        let copy = image.copy() as? NSImage ?? image
        copy.size = size
        return copy
    }
}
