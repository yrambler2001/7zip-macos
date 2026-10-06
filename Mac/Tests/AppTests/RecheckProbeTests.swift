// RecheckProbeTests.swift -- the Mac half of the `recheck` measurements (ai/reports/recheck.md):
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

    // MARK: keyboard sequence of rc1 §B

    private func key(_ window: NSWindow, _ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: chars,
                                           charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) else { continue }
            window.sendEvent(e)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    func testProbeKeys() {
        let cmp = base + "/recheck/cmp"
        let c = freshWindow(panels: 1)
        guard let window = c.window else { return XCTFail("no window") }
        let p = c.focusedPanel
        bind(p, cmp)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(p.tableView)
        var log = ""
        func state(_ what: String) {
            log += "KEY \(what) : focused=\(p.focusedIndex) selcount=\(p.tableView.selectedRowIndexes.count) firstResponder=\(type(of: window.firstResponder!)) status=\(p.statusBarTexts.first ?? "")\n"
        }
        state("start")
        key(window, "\u{F729}", 115); state("Home")
        key(window, "\u{F746}", 114); state("Insert")
        key(window, " ", 49); state("Space")
        key(window, "*", 67, .numericPad); state("Num*")
        key(window, "*", 67, .numericPad); state("Num*2")
        key(window, "\u{F72B}", 119); state("End")
        key(window, "\u{F700}", 126, [.shift, .numericPad, .function]); state("Shift+Up")
        key(window, "\u{F729}", 115); key(window, "n", 45); state("type n")
        key(window, "a", 0); state("type a")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        key(window, "e", 14); key(window, "n", 45); state("type en (after pause)")
        key(window, "\u{F701}", 125, [.numericPad, .function]); state("Down")
        key(window, " ", 49, .command); state("Cmd+Space")
        key(window, "\u{F700}", 126, [.command, .numericPad, .function]); state("Cmd+Up")
        key(window, " ", 49, .command); state("Cmd+Space2")
        key(window, "a", 0, .command); state("Cmd+A")
        key(window, "\u{F729}", 115); state("Home after Cmd+A")
        for i in 1...3 { key(window, "\t", 48); state("Tab \(i)") }
        for i in 1...2 { key(window, "\u{19}", 48, .shift); state("ShiftTab \(i)") }
        save("keys.txt", log)
    }

    func testProbeWheel() throws {
        let dir = base + "/recheck/many"
        let fm = FileManager.default
        try? fm.removeItem(atPath: dir)
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for i in 1...120 { fm.createFile(atPath: dir + String(format: "/f%03d.txt", i), contents: Data("x".utf8)) }
        let c = freshWindow(panels: 1)
        guard let window = c.window else { return XCTFail("no window") }
        window.setContentSize(NSSize(width: 900, height: 600))
        let p = c.focusedPanel
        bind(p, dir)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let scroll = p.tableView.enclosingScrollView else { return XCTFail("no scroll view") }
        var log = "lineScroll=\(scroll.verticalLineScroll) rowHeight=\(p.tableView.rowHeight)\n"
        for notch in 1...3 {
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0),
                  let e = NSEvent(cgEvent: cg) else { continue }
            scroll.scrollWheel(with: e)
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
            log += "notch \(notch): y=\(scroll.contentView.bounds.origin.y) topRow=\(p.tableView.rows(in: scroll.contentView.bounds).location) deltaY=\(e.scrollingDeltaY) precise=\(e.hasPreciseScrollingDeltas)\n"
        }
        save("wheel.txt", log)
        try? fm.removeItem(atPath: dir)
    }
}
