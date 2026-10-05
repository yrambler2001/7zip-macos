// Feel3FontTests.swift -- the font comparison images for the user's choice (reports/feel3.md §4):
// for every FM.ListFont candidate, matched to Segoe UI 9 pt by height and by width, the same file
// list rendered by the real panel under the Windows capture of 7zFM 26.03
// (`wincompare-listfeel-list-win.png`, 760 x 200 px at 96 dpi): one image at 1x (1 Windows px =
// 1 Mac pt) and one at 2x (the Windows pixels doubled, the Mac rendered at Retina scale).
//
// Writes Mac/docs/reports/screenshots/feel3-font-<candidate>-<byheight|bywidth>[-2x].png and
// feel3-font-current[-2x].png (the default, Helvetica Neue 11).

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
        guard let content = controller.window?.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        let list: NSView = panel.tableView.enclosingScrollView ?? panel.tableView
        var rect = list.convert(list.bounds, to: content)
        rect = NSRect(x: rect.minX, y: rect.maxY - 200, width: 760, height: 200)
        guard let raw = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 760 * scale, pixelsHigh: 200 * scale,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
              let rep = raw.retagging(with: .sRGB) else { return nil }
        rep.size = rect.size
        content.cacheDisplay(in: rect, to: rep)
        return rep.cgImage
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
        if let current = ListFontChoice.font(name: ListFontChoice.defaultFontName, size: ListFontChoice.defaultSize) {
            shots.append((current, "Helvetica Neue 11 (the current default)", "feel3-font-current"))
        }
        for c in ListFontChoice.candidates {
            guard let font = ListFontChoice.font(name: c.fontName, size: c.size) else { continue }
            let how = c.key.hasSuffix("byheight") ? "matched by height (cap + x-height = 15 px)"
                                                  : "matched by width (summed advances = Segoe UI's)"
            shots.append((font, c.label + " pt, " + how, "feel3-font-" + c.key))
        }
        for shot in shots {
            for scale in [1, 2] {
                let mac = try XCTUnwrap(renderList(font: shot.font, folder: folder, scale: scale), shot.name)
                compose(windows: windows, mac: mac, scale: scale, macCaption: shot.caption,
                        file: shot.name + (scale == 2 ? "-2x" : "") + ".png")
            }
        }
    }
}
