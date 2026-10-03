// OpsGapsTests.swift -- the operation-level gaps of `Mac/docs/parity.md` closed by `mac/opsgaps`,
// asserted in the app's own process (`SevenZipAppTests`, see AppHostTestCase):
//
//   * bundled HTML help: every Windows kHelpTopic resolves to a page inside the app bundle, anchors
//     kept, and the Help buttons of Options (each page), Extract and Compress open their topic
//     (01 §9 #17, `ShowHelpWindow`);
//   * the Dock-tile progress bar (the `ITaskbarList3` taskbar progress, 01b §4.17): combined over
//     several operations, coloured like TBPFLAG, gone after finish / cancel;
//   * the failure text of a failed operation is `CProgressThreadVirt::Process` + `HResultToMessage`
//     (lang 3000 for E_OUTOFMEMORY, "Error #N", silence for E_ABORT);
//   * the checksum list exposes its rows (requests.md, `finder` -> `tools`);
//   * the panel's Test recognises checksum files (`t -thash`, 03 §2.6);
//   * the `test` URL host is refused without a modal box (requests.md, `fastui` -> `resetcmd`).
//
// No browser is launched: `Help.opener` captures the URL instead.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class OpsGapsTests: AppHostTestCase {

    override var screenshotPrefix: String { "opsgaps" }

    private var opened: [URL] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        opened = []
        Help.opener = { [weak self] url in self?.opened.append(url) }
    }

    override func tearDown() {
        Help.opener = nil
        super.tearDown()
    }

    // MARK: - help

    /// Every kHelpTopic in the Windows sources, with where it comes from.
    private let windowsTopics: [(String, String)] = [
        (Help.start, "AboutDialog.cpp:25"),
        (Help.contents, "kFMHelpTopic, MyLoadMenu.cpp:38"),
        (Help.benchmark, "BenchmarkDialog.cpp:37"),
        (Help.tempFiles, "BrowseDialog2.cpp:979"),
        (Help.add, "CompressDialog.cpp:1254"),
        (Help.addOptions, "CompressDialog.cpp:1255"),
        (Help.extract, "ExtractDialog.cpp:414"),
        (Help.optionsSystem, "SystemPage.cpp:39"),
        (Help.optionsMenu, "MenuPage.cpp:41"),
        (Help.optionsFolders, "FoldersPage.cpp"),
        (Help.optionsEditor, "EditPage.cpp:28"),
        (Help.optionsSettings, "SettingsPage.cpp:45"),
        (Help.optionsLanguage, "LangPage.cpp:28"),
    ]

    func testEveryWindowsHelpTopicIsBundled() throws {
        for (topic, source) in windowsTopics {
            let url = try XCTUnwrap(Help.bundledURL(for: topic), "\(topic) (\(source)) is not in the bundle")
            XCTAssertTrue(url.isFileURL)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.path)
            XCTAssertTrue(url.path.contains("/Contents/Resources/Help/"), url.path)
            let anchor = topic.components(separatedBy: "#").dropFirst().first
            XCTAssertEqual(url.fragment, anchor, "the kHelpTopic anchor must survive: \(topic)")
            // The page is real HTML from 7-zip.chm, not a placeholder.
            let html = try String(contentsOf: url, encoding: .isoLatin1)
            XCTAssertTrue(html.localizedCaseInsensitiveContains("<html"), topic)
        }
        // Lower-case `fm/` on disk, `FM/` in half the Windows sources: CHM paths are case-blind.
        XCTAssertEqual(Help.bundledURL(for: "FM/index.htm")?.lastPathComponent, "index.htm")
        XCTAssertNil(Help.bundledURL(for: "../Info.plist"))
        XCTAssertNil(Help.bundledURL(for: "fm/no-such-page.htm"))
    }

    func testHelpContentsOpensTheBundledFileManagerPage() throws {
        Help.show(topic: Help.contents)
        let url = try XCTUnwrap(opened.last)
        XCTAssertTrue(url.isFileURL)
        XCTAssertTrue(url.path.hasSuffix("Help/fm/index.htm"), url.path)
    }

    func testOptionsHelpButtonOpensTheTopicOfThePageOnScreen() throws {
        let controller = OptionsWindowController.shared
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in })
        defer { ModalProbe.close(window) }
        let tabs = try XCTUnwrap(firstView(of: NSTabView.self, in: window.contentView))
        let help = try XCTUnwrap(button(titled: Lang.text(409, "Help"), in: window.contentView))
        // OptionsDialog.cpp:13-20 order, plus the macOS-only Plugins page.
        let expected = ["#system", "#sevenZip", "#folders", "#editor", "#settings", "#language", ""]
        XCTAssertEqual(tabs.numberOfTabViewItems, expected.count)
        for index in 0..<tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at: index)
            opened = []
            help.performClick(nil)
            let url = try XCTUnwrap(opened.last, "page \(index): Help opened nothing (it used to beep)")
            XCTAssertTrue(url.isFileURL, "page \(index): \(url)")
            if expected[index].isEmpty {
                XCTAssertTrue(url.path.hasSuffix("fm/plugins/index.htm"), url.path)
            } else {
                XCTAssertTrue(url.path.hasSuffix("fm/options.htm"), url.path)
                XCTAssertEqual("#" + (url.fragment ?? ""), expected[index])
            }
        }
    }

    func testExtractAndCompressHelpButtonsOpenTheirTopics() throws {
        var extractOptions = ExtractDialog.Options()
        extractOptions.directoryPath = TestPaths.fixtures + "/"
        extractOptions.archivePath = TestPaths.fixture("test.7z")
        XCTAssertTrue(ModalProbe.present({ _ = ExtractDialog.run(extractOptions) }) { window in
            self.button(titled: Lang.text(409, "Help"), in: window.contentView)?.performClick(nil)
        })
        XCTAssertEqual(opened.last?.path.hasSuffix("fm/plugins/7-zip/extract.htm"), true, "\(opened)")

        var input = CompressDialogInput()
        input.directoryPrefix = TestPaths.fixtures + "/"
        input.archiveBaseName = "Archive"
        input.itemPaths = [TestPaths.fixture("test.7z")]
        opened = []
        XCTAssertTrue(ModalProbe.present(timeout: 60, { _ = CompressDialogController.run(input) }) { window in
            self.button(titled: Lang.text(409, "Help"), in: window.contentView)?.performClick(nil)
        })
        let url = try XCTUnwrap(opened.last)
        XCTAssertTrue(url.path.hasSuffix("fm/plugins/7-zip/add.htm"), url.path)
        XCTAssertNil(url.fragment)
    }

    // MARK: - Dock tile

    func testDockTileCombinesSeveralOperationsAndClears() {
        let tile = ProgressDockTile.shared
        XCTAssertNil(tile.displayed, "no operation is running")
        let a = NSObject(), b = NSObject()
        tile.begin(a)
        tile.begin(b)
        XCTAssertEqual(tile.activeCount, 2)
        XCTAssertNotNil(tile.displayed)
        XCTAssertNil(tile.displayed?.fraction ?? nil, "no totals yet: an empty bar")

        tile.update(a, .init(completed: 50, total: 100))
        tile.update(b, .init(completed: 0, total: 300))
        XCTAssertEqual(tile.displayed?.fraction ?? -1, 50.0 / 400.0, accuracy: 0.0001)
        XCTAssertEqual(tile.displayed?.state, .normal)

        tile.update(a, .init(completed: 100, total: 100, paused: true))
        XCTAssertEqual(tile.displayed?.state, .normal, "paused only when every operation is")
        tile.update(b, .init(completed: 100, total: 300, paused: true))
        XCTAssertEqual(tile.displayed?.state, .paused)       // TBPF_PAUSED
        tile.update(b, .init(completed: 100, total: 300, hasErrors: true))
        XCTAssertEqual(tile.displayed?.state, .error)        // TBPF_ERROR

        tile.end(a)
        XCTAssertEqual(tile.displayed?.fraction ?? -1, 1.0 / 3.0, accuracy: 0.0001)
        tile.end(b)
        tile.end(b)                                          // idempotent
        XCTAssertNil(tile.displayed, "TBPF_NOPROGRESS after the last operation")
        XCTAssertEqual(tile.activeCount, 0)
        XCTAssertNil(NSApp.dockTile.contentView, "the plain icon is back")
    }

    /// The tile as the Dock draws it, in the three TBPFLAG colours (screencapture is denied here, so
    /// the view is rendered in process): `Mac/docs/reports/screenshots/opsgaps-dock-tile.png`.
    func testDockTileRendering() {
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: 3 * 128, height: 128))
        for (i, (fraction, state)) in [(0.35, ProgressDockTile.State.normal), (0.6, .paused), (0.8, .error)].enumerated() {
            let view = ProgressDockTileView(frame: NSRect(x: CGFloat(i) * 128, y: 0, width: 128, height: 128))
            view.fraction = fraction
            view.state = state
            strip.addSubview(view)
        }
        let window = NSWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = strip
        defer { window.close() }
        XCTAssertNotNil(attach(window, "dock-tile"))
    }

    func testDockTileFollowsARealOperationAndClearsOnCancel() {
        var samples: [Double?] = []
        var showing = false
        var cancelled = false
        let sampler = Timer(timeInterval: 0.05, repeats: true) { _ in
            if let shown = ProgressDockTile.shared.displayed {
                showing = true
                samples.append(shown.fraction)
                if let f = shown.fraction, f >= 0.25, !cancelled {
                    cancelled = true
                    OperationRunner.cancelActiveOperations()
                }
            }
        }
        RunLoop.main.add(sampler, forMode: .common)
        defer { sampler.invalidate() }

        var options = OperationRunner.Options(title: "Testing")
        options.waitMode = false
        let result = OperationRunner.run(options) { runner -> Int in
            runner.progressSetTotal(1000)
            for step in 1...200 {
                if runner.progressCheckBreak() {
                    throw NSError(domain: SZErrorDomain, code: SZError.Code.cancelled.rawValue)
                }
                runner.progressSetCompleted(UInt64(step * 5))
                Thread.sleep(forTimeInterval: 0.02)
            }
            return 0
        }
        if case .success = result { XCTFail("the operation should have been cancelled") }
        XCTAssertTrue(showing, "the Dock tile never showed the operation")
        XCTAssertTrue(samples.contains { ($0 ?? 0) > 0 }, "the Dock tile never advanced: \(samples)")
        XCTAssertNil(ProgressDockTile.shared.displayed, "a cancelled operation must clear the tile")
        XCTAssertNil(NSApp.dockTile.contentView)
    }

    // MARK: - failure text

    func testFailureMessageIsHResultToMessage() {
        let memory = NSError(domain: SZErrorDomain, code: SZError.Code.outOfMemory.rawValue,
                             userInfo: [NSLocalizedDescriptionKey: "Cannot allocate memory"])
        XCTAssertEqual(OperationRunner.failureMessage(for: memory),
                       Lang.text(3000, "The system cannot allocate the required amount of memory"))
        let memoryByHResult = NSError(domain: SZErrorDomain, code: SZError.Code.engine.rawValue,
                                      userInfo: [NSLocalizedDescriptionKey: "x", "SZErrorHRESULT": NSNumber(value: UInt32(0x8007_000E))])
        XCTAssertEqual(OperationRunner.failureMessage(for: memoryByHResult),
                       Lang.text(3000, "The system cannot allocate the required amount of memory"))

        let cancelled = NSError(domain: SZErrorDomain, code: SZError.Code.cancelled.rawValue)
        XCTAssertNil(OperationRunner.failureMessage(for: cancelled), "E_ABORT is silent")

        let intThrow = NSError(domain: SZErrorDomain, code: SZError.Code.engine.rawValue,
                               userInfo: [NSLocalizedDescriptionKey: "Internal Error #7"])
        XCTAssertEqual(OperationRunner.failureMessage(for: intThrow), "Error #7")   // catch (int v)
        let unknown = NSError(domain: SZErrorDomain, code: SZError.Code.engine.rawValue,
                              userInfo: [NSLocalizedDescriptionKey: "Unknown error"])
        XCTAssertEqual(OperationRunner.failureMessage(for: unknown), "Error")      // catch (...)

        let wrongPassword = NSError(domain: SZErrorDomain, code: SZError.Code.wrongPassword.rawValue,
                                    userInfo: [NSLocalizedDescriptionKey: Lang.text(3729, "Wrong password")])
        XCTAssertEqual(OperationRunner.failureMessage(for: wrongPassword), Lang.text(3729, "Wrong password"))
    }

    /// The per-item texts are the lang-file strings SetExtractErrorMessage builds; a CRC failure in
    /// a checksum file run through the panel's Test path shows "CRC Failed" (3723-family).
    func testChecksumFilesAreRecognisedForTheTestButton() throws {
        XCTAssertTrue(ExtractCommands.areChecksumFiles(["/x/a.sha256", "/x/B.MD5"]))
        XCTAssertFalse(ExtractCommands.areChecksumFiles(["/x/a.sha256", "/x/a.7z"]))
        XCTAssertFalse(ExtractCommands.areChecksumFiles([]))
    }

    // MARK: - checksum list accessibility

    func testHashListRowsAreRealTextCells() throws {
        let list = HashListDialogView(strings: ["CRC32  for data", "SHA256 for data"],
                                      values: ["AABBCCDD", "0123abcd"], selectFirst: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 200),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = list
        list.frame = window.contentView?.bounds ?? .zero
        window.contentView?.layoutSubtreeIfNeeded()
        defer { window.close() }
        XCTAssertEqual(list.displayedRows, [["CRC32  for data", "AABBCCDD"], ["SHA256 for data", "0123abcd"]])
        let table = try XCTUnwrap(firstView(of: NSTableView.self, in: list))
        let cell = try XCTUnwrap(table.view(atColumn: 1, row: 0, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(cell.textField?.accessibilityValue() as? String, "AABBCCDD")
    }

    // MARK: - the `test` URL host

    func testUnknownTestURLIsRefusedWithoutABox() throws {
        let url = try XCTUnwrap(URL(string: "sevenzip://test/no-such-command"))
        let windowsBefore = NSApp.windows.filter(\.isVisible).count
        XCTAssertEqual(URLCommands.handle(url), .userError)
        XCTAssertNil(NSApp.modalWindow)
        XCTAssertEqual(NSApp.windows.filter(\.isVisible).count, windowsBefore, "no alert may appear")
    }

    // MARK: - helpers

    private func firstView<T: NSView>(of type: T.Type, in root: NSView?) -> T? {
        guard let root else { return nil }
        if let match = root as? T { return match }
        for child in root.subviews {
            if let found = firstView(of: type, in: child) { return found }
        }
        return nil
    }

    private func button(titled title: String, in root: NSView?) -> NSButton? {
        guard let root else { return nil }
        if let b = root as? NSButton, b.title == title { return b }
        for child in root.subviews {
            if let found = button(titled: title, in: child) { return found }
        }
        return nil
    }
}
