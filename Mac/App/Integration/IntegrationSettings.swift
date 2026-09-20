// IntegrationSettings.swift -- the five `HKCU\Software\7-Zip\Options` values the Finder menu
// needs (`CContextMenuInfo`, 03-shell-integration-inventory.md section 1.3), readable from a
// **sandboxed** app extension.
//
// Foundation only, and deliberately independent of `Settings` / `SZSettings`: the Finder Sync and
// Quick Action extensions must not link the bridge framework (it would pull the whole engine into
// the appex) and cannot use `UserDefaults.standard`, whose domain the sandbox redirects into the
// extension's own container.
//
// Two ways in, tried in this order (03 section 6.4 "shared defaults" / the URL-scheme handshake):
//
//  1. the **snapshot** the app writes into the extension's container
//     (`FinderSettingsBridge.push()`); the app is unsandboxed, so it can write there, and the
//     extension can always read its own container. This is what makes the handshake work with no
//     App Group -- a group identifier without a Team ID prefix is rejected on macOS 15+.
//  2. `CFPreferencesCopyAppValue` on the app's own domain, which the appex is allowed to read
//     because it carries
//     `com.apple.security.temporary-exception.shared-preference.read-only` (FinderSync.entitlements).
//
// The values are re-read on **every** `menu(for:)` because Finder never tells an extension that
// settings changed (03 section 6.2).

import Foundation

/// `Explorer/ContextMenuFlags.h:8-24`, duplicated here for the extension. Identical bits to
/// `Settings.ContextMenuFlags`, which the app keeps using.
struct ContextMenuItemFlags: OptionSet {
    let rawValue: UInt32

    static let extractFiles = ContextMenuItemFlags(rawValue: 1 << 0)        // kExtract
    static let extractHere = ContextMenuItemFlags(rawValue: 1 << 1)         // kExtractHere
    static let extractTo = ContextMenuItemFlags(rawValue: 1 << 2)           // kExtractTo
    static let test = ContextMenuItemFlags(rawValue: 1 << 4)                // kTest
    static let open = ContextMenuItemFlags(rawValue: 1 << 5)                // kOpen
    static let openAs = ContextMenuItemFlags(rawValue: 1 << 6)              // kOpenAs
    static let compress = ContextMenuItemFlags(rawValue: 1 << 8)            // kCompress
    static let compressTo7z = ContextMenuItemFlags(rawValue: 1 << 9)        // kCompressTo7z
    static let compressEmail = ContextMenuItemFlags(rawValue: 1 << 10)      // kCompressEmail
    static let compressTo7zEmail = ContextMenuItemFlags(rawValue: 1 << 11)  // kCompressTo7zEmail
    static let compressToZip = ContextMenuItemFlags(rawValue: 1 << 12)      // kCompressToZip
    static let compressToZipEmail = ContextMenuItemFlags(rawValue: 1 << 13) // kCompressToZipEmail
    static let crcCascaded = ContextMenuItemFlags(rawValue: 1 << 30)        // kCRC_Cascaded
    static let crc = ContextMenuItemFlags(rawValue: 1 << 31)                // kCRC

    /// `Flags = (UInt32)-1` when the registry value is absent: every item enabled.
    static let all = ContextMenuItemFlags(rawValue: 0xFFFF_FFFF)
}

/// The identifiers the three bundles use, in one place.
enum SevenZipBundle {
    static let app = "com.yrambler2001.7zip"
    static let finderSync = "com.yrambler2001.7zip.FinderSync"
    static let quickActionExtract = "com.yrambler2001.7zip.QuickActionExtract"
    static let quickActionCompress = "com.yrambler2001.7zip.QuickActionCompress"

    /// `SEVENZIP_DEFAULTS_SUITE` (`NMacPrefs::kSuiteEnvVar`), honoured on every access so a test
    /// can switch domains mid-process.
    static let suiteEnvironmentVariable = "SEVENZIP_DEFAULTS_SUITE"

