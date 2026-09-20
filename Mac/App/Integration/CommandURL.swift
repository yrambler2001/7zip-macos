// CommandURL.swift -- the `sevenzip://` transport that replaces the Win32 `#7zMap` shared-memory
// section (03-shell-integration-inventory.md section 1.5, section 6.4).
//
// The Finder Sync extension and the Quick Actions are sandboxed: they may not read files or spawn
// processes, but `NSWorkspace.open(URL)` is allowed. So they encode the identical 7zG argv and
// hand it to the app, which parses it with `SevenZipArguments` and runs it through the one
// `CommandExecutor`. Nothing about the argument grammar changes between the three routes.
//
//   sevenzip:///run?argv=<base64url JSON array of strings>[&tmp=<base64url JSON array of paths>]
//   sevenzip:///settings[?show=1]
//
// `tmp` names the temporary list files the sender created; the receiver deletes them once the
// command line has been parsed, which is what the Win32 side achieves with `CEventSetEnd`
// (ArchiveCommandLine.cpp:636-647).
//
// `x-7zip` is accepted as well because `03 section 6.4` spells the scheme that way.
//
// Foundation only: shared by the app, the Finder Sync extension, the Quick Actions and the tests.

import Foundation

enum CommandURL {

    /// The scheme registered in `Mac/App/Info.plist` (`CFBundleURLTypes`).
    static let scheme = "sevenzip"
    /// The spelling used by `03 section 6.4`, also registered.
    static let alternateScheme = "x-7zip"

    static let runPath = "/run"
    static let settingsPath = "/settings"

    /// The test-support host (`Mac/docs/test-support-contract.md`). `sevenzip://test/reset?<query>`
    /// returns a running app to a known state without quitting. Rejected outright unless
    /// `SZ_TEST_SUPPORT=1` is in the environment, so a shipped app has no such command.
    static let testHost = "test"
    static let resetPath = "/reset"

    /// Above this many selected items the paths go into a list file instead of the URL. 16 is
    /// the number of items Explorer itself passes before it reduces the selection
    /// (`k_Explorer_NumReducedItems`, ContextMenu.cpp:716), so the switch-over point is familiar.
    static let maximumInlinePathCount = 16
    /// ... and above this many UTF-8 bytes of paths, whichever comes first.
    static let maximumInlinePathBytes = 2048

    // MARK: - Actions

    enum Action: Equatable {
        /// Run a 7zG command line. `temporaryFiles` must be deleted by the receiver.
        case run(argv: [String], temporaryFiles: [String])
        /// Push the current settings to the extensions; `show` also opens Options > 7-Zip.
        case settings(show: Bool)
        /// Return the running app to a known state (test support only).
        case testReset(TestResetRequest)
    }

    /// `SZ_TEST_SUPPORT=1`. Read straight from the environment because this file is Foundation
    /// only: it is compiled into the two sandboxed appexes, which may not link `SevenZipKit`.
    /// `Settings.TestSupport.isEnabled` resolves the same variable through the bridge.
    static var testSupportEnabled: Bool { environmentValue("SZ_TEST_SUPPORT") == "1" }

    /// `getenv`, not `ProcessInfo.processInfo.environment`, so the value follows a `setenv` made
    /// during the process's life -- the rule `NMacPrefs::ApplicationID()` already follows.
    static func environmentValue(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    /// The per-instance temporary root a list file is written into: `<SZ_STATE_DIR>/tmp` when the
    /// state directory is active, else `NSTemporaryDirectory()`. Kept here, reading the environment
    /// directly, for the same Foundation-only reason; the bridge's `SZSettings.temporaryDirectory`
    /// is the same rule and a unit test asserts the two agree.
    static var temporaryRoot: String {
        guard testSupportEnabled,
              let dir = environmentValue("SZ_STATE_DIR"),
              (dir as NSString).isAbsolutePath else { return NSTemporaryDirectory() }
        let temp = ((dir as NSString).standardizingPath as NSString).appendingPathComponent("tmp") + "/"
        try? FileManager.default.createDirectory(atPath: temp, withIntermediateDirectories: true)
        return temp
    }

    // MARK: - Building

    static func url(argv: [String], temporaryFiles: [String] = []) -> URL? {
        guard let argvBlob = encode(argv) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = runPath
        var items = [URLQueryItem(name: "argv", value: argvBlob)]
        if !temporaryFiles.isEmpty, let tmpBlob = encode(temporaryFiles) {
            items.append(URLQueryItem(name: "tmp", value: tmpBlob))
        }
        components.queryItems = items
        return components.url
    }

    static func settingsURL(show: Bool) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = ""
        components.path = settingsPath
        if show { components.queryItems = [URLQueryItem(name: "show", value: "1")] }
        return components.url
    }

