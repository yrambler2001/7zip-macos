// SettingsDomain.swift -- deterministic settings for UI tests.
//
// The app keeps everything in the preferences domain `com.yrambler2001.7zip`
// (`UserDefaults.standard` in the app, `SZSettings`/CFPreferences in the bridge; architecture.md
// "As built"). Two channels exist, and which one works depends on the sandbox:
//
//   1. `SettingsSeed` -> launch arguments (`-FM.PanelPath0 /path`). They land in NSUserDefaults'
//      argument domain, which has priority over everything stored, are gone when the process
//      exits, and work from the sandboxed test runner. This is what tests use.
//      Limits, measured (see Mac/docs/reports/harness.md): an argument value is a *string*, so a
//      key the app reads as `object(forKey:) as? Int/Bool` or as a `stringArray` falls back to the
//      app's built-in default -- which is what a "clean" launch wants anyway. Values containing
//      `{}` are parsed as an old-style plist, so a window frame must be passed as
//      "x y w h" (NSRectFromString accepts it) instead of "{{x, y}, {w, h}}".
//      `Lang` is read through CFPreferences, so it cannot be seeded this way; Mac/scripts/test.sh
//      writes it into the real domain for the duration of a UI run instead.
//   2. `SettingsDomain` -> the real CFPreferences domain. Only from an unsandboxed process:
//      Xcode's XCTRunner.app is app-sandboxed, so preference reads/writes made from a UI test are
//      redirected into the runner's own container and the app never sees them (`isRedirected`
//      reports that). `Mac/scripts/test.sh` and `verify.sh` therefore back up, clear and restore
//      the domain around a UI run with `defaults export/import`, which is what keeps the
//      developer's real settings safe.

import Foundation

/// What the app's settings should be when it is launched, expressed as launch arguments.
public enum SettingsSeed {
    /// The app's defaults for every key the harness knows: English-style details view, one panel,
    /// both panels in the home directory, a 1200x800 window, no favorites, no history.
    case clean
    /// `.clean` plus these overrides: preference key -> argument value
    /// (`[SettingsDomain.Key.panelPath0: TestPaths.fixtures]`).
    case values([String: String])
    /// No overrides at all: the app starts from whatever is stored. Used by `relaunch()` to prove
    /// that something persisted.
    case keep
}

public extension SettingsSeed {

    /// `-key value` pairs for `XCUIApplication.launchArguments`.
    var launchArguments: [String] {
        switch self {
        case .keep:
            return []
        case .clean:
            return Self.arguments(from: Self.cleanValues)
        case .values(let overrides):
            var values = Self.cleanValues
            for (key, value) in overrides { values[key] = value }
            return Self.arguments(from: values)
        }
    }

    /// The values `.clean` sets. Keys whose type an argument cannot express (Int / Bool object /
    /// array) are passed anyway: they shadow the stored value and the app falls back to its
    /// built-in default (1 panel, details view, default toolbars, no favorites).
    static var cleanValues: [String: String] {
        let home = TestPaths.realHome
        return [
            SettingsDomain.Key.position: "100 100 1200 800",   // NSRectFromString, no braces
            SettingsDomain.Key.maximized: "0",
            SettingsDomain.Key.numPanels: "1",
            SettingsDomain.Key.currentPanel: "0",
            SettingsDomain.Key.splitterPos: "0.5",
            SettingsDomain.Key.panelPath0: home,
            SettingsDomain.Key.panelPath1: home,
            SettingsDomain.Key.listMode0: "3",
            SettingsDomain.Key.listMode1: "3",
            SettingsDomain.Key.flatView0: "0",
            SettingsDomain.Key.flatView1: "0",
            SettingsDomain.Key.showDots: "0",
            SettingsDomain.Key.showGrid: "0",
            SettingsDomain.Key.folderHistory: "",
            SettingsDomain.Key.folderShortcuts: "",
            SettingsDomain.Key.timestampShowUTC: "0",
        ]
    }

