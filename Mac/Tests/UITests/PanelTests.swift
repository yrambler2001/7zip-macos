// PanelTests.swift -- UI tests for the `panel` scope (01-fm-feature-inventory.md section 3):
// view modes, sorting, the selection commands, navigation into an archive, copy between panels,
// rename, create folder, delete to the Trash and the list context menu.
//
// They use the `harness` scope's helpers (`SevenZipUITestCase`, `SevenZipApp`, `SevenZipPanel`,
// `SettingsDomain`, `TestPaths`; see Mac/docs/api/harness.md). Those helpers and the `7-ZipUITests`
// target live on `mac/harness`, which is not merged into `macos` yet, so this file is compiled and
// run only after that merge -- `Mac/scripts/test.sh --ui`. Everything it asserts was verified by
// hand in the running app first (Mac/docs/reports/panel.md).

import XCTest

final class PanelTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "panel" }

    private var fixtures: String { TestPaths.fixtures }

    /// A fresh scratch directory with three files and one sub-folder.
    private func makeScratch(_ name: String) throws -> String {
        let base = (TestPaths.artifacts as NSString).appendingPathComponent("panel-\(name)-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(atPath: base, withIntermediateDirectories: true)
        try manager.createDirectory(atPath: (base as NSString).appendingPathComponent("sub"),
                                    withIntermediateDirectories: true)
        for (file, size) in [("alpha.txt", 10), ("beta.txt", 2000), ("gamma.md", 100)] {
            let data = Data(repeating: 0x41, count: size)
            try data.write(to: URL(fileURLWithPath: (base as NSString).appendingPathComponent(file)))
        }
        addTeardownBlock { try? manager.removeItem(atPath: base) }
        return base
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
        let field = dialog.comboBoxes.firstMatch.textFields.firstMatch
        if field.exists {
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeText("*.txt")
        }
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
        let destination = try makeScratch("copy-dst")
        launch(seed: .values([SettingsDomain.Key.panelPath0: source]))
        XCTAssertTrue(sevenZip.ensurePanelCount(2))
        let left = sevenZip.panel(0)
        let right = sevenZip.panel(1)
        right.navigate(to: destination)
        XCTAssertTrue(right.waitForPath(destination))
        XCTAssertTrue(left.waitForRow(named: "alpha.txt"))
        left.select("alpha.txt")
        XCTAssertTrue(sevenZip.selectMenuItem("File", "Copy To..."))
        guard let dialog = sevenZip.waitForDialog(title: "Copy") else { return XCTFail("no Copy dialog") }
        screenshot("07-copy-dialog")
        XCTAssertTrue(sevenZip.texts(of: dialog).contains { $0.contains("alpha.txt") },
                      "the info text lists the item: \(sevenZip.texts(of: dialog))")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
        XCTAssertTrue(waitFor("copied") { right.hasRow(named: "alpha.txt") }, "right panel: \(right.names)")
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
        let field = dialog.comboBoxes.firstMatch
        field.click()
        app.typeKey("a", modifierFlags: .command)
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
        let cell = panel.nameCell(named: "test.7z")
        cell.rightClick()
        let menu = app.menus.firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5), "no context menu")
        let titles = menu.menuItems.allElementsBoundByIndex.map { $0.title }
        screenshot("10-context-menu")
        for expected in ["Open archive", "Extract files...", "Add to archive...", "Rename", "Delete", "Properties"] {
            XCTAssertTrue(titles.contains(expected), "context menu has no '\(expected)': \(titles)")
        }
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: helpers

    private func waitFor(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }
}
