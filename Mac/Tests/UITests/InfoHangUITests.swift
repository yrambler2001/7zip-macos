// InfoHangUITests.swift -- the user's report, with real clicks: "I clicked Info in 7-Zip File
// Manager, closed it and then the app became unresponsive" (Mac/docs/reports/infohang.md).
//
// The flat toolbar's Info button (IDM_PROPERTIES 551, IDS_BUTTON_INFO) is clicked with the mouse,
// the Properties list (IDS_PROPERTIES 6600) is closed each way a user closes a window -- OK,
// Escape, the title-bar close button, Cmd+W -- and the app must then still take input: a menu
// command (Edit > Select All) and a click on a row both have to reach the panel and change its
// status bar. Before the fix the close button left `NSApp.runModal` running for a window that was
// no longer on screen, so the menu items stayed disabled and the click on the row was refused.
// The app-hosted half, with every item kind and every toolbar dialog, is `InfoHangTests`.

import Foundation
import XCTest

final class InfoHangUITests: SevenZipUITestCase {

    override var screenshotPrefix: String { "infohang" }

    private func makeScratch() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("infohang-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        // Leave the directory before deleting it (PanelTests.addSafeCleanup explains why).
        addTeardownBlock { [weak sevenZip] in
            if let app = sevenZip, app.isRunning, app.testSupportIsImplemented {
                var options = SevenZipApp.ResetOptions()
                options.panels = 1
                options.path0 = TestPaths.fixtures
                options.path1 = TestPaths.fixtures
                _ = app.reset(options)
            }
            try? FileManager.default.removeItem(atPath: dir)
        }
        for name in ["one.txt", "two.txt", "three.txt"] {
            try "\(name)\n".write(toFile: (dir as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return dir
    }

    private func propertiesIsGone(timeout: TimeInterval = 10) -> Bool {
        let properties = app.windows.matching(NSPredicate(format: "title == %@", "Properties")).firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !properties.exists { return true }
            usleep(200_000)
        } while Date() < deadline
        return !properties.exists
    }

    func testToolbarInfoThenCloseEveryWayLeavesTheAppResponsive() throws {
        let scratch = try makeScratch()
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "one.txt"))
        let info = sevenZip.toolbarButton("Info")
        XCTAssertTrue(info.waitForExistence(timeout: 10), "no Info button in the toolbar")

        for way in ["OK", "Escape", "close button", "Cmd+W"] {
            panel.nameCell(named: "one.txt").click()
            XCTAssertTrue(waitFor("one row selected before Info") { panel.status.contains("1 / 3") },
                          "\(way): status \(panel.status)")
            info.click()
            guard let dialog = sevenZip.waitForDialog(title: "Properties", timeout: 15) else {
                return XCTFail("\(way): toolbar Info opened no Properties dialog")
            }
            if way == "close button" { screenshot("properties-open") }
            switch way {
            case "OK":
                XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
            case "Escape":
                app.typeKey(.escape, modifierFlags: [])
            case "close button":
                let close = dialog.buttons[XCUIIdentifierCloseWindow]
                XCTAssertTrue(close.waitForExistence(timeout: 5), "the Properties window has no close button")
                close.click()
            default:
                app.typeKey("w", modifierFlags: .command)
            }
            XCTAssertTrue(propertiesIsGone(), "\(way): the Properties window did not close")

            // Still responsive: a menu command reaches the panel ...
            XCTAssertTrue(sevenZip.selectMenuItem("Edit", "Select All"), "\(way): Edit > Select All")
            XCTAssertTrue(waitFor("Select All after \(way)") { panel.status.contains("3 / 3") },
                          "\(way): the menu no longer reaches the panel (status \(panel.status))")
            // ... and so does a click on a row.
            panel.nameCell(named: "two.txt").click()
            XCTAssertTrue(waitFor("click after \(way)") { panel.status.contains("1 / 3") },
                          "\(way): a click on a row was refused (status \(panel.status))")
        }
        screenshot("responsive-after-close")
    }
}
