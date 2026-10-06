// NewWindowUITests.swift -- the real input paths of "starting 7-Zip again opens a new 7-Zip File
// Manager window" and "an archive opened from Finder gets its own window" (user decisions,
// Mac/docs/reports/newwindow.md; 01 §1.1 "Single instance", 03 §6.2).
//
// A Dock click, a Finder double-click of 7-Zip.app and `open -a 7-Zip` all reach a running app as
// the *reopen* Apple event, which Launch Services sends when it is asked to open an application
// that is already running: `NSWorkspace.openApplication(at:)` aimed at this shard's bundle is
// exactly that request, sent by the test runner -- i.e. a launch, which opens a window. A Dock
// click is the same event sent by the Dock, which only shows the open windows (appfeel); those
// cases click the real Dock tile. A Finder double-click of an archive is the *open documents* event:
// `NSWorkspace.open(_:withApplicationAt:)`. Neither drives another application, so no Automation
// consent is involved (Mac/docs/reports/vmcheck.md). The in-process half of the same cases is
// `Mac/Tests/AppTests/NewWindowTests.swift`.

import AppKit
import XCTest

final class NewWindowUITests: SevenZipUITestCase {

    override var screenshotPrefix: String { "newwindow" }

    // MARK: - helpers

    /// The file-manager windows: their title is the focused panel's path (CApp::RefreshTitle).
    private var managerWindows: XCUIElementQuery {
        app.windows.matching(NSPredicate(format: "title BEGINSWITH '/'"))
    }

    private func waitForManagerWindows(_ count: Int, timeout: TimeInterval = 20) -> Bool {
        waitFor("\(count) file-manager windows", timeout: timeout) { managerWindows.count == count }
    }

    private func appURL() throws -> URL {
        try XCTUnwrap(TestShard.appURL, "cannot find this shard's 7-Zip.app")
    }

    /// Blocks until Launch Services has delivered the request; false on an error.
    private func deliver(_ body: (@escaping (Error?) -> Void) -> Void) -> Bool {
        var outcome: Error??
        body { outcome = .some($0) }
        let deadline = Date().addingTimeInterval(20)
        while outcome == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        if let error = outcome ?? nil { XCTFail("Launch Services refused: \(error)") }
        return outcome != nil && (outcome ?? nil) == nil
    }

