// UpdateCheck.swift -- "is there a newer 7-Zip for macOS?", a macOS addition (pub3,
// ai/reports/pub3.md). 7zFM has no update check; the port's releases are published on GitHub
// (https://github.com/yrambler2001/7zip-macos/releases, tags v<port version>), and the app asks
// GitHub's public API for the latest one:
//
//   * at startup, File Manager launches only -- never for a 7zG-mode command from Finder (GMode),
//     never under test support (SZ_TEST_SUPPORT) -- at most once per 24 h, asynchronously, and
//     silently on any error (offline, rate limit, no release yet). Off with Options > macOS >
//     "Check for updates at startup" (FM.CheckUpdates);
//   * from Help > Check for Updates..., always, ignoring the 24 h and the skipped version, and
//     reporting every outcome.
//
// A newer release is offered in a message box owned by the main window: Download (opens the
// release page in the browser), Later, Skip This Version (FM.UpdateSkippedVersion: not offered at
// startup again). Nothing is downloaded or installed, and the request carries nothing but the
// standard headers (Accept, User-Agent).
//
// The pieces are separate so the tests can drive each without a network: `SemVer` (comparison),
// `ReleaseInfo.parse` (the API's JSON), `UpdateCheck` decisions (pure functions), `UpdateFetching`
// (the network, replaceable through `UpdateCheck.fetcher`) and the prompt (`UpdateCheck.prompt`).

import AppKit

// MARK: - Semantic versions

/// A semantic version (semver.org 2.0.0): MAJOR.MINOR.PATCH[-PRERELEASE][+BUILD]. A leading "v" is
/// accepted ("v1.2.0", the tag form), a missing MINOR or PATCH counts as 0, BUILD is ignored.
struct SemVer: Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    /// The dot-separated pre-release identifiers ("beta.2" -> ["beta", "2"]); empty for a release.
    let prerelease: [String]

    init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    init?(_ text: String) {
        var s = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if s.first == "v" || s.first == "V" { s = s.dropFirst() }
        if let plus = s.firstIndex(of: "+") { s = s[..<plus] }
        var pre: [String] = []
        if let dash = s.firstIndex(of: "-") {
            let tail = s[s.index(after: dash)...]
            pre = tail.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard !pre.isEmpty, pre.allSatisfy({ !$0.isEmpty }) else { return nil }
            s = s[..<dash]
        }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: pre)
    }

    var isPrerelease: Bool { !prerelease.isEmpty }

    var description: String {
        "\(major).\(minor).\(patch)" + (prerelease.isEmpty ? "" : "-" + prerelease.joined(separator: "."))
    }

    static func == (a: SemVer, b: SemVer) -> Bool {
        a.major == b.major && a.minor == b.minor && a.patch == b.patch && a.prerelease == b.prerelease
    }

    /// semver.org section 11: the numbers numerically; a pre-release sorts before its release;
    /// pre-release identifiers one by one, numeric ones numerically and below alphanumeric ones,
    /// which compare in ASCII order; a shorter list of equal identifiers sorts first.
    static func < (a: SemVer, b: SemVer) -> Bool {
        if a.major != b.major { return a.major < b.major }
        if a.minor != b.minor { return a.minor < b.minor }
        if a.patch != b.patch { return a.patch < b.patch }
        switch (a.prerelease.isEmpty, b.prerelease.isEmpty) {
        case (true, true), (true, false): return false
        case (false, true): return true
        case (false, false): break
        }
        for (x, y) in zip(a.prerelease, b.prerelease) where x != y {
            switch (Int(x), Int(y)) {
            case let (nx?, ny?): return nx < ny
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return x < y
            }
        }
        return a.prerelease.count < b.prerelease.count
    }
}

// MARK: - The release, as GitHub describes it

