// make-icons.swift -- the drawing half of the icon pipeline (see Mac/scripts/make-icons.py).
//
// Run by Mac/scripts/make-icons.sh as
//
//     swift Mac/scripts/make-icons.swift <icons-manifest.json> <out-dir> [--contact-sheet <png>]
//
// It reads the manifest the Python extractor derived from the upstream Windows icon resources
// (the exact archive-body palette, each format's exact badge colour, and the label its badge
// spells) and *re-draws* the art with CoreGraphics once per pixel size.  Nothing is scaled from
// a big bitmap: strokes, insets, corner radii, the fold and the type size are all functions of
// the pixel size, so 16px is a legible small icon rather than a shrunken large one.
//
// Output tree (all sRGB, 8bpc, premultiplied alpha):
//     <out-dir>/app/<px>.png            the AppIcon slots
//     <out-dir>/doc/<name>/<px>.png     one document icon per upstream format icon
//
// Shapes:
//   * App icon  -- the macOS rounded-square.  macOS uses a continuous ("squircle") corner, which
//     a superellipse |x/a|^5 + |y/a|^5 = 1 reproduces almost exactly: for Apple's 824pt body in a
//     1024pt canvas with a 185.4pt corner radius, the rounded rect's 45-degree point is at 357.7
//     and the superellipse's is at 358.7, a 1pt difference.  So the body is that superellipse,
//     824/1024 = 0.8046875 of the canvas, centred, leaving Apple's 100/1024 margin on each side.
//   * Document icon -- the standard page: 704x900 in a 1024 canvas (0.6875 x 0.8789), centred
//     horizontally, with the top-right corner folded over by 190/1024.

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - Manifest

struct Manifest: Decodable {
    struct App: Decodable {
        let label: String
        let gradientTop: String
        let gradientBottom: String
    }
    struct Icon: Decodable {
        let index: Int
        let name: String
        let label: String
        let badge: String
        let extensions: [String]
    }
    let pixelSizes: [Int]
    let body: [String: String]
    let app: App
    let icons: [Icon]
}

// MARK: - Colour helpers

/// `#rrggbb` -> CGColor in sRGB.  The manifest carries the upstream bytes verbatim, so the
/// generated art uses 7-Zip's own colours with no conversion.
func rgb(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    var s = Substring(hex)
    if s.hasPrefix("#") { s = s.dropFirst() }
    let v = UInt32(s, radix: 16) ?? 0
    return CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
                   green: CGFloat((v >> 8) & 0xFF) / 255,
                   blue: CGFloat(v & 0xFF) / 255,
                   alpha: alpha)
}

/// Move a colour towards white (`t > 0`) or black (`t < 0`); used only for gradient stops and
/// the page's paper shading, never to invent a new brand colour.
func shade(_ c: CGColor, _ t: CGFloat) -> CGColor {
    let p = c.components ?? [0, 0, 0, 1]
    func f(_ x: CGFloat) -> CGFloat { t >= 0 ? x + (1 - x) * t : x * (1 + t) }
    return CGColor(srgbRed: f(p[0]), green: f(p[1]), blue: f(p[2]), alpha: p.count > 3 ? p[3] : 1)
}

// MARK: - Paths

