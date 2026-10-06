// TestSupport.swift -- the test-side half of `ai/test-support-contract.md`: which app
// instance a shard drives, the environment it launches with, and the `sevenzip://test/reset`
// command that returns a running instance to a known state instead of quitting it.
//
// Three things live here.
//
// 1. `TestShard` -- the identity of this XCUITest bundle. Every UI-test target is built against an
//    app target of its own with its own `PRODUCT_BUNDLE_IDENTIFIER`, which is what lets the
//    read-only shards run **at the same time** on one machine: `XCUIApplication.launch()` attaches
//    to an instance that is already running rather than replacing it, and `terminate()` kills every
//    process with that bundle id, so two shards sharing an id fail each other's tests. The shard
//    reads its own app's name and id out of its Info.plist (`SEVENZIP_APP_NAME` /
//    `SEVENZIP_APP_BUNDLE_ID`, set per target in `Mac/project.yml`), so one `.xctestrun` can run
//    them all.
//
// 2. `TestShard.environment(for:)` -- `SZ_TEST_SUPPORT`, `SZ_DISABLE_ANIMATIONS` and `SZ_STATE_DIR`
//    per test class, so animations cost nothing and no two instances write the same file.
//
// 3. `SevenZipApp.reset(...)` -- the reset command, with the capability probe the contract makes
//    possible: the main window's accessibility **value** is the reset generation as a decimal
//    string, starting at `0`. An app that does not implement the contract has no such value, so the
//    probe is a plain read with no side effect -- which matters, because sending
//    `sevenzip://test/reset` to an app without the support raises its "Unsupported URL command"
//    error box (`CommandURL.parse`). When the probe says no, `reset` falls back to a relaunch with
//    the same settings, so every test is correct both before and after the app side lands; what
//    changes is only how long it takes. `SevenZipApp.testSupportIsImplemented` reports which of the
//    two happened, and `TestSupportContractTests` asserts the contract itself.

import AppKit
import XCTest

// MARK: - Which instance this shard drives

public enum TestShard {

    /// `SEVENZIP_APP_BUNDLE_ID` from this test bundle's Info.plist; the shipping id when a target
    /// does not set one (the input shard drives the real app).
    public static let appBundleIdentifier: String = {
        info("SevenZipAppBundleID") ?? "com.yrambler2001.7zip"
    }()

    /// `SEVENZIP_APP_NAME` from this test bundle's Info.plist -- the `.app` this shard drives.
    public static let appName: String = {
        info("SevenZipAppName") ?? "7-Zip"
    }()

    /// A short name for this shard, used in state-directory and seed-file names.
    public static let name: String = {
        info("SevenZipShardName") ?? "ui"
    }()

