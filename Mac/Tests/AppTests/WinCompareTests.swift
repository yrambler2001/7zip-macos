// WinCompareTests.swift -- regression tests for the differences the side-by-side comparison with
// the real 7zFM 25.01 found (Mac/docs/reports/wincompare.md). Each test names the Windows
// observation it pins down. They use the ordinary fixtures (Mac/Tests/Fixtures), not the
// comparison folder, so they always run.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class WinCompareTests: AppHostTestCase {

    override var screenshotPrefix: String { "wincompare" }

    private var controllers: [MainWindowController] = []
    private var scratchDirectories: [String] = []
    private var savedNumPanels = 1
    private var savedPanelPaths: [String?] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedNumPanels = Settings.numPanels
        savedPanelPaths = [Settings.panelPath(0), Settings.panelPath(1)]
    }

    override func tearDown() {
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for controller in controllers {
            controller.window?.toolbar = nil
            controller.window?.close()
        }
        controllers = []
        for path in scratchDirectories { try? FileManager.default.removeItem(atPath: path) }
        scratchDirectories = []
        for (i, path) in savedPanelPaths.enumerated() { Settings.setPanelPath(path, i) }
        Settings.numPanels = savedNumPanels
        CompressModel.hardwareOverride = nil
        super.tearDown()
    }

    // MARK: - helpers

    private func makeScratch() -> String {
        let path = (TestPaths.artifacts as NSString).appendingPathComponent("wincompare-t-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/sub", withIntermediateDirectories: true)
        for name in ["test.7z", "test.zip"] {
            try? fm.copyItem(atPath: TestPaths.fixture(name), toPath: path + "/" + name)
        }
        fm.createFile(atPath: path + "/a.txt", contents: Data(repeating: 0x61, count: 1234))
        scratchDirectories.append(path)
        return path
    }

    private func makeWindow() -> MainWindowController {
        Settings.numPanels = 1
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(NSSize(width: 1000, height: 600))
        controller.showWindow(nil)
        ActiveContext.register(controller)
        return controller
    }

    private func navigate(_ panel: PanelViewController, to path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
    }

    private func select(_ panel: PanelViewController, _ names: [String]) {
        var set = IndexSet()
        for name in names {
            if let i = panel.rows.firstIndex(where: { $0.name == name }) { set.insert(i) }
        }
        if let first = set.first { panel.setFocus(first) }
        panel.setSelectedIndexes(set)
    }

    private func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }

    private func texts(_ window: NSWindow) -> [String] {
        allViews(window.contentView!).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    private func buttonTitles(_ window: NSWindow) -> [String] {
        allViews(window.contentView!).compactMap { v in
            guard let b = v as? NSButton, !b.isHidden else { return nil }
            return b.title
        }
    }

    // MARK: - menus

    /// View > Time shows local time unless UTC is checked (ConvertUtcFileTimeToString follows
    /// g_Timestamp_Show_UTC): 7zFM printed 18:09 at 18:09 CEST, the port printed 16:09.
    func testTimeMenuShowsLocalTime() {
        let savedUTC = Settings.timestampShowUTC
        defer { Settings.timestampShowUTC = savedUTC }
        Settings.timestampShowUTC = false
        let menu = NSMenu()
        let popup = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        TimeMenuDelegate.shared.rebuild(menu, popupItem: popup)
        let minute = menu.items.first { $0.tag == MainMenu.idmViewTime + 1 }?.title ?? ""
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: TimeZone.current.secondsFromGMT())
        f.dateFormat = "yyyy-MM-dd HH:mm"
        let local = f.string(from: Date())
        XCTAssertEqual(minute, local, "the minute-level example is local time")

        Settings.timestampShowUTC = true
        TimeMenuDelegate.shared.rebuild(menu, popupItem: popup)
        f.timeZone = TimeZone(secondsFromGMT: 0)
        XCTAssertEqual(menu.items.first { $0.tag == MainMenu.idmViewTime + 1 }?.title, f.string(from: Date()))
    }

    /// CascadedMenu: the context menu starts with one "7-Zip" submenu, then directly the File-menu
    /// items, which are the File menu's own (Open Inside * / #, CRC >, Link..., no Exit).
    func testContextMenuIsCascadedAndSharesTheFileMenu() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        select(panel, ["test.7z"])
        let menu = panel.makeItemContextMenu()
        XCTAssertEqual(menu.items.first?.title, "7-Zip")
        let verbs = menu.items.first?.submenu?.items.map(\.title) ?? []
        XCTAssertTrue(verbs.contains("Extract Here"), "\(verbs)")
        XCTAssertTrue(verbs.contains("CRC SHA"), "kCRC_Cascaded puts CRC SHA inside 7-Zip: \(verbs)")
        let top = menu.items.map(\.title)
        XCTAssertEqual(top[1], "Open", "no separator between 7-Zip and the File part: \(top)")
        for title in ["Open Inside *", "Open Inside #", "CRC", "Link...", "Create Folder"] {
            XCTAssertTrue(top.contains(title), "missing \(title): \(top)")
        }
        XCTAssertFalse(top.contains("Exit"))

        Settings.cascadedMenu = false
        defer { Settings.cascadedMenu = nil }
        let flat = panel.makeItemContextMenu().items.map(\.title)
        XCTAssertFalse(flat.contains("7-Zip"))
        XCTAssertTrue(flat.contains("Extract Here"), "\(flat)")
    }

    /// The File menu gets the same "7-Zip" submenu at its top for a file-system selection
    /// (CreateFileMenu, programMenu = true), and none inside an archive.
    func testFileMenuInsertsTheSevenZipSubmenu() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        select(panel, ["a.txt"])
        guard let file = NSApp.mainMenu?.items.first(where: { $0.submenu?.items.contains { $0.tag == 540 } ?? false })?.submenu else {
            return XCTFail("no File menu")
        }
        file.delegate?.menuNeedsUpdate?(file)
        let open = file.items.firstIndex { $0.tag == 540 }!
        XCTAssertEqual(file.items[open - 1].title, "7-Zip", "\(file.items.map(\.title))")
        XCTAssertEqual(file.items.filter { $0.title == "7-Zip" }.count, 1, "no second, static 7-Zip submenu")

        navigate(panel, to: scratch + "/test.7z")
        select(panel, ["readme.txt"])
        file.delegate?.menuNeedsUpdate?(file)
        XCTAssertFalse(file.items.contains { $0.title == "7-Zip" }, "IsArcFolder: no 7-Zip commands")
        navigate(panel, to: scratch)
        file.delegate?.menuNeedsUpdate?(file)
    }

    // MARK: - list

    /// GetColumnAlign: VT_BOOL is right-aligned ("Encrypted" in 7zFM 25.01).
    func testBooleanColumnsAreRightAligned() {
        XCTAssertEqual(PanelFormat.alignment(for: .bool, propID: .encrypted), .right)
        XCTAssertEqual(PanelFormat.alignment(for: .fileTime, propID: .mtime), .left)
    }

    // MARK: - texts

    /// AddSizeValue (OverwriteDialog.cpp): plain digits and " : N KiB".
    func testSizeValue() {
        XCTAssertEqual(Formatting.sizeValue(0), "0 bytes")
        XCTAssertEqual(Formatting.sizeValue(1234), "1234 bytes : 1 KiB")
        XCTAssertEqual(Formatting.sizeValue(103_964), "103964 bytes : 101 KiB")
        XCTAssertEqual(Formatting.sizeValue(20 << 20), "20971520 bytes : 20 MiB")
    }

    /// GetItemsInfoString: counts first, then the folder and the indented names.
    func testCopyDialogInfoText() {
        let file = PanelRow(engineIndex: 0, name: "a.txt", displayName: "a.txt", isDirectory: false, size: 1234)
        let info = Bidi.stripped(PanelFormat.itemsInfo(rows: [file], folderPrefix: "/x/cmp/"))
        XCTAssertEqual(info, "Files: 1    ( 1 234 bytes )\n\n/x/cmp/\n  a.txt")
        let dir = PanelRow(engineIndex: 1, name: "sub", displayName: "sub", isDirectory: true, size: 0)
        let two = Bidi.stripped(PanelFormat.itemsInfo(rows: [dir, file], folderPrefix: "/x/"))
        XCTAssertEqual(two, "Folders: 1\nFiles: 1    ( 1 234 bytes )\n\n/x/\n  sub/\n  a.txt",
                       "a folder's size is undefined, so it has no ( ... ) and there is no Size line")
    }

    /// Browse_ConvertSizeToString and the "Name-2" column of Delete Temporary Files.
    func testTempFilesSizeText() {
        XCTAssertEqual(ToolsTempFilesDialog.browseSizeText(9999), "9999")
        XCTAssertEqual(ToolsTempFilesDialog.browseSizeText(2_043_904), "1996 KB")
        XCTAssertEqual(ToolsTempFilesDialog.browseSizeText(5_293_056), "5169 KB")
        XCTAssertEqual(ToolsTempFilesDialog.browseSizeText(UInt64(20000) << 20), "19 GB")
    }

    // MARK: - dialogs

    /// IDD_OVERWRITE: folder, name, "1234 bytes : 1 KiB", "Modified: ..." as four lines.
    func testOverwriteDialogFileBlock() {
        let date = Date(timeIntervalSince1970: 1_705_311_000)
        let old = OverwriteDialog.FileInfo(path: "/x/cmp/a.txt", size: 1234, time: date)
        let new = OverwriteDialog.FileInfo(path: "a.txt", size: 1234, time: date)
        let appeared = ModalProbe.present({ _ = OverwriteDialog.run(oldFile: old, newFile: new, parent: nil) }) { window in
            let blocks = self.texts(window).filter { $0.contains("bytes") }
            XCTAssertEqual(blocks.count, 2, "\(self.texts(window))")
            XCTAssertTrue(blocks.first?.hasPrefix("/x/cmp/\na.txt\n1234 bytes : 1 KiB\nModified: ") ?? false, "\(blocks)")
            XCTAssertTrue(blocks.last?.hasPrefix("\na.txt\n1234 bytes : 1 KiB\n") ?? false, "\(blocks)")
        }
        XCTAssertTrue(appeared)
    }

    /// Comment on an item is CComboDialog: "<name> : Comment" with "Comment:".
    func testCommentUsesTheComboDialog() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch + "/test.zip")
        select(panel, ["readme.txt"])
        let appeared = ModalProbe.present({ panel.changeComment() }) { window in
            XCTAssertEqual(window.title, "readme.txt : Comment")
            XCTAssertTrue(self.texts(window).contains("Comment:"), "\(self.texts(window))")
        }
        XCTAssertTrue(appeared)
    }

    /// Deleting inside an archive asks Yes / No / Cancel (MB_YESNOCANCEL).
    func testArchiveDeleteAsksYesNoCancel() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch + "/test.zip")
        select(panel, ["readme.txt"])
        let appeared = ModalProbe.present({ panel.deleteItems(toTrash: true) }) { window in
            let buttons = self.buttonTitles(window)
            XCTAssertTrue(["Yes", "No", "Cancel"].allSatisfy(buttons.contains), "\(buttons)")
        }
        XCTAssertTrue(appeared)
        XCTAssertTrue(panel.rows.contains { $0.name == "readme.txt" }, "nothing was deleted")
    }

    /// IDD_ABOUT has OK and www.7-zip.org only.
    func testAboutHasNoHelpButton() {
        let appeared = ModalProbe.present({ AboutDialog.show(parent: nil) }) { window in
            let buttons = self.buttonTitles(window)
            XCTAssertFalse(buttons.contains("Help"), "\(buttons)")
            XCTAssertTrue(buttons.contains("www.7-zip.org"))
        }
        XCTAssertTrue(appeared)
    }

    /// Extract dialog from the toolbar: "Eliminate duplication of root folder" starts unchecked.
    func testExtractDialogElimDupDefaultsOff() {
        let saved = Settings.extractElimDup
        defer { Settings.extractElimDup = saved }
        Settings.extractElimDup = nil
        var options = ExtractDialog.Options()
        options.directoryPath = TestPaths.fixtures + "/"
        options.archivePath = TestPaths.fixture("test.7z")
        let appeared = ModalProbe.present({ _ = ExtractDialog.run(options) }) { window in
            let box = self.allViews(window.contentView!).compactMap { $0 as? NSButton }
                .first { $0.title == "Eliminate duplication of root folder" }
            XCTAssertEqual(box?.state, .off)
        }
        XCTAssertTrue(appeared)
    }

    /// EnableMultiCombo(IDC_COMPRESS_METHOD): bzip2's single method is grayed.
    func testCompressSingleMethodComboIsDisabled() {
        var input = CompressDialogInput()
        input.directoryPrefix = TestPaths.fixtures + "/"
        input.archiveBaseName = "a"
        input.itemPaths = [TestPaths.fixture("test.7z")]
        let appeared = ModalProbe.present(timeout: 40, { _ = CompressDialogController.run(input) }) { window in
            guard let dialog = self.allViews(window.contentView!).compactMap({ ($0 as? NSPopUpButton)?.target as? CompressDialogController }).first else {
                return XCTFail("no compress dialog")
            }
            var parts: [String: Any] = [:]
            for child in Mirror(reflecting: dialog).children { if let l = child.label { parts[l] = child.value } }
            guard let format = parts["formatCombo"] as? NSPopUpButton,
                  let method = parts["methodCombo"] as? NSPopUpButton,
                  let bzip2 = format.itemArray.firstIndex(where: { $0.title == "bzip2" }) else {
                return XCTFail("controls not found")
            }
            XCTAssertTrue(method.isEnabled, "7z offers four methods")
            format.selectItem(at: bzip2)
            NSApp.sendAction(format.action!, to: format.target, from: format)
            XCTAssertEqual(method.numberOfItems, 1)
            XCTAssertFalse(method.isEnabled, "one method: grayed, as in 7zG")
        }
        XCTAssertTrue(appeared)
    }
}
