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
enum TestResetCoordinator {

    /// Number of completed resets. Published as the main window's accessibility value and written
    /// into the acknowledgement file; `0` before the first reset, exactly as the contract says.
    private(set) static var generation = 0

    /// How long step 2 may take before the reset gives up waiting and carries on regardless. A
    /// reset that never finished would be worse than one that finished with a warning: the test
    /// would hang on the acknowledgement instead of failing with a message.
    static let settleTimeout: TimeInterval = 15
    static let settleInterval: TimeInterval = 0.02

    private static var current: TestResetRequest?
    private static var queued: TestResetRequest?
    private static var timer: Timer?
    private static var deadline = Date.distantPast

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
        deadline = Date().addingTimeInterval(settleTimeout)
        NSApp.mainMenu?.cancelTrackingWithoutAnimation()
        OperationRunner.cancelActiveOperations()
        closeTransientUI()
        let ticker = Timer(timeInterval: settleInterval, repeats: true) { _ in settleTick() }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
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
                NSApp.abortModal()
            }
            window.orderOut(nil)
        }
        // A modal session whose window is already gone (or one belonging to an alert AppKit has
        // not listed yet) still has to be told to stop, or the stack never unwinds.
        if NSApp.modalWindow != nil { NSApp.abortModal() }
    }

    // MARK: step 2 -- wait until it really has

    private static var hasSettled: Bool {
        !OperationRunner.hasActiveOperation && NSApp.modalWindow == nil && transientWindows().isEmpty
    }

    private static func settleTick() {
        guard let request = current else { return }
        if !hasSettled {
            guard Date() >= deadline else {
                // Each unwound layer can expose the next modal session; keep telling them to go.
                closeTransientUI()
                return
            }
            NSLog("7-Zip test reset: gave up waiting for the app to settle after %.0f s "
                  + "(operation: %@, modal: %@, windows: %d)",
                  settleTimeout,
                  OperationRunner.hasActiveOperation ? "yes" : "no",
                  NSApp.modalWindow == nil ? "no" : "yes",
                  transientWindows().count)
        }
        timer?.invalidate()
        timer = nil
        applySettings(request)
        rebuild(request)
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
        guard let controller = (NSApp.delegate as? AppDelegate)?.mainWindowController else {
            finish(request)
            return
        }
        controller.resetForTest(request) { finish(request) }
    }

    private static func finish(_ request: TestResetRequest) {
        generation += 1
        // Signal 1: the main window's accessibility value, for a test that polls instead of
        // watching a file.
        mainWindow?.setAccessibilityValue(String(generation))
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
        current = nil
        if let next = queued {
            queued = nil
            begin(next)
        }
    }

    /// The value the main window publishes before the first reset.
    static var initialAccessibilityValue: String { String(generation) }
}
