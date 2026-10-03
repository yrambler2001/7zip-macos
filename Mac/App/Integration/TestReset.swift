// TestReset.swift -- the app side of `Mac/docs/test-support-contract.md`: animation suppression and
// `sevenzip://test/reset`, the command that returns a running app to a known state without quitting.
//
// Why it exists: the UI suite cost 28.7 s per test because every test quit and relaunched the app,
// so the assertions were a rounding error next to process launch. A reset replaces the relaunch.
//
// Why it lives in `Integration`: the reset is one more route into the command layer
// (`Mac/docs/api/finder.md` section 1), delivered by the same `sevenzip://` URL channel as every
// other out-of-process command, and parsed by the same `CommandURL`.
//
// Nothing here does anything unless `SZ_TEST_SUPPORT=1` was in the environment at launch
// (`TestSupport.isEnabled`); `CommandURL.parse` rejects the `test` host outright without it.

import AppKit
import SevenZipKit

// ---------------------------------------------------------------------------
// MARK: - Animation suppression (SZ_DISABLE_ANIMATIONS)

/// Removes animation *time*, not just animation length: the AppKit defaults below turn the
/// automatic window animations off altogether rather than shortening them, and
/// `withoutAnimation` runs a layout change inside a zero-duration, implicit-animation-free
/// grouping so nothing is left to interpolate.
///
/// Three groups are covered, which is what the contract asks for:
///
/// * **dialogs appearing and disappearing** -- `NSAutomaticWindowAnimationsEnabled = NO` covers
///   every window AppKit animates on its own, including `NSAlert`, the sheets
///   (`beginSheetModal`), `NSOpenPanel`/`NSSavePanel` and the modal dialogs this app builds with
///   `DialogKit`; each window this app creates is *also* given `animationBehavior = .none`
///   explicitly, so the suppression does not depend on one default alone.
/// * **window resizing** -- `NSWindowResizeTime` is AppKit's seconds-per-150-points figure used by
///   `setFrame(_:display:animate:)` and by `zoom(_:)`; 0.001 makes it a single frame.
/// * **the split view** -- `MainWindowController` wraps every divider move, every panel
///   insertion/removal and every frame change in `withoutAnimation`.
enum TestAnimations {

    /// Registered in `applicationWillFinishLaunching`, before any window exists. The registration
    /// domain is used rather than the app domain so nothing is persisted into the settings file a
    /// test seeded, and nothing is written to the user's real defaults.
    static let defaults: [String: Any] = [
        "NSAutomaticWindowAnimationsEnabled": false,
        "NSWindowResizeTime": 0.001,
        "NSScrollAnimationEnabled": false,
        "NSScrollViewRubberbanding": false,
        "NSDocumentRevisionsWindowTransformAnimation": false,
        "NSToolbarFullScreenAnimationDuration": 0.0,
        "NSBrowserColumnAnimationSpeedMultiplier": 0.0,
        "QLPanelAnimationDuration": 0.0,
    ]

    private static var installed = false

    static var isDisabled: Bool { TestSupport.animationsDisabled }