    /// The app bundle this shard drives, needed to send a URL to *this* instance rather than to
    /// whichever copy LaunchServices considers the handler (another worktree's build, for one).
    ///
    /// testreg: found on disk only, never through Launch Services. The old last resort,
    /// `urlForApplication(withBundleIdentifier:)`, returned **`/Applications/7-Zip.app`** once the
    /// installed copy owned the registrations (finderfix unregisters the builds after every run), so
    /// "aimed" reopens and URLs went to the user's 7-Zip -- the three `NewWindowUITests` failures of
    /// ai/reports/gmode.md §5. It got that far because the bundle walk below stopped one
    /// level short: on macOS the test bundle is `<Config>/<Target>-Runner.app/Contents/PlugIns/
    /// <Target>.xctest`, four levels under `<Config>`, not three. nil means "not found", and every
    /// caller treats that as a failure rather than falling back to an unaimed request.
    public static let appURL: URL? = {
        if let path = ProcessInfo.processInfo.environment["SEVENZIP_APP_PATH"],
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path).standardizedFileURL
        }
        for directory in productsDirectories() {
            let candidate = directory.appendingPathComponent(appName + ".app")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate.standardizedFileURL }
        }
        return nil
    }()

    /// The bundle identifier the shipping app (and the user's installed copy) carries.
    public static let shippingBundleIdentifier = "com.yrambler2001.7zip"

    /// True when `url` is this shard's own app bundle (symlinks resolved).
    public static func isTestBuild(_ url: URL?) -> Bool {
        guard let url, let appURL else { return false }
        return canonical(url) == canonical(appURL)
    }

    /// Running copies of 7-Zip this shard must never launch, message, or terminate: any process with
    /// this shard's bundle identifier that is not this shard's build, and any copy of the shipping
    /// identifier outside this run's products directory (the user's `/Applications/7-Zip.app`,
    /// another worktree's build). XCUIApplication attaches to and terminates by bundle identifier,
    /// so with one of these running the input shard could drive or kill the user's app.
    public static func foreignInstances() -> [NSRunningApplication] {
        let products = appURL.map { canonical($0.deletingLastPathComponent()) + "/" }
        return NSWorkspace.shared.runningApplications.filter { running in
            guard let id = running.bundleIdentifier, !running.isTerminated else { return false }
            if id == appBundleIdentifier { return !isTestBuild(running.bundleURL) }
            guard id == shippingBundleIdentifier else { return false }
            guard let bundle = running.bundleURL, let products else { return true }
            return !canonical(bundle).hasPrefix(products)
        }
    }

    /// A readable list of `foreignInstances()` for a failure message; nil when there are none.
    public static func describeForeignInstances() -> String? {
        let found = foreignInstances()
        guard !found.isEmpty else { return nil }
        return found.map { "\($0.bundleURL?.path ?? "?") (pid \($0.processIdentifier))" }
            .joined(separator: ", ")
    }

    /// The guard every UI test runs before and after it touches the app (testreg): fails loudly
    /// when a 7-Zip that is not this shard's build is running, so a test can never drive, message
    /// or terminate the user's installed copy, and a test that *made* one start is named.
    public static func assertOnlyTestBuildRuns(_ when: String,
                                               file: StaticString = #filePath, line: UInt = #line) {
        guard appURL != nil else {
            XCTFail("cannot find this shard's \(appName).app next to the test runner; refusing to fall "
                    + "back to Launch Services (it would pick /Applications/7-Zip.app)", file: file, line: line)
            return
        }
        if let foreign = describeForeignInstances() {
            XCTFail("\(when): a 7-Zip that is not the build under test is running: \(foreign). "
                    + "The tests never touch it; quit it (or find the test that started it).",
                    file: file, line: line)
        }
    }

    private static func canonical(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// `SZ_STATE_DIR` for one test class: everything the instance would otherwise put in a shared
    /// location (work directory, temp extraction folders, caches) goes here, so two instances never
    /// touch the same file (contract, "Running several instances at once").
    public static func stateDirectory(for owner: String) -> String {
        let path = (TestPaths.artifacts as NSString)
            .appendingPathComponent("state-\(name)-\(slug(owner))")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// The environment every launch of this shard adds: the test affordances on, animations off,
    /// and a state directory of its own.
    public static func environment(for owner: String) -> [String: String] {
        ["SZ_TEST_SUPPORT": "1",
         "SZ_DISABLE_ANIMATIONS": "1",
         "SZ_STATE_DIR": stateDirectory(for: owner)]
    }

    // MARK: helpers

    private static func info(_ key: String) -> String? {
        guard let value = Bundle(for: ShardToken.self).infoDictionary?[key] as? String,
              !value.isEmpty, !value.hasPrefix("$(") else { return nil }
        return value
    }

    /// Where `build-for-testing` put the products. The runner app itself lives there
    /// (`<Products>/<Config>/<Target>-Runner.app/Contents/PlugIns/<Target>.xctest`), so every
    /// ancestor of the test bundle up to `<Config>` is tried, and xcodebuild also passes the list in
    /// `__XCODE_BUILT_PRODUCTS_DIR_PATHS`.
    private static func productsDirectories() -> [URL] {
        var found: [URL] = []
        var directory = Bundle(for: ShardToken.self).bundleURL
        for _ in 0..<5 {
            directory = directory.deletingLastPathComponent()      // PlugIns, Contents, Runner.app, <Config>, ...
            found.append(directory)
        }
        if let list = ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] {
            found += list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        }
        return found
    }

    private static func slug(_ text: String) -> String {
        let parts = text.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        return parts.suffix(2).joined(separator: "-")
    }

    private final class ShardToken {}
}

// MARK: - The reset command

public extension SevenZipApp {

    /// What `sevenzip://test/reset` is asked for. Every parameter is optional, as in the contract.
    struct ResetOptions {
        /// Absolute path to a plist that replaces the settings domain's contents.
        public var defaults: String?
        /// Language code to load, as the Options Language page would.
        public var language: String?
        /// 1 or 2.
        public var panels: Int?
        /// The directory each panel shows.
        public var path0: String?
        public var path1: String?
        /// Default view mode for both panels.
        public var view: Int?
        public init() {}
    }

