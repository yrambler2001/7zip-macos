// PanelWindowlessErrorTests.swift -- the defect of `Mac/docs/reports/fastui.md` section 6.10, as a
// test: a panel closed at runtime stays alive in `MainWindowController.panels` with no window, and
// when its folder disappears the failed reload used to put up an **app-modal** `NSAlert` attached to
// nothing. Nothing could dismiss it: the reset could not settle past it, no click could reach it,
// and every accessibility query after it took about six seconds.
//
// The user sequence is exactly the one a person hits: two panels, close one (F9 /
// IDM_VIEW_TWO_PANELS 732), delete the folder that closed panel was showing, and let the app reload
// its panels -- which it does on its own from the View menu's timestamp items, from an Options
// apply, from a language switch and from `sevenzip://test/reset`, all of which reload *every* panel,
// hidden ones included.
//
// The probe is `ModalProbe`'s trick (fastui section 6.5): a timer added to `.common` and
// `.modalPanel` *before* the trigger fires inside a nested `NSApp.runModal` loop, so the wedge is
// recorded and then ended with `NSApp.stopModal()` instead of hanging the whole bundle.

import AppKit
import XCTest
@testable import SevenZipAppHost

final class PanelWindowlessErrorTests: AppHostTestCase {

    override var screenshotPrefix: String { "modalfix" }

    private var controllers: [MainWindowController] = []
    private var scratchDirectories: [String] = []

    override func tearDown() {
        for controller in controllers {
            // `OptionsPostApply.reloadLangItems()` walks every window's toolbar and throws on a closed
            // one, so an extra window this test built does not leave one behind (see the note in
            // `TestResetSettleTests.setUpWithError`, and the request filed for `options`).
            controller.window?.toolbar = nil
            controller.window?.close()
        }
        controllers = []
        for path in scratchDirectories { try? FileManager.default.removeItem(atPath: path) }
        scratchDirectories = []
        super.tearDown()
    }

    // MARK: - fixtures

    private func makeScratchDirectory(_ name: String) -> String {
        let path = (TestPaths.artifacts as NSString).appendingPathComponent("modalfix-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: (path as NSString).appendingPathComponent("a.txt"),
                                           contents: Data("a".utf8), attributes: nil)
        scratchDirectories.append(path)
        return path
    }

    /// A window of its own, so nothing here touches the app's live one (the house rule of
    /// `AppHostTestCase`). Two panels, panel 0 focused, so `switchOnOffOnePanel` closes panel 1.
    private func makeWindow(panels: Int) -> MainWindowController {
        Settings.numPanels = panels
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(NSSize(width: 1200, height: 800))
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        return controller
    }

    private func navigate(_ panel: PanelViewController, to path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
    }

    // MARK: - the probe

    private struct ModalSighting {
        var window: NSWindow?
        var sheetParent: NSWindow?
        var isAppModal = false
    }

    /// Runs `body` and then pumps the run loop for `settle` seconds, recording the first modal
    /// session or sheet that comes up. An app-modal session is ended with `NSApp.stopModal()` -- not
    /// `abortModal()`, which raises `NSAbortModalException` and would unwind out of this timer.
    private func sightingWhile(_ what: String, settle: TimeInterval = 3, shot: String? = nil,
                               _ body: () -> Void) -> ModalSighting {
        var sighting = ModalSighting()
        let known = Set(NSApp.windows.filter { $0.isVisible }.map(ObjectIdentifier.init))
        let timer = Timer(timeInterval: 0.02, repeats: true) { _ in
            if sighting.window == nil {
                let fresh = NSApp.windows.first {
                    $0.isVisible && !known.contains(ObjectIdentifier($0))
                        && ($0.isSheet || $0 is NSPanel || $0.styleMask.contains(.titled))
                }
                if let window = fresh ?? NSApp.modalWindow {
                    sighting.window = window
                    sighting.sheetParent = window.sheetParent
                }
            }
            if let modal = NSApp.modalWindow {
                sighting.isAppModal = true
                if sighting.window == nil { sighting.window = modal }
                NSApp.stopModal()
            }
        }
        for mode in [RunLoop.Mode.common, .modalPanel, .default, .eventTracking] {
            RunLoop.main.add(timer, forMode: mode)
        }
        body()
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        timer.invalidate()
        // Whatever came up, leave nothing behind for the next case.
        if let window = sighting.window, window.isVisible {
            if let shot { attach(window, shot) }
            if let parent = window.sheetParent { parent.endSheet(window, returnCode: .cancel) }
            window.orderOut(nil)
        }
        print("MODALFIX | \(what) | window: \(sighting.window.map { "\(type(of: $0))" } ?? "none")"
              + " | app-modal: \(sighting.isAppModal) | sheet of: "
              + (sighting.sheetParent == nil ? "nothing" : "a window"))
        return sighting
    }

