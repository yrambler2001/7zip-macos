// ModalProbe.swift -- opens one of the app's dialogs in this process and hands it to a test while
// it is on screen, without a click and without a second process.
//
// The problem it solves. Every dialog of the port is presented the way 7zFM presents its own
// (`DoModal`): a `static func run(...)` builds the window and then blocks in `NSApp.runModal(for:)`
// until a button ends the session. A test cannot call that and then measure the window -- `run`
// does not return until the window is gone, and the controllers are `private`, so the window
// cannot be built without it.
//
// How it works. `NSApp.runModal(for:)` spins a **nested** run loop in `NSModalPanelRunLoopMode`.
// A timer added to that mode before `run()` is called therefore fires *inside* the modal session,
// with the window built, ordered front and laid out. The probe:
//
//   1. adds a repeating timer to `.modalPanel` and `.default`;
//   2. calls `present()`, which blocks in `runModal` (or, for the Options window, returns at once);
//   3. from the timer, finds the window that came up, forces a layout pass, calls `body`, and ends
//      the modal session with `NSApp.stopModal()`, so `run()` returns its "cancelled" answer;
//   4. if no window turns up before `timeout`, it ends the session anyway and reports false, so a
//      dialog that fails to appear fails the test instead of hanging the run.
//
// No sleeps: the timer is a poll of a *condition* (a new visible window), and the deadline is the
// failure path, not the happy path.

import AppKit
import XCTest

enum ModalProbe {

    /// Present a dialog and inspect its window while it is up.
    ///
    /// - Parameters:
    ///   - present: the app's own presentation call, e.g. `{ _ = CopyMoveDialog.run(...) }`. It may
    ///     block in `NSApp.runModal`; that is the normal case.
    ///   - timeout: how long to wait for the window to appear before giving up.
    ///   - body: called once, on the main thread, with the window that came up.
    /// - Returns: false when no window appeared (the test should fail on that).
    @discardableResult
    static func present(timeout: TimeInterval = 30,
                        _ present: () -> Void,
                        inspect body: @escaping (NSWindow) -> Void) -> Bool {
        XCTAssertTrue(Thread.isMainThread, "ModalProbe must be driven from the main thread")
        let known = Set(NSApp.windows.filter { $0.isVisible }.map(ObjectIdentifier.init))
        var inspected = false
        let deadline = Date().addingTimeInterval(timeout)

        let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
            guard !inspected else { return }
            if Date() > deadline {
                timer.invalidate()
                if NSApp.modalWindow != nil { NSApp.stopModal() }
                return
            }
            guard let window = candidate(excluding: known) else { return }
            // Wait until it really is on screen and sized; a window is in `NSApp.windows` from the
            // moment it is created.
            guard window.isVisible, window.frame.width > 1, window.frame.height > 1 else { return }
            inspected = true
            timer.invalidate()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            body(window)
            if NSApp.modalWindow != nil { NSApp.stopModal() }
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .eventTracking)

        present()

        // A non-modal presentation (`OptionsWindowController.showOptions`) returns immediately, so
        // nothing has spun a run loop yet: do it here until the probe has run.
        while !inspected, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        timer.invalidate()
        return inspected
    }

    /// The window a presentation just put on screen: the modal window if there is one, else the
    /// newest visible window that was not there before.
    private static func candidate(excluding known: Set<ObjectIdentifier>) -> NSWindow? {
        if let modal = NSApp.modalWindow { return modal }
        return NSApp.windows.last {
            $0.isVisible && !known.contains(ObjectIdentifier($0)) && !($0 is NSPanel && $0.title.isEmpty)
        }
    }

    /// Close a window a non-modal presentation left open, and wait until it is really gone.
    static func close(_ window: NSWindow) {
        window.orderOut(nil)
        var spins = 0
        while window.isVisible, spins < 50 {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            spins += 1
        }
    }
}
