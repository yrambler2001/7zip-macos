// SmokeTests.swift -- the UI tests that must stay green from Wave 1 on. They cover only what the
// scaffold already does (architecture.md "As built"): launching, listing, navigating into a
// directory and into an archive, going up, the two-panel toggle and its persistence, sorting by a
// column header, and the menu bar / toolbar inventory. Behaviour that is not implemented yet is
// listed in Mac/docs/reports/harness.md instead of being asserted here.
//
// Every test launches the app with clean settings passed as launch arguments (one panel, panel 0
// in the home directory, 1200x800 window); nothing stored is changed by the test itself, and
// Mac/scripts/test.sh backs up and restores the real preferences domain around the run.

import Foundation
import XCTest

final class SmokeTests: SevenZipUITestCase {

    private var fixtures: String { TestPaths.fixtures }
    private var fixturesParent: String { (TestPaths.fixtures as NSString).deletingLastPathComponent }

    // MARK: 1.4 app shell / 1.6 basic panels

    /// The app launches, shows one window and lists the home directory (the scaffold's start
    /// folder when nothing is stored).
    func testLaunchesAndListsHomeDirectory() {
        launch()
        XCTAssertTrue(sevenZip.window.exists, "no main window")
        XCTAssertEqual(sevenZip.panelCount, 1, "kNumDefaultPanels is 1")
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForPath(TestPaths.realHome), "panel 0 shows \(panel.path)")
        XCTAssertGreaterThan(panel.rowCount, 0, "home directory listed no items")
        XCTAssertTrue(panel.status.contains("object(s) selected"), "status bar reads '\(panel.status)'")
        XCTAssertEqual(sevenZip.windowTitle, TestPaths.realHome + "/", "window title follows the panel path")
        screenshot("01-home")
    }

    /// Double-clicking a directory row enters it (CPanel::OpenItem).
    func testNavigateIntoDirectory() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: fixturesParent]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForPath(fixturesParent))
        XCTAssertTrue(panel.waitForRow(named: "Fixtures"), "no Fixtures row in \(panel.names)")
        panel.open("Fixtures")
        XCTAssertTrue(panel.waitForPath(fixtures), "panel went to \(panel.path)")
        XCTAssertTrue(panel.waitForRow(named: "test.7z"))
        screenshot("02-fixtures")
    }

    /// Opening an archive lists its entries in the same panel (archive as folder, 2.3).
    func testOpenFixtureArchiveListsEntries() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "test.7z"))
        panel.open("test.7z")
        XCTAssertTrue(panel.waitForPath(TestPaths.fixture("test.7z")), "panel shows \(panel.path)")
        for entry in ["readme.txt", "notes.md", "sub"] {
            XCTAssertTrue(panel.waitForRow(named: entry), "archive listing lacks \(entry): \(panel.names)")
        }
        screenshot("03-archive")
    }

    /// "Up One Level" walks out of a folder inside the archive and then out of the archive itself
    /// (bindToParentFolder).
    func testGoUpFromInsideArchive() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "test.7z"))
        panel.open("test.7z")
        XCTAssertTrue(panel.waitForRow(named: "sub"))
        panel.open("sub")
        XCTAssertTrue(panel.waitForRow(named: "big.txt"), "sub/ listing is \(panel.names)")
        panel.goUp()
        XCTAssertTrue(panel.waitForPath(TestPaths.fixture("test.7z")), "back in the archive root, not \(panel.path)")
        panel.goUp()
        XCTAssertTrue(panel.waitForPath(fixtures), "back in the fixtures folder, not \(panel.path)")
        XCTAssertTrue(panel.hasRow(named: "test.7z"))
    }

    /// View > 2 Panels adds the second panel and the choice survives a relaunch
    /// (IDM_VIEW_TWO_PANELS 732, FM.Panels.numPanels).
    func testTwoPanelsToggleAndPersistsAcrossRelaunch() {
        launch()
        XCTAssertTrue(sevenZip.ensurePanelCount(1), "could not get down to one panel")
        XCTAssertTrue(sevenZip.selectMenuItem("View", "2 Panels"), "View > 2 Panels not clickable")
        XCTAssertTrue(waitFor("two panels") { self.sevenZip.panelCount == 2 })
        XCTAssertTrue(sevenZip.panelsAreOrderedLeftToRight)
        XCTAssertTrue(sevenZip.panel(1).waitForPath(TestPaths.realHome), "panel 1 shows \(sevenZip.panel(1).path)")
        screenshot("04-two-panels")

        // quit through the menu so the app saves FM.Panels.numPanels, then start with whatever is
        // stored (seed .keep) -- the second panel must come back.
        sevenZip.relaunch()
        XCTAssertTrue(waitFor("two panels after relaunch") { self.sevenZip.panelCount == 2 },
                      "relaunch showed \(sevenZip.panelCount) panel(s)")
        screenshot("06-two-panels-restored")
        XCTAssertTrue(sevenZip.ensurePanelCount(1), "leave one panel behind for the next test")
        _ = sevenZip.quit()
    }

    /// Clicking a column header sorts by it; size columns start descending and the second click
    /// reverses (PanelSort.cpp OnColumnClick).
    func testSortByColumnHeaderReordersRows() throws {
        // The default order is only name-ascending when nothing is stored for this folder type:
        // the app saves the sort column under `FM.Columns.FSFolder` when it quits, so a test that
        // clicked Size or chose Unsorted used to make this one start from that order. Each launch
        // now gets a settings domain of its own (SettingsSeedFile), which is what keeps the
        // assertion below honest -- do not relax it, it is the isolation regression test.
        launch(seed: .values([SettingsDomain.Key.panelPath0: fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "test.7z"))
        XCTAssertEqual(panel.columnTitles.first, "Name")
        XCTAssertTrue(panel.columnTitles.contains("Size"), "columns: \(panel.columnTitles)")
        XCTAssertNil(sevenZip.seedFile?.values["FM.Columns.FSFolder"],
                     "the seeded domain must not carry a stored column layout")

        let byName = try expectedOrder(bySizeDescending: nil)
        XCTAssertEqual(panel.names, byName, "default order is name ascending")

        panel.clickColumnHeader("Size")
        let descending = try expectedOrder(bySizeDescending: true)
        XCTAssertTrue(waitFor("size descending") { panel.names == descending },
                      "after one Size click: \(panel.names) != \(descending)")
        screenshot("05-sorted-by-size")

        panel.clickColumnHeader("Size")
        let ascending = try expectedOrder(bySizeDescending: false)
        XCTAssertTrue(waitFor("size ascending") { panel.names == ascending },
                      "after two Size clicks: \(panel.names) != \(ascending)")
    }

    /// An encrypted archive asks for the password and lists its entries once it is given
    /// (SZPasswordDelegate, IDD_PASSWORD 3800; `secret.7z` uses the password "secret").
    func testPasswordPromptOpensEncryptedArchive() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "secret.7z"))
        panel.open("secret.7z")
        guard let dialog = sevenZip.waitForDialog(title: "Enter password") else {
            return XCTFail("no password dialog; dialogs: \(app.dialogs.count), sheets: \(app.sheets.count)")
        }
        screenshot("07-password")
        let field = dialog.secureTextFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no password field")
        field.click()
        field.typeText("secret")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
        XCTAssertTrue(panel.waitForRow(named: "readme.txt"), "listing after the password: \(panel.names)")
    }

    /// The menu bar has the 7zFM menus with the expected items (MainMenu.swift, 01 section 2).
    func testMenuBarStructure() throws {
        launch()
        // Titles come from the lang file, which a test cannot seed (Lang is read through
        // CFPreferences); Mac/scripts/test.sh sets Lang = "-" for the run. If some other language
        // is loaded the titles are not the English resource texts, so skip instead of failing.
        try XCTSkipUnless(sevenZip.itemTitles(in: "Tools").contains("Benchmark"),
                          "the app is not running with English strings (set Lang to \"-\")")
        XCTAssertEqual(Array(sevenZip.topLevelMenuTitles.dropFirst()),
                       ["7-Zip", "File", "Edit", "View", "Favorites", "Tools", "Window", "Help"],
                       "top level menus: \(sevenZip.topLevelMenuTitles)")

        assertMenu("File", contains: ["Open", "Open Inside", "Open Inside *", "Open Inside #",
                                      "Open Outside", "View", "Edit", "Rename", "Copy To...",
                                      "Move To...", "Delete", "Split file...", "Combine files...",
                                      "Properties", "Comment...", "CRC", "Diff", "Create Folder",
                                      "Create File", "Link...", "Exit"])
        assertMenu("Edit", contains: ["Select All", "Deselect All", "Invert Selection", "Select...",
                                      "Deselect...", "Select by Type", "Deselect by Type"])
        assertMenu("View", contains: ["Large Icons", "Small Icons", "List", "Details", "Name", "Type",
                                      "Date", "Size", "Unsorted", "Flat View", "2 Panels", "Toolbars",
                                      "Open Root Folder", "Up One Level", "Folders History...",
                                      "Refresh", "Auto Refresh"])
        assertMenu("Tools", contains: ["Options...", "Benchmark", "Delete Temporary Files..."])
        assertMenu("Help", contains: ["Contents...", "About 7-Zip..."])
        XCTAssertEqual(sevenZip.itemTitles(in: "Favorites").first, "Add folder to Favorites as")

        // items are addressable by the selector they send, whatever language the titles are in
        XCTAssertTrue(sevenZip.menuItem(selector: "viewTwoPanels:").exists)
        // IDM_ABOUT 961 is wired to MenuActions.helpAbout in MainMenu.swift, but
        // ToolsCommands.install() retargets both About items at the real IDD_ABOUT 2900 dialog on
        // didFinishLaunching, and an NSMenuItem's accessibility identifier is its *current* action
        // -- so the built menu shows `toolsShowAbout:`. Accept either, and assert the item is there
        // and enabled by its menu path (requests.md: harness -> tools/panel).
        XCTAssertTrue(sevenZip.menuItem("Help", "About 7-Zip...").isEnabled, "Help > About 7-Zip...")
        XCTAssertTrue(sevenZip.menuItem(selector: "helpAbout:").exists
                          || sevenZip.menuItem(selector: "toolsShowAbout:").exists,
                      "no About item addressable by selector")
        XCTAssertTrue(sevenZip.menuItem("File", "CRC", "MD5").exists, "nested CRC submenu")
        XCTAssertEqual(sevenZip.itemTitles(in: "File", "CRC"),
                       ["CRC-32", "CRC-64", "XXH64", "MD5", "SHA-1", "SHA-256", "SHA-384",
                        "SHA-512", "SHA3-256", "BLAKE2sp", "*"],
                       "the CRC submenu is titled from lang id 553, which no .ttt translates")
    }

    /// The seven 7zFM toolbar buttons exist and Add is wired to the Compress dialog
    /// (App.cpp g_ArchiveButtons / g_StandardButtons).
    func testToolbarButtons() {
        launch()
        XCTAssertEqual(sevenZip.toolbarButtonTitles, ["Add", "Extract", "Test", "Copy", "Move", "Delete", "Info"])
        XCTAssertTrue(sevenZip.toolbarButton("Add").exists)
        XCTAssertTrue(sevenZip.toolbarButton("Add").isEnabled, "the compress scope implemented Add")
    }

    // MARK: helpers

    private func assertMenu(_ menu: String, contains expected: [String],
                            file: StaticString = #filePath, line: UInt = #line) {
        let titles = sevenZip.itemTitles(in: menu).filter { !$0.isEmpty }
        for title in expected where !titles.contains(title) {
            XCTFail("menu \(menu) has no item '\(title)'; it has \(titles)", file: file, line: line)
        }
    }

    /// Poll `condition` (UI updates land asynchronously through the panel's queue).
    private func waitFor(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    /// The fixture file names in the order the panel must show them: directories first, then by
    /// size (nil = by name ascending), ties broken by name — in the *same* direction as the sort,
    /// because `CompareItems` (PanelSort.cpp:220) applies `_ascending ? res : -res` to the whole
    /// comparison, the `kpidName` tie-break round included. `multi.7z.001` and `multi.7z.002` are
    /// both exactly 12 000 bytes, which is the only place in the fixtures where this shows.
    private func expectedOrder(bySizeDescending descending: Bool?) throws -> [String] {
        let fm = FileManager.default
        let names = try fm.contentsOfDirectory(atPath: fixtures)
        var items: [(name: String, size: Int, isDir: Bool)] = []
        for name in names {
            let attrs = try fm.attributesOfItem(atPath: (fixtures as NSString).appendingPathComponent(name))
            items.append((name, (attrs[.size] as? Int) ?? 0, (attrs[.type] as? FileAttributeType) == .typeDirectory))
        }
        return items.sorted { a, b in
            if a.isDir != b.isDir { return a.isDir }
            guard let descending else { return a.name.lowercased() < b.name.lowercased() }
            if a.size != b.size { return descending ? a.size > b.size : a.size < b.size }
            return descending ? a.name.lowercased() > b.name.lowercased()
                              : a.name.lowercased() < b.name.lowercased()
        }.map { $0.name }
    }
}