    // MARK: - the regression

    /// Two panels, close one, delete the folder it was showing, then make the app reload every
    /// panel the way the View menu and a reset do. Nothing may open an app-modal session, because
    /// an app-modal alert owned by no window cannot be dismissed by anything.
    func testAClosedPanelWhoseFolderVanishedOpensNoOwnerlessModalAlert() {
        let scratch = makeScratchDirectory("closed-panel")
        let controller = makeWindow(panels: 2)
        XCTAssertEqual(controller.panels.count, 2, "the fixture needs two panels")
        navigate(controller.panels[0], to: TestPaths.fixtures)
        navigate(controller.panels[1], to: scratch)

        controller.setFocusedPanel(0)
        controller.switchOnOffOnePanel()                     // IDM_VIEW_TWO_PANELS 732 / F9
        XCTAssertEqual(controller.numPanels, 1, "the second panel should be closed")
        XCTAssertEqual(controller.panels.count, 2, "7zFM keeps the closed panel alive (it is reused)")
        XCTAssertNil(controller.panels[1].view.window, "the closed panel's view has no window")

        try? FileManager.default.removeItem(atPath: scratch)

        // Every one of these reloads *all* the panels, the hidden one included: the View menu's
        // UTC item (IDM_VIEW_TIME_UTC 799), an Options apply, a language switch, and step 3 of
        // `sevenzip://test/reset`.
        let sighting = sightingWhile("closed panel, folder deleted, all panels reloaded") {
            controller.viewTimeUTC(nil)
            Settings.notifyAllGroups()
            for panel in controller.panels { panel.refreshIfChanged() }
        }
        Settings.timestampShowUTC = false

        XCTAssertFalse(sighting.isAppModal,
                       "a panel with no window opened an app-modal session; nothing can dismiss it "
                       + "(Mac/docs/reports/fastui.md 6.10)")
        if let window = sighting.window {
            XCTAssertNotNil(window.sheetParent,
                            "an error a panel reports must be a sheet of the window that owns it")
        }
        XCTAssertNil(NSApp.modalWindow, "the app must be left with no modal session")
        // Evidence for a human: the window is still drawing, one panel, no alert over it. On the
        // unfixed code this moment was an `_NSAlertPanel` owned by nothing and a wedged main thread.
        if let window = controller.window { attach(window, "closed-panel-folder-deleted-no-wedge") }
    }

    /// The other half of the rule: when a closed panel *does* have to report something, it reports it
    /// as a sheet of the window that owns it. In 7zFM the hidden panel still has an HWND, so
    /// `MessageBoxW(_panelHWND, ...)` always had an owner; `hostWindow` is that owner here.
    func testAClosedPanelReportsItsErrorOnTheWindowThatOwnsIt() {
        let controller = makeWindow(panels: 2)
        navigate(controller.panels[0], to: TestPaths.fixtures)
        navigate(controller.panels[1], to: TestPaths.fixtures)
        controller.setFocusedPanel(0)
        controller.switchOnOffOnePanel()
        let closed = controller.panels[1]
        XCTAssertNil(closed.view.window, "the closed panel's view has no window")
        XCTAssertTrue(closed.hostWindow === controller.window,
                      "a closed panel's sheets belong to the window that owns it")

        let sighting = sightingWhile("a closed panel reports an error") {
            closed.showError(message: "modalfix: a deliberate error from a closed panel")
        }
        XCTAssertFalse(sighting.isAppModal, "the error must not be app-modal")
        XCTAssertNotNil(sighting.window, "the error should have been shown")
        XCTAssertTrue(sighting.sheetParent === controller.window,
                      "the error must be a sheet of the panel's own window")
    }

