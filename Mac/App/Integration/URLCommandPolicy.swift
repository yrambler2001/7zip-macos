// URLCommandPolicy.swift -- what a `sevenzip:///run` URL may make the app do (sec113).
//
// A URL can be opened by any process: a web page (after one browser prompt), any local app, and a
// sandboxed app as well, since `NSWorkspace.open(URL)` is allowed from the sandbox. The app that
// receives it is not sandboxed. So a command URL is accepted only when
//
//  1. it carries the **secret token** the app generated (`URLCommandToken`) -- only the app's own
//     extensions can read it, through the snapshot the app pushes into their containers or the
//     read-only shared-preference exception on the app's domain; and
//  2. its argv has exactly one of the **shapes the extensions build** (`FinderMenuModel`, 03
//     section 1.4), for the paths it names, with every target outside the protected folders.
//
// (2) is defence in depth: it holds even if the token leaked. It does not parse the 7zG grammar a
// second time. It reads the selection the URL names, asks `FinderMenuModel` for every command it
// would offer for those items (under every setting that changes a switch: `-spe`, `-snz<N>`), and
// requires the argv to be one of them, token for token. Everything the extensions never send --
// `-sdel`, `-p`, `-y`, `-ao*`, `-sfx`, `-r`, `-x`, `u`, `d`, `rn`, `e`, an `-o` that is not the
// archive's own folder, a list file the extension did not write -- is refused by construction; the
// explicit checks below only give the log a precise reason.
//
// The full 7zG grammar stays available to a real command line (`open -a 7-Zip --args …`, the
// `7zG` argv), which already needs local code execution.
//
// Foundation only: the app, the Services and the unit tests share it.

import Foundation

// MARK: - The token

/// The URL secret's format and the comparison. Generation and storage live in the app
/// (`URLCommandTokenStore`), which links Security and the settings bridge.
enum URLCommandToken {

    /// The settings key, in the app's domain (`com.yrambler2001.7zip`) and in the extension
    /// snapshot (`IntegrationSettings.snapshotURL`).
    static let settingsKey = "Integration.URLToken"

    /// The query item that carries it.
    static let queryName = "token"

    /// 256 bits as 64 lowercase hex digits.
    static let byteCount = 32

    static func isWellFormed(_ token: String?) -> Bool {
        guard let token, token.utf8.count == byteCount * 2 else { return false }
        return token.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Hex encoding of `bytes`.
    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Constant-time equality: every byte is compared whatever the earlier ones were, so the time
    /// taken says nothing about how much of a guess was right. The length is public (always 64).
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8)
        let y = Array(b.utf8)
        guard x.count == y.count, !x.isEmpty else { return false }
        var difference: UInt8 = 0
        for i in 0..<x.count { difference |= x[i] ^ y[i] }
        return difference == 0
    }

    /// Whether `presented` is the expected token. A missing or malformed value on either side is a
    /// mismatch.
    static func matches(_ presented: String?, expected: String?) -> Bool {
        guard isWellFormed(expected), let expected, let presented else { return false }
        return constantTimeEqual(presented, expected)
    }
}

// MARK: - The policy

struct URLCommandPolicy {

    /// What to do with one command.
    enum Decision: Equatable {
        /// Run `argv` (the selection inlined, list files already read) and delete `temporaryFiles`.
        case allow(argv: [String], temporaryFiles: [String])
        /// Refuse. `reason` is for the log only; the user sees `refusalMessage`.
        case refuse(String)

        var isAllowed: Bool { if case .allow = self { return true } else { return false } }
    }

    /// The one text the user sees. It does not say which check failed (the log does).
    static let refusalMessage =
        "7-Zip did not run a command that another application sent to it. Only commands from the "
        + "7-Zip Finder menu and Quick Actions are accepted this way."

