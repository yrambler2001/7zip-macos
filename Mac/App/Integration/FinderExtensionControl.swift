// FinderExtensionControl.swift -- the state of *this* app copy's Finder Sync extension, and the
// switch behind Options > 7-Zip > "Integrate 7-Zip to shell context menu" (IDX_SYSTEM_INTEGRATE_TO_MENU
// 2301; 01b §4.13, 03 §1.3 / §6.4 / §7).
//
// Windows: the checkbox is checked when *this* installation's 7-zip.dll is the registered context-
// menu handler (`CheckContextMenuHandler(path)`), disabled when the DLL is missing, and Apply
// registers or unregisters it (`SetContextMenuHandler`), shows the error in a message box and
// re-reads the state (MenuPage.cpp:170-180, :299-316). The macOS counterpart is PlugInKit:
//
//   pluginkit -m -v -i com.yrambler2001.7zip.FinderSync
//   +    com.yrambler2001.7zip.FinderSync(26.03)  <UUID>  <date>  <path>/7-Zip.app/Contents/PlugIns/FinderSync.appex
//
// reads: "the plug-in com.yrambler2001.7zip.FinderSync, version 26.03, is elected **+** = use (the
// user turned it on; **-** = ignore, off; **!** / **=** / **?** see `Registration`); the copy that
// Finder runs is the one inside <path>". Several copies of the app (Debug, Release, a DMG copy,
// a scratch copy) each register their own appex under the same identifier; PlugInKit keeps them
// all (`pluginkit -m -D -A` lists them) and hands Finder one. Which one is not something a caller
// can steer: measured on macOS 26, neither the registration date, nor re-adding (`-a` of a known
// path is a no-op), nor `lsregister -f`, nor touching the bundle moved it; the freshly built copy
// kept winning. What does work, at once, is removing the other copies' registrations
// (`pluginkit -r <path>`): the only copy left is the one Finder runs. A removed copy registers
// itself again when it is launched (or rebuilt), and then it claims the extension the same way.
// The election (+/-) belongs to the identifier, not to a copy.
//
// So: "enabled" here means the elected copy is *this* app's appex and the election is use. Enabling
// removes every other copy's registration, adds this one (`pluginkit -a`) and elects use
// (`pluginkit -e use`); disabling elects ignore. Neither needs the user's consent on
// macOS 14-26 (measured on 26.0: rc 0, Finder starts/stops the extension process at once). When the
// election does not take effect anyway (an MDM profile, a future system), the page falls back to
// `FIFinderSyncController.showExtensionManagementInterface()`, the System Settings pane.
//
// Every launch of a real copy (not a test instance) claims the extension for itself in the
// background, so the copy the user runs is the one whose extension Finder uses -- a Debug build
// that Xcode registered later no longer wins over the installed app.

import AppKit
import FinderSync

enum FinderExtensionControl {

    static let identifier = "com.yrambler2001.7zip.FinderSync"
    static let pluginkitPath = "/usr/bin/pluginkit"

    /// One line of `pluginkit -m -v`.
    struct Registration: Equatable {
        /// `+` elected to use, `-` elected to ignore, `!` forced on for development, `=` superseded
        /// by another copy, `?` unknown, ` ` no election (a Finder Sync extension is then off).
        var election: Character
        var version: String
        var path: String
        var isEnabled: Bool { election == "+" || election == "!" }
    }

    enum State: Equatable {
        /// This copy carries no FinderSync.appex (the test copies 7-Zip-Host / -Probe1 / -Probe2):
        /// the checkbox is disabled, as MenuPage.cpp disables it when 7-zip.dll is missing.
        case notEmbedded
        /// PlugInKit does not know the identifier at all.
        case notRegistered
        /// Finder runs this copy's appex, elected use.
        case enabled
        /// Finder would run this copy's appex, but the election is ignore (or none).
        case disabled
        /// Another copy of the app is the one Finder runs.
        case otherCopy(path: String, enabled: Bool)

        var isOn: Bool { self == .enabled }
    }

    // MARK: - pure parts (unit-tested, AppFeelTests)

