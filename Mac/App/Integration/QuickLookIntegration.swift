// QuickLookIntegration.swift -- the app's side of the Quick Look preview extension (quicklook
// scope, a macOS addition: 7zFM has no shell preview handler, docs/parity.md "Added on macOS").
//
//   * `QuickLookExtensionControl`: the switch behind Options > macOS > "Quick Look preview for
//     archives" (lang 9970). An app cannot turn one of its extensions on or off through a public
//     API, so this works exactly like the Finder integration's checkbox (`FinderExtensionControl`,
//     01b §4.13): through PlugInKit, `pluginkit -e use|ignore -i com.yrambler2001.7zip.QuickLook`,
//     after making this copy's appex the registered one (`pluginkit -r` for every other copy, then
//     `-a`). PlugInKit is the truth: the checkbox shows what it reports, and the same switch in
//     System Settings > General > Login Items & Extensions > Quick Look shows the same state.
//   * The default is **on**: Quick Look uses a registered preview extension that nobody elected
//     (measured on macOS 26: the leading column of `pluginkit -m -v` is blank and `qlmanage -p` uses
//     it), so only an explicit `-` (ignore) turns it off. The first launch of an installed copy
//     elects it `+` once (`FM.QuickLookFirstLaunch`, for copies that were already installed before
//     the extension existed too), and Reset All Settings elects it `+` again (`SettingsReset`).
//   * `QuickLookSettingsBridge`: pushes the four display settings the preview follows (language,
//     theme, time format) into the extension's container (`QuickLookPreferences`).
//
// Test instances (SZ_TEST_SUPPORT, the -Host / -Probe copies, which embed no extension) never
// touch PlugInKit; every call goes through `FinderExtensionControl.runner`, which the tests replace.

import AppKit

enum QuickLookExtensionControl {

    static let identifier = QuickLookPreferences.extensionBundleIdentifier
    static let appexName = "QuickLook.appex"

    enum State: Equatable {
        /// This copy carries no QuickLook.appex (the test copies): the checkbox is disabled.
        case notEmbedded
        /// PlugInKit does not know the identifier (the copy was never launched or registered).
        case notRegistered
        /// Quick Look uses this copy's extension.
        case enabled
        /// Elected ignore: Quick Look does not use it.
        case disabled
        /// Another copy of the app is the registered one.
        case otherCopy(path: String, enabled: Bool)

        var isOn: Bool { self == .enabled }
    }

    /// A Quick Look extension is used unless it is elected ignore: ` ` (no election) and `+` are
    /// on, `!` is forced on, `-` is off. (A Finder Sync extension needs `+`; this one does not.)
    static func isEnabled(_ registration: FinderExtensionControl.Registration) -> Bool {
        registration.election != "-" && registration.election != "="
    }

    /// The state for the copy whose appex is at `embeddedPath`, given the registration in use.
    static func state(active: FinderExtensionControl.Registration?, embeddedPath: String?) -> State {
        guard let embeddedPath else { return .notEmbedded }
        guard let active else { return .notRegistered }
        guard FinderExtensionControl.canonical(active.path) == FinderExtensionControl.canonical(embeddedPath) else {
            return .otherCopy(path: active.path, enabled: isEnabled(active))
        }
        return isEnabled(active) ? .enabled : .disabled
    }

    /// `Contents/PlugIns/QuickLook.appex` of the running app, when it has one.
    static var embeddedAppexPath: String? {
        guard let url = Bundle.main.builtInPlugInsURL?.appendingPathComponent(appexName),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return FinderExtensionControl.canonical(url.path)
    }

    static func activeRegistration() -> FinderExtensionControl.Registration? {
        FinderExtensionControl.parse(FinderExtensionControl.runner(["-m", "-v", "-i", identifier]).output,
                                     identifier: identifier).first
    }

    static func allRegistrations() -> [FinderExtensionControl.Registration] {
        FinderExtensionControl.parse(FinderExtensionControl.runner(["-m", "-D", "-A", "-v", "-i", identifier]).output,
                                     identifier: identifier)
    }

    /// Blocking (runs `pluginkit`): call it off the main thread.
    static func currentState(embeddedPath: String? = embeddedAppexPath) -> State {
        guard embeddedPath != nil else { return .notEmbedded }
        return state(active: activeRegistration(), embeddedPath: embeddedPath)
    }

    /// Makes this copy's appex the registered one: removes every other copy's registration, then
    /// adds this one. Blocking.
    static func claim(embeddedPath: String) {
        let mine = FinderExtensionControl.canonical(embeddedPath)
        for registration in allRegistrations() where FinderExtensionControl.canonical(registration.path) != mine {
            _ = FinderExtensionControl.runner(["-r", registration.path])
        }
        _ = FinderExtensionControl.runner(["-a", embeddedPath])
    }

