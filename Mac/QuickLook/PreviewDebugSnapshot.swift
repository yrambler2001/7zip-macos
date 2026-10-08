// PreviewDebugSnapshot.swift -- DEBUG BUILDS ONLY (qlfix): a picture of the preview as the real
// Quick Look host shows it, for verification without screen capture.
//
// When the file `<container>/Data/tmp/ql-snapshot-request` exists (the extension's own sandbox
// tmp, `NSTemporaryDirectory()`), each preview, one second after Quick Look got it, writes two
// PNGs next to it and logs their paths (subsystem com.yrambler2001.7zip, category quicklook):
//
//   snapshot-<file>-<light|dark>-screen.png  the faithful one: the view drawn through the printing
//                                            path, then every overflow layer of our own views (the
//                                            drawing a view did outside its bounds, which the host
//                                            composites above its siblings) drawn on top
//   snapshot-<file>-<light|dark>-parts.png   the hierarchy redrawn piece by piece in z-order, each
//                                            piece asked for the whole root rect (the real host's
//                                            dirty rects): the faithful one
//   snapshot-<file>-<light|dark>-cache.png   bitmapImageRepForCachingDisplay + cacheDisplay
//   snapshot-<file>-<light|dark>-display.png displayIgnoringOpacity(_:in:) of the whole view
//   snapshot-<file>-<light|dark>-layer.png   the view's backing layer tree rendered (what the
//                                            host composites on screen), when it has one
//
// Nothing of this exists in a Release build.

#if DEBUG
import AppKit
import CoreImage
import IOSurface
import os

enum PreviewDebugSnapshot {