/// The fields of GET /repos/{owner}/{repo}/releases/latest that the check uses.
struct ReleaseInfo: Equatable, Decodable {
    let tagName: String
    let name: String
    let body: String
    let htmlURL: URL
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", name, body, htmlURL = "html_url", draft, prerelease
    }

    init(tagName: String, name: String = "", body: String = "", htmlURL: URL, draft: Bool = false, prerelease: Bool = false) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.draft = draft
        self.prerelease = prerelease
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        htmlURL = try c.decode(URL.self, forKey: .htmlURL)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
    }

    static func parse(_ data: Data) throws -> ReleaseInfo {
        try JSONDecoder().decode(ReleaseInfo.self, from: data)
    }

    /// The port version the tag names ("v1.2.0" -> 1.2.0); nil for a tag that is not one.
    var version: SemVer? { SemVer(tagName) }

    /// The engine version the release names ("7-Zip 26.04 for macOS 1.1.0" -> "26.04"), if it does.
    var upstreamVersion: String? {
        let pattern = #"7-Zip\s+([0-9]+\.[0-9]+)\s+for\s+macOS"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        for text in [name, body] {
            let range = NSRange(text.startIndex..., in: text)
            if let m = regex.firstMatch(in: text, range: range), let r = Range(m.range(at: 1), in: text) {
                return String(text[r])
            }
        }
        return nil
    }

    /// The first lines of the release notes, for the message box: blank lines and Markdown heading
    /// marks dropped, each line trimmed and cut at `lineLength`, at most `maxLines` of them.
    func notesExcerpt(maxLines: Int = 6, lineLength: Int = 120) -> String {
        var lines: [String] = []
        for raw in body.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.count > lineLength { line = String(line.prefix(lineLength - 3)) + "..." }
            if lines.count == maxLines { lines.append("..."); break }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - The network

/// Fetches the latest-release document. The tests replace it (`UpdateCheck.fetcher`); nothing in the
/// test suites ever reaches the network.
protocol UpdateFetching {
    /// Calls `completion` once, on any queue, with the response body of a 200 or an error.
    func fetchLatestRelease(completion: @escaping (Result<Data, Error>) -> Void)
}

struct UpdateCheckError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// URLSession, an ephemeral session (no cookies, no cache on disk), a short timeout.
struct URLSessionUpdateFetcher: UpdateFetching {
    var url: URL = UpdateCheck.latestReleaseURL
    var timeout: TimeInterval = 15

    /// The request, headers included: the API's media type and a User-Agent (GitHub refuses a
    /// request without one). Nothing else is sent.
    func makeRequest() -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("7-Zip-for-macOS/\(PortVersion.port)", forHTTPHeaderField: "User-Agent")
        return request
    }

    func fetchLatestRelease(completion: @escaping (Result<Data, Error>) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout * 2
        let session = URLSession(configuration: configuration)
        let task = session.dataTask(with: makeRequest()) { data, response, error in
            defer { session.finishTasksAndInvalidate() }
            if let error { completion(.failure(error)); return }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200, let data else {
                completion(.failure(UpdateCheckError(message: "HTTP \(status)")))
                return
            }
            completion(.success(data))
        }
        task.resume()
    }
}

// MARK: - Settings (macOS only, FM.* like the theme)

extension Settings.Key {
    /// Options > macOS > "Check for updates at startup" (default on).
    static let checkUpdates = "FM.CheckUpdates"
    /// When the last startup check was made, seconds since 1970.
    static let updateLastCheck = "FM.UpdateLastCheck"
    /// The port version the user chose to skip ("1.1.0").
    static let updateSkippedVersion = "FM.UpdateSkippedVersion"
}

extension Settings {
    static var checkUpdates: Bool {
        get { bool(Key.checkUpdates, default: true) }
        set { setBool(newValue, Key.checkUpdates) }
    }

    static var updateLastCheck: Date? {
        get { optionalInteger(Key.updateLastCheck).map { Date(timeIntervalSince1970: TimeInterval($0)) } }
        set { setOptionalInteger(newValue.map { Int($0.timeIntervalSince1970) }, Key.updateLastCheck) }
    }

    static var updateSkippedVersion: String? {
        get { string(Key.updateSkippedVersion) }
        set { setString(newValue, Key.updateSkippedVersion) }
    }
}

// MARK: - The check

enum UpdateCheck {

    static let latestReleaseURL = URL(string: "https://api.github.com/repos/yrambler2001/7zip-macos/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/yrambler2001/7zip-macos/releases")!
    /// At most one startup check per this interval.
    static let interval: TimeInterval = 24 * 60 * 60
    /// How long after launching the startup check waits: past `GMode.launchWindowGrace`, so a launch
    /// made for a Finder command is known as one by then.
    static var startupDelay: TimeInterval { GMode.launchWindowGrace + 1.5 }

    /// The network. Tests replace it with a stub.
    static var fetcher: UpdateFetching = URLSessionUpdateFetcher()
    /// Opens the release page. Tests replace it.
    static var opener: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// The clock. Tests replace it.
    static var now: () -> Date = Date.init

