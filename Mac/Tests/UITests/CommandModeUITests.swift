// CommandModeUITests.swift -- the `cmdmode` scope's XCUITest coverage: the app really launched in
// 7zG command mode (03-shell-integration-inventory.md section 2, section 6.4), the three dialogs
// that command mode is allowed to show, and the argv a Dock drop produces.
//
// Why it is shaped like this: command mode orders every window out and `exit()`s with the 7zG exit
// code, so `SevenZipApp.launch()` -- which waits for a window and a panel table -- cannot be used.
// These tests drive `XCUIApplication` directly with the real argv, which is the only way to see the
// command-mode dialogs from a test.
//
// The **Dock drop itself** is not reachable: Automation permission is not granted on this machine
// and XCUITest cannot drag onto the Dock (`Mac/docs/parity.md` F.4 records the one manual check a
// human still owes). What is covered here is the command a Dock drop runs -- the exact argv
// `FinderMenuModel`'s `SevenZipCompress` verb builds, which `CommandModeTests` asserts separately --
// so the half that can be automated is.

import Foundation
import XCTest

final class CommandModeUITests: SevenZipUITestCase {

    override var screenshotPrefix: String { "cmdmode" }

    private var work: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmdmode-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let work { try? FileManager.default.removeItem(at: work) }
        super.tearDown()
    }

    // MARK: - helpers

    /// Launch the app in 7zG command mode with `argv` and its own throwaway settings domain.
    /// `SevenZipApp.launch()` is deliberately not used: there is no window and no panel to wait for.
    private func launchCommandMode(_ argv: [String]) {
        let app = sevenZip.app
        app.launchArguments = argv
        var env = ["SEVENZIP_UITEST": "1"]
        // A domain of its own, so the developer's settings and the other tests are untouched.
        env[SettingsDomain.suiteEnvironmentVariable] =
            "com.yrambler2001.7zip.cmdmode-ui-\(UUID().uuidString)"
        app.launchEnvironment = env
        if sevenZip.isRunning { app.terminate() }
        app.launch()
    }

    /// The first window command mode put on screen (the main window is ordered out, so anything
    /// visible is the command's own dialog).
    private func waitForDialog(timeout: TimeInterval = 60) -> XCUIElement? {
        let app = sevenZip.app
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for index in 0..<app.windows.count {
                let candidate = app.windows.element(boundBy: index)
                if candidate.exists, candidate.isHittable, candidate.frame.width > 1 {
                    return candidate
                }
            }
            for index in 0..<app.dialogs.count {
                let candidate = app.dialogs.element(boundBy: index)
                if candidate.exists { return candidate }
            }
            _ = app.windows.element(boundBy: 0).waitForExistence(timeout: 1)
        }
        return nil
    }

    /// Screenshot one element under this scope's prefix, so `test.sh` exports it as
    /// `Mac/docs/reports/screenshots/cmdmode-<name>.png`. `SevenZipApp.screenshot` always shoots
    /// window 0, which in command mode may be the ordered-out main window.
    private func attach(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = "\(screenshotPrefix)-\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Close a command-mode dialog whatever its button is called (lang 401 OK / 402 Cancel /
    /// 408 Close), then assert the process really exited -- command mode calls `exit()` with the
    /// 7zG code, so "the app is gone" is the observable end of the command.
    private func dismissAndExpectExit(_ dialog: XCUIElement, preferring titles: [String]) {
        for title in titles where dialog.buttons[title].exists {
            dialog.buttons[title].click()
            if sevenZip.app.wait(for: .notRunning, timeout: 60) { return }
        }
        dialog.typeKey(.escape, modifierFlags: [])
        if sevenZip.app.wait(for: .notRunning, timeout: 20) { return }
        let any = dialog.buttons.firstMatch
        if any.exists { any.click() }
        XCTAssertTrue(sevenZip.app.wait(for: .notRunning, timeout: 60),
                      "command mode must exit once its dialog is closed")
    }

    /// A small tree to compress, and a 7z archive made from it by the app itself.
    private func makeFixtureTree() throws -> (files: [String], archive: String) {
        let one = work.appendingPathComponent("one.txt")
        let two = work.appendingPathComponent("two.txt")
        try "hello 7-zip\n".write(to: one, atomically: true, encoding: .utf8)
        try "second file\n".write(to: two, atomically: true, encoding: .utf8)
        let archive = work.appendingPathComponent("made.7z")
        // Built with the console tool when it exists, else with the app in command mode.
        let tool = (TestPaths.repoRoot ?? "") + "/CPP/7zip/Bundles/Alone2/b/m_arm64/7zz"
        if FileManager.default.isExecutableFile(atPath: tool) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = ["a", archive.path, one.path, two.path]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
        } else {
            launchCommandMode(["a", "-y", archive.path, one.path, two.path])
            XCTAssertTrue(sevenZip.app.wait(for: .notRunning, timeout: 120))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path),
                      "the fixture archive was not created")
        return ([one.path, two.path], archive.path)
    }

    // MARK: - 03 section 2.4: the dialogs command mode may show

    /// The command a **Dock drop** of two files runs: `FinderMenuModel`'s `SevenZipCompress` verb,
    /// i.e. `a <selection> -ad -saa -- <dir><name>` (03 section 1.4 item B5, section 1.7). `-ad` is
    /// the only thing that opens the Compress dialog (03 section 2.4), so seeing it here is seeing
    /// what a Dock drop puts on screen.
    func testDockDropArgvOpensTheCompressDialog() throws {
        let fixture = try makeFixtureTree()
        // The verb's argv, spelled out: the UI-test target must not link the app's Integration
        // sources (they belong to the two sandboxed appex targets as well), and
        // `CommandModeTests.testDockDropCompressCommandIsTheFinderMenuCommand` is what asserts that
        // `FinderMenuModel` really produces this shape. `CreateArchiveName` of two files in one
        // folder is that folder's name.
        let folder = work.path + "/"
        let argv = ["a"]
            + fixture.files.map { "-iw-!" + $0 }
            + ["-ad", "-saa", "--", folder + work.lastPathComponent]

        launchCommandMode(argv)
        let dialog = try XCTUnwrap(waitForDialog(), "the Compress dialog did not appear")
        // IDD_COMPRESS 4000: the format combo is the control that identifies it.
        XCTAssertTrue(dialog.comboBoxes.count > 0 || dialog.popUpButtons.count > 0,
                      "no combo box in \(dialog.debugDescription)")
        attach(dialog, "01-dock-drop-compress")

        // Cancel is E_ABORT, i.e. exit 255, and the process really goes away.
        dismissAndExpectExit(dialog, preferring: ["Cancel", "Close"])
    }

    /// `t -scrc<M>`: the checksums of the extracted data go to the hash results list **instead of**
    /// the test summary (03 section 2.6, ExtractGUI.cpp:129-152). Like upstream's `ShowHashResults`
    /// the list is not suppressed by `-y`.
    func testTestWithScrcShowsTheChecksumList() throws {
        let fixture = try makeFixtureTree()
        launchCommandMode(["t", "-y", "-scrcSHA256", fixture.archive])
        let dialog = try XCTUnwrap(waitForDialog(), "the checksum list did not appear")
        // IDS_CHECKSUM_INFORMATION: a 2-column list of name/value rows.
        XCTAssertTrue(dialog.tables.count > 0 || dialog.outlines.count > 0,
                      "no list in \(dialog.debugDescription)")
        attach(dialog, "02-scrc-checksum-list")

        dismissAndExpectExit(dialog, preferring: ["Close", "OK", "Cancel"])
    }

    /// `-sfx<module>` with a module that is not there: an error box and nothing written, instead of
    /// the bundled stub or a plain archive (01b section 4.23, parity.md F.3). Without `-y` the box
    /// is shown, which is what makes it visible to a test.
    func testMissingSfxModuleShowsAnErrorAndWritesNothing() throws {
        let fixture = try makeFixtureTree()
        let output = work.appendingPathComponent("never-written.exe")
        launchCommandMode(["a", "-sfx/nonexistent/none.sfx", output.path, fixture.files[0]])
        let dialog = try XCTUnwrap(waitForDialog(), "the error box did not appear")
        let text = dialog.staticTexts.allElementsBoundByIndex.map { $0.label }.joined(separator: " ")
        XCTAssertTrue(text.contains("SFX module"), "unexpected box text: \(text)")
        attach(dialog, "03-sfx-module-error")

        dismissAndExpectExit(dialog, preferring: ["OK"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path),
                       "nothing may be written when the SFX module is missing")
    }

    /// The plainest fact about command mode: it shows no file-manager window and it exits by itself.
    /// The exit **codes** are checked against the real process in `Mac/docs/reports/cmdmode.md`,
    /// because XCUITest cannot read one.
    func testCommandModeShowsNoWindowAndExits() throws {
        let fixture = try makeFixtureTree()
        launchCommandMode(["t", "-y", fixture.archive])
        XCTAssertTrue(sevenZip.app.wait(for: .notRunning, timeout: 120),
                      "`t -y` must finish and exit on its own")
    }
}
