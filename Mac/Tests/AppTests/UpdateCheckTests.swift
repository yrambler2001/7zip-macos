// UpdateCheckTests.swift -- the update check (pub3, ai/reports/pub3.md; UpdateCheck.swift): semantic
// version comparison, the GitHub release JSON, the startup decision (24 h, the setting, test
// support, 7zG mode), the skipped version, Help > Check for Updates..., the Options > macOS
// checkbox and the message boxes. The network is always the stub below: no test reaches GitHub.

import AppKit
import XCTest
@testable import SevenZipAppHost

/// Answers every fetch with a canned result and counts the calls.
final class StubUpdateFetcher: UpdateFetching {
    var result: Result<Data, Error>
    private(set) var calls = 0

    init(_ result: Result<Data, Error>) { self.result = result }

    func fetchLatestRelease(completion: @escaping (Result<Data, Error>) -> Void) {
        calls += 1
        let result = self.result
        DispatchQueue.global().async { completion(result) }
    }
}

final class UpdateCheckTests: AppHostTestCase {

    override var screenshotPrefix: String { "pub3" }

    /// A trimmed copy of a real GET /repos/{owner}/{repo}/releases/latest answer: every field the
    /// check reads, and enough of the others (author, assets) that the decoder must skip them.
    static func releaseJSON(tag: String = "v1.2.0", name: String = "7-Zip 26.04 for macOS 1.2.0",
                            draft: Bool = false, prerelease: Bool = false,
                            body: String = "## What's new\\r\\n\\r\\n- Faster listing of large archives\\r\\n- Fixed the Finder menu on macOS 26\\r\\n") -> Data {
        """
        {
          "url": "https://api.github.com/repos/yrambler2001/7zip-macos/releases/1",
          "html_url": "https://github.com/yrambler2001/7zip-macos/releases/tag/\(tag)",
          "id": 1,
          "author": { "login": "yrambler2001", "id": 2, "type": "User" },
          "tag_name": "\(tag)",
          "target_commitish": "macos",
          "name": "\(name)",
          "draft": \(draft),
          "prerelease": \(prerelease),
          "created_at": "2026-11-01T10:00:00Z",
          "published_at": "2026-11-01T10:05:00Z",
          "assets": [ { "name": "7-Zip-26.04-macOS-1.2.0.dmg", "size": 9000000,
                        "browser_download_url": "https://github.com/yrambler2001/7zip-macos/releases/download/\(tag)/7-Zip-26.04-macOS-1.2.0.dmg" } ],
          "tarball_url": null,
          "body": "\(body)"
        }
        """.data(using: .utf8)!
    }

    private var savedFetcher: UpdateFetching!
    private var savedOpener: ((URL) -> Void)!
    private var savedNow: (() -> Date)!
    private var controllers: [MainWindowController] = []
    private var savedPanelPath: String?

