// LaunchStateTests.swift -- what the app shows when it comes up, read and not touched: the second
// read-only shard (`7-Zip-Probe2`, bundle id `com.yrambler2001.7zip-p2`).
//
// From `SmokeTests`, which is otherwise a click-driven class. These two cases synthesize nothing:
// they launch with a known settings domain and compare the accessibility tree against it, so they
// run concurrently with the other read-only shards.

import XCTest

final class LaunchStateTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "harness" }

    // MARK: 1.4 app shell / 1.6 basic panels

    /// The app launches, shows one window and lists the home directory (the scaffold's start folder
    /// when nothing is stored), with the status bar and the window title following the panel.
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

    /// A seeded folder is what panel 0 opens in, and the seven default columns of a file-system
    /// folder are all there (01 section 3.2). The launch-side half of what the 93-language sweep
    /// used to assert once per language; the language-dependent half is now
    /// `SevenZipAppTests/LocalizationFittingTests`.
    func testSeededFolderAndColumnsComeUp() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "test.7z"), "fixtures listing: \(panel.names)")
        let fixtureCount = (try? FileManager.default.contentsOfDirectory(atPath: TestPaths.fixtures))?
            .filter { !$0.hasPrefix(".") }.count ?? 0
        XCTAssertGreaterThan(fixtureCount, 0, "no fixtures at \(TestPaths.fixtures)")
        XCTAssertEqual(panel.rowCount, fixtureCount, "listing: \(panel.names)")
        let columns = panel.columnTitles
        XCTAssertGreaterThanOrEqual(columns.count, 7, "columns: \(columns)")
        XCTAssertEqual(columns.first, "Name")
        XCTAssertFalse(columns.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty },
                       "a column header is empty: \(columns)")
        screenshot("02-fixtures-columns")
    }
}
