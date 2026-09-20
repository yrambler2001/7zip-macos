// TestSupportContractTests.swift -- asserts `Mac/docs/test-support-contract.md` itself, which is
// what makes the rest of the suite fast.
//
// **These are the tests that need the app side, and it is not on this branch.** `mac/resetcmd`
// implements the contract in `Mac/App/*`, which this scope does not own. So each case is wrapped in
// a *non-strict* `XCTExpectFailure`: it goes green whether the affordance is there or not, and the
// moment `mac/resetcmd` merges the run starts reporting them as passing. Nothing else in the suite
// depends on the contract being implemented -- `SevenZipApp.prepare` falls back to a relaunch and
// says so in `lastPreparation` -- so this file is the whole of the "expected to fail until the
// merge" list, and `Mac/docs/reports/fastui.md` names it as such.
//
// Everything asserted here is read-only, so it belongs in an inspection shard.

import XCTest

final class TestSupportContractTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "fastui" }

    /// Non-strict: a pass is fine too, which is what happens once the app side lands.
    private func expectingTheAppSide(_ what: String, _ body: () -> Void) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("the app side of the test-support contract (\(what)) lands with mac/resetcmd",
                        options: options, failingBlock: body)
    }

    /// Contract, "How a test knows the reset finished" point 2: the main window's accessibility
    /// value is the reset generation as a string, `0` before the first reset.
    func testMainWindowCarriesTheResetGeneration() {
        expectingTheAppSide("the reset generation on the main window") {
            launch()
            XCTAssertTrue(sevenZip.testSupportIsImplemented,
                          "the main window's accessibility value is "
                          + "\(String(describing: sevenZip.window.value)), not a generation number")
            XCTAssertEqual(sevenZip.resetGeneration, 0, "the generation starts at 0")
        }
    }

    /// Contract, "The reset command": the running instance goes back to a known state, writes the
    /// ack file last, and bumps the generation -- without quitting.
    func testResetReturnsTheAppToAKnownStateWithoutRelaunching() {
        expectingTheAppSide("sevenzip://test/reset") {
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
    }

    /// Contract, "Reset must ... close every sheet, dialog, alert and secondary window": the state
    /// a failing test leaves behind is exactly what the next test must not inherit.
    func testResetClosesAnOpenDialog() {
        expectingTheAppSide("reset closing an open dialog") {
            launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]))
            guard sevenZip.testSupportIsImplemented else {
                return XCTFail("the app does not implement the contract yet")
            }
            // A dialog opened without synthesized input: the URL command form of "Add to archive".
            let argv = ["a", "-ad", "-saa", "-iw-!" + TestPaths.fixture("test.7z"),
                        "--", TestPaths.artifacts + "/contract-archive"]
            let data = try! JSONSerialization.data(withJSONObject: argv)
            let blob = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            XCTAssertTrue(sevenZip.open(URL(string: "sevenzip:///run?argv=" + blob)!))
            XCTAssertNotNil(sevenZip.waitForDialog(title: "Archive format:", timeout: 30),
                            "the Compress dialog did not open")

            var options = SevenZipApp.ResetOptions()
            options.path0 = TestPaths.fixtures
            let outcome = sevenZip.reset(options)
            if case .failed(let why) = outcome { return XCTFail("reset failed: \(why)") }
            XCTAssertTrue(sevenZip.waitForNoDialog(timeout: 10), "the reset left a dialog on screen")
            XCTAssertEqual(app.windows.count, 1, "the reset left a secondary window open")
        }
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
