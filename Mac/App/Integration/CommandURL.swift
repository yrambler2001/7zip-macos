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

    static func parse(_ url: URL) throws -> Action {
        let urlScheme = url.scheme?.lowercased()
        guard urlScheme == scheme || urlScheme == alternateScheme else {
            throw SevenZipArgumentError("Unsupported URL scheme", url.absoluteString)
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let query = components?.queryItems ?? []
        let path = url.path.isEmpty ? runPath : url.path

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
                                   listFileDirectory: String = NSTemporaryDirectory())
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
