// NewWindowTests.swift -- "starting 7-Zip again opens a new 7-Zip File Manager window" and "an
// archive opened from Finder gets its own window" (user decisions, Mac/docs/reports/newwindow.md;
// 01 §1.1 "Single instance", 03 §6.2), in process.
//
// The entry points are called exactly as AppKit calls them: the reopen Apple event ends in
// `applicationShouldHandleReopen(_:hasVisibleWindows:)`, a Finder open in `application(_:open:)`,
// File > New Window is the menu item's own action sent down the responder chain. The real input
// paths (an aimed reopen / odoc from another process, the key equivalent) are covered by
// `Mac/Tests/UITests/NewWindowUITests.swift`.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class NewWindowTests: AppHostTestCase {

    override var screenshotPrefix: String { "newwindow" }

    private var before: [MainWindowController] = []
    private var savedPaths: [String?] = []
    private var savedNumPanels = 1
    private var savedCurrentPanel = 0
    private var savedFrame: String?
    private var savedMaximized = false
    private var savedSplitter = 0.5
    private var scratch = ""

    private var delegate: AppDelegate { NSApp.delegate as! AppDelegate }

    override func setUpWithError() throws {
        try super.setUpWithError()
        before = MainWindows.controllers
        savedPaths = [Settings.panelPath(0), Settings.panelPath(1)]
        savedNumPanels = Settings.numPanels
        savedCurrentPanel = Settings.currentPanel
        savedFrame = Settings.windowFrame
        savedMaximized = Settings.maximized
        savedSplitter = Settings.splitterPos
        scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("newwindow-\(UUID().uuidString)")
        for name in ["a", "b"] {
            try FileManager.default.createDirectory(atPath: scratch + "/" + name, withIntermediateDirectories: true)
        }
    }

    override func tearDown() {
        // Every window a test opened is closed; the host's own window stays.
        for controller in MainWindows.controllers where !before.contains(where: { $0 === controller }) {
            controller.window?.close()
        }
        wait(for: "closed windows released") { true }
        // A closing window saves its state, as on Windows; put the host's settings back.
        Settings.setPanelPath(savedPaths[0], 0)
        Settings.setPanelPath(savedPaths[1], 1)
        Settings.numPanels = savedNumPanels
        Settings.currentPanel = savedCurrentPanel
        Settings.windowFrame = savedFrame
        Settings.maximized = savedMaximized
        Settings.splitterPos = savedSplitter
        try? FileManager.default.removeItem(atPath: scratch)
        super.tearDown()
    }

    // MARK: - helpers

    private var added: [MainWindowController] {
        MainWindows.controllers.filter { c in !before.contains { $0 === c } }
    }

    private func navigate(_ panel: PanelViewController, to path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
    }

    /// `PanelPath0` as stored (a folder is saved with its trailing separator), without it.
    private var savedPath0: String? {
        Settings.panelPath(0).map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
    }

    private func fileMenuItem(_ selector: Selector) -> NSMenuItem? {
        let file = NSApp.mainMenu?.items.first { $0.submenu?.title == "File" }?.submenu
        return file?.items.first { $0.action == selector }
    }

    // MARK: - re-launch of the running app (reopen Apple event)

    /// Dock click / Finder double-click / `open -a` while windows are open: one more window, and
    /// AppKit's default reaction is suppressed (false).
    func testReopenWithWindowsOpenOpensAnotherWindow() throws {
        Settings.setPanelPath(scratch + "/a", 0)
        let handled = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        XCTAssertFalse(handled, "AppKit must not also un-minimize or activate a window of its own")
        XCTAssertEqual(added.count, 1, "a reopen with windows open must open exactly one more window")
        let window = try XCTUnwrap(added.first?.window)
        XCTAssertTrue(window.isVisible)
        // It starts where a fresh 7zFM launch starts: the saved panel path.
        let panel = try XCTUnwrap(added.first?.focusedPanel)
        XCTAssertTrue(wait(for: "the saved path") { panel.currentPath.hasPrefix(self.scratch + "/a") },
                      "the new window shows \(panel.currentPath)")
        // Two reopens, two more windows.
        _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true)
        XCTAssertEqual(added.count, 2)
    }

    /// Dock click with no visible window (every window minimized; with none at all the app has
    /// already quit, as 7zFM's process ends with its window): a window appears.
    func testReopenWithNoVisibleWindowOpensOne() throws {
        let handled = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
        XCTAssertFalse(handled)
        XCTAssertEqual(added.count, 1)
        XCTAssertTrue(added.first?.window?.isVisible ?? false, "the new window is on screen")
    }

    // MARK: - File > New Window (macOS addition)

    /// The item exists, sits first in File, has Option+Cmd+N (Cmd+N stays IDM_CREATE_FILE's
    /// Ctrl+N), and sending its action opens a window cascaded off the front one.
    func testNewWindowMenuItemOpensACascadedWindow() throws {
        let item = try XCTUnwrap(fileMenuItem(#selector(MenuActions.fileNewWindow(_:))), "no File > New Window")
        XCTAssertEqual(item.title, "New Window")
        XCTAssertEqual(item.keyEquivalent, "n")
        XCTAssertEqual(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command, .option])
        XCTAssertTrue(item.menu?.items.first === item, "New Window is the first item of File")
        let createFile = try XCTUnwrap(fileMenuItem(#selector(MenuActions.fileCreateFile(_:))))
        XCTAssertEqual(createFile.keyEquivalent, "n")
        XCTAssertEqual(createFile.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask), [.command])

        let front = MainWindows.frontToBack.first?.window
        XCTAssertTrue(NSApp.sendAction(item.action!, to: nil, from: item), "nobody handles New Window")
        XCTAssertEqual(added.count, 1)
        let window = try XCTUnwrap(added.first?.window)
        XCTAssertTrue(window.isVisible)
        if let front, front.isVisible {
            XCTAssertNotEqual(window.frame.origin, front.frame.origin,
                              "the new window must not sit exactly on the one it was opened from")
        }
        attach(window, "10-hosted-new-window")
    }

    /// Each window starts from the settings as a fresh 7zFM launch does (CApp::Create): panel count
    /// and both panel paths.
    func testNewWindowStartsFromTheSavedSettings() throws {
        Settings.numPanels = 2
        Settings.currentPanel = 1
        Settings.setPanelPath(scratch + "/a", 0)
        Settings.setPanelPath(scratch + "/b", 1)
        let controller = delegate.openNewWindow()
        XCTAssertEqual(controller.numPanels, 2)
        XCTAssertEqual(controller.focusedPanelIndex, 1)
        XCTAssertTrue(wait(for: "both saved paths") {
            controller.panels.count == 2
                && controller.panels[0].currentPath.hasPrefix(self.scratch + "/a")
                && controller.panels[1].currentPath.hasPrefix(self.scratch + "/b")
        }, "\(controller.panels.map(\.currentPath))")
    }

    // MARK: - saved state: the window closed last wins

    /// Like 7zFM processes exiting one after another: each close writes the window's state, so the
    /// last one closed is what the next launch reads -- and a closed window never writes again.
    func testTheWindowClosedLastWins() throws {
        let first = delegate.openNewWindow()
        let second = delegate.openNewWindow()
        navigate(first.focusedPanel, to: scratch + "/a")
        navigate(second.focusedPanel, to: scratch + "/b")

        second.window?.close()
        XCTAssertEqual(savedPath0, scratch + "/b")
        first.window?.close()
        XCTAssertEqual(savedPath0, scratch + "/a", "the window closed last wins")
        XCTAssertTrue(first.isClosed && second.isClosed)
        XCTAssertFalse(MainWindows.controllers.contains { $0 === first || $0 === second },
                       "a closed window leaves the window list")

        // Quit after that: only open windows save, so neither closed one writes again.
        Settings.setPanelPath(scratch + "/sentinel", 0)
        MainWindows.saveAllForTermination()
        XCTAssertNotEqual(savedPath0, scratch + "/a")
        XCTAssertNotEqual(savedPath0, scratch + "/b")
    }

    /// Quit with several windows open: they save from the back to the front, so the frontmost
    /// window's state survives (as if the user had closed them from the back).
    func testQuitSavesTheFrontmostWindowLast() throws {
        let back = delegate.openNewWindow()
        let front = delegate.openNewWindow()
        navigate(back.focusedPanel, to: scratch + "/a")
        navigate(front.focusedPanel, to: scratch + "/b")
        back.window?.orderFront(nil)
        front.window?.orderFront(nil)
        XCTAssertTrue(MainWindows.frontToBack.first === front)
        MainWindows.saveAllForTermination()
        XCTAssertEqual(savedPath0, scratch + "/b")

        front.window?.orderBack(nil)
        back.window?.orderFront(nil)
        MainWindows.saveAllForTermination()
        XCTAssertEqual(savedPath0, scratch + "/a")
    }

    // MARK: - an archive opened from Finder

    /// Cold launch by a Finder double-click: the open-documents event arrives before
    /// `applicationDidFinishLaunching`, so the document's window exists and no default window is
    /// added; a launch with nothing to open, or with a 7zFM argv path, gets the default window.
    func testColdLaunchForDocumentsAddsNoDefaultWindow() {
        XCTAssertFalse(AppDelegate.needsLaunchWindow(documentWindows: 1, startPath: nil))
        XCTAssertFalse(AppDelegate.needsLaunchWindow(documentWindows: 2, startPath: nil))
        XCTAssertTrue(AppDelegate.needsLaunchWindow(documentWindows: 0, startPath: nil))
        XCTAssertTrue(AppDelegate.needsLaunchWindow(documentWindows: 0, startPath: "/tmp"))
        XCTAssertTrue(AppDelegate.needsLaunchWindow(documentWindows: 1, startPath: "/tmp"))
        XCTAssertTrue(delegate.hasFinishedLaunching)
    }

    /// `application(_:open:)` (Finder double-click, Open With, `open file.7z`): every archive gets a
    /// window of its own; the window that was already open keeps what it shows.
    func testArchiveFromFinderGetsItsOwnWindow() throws {
        let existing = try XCTUnwrap(MainWindows.primary)
        let existingPath = existing.focusedPanel.currentPath
        let archive = URL(fileURLWithPath: TestPaths.fixture("test.7z"))
        let second = URL(fileURLWithPath: TestPaths.fixture("test.zip"))

        delegate.application(NSApp, open: [archive])
        XCTAssertEqual(added.count, 1, "the archive must open in a new window")
        let window = try XCTUnwrap(added.first)
        XCTAssertTrue(wait(for: "the archive is open") {
            window.focusedPanel.snapshot?.isArchive ?? false
        }, "the new window shows \(window.focusedPanel.currentPath)")
        XCTAssertTrue(window.focusedPanel.currentPath.contains("test.7z"), window.focusedPanel.currentPath)
        XCTAssertEqual(existing.focusedPanel.currentPath, existingPath, "the open window was reused")

        // Opening another archive while that one is open: a third window, not the second reused.
        delegate.application(NSApp, open: [second])
        XCTAssertEqual(added.count, 2)
        XCTAssertTrue(wait(for: "the second archive is open") {
            self.added.last?.focusedPanel.currentPath.contains("test.zip") ?? false
        })
        XCTAssertTrue(window.focusedPanel.currentPath.contains("test.7z"))
        attach(try XCTUnwrap(added.last?.window), "11-hosted-archive-from-finder")
    }

    /// Several files in one open event: one window each (one `7zFM.exe "%1"` per file).
    func testSeveralArchivesInOneOpenEventGetAWindowEach() throws {
        delegate.application(NSApp, open: [URL(fileURLWithPath: TestPaths.fixture("test.7z")),
                                           URL(fileURLWithPath: TestPaths.fixture("test.zip"))])
        XCTAssertEqual(added.count, 2)
        XCTAssertTrue(wait(for: "both archives open") {
            self.added.allSatisfy { $0.focusedPanel.snapshot?.isArchive ?? false }
        })
    }
}
