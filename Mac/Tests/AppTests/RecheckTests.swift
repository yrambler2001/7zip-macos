// RecheckTests.swift -- regression tests for the `recheck` fixes (Mac/docs/reports/recheck.md),
// each against a number measured on fresh-default 7zFM 26.03 on Windows 11 at 96 dpi
// (recheck-data/win/).

import AppKit
import XCTest
@testable import SevenZipAppHost

final class RecheckTests: AppHostTestCase {

    override var screenshotPrefix: String { "recheck" }

    private var controllers: [MainWindowController] = []
    private var windows: [NSWindow] = []
    private var savedAppearance: NSAppearance?
    private var savedNumPanels = 1
    private var savedPanelPath: String?
    private var savedListModes: [Int] = [3, 3]

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedAppearance = NSApp.appearance
        savedNumPanels = Settings.numPanels
        savedPanelPath = Settings.panelPath(0)
        savedListModes = [Settings.listMode(0), Settings.listMode(1)]
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() {
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for c in controllers { c.closeDiscardingState() }
        controllers = []
        for w in windows { w.orderOut(nil) }
        windows = []
        Settings.numPanels = savedNumPanels
        Settings.setPanelPath(savedPanelPath, 0)
        for (i, mode) in savedListModes.enumerated() { Settings.setListMode(mode, i) }
        NSApp.appearance = savedAppearance
        super.tearDown()
    }

    // MARK: helpers

    private struct Pixels {
        let rep: NSBitmapImageRep
        /// (x, y) in points from the content area's top-left.
        let top: Int
        func rgb(_ x: Int, _ y: Int) -> [Int] {
            var p = [Int](repeating: 0, count: 5)
            rep.getPixel(&p, atX: x, y: y + top)
            return [p[0], p[1], p[2]]
        }
    }

    /// The window with its frame view, at 1x; `top` is the title bar's height.
    private func render(_ window: NSWindow) -> Pixels? {
        guard let frameView = window.contentView?.superview else { return nil }
        window.contentView?.layoutSubtreeIfNeeded()
        let rect = frameView.bounds
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = rect.size
        frameView.cacheDisplay(in: rect, to: rep)
        let top = Int(rect.height - window.contentLayoutRect.height)
        return Pixels(rep: rep, top: top)
    }

    private func mainWindow(panels: Int = 1) -> MainWindowController {
        Settings.numPanels = panels
        Settings.setPanelPath(NSTemporaryDirectory(), 0)
        Settings.setListMode(3, 0)                    // Details, whatever an earlier test left
        Settings.setListMode(3, 1)
        let c = MainWindowController()
        controllers.append(c)
        c.window?.setContentSize(NSSize(width: 900, height: 500))
        c.showWindow(nil)
        c.window?.contentView?.layoutSubtreeIfNeeded()
        return c
    }

    // MARK: - §2 main window chrome

