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
// the first, highest-colour one, as Windows picks on a true-colour display.
//
// sffont (the user's decision): the **low-resolution** frame at every scale, drawn pixel-sharp. The
// 16 x 16 frame is the one whose extension text ("7z", "zip", ...) is drawn legibly; the 32 px
// frame downscaled (feel3's Retina choice) blurred it. So a 16 pt icon is the 16 px frame and a
// 32 pt icon the 32 px frame, and on a Retina (or 3x) screen the frame is enlarged by whole
// pixels with nearest-neighbour -- each icon pixel a 2 x 2 (3 x 3) block, never smoothed: the
// image carries a pre-enlarged bitmap for each scale, so no interpolation happens when it is drawn.

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
        // The frame of exactly this size; an .ico without one falls back to the nearest larger
        // frame, then to the largest smaller one.
        let pixels = Int(points)
        guard let frame = frames[pixels]
                ?? frames.filter({ $0.key > pixels }).min(by: { $0.key < $1.key })?.value
                ?? frames.max(by: { $0.key < $1.key })?.value else { return nil }
        let image = NSImage(size: NSSize(width: points, height: points))
        for scale in 1...3 {
            guard let rep = nearestNeighbour(frame, width: pixels * scale, height: pixels * scale) else { continue }
            rep.size = image.size
            image.addRepresentation(rep)
        }
        cache[key] = image
        return image
    }

    /// `frame` enlarged to `width` x `height` by whole pixels with no interpolation: every source
    /// pixel becomes an exact block. (The .ico frames are 8-bit indexed with an 8-bit alpha;
    /// Core Graphics decodes them when it draws, NSBitmapImageRep.colorAt cannot read them.)
    static func nearestNeighbour(_ frame: CGImage, width: Int, height: Int) -> NSBitmapImageRep? {
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .none
        ctx.setShouldAntialias(false)
        ctx.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage().map(NSBitmapImageRep.init(cgImage:))
    }
}
