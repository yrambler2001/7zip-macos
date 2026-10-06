// make-icons.swift -- the contact-sheet half of the icon pipeline (see Mac/scripts/make-icons.py).
//
// Run by Mac/scripts/make-icons.sh as
//
//     swift Mac/scripts/make-icons.swift <icons-manifest.json> <png-dir> --contact-sheet <png>
//
// Nothing is drawn here any more.  The app icon (winmatch) and the document icons (docicons) are
// the upstream Windows .ico frames, enlarged nearest-neighbour by make-icons.py; this script only
// lays the finished 128 px PNGs out on a labelled checkerboard for the reports.

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Manifest

struct Manifest: Decodable {
    struct Icon: Decodable {
        let name: String
        let extensions: [String]
    }
    let icons: [Icon]
}

// MARK: - Text

/// Draw `text` centred in `box`, in the heaviest system face, shrunk until it fits with
/// `padding` to spare.  Returns false when even the smallest legible size will not fit, so the
/// caller can drop the label instead of drawing mush.
@discardableResult
func drawLabel(_ ctx: CGContext, _ text: String, in box: CGRect, colour: CGColor,
               padding: CGFloat, maxHeightFraction: CGFloat) -> Bool {
    let avail = box.width - 2 * padding
    guard avail > 2, box.height > 3 else { return false }
    var size = box.height * maxHeightFraction
    var line: CTLine?
    var bounds = CGRect.zero
    while size >= 3 {
        let font = NSFont.systemFont(ofSize: size, weight: .heavy)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: colour) ?? .white,
            // Tighten the tracking a little: these labels are all-caps abbreviations.
            .kern: -size * 0.02,
        ]
        let l = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let b = CTLineGetBoundsWithOptions(l, .useGlyphPathBounds)
        if b.width <= avail {
            line = l
            bounds = b
            break
        }
        size *= 0.94
    }
    guard let l = line else { return false }
    ctx.saveGState()
    ctx.textMatrix = .identity
    ctx.setAllowsAntialiasing(true)
    ctx.textPosition = CGPoint(x: box.midX - bounds.width / 2 - bounds.minX,
                               y: box.midY - bounds.height / 2 - bounds.minY)
    CTLineDraw(l, ctx)
    ctx.restoreGState()
    return true
}

// MARK: - Bitmap plumbing

func writePNG(_ ctx: CGContext, to path: String) {
    guard let image = ctx.makeImage() else { fatalError("makeImage failed for \(path)") }
    let url = URL(fileURLWithPath: path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
    else { fatalError("no PNG destination for \(path)") }
    CGImageDestinationAddImage(dest, image, nil)
    if !CGImageDestinationFinalize(dest) { fatalError("PNG write failed for \(path)") }
}

/// Run `body` with AppKit's text machinery pointed at `ctx` (CoreText needs no wrapper, but
/// NSFont metrics do want a current graphics context in some paths).
func withAppKit(_ ctx: CGContext, _ body: () -> Void) {
    let saved = NSGraphicsContext.current
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    body()
    NSGraphicsContext.current = saved
}

// MARK: - Contact sheet

/// Every generated icon at 128 points in a grid, on a checkerboard so a lost alpha channel shows
/// up as an opaque square, with the name and the extensions it serves underneath.
func drawContactSheet(_ m: Manifest, pngDir: String, to out: String) {
    let cell = 128, gap = 22, labelH = 34, cols = 7
    let items: [(String, String, String)] =
        [("app", "AppIcon", "7-Zip.app")] +
        m.icons.map { ("doc/\($0.name)", "doc-\($0.name)", $0.extensions.joined(separator: " ")) } +
        [("doc/fm", "doc-fm", "any other type opened with 7-Zip")]
    let rows = (items.count + cols - 1) / cols
    let W = cols * (cell + gap) + gap
    let H = rows * (cell + gap + labelH) + gap + 54
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    withAppKit(ctx) {
        let title = "7-Zip.app icon assets -- every icon at 128pt (.ico frames enlarged nearest-neighbour), on a checkerboard"
        drawLabel(ctx, title, in: CGRect(x: 0, y: H - 46, width: W, height: 32),
                  colour: CGColor(srgbRed: 0.85, green: 0.85, blue: 0.86, alpha: 1),
                  padding: 24, maxHeightFraction: 0.60)
    }

    for (i, item) in items.enumerated() {
        let col = i % cols, row = i / cols
        let x = gap + col * (cell + gap)
        let y = H - 54 - (row + 1) * (cell + gap + labelH) + labelH
        let box = CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(cell), height: CGFloat(cell))
        // Checkerboard under the icon: 16px squares in two greys.
        ctx.saveGState()
        ctx.clip(to: box)
        var cy = 0
        while cy < cell {
            var cx = 0
            while cx < cell {
                let light = ((cx / 16) + (cy / 16)) % 2 == 0
                ctx.setFillColor(light ? CGColor(srgbRed: 0.42, green: 0.42, blue: 0.44, alpha: 1)
                                       : CGColor(srgbRed: 0.30, green: 0.30, blue: 0.32, alpha: 1))
                ctx.fill(CGRect(x: box.minX + CGFloat(cx), y: box.minY + CGFloat(cy),
                                width: 16, height: 16))
                cx += 16
            }
            cy += 16
        }
        ctx.restoreGState()

        let path = "\(pngDir)/\(item.0)/128.png"
        if let src = CGDataProvider(filename: path).flatMap({ CGImage(pngDataProviderSource: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent) }) {
            ctx.draw(src, in: box)
        } else {
            FileHandle.standardError.write("contact sheet: missing \(path)\n".data(using: .utf8)!)
        }
        withAppKit(ctx) {
            drawLabel(ctx, item.1, in: CGRect(x: box.minX - 8, y: box.minY - 19,
                                              width: box.width + 16, height: 17),
                      colour: CGColor(srgbRed: 0.93, green: 0.93, blue: 0.94, alpha: 1),
                      padding: 2, maxHeightFraction: 0.95)
            drawLabel(ctx, item.2, in: CGRect(x: box.minX - 12, y: box.minY - 33,
                                              width: box.width + 24, height: 14),
                      colour: CGColor(srgbRed: 0.62, green: 0.68, blue: 0.80, alpha: 1),
                      padding: 1, maxHeightFraction: 0.90)
        }
    }
    writePNG(ctx, to: out)
    print("contact sheet: \(W)x\(H) with \(items.count) icons -> \(out)")
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let i = args.firstIndex(of: "--contact-sheet"), i + 1 < args.count else {
    FileHandle.standardError.write(
        "usage: make-icons.swift <manifest.json> <png-dir> --contact-sheet <png>\n"
            .data(using: .utf8)!)
    exit(2)
}
let manifest = try JSONDecoder().decode(Manifest.self,
                                        from: Data(contentsOf: URL(fileURLWithPath: args[0])))
drawContactSheet(manifest, pngDir: args[1], to: args[i + 1])
