// AppDelegate.swift -- application entry point (7zFM WinMain2 equivalent, FM.cpp:577).
// No nib: the menu bar and the main window are built in code.

import Cocoa
import SevenZipKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Entry point. There is no nib to instantiate the delegate, so it is created here and
    /// attached before the run loop starts (NSApplicationMain would only load NSMainNibFile).
    private static let sharedDelegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = sharedDelegate
        app.run()
    }

    /// The oldest open file-manager window (`MainWindows.primary`); nil when none is open. Every
    /// window of the process is in `MainWindows.controllers`.
    var mainWindowController: MainWindowController? { MainWindows.primary }

    /// False until `applicationDidFinishLaunching`. Documents of a cold launch arrive before it
    /// (`application(_:open:)` precedes `applicationDidFinishLaunching`), and then they are the
    /// launch's windows: the default window is not created next to them.
    private(set) var hasFinishedLaunching = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Test support (Mac/docs/api/resetcmd.md) comes first: `prepareForLaunch` may point the
        // settings domain at the instance's own state directory, so it has to run before anything
        // reads a setting, and the animation defaults have to be registered before any window is
        // created. Both are no-ops unless SZ_TEST_SUPPORT=1 is in the environment.
        TestSupport.prepareForLaunch()
        TestAnimations.installIfNeeded()
        // LoadLangOneTime() before anything reads a string (FM.cpp:615)
        Lang.loadFromSettings()
        SZFolder.timestampShowUTC = Settings.timestampShowUTC   // g_Timestamp_Show_UTC
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 7zFM does not load codecs at startup: `LoadGlobalCodecs()` in WinMain2 is commented out,
        // "we will load Global_Codecs at first use instead" (FM.cpp:738-743, 01 §1.1). The window
        // is created first; the format table is built on a worker right after, and every engine
        // entry point (`SZArchiveOpener`, `SZExtractor`, `SZUpdater`, `SZHasher`, `SZBenchmark`)
        // still loads it itself on first use, so nothing depends on this call having finished.
        hasFinishedLaunching = true
        // 7zFM.exe "%1" from Explorer starts a process whose one window shows the archive: when
        // Finder launched the app to open documents, their windows already exist and no empty
        // window is added (Mac/docs/reports/newwindow.md).
        let args = Array(CommandLine.arguments.dropFirst())
        let startPath = args.first.flatMap { $0.hasPrefix("-") ? nil : $0 }
        let controller: MainWindowController? = Self.needsLaunchWindow(
            documentWindows: MainWindows.controllers.count, startPath: startPath) ? MainWindows.open() : nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try SZCodecs.loadCodecs()
            } catch {
                NSLog("7-Zip: codecs failed to load: %@", error.localizedDescription)
            }
        }
        // Not Windows parity (01 §1.1: `DeleteOldTempFiles` has no caller): remove the `7zO*` /
        // `7zE*` folders an earlier run left behind (`TempOpenJanitor.swift`).
        TempOpenJanitor.sweepAtLaunch()

        // 7zFM.exe [path] [-t<arcType>]  (FM.cpp:639-702): a path names the folder or archive
        // panel 0 starts in. Other switches are not parsed by 7zFM either.
        if let controller, let first = startPath {
            let hint = args.dropFirst().first { $0.hasPrefix("-t") }.map { String($0.dropFirst(2)) }
            controller.openStartupPath(first, formatHint: hint, closesWindowOnFailure: true)
        }
        NSApp.activate(ignoringOtherApps: true)

        // Test support: the aimable delivery channel for `sevenzip://test/reset`
        // (Mac/docs/api/resetcmd.md section 5). A no-op unless SZ_TEST_SUPPORT=1 and SZ_STATE_DIR
        // are both set, and it is started last so the window already exists when the first reset
        // arrives.
        TestResetWatcher.startIfNeeded()
    }

    /// Whether `applicationDidFinishLaunching` creates the default window. Not when the launch
    /// was for documents -- Launch Services delivers a Finder double-click's open-documents event
    /// *before* `applicationDidFinishLaunching` (measured, Mac/docs/reports/newwindow.md), so their
    /// windows exist by then -- unless a 7zFM argv path also asks for a window of its own.
    static func needsLaunchWindow(documentWindows: Int, startPath: String?) -> Bool {
        documentWindows == 0 || startPath != nil
    }

    /// A re-launch of the running app -- Dock icon click, Finder double-click of 7-Zip.app,
    /// `open -a 7-Zip` (the reopen Apple event, `kAEReopenApplication`) -- is a new 7zFM.exe on
    /// Windows, i.e. a new window (01 §1.1 "Single instance"; user decision,
    /// Mac/docs/reports/newwindow.md). So a window is opened whether windows are open or not, and
    /// AppKit's own reaction (un-minimizing a window) is suppressed by returning false.
    ///
    /// Not in 7zG command mode: that process shows only its command's dialogs and exits when the
    /// command ends (03 §6.4), which would take a window opened here with it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !SevenZipCommandLineEntry.isCommandMode else { return true }
        openNewWindow()
        return false
    }

    /// File > New Window (macOS addition, no Windows resource ID): what a second 7zFM.exe launch
    /// gives on Windows -- a window that starts from the saved settings.
    @objc func fileNewWindow(_ sender: Any?) {
        openNewWindow()
    }

    /// One new file-manager window, in front.
    @discardableResult
    func openNewWindow() -> MainWindowController {
        let controller = MainWindows.open()
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true   // 7zFM: closing the window exits the process (WM_CLOSE -> PostQuitMessage)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // WM_CLOSE order (FM.cpp:1028-1047, 01 §1.1 "Shutdown"): first `g_ExitEventLauncher.Exit`
        // -- every temp-file watcher is finished, which here means the "file was modified, update
        // the archive?" question is asked for each edited item and its watcher stopped --, then
        // `g_App.Save()` and `SaveWindowInfo`. `finishAll` is idempotent, so the manager's own
        // willTerminate observer finds nothing left to do.
        TempOpenManager.shared.finishAll()
        // g_App.Save() + SaveWindowInfo (FM.cpp:1028-1047) for every open window, backmost first,
        // so the frontmost one's state is what the next launch reads (MainWindows.swift).
        MainWindows.saveAllForTermination()
        Settings.synchronize()
        // `FreeGlobalCodecs()` (FM.cpp:776) is left to process exit: a Cmd+Q can arrive while an
        // operation's worker still holds the codecs, and freeing them under it would crash.
    }
}