    /// Parses `pluginkit -m [-D] [-A] -v -i <identifier>` output, one `Registration` per line that
    /// names the identifier.
    static func parse(_ output: String, identifier: String = identifier) -> [Registration] {
        output.split(whereSeparator: \.isNewline).compactMap { raw -> Registration? in
            let line = String(raw)
            guard let first = line.first, let idRange = line.range(of: identifier) else { return nil }
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let path = fields.last(where: { $0.hasPrefix("/") }) else { return nil }
            var version = ""
            let rest = line[idRange.upperBound...]
            if rest.hasPrefix("("), let close = rest.firstIndex(of: ")") {
                version = String(rest[rest.index(after: rest.startIndex)..<close])
            }
            return Registration(election: first, version: version, path: path)
        }
    }

    /// The state for the copy whose appex is at `embeddedPath`, given the registration Finder uses.
    static func state(active: Registration?, embeddedPath: String?) -> State {
        guard let embeddedPath else { return .notEmbedded }
        guard let active else { return .notRegistered }
        guard canonical(active.path) == canonical(embeddedPath) else {
            return .otherCopy(path: active.path, enabled: active.isEnabled)
        }
        return active.isEnabled ? .enabled : .disabled
    }

    /// `realpath`, so `Mac/build/Debug/7-Zip.app` (a symlink into DerivedData) and `/tmp` compare
    /// equal to what PlugInKit prints. A path that no longer exists is returned as it is.
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - this copy

