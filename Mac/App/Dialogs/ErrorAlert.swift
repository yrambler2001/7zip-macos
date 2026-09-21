// ErrorAlert.swift -- the one rule about where a message box goes.
//
// The defect this file exists for (`Mac/docs/reports/fastui.md` section 6.10).
// `PanelViewController.showError` chose its presentation on `view.window`: a sheet when the panel had
// a window, `NSAlert.runModal()` when it did not. A panel closed at runtime (F9 /
// IDM_VIEW_TWO_PANELS 732) is deliberately kept alive and reused -- 7zFM hides its non-focused panel
// rather than destroying it, and step 4 of `sevenzip://test/reset` rebuilds the hidden one too -- but
// on macOS a view taken out of the split view has no window at all, so `view.window` is nil. When
// that panel's folder was deleted, the failed reload raised an **app-modal alert owned by no
// window**: no parent window could dismiss it, no click could reach it, the reset could not settle
// past it, and every accessibility query afterwards took about six seconds.
//
// The rule, for every presentation in the app:
//
//   * an alert that belongs to a window is a **sheet** of that window. A sheet can be dismissed by
//     its parent, and `TestResetCoordinator.closeTransientUI` (step 1 of the reset) can end it;
//   * an app-modal alert is honest only when the app has **no** window to attach it to. That is the
//     7zG case: a command line or a `sevenzip://` URL handled by a process that never opened a
//     window, where `MessageBoxW(NULL, ...)` is what 7-Zip itself does;
//   * "this *view* has no window" is never the same question as "this *app* has no window". A panel
//     whose view is out of the split view still belongs to the main window -- in 7zFM the hidden
//     panel still has a valid HWND, so `MessageBoxW(_panelHWND, ...)` always had an owner. Ask the
//     owner, not the view.
//
// Parity: 01-fm-feature-inventory.md section 2.8 (the error message boxes), 01b section 4.19.

import AppKit

enum ErrorAlert {

    /// The app's standard message box: title "7-Zip", one OK button, lang 401.
    static func make(message: String, style: NSAlert.Style = .warning) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "7-Zip"
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: Lang.text(401, "OK"))
        return alert
    }

    /// Show `alert` and return at once. A sheet of `window`; with no window at all the message goes
    /// to the log, because an app-modal alert that nothing owns is a wedge, not a message.
    static func present(_ alert: NSAlert, on window: NSWindow?) {
        guard let window else {
            NSLog("7-Zip: %@ (no window to present it on)", alert.informativeText)
            return
        }
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    /// Show `alert` and wait for the answer. A sheet of `window`, kept synchronous by running a
    /// nested modal loop for the sheet -- the same shape as `BrowseDialog.present`, which has done
    /// this for `NSSavePanel` since Wave 1. Without a window (and only then) the alert is app-modal,
    /// which is the 7zG behaviour for a process that has no window.
    @discardableResult
    static func run(_ alert: NSAlert, on window: NSWindow?) -> NSApplication.ModalResponse {
        guard let window else { return alert.runModal() }
        var response: NSApplication.ModalResponse?
        alert.beginSheetModal(for: window) { result in
            response = result
            // Only this alert's own session may be stopped, never a caller's dialog underneath it.
            if NSApp.modalWindow === alert.window { NSApp.stopModal() }
        }
        NSApp.runModal(for: alert.window)
        // The handler runs inside the nested loop; should AppKit have ended that loop when the sheet
        // was ordered out, give the queued handler a moment to deliver the response.
        var attempts = 0
        while response == nil, attempts < 20 {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            attempts += 1
        }
        return response ?? .cancel
    }
}
