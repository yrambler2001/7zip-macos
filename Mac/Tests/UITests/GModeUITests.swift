// GModeUITests.swift -- "7zG mode" through the real input path (Mac/docs/reports/gmode.md).
//
// Finder's 7-Zip menu, the Quick Actions and the Services reach the app as a `sevenzip://` URL that
// Launch Services delivers (`ExtensionHandoff`). Here the test runner sends the same URL the same
// way -- `NSWorkspace.open(_:withApplicationAt:)` aimed at this shard's bundle, no Automation
// involved -- which is what makes a **cold** launch testable at all: XCUIApplication.launch() would
// start the app without the URL.
//
// Windows behaviour being matched (03 §1.5, §2): the shell runs 7zG.exe, a process with no 7zFM
// window. Its dialog stands alone, centred on the work area; OK runs the operation, Cancel ends it,
// and either way the process exits. A running 7zFM is not touched.

import AppKit
import XCTest

final class GModeUITests: SevenZipUITestCase {

    override var screenshotPrefix: String { "gmode" }
    override class var reusesTheApp: Bool { false }

    /// The app as Launch Services started it. By bundle URL, not by bundle identifier: another copy
    /// with the same identifier (the installed /Applications/7-Zip.app) may be running too.
    private var target: XCUIApplication {
        TestShard.appURL.map { XCUIApplication(url: $0) }
            ?? XCUIApplication(bundleIdentifier: TestShard.appBundleIdentifier)
    }
    private var scratch = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("gmode-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        try "hello 7-zip\n".write(toFile: scratch + "/one.txt", atomically: true, encoding: .utf8)
        stopTarget()
        addTeardownBlock { [weak self] in
            self?.stopTarget()
            if let dir = self?.scratch { try? FileManager.default.removeItem(atPath: dir) }
        }
    }

    // MARK: - helpers

    private func stopTarget() {
        let app = target
        if app.state != .notRunning, app.state != .unknown {
            app.terminate()
            _ = app.wait(for: .notRunning, timeout: 15)
        }
    }

    /// `sevenzip:///run?argv=<base64url JSON>` -- CommandURL.url(argv:), spelled out because the
    /// UI-test bundle does not compile the app's sources.
    private func commandURL(_ argv: [String]) throws -> URL {
        let data = try JSONSerialization.data(withJSONObject: argv)
        let blob = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return try XCTUnwrap(URL(string: "sevenzip:///run?argv=" + blob))
    }

    /// Finder's "Add to archive..." for `one.txt` (03 §1.4 B5).
    private func addToArchiveURL() throws -> URL {
        try commandURL(["a", "-ad", "-saa", "-i!" + scratch + "/one.txt", "--", scratch + "/one"])
    }

    /// Delivers `url` as the Finder extension does: aimed at this shard's app, activating it only
    /// when it is not running yet (`ExtensionHandoff`). A cold delivery launches the app with the
    /// test environment and a throwaway settings domain.
    private func deliver(_ url: URL, cold: Bool) throws {
        let appURL = try XCTUnwrap(TestShard.appURL, "cannot find this shard's 7-Zip.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        configuration.activates = cold
        if cold {
            var env = TestShard.environment(for: sevenZip.owner)
            env["SEVENZIP_UITEST"] = "1"
            let seed = try SettingsSeedFile.make(name: "gmode-cold", values: SettingsSeed.clean.preferences ?? [:])
            addTeardownBlock { seed.remove() }
            env.merge(seed.launchEnvironment) { _, new in new }
            configuration.environment = env
        }
        var outcome: Error??
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            outcome = .some(error)
        }
        let deadline = Date().addingTimeInterval(30)
        while outcome == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let delivered = try XCTUnwrap(outcome, "Launch Services did not answer")
        XCTAssertNil(delivered, "Launch Services refused the URL")
    }

    /// File-manager windows: their title is the focused panel's path (CApp::RefreshTitle).
    private func managerWindows(_ app: XCUIApplication) -> XCUIElementQuery {
        app.windows.matching(NSPredicate(format: "title BEGINSWITH '/'"))
    }

    /// A dialog of `app` by title. The app's dialogs are AXDialog windows, so XCUI lists them under
    /// `dialogs`, not `windows`.
    private func window(_ app: XCUIApplication, titled title: String, timeout: TimeInterval = 30) -> XCUIElement? {
        SevenZipApp(app: app).waitForDialog(title: title, timeout: timeout)
    }

    /// Waits for the app to exit. That it exits at all also proves no file-manager window opened
    /// after the command: a command-only launch stays alive while one is open (`GMode.shouldQuit`).
    /// (Querying the windows while the process goes away fails the test with "not running".)
    private func waitForExitWithoutManagerWindow(_ app: XCUIApplication, timeout: TimeInterval = 30) -> Bool {
        app.wait(for: .notRunning, timeout: timeout)
    }