    static func screen(_ root: NSView, log: Logger, scale: CGFloat = 2) -> Data? {
        let size = root.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                         pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let cg = context.cgContext
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        cg.scaleBy(x: CGFloat(rep.pixelsWide) / size.width, y: CGFloat(rep.pixelsHigh) / size.height)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)                                   // root coordinates, y down
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            func pdf(_ v: NSView) {
                guard let image = NSPDFImageRep(data: v.dataWithPDF(inside: v.bounds)) else { return }
                let f = root.convert(v.bounds, from: v)
                cg.saveGState()
                cg.translateBy(x: f.minX, y: f.maxY)
                cg.scaleBy(x: 1, y: -1)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
                image.draw(in: NSRect(origin: .zero, size: f.size))
                cg.restoreGState()
            }
            pdf(root)
            for sub in root.subviews where !sub.isHidden {
                // A scroll view as its rows and its header: printing the scroll view itself also
                // prints macOS 26's scroll-edge backdrop as an opaque grey wash over the rows, which
                // the window server does not show at rest (the rows start below the header).
                if let scroll = sub as? NSScrollView {
                    pdf(scroll.contentView)
                    if let header = (scroll.documentView as? NSTableView)?.headerView { pdf(header) }
                    continue
                }
                pdf(sub)
                NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
                overflow(in: sub, root: root, ctx: cg, log: log)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// Re-draws the overflow layers of our own views (see the caller), depth first in z-order.
    static func overflow(in view: NSView, root: NSView, ctx: CGContext, log: Logger) {
        let ours = Bundle(for: type(of: view)) == Bundle(for: ArchivePreviewView.self)
        if ours, let layer = view.layer {
            for sub in layer.sublayers ?? [] where !(sub.delegate is NSView) {
                let rect = sub.frame                       // in the view's (flipped) coordinates
                guard !view.bounds.contains(rect) else { continue }
                log.log("overflow layer of \(String(describing: type(of: view)), privacy: .public): \(NSStringFromRect(rect), privacy: .public) for bounds \(NSStringFromRect(view.bounds), privacy: .public)")
                let origin = root.convert(view.bounds.origin, from: view)
                ctx.saveGState()
                ctx.translateBy(x: origin.x, y: origin.y)
                ctx.clip(to: rect)
                view.draw(rect)
                ctx.restoreGState()
            }
        }
        for sub in view.subviews where !sub.isHidden && !(sub is NSScrollView) { overflow(in: sub, root: root, ctx: ctx, log: log) }
    }

    static func parts(_ root: NSView, scale: CGFloat = 2) -> Data? {
        let size = root.bounds.size
        guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        var pieces: [NSView] = []
        for sub in root.subviews where !sub.isHidden {
            if let scroll = sub as? NSScrollView {
                pieces.append(scroll.contentView)
                if let header = (scroll.documentView as? NSTableView)?.headerView { pieces.append(header) }
            } else {
                pieces.append(sub)
            }
        }
        root.effectiveAppearance.performAsCurrentDrawingAppearance {
            // The root's own drawing (flipped root: y down).
            ctx.saveGState()
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
            root.draw(root.bounds)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            for piece in pieces {
                let whole = piece.convert(root.bounds, from: root)
                let w = Int(size.width * scale), h = Int(size.height * scale)
                guard let sub = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                sub.scaleBy(x: scale, y: scale)
                if piece.isFlipped {
                    sub.translateBy(x: 0, y: whole.height)
                    sub.scaleBy(x: 1, y: -1)
                }
                sub.translateBy(x: -whole.minX, y: -whole.minY)
                sub.setAllowsFontSmoothing(false)
                piece.displayIgnoringOpacity(whole, in: NSGraphicsContext(cgContext: sub, flipped: piece.isFlipped))
                if let image = sub.makeImage() { ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h)) }
            }
        }
        guard let image = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// Draws `layer` (bounds origin at the context's origin, y up) and its sublayers.
    static func composite(_ layer: CALayer, in ctx: CGContext, kinds: inout [String], depth: Int) {
        guard !layer.isHidden, layer.opacity > 0 else { return }
        let b = layer.bounds
        ctx.saveGState()
        ctx.setAlpha(CGFloat(layer.opacity))
        if let bg = layer.backgroundColor {
            ctx.setFillColor(bg)
            ctx.fill(CGRect(origin: .zero, size: b.size))
        }
        var kind = "none"
        if let contents = layer.contents {
            let ref = contents as CFTypeRef
            if CFGetTypeID(ref) == CGImage.typeID {
                kind = "CGImage"
                ctx.draw(contents as! CGImage, in: CGRect(origin: .zero, size: b.size))
            } else if CFGetTypeID(ref) == IOSurfaceGetTypeID() {
                kind = "IOSurface"
                let surface = unsafeBitCast(contents as AnyObject, to: IOSurfaceRef.self)
                let ci = CIImage(ioSurface: surface)
                if let cg = CIContext().createCGImage(ci, from: ci.extent) {
                    ctx.draw(cg, in: CGRect(origin: .zero, size: b.size))
                }
            } else {
                kind = String(describing: type(of: contents))
            }
        }
        if depth < 6 {
            kinds.append("\(depth):\(layer.delegate.map { String(describing: type(of: $0)) } ?? "-") \(Int(layer.frame.minX)),\(Int(layer.frame.minY)) \(Int(b.width))x\(Int(b.height)) \(kind) grav=\(layer.contentsGravity.rawValue)")
        }
        if layer.masksToBounds { ctx.clip(to: CGRect(origin: .zero, size: b.size)) }
        for sub in layer.sublayers ?? [] {
            ctx.saveGState()
            let f = sub.frame
            let y = layer.isGeometryFlipped ? b.height - f.maxY : f.minY
            ctx.translateBy(x: f.minX - b.minX, y: y - (layer.isGeometryFlipped ? 0 : b.minY))
            composite(sub, in: ctx, kinds: &kinds, depth: depth + 1)
            ctx.restoreGState()
        }
        ctx.restoreGState()
    }

