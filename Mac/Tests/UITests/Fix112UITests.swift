// Fix112UITests.swift -- real mouse clicks on the column headers with the settings a 1.1.1 user
// had when sorting stopped working (ai/reports/fix112.md §1): Show ".." on and a stored
// file-system layout sorted by Created. The click used to change the saved sort but not the rows.
//
// Input shard: it clicks.

import XCTest

final class Fix112UITests: SevenZipUITestCase {

    override var screenshotPrefix: String { "fix112" }

    /// FM.Columns.FSFolder with the shape of the user's (column and sort values only).
    private static let userFSFolderLayout = """
    {"sortID":10,"ascending":true,"columns":[{"visible":true,"width":464,"propID":4},\
    {"visible":true,"width":126,"propID":7},{"visible":true,"width":124,"propID":12},\
    {"visible":true,"width":123,"propID":10},{"visible":true,"width":100,"propID":28},\
    {"visible":false,"width":123,"propID":11},{"visible":false,"width":100,"propID":9},\
    {"visible":false,"width":126,"propID":8}]}
    """

    private func makeScratch() throws -> String {
        let base = (TestPaths.artifacts as NSString).appendingPathComponent("fix112-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(atPath: base + "/sub", withIntermediateDirectories: true)
        for (file, size) in [("alpha.txt", 10), ("beta.txt", 2000), ("gamma.md", 100)] {
            try Data(repeating: 0x41, count: size).write(to: URL(fileURLWithPath: base + "/" + file))
        }
        addTeardownBlock { [weak sevenZip] in
            if let app = sevenZip, app.isRunning, app.testSupportIsImplemented {
                var options = SevenZipApp.ResetOptions()
                options.panels = 1
                options.path0 = TestPaths.fixtures
                options.path1 = TestPaths.fixtures
                _ = app.reset(options)
            }
            try? manager.removeItem(atPath: base)
        }
        return base
    }

    func testHeaderClicksSortWithShowDotsAndAStoredLayout() throws {
        let scratch = try makeScratch()
        launch(seed: .typed([SettingsDomain.Key.panelPath0: scratch,
                             SettingsDomain.Key.showDots: true,
                             "FM.ListMode0": 3,
                             "FM.Columns.FSFolder": Self.userFSFolderLayout]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "beta.txt"))
        func names() -> [String] { panel.names.filter { $0 != ".." } }
        panel.clickColumnHeader("Size")
        XCTAssertTrue(waitFor("size descending") { names() == ["sub", "beta.txt", "gamma.md", "alpha.txt"] },
                      "Size starts descending, order is \(names())")
        panel.clickColumnHeader("Size")
        XCTAssertTrue(waitFor("size ascending") { names() == ["sub", "alpha.txt", "gamma.md", "beta.txt"] },
                      "a second click ascends, order is \(names())")
        panel.clickColumnHeader("Name")
        XCTAssertTrue(waitFor("name ascending") { names() == ["sub", "alpha.txt", "beta.txt", "gamma.md"] },
                      "Name ascending, order is \(names())")
        panel.clickColumnHeader("Name")
        XCTAssertTrue(waitFor("name descending") { names() == ["sub", "gamma.md", "beta.txt", "alpha.txt"] },
                      "Name descending, order is \(names())")
        XCTAssertEqual(panel.names.first, "..", "the .. row stays first")
        screenshot("01-sorted-with-dots")
    }

    /// Options > macOS > Reset All Settings... > Yes, with real clicks: the app quits, its domain
    /// file keeps only the first-launch marker (nothing the quitting instance saved), and a new
    /// instance of the same bundle starts on that file.
    func testResetAllSettingsEmptiesTheDomainAndRestarts() throws {
        launch(seed: .typed([SettingsDomain.Key.panelPath0: TestPaths.fixtures,
                             SettingsDomain.Key.showDots: true,
                             "FM.Theme": "dark",
                             "FM.FirstLaunchIntegration": true,
                             "FM.Columns.FSFolder": Self.userFSFolderLayout]))
        let seed = try XCTUnwrap(sevenZip.seedFile)
        XCTAssertTrue(sevenZip.selectMenuItem("Tools", "Options..."), "Tools > Options...")
        let options = try XCTUnwrap(sevenZip.waitForDialog(title: "Options"), "no Options window")
        let tab = options.radioButtons["macOS"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10), "no macOS tab")
        tab.click()
        let reset = options.buttons["Reset All Settings..."]
        XCTAssertTrue(reset.waitForExistence(timeout: 10), "no Reset All Settings... button")
        screenshot("02-options-macos-reset")
        reset.click()
        let yes = app.buttons["Yes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 10), "no confirmation")
        XCTAssertTrue(app.staticTexts["Reset all 7-Zip settings to their defaults? 7-Zip will restart."].exists
                      || app.staticTexts.containing(NSPredicate(format: "value BEGINSWITH 'Reset all 7-Zip settings'")).firstMatch.exists,
                      "the question")
        screenshot("03-reset-question")
        yes.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 30), "the app quits")

        // The relaunched instance (a new process of the same bundle, outside XCUITest's launch).
        let again = XCUIApplication(bundleIdentifier: SevenZipApp.bundleIdentifier)
        XCTAssertTrue(again.wait(for: .runningForeground, timeout: 60), "7-Zip started again")
        XCTAssertTrue(again.windows.firstMatch.waitForExistence(timeout: 30), "with a window")
        let values = seed.values
        XCTAssertNil(values["FM.Theme"], "theme back to the default: \(values.keys.sorted())")
        XCTAssertNil(values[SettingsDomain.Key.showDots])
        XCTAssertNil(values["FM.Columns.FSFolder"])
        XCTAssertEqual(values["FM.FirstLaunchIntegration"] as? Bool, true, "the first-launch marker is kept")
        again.terminate()
        XCTAssertTrue(again.wait(for: .notRunning, timeout: 30))
    }
}
