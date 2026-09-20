// PanelTests.swift -- UI tests for the `panel` scope (01-fm-feature-inventory.md section 3):
// view modes, sorting, the selection commands, navigation into an archive, copy between panels,
// rename, create folder, delete to the Trash and the list context menu.
//
// They use the `harness` scope's helpers (`SevenZipUITestCase`, `SevenZipApp`, `SevenZipPanel`,
// `SettingsDomain`, `TestPaths`; see Mac/docs/api/harness.md). Everything they assert was verified
// by hand in the running app first (Mac/docs/reports/panel.md).
//
// Every case here clicks, double-clicks or types, so the class belongs to the **input shard** and
// runs alone: macOS delivers a synthesized event to whatever application is frontmost. The app is
// launched once for the class and reset between tests (`SevenZipUITestCase`).

import XCTest

final class PanelTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "panel" }

    private var fixtures: String { TestPaths.fixtures }

    /// A fresh scratch directory with three files and one sub-folder, or an empty one.
    ///
    /// `contents: false` matters for the copy test: two scratch directories hold the *same* three
    /// names, so copying between them raises the Confirm File Replace prompt (IDD_OVERWRITE 3400),
    /// which blocks the rest of the test — and makes "the file is now in the other panel" true
    /// before the copy even runs.
    private func makeScratch(_ name: String, contents: Bool = true) throws -> String {
        let base = (TestPaths.artifacts as NSString).appendingPathComponent("panel-\(name)-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(atPath: base, withIntermediateDirectories: true)
        guard contents else {
            addSafeCleanup(of: base, with: manager)
            return base
        }
        try manager.createDirectory(atPath: (base as NSString).appendingPathComponent("sub"),
                                    withIntermediateDirectories: true)
        for (file, size) in [("alpha.txt", 10), ("beta.txt", 2000), ("gamma.md", 100)] {
            let data = Data(repeating: 0x41, count: size)
            try data.write(to: URL(fileURLWithPath: (base as NSString).appendingPathComponent(file)))
        }
        addSafeCleanup(of: base, with: manager)
        return base
    }

    /// Delete a scratch directory after the test -- but get the app out of it first.
    private func addSafeCleanup(of path: String, with manager: FileManager) {
        // Move the app off this directory **before** it disappears. A panel whose folder vanishes
        // refreshes, fails, and shows an error -- and when that panel has been closed at runtime
        // (`ensurePanelCount(1)`), its view has no window, so `PanelViewController.showError` takes
        // the `alert.runModal()` branch instead of `beginSheetModal(for:)` and puts up an
        // **app-modal alert attached to nothing**. The app is then wedged: the next test's reset
        // never settles, never acknowledges, and every accessibility query takes seconds. Measured
        // with a stack sample; filed for `panel` and `resetcmd` in Mac/docs/requests.md. The test's
        // own part of it is this: do not delete a directory the app under test is still showing.
        addTeardownBlock { [weak sevenZip] in
            if let app = sevenZip, app.isRunning, app.testSupportIsImplemented {
                var options = SevenZipApp.ResetOptions()
                options.panels = 1
                options.path0 = TestPaths.fixtures
                options.path1 = TestPaths.fixtures
                _ = app.reset(options)
            }
            try? manager.removeItem(atPath: path)
        }
    }

    // MARK: 3.1 view modes

    /// All four view modes switch and keep the items (Panel.cpp SetListViewMode, 01 §3.1).
    func testViewModesSwitch() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "test.7z"))
        for (title, selector, shot) in [("Large Icons", "viewLargeIcons:", "01-large-icons"),
                                        ("Small Icons", "viewSmallIcons:", "02-small-icons"),
                                        ("List", "viewList:", "03-list"),
                                        ("Details", "viewDetails:", "04-details")] {
            XCTAssertTrue(sevenZip.selectMenuItem("View", title), "View > \(title) not clickable")
            XCTAssertTrue(sevenZip.menuItem(selector: selector).exists)
            screenshot(shot)
        }
        XCTAssertTrue(panel.waitForRow(named: "test.7z"), "the details list is back with its items")
    }

    // MARK: 3.3 sorting

    /// Clicking Size sorts descending first, clicking again ascending; folders stay on top
    /// (SortItemsWithPropID, 01 §3.3).
    func testSortBySizeStartsDescendingAndKeepsFoldersFirst() throws {
        let scratch = try makeScratch("sort")
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "beta.txt"))
        XCTAssertEqual(panel.names, ["sub", "alpha.txt", "beta.txt", "gamma.md"], "default is name ascending")
        panel.clickColumnHeader("Size")
        XCTAssertTrue(waitFor("size descending") { panel.names == ["sub", "beta.txt", "gamma.md", "alpha.txt"] },
                      "size descending first, order is \(panel.names)")
        panel.clickColumnHeader("Size")
        XCTAssertTrue(waitFor("size ascending") { panel.names == ["sub", "alpha.txt", "gamma.md", "beta.txt"] },
                      "second click ascends, order is \(panel.names)")
    }

    // MARK: 3.6 selection

    /// Select All / Deselect All / Invert Selection and Select by mask (PanelSelect.cpp).
    func testSelectionCommands() throws {
        let scratch = try makeScratch("select")
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "alpha.txt"))
        XCTAssertTrue(sevenZip.selectMenuItem("Edit", "Select All"))
        XCTAssertTrue(waitFor("all four selected") { panel.status.contains("4 / 4") }, "status: \(panel.status)")
        XCTAssertTrue(sevenZip.selectMenuItem("Edit", "Invert Selection"))
        XCTAssertTrue(waitFor("nothing selected") { panel.status.contains("0 / 4") || panel.status.contains("1 / 4") },
                      "status: \(panel.status)")
        XCTAssertTrue(sevenZip.selectMenuItem("Edit", "Select..."))
        guard let dialog = sevenZip.waitForDialog(title: "Select") else { return XCTFail("no Select dialog") }
        screenshot("05-select-mask")
        // IDC_COMBO 101 of IDD_COMBO 98: an editable NSComboBox exposes no child text field (its
        // only child is the disclosure button), so the old `comboBoxes.firstMatch.textFields`
        // lookup never matched, nothing was typed, and the default "*" mask selected all four
        // items. ComboDialog.run() focuses the combo and selects its text, exactly as 7zFM does,
        // so typing replaces the default -- and the mask is read back so a silent miss fails here
        // instead of turning into a wrong selection count.
        let mask = dialog.comboBoxes.firstMatch
        XCTAssertTrue(mask.waitForExistence(timeout: 5), "the Select dialog has no mask combo box")
        XCTAssertEqual(mask.value as? String, "*", "the default mask is \"*\" (PanelKeys.selectSpec)")
        app.typeKey("a", modifierFlags: .command)
        app.typeText("*.txt")
        XCTAssertEqual(mask.value as? String, "*.txt", "the mask was not typed into the combo")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
        XCTAssertTrue(waitFor("two .txt files selected") { panel.status.contains("2 / 4") }, "status: \(panel.status)")
    }

    // MARK: 3.8 navigation

    /// Into an archive, into a sub-folder, back out with the Up button (01 §3.8).
    func testNavigateIntoArchiveAndBack() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "test.7z"))
        panel.open("test.7z")
        XCTAssertTrue(panel.waitForRow(named: "readme.txt"), "archive listing: \(panel.names)")
        screenshot("06-inside-archive")
        panel.open("sub")
        XCTAssertTrue(panel.waitForRow(named: "big.txt"))
        panel.goUp()
        XCTAssertTrue(panel.waitForPath(TestPaths.fixture("test.7z")))
        panel.goUp()
        XCTAssertTrue(panel.waitForPath(fixtures))
    }

    /// A nested archive opens as another level (01 §3.8 step 6).
    func testNestedArchive() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "nested.zip"))
        panel.open("nested.zip")
        // make-fixtures.sh puts test.7z and test.tar.gz in nested.zip, not test.zip.
        XCTAssertTrue(panel.waitForRow(named: "test.7z"), "nested.zip holds \(panel.names)")
        panel.open("test.7z")
        XCTAssertTrue(panel.waitForRow(named: "readme.txt"), "inner archive holds \(panel.names)")
    }

    // MARK: 3.10 copy between panels

    /// F5 / File > Copy To... proposes the other panel and copies there (CApp::OnCopy, 01 §3.10).
    func testCopyBetweenPanels() throws {
        let source = try makeScratch("copy-src")
        let destination = try makeScratch("copy-dst", contents: false)
        launch(seed: .values([SettingsDomain.Key.panelPath0: source]))
        XCTAssertTrue(sevenZip.ensurePanelCount(2))
        let left = sevenZip.panel(0)
        let right = sevenZip.panel(1)
        XCTAssertTrue(sevenZip.panelsAreOrderedLeftToRight, "panel 0 must be the left one")
        XCTAssertTrue(right.navigate(to: destination), "panel 1 has no address bar")
        XCTAssertTrue(right.waitForPath(destination),
                      "panel 1 shows '\(right.path)', panel 0 shows '\(left.path)'")
        XCTAssertTrue(left.waitForRow(named: "alpha.txt"), "panel 0 lists \(left.names)")
        XCTAssertFalse(right.hasRow(named: "alpha.txt"), "the destination panel must start empty")
        left.select("alpha.txt")
        XCTAssertTrue(sevenZip.selectMenuItem("File", "Copy To..."))
        guard let dialog = sevenZip.waitForDialog(title: "Copy") else { return XCTFail("no Copy dialog") }
        screenshot("07-copy-dialog")
        XCTAssertTrue(sevenZip.texts(of: dialog).contains { $0.contains("alpha.txt") },
                      "the info text lists the item: \(sevenZip.texts(of: dialog))")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
        XCTAssertTrue(waitFor("copied") { right.hasRow(named: "alpha.txt") }, "right panel: \(right.names)")
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: (destination as NSString).appendingPathComponent("alpha.txt")),
                      "the file really is in the destination folder, not only in the listing")
        XCTAssertTrue(sevenZip.waitForNoDialog(), "the copy finished without asking anything")
        XCTAssertTrue(sevenZip.ensurePanelCount(1))
    }

    // MARK: 3.11 item operations

    /// Create Folder (F7) with the Combo dialog, then Delete to the Trash (01 §3.11).
    func testCreateFolderAndDelete() throws {
        let scratch = try makeScratch("create")
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "alpha.txt"))
        XCTAssertTrue(sevenZip.selectMenuItem("File", "Create Folder"))
        guard let dialog = sevenZip.waitForDialog(title: "Create Folder") else {
            return XCTFail("no Create Folder dialog")
        }
        screenshot("08-create-folder")
        // ComboDialog.swift:73 calls selectText(nil), so the default name is already selected
        // and focused exactly as in 7zFM: typing replaces it. Clicking first would deselect it.
        XCTAssertTrue(dialog.comboBoxes.firstMatch.exists, "the name combo is missing")
        app.typeText("made-by-test")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
        XCTAssertTrue(panel.waitForRow(named: "made-by-test"), "listing: \(panel.names)")

        panel.select("made-by-test")
        XCTAssertTrue(sevenZip.selectMenuItem("File", "Delete"))
        XCTAssertTrue(waitFor("folder went to the Trash") { !panel.hasRow(named: "made-by-test") },
                      "a file-system delete to the Trash asks nothing (01 §3.11); listing: \(panel.names)")
    }

    /// Rename (F2) edits the name in place and refocuses the renamed row (01 §3.11).
    func testRenameInPlace() throws {
        let scratch = try makeScratch("rename")
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "gamma.md"))
        panel.select("gamma.md")
        XCTAssertTrue(sevenZip.selectMenuItem("File", "Rename"))
        app.typeKey("a", modifierFlags: .command)
        app.typeText("renamed.md\r")
        XCTAssertTrue(waitFor("renamed") { panel.hasRow(named: "renamed.md") }, "listing: \(panel.names)")
        XCTAssertFalse(panel.hasRow(named: "gamma.md"))
    }

    /// Properties (Alt+Enter / toolbar Info) lists the item's properties (01 §3.11).
    func testPropertiesDialog() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "test.7z"))
        panel.select("test.7z")
        XCTAssertTrue(sevenZip.selectMenuItem("File", "Properties"))
        guard let dialog = sevenZip.waitForDialog(title: "Properties") else {
            return XCTFail("no Properties dialog")
        }
        screenshot("09-properties")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
    }

    // MARK: 2.8 context menu

    /// The list context menu of a file-system folder starts with the 7-Zip commands and ends with
    /// the File-menu items (CreateFileMenu, 01 §2.8).
    func testListContextMenuContents() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "test.7z"))
        // `app.menus.firstMatch` was the **Apple menu**: every menu-bar menu is in `app.menus`
        // too, all with an empty title and a zero frame while closed, so the assertions below ran
        // against "About This Mac ... Clear Menu". The list context menu is the NSTableView's own
        // `menu(for:)`, so it is a child of the table in the accessibility tree.
        guard let menu = panel.openContextMenu(onRow: "test.7z") else {
            return XCTFail("no context menu on the test.7z row")
        }
        let titles = panel.menuItemTitles(of: menu).filter { !$0.isEmpty }
        screenshot("10-context-menu")
        for expected in ["Open archive", "Extract files...", "Add to archive...", "Rename", "Delete", "Properties"] {
            XCTAssertTrue(titles.contains(expected), "context menu has no '\(expected)': \(titles)")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

}