    /// Elects use (after claiming) or ignore, then waits up to `timeout` for PlugInKit to agree and
    /// returns where it ended. Blocking.
    @discardableResult
    static func setEnabled(_ on: Bool, embeddedPath: String? = embeddedAppexPath, timeout: TimeInterval = 3) -> State {
        guard let embeddedPath else { return .notEmbedded }
        if on { claim(embeddedPath: embeddedPath) }
        _ = FinderExtensionControl.runner(["-e", on ? "use" : "ignore", "-i", identifier])
        let deadline = Date().addingTimeInterval(timeout)
        var state = currentState(embeddedPath: embeddedPath)
        while state.isOn != on, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            state = currentState(embeddedPath: embeddedPath)
        }
        return state
    }

    /// Reset All Settings: back to the default, on. Elects use without waiting (the app quits right
    /// after). Never in a test instance, never for a copy without the extension.
    static func restoreDefault(embeddedPath: String? = embeddedAppexPath, testSupport: Bool = TestSupport.isEnabled) {
        guard !testSupport, let embeddedPath else { return }
        claim(embeddedPath: embeddedPath)
        _ = FinderExtensionControl.runner(["-e", "use", "-i", identifier])
    }

    /// One line for the checkbox's tool tip.
    static func describe(_ state: State) -> String {
        switch state {
        case .notEmbedded: return "This copy of 7-Zip has no Quick Look extension."
        case .notRegistered: return "The Quick Look extension is not registered yet."
        case .enabled: return "Quick Look uses this copy's extension: \(embeddedAppexPath ?? "")"
        case .disabled: return "This copy's Quick Look extension is turned off."
        case let .otherCopy(path, enabled):
            return "Quick Look uses another copy's extension (\(enabled ? "on" : "off")): \(path)"
        }
    }

    // MARK: - at launch

    /// Marker of the one-time election (kept by Reset All Settings, like FM.FirstLaunchIntegration).
    static let firstLaunchMarkerKey = "FM.QuickLookFirstLaunch"

    /// What to do at launch, decided like `FirstLaunchIntegration.decide` (pure; tested).
    enum LaunchAction: Equatable {
        case none
        /// Another copy (or none) is registered: take the registration over, keep the election.
        case claim
        /// First launch of an installed copy: claim and elect use, then set the marker.
        case enable
    }

    static func launchAction(testSupport: Bool, xctestLoaded: Bool, bundleIdentifier: String?,
                             bundlePath: String, home: String, embedded: Bool, markerSet: Bool) -> LaunchAction {
        if testSupport || xctestLoaded || !embedded { return .none }
        guard bundleIdentifier == FirstLaunchIntegration.realBundleIdentifier else { return .none }
        if !markerSet, FirstLaunchIntegration.isInstalledLocation(bundlePath, home: home) { return .enable }
        return .claim
    }

    /// At launch of a real copy (`QuickLookIntegration.install`), in the background.
    static func runAtLaunch() {
        let action = launchAction(testSupport: TestSupport.isEnabled,
                                  xctestLoaded: NSClassFromString("XCTestCase") != nil,
                                  bundleIdentifier: Bundle.main.bundleIdentifier,
                                  bundlePath: Bundle.main.bundlePath, home: NSHomeDirectory(),
                                  embedded: embeddedAppexPath != nil,
                                  markerSet: Settings.hasKey(firstLaunchMarkerKey))
        guard action != .none, let embedded = embeddedAppexPath else { return }
        if action == .enable {
            Settings.setBool(true, firstLaunchMarkerKey)
            Settings.synchronize()
        }
        FinderExtensionControl.launchQueue.async {
            switch action {
            case .enable:
                setEnabled(true, embeddedPath: embedded)
            case .claim:
                // Another copy's registration, or none at all (a copy replaced in place after a
                // `pluginkit -r` of its path, measured: Launch Services does not bring it back):
                // register this one. The election is left alone.
                FinderExtensionControl.registerAtLaunch(identifier: identifier, embeddedPath: embedded)
            case .none:
                break
            }
        }
    }
}

/// Keeps the extension's copy of the display settings current (`QuickLookPreferences`).
enum QuickLookSettingsBridge {

    /// The values the preview follows, from the app's own settings.
    static func snapshot() -> QuickLookPreferences {
        QuickLookPreferences(language: Settings.string(Settings.Key.lang) ?? "",
                             theme: Settings.theme.rawValue,
                             timestampLevel: Settings.timestampLevel,
                             timestampShowUTC: Settings.timestampShowUTC)
    }

    /// Writes the snapshot into the extension's container when it exists. Never in a test
    /// instance (its settings are not the user's).
    @discardableResult
    static func push() -> Bool {
        guard !TestSupport.isEnabled, Bundle.main.bundleIdentifier == FirstLaunchIntegration.realBundleIdentifier
        else { return false }
        return snapshot().write()
    }
}

/// Installed from `MainMenu.build()` next to `FinderIntegration.install()`.
enum QuickLookIntegration {

    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            QuickLookExtensionControl.runAtLaunch()
            QuickLookSettingsBridge.push()
        }
        // The theme and the time format are `view` settings, the language its own group.
        for group in [Settings.Group.view, Settings.Group.language] {
            NotificationCenter.default.addObserver(forName: group.notificationName, object: nil, queue: .main) { note in
                let key = note.userInfo?[Settings.keyUserInfoKey] as? String
                let watched: Set<String> = [Settings.Key.lang, Settings.Key.theme,
                                            Settings.Key.timestampLevel, Settings.Key.timestampShowUTC]
                guard key == nil || watched.contains(key!) else { return }
                QuickLookSettingsBridge.push()
            }
        }
    }
}