    /// How the app was brought back to a known state.
    enum ResetOutcome: Equatable {
        /// The running instance honoured `sevenzip://test/reset` (generation `n`).
        case reset(generation: Int)
        /// The app does not implement the contract yet, so it was quit and launched again.
        case relaunched
        /// Neither worked.
        case failed(String)
    }

    /// The main window's accessibility value: the reset generation as a decimal string, `0` before
    /// the first reset (contract, "How a test knows the reset finished" point 2). nil when the app
    /// does not implement the contract -- or when there is no window at all.
    var resetGeneration: Int? {
        guard isRunning, window.exists else { return nil }
        guard let text = window.value as? String else { return nil }
        return Int(text.trimmingCharacters(in: .whitespaces))
    }

    /// True when the running instance implements the test-support contract. A pure read: nothing is
    /// sent to an app that would answer with an error box.
    var testSupportIsImplemented: Bool { resetGeneration != nil }

    /// Return the running instance to a known state without quitting it.
    ///
    /// Waits for **both** signals the contract specifies -- the ack file the app writes last, and
    /// the main window's generation going up -- instead of sleeping. Falls back to a relaunch with
    /// `seed` when the app does not implement the contract.
    @discardableResult
    func reset(_ options: ResetOptions, seed: SettingsSeed = .clean,
               timeout: TimeInterval = 30) -> ResetOutcome {
        guard isRunning, window.exists else {
            launch(seed: seed)
            return .relaunched
        }
        guard let before = resetGeneration else {
            // No generation on the window: the app side of the contract is not there yet. Sending
            // the URL would only raise "Unsupported URL command".
            launch(seed: seed)
            return .relaunched
        }

        let ack = (TestPaths.artifacts as NSString)
            .appendingPathComponent("reset-ack-\(TestShard.name)-\(UUID().uuidString.prefix(8)).txt")
        try? FileManager.default.removeItem(atPath: ack)
        guard let url = Self.resetURL(options, ack: ack) else {
            return .failed("could not build the reset URL")
        }
        guard open(url) else { return .failed("the app did not accept \(url.absoluteString)") }

        // Signal 1: the ack file, written last, holding the new generation as decimal text.
        let deadline = Date().addingTimeInterval(timeout)
        var acknowledged: Int?
        while Date() < deadline {
            if let text = try? String(contentsOfFile: ack, encoding: .utf8),
               let generation = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                acknowledged = generation
                break
            }
            usleep(20_000)
        }
        guard let acknowledged else {
            // Which half of the contract broke matters to whoever owns the app side: the generation
            // is published *before* the ack file is written, so a bumped generation with no file is a
            // failure in step 5, and an unbumped one means the reset stalled in steps 2-4 (settling,
            // reloading settings, rebuilding the panels) or never started at all.
            let now = resetGeneration.map(String.init) ?? "none"
            return .failed("no reset acknowledgement at \(ack) within \(Int(timeout)) s "
                           + "(generation was \(before), is now \(now); app "
                           + (isRunning ? "still running" : "gone") + "; "
                           + (FileManager.default.fileExists(atPath: requestPath ?? "")
                              ? "the request file was never taken" : "the request file was taken")
                           + ")" + (stallNote(ack: ack).map { "; stall note: " + $0 } ?? ""))
        }
        // A reset that could not settle still acknowledges, and says why in `<ack>.stall` (written
        // before the ack, removed by a clean reset; `ai/api/resetcmd.md`, "The stall note").
        // The app is then *not* in the known state the test asked for, so it is a failure -- with the
        // step that stalled named, instead of whatever the next assertion trips over.
        if let note = stallNote(ack: ack, generation: acknowledged) {
            try? FileManager.default.removeItem(atPath: ack)
            return .failed("the reset acknowledged generation \(acknowledged) but did not settle: \(note)")
        }
        // Signal 2: the window's generation went up.
        while Date() < deadline {
            if let now = resetGeneration, now > before, now >= acknowledged { break }
            usleep(20_000)
        }
        guard let after = resetGeneration, after > before else {
            return .failed("the ack was written but the window generation stayed at \(before)")
        }
        try? FileManager.default.removeItem(atPath: ack)
        return .reset(generation: after)
    }

    /// The stall note of a reset (`<ack>.stall`, else `<SZ_STATE_DIR>/reset-stall`), trimmed, when
    /// there is one -- and, with `generation`, only when its first field ("7: step 4 ...") names that
    /// generation, so a note about an earlier reset is never read as this one's
    /// (`ai/api/resetcmd.md`, "The stall note"; requests.md: modalfix -> harness).
    func stallNote(ack: String, generation: Int? = nil) -> String? {
        let candidates = [ack + ".stall",
                          (TestShard.stateDirectory(for: owner) as NSString).appendingPathComponent("reset-stall")]
        for path in candidates {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            let note = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else { continue }
            if let generation {
                let field = note.prefix { $0 != ":" }
                guard Int(field.trimmingCharacters(in: .whitespaces)) == generation else { continue }
            }
            return note
        }
        return nil
    }

    /// `sevenzip://test/reset?...` with the options that were given.
    static func resetURL(_ options: ResetOptions, ack: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "sevenzip"
        components.host = "test"
        components.path = "/reset"
        var items: [URLQueryItem] = []
        if let value = options.defaults { items.append(URLQueryItem(name: "defaults", value: value)) }
        if let value = options.language { items.append(URLQueryItem(name: "lang", value: value)) }
        if let value = options.panels { items.append(URLQueryItem(name: "panels", value: String(value))) }
        if let value = options.path0 { items.append(URLQueryItem(name: "path0", value: value)) }
        if let value = options.path1 { items.append(URLQueryItem(name: "path1", value: value)) }
        if let value = options.view { items.append(URLQueryItem(name: "view", value: String(value))) }
        if let ack { items.append(URLQueryItem(name: "ack", value: ack)) }
        components.queryItems = items
        return components.url
    }

    /// Send a `sevenzip://` URL to **this shard's** instance.
    ///
    /// Two channels, both aimed:
    ///
    /// 1. **`<SZ_STATE_DIR>/reset-request`** -- the app watches that file and treats its contents as
    ///    the URL (`ai/api/resetcmd.md` section 5). The state directory belongs to exactly one
    ///    instance, so a request left there cannot reach another; the watcher is a `Timer` in
    ///    `.common` mode, so it also arrives while `NSApp.runModal` is on the stack, which no Apple
    ///    event does. Any `sevenzip://` URL works, not only a reset.
    /// 2. `NSWorkspace.open(_:withApplicationAt:)` with this shard's bundle (`TestShard.appURL`).
    ///
    /// There is no third, unaimed `NSWorkspace.open(URL)` any more (testreg): Launch Services hands
    /// that to whichever registered bundle owns the scheme -- a probe once (resetcmd), and the user's
    /// installed `/Applications/7-Zip.app` on a machine that has one. Returns false instead.
    @discardableResult
    func open(_ url: URL, timeout: TimeInterval = 10) -> Bool {
        if writeRequest(url) { return true }
        // else: the app is not running or did not take the file, so aim the URL instead.
        guard let appURL = TestShard.appURL else {
            XCTFail("cannot aim \(url.scheme ?? "")://: this shard's app bundle was not found")
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        var outcome: Bool?
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: configuration) { _, error in
            outcome = error == nil
        }
        let deadline = Date().addingTimeInterval(timeout)
        while outcome == nil, Date() < deadline { usleep(20_000) }
        return outcome == true
    }

    /// `<SZ_STATE_DIR>/reset-request` for this instance, the file channel 1 writes.
    var requestPath: String? {
        (TestShard.stateDirectory(for: owner) as NSString).appendingPathComponent("reset-request")
    }

    /// Channel 1: the URL as the contents of `<SZ_STATE_DIR>/reset-request`.
    ///
    /// Returns true only when the app **took** the request: it removes the file before acting on it
    /// (`ai/api/resetcmd.md` section 5), so its disappearance is a delivery receipt. A
    /// successful *write* is not — on an app without the watcher the file would simply sit there and
    /// the command would silently never run, which is how three URL-driven tests failed the first
    /// time this channel was tried on a branch whose app side was not merged yet. When the file is
    /// still there, it is removed again and `open` falls through to the aimed `NSWorkspace` call.
    func writeRequest(_ url: URL, timeout: TimeInterval = 5) -> Bool {
        guard isRunning else { return false }
        let directory = TestShard.stateDirectory(for: owner)
        let request = URL(fileURLWithPath: directory).appendingPathComponent("reset-request")
        do {
            try Data(url.absoluteString.utf8).write(to: request, options: .atomic)
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !FileManager.default.fileExists(atPath: request.path) { return true }
            usleep(20_000)
        }
        try? FileManager.default.removeItem(at: request)
        return false
    }
}