/// A superellipse |x/a|^n + |y/b|^n = 1 inscribed in `r`, as a polyline dense enough that
/// CoreGraphics' anti-aliasing cannot tell it from a curve (1024 segments at any size).
func superellipsePath(in r: CGRect, exponent n: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let a = r.width / 2, b = r.height / 2
    let cx = r.midX, cy = r.midY
    let steps = 256
    for quadrant in 0..<4 {
        let sx: CGFloat = (quadrant == 0 || quadrant == 3) ? 1 : -1
        let sy: CGFloat = (quadrant < 2) ? 1 : -1
        for i in 0...steps {
            // Sweep the parameter in the quadrant with a cosine ramp so the corner, where the
            // curvature lives, gets most of the samples.
            let t = CGFloat(i) / CGFloat(steps)
            let u = (1 - cos(t * .pi / 2))
            let x = a * pow(1 - pow(u, n), 1 / n)
            let y = b * u
            let pt = CGPoint(x: cx + sx * (quadrant % 2 == 0 ? x : y),
                             y: cy + sy * (quadrant % 2 == 0 ? y : x))
            if quadrant == 0 && i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
    }
    p.closeSubpath()
    return p
}

/// The macOS document page: a rounded rectangle whose top-right corner is cut off by a fold of
/// side `fold`.  Returns the page outline; `foldPath` returns the little triangle that sits on it.
func pagePath(_ r: CGRect, radius: CGFloat, fold: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let x0 = r.minX, x1 = r.maxX, y0 = r.minY, y1 = r.maxY   // y0 = bottom (CG is y-up)
    p.move(to: CGPoint(x: x0 + radius, y: y1))
    p.addLine(to: CGPoint(x: x1 - fold, y: y1))              // top edge, stopping at the fold
    p.addLine(to: CGPoint(x: x1, y: y1 - fold))              // the diagonal of the fold
    p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1 - radius, y: y0),
             radius: radius)
    p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x0, y: y0 + radius),
             radius: radius)
    p.addArc(tangent1End: CGPoint(x: x0, y: y1), tangent2End: CGPoint(x: x0 + radius, y: y1),
             radius: radius)
    p.closeSubpath()
    return p
}

func foldPath(_ r: CGRect, fold: CGFloat, radius: CGFloat) -> CGPath {
    let p = CGMutablePath()
    let x1 = r.maxX, y1 = r.maxY
    p.move(to: CGPoint(x: x1 - fold, y: y1))
    p.addLine(to: CGPoint(x: x1, y: y1 - fold))
    p.addLine(to: CGPoint(x: x1 - fold, y: y1 - fold))
    p.closeSubpath()
    _ = radius
    return p
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

func makeContext(_ px: Int) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: px * 4,
                        space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

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

// MARK: - The app icon

/// 7-Zip.app's icon: the macOS rounded-square in 7-Zip's two brand blues, carrying the manila
/// archive sheet and the "7z" mark that CPP/7zip/UI/FileManager/FM.ico draws.
///
/// Small sizes get a deliberately different composition: below 64px the sheet's border and the
/// white plate collapse into noise, so the mark is drawn straight onto the squircle at nearly
/// twice the relative size.  That is the same "simplify the small sizes" rule Apple's own icons
/// follow, and it is why this renderer draws every size instead of downsampling one.
func drawAppIcon(_ px: Int, _ m: Manifest) -> CGContext {
    let ctx = makeContext(px)
    let S = CGFloat(px)
    let top = rgb(m.app.gradientTop)          // zip.ico blue   #0000ff
    let bottom = rgb(m.app.gradientBottom)    // 7z.ico  navy   #000080
    let sheet = rgb(m.body["fill"]!)          //                #ffff99
    let border = rgb(m.body["border"]!)       //                #999900

    // ---- body: Apple's 824/1024 squircle, centred -------------------------------------
    let inset = S * (1 - 0.8046875) / 2
    let body = CGRect(x: inset, y: inset, width: S - 2 * inset, height: S - 2 * inset)
    let shape = superellipsePath(in: body, exponent: 5)

    // A soft contact shadow, as every macOS app icon has.  Skipped below 64px where it would
    // just muddy the two or three pixels of margin available.
    if px >= 64 {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.012), blur: S * 0.028,
                      color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.30))
        ctx.addPath(shape)
        ctx.setFillColor(bottom)
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let grad = CGGradient(colorsSpace: cs,
                          colors: [shade(top, 0.10), top, bottom] as CFArray,
                          locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.minY), options: [])
    // Glass highlight across the top third, the way macOS app icons catch light.
    let gloss = CGGradient(colorsSpace: cs,
                           colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.15),
                                    CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(gloss, start: CGPoint(x: 0, y: body.maxY),
                           end: CGPoint(x: 0, y: body.midY + body.height * 0.06), options: [])
    ctx.restoreGState()

    // Hairline rim so the icon keeps an edge against a light Dock background.
    ctx.addPath(shape)
    ctx.setStrokeColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
    ctx.setLineWidth(max(1, S * 0.004))
    ctx.strokePath()

    withAppKit(ctx) {
        if px >= 64 {
            // ---- the manila archive sheet, then "7z" in 7-Zip navy on it -----------------
            // Proportions chosen so the mark's optical size barely changes across the 32 -> 64
            // step where the sheet appears.
            let w = S * 0.520, h = S * 0.600
            let sheetRect = CGRect(x: (S - w) / 2, y: (S - h) / 2 - S * 0.010, width: w, height: h)
            let r = S * 0.050
            let sp = CGPath(roundedRect: sheetRect, cornerWidth: r, cornerHeight: r,
                            transform: nil)
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -S * 0.010), blur: S * 0.026,
                          color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.40))
            ctx.addPath(sp)
            ctx.setFillColor(sheet)
            ctx.fillPath()
            ctx.restoreGState()

            // A faint warm shading down the sheet, so a 1024px icon is not a flat colour field.
            ctx.saveGState()
            ctx.addPath(sp)
            ctx.clip()
            let sheetGrad = CGGradient(colorsSpace: cs,
                                       colors: [shade(sheet, 0.45), sheet,
                                                rgb(m.body["edge"]!, 0.55)] as CFArray,
                                       locations: [0, 0.45, 1])!
            ctx.drawLinearGradient(sheetGrad, start: CGPoint(x: 0, y: sheetRect.maxY),
                                   end: CGPoint(x: 0, y: sheetRect.minY), options: [])
            ctx.restoreGState()

            ctx.addPath(sp)
            ctx.setStrokeColor(border)
            ctx.setLineWidth(max(1, S * 0.012))
            ctx.strokePath()

            drawLabel(ctx, m.app.label, in: sheetRect, colour: bottom,
                      padding: w * 0.13, maxHeightFraction: 0.66)
        } else {
            // ---- 16px / 32px: the mark alone, as big as the body allows ------------------
            // At 16px two glyphs have about 5px of stem each and run together, so the mark drops
            // to the "7" the whole brand is built on; 32px still carries "7z" cleanly.
            let box = body.insetBy(dx: body.width * 0.10, dy: body.height * 0.14)
            drawLabel(ctx, px <= 16 ? String(m.app.label.prefix(1)) : m.app.label,
                      in: box, colour: sheet,
                      padding: box.width * 0.02, maxHeightFraction: 0.98)
        }
    }
    return ctx
}