    /// The user's real home directory.
    var homeDirectory: String
    /// Directories a `7zL-<uuid>.txt` list file may come from: the extensions' temporary folders
    /// and the app's own (`CommandURL.temporaryRoot`, the Services' long selections).
    var listFileDirectories: [String]
    /// Container names under `~/Library/Containers` that are not protected (test support only:
    /// the sandboxed XCUITest runner's scratch folder lives there).
    var exemptContainerSuffixes: [String] = []

    /// Folders under `~/Library` that hold ordinary user documents: iCloud Drive and the File
    /// Provider clouds (Dropbox, OneDrive, Google Drive, ...).
    static let documentFoldersInLibrary = ["Library/Mobile Documents", "Library/CloudStorage"]

    /// System folders a command from a URL never writes into or reads from.
    static let protectedSystemRoots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc",
                                       "/private/etc", "/private/var/db"]

    /// Commands the extensions build (`FinderMenuModel`): extract, test, add, hash.
    static let allowedCommands: Set<String> = ["x", "t", "a", "h"]

    /// Upper bounds, so a URL cannot make the app read an arbitrarily large list.
    static let maximumItems = 100_000
    static let maximumListFileBytes = 64 * 1024 * 1024

    /// The extensions' bundle identifiers, plus the same names under a differently-named build's
    /// identifier (`SevenZipBundle.runningAppIdentifier`).
    static func extensionBundleIDs(appIdentifier: String = SevenZipBundle.runningAppIdentifier) -> [String] {
        var ids = [SevenZipBundle.finderSync, SevenZipBundle.quickActionExtract,
                   SevenZipBundle.quickActionCompress]
        if appIdentifier != SevenZipBundle.app {
            ids += ["FinderSync", "QuickActionExtract", "QuickActionCompress"].map { appIdentifier + "." + $0 }
        }
        return ids
    }

    /// Debug builds are the ones the XCUITest suites drive. A URL launch from the sandboxed test
    /// runner reaches the app without the runner's environment (no `SZ_TEST_SUPPORT`), and the
    /// runner can only write inside its own container, so a Debug build does not protect the
    /// `*.xctrunner` containers. A Release build never exempts anything.
    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    /// The policy the app applies: the real home, the extensions' `tmp` folders and its own
    /// temporary root; with `SZ_TEST_SUPPORT=1` or in a Debug build, the XCUITest runners'
    /// containers are not protected.
    static func standard(testSupport: Bool = CommandURL.testSupportEnabled || isDebugBuild) -> URLCommandPolicy {
        let home = SevenZipBundle.realHomeDirectory
        var lists = extensionBundleIDs().map {
            (home as NSString).appendingPathComponent("Library/Containers/\($0)/Data/tmp")
        }
        lists.append(CommandURL.temporaryRoot)
        lists.append(NSTemporaryDirectory())
        return URLCommandPolicy(homeDirectory: home, listFileDirectories: lists,
                                exemptContainerSuffixes: testSupport ? [".xctrunner"] : [])
    }

    // MARK: - Evaluation

    func evaluate(argv: [String], temporaryFiles: [String]) -> Decision {
        guard let first = argv.first else { return .refuse("empty command") }
        if argv.contains(where: { $0.contains("\0") }) { return .refuse("NUL in an argument") }

        // "Open archive" (A1 / A2): the 7zFM argv `<path> [-t<type>]`. It only opens a window.
        if first.hasPrefix("/") {
            return evaluateOpen(argv)
        }
        guard Self.allowedCommands.contains(first) else {
            return .refuse("command '\(first)' is not built by the extensions")
        }
        if let reason = forbiddenSwitchReason(argv) { return .refuse(reason) }

        // Split the argv around the selection switches.
        let end = argv.firstIndex(of: "--") ?? argv.count
        let selectionIndices = (1..<max(end, 1)).filter { isSelectionSwitch(argv[$0]) }
        guard let low = selectionIndices.first, let high = selectionIndices.last else {
            return .refuse("no selection")
        }
        guard selectionIndices.count == high - low + 1 else { return .refuse("split selection") }
        let selectionTokens = Array(argv[low...high])
        let kind: CommandURL.SelectionKind
        var prefixEnd = low
        if selectionTokens.allSatisfy({ $0.hasPrefix("-aiw-") }) {
            kind = .archives
            guard low >= 2, argv[low - 1] == "-an" else { return .refuse("archive selection without -an") }
            prefixEnd = low - 1
        } else if selectionTokens.allSatisfy({ $0.hasPrefix("-iw-") }) {
            kind = .items
        } else {
            return .refuse("mixed selection switches")
        }
        let prefix = Array(argv[0..<prefixEnd])
        let suffix = Array(argv[(high + 1)...])

        // The selected paths: inline, or one list file the extension wrote.
        let switchPrefix = kind.switchPrefix + "w-"
        var paths: [String] = []
        var acceptedTemporaryFiles: [String] = []
        let lists = selectionTokens.filter { $0.hasPrefix(switchPrefix + "@") }
        if lists.isEmpty {
            paths = selectionTokens.map { String($0.dropFirst(switchPrefix.count + 1)) }
        } else {
            guard selectionTokens.count == 1 else { return .refuse("list file mixed with names") }
            let listPath = String(selectionTokens[0].dropFirst(switchPrefix.count + 1))
            guard temporaryFiles.contains(listPath) else { return .refuse("list file not declared in tmp") }
            switch readListFile(listPath) {
            case .success(let read): paths = read
            case .failure(let reason): return .refuse(reason.text)
            }
            acceptedTemporaryFiles = [listPath]
        }
        guard !paths.isEmpty, paths.count <= Self.maximumItems else { return .refuse("selection size") }

        // Every selected item: an absolute, clean path to something that exists, outside the
        // protected folders once symbolic links are resolved.
        var followFlags: [Bool] = []
        var linkFlags: [Bool] = []
        for path in paths {
            guard Self.isCleanAbsolutePath(path) else { return .refuse("unclean path") }
            guard let info = Self.fileInfo(path) else { return .refuse("selected item does not exist") }
            guard let real = resolvedPath(path), !isProtected(real) else {
                return .refuse("selected item in a protected folder")
            }
            followFlags.append(info.followsToDirectory)
            linkFlags.append(info.isDirectory)
        }

        // The argv must be one the menu would build for exactly these items.
        guard let command = matchingCommand(paths: paths, flagVariants: [followFlags, linkFlags],
                                            kind: kind, prefix: prefix, suffix: suffix) else {
            return .refuse("not a command the extensions build")
        }

        // Where it writes.
        for target in outputTargets(of: command, prefix: prefix, suffix: suffix) {
            guard Self.isCleanAbsolutePath(target) else { return .refuse("unclean target") }
            guard let real = resolvedPath(target) else { return .refuse("unresolvable target") }
            if isProtected(real) { return .refuse("target in a protected folder") }
        }

        // The command that runs names the items inline, so a list file cannot change between
        // this check and the parse.
        let inline = paths.map { switchPrefix + "!" + $0 }
        let selection = (kind.needsNoArchiveName ? ["-an"] : []) + inline
        return .allow(argv: prefix + selection + suffix, temporaryFiles: acceptedTemporaryFiles)
    }

    /// A1 / A2: `<path>` or `<path> -t<type>` with a type from the "Open archive >" submenu.
    private func evaluateOpen(_ argv: [String]) -> Decision {
        guard argv.count <= 2, Self.isCleanAbsolutePath(argv[0]) else { return .refuse("open: bad shape") }
        if argv.count == 2 {
            let types = ArchiveNaming.openTypes.filter { !$0.isEmpty }.map { "-t" + $0 }
            guard types.contains(argv[1]) else { return .refuse("open: unexpected type") }
        }
        return .allow(argv: argv, temporaryFiles: [])
    }

    // MARK: - Shape matching

    /// The menu command whose argv, for `paths`, is `prefix + <selection> + suffix`, under any of
    /// the settings that change a switch and either reading of "is a directory" (Finder reports a
    /// symbolic link to a folder as a file; `stat` follows it).
    private func matchingCommand(paths: [String], flagVariants: [[Bool]],
                                 kind: CommandURL.SelectionKind, prefix: [String],
                                 suffix: [String]) -> FinderMenuCommand? {
        var seen = Set<[Bool]>()
        for flags in flagVariants where seen.insert(flags).inserted {
            let selection = FinderSelection(paths: paths, directoryFlags: flags)
            for settings in Self.settingVariants() {
                for command in FinderMenuModel.allCommands(selection: selection, settings: settings)
                where command.selectionKind == kind
                    && command.prefixArguments == prefix && command.suffixArguments == suffix {
                    // `InvokeCommandCommon` refuses extract/test on a folder (ContextMenu.cpp:1280).
                    if command.refusesDirectories, flags.contains(true) { continue }
                    return command
                }
            }
        }
        return nil
    }

    /// `ElimDupExtract` on and off times `WriteZoneIdExtract` none / 0 / 1 / 2.
    static func settingVariants() -> [IntegrationSettings] {
        var out: [IntegrationSettings] = []
        for spe in [true, false] {
            for zone in [-1, 0, 1, 2] {
                var s = IntegrationSettings()
                s.eliminateDuplicateRoot = spe
                s.writeZoneIdExtract = zone
                out.append(s)
            }
        }
        return out
    }

    /// The paths a matched command writes: the `-o` folder of an extract, the archive of an add
    /// (not the e-mail variants, which build in 7-Zip's own temporary folder).
    private func outputTargets(of command: FinderMenuCommand, prefix: [String],
                               suffix: [String]) -> [String] {
        var targets: [String] = []
        for token in prefix where token.hasPrefix("-o") { targets.append(String(token.dropFirst(2))) }
        if prefix.first == "a", !suffix.contains("-seml."), let last = suffix.last,
           suffix.dropLast().last == "--" {
            targets.append(last)
        }
        return targets
    }

    // MARK: - Switches

    private func isSelectionSwitch(_ token: String) -> Bool {
        ["-aiw-!", "-aiw-@", "-iw-!", "-iw-@"].contains { token.hasPrefix($0) }
    }

    /// A precise reason for the log when a switch the extensions never send is present. The shape
    /// match refuses these anyway.
    func forbiddenSwitchReason(_ argv: [String]) -> String? {
        let end = argv.firstIndex(of: "--") ?? argv.count
        for token in argv[1..<max(end, 1)] {
            let t = token.lowercased()
            if t == "-sdel" { return "-sdel" }
            if t.hasPrefix("-p") { return "-p (password)" }
            if t == "-y" { return "-y" }
            if t.hasPrefix("-ao") { return "-ao (overwrite mode)" }
            if t.hasPrefix("-sfx") { return "-sfx" }
            if t.hasPrefix("-r") { return "-r (recursion)" }
            if t.hasPrefix("-x") || t.hasPrefix("-ax") { return "-x (exclude)" }
            if t.hasPrefix("-w") { return "-w (working folder)" }
            if t.hasPrefix("-v") { return "-v (volumes)" }
            if t.hasPrefix("-spf") || t.hasPrefix("-snl") || t.hasPrefix("-snh") {
                return "\(token) (path handling)"
            }
            if t.hasPrefix("-i@") || t.hasPrefix("-ai@") || t.hasPrefix("-i!") || t.hasPrefix("-ai!") {
                return "\(t.prefix(4)) (wildcard selection)"
            }
        }
        return nil
    }

    // MARK: - List files

    struct ListFileError: Error {
        let text: String
        static func refused(_ text: String) -> ListFileError { ListFileError(text: text) }
    }

    /// Reads a `7zL-<uuid>.txt` the extension wrote: in one of `listFileDirectories`, a regular
    /// file (not a link) owned by this user, UTF-8, one path per line.
    func readListFile(_ path: String) -> Result<[String], ListFileError> {
        guard Self.isCleanAbsolutePath(path) else { return .failure(.refused("list file: unclean path")) }
        let name = (path as NSString).lastPathComponent
        guard name.hasPrefix("7zL-"), name.hasSuffix(".txt"),
              UUID(uuidString: String(name.dropFirst(4).dropLast(4))) != nil else {
            return .failure(.refused("list file: unexpected name"))
        }
        let directory = (path as NSString).deletingLastPathComponent
        guard let realDirectory = Self.realPath(directory),
              listFileDirectories.compactMap({ Self.realPath($0) }).contains(realDirectory) else {
            return .failure(.refused("list file: unexpected folder"))
        }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(),
              st.st_size <= off_t(Self.maximumListFileBytes) else {
            return .failure(.refused("list file: not a regular file of this user"))
        }
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return .failure(.refused("list file: unreadable"))
        }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return .success(lines)
    }

    // MARK: - Paths

    /// Absolute, no `.` or `..` component, no empty component, no line break. `..` is refused
    /// outright rather than standardised away: the extensions never produce one.
    static func isCleanAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.contains("\n"), !path.contains("\r"),
              !path.contains("\0") else { return false }
        if path == "/" { return true }
        var components = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        if components.last == "" { components.removeLast() }       // one trailing slash
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    struct FileInfo {
        /// `lstat`: the item itself is a directory.
        var isDirectory: Bool
        /// `stat`: the item, following a link, is a directory.
        var followsToDirectory: Bool
    }

    static func fileInfo(_ path: String) -> FileInfo? {
        var l = stat()
        guard lstat(path, &l) == 0 else { return nil }
        var s = stat()
        let follows = stat(path, &s) == 0 && (s.st_mode & S_IFMT) == S_IFDIR
        return FileInfo(isDirectory: (l.st_mode & S_IFMT) == S_IFDIR, followsToDirectory: follows)
    }

    /// `realpath(3)`, nil when the path cannot be resolved.
    static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The path with every symbolic link resolved: the deepest part that exists goes through
    /// `realpath`, the part that does not exist yet is appended. A dangling link -- something
    /// exists, but cannot be resolved -- is nil, because where it would write is unknown.
    func resolvedPath(_ path: String) -> String? {
        // Without the trailing slash: `lstat("link/")` follows the link, so a dangling one would
        // look absent and its name would be appended unresolved.
        var existing = path
        while existing.count > 1, existing.hasSuffix("/") { existing.removeLast() }
        var missing: [String] = []
        while existing != "/" {
            var st = stat()
            if lstat(existing, &st) == 0 { break }
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard var real = Self.realPath(existing) else { return nil }
        for component in missing { real = (real as NSString).appendingPathComponent(component) }
        return real
    }

    /// Whether a resolved path is in `~/Library` (outside its document folders) or a system folder.
    func isProtected(_ resolved: String) -> Bool {
        func isInside(_ path: String, _ root: String) -> Bool {
            path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
        for root in Self.protectedSystemRoots where isInside(resolved, root) { return true }
        let home = Self.realPath(homeDirectory) ?? homeDirectory
        let library = (home as NSString).appendingPathComponent("Library")
        guard isInside(resolved, library) else { return false }
        for folder in Self.documentFoldersInLibrary
        where isInside(resolved, (home as NSString).appendingPathComponent(folder)) {
            return false
        }
        if !exemptContainerSuffixes.isEmpty {
            let containers = (library as NSString).appendingPathComponent("Containers")
            if isInside(resolved, containers), resolved.count > containers.count + 1 {
                let rest = resolved.dropFirst(containers.count + 1)
                let container = rest.split(separator: "/").first.map(String.init) ?? ""
                if exemptContainerSuffixes.contains(where: { container.hasSuffix($0) }) { return false }
            }
        }
        return true
    }
}
