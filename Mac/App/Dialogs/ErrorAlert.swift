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
// The rule, for every presentation in the app (since `recheck2` every box is a `WinMessageBox`, a
// Windows-style message box window; the rule is about its owner):
//
//   * a box that belongs to a window is owned by that window (`WinMessageBox`); it is an ordinary
//     titled window that its buttons, Esc, the close box and `TestResetCoordinator.closeTransientUI`
//     (step 1 of the reset) all end -- never an ownerless `NSAlert`;
//   * a box with no owner is honest only when the app has **no** window at all. That is the 7zG
//     case: a command line or a `sevenzip://` URL handled by a process that never opened a window,
//     where `MessageBoxW(NULL, ...)` is what 7-Zip itself does;
//   * "this *view* has no window" is never the same question as "this *app* has no window". A panel
//     whose view is out of the split view still belongs to the main window -- in 7zFM the hidden
//     panel still has a valid HWND, so `MessageBoxW(_panelHWND, ...)` always had an owner. Ask the
//     owner, not the view.
//
// Parity: 01-fm-feature-inventory.md section 2.8 (the error message boxes), 01b section 4.19.

import AppKit

enum ErrorAlert {

    /// MessageBox_Error (Panel.cpp:757-761): caption "7-Zip", OK, MB_ICONSTOP. Returns at once; the
    /// box comes up from the main run loop, owned by `window`. With no window the message goes to
    /// the log: a report from something whose window is gone (a panel of a closed window still
    /// finishing a reload) has nobody to tell, and must not borrow another window.
    static func present(_ message: String, caption: String = "7-Zip", icon: WinMessageBox.Icon = .error,
                        on window: NSWindow?) {
        guard let window else {
            NSLog("7-Zip: %@ (no window to present it on)", message)
            return
        }
        WinMessageBox.show(message, caption: caption, icon: icon, owner: window)
    }

    /// The same box, waiting for it to be dismissed. With no window anywhere it is centred on the
    /// screen with no owner -- the 7zG behaviour for a process that has no window.
    @discardableResult
    static func run(_ message: String, caption: String = "7-Zip", icon: WinMessageBox.Icon = .error,
                    on window: NSWindow?) -> WinMessageBox.Result {
        WinMessageBox.run(message, caption: caption, icon: icon, owner: window)
    }
}
