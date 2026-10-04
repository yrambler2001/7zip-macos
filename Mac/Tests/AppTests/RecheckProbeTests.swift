// RecheckProbeTests.swift -- the Mac half of the `recheck` measurements (Mac/docs/reports/recheck.md):
// the whole main window on a fresh default, rendered at 1x with its frame, plus a view-tree dump
// and the menu bar with key equivalents, written to Mac/build/recheck/out. Runs only when
// Mac/build/recheck/PROBE and the fixture folder Mac/build/recheck/cmp exist, so normal runs skip it.

import AppKit
import XCTest
@testable import SevenZipAppHost

final class RecheckProbeTests: AppHostTestCase {

    override var screenshotPrefix: String { "recheck" }

    private var controllers: [MainWindowController] = []
    private var saved: [String: Any] = [:]
    private var savedAppearance: NSAppearance?

    private var base: String { (TestPaths.repoRoot ?? "/tmp") + "/Mac/build" }
    private var outDir: String { base + "/recheck/out" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: base + "/recheck/PROBE")
                          && FileManager.default.fileExists(atPath: base + "/recheck/cmp"),
                          "recheck probe not requested")
        try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        savedAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() {
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for c in controllers { c.closeDiscardingState() }
        controllers = []
        NSApp.appearance = savedAppearance
        super.tearDown()
    }

    private func save(_ name: String, _ text: String) {
        try? text.write(toFile: outDir + "/" + name, atomically: true, encoding: .utf8)
    }

    /// The window's frame view (title bar included) at 1x.
    private func render(_ window: NSWindow, _ name: String) {
        guard let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        let rect = frameView.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = rect.size
        frameView.cacheDisplay(in: rect, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: outDir + "/" + name))
    }

    private func freshWindow(panels: Int) -> MainWindowController {
        Settings.removeKey("FM.Columns.FSFolder")
        Settings.windowFrame = nil
        Settings.maximized = false
        Settings.numPanels = panels
        Settings.setListMode(3, 0)
        Settings.setListMode(3, 1)
        let c = MainWindowController()
        controllers.append(c)
        c.showWindow(nil)
        return c
    }

    private func bind(_ panel: PanelViewController, _ path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "bound \(path)") { done })
    }

    func testProbeMainWindow() {
        let cmp = base + "/recheck/cmp"
        let c = freshWindow(panels: 1)
        guard let window = c.window else { return XCTFail("no window") }
        let screen = window.screen ?? NSScreen.main
        save("fresh-frame.txt", "frame=\(window.frame) content=\(window.contentRect(forFrameRect: window.frame)) "
             + "screen=\(screen?.frame ?? .zero) visible=\(screen?.visibleFrame ?? .zero) "
             + "background=\(window.backgroundColor.usingColorSpace(.sRGB).map { "\($0.redComponent * 255),\($0.greenComponent * 255),\($0.blueComponent * 255)" } ?? "?")\n")
        bind(c.focusedPanel, cmp)
        window.makeFirstResponder(c.focusedPanel.tableView)
        window.setContentSize(NSSize(width: 1424, height: 694))
        window.contentView?.layoutSubtreeIfNeeded()
        save("fresh.txt", WinCompareDump.window(window))
        render(window, "fresh-mac.png")
        save("menu-main.txt", WinCompareDump.menu(NSApp.mainMenu ?? NSMenu()) { _ in true })

        c.viewTwoPanels(nil)
        if c.panels.count > 1 { bind(c.panels[1], cmp) }
        window.contentView?.layoutSubtreeIfNeeded()
        save("two.txt", WinCompareDump.window(window))
        render(window, "two-mac.png")
    }
}
