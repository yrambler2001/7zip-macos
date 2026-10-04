// MainWindows.swift -- every open 7-Zip File Manager window of this process.
//
// On Windows each `7zFM.exe` launch is a process with one window (01 §1.1 "Single instance": there
// is no single-instance restriction), so starting 7-Zip again while it runs gives a second window,
// and so does opening a second archive from Explorer (`7zFM.exe "%1"`, 03 §6.2). The macOS port is
// one process, so the same thing is done with a window per "launch" inside it (user decision,
// Mac/docs/reports/newwindow.md):
//
//   * a re-launch of the running app -- Finder double-click of the app, Spotlight, `open -a 7-Zip`
//     -- arrives as the reopen Apple event (`applicationShouldHandleReopen`) and opens a window,
//     whether or not windows are already open; a Dock click sends the same event but only shows
//     the open windows (its sender is the Dock: `ReopenSender`, reports/appfeel.md §1);
//   * File > New Window (macOS addition, no Windows resource ID) does the same from the menu;
//   * every archive or folder handed over by Finder / `open` / a 7zFM argv URL gets its own window
//     (`CommandExecutor.openInFileManager`), except that the documents of a cold launch replace the
//     default window instead of opening next to it.
//
// Saved state. Each new window starts from the settings, exactly as a fresh 7zFM process reads the
// registry (`CWindowInfo::Read`, `CApp::Create`): frame, panel count, splitter, panel paths, list
// modes. Each window writes its state back when it closes (WM_CLOSE -> `g_App.Save()` +
// `SaveWindowInfo`, FM.cpp:1028-1047), so the window closed last wins, as the 7zFM process that
// exits last wins on Windows. On Quit the open windows save from the back to the front, so the
// frontmost window's state is the one left -- the same result as closing them one by one from the
// back. A window never saves after it has closed.

import AppKit

enum MainWindows {

    /// Every file-manager window this process opened and has not closed yet, oldest first.
    private(set) static var controllers: [MainWindowController] = []

    /// The oldest open window: what `AppDelegate.mainWindowController` reports, i.e. the window the
    /// test reset keeps and the fallback owner of an ownerless dialog.
    static var primary: MainWindowController? { controllers.first }

    /// The open windows from the frontmost to the backmost (minimized ones last).
    static var frontToBack: [MainWindowController] {
        let ordered = NSApp.orderedWindows.compactMap { window in
            controllers.first { $0.window === window }
        }
        return ordered + controllers.filter { c in !ordered.contains { $0 === c } }
    }

    /// Creates a window from the saved settings, registers it, and -- when `show` is true -- puts
    /// it on screen cascaded from the frontmost file-manager window, if there is one.
    @discardableResult
    static func open(show: Bool = true) -> MainWindowController {
        let anchor = frontToBack.first?.window
        let controller = MainWindowController()
        register(controller)
        if show {
            controller.showWindow(nil)
            if let anchor, anchor.isVisible, let window = controller.window {
                // The saved frame is shared, so a second window would sit exactly on the first.
                // `cascadeTopLeft(from: .zero)` moves nothing and returns the next cascade point.
                window.cascadeTopLeft(from: anchor.cascadeTopLeft(from: .zero))
            }
        }
        return controller
    }

    /// Adds a controller that was created elsewhere. It leaves the list when its window closes.
    static func register(_ controller: MainWindowController) {
        guard !controllers.contains(where: { $0 === controller }) else { return }
        controllers.append(controller)
    }

    /// Called by the controller's `windowWillClose`, after it has saved its state.
    static func didClose(_ controller: MainWindowController) {
        guard controllers.contains(where: { $0 === controller }) else { return }
        controllers.removeAll { $0 === controller }
        // The window is still inside `close()`, and the controller is its delegate: keep the
        // controller alive until that call has returned.
        DispatchQueue.main.async { withExtendedLifetime(controller) {} }
    }

    /// Quit (`applicationWillTerminate`): every open window saves, backmost first, so the frontmost
    /// window's state is what the next launch starts from.
    static func saveAllForTermination() {
        for controller in frontToBack.reversed() where !controller.isClosed {
            controller.saveState()
        }
    }
}