    private static let keys = [Settings.Key.checkUpdates, Settings.Key.updateLastCheck, Settings.Key.updateSkippedVersion]

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedFetcher = UpdateCheck.fetcher
        savedOpener = UpdateCheck.opener
        savedNow = UpdateCheck.now
        savedPanelPath = Settings.panelPath(0)
        // Belt and braces: a test that forgot its stub fails instead of reaching GitHub.
        UpdateCheck.fetcher = StubUpdateFetcher(.failure(UpdateCheckError(message: "no network in tests")))
        UpdateCheck.opener = { XCTFail("opened \($0) unexpectedly") }
        for key in Self.keys { Settings.removeKey(key) }
    }

    override func tearDown() {
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for box in WinMessageBox.visibleBoxes { box.answer(box.boxButtons.escapeResult ?? .no) }
        for controller in controllers { controller.window?.close() }
        controllers = []
        UpdateCheck.fetcher = savedFetcher
        UpdateCheck.opener = savedOpener
        UpdateCheck.now = savedNow
        Settings.setPanelPath(savedPanelPath, 0)
        // The host's settings domain is the tests' own (AppHostTestCase), so the keys are removed.
        for key in Self.keys { Settings.removeKey(key) }
        super.tearDown()
    }

    // MARK: - semantic versions

    func testSemVerParsing() {
        XCTAssertEqual(SemVer("1.2.3"), SemVer(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemVer("v1.2.3"), SemVer(major: 1, minor: 2, patch: 3), "the tag form")
        XCTAssertEqual(SemVer("V2.0"), SemVer(major: 2, minor: 0, patch: 0), "a missing patch is 0")
        XCTAssertEqual(SemVer("3"), SemVer(major: 3, minor: 0, patch: 0))
        XCTAssertEqual(SemVer("1.0.0-beta.2+exp.sha.5114f85"), SemVer(major: 1, minor: 0, patch: 0, prerelease: ["beta", "2"]),
                       "build metadata is ignored")
        XCTAssertEqual(SemVer(" 1.0.0 \n")?.description, "1.0.0")
        XCTAssertEqual(SemVer("1.0.0-rc.1")?.description, "1.0.0-rc.1")
        for bad in ["", "v", "1.2.3.4", "1..2", "a.b.c", "1.2.x", "1.0.0-", "1.0.0-a..b", "-1.0.0", "1.٣.0"] {
            XCTAssertNil(SemVer(bad), "'\(bad)' is not a version")
        }
    }

    func testSemVerOrdering() throws {
        func v(_ s: String) throws -> SemVer { try XCTUnwrap(SemVer(s), s) }
        XCTAssertGreaterThan(try v("1.10.0"), try v("1.9.0"), "numeric, not lexical")
        XCTAssertGreaterThan(try v("1.0.10"), try v("1.0.9"))
        XCTAssertGreaterThan(try v("2.0.0"), try v("1.99.99"))
        XCTAssertGreaterThan(try v("1.0.1"), try v("1.0.0"))
        XCTAssertEqual(try v("v1.0.0"), try v("1.0.0"))
        XCTAssertFalse(try v("1.0.0") < v("1.0.0"))
        // semver.org section 11's own chain
        let chain = ["1.0.0-alpha", "1.0.0-alpha.1", "1.0.0-alpha.beta", "1.0.0-beta", "1.0.0-beta.2",
                     "1.0.0-beta.11", "1.0.0-rc.1", "1.0.0"]
        for (a, b) in zip(chain, chain.dropFirst()) {
            XCTAssertLessThan(try v(a), try v(b), "\(a) < \(b)")
        }
        XCTAssertLessThan(try v("1.1.0-beta.1"), try v("1.1.0"), "a pre-release is older than its release")
        XCTAssertGreaterThan(try v("1.1.0-beta.1"), try v("1.0.0"), "... and newer than the release before")
    }

    // MARK: - the release JSON

    func testReleaseJSONIsParsed() throws {
        let release = try ReleaseInfo.parse(Self.releaseJSON())
        XCTAssertEqual(release.tagName, "v1.2.0")
        XCTAssertEqual(release.name, "7-Zip 26.04 for macOS 1.2.0")
        XCTAssertEqual(release.htmlURL, URL(string: "https://github.com/yrambler2001/7zip-macos/releases/tag/v1.2.0"))
        XCTAssertFalse(release.draft)
        XCTAssertFalse(release.prerelease)
        XCTAssertEqual(release.version, SemVer("1.2.0"))
        XCTAssertEqual(release.upstreamVersion, "26.04", "the engine version from the release's name")
        XCTAssertEqual(release.notesExcerpt(), "What's new\n- Faster listing of large archives\n- Fixed the Finder menu on macOS 26")

        // null name / body (GitHub sends null for an empty one)
        let bare = #"{"tag_name":"v2.0.0","html_url":"https://example.com/r","name":null,"body":null,"draft":false,"prerelease":false}"#
        let parsed = try ReleaseInfo.parse(Data(bare.utf8))
        XCTAssertEqual(parsed.name, "")
        XCTAssertEqual(parsed.body, "")
        XCTAssertNil(parsed.upstreamVersion)

        XCTAssertThrowsError(try ReleaseInfo.parse(Data(#"{"message":"Not Found","documentation_url":"x"}"#.utf8)),
                             "a 404 document is not a release")
        XCTAssertThrowsError(try ReleaseInfo.parse(Data("<html>".utf8)))
    }

    func testNotesExcerptIsShort() {
        let body = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n" + String(repeating: "x", count: 300)
        let release = ReleaseInfo(tagName: "v1.0.1", body: "\n\n# Title\n\n" + body, htmlURL: UpdateCheck.releasesPageURL)
        let lines = release.notesExcerpt().components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Title")
        XCTAssertEqual(lines.count, 7, "six lines and an ellipsis")
        XCTAssertEqual(lines.last, "...")
        let long = ReleaseInfo(tagName: "v1", body: String(repeating: "y", count: 300), htmlURL: UpdateCheck.releasesPageURL)
        XCTAssertEqual(long.notesExcerpt().count, 120)
    }

    // MARK: - decisions

    func testEvaluate() throws {
        let current = try XCTUnwrap(SemVer("1.0.0"))
        let newer = try ReleaseInfo.parse(Self.releaseJSON(tag: "v1.2.0"))
        XCTAssertEqual(UpdateCheck.evaluate(newer, current: current), .newer(newer, SemVer(major: 1, minor: 2, patch: 0)))
        XCTAssertEqual(UpdateCheck.evaluate(try ReleaseInfo.parse(Self.releaseJSON(tag: "v1.0.0")), current: current), .upToDate)
        XCTAssertEqual(UpdateCheck.evaluate(try ReleaseInfo.parse(Self.releaseJSON(tag: "v0.9.0")), current: current), .upToDate,
                       "an older release is no update")
        XCTAssertEqual(UpdateCheck.evaluate(newer, current: try XCTUnwrap(SemVer("1.10.0"))), .upToDate, "1.10.0 > 1.2.0")
        for json in [Self.releaseJSON(tag: "v2.0.0", draft: true), Self.releaseJSON(tag: "v2.0.0", prerelease: true),
                     Self.releaseJSON(tag: "v2.0.0-beta.1"), Self.releaseJSON(tag: "nightly")] {
            guard case .failed = UpdateCheck.evaluate(try ReleaseInfo.parse(json), current: current) else {
                return XCTFail("drafts, pre-releases and non-version tags are ignored")
            }
        }
        guard case .failed = UpdateCheck.evaluate(.failure(URLError(.notConnectedToInternet)), current: current),
              case .failed = UpdateCheck.evaluate(.success(Data("{}".utf8)), current: current) else {
            return XCTFail("an error or a document that is not a release fails")
        }
    }

    func testStartupDecision() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func due(enabled: Bool = true, testSupport: Bool = false, commandMode: Bool = false, window: Bool = true,
                 last: Date? = nil) -> Bool {
            UpdateCheck.shouldCheckAtStartup(enabled: enabled, testSupport: testSupport, commandMode: commandMode,
                                             hasFileManagerWindow: window, lastCheck: last, now: now)
        }
        XCTAssertTrue(due(), "first launch checks")
        XCTAssertFalse(due(enabled: false), "Options > macOS > Check for updates at startup off")
        XCTAssertFalse(due(testSupport: true), "never under test support")
        XCTAssertFalse(due(commandMode: true), "never in 7zG mode (a Finder command)")
        XCTAssertFalse(due(window: false), "never without a File Manager window")
        XCTAssertFalse(due(last: now.addingTimeInterval(-60)), "checked a minute ago")
        XCTAssertFalse(due(last: now.addingTimeInterval(-23 * 3600)), "checked 23 h ago")
        XCTAssertTrue(due(last: now.addingTimeInterval(-24 * 3600)), "24 h ago")
        XCTAssertTrue(due(last: now.addingTimeInterval(-30 * 86400)))
        XCTAssertTrue(due(last: now.addingTimeInterval(3600)), "a clock set back does not block it for ever")
    }

    func testSkippedVersion() throws {
        let release = try ReleaseInfo.parse(Self.releaseJSON(tag: "v1.2.0"))
        let newer = UpdateCheck.Outcome.newer(release, try XCTUnwrap(release.version))
        XCTAssertTrue(UpdateCheck.shouldShow(newer, manual: false, skippedVersion: nil))
        XCTAssertFalse(UpdateCheck.shouldShow(newer, manual: false, skippedVersion: "1.2.0"), "skipped at startup")
        XCTAssertTrue(UpdateCheck.shouldShow(newer, manual: false, skippedVersion: "1.1.0"), "a later version than the skipped one")
        XCTAssertTrue(UpdateCheck.shouldShow(newer, manual: true, skippedVersion: "1.2.0"), "the menu ignores the skip")
        XCTAssertFalse(UpdateCheck.shouldShow(.upToDate, manual: false, skippedVersion: nil), "startup is silent when up to date")
        XCTAssertFalse(UpdateCheck.shouldShow(.failed("offline"), manual: false, skippedVersion: nil), "... and on errors")
        XCTAssertTrue(UpdateCheck.shouldShow(.upToDate, manual: true, skippedVersion: nil))
        XCTAssertTrue(UpdateCheck.shouldShow(.failed("offline"), manual: true, skippedVersion: nil))
    }

    /// This process is an XCTest host: it must never have started a check of its own, and a startup
    /// check asked for now does not reach the network.
    func testTestProcessesNeverCheckAtStartup() {
        XCTAssertTrue(UpdateCheck.isTestProcess)
        let stub = StubUpdateFetcher(.success(Self.releaseJSON()))
        UpdateCheck.fetcher = stub
        UpdateCheck.scheduleStartupCheck()
        UpdateCheck.startupCheckIfDue()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(stub.calls, 0)
        XCTAssertNil(Settings.updateLastCheck)
    }

    func testRequestHeaders() {
        let request = URLSessionUpdateFetcher().makeRequest()
        XCTAssertEqual(request.url, URL(string: "https://api.github.com/repos/yrambler2001/7zip-macos/releases/latest"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "7-Zip-for-macOS/\(PortVersion.port)")
        XCTAssertEqual(request.allHTTPHeaderFields?.count, 2, "nothing but the standard headers")
        XCTAssertLessThanOrEqual(request.timeoutInterval, 30)
    }

    // MARK: - versions

    func testPortVersion() {
        XCTAssertNotNil(SemVer(PortVersion.port), "CFBundleShortVersionString is the port's semver, not '\(PortVersion.port)'")
        XCTAssertEqual(PortVersion.upstream, "26.04")
        XCTAssertEqual(PortVersion.displayName(upstream: "26.03", port: "1.0.0"), "7-Zip 26.03 for macOS 1.0.0")
        XCTAssertTrue(AboutDialog.versionText.hasPrefix(PortVersion.displayName + " ("), AboutDialog.versionText)
    }

    // MARK: - UI

    func testHelpMenuHasCheckForUpdates() throws {
        let bar = MainMenu.build()
        let help = try XCTUnwrap(bar.items.last?.submenu, "the Help menu")
        let item = try XCTUnwrap(help.items.first { $0.action == #selector(AppDelegate.helpCheckForUpdates(_:)) },
                                 "Help > Check for Updates...")
        XCTAssertEqual(item.title, "Check for Updates...")
        XCTAssertEqual(item.accessibilityIdentifier(), "helpCheckForUpdates:")
        let titles = help.items.map(\.title)
        XCTAssertLessThan(try XCTUnwrap(titles.firstIndex(of: item.title)),
                          try XCTUnwrap(titles.firstIndex { $0.hasPrefix("About") }), "just above About")
        XCTAssertTrue(NSApp.delegate?.responds(to: #selector(AppDelegate.helpCheckForUpdates(_:))) ?? false,
                      "the app delegate answers it, with or without a window")
    }

    func testOptionsMacPageCheckbox() throws {
        let page = OptionsMacPage()
        page.loadView()
        page.pageDidLoad()
        let box = try XCTUnwrap(page.updatesBox)
        XCTAssertEqual(box.title, "Check for updates at startup")
        XCTAssertEqual(box.state, .on, "on by default")
        box.performClick(nil)
        XCTAssertTrue(page.applyPage())
        XCTAssertFalse(Settings.checkUpdates)
        XCTAssertTrue(Settings.hasKey(Settings.Key.checkUpdates), "persisted as FM.CheckUpdates")
        page.pageDidLoad()
        XCTAssertEqual(page.updatesBox.state, .off)
        XCTAssertNotEqual(page.updatesBox.frame.minY, page.gridBox.frame.minY, "a row of its own")
    }

    /// Help > Check for Updates... with a newer release: the box, its text and buttons, owned by
    /// the main window; Skip This Version records the version, Download opens the release page.
    func testNewerReleaseBox() throws {
        Settings.setPanelPath(NSTemporaryDirectory(), 0)
        let controller = MainWindowController()
        controllers.append(controller)
        controller.showWindow(nil)
        let main = try XCTUnwrap(MainWindows.primary?.window)
        UpdateCheck.fetcher = StubUpdateFetcher(.success(Self.releaseJSON(tag: "v9.1.0", name: "7-Zip 26.04 for macOS 9.1.0")))

        var shown: WinMessageBoxWindow?
        var answers: [WinMessageBox.Result] = [.button3, .button1, .button2]
        // Only the update box is scripted; anything else (a stale panel path's "Path not found" from an
        // earlier test's settings) goes to the default recorder.
        let recorder = recordAndDismissReports
        WinMessageBox.observers = [{ box in
            guard box.boxButtons.customTitles != nil else { return recorder(box) }
            shown = box
            let answer = answers.removeFirst()
            RunLoop.main.perform(inModes: [.modalPanel, .default, .common]) { box.answer(answer) }
        }]
        var opened: [URL] = []
        UpdateCheck.opener = { opened.append($0) }

        // 1. Skip This Version
        var outcome: UpdateCheck.Outcome?
        UpdateCheck.check(manual: true) { outcome = $0 }
        XCTAssertTrue(wait(for: "the box", timeout: 10) { shown?.result != nil })
        let box = try XCTUnwrap(shown)
        XCTAssertNotNil(outcome)
        XCTAssertTrue(box.message.hasPrefix("A new version is available: 7-Zip 26.04 for macOS 9.1.0 (you have \(PortVersion.port))."),
                      box.message)
        XCTAssertTrue(box.message.contains("- Faster listing of large archives"), "the notes excerpt")
        XCTAssertEqual(box.caption, "7-Zip")
        XCTAssertEqual(box.icon, .information)
        XCTAssertEqual(box.pushButtons.map(\.title), ["Download", "Later", "Skip This Version"])
        XCTAssertEqual(box.boxButtons.escapeResult, .button2, "Esc is Later")
        XCTAssertTrue(box.ownerWindow === main, "owned by the main window")
        for button in box.pushButtons {
            XCTAssertGreaterThanOrEqual(button.frame.width + 2, button.intrinsicContentSize.width, "'\(button.title)' fits")
        }
        _ = attach(box, "update-available")
        XCTAssertEqual(Settings.updateSkippedVersion, "9.1.0")
        XCTAssertTrue(opened.isEmpty)

        // 2. Download (the menu ignores the skipped version)
        shown = nil
        UpdateCheck.check(manual: true)
        XCTAssertTrue(wait(for: "the second box", timeout: 10) { shown?.result != nil })
        XCTAssertEqual(opened, [URL(string: "https://github.com/yrambler2001/7zip-macos/releases/tag/v9.1.0")!])

        // 3. Later: nothing
        shown = nil
        UpdateCheck.check(manual: true)
        XCTAssertTrue(wait(for: "the third box", timeout: 10) { shown?.result != nil })
        XCTAssertEqual(opened.count, 1)
        XCTAssertEqual(Settings.updateSkippedVersion, "9.1.0")

        // a startup outcome for the skipped version shows nothing
        shown = nil
        let release = try ReleaseInfo.parse(Self.releaseJSON(tag: "v9.1.0"))
        UpdateCheck.present(.newer(release, try XCTUnwrap(release.version)), manual: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertNil(shown)
    }

    func testUpToDateAndErrorBoxes() throws {
        Settings.setPanelPath(NSTemporaryDirectory(), 0)
        let controller = MainWindowController()
        controllers.append(controller)
        controller.showWindow(nil)
        recordedBoxes = []
        UpdateCheck.fetcher = StubUpdateFetcher(.success(Self.releaseJSON(tag: "v\(PortVersion.port)")))
        UpdateCheck.check(manual: true)
        XCTAssertTrue(wait(for: "the up-to-date box", timeout: 10) { recordedBoxes.count == 1 })
        XCTAssertEqual(recordedBoxes.last?.text, "You have the latest version (\(PortVersion.displayName)).")

        UpdateCheck.fetcher = StubUpdateFetcher(.failure(UpdateCheckError(message: "HTTP 403")))
        UpdateCheck.check(manual: true)
        XCTAssertTrue(wait(for: "the error box", timeout: 10) { recordedBoxes.count == 2 })
        XCTAssertEqual(recordedBoxes.last?.text, "Could not check for updates.\nHTTP 403")

        // the same outcomes at startup are silent
        UpdateCheck.present(.upToDate, manual: false)
        UpdateCheck.present(.failed("offline"), manual: false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(recordedBoxes.count, 2)
    }

    /// The custom-button box keeps the Windows geometry: right-aligned 15 px from the edge, 8 px
    /// apart, at least 75 px each.
    func testCustomButtonLayout() {
        let layout = WinMessageBoxLayout(text: "Hello", caption: "7-Zip", buttonCount: 3, hasIcon: true,
                                         customTitles: ["Download", "Later", "Skip This Version"])
        XCTAssertEqual(layout.buttonFrames.count, 3)
        XCTAssertEqual(layout.buttonFrames.last?.maxX ?? 0, layout.clientSize.width - 15, accuracy: 0.5)
        for (a, b) in zip(layout.buttonFrames, layout.buttonFrames.dropFirst()) {
            XCTAssertEqual(b.minX - a.maxX, WinMessageBoxLayout.buttonPitch - WinMessageBoxLayout.buttonSize.width, accuracy: 0.5)
        }
        XCTAssertTrue(layout.buttonFrames.allSatisfy { $0.width >= WinMessageBoxLayout.buttonSize.width })
        XCTAssertGreaterThan(layout.buttonFrames[2].width, layout.buttonFrames[1].width, "Skip This Version is wider")
        XCTAssertGreaterThanOrEqual(layout.buttonFrames.first?.minX ?? 0, 27)
    }
}
