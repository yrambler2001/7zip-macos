// Sec113Tests.swift -- command URLs through the real handler (`application(_:open:)`), in the
// running app (sec113, `URLCommandPolicy.swift`, `URLCommandTokenStore.swift`).
//
// A forged URL -- no secret, a wrong one, or the right one with a command the extensions never
// build -- must run nothing and put up the one refusal box, in 7zG mode (no file-manager owner);
// `x-7zip:` the same. The extensions' own shapes, with the secret, still run.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class Sec113Tests: AppHostTestCase {

    override var screenshotPrefix: String { "sec113" }

    private var delegate: AppDelegate { NSApp.delegate as! AppDelegate }
    private var scratch = ""
    private var before: [MainWindowController] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        before = MainWindows.controllers
        GMode.resetForTesting()
        GMode.changesActivation = false
        GMode.terminate = {}
        scratch = (NSTemporaryDirectory() as NSString).appendingPathComponent("sec113-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: scratch + "/out", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: TestPaths.fixture("test.7z"), toPath: scratch + "/test.7z")
        try "keep me\n".write(toFile: scratch + "/one.txt", atomically: true, encoding: .utf8)
    }

    override func tearDown() {
        for controller in MainWindows.controllers where !before.contains(where: { $0 === controller }) {
            controller.window?.close()
        }
        GMode.resetForTesting()
        GMode.changesActivation = true
        try? FileManager.default.removeItem(atPath: scratch)
        super.tearDown()
    }

    private var token: String { URLCommandTokenStore.ensure() ?? "" }

    private func contents(_ dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted()
    }

    /// Opens `url` the way AppKit delivers it and asserts the refusal box: 7-Zip's error box, no
    /// file-manager owner, the refusal text.
    private func assertRefused(_ url: URL, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let windowsBefore = MainWindows.controllers.count
        var inspected = false
        XCTAssertTrue(ModalProbe.present({ self.delegate.application(NSApp, open: [url]) }) { window in
            inspected = true
            let box = window as? WinMessageBoxWindow
            XCTAssertNotNil(box, "\(what): not a message box: \(window)", file: file, line: line)
            XCTAssertEqual(box?.message, URLCommandPolicy.refusalMessage, what, file: file, line: line)
            XCTAssertNil(box?.ownerWindow, "\(what): the box has an owner", file: file, line: line)
            XCTAssertTrue(GMode.isActive, "\(what): not in 7zG mode", file: file, line: line)
        }, "\(what): the probe timed out", file: file, line: line)
        XCTAssertTrue(inspected, "\(what): no refusal box", file: file, line: line)
        XCTAssertEqual(MainWindows.controllers.count, windowsBefore, "\(what): a window opened", file: file, line: line)
    }

    /// `x -o<out>/ -y -an -aiw-!<archive>`: what a web page would send.
    private func forgedExtract() -> [String] {
        ["x", "-o" + scratch + "/out/", "-y", "-an", "-aiw-!" + scratch + "/test.7z"]
    }

    // MARK: - forged

    func testRunURLWithoutTokenRunsNothing() throws {
        assertRefused(try XCTUnwrap(CommandURL.url(argv: forgedExtract())), "no token")
        XCTAssertEqual(contents(scratch + "/out"), [], "a refused URL extracted something")
        // Even the extensions' own shape needs the secret.
        let here = ["x", "-o" + scratch + "/", "-an", "-aiw-!" + scratch + "/test.7z"]
        assertRefused(try XCTUnwrap(CommandURL.url(argv: here)), "legitimate shape, no token")
        XCTAssertEqual(contents(scratch), ["one.txt", "out", "test.7z"])
        // Opening an archive in the file manager too: it makes 7-Zip parse a file a page chose.
        assertRefused(try XCTUnwrap(CommandURL.url(argv: [scratch + "/test.7z"])), "open, no token")
    }

    func testRunURLWithWrongTokenRunsNothing() throws {
        let wrong = String(repeating: "ab", count: 32)
        XCTAssertNotEqual(wrong, token)
        assertRefused(try XCTUnwrap(CommandURL.url(argv: forgedExtract(), token: wrong)), "wrong token")
        XCTAssertEqual(contents(scratch + "/out"), [])
    }

    func testAlternateSchemeIsCheckedTheSameWay() throws {
        let url = try XCTUnwrap(CommandURL.url(argv: forgedExtract()))
        let alternate = try XCTUnwrap(URL(string: url.absoluteString.replacingOccurrences(of: "sevenzip:", with: "x-7zip:")))
        XCTAssertEqual(alternate.scheme, "x-7zip")
        assertRefused(alternate, "x-7zip, no token")
        let withToken = try XCTUnwrap(URL(string: try XCTUnwrap(CommandURL.url(argv: forgedExtract(), token: token))
            .absoluteString.replacingOccurrences(of: "sevenzip:", with: "x-7zip:")))
        assertRefused(withToken, "x-7zip, token, forbidden shape")
        XCTAssertEqual(contents(scratch + "/out"), [])
    }

    func testValidTokenWithForbiddenCommandRunsNothing() throws {
        // -sdel would delete one.txt after packing it; -p would encrypt it with a chosen password.
        let item = "-iw-!" + scratch + "/one.txt"
        for argv in [["a", item, "-t7z", "-sae", "-sdel", "--", scratch + "/one.7z"],
                     ["a", item, "-t7z", "-psecret", "-sae", "--", scratch + "/one.7z"],
                     ["d", item, "--", scratch + "/test.7z"],
                     ["x", "-o" + NSHomeDirectory() + "/Library/LaunchAgents/", "-an", "-aiw-!" + scratch + "/test.7z"]] {
            assertRefused(try XCTUnwrap(CommandURL.url(argv: argv, token: token)), argv.joined(separator: " "))
        }
        XCTAssertEqual(contents(scratch), ["one.txt", "out", "test.7z"], "a refused command changed the folder")
        XCTAssertEqual(try String(contentsOfFile: scratch + "/one.txt", encoding: .utf8), "keep me\n")
    }

    // MARK: - legitimate

    func testExtensionShapeWithTokenRuns() throws {
        // B7 "Add to one.7z": no dialog, so it runs to the end here.
        let argv = ["a", "-iw-!" + scratch + "/one.txt", "-t7z", "-sae", "--", scratch + "/one.7z"]
        delegate.application(NSApp, open: [try XCTUnwrap(CommandURL.url(argv: argv, token: token))])
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch + "/one.7z"), "the command did not run")
        XCTAssertTrue(recordedBoxes.isEmpty, "unexpected box: \(recordedBoxes.map(\.text))")
    }

    // MARK: - the secret's lifetime

    func testSecretIsCreatedAndAResetDropsIt() {
        let first = token
        XCTAssertTrue(URLCommandToken.isWellFormed(first))
        XCTAssertEqual(URLCommandTokenStore.ensure(), first, "the secret does not rotate by itself")
        XCTAssertTrue(URLCommandTokenStore.accepts(first))
        XCTAssertFalse(URLCommandTokenStore.accepts(nil))
        // Reset All Settings keeps only its preserved keys, so the relaunched app makes a new one.
        XCTAssertFalse(SettingsReset.isPreserved(URLCommandToken.settingsKey))
        XCTAssertNil(SettingsReset.contentsAfterReset([URLCommandToken.settingsKey: first])[URLCommandToken.settingsKey])
        Settings.setString(nil, URLCommandToken.settingsKey)
        let second = URLCommandTokenStore.ensure()
        XCTAssertNotNil(second)
        XCTAssertNotEqual(second, first)
        XCTAssertFalse(URLCommandTokenStore.accepts(first), "the old secret is refused after a reset")
        // The snapshot the extensions read carries the new one.
        XCTAssertEqual(FinderSettingsBridge.snapshotDictionary()[URLCommandToken.settingsKey] as? String, second)
    }

    // MARK: - the update checker's Download button

    func testDownloadOpensOnlyThisRepositorysReleasePages() throws {
        func release(_ s: String) throws -> ReleaseInfo { ReleaseInfo(tagName: "v9.9.9", htmlURL: try XCTUnwrap(URL(string: s))) }
        let good = "https://github.com/yrambler2001/7zip-macos/releases/tag/v9.9.9"
        XCTAssertEqual(UpdateCheck.downloadURL(for: try release(good)).absoluteString, good)
        for bad in ["http://github.com/yrambler2001/7zip-macos/releases/tag/v9.9.9",
                    "https://evil.example/yrambler2001/7zip-macos/releases/tag/v9.9.9",
                    "https://github.com.evil.example/yrambler2001/7zip-macos/releases/tag/v1",
                    "https://user@github.com/yrambler2001/7zip-macos/releases/tag/v1",
                    "https://github.com:444/yrambler2001/7zip-macos/releases/tag/v1",
                    "https://github.com/someone/7zip-macos/releases/tag/v1",
                    "https://github.com/yrambler2001/7zip-macos/releases/../../evil",
                    "https://github.com/yrambler2001/7zip-macos/releases/%2e%2e/x",
                    "https://github.com/yrambler2001/7zip-macos/releasesX/tag/v1",
                    "file:///Applications/Calculator.app",
                    "x-7zip:///run?argv=W10"] {
            XCTAssertEqual(UpdateCheck.downloadURL(for: try release(bad)), UpdateCheck.releasesPageURL, bad)
        }
    }
}
