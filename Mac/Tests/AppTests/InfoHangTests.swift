// InfoHangTests.swift -- "I clicked Info, closed it and the app became unresponsive"
// (ai/reports/infohang.md). Opens Properties (IDM_PROPERTIES 551, toolbar Info) and every
// other dialog the toolbar opens, closes each one every way a user can, and checks that the modal
// session really ended: `NSApp.modalWindow` is nil and the main window takes actions again.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class InfoHangTests: AppHostTestCase {

    override var screenshotPrefix: String { "infohang" }

    private var controllers: [MainWindowController] = []
    private var scratchDirectories: [String] = []
    private var savedNumPanels = 1
    private var savedPanelPaths: [String?] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedNumPanels = Settings.numPanels
        savedPanelPaths = [Settings.panelPath(0), Settings.panelPath(1)]
    }

    override func tearDown() {
        while NSApp.modalWindow != nil { NSApp.stopModal(withCode: .abort); RunLoop.current.run(until: Date()) }
        for controller in controllers { controller.window?.close() }
        controllers = []
        for path in scratchDirectories { try? FileManager.default.removeItem(atPath: path) }
        scratchDirectories = []
        for (i, path) in savedPanelPaths.enumerated() { Settings.setPanelPath(path, i) }
        Settings.numPanels = savedNumPanels
        super.tearDown()
    }

    // MARK: - helpers

    private func makeScratch() -> String {
        let path = (TestPaths.artifacts as NSString).appendingPathComponent("infohang-t-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/sub", withIntermediateDirectories: true)
        try? fm.copyItem(atPath: TestPaths.fixture("test.7z"), toPath: path + "/test.7z")
        fm.createFile(atPath: path + "/a.txt", contents: Data(repeating: 0x61, count: 1234))
        scratchDirectories.append(path)
        return path
    }

    private func makeWindow(at path: String) -> MainWindowController {
        Settings.numPanels = 1
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(NSSize(width: 900, height: 560))
        controller.showWindow(nil)
        ActiveContext.register(controller)
        var done = false
        controller.focusedPanel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
        return controller
    }

    enum CloseWay: String, CaseIterable {
        case okButton, cancelButton, escape, returnKey, closeButton, commandW
    }

    private func keyEvent(_ chars: String, mods: NSEvent.ModifierFlags = [], keyCode: UInt16, window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: keyCode)!
    }

    private func button(_ title: String, in window: NSWindow) -> NSButton? {
        func all(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(all) }
        return all(window.contentView!).compactMap { $0 as? NSButton }.first { $0.title == title }
    }

    /// The input a user gives to close `window` the given way. Key presses go through
    /// `NSApp.sendEvent`, as the event loop delivers them (key equivalents, then the window).
    private func close(_ window: NSWindow, _ way: CloseWay) {
        switch way {
        case .okButton: button("OK", in: window)?.performClick(nil)
        case .cancelButton: button("Cancel", in: window)?.performClick(nil)
        case .escape: NSApp.sendEvent(keyEvent("\u{1b}", keyCode: 53, window: window))
        case .returnKey: NSApp.sendEvent(keyEvent("\r", keyCode: 36, window: window))
        case .closeButton: window.standardWindowButton(.closeButton)?.performClick(nil)
        case .commandW:
            // NSApp hands a Command key to the *key* window's performKeyEquivalent first; the host
            // app runs in the background and may have no key window, so do that step directly.
            let event = keyEvent("w", mods: [.command], keyCode: 13, window: window)
            if NSApp.keyWindow === window { NSApp.sendEvent(event) } else if !window.performKeyEquivalent(with: event) {
                NSApp.mainMenu?.performKeyEquivalent(with: event)
            }
        }
    }

    struct Outcome {
        var opened = false
        var dialogTitle = ""
        var modalAfterClose = false     // a modal session outlived the close: the hang
        var leftoverTitles: [String] = []
        var visibleWhileStuck: [Bool] = []   // was the stuck session's window still on screen
    }

    /// Runs `open`, waits for its modal window, closes it `way`, and reports whether every modal
    /// session ended within `grace` seconds. Sessions left behind are ended here so the run goes on.
    /// The close is performed from its own run-loop pass, not from inside the watchdog timer: a
    /// close that starts another modal session (Return opens the item viewer) must not block the
    /// timer that is meant to notice it.
    private func scenario(_ way: CloseWay, grace: TimeInterval = 2, open: () -> Void) -> Outcome {
        var outcome = Outcome()
        var closedAt: Date?
        var finished = false
        let deadline = Date().addingTimeInterval(6)
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            if let closedAt {
                if NSApp.modalWindow == nil { finished = true; timer.invalidate(); return }
                if Date().timeIntervalSince(closedAt) > grace {
                    outcome.modalAfterClose = true
                    if let modal = NSApp.modalWindow {
                        outcome.leftoverTitles.append(modal.title)
                        outcome.visibleWhileStuck.append(modal.isVisible)
                    }
                    NSApp.stopModal(withCode: .abort)       // innermost first; the next tick takes the next
                }
                return
            }
            if Date() > deadline { finished = true; timer.invalidate(); return }
            guard let modal = NSApp.modalWindow, modal.isVisible else { return }
            outcome.opened = true
            outcome.dialogTitle = modal.title
            closedAt = Date()
            RunLoop.main.perform(inModes: [.default, .modalPanel, .eventTracking]) { self.close(modal, way) }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        open()
        while !finished, Date() < deadline.addingTimeInterval(grace + 5) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        timer.invalidate()
        for window in NSApp.windows where window is DialogWindow && window.isVisible { window.orderOut(nil) }
        return outcome
    }

    /// After the dialog: no modal session, and the main window answers a menu action again
    /// (View > Refresh validates and runs through its responder chain).
    private func assertResponsive(_ controller: MainWindowController, _ label: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(NSApp.modalWindow, "\(label): a modal session is still running", file: file, line: line)
        XCTAssertTrue(controller.window?.isVisible ?? false, "\(label): the main window was closed", file: file, line: line)
    }

    /// The toolbar button's own action, down the responder chain as a click sends it; straight to
    /// the focused panel when the host app is in the background and has no key window.
    private func clickToolbar(_ id: String, _ controller: MainWindowController) {
        guard let button = controller.toolbarView.button(id), let action = button.action else {
            XCTFail("no toolbar button \(id)"); return
        }
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.focusedPanel.tableView)
        if !NSApp.sendAction(action, to: nil, from: button) {
            // The chain the key window would have walked: the list, its panel, the window
            // controller, then the app delegate.
            let chain: [AnyObject?] = [controller.focusedPanel, controller, NSApp.delegate]
            let target = chain.compactMap { $0 }.first { ($0 as? NSObject)?.responds(to: action) ?? false }
            XCTAssertNotNil(target, "nobody handles \(action)")
            NSApp.sendAction(action, to: target, from: button)
        }
    }

    // MARK: - the matrix

    /// What is focused / selected when Info is clicked.
    private enum Pick {
        case name(String)
        case names([String])
        case parentRow
        case nothing
    }

    private func pick(_ p: Pick, in panel: PanelViewController) -> Bool {
        switch p {
        case .name(let name):
            guard let row = panel.rows.firstIndex(where: { $0.name == name }) else { return false }
            panel.setFocus(row)
        case .names(let names):
            let rows = IndexSet(panel.rows.indices.filter { names.contains(panel.rows[$0].name) })
            guard rows.count == names.count, let first = rows.first else { return false }
            panel.setFocus(first)
            panel.setSelectedIndexes(rows)
        case .parentRow:
            guard let row = panel.rows.firstIndex(where: { $0.isParentRow }) else { return false }
            panel.setFocus(row)
        case .nothing:
            panel.killSelection()
        }
        return true
    }

    /// Opens Properties with `open` for every pick and closes it every way; returns the lines that
    /// left a modal session behind (or never opened, or closed the main window).
    private func runMatrix(_ controller: MainWindowController, location: String, picks: [(String, Pick)],
                           ways: [CloseWay], open: @escaping () -> Void) -> [String] {
        var failures: [String] = []
        let panel = controller.focusedPanel
        for (label, p) in picks {
            for way in ways {
                guard pick(p, in: panel) else { failures.append("\(location) \(label): cannot pick"); continue }
                let outcome = scenario(way, open: open)
                let line = "\(location) \(label) / \(way.rawValue): opened \(outcome.opened) '\(outcome.dialogTitle)' "
                    + "stuck \(outcome.modalAfterClose) \(outcome.leftoverTitles) visible \(outcome.visibleWhileStuck) "
                    + "main-visible \(controller.window?.isVisible ?? false)"
                print("INFOHANG | " + line)
                if !outcome.opened || outcome.modalAfterClose || !(controller.window?.isVisible ?? false) {
                    failures.append(line)
                }
                if !(controller.window?.isVisible ?? false) { controller.showWindow(nil) }
            }
        }
        return failures
    }

    private var closeWays: [CloseWay] { [.okButton, .cancelButton, .escape, .closeButton, .commandW] }

    /// The user's report: toolbar Info, then close. On a file, a folder, an archive on disk, two
    /// items, nothing selected, `..`, inside an archive and at its root; closed with OK, Cancel,
    /// Escape, the title-bar close button and Cmd+W. Before the fix the close button and Cmd+W left
    /// the modal session of the closed window running and the app refused every click after it.
    func testInfoButtonCloseEveryWay() throws {
        let savedDots = Settings.showDots
        Settings.showDots = true
        defer { Settings.showDots = savedDots }
        let scratch = makeScratch()
        let controller = makeWindow(at: scratch)
        let info = { self.clickToolbar("sz.info", controller) }
        var failures = runMatrix(controller, location: "fs", picks: [
            ("a.txt", .name("a.txt")), ("sub", .name("sub")), ("test.7z", .name("test.7z")),
            ("a.txt+sub", .names(["a.txt", "sub"])),
        ], ways: closeWays, open: info)
        // Nothing operated on the file system: InvokeSystemCommand returns without a window
        // (PanelMenu.cpp:58-66; listfeel.md §4), so there is nothing to close.
        for (label, p) in [("nothing", Pick.nothing), ("..", Pick.parentRow)] {
            XCTAssertTrue(pick(p, in: controller.focusedPanel))
            info()
            XCTAssertEqual(controller.focusedPanel.lastPropertiesRoute, .nothing, "fs \(label)")
            XCTAssertNil(NSApp.modalWindow, "fs \(label): 7zFM opens no window")
        }

        var done = false
        controller.focusedPanel.navigate(to: scratch + "/test.7z") { _ in done = true }
        XCTAssertTrue(wait(for: "inside test.7z") { done && controller.focusedPanel.snapshot?.isArchive == true })
        let first = controller.focusedPanel.rows.first { !$0.isParentRow }?.name ?? ""
        failures += runMatrix(controller, location: "archive", picks: [
            ("item", .name(first)), ("root/nothing", .nothing), ("..", .parentRow),
        ], ways: closeWays, open: info)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        assertResponsive(controller, "after the matrix")
    }

    /// File > Properties (the menu item, IDM_PROPERTIES 551) and the panel's own Alt+Enter path
    /// reach the same dialog; closed with the title-bar button they must end the session too.
    func testPropertiesMenuPathCloseButton() throws {
        let scratch = makeScratch()
        let controller = makeWindow(at: scratch)
        let menu = { _ = NSApp.sendAction(#selector(PanelViewController.fileProperties(_:)), to: controller.focusedPanel, from: nil) }
        let failures = runMatrix(controller, location: "menu", picks: [("a.txt", .name("a.txt"))],
                                 ways: [.closeButton, .commandW], open: menu)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        assertResponsive(controller, "after File > Properties")
    }

    /// Return on a Properties row is OnEnter -> ShowItemInfo (ListViewDialog.cpp:247-256): the
    /// item viewer (IDD_EDIT_DLG 94) opens over Properties. Closing the viewer with its title-bar
    /// button must return to Properties, and closing that must end every session.
    func testReturnOpensTheViewerAndBothCloseButtonsEndTheirSessions() throws {
        let scratch = makeScratch()
        let controller = makeWindow(at: scratch)
        XCTAssertTrue(pick(.name("a.txt"), in: controller.focusedPanel))
        var titles: [String] = []
        var finished = false
        let deadline = Date().addingTimeInterval(15)
        var step = 0
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            if Date() > deadline {          // end whatever is left so the test fails instead of hanging
                if NSApp.modalWindow != nil { NSApp.stopModal(withCode: .abort) } else { timer.invalidate(); finished = true }
                return
            }
            switch step {
            case 0:     // Properties is up: press Return on the list
                guard let modal = NSApp.modalWindow, modal.isVisible else { return }
                titles.append(modal.title); step = 1
                RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                    NSApp.sendEvent(self.keyEvent("\r", keyCode: 36, window: modal))
                }
            case 1:     // the viewer is up over it: its close button
                guard let modal = NSApp.modalWindow, modal.isVisible, titles.last != modal.title else { return }
                titles.append(modal.title); step = 2
                RunLoop.main.perform(inModes: [.default, .modalPanel]) { self.close(modal, .closeButton) }
            case 2:     // back on Properties: its close button
                guard let modal = NSApp.modalWindow, modal.isVisible, modal.title == titles.first else { return }
                titles.append(modal.title); step = 3
                RunLoop.main.perform(inModes: [.default, .modalPanel]) { self.close(modal, .closeButton) }
            default:
                if NSApp.modalWindow == nil { timer.invalidate(); finished = true }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        clickToolbar("sz.info", controller)
        while !finished, Date() < deadline.addingTimeInterval(2) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        timer.invalidate()
        print("INFOHANG | return path: \(titles) step \(step) modal \(String(describing: NSApp.modalWindow?.title))")
        XCTAssertEqual(titles, ["Properties", "Name", "Properties"], "Properties -> item viewer -> Properties")
        XCTAssertEqual(step, 3)
        assertResponsive(controller, "after the viewer and Properties")
    }

    // MARK: - the other toolbar buttons (Add, Extract, Test, Copy, Move, Delete)

    /// Every toolbar button opens a modal window; closing it with the title-bar button or Cmd+W
    /// must end that session and do nothing else (IDCANCEL): no archive written, nothing copied,
    /// moved or deleted. Test ends in a result alert (OK).
    func testEveryToolbarDialogEndsItsSessionWhenClosed() throws {
        let scratch = makeScratch()
        let controller = makeWindow(at: scratch)
        let fm = FileManager.default
        let before = Set((try? fm.contentsOfDirectory(atPath: scratch)) ?? [])
        var failures: [String] = []
        let plan: [(String, String, [CloseWay])] = [
            ("sz.add", "a.txt", [.closeButton, .commandW]),
            ("sz.extract", "test.7z", [.closeButton, .commandW]),
            ("sz.copy", "a.txt", [.closeButton, .commandW]),
            ("sz.move", "a.txt", [.closeButton, .commandW]),
            ("sz.test", "test.7z", [.okButton]),
        ]
        for (id, name, ways) in plan {
            failures += runMatrix(controller, location: id, picks: [(name, .name(name))], ways: ways) {
                self.clickToolbar(id, controller)
            }
        }
        // Delete to the Trash on disk asks nothing (FOF_ALLOWUNDO, PanelOperations.swift); inside
        // an archive it asks with an NSAlert, which has no close box: Escape is its IDCANCEL.
        try? fm.copyItem(atPath: scratch + "/test.7z", toPath: scratch + "/del.7z")
        var done = false
        controller.focusedPanel.navigate(to: scratch + "/del.7z") { _ in done = true }
        XCTAssertTrue(wait(for: "inside del.7z") { done && controller.focusedPanel.snapshot?.isArchive == true })
        let item = controller.focusedPanel.rows.first { !$0.isParentRow }?.name ?? ""
        let countBefore = controller.focusedPanel.rows.count
        failures += runMatrix(controller, location: "sz.delete (archive)", picks: [(item, .name(item))],
                              ways: [.escape]) { self.clickToolbar("sz.delete", controller) }
        XCTAssertEqual(controller.focusedPanel.rows.count, countBefore, "Escape on the delete question deleted")
        controller.focusedPanel.navigate(to: scratch) { _ in done = true }
        try? fm.removeItem(atPath: scratch + "/del.7z")
        let after = Set((try? fm.contentsOfDirectory(atPath: scratch)) ?? [])
        XCTAssertEqual(after, before, "closing a dialog must not run its operation")
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        assertResponsive(controller, "after every toolbar dialog")
    }
}
