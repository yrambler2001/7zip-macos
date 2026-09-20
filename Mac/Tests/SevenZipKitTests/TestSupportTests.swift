// TestSupportTests.swift -- the parts of `mac/resetcmd` that are testable without the GUI:
// the three environment switches, the `sevenzip://test/reset` URL grammar and its rejection when
// test support is off, the `SZ_STATE_DIR` redirection, and the settings reload.
//
// Contract: `Mac/docs/test-support-contract.md`. Implementation notes: `Mac/docs/api/resetcmd.md`.
//
// The sources under test are `Mac/App/Support/Settings.swift` (`TestSupport`, the domain
// replacement) and `Mac/App/Integration/CommandURL.swift` (`TestResetRequest`), both already
// compiled into this target, plus `SZSettings` in the bridge.
//
// Isolation: every test that writes settings points `SEVENZIP_DEFAULTS_SUITE` at an absolute plist
// path of its own inside a fresh temporary directory, because `Settings.replaceDomainContents`
// deliberately **empties** the domain it is pointed at. tearDown restores the environment exactly
// as it found it, so neither the user's real settings nor `SettingsTests`' own suite is touched.

import XCTest
import SevenZipKit

final class TestSupportTests: XCTestCase {

    private var savedEnvironment: [String: String?] = [:]
    private var scratch: URL!

