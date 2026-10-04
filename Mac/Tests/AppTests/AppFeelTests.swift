// AppFeelTests.swift -- appfeel (Mac/docs/reports/appfeel.md), in process:
//
//  1. a reopen Apple event from the Dock shows the open windows, one from anywhere else opens a new
//     window, and one with no sender falls back to showing (user request 7);
//  2. Options > 7-Zip > "Integrate 7-Zip to shell context menu" (IDX_SYSTEM_INTEGRATE_TO_MENU 2301,
//     01b §4.13) reflects whether Finder uses *this* copy's extension and Apply switches it
//     (user request 16).
//
// PlugInKit is never touched for real here: `FinderExtensionControl.runner` is a fake database
// for the whole class, so the machine's election and registrations stay as they are. The real Dock
// click is in `Mac/Tests/UITests/NewWindowUITests.swift`.

import AppKit
import XCTest
@testable import SevenZipAppHost

/// A stand-in for `pluginkit`: registered copies and one election for the identifier. Which copy
/// Finder runs is not steerable on the real system except by removing the others, so the fake
/// reports the *first* registered copy as the active one -- a claim that only re-added its own copy
/// would fail here, as it did on the real machine.
final class FakePluginKit {
    private let lock = NSLock()
    private var _copies: [String] = []
    private var _election: Character = " "
    private var _calls: [[String]] = []

    var copies: [String] { lock.withLock { _copies } }
    var calls: [[String]] { lock.withLock { _calls } }
    var election: Character { lock.withLock { _election } }

    init(copies: [String], election: Character) {
        _copies = copies
        _election = election
    }

    func run(_ arguments: [String]) -> (status: Int32, output: String) {
        lock.withLock {
            _calls.append(arguments)
            switch arguments.first {
            case "-m":
                let listed = arguments.contains("-D") ? _copies : Array(_copies.prefix(1))
                let lines = listed.map {
                    "\(_election)    \(FinderExtensionControl.identifier)(26.03)\t00000000-0000-0000-0000-000000000000\t2026-10-04 00:00:00 +0000\t\($0)"
                }
                return (0, (lines + [" (\(listed.count) plug-ins)"]).joined(separator: "\n") + "\n")
            case "-a":
                if !_copies.contains(arguments[1]) { _copies.append(arguments[1]) }
            case "-r":
                _copies.removeAll { $0 == arguments[1] }
            case "-e":
                _election = arguments[1] == "use" ? "+" : "-"
            default:
                return (1, "")
            }
            return (0, "")
        }
    }
}

final class AppFeelTests: AppHostTestCase {

    override var screenshotPrefix: String { "appfeel" }

