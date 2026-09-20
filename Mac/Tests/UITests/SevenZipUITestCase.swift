// SevenZipUITestCase.swift -- base class for every 7-Zip UI test: it hands the test a
// `SevenZipApp` to launch with clean or seeded settings, screenshots a failure, and kills the app
// afterwards.
//
// Settings hygiene: every `launch(...)` writes the seed to a property-list file of its own and
// hands it to the app as its whole preferences domain (`SettingsSeed` / `SettingsSeedFile`), so a
// test can neither read nor corrupt the developer's preferences, and the state the app saves when
// it quits cannot reach the next test. `Mac/scripts/test.sh` still backs the real domain up and
// restores it around a run as a safety net, and if the runner is ever *not* sandboxed this class
// snapshots and restores the domain itself.
//
//   final class MyTests: SevenZipUITestCase {
//       override var screenshotPrefix: String { "panel" }      // screenshots/panel-*.png
//       func testSomething() {
//           launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]))
//           let p = sevenZip.panel(0)
//           XCTAssertTrue(p.waitForRow(named: "test.7z"))
//           screenshot("01-fixtures")
//       }
//   }

import Foundation
import XCTest

open class SevenZipUITestCase: XCTestCase {

    /// The driver. Not launched until a test calls `launch(...)`.
    public var sevenZip: SevenZipApp!
    /// Shorthand for `sevenZip.app`.
    public var app: XCUIApplication { sevenZip.app }
    /// File-name prefix of the screenshots this class writes (`<prefix>-<name>.png`).
    open var screenshotPrefix: String { "harness" }

    private var savedSettings: [String: Any]?

    open override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        sevenZip = SevenZipApp()
        sevenZip.seedName = Self.slug(name)      // the seed file says which test wrote it
        // Only meaningful outside the sandbox; inside it the snapshot is the runner's own copy.
        savedSettings = sevenZip.settings.isRedirected ? nil : sevenZip.settings.snapshot()
    }

    open override func tearDown() {
        // `hasSucceeded` is only valid once the run has stopped, and tearDown runs before that,
        // so it would attach a "failure" screenshot to every passing test: count failures instead.
        let failed = (testRun?.totalFailureCount ?? 0) > 0
        if failed {
            _ = sevenZip?.screenshot("failure-" + Self.slug(name), prefix: screenshotPrefix, test: self)
        }
        sevenZip?.terminate()
        // A passing test's per-test settings domain is throwaway; a failing one's is evidence.
        if !failed { sevenZip?.seedFile?.remove() }
        if let savedSettings { sevenZip?.settings.restore(savedSettings) }
        super.tearDown()
    }

    /// Launch the app; see `SevenZipApp.launch`.
    @discardableResult
    public func launch(seed: SettingsSeed = .clean,
                       path: String? = nil,
                       formatHint: String? = nil,
                       arguments: [String] = [],
                       environment: [String: String] = [:]) -> XCUIElement {
        sevenZip.launch(seed: seed, path: path, formatHint: formatHint,
                        arguments: arguments, environment: environment)
    }

    /// Screenshot into `Mac/docs/reports/screenshots/<screenshotPrefix>-<name>.png`.
    @discardableResult
    public func screenshot(_ name: String) -> URL? {
        sevenZip.screenshot(name, prefix: screenshotPrefix, test: self)
    }

    /// "-[SevenZipUITests.SmokeTests testX]" -> "SmokeTests-testX"
    private static func slug(_ testName: String) -> String {
        let parts = testName.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        return parts.suffix(2).joined(separator: "-")
    }
}