    /// COLOR_BTNFACE around the toolbar and in the status bar, the white address band with its
    /// combo border, the list's client edge, the status bar's line and divider: the rows and
    /// columns of `recheck-data/win/fresh-screen.png`, mapped to the Mac's content area.
    func testMainWindowChromeColoursAndGeometry() throws {
        let c = mainWindow()
        let window = try XCTUnwrap(c.window)
        XCTAssertEqual(window.backgroundColor.usingColorSpace(.sRGB)?.redComponent ?? 0, 240 / 255, accuracy: 0.002)
        let px = try XCTUnwrap(render(window))
        let h = Int(window.contentLayoutRect.height)
        // toolbar strip: etched line 160 / 255, then 240 down to y 51
        XCTAssertEqual(px.rgb(600, 0), [160, 160, 160])
        XCTAssertEqual(px.rgb(600, 1), [255, 255, 255])
        XCTAssertEqual(px.rgb(600, 20), [240, 240, 240])
        XCTAssertEqual(px.rgb(600, 51), [240, 240, 240])
        // address band at y 52: combo border (141) on rows 52 and 75, white inside
        XCTAssertEqual(px.rgb(600, 52), [141, 141, 141])
        XCTAssertEqual(px.rgb(600, 60), [255, 255, 255])
        XCTAssertEqual(px.rgb(600, 75), [141, 141, 141])
        XCTAssertEqual(px.rgb(33, 60), [141, 141, 141], "combo's left border at x 33")
        XCTAssertEqual(px.rgb(31, 60), [180, 180, 180], "band border")
        XCTAssertEqual(px.rgb(12, 75), [220, 220, 220], "band bottom under the Up button")
        // the list's client edge at y 76, white inside
        XCTAssertEqual(px.rgb(600, 76), [130, 135, 144])
        XCTAssertEqual(px.rgb(0, 300), [130, 135, 144])
        // status bar: 23 px, line (215) on top, BTNFACE, a divider at x 219 on rows 2..21
        XCTAssertEqual(px.rgb(600, h - 24), [130, 135, 144], "list bottom edge")
        XCTAssertEqual(px.rgb(600, h - 23), [215, 215, 215])
        XCTAssertEqual(px.rgb(600, h - 12), [240, 240, 240])
        XCTAssertEqual(px.rgb(219, h - 12), [215, 215, 215])
        XCTAssertEqual(px.rgb(219, h - 22), [240, 240, 240])
    }

    /// No active-panel highlight (7zFM has none) and a plain 4 px splitter of BTNFACE.
    func testTwoPanelsHaveNoActiveHighlightAndAPlainSplitter() throws {
        let c = mainWindow(panels: 2)
        let window = try XCTUnwrap(c.window)
        let px = try XCTUnwrap(render(window))
        let left = c.panels[0].view.frame.width
        let x = Int(left)
        for dx in 0..<4 { XCTAssertEqual(px.rgb(x + dx, 300), [240, 240, 240], "splitter column \(dx)") }
        XCTAssertEqual(px.rgb(x - 1, 300), [130, 135, 144])
        XCTAssertEqual(px.rgb(x + 4, 300), [130, 135, 144])
        // both bands white under the Up button, whichever panel is active
        XCTAssertEqual(px.rgb(28, 62), [255, 255, 255])
        XCTAssertEqual(px.rgb(x + 4 + 28, 62), [255, 255, 255])
    }