    private static func arguments(from values: [String: String]) -> [String] {
        values.keys.sorted().flatMap { ["-" + $0, values[$0] ?? ""] }
    }
}

/// The real preferences domain. Usable from scripts and from an unsandboxed process; from a UI
/// test it is redirected into the runner's container (see the file comment).
public struct SettingsDomain {

    /// Preference keys, named after the Windows registry values (01b §5.2, `SZSettings.h`).
    public enum Key {
        public static let lang = "Lang"                            // "" system, "-" English
        public static let position = "FM.Position"                 // NSStringFromRect
        public static let maximized = "FM.Maximized"
        public static let numPanels = "FM.Panels.numPanels"        // 1 or 2
        public static let currentPanel = "FM.Panels.currentPanel"  // 0 or 1
        public static let splitterPos = "FM.Panels.splitterPos"    // ratio 0..1
        public static let panelPath0 = "FM.PanelPath0"
        public static let panelPath1 = "FM.PanelPath1"
        public static let listMode0 = "FM.ListMode0"               // 3 = details
        public static let listMode1 = "FM.ListMode1"
        public static let flatView0 = "FM.FlatViewArc0"
        public static let flatView1 = "FM.FlatViewArc1"
        public static let folderHistory = "FM.FolderHistory"
        public static let folderShortcuts = "FM.FolderShortcuts"
        public static let showDots = "FM.ShowDots"
        public static let showGrid = "FM.ShowGrid"
        public static let fullRow = "FM.FullRow"
        public static let toolbars = "FM.Toolbars"                 // bit0 labels, bit2 std, bit3 arc
        public static let autoRefresh = "FM.AutoRefresh"
        public static let timestampLevel = "FM.TimestampLevel"
        public static let timestampShowUTC = "FM.TimestampShowUTC"
    }

    public let applicationID: String

    public init(applicationID: String = SevenZipApp.bundleIdentifier) {
        self.applicationID = applicationID
    }

    private var id: CFString { applicationID as CFString }

    /// True when this process is sandboxed, so every read and write below goes to a private copy
    /// instead of the app's domain (the case inside Xcode's XCTRunner).
    public var isRedirected: Bool { TestPaths.isSandboxed }

    /// Every key/value currently stored for the app (this user, any host).
    public func snapshot() -> [String: Any] {
        guard let keys = CFPreferencesCopyKeyList(id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else {
            return [:]
        }
        let values = CFPreferencesCopyMultiple(keys, id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (values as? [String: Any]) ?? [:]
    }

    /// Remove every key of the domain.
    public func clear() {
        let keys = CFPreferencesCopyKeyList(id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSetMultiple(nil, keys, id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        synchronize()
    }

    /// Merge `values` into the domain (a nil value removes the key).
    public func write(_ values: [String: Any?]) {
        var toSet: [String: Any] = [:]
        var toRemove: [String] = []
        for (key, value) in values {
            if let value { toSet[key] = value } else { toRemove.append(key) }
        }
        CFPreferencesSetMultiple(toSet as CFDictionary, toRemove as CFArray,
                                 id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        synchronize()
    }

    /// Make the domain contain exactly `values` (anything else is removed).
    public func replace(with values: [String: Any]) {
        let existing = CFPreferencesCopyKeyList(id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String] ?? []
        let remove = existing.filter { values[$0] == nil }
        CFPreferencesSetMultiple(values as CFDictionary, remove as CFArray,
                                 id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        synchronize()
    }

    /// Put a `snapshot()` back, dropping anything that was added meanwhile.
    public func restore(_ snapshot: [String: Any]) {
        replace(with: snapshot)
    }

    public func value(forKey key: String) -> Any? {
        CFPreferencesCopyValue(key as CFString, id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }

    @discardableResult
    public func synchronize() -> Bool {
        CFPreferencesSynchronize(id, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
    }
}