    /// "Open the application" while it runs, from the test runner: the reopen event of a launch
    /// from Finder / Spotlight / `open -a` (its sender is not the Dock).
    private func sendReopen() throws -> Bool {
        let url = try appURL()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        return deliver { done in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in done(error) }
        }
    }

    /// A Finder double-click of `files`: the open-documents event, aimed at this shard's bundle.
    private func sendOpen(_ files: [String], environment: [String: String] = [:]) throws -> Bool {
        let url = try appURL()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        configuration.environment = environment
        return deliver { done in
            NSWorkspace.shared.open(files.map { URL(fileURLWithPath: $0) }, withApplicationAt: url,
                                    configuration: configuration) { _, error in done(error) }
        }
    }

    // MARK: - re-launch of the running app

    /// Reopen with a window open: a second window, the first one untouched.
    func testReopenWithAWindowOpenOpensAnotherWindow() throws {
        launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]))
        XCTAssertTrue(waitForManagerWindows(1))
        XCTAssertTrue(try sendReopen())
        XCTAssertTrue(waitForManagerWindows(2), "a reopen must open a new window, found \(managerWindows.count)")
        // Both start at the saved path, as two 7zFM launches would.
        let titles = managerWindows.allElementsBoundByIndex.map(\.title)
        XCTAssertEqual(titles.filter { $0.hasPrefix(TestPaths.fixtures) }.count, 2, "\(titles)")
        screenshot("01-reopen-second-window")
        XCTAssertTrue(try sendReopen())
        XCTAssertTrue(waitForManagerWindows(3))
    }

    /// Reopen with no visible window (the only one minimized): a window appears.
    func testReopenWithNoVisibleWindowOpensOne() throws {
        launch()
        XCTAssertTrue(waitForManagerWindows(1))
        XCTAssertTrue(sevenZip.selectMenuItem("Window", "Minimize"))
        XCTAssertTrue(waitFor("the window minimized") {
            !self.managerWindows.allElementsBoundByIndex.contains { $0.isHittable }
        }, "the window did not minimize")
        XCTAssertTrue(try sendReopen())
        XCTAssertTrue(waitFor("a visible file-manager window") {
            self.managerWindows.allElementsBoundByIndex.contains { $0.isHittable }
        }, "no visible window after the reopen")
        // Un-minimizing the window (AppKit's own reaction to a reopen) would leave one window; a
        // new one makes two. The Window menu lists every window, minimized ones included.
        let listed = sevenZip.itemTitles(in: "Window").filter { $0.hasPrefix("/") }
        sevenZip.closeOpenMenus()
        XCTAssertEqual(listed.count, 2, "the reopen must open a new window, not un-minimize: \(listed)")
        screenshot("05-reopen-after-minimize")
    }

    // MARK: - a Dock click (appfeel, user request 7)

    /// This app's tile in the Dock, found through the Dock's own accessibility tree (no Automation
    /// consent: XCUITest reads and clicks other apps' elements as the test runner).
    ///
    /// testreg: a Dock can show **two** "7-Zip" tiles -- the user's installed copy in the
    /// persistent or recent-applications section, and this build's running one -- and the installed
    /// copy's came first: clicking it launched /Applications/7-Zip.app (measured; that was the
    /// `testDockClickRestoresTheMinimizedWindow` failure). XCUITest exposes neither a tile's AXURL
    /// nor its running indicator, the sandboxed runner may not read the accessibility API itself
    /// (measured: it may not), and a tile's Dock menu was no reliable tell either (opening the
    /// installed copy's and pressing Escape still launched it). So with more than one tile of that
    /// name the test is skipped rather than click a tile that may start another 7-Zip.
    private func dockTile() throws -> XCUIElement {
        let dock = XCUIApplication(bundleIdentifier: "com.apple.dock")
        let name = (try appURL()).deletingPathExtension().lastPathComponent
        // A Dock tile is an AXDockItem, which XCUITest reports as `.dockItem`.
        let query = dock.descendants(matching: .dockItem).matching(NSPredicate(format: "title == %@", name))
        guard query.firstMatch.waitForExistence(timeout: 10) else {
            let all = dock.descendants(matching: .any).allElementsBoundByIndex.prefix(40)
                .map { "\($0.elementType.rawValue):\($0.title)" }
            throw XCTSkip("no Dock tile titled \(name) (Dock elements: \(all))")
        }
        let count = query.count
        guard count == 1 else {
            throw XCTSkip("the Dock shows \(count) tiles titled \(name) (an installed 7-Zip is kept or "
                          + "recent in the Dock); not clicking one that may launch it")
        }
        return query.firstMatch
    }

    /// A click on the Dock tile sends the reopen event from the Dock: the open window is shown,
    /// and no new window is opened (a launch from Finder / Spotlight / `open -a` still opens one,
    /// `testReopenWithAWindowOpenOpensAnotherWindow`).
    func testDockClickShowsTheOpenWindowInsteadOfOpeningOne() throws {
        launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]))
        XCTAssertTrue(waitForManagerWindows(1))
        try dockTile().click()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(managerWindows.count, 1, "a Dock click must not open a window")
        XCTAssertTrue(waitFor("the app in front") { self.app.state == .runningForeground })
        screenshot("06-dock-click-shows-window")
    }

    /// With the only window minimized, a Dock click brings it back -- one window, on screen -- as
    /// every Mac app does.
    func testDockClickRestoresTheMinimizedWindow() throws {
        launch()
        XCTAssertTrue(waitForManagerWindows(1))
        XCTAssertTrue(sevenZip.selectMenuItem("Window", "Minimize"))
        XCTAssertTrue(waitFor("the window minimized") {
            !self.managerWindows.allElementsBoundByIndex.contains { $0.isHittable }
        }, "the window did not minimize")
        try dockTile().click()
        XCTAssertTrue(waitFor("the window back on screen") {
            self.managerWindows.allElementsBoundByIndex.contains { $0.isHittable }
        }, "a Dock click must restore the minimized window")
        let listed = sevenZip.itemTitles(in: "Window").filter { $0.hasPrefix("/") }
        sevenZip.closeOpenMenus()
        XCTAssertEqual(listed.count, 1, "a Dock click must restore, not open a window: \(listed)")
        screenshot("07-dock-click-restores")
    }

    /// A double-click on 7-Zip.app in a Finder window while the app runs: the reopen event comes
    /// from Finder, i.e. a launch, which opens a new window (the Dock's sender would not). The
    /// Finder window is opened with Launch Services and driven through its accessibility tree.
    func testFinderDoubleClickOfTheAppOpensANewWindow() throws {
        launch()
        XCTAssertTrue(waitForManagerWindows(1))
        let bundle = try appURL()
        let name = bundle.deletingPathExtension().lastPathComponent
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.addsToRecentItems = false
        let finderURL = try XCTUnwrap(NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"))
        XCTAssertTrue(deliver { done in
            NSWorkspace.shared.open([bundle.deletingLastPathComponent()], withApplicationAt: finderURL,
                                    configuration: configuration) { _, error in done(error) }
        })
        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        let folderWindow = finder.windows.matching(NSPredicate(format: "title == %@",
                                                               bundle.deletingLastPathComponent().lastPathComponent)).firstMatch
        guard folderWindow.waitForExistence(timeout: 15) else { throw XCTSkip("no Finder window for the build folder") }
        defer { folderWindow.typeKey("w", modifierFlags: .command) }
        let names = [name, name + ".app"]
        let item = folderWindow.descendants(matching: .any)
            .matching(NSPredicate(format: "(value IN %@ OR title IN %@) AND elementType != %d",
                                  names, names, XCUIElement.ElementType.window.rawValue)).firstMatch
        guard item.waitForExistence(timeout: 15) else { throw XCTSkip("\(name) not found in the Finder window") }
        item.doubleClick()
        XCTAssertTrue(waitForManagerWindows(2), "a launch from Finder must open a window, found \(managerWindows.count)")
        screenshot("08-finder-double-click-new-window")
    }

    // MARK: - File > New Window

    /// The key equivalent (Option+Cmd+N; Cmd+N stays Create File, IDM_CREATE_FILE Ctrl+N) and the
    /// menu item each open a window.
    func testNewWindowShortcutAndMenuItem() {
        launch()
        XCTAssertTrue(waitForManagerWindows(1))
        sevenZip.panel(0).focusList()
        app.typeKey("n", modifierFlags: [.command, .option])
        XCTAssertTrue(waitForManagerWindows(2), "Option+Cmd+N must open a window")
        XCTAssertTrue(sevenZip.selectMenuItem("File", "New Window"))
        XCTAssertTrue(waitForManagerWindows(3), "File > New Window must open a window")
        screenshot("02-new-window")
    }

    // MARK: - an archive opened from Finder

    /// The running app is handed an archive: it opens in a window of its own and the window that
    /// was open keeps its folder.
    func testArchiveFromFinderGetsItsOwnWindow() throws {
        launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]))
        XCTAssertTrue(waitForManagerWindows(1))
        XCTAssertTrue(try sendOpen([TestPaths.fixture("test.7z")]))
        XCTAssertTrue(waitForManagerWindows(2), "the archive must open in a new window")
        XCTAssertTrue(waitFor("the archive window") {
            self.managerWindows.allElementsBoundByIndex.contains { $0.title.contains("test.7z") }
        })
        let titles = managerWindows.allElementsBoundByIndex.map(\.title)
        XCTAssertTrue(titles.contains { !$0.contains("test.7z") && $0.hasPrefix(TestPaths.fixtures) },
                      "the first window must keep its folder: \(titles)")
        screenshot("03-archive-own-window")
    }

    /// A fresh process asked to open an archive gets a window that shows it, and nothing replaces
    /// it. `XCUIApplication.open(_:)` launches the app and then hands it the file, usually *after*
    /// `applicationDidFinishLaunching` (measured: 4 runs in 5) -- which is a launch followed by a
    /// Finder open, so the launch window stays and the archive gets its own. A real Finder
    /// double-click delivers the file *before* it, and then the launch window is never created
    /// (measured with `open -a`, and `NewWindowTests.testColdLaunchForDocumentsAddsNoDefaultWindow`).
    func testArchiveOpenedIntoAFreshProcessGetsItsOwnWindow() throws {
        sevenZip.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 20))
        let seed = try SettingsSeedFile.make(name: "newwindow-cold", values: SettingsSeed.clean.preferences ?? [:])
        addTeardownBlock { seed.remove() }
        var environment = TestShard.environment(for: NSStringFromClass(Self.self))
        environment.merge(seed.launchEnvironment) { _, new in new }
        environment["SEVENZIP_UITEST"] = "1"
        app.launchArguments = []
        app.launchEnvironment = environment
        app.open(URL(fileURLWithPath: TestPaths.fixture("test.7z")))
        XCTAssertTrue(waitFor("the archive window", timeout: 60) {
            self.managerWindows.allElementsBoundByIndex.contains { $0.title.contains("test.7z") }
        }, "no window shows the archive")
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let titles = managerWindows.allElementsBoundByIndex.map(\.title)
        XCTAssertEqual(titles.filter { $0.contains("test.7z") }.count, 1, "\(titles)")
        XCTAssertLessThanOrEqual(titles.count, 2, "at most the launch window besides the archive's: \(titles)")
        screenshot("04-fresh-process-archive")
        sevenZip.terminate()
    }
}
