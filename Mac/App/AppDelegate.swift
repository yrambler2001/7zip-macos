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

    private(set) var mainWindowController: MainWindowController?

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
        // 7zFM loads codecs at first use; loading here is cheap (no file access) and makes
        // format lookups available to the panels immediately.
        do {
            try SZCodecs.loadCodecs()
        } catch {
            NSLog("7-Zip: codecs failed to load: %@", error.localizedDescription)
        }

        let controller = MainWindowController()
        mainWindowController = controller
        controller.showWindow(nil)

        // 7zFM.exe [path] [-t<arcType>]  (FM.cpp:639-702): a path names the folder or archive
        // panel 0 starts in. Other switches are not parsed by 7zFM either.
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, !first.hasPrefix("-") {
            let hint = args.dropFirst().first { $0.hasPrefix("-t") }.map { String($0.dropFirst(2)) }
            controller.openStartupPath(first, formatHint: hint)
        }
        NSApp.activate(ignoringOtherApps: true)

        // Test support: the aimable delivery channel for `sevenzip://test/reset`
        // (Mac/docs/api/resetcmd.md section 5). A no-op unless SZ_TEST_SUPPORT=1 and SZ_STATE_DIR
        // are both set, and it is started last so the window already exists when the first reset
        // arrives.
        TestResetWatcher.startIfNeeded()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true   // 7zFM: closing the window exits the process (WM_CLOSE -> PostQuitMessage)
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.saveState()   // g_App.Save() + SaveWindowInfo (FM.cpp:1028-1047)
        Settings.synchronize()
    }
}
