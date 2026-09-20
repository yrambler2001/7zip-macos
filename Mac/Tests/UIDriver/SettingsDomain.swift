// SettingsDomain.swift -- deterministic, per-test settings for UI tests.
//
// The app resolves its whole preferences domain from the `SEVENZIP_DEFAULTS_SUITE` environment
// variable (`NMacPrefs::ApplicationID`, `Mac/docs/api/options.md`): `SZSettings`, the Swift
// `Settings` facade and the engine-side `ZipRegistry` accessors all read and write that one domain.
//
// **CFPreferences accepts an absolute path as an application ID**, and then reads and writes
// exactly that property-list file (measured: `CFPreferencesCopyAppValue(key, "/a/b/seed")` and
// `".../seed.plist"` both resolve to `/a/b/seed.plist`; a missing file behaves as an empty domain).
// So a UI test does not need to write a CFPreferences domain at all -- which it cannot, because
// Xcode's XCTRunner.app is app-sandboxed and every domain it touches is redirected into its own
// container. It writes a plain plist **file** into that container and points the app at it:
//
//   1. `SettingsSeed` -> a `SettingsSeedFile` in `TestPaths.artifacts`, handed to the app as
//      `SEVENZIP_DEFAULTS_SUITE=<path>`. Values are **typed**, so `FM.Panels.numPanels`,
//      `FM.Toolbars`, `FM.ListMode*`, `FM.AutoRefresh` and `Lang` -- everything the old launch
//      argument channel could not express -- finally work, and each test gets a domain of its own
//      that nothing else in the run can see. That is what makes the app's save-on-quit harmless:
//      it writes the throwaway file, never `com.yrambler2001.7zip` and never the next test's state
//      (`FM.Columns.<FolderTypeID>` used to leak the sort order into the following test).
//   2. Launch arguments still win over the file for keys whose value is a string, and
//      `SevenZipApp.launch(arguments:)` passes extra ones through, so a one-off override needs no
//      seed file.
//   3. `SettingsDomain` -> the real CFPreferences domain. Only useful from an unsandboxed process
//      (the scripts); `isRedirected` reports when it is not. `Mac/scripts/test.sh` still backs the
//      real domain up and restores it around a UI run as a safety net for a test that launches the
//      app without a seed.

import Foundation


/// What the app's settings are when it is launched. Written as a property-list file that the app
/// uses as its whole preferences domain, so the values are typed and private to one test.
public enum SettingsSeed {
    /// The app's defaults for every key the harness knows: English strings, details view, one
    /// panel, both panels in the home directory, a 1200x800 window, no favorites, no history.
    case clean
    /// `.clean` plus these string overrides
    /// (`[SettingsDomain.Key.panelPath0: TestPaths.fixtures]`).
    case values([String: String])
    /// `.clean` plus these **typed** overrides -- `Int`, `Bool`, `[String]` and `String` all reach
    /// the app as themselves (`[SettingsDomain.Key.numPanels: 2]`).
    case typed([String: Any])
    /// Exactly these values and nothing else: the escape hatch for a test that must assert what
    /// the app does with an empty or hand-built domain.
    case only([String: Any])
    /// Keep the domain of the previous `launch()` untouched: the app starts from whatever it saved
    /// when it quit. `relaunch()` uses this to prove that something persisted.
    case keep
}

public extension SettingsSeed {

    /// The settings the app must find in its domain, or nil for `.keep` (reuse the previous file).
    var preferences: [String: Any]? {
        switch self {
        case .keep:
            return nil
        case .clean:
            return Self.cleanValues
        case .values(let overrides):
            return Self.cleanValues.merging(overrides.mapValues { $0 as Any }) { _, new in new }
        case .typed(let overrides):
            return Self.cleanValues.merging(overrides) { _, new in new }
        case .only(let values):
            return values
        }
    }

    /// `-key value` pairs for `XCUIApplication.launchArguments`. Empty now that the seed is a
    /// typed plist: a launch argument can only carry a string and would shadow the typed value.
    /// `SevenZipApp.launch(arguments:)` still passes caller-supplied arguments through.
    var launchArguments: [String] { [] }

    /// The values `.clean` sets, with the types the app reads them as (`Settings.swift`).
    static var cleanValues: [String: Any] {
        let home = TestPaths.realHome
        return [
            SettingsDomain.Key.lang: "-",                      // built-in English, so titles match
            SettingsDomain.Key.position: "100 100 1200 800",   // NSRectFromString, no braces
            SettingsDomain.Key.maximized: false,
            SettingsDomain.Key.numPanels: 1,
            SettingsDomain.Key.currentPanel: 0,
            SettingsDomain.Key.splitterPos: "0.500000",        // stored as a string (setDouble)
            SettingsDomain.Key.panelPath0: home,
            SettingsDomain.Key.panelPath1: home,
            SettingsDomain.Key.listMode0: 3,                   // details
            SettingsDomain.Key.listMode1: 3,
            SettingsDomain.Key.flatView0: false,
            SettingsDomain.Key.flatView1: false,
            SettingsDomain.Key.showDots: false,
            SettingsDomain.Key.showGrid: false,
            SettingsDomain.Key.fullRow: false,
            SettingsDomain.Key.autoRefresh: true,
            SettingsDomain.Key.folderHistory: [String](),
            SettingsDomain.Key.folderShortcuts: [String](),
            SettingsDomain.Key.timestampShowUTC: false,
        ]
    }
}

/// One test's preferences domain: a property-list file the app is pointed at with
/// `SEVENZIP_DEFAULTS_SUITE`. See the file comment for why a file works and a domain name does not.
public struct SettingsSeedFile {

    public let url: URL

    public init(url: URL) { self.url = url }

    /// A fresh file in `TestPaths.artifacts` holding `values`; `name` only makes it recognisable.
    public static func make(name: String, values: [String: Any]) throws -> SettingsSeedFile {
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let file = "seed-\(String(safe))-\(UUID().uuidString.prefix(8)).plist"
        try FileManager.default.createDirectory(atPath: TestPaths.artifacts, withIntermediateDirectories: true)
        let seed = SettingsSeedFile(url: URL(fileURLWithPath: TestPaths.artifacts).appendingPathComponent(file))
        try seed.write(values)
        return seed
    }

    /// What the app is launched with so it treats this file as its whole settings domain.
    public var launchEnvironment: [String: String] { [SettingsDomain.suiteEnvironmentVariable: url.path] }

    public func write(_ values: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }

    /// The file as it stands now -- after a graceful quit this is what the app saved.
    public var values: [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
            return [:]
        }
        return (plist as? [String: Any]) ?? [:]
    }

    public func remove() {
        try? FileManager.default.removeItem(at: url)
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

    /// The environment variable the app resolves to its preferences domain: a domain name, or an
    /// absolute path to a property-list file (`SettingsSeedFile`).
    public static let suiteEnvironmentVariable = "SEVENZIP_DEFAULTS_SUITE"

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
