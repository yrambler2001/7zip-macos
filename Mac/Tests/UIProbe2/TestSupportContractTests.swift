// TestSupportContractTests.swift -- asserts `ai/test-support-contract.md` itself, which is
// what makes the rest of the suite fast.
//
// The app side is `mac/resetcmd`'s (`Mac/App/Integration/TestReset.swift`), merged into `macos`, so
// these are ordinary passing tests. They were wrapped in a non-strict `XCTExpectFailure` while that
// branch was in flight; the wrappers are gone and the assertions are now the real thing -- if the
// affordances regress, this file is what says so. `SevenZipApp.prepare` still falls back to a
// relaunch when `testSupportIsImplemented` is false and records which happened in
// `lastPreparation`, so an app built without `SZ_TEST_SUPPORT` does not fail the rest of the suite.
//
// Everything asserted here is read-only, so it belongs in an inspection shard.

import XCTest

final class TestSupportContractTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "fastui" }

    /// Contract, "How a test knows the reset finished" point 2: the main window's accessibility
    /// value is the reset generation as a string, `0` before the first reset.
    func testMainWindowCarriesTheResetGeneration() {
        launch()
        XCTAssertTrue(sevenZip.testSupportIsImplemented,
                      "the main window's accessibility value is "
                      + "\(String(describing: sevenZip.window.value)), not a generation number")
        XCTAssertEqual(sevenZip.resetGeneration, 0, "the generation starts at 0")
    }

    /// Contract, "The reset command": the running instance goes back to a known state, writes the
    /// ack file last, and bumps the generation -- without quitting.
    func testResetReturnsTheAppToAKnownStateWithoutRelaunching() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "test.7z"))
        guard let processBefore = sevenZip.resetGeneration else {
            return XCTFail("the app does not implement the contract yet")
        }

        var options = SevenZipApp.ResetOptions()
        options.panels = 1
        options.path0 = TestPaths.realHome
        let outcome = sevenZip.reset(options)
        XCTAssertEqual(outcome, .reset(generation: processBefore + 1),
                       "reset outcome: \(outcome)")
        XCTAssertTrue(panel.waitForPath(TestPaths.realHome), "panel 0 shows \(panel.path)")
        XCTAssertTrue(sevenZip.isRunning, "the app must not have quit")
    }

    /// Contract, "Reset must ... close every sheet, dialog, alert and secondary window": the state
    /// a failing test leaves behind is exactly what the next test must not inherit.
    func testResetClosesAnOpenDialog() {
        launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]))
        guard sevenZip.testSupportIsImplemented else {
            return XCTFail("the app does not implement the contract yet")
        }
        // A dialog opened without synthesized input: the URL command form of "Add to archive".
        // The menu's own shape, with the secret (sec113); the dialog is closed by the reset, so
        // nothing is written next to the fixture.
        let argv = ["a", "-iw-!" + TestPaths.fixture("test.7z"), "-ad", "-saa",
                    "--", TestPaths.fixture("test")]
        XCTAssertTrue(sevenZip.open(TestShard.commandURL(argv)))
        XCTAssertNotNil(sevenZip.waitForDialog(title: "Archive format:", timeout: 30),
                        "the Compress dialog did not open")

        var options = SevenZipApp.ResetOptions()
        options.path0 = TestPaths.fixtures
        let outcome = sevenZip.reset(options)
        if case .failed(let why) = outcome { return XCTFail("reset failed: \(why)") }
        XCTAssertTrue(sevenZip.waitForNoDialog(timeout: 10), "the reset left a dialog on screen")
        XCTAssertEqual(app.windows.count, 1, "the reset left a secondary window open")
    }

    /// Contract, "Running several instances at once": this shard drives an app whose bundle
    /// identifier is its own, which is what lets the read-only shards run at the same time. Not
    /// expected to fail -- it is about the build, which this scope owns.
    func testThisShardDrivesItsOwnBundleIdentifier() {
        XCTAssertNotEqual(TestShard.appBundleIdentifier, "com.yrambler2001.7zip",
                          "an inspection shard must not share the shipping bundle id with the input shard")
        XCTAssertEqual(SevenZipApp.bundleIdentifier, TestShard.appBundleIdentifier)
        XCTAssertNotNil(TestShard.appURL, "the shard could not locate \(TestShard.appName).app")
        launch()
        XCTAssertTrue(sevenZip.isRunning)
        // SZ_STATE_DIR is per class, so two shards never write the same file.
        let state = TestShard.stateDirectory(for: "TestSupportContractTests")
        XCTAssertTrue(state.contains(TestShard.name), "the state directory is not shard specific: \(state)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: state))
    }
}
