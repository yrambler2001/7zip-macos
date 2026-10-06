// FinderHandoffTests.swift -- the finderfix unit tests: everything between a click in Finder and
// the `sevenzip://` URL the app receives, without Finder.
//
// The shipped defect (Mac/docs/reports/finderfix.md): the 7-Zip submenu showed in Finder but its
// items did nothing, and neither did the "Extract with 7-Zip" Quick Action.
//  * Finder copies an extension's menu and drops `representedObject`; the click arrived with
//    `representedObject == nil, tag == 0`. -> Items are numbered by tag and resolved again
//    (`FinderMenuBuilder`, `FinderMenuModel.resolveInvocation`).
//  * Finder hands a Quick Action an attachment registered only as the file's content type
//    (`public.zip-archive`), never `public.file-url`. -> `QuickActionInput` resolves any attachment.
//  * The URL was opened unaimed, so any registered copy of 7-Zip could answer. -> `ExtensionHandoff`
//    aims it at the containing app and falls back to the scheme only when that fails.
//  * Every failure used to be a silent `return`. -> `sevenzip:///error?code=` makes the app say so.
//
// Parity references: 03-shell-integration-inventory.md sections 1.4, 6.1, 6.4.

import AppKit
import os
import UniformTypeIdentifiers
import XCTest

final class FinderHandoffTests: XCTestCase {

    private let log = Logger(subsystem: ExtensionHandoff.subsystem, category: "tests")

    private func archiveSelection() -> FinderSelection {
        FinderSelection(paths: ["/Users/me/Downloads/probe.zip"], directoryFlags: [false])
    }

    private func mixedSelection() -> FinderSelection {
        FinderSelection(paths: ["/Users/me/a b.txt", "/Users/me/dir/"], directoryFlags: [false, true])
    }

