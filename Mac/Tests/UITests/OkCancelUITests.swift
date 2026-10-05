// OkCancelUITests.swift -- the user's report, with real input (Mac/docs/reports/okcancel.md):
// "I right-clicked a table row, chose 7-Zip > Add to archive... and 7-Zip > Compress and email...,
// and SOMETIMES the OK and Cancel buttons don't work, while Help works and the red close button
// works."
//
// Each case right-clicks a row, opens the 7-Zip submenu, picks the verb, and clicks the dialog's
// own OK or Cancel with the mouse -- many times in a row, and right after another dialog -- and
// the dialog must be gone within a few seconds every time. Input shard (synthesized clicks).

import XCTest

final class OkCancelUITests: SevenZipUITestCase {

    override var screenshotPrefix: String { "okcancel" }
    override class var timeAllowance: TimeInterval { 900 }

    private func makeScratch() throws -> String {
        let fm = FileManager.default
        let base = (TestPaths.artifacts as NSString).appendingPathComponent("okcancel-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(atPath: base, withIntermediateDirectories: true)
        try Data("alpha".utf8).write(to: URL(fileURLWithPath: base + "/alpha.txt"))
        try Data("beta".utf8).write(to: URL(fileURLWithPath: base + "/beta.txt"))
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

    /// Right-click `row`, 7-Zip > `verb`; the dialog titled `title`, or nil.
    private func openVerb(_ verb: String, on row: String, expecting title: String) -> XCUIElement? {
        let panel = sevenZip.panel(0)
        guard let menu = panel.openContextMenu(onRow: row) else { XCTFail("no context menu on \(row)"); return nil }
        let top = menu.menuItems["7-Zip"]
        guard top.waitForExistence(timeout: 5) else { XCTFail("no 7-Zip submenu"); return nil }
        top.hover()
        let sub = top.menus.firstMatch
        guard sub.waitForExistence(timeout: 5) else { XCTFail("the 7-Zip submenu did not open"); return nil }
        let item = sub.menuItems.matching(NSPredicate(format: "title == %@", verb)).firstMatch
        guard item.waitForExistence(timeout: 5) else {
            XCTFail("no '\(verb)' in \(panel.menuItemTitles(of: sub))"); return nil
        }
        item.click()
        return sevenZip.waitForDialog(title: title, timeout: 20)
    }

    private func isGone(_ dialog: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !dialog.exists { return true }
            usleep(100_000)
        } while Date() < deadline
        return !dialog.exists
    }

    /// Click a button of the dialog with the mouse, after moving the mouse across the dialog's
    /// combo boxes as a user's pointer does on its way to OK / Cancel -- the move that sent the
    /// unrecognized `mouseEntered:` (the dialog came up under the pointer only sometimes).
    private func click(_ button: String, in dialog: XCUIElement) -> Bool {
        for combo in dialog.comboBoxes.allElementsBoundByIndex.prefix(2) where combo.exists { combo.hover() }
        for popup in dialog.popUpButtons.allElementsBoundByIndex.prefix(2) where popup.exists { popup.hover() }
        let b = dialog.buttons.matching(NSPredicate(format: "title == %@", button)).firstMatch
        guard b.waitForExistence(timeout: 5) else { return false }
        b.click()
        return true
    }

    /// Add to archive... and Compress and email... from the context menu, Cancel clicked, 20 times
    /// each, alternating, so every dialog also comes right after another one.
    func testContextMenuCompressDialogsCancelWithTheMouse() throws {
        let scratch = try makeScratch()
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "alpha.txt"))
        var failures: [String] = []
        for round in 1...(ProcessInfo.processInfo.environment["OKC_ROUNDS"].flatMap(Int.init) ?? 20) {
            for verb in ["Add to archive...", "Compress and email..."] {
                guard let dialog = openVerb(verb, on: round % 2 == 0 ? "alpha.txt" : "beta.txt",
                                            expecting: "Add to Archive") else {
                    failures.append("round \(round) \(verb): no dialog"); continue
                }
                if round == 1 && verb.hasPrefix("Add") { screenshot("compress-from-context-menu") }
                XCTAssertTrue(click("Cancel", in: dialog))
                if !isGone(dialog) {
                    failures.append("round \(round) \(verb): Cancel did not close the dialog")
                    screenshot("stuck-\(round)")
                    // get out with the close button so the next round starts clean
                    dialog.buttons[XCUIIdentifierCloseWindow].click()
                    _ = isGone(dialog)
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// Add to archive... from the context menu, OK clicked: the archive is written and the dialog
    /// goes, 10 times (each time a new name, so no Update-mode question is asked).
    func testContextMenuAddToArchiveOKWithTheMouse() throws {
        let scratch = try makeScratch()
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "alpha.txt"))
        var failures: [String] = []
        for round in 1...10 {
            guard let dialog = openVerb("Add to archive...", on: "alpha.txt", expecting: "Add to Archive") else {
                failures.append("round \(round): no dialog"); continue
            }
            let name = "ok\(round)"
            let combo = dialog.comboBoxes.firstMatch
            XCTAssertTrue(combo.waitForExistence(timeout: 5))
            combo.click()
            combo.typeKey("a", modifierFlags: .command)
            combo.typeText(name + ".7z")
            XCTAssertTrue(click("OK", in: dialog))
            if !isGone(dialog, timeout: 10) {
                failures.append("round \(round): OK did not close the dialog")
                screenshot("stuck-ok-\(round)")
                dialog.buttons[XCUIIdentifierCloseWindow].click()
                _ = isGone(dialog)
                continue
            }
            let path = scratch + "/" + name + ".7z"
            if !waitFor(path, timeout: 30, { FileManager.default.fileExists(atPath: path) }) {
                failures.append("round \(round): \(name).7z was not written")
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    /// The other entry points to the same dialogs: the toolbar's Add (IDM_ADD, kAddCommand 1070)
    /// and Extract, and 7-Zip > Extract files... (IDS_CONTEXT_EXTRACT 2323) from the context menu,
    /// each closed with Cancel after the pointer crossed the dialog's combos, five times.
    func testOtherEntryPointsCancelWithTheMouse() throws {
        let scratch = try makeScratch()
        try FileManager.default.copyItem(atPath: (TestPaths.fixtures as NSString).appendingPathComponent("test.zip"),
                                         toPath: scratch + "/arc.zip")
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "arc.zip"))
        var failures: [String] = []
        for round in 1...5 {
            for (way, title) in [("toolbar Add", "Add to Archive"), ("toolbar Extract", "Extract"),
                                 ("context Extract files...", "Extract")] {
                panel.select(round % 2 == 0 ? "alpha.txt" : "arc.zip")
                if way.hasPrefix("toolbar") { panel.select("arc.zip") }
                let dialog: XCUIElement?
                switch way {
                case "toolbar Add":
                    sevenZip.toolbarButton("Add").click()
                    dialog = sevenZip.waitForDialog(title: title, timeout: 20)
                case "toolbar Extract":
                    sevenZip.toolbarButton("Extract").click()
                    dialog = sevenZip.waitForDialog(title: title, timeout: 20)
                default:
                    dialog = openVerb("Extract files...", on: "arc.zip", expecting: title)
                }
                guard let dialog else { failures.append("round \(round) \(way): no dialog"); continue }
                XCTAssertTrue(click("Cancel", in: dialog))
                if !isGone(dialog) {
                    failures.append("round \(round) \(way): Cancel did not close the dialog")
                    dialog.buttons[XCUIIdentifierCloseWindow].click()
                    _ = isGone(dialog)
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }
}