    /// The user's real home directory. `NSHomeDirectory()` is the container root inside a
    /// sandboxed extension (`~/Library/Containers/<id>/Data`), so the prefix is stripped.
    static var realHomeDirectory: String {
        let home = NSHomeDirectory()
        guard let range = home.range(of: "/Library/Containers/") else { return home }
        return String(home[home.startIndex..<range.lowerBound])
    }

    /// The containing `7-Zip.app`, seen from an appex inside `Contents/PlugIns`.
    static var containingAppURL: URL {
        var url = Bundle.main.bundleURL
        while url.pathExtension == "appex" || url.lastPathComponent == "PlugIns"
            || url.lastPathComponent == "Contents" {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    /// The preferences domain in use, exactly as `NMacPrefs::ApplicationID()` resolves it.
    static var preferencesDomain: String {
        if let env = ProcessInfo.processInfo.environment[suiteEnvironmentVariable], !env.isEmpty {
            return env
        }
        return app
    }
}

/// The five `Options.*` values, plus where they came from.
struct IntegrationSettings: Equatable {

    enum Key {
        static let cascadedMenu = "Options.CascadedMenu"
        static let menuIcons = "Options.MenuIcons"
        static let elimDupExtract = "Options.ElimDupExtract"
        static let writeZoneIdExtract = "Options.WriteZoneIdExtract"
        static let contextMenu = "Options.ContextMenu"
        /// Not a Windows value: the resolved lang texts the app pushes with the snapshot.
        static let localizedTitles = "Options.LocalizedTitles"
    }

    /// `CascadedMenu`, default **true**.
    var cascadedMenu = true
    /// `MenuIcons`, default false.
    var menuIcons = false
    /// `ElimDupExtract`, default **true**; `-spe` on the `Extract to "<x>/"` command only.
    var eliminateDuplicateRoot = true
    /// `WriteZoneIdExtract`: -1 unset (= no), 0 no, 1 yes, 2 Office files only.
    var writeZoneIdExtract = -1
    /// `ContextMenu` bit mask; every item when the value is absent.
    var flags: ContextMenuItemFlags = .all
    /// Lang-file texts the app resolved for the extension, keyed by the decimal lang ID. The
    /// `.txt` reader lives in the bridge framework, which a sandboxed appex must not link, so the
    /// app pushes the resolved strings with the rest of the snapshot and the extension's
    /// `localize` closure reads them. Missing IDs fall back to the English resource text.
    var localizedTitles: [String: String] = [:]

    static let `default` = IntegrationSettings()

    /// The lang IDs the Finder menu needs (Explorer/resource.h + PropertyName.cpp).
    static let menuLangIDs: [UInt32] = [
        2322,  // IDS_CONTEXT_OPEN            "Open archive"
        2323,  // IDS_CONTEXT_EXTRACT         "Extract files..."
        2324,  // IDS_CONTEXT_COMPRESS        "Add to archive..."
        2325,  // IDS_CONTEXT_TEST            "Test archive"
        2326,  // IDS_CONTEXT_EXTRACT_HERE    "Extract Here"
        2327,  // IDS_CONTEXT_EXTRACT_TO      "Extract to {0}"
        2328,  // IDS_CONTEXT_COMPRESS_TO     "Add to {0}"
        2329,  // IDS_CONTEXT_COMPRESS_EMAIL  "Compress and email..."
        2330,  // IDS_CONTEXT_COMPRESS_TO_EMAIL "Compress to {0} and email"
        3015,  // IDS_SELECT_FILES            "You must select one or more files"
        1046,  // GetNameOfProperty(kpidChecksum) = 1000 + 46 "Checksum"
    ]

    /// `LangString(id)` with the English resource text as the fallback.
    func localize(_ id: UInt32, _ fallback: String) -> String {
        let text = localizedTitles[String(id)]
        return (text?.isEmpty == false) ? text! : fallback
    }

    /// `-snz<N>` for the extract commands, or nil when the value is unset or 0.
    var zoneIDSwitchValue: Int? {
        writeZoneIdExtract == -1 ? nil : writeZoneIdExtract
    }

    // MARK: - Reading

    /// The snapshot file inside the Finder Sync extension's container, written by the app.
    static func snapshotURL(forExtension bundleID: String) -> URL {
        // The path is built from the real home in both processes: the app writes it, the sandboxed
        // extension reads it inside its own container.
        URL(fileURLWithPath: SevenZipBundle.realHomeDirectory)
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences")
            .appendingPathComponent("com.yrambler2001.7zip.integration.plist")
    }

    /// Read the values the extension should use: the pushed snapshot first, the app's own
    /// preferences domain second, the documented defaults last.
    static func current(extensionBundleID: String? = nil) -> IntegrationSettings {
        if let bundleID = extensionBundleID,
           let snapshot = load(fromSnapshotAt: snapshotURL(forExtension: bundleID)) {
            return snapshot
        }
        return loadFromPreferences()
    }

    static func load(fromSnapshotAt url: URL) -> IntegrationSettings? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return IntegrationSettings(dictionary: dict)
    }

    /// `CFPreferencesCopyAppValue` on `SevenZipBundle.preferencesDomain`, with the same
    /// CFBoolean / CFNumber shapes `NMacPrefs` writes (`MacPrefs.cpp:91-185`).
    static func loadFromPreferences(domain: String = SevenZipBundle.preferencesDomain)
        -> IntegrationSettings {
        var out = IntegrationSettings()
        let appID = domain as CFString

        func value(_ key: String) -> Any? {
            CFPreferencesCopyAppValue(key as CFString, appID) as Any?
        }
        func boolValue(_ key: String) -> Bool? {
            guard let v = value(key) else { return nil }
            if let n = v as? NSNumber { return n.boolValue }
            return nil
        }
        func intValue(_ key: String) -> Int? {
            guard let v = value(key) else { return nil }
            if let n = v as? NSNumber { return n.intValue }
            return nil
        }

        if let v = boolValue(Key.cascadedMenu) { out.cascadedMenu = v }
        if let v = boolValue(Key.menuIcons) { out.menuIcons = v }
        if let v = boolValue(Key.elimDupExtract) { out.eliminateDuplicateRoot = v }
        out.writeZoneIdExtract = intValue(Key.writeZoneIdExtract) ?? -1
        if let v = intValue(Key.contextMenu) {
            out.flags = ContextMenuItemFlags(rawValue: UInt32(truncatingIfNeeded: v))
        }
        return out
    }

    // MARK: - Snapshot round trip

    init() {}

    init(dictionary: [String: Any]) {
        self.init()
        if let v = dictionary[Key.cascadedMenu] as? NSNumber { cascadedMenu = v.boolValue }
        if let v = dictionary[Key.menuIcons] as? NSNumber { menuIcons = v.boolValue }
        if let v = dictionary[Key.elimDupExtract] as? NSNumber { eliminateDuplicateRoot = v.boolValue }
        if let v = dictionary[Key.writeZoneIdExtract] as? NSNumber { writeZoneIdExtract = v.intValue }
        if let v = dictionary[Key.contextMenu] as? NSNumber {
            flags = ContextMenuItemFlags(rawValue: UInt32(truncatingIfNeeded: v.intValue))
        }
        if let v = dictionary[Key.localizedTitles] as? [String: String] { localizedTitles = v }
    }

    /// The plist the app pushes. Key names are unchanged so the same dictionary also matches
    /// `Settings.finderIntegrationSettings()`.
    var dictionary: [String: Any] {
        [
            Key.cascadedMenu: cascadedMenu,
            Key.menuIcons: menuIcons,
            Key.elimDupExtract: eliminateDuplicateRoot,
            Key.writeZoneIdExtract: writeZoneIdExtract,
            Key.contextMenu: Int(Int32(truncatingIfNeeded: flags.rawValue)),
            Key.localizedTitles: localizedTitles,
        ]
    }
}