    private var delegate: AppDelegate { NSApp.delegate as! AppDelegate }
    private var before: [MainWindowController] = []
    private var savedRunner: ((_ arguments: [String]) -> (status: Int32, output: String))?
    private var scratch = ""
    private var savedPaths: [String?] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        before = MainWindows.controllers
        savedPaths = [Settings.panelPath(0), Settings.panelPath(1)]
        savedRunner = FinderExtensionControl.runner
        // Never the real pluginkit in this class.
        FinderExtensionControl.runner = { _ in XCTFail("pluginkit called without a fake"); return (1, "") }
        scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("appfeel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        for controller in MainWindows.controllers where !before.contains(where: { $0 === controller }) {
            controller.window?.close()
        }
        for controller in MainWindows.controllers where controller.window?.isMiniaturized == true {
            controller.window?.deminiaturize(nil)
        }
        Settings.setPanelPath(savedPaths[0], 0)
        Settings.setPanelPath(savedPaths[1], 1)
        if let savedRunner { FinderExtensionControl.runner = savedRunner }
        try? FileManager.default.removeItem(atPath: scratch)
        super.tearDown()
    }

    private var added: [MainWindowController] {
        MainWindows.controllers.filter { c in !before.contains { $0 === c } }
    }

    // MARK: - 1. reopen: who sent it

    func testReopenSenderClassification() {
        let own = getpid()
        XCTAssertEqual(ReopenSender.classify(nil, ownPID: own), .unknown, "no current event")
        XCTAssertEqual(ReopenSender.classify(.init(pid: 0), ownPID: own), .unknown, "no sender pid")
        XCTAssertEqual(ReopenSender.classify(.init(pid: own, bundleIdentifier: "com.yrambler2001.7zip"), ownPID: own),
                       .unknown, "the app itself")
        XCTAssertEqual(ReopenSender.classify(.init(pid: 99, bundleIdentifier: "com.apple.dock",
                                                   executablePath: ReopenSender.dockExecutablePath), ownPID: own), .dock)
        XCTAssertEqual(ReopenSender.classify(.init(pid: 99, executablePath: ReopenSender.dockExecutablePath), ownPID: own),
                       .dock, "the Dock recognised by its executable alone")
        XCTAssertEqual(ReopenSender.classify(.init(pid: 99, bundleIdentifier: "com.apple.finder"), ownPID: own),
                       .launcher("com.apple.finder"))
        XCTAssertEqual(ReopenSender.classify(.init(pid: 99, bundleIdentifier: "com.apple.Spotlight"), ownPID: own),
                       .launcher("com.apple.Spotlight"))
        XCTAssertEqual(ReopenSender.classify(.init(pid: 99, executablePath: "/usr/bin/open"), ownPID: own),
                       .launcher("/usr/bin/open"))
        // `open -a` exits before the event is handled (measured): not the Dock, so a launcher.
        XCTAssertEqual(ReopenSender.classify(.init(pid: 99), ownPID: own), .launcher("exited process 99"))
        // Outside an Apple event there is no sender at all.
        XCTAssertNil(ReopenSender.current())
    }

    /// A launch of the running app (Finder, Spotlight, `open -a`): a new window.
    func testReopenFromALauncherOpensANewWindow() {
        XCTAssertFalse(delegate.handleReopen(from: .launcher("com.apple.finder")))
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(added.first?.window?.isVisible ?? false)
    }

    /// A Dock click with a window on screen: no new window, and AppKit's own handling is off.
    func testReopenFromTheDockOpensNoWindow() {
        let visibleBefore = MainWindows.controllers.filter { $0.window?.isVisible == true }.count
        XCTAssertGreaterThan(visibleBefore, 0, "the host shows its window")
        XCTAssertFalse(delegate.handleReopen(from: .dock))
        XCTAssertEqual(added.count, 0, "a Dock click must not open a window")
    }

    /// No identifiable sender -- here the delegate is called with no Apple event, as AppKit never
    /// does -- falls back to the Dock's behaviour.
    func testReopenWithoutASenderOpensNoWindow() {
        XCTAssertFalse(delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
        XCTAssertEqual(added.count, 0)
    }

    /// A Dock click with every window minimized brings the most recent one back instead of opening
    /// one, as every Mac app does.
    func testReopenFromTheDockRestoresAMinimizedWindow() throws {
        let window = try XCTUnwrap(MainWindows.open().window)
        let count = MainWindows.controllers.count
        for controller in MainWindows.controllers { controller.window?.miniaturize(nil) }
        XCTAssertTrue(wait(for: "every window minimized") {
            MainWindows.controllers.allSatisfy { $0.window?.isMiniaturized == true }
        })
        XCTAssertFalse(delegate.handleReopen(from: .dock))
        XCTAssertTrue(wait(for: "one window back") {
            MainWindows.controllers.contains { $0.window?.isMiniaturized == false && $0.window?.isVisible == true }
        }, "the Dock click restored nothing")
        XCTAssertEqual(MainWindows.controllers.count, count, "restored, not opened")
        _ = window
    }

    // MARK: - 2. the Finder extension

    private func makeAppex(_ name: String) throws -> String {
        let path = scratch + "/\(name).app/Contents/PlugIns/FinderSync.appex"
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return FinderExtensionControl.canonical(path)
    }

    /// The four-copy listing measured on this machine (`pluginkit -m -D -A -v -i …`), and the line
    /// the user reported.
    func testPluginkitOutputIsParsed() {
        let output = """
        +    com.yrambler2001.7zip.FinderSync(26.03)\tE33C42AC-9E69-461E-8379-C98FAB431584\t2026-10-04 02:21:30 +0000\t/a/Debug/7-Zip.app/Contents/PlugIns/FinderSync.appex
        -    com.yrambler2001.7zip.FinderSync(26.03)\t5A9DAFA2-11B4-4A7E-86C4-E4ADA6618D8F\t2026-10-03 23:39:09 +0000\t/b/Release/7-Zip.app/Contents/PlugIns/FinderSync.appex
        !    com.yrambler2001.7zip.FinderSync(26.04)\t947800A6-8BEF-4887-9AB1-CD818F0BDA4A\t2026-10-03 23:16:02 +0000\t/c d/7-Zip.app/Contents/PlugIns/FinderSync.appex
        +    com.other.FinderSync(1.0)\t947800A6-8BEF-4887-9AB1-CD818F0BDA4B\t2026-10-03 23:16:02 +0000\t/x/Other.app/Contents/PlugIns/FinderSync.appex
         (4 plug-ins)
        """
        let parsed = FinderExtensionControl.parse(output)
        XCTAssertEqual(parsed.map(\.election), ["+", "-", "!"])
        XCTAssertEqual(parsed.map(\.version), ["26.03", "26.03", "26.04"])
        XCTAssertEqual(parsed[2].path, "/c d/7-Zip.app/Contents/PlugIns/FinderSync.appex", "a path with a space")
        XCTAssertEqual(parsed.map(\.isEnabled), [true, false, true])
        XCTAssertTrue(FinderExtensionControl.parse(" (0 plug-ins)\n").isEmpty)
    }

    func testStateIsAboutThisCopy() throws {
        let mine = try makeAppex("Mine")
        let other = try makeAppex("Other")
        typealias R = FinderExtensionControl.Registration
        XCTAssertEqual(FinderExtensionControl.state(active: nil, embeddedPath: nil), .notEmbedded)
        XCTAssertEqual(FinderExtensionControl.state(active: nil, embeddedPath: mine), .notRegistered)
        XCTAssertEqual(FinderExtensionControl.state(active: R(election: "+", version: "", path: mine), embeddedPath: mine), .enabled)
        XCTAssertEqual(FinderExtensionControl.state(active: R(election: "-", version: "", path: mine), embeddedPath: mine), .disabled)
        XCTAssertEqual(FinderExtensionControl.state(active: R(election: "+", version: "", path: other), embeddedPath: mine),
                       .otherCopy(path: other, enabled: true),
                       "the user's report: enabled, but for another copy -- the box must not claim it")
        // A symlinked path (Mac/build/Debug/7-Zip.app -> DerivedData) is the same copy.
        let link = scratch + "/Link.app"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: scratch + "/Mine.app")
        XCTAssertEqual(FinderExtensionControl.state(active: R(election: "+", version: "", path: mine),
                                                    embeddedPath: link + "/Contents/PlugIns/FinderSync.appex"), .enabled)
    }

    /// Enabling: every other copy's registration (deleted or not) is removed, so this copy is the
    /// one Finder runs, and use is elected. Disabling: ignore is elected, the registrations stay.
    func testEnableClaimsThisCopyAndDisableElectsIgnore() throws {
        let mine = try makeAppex("Mine")
        let other = try makeAppex("Other")
        let gone = scratch + "/Gone.app/Contents/PlugIns/FinderSync.appex"
        let fake = FakePluginKit(copies: [other, gone, mine], election: "-")
        FinderExtensionControl.runner = fake.run
        XCTAssertEqual(FinderExtensionControl.currentState(embeddedPath: mine), .otherCopy(path: other, enabled: false))

        XCTAssertEqual(FinderExtensionControl.setEnabled(true, embeddedPath: mine), .enabled)
        XCTAssertEqual(fake.copies, [mine], "only this copy stays registered")
        XCTAssertTrue(fake.calls.contains(["-r", gone]))
        XCTAssertTrue(fake.calls.contains(["-r", other]))
        XCTAssertFalse(fake.calls.contains(["-r", mine]), "this copy is never removed")
        XCTAssertTrue(fake.calls.contains(["-e", "use", "-i", FinderExtensionControl.identifier]))

        XCTAssertEqual(FinderExtensionControl.setEnabled(false, embeddedPath: mine), .disabled)
        XCTAssertEqual(fake.election, "-")
        XCTAssertEqual(fake.copies, [mine])
        XCTAssertEqual(FinderExtensionControl.setEnabled(true, embeddedPath: nil), .notEmbedded)
    }

    /// An election that does not take (MDM, a future system): the state is reported as it is, so
    /// the page can say so and offer System Settings.
    func testAnElectionThatDoesNotTakeIsReported() throws {
        let mine = try makeAppex("Mine")
        let fake = FakePluginKit(copies: [mine], election: "-")
        FinderExtensionControl.runner = { arguments in
            arguments.first == "-e" ? (1, "") : fake.run(arguments)
        }
        XCTAssertEqual(FinderExtensionControl.setEnabled(true, embeddedPath: mine, timeout: 0.5), .disabled)
    }

    /// Test instances (and copies without the appex, like this host) never claim at launch.
    func testTestInstancesDoNotClaimAtLaunch() {
        FinderExtensionControl.claimAtLaunchIfNeeded()     // the fake runner fails on any call
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    // MARK: - the Options page

    private func integrateBox(in page: OptionsMenuPage) throws -> NSButton {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return try XCTUnwrap(all(page.view).compactMap { $0 as? NSButton }
            .first { $0.title == Lang.text(2301, "Integrate 7-Zip to shell context menu") })
    }

    private func loadedPage(embedded: String?) throws -> (OptionsMenuPage, NSButton) {
        let page = OptionsMenuPage()
        page.embeddedAppexPath = embedded
        _ = page.view
        page.pageDidLoad()
        let box = try integrateBox(in: page)
        XCTAssertTrue(wait(for: "the pluginkit answer") { page.finderExtensionState != nil })
        return (page, box)
    }

    /// The test copies carry no appex: the box is disabled, as MenuPage.cpp disables it when
    /// 7-zip.dll is missing. (This is also why the box was grey before: it was always disabled.)
    func testBoxIsDisabledWithoutAnEmbeddedExtension() throws {
        XCTAssertNil(FinderExtensionControl.embeddedAppexPath, "the host app has no FinderSync.appex")
        let (page, box) = try loadedPage(embedded: nil)
        XCTAssertFalse(box.isEnabled)
        XCTAssertEqual(page.finderExtensionState, .notEmbedded)
    }

    /// Checked only for this copy; clicking marks the page changed; Apply switches it and the box
    /// follows the real state.
    func testBoxReflectsThisCopyAndApplySwitchesIt() throws {
        let mine = try makeAppex("Mine")
        let other = try makeAppex("Other")
        let fake = FakePluginKit(copies: [other, mine], election: "+")
        FinderExtensionControl.runner = fake.run

        let (page, box) = try loadedPage(embedded: mine)
        XCTAssertTrue(box.isEnabled)
        XCTAssertEqual(box.state, .off, "enabled for another copy is not enabled for this one")
        XCTAssertEqual(page.finderExtensionState, .otherCopy(path: other, enabled: true))

        box.performClick(nil)
        XCTAssertEqual(box.state, .on)
        XCTAssertTrue(page.pageIsChanged, "the click enables Apply")
        XCTAssertFalse(fake.calls.contains { $0.first == "-e" }, "nothing changes before Apply")
        var done = false
        page.applyIntegrationForTesting { done = true }
        XCTAssertTrue(wait(for: "Apply") { done })
        XCTAssertEqual(page.finderExtensionState, .enabled)
        XCTAssertEqual(box.state, .on)
        XCTAssertEqual(fake.copies, [mine])

        box.performClick(nil)
        XCTAssertEqual(box.state, .off)
        done = false
        page.applyIntegrationForTesting { done = true }
        XCTAssertTrue(wait(for: "Apply") { done })
        XCTAssertEqual(page.finderExtensionState, .disabled)
        XCTAssertEqual(fake.election, "-")
        XCTAssertEqual(box.state, .off)
    }
}
