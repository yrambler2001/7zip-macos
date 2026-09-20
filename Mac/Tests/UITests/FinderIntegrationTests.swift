// FinderIntegrationTests.swift -- what the app does when it is handed a Finder command.
//
// The Finder Sync extension and the Quick Actions cannot be driven from a test (Finder itself would
// have to be scripted, and this machine grants no Automation permission -- Mac/docs/reports/vmcheck.md
// section 5), but the **hand-off** can: the extension's only action is
// `NSWorkspace.open(sevenzip:///run?argv=...)`, so these tests send exactly the URLs the menu items
// build and assert on the dialogs the app then shows.
//
// The argument grammar itself, the menu tree and the naming rules are covered by
// `SevenZipKitTests/FinderCommandTests` (63 cases); this file covers the app's reaction.
//
// Parity references: 03-shell-integration-inventory.md sections 1.4, 2.4, 6.4; Mac/docs/api/finder.md.

import AppKit
import XCTest

final class FinderIntegrationTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "finder" }

    // MARK: - Helpers

    /// The URL a Finder Sync menu item sends: `sevenzip:///run?argv=<base64url JSON array>`.
    /// Built here by hand so the UI-test target needs no product sources.
    private func commandURL(_ argv: [String]) -> URL {
        let data = try! JSONSerialization.data(withJSONObject: argv)
        let blob = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "sevenzip:///run?argv=" + blob)!
    }

    @discardableResult
    private func send(_ argv: [String]) -> Bool {
        NSWorkspace.shared.open(commandURL(argv))
    }

    private func makeOutputDirectory(_ name: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("finder-ui-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    // MARK: - The three dialogs a command can open (03 section 2.4)

    /// B1 "Extract files..." -> `x -o"<dir><spec>/" -ad -an -ai…` -> the Extract dialog.
    func testExtractFilesCommandOpensTheExtractDialog() throws {
        launch()
        let out = try makeOutputDirectory("extract")
        XCTAssertTrue(send(["x", "-o" + out + "/", "-ad", "-an",
                            "-aiw-!" + TestPaths.fixture("test.7z")]))

        guard let dialog = sevenZip.waitForDialog(title: "Extract", timeout: 25) else {
            return XCTFail("the Extract dialog did not appear")
        }
        screenshot("01-extract-dialog-from-finder-command")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "Cancel"))
        // Cancel is E_ABORT: nothing is extracted and the app stays alive.
        XCTAssertTrue(sevenZip.isRunning)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out), [])
    }

    /// B5 "Add to archive..." -> `a -i… -ad -saa -- "<dir><name>"` -> the Compress dialog.
    func testAddToArchiveCommandOpensTheCompressDialog() throws {
        launch()
        let out = try makeOutputDirectory("compress")
        XCTAssertTrue(send(["a", "-iw-!" + TestPaths.fixture("test.zip"),
                            "-iw-!" + TestPaths.fixture("test.7z"),
                            "-ad", "-saa", "--", out + "/Archive"]))

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

    /// C6 "SHA-256" -> `h -scrcSHA256 -i…` -> the checksum results list.
    func testChecksumCommandShowsTheHashResults() throws {
        launch()
        XCTAssertTrue(send(["h", "-scrcSHA256", "-iw-!" + TestPaths.fixture("test.7z")]))

        guard let dialog = sevenZip.waitForDialog(title: "Checksum information", timeout: 30) else {
            return XCTFail("the checksum results dialog did not appear")
        }
        // The rows live in the list view (CListViewDialog). `HashListDialogView` does not expose
        // its rows to accessibility -- neither `cells` nor `staticText` descendants resolve -- so
        // the assertion stops at the list itself and the screenshot carries the rows. Recorded in
        // Mac/docs/requests.md for the scope that owns the list dialog.
        let table = dialog.tables.firstMatch
        XCTAssertTrue(table.waitForExistence(timeout: 10), "the results list is missing")
        screenshot("03-checksum-results-from-finder-command")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "Close")
                      || sevenZip.dismissDialog(dialog, button: "OK"))
    }

    // MARK: - The refusals (03 section 1.4 "Invoke-side error handling")

    /// A folder in an extract selection is IDS_SELECT_FILES 3015, not an extraction.
    func testExtractCommandRefusesADirectory() throws {
        launch()
        let out = try makeOutputDirectory("refuse")
        XCTAssertTrue(send(["x", "-o" + out + "/", "-an", "-aiw-!" + TestPaths.fixtures]))

        guard let dialog = sevenZip.waitForDialog(title: "You must select one or more files",
                                                 timeout: 25) else {
            return XCTFail("IDS_SELECT_FILES 3015 was not shown")
        }
        screenshot("04-select-files-refusal")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out), [])
    }

    /// `l` and `i` are the two commands 7zG refuses (GUI.cpp:396-399).
    func testUnsupportedCommandIsReported() {
        launch()
        XCTAssertTrue(send(["l", TestPaths.fixture("test.7z")]))

        guard let dialog = sevenZip.waitForDialog(title: "Unsupported command", timeout: 25) else {
            return XCTFail("the Unsupported command box did not appear")
        }
        screenshot("05-unsupported-command")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
    }

    /// A switch-syntax error is a user error with the upstream message (CParser::ParseString).
    func testUnknownSwitchIsReported() {
        launch()
        XCTAssertTrue(send(["x", "-zzz", "-an", "-aiw-!" + TestPaths.fixture("test.7z")]))

        guard let dialog = sevenZip.waitForDialog(title: "Unknown switch:", timeout: 25) else {
            return XCTFail("the Unknown switch box did not appear")
        }
        screenshot("06-unknown-switch")
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "OK"))
    }

    // MARK: - Silent commands (no `-ad`)

    /// B2 "Extract Here" runs without a dialog and the files simply appear.
    func testExtractHereCommandRunsSilently() throws {
        launch()
        let out = try makeOutputDirectory("here")
        XCTAssertTrue(send(["x", "-o" + out + "/", "-y", "-an",
                            "-aiw-!" + TestPaths.fixture("test.7z")]))

        let deadline = Date().addingTimeInterval(40)
        var names: [String] = []
        repeat {
            names = (try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []
            if names.contains("readme.txt") { break }
            usleep(300_000)
        } while Date() < deadline
        XCTAssertTrue(names.contains("readme.txt"), "extracted: \(names)")
        XCTAssertTrue(names.contains("notes.md"))
        XCTAssertTrue(names.contains("sub"))
        screenshot("07-after-silent-extract-here")
    }

    // MARK: - A1 "Open archive" (the 7zFM argv, 03 section 1.4)

    /// The open form carries a path instead of a command word and lands in the file manager.
    func testOpenArchiveCommandListsTheArchiveInThePanel() {
        launch()
        XCTAssertTrue(send([TestPaths.fixture("test.7z")]))

        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "readme.txt", timeout: 30),
                      "the archive was not opened in panel 0")
        XCTAssertTrue(panel.hasRow(named: "notes.md"))
        screenshot("08-open-archive-from-finder-command")
    }

    /// `-t<type>` forces the handler, like `Open archive > 7z`.
    func testOpenArchiveWithForcedTypeListsTheArchive() {
        launch()
        XCTAssertTrue(send([TestPaths.fixture("test.7z"), "-t7z"]))
        XCTAssertTrue(sevenZip.panel(0).waitForRow(named: "readme.txt", timeout: 30))
        screenshot("09-open-archive-as-7z")
    }

    // MARK: - 7zG mode from a real argv (03 section 6.4)

    /// `argv[1]` is a command word: the file manager is ordered out and only the command's own
    /// dialog is shown. `-ad` keeps the process alive long enough to assert that.
    func testCommandModeArgvShowsOnlyTheCommandDialog() throws {
        let out = try makeOutputDirectory("argv")
        let app = XCUIApplication()
        app.launchArguments = ["x", "-o" + out + "/", "-ad", "-an",
                               "-aiw-!" + TestPaths.fixture("test.7z")]
        app.launchEnvironment = ["SEVENZIP_UITEST": "1"]
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