    /// Call before the first window is created; harmless to call twice.
    static func installIfNeeded() {
        guard isDisabled, !installed else { return }
        installed = true
        UserDefaults.standard.register(defaults: defaults)
        // Window tabbing, as the contract asks: a tabbed window changes the accessibility tree a
        // test walks, and the tab-bar show/hide is itself animated.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    /// Applied to every window this app creates. Without animations disabled this is a no-op, so
    /// the call can sit unconditionally next to the window's construction.
    static func apply(to window: NSWindow?) {
        guard isDisabled, let window else { return }
        window.animationBehavior = .none
        window.tabbingMode = .disallowed
    }

    /// Runs `body` with no implicit animation and a zero duration. Used for the layout changes
    /// AppKit would otherwise interpolate (the split view, a window frame change).
    static func withoutAnimation(_ body: () -> Void) {
        guard isDisabled else { return body() }
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        NSAnimationContext.current.allowsImplicitAnimation = false
        body()
        NSAnimationContext.endGrouping()
    }
}

// ---------------------------------------------------------------------------
// MARK: - The reset command

/// `sevenzip://test/reset?<query>`.
///
/// The hard part is not the settings but the honesty of "a known state": an operation may be
/// running on a worker thread with a modal progress dialog on the stack, a question dialog may be
/// nested inside that, and the panel's `SZFolder` is owned by the panel's serial queue. So the
/// reset is a small state machine rather than a function:
///
/// 1. **ask everything to stop** -- cancel tracking in the menus, cancel every live
///    `OperationRunner` (which makes the worker's next `progressCheckBreak` return `E_ABORT`), end
///    every sheet, abort the innermost modal session and order every secondary window out;
/// 2. **wait until it really has** -- a 20 ms timer in `.common` mode (a main-queue block is not
///    delivered reliably while `NSApp.runModal` is on the stack, which is why `OperationRunner`
///    uses a timer too) re-aborts each newly exposed modal session as the stack unwinds, and only
///    continues once no operation is live, no modal window is up and no secondary window is
///    visible;
/// 3. **reload settings** -- optionally replace the whole domain from a plist, switch the language
///    the way the Options > Language page does, then rebuild the menu bar and the toolbars and tell
///    every settings group to re-read;
/// 4. **rebuild both panels** -- panel count, paths, view mode, and selection / sort / flat mode
///    back to their defaults, each panel's folder chain released **on the queue that owns it**;
/// 5. **signal** -- bump the generation, publish it as the main window's accessibility value, and
///    only then write the acknowledgement file.
///
/// Steps 2 and 3-4 each have a deadline of `settleTimeout`, and step 5 runs when either expires. The
/// acknowledgement is therefore **unconditional**: a reset that could not settle still bumps the
/// generation, still writes the ack, and leaves a note beside it naming the step that stalled and what
/// was still up. A test then fails with that message instead of timing out with nothing, which is the
/// difference between a diagnosis and a shrug (`Mac/docs/reports/fastui.md` section 6.10).
enum TestResetCoordinator {

    /// Number of completed resets. Published as the main window's accessibility value and written
    /// into the acknowledgement file; `0` before the first reset, exactly as the contract says.
    private(set) static var generation = 0

    /// How long each half of the reset may take before it gives up waiting and carries on regardless:
    /// step 2's settle, and then steps 3-4 together. A reset that never finished would be worse than
    /// one that finished with a warning -- the test would hang on the acknowledgement instead of
    /// failing with a message that says which step stalled. `var`, so a test can shorten it.
    static var settleTimeout: TimeInterval = 15
    static let settleInterval: TimeInterval = 0.02

    /// Which step the reset in flight is on; the stall message names it.
    enum Stage: String {
        case idle
        case stopping = "step 1 (stop everything)"
        case settling = "step 2 (wait until it really has stopped)"
        case reloadingSettings = "step 3 (reload the settings)"
        case rebuildingPanels = "step 4 (rebuild the panels)"
        case signalling = "step 5 (signal)"
    }

    private(set) static var stage: Stage = .idle
    /// Why the last reset did not settle cleanly, or nil when it did. Logged, and written next to the
    /// acknowledgement file so a test can quote it instead of reporting a bare timeout.
    private(set) static var lastStall: String?

    private static var current: TestResetRequest?
    private static var queued: TestResetRequest?
    private static var timer: Timer?
    private static var finishGuard: Timer?
    private static var deadline = Date.distantPast
    /// Identifies the reset in flight, so a panel rebuild that calls back *after* the watchdog has
    /// already acknowledged cannot finish the next reset by accident.
    private static var runID = 0
    private static var stall: String?

    static var isResetting: Bool { current != nil }

    /// Entry point from `URLCommands.handle`. Main thread.
    static func handle(_ request: TestResetRequest) -> SevenZipExitCode {
        guard TestSupport.isEnabled else { return .userError }
        for warning in request.warnings { NSLog("7-Zip test reset: %@", warning) }
        if isResetting {
            // Tests do not overlap resets, but a stray second URL must not be lost: it runs after
            // the one in flight, so its acknowledgement still arrives.
            queued = request
            return .success
        }
        begin(request)
        return .success
    }

    // MARK: step 1 -- ask everything to stop

    private static func begin(_ request: TestResetRequest) {
        current = request
        runID += 1
        stall = nil
        stage = .stopping
        deadline = Date().addingTimeInterval(settleTimeout)
        // The ticker is armed **first**, before anything that can unwind the stack. `closeTransientUI`
        // used to call `NSApp.abortModal()`, which raises `NSAbortModalException`; the exception left
        // this function -- and the `CFRunLoopTimer` callback it was running inside -- so the ticker was
        // never created, `current` stayed set, `isResetting` was true for ever and no reset ever
        // acknowledged again. It no longer raises (see `closeTransientUI`), and the order here means
        // that even if something else did, the reset would still have a heartbeat.
        let ticker = Timer(timeInterval: settleInterval, repeats: true) { _ in settleTick() }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
        NSApp.mainMenu?.cancelTrackingWithoutAnimation()
        OperationRunner.cancelActiveOperations()
        stage = .settling
        closeTransientUI()
        settleTick()
    }

