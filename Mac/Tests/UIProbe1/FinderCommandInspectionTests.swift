// FinderCommandInspectionTests.swift -- the half of `FinderIntegrationTests` that never synthesizes
// a keyboard or mouse event, so it can run **at the same time** as the other shards.
//
// Why the split. macOS delivers a synthesized click to whatever window is frontmost under the
// cursor, so two XCUITest processes that click cannot run at once -- one steals the other's events.
// A test that only sends a `sevenzip://` URL and then *reads* the accessibility tree has no such
// constraint: `NSWorkspace.open(urls:withApplicationAt:)` is an Apple event, not an input event.
// This shard drives an app target of its own (`7-Zip-Probe1`, bundle id `com.yrambler2001.7zip-p1`)
// so its instance cannot be confused with, or terminated by, the input shard's.
//
// What changed against the XCUITest original, and it is the one thing worth flagging: the three
// refusal boxes used to be closed by clicking OK. The click was **dismissal, not assertion** -- the
// assertion is that the box appeared with the right message -- so it is replaced by asserting that
// the box's OK button is there and enabled, and the instance is thrown away in `tearDown`. The
// click-is-the-specification cases (Cancel means `E_ABORT`, so nothing is extracted and the process
// ends) stay in the input shard, in `FinderIntegrationTests`.
//
// Parity references: 03-shell-integration-inventory.md sections 1.4, 2.4, 6.4; ai/api/finder.md.

import AppKit
import XCTest

final class FinderCommandInspectionTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "finder" }

    // MARK: - Helpers

    /// The URL a Finder Sync menu item sends: `sevenzip:///run?argv=<base64url JSON array>` with
    /// the app's secret (sec113, `TestShard.commandURL`).
    private func commandURL(_ argv: [String]) -> URL {
        TestShard.commandURL(argv)
    }

    /// The first words of the one box a refused command URL shows (`URLCommandPolicy`).
    private let refusalTitle = "7-Zip did not run a command that another application sent"

    /// Send the command to **this shard's** instance, and to nothing else: `SevenZipApp.open` has
    /// no unaimed `NSWorkspace.open` fallback (testreg), which matters here because the app copy
    /// this shard drives deliberately claims no URL scheme (see the class comment). It is delivered through
    /// `<SZ_STATE_DIR>/reset-request`, which `TestResetWatcher` (merged into `macos`) reads and which
    /// is aimed by construction; false here means that watcher did not take the request, and the
    /// test fails on the spot rather than asserting against somebody else's instance.
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

    /// A modal box has to go before the next test runs, and this shard may not click it away: throw
    /// the instance out instead. Cheap, because the next test of the class launches once.
    private func discardInstanceAfterThisTest() {
        addTeardownBlock { [weak sevenZip] in sevenZip?.terminate() }
    }

    // MARK: - Commands that open no dialog at all (03 section 2.4)

    /// B2 "Extract Here" runs without a dialog and the files simply appear.
    func testExtractHereCommandRunsSilently() throws {
        launch()
        // sec113: the menu's own shape, `x -o"<archive's folder>/" -an -ai…`, on a copy.
        let out = try makeOutputDirectory("here")
        try FileManager.default.copyItem(atPath: TestPaths.fixture("test.7z"), toPath: out + "/test.7z")
        XCTAssertTrue(send(["x", "-o" + out + "/", "-an", "-aiw-!" + out + "/test.7z"]))

        var names: [String] = []
        XCTAssertTrue(waitFor("readme.txt extracted", timeout: 40) {
            names = (try? FileManager.default.contentsOfDirectory(atPath: out)) ?? []
            return names.contains("readme.txt")
        }, "extracted: \(names)")
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

    // MARK: - The refusals (03 section 1.4 "Invoke-side error handling"; sec113)

    /// A folder in an extract selection is never a command the menu builds (IDS_SELECT_FILES 3015
    /// on Windows): over the URL route it is refused before anything runs.
    func testExtractCommandRefusesADirectory() throws {
        discardInstanceAfterThisTest()
        launch()
        let out = try makeOutputDirectory("refuse")
        XCTAssertTrue(send(["x", "-o" + out + "/", "-an", "-aiw-!" + TestPaths.fixtures]))

        guard let dialog = sevenZip.waitForDialog(title: refusalTitle, timeout: 25) else {
            return XCTFail("the refusal box was not shown")
        }
        screenshot("04-select-files-refusal")
        assertHasEnabledButton(dialog, "OK")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out), [])
    }

    /// `l` (which 7zG refuses itself, GUI.cpp:396-399) and a switch-syntax error are not shapes the
    /// menu builds either: the URL route refuses them with the one box. The command line still
    /// reports them as 7zG does (`CommandModeUITests`).
    func testUnsupportedCommandIsReported() {
        discardInstanceAfterThisTest()
        launch()
        XCTAssertTrue(send(["l", TestPaths.fixture("test.7z")]))

        guard let dialog = sevenZip.waitForDialog(title: refusalTitle, timeout: 25) else {
            return XCTFail("the refusal box did not appear")
        }
        screenshot("05-unsupported-command")
        assertHasEnabledButton(dialog, "OK")
    }

    func testUnknownSwitchIsReported() {
        discardInstanceAfterThisTest()
        launch()
        XCTAssertTrue(send(["x", "-zzz", "-an", "-aiw-!" + TestPaths.fixture("test.7z")]))

        guard let dialog = sevenZip.waitForDialog(title: refusalTitle, timeout: 25) else {
            return XCTFail("the refusal box did not appear")
        }
        screenshot("06-unknown-switch")
        assertHasEnabledButton(dialog, "OK")
    }

    /// sec113: a forged URL -- the extract a web page would send, `-y` included, without the
    /// secret -- extracts nothing and shows the refusal box.
    func testRunURLWithoutTheSecretIsRefused() throws {
        discardInstanceAfterThisTest()
        launch()
        let out = try makeOutputDirectory("forged")
        try FileManager.default.copyItem(atPath: TestPaths.fixture("test.7z"), toPath: out + "/test.7z")
        XCTAssertTrue(sevenZip.open(TestShard.commandURL(["x", "-o" + out + "/", "-y", "-an",
                                                         "-aiw-!" + out + "/test.7z"], token: nil)))
        guard let dialog = sevenZip.waitForDialog(title: refusalTitle, timeout: 25) else {
            return XCTFail("the refusal box did not appear")
        }
        screenshot("21-forged-url-refused")
        assertHasEnabledButton(dialog, "OK")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out), ["test.7z"])
    }

    // MARK: - helpers

    /// The box can be dismissed: its button is there, hittable and enabled. Asserted instead of
    /// clicked, because this shard synthesizes no input.
    private func assertHasEnabledButton(_ dialog: XCUIElement, _ title: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let button = dialog.buttons
            .matching(NSPredicate(format: "title == %@ OR label == %@", title, title)).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no '\(title)' button", file: file, line: line)
        XCTAssertTrue(button.isEnabled, "'\(title)' is disabled", file: file, line: line)
    }
}
