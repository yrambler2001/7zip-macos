// QuickLookPreferences.swift -- the few display settings the Quick Look preview extension follows,
// handed from the app to the sandboxed extension (quicklook scope, a macOS addition).
//
// The extension draws an archive the way the app's list does, so it needs four of the app's
// settings: the language (`Lang`, 01 §7.1), the theme (`FM.Theme`, Options > macOS), and the time
// format of the Modified column (`FM.TimestampLevel`, `FM.TimestampShowUTC`, View > Time, 01 §2.3).
// The extension is sandboxed and holds *no* entitlement besides the sandbox -- in particular not
// the read-only shared-preference exception the Finder extension uses, because the app's domain
// also holds the URL secret (`Integration.URLToken`), which an extension that parses untrusted
// archives has no business being able to read.
//
// So the app writes these four values -- and nothing else -- into the extension's own container
// (`~/Library/Containers/com.yrambler2001.7zip.QuickLook/Data/Library/Preferences/`), as
// `FinderSettingsBridge` does for the Finder extension; the app is unsandboxed and may write there,
// and the extension may always read its own container. The container exists once Quick Look has
// run the extension; until then (and if the file is unreadable) the extension falls back to the
// defaults: the system's language and appearance, minutes, local time.
//
// Foundation only: compiled into the app, the extension and the unit tests.

import Foundation

struct QuickLookPreferences: Equatable {

    /// The extension's bundle identifier (`Mac/project.yml`, target QuickLook).
    static let extensionBundleIdentifier = "com.yrambler2001.7zip.QuickLook"
    /// The snapshot's file name inside the container's `Library/Preferences`.
    static let fileName = "com.yrambler2001.7zip.quicklook.plist"

    /// Keys of the snapshot: the app's own settings keys (`Settings.Key`).
    enum Key {
        static let language = "Lang"
        static let theme = "FM.Theme"
        static let timestampLevel = "FM.TimestampLevel"
        static let timestampShowUTC = "FM.TimestampShowUTC"
    }

    /// `Lang`: "" = the system's language, "-" = English, else a file name ("de", "pt-br").
    var language: String?
    /// `FM.Theme`: "system" | "light" | "dark" (`AppTheme`); nil = follow the system.
    var theme: String?
    /// `FM.TimestampLevel` (`SZTimestampLevel` raw value); nil = minutes.
    var timestampLevel: Int?
    /// `FM.TimestampShowUTC`; nil = local time.
    var timestampShowUTC: Bool?

    init(language: String? = nil, theme: String? = nil, timestampLevel: Int? = nil, timestampShowUTC: Bool? = nil) {
        self.language = language
        self.theme = theme
        self.timestampLevel = timestampLevel
        self.timestampShowUTC = timestampShowUTC
    }

    init(dictionary: [String: Any]) {
        language = dictionary[Key.language] as? String
        theme = dictionary[Key.theme] as? String
        timestampLevel = (dictionary[Key.timestampLevel] as? NSNumber)?.intValue
        timestampShowUTC = (dictionary[Key.timestampShowUTC] as? NSNumber)?.boolValue
    }

    var dictionary: [String: Any] {
        var out: [String: Any] = [:]
        if let language { out[Key.language] = language }
        if let theme { out[Key.theme] = theme }
        if let timestampLevel { out[Key.timestampLevel] = timestampLevel }
        if let timestampShowUTC { out[Key.timestampShowUTC] = timestampShowUTC }
        return out
    }

    // MARK: - where

    /// The user's real home: `NSHomeDirectory()` is the container's `Data` folder inside a
    /// sandboxed process (the same rule as `SevenZipBundle.realHomeDirectory`).
    static func realHomeDirectory(_ home: String = NSHomeDirectory()) -> String {
        guard let range = home.range(of: "/Library/Containers/") else { return home }
        return String(home[home.startIndex..<range.lowerBound])
    }

    /// The extension's container (`~/Library/Containers/<id>`).
    static func containerURL(home: String = realHomeDirectory()) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Containers/\(extensionBundleIdentifier)")
    }

    /// The snapshot file, the same path from the app and from inside the extension.
    static func snapshotURL(home: String = realHomeDirectory()) -> URL {
        containerURL(home: home).appendingPathComponent("Data/Library/Preferences/\(fileName)")
    }

    // MARK: - reading (the extension)

    /// The pushed snapshot, or nil when there is none or it cannot be read.
    static func load(from url: URL = snapshotURL()) -> QuickLookPreferences? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = plist as? [String: Any] else { return nil }
        return QuickLookPreferences(dictionary: dictionary)
    }

    // MARK: - writing (the app)

    /// Writes the snapshot when the container exists (the system creates it the first time Quick
    /// Look runs the extension; a missing container is not an error). Returns whether it wrote.
    @discardableResult
    func write(home: String = QuickLookPreferences.realHomeDirectory()) -> Bool {
        let container = Self.containerURL(home: home)
        guard FileManager.default.fileExists(atPath: container.path),
              let data = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        else { return false }
        let url = Self.snapshotURL(home: home)
        if (try? Data(contentsOf: url)) == data { return true }      // unchanged: no write at all
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) != nil
    }
}
