// GModeTests.swift -- "7zG mode" in process (Mac/docs/reports/gmode.md, App/Integration/GMode.swift).
//
// On Windows a shell command runs in 7zG.exe: no 7zFM window appears, the dialog stands alone,
// centred on the work area, and the process exits when the command ends (03 §1.5, §2). Here the
// commands are sent exactly as AppKit delivers them -- `application(_:open:)` with a `sevenzip://`
// URL -- to the running host app, which is the *warm* case: its file-manager window must keep its
// place, and the app must keep running. The cold case (a launch made for the command, which quits
// afterwards) needs a process of its own and is in `Mac/Tests/UITests/GModeUITests.swift`; its
// decisions are unit-tested here.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class GModeTests: AppHostTestCase {

    override var screenshotPrefix: String { "gmode" }

    private var delegate: AppDelegate { NSApp.delegate as! AppDelegate }
    private var before: [MainWindowController] = []
    private var scratch = ""
    private var quitRequests = 0

    override func setUpWithError() throws {
        try super.setUpWithError()
        before = MainWindows.controllers
        GMode.resetForTesting()
        GMode.changesActivation = false
        GMode.terminate = { [weak self] in self?.quitRequests += 1 }
        quitRequests = 0
        scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("gmode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        try "hello 7-zip\n".write(toFile: scratch + "/one.txt", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        for controller in MainWindows.controllers where !before.contains(where: { $0 === controller }) {
            controller.window?.close()
        }
        spin(0.2)
        GMode.resetForTesting()
        GMode.changesActivation = true
        try? FileManager.default.removeItem(atPath: scratch)
        super.tearDown()
    }

    // MARK: - helpers

    private func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > end { XCTFail("timed out waiting for \(what)"); return false }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// The file-manager windows, front to back, as identities.
    private var managerOrder: [ObjectIdentifier] { MainWindows.frontToBack.map(ObjectIdentifier.init) }

    /// Finder's "Add to archive..." command line for `one.txt` (FinderMenuModel, 03 §1.4 B5).
    private func addToArchiveURL() throws -> URL {
        let argv = ["a", "-ad", "-saa", "-i!" + scratch + "/one.txt", "--", scratch + "/one"]
        return try XCTUnwrap(CommandURL.url(argv: argv))
    }

    private func assertCentredOnWorkArea(_ window: NSWindow, file: StaticString = #filePath, line: UInt = #line) {
        guard let area = NSScreen.main?.visibleFrame else { return XCTFail("no screen", file: file, line: line) }
        let frame = window.frame
        // DS_CENTER without an owner, as 7zG's Compress / Extract dialogs are placed
        // (wincompare-data/win/dlg-compress.txt): the frame's centre is the work area's centre.
        if frame.height <= area.height {
            XCTAssertEqual(frame.midY, area.midY, accuracy: 1, "vertical centre", file: file, line: line)
        }
        XCTAssertEqual(frame.midX, area.midX, accuracy: 1, "horizontal centre", file: file, line: line)
    }

    // MARK: - warm: the file manager is open

    /// Add to archive from Finder while a file-manager window is open: the Compress dialog is a
    /// window of its own (no sheet, no owner), centred on the work area; the file-manager windows
    /// keep their number and order; Cancel leaves the app running.
    func testWarmCommandDialogStandsAloneAndLeavesTheWindowsAlone() throws {
        let managerWindow = try XCTUnwrap(MainWindows.primary?.window)
        let orderBefore = managerOrder
        let url = try addToArchiveURL()

        var inspected = false
        XCTAssertTrue(ModalProbe.present({ delegate.application(NSApp, open: [url]) }) { window in
            inspected = true
            XCTAssertTrue(GMode.isActive, "the URL command did not run in 7zG mode")
            XCTAssertEqual(window.title, Lang.text(4000, "Add to Archive"))
            XCTAssertFalse(window.isSheet, "the Compress dialog must not be a sheet")
            XCTAssertNil(window.sheetParent)
            XCTAssertNil(window.parent, "the Compress dialog must not be a child of a file-manager window")
            self.assertCentredOnWorkArea(window)
            // No file-manager window may own a dialog of this command, even when named explicitly.
            XCTAssertNil(DialogKit.owner(for: nil, parent: managerWindow))
            XCTAssertEqual(self.managerOrder, orderBefore, "the file-manager windows moved")
            XCTAssertEqual(MainWindows.controllers.count, self.before.count, "a file-manager window appeared")
            // A Dock click while the dialog is up brings the dialog forward, not a window.
            XCTAssertFalse(self.delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: true))
            XCTAssertEqual(MainWindows.controllers.count, self.before.count)
            self.attach(window, "01-hosted-warm-add-to-archive")
        })
        XCTAssertTrue(inspected)
        XCTAssertFalse(GMode.isActive)
        XCTAssertEqual(GMode.completedCommands, 1)
        XCTAssertEqual(managerOrder, orderBefore, "the file-manager windows moved")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch + "/one.7z"), "Cancel created an archive")
        spin(0.2)
        XCTAssertEqual(quitRequests, 0, "a running file manager must not quit after a shell command")
    }

    /// An extension's error report is 7zG's MessageBox with no owner: centred on the screen, owned
    /// by no file-manager window.
    func testWarmErrorBoxHasNoFileManagerOwner() throws {
        let url = try XCTUnwrap(CommandURL.errorURL(.noItems))
        let orderBefore = managerOrder
        var inspected = false
        XCTAssertTrue(ModalProbe.present({ delegate.application(NSApp, open: [url]) }) { window in
            inspected = true
            let box = window as? WinMessageBoxWindow
            XCTAssertNotNil(box, "not a message box: \(window)")
            XCTAssertNil(box?.ownerWindow, "the box is owned by \(box?.ownerWindow?.title ?? "-")")
            if let screen = NSScreen.main {
                XCTAssertEqual(window.frame.midX, screen.frame.midX, accuracy: 1)
                XCTAssertEqual(window.frame.midY, screen.frame.midY, accuracy: 1)
            }
        })
        XCTAssertTrue(inspected)
        XCTAssertEqual(managerOrder, orderBefore)
        XCTAssertEqual(recordedBoxes.last?.text, CommandURL.ExtensionFailure.noItems.message)
        XCTAssertNil(recordedBoxes.last?.owner)
    }

    /// "Open archive" is 7zFM.exe on Windows: exactly one new file-manager window, and the app keeps
    /// running even when the launch was made for the command.
    func testOpenArchiveOpensExactlyOneWindowAndDoesNotQuit() throws {
        GMode.resetForTesting(launchedForCommand: true)
        GMode.changesActivation = false
        GMode.terminate = { [weak self] in self?.quitRequests += 1 }
        let url = try XCTUnwrap(CommandURL.url(argv: [TestPaths.fixture("test.7z")]))
        delegate.application(NSApp, open: [url])
        XCTAssertEqual(MainWindows.controllers.count, before.count + 1, "Open archive must open one window")
        let window = try XCTUnwrap(MainWindows.controllers.last)
        XCTAssertTrue(waitUntil("the archive is open") { window.focusedPanel.snapshot?.isArchive ?? false })
        XCTAssertTrue(window.focusedPanel.currentPath.contains("test.7z"), window.focusedPanel.currentPath)
        spin(0.3)
        XCTAssertEqual(quitRequests, 0, "the app quit with the archive's window open")
        XCTAssertFalse(GMode.shouldQuit)
    }

    /// A finished command refreshes the panels (7zFM re-reads a folder after a change): the archive
    /// a Finder command wrote appears in a panel showing that folder, with no window opened.
    func testWarmCommandRefreshesThePanels() throws {
        let controller = try XCTUnwrap(MainWindows.primary)
        let panel = controller.focusedPanel
        let savedPath = panel.currentPath
        addTeardownBlock { [weak self] in
            // Leave the scratch folder before tearDown deletes it.
            panel.navigate(to: savedPath)
            let end = Date().addingTimeInterval(5)
            while panel.currentPath != savedPath, Date() < end { self?.spin(0.05) }
        }
        panel.navigate(to: scratch)
        XCTAssertTrue(waitUntil("the panel lists one.txt") { panel.rows.contains { $0.name == "one.txt" } })
        // No dialog (no -ad): the progress window comes and goes by itself.
        let url = try XCTUnwrap(CommandURL.url(argv: ["a", "-t7z", "-i!" + scratch + "/one.txt", "--",
                                                      scratch + "/made.7z"]))
        delegate.application(NSApp, open: [url])
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch + "/made.7z"))
        XCTAssertTrue(waitUntil("the panel lists made.7z") { panel.rows.contains { $0.name == "made.7z" } })
        XCTAssertEqual(MainWindows.controllers.count, before.count)
    }

    // MARK: - cold: the launch's decisions

    /// A command that comes in while the launch waits for it cancels the default window and marks
    /// the launch as one for a command (the `GURL` that arrives after `didFinishLaunching`).
    func testCommandCancelsTheDeferredLaunchWindow() {
        GMode.launchWindowGrace = 0.2
        var opened = false
        GMode.deferLaunchWindow { opened = true }
        XCTAssertTrue(GMode.isLaunchWindowPending)
        var ran = false
        GMode.submit { ran = true }
        XCTAssertTrue(ran, "a command after launching runs at once")
        XCTAssertFalse(GMode.isLaunchWindowPending)
        XCTAssertTrue(GMode.launchedForCommand)
        spin(0.4)
        XCTAssertFalse(opened, "the default window appeared under a command")
    }

    func testCommandLaunchHasNoDefaultWindow() {
        XCTAssertFalse(AppDelegate.needsLaunchWindow(documentWindows: 0, startPath: nil, forCommand: true))
        XCTAssertFalse(AppDelegate.needsLaunchWindow(documentWindows: 0, startPath: "a", forCommand: true))
        XCTAssertTrue(AppDelegate.needsLaunchWindow(documentWindows: 0, startPath: nil, forCommand: false))
    }

    /// Only a plain launch carries `oapp`; a launch for a URL has none when it finishes (measured).
    func testOpenApplicationEventIsRecognised() {
        let target = NSAppleEventDescriptor(processIdentifier: getpid())
        let oapp = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                                          eventID: AEEventID(kAEOpenApplication), targetDescriptor: target,
                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        let gurl = NSAppleEventDescriptor(eventClass: AEEventClass(kInternetEventClass),
                                          eventID: AEEventID(kAEGetURL), targetDescriptor: target,
                                          returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        XCTAssertTrue(GMode.isOpenApplicationEvent(oapp))
        XCTAssertFalse(GMode.isOpenApplicationEvent(gurl))
        XCTAssertFalse(GMode.isOpenApplicationEvent(nil))
    }

    /// 7zG exits when its command is done; a command-only launch does the same, unless the command
    /// opened the file manager or something is still on screen or still to run.
    func testQuitDecision() {
        func quit(_ launched: Bool = true, running: Int = 0, queued: Int = 0, drained: Bool = true,
                  fm: Int = 0, modal: Bool = false, visible: Int = 0) -> Bool {
            GMode.shouldQuit(launchedForCommand: launched, running: running, queued: queued,
                             launchDrained: drained, fileManagerWindows: fm, modal: modal, visibleWindows: visible)
        }
        XCTAssertTrue(quit())
        XCTAssertFalse(quit(false), "a running file manager never quits after a command")
        XCTAssertFalse(quit(running: 1))
        XCTAssertFalse(quit(queued: 1))
        XCTAssertFalse(quit(drained: false))
        XCTAssertFalse(quit(fm: 1), "Open archive keeps the app")
        XCTAssertFalse(quit(modal: true))
        XCTAssertFalse(quit(visible: 1))
    }

    /// Which URLs make the app a 7zG process: commands and their error reports, not the settings
    /// hand-off or the test host.
    func testShellCommandURLs() throws {
        XCTAssertTrue(URLCommands.isShellCommand(try addToArchiveURL()))
        XCTAssertTrue(URLCommands.isShellCommand(try XCTUnwrap(CommandURL.errorURL(.noItems))))
        XCTAssertTrue(URLCommands.isShellCommand(try XCTUnwrap(URL(string: "sevenzip:///bogus"))))
        XCTAssertFalse(URLCommands.isShellCommand(try XCTUnwrap(CommandURL.settingsURL(show: true))))
        XCTAssertFalse(URLCommands.isShellCommand(try XCTUnwrap(URL(string: "sevenzip://test/reset"))))
    }
}
