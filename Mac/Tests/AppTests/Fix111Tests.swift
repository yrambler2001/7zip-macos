// Fix111Tests.swift -- the 1.1.1 fixes in the real panel (ai/reports/fix111.md):
//
//   1. an app bundle (a Chrome web-app shim in ~/Applications/Chrome Apps.localized, a copied
//      application) opens as a folder; it used to be tried as an archive and fail with
//      "E_FAIL Unspecified error"; a folder of odd entries opens without a message;
//   2. every row's text sits on the same baseline, whatever characters the name holds (the CR of
//      the Finder's "Icon\r" started a second line and pushed the name up);
//   3. the header sorts on a click and reverses on a second one, View > Arrange By follows it;
//   4. the status bar's text insets.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class Fix111Tests: AppHostTestCase {

    override var screenshotPrefix: String { "fix111" }

    private var controllers: [MainWindowController] = []
    private var scratchDirectories: [String] = []
    private var savedNumPanels = 1
    private var savedPanelPaths: [String?] = []
    private var savedListModes: [Int] = []
    private var savedAppearance: NSAppearance?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedNumPanels = Settings.numPanels
        savedPanelPaths = [Settings.panelPath(0), Settings.panelPath(1)]
        savedListModes = [Settings.listMode(0), Settings.listMode(1)]
        savedAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() {
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for controller in controllers { controller.window?.close() }
        controllers = []
        for path in scratchDirectories {
            if let walker = FileManager.default.enumerator(atPath: path) {
                for case let rel as String in walker { chmod(path + "/" + rel, 0o755) }
            }
            try? FileManager.default.removeItem(atPath: path)
        }
        scratchDirectories = []
        for (i, path) in savedPanelPaths.enumerated() { Settings.setPanelPath(path, i) }
        for (i, mode) in savedListModes.enumerated() { Settings.setListMode(mode, i) }
        Settings.numPanels = savedNumPanels
        NSApp.appearance = savedAppearance
        super.tearDown()
    }

    // MARK: helpers

    private func makeScratch(_ name: String) -> String {
        let path = (TestPaths.artifacts as NSString).appendingPathComponent("fix111-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        scratchDirectories.append(path)
        return path
    }

    private func touch(_ path: String, _ text: String = "") {
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data(text.utf8)), path)
    }

    private func setXattr(_ path: String, _ name: String, _ value: [UInt8]) {
        _ = value.withUnsafeBytes { setxattr(path, name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
    }

    /// A Chrome "web app" shim as Chrome writes it.
    private func makeChromeShim(_ path: String) {
        let fm = FileManager.default
        for dir in ["Contents/MacOS", "Contents/Resources/en-US.lproj", "Contents/_CodeSignature"] {
            try? fm.createDirectory(atPath: path + "/" + dir, withIntermediateDirectories: true)
        }
        touch(path + "/Contents/Info.plist", "<plist><dict/></plist>")
        touch(path + "/Contents/PkgInfo", "APPL????")
        touch(path + "/Contents/MacOS/app_mode_loader", "#!/bin/sh\n")
        chmod(path + "/Contents/MacOS/app_mode_loader", 0o755)
        touch(path + "/Contents/Resources/app.icns")
        chmod(path + "/Contents/Resources", 0o700)
        touch(path + "/Contents/_CodeSignature/CodeResources")
        setXattr(path, "com.apple.FinderInfo", [UInt8](repeating: 0, count: 32))
    }

    private func makeWindow(size: NSSize = NSSize(width: 1000, height: 600)) -> MainWindowController {
        Settings.numPanels = 1
        Settings.setListMode(3, 0)
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(size)
        controller.showWindow(nil)
        return controller
    }

    private func navigate(_ panel: PanelViewController, to path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
        panel.view.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func rowIndex(_ panel: PanelViewController, _ name: String) -> Int {
        panel.rows.firstIndex { $0.name == name } ?? -1
    }

    // MARK: - 1. app bundles and odd entries

    /// ~/Applications/Chrome Apps.localized/<web app>.app: the folder lists, Enter on the app shim
    /// enters it (7zFM: IsItem_Folder -> OpenFolder), and nothing reports an error.
    func testChromeAppShimOpensAsAFolder() throws {
        let scratch = makeScratch("apps")
        let apps = scratch + "/Chrome Apps.localized"
        let shimName = "Panasonic - Osprzęt elektroinstalacyjny.app"
        makeChromeShim(apps + "/" + shimName)
        touch(apps + "/Icon\r")
        setXattr(apps + "/Icon\r", "com.apple.ResourceFork", Array(repeating: 3, count: 900))
        try FileManager.default.createDirectory(atPath: apps + "/.localized", withIntermediateDirectories: true)
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: apps)
        XCTAssertEqual(panel.currentPath, apps + "/")
        let shim = rowIndex(panel, shimName)
        XCTAssertGreaterThanOrEqual(shim, 0, "rows: \(panel.rows.map(\.name))")
        XCTAssertGreaterThanOrEqual(rowIndex(panel, "Icon\r"), 0)

        panel.openRow(panel.rows[shim], insideOnly: false, formatHint: nil)
        XCTAssertTrue(wait(for: "entered the app shim") { panel.currentPath == apps + "/" + shimName + "/" },
                      "path \(panel.currentPath)")
        XCTAssertEqual(panel.rows.filter { !$0.isParentRow }.map(\.name), ["Contents"])
        let contents = try XCTUnwrap(panel.rows.first { $0.name == "Contents" })
        panel.openRow(contents, insideOnly: false, formatHint: nil)
        XCTAssertTrue(wait(for: "entered Contents") { panel.currentPath.hasSuffix(shimName + "/Contents/") })
        XCTAssertEqual(Set(panel.rows.filter { !$0.isParentRow }.map(\.name)),
                       ["MacOS", "Resources", "_CodeSignature", "Info.plist", "PkgInfo"])
        XCTAssertTrue(recordedBoxes.isEmpty, "message boxes: \(recordedBoxes.map(\.text))")

        // A real application bundle, from the address bar.
        navigate(panel, to: "/System/Applications/Calculator.app")
        XCTAssertEqual(panel.currentPath, "/System/Applications/Calculator.app/")
        XCTAssertEqual(panel.rows.filter { !$0.isParentRow }.map(\.name), ["Contents"])
        XCTAssertTrue(recordedBoxes.isEmpty, "message boxes: \(recordedBoxes.map(\.text))")
    }

    /// Broken and looping links, unreadable entries, a FIFO, resource forks, names with control
    /// characters and emoji: the folder opens without a message and lists every entry.
    func testOddEntriesOpenWithoutAnError() throws {
        let dir = makeScratch("odd")
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: dir + "/broken", withDestinationPath: "nowhere")
        try fm.createSymbolicLink(atPath: dir + "/loop1", withDestinationPath: "loop2")
        try fm.createSymbolicLink(atPath: dir + "/loop2", withDestinationPath: "loop1")
        try fm.createDirectory(atPath: dir + "/noread", withIntermediateDirectories: true)
        chmod(dir + "/noread", 0)
        touch(dir + "/nofile", "x")
        chmod(dir + "/nofile", 0)
        XCTAssertEqual(mkfifo(dir + "/pipe", 0o644), 0)
        touch(dir + "/rsrc", "data")
        setXattr(dir + "/rsrc", "com.apple.ResourceFork", Array(repeating: 1, count: 4000))
        for name in ["Icon\r", "two\nlines", "emoji 😀🇺🇦.txt"] { touch(dir + "/" + name) }
        makeChromeShim(dir + "/Shim.app")
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: dir)
        XCTAssertEqual(panel.currentPath, dir + "/")
        XCTAssertEqual(Set(panel.rows.filter { !$0.isParentRow }.map(\.name)),
                       ["broken", "loop1", "loop2", "noread", "nofile", "pipe", "rsrc", "Icon\r", "two\nlines",
                        "emoji 😀🇺🇦.txt", "Shim.app"])
        XCTAssertTrue(recordedBoxes.isEmpty, "message boxes: \(recordedBoxes.map(\.text))")
        // the list draws every row (icons, cells) without trouble
        panel.tableView.layoutSubtreeIfNeeded()
        _ = panel.tableView.bitmapImageRepForCachingDisplay(in: panel.tableView.visibleRect)
    }

    // MARK: - 2. one baseline for every row

    /// Names with a CR (the Finder's "Icon\r"), an LF, a tab, emoji, Arabic, stacked combining
    /// marks, Tibetan and Thai stacks: every name's text field puts its first baseline where a
    /// plain ASCII name's is, and its text stays on one line inside the row.
    func testEveryRowSharesOneBaseline() throws {
        let dir = makeScratch("baseline")
        let names = ["Icon\r", "Icon", "plain.txt", "two\nlines", "cr\r\nlf.txt", "tab\there", "bell\u{7}.txt",
                     "emoji 😀🇺🇦👩‍👩‍👧.txt", "عربي.txt", "Z̷̢̛͓a̸l̶g̵o̴.txt", "ཀྵྐྵྐྵ.txt", "ด้้้้้้้.txt",
                     "日本語.txt", "\u{2028}sep.txt"]
        for name in names { touch(dir + "/" + name) }
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: dir)
        let table = panel.tableView
        let nameColumn = try XCTUnwrap(table.tableColumns.firstIndex { PanelViewController.propID(of: $0) == .name })
        let plain = rowIndex(panel, "plain.txt")
        func baseline(_ row: Int) throws -> (CGFloat, NSTextField) {
            let cell = try XCTUnwrap(table.view(atColumn: nameColumn, row: row, makeIfNecessary: true) as? PanelCellView)
            cell.layoutSubtreeIfNeeded()
            let field = try XCTUnwrap(cell.textField)
            let top = field.convert(NSPoint(x: 0, y: field.isFlipped ? 0 : field.bounds.height), to: cell)
            let fromRowTop = cell.isFlipped ? top.y : cell.bounds.height - top.y
            return (fromRowTop + field.firstBaselineOffsetFromTop, field)
        }
        let (reference, _) = try baseline(plain)
        XCTAssertEqual(reference, PanelMetrics.textBaseline(for: PanelMetrics.listFont), accuracy: 0.01)
        for name in names {
            let row = rowIndex(panel, name)
            XCTAssertGreaterThanOrEqual(row, 0, name.debugDescription)
            let (b, field) = try baseline(row)
            XCTAssertEqual(b, reference, accuracy: 0.01, "\(name.debugDescription): baseline \(b), plain \(reference)")
            XCTAssertFalse(field.stringValue.unicodeScalars.contains { Formatting.isControl($0) },
                           "\(name.debugDescription) shows \(field.stringValue.debugDescription)")
        }
        // The CR name draws its text on the same rows of pixels as a plain one.
        let iconRow = rowIndex(panel, "Icon\r")
        XCTAssertEqual(panel.rows[iconRow].displayName, "Icon")
        if let window = panel.view.window { attach(window, "02-baselines") }
        let ink = { (row: Int) -> NSRect? in self.inkBox(table, row: row, column: nameColumn) }
        let iconInk = try XCTUnwrap(ink(iconRow))
        let plainInk = try XCTUnwrap(ink(rowIndex(panel, "Icon")))
        XCTAssertEqual(iconInk, plainInk, "Icon\\r ink \(iconInk) vs Icon \(plainInk)")
    }

    /// Other columns show LF and CR as spaces (PanelListNotify.cpp:470-479), the name column
    /// draws nothing for a control character, and a name of control characters only shows "_".
    func testControlCharactersInCellText() {
        XCTAssertEqual(Formatting.displayName("Icon\r"), "Icon")
        XCTAssertEqual(Formatting.displayName("a\nb\tc\u{7}"), "abc")
        XCTAssertEqual(Formatting.displayName("\r"), "_")
        XCTAssertEqual(Formatting.displayName("x\u{202E}y"), "x_y")
        XCTAssertEqual(Formatting.oneLine("line 1\r\nline 2"), "line 1  line 2")
        XCTAssertEqual(Formatting.oneLine("plain"), "plain")
    }

    // MARK: - rendering helpers

    /// The bounding box (row coordinates, from the row's top) of the dark pixels of a cell.
    private func inkBox(_ table: NSTableView, row: Int, column: Int) -> NSRect? {
        let rect = table.frameOfCell(atColumn: column, row: row).integral
        guard let raw = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width) * 2,
                                         pixelsHigh: Int(rect.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 32),
              let rep = raw.retagging(with: .sRGB), let data = rep.bitmapData else { return nil }
        rep.size = rect.size
        table.cacheDisplay(in: rect, to: rep)
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        // skip the icon: text only (from the label's x)
        let startX = Int(PanelMetrics.labelX) * 2
        for y in 0..<rep.pixelsHigh {
            for x in startX..<rep.pixelsWide {
                let p = data + y * rep.bytesPerRow + x * 4
                let a = Int(p[3])
                let lum = (Int(p[0]) + 255 - a + Int(p[1]) + 255 - a + Int(p[2]) + 255 - a) / 3
                if lum < 140 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= 0 else { return nil }
        return NSRect(x: CGFloat(minX) / 2, y: CGFloat(minY) / 2,
                      width: CGFloat(maxX - minX + 1) / 2, height: CGFloat(maxY - minY + 1) / 2)
    }
}
