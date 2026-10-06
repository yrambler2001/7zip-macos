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

    /// A "7-Zip quit unexpectedly" box left over from an earlier crashed run sits over the main
    /// window and takes clicks; answer it with Ignore.
    private func dismissCrashReporter() {
        for id in ["com.apple.UserNotificationCenter"] {
            let other = XCUIApplication(bundleIdentifier: id)
            guard other.state != .notRunning else { continue }
            for _ in 0..<10 {
                let ignore = other.buttons.matching(identifier: "Ignore").firstMatch
                guard ignore.exists else { break }
                print("OKCANCEL | dismissing a crash report box of \(id)")
                ignore.click()
            }
        }
    }

    private func makeScratch() throws -> String {
        dismissCrashReporter()
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
        guard let menu = panel.openContextMenu(onRow: row) else {
            screenshot("no-context-menu")
            XCTFail("no context menu on \(row)"); return nil
        }
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

    /// Add to archive... from the context menu, OK clicked with the default name: the dialog goes
    /// and `alpha.7z` is written, 10 times (the archive is removed between rounds).
    func testContextMenuAddToArchiveOKWithTheMouse() throws {
        let scratch = try makeScratch()
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "alpha.txt"))
        let path = scratch + "/alpha.7z"
        var failures: [String] = []
        for round in 1...10 {
            try? FileManager.default.removeItem(atPath: path)
            // Let the listing settle first, or the right click lands on a row that is moving.
            _ = waitFor("alpha.7z gone from the list", timeout: 10) { !panel.hasRow(named: "alpha.7z") }
            guard let dialog = openVerb("Add to archive...", on: "alpha.txt", expecting: "Add to Archive") else {
                failures.append("round \(round): no dialog"); continue
            }
            XCTAssertTrue(click("OK", in: dialog))
            if !isGone(dialog, timeout: 10) {
                failures.append("round \(round): OK did not close the dialog")
                screenshot("stuck-ok-\(round)")
                dialog.buttons[XCUIIdentifierCloseWindow].click()
                _ = isGone(dialog)
                continue
            }
            if !waitFor(path, timeout: 30, { FileManager.default.fileExists(atPath: path) }) {
                screenshot("not-written-\(round)")
                failures.append("round \(round): alpha.7z was not written")
            }
            _ = panel.waitForRow(named: "alpha.7z", timeout: 10)
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
        // Selected once: a second click on a selected name starts the slow-click rename (01 §3.9).
        panel.select("arc.zip")
        var failures: [String] = []
        for round in 1...5 {
            for (way, title) in [("toolbar Add", "Add to Archive"), ("toolbar Extract", "Extract"),
                                 ("context Extract files...", "Extract")] {
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
