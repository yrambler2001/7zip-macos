// SevenZipUITestCase.swift -- base class for every 7-Zip UI test: it hands the test a
// `SevenZipApp` to launch with clean or seeded settings, screenshots a failure, and kills the app
// afterwards.
//
// Settings hygiene: the app is launched with its settings as launch arguments
// (`SettingsSeed`), which never touch what is stored, so a test cannot corrupt the developer's
// preferences. The app itself still saves its state when it quits, so `Mac/scripts/test.sh` backs
// the domain up before a UI run and restores it afterwards. If the runner is ever *not* sandboxed
// this class additionally snapshots and restores the domain itself.
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
        // Only meaningful outside the sandbox; inside it the snapshot is the runner's own copy.
        savedSettings = sevenZip.settings.isRedirected ? nil : sevenZip.settings.snapshot()
    }

    open override func tearDown() {
        // `hasSucceeded` is only valid once the run has stopped, and tearDown runs before that,
        // so it would attach a "failure" screenshot to every passing test: count failures instead.
        if let run = testRun, run.totalFailureCount > 0 {
            _ = sevenZip?.screenshot("failure-" + Self.slug(name), prefix: screenshotPrefix, test: self)
        }
        sevenZip?.terminate()
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