    /// The menu Finder receives, every item copied the way Finder copies it: title, tag and
    /// action survive; `representedObject` and `target` do not.
    private func clicks(for selection: FinderSelection, settings: IntegrationSettings = IntegrationSettings())
        -> [(tag: Int, title: String)] {
        let nodes = FinderMenuModel.build(selection: selection, settings: settings)
        let menu = FinderMenuBuilder.menu(for: nodes, action: #selector(NSObject.description), image: nil)
        return FinderMenuBuilder.commandItems(of: menu).map { item in
            let copy = NSMenuItem(title: item.title, action: item.action, keyEquivalent: "")
            copy.tag = item.tag
            XCTAssertNil(copy.representedObject)
            return (copy.tag, copy.title)
        }
    }

    // MARK: - Finder Sync: the click resolves to the command that was shown

    func testEveryMenuItemResolvesToItsOwnCommandFromTagAndTitleAlone() throws {
        for selection in [archiveSelection(), mixedSelection()] {
            let nodes = FinderMenuModel.build(selection: selection, settings: IntegrationSettings())
            let commands = FinderMenuModel.flattenCommands(nodes)
            let delivered = clicks(for: selection)
            XCTAssertEqual(delivered.count, commands.count)
            XCTAssertFalse(commands.isEmpty)
            for (index, click) in delivered.enumerated() {
                XCTAssertNotEqual(click.tag, 0, "an unnumbered item cannot be resolved")
                let resolved = FinderMenuModel.resolveInvocation(tag: click.tag, title: click.title,
                                                                 nodes: nodes)
                XCTAssertEqual(resolved, commands[index], "item \(index) \(click.title)")
            }
        }
    }

    /// The two reported items, end to end: the argv the app receives is the 7zG one.
    func testOpenArchiveAndAddToArchiveBuildTheirCommandLines() throws {
        let selection = archiveSelection()
        let nodes = FinderMenuModel.build(selection: selection, settings: IntegrationSettings())
        let delivered = clicks(for: selection)

        let open = try XCTUnwrap(delivered.first { $0.title == "Open archive" })
        let openCommand = try XCTUnwrap(FinderMenuModel.resolveInvocation(tag: open.tag, title: open.title, nodes: nodes))
        XCTAssertEqual(openCommand.argv(for: selection.paths).argv, ["/Users/me/Downloads/probe.zip"])

        let add = try XCTUnwrap(delivered.first { $0.title == "Add to archive..." })
        let addCommand = try XCTUnwrap(FinderMenuModel.resolveInvocation(tag: add.tag, title: add.title, nodes: nodes))
        let argv = addCommand.argv(for: selection.paths).argv
        XCTAssertEqual(argv.first, "a")
        XCTAssertTrue(argv.contains("-iw-!/Users/me/Downloads/probe.zip"))
        XCTAssertTrue(argv.contains("-ad"))

        // And the URL round trip the app parses.
        let url = try XCTUnwrap(CommandURL.url(argv: argv))
        guard case .run(let decoded, let temporary) = try CommandURL.parse(url) else {
            return XCTFail("not a run URL")
        }
        XCTAssertEqual(decoded, argv)
        XCTAssertEqual(temporary, [])
    }

    /// What the old code did with Finder's copy: no `representedObject`, so nothing. Tag 0 (an
    /// item from an extension that did not number its items) must not silently pick a command
    /// when the title is ambiguous, and must still work when the title is unique.
    func testTagZeroFallsBackToAUniqueTitleOnly() {
        let nodes = FinderMenuModel.build(selection: archiveSelection(), settings: IntegrationSettings())
        XCTAssertEqual(FinderMenuModel.resolveInvocation(tag: 0, title: "Add to archive...", nodes: nodes)?.verb,
                       "SevenZipCompress")
        // A1 "Open archive" and the first child of A2 run the same command line: either will do.
        XCTAssertEqual(FinderMenuModel.resolveInvocation(tag: 0, title: "Open archive", nodes: nodes)?.verb,
                       "SevenZipOpen")
        XCTAssertNil(FinderMenuModel.resolveInvocation(tag: 0, title: "No such item", nodes: nodes))
    }

    /// The settings changed between showing the menu and the click (an item was switched off, so
    /// the numbering moved): the title wins over a stale tag.
    func testAStaleTagIsCorrectedByTheTitle() throws {
        var shown = IntegrationSettings()
        shown.flags = .all
        let selection = archiveSelection()
        let shownNodes = FinderMenuModel.build(selection: selection, settings: shown)
        let click = try XCTUnwrap(clicks(for: selection, settings: shown).first { $0.title == "Add to archive..." })

        var now = shown
        now.flags.remove(.extractFiles)
        let currentNodes = FinderMenuModel.build(selection: selection, settings: now)
        XCTAssertNotEqual(FinderMenuModel.flattenCommands(shownNodes).count,
                          FinderMenuModel.flattenCommands(currentNodes).count)
        XCTAssertEqual(FinderMenuModel.resolveInvocation(tag: click.tag, title: click.title,
                                                         nodes: currentNodes)?.verb, "SevenZipCompress")
    }

    // MARK: - Error reporting from an extension

    func testErrorURLRoundTripsEveryFailureAndRejectsOtherCodes() throws {
        for failure in CommandURL.ExtensionFailure.allCases {
            let url = try XCTUnwrap(CommandURL.errorURL(failure))
            XCTAssertEqual(url.path, "/error")
            XCTAssertEqual(try CommandURL.parse(url), .extensionFailure(failure))
            XCTAssertFalse(failure.message.isEmpty)
        }
        // A URL cannot make the app display text of its choosing.
        let forged = try XCTUnwrap(URL(string: "sevenzip:///error?code=Your%20Mac%20is%20infected"))
        XCTAssertThrowsError(try CommandURL.parse(forged))
        XCTAssertThrowsError(try CommandURL.parse(try XCTUnwrap(URL(string: "sevenzip:///error"))))
    }

    // MARK: - ExtensionHandoff: aimed at the containing app, scheme as the fallback

    private var savedAimed: ExtensionHandoff.AimedOpener!
    private var savedScheme: ExtensionHandoff.SchemeOpener!

    override func setUp() {
        super.setUp()
        savedAimed = ExtensionHandoff.aimedOpener
        savedScheme = ExtensionHandoff.schemeOpener
    }

    override func tearDown() {
        ExtensionHandoff.aimedOpener = savedAimed
        ExtensionHandoff.schemeOpener = savedScheme
        super.tearDown()
    }

    private func send(_ url: URL, to app: URL) -> ExtensionHandoff.Outcome? {
        let done = expectation(description: "hand-off answered")
        var outcome: ExtensionHandoff.Outcome?
        ExtensionHandoff.send(url, to: app, log: log) { outcome = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return outcome
    }

    func testHandoffIsAimedAtTheContainingAppFirst() throws {
        let url = try XCTUnwrap(CommandURL.url(argv: ["/tmp/a.zip"]))
        let app = URL(fileURLWithPath: "/Applications/7-Zip.app")
        var aimedAt: [URL] = []
        var schemeCalls = 0
        ExtensionHandoff.aimedOpener = { sent, target, completion in
            XCTAssertEqual(sent, url)
            aimedAt.append(target)
            completion(nil)
        }
        ExtensionHandoff.schemeOpener = { _ in schemeCalls += 1; return true }
        XCTAssertEqual(send(url, to: app), .aimed)
        XCTAssertEqual(aimedAt, [app])
        XCTAssertEqual(schemeCalls, 0, "a delivered aimed open must not also go to the scheme handler")
    }

    func testHandoffFallsBackToTheSchemeAndReportsATotalFailure() throws {
        let url = try XCTUnwrap(CommandURL.url(argv: ["/tmp/a.zip"]))
        let app = URL(fileURLWithPath: "/Applications/7-Zip.app")
        ExtensionHandoff.aimedOpener = { _, _, completion in
            completion(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError))
        }
        ExtensionHandoff.schemeOpener = { _ in true }
        XCTAssertEqual(send(url, to: app), .scheme)
        ExtensionHandoff.schemeOpener = { _ in false }
        XCTAssertEqual(send(url, to: app), .failed)
    }

    func testContainingAppIsFoundFromAnAppexPath() {
        // `SevenZipBundle.containingAppURL` walks up from the running bundle; in the test bundle it
        // must at least never return a path inside `Contents/PlugIns`.
        let url = SevenZipBundle.containingAppURL
        XCTAssertFalse(url.path.contains("/PlugIns/"))
        XCTAssertNotEqual(url.pathExtension, "appex")
    }

    // MARK: - Quick Action input: Finder gives the content type, not public.file-url

    private func resolve(_ providers: [NSItemProvider]) -> [URL] {
        let done = expectation(description: "resolved")
        var out: [URL] = []
        QuickActionInput.fileURLs(from: providers) { out = $0; done.fulfill() }
        wait(for: [done], timeout: 10)
        return out
    }

    private func makeZip() throws -> URL {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("finderfix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        let url = URL(fileURLWithPath: dir).appendingPathComponent("probe.zip")
        try Data("PK\u{5}\u{6}".utf8 + [UInt8](repeating: 0, count: 18)).write(to: url)
        return url
    }

    /// Finder's shape on macOS 26, as logged by the extension: one attachment whose only registered
    /// type is the file's own (`public.zip-archive`), openable in place.
    func testAnAttachmentWithOnlyTheContentTypeResolvesToTheOriginalFile() throws {
        let zip = try makeZip()
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.zip.identifier,
                                            fileOptions: [.openInPlace], visibility: .all) { completion in
            completion(zip, true, nil)
            return nil
        }
        XCTAssertEqual(provider.registeredTypeIdentifiers, [UTType.zip.identifier])
        XCTAssertFalse(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier))
        XCTAssertEqual(resolve([provider]).map(\.standardizedFileURL.path), [zip.standardizedFileURL.path])
    }