    // MARK: lang IDs (macOS addition, outside every official block, after the theme's 9900-9903)

    enum LangID {
        static let checkAtStartup: UInt32 = 9950     // Options > macOS checkbox
        static let menuItem: UInt32 = 9951           // Help > Check for Updates...
        static let newVersion: UInt32 = 9952         // "A new version is available: {0} (you have {1})."
        static let download: UInt32 = 9953
        static let later: UInt32 = 9954
        static let skip: UInt32 = 9955
        static let upToDate: UInt32 = 9956           // "You have the latest version ({0})."
        static let failed: UInt32 = 9957             // "Could not check for updates."
    }

    static var checkAtStartupText: String { Lang.text(LangID.checkAtStartup, "Check for updates at startup") }
    static var menuItemText: String { Lang.get(LangID.menuItem, "Check for &Updates...") }

    // MARK: decisions (pure)

    /// Whether this launch checks: the setting is on, it is not a test run, the app runs as the File
    /// Manager (a window of its own, no 7zG-mode command), and the last check is 24 h old (or in the
    /// future: a clock that went back does not block the check for ever).
    static func shouldCheckAtStartup(enabled: Bool, testSupport: Bool, commandMode: Bool,
                                     hasFileManagerWindow: Bool, lastCheck: Date?, now: Date) -> Bool {
        guard enabled, !testSupport, !commandMode, hasFileManagerWindow else { return false }
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed >= interval || elapsed < 0
    }

    enum Outcome: Equatable {
        /// A newer release than the running one.
        case newer(ReleaseInfo, SemVer)
        /// The latest release is this version or older.
        case upToDate
        /// No usable answer: offline, an HTTP error, a document that is not a release, a draft or a
        /// pre-release (the API's "latest" never is one, but the check does not rely on that).
        case failed(String)
    }

    /// Compares the release with the running version.
    static func evaluate(_ release: ReleaseInfo, current: SemVer) -> Outcome {
        if release.draft || release.prerelease { return .failed("the latest release is a draft or a pre-release") }
        guard let version = release.version else { return .failed("the release tag '\(release.tagName)' is not a version") }
        if version.isPrerelease { return .failed("the release tag '\(release.tagName)' is a pre-release") }
        return version > current ? .newer(release, version) : .upToDate
    }

    static func evaluate(_ result: Result<Data, Error>, current: SemVer) -> Outcome {
        switch result {
        case .failure(let error):
            return .failed(error.localizedDescription)
        case .success(let data):
            do {
                return evaluate(try ReleaseInfo.parse(data), current: current)
            } catch {
                return .failed("the answer is not a release")
            }
        }
    }

    /// Whether the outcome is shown: a manual check shows everything; a startup check only a newer
    /// version that the user has not skipped.
    static func shouldShow(_ outcome: Outcome, manual: Bool, skippedVersion: String?) -> Bool {
        if manual { return true }
        guard case .newer(_, let version) = outcome else { return false }
        if let skippedVersion, let skipped = SemVer(skippedVersion), skipped == version { return false }
        return true
    }

    // MARK: the message boxes' texts

    /// "A new version is available: 7-Zip 26.04 for macOS 1.1.0 (you have 1.0.0)." then the
    /// release's name and the first lines of its notes.
    static func newVersionMessage(_ release: ReleaseInfo, version: SemVer, current: String = PortVersion.port,
                                  upstream: String = PortVersion.upstream) -> String {
        let newName = PortVersion.displayName(upstream: release.upstreamVersion ?? upstream, port: version.description)
        let template = Lang.text(LangID.newVersion, "A new version is available: {0} (you have {1}).")
        var text = template.replacingOccurrences(of: "{0}", with: newName).replacingOccurrences(of: "{1}", with: current)
        var details: [String] = []
        let title = release.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, title != release.tagName, title != newName { details.append(title) }
        let notes = release.notesExcerpt()
        if !notes.isEmpty { details.append(notes) }
        if !details.isEmpty { text += "\n\n" + details.joined(separator: "\n") }
        return text
    }

    static func upToDateMessage(current: String = PortVersion.displayName) -> String {
        Lang.format(Lang.text(LangID.upToDate, "You have the latest version ({0})."), current)
    }