    /// Deferring must not become *swallowing*. A panel that was closed while its folder was deleted is
    /// reopened here, and the question is what the user then sees: anything except the stale listing of
    /// a directory that no longer exists. Either the deferred reload reports the failure -- now on a
    /// real window, as a sheet -- or the auto-refresh notices the directory is gone and goes up to the
    /// nearest folder that still exists (`recoverFromRemovedDirectory`, fsfolder api section 7), which
    /// is what 7zFM does. A deferred error that never appears at all would be a bug of its own.
    func testAReopenedPanelDoesNotKeepShowingAFolderThatWasDeleted() {
        let scratch = makeScratchDirectory("reopen-after-delete")
        let controller = makeWindow(panels: 2)
        navigate(controller.panels[0], to: TestPaths.fixtures)
        navigate(controller.panels[1], to: scratch)
        let hidden = controller.panels[1]
        XCTAssertTrue(hidden.rows.contains { $0.name == "a.txt" })

        controller.setFocusedPanel(0)
        controller.switchOnOffOnePanel()                     // close it (F9)
        XCTAssertNil(hidden.view.window)

        try? FileManager.default.removeItem(atPath: scratch)
        // Something asks every panel to reload while this one is closed, so the reload is deferred with
        // a folder that can no longer be read -- the exact state the old code turned into a wedge.
        Settings.notifyAllGroups()

        let sighting = sightingWhile("reopening a panel whose folder was deleted", settle: 8) {
            controller.switchOnOffOnePanel()                 // reopen it
        }

        XCTAssertFalse(sighting.isAppModal, "reopening must not open an app-modal session either")
        if let window = sighting.window {
            XCTAssertNotNil(window.sheetParent, "an error shown on reopen must be a sheet")
        }
        let movedAway = !hidden.currentPath.hasPrefix(scratch)
        let listingIsGone = !hidden.rows.contains { $0.name == "a.txt" }
        print("MODALFIX | reopened panel | path: \(hidden.currentPath) | moved away: \(movedAway)"
              + " | stale row gone: \(listingIsGone)"
              + " | error shown: \(sighting.window != nil)")
        XCTAssertTrue(movedAway || listingIsGone || sighting.window != nil,
                      "a reopened panel showed the stale contents of a deleted folder and said nothing: "
                      + "path \(hidden.currentPath), \(hidden.rows.count) row(s)")
        XCTAssertTrue(movedAway,
                      "the panel should have gone up to the nearest folder that still exists, as 7zFM "
                      + "does; it is still on \(hidden.currentPath)")
    }

    /// Deferring is not dropping: a reload a panel missed while it was closed is applied when it comes
    /// back, which is what keeps the View menu, an Options apply and a language switch honest.
    func testReopeningAPanelAppliesTheReloadItDeferred() {
        let scratch = makeScratchDirectory("deferred-reload")
        let controller = makeWindow(panels: 2)
        navigate(controller.panels[0], to: TestPaths.fixtures)
        navigate(controller.panels[1], to: scratch)
        let hidden = controller.panels[1]
        XCTAssertTrue(hidden.rows.contains { $0.name == "a.txt" }, "the fixture file should be listed")

        controller.setFocusedPanel(0)
        controller.switchOnOffOnePanel()
        XCTAssertNil(hidden.view.window)

        _ = FileManager.default.createFile(atPath: (scratch as NSString).appendingPathComponent("b.txt"),
                                           contents: Data("b".utf8), attributes: nil)
        controller.viewTimeUTC(nil)                          // IDM_VIEW_TIME_UTC 799: reloads all panels
        Settings.timestampShowUTC = false
        XCTAssertFalse(wait(for: "no reload while closed", timeout: 1) {
            hidden.rows.contains { $0.name == "b.txt" }
        }, "a closed panel must not reload -- it has no window to draw in and none to put an error on")

        controller.switchOnOffOnePanel()                     // reopen it
        XCTAssertTrue(wait(for: "the deferred reload") { hidden.rows.contains { $0.name == "b.txt" } },
                      "the reload deferred while the panel was closed should run when it is shown")
    }
}