// MARK: - The document icons

/// One macOS document icon per upstream format icon: the standard white page with a folded
/// top-right corner, a manila band (the 7-Zip archive body colour) and, at the foot of the page,
/// the format's badge in its exact upstream badge colour carrying the label its Windows badge
/// spells.  Below 64px the label is dropped -- there is no type size that would be legible -- and
/// the bands alone carry the identity, exactly as Apple's own document icons behave.
func drawDocIcon(_ px: Int, _ icon: Manifest.Icon, _ m: Manifest) -> CGContext {
    let ctx = makeContext(px)
    let S = CGFloat(px)
    let badge = rgb(icon.badge)
    let manila = rgb(m.body["fill"]!)
    let olive = rgb(m.body["border"]!)

    // 704 x 900 page in a 1024 canvas, centred horizontally, 62 top / 62 bottom.
    let pw = S * 0.6875, ph = S * 0.8789
    let page = CGRect(x: (S - pw) / 2, y: (S - ph) / 2, width: pw, height: ph)
    let radius = max(S * 0.0293, px <= 32 ? 1 : 2)
    let fold = S * 0.1855
    let path = pagePath(page, radius: radius, fold: fold)

    // Paper.  Flat, as macOS 11+ document icons are -- and, incidentally, the reason a 1024px
    // document icon compresses to a few kB instead of 130: every large area is a single colour.
    ctx.addPath(path)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    ctx.fillPath()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()

    // ---- the 7-Zip artwork: manila band + badge band at the foot of the page -------------
    let badgeH = ph * 0.260
    let manilaH = ph * 0.130
    let rule = max(1, S * 0.006)
    let badgeRect = CGRect(x: page.minX, y: page.minY, width: pw, height: badgeH)
    let manilaRect = CGRect(x: page.minX, y: badgeRect.maxY, width: pw, height: manilaH)
    ctx.setFillColor(manila)
    ctx.fill(manilaRect)
    ctx.setFillColor(rgb(m.body["edge"]!))
    ctx.fill(CGRect(x: page.minX, y: manilaRect.maxY - rule, width: pw, height: rule))
    ctx.setFillColor(badge)
    ctx.fill(badgeRect)
    ctx.setFillColor(olive)
    ctx.fill(CGRect(x: page.minX, y: badgeRect.maxY, width: pw, height: rule))

    // The page's own rule lines above the artwork, so large sizes are not an empty white field.
    // Collect the rows first, then draw, so the topmost one can simply be drawn short instead of
    // being painted over afterwards.
    if px >= 128 {
        let lineH = max(1, S * 0.012)
        let left = page.minX + pw * 0.115
        var ys: [CGFloat] = []
        var y = manilaRect.maxY + ph * 0.150
        while y < page.maxY - fold - ph * 0.035 && ys.count < 5 {
            ys.append(y)
            y += ph * 0.098
        }
        ctx.setFillColor(CGColor(srgbRed: 0.84, green: 0.84, blue: 0.82, alpha: 1))
        for (i, ry) in ys.enumerated() {
            // ys[0] is the lowest rule, i.e. the paragraph's last line: draw that one short.
            let w = (i == 0) ? pw * 0.480 : pw * 0.770
            ctx.fill(CGRect(x: left, y: ry, width: w, height: lineH))
        }
    }
    ctx.restoreGState()

    // Fold: the turned-over corner, a flat grey triangle in the cut corner.
    ctx.addPath(foldPath(page, fold: fold, radius: radius))
    ctx.setFillColor(CGColor(srgbRed: 0.855, green: 0.855, blue: 0.845, alpha: 1))
    ctx.fillPath()

    // Page outline.
    ctx.addPath(path)
    ctx.setStrokeColor(CGColor(srgbRed: 0.62, green: 0.62, blue: 0.60, alpha: 0.55))
    ctx.setLineWidth(max(1, S * 0.005))
    ctx.strokePath()

    // ---- the label -----------------------------------------------------------------------
    if badgeH >= 9 {
        withAppKit(ctx) {
            drawLabel(ctx, icon.label, in: badgeRect,
                      colour: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1),
                      padding: pw * 0.075, maxHeightFraction: 0.62)
        }
    }
    return ctx
}