    /// The main window, i.e. the one window a reset keeps.
    private static var mainWindow: NSWindow? {
        (NSApp.delegate as? AppDelegate)?.mainWindowController?.window
    }

    /// Windows a reset must get rid of: sheets, alerts, dialogs, the Options window, the progress
    /// dialog, the About box. AppKit infrastructure (tool tips, menu shadows, the status bar) is
    /// left alone -- it is not app state and ordering it out would be a side effect of its own.
    private static func transientWindows() -> [NSWindow] {
        let main = mainWindow
        return NSApp.windows.filter { window in
            guard window !== main, window.isVisible else { return false }
            return window.isSheet || window.styleMask.contains(.titled) || window is NSPanel
        }
    }

    private static func closeTransientUI() {
        for window in transientWindows().reversed() {
            if let savePanel = window as? NSSavePanel {
                savePanel.cancel(nil)            // NSOpenPanel too: it is an NSSavePanel subclass
            }
            if let parent = window.sheetParent {
                parent.endSheet(window, returnCode: .cancel)
            }
            if NSApp.modalWindow === window {
                stopModalSession()
            }
            // No fade. The settle ticker calls this every 20 ms until the window is gone, and
            // ordering a window out again while AppKit is still animating it out over-releases the
            // `_NSWindowTransformAnimation` it made for the first call -- a `EXC_BAD_ACCESS` in
            // `objc_release` under `CA::Transaction::commit`, measured once in the app-hosted suite. A
            // reset is tearing the UI down, not presenting it, so there is nothing to animate anyway.
            window.animationBehavior = .none
            window.orderOut(nil)
            // A second file-manager window (File > New Window, a reopen, an archive from Finder:
            // `MainWindows`) is closed rather than hidden, so it leaves the window list and the
            // next test starts with the one window a launch has. It does not save: step 3 is about
            // to replace the settings, and in a UI test the domain is the seed file the test has
            // just rewritten.
            if let controller = window.windowController as? MainWindowController {
                controller.closeDiscardingState()
            }
        }
        // A modal session whose window is already gone (or one belonging to an alert AppKit has
        // not listed yet) still has to be told to stop, or the stack never unwinds.
        if NSApp.modalWindow != nil { stopModalSession() }
    }

    /// Ends the innermost modal session **without raising**.
    ///
    /// This is the fix for the wedge of `Mac/docs/reports/fastui.md` section 6.10, and the reason the
    /// reset used to give up for good rather than after 15 s. `NSApp.abortModal()` is documented to
    /// raise `NSAbortModalException`, and both callers of `closeTransientUI` run inside a
    /// `CFRunLoopTimer` callback (the settle ticker, and `TestResetWatcher.poll` by way of `begin`).
    /// An exception that unwinds out of a timer callback leaves that timer marked as firing, so the
    /// run loop never fires it again: one ownerless `NSAlert` therefore killed the settle ticker *and*
    /// the request watcher, and no reset could be delivered or acknowledged for the rest of the
    /// process's life. The observed symptom was exactly that -- "generation was 0, is now 0; the
    /// request file was taken".
    ///
    /// `stopModal(withCode:)` sets the session's stop flag instead of throwing, and the modal loop
    /// notices when it next dequeues an event -- so one is posted. The settle ticker keeps calling
    /// this every 20 ms, which is what unwinds a stack of nested sessions one layer per tick.
    private static func stopModalSession() {
        NSApp.stopModal(withCode: .abort)
        guard let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                            modifierFlags: [],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: 0, context: nil,
                                            subtype: 0, data1: 0, data2: 0) else { return }
        NSApp.postEvent(wake, atStart: true)
    }

    // MARK: step 2 -- wait until it really has

    private static var hasSettled: Bool {
        !OperationRunner.hasActiveOperation && NSApp.modalWindow == nil && transientWindows().isEmpty
    }

    /// What is still up, for the stall message. A diagnostic that names the obstacle is worth more
    /// than a clean-looking timeout in the test log.
    private static var settleObstacles: String {
        var parts: [String] = []
        if OperationRunner.hasActiveOperation { parts.append("an operation is still running") }
        if let modal = NSApp.modalWindow {
            parts.append("an app-modal session is up (\(type(of: modal)), "
                         + (modal.sheetParent == nil ? "owned by no window" : "a sheet") + ")")
        }
        let transient = transientWindows()
        if !transient.isEmpty {
            parts.append("\(transient.count) window(s) would not go: "
                         + transient.map { "\(type(of: $0))" }.joined(separator: ", "))
        }
        return parts.isEmpty ? "nothing, in fact" : parts.joined(separator: "; ")
    }

