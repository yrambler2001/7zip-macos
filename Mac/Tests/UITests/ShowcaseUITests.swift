// ShowcaseUITests.swift -- the one showcase image that needs a real menu on screen: the panel's
// context menu with the 7-Zip submenu open (not used by the README), taken in the neutral
// demo folder `/Users/Shared/7-Zip Demo/` that `ShowcaseScreenshotTests` (app-hosted) creates.
//
// Opt-in like the app-hosted half: runs only when `Mac/build/showcase/RUN` exists (or
// SEVENZIP_SHOWCASE=1 is in the runner's environment) and the demo folder exists. `Mac/scripts/showcase.sh` runs both.
// The screenshot is an XCTest attachment that test.sh exports to Mac/build/screenshots/.

import XCTest

final class ShowcaseUITests: SevenZipUITestCase {

    override var screenshotPrefix: String { "showcase" }

    private static let demo = "/Users/Shared/7-Zip Demo"

    func testContextMenuImage() throws {
        let flag = (TestPaths.repoRoot ?? "/nonexistent") + "/Mac/build/showcase/RUN"
        guard ProcessInfo.processInfo.environment["SEVENZIP_SHOWCASE"] == "1"
                || FileManager.default.fileExists(atPath: flag) else {
            throw XCTSkip("showcase images are opt-in: Mac/scripts/showcase.sh")
        }
        guard FileManager.default.fileExists(atPath: Self.demo + "/Photos 2025.zip") else {
            throw XCTSkip("no demo folder; run ShowcaseScreenshotTests first (Mac/scripts/showcase.sh)")
        }
        launch(seed: .values([SettingsDomain.Key.panelPath0: Self.demo]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "Photos 2025.zip"))
        panel.select("Photos 2025.zip")
        guard let menu = panel.openContextMenu(onRow: "Photos 2025.zip") else {
            return XCTFail("no context menu on Photos 2025.zip")
        }
        let sevenZipItem = menu.menuItems["7-Zip"]
        sevenZipItem.hover()
        let sub = sevenZipItem.menus.firstMatch
        XCTAssertTrue(sub.waitForExistence(timeout: 5), "the 7-Zip submenu did not open")
        screenshot("context-menu")
        sevenZip.app.typeKey(.escape, modifierFlags: [])
        sevenZip.app.typeKey(.escape, modifierFlags: [])
    }
}