    /// The toolbar's text buttons are 42 x 46 with the GUI font, as on Windows (fresh.txt).
    func testToolbarTextButtonsAreTheWindowsSize() throws {
        let c = mainWindow()
        let strip = try XCTUnwrap(Self.find(FMToolbarView.self, in: c.window?.contentView))
        XCTAssertEqual(strip.buttonSize, NSSize(width: 42, height: 46))
        XCTAssertEqual(strip.frame.height, 52)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let v = view as? T { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }

    // MARK: - §5 progress window

    func testProgressSizesUseConvertSizeToString() {
        XCTAssertEqual(ProgressFormatting.size(0), "0")
        XCTAssertEqual(ProgressFormatting.size(99_999), "99999")
        XCTAssertEqual(ProgressFormatting.size(69_206_016), "67584 KB")          // measured
        XCTAssertEqual(ProgressFormatting.size(356_515_840), "340 MB")
        XCTAssertEqual(ProgressFormatting.size(6_000_000_000), "5722 MB")
        XCTAssertEqual(ProgressFormatting.size(UInt64(100_000) << 30), "100000 GB")
    }

    /// "Paused 29% Checksum calculating...", "47% Background Checksum calculating...", the main
    /// window's title "<prefix> Checksum calculating... 7-Zip" meanwhile, and its own title back
    /// afterwards; the percentage moves only when the elapsed second changes.
    func testProgressTitlesAndTheMainWindowTitle() throws {
        let progress = ProgressDialog(title: "Checksum calculating...", showCompressionInfo: false)
        windows.append(progress.window)
        let main = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        main.title = "/Users/x/"
        windows.append(main)
        progress.mainWindow = main
        var s = ProgressSnapshot()
        s.totalBytes = 1000
        s.completedBytes = 10
        s.elapsed = 0.2
        progress.update(s)
        XCTAssertEqual(progress.window.title, "1% Checksum calculating...")
        XCTAssertEqual(main.title, "1% Checksum calculating... 7-Zip")
        s.completedBytes = 290
        s.elapsed = 0.8
        progress.update(s)
        XCTAssertEqual(progress.window.title, "1% Checksum calculating...", "same second: no new percent")
        s.elapsed = 1.0
        progress.update(s)
        XCTAssertEqual(progress.window.title, "29% Checksum calculating...")
        s.paused = true
        s.elapsed = 1.2
        progress.update(s)
        XCTAssertEqual(progress.window.title, "Paused 29% Checksum calculating...")
        XCTAssertEqual(main.title, "Paused 29% Checksum calculating... 7-Zip")
        s.paused = false
        s.completedBytes = 470
        s.elapsed = 2.0
        progress.update(s)
        let background = try XCTUnwrap(Self.button(titled: "Background", in: progress.window.contentView))
        background.performClick(nil)
        XCTAssertEqual(progress.window.title, "47% Background Checksum calculating...")
        XCTAssertEqual(main.title, "47% Background Checksum calculating... 7-Zip")
        progress.restoreMainWindowTitle()
        XCTAssertEqual(main.title, "/Users/x/")
    }

    private static func button(titled title: String, in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let b = view as? NSButton, b.title.replacingOccurrences(of: "&", with: "") == title { return b }
        for sub in view.subviews { if let b = button(titled: title, in: sub) { return b } }
        return nil
    }

    // MARK: - §3 keyboard and wheel

    private func folderWith(_ count: Int) throws -> String {
        let dir = NSTemporaryDirectory() + "recheck-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for i in 1...count { FileManager.default.createFile(atPath: dir + String(format: "/f%03d.txt", i), contents: Data("x".utf8)) }
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    private func boundWindow(_ path: String) -> (NSWindow, PanelViewController)? {
        let c = mainWindow()
        guard let window = c.window else { return nil }
        let p = c.focusedPanel
        var done = false
        p.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "bound") { done })
        // Let the file-system watcher's late notice for the files just created land first: an
        // auto-refresh in the middle of the key sequence restores the old focus.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(p.tableView)
        return (window, p)
    }

