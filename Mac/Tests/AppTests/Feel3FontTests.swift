// Feel3FontTests.swift -- the font comparison images for the user's choice (reports/feel3.md §4):
// for every FM.ListFont candidate, matched to Segoe UI 9 pt by height and by width, the same file
// list rendered by the real panel under the Windows capture of 7zFM 26.03
// (`wincompare-listfeel-list-win.png`, 760 x 200 px at 96 dpi): one image at 1x (1 Windows px =
// 1 Mac pt) and one at 2x (the Windows pixels doubled, the Mac rendered at Retina scale).
//
// Writes Mac/docs/reports/screenshots/feel3-font-<candidate>-<byheight|bywidth>[-2x].png,
// feel3-font-current[-2x].png (the default, Helvetica Neue 11) and feel3-font-current-byheight[-2x].png
// (the default family matched by height, i.e. the helvetica-neue-byheight font).
// The Mac text is drawn without font smoothing, as the app's windows show it (drawUnsmoothed).

import AppKit
import XCTest
@testable import SevenZipAppHost

final class Feel3FontTests: AppHostTestCase {

    override var screenshotPrefix: String { "feel3-font" }

    private var controllers: [MainWindowController] = []
    private var scratch: String?
    private var savedNumPanels = 1
    private var savedPanelPath: String?
    private var savedListMode = 3
    private var savedAppearance: NSAppearance?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedNumPanels = Settings.numPanels
        savedPanelPath = Settings.panelPath(0)
        savedListMode = Settings.listMode(0)
        savedAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() {
        ListFontChoice.override = nil
        for controller in controllers { controller.window?.close() }
        controllers = []
        if let scratch { try? FileManager.default.removeItem(atPath: (scratch as NSString).deletingLastPathComponent) }
        Settings.numPanels = savedNumPanels
        Settings.setPanelPath(savedPanelPath, 0)
        Settings.setListMode(savedListMode, 0)
        NSApp.appearance = savedAppearance
        super.tearDown()
    }

