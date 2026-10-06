// GMode.swift -- "7zG mode": a command that came from outside the app runs the way 7zG.exe runs it.
//
// On Windows every shell entry (the Explorer context menu, a drop on the 7-Zip icon, a command line)
// starts **7zG.exe**, a separate GUI process with no file-manager window (03-shell-integration-
// inventory.md section 1.5, section 2; CompressCall.cpp:74-98). Its dialog, then its progress window,
// then its message boxes appear on their own, centred on the screen, and the process exits when the
// command ends -- OK, Cancel or an error. 7zFM is not involved, so its windows neither appear nor
// move. The macOS port has one binary, so this file makes the app behave like that second process
// whenever a command arrives from Finder, a Quick Action, a Service, a `sevenzip://` URL, a Dock drop
// or a 7zG command line:
//
//  * **No file-manager window is created for it.** A command that arrives before
//    `applicationDidFinishLaunching` (Launch Services delivers the launch's `GURL` / `odoc` event
//    first -- measured, reports/gmode.md section 2) is queued, the launch is marked as "for a
//    command", and `AppDelegate` creates no default window. The command runs once launching is done,
//    outside the Apple-event handler.
//  * **Its dialogs are not attached to file-manager windows.** While a command runs, `DialogKit`
//    never picks a file-manager window as an owner, so the dialogs are free windows centred on the
//    work area, as DS_CENTER centres an ownerless 7zG dialog (wincompare-data/win/dlg-compress.txt,
//    dlg-extract.txt: both centred on the 1920 x 1032 work area while 7zFM sat elsewhere).
//  * **It ends like 7zG.** A launch that existed only for commands quits when the last one ends and
//    no file-manager window was opened by it ("Open archive" is 7zFM.exe on Windows, so it opens one
//    window and the app stays). A running app keeps running, gives the focus back to the app that
//    had it (7zG's window disappears and Windows activates the next window, Explorer), and refreshes
//    its panels, as 7zFM re-reads a folder after a change.

import AppKit
import os

private let log = Logger(subsystem: "com.yrambler2001.7zip", category: "GMode")

enum GMode {

    // MARK: - State

    /// How many shell commands are running right now (a second one can arrive while the first one's
    /// dialog is up, because Apple events are served inside the modal session).
    private(set) static var depth = 0

    /// True while a shell command runs: dialogs do not attach to file-manager windows.
    static var isActive: Bool { depth > 0 }

    /// The process was launched to run a command (the command arrived before
    /// `applicationDidFinishLaunching`, or argv is a 7zG command line). Such a launch creates no
    /// file-manager window and quits when its commands are done, as 7zG.exe does.
    private(set) static var launchedForCommand = false

    /// Commands that arrived before launching finished, in arrival order.
    private static var queued: [() -> Void] = []

    /// False until the commands queued during the launch have been started.
    private static var launchDrained = false

    /// How the app quits once a command-only launch is done. Tests replace it.
    static var terminate: () -> Void = { NSApp.terminate(nil) }

    /// Commands that finished, for the tests.
    private(set) static var completedCommands = 0

    // MARK: - Entry

    /// Runs `command` now, or -- when the app is still launching -- once it has finished launching,
    /// and marks the launch as one made for a command. Every shell route calls this from its Apple
    /// event handler (`application(_:open:)`), so a command never runs before the app is up.
    static func submit(_ command: @escaping () -> Void) {
        let finished = (NSApp.delegate as? AppDelegate)?.hasFinishedLaunching ?? true
        if let pending = pendingLaunchWindow {
            // The event this launch was waiting for is a command: the default window is not wanted.
            pending.cancel()
            pendingLaunchWindow = nil
            launchedForCommand = true
            log.log("launch is for a command (arrived after launching): no file-manager window")
        }
        if !finished {
            if !launchedForCommand { log.log("launch is for a command: no file-manager window") }
            launchedForCommand = true
            queued.append(command)
            return
        }
        if !launchDrained, !queued.isEmpty {
            queued.append(command)          // keep the order of what arrived during the launch
            return
        }
        command()
    }

    // MARK: - The launch window

    /// How long a launch with no `oapp` event waits for its command before it shows the default
    /// window after all. The `GURL` arrived about 30 ms after `applicationDidFinishLaunching` in the
    /// measured launches.
    static var launchWindowGrace: TimeInterval = 1.5

    private static var pendingLaunchWindow: DispatchWorkItem?

