// CommandLineEntry.swift -- "7zG mode": the app started with a 7zG command line.
//
// `Main2` (CPP/7zip/UI/GUI/GUI.cpp:137-402) drops argv[0] and requires a command word; this is the
// same contract, in the app, because the macOS port has one binary instead of `7zFM.exe` +
// `7zG.exe` (03-shell-integration-inventory.md section 6.4). `argv[1] ∈ {a,u,d,rn,x,e,t,h,b,l,i}`
// puts the process into command mode: the file-manager window is ordered out, only the command's
// own dialogs and the progress window are shown, and the process exits with the 7zG exit code
// (ExitCode.h). Anything else is left to the file-manager argv (`7zFM.exe [path] [-t<type>]`,
// FM.cpp:639-702), which `AppDelegate` already handles.
//
// Command mode is detected in `applicationWillFinishLaunching` (through `FinderIntegration.install`,
// called from `MainMenu.build`) and executed from the `didFinishLaunching` notification, i.e. after
// AppKit has a run loop, so the dialogs and `OperationRunner`'s modal session work normally.

import AppKit

enum SevenZipCommandLineEntry {

    /// argv without argv[0], exactly what `Main2` parses.
    static var arguments: [String] { Array(CommandLine.arguments.dropFirst()) }

    /// True when argv[1] is a 7zG command word. A settings seed (`-FM.ShowGrid 1`, the UI test
    /// harness) and a plain path both fail this test, so neither is mistaken for a command.
    static var isCommandMode: Bool {
        guard let first = arguments.first else { return false }
        return !first.hasPrefix("-") && SevenZipCommandType.parse(first) != nil
    }

    /// Set once the launch command has run, so a second notification cannot run it twice.
    private static var launchCommandDidRun = false

    /// Runs the launch command line, if there is one, and terminates with its exit code.
    static func runLaunchCommandIfNeeded() {
        guard !launchCommandDidRun, isCommandMode else { return }
        launchCommandDidRun = true

        // "no document windows" (03 section 6.4): the file manager the app always creates is
        // ordered out rather than closed, because closing the last window terminates the process
        // before the command could run.
        for window in NSApp.windows { window.orderOut(nil) }

        let code = CommandExecutor.run(argv: arguments, parentWindow: nil)
        // `exit` rather than `NSApp.terminate`: 7zG returns a real exit code, and the file
        // manager's `applicationWillTerminate` must not save the window/panel state of a window
        // the user never saw.
        exit(code.rawValue)
    }
}