    /// The Windows capture's folder: the same names, sizes and times (wincompare's `cmp`).
    private func makeFixture() -> String {
        let root = (TestPaths.artifacts as NSString).appendingPathComponent("feel3font-\(UUID().uuidString)")
        let path = root + "/cmp"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/sub", withIntermediateDirectories: true)
        let files: [(String, Int)] = [("a.txt", 1234), ("arc.7z", 101_156), ("arc.tar", 9216), ("arc.zip", 100_979),
                                      ("b.bin", 100_000), ("broken.7z", 300), ("empty.txt", 0), ("enc.7z", 415),
                                      ("encz.zip", 410), ("fake.zip", 24), ("notes.md", 20)]
        for (name, size) in files { fm.createFile(atPath: path + "/" + name, contents: Data(repeating: 0x61, count: size)) }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2024, 1, 15, 10, 30)   // shown as 11:30, as listfeel's fixture
        if let date = Calendar.current.date(from: c) {
            for name in ((try? fm.contentsOfDirectory(atPath: path)) ?? []) + [""] {
                try? fm.setAttributes([.modificationDate: date, .creationDate: date],
                                      ofItemAtPath: name.isEmpty ? path : path + "/" + name)
            }
        }
        scratch = path
        return path
    }

    /// The list's top-left 760 x 200 pt with `font`, at `scale`.
    private func renderList(font: NSFont, folder: String, scale: Int) -> CGImage? {
        ListFontChoice.override = font
        Settings.numPanels = 1
        Settings.setListMode(3, 0)
        Settings.removeKey("FM.Columns.FSFolder")
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(NSSize(width: 1000, height: 600))
        controller.showWindow(nil)
        defer { controller.window?.close() }
        let panel = controller.focusedPanel
        var done = false
        panel.navigate(to: folder) { _ in done = true }
        guard wait(for: "bound", until: { done }) else { return nil }
        controller.window?.makeFirstResponder(panel.tableView)
        panel.listFocusOverride = true
        defer { panel.listFocusOverride = nil }
        if let a = panel.rows.firstIndex(where: { $0.name == "a.txt" }) {
            panel.tableView.selectRowIndexes(IndexSet(integer: a), byExtendingSelection: false)
            panel.focusedIndex = a
            panel.refreshSelectionAppearance()
        }
        guard let content = controller.window?.contentView,
              let scroll = panel.tableView.enclosingScrollView,
              let headerClip = panel.tableView.headerView?.superview as? NSClipView else { return nil }
        let rowCount = panel.rows.count
        guard wait(for: "row views", until: {
            content.layoutSubtreeIfNeeded()
            content.displayIfNeeded()
            let table = panel.tableView
            return rowCount >= 12 && table.numberOfRows == rowCount
                && (0..<min(rowCount, 9)).allSatisfy { table.view(atColumn: 0, row: $0, makeIfNecessary: false) != nil }
        }) else { return nil }
        return Self.drawList(scroll, parts: [scroll.contentView, headerClip],
                             size: NSSize(width: 760, height: 200), scale: scale)
    }

    /// The scroll view's top-left `size`, drawn part by part: the rows' clip view, then the header's
    /// clip view over it. Drawing the window's content view (or the scroll view) as one piece is
    /// not reliable on macOS 26: in about one run in three a capture of one candidate came out
    /// with the header and **no rows** -- the scroll view, which now also holds the header's scroll
    /// pocket and backdrop views, skipped its rows' clip view, with `cacheDisplay` as with
    /// `displayIgnoringOpacity`, while that clip view drawn on its own was complete (that is how
    /// feel3-font-arial-bywidth.png was written with an empty list). Each part is drawn exactly
    /// once, so no text is drawn twice.
    static func drawList(_ scroll: NSScrollView, parts: [NSView], size: NSSize, scale: Int) -> CGImage? {
        let s = CGFloat(scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width * s), height: Int(size.height * s),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size.width * s, height: size.height * s))
        // The capture, in the scroll view's coordinates: its top-left corner.
        let b = scroll.bounds
        let region = NSRect(x: b.minX, y: scroll.isFlipped ? b.minY : b.maxY - size.height,
                            width: size.width, height: size.height)
        for part in parts {
            let inScroll = scroll.convert(part.bounds, from: part).intersection(region)
            guard !inScroll.isEmpty else { continue }
            let partRect = part.convert(inScroll, from: scroll)
            guard let image = drawUnsmoothed(part, rect: partRect, scale: scale) else { continue }
            // Top-left of the part's piece, measured from the capture's top-left.
            let dx = inScroll.minX - region.minX
            let dyTop = scroll.isFlipped ? inScroll.minY - region.minY : region.maxY - inScroll.maxY
            ctx.draw(image, in: CGRect(x: dx * s, y: (size.height - dyTop - inScroll.height) * s,
                                       width: inScroll.width * s, height: inScroll.height * s))
        }
        return ctx.makeImage()
    }

    /// The rows below the header carry ~4 000 px of ink at 1x for every candidate.
    static let minimumRowInk = 2_000.0

    /// `rect` of `view` drawn at `scale` the way the screen shows it: **without font smoothing**.
    /// `cacheDisplay(in:to:)` draws into a bitmap context that keeps Core Graphics' default font
    /// smoothing on, which on macOS 10.14+ is stem darkening -- every glyph dilated by a fraction
    /// of a device pixel, bold-looking at 1x. The window's layer backing stores (the app on
    /// screen) draw the list's text without it: an XCUITest screenshot of a row matched this
    /// rendering and not cacheDisplay's (reports/feel3.md §4, "Why the first images looked bold").
    static func drawUnsmoothed(_ view: NSView, rect: NSRect, scale: Int) -> CGImage? {
        let s = CGFloat(scale)
        guard let ctx = CGContext(data: nil, width: Int(rect.width * s), height: Int(rect.height * s),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -rect.minX, y: -rect.minY)
        ctx.setAllowsFontSmoothing(false)
        ctx.setShouldSmoothFonts(false)
        view.displayIgnoringOpacity(rect, in: NSGraphicsContext(cgContext: ctx, flipped: false))
        return ctx.makeImage()
    }

    /// Darkness (1 - mean RGB, over white) summed over the image below `top` pt, in 1x px units.
    static func ink(_ image: CGImage, below top: Int, scale: Int) -> Double {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return 0 }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let p = data.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0
        for y in min(h, top * scale)..<h {                     // row 0 of the buffer is the top
            for x in 0..<w {
                let o = y * w * 4 + x * 4
                sum += 1 - (Double(p[o]) + Double(p[o + 1]) + Double(p[o + 2])) / 765
            }
        }
        return sum / Double(scale * scale)
    }

    private func windowsCapture() -> CGImage? {
        let path = TestPaths.screenshots + "/wincompare-listfeel-list-win.png"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Windows above, the Mac below, each under a caption; `scale` 1 or 2 (Windows doubled with
    /// nearest-neighbour, so its pixels stay pixels).
    private func compose(windows: CGImage, mac: CGImage, scale: Int, macCaption: String, file: String) {
        let s = CGFloat(scale)
        let captionH = 18 * s, gap = 6 * s
        let width = 760 * s, height = captionH * 2 + 200 * s * 2 + gap
        guard let ctx = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .none
        ctx.setAllowsFontSmoothing(false)                // as the screen draws (drawUnsmoothed)
        // CG is bottom-up: Windows block on top.
        let winY = height - captionH - 200 * s
        ctx.draw(windows, in: CGRect(x: 0, y: winY, width: 760 * s, height: 200 * s))
        let macY = winY - gap - captionH - 200 * s
        ctx.draw(mac, in: CGRect(x: 0, y: macY, width: 760 * s, height: 200 * s))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 11 * s), .foregroundColor: NSColor.darkGray]
        ("Windows 11, 7zFM 26.03: Segoe UI 9 pt (12 px) at 96 dpi" + (scale == 2 ? ", pixels doubled" : "") as NSString)
            .draw(at: NSPoint(x: 4 * s, y: height - captionH + 3 * s), withAttributes: attrs)
        ("macOS: " + macCaption + (scale == 2 ? ", Retina 2x" : ", 1x") as NSString)
            .draw(at: NSPoint(x: 4 * s, y: winY - gap - captionH + 3 * s), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: TestPaths.screenshots).appendingPathComponent(file), options: .atomic)
    }

    func testFontComparisonImages() throws {
        let windows = try XCTUnwrap(windowsCapture(), "wincompare-listfeel-list-win.png")
        let folder = makeFixture()
        var shots: [(font: NSFont, caption: String, name: String)] = []
        // "current" is the default feel3 compared against, Helvetica Neue 11 (sffont made SF Pro 12.2
        // the default; the images stay what the user chose from).
        if let current = ListFontChoice.font(name: ListFontChoice.previousDefaultFontName,
                                             size: ListFontChoice.previousDefaultSize) {
            shots.append((current, "Helvetica Neue 11 (the current default)", "feel3-font-current"))
        }
        // The current family matched by height: the same font and size as helvetica-neue-byheight
        // (the default family is Helvetica Neue), asked for under its own name.
        if let c = ListFontChoice.candidates.first(where: { $0.key == "helvetica-neue-byheight" }),
           c.fontName == ListFontChoice.previousDefaultFontName,
           let font = ListFontChoice.font(name: c.fontName, size: c.size) {
            shots.append((font, c.label + " pt (the current family) matched by height (cap + x-height = 15 px)",
                          "feel3-font-current-byheight"))
        }
        for c in ListFontChoice.candidates where c.key != "helvetica-neue-11" {
            guard let font = ListFontChoice.font(name: c.fontName, size: c.size) else { continue }
            let how = c.key.hasSuffix("byheight") ? "matched by height (cap + x-height = 15 px)"
                                                  : "matched by width (summed advances = Segoe UI's)"
            shots.append((font, c.label + " pt, " + how, "feel3-font-" + c.key))
        }
        for shot in shots {
            for scale in [1, 2] {
                let mac = try XCTUnwrap(renderList(font: shot.font, folder: folder, scale: scale), shot.name)
                // An empty capture (header only) must fail, not be written.
                let ink = Self.ink(mac, below: 24, scale: scale)
                XCTAssertGreaterThan(ink, Self.minimumRowInk, "\(shot.name) at \(scale)x: the Mac list has no rows (ink \(Int(ink)))")
                compose(windows: windows, mac: mac, scale: scale, macCaption: shot.caption,
                        file: shot.name + (scale == 2 ? "-2x" : "") + ".png")
            }
        }
    }
}
