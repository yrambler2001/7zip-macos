// PanelArchiveIcons.swift -- the archive icons 7zFM's list shows (feel3, the user's finding 8).
//
// 7zFM asks the shell for an item's icon by its extension (SHGetFileInfo with
// SHGFI_USEFILEATTRIBUTES, GetRealIconIndex / Shell_GetFileInfo_SysIconIndex_for_Path in
// SysIconUtils.cpp) unless ShowRealFileIcons is on. For an extension 7-Zip is associated with,
// the shell answers with the `DefaultIcon` 7-Zip registered: `7z.dll,<index>`
// (NRegistryAssoc::AddShellExtensionInfo), i.e. frame <index> of CPP/7zip/Archive/Icons/*.ico
// (Format7zF/resource.rc:6-32, the index from string resource 100 -- `FileTypes.all`). So .7z,
// .zip, .rar, ... show 7-Zip's per-format icons: 16 x 16 in Details / Small Icons / List, 32 x 32
// in Large Icons.
//
// The port shows exactly those frames: the upstream `.ico` files are bundled unchanged as
// `fm-<name>.ico` (Mac/Resources/Icons) and each size uses the icon's own frame of that size --
// the first, highest-colour one, as Windows picks on a true-colour display. On a Retina screen a
// 16 pt icon uses the 32 px frame (what Windows shows at 200 %).

import AppKit
import ImageIO

enum PanelArchiveIcons {

    private static var cache: [String: NSImage] = [:]

    /// The 7-Zip icon for `name`'s extension, or nil when 7-Zip does not register the extension
    /// (FileTypes, 7z.dll string resource 100).
    static func icon(forName name: String, large: Bool) -> NSImage? {
        let ext = (name as NSString).pathExtension.lowercased()
        guard !ext.isEmpty, let type = FileTypes.type(forExtension: ext) else { return nil }
        return icon(named: type.iconFileName, large: large)
    }

    /// `fm-<iconName>.ico` at 16 or 32 pt.
    static func icon(named iconName: String, large: Bool) -> NSImage? {
        let key = (large ? "L" : "S") + iconName
        if let cached = cache[key] { return cached }
        guard let url = Bundle.main.url(forResource: "fm-" + iconName, withExtension: "ico"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        // The first frame of each pixel size (the .ico's own order: the 8-bit frame before the
        // 4-bit one).
        var frames: [Int: CGImage] = [:]
        for i in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, i, nil) else { continue }
            if frames[image.width] == nil { frames[image.width] = image }
        }
        let points: CGFloat = large ? 32 : 16
        let image = NSImage(size: NSSize(width: points, height: points))
        for (pixels, frame) in frames.sorted(by: { $0.key < $1.key }) {
            let rep = NSBitmapImageRep(cgImage: frame)
            rep.size = NSSize(width: points, height: points)
            // Only the frames that are this size or its 2x: a 16 px frame stretched to 32 pt would
            // win over nothing but itself.
            if CGFloat(pixels) == points || CGFloat(pixels) == points * 2 || frames.count == 1 {
                image.addRepresentation(rep)
            }
        }
        if image.representations.isEmpty, let any = frames.values.first {
            let rep = NSBitmapImageRep(cgImage: any)
            rep.size = image.size
            image.addRepresentation(rep)
        }
        cache[key] = image
        return image
    }
}
