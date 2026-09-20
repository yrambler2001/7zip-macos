// ResetCommandTests.swift -- `sevenzip://test/reset` driven through the real app: both completion
// signals, what a reset actually resets, and the measurement that justifies the whole exercise.
//
// Owned by `mac/resetcmd` (the app side of `Mac/docs/test-support-contract.md`); the suite proper
// belongs to `mac/fastui`. It is therefore deliberately **self-contained**: a bare `XCTestCase` with
// its own `XCUIApplication`, no `SevenZipUITestCase`, no `SevenZipApp`, no `TestPaths`, so a rewrite
// of the harness cannot break it and this file cannot get in the harness's way.
//
// What is asserted:
//   * the main window's accessibility value is "0" before the first reset and counts up after each;
//   * the acknowledgement file is written last and holds the same generation;
//   * `defaults`, `lang`, `panels`, `path0`, `path1` and `view` all take effect;
//   * selection and view mode really do go back to their defaults;
//   * the reset is refused when `SZ_TEST_SUPPORT` is not set.
//
// The measurement (`testMeasureResetAgainstRelaunch`) prints both numbers; `Mac/docs/api/resetcmd.md`
// records them.

import XCTest

final class ResetCommandTests: XCTestCase {

    private var app: XCUIApplication!
    private var scratch: URL!
    private var stateDirectory: URL!
    private var ackCounter = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resetcmd-ui-\(UUID().uuidString)")
        stateDirectory = scratch.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let app {
            app.terminate()
            // Wait for it, so the next test does not attach to this one's instance.
            _ = waitFor(timeout: 15) { app.state == .notRunning }
        }
        app = nil
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }

    // MARK: - launching

    /// `launchEnvironment` is the only way an XCUITest can hand the app an environment, and it is
    /// exactly what the contract asks the app to honour.
    private func launchApp(testSupport: Bool = true, seed: [String: Any]? = nil) -> XCUIApplication {
        let application = XCUIApplication()
        var environment = ["SZ_DISABLE_ANIMATIONS": "1", "SZ_STATE_DIR": stateDirectory.path]
        if testSupport { environment["SZ_TEST_SUPPORT"] = "1" }
        if let seed {
            let path = scratch.appendingPathComponent("seed-launch.plist")
            try? (seed as NSDictionary).write(to: path)
            environment["SEVENZIP_DEFAULTS_SUITE"] = path.path
        }
        application.launchEnvironment = environment
        // `XCUIApplication.launch()` *attaches* to an instance that is already running instead of
        // replacing it, so a leftover from an earlier test would be used with the earlier test's
        // environment (measured: "Running Background" activation failures and a generation of "1"
        // where "0" was expected). The harness's own `launch()` does the same thing for the same
        // reason -- see `Mac/docs/api/harness.md` section 1a.
        if application.state != .notRunning {
            application.terminate()
            _ = waitFor(timeout: 15) { application.state == .notRunning }
        }
        application.launch()
        app = application
        XCTAssertTrue(application.windows.firstMatch.waitForExistence(timeout: 30), "no window")
        if testSupport {
            // The generation is published only under SZ_TEST_SUPPORT, so this is the cheap proof
            // that the environment reached the app -- rather than ten reset timeouts in a row.
            XCTAssertEqual(application.windows.firstMatch.value as? String, "0",
                           "the app under test did not start with SZ_TEST_SUPPORT=1")
        }
        return application
    }

    private var window: XCUIElement { app.windows.firstMatch }

    /// The reset generation the app publishes, or nil when the window has no value.
    private var publishedGeneration: Int? {
        (window.value as? String).flatMap(Int.init)
    }

    // MARK: - sending the reset

    /// Delivers one `sevenzip://test/reset` to **this** app instance.
    ///
    /// Not `NSWorkspace.open(URL)`: Launch Services routes a `sevenzip://` URL to whichever bundle
    /// it considers the scheme's handler, and the moment a second copy of the app exists that is a
    /// different bundle than the one this test launched. Measured on this machine, with two probe
    /// bundles registered: every reset went to a probe and none of them was ever acknowledged.
    /// `open(_:withApplicationAt:)` can aim, but a sandboxed runner cannot reliably resolve a bundle
    /// URL outside its container.
    ///
    /// So the URL is written into `<SZ_STATE_DIR>/reset-request`, which belongs to exactly this
    /// instance and which this process owns (`SZ_STATE_DIR` is inside the runner's own temp
    /// directory). Same URL, same parser, delivery that cannot go to the wrong app -- and it gets
    /// through while the app is inside a modal session. See `Mac/docs/api/resetcmd.md` section 5.
    @discardableResult
    private func sendReset(_ parameters: [String: String], timeout: TimeInterval = 45)
        -> (generation: Int, seconds: TimeInterval)? {
        ackCounter += 1
        let ack = scratch.appendingPathComponent("ack-\(ackCounter).txt")
        try? FileManager.default.removeItem(at: ack)

        var components = URLComponents()
        components.scheme = "sevenzip"
        components.host = "test"
        components.path = "/reset"
        components.queryItems = parameters.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "ack", value: ack.path)]
        guard let url = components.url else { XCTFail("bad reset URL"); return nil }

        let started = Date()
        let request = stateDirectory.appendingPathComponent("reset-request")
        do {
            try Data(url.absoluteString.utf8).write(to: request, options: .atomic)
        } catch {
            XCTFail("cannot write the reset request: \(error)")
            return nil
        }

        while Date().timeIntervalSince(started) < timeout {
            if let text = try? String(contentsOf: ack, encoding: .utf8), let generation = Int(text) {
                return (generation, Date().timeIntervalSince(started))
            }
            usleep(3000)
        }
        return nil
    }

    /// Writes any `sevenzip://` URL into this instance's request file (see `sendReset`).
    private func send(url: URL) {
        let request = stateDirectory.appendingPathComponent("reset-request")
        XCTAssertNoThrow(try Data(url.absoluteString.utf8).write(to: request, options: .atomic))
    }

    /// `sevenzip:///run?argv=<base64url JSON array>` -- the ordinary command route
    /// (`Mac/docs/api/finder.md` section 5), used here to start a long real operation.
    private func runURL(argv: [String]) -> URL {
        let json = try! JSONSerialization.data(withJSONObject: argv)
        let blob = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var components = URLComponents()
        components.scheme = "sevenzip"
        components.host = ""
        components.path = "/run"
        components.queryItems = [URLQueryItem(name: "argv", value: blob)]
        return components.url!
    }

    /// Polls `condition` on the main thread; XCUITest has no generic wait for a computed predicate.
    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            usleep(50_000)
        }
        return condition()
    }

    private func seedFile(_ values: [String: Any], named name: String) -> String {
        let path = scratch.appendingPathComponent(name)
        try? (values as NSDictionary).write(to: path)
        return path.path
    }

    private var fixtures: String {
        // The Fixtures folder is copied into this bundle's resources by `project.yml`.
        Bundle(for: Self.self).resourceURL!.appendingPathComponent("Fixtures").path
    }

    // MARK: - 1. The two completion signals

    func testGenerationStartsAtZeroAndCountsUp() {
        _ = launchApp()
        XCTAssertEqual(publishedGeneration, 0, "the window must publish 0 before the first reset")

        for expected in 1...3 {
            guard let result = sendReset([:]) else {
                return XCTFail("reset \(expected) was never acknowledged")
            }
            XCTAssertEqual(result.generation, expected, "the ack file holds the generation")
            // The accessibility value is set before the ack is written, so it is already up to date.
            XCTAssertEqual(publishedGeneration, expected,
                           "the window's accessibility value must follow the ack")
        }
    }

    /// The ack is written *last*: by the time it exists, the panels are rebuilt and readable.
    func testAckIsWrittenAfterEverythingElseHasSettled() {
        _ = launchApp()
        guard sendReset(["path0": fixtures, "panels": "1", "view": "3"]) != nil else {
            return XCTFail("not acknowledged")
        }
        // No waitForExistence: if the ack meant what it says, the row is in the tree already.
        let table = app.windows.firstMatch.tables.firstMatch
        XCTAssertTrue(table.exists)
        XCTAssertTrue(table.staticTexts["test.7z"].exists,
                      "the panel must already show the requested folder when the ack lands")
    }

    // MARK: - 2. What a reset resets

    func testPanelCountAndPathsFollowTheRequest() {
        _ = launchApp()
        guard sendReset(["panels": "2", "path0": fixtures, "path1": "/usr"]) != nil else {
            return XCTFail("not acknowledged")
        }
        XCTAssertEqual(window.tables.count, 2, "panels=2")
        guard sendReset(["panels": "1", "path0": "/usr"]) != nil else {
            return XCTFail("not acknowledged")
        }
        XCTAssertEqual(window.tables.count, 1, "panels=1")
    }

    func testDefaultsPlistReplacesTheSettingsDomain() {
        _ = launchApp()
        // A first reset that switches a visible setting on, and a second that does not mention it:
        // the second must put it back, because `defaults` replaces the domain rather than merging.
        let withTwoPanels = seedFile(["Lang": "-", "FM.Panels.numPanels": 2,
                                      "FM.PanelPath0": fixtures, "FM.PanelPath1": "/usr"],
                                     named: "two-panels.plist")
        let withOnePanel = seedFile(["Lang": "-", "FM.PanelPath0": fixtures],
                                    named: "one-panel.plist")
        guard sendReset(["defaults": withTwoPanels]) != nil else { return XCTFail("not acknowledged") }
        XCTAssertEqual(window.tables.count, 2)
        guard sendReset(["defaults": withOnePanel]) != nil else { return XCTFail("not acknowledged") }
        XCTAssertEqual(window.tables.count, 1, "numPanels was absent from the second plist")
    }

    /// The contract's "return selection ... to their defaults".
    ///
    /// "Default" is not "nothing selected": a freshly bound panel selects its first row, exactly as
    /// 7zFM leaves a focused-but-unselected row (`Mac/docs/api/panel.md` section 7 point 6). So the
    /// assertion is that a row the test picked *by hand* is no longer selected afterwards and the
    /// first row is -- which is only true if the panel was really rebuilt.
    func testSelectionIsResetToTheFreshlyBoundDefault() {
        _ = launchApp()
        guard sendReset(["path0": fixtures, "panels": "1", "view": "3"]) != nil else {
            return XCTFail("not acknowledged")
        }
        let table = window.tables.firstMatch
        XCTAssertTrue(table.staticTexts["test.zip"].waitForExistence(timeout: 15))

        func row(_ name: String) -> XCUIElement {
            table.tableRows.containing(.staticText, identifier: name).firstMatch
        }
        // The fixtures sort by name, so "multi.7z.001" is the first row and "test.zip" the last.
        let picked = row("test.zip")
        let first = row("multi.7z.001")
        table.staticTexts["test.zip"].click()
        XCTAssertTrue(picked.isSelected, "the click must select the row or the test proves nothing")
        XCTAssertFalse(first.isSelected)

        guard sendReset(["path0": fixtures, "panels": "1", "view": "3"]) != nil else {
            return XCTFail("not acknowledged")
        }
        XCTAssertTrue(table.staticTexts["test.zip"].waitForExistence(timeout: 15))
        XCTAssertFalse(row("test.zip").isSelected, "the hand-picked row must not survive a reset")
        XCTAssertTrue(row("multi.7z.001").isSelected, "and the panel must be freshly bound")
    }

    /// A reset has to cancel a running operation and wait for the worker to actually stop before it
    /// rebuilds the panels -- otherwise a cancelled operation would still be holding a panel's
    /// folder on a worker thread while the panel replaces it.
    ///
    /// The long operation is a real one, started through the same channel: `sevenzip:///run` with
    /// `h -scrcSHA256 /Applications`, which is `7zG h` inside the running file manager and puts up
    /// the Progress dialog (`Mac/docs/api/finder.md` section 1.2) for as long as it takes to hash
    /// every file under `/Applications` -- tens of seconds here, and no file-access permission, so
    /// an unattended run cannot be stopped by a TCC prompt. Driving it through the menus instead
    /// would mostly test the menus.
    ///
    /// This is also the case an Apple-event-delivered URL could not serve: while `NSApp.runModal` is
    /// on the stack the reset arrives on the watcher's `.common`-mode timer.
    func testResetCancelsARunningOperation() throws {
        _ = launchApp()
        guard sendReset(["path0": fixtures, "panels": "1", "view": "3"]) != nil else {
            return XCTFail("not acknowledged")
        }
        let generationBefore = publishedGeneration ?? -1

        send(url: runURL(argv: ["h", "-scrcSHA256", "/Applications"]))
        // IDD_PROGRESS 97 appears after the 500 ms creation delay. **It is an
        // `XCUIElement.ElementType.dialog`, not a `.window`**: measured, `app.windows.count` stays 1
        // while `app.dialogs.count` becomes 1, so a test that watches `app.windows` never sees the
        // progress dialog at all.
        guard waitFor(timeout: 30, { self.app.dialogs.count > 0 }) else {
            throw XCTSkip("the hash produced no progress dialog in 30 s "
                          + "(dialogs=\(app.dialogs.count), windows=\(app.windows.count))")
        }

        guard let result = sendReset(["path0": fixtures, "panels": "1"], timeout: 60) else {
            return XCTFail("the reset was not acknowledged while an operation was running")
        }
        XCTAssertEqual(result.generation, generationBefore + 1)
        XCTAssertTrue(waitFor(timeout: 10, { self.app.dialogs.count == 0 }),
                      "the progress dialog must be gone")
        XCTAssertEqual(app.windows.count, 1, "and nothing else may be left open")
        // The app is usable for the next test without a relaunch, and the panel really was rebuilt.
        XCTAssertTrue(window.tables.firstMatch.staticTexts["test.7z"].waitForExistence(timeout: 15))
        guard let after = sendReset(["path0": fixtures]) else {
            return XCTFail("the app stopped answering after a cancelled operation")
        }
        XCTAssertEqual(after.generation, result.generation + 1)
    }

    func testViewModeFollowsTheRequest() {
        _ = launchApp()
        // Details keeps the table; the other three modes lay a collection view over it (panel api
        // section 7 point 7), and the table stays in the hierarchy either way.
        guard sendReset(["path0": fixtures, "view": "details"]) != nil else {
            return XCTFail("not acknowledged")
        }
        XCTAssertTrue(window.tables.firstMatch.staticTexts["test.7z"].waitForExistence(timeout: 10))
        guard sendReset(["path0": fixtures, "view": "large"]) != nil else {
            return XCTFail("not acknowledged")
        }
        XCTAssertTrue(window.descendants(matching: .any)["test.7z"].exists
                      || window.staticTexts["test.7z"].exists,
                      "the item is still listed in large-icon mode")
    }

    func testLanguageIsReloaded() {
        _ = launchApp()
        guard sendReset(["lang": "-", "path0": fixtures]) != nil else {
            return XCTFail("not acknowledged")
        }
        // The app menu keeps the bundle name in every language, so the whole list of top-level
        // titles is compared instead of one of them.
        func menuTitles() -> [String] {
            app.menuBars.menuBarItems.allElementsBoundByIndex.map(\.title)
        }
        let english = menuTitles()
        XCTAssertTrue(english.contains("File"), "unexpected English menu bar: \(english)")
        guard sendReset(["lang": "de", "path0": fixtures]) != nil else {
            return XCTFail("not acknowledged")
        }
        let german = menuTitles()
        XCTAssertNotEqual(english, german,
                          "the menu bar must be rebuilt from the new lang file (\(german))")
        XCTAssertFalse(german.contains("File"), "still English: \(german)")
        guard sendReset(["lang": "-", "path0": fixtures]) != nil else {
            return XCTFail("not acknowledged")
        }
        XCTAssertEqual(menuTitles(), english, "and back again")
    }

    // MARK: - 3. The gate

    /// Without `SZ_TEST_SUPPORT` the host does not exist: no ack, no generation, and the window
    /// publishes no value at all.
    func testResetDoesNothingWithoutTestSupport() {
        _ = launchApp(testSupport: false)
        XCTAssertNil(publishedGeneration,
                     "the window must not publish a reset generation without test support")
        XCTAssertNil(sendReset([:], timeout: 6), "the reset must not be acknowledged")
        XCTAssertTrue(app.windows.firstMatch.exists, "and the app must still be alive")
    }

    // MARK: - 4. The measurement

    /// Prints the two numbers `Mac/docs/api/resetcmd.md` reports: what a reset costs against what a
    /// relaunch costs, both measured the way a test pays for them.
    func testMeasureResetAgainstRelaunch() {
        let seed = seedFile(["Lang": "-", "FM.PanelPath0": fixtures,
                             "FM.Position": "{{80, 80}, {1200, 800}}"], named: "measure.plist")
        _ = launchApp()

        var resets: [TimeInterval] = []
        for index in 0..<10 {
            let parameters: [String: String] = index % 2 == 0
                ? ["defaults": seed, "path0": fixtures, "panels": "2", "path1": "/usr", "view": "3"]
                : ["defaults": seed, "path0": "/usr", "panels": "1", "view": "2"]
            guard let result = sendReset(parameters) else { return XCTFail("not acknowledged") }
            resets.append(result.seconds)
        }

        var minimal: [TimeInterval] = []
        for _ in 0..<10 {
            // No `defaults`, no panel switch: this is the floor -- URL transport plus one panel
            // rebind plus the acknowledgement -- so the difference from `resets` is the real work.
            guard let result = sendReset(["path0": fixtures]) else { return XCTFail("not acknowledged") }
            minimal.append(result.seconds)
        }

        var relaunches: [TimeInterval] = []
        for _ in 0..<3 {
            let started = Date()
            app.terminate()
            let application = XCUIApplication()
            application.launchEnvironment = ["SZ_TEST_SUPPORT": "1",
                                            "SZ_DISABLE_ANIMATIONS": "1",
                                            "SZ_STATE_DIR": stateDirectory.path,
                                            "SEVENZIP_DEFAULTS_SUITE": seed]
            application.launch()
            app = application
            XCTAssertTrue(application.windows.firstMatch.tables.firstMatch
                .waitForExistence(timeout: 60), "no panel after the relaunch")
            relaunches.append(Date().timeIntervalSince(started))
        }

        func summary(_ label: String, _ values: [TimeInterval]) -> String {
            let mean = values.reduce(0, +) / Double(values.count)
            return String(format: "%@: n=%d mean %.3f s min %.3f max %.3f",
                          label, values.count, mean, values.min()!, values.max()!)
        }
        let text = summary("reset (defaults + panel switch)", resets) + "\n"
            + summary("reset (minimal)", minimal) + "\n"
            + summary("relaunch", relaunches)
        add(XCTAttachment(string: text))
        print("== resetcmd measurement ==\n" + text)
        XCTAssertLessThan(resets.reduce(0, +) / Double(resets.count),
                          relaunches.reduce(0, +) / Double(relaunches.count),
                          "a reset has to be cheaper than a relaunch or none of this was worth it")
    }
}
