// SevenZipUITestCase.swift -- base class for every 7-Zip UI test. It hands the test a
// `SevenZipApp`, brings that app to the settings the test asks for, screenshots a failure, and
// hands the instance on to the next test of the same class instead of quitting it.
//
// **One app per class, not one per test.** Measured before this change: 52 UI tests, 1490 s, 28.7 s
// each, and the assertions were a rounding error next to the launch. So the app is launched once
// per test class and returned to a known state between tests through `sevenzip://test/reset`
// (`ai/test-support-contract.md`), waiting for the acknowledgement the contract specifies.
// Everything a reset cannot express still relaunches, and says so:
//
//   * `seed: .keep` and `relaunch()` -- the *point* of those is that the app quit and came back;
//   * a `path:` / `formatHint:` argv (7zG mode, an archive on the command line);
//   * extra `arguments:` or `environment:` -- a process's environment cannot be changed once it
//     runs, so a test that needs `SZ_OPSINFRA_DEMO` needs its own process;
//   * an app that does not implement the contract yet, which `testSupportIsImplemented` reports.
//     Until `mac/resetcmd` merges that is *every* app, so the suite behaves exactly as before and
//     stays green; what changes then is only the time it takes.
//
// Settings hygiene is unchanged: every launch and every reset hands the app one property-list file
// as its whole preferences domain (`SettingsSeed` / `SettingsSeedFile`), so a test can neither read
// nor corrupt the developer's preferences, and what the app saves when it quits cannot reach the
// next test. What is new is `SZ_STATE_DIR` and `SZ_DISABLE_ANIMATIONS` from `TestShard`: a state
// directory per test class, so two shards running at once never touch the same file, and no
// animation time at all.
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

    /// The driver. Shared by every test of this class; not launched until a test calls `launch(...)`.
    public var sevenZip: SevenZipApp!
    /// Shorthand for `sevenZip.app`.
    public var app: XCUIApplication { sevenZip.app }
    /// File-name prefix of the screenshots this class writes (`<prefix>-<name>.png`).
    open var screenshotPrefix: String { "harness" }

    /// Set false by a class whose tests must each have a process of their own.
    open class var reusesTheApp: Bool { true }

    /// Seconds a single test may take before XCTest fails it instead of letting the run stall. Only
    /// in effect when the run passes `-test-timeouts-enabled YES`, which `Mac/scripts/test.sh` does.
    open class var timeAllowance: TimeInterval { 240 }

    /// The instance of this test class's app, kept between tests. Keyed by class name, because the
    /// static lives on the base class while `Self` is the subclass.
    private static var instances: [String: SevenZipApp] = [:]

    private var savedSettings: [String: Any]?

    /// The dictionary key of this test class. A `class var`, not a `static var`, so a subclass
    /// really gets its own entry: `self` inside a class property is the class it was called on.
    private class var key: String { NSStringFromClass(self) }

    open override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        executionTimeAllowance = Self.timeAllowance
        // testreg: never drive, message or terminate a 7-Zip that is not this shard's build
        // (XCUIApplication attaches to and terminates by bundle identifier, and the user's
        // /Applications/7-Zip.app carries the input shard's). Stops the test before it starts.
        TestShard.assertOnlyTestBuildRuns("before \(name)")
        if Self.reusesTheApp, let existing = Self.instances[Self.key] {
            sevenZip = existing
        } else {
            sevenZip = SevenZipApp()
            Self.instances[Self.key] = sevenZip
        }
        sevenZip.owner = Self.key
        sevenZip.seedName = Self.slug(name)      // the seed file says which test wrote it
        // Only meaningful outside the sandbox; inside it the snapshot is the runner's own copy.
        savedSettings = sevenZip.settings.isRedirected ? nil : sevenZip.settings.snapshot()
    }

    open override func tearDown() {
        // `hasSucceeded` is only valid once the run has stopped, and tearDown runs before that,
        // so it would attach a "failure" screenshot to every passing test: count failures instead.
        // testreg: a test that made Launch Services start or message another copy fails here, by name.
        if (testRun?.totalFailureCount ?? 0) == 0 { TestShard.assertOnlyTestBuildRuns("after \(name)") }
        let failed = (testRun?.totalFailureCount ?? 0) > 0
        if failed {
            _ = sevenZip?.screenshot("failure-" + Self.slug(name), prefix: screenshotPrefix, test: self)
        }
        // A failing test may have left a modal sheet up or the panels in a state a reset cannot
        // untangle, so its process is thrown away; a passing one hands its app to the next test --
        // but only when a reset is what the next test will do. With the app side of the contract
        // missing, `prepare` relaunches anyway, and keeping the old instance alive until then is not
        // free: measured, leaving a process to be terminated by the *next* test's launch cost two
        // failures per run, a menu item clicked at an undefined point ("Invalid parameter not
        // satisfying: point.x != INFINITY") and a column-header click that landed nowhere. So while
        // there is no reset, the lifecycle is exactly the one the suite had before this change.
        let willReuse = Self.reusesTheApp && (sevenZip?.testSupportIsImplemented ?? false)
        if failed || !willReuse {
            sevenZip?.terminate()
            Self.instances[Self.key] = nil
        }
        // A passing test's per-test settings domain is throwaway; a failing one's is evidence.
        if !failed { sevenZip?.seedFile?.remove() }
        if let savedSettings { sevenZip?.settings.restore(savedSettings) }
        super.tearDown()
    }

    /// The last test of the class has run: let go of the instance it was reusing.
    open override class func tearDown() {
        instances[key]?.terminate()
        instances[key]?.seedFile?.remove()
        instances[key] = nil
        super.tearDown()
    }

    /// Bring the app to these settings: a reset of the running instance when the contract allows
    /// it, a launch when it does not. See `SevenZipApp.prepare`.
    @discardableResult
    public func launch(seed: SettingsSeed = .clean,
                       path: String? = nil,
                       formatHint: String? = nil,
                       arguments: [String] = [],
                       environment: [String: String] = [:]) -> XCUIElement {
        sevenZip.prepare(seed: seed, path: path, formatHint: formatHint,
                         arguments: arguments, environment: environment)
    }

    /// Launch a process of its own, whatever the class's reuse policy is -- for a test that asserts
    /// something about startup itself.
    @discardableResult
    public func launchFreshProcess(seed: SettingsSeed = .clean,
                                   path: String? = nil,
                                   formatHint: String? = nil,
                                   arguments: [String] = [],
                                   environment: [String: String] = [:]) -> XCUIElement {
        sevenZip.launch(seed: seed, path: path, formatHint: formatHint,
                        arguments: arguments, environment: environment)
    }

    /// Screenshot into `Mac/build/screenshots/<screenshotPrefix>-<name>.png`.
    @discardableResult
    public func screenshot(_ name: String) -> URL? {
        sevenZip.screenshot(name, prefix: screenshotPrefix, test: self)
    }

    /// Poll `condition` until it holds -- UI updates land asynchronously through the panel's queue,
    /// so a test waits for the state it needs and never for a fixed number of seconds.
    @discardableResult
    public func waitFor(_ what: String, timeout: TimeInterval = 20, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            usleep(100_000)
        } while Date() < deadline
        return condition()
    }

    /// "-[SevenZipUITests.SmokeTests testX]" -> "SmokeTests-testX"
    private static func slug(_ testName: String) -> String {
        let parts = testName.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        return parts.suffix(2).joined(separator: "-")
    }
}