    private static func settleTick() {
        guard let request = current, stage == .settling else { return }
        if !hasSettled {
            guard Date() >= deadline else {
                // Each unwound layer can expose the next modal session; keep telling them to go.
                closeTransientUI()
                return
            }
            record(stall: "\(Stage.settling.rawValue) timed out after \(Int(settleTimeout)) s: "
                          + settleObstacles)
        }
        timer?.invalidate()
        timer = nil
        // Steps 3 and 4 get a deadline of their own. Step 4 hands the panels a completion block, and
        // a block that never arrives (a panel queue parked behind a folder nobody released, say) used
        // to mean no acknowledgement at all, which a test can only report as a bare timeout.
        armFinishGuard(request, runID)
        stage = .reloadingSettings
        applySettings(request)
        stage = .rebuildingPanels
        rebuild(request)
    }

    /// Writes the acknowledgement whatever happens, `settleTimeout` after step 2 ended.
    private static func armFinishGuard(_ request: TestResetRequest, _ id: Int) {
        finishGuard?.invalidate()
        let guardTimer = Timer(timeInterval: settleTimeout, repeats: false) { _ in
            guard current != nil, runID == id else { return }
            record(stall: "\(stage.rawValue) did not finish within \(Int(settleTimeout)) s: "
                          + settleObstacles)
            finish(request, id)
        }
        RunLoop.main.add(guardTimer, forMode: .common)
        finishGuard = guardTimer
    }

    private static func record(stall message: String) {
        stall = stall.map { $0 + " | " + message } ?? message
        NSLog("7-Zip test reset: %@", message)
    }

    // MARK: step 3 -- reload settings

    private static func applySettings(_ request: TestResetRequest) {
        if let path = request.defaultsPath {
            if !Settings.replaceDomainContents(fromPlistAt: path) {
                NSLog("7-Zip test reset: cannot read the defaults plist at %@", path)
            }
        }
        if let language = request.language {
            // The Options > Language page applies the switch live and posts the group notification
            // before the key is written (`Mac/docs/api/options.md` section 4); writing the key is
            // what posts it here, and the reload below is the "applied" half.
            Settings.language = language
        }
        Lang.loadFromSettings()
        SZFolder.timestampShowUTC = Settings.timestampShowUTC      // g_Timestamp_Show_UTC
        Settings.notifyAllGroups()
        OptionsPostApply.reloadLangItems()                         // MyLoadMenu(true) + ReloadToolbars
    }

    // MARK: steps 4 and 5 -- rebuild the panels, then signal

    private static func rebuild(_ request: TestResetRequest) {
        let id = runID
        guard let controller = (NSApp.delegate as? AppDelegate)?.mainWindowController else {
            record(stall: "\(Stage.rebuildingPanels.rawValue) skipped: there is no main window")
            finish(request, id)
            return
        }
        controller.resetForTest(request) { finish(request, id) }
    }

    /// Step 5. Runs exactly once per reset -- `runID` drops a panel rebuild that calls back after the
    /// watchdog has already acknowledged -- and it runs whether or not the reset settled, because a
    /// test that is told "generation 4, and here is what did not settle" can fail with a message,
    /// while a test that is told nothing can only time out.
    private static func finish(_ request: TestResetRequest, _ id: Int) {
        guard current != nil, runID == id else { return }
        timer?.invalidate()
        timer = nil
        finishGuard?.invalidate()
        finishGuard = nil
        stage = .signalling
        generation += 1
        lastStall = stall
        // Signal 1: the main window's accessibility value, for a test that polls instead of
        // watching a file.
        mainWindow?.setAccessibilityValue(String(generation))
        // The stall note goes out *before* the acknowledgement, so a test that has seen the ack can
        // trust the note next to it -- and a clean reset removes a note an earlier one left, so a
        // stale file can never be read as this reset's diagnosis.
        writeStallNote(for: request)
        // Signal 2: the acknowledgement file, written last of all and atomically, so a poller
        // never sees a half-written generation.
        if let ackPath = request.ackPath {
            let url = URL(fileURLWithPath: ackPath)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            do {
                try Data(String(generation).utf8).write(to: url, options: .atomic)
            } catch {
                NSLog("7-Zip test reset: cannot write the ack file %@: %@", ackPath,
                      error.localizedDescription)
            }
        }
        stage = .idle
        current = nil
        stall = nil
        if let next = queued {
            queued = nil
            begin(next)
        }
    }