    private func attach(_ element: XCUIElement, _ name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = "\(screenshotPrefix)-\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// DS_CENTER with no owner: the dialog's frame is centred on the work area (7zG,
    /// wincompare-data/win/dlg-compress.txt). XCUI frames are top-left based.
    private func assertCentredOnWorkArea(_ frame: CGRect, file: StaticString = #filePath, line: UInt = #line) {
        guard let screen = NSScreen.screens.first, let main = NSScreen.main else { return }
        let visible = main.visibleFrame
        let top = screen.frame.maxY - visible.maxY
        XCTAssertEqual(frame.midX, visible.midX, accuracy: 2, "horizontal centre", file: file, line: line)
        XCTAssertEqual(frame.midY, top + visible.height / 2, accuracy: 2, "vertical centre", file: file, line: line)
    }

    // MARK: - cold: the app was not running

    /// Add to archive from Finder, then Cancel: the Compress dialog is the only window, no
    /// file-manager window ever appears, and the app quits -- 7zG.exe exiting with E_ABORT.
    func testColdAddToArchiveCancelQuitsWithoutAFileManagerWindow() throws {
        try deliver(addToArchiveURL(), cold: true)
        let app = target
        let dialog = try XCTUnwrap(window(app, titled: "Add to Archive"), "IDD_COMPRESS did not appear")
        XCTAssertEqual(managerWindows(app).count, 0, "a file-manager window opened with the dialog")
        XCTAssertEqual(app.windows.count, 0, "only the dialog may be on screen")
        XCTAssertEqual(app.dialogs.count, 1, "only the dialog may be on screen")
        assertCentredOnWorkArea(dialog.frame)
        attach(dialog, "02-cold-add-to-archive")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "Cancel"))
        XCTAssertTrue(waitForExitWithoutManagerWindow(app), "the app did not quit after Cancel")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch + "/one.7z"))
    }

    /// The same with OK: the archive is written, then the app quits; still no file-manager window.
    func testColdAddToArchiveOKCompressesAndQuits() throws {
        try deliver(addToArchiveURL(), cold: true)
        let app = target
        let dialog = try XCTUnwrap(window(app, titled: "Add to Archive"), "IDD_COMPRESS did not appear")
        XCTAssertEqual(managerWindows(app).count, 0)
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
        XCTAssertTrue(waitForExitWithoutManagerWindow(app, timeout: 60), "the app did not quit after the operation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch + "/one.7z"), "no archive was written")
    }

    /// An extension's error report: the box alone, OK, and the app is gone.
    func testColdErrorBoxQuitsAfterOK() throws {
        try deliver(try XCTUnwrap(URL(string: "sevenzip:///error?code=noitems")), cold: true)
        let app = target
        let box = try XCTUnwrap(window(app, titled: "7-Zip"), "no error box")
        XCTAssertEqual(managerWindows(app).count, 0)
        XCTAssertTrue(sevenZip.dismissDialog(box, button: "OK"))
        XCTAssertTrue(waitForExitWithoutManagerWindow(app), "the app did not quit after the error box")
    }

    /// "Open archive" is 7zFM.exe on Windows: exactly one file-manager window, and the app stays.
    func testColdOpenArchiveOpensExactlyOneWindow() throws {
        try deliver(try commandURL([TestPaths.fixture("test.7z")]), cold: true)
        let app = target
        let archiveWindow = app.windows.matching(NSPredicate(format: "title CONTAINS 'test.7z'")).firstMatch
        XCTAssertTrue(archiveWindow.waitForExistence(timeout: 30), "the archive's window did not open")
        Thread.sleep(forTimeInterval: 2)          // a stray default window would be up by now
        XCTAssertEqual(managerWindows(app).count, 1, "Open archive must give exactly one window")
        XCTAssertNotEqual(app.state, .notRunning)
    }

    // MARK: - warm: the file manager is open

    /// Two file-manager windows are open; Add to archive from Finder shows its dialog on its own (no
    /// sheet), the windows keep their number, frames and order, OK writes the archive, the panel
    /// showing that folder lists it, and the app keeps running.
    func testWarmCommandLeavesTheFileManagerWindowsAlone() throws {
        launch(seed: .values([SettingsDomain.Key.panelPath0: scratch]))
        XCTAssertTrue(sevenZip.panel(0).waitForRow(named: "one.txt"))
        XCTAssertTrue(sevenZip.selectMenuItem("File", "New Window"))
        XCTAssertTrue(waitFor("two file-manager windows") { managerWindows(app).count == 2 })
        let framesBefore = managerWindows(app).allElementsBoundByIndex.map(\.frame)

        try deliver(addToArchiveURL(), cold: false)
        let dialog = try XCTUnwrap(window(app, titled: "Add to Archive"), "IDD_COMPRESS did not appear")
        XCTAssertEqual(app.sheets.count, 0, "the dialog must not be a sheet of a file-manager window")
        XCTAssertEqual(managerWindows(app).count, 2)
        XCTAssertEqual(managerWindows(app).allElementsBoundByIndex.map(\.frame), framesBefore,
                       "the file-manager windows moved or changed order")
        assertCentredOnWorkArea(dialog.frame)
        attach(dialog, "03-warm-add-to-archive")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))

        XCTAssertTrue(waitFor("the archive", timeout: 60) { FileManager.default.fileExists(atPath: scratch + "/one.7z") })
        XCTAssertTrue(sevenZip.panel(0).waitForRow(named: "one.7z"), "the panel was not refreshed")
        Thread.sleep(forTimeInterval: 1)
        XCTAssertNotEqual(app.state, .notRunning, "the file manager quit after a shell command")
        XCTAssertEqual(managerWindows(app).count, 2)
        XCTAssertEqual(managerWindows(app).allElementsBoundByIndex.map(\.frame), framesBefore)
    }
}