    private func key(_ window: NSWindow, _ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: window.windowNumber,
                                        context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                window.sendEvent(e)
            }
        }
    }

    /// The list control's keys, measured on 7zFM (rc1-log.txt): Home selects the first item,
    /// Num * keeps the focus, End focuses and selects the last, Shift+Up focuses the one above
    /// and selects both, Page Down goes to the last visible row first, Shift+Tab stays in the list.
    func testListKeysMoveLikeTheListControl() throws {
        let dir = try folderWith(60)
        let (window, p) = try XCTUnwrap(boundWindow(dir))
        XCTAssertEqual(p.selectedIndexes.count, 0)
        key(window, "\u{F729}", 115, .function)
        XCTAssertEqual(p.focusedIndex, 0); XCTAssertEqual(p.selectedIndexes, IndexSet(integer: 0))
        key(window, "*", 67, .numericPad)
        XCTAssertEqual(p.focusedIndex, 0, "Num * keeps the focus"); XCTAssertEqual(p.selectedIndexes.count, 59)
        key(window, "*", 67, .numericPad)
        XCTAssertEqual(p.selectedIndexes, IndexSet(integer: 0))
        key(window, "\u{F72B}", 119, .function)
        XCTAssertEqual(p.focusedIndex, 59); XCTAssertEqual(p.selectedIndexes, IndexSet(integer: 59))
        key(window, "\u{F700}", 126, [.shift, .numericPad, .function])
        XCTAssertEqual(p.focusedIndex, 58); XCTAssertEqual(p.selectedIndexes, IndexSet(58...59))
        key(window, "\u{F729}", 115, .function)
        key(window, "\u{F72D}", 121, .function)                         // Page Down
        let visible = p.tableView.rows(in: p.tableView.visibleRect.insetBy(dx: 0, dy: 1))
        XCTAssertEqual(p.focusedIndex, visible.location + visible.length - 1, "to the last visible row first")
        XCTAssertEqual(p.selectedIndexes.count, 1)
        key(window, "\u{19}", 48, .shift)
        XCTAssertTrue(window.firstResponder === p.tableView, "Shift+Tab stays in the list")
    }

    /// One wheel notch (a line-based scroll event) scrolls three rows, SPI_GETWHEELSCROLLLINES.
    func testWheelNotchScrollsThreeRows() throws {
        let dir = try folderWith(120)
        let (_, p) = try XCTUnwrap(boundWindow(dir))
        let scroll = try XCTUnwrap(p.tableView.enclosingScrollView)
        let y0 = scroll.contentView.bounds.origin.y
        let cg = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: -1, wheel2: 0, wheel3: 0))
        scroll.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: cg)))
        XCTAssertEqual(scroll.contentView.bounds.origin.y - y0, 3 * PanelMetrics.rowHeight, accuracy: 0.5)
    }

    // MARK: - §6 dialogs: Tab order, Esc

    private func tabChain(_ present: () -> Void) -> [String] {
        var lines: [String] = []
        let appeared = ModalProbe.present(timeout: 30, present) { window in
            lines = DialogKeys.dump("x", window).split(separator: "\n").map(String.init)
        }
        XCTAssertTrue(appeared)
        return lines.filter { $0.hasPrefix("  tab ") }.map { String($0.split(separator: ":", maxSplits: 1)[1]).trimmingCharacters(in: .whitespaces) }
    }

    /// Tab walks the controls in .rc template order, as on 7zFM (recheck-data/win/keys.txt).
    func testDialogTabOrderFollowsTheTemplate() {
        let copy = tabChain { _ = CopyMoveDialog.run(move: false, value: "/tmp/", history: [], info: "", parent: nil) }
        XCTAssertEqual(copy, ["NSButton '...'", "NSButton 'OK'", "NSButton 'Cancel'", "WinComboBox '/tmp/'"])   // feel3: the Windows-drawn combo
        let link = tabChain {
            _ = LinkDialog.run(currentDirPrefix: TestPaths.fixtures + "/", filePath: TestPaths.fixture("test.7z"),
                               anotherPath: "/tmp", parent: nil)
        }
        XCTAssertEqual(link.filter { $0.contains("Link'") || $0.contains("Hard") }, ["NSButton 'Hard Link'", "NSButton 'Link'"],
                       "the radio group is one Tab stop")
        var pw = PasswordDialog.Options()
        pw.subject = "a.7z"
        let password = tabChain { _ = PasswordDialog.run(pw, parent: nil) }
        XCTAssertEqual(password, ["NSButton 'Show password'", "NSButton 'OK'", "NSButton 'Cancel'", "NSSecureTextField ''"])
    }

    /// Esc closes About, which has no Cancel button (DefDlgProc -> IDCANCEL).
    func testEscapeClosesAbout() {
        var closed = false
        let appeared = ModalProbe.present(timeout: 30, { AboutDialog.show(parent: nil); closed = true }) { window in
            window.cancelOperation(nil)
        }
        XCTAssertTrue(appeared)
        XCTAssertTrue(wait(for: "About closed by Esc", timeout: 5) { closed })
    }

    /// CW_USEDEFAULT: 1440 x 753 at the work area's top-left cascade slot for a 1920 x 1032 area.
    func testDefaultWindowFrameIsTheWindowsDefault() {
        let frame = MainWindowController.defaultFrame(in: NSRect(x: 0, y: 48, width: 1920, height: 1032))
        XCTAssertEqual(frame.size, NSSize(width: 1440, height: 753))
        XCTAssertEqual(frame.minX, 26)
        XCTAssertEqual(frame.maxY, 48 + 1032 - 26)
    }
}
