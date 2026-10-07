// SettingsReset.swift -- Options > macOS > "Reset All Settings..." (fix112, a macOS addition: 7zFM
// has no such command; on Windows the equivalent is deleting HKCU\Software\7-Zip by hand).
//
// After the user confirms, the app
//
//   1. empties the settings domain in use -- `com.yrambler2001.7zip`, or the domain named by
//      `SEVENZIP_DEFAULTS_SUITE` -- keeping only `preservedKeys` (below). That domain holds every
//      setting the app and the engine write: the Options pages, the window and panel state
//      (FM.Position, FM.Panels.*, FM.PanelPath*, FM.ListMode*, FM.Toolbars), the per-folder-type
//      column layouts and sorts (FM.Columns.*), the histories (FM.FolderHistory, FM.CopyHistory,
//      Extraction.PathHistory, Compression.ArcHistory), the favorites, the compression and
//      extraction options, the theme, the update-check state, and anything AppKit put there
//      (NSTableView / NSWindow / NSSplitView autosave keys, the open panel's last folder);
//   2. removes the window-restoration archive (~/Library/Saved Application State/<id>.savedState)
//      when the domain is the app's own (never in a suite run, whose state is elsewhere);
//   3. suspends every settings write for the rest of the process (`SZSettings.writesSuspended`),
//      so the quitting instance's save-on-quit (`applicationWillTerminate` -> every window's
//      `saveState`) cannot put its state back;
//   4. starts a detached helper that waits for this process to exit and then opens the same bundle
//      again (`/usr/bin/open -n -a <bundle>`), and quits.
//
// Not touched: the user's files and archives, the temporary 7zO*/7zE* folders (the next launch's
// `TempOpenJanitor` sweeps them as after any quit), and the Finder integration's PlugInKit state --
// the Finder extension and the Quick Actions stay enabled or disabled exactly as they are.
// quicklook: the Quick Look preview extension is the exception: its checkbox (Options > macOS) is a
// setting with a default (on), so the reset elects it "use" again (`QuickLookExtensionControl`).
// Its first-launch marker `FM.QuickLookFirstLaunch` is kept, like FM.FirstLaunchIntegration.
//
// Decision on the first-launch marker: `FM.FirstLaunchIntegration` is **kept**. Removing it would
// make the next launch of an installed copy run `FirstLaunchIntegration` again, which re-elects the
// Finder extension and both Quick Actions -- re-enabling what the user may have switched off in
// Options > 7-Zip or System Settings. Keeping it means the integration stays as the user left it.
// The Launch Services stamp (`FM.LaunchServicesStamp*`) is kept too: it only records that this
// bundle was registered, and dropping it would just re-run `lsregister` for no change.

import AppKit
import SevenZipKit

enum SettingsReset {

    // MARK: - the decision (pure; SettingsResetTests and Fix112Tests drive it)

    /// Keys that survive a reset (see the file comment for why).
    static let preservedKeys: Set<String> = [FirstLaunchIntegration.markerKey,
                                             QuickLookExtensionControl.firstLaunchMarkerKey]
    static let preservedPrefixes = ["FM.LaunchServicesStamp"]

    static func isPreserved(_ key: String) -> Bool {
        preservedKeys.contains(key) || preservedPrefixes.contains { key.hasPrefix($0) }
    }

    /// What the domain holds after the reset: only the preserved keys of `contents`.
    static func contentsAfterReset(_ contents: [String: Any]) -> [String: Any] {
        contents.filter { isPreserved($0.key) }
    }

    /// The environment the relaunched instance gets: the variables that choose the settings domain
    /// and the test-support state, passed on so a suite run (or a test instance) stays one. `open`
    /// does not pass the caller's environment through Launch Services by itself.
    static let forwardedEnvironment = [SZSettingsSuiteEnvironmentVariable,
                                       SZSettingsTestSupportEnvironmentVariable,
                                       SZSettingsStateDirectoryEnvironmentVariable,
                                       TestSupport.animationsVariable]

    /// The helper's command line: wait (at most 30 s) for `pid` to exit, then open the bundle as a
    /// new instance with the forwarded environment.
    static func relaunchArguments(bundlePath: String, pid: Int32, environment: [String: String]) -> [String] {
        var open = ["/usr/bin/open", "-n", "-a", bundlePath]
        for name in forwardedEnvironment {
            if let value = environment[name], !value.isEmpty { open += ["--env", "\(name)=\(value)"] }
        }
        let quoted = open.map(shellQuote).joined(separator: " ")
        let script = "i=0; while kill -0 \(pid) 2>/dev/null && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done; exec \(quoted)"
        return ["/bin/sh", "-c", script]
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `~/Library/Saved Application State/<bundle id>.savedState`, or nil in a suite run.
    static func savedApplicationStatePath(bundleIdentifier: String?, usesOverrideSuite: Bool, home: String) -> String? {
        guard !usesOverrideSuite, let id = bundleIdentifier, !id.isEmpty else { return nil }
        return (home as NSString).appendingPathComponent("Library/Saved Application State/\(id).savedState")
    }

    // MARK: - the side effects (replaceable by a test)

    /// Starts the relaunch helper. A test replaces it so nothing is launched.
    static var startRelauncher: (_ arguments: [String]) -> Void = { arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { NSLog("7-Zip: cannot schedule the relaunch: %@", error.localizedDescription) }
    }

    /// Quits the app. A test replaces it.
    static var terminate: () -> Void = { NSApp.terminate(nil) }

    // MARK: - the command

    /// Lang IDs (macOS additions, outside every official block, next to the theme's 9900s).
    enum LangID {
        static let button: UInt32 = 9960          // "Reset All Settings..."
        static let question: UInt32 = 9961        // the confirmation
    }

    static var buttonTitle: String { Lang.text(LangID.button, "Reset All Settings...") }
    static var questionText: String {
        Lang.text(LangID.question, "Reset all 7-Zip settings to their defaults? 7-Zip will restart.")
    }

    /// Asks, and on Yes resets and restarts. Returns whether the reset ran.
    @discardableResult
    static func confirmAndRun(owner: NSWindow?) -> Bool {
        guard WinMessageBox.run(questionText, buttons: .yesNo, icon: .question, owner: owner) == .yes else { return false }
        resetAndRelaunch()
        return true
    }

    /// Steps 1-4 of the file comment.
    static func resetAndRelaunch() {
        resetDomain()
        let env = ProcessInfo.processInfo.environment
        startRelauncher(relaunchArguments(bundlePath: Bundle.main.bundleURL.path,
                                          pid: ProcessInfo.processInfo.processIdentifier, environment: env))
        terminate()
    }

    /// Steps 1-3: empties the domain (keeping the preserved keys), drops the saved window state and
    /// suspends every later write.
    static func resetDomain() {
        let kept = contentsAfterReset(Settings.domainContents())
        Settings.replaceDomainContents(with: kept)
        if let path = savedApplicationStatePath(bundleIdentifier: Bundle.main.bundleIdentifier,
                                                usesOverrideSuite: SZSettings.usesOverrideSuite,
                                                home: NSHomeDirectory()) {
            try? FileManager.default.removeItem(atPath: path)
        }
        SZSettings.writesSuspended = true
        // quicklook: "Quick Look preview for archives" is on by default, so a reset turns it back
        // on (PlugInKit holds that state, not the domain). A no-op in test instances and in copies
        // without the extension.
        QuickLookExtensionControl.restoreDefault()
    }
}
