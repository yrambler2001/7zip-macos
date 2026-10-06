// ReopenSender.swift -- who asked a running 7-Zip to "open" again: the Dock, or a launcher.
//
// A Dock click on the running app and a second launch from Finder / Spotlight / Launchpad /
// `open -a` all reach the app as the same reopen Apple event (`kAEReopenApplication`, 'aevt'/'rapp')
// and end in `applicationShouldHandleReopen`. The user wants them to differ (user request 7,
// ai/reports/appfeel.md):
//
//   * a Dock click shows the windows that are open (the macOS convention), and
//   * a launch from anywhere else opens a new window, as a second 7zFM.exe does on Windows
//     (01 §1.1 "Single instance": every launch is a process with one window; reports/newwindow.md).
//
// The event carries its sender: Launch Services sends a reopen from *the process that asked*, so
// `keySenderPIDAttr` is the Dock for a Dock click, Finder for a double-click, `/usr/bin/open` for
// `open -a`, and the test runner for `NSWorkspace.openApplication` (measured on macOS 26 with a probe
// app that logged every reopen, reports/appfeel.md §1). The pid is resolved to a bundle identifier,
// and only `com.apple.dock` counts as a Dock click. A sender that has exited by the time the event is
// handled (`open -a` does) is a launcher too: the Dock never exits. An event with no sender at all
// (no current event, no pid, the app itself) falls back to the safe choice: show what is open,
// never a surprise window.
//
// Limitation: on macOS 14 and 15 Launchpad is drawn by the Dock process, so a launch from Launchpad
// reports the Dock and shows the open windows instead of opening a new one.

import AppKit

enum ReopenSender {

    /// What the reopen event's sender says about the user's gesture.
    enum Kind: Equatable {
        /// A click on the app's Dock icon (sender `com.apple.dock`).
        case dock
        /// A launch of the running app from Finder, Spotlight, `open -a`, another app.
        case launcher(String)
        /// No usable sender: treated like the Dock (show what is open).
        case unknown
    }

    static let dockBundleIdentifier = "com.apple.dock"
    static let dockExecutablePath = "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"

    /// The sender of the Apple event being handled, when it is a reopen event: its pid, bundle
    /// identifier and executable path (each nil when it cannot be found).
    struct Sender: Equatable {
        var pid: pid_t
        var bundleIdentifier: String?
        var executablePath: String?
    }

    /// Reads `NSAppleEventManager.shared().currentAppleEvent`; nil outside a reopen event (a test
    /// calling the delegate directly, or AppKit calling it for another reason).
    static func current() -> Sender? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventClass == AEEventClass(kCoreEventClass),
              event.eventID == AEEventID(kAEReopenApplication) else { return nil }
        let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value ?? 0
        guard pid > 0 else { return Sender(pid: 0) }
        var bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        if bundleIdentifier == nil, NSRunningApplication.runningApplications(
            withBundleIdentifier: dockBundleIdentifier).contains(where: { $0.processIdentifier == pid }) {
            bundleIdentifier = dockBundleIdentifier
        }
        return Sender(pid: pid, bundleIdentifier: bundleIdentifier, executablePath: executablePath(of: pid))
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// Pure classification, unit-tested (`AppFeelTests`).
    static func classify(_ sender: Sender?, ownPID: pid_t = getpid()) -> Kind {
        guard let sender, sender.pid > 0, sender.pid != ownPID else { return .unknown }
        if sender.bundleIdentifier == dockBundleIdentifier || sender.executablePath == dockExecutablePath {
            return .dock
        }
        // A sender that has already exited is a short-lived launcher -- `open -a` sends the event
        // and quits before it is handled (measured) -- and certainly not the Dock, which stays.
        return .launcher(sender.bundleIdentifier ?? sender.executablePath ?? "exited process \(sender.pid)")
    }

    /// The current event's classification. Debug builds log it (`log stream --predicate
    /// 'process == "7-Zip"' | grep reopen`), which is how the Dock's sender was checked by hand.
    static func classifyCurrent() -> Kind {
        let sender = current()
        let kind = classify(sender)
        #if DEBUG
        NSLog("7-Zip reopen: sender pid %d %@ %@ -> %@", sender?.pid ?? 0,
              sender?.bundleIdentifier ?? "-", sender?.executablePath ?? "-", String(describing: kind))
        #endif
        return kind
    }
}