    /// Whether `event` is the plain "open application" event of a default launch (Finder, the Dock,
    /// Spotlight, `open -a`, a direct exec). A launch for a URL or a Service has none.
    static func isOpenApplicationEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        guard let event else { return false }
        return event.eventClass == AEEventClass(kCoreEventClass) && event.eventID == AEEventID(kAEOpenApplication)
    }

    /// The default window of a launch that was made for some event still on its way (no `oapp`):
    /// shown after `launchWindowGrace` unless a command arrives first or a window exists by then.
    static func deferLaunchWindow(_ open: @escaping () -> Void) {
        let item = DispatchWorkItem {
            pendingLaunchWindow = nil
            guard !launchedForCommand, MainWindows.controllers.isEmpty else { return }
            log.log("no command arrived for this launch: opening the default window")
            open()
        }
        pendingLaunchWindow = item
        DispatchQueue.main.asyncAfter(deadline: .now() + launchWindowGrace, execute: item)
    }

    /// Whether the default window is still waiting for the launch's command (tests).
    static var isLaunchWindowPending: Bool { pendingLaunchWindow != nil }

    /// Marks the launch as one made for a command without queueing anything: the 7zG argv
    /// (`CommandLineEntry`), which `applicationDidFinishLaunching` itself starts.
    static func markLaunchForCommand() {
        launchedForCommand = true
    }

    /// Called once `applicationDidFinishLaunching` is done (the notification observer installed by
    /// `FinderIntegration`). Starts the queued commands from the main run loop, so the launch event
    /// is answered first and the modal sessions run at the top level.
    static func launchDidFinish() {
        DispatchQueue.main.async {
            while !queued.isEmpty {
                let command = queued.removeFirst()
                command()
            }
            launchDrained = true
            if launchedForCommand { scheduleQuitIfDone() }
        }
    }

    /// One shell command. `body` gets the window its dialogs should belong to, which in this mode is
    /// always none: the dialogs are top-level windows like 7zG's.
    @discardableResult
    static func run<T>(_ body: () -> T) -> T {
        let wasActive = NSApp.isActive
        let previousApp = NSWorkspace.shared.frontmostApplication
        let windowsBefore = MainWindows.controllers.map(ObjectIdentifier.init)
        depth += 1
        // The app activates when the command's first window comes up (`prepareModal`), not here:
        // activating now would raise the file-manager window that is main, before any dialog exists.
        if !wasActive { pendingActivation = true }
        let result = body()
        if depth == 1 { pendingActivation = false }
        depth -= 1
        completedCommands += 1
        guard depth == 0 else { return result }

        let windowsAfter = MainWindows.controllers.map(ObjectIdentifier.init)
        if !windowsAfter.isEmpty {
            // 7zFM re-reads a folder after a change (RefreshListCtrl_SaveFocused); a 7zG run is such
            // a change for whatever folder the panels show.
            for controller in MainWindows.controllers where !controller.isClosed {
                controller.refreshAllPanels()
            }
        }
        if launchedForCommand {
            scheduleQuitIfDone()
        } else if changesActivation, !wasActive, windowsAfter == windowsBefore, let previousApp,
                  previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  !previousApp.isTerminated {
            // 7zG's window is gone, so Windows activates the next window (Explorer); the 7zFM
            // windows stay where they were. Not when the command opened a window of its own.
            previousApp.activate()
        }
        return result
    }

    /// The app still has to be activated for the running command (it was not active when it began).
    private static var pendingActivation = false

    /// False in the app-hosted tests, which must not move the focus between applications.
    static var changesActivation = true

    /// Called by `DialogKit.runModal(for:)` before every modal session. The command's first window
    /// becomes key and main and only then is the app activated, so the dialog is the window that
    /// comes forward and takes the focus, as 7zG's dialog is the foreground window, and no
    /// file-manager window is raised with it (activation brings the main and key windows forward).
    static func prepareModal(_ window: NSWindow) {
        guard isActive else { return }
        window.makeKeyAndOrderFront(nil)
        if window.canBecomeMain { window.makeMain() }
        guard pendingActivation, changesActivation else { return }
        pendingActivation = false
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Quits a command-only launch once nothing is left: no command running or queued, no
    /// file-manager window (the command may have opened one, as "Open archive" does), and no other
    /// window on screen. Checked from the run loop, so an event already waiting gets in first.
    private static func scheduleQuitIfDone() {
        DispatchQueue.main.async {
            guard shouldQuit else { return }
            log.log("command-only launch is done: quitting")
            terminate()
        }
    }

    /// Whether a command-only launch has nothing left to show (see `scheduleQuitIfDone`).
    static var shouldQuit: Bool {
        shouldQuit(launchedForCommand: launchedForCommand, running: depth, queued: queued.count,
                   launchDrained: launchDrained, fileManagerWindows: MainWindows.controllers.count,
                   modal: NSApp.modalWindow != nil,
                   visibleWindows: NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.count)
    }

    /// The decision itself, unit-tested: 7zG exits when its command is done; a launch that only
    /// ran commands does the same unless something of the file manager is still on screen.
    static func shouldQuit(launchedForCommand: Bool, running: Int, queued: Int, launchDrained: Bool,
                           fileManagerWindows: Int, modal: Bool, visibleWindows: Int) -> Bool {
        launchedForCommand && running == 0 && queued == 0 && launchDrained
            && fileManagerWindows == 0 && !modal && visibleWindows == 0
    }

    /// Whether a window may own a dialog right now: in this mode, never a file-manager window.
    static func mayOwnDialogs(_ window: NSWindow) -> Bool {
        !(isActive && window.windowController is MainWindowController)
    }

    // MARK: - Tests

    /// Puts the state back (app-hosted tests only).
    static func resetForTesting(launchedForCommand launched: Bool = false) {
        depth = 0
        queued = []
        launchDrained = true
        launchedForCommand = launched
        completedCommands = 0
        pendingLaunchWindow?.cancel()
        pendingLaunchWindow = nil
        launchWindowGrace = 1.5
        terminate = { NSApp.terminate(nil) }
        pendingActivation = false
    }
}