    // MARK: - Parsing

    static func parse(_ url: URL, testSupportEnabled enabled: Bool = CommandURL.testSupportEnabled)
        throws -> Action {
        let urlScheme = url.scheme?.lowercased()
        guard urlScheme == scheme || urlScheme == alternateScheme else {
            throw SevenZipArgumentError("Unsupported URL scheme", url.absoluteString)
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        let path = url.path.isEmpty ? runPath : url.path

        // The `test` host is a separate namespace, not a command: it exists only while the app was
        // started with SZ_TEST_SUPPORT=1, and the rejection is deliberately the same shape as an
        // unknown command so a shipped app gives nothing away.
        if url.host?.lowercased() == testHost {
            guard enabled else {
                throw SevenZipArgumentError("Unsupported URL command", url.absoluteString)
            }
            switch path {
            case resetPath:
                return .testReset(TestResetRequest(query: query))
            default:
                throw SevenZipArgumentError("Unsupported URL command", url.absoluteString)
            }
        }

        switch path {
        case runPath:
            guard let blob = query.first(where: { $0.name == "argv" })?.value,
                  let argv = decode(blob) else {
                throw SevenZipArgumentError("Specify command", url.absoluteString)
            }
            let tmp = query.first(where: { $0.name == "tmp" })?.value.flatMap(decode) ?? []
            return .run(argv: argv, temporaryFiles: tmp)
        case settingsPath:
            let show = query.first(where: { $0.name == "show" })?.value == "1"
            return .settings(show: show)
        default:
            throw SevenZipArgumentError("Unsupported URL command", url.absoluteString)
        }
    }

    // MARK: - base64url of a JSON string array

    static func encode(_ strings: [String]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: strings) else { return nil }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decode(_ blob: String) -> [String]? {
        var s = blob
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        guard let data = Data(base64Encoded: s),
              let any = try? JSONSerialization.jsonObject(with: data),
              let strings = any as? [String] else { return nil }
        return strings
    }

    // MARK: - Selection transport

    /// Which censor the paths belong to: the archive censor (`-ai`, extract and test) or the item
    /// censor (`-i`, add and hash).
    enum SelectionKind {
        case archives
        case items

        /// `kArcIncludeSwitches` = " -an -ai", `kIncludeSwitch` = " -i" (CompressCall.cpp:41-44).
        var switchPrefix: String { self == .archives ? "-ai" : "-i" }
        var needsNoArchiveName: Bool { self == .archives }
    }

    /// The switches that carry `paths`, and the temporary files the receiver must delete.
    ///
    /// Short selections become one `-<ai|i>w-!<path>` per item -- the `kImmediateNameID` source
    /// the parser already supports (ArchiveCommandLine.cpp:246, :829), with the `w-` postfix so a
    /// real file name containing `*`, `?` or `[` is not read as a wildcard (macOS allows all
    /// three; `ISWITCH_NO_WILDCARD_POSTFIX` is empty upstream only because Windows does not).
    /// Long selections become `-<ai|i>@<listfile>`, a UTF-8 list file in `listFileDirectory`
    /// (the caller's own temp directory, readable by the unsandboxed app).
    static func selectionArguments(paths: [String], kind: SelectionKind,
                                   listFileDirectory: String = CommandURL.temporaryRoot)
        -> (arguments: [String], temporaryFiles: [String]) {
        var arguments: [String] = []
        if kind.needsNoArchiveName { arguments.append("-an") }

        let byteCount = paths.reduce(0) { $0 + $1.utf8.count + 1 }
        let inline = paths.count <= maximumInlinePathCount && byteCount <= maximumInlinePathBytes

        if inline {
            for path in paths { arguments.append(kind.switchPrefix + "w-!" + path) }
            return (arguments, [])
        }

        guard let listPath = writeListFile(paths: paths, in: listFileDirectory) else {
            // Writing failed: fall back to the inline form rather than losing the command.
            for path in paths { arguments.append(kind.switchPrefix + "w-!" + path) }
            return (arguments, [])
        }
        arguments.append(kind.switchPrefix + "w-@" + listPath)
        return (arguments, [listPath])
    }

    /// One UTF-8 path per line, LF-separated, in a uniquely named file (`7zL-<uuid>.txt`).
    static func writeListFile(paths: [String], in directory: String) -> String? {
        let name = "7zL-\(UUID().uuidString).txt"
        let path = (directory as NSString).appendingPathComponent(name)
        let text = paths.joined(separator: "\n") + "\n"
        guard let data = text.data(using: .utf8) else { return nil }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            return nil
        }
        return path
    }

