// SmokeTests.swift -- the UI tests that must stay green from Wave 1 on: navigating into a directory
// and into an archive, going up, the two-panel toggle and its persistence, sorting by a column
// header, and the password prompt. Every one of them double-clicks, clicks a header or types, so
// this class is part of the **input shard** and runs alone (macOS delivers a synthesized event to
// whatever is frontmost).
//
// Three cases left this file for a target that needs no GUI at all:
//   * the menu bar and toolbar inventory -> `SevenZipAppTests/MenuAndToolbarTests` (it is
//     `NSApp.mainMenu` and one `NSToolbar`, so no launch and no accessibility bus);
//   * "launches and lists the home directory" -> `UIProbe2/LaunchStateTests`, which reads and never
//     clicks, so it runs concurrently with the other read-only shards.
//
// The app is launched once for the class and reset between tests (`SevenZipUITestCase`); each test
// still declares the settings domain it needs, so nothing about what is asserted changed.

import Foundation
import XCTest

final class SmokeTests: SevenZipUITestCase {

    private var fixtures: String { TestPaths.fixtures }
    private var fixturesParent: String { (TestPaths.fixtures as NSString).deletingLastPathComponent }

    // MARK: 1.4 app shell / 1.6 basic panels

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

    // MARK: helpers

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