    private static let variables = [
        SZSettingsTestSupportEnvironmentVariable,      // SZ_TEST_SUPPORT
        "SZ_DISABLE_ANIMATIONS",
        SZSettingsStateDirectoryEnvironmentVariable,   // SZ_STATE_DIR
        SZSettingsSuiteEnvironmentVariable,            // SEVENZIP_DEFAULTS_SUITE
    ]

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedEnvironment = [:]
        for name in Self.variables {
            savedEnvironment[name] = getenv(name).map { String(cString: $0) }
            unsetenv(name)
        }
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("resetcmd-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for (name, value) in savedEnvironment {
            if let value { setenv(name, value, 1) } else { unsetenv(name) }
        }
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
        super.tearDown()
    }

    private func enableTestSupport() {
        setenv(SZSettingsTestSupportEnvironmentVariable, "1", 1)
    }

    /// Points the settings domain at a plist of this test's own, and returns its path.
    private func isolatedDomain() -> String {
        let path = scratch.appendingPathComponent("prefs.plist").path
        setenv(SZSettingsSuiteEnvironmentVariable, path, 1)
        return path
    }

    // MARK: - 1. The environment switches

    func testTestSupportIsOffByDefault() {
        XCTAssertFalse(TestSupport.isEnabled)
        XCTAssertFalse(SZSettings.testSupportEnabled)
        XCTAssertFalse(TestSupport.animationsDisabled)
        XCTAssertNil(TestSupport.stateDirectory)
        XCTAssertEqual(TestSupport.temporaryDirectory, NSTemporaryDirectory())
    }

    /// Only the exact value "1" counts, so a stray "0"/"false"/"YES" cannot switch test support on.
    func testTestSupportRequiresExactlyOne() {
        for value in ["0", "", "yes", "YES", "true", "2", "11"] {
            setenv(SZSettingsTestSupportEnvironmentVariable, value, 1)
            XCTAssertFalse(TestSupport.isEnabled, "SZ_TEST_SUPPORT=\(value) must not enable it")
        }
        setenv(SZSettingsTestSupportEnvironmentVariable, "1", 1)
        XCTAssertTrue(TestSupport.isEnabled)
    }

    /// The other two switches are gated on the master switch, which is what keeps the promise that
    /// nothing changes behaviour when `SZ_TEST_SUPPORT` is unset.
    func testAnimationsAndStateDirectoryAreGatedOnTestSupport() {
        setenv("SZ_DISABLE_ANIMATIONS", "1", 1)
        setenv(SZSettingsStateDirectoryEnvironmentVariable, scratch.path, 1)
        XCTAssertFalse(TestSupport.animationsDisabled)
        XCTAssertNil(TestSupport.stateDirectory)
        XCTAssertEqual(TestSupport.temporaryDirectory, NSTemporaryDirectory())

        enableTestSupport()
        XCTAssertTrue(TestSupport.animationsDisabled)
        XCTAssertEqual(TestSupport.stateDirectory, scratch.path)
    }

    func testAnimationsRequiresExactlyOne() {
        enableTestSupport()
        for value in ["0", "yes", "true"] {
            setenv("SZ_DISABLE_ANIMATIONS", value, 1)
            XCTAssertFalse(TestSupport.animationsDisabled)
        }
        setenv("SZ_DISABLE_ANIMATIONS", "1", 1)
        XCTAssertTrue(TestSupport.animationsDisabled)
    }

    /// The variables are re-read on every access, so a test may switch them mid-process -- the rule
    /// `NMacPrefs::ApplicationID()` already follows for the settings suite.
    func testSwitchesAreReReadOnEveryAccess() {
        enableTestSupport()
        XCTAssertTrue(TestSupport.isEnabled)
        unsetenv(SZSettingsTestSupportEnvironmentVariable)
        XCTAssertFalse(TestSupport.isEnabled)
        enableTestSupport()
        XCTAssertTrue(TestSupport.isEnabled)
    }

    // MARK: - 2. The state directory

    func testStateDirectoryRedirectsTheTemporaryDirectory() throws {
        enableTestSupport()
        setenv(SZSettingsStateDirectoryEnvironmentVariable, scratch.path, 1)

        let expected = scratch.appendingPathComponent("tmp").path + "/"
        XCTAssertEqual(SZSettings.temporaryDirectory, expected)
        XCTAssertEqual(TestSupport.temporaryDirectory, expected)
        XCTAssertNotEqual(SZSettings.temporaryDirectory, NSTemporaryDirectory())
        // It must exist: mkdtemp() and the list-file writers do not create it themselves.
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected))
    }

    /// `CommandURL` resolves the same rule on its own, because it is Foundation-only (it is
    /// compiled into the two sandboxed appexes, which may not link the bridge). The two
    /// implementations must never disagree.
    func testCommandURLTemporaryRootAgreesWithTheBridge() {
        XCTAssertEqual(CommandURL.temporaryRoot, SZSettings.temporaryDirectory)
        enableTestSupport()
        setenv(SZSettingsStateDirectoryEnvironmentVariable, scratch.path, 1)
        XCTAssertEqual(CommandURL.temporaryRoot, SZSettings.temporaryDirectory)
        XCTAssertEqual(CommandURL.temporaryRoot, scratch.appendingPathComponent("tmp").path + "/")
    }

    /// Two instances given different values must never touch the same file.
    func testTwoStateDirectoriesNeverShareATemporaryPath() throws {
        enableTestSupport()
        let a = scratch.appendingPathComponent("a").path
        let b = scratch.appendingPathComponent("b").path
        setenv(SZSettingsStateDirectoryEnvironmentVariable, a, 1)
        let tempA = SZSettings.temporaryDirectory
        setenv(SZSettingsStateDirectoryEnvironmentVariable, b, 1)
        let tempB = SZSettings.temporaryDirectory
        XCTAssertNotEqual(tempA, tempB)
        XCTAssertFalse(tempA.hasPrefix(tempB))
        XCTAssertFalse(tempB.hasPrefix(tempA))

        // A list file written by each lands in its own tree.
        let listA = try XCTUnwrap(CommandURL.writeListFile(paths: ["/x"], in: tempA))
        let listB = try XCTUnwrap(CommandURL.writeListFile(paths: ["/x"], in: tempB))
        XCTAssertTrue(listA.hasPrefix(tempA))
        XCTAssertTrue(listB.hasPrefix(tempB))
        XCTAssertNotEqual(listA, listB)
    }

    /// The bridge's own temp-folder machinery has to follow the state directory too, or the app and
    /// the engine would disagree about where `7zO*` / `7zE*` live -- and `temporaryDirectories`,
    /// which Tools > Delete Temporary Files and the launch sweep enumerate, would list and delete
    /// another instance's live folders.
    func testStateDirectoryRedirectsTheBridgeTemporaryFolders() throws {
        enableTestSupport()
        setenv(SZSettingsStateDirectoryEnvironmentVariable, scratch.path, 1)
        let root = scratch.appendingPathComponent("tmp").path

        let opened = try XCTUnwrap(
            SZTempOpen.createTemporaryDirectory(prefix: SZTempOpen.openDirectoryPrefix))
        let extracted = try XCTUnwrap(
            SZTempOpen.createTemporaryDirectory(prefix: SZTempOpen.extractDirectoryPrefix))
        defer {
            SZTempOpen.removeTemporaryDirectory(atPath: opened)
            SZTempOpen.removeTemporaryDirectory(atPath: extracted)
        }
        XCTAssertTrue(opened.hasPrefix(root), "\(opened) is not inside \(root)")
        XCTAssertTrue(extracted.hasPrefix(root), "\(extracted) is not inside \(root)")
        // The folder's parent is the state directory's own `tmp`, not the shared temp root. (A
        // `hasPrefix(NSTemporaryDirectory())` check would not say that: this test's scratch
        // directory is itself inside the shared temp root.)
        XCTAssertEqual((opened as NSString).deletingLastPathComponent,
                       (root as NSString).standardizingPath)

        // Both are enumerated, and nothing from the shared temp root is.
        let listed = SZTempOpen.temporaryDirectories()
        XCTAssertTrue(listed.contains(opened), "\(opened) missing from \(listed)")
        XCTAssertTrue(listed.contains(extracted))
        XCTAssertTrue(listed.allSatisfy { $0.hasPrefix(root) }, "leaked outside the state dir: \(listed)")

        // The removal guard is scoped to the same root: a path outside it is refused.
        XCTAssertFalse(SZTempOpen.removeTemporaryDirectory(atPath: NSTemporaryDirectory() + "7zO-foreign"))
    }

    /// A relative value is refused rather than resolved against the current directory, which would
    /// be a path the app could not reason about.
    func testRelativeStateDirectoryIsIgnored() {
        enableTestSupport()
        setenv(SZSettingsStateDirectoryEnvironmentVariable, "relative/state", 1)
        XCTAssertNil(TestSupport.stateDirectory)
        XCTAssertEqual(TestSupport.temporaryDirectory, NSTemporaryDirectory())
    }

    /// `prepareForLaunch` points the settings domain at the state directory when the harness has
    /// not named a suite itself, so two instances keep separate settings even with one bundle id.
    func testPrepareForLaunchDerivesTheSettingsDomainFromTheStateDirectory() {
        enableTestSupport()
        setenv(SZSettingsStateDirectoryEnvironmentVariable, scratch.path, 1)
        TestSupport.prepareForLaunch()
        XCTAssertEqual(SZSettings.applicationID, scratch.appendingPathComponent("preferences.plist").path)
        XCTAssertTrue(SZSettings.usesOverrideSuite)
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.path))
    }

    /// ... but an explicit suite always wins: that is how the UI harness seeds one plist per test.
    func testPrepareForLaunchKeepsAnExplicitSuite() {
        enableTestSupport()
        setenv(SZSettingsStateDirectoryEnvironmentVariable, scratch.path, 1)
        setenv(SZSettingsSuiteEnvironmentVariable, "com.yrambler2001.7zip.resetcmd-tests", 1)
        TestSupport.prepareForLaunch()
        XCTAssertEqual(SZSettings.applicationID, "com.yrambler2001.7zip.resetcmd-tests")
    }

    func testPrepareForLaunchDoesNothingWithoutTestSupport() {
        setenv(SZSettingsStateDirectoryEnvironmentVariable, scratch.path, 1)
        TestSupport.prepareForLaunch()
        XCTAssertEqual(SZSettings.applicationID, SZSettingsDefaultApplicationID)
    }

    // MARK: - 3. The reset URL

    private func resetURL(_ query: String) -> URL {
        URL(string: "sevenzip://test/reset" + (query.isEmpty ? "" : "?" + query))!
    }

    /// The whole point of the gate: with `SZ_TEST_SUPPORT` unset the host does not exist, and the
    /// rejection is the same "Unsupported URL command" a shipped app gives any unknown command.
    func testResetIsRejectedWhenTestSupportIsOff() {
        XCTAssertFalse(CommandURL.testSupportEnabled)
        for query in ["", "ack=/tmp/a", "panels=2&path0=/tmp"] {
            XCTAssertThrowsError(try CommandURL.parse(resetURL(query))) { error in
                let message = (error as? SevenZipArgumentError)?.message
                XCTAssertEqual(message, "Unsupported URL command")
            }
        }
        // Explicitly, so the gate is testable without touching the environment at all.
        XCTAssertThrowsError(try CommandURL.parse(resetURL("panels=1"), testSupportEnabled: false))
    }

    func testResetIsAcceptedWhenTestSupportIsOn() throws {
        enableTestSupport()
        XCTAssertTrue(CommandURL.testSupportEnabled)
        let action = try CommandURL.parse(resetURL("panels=2"))
        guard case .testReset(let request) = action else { return XCTFail("not a reset: \(action)") }
        XCTAssertEqual(request.panelCount, 2)
    }

    func testEveryContractParameterIsParsed() throws {
        let query = "defaults=/tmp/seed.plist&lang=de&panels=2"
            + "&path0=/tmp/left&path1=/tmp/right&view=1&ack=/tmp/ack.txt"
        let action = try CommandURL.parse(resetURL(query), testSupportEnabled: true)
        guard case .testReset(let request) = action else { return XCTFail("not a reset") }
        XCTAssertEqual(request.defaultsPath, "/tmp/seed.plist")
        XCTAssertEqual(request.language, "de")
        XCTAssertEqual(request.panelCount, 2)
        XCTAssertEqual(request.panelPaths[0], "/tmp/left")
        XCTAssertEqual(request.panelPaths[1], "/tmp/right")
        XCTAssertEqual(request.viewMode, 1)
        XCTAssertEqual(request.ackPath, "/tmp/ack.txt")
        XCTAssertTrue(request.warnings.isEmpty, "unexpected warnings: \(request.warnings)")
    }

    func testEveryParameterIsOptional() throws {
        let action = try CommandURL.parse(resetURL(""), testSupportEnabled: true)
        guard case .testReset(let request) = action else { return XCTFail("not a reset") }
        XCTAssertEqual(request, TestResetRequest())
        XCTAssertNil(request.panelCount)
        XCTAssertTrue(request.panelPaths.isEmpty)
        XCTAssertTrue(request.warnings.isEmpty)
    }

    /// Paths with spaces and non-ASCII survive the query encoding, which is what a fixture path in
    /// a worktree looks like.
    func testPathsWithSpacesAndNonASCIISurvive() throws {
        var request = TestResetRequest()
        request.panelPaths[0] = "/tmp/a b/ünïcode & more"
        request.ackPath = "/tmp/a b/ack ✓.txt"
        let url = try XCTUnwrap(request.url)
        let action = try CommandURL.parse(url, testSupportEnabled: true)
        guard case .testReset(let parsed) = action else { return XCTFail("not a reset") }
        XCTAssertEqual(parsed.panelPaths[0], "/tmp/a b/ünïcode & more")
        XCTAssertEqual(parsed.ackPath, "/tmp/a b/ack ✓.txt")
    }

    func testViewModeAcceptsNumbersAndNames() throws {
        for (value, expected) in [("0", 0), ("3", 3), ("large", 0), ("small", 1),
                                  ("list", 2), ("details", 3), ("DETAILS", 3)] {
            let action = try CommandURL.parse(resetURL("view=\(value)"), testSupportEnabled: true)
            guard case .testReset(let request) = action else { return XCTFail("not a reset") }
            XCTAssertEqual(request.viewMode, expected, "view=\(value)")
        }
    }

    /// A value the app cannot use is recorded and ignored rather than failing the command, because
    /// the acknowledgement has to be written for every reset a test issues (api/resetcmd.md §4).
    func testUnusableValuesAreWarnedAboutAndIgnored() throws {
        let query = "panels=3&view=huge&ack=relative/path&defaults=also/relative&bogus=1"
        let action = try CommandURL.parse(resetURL(query), testSupportEnabled: true)
        guard case .testReset(let request) = action else { return XCTFail("not a reset") }
        XCTAssertNil(request.panelCount)
        XCTAssertNil(request.viewMode)
        XCTAssertNil(request.ackPath)
        XCTAssertNil(request.defaultsPath)
        XCTAssertEqual(request.warnings.count, 5)
        XCTAssertTrue(request.warnings.contains { $0.contains("unknown reset parameter: bogus") })
    }

    func testUnknownTestCommandIsRejected() {
        XCTAssertThrowsError(try CommandURL.parse(URL(string: "sevenzip://test/quit")!,
                                                 testSupportEnabled: true))
        XCTAssertThrowsError(try CommandURL.parse(URL(string: "sevenzip://test/")!,
                                                 testSupportEnabled: true))
    }

    /// The `test` host must not disturb the two real commands, with or without test support.
    func testTheRealCommandsAreUnaffected() throws {
        for enabled in [false, true] {
            let run = try XCTUnwrap(CommandURL.url(argv: ["x", "/tmp/a.7z"]))
            XCTAssertEqual(try CommandURL.parse(run, testSupportEnabled: enabled),
                           .run(argv: ["x", "/tmp/a.7z"], temporaryFiles: []))
            let settings = try XCTUnwrap(CommandURL.settingsURL(show: true))
            XCTAssertEqual(try CommandURL.parse(settings, testSupportEnabled: enabled),
                           .settings(show: true))
        }
    }

    /// `x-7zip://test/reset` works too: `03 section 6.4` spells the scheme that way and both are
    /// registered.
    func testAlternateSchemeIsAccepted() throws {
        let url = URL(string: "x-7zip://test/reset?panels=1")!
        let action = try CommandURL.parse(url, testSupportEnabled: true)
        guard case .testReset(let request) = action else { return XCTFail("not a reset") }
        XCTAssertEqual(request.panelCount, 1)
    }

    func testRequestURLRoundTrip() throws {
        var request = TestResetRequest()
        request.defaultsPath = "/tmp/seed.plist"
        request.language = "-"
        request.panelCount = 2
        request.panelPaths = [0: "/tmp/one", 1: "/tmp/two"]
        request.viewMode = 3
        request.ackPath = "/tmp/ack"
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, CommandURL.testHost)
        XCTAssertEqual(url.path, CommandURL.resetPath)
        let action = try CommandURL.parse(url, testSupportEnabled: true)
        XCTAssertEqual(action, .testReset(request))
    }

    // MARK: - 4. The settings reload

    func testReplaceDomainContentsReplacesEverything() throws {
        _ = isolatedDomain()
        Settings.setString("/tmp/before", Settings.Key.panelPath(0))
        Settings.setInteger(2, Settings.Key.numPanels)
        XCTAssertEqual(Settings.panelPath(0), "/tmp/before")

        Settings.replaceDomainContents(with: [Settings.Key.lang: "de",
                                              Settings.Key.panelPath(0): "/tmp/after"])
        // The new values are in ...
        XCTAssertEqual(Settings.language, "de")
        XCTAssertEqual(Settings.panelPath(0), "/tmp/after")
        // ... and the keys the replacement did not mention are gone, not merged.
        XCTAssertFalse(SZSettings.hasKey(Settings.Key.numPanels))
        XCTAssertEqual(Settings.numPanels, 1)                   // back to the documented default
        XCTAssertEqual(Set(Settings.domainContents().keys),
                       Set([Settings.Key.lang, Settings.Key.panelPath(0)]))
    }

    func testReplaceDomainContentsKeepsPropertyListTypes() throws {
        _ = isolatedDomain()
        Settings.replaceDomainContents(with: [
            Settings.Key.numPanels: 2,
            Settings.Key.showDots: true,
            Settings.Key.splitterPos: "0.25",
            Settings.Key.folderHistory: ["/tmp", "/usr"],
        ])
        XCTAssertEqual(Settings.numPanels, 2)
        XCTAssertTrue(Settings.showDots)
        XCTAssertEqual(Settings.splitterPos, 0.25, accuracy: 0.0001)
        XCTAssertEqual(Settings.folderHistory, ["/tmp", "/usr"])
        XCTAssertEqual(SZSettings.propertyListValue(forKey: Settings.Key.numPanels) as? Int, 2)
        XCTAssertEqual(SZSettings.propertyListValue(forKey: Settings.Key.showDots) as? Bool, true)
        XCTAssertEqual(SZSettings.propertyListValue(forKey: Settings.Key.folderHistory) as? [String],
                       ["/tmp", "/usr"])
    }

    /// `defaults=<plist>`: the file is the domain afterwards, whatever was there before.
    func testReplaceDomainContentsFromAPlistFile() throws {
        _ = isolatedDomain()
        Settings.setString("/tmp/stale", Settings.Key.panelPath(0))
        Settings.setBool(true, Settings.Key.showGrid)

        let seed: [String: Any] = [Settings.Key.lang: "-",
                                   Settings.Key.numPanels: 2,
                                   Settings.Key.panelPath(0): "/tmp/seeded"]
        let seedPath = scratch.appendingPathComponent("seed.plist")
        try (seed as NSDictionary).write(to: seedPath)

        XCTAssertTrue(Settings.replaceDomainContents(fromPlistAt: seedPath.path))
        XCTAssertEqual(Settings.language, "-")
        XCTAssertEqual(Settings.numPanels, 2)
        XCTAssertEqual(Settings.panelPath(0), "/tmp/seeded")
        XCTAssertFalse(SZSettings.hasKey(Settings.Key.showGrid))
        XCTAssertFalse(Settings.showGrid)
    }

    func testReplaceDomainContentsFromAMissingOrBadPlistFails() throws {
        _ = isolatedDomain()
        Settings.setString("/tmp/keep", Settings.Key.panelPath(0))
        XCTAssertFalse(Settings.replaceDomainContents(
            fromPlistAt: scratch.appendingPathComponent("nope.plist").path))
        let notADictionary = scratch.appendingPathComponent("array.plist")
        try (["a", "b"] as NSArray).write(to: notADictionary)
        XCTAssertFalse(Settings.replaceDomainContents(fromPlistAt: notADictionary.path))
        // A failed replacement leaves the domain alone rather than emptying it.
        XCTAssertEqual(Settings.panelPath(0), "/tmp/keep")
    }

    /// The engine side reads the same domain through `ZipRegistryMac`, so a replaced domain has to
    /// reach it too -- that is what makes `defaults=` cover `Extraction.*` / `Options.*` as well.
    func testReplacedDomainReachesTheEngineAccessors() throws {
        _ = isolatedDomain()
        Settings.replaceDomainContents(with: [Settings.Key.workDirType: 2,
                                              Settings.Key.workDirPath: "/tmp/work-from-plist",
                                              Settings.Key.tempRemovableOnly: false])
        let info = SZWorkDirSettings.loadFromSettings()
        XCTAssertEqual(info.mode, .specified)
        XCTAssertEqual(info.path, "/tmp/work-from-plist")
        XCTAssertFalse(info.forRemovableOnly)
    }

    /// After a wholesale replacement no observer can know which keys moved, so every group is told
    /// to re-read. The panels and the window controller listen to exactly these names.
    func testNotifyAllGroupsPostsEveryGroup() {
        var seen = Set<String>()
        var observers: [NSObjectProtocol] = []
        let groups: [Settings.Group] = [.language, .editor, .fm, .view, .extraction, .compression,
                                        .workDir, .contextMenu]
        for group in groups {
            observers.append(NotificationCenter.default.addObserver(
                forName: group.notificationName, object: nil, queue: nil) { _ in
                    seen.insert(group.rawValue)
                })
        }
        var generalCount = 0
        observers.append(NotificationCenter.default.addObserver(
            forName: Settings.didChangeNotification, object: nil, queue: nil) { _ in
                generalCount += 1
            })
        defer { observers.forEach(NotificationCenter.default.removeObserver(_:)) }

        Settings.notifyAllGroups()
        XCTAssertEqual(seen, Set(groups.map(\.rawValue)))
        XCTAssertEqual(generalCount, groups.count)
    }

    /// The language half of the reload. `Lang.loadFromSettings()` (the app target, not compiled
    /// into this bundle) is two lines: read the `Lang` key from the domain and hand it to
    /// `SZLang.loadLanguage(code:)`. Both halves are asserted here -- that a replaced domain
    /// carries the code the reset asked for, and that the bridge accepts it -- so the only thing
    /// left uncovered is the wrapper itself, which the UI test exercises end to end.
    func testLanguageReloadFollowsTheSettingsKey() throws {
        _ = isolatedDomain()
        Settings.replaceDomainContents(with: [Settings.Key.lang: "-"])
        XCTAssertEqual(Settings.language, "-")                   // built-in English
        XCTAssertEqual(SZSettings.string(forKey: SZSettingsKeyLang), "-")

        try SZLang.shared.loadLanguage(code: Settings.language)
        let english = SZLang.shared.string(forID: 401, fallback: "OK")
        XCTAssertFalse(english.isEmpty)

        // `lang=` writes the key the same way the Options > Language page does.
        Settings.language = "no-such-language"
        XCTAssertEqual(SZSettings.string(forKey: SZSettingsKeyLang), "no-such-language")
        // A language file that does not exist is reported, and the table is left usable -- which is
        // why `Lang.loadFromSettings()` only logs.
        XCTAssertThrowsError(try SZLang.shared.loadLanguage(code: Settings.language))
        XCTAssertFalse(SZLang.shared.string(forID: 401, fallback: "OK").isEmpty)

        Settings.language = "-"
        try SZLang.shared.loadLanguage(code: Settings.language)
        XCTAssertEqual(SZLang.shared.string(forID: 401, fallback: "OK"), english)
    }
}
