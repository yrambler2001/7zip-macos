// FinderIntegrationTests.swift -- what the app does when it is handed a Finder command, for the
// cases where **the click is the specification**: Cancel is `E_ABORT`, so nothing is extracted, and
// in command mode the process ends with it.
//
// The Finder Sync extension and the Quick Actions cannot be driven from a test (Finder itself would
// have to be scripted, and this machine grants no Automation permission -- ai/reports/vmcheck.md
// section 5), but the **hand-off** can: the extension's only action is
// `NSWorkspace.open(sevenzip:///run?argv=...)`, so these tests send exactly the URLs the menu items
// build and assert on the dialogs the app then shows.
//
// The six cases that only send a URL and read the tree moved to
// `Mac/Tests/UIProbe1/FinderCommandInspectionTests.swift`, which runs concurrently with the other
// read-only shards. What is left here needs to click, so it runs alone.
//
// The argument grammar itself, the menu tree and the naming rules are covered by
// `SevenZipKitTests/FinderCommandTests` (63 cases); this file covers the app's reaction.
//
// Parity references: 03-shell-integration-inventory.md sections 1.4, 2.4, 6.4; ai/api/finder.md.

import AppKit
import XCTest

final class FinderIntegrationTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "finder" }

    // MARK: - Helpers

    /// The URL a Finder Sync menu item sends: `sevenzip:///run?argv=<base64url JSON array>` with
    /// the app's secret (sec113, `TestShard.commandURL`).
    private func commandURL(_ argv: [String]) -> URL {
        TestShard.commandURL(argv)
    }

    /// Send the command to **this shard's** instance rather than to whichever registered copy
    /// LaunchServices picks for the scheme (`SevenZipApp.open`).
    @discardableResult
    private func send(_ argv: [String]) -> Bool {
        sevenZip.open(commandURL(argv))
    }

    private func makeOutputDirectory(_ name: String) throws -> String {
        let path = (TestPaths.artifacts as NSString)
            .appendingPathComponent("finder-ui-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    // MARK: - The dialogs a command opens, and what Cancel does (03 section 2.4)

    /// B1 "Extract files..." -> `x -o"<dir><spec>/" -ad -an -ai…` -> the Extract dialog, and Cancel
    /// is E_ABORT: nothing is extracted and the app stays alive.
    func testExtractFilesCommandOpensTheExtractDialog() throws {
        launch()
        // sec113: the menu's own shape on a copy, `-o` = "<archive's folder>/test/".
        let out = try makeOutputDirectory("extract")
        try FileManager.default.copyItem(atPath: TestPaths.fixture("test.7z"), toPath: out + "/test.7z")
        XCTAssertTrue(send(["x", "-o" + out + "/test/", "-ad", "-an", "-aiw-!" + out + "/test.7z"]))

        guard let dialog = sevenZip.waitForDialog(title: "Extract", timeout: 25) else {
            return XCTFail("the Extract dialog did not appear")
        }
        screenshot("01-extract-dialog-from-finder-command")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "Cancel"))
        XCTAssertTrue(sevenZip.isRunning)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out), ["test.7z"])
    }

    /// B5 "Add to archive..." -> `a -i… -ad -saa -- "<dir><name>"` -> the Compress dialog.
    func testAddToArchiveCommandOpensTheCompressDialog() throws {
        launch()
        // sec113: the menu's own shape -- several items are named after their folder, next to them.
        // Cancelled below, so nothing is written there.
        let folderName = (TestPaths.fixtures as NSString).lastPathComponent
        XCTAssertTrue(send(["a", "-iw-!" + TestPaths.fixture("test.zip"),
                            "-iw-!" + TestPaths.fixture("test.7z"),
                            "-ad", "-saa", "--", TestPaths.fixtures + "/" + folderName]))

        // The Compress window draws no visible title bar, so it is matched by one of its own
        // labels rather than by the window title (IDD_COMPRESS 4000 "Add to Archive").
        guard let dialog = sevenZip.waitForDialog(title: "Archive format:", timeout: 25) else {
            return XCTFail("the Add to Archive dialog did not appear")
        }
        XCTAssertTrue(sevenZip.texts(of: dialog).contains { $0.hasPrefix("Compression level:") })
        screenshot("02-add-to-archive-dialog-from-finder-command")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "Cancel"))
        XCTAssertTrue(sevenZip.isRunning)
    }

    /// C6 "SHA-256" -> `h -scrcSHA256 -i…` -> the checksum results list, closed with Close (lang 408).
    func testChecksumCommandShowsTheHashResults() {
        launch()
        XCTAssertTrue(send(["h", "-scrcSHA256", "-iw-!" + TestPaths.fixture("test.7z")]))

        guard let dialog = sevenZip.waitForDialog(title: "Checksum information", timeout: 30) else {
            return XCTFail("the checksum results dialog did not appear")
        }
        // The rows live in the list view (CListViewDialog). `HashListDialogView` does not expose
        // its rows to accessibility -- neither `cells` nor `staticText` descendants resolve -- so
        // the assertion stops at the list itself and the screenshot carries the rows. Recorded in
        // ai/requests.md for the scope that owns the list dialog.
        let table = dialog.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10), "the results list is missing")
        screenshot("03-checksum-results-from-finder-command")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "Close")
                      || sevenZip.dismissDialog(dialog, button: "OK"))
    }

    // MARK: - An extension that fails says so (finderfix)

    /// `sevenzip:///error?code=noitems` is what the Finder Sync extension or a Quick Action sends
    /// when it could not build a command: the app must put up an error box, never do nothing.
    func testExtensionFailureURLShowsAnErrorBox() {
        launch()
        XCTAssertTrue(sevenZip.open(URL(string: "sevenzip:///error?code=noitems")!))
        guard let box = sevenZip.waitForDialog(title: "7-Zip did not receive", timeout: 25) else {
            return XCTFail("no error box for an extension failure")
        }
        screenshot("20-extension-failure-error-box")
        XCTAssertTrue(sevenZip.dismissDialog(box, button: "OK"))
        XCTAssertTrue(sevenZip.isRunning)
    }

    // MARK: - 7zG mode from a real argv (03 section 6.4)

    /// `argv[1]` is a command word: the file manager is ordered out and only the command's own
    /// dialog is shown. `-ad` keeps the process alive long enough to assert that, and Cancel
    /// (E_ABORT) ends it -- so this one needs a process of its own, not a reset.
    func testCommandModeArgvShowsOnlyTheCommandDialog() throws {
        let out = try makeOutputDirectory("argv")
        // Launched by hand, not through `SevenZipApp.launch`: command mode orders every window out
        // (03 section 6.4), so the driver's wait for a main window and a panel list would burn two
        // 60 s timeouts before the Extract dialog is even looked for.
        let app = XCUIApplication()
        app.launchArguments = ["x", "-o" + out + "/", "-ad", "-an",
                              "-aiw-!" + TestPaths.fixture("test.7z")]
        app.launchEnvironment = ["SEVENZIP_UITEST": "1"]
            .merging(TestShard.environment(for: "FinderIntegrationTests")) { mine, _ in mine }
        if app.state != .notRunning && app.state != .unknown { app.terminate() }
        app.launch()

        guard let dialog = sevenZip.waitForDialog(title: "Extract", timeout: 30) else {
            return XCTFail("the Extract dialog did not appear in command mode")
        }
        // "no document windows" (03 section 6.4): the file manager, whose title is the panel's
        // path, is never on screen.
        XCTAssertEqual(app.windows.matching(NSPredicate(format: "title BEGINSWITH '/'")).count, 0)
        screenshot("10-command-mode-argv")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "Cancel"))
        // Cancel is E_ABORT, which ends the command-mode process.
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out), [])
    }
}