// MARK: - Contact sheet

/// Every generated icon at 128 points in a grid, on a checkerboard so a lost alpha channel shows
/// up as an opaque square, with the name and the extensions it serves underneath.
func drawContactSheet(_ m: Manifest, pngDir: String, to out: String) {
    let cell = 128, gap = 22, labelH = 34, cols = 7
    let items: [(String, String, String)] =
        [("app", "AppIcon", "7-Zip.app")] +
        m.icons.map { ("doc/\($0.name)", "doc-\($0.name)", $0.extensions.joined(separator: " ")) }
    let rows = (items.count + cols - 1) / cols
    let W = cols * (cell + gap) + gap
    let H = rows * (cell + gap + labelH) + gap + 54
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                        space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.13, green: 0.13, blue: 0.14, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))

    withAppKit(ctx) {
        let title = "7-Zip.app icon assets -- every generated icon at 128pt, on a checkerboard"
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
        if let src = CGDataProvider(filename: path).flatMap({ CGImage(pngDataProviderSource: $0, decode: nil, shouldInterpolate: true, intent: .defaultIntent) }) {
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
guard args.count >= 2 else {
    FileHandle.standardError.write(
        "usage: make-icons.swift <manifest.json> <out-dir> [--contact-sheet <png>]\n"
            .data(using: .utf8)!)
    exit(2)
}
let manifest = try JSONDecoder().decode(Manifest.self,
                                        from: Data(contentsOf: URL(fileURLWithPath: args[0])))
let outDir = args[1]

if let i = args.firstIndex(of: "--contact-sheet"), i + 1 < args.count {
    drawContactSheet(manifest, pngDir: outDir, to: args[i + 1])
    exit(0)
}

for px in manifest.pixelSizes {
    writePNG(drawAppIcon(px, manifest), to: "\(outDir)/app/\(px).png")
}
print("app icon: \(manifest.pixelSizes.count) sizes \(manifest.pixelSizes)")
for icon in manifest.icons {
    for px in manifest.pixelSizes {
        writePNG(drawDocIcon(px, icon, manifest), to: "\(outDir)/doc/\(icon.name)/\(px).png")
    }
}
print("document icons: \(manifest.icons.count) formats x \(manifest.pixelSizes.count) sizes "
      + "= \(manifest.icons.count * manifest.pixelSizes.count) pngs")
