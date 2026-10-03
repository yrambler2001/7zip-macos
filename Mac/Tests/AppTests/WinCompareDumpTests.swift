// WinCompareDumpTests.swift -- the macOS half of the side-by-side comparison with the real 7zFM
// (Mac/docs/reports/wincompare.md). It drives the app's own windows over the same fixture folder
// the Windows half used and writes text dumps to Mac/build/wincompare/out plus the paired
// screenshots `wincompare-<area>-mac.png`.
//
// It only runs when the fixture folder exists (`Mac/build/wincompare/cmp`, or WINCOMPARE_FIXTURES),
// so a normal `test.sh -H` skips it. The fixture is built by the commands in wincompare.md §1.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class WinCompareDumpTests: AppHostTestCase {

    override var screenshotPrefix: String { "wincompare" }

    private var controllers: [MainWindowController] = []
    private var savedNumPanels = 1
    private var savedPanelPaths: [String?] = []

    private var fixtures: String {
        ProcessInfo.processInfo.environment["WINCOMPARE_FIXTURES"]
            ?? ((TestPaths.repoRoot ?? "") + "/Mac/build/wincompare/cmp")
    }
    private var outDir: String { ((TestPaths.repoRoot ?? NSTemporaryDirectory()) + "/Mac/build/wincompare/out") }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.fileExists(atPath: fixtures + "/arc.7z") else {
            throw XCTSkip("no wincompare fixture folder at \(fixtures)")
        }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        savedNumPanels = Settings.numPanels
        savedPanelPaths = [Settings.panelPath(0), Settings.panelPath(1)]
        savedAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    private var savedAppearance: NSAppearance?

    /// The Windows captures are light, so the Mac ones are taken in Aqua, on the window's own
    /// background colour (`cacheDisplay` leaves the background transparent, which is what made
    /// the labels of a dark-mode capture invisible).
    @discardableResult
    override func attach(_ window: NSWindow, _ name: String) -> URL? {
        guard let content = window.contentView else { return nil }
        content.layoutSubtreeIfNeeded()
        content.displayIfNeeded()
        let bounds = content.bounds
        guard bounds.width > 1, bounds.height > 1,
              let rep = content.bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        content.cacheDisplay(in: bounds, to: rep)
        guard let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                          colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: flat) else { return nil }
        let pixels = NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            pixels.fill()
        }
        rep.draw(in: pixels, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = flat.representation(using: .png, properties: [:]) else { return nil }
        let file = "wincompare-\(name).png"
        let url = URL(fileURLWithPath: TestPaths.screenshots).appendingPathComponent(file)
        try? png.write(to: url, options: .atomic)
        return url
    }

    override func tearDown() {
        NSApp.appearance = savedAppearance
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for controller in controllers {
            controller.window?.toolbar = nil
            controller.window?.close()
        }
        controllers = []
        for (i, path) in savedPanelPaths.enumerated() { Settings.setPanelPath(path, i) }
        Settings.numPanels = savedNumPanels
        super.tearDown()
    }

    // MARK: - helpers

    private func save(_ name: String, _ text: String) {
        try? text.write(toFile: outDir + "/" + name, atomically: true, encoding: .utf8)
    }

    private func makeWindow(panels: Int = 1) -> MainWindowController {
        Settings.numPanels = panels
        let controller = MainWindowController()
        controllers.append(controller)
        // The Windows client area of the captured 7zFM window was 1424x694.
        controller.window?.setContentSize(NSSize(width: 1424, height: 694))
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        ActiveContext.register(controller)
        return controller
    }

    private func navigate(_ panel: PanelViewController, to path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
        settle()
    }

    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func select(_ panel: PanelViewController, _ names: [String]) {
        var set = IndexSet()
        for name in names {
            if let i = panel.rows.firstIndex(where: { $0.name == name }) { set.insert(i) }
        }
        if let first = set.first { panel.setFocus(first) }
        panel.setSelectedIndexes(set)
        settle(0.1)
    }

    private func handler(for action: Selector, from panel: PanelViewController) -> NSObject? {
        var responder: NSResponder? = panel.tableView
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        if let window = panel.view.window {
            if window.responds(to: action) { return window }
            if let wc = window.windowController, wc.responds(to: action) { return wc }
            if let d = window.delegate as? NSObject, d.responds(to: action) { return d }
        }
        if let delegate = NSApp.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        return nil
    }

    private func validate(_ item: NSMenuItem, _ panel: PanelViewController) -> Bool {
        guard let action = item.action else { return item.submenu != nil }
        if let target = item.target as? NSObject {
            if let v = target as? NSMenuItemValidation { return v.validateMenuItem(item) }
            return true
        }
        guard let target = handler(for: action, from: panel) else { return false }
        if let v = target as? NSMenuItemValidation { return v.validateMenuItem(item) }
        if let v = target as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) }
        return true
    }

    private func menuBar(_ panel: PanelViewController) -> String {
        guard let bar = NSApp.mainMenu else { return "no main menu" }
        return WinCompareDump.menu(bar) { self.validate($0, panel) }
    }

    @discardableResult
    private func send(_ action: Selector, tag: Int = 0, from panel: PanelViewController) -> Bool {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
        item.tag = tag
        guard let target = handler(for: action, from: panel) else { XCTFail("no handler for \(action)"); return false }
        _ = target.perform(action, with: item)
        return true
    }

    private func mainDump(_ controller: MainWindowController) -> String {
        guard let window = controller.window else { return "" }
        var out = WinCompareDump.window(window)
        if let toolbar = window.toolbar {
            out += "== toolbar\n"
            for item in toolbar.items {
                out += "  BTN '\(item.label)' id=\(item.itemIdentifier.rawValue)" + (item.isEnabled ? "" : " DISABLED") + "\n"
            }
        }
        out += "TITLE '\(window.title)'\n"
        return out
    }

    /// Present a dialog through `action`, dump and screenshot it, end its modal session.
    private func dialog(_ name: String, timeout: TimeInterval = 20, _ action: () -> Void,
                        then body: ((NSWindow) -> Void)? = nil) {
        let appeared = ModalProbe.present(timeout: timeout, action) { window in
            self.save("dlg-\(name).txt", WinCompareDump.window(window))
            self.attach(window, "dlg-\(name)-mac")
            body?(window)
        }
        if !appeared { save("dlg-\(name).txt", "NONE\n") }
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for window in NSApp.windows where window.isVisible && window.sheetParent != nil {
            window.sheetParent?.endSheet(window)
        }
        settle(0.2)
    }

    // MARK: - main window, menus, view modes, sorting, archives

    func testDumpMainWindowAndMenus() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: fixtures)
        select(panel, [])
        save("main-folder.txt", mainDump(controller))
        attach(controller.window!, "main-folder-mac")
        save("menu-noselection.txt", menuBar(panel))
        for (tag, name) in [("arc7z", "arc.7z"), ("atxt", "a.txt"), ("sub", "sub")] {
            select(panel, [name])
            save("menu-sel-\(tag).txt", menuBar(panel))
        }
        select(panel, ["a.txt", "b.bin"])
        save("menu-sel-two.txt", menuBar(panel))
        save("main-sel-two.txt", mainDump(controller))

        // context menus (7zFM: WM_CONTEXTMENU on the list)
        for (tag, name) in [("arc7z", "arc.7z"), ("atxt", "a.txt"), ("sub", "sub")] {
            select(panel, [name])
            let menu = panel.makeItemContextMenu()
            save("ctx-\(tag).txt", WinCompareDump.menu(menu) { self.validate($0, panel) })
        }
        select(panel, [])
        if panel.responds(to: NSSelectorFromString("makeBackgroundContextMenu")) {
            // optional API
        }

        // view modes
        for (mode, name) in [(0, "large"), (1, "small"), (2, "list")] {
            panel.setListViewMode(mode)
            settle(0.5)
            attach(controller.window!, "main-view-\(name)-mac")
            save("main-view-\(name).txt", mainDump(controller))
        }
        panel.setListViewMode(3)
        settle()

        // sorting through the View menu actions
        let sorts: [(Selector, String)] = [
            (#selector(MenuActions.viewArrangeByType(_:)), "type"),
            (#selector(MenuActions.viewArrangeByDate(_:)), "date"),
            (#selector(MenuActions.viewArrangeBySize(_:)), "size"),
            (#selector(MenuActions.viewArrangeNoSort(_:)), "unsorted"),
            (#selector(MenuActions.viewArrangeByName(_:)), "name")]
        for (action, name) in sorts {
            send(action, from: panel); settle()
            save("main-sort-\(name).txt", mainDump(controller))
        }
        send(#selector(MenuActions.viewArrangeBySize(_:)), from: panel); settle()
        send(#selector(MenuActions.viewArrangeBySize(_:)), from: panel); settle()
        save("main-sort-size-again.txt", mainDump(controller))
        send(#selector(MenuActions.viewArrangeByName(_:)), from: panel); settle()

        send(#selector(MenuActions.viewFlatView(_:)), from: panel); settle(0.8)
        save("main-flat.txt", mainDump(controller))
        attach(controller.window!, "main-flat-mac")
        send(#selector(MenuActions.viewFlatView(_:)), from: panel); settle(0.5)

        // archives
        for (name, tag) in [("arc.7z", "arc7z"), ("arc.zip", "arczip"), ("arc.tar", "arctar"), ("vol.7z.001", "vol")] {
            navigate(panel, to: fixtures + "/" + name)
            select(panel, [])
            save("main-\(tag).txt", mainDump(controller))
            attach(controller.window!, "main-\(tag)-mac")
            if tag == "arc7z" {
                save("menu-arc7z-noselection.txt", menuBar(panel))
                select(panel, ["a.txt"])
                save("menu-arc7z-sel-atxt.txt", menuBar(panel))
                save("ctx-inarc-atxt.txt", WinCompareDump.menu(panel.makeItemContextMenu()) { self.validate($0, panel) })
                navigate(panel, to: fixtures + "/arc.7z/sub")
                save("main-arc7z-sub.txt", mainDump(controller))
            }
        }
        navigate(panel, to: fixtures)
    }

    func testDumpTwoPanels() throws {
        let controller = makeWindow(panels: 2)
        for panel in controller.visiblePanels { navigate(panel, to: fixtures) }
        save("main-twopanels.txt", mainDump(controller))
        attach(controller.window!, "main-twopanels-mac")
        save("menu-twopanels.txt", menuBar(controller.focusedPanel))
    }

    // MARK: - dialogs, driven through the real commands

    struct Step {
        let name: String
        var match: (NSWindow) -> Bool = { w in !WinCompareDumpTests.isProgress(w) }
        var respond: (NSWindow) -> Void = { WinCompareDumpTests.cancel($0) }
    }

    static func isProgress(_ w: NSWindow) -> Bool {
        let t = w.title
        return t.range(of: "^[0-9]+%", options: .regularExpression) != nil || t.contains("Opening")
    }

    static func buttons(_ view: NSView) -> [NSButton] {
        var out: [NSButton] = []
        if let b = view as? NSButton, !b.isHidden { out.append(b) }
        for v in view.subviews { out += buttons(v) }
        return out
    }

    static func click(_ w: NSWindow, _ titles: [String]) -> Bool {
        guard let content = w.contentView else { return false }
        let all = buttons(content)
        for t in titles {
            if let b = all.first(where: { $0.title == t && $0.isEnabled }) { b.performClick(nil); return true }
        }
        return false
    }

    static func cancel(_ w: NSWindow) {
        if click(w, ["Cancel", "No", "Close", "OK"]) { return }
        if let parent = w.sheetParent { parent.endSheet(w); return }
        if NSApp.modalWindow === w { NSApp.stopModal() }
        w.close()
    }

    static func type(_ text: String, into w: NSWindow) {
        func fields(_ v: NSView) -> [NSTextField] {
            var out: [NSTextField] = []
            if let f = v as? NSTextField, f.isEditable, !f.isHidden { out.append(f) }
            for c in v.subviews { out += fields(c) }
            return out
        }
        if let f = w.contentView.map(fields)?.first { f.stringValue = text }
    }

    /// Run `action`, then answer each window that comes up in order: dump, screenshot, respond.
    private func chain(_ steps: [Step], timeout: TimeInterval = 25, _ action: () -> Void) {
        var known = Set(NSApp.windows.filter { $0.isVisible }.map(ObjectIdentifier.init))
        var index = 0
        let deadline = Date().addingTimeInterval(timeout)
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            guard index < steps.count else { timer.invalidate(); return }
            if Date() > deadline {
                timer.invalidate()
                while NSApp.modalWindow != nil { NSApp.abortModal() }
                return
            }
            let step = steps[index]
            let candidates = ([NSApp.modalWindow].compactMap { $0 } + NSApp.windows.reversed())
                .filter { $0.isVisible && !known.contains(ObjectIdentifier($0)) && $0.frame.width > 1 && !($0 is NSPanel && $0.title.isEmpty && $0.contentView?.subviews.isEmpty ?? true) }
            guard let w = candidates.first(where: step.match) else { return }
            known.insert(ObjectIdentifier(w))
            w.contentView?.layoutSubtreeIfNeeded()
            w.displayIfNeeded()
            self.save("dlg-\(step.name).txt", WinCompareDump.window(w))
            self.attach(w, "dlg-\(step.name)-mac")
            index += 1
            step.respond(w)
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)
        action()
        while index < steps.count, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        timer.invalidate()
        for i in index..<steps.count { save("dlg-\(steps[i].name).txt", "NONE\n") }
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for w in NSApp.windows where w.isVisible && !(w.windowController is MainWindowController) {
            if let parent = w.sheetParent { parent.endSheet(w) } else if w.level == .normal || w.level == .modalPanel || w.level == .floating { w.orderOut(nil) }
        }
        settle(0.3)
    }

    private func one(_ name: String, timeout: TimeInterval = 25, _ action: () -> Void) {
        chain([Step(name: name)], timeout: timeout, action)
    }

    private func scratchCopy() throws -> String {
        let dir = (TestPaths.artifacts as NSString).appendingPathComponent("wincompare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dst = dir + "/cmp"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/cp")
        p.arguments = ["-Rp", fixtures, dst]
        try p.run(); p.waitUntilExit()
        return dst
    }

    func testDumpDialogs() throws {
        let cmp = try scratchCopy()
        defer { try? FileManager.default.removeItem(atPath: (cmp as NSString).deletingLastPathComponent) }
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: cmp)
        let A = MenuActions.self

        select(panel, ["a.txt"])
        one("copy") { send(#selector(A.fileCopyTo(_:)), from: panel) }
        one("move") { send(#selector(A.fileMoveTo(_:)), from: panel) }
        one("createfolder") { send(#selector(A.fileCreateFolder(_:)), from: panel) }
        one("createfile") { send(#selector(A.fileCreateFile(_:)), from: panel) }
        one("properties-file") { send(#selector(A.fileProperties(_:)), from: panel) }
        one("comment-file") { send(#selector(A.fileComment(_:)), from: panel) }
        one("hash-crc32") { send(#selector(A.fileCalculateHash(_:)), tag: 102, from: panel) }
        one("hash-all") { send(#selector(A.fileCalculateHash(_:)), tag: 101, from: panel) }
        one("link") { send(#selector(A.fileLink(_:)), from: panel) }
        // No Delete here: like 7zFM (SHFileOperation, FOF_ALLOWUNDO) the port moves to the Trash
        // without asking, so a "dialog" step would really delete (wincompare.md, Delete).
        select(panel, ["a.txt", "b.bin"])
        one("hash-two-sha256") { send(#selector(A.fileCalculateHash(_:)), tag: 105, from: panel) }
        select(panel, ["b.bin"])
        one("split") { send(#selector(A.fileSplit(_:)), from: panel) }
        select(panel, ["vol.7z.001"])
        one("combine") { send(#selector(A.fileCombine(_:)), from: panel) }
        select(panel, ["sub"])
        one("properties-folder") { send(#selector(A.fileProperties(_:)), from: panel) }
        one("hash-folder-crc") { send(#selector(A.fileCalculateHash(_:)), tag: 102, from: panel) }
        one("select") { send(#selector(A.editSelect(_:)), from: panel) }
        one("deselect") { send(#selector(A.editDeselect(_:)), from: panel) }
        one("history") { send(#selector(A.viewFoldersHistory(_:)), from: panel) }
        one("tempfiles") { send(#selector(A.toolsDeleteTempFiles(_:)), from: panel) }
        one("about") { send(#selector(A.helpAbout(_:)), from: panel) }
        chain([Step(name: "createfolder-exists", respond: { w in Self.type("sub", into: w); _ = Self.click(w, ["OK"]) }),
               Step(name: "err-createfolder-exists")]) { send(#selector(A.fileCreateFolder(_:)), from: panel) }

        // Options: every page
        let options = OptionsWindowController.shared
        if let window = options.window {
            _ = ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in }
            if let tabs = WinCompareDumpTests.firstTabView(window.contentView!) {
                for i in 0..<tabs.numberOfTabViewItems {
                    tabs.selectTabViewItem(at: i)
                    window.contentView?.layoutSubtreeIfNeeded()
                    save("dlg-options-\(i).txt", WinCompareDump.window(window))
                    attach(window, "dlg-options-\(i)-mac")
                }
            }
            ModalProbe.close(window)
        }

        // 7zG-side dialogs
        select(panel, ["a.txt"])
        one("compress", timeout: 40) { send(#selector(A.toolbarAddToArchive(_:)), from: panel) }
        select(panel, ["a.txt", "b.bin"])
        one("compress-two", timeout: 40) { send(#selector(A.toolbarAddToArchive(_:)), from: panel) }
        select(panel, ["arc.7z"])
        one("extract") { send(#selector(A.toolbarExtractArchives(_:)), from: panel) }
        select(panel, ["arc.7z", "arc.zip"])
        one("extract-two") { send(#selector(A.toolbarExtractArchives(_:)), from: panel) }
        select(panel, ["arc.7z"])
        chain([Step(name: "test-arc7z-final", match: { !WinCompareDumpTests.isProgress($0) || $0.title.contains("100%") })], timeout: 30) {
            send(#selector(A.toolbarTestArchives(_:)), from: panel)
        }
        select(panel, ["broken.7z"])
        chain([Step(name: "test-broken-final", match: { _ in true })], timeout: 30) {
            send(#selector(A.toolbarTestArchives(_:)), from: panel)
        }

        // errors opening archives. Enter on a file no handler accepts (S_FALSE) starts it
        // externally on both systems (PanelItemOpen.cpp:1002-1016); on the reference PC that is
        // 7zFM itself through the .7z / .zip association, whose launch-time box is the text
        // below -- the port's equivalent is the command-line open (FM.cpp:997-1014).
        for (name, file) in [("err-broken", "broken.7z"), ("err-fake", "fake.zip")] {
            one(name) { controller.openStartupPath(cmp + "/" + file, formatHint: nil) }
            navigate(panel, to: cmp)
        }
        select(panel, ["enc.7z"])
        chain([Step(name: "password-enc7z", respond: { w in Self.type("wrong", into: w); _ = Self.click(w, ["OK"]) }),
               Step(name: "err-wrongpw")]) { send(#selector(A.fileOpen(_:)), from: panel) }
        navigate(panel, to: cmp)
        select(panel, ["enc.7z"])
        chain([Step(name: "password-enc7z-cancel"), Step(name: "err-after-cancel")], timeout: 8) {
            send(#selector(A.fileOpen(_:)), from: panel)
        }
        navigate(panel, to: cmp)

        // inside arc.7z
        navigate(panel, to: cmp + "/arc.7z")
        select(panel, ["a.txt"])
        one("arc-properties-item") { send(#selector(A.fileProperties(_:)), from: panel) }
        one("arc-hash-crc32") { send(#selector(A.fileCalculateHash(_:)), tag: 102, from: panel) }
        one("arc-comment-7z") { send(#selector(A.fileComment(_:)), from: panel) }
        one("arc-createfolder") { send(#selector(A.fileCreateFolder(_:)), from: panel) }
        one("arc-delete") { send(#selector(A.fileDelete(_:)), from: panel) }
        one("arc-copy") { send(#selector(A.fileCopyTo(_:)), from: panel) }
        // The overwrite prompt of that copy, with the same two files (IDD_OVERWRITE 3500).
        let fmt = ISO8601DateFormatter()
        let when = fmt.date(from: "2024-01-15T09:30:00Z")!
        let old = OverwriteDialog.FileInfo(path: cmp + "/a.txt", size: 1234, time: when)
        let new = OverwriteDialog.FileInfo(path: "a.txt", size: 1234, time: when)
        one("overwrite") { _ = OverwriteDialog.run(oldFile: old, newFile: new, showExtraButtons: true, parent: nil) }
        select(panel, [])
        one("arc-properties-none") { send(#selector(A.fileProperties(_:)), from: panel) }
        navigate(panel, to: cmp + "/arc.zip")
        select(panel, ["a.txt"])
        one("arczip-comment") { send(#selector(A.fileComment(_:)), from: panel) }
        one("arczip-properties-item") { send(#selector(A.fileProperties(_:)), from: panel) }
        navigate(panel, to: cmp + "/vol.7z.001")
        select(panel, [])
        one("vol-properties") { send(#selector(A.fileProperties(_:)), from: panel) }
        navigate(panel, to: cmp + "/encz.zip")
        select(panel, ["a.txt"])
        one("enczip-copy") { send(#selector(A.fileCopyTo(_:)), from: panel) }
        navigate(panel, to: cmp)
    }

    static func firstTabView(_ view: NSView) -> NSTabView? {
        if let t = view as? NSTabView { return t }
        for v in view.subviews { if let t = firstTabView(v) { return t } }
        return nil
    }

    // MARK: - the Compress dialog's lists, every format x level and format x method

    /// The same walk as the Windows script s4.ps1 (CB_SETCURSEL + CBN_SELCHANGE on 7zG's combos),
    /// with the reference PC's hardware (8 threads, 21 240 692 736 bytes of RAM) so the thread
    /// lists and memory figures are comparable.
    func testDumpCompressMatrix() throws {
        let cmp = try scratchCopy()
        defer { try? FileManager.default.removeItem(atPath: (cmp as NSString).deletingLastPathComponent) }
        CompressModel.hardwareOverride = (threads: 8, ram: 21_240_692_736)
        defer { CompressModel.hardwareOverride = nil }
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: cmp)
        select(panel, ["a.txt"])
        var out = ""
        let appeared = ModalProbe.present(timeout: 40, {
            self.send(#selector(MenuActions.toolbarAddToArchive(_:)), from: panel)
        }) { window in
            guard let any = WinCompareDumpTests.allViews(window.contentView!).compactMap({ $0 as? NSPopUpButton })
                    .first(where: { $0.target is CompressDialogController }),
                  let dialog = any.target as? CompressDialogController else { out = "no dialog controller"; return }
            var parts: [String: Any] = [:]
            for child in Mirror(reflecting: dialog).children { if let l = child.label { parts[l] = child.value } }
            func popup(_ n: String) -> NSPopUpButton { parts[n] as! NSPopUpButton }
            func label(_ n: String) -> String { (parts[n] as? NSTextField)?.stringValue ?? "?" }
            func items(_ n: String) -> String {
                let p = popup(n)
                if p.isHidden || p.numberOfItems == 0 { return "" }
                let dis = p.isEnabled ? "" : "(disabled) "
                return dis + (0..<p.numberOfItems).map { (p.indexOfSelectedItem == $0 ? "*" : "") + (p.item(at: $0)?.title ?? "") }
                    .joined(separator: " | ")
            }
            func choose(_ n: String, _ i: Int) {
                let p = popup(n)
                p.selectItem(at: i)
                NSApp.sendAction(p.action!, to: p.target, from: p)
            }
            func state() -> String {
                "  method: " + items("methodCombo") + "\n  dict: " + items("dictionaryCombo") + "\n  word: " + items("orderCombo")
                    + "\n  solid: " + items("solidCombo") + "\n  threads: " + items("threadsCombo") + " " + label("hardwareThreadsLabel")
                    + "\n  memuse: " + items("memUseCombo") + "\n  mem: " + label("memoryValueLabel") + " / " + label("memoryDeValueLabel")
                    + "\n  enc: " + items("encryptionMethodCombo") + "\n"
            }
            let format = popup("formatCombo")
            out += "formats: " + items("formatCombo") + "\n"
            for f in 0..<format.numberOfItems {
                choose("formatCombo", f)
                let fn = format.titleOfSelectedItem ?? ""
                out += "== FORMAT \(fn)  levels: " + items("levelCombo") + "  update: " + items("updateModeCombo")
                    + "  sfx=" + ((parts["sfxBox"] as? NSButton)?.isEnabled == true ? "True" : "False") + "\n"
                out += state()
                let level = popup("levelCombo")
                for l in 0..<level.numberOfItems {
                    choose("levelCombo", l)
                    out += "-- \(fn) level " + (level.titleOfSelectedItem ?? "") + "\n" + state()
                }
                if let normal = level.itemArray.firstIndex(where: { $0.title.hasSuffix("Normal") }) { choose("levelCombo", normal) }
                let method = popup("methodCombo")
                for m in 0..<method.numberOfItems {
                    choose("methodCombo", m)
                    out += "-- \(fn) Normal method " + (method.titleOfSelectedItem ?? "") + "\n" + state()
                }
            }
        }
        XCTAssertTrue(appeared)
        save("compress-matrix.txt", out)
    }

    static func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
}
