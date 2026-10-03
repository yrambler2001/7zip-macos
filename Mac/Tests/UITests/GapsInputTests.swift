// GapsInputTests.swift -- real-input coverage for features the panelgaps / navgaps scopes added
// with app-hosted tests only (`Mac/Tests/AppTests/PanelGapsTests.swift`, `NavGapsTests.swift`).
// Those call the menu builder, the collection view's drag delegate and the open path directly; what
// they cannot show is that a real right click, a real mouse drag and a real button press reach the
// same code. Every case here synthesizes input, so the class belongs to the **input shard**.
//
// Written by `mac/uiverify` (Mac/docs/reports/uiverify.md). The icon-view drag needed a product fix
// first: the collection view's items were not in the accessibility tree at all.
//
// Not here, on purpose:
//   * the Help buttons (opsgaps). Their only test hook is in process (`HelpTopics.opener`), which
//     `OpsGapsTests` already uses; from XCUITest a click would launch the user's browser.
//   * the "Opening" progress window's own Cancel button (navgaps §1). It appears only after 500 ms
//     (WaitMode), and no fixture takes that long to open; the password Cancel below is the real
//     input path the open can be cancelled through with the fixtures that exist.

import XCTest

final class GapsInputTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "uiverify" }

    /// A scratch folder holding a copy of `test.zip` as `arc.zip`, two text files and a folder.
    private func makeScratch(_ name: String) throws -> String {
        let fm = FileManager.default
        let base = (TestPaths.artifacts as NSString).appendingPathComponent("gaps-\(name)-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(atPath: base + "/dir", withIntermediateDirectories: true)
        try fm.copyItem(atPath: (TestPaths.fixtures as NSString).appendingPathComponent("test.zip"),
                        toPath: base + "/arc.zip")
        try Data("alpha".utf8).write(to: URL(fileURLWithPath: base + "/alpha.txt"))
        try Data("beta".utf8).write(to: URL(fileURLWithPath: base + "/beta.txt"))
        // Move the app off the folder before it disappears (PanelTests.addSafeCleanup explains why).
        addTeardownBlock { [weak sevenZip] in
            if let app = sevenZip, app.isRunning, app.testSupportIsImplemented {
                var options = SevenZipApp.ResetOptions()
                options.panels = 1
                options.path0 = TestPaths.fixtures
                app.reset(options)
            }
            try? fm.removeItem(atPath: base)
        }
        return base
    }

    private func waitForFile(_ path: String, timeout: TimeInterval = 30) -> Bool {
        waitFor(path, timeout: timeout) { FileManager.default.fileExists(atPath: path) }
    }

    // MARK: - panelgaps: the 7-Zip verbs of the panel's context menu (01 §2.9, CreateSevenZipMenu)

    /// Right-click an archive, choose `Extract to "arc/"` (lang 2327): the archive is extracted into
    /// a folder named after it, next to it, with no dialog (ContextMenu.cpp kExtractTo).
    func testRightClickExtractToExtractsNextToTheArchive() throws {
        let scratch = try makeScratch("verb")
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "arc.zip"))
        panel.select("arc.zip")

        guard let menu = panel.openContextMenu(onRow: "arc.zip") else {
            return XCTFail("no context menu on arc.zip")
        }
        let titles = panel.menuItemTitles(of: menu)
        screenshot("01-context-menu-7zip-verbs")
        let title = "Extract to \"arc/\""
        XCTAssertTrue(titles.contains(title), "context menu: \(titles)")
        // The 7-Zip verbs come first, the file-menu items after the separator (PanelContextMenu).
        XCTAssertTrue(titles.contains("Open archive"), "context menu: \(titles)")
        menu.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch.click()

        XCTAssertTrue(waitForFile(scratch + "/arc"), "Extract to \"arc/\" made no folder")
        let extracted = (try? FileManager.default.contentsOfDirectory(atPath: scratch + "/arc")) ?? []
        XCTAssertFalse(extracted.isEmpty, "the arc/ folder is empty")
        XCTAssertTrue(panel.waitForRow(named: "arc"), "the panel did not pick up the new folder: \(panel.names)")
    }

    // MARK: - panelgaps: drag and drop in the icon view modes (01 §3.15)

    /// In Large Icons, drag `alpha.txt` onto the `dir` icon with the mouse: the file lands in the
    /// folder (same volume, so the default effect is a move). The app-hosted test calls the
    /// collection view's drop delegate; this one goes through a real drag session.
    func testDragOntoAFolderInLargeIcons() throws {
        let scratch = try makeScratch("icons")
        launch(seed: .typed([SettingsDomain.Key.panelPath0: scratch,
                             SettingsDomain.Key.listMode0: 0]))            // Large Icons
        let panel = sevenZip.panel(0)
        XCTAssertTrue(waitFor("the icon view") { panel.iconView.exists }, "panel 0 is not in an icon mode")
        if !panel.waitForIcon(named: "alpha.txt") { _ = sevenZip.dumpTree("uiverify-icons") }
        XCTAssertTrue(panel.iconNames.contains("alpha.txt"), "icons: \(panel.iconNames)")
        XCTAssertTrue(panel.iconNames.contains("dir"), "icons: \(panel.iconNames)")
        screenshot("02-large-icons")

        let source = panel.iconItem(named: "alpha.txt")
        let target = panel.iconItem(named: "dir")
        XCTAssertTrue(source.exists && target.exists)
        source.press(forDuration: 0.6, thenDragTo: target)

        // A drop that asks first (an archive target) would show a box; a folder does not.
        XCTAssertTrue(waitForFile(scratch + "/dir/alpha.txt"), "nothing arrived in dir/")
        XCTAssertTrue(sevenZip.waitForNoDialog(timeout: 5), "the drop left a dialog up")
    }

    // MARK: - navgaps: cancelling an open (01 §6.7, PROGRESS 153)

    /// Double-click an archive with encrypted headers: the "Opening" progress (IDS_OPENNING 3303)
    /// is up behind the password dialog; Cancel there is E_ABORT -- no error box, and the panel stays
    /// in the folder (OpenAsArc_Msg is silent for an abort).
    func testCancelWhileOpeningIsSilent() throws {
        launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "secret.7z"))
        panel.open("secret.7z")
        guard let dialog = sevenZip.waitForDialog(title: "Enter password") else {
            return XCTFail("no password dialog; dialogs: \(app.dialogs.count), sheets: \(app.sheets.count)")
        }
        let titled = NSPredicate(format: "title CONTAINS 'Opening'")
        let opening = app.windows.matching(titled).count + app.dialogs.matching(titled).count
        if opening == 0 { _ = sevenZip.dumpTree("uiverify-opening") }
        XCTAssertGreaterThan(opening, 0, "the Opening progress is not up behind the password dialog")
        screenshot("03-opening-and-password")

        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "Cancel"))
        XCTAssertTrue(sevenZip.waitForNoDialog(timeout: 10), "a box followed the cancelled open")
        XCTAssertTrue(panel.waitForRow(named: "secret.7z"), "the panel left the folder: \(panel.names)")
        XCTAssertTrue(panel.waitForPath(TestPaths.fixtures))
    }

    // MARK: - navgaps: the four-part status bar (01 §1.2)

    /// Selecting a file fills sections 1-3 (selected size, focused size, focused time) after the
    /// "N / M object(s) selected" section; a click on the item is what selects it.
    func testStatusBarSectionsFollowAClickedItem() throws {
        let scratch = try makeScratch("status")
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "alpha.txt"))
        panel.select("alpha.txt")
        XCTAssertTrue(waitFor("section 0") { panel.statusParts.first?.contains("1 / 4") == true },
                      "status: \(panel.statusParts)")
        XCTAssertTrue(waitFor("sizes") { panel.statusParts.count >= 3 && panel.statusParts[1] == "5" },
                      "status: \(panel.statusParts)")
        XCTAssertEqual(panel.statusParts.count >= 3 ? panel.statusParts[2] : nil, "5",
                       "the focused item's size: \(panel.statusParts)")
    }
}