    /// `<ack>.stall`, or `<SZ_STATE_DIR>/reset-stall` when the request named no ack file. Present only
    /// when this reset did not settle; removed otherwise.
    static func stallNotePath(for request: TestResetRequest) -> String? {
        if let ackPath = request.ackPath { return ackPath + ".stall" }
        guard let state = TestSupport.stateDirectory else { return nil }
        return (state as NSString).appendingPathComponent("reset-stall")
    }

    private static func writeStallNote(for request: TestResetRequest) {
        guard let path = stallNotePath(for: request) else { return }
        guard let stall else {
            try? FileManager.default.removeItem(atPath: path)
            return
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? Data("\(generation): \(stall)\n".utf8).write(to: url, options: .atomic)
    }

    /// The value the main window publishes before the first reset.
    static var initialAccessibilityValue: String { String(generation) }
}

// ---------------------------------------------------------------------------

/// A second delivery channel for exactly the same `sevenzip://test/reset` URL, because the first one
/// cannot be aimed at one instance and cannot get through a modal session.
///
/// **Measured, and the reason this exists.** `NSWorkspace.open(URL)` hands a `sevenzip://` URL to
/// whichever bundle Launch Services currently considers the scheme's handler. As soon as a second
/// copy of the app is built -- which is the case this contract exists to support -- that is a
/// different bundle than the one the test launched: with two extra probe bundles registered on this
/// machine, `urlForApplication(toOpen:)` named a probe, and every reset a UI test sent went to it
/// instead of the app under test. `open(_:withApplicationAt:)` *can* aim, and does (the
/// out-of-process driver in `Mac/docs/reports/resetcmd.md` uses it), but a **sandboxed** XCUITest
/// runner cannot reliably resolve a bundle URL outside its container to aim with.
///
/// So when a state directory is set, the app also watches `<SZ_STATE_DIR>/reset-request` and treats
/// its contents as the URL. The state directory belongs to exactly one instance, so a request left
/// there can only reach that instance. And the watcher is a `Timer` in `.common` mode rather than an
/// Apple event, so a reset is delivered even while `NSApp.runModal` is on the stack -- which is
/// precisely the case the contract's "cancel or finish any running operation" has to cover.
///
/// The shape of the command is unchanged: the file holds the same URL, parsed by the same
/// `CommandURL.parse`, and the `sevenzip://` route is untouched.
enum TestResetWatcher {

    /// `<SZ_STATE_DIR>/reset-request`.
    static let requestFileName = "reset-request"
    /// 20 ms: fast enough to be invisible next to a panel rebuild, cheap enough to ignore -- and it
    /// only ever runs under `SZ_TEST_SUPPORT` with a state directory.
    static let pollInterval: TimeInterval = 0.02

    private static var timer: Timer?

    static var requestPath: String? {
        guard let state = TestSupport.stateDirectory else { return nil }
        return (state as NSString).appendingPathComponent(requestFileName)
    }

    static func startIfNeeded() {
        guard TestSupport.isEnabled, timer == nil, requestPath != nil else { return }
        let ticker = Timer(timeInterval: pollInterval, repeats: true) { _ in poll() }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    private static func poll() {
        guard let path = requestPath,
              let data = FileManager.default.contents(atPath: path) else { return }
        // Removed before it is acted on, so a slow command cannot be started twice.
        try? FileManager.default.removeItem(atPath: path)
        let text = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text) else {
            NSLog("7-Zip test reset: %@ is not a URL: %@", requestFileName, text)
            return
        }
        // A reset is handled inline because it never blocks: `TestResetCoordinator.handle` arms its
        // own timer and returns. Anything else -- a `sevenzip:///run` command, say -- *does* block,
        // for as long as its progress dialog is up, and **a CFRunLoopTimer is not re-entrant**: while
        // its callback is on the stack the run loop will not fire that timer again, however long the
        // callback takes and whatever mode the nested loop spins in. Running a blocking command
        // straight from here would therefore wedge this watcher for the duration and make the reset
        // that was supposed to cancel that very command undeliverable. Measured: a
        // `sevenzip:///run?argv=["h",…]` handled inline stopped every later reset dead.
        if url.host?.lowercased() == CommandURL.testHost {
            URLCommands.handle(url)
        } else {
            DispatchQueue.main.async { URLCommands.handle(url) }
        }
    }
}