    /// `Contents/PlugIns/FinderSync.appex` of the running app, when it has one.
    static var embeddedAppexPath: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent("FinderSync.appex"),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return canonical(url.path)
    }

    /// Runs `pluginkit` with `arguments`; replaced by the tests, which must never change the
    /// machine's real election.
    static var runner: (_ arguments: [String]) -> (status: Int32, output: String) = runPluginkit

    private static func runPluginkit(_ arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pluginkitPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// The registration Finder uses (`pluginkit -m` without `-D` prints only that one).
    static func activeRegistration() -> Registration? {
        parse(runner(["-m", "-v", "-i", identifier]).output).first
    }

    /// Every registered copy, duplicates included.
    static func allRegistrations() -> [Registration] {
        parse(runner(["-m", "-D", "-A", "-v", "-i", identifier]).output)
    }

    /// Blocking (it runs `pluginkit`): call it off the main thread.
    static func currentState(embeddedPath: String? = embeddedAppexPath) -> State {
        guard embeddedPath != nil else { return .notEmbedded }
        return state(active: activeRegistration(), embeddedPath: embeddedPath)
    }

    /// Makes this copy's appex the one Finder runs: removes the registration of every other copy
    /// (deleted ones included), then adds this one. Blocking.
    static func claim(embeddedPath: String) {
        claim(identifier: identifier, embeddedPath: embeddedPath)
    }

    /// The same for any of this app's extension identifiers (the Quick Actions, Quick Look).
    /// Registering never changes the election: `-a` only adds the path; whether the identifier is
    /// elected use or ignore stays what the user (or the first launch) made it.
    static func claim(identifier: String, embeddedPath: String) {
        let mine = canonical(embeddedPath)
        let all = parse(runner(["-m", "-D", "-A", "-v", "-i", identifier]).output, identifier: identifier)
        for registration in all where canonical(registration.path) != mine {
            _ = runner(["-r", registration.path])
        }
        _ = runner(["-a", embeddedPath])
    }

    /// Apply of IDX_SYSTEM_INTEGRATE_TO_MENU: claim and elect use, or elect ignore; then wait (up
    /// to `timeout`, PlugInKit updates its database asynchronously) for the state to follow and
    /// return what it ended at. Blocking.
    @discardableResult
    static func setEnabled(_ on: Bool, embeddedPath: String? = embeddedAppexPath,
                           timeout: TimeInterval = 3) -> State {
        guard let embeddedPath else { return .notEmbedded }
        if on { claim(embeddedPath: embeddedPath) }
        _ = runner(["-e", on ? "use" : "ignore", "-i", identifier])
        let deadline = Date().addingTimeInterval(timeout)
        var state = currentState(embeddedPath: embeddedPath)
        while state.isOn != on, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            state = currentState(embeddedPath: embeddedPath)
        }
        return state
    }

    /// What a launch does with one of this copy's extensions (pure; AppFeelTests / QuickLookPreviewTests).
    enum LaunchRegistration: Equatable {
        /// PlugInKit has no registration at all -- the app was replaced in place (a `brew upgrade`,
        /// a drag from the disk image over the old copy) after its path had been removed, and Launch
        /// Services does not bring it back (measured on macOS 26): add this copy's appex.
        case register
        /// Another copy is registered: remove it and add this one.
        case takeOver
        /// This copy is registered: nothing to do, whatever the election (`+`, none, or the user's
        /// `-`, which is never flipped).
        case leave
    }

    static func launchRegistration(active: Registration?, embeddedPath: String) -> LaunchRegistration {
        guard let active else { return .register }
        return canonical(active.path) == canonical(embeddedPath) ? .leave : .takeOver
    }

    /// Every PlugInKit call made at launch (this claim, the first-launch election, Quick Look's)
    /// runs on this one serial queue, in the order the launch asks for them, so a registration and
    /// an election never interleave.
    static let launchQueue = DispatchQueue(label: "com.yrambler2001.7zip.pluginkit", qos: .utility)

    /// This copy's extensions besides Quick Look: identifier and appex file name.
    static let finderExtensions: [(identifier: String, appex: String)] = [
        (identifier, "FinderSync.appex"),
        ("com.yrambler2001.7zip.QuickActionExtract", "QuickActionExtract.appex"),
        ("com.yrambler2001.7zip.QuickActionCompress", "QuickActionCompress.appex"),
    ]

    /// One extension at launch: register it when missing, take it over from another copy, leave a
    /// registered one alone. The election is never touched. Blocking.
    @discardableResult
    static func registerAtLaunch(identifier: String, embeddedPath: String) -> LaunchRegistration {
        let active = parse(runner(["-m", "-v", "-i", identifier]).output, identifier: identifier).first
        let action = launchRegistration(active: active, embeddedPath: embeddedPath)
        if action != .leave { claim(identifier: identifier, embeddedPath: embeddedPath) }
        return action
    }

    /// At launch of a real copy: the Finder Sync extension and both Quick Actions are registered
    /// from this copy -- taken over from another copy (so the app the user runs is the one Finder's
    /// menu calls back), or re-added when PlugInKit lost them. The election is left alone, so a user
    /// who turned the integration off keeps it off. Test instances (SZ_TEST_SUPPORT=1) never touch
    /// PlugInKit.
    static func claimAtLaunchIfNeeded() {
        guard !TestSupport.isEnabled, let embeddedPath = embeddedAppexPath else { return }
        let plugIns = (embeddedPath as NSString).deletingLastPathComponent
        let present = finderExtensions.compactMap { ext -> (String, String)? in
            let path = (plugIns as NSString).appendingPathComponent(ext.appex)
            return FileManager.default.fileExists(atPath: path) ? (ext.identifier, canonical(path)) : nil
        }
        launchQueue.async {
            for (identifier, path) in present { registerAtLaunch(identifier: identifier, embeddedPath: path) }
        }
    }

    /// The System Settings pane where the user switches Finder extensions (the fallback).
    static func showManagementInterface() {
        FIFinderSyncController.showExtensionManagementInterface()
    }

    /// One line for the checkbox's tool tip.
    static func describe(_ state: State) -> String {
        switch state {
        case .notEmbedded: return "This copy of 7-Zip has no Finder extension."
        case .notRegistered: return "The Finder extension is not registered."
        case .enabled: return "Finder uses this copy's extension: \(embeddedAppexPath ?? "")"
        case .disabled: return "This copy's Finder extension is turned off."
        case let .otherCopy(path, enabled):
            return "Finder uses another copy's extension (\(enabled ? "on" : "off")): \(path)"
        }
    }
}