    /// Deletes the list files a command carried. Only files whose name matches the generated
    /// pattern are removed, so a hand-written `-i@list` is never destroyed.
    static func removeTemporaryFiles(_ paths: [String]) {
        for path in paths {
            let name = (path as NSString).lastPathComponent
            guard name.hasPrefix("7zL-"), name.hasSuffix(".txt") else { continue }
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // MARK: - Display

    /// The command line as 7-Zip would spell it, for logs, the report and the tests.
    static func displayText(_ argv: [String]) -> String {
        argv.map { token in
            token.contains(" ") ? "\"" + token + "\"" : token
        }.joined(separator: " ")
    }
}

// ---------------------------------------------------------------------------

/// The parsed form of `sevenzip://test/reset?<query>` (`Mac/docs/test-support-contract.md`).
///
/// Every parameter is optional and an absent one means "leave that alone", except that selection,
/// sort order, view mode and flat mode always go back to their defaults. Foundation only, so the
/// unit tests can assert the parse without the app.
///
/// A value the app cannot use (`panels=3`, `view=huge`) is **recorded in `warnings` and ignored**
/// rather than failing the whole command, because the acknowledgement file has to be written for
/// every reset a test issues -- a reset that refused to run would show up as a timeout with no
/// explanation. The warnings are logged by the app (`TestResetCoordinator`). See
/// `Mac/docs/api/resetcmd.md` section 4 for why this is the one place the contract is read
/// leniently.
struct TestResetRequest: Equatable {

    /// `defaults`: absolute path to a plist that replaces the settings domain's contents.
    var defaultsPath: String?
    /// `lang`: language code to load, as the Options > Language page would ("-" = built-in English).
    var language: String?
    /// `panels`: 1 or 2.
    var panelCount: Int?
    /// `path0` / `path1`: the directory each panel shows.
    var panelPaths: [Int: String] = [:]
    /// `view`: default view mode for both panels (0 large, 1 small, 2 list, 3 details).
    var viewMode: Int?
    /// `ack`: absolute path the app writes, last of all, once the reset is complete.
    var ackPath: String?
    /// Parameters that were not understood, for the log.
    var warnings: [String] = []

    init() {}

    /// The view-mode names accepted beside 0...3, because the contract does not spell an encoding
    /// (`FM.ListMode<N>`, 01b section 5.2: 0 large icons, 1 small icons, 2 list, 3 details).
    static let viewModeNames = ["large": 0, "small": 1, "list": 2, "details": 3]

    init(query: [URLQueryItem]) {
        for item in query {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "defaults":
                if (value as NSString).isAbsolutePath { defaultsPath = value }
                else { warnings.append("defaults must be an absolute path: \(value)") }
            case "lang":
                language = value
            case "panels":
                if let n = Int(value), n == 1 || n == 2 { panelCount = n }
                else { warnings.append("panels must be 1 or 2: \(value)") }
            case "path0", "path1":
                let index = item.name.hasSuffix("1") ? 1 : 0
                panelPaths[index] = value
            case "view":
                if let n = Int(value), (0...3).contains(n) { viewMode = n }
                else if let n = Self.viewModeNames[value.lowercased()] { viewMode = n }
                else { warnings.append("view must be 0...3 or large/small/list/details: \(value)") }
            case "ack":
                if (value as NSString).isAbsolutePath { ackPath = value }
                else { warnings.append("ack must be an absolute path: \(value)") }
            default:
                warnings.append("unknown reset parameter: \(item.name)")
            }
        }
    }

    /// The URL a test sends, for the tests and the documentation.
    var url: URL? {
        var components = URLComponents()
        components.scheme = CommandURL.scheme
        components.host = CommandURL.testHost
        components.path = CommandURL.resetPath
        var items: [URLQueryItem] = []
        if let defaultsPath { items.append(URLQueryItem(name: "defaults", value: defaultsPath)) }
        if let language { items.append(URLQueryItem(name: "lang", value: language)) }
        if let panelCount { items.append(URLQueryItem(name: "panels", value: String(panelCount))) }
        for index in panelPaths.keys.sorted() {
            items.append(URLQueryItem(name: "path\(index)", value: panelPaths[index]))
        }
        if let viewMode { items.append(URLQueryItem(name: "view", value: String(viewMode))) }
        if let ackPath { items.append(URLQueryItem(name: "ack", value: ackPath)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }
}
