// CommandModeUITests.swift -- the `cmdmode` scope's XCUITest coverage.
//
// **Command mode cannot be driven by XCUITest at all**, which was measured rather than assumed.
// `argv[1] ∈ {a,u,d,rn,x,e,t,h,b}` puts the process into 7zG mode: every window is ordered out and
// the process `exit()`s with the 7zG code (03-shell-integration-inventory.md section 6.4). Launching
// that from XCUITest fails two different ways, and both were seen in a real run:
//
//   * a command that finishes by itself (`t -y <archive>`) exits before the runner can attach, and
//     `XCUIApplication.launch()` fails with "Application 'com.yrambler2001.7zip' has not loaded
//     accessibility" after ~69 s;
//   * a command that shows a dialog (`a … -ad`, or an error box) is inside `NSApp.runModal` while
//     still handling `applicationDidFinishLaunching`, so the app never becomes idle and `launch()`
//     fails the same way after ~69 s.
//
// Exit codes are therefore verified by running the built binary from a shell and reading `$?` --
// 25 cases, listed in `Mac/docs/reports/cmdmode.md` section 4.2 -- and the two dialogs command mode
// is allowed to show are screenshotted here through the **file manager**, where they are the same
// dialogs built by the same code:
//
//   * IDD_COMPRESS 4000 "Add to archive" (lang id 4000; the source fallback spells it "Add to
//     Archive", the lang file wins) is what `-ad` opens, and `-ad` is exactly what a Dock drop
//     passes (`a <selection> -ad -saa -- <dir><name>`, 03 section 1.4 item B5, section 1.7);
//   * IDS_CHECKSUM_INFORMATION 7501 "Checksum information" is what `h` shows and, since this scope
//     wired `-scrc` on `x`/`t`, what those two now show instead of the test summary box
//     (03 section 2.6, ExtractGUI.cpp:129-152).
//
// The Dock **gesture** is not reachable either: Automation permission is not granted on this machine
// and XCUITest cannot drag onto the Dock. `Mac/docs/parity.md` F.4 records the one manual check a
// human still owes; the routing, the argv, the Apple-event sender detection and the `Info.plist`
// claim are unit-tested in `CommandModeTests`.

import Foundation
import XCTest

final class CommandModeUITests: SevenZipUITestCase {

    override var screenshotPrefix: String { "cmdmode" }

    /// A small folder for the panel to start in, so the tests do not depend on the fixtures' shape.
    private func makeScratch(_ name: String) throws -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("cmdmode-ui-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        try "hello 7-zip\n".write(toFile: (dir as NSString).appendingPathComponent("one.txt"),
                                 atomically: true, encoding: .utf8)
        try "second file\n".write(toFile: (dir as NSString).appendingPathComponent("two.txt"),
                                 atomically: true, encoding: .utf8)
        return dir
    }

    /// IDD_COMPRESS 4000: the dialog a Dock drop of one or more items opens, because
    /// `FinderMenuModel`'s `SevenZipCompress` verb carries `-ad` and `-ad` is the only thing that
    /// opens it (03 section 2.4). Cancel is `E_ABORT`, i.e. exit 255 in command mode; inside the file
    /// manager it just closes, and the panel must survive it.
    func testAddToArchiveDialogIsTheOneADockDropOpens() throws {
        let scratch = try makeScratch("compress")
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "one.txt"))
        XCTAssertTrue(sevenZip.selectMenuItem("Edit", "Select All"))

        let add = sevenZip.toolbarButton("Add")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "no Add button in the toolbar")
        add.click()

        // The window title is lang id 4000, which `en.ttt` spells "Add to archive" -- the
        // `Lang.text(4000, "Add to Archive")` fallback in the source is never what a run sees.
        guard let dialog = sevenZip.waitForDialog(title: "Add to archive", timeout: 30) else {
            _ = sevenZip.dumpTree("cmdmode-compress")
            return XCTFail("IDD_COMPRESS 4000 did not appear")
        }
        // The format combo is the control that identifies it (IDC_COMPRESS_FORMAT 104).
        XCTAssertTrue(dialog.comboBoxes.count > 0 || dialog.popUpButtons.count > 0,
                      "the Compress dialog has no format combo")
        screenshot("01-add-to-archive-dialog")

        // Escape, not the Cancel button: this dialog is currently wider than the screen and its
        // bottom button row is clipped (`parity.md` B17, which a parallel agent is fixing), so the
        // button is not hittable and a test that clicked it would fail for the wrong reason.
        app.typeKey(.escape, modifierFlags: [])
        if !sevenZip.waitForNoDialog(timeout: 10) {
            XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "Cancel"))
        }
        XCTAssertTrue(panel.waitForRow(named: "one.txt"), "the panel must survive a cancelled Add")
    }

    /// IDS_CHECKSUM_INFORMATION 7501: the results list `h` shows and that `x -scrc` / `t -scrc` now
    /// show instead of the test summary. Reached here through File ▸ CRC ▸ CRC-32, which builds it
    /// with the same `HashResultsDialog.show(results:parent:)` the command path calls.
    func testChecksumInformationDialogIsWhatScrcShows() throws {
        let scratch = try makeScratch("checksum")
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "one.txt"))
        XCTAssertTrue(sevenZip.selectMenuItem("Edit", "Select All"))
        XCTAssertTrue(sevenZip.selectMenuItem("File", "CRC", "CRC-32"))

        guard let dialog = sevenZip.waitForDialog(title: "Checksum information", timeout: 60) else {
            _ = sevenZip.dumpTree("cmdmode-checksum")
            return XCTFail("IDS_CHECKSUM_INFORMATION 7501 did not appear")
        }
        // Two columns of name/value rows (AddHashBundleRes).
        XCTAssertTrue(dialog.tables.count > 0 || dialog.outlines.count > 0,
                      "the checksum dialog has no results list")
        screenshot("02-checksum-information")

        // Its button is Close (lang 408), not OK.
        if !sevenZip.dismissDialog(dialog, button: "Close") {
            XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
        }
        XCTAssertTrue(panel.waitForRow(named: "one.txt"))
    }
}