    static func failedMessage(_ reason: String) -> String {
        Lang.text(LangID.failed, "Could not check for updates.") + "\n" + reason
    }

    /// Download, Later, Skip This Version; Esc and the close box answer Later.
    static var promptButtons: WinMessageBox.Buttons {
        .custom([Lang.text(LangID.download, "Download"), Lang.text(LangID.later, "Later"),
                 Lang.text(LangID.skip, "Skip This Version")], escape: 1)
    }

    // MARK: running it

    /// The running version, as a SemVer (0.0.0 if the bundle's is not one, so any release is newer).
    static var currentVersion: SemVer { SemVer(PortVersion.port) ?? SemVer(major: 0, minor: 0, patch: 0) }

    private static var startupScheduled = false

    /// The shipping app's bundle identifier. The test copies of the app (7-Zip-Host, the UI-test
    /// probes) have identifiers of their own and never check at startup.
    static let appBundleIdentifier = "com.yrambler2001.7zip"

    /// A process that must not reach the network on its own: test support on (SZ_TEST_SUPPORT, every
    /// XCUITest launch), an XCTest host (the app-hosted tests run in a normal launch of 7-Zip-Host),
    /// or any copy of the app that is not the shipping one.
    static var isTestProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        return TestSupport.isEnabled
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || Bundle.main.bundleIdentifier != appBundleIdentifier
    }

    /// From `applicationDidFinishLaunching`: once, after `startupDelay`, if `shouldCheckAtStartup`.
    static func scheduleStartupCheck() {
        guard !startupScheduled, !isTestProcess else { return }
        startupScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + startupDelay) { startupCheckIfDue() }
    }

    /// The startup check, if this launch is one that checks.
    static func startupCheckIfDue() {
        let due = shouldCheckAtStartup(enabled: Settings.checkUpdates, testSupport: isTestProcess,
                                       commandMode: isCommandContext, hasFileManagerWindow: MainWindows.primary != nil,
                                       lastCheck: Settings.updateLastCheck, now: now())
        guard due else { return }
        Settings.updateLastCheck = now()
        check(manual: false)
    }

    /// A 7zG-mode command runs or launched the app: no File Manager context for a box.
    static var isCommandContext: Bool {
        GMode.launchedForCommand || GMode.isActive || SevenZipCommandLineEntry.isCommandMode
    }

    /// Fetches, evaluates and, if `shouldShow`, shows the outcome. `completion` gets the outcome on
    /// the main thread (the tests wait for it).
    static func check(manual: Bool, completion: ((Outcome) -> Void)? = nil) {
        let current = currentVersion
        fetcher.fetchLatestRelease { result in
            let outcome = evaluate(result, current: current)
            DispatchQueue.main.async {
                present(outcome, manual: manual)
                completion?(outcome)
            }
        }
    }

    /// Shows the outcome's box, owned by the main window. A startup outcome is dropped while a
    /// Finder command or another modal window is up: the next launch asks again.
    static func present(_ outcome: Outcome, manual: Bool) {
        guard shouldShow(outcome, manual: manual, skippedVersion: Settings.updateSkippedVersion) else { return }
        if !manual {
            guard !isCommandContext, NSApp.modalWindow == nil, MainWindows.primary != nil else {
                Settings.updateLastCheck = nil
                return
            }
        }
        let owner = MainWindows.primary?.window ?? NSApp.mainWindow
        switch outcome {
        case .newer(let release, let version):
            WinMessageBox.show(newVersionMessage(release, version: version), buttons: promptButtons,
                               icon: .information, owner: owner) { answer in
                handle(answer, release: release, version: version)
            }
        case .upToDate:
            WinMessageBox.show(upToDateMessage(), icon: .information, owner: owner)
        case .failed(let reason):
            WinMessageBox.show(failedMessage(reason), icon: .error, owner: owner)
        }
    }

    /// Download opens the release page; Skip remembers the version; Later does nothing.
    static func handle(_ answer: WinMessageBox.Result, release: ReleaseInfo, version: SemVer) {
        switch answer {
        case .button1: opener(release.htmlURL)
        case .button3: Settings.updateSkippedVersion = version.description
        default: break
        }
    }
}

// MARK: - Help > Check for Updates... (macOS addition, no Windows resource ID)

extension AppDelegate {
    @objc func helpCheckForUpdates(_ sender: Any?) {
        UpdateCheck.check(manual: true)
    }
}
