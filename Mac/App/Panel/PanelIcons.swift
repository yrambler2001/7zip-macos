// PanelIcons.swift -- the panel's icon rule (SetItemText, PanelListNotify.cpp:152-522, and
// LoadFullPathAndShow, PanelFolderChange.cpp:406-520): the real file-system icon
// (IFolderGetSystemIconIndex, which the bridge leaves to the app -- Mac/docs/requests.md) for
// file-system, volume and root items, and the extension cache inside archives unless
// ShowRealFileIcons is on. The address bar shows the Computer, volume or archive-file icon.

import AppKit
import SevenZipKit

enum PanelIcons {

    static let smallSize = NSSize(width: 16, height: 16)
    static let largeSize = NSSize(width: 32, height: 32)

    static func icon(for row: PanelRow, snapshot: PanelSnapshot?, cache: inout [String: NSImage],
                     large: Bool) -> NSImage {
        let size = large ? largeSize : smallSize
        if row.isParentRow { return resized(Icons.folder, size) }
        // Real icons: FS folders, the volumes list and the root always; archives only when the
        // user asked for them (ShowRealFileIcons) -- and there the file does not exist, so the
        // extension cache is all there is.
        if !row.fullPath.isEmpty {
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