    static var requestURL: URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ql-snapshot-request")
    }

    static func scheduleIfRequested(_ view: NSView, fileName: String, log: Logger) {
        guard FileManager.default.fileExists(atPath: requestURL.path) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak view] in
            guard let view else { return }
            let dark = view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = "snapshot-\(fileName)-\(dark ? "dark" : "light")"
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            var written: [String] = []
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                if let png = rep.representation(using: .png, properties: [:]) {
                    let url = dir.appendingPathComponent(base + "-cache.png")
                    if (try? png.write(to: url)) != nil { written.append(url.path) }
                }
            }
            // What the layer tree shows, rebuilt from drawing: the root's background, then each of
            // its subviews in z-order (the scroll view as its rows and its header), each asked to draw
            // the *whole* root rect, as the real host asks (dirty rects logged up to 820 x 560 for a
            // 1 pt view) -- so drawing a view does outside its bounds lands where its overflow layer
            // would put it. The whole-view captures below come out empty on macOS 26 (layer-backed
            // text and table views do not draw into an offscreen context in one pass).
            // The faithful one: each piece drawn through the printing path (dataWithPDF, which
            // draws views the traditional way), stacked as the host stacks the layers -- the root,
            // then each subview in z-order followed by the overflow layers of our own views in it
            // (drawing a view did outside its bounds, which AppKit backs with an extra layer just
            // above the view and below its later siblings).
            if let png = screen(view, log: log) {
                let url = dir.appendingPathComponent(base + "-screen.png")
                if (try? png.write(to: url)) != nil { written.append(url.path) }
            }
            if let png = parts(view) {
                let url = dir.appendingPathComponent(base + "-parts.png")
                if (try? png.write(to: url)) != nil { written.append(url.path) }
            }
            // The traditional drawing pass of the whole hierarchy, with AppKit's own dirty rects.
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds),
               let context = NSGraphicsContext(bitmapImageRep: rep) {
                view.displayIgnoringOpacity(view.bounds, in: context)
                if let png = rep.representation(using: .png, properties: [:]) {
                    let url = dir.appendingPathComponent(base + "-display.png")
                    if (try? png.write(to: url)) != nil { written.append(url.path) }
                }
            }
            if let layer = view.layer {
                let scale = view.window?.backingScaleFactor ?? 2
                let size = view.bounds.size
                if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                       bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: scale, y: scale)
                    if layer.isGeometryFlipped == false && view.isFlipped {
                        ctx.translateBy(x: 0, y: size.height)
                        ctx.scaleBy(x: 1, y: -1)
                    }
                    layer.render(in: ctx)
                    if let image = ctx.makeImage(),
                       let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        let url = dir.appendingPathComponent(base + "-layer.png")
                        if (try? png.write(to: url)) != nil { written.append(url.path) }
                    }
                }
            }
            // The layer tree as the window server composites it: every layer's backing contents
            // drawn into its frame (stretched as contentsGravity .resize does), its background colour,
            // its clip, recursively from the window's root layer.
            if let root = view.window?.contentView?.layer ?? view.layer {
                let scale = view.window?.backingScaleFactor ?? 2
                let size = root.bounds.size
                var kinds: [String] = []
                if let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                       bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    ctx.scaleBy(x: scale, y: scale)
                    composite(root, in: ctx, kinds: &kinds, depth: 0)
                    if let image = ctx.makeImage(),
                       let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                        let url = dir.appendingPathComponent(base + "-composite.png")
                        if (try? png.write(to: url)) != nil { written.append(url.path) }
                    }
                }
                for (i, kind) in kinds.enumerated() where !kind.hasPrefix("4:") && !kind.hasPrefix("5:") {
                    log.log("layer \(i, privacy: .public): \(kind, privacy: .public)")
                }
            }
            if let preview = view as? ArchivePreviewView {
                let o = preview.outlineView
                func srgb(_ c: NSColor?, _ v: NSView) -> String {
                    var out = "-"
                    v.effectiveAppearance.performAsCurrentDrawingAppearance {
                        if let c = c?.usingColorSpace(.sRGB) {
                            out = "\(Int(c.redComponent * 255)),\(Int(c.greenComponent * 255)),\(Int(c.blueComponent * 255)),\(Int(c.alphaComponent * 255))"
                        }
                    }
                    return out
                }
                log.log("colours: root \(view.effectiveAppearance.name.rawValue, privacy: .public) window \(srgb(WinChrome.window, view), privacy: .public); outline \(o.effectiveAppearance.name.rawValue, privacy: .public) bg \(srgb(o.backgroundColor, o), privacy: .public) style \(o.style.rawValue, privacy: .public) effective \(o.effectiveStyle.rawValue, privacy: .public); scroll bg \(srgb(preview.scrollView.backgroundColor, preview.scrollView), privacy: .public) draws \(preview.scrollView.drawsBackground, privacy: .public); clip draws \(preview.scrollView.contentView.drawsBackground, privacy: .public) \(srgb(preview.scrollView.contentView.backgroundColor, preview.scrollView), privacy: .public)")
            }
            log.log("snapshot written: \(written.joined(separator: " "), privacy: .public) (layer-backed: \(view.layer != nil, privacy: .public), window: \(String(describing: view.window.map { type(of: $0) }), privacy: .public))")
        }
    }
}
#endif