    /// A host that answers `loadItem` of the content type with the URL (older systems, other hosts).
    func testAnItemThatIsAFileURLIsAccepted() throws {
        let zip = try makeZip()
        let provider = NSItemProvider()
        provider.registerItem(forTypeIdentifier: UTType.zip.identifier) { completion, _, _ in
            completion?(zip as NSURL, nil)
        }
        XCTAssertEqual(resolve([provider]).map(\.path), [zip.path])
    }

    /// The case the original code handled, kept working.
    func testAFileURLAttachmentStillWorks() throws {
        let zip = try makeZip()
        let provider = NSItemProvider(item: zip as NSURL, typeIdentifier: UTType.fileURL.identifier)
        XCTAssertEqual(resolve([provider]).map(\.path), [zip.path])
    }

    /// Order is kept, and an attachment with nothing usable is dropped rather than failing all.
    func testOrderIsKeptAndUnusableAttachmentsAreDropped() throws {
        let first = try makeZip()
        let second = try makeZip()
        let text = NSItemProvider(item: "hello" as NSString, typeIdentifier: UTType.plainText.identifier)
        let a = NSItemProvider(item: first as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let b = NSItemProvider(item: second as NSURL, typeIdentifier: UTType.fileURL.identifier)
        XCTAssertEqual(resolve([a, text, b]).map(\.path), [first.path, second.path])
        XCTAssertEqual(resolve([]), [])
    }

    // MARK: - Info.plist: the Compress Quick Action is offered for any item

    func testCompressQuickActionActivatesForAnyFinderItem() throws {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("QuickAction/Compress/Info.plist")
        let dict = try XCTUnwrap(NSDictionary(contentsOf: plist) as? [String: Any])
        let attributes = try XCTUnwrap((dict["NSExtension"] as? [String: Any])?["NSExtensionAttributes"] as? [String: Any])
        // A predicate string, not the `NSExtensionActivationSupportsFileWithMaxCount` dictionary:
        // Finder's attachments carry the content type only, so the rule tests UTI conformance.
        let rule = try XCTUnwrap(attributes["NSExtensionActivationRule"] as? String)
        XCTAssertTrue(rule.contains("UTI-CONFORMS-TO \"public.item\""))
        let predicate = NSPredicate(format: rule)
        let txt = ["extensionItems": [["attachments": [["registeredTypeIdentifiers": ["public.plain-text"]]]]]]
        let folder = ["extensionItems": [["attachments": [["registeredTypeIdentifiers": ["public.folder"]]]]]]
        let none = ["extensionItems": [["attachments": [[String: Any]]()]]]
        XCTAssertTrue(predicate.evaluate(with: txt))
        XCTAssertTrue(predicate.evaluate(with: folder))
        XCTAssertFalse(predicate.evaluate(with: none))
    }
}
