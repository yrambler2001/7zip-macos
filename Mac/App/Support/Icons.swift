// Icons.swift -- 16 px system icons by extension (g_Ext_to_Icon_Map equivalent).

import AppKit
import UniformTypeIdentifiers

enum Icons {

    private static var cache: [String: NSImage] = [:]
    private static let iconSize = NSSize(width: 16, height: 16)

    static let folder: NSImage = {
        let image = NSWorkspace.shared.icon(for: .folder)
        image.size = iconSize
        return image
    }()

    /// Icon for a file name (by extension) or a folder.
    static func icon(forName name: String, isDirectory: Bool) -> NSImage {
        if isDirectory { return folder }
        let ext = (name as NSString).pathExtension.lowercased()
        if let cached = cache[ext] { return cached }
        let type = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        image.size = iconSize
        cache[ext] = image
        return image
    }
}
