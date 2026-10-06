// DialogLayoutTests.swift -- every window and dialog the app has, measured in this process.
//
// This is `LayoutSweepTests` (Mac/Tests/UITests/LayoutSweepTests.swift) with the app launch, the
// menu driving and the screenshot comparison taken out. The sweep that found the clipped button
// rows of nineteen dialogs asked one question of each window -- "does anything stick out of the
// content rectangle?" -- and answered it from a screenshot. That question is
// `WindowAudit.report`, and the answer is a number, so it belongs here: 11 XCUITest cases, each
// paying for an app launch and a walk through the menu bar, become a handful of cases that
// instantiate the dialog directly (`ModalProbe`), force a layout pass and measure.
//
// Parity references stay with the dialog: `01b-fm-dialogs-settings.md` section 4.x and the Windows
// resource ID are named for every window, exactly as in the XCUITest sweep.
//
// Each dialog is also written to `Mac/docs/reports/screenshots/fastui-*.png`, so the visual record
// the `polish` scope relied on survives -- the difference is that the PNG is now evidence for a
// human, not the measurement itself.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class DialogLayoutTests: AppHostTestCase {

    override var screenshotPrefix: String { "fastui" }

    private var fixtures: String { TestPaths.fixtures }
    private var archive: String { TestPaths.fixture("test.7z") }

    // MARK: - helpers

    /// Present a dialog, audit and screenshot it, and end the modal session.
    private func sweep(_ name: String, shot: String, timeout: TimeInterval = 30,
                       file: StaticString = #filePath, line: UInt = #line,
                       _ present: () -> Void) {
        let appeared = ModalProbe.present(timeout: timeout, present) { window in
            self.audit(window, name, shot: shot)
        }
        if !appeared {
            XCTFail("MISSING \(name): the dialog never came up", file: file, line: line)
        }
    }

    private var infoLines: [String] {
        ["test.7z", "  1 file, 2 folders", "  838 bytes"]
    }

    // MARK: - 4.5 Copy / Move (IDD_COPY 96, IDS_COPY 6000 / IDS_MOVE 6001)

    /// The dialog whose clipped button row started the sweep: `DialogKit.install` pinned the
    /// content with `+margin`, so the bottom `margin` points of the content -- the OK / Cancel row
    /// -- fell outside the window. That is a CLIPPED finding, and it is what this asserts.
    func testCopyAndMoveDialogLayout() {
        continueAfterFailure = true
        sweep("Copy (IDD_COPY 96 / IDS_COPY 6000)", shot: "22-copy") {
            _ = CopyMoveDialog.run(move: false, value: fixtures, history: [fixtures, "/tmp"],
                                   info: infoLines.joined(separator: "\n"), parent: nil)
        }
        sweep("Move (IDD_COPY 96 / IDS_MOVE 6001)", shot: "23-move") {
            _ = CopyMoveDialog.run(move: true, value: fixtures, history: [], info: "", parent: nil)
        }
        finishAudit("Copy / Move")
    }

    // MARK: - 4.11 list dialog (IDD_LISTVIEW 99) and the text viewer (IDD_EDIT_DLG 94)

    /// Properties, Folders History, and the read-only text viewer the list dialog opens -- one
    /// window class, three callers.
    func testListViewDialogLayout() {
        continueAfterFailure = true
        var properties = ListViewDialogOptions()
        properties.title = Lang.text(6600, "Properties")
        properties.strings = ["Path", "Size", "Packed Size", "Modified", "Attributes", "CRC"]
        properties.values = [archive, "838", "410", "2026-09-12 10:00:00", "A", "0BADF00D"]
        properties.numColumns = 2
        properties.selectFirst = true
        sweep("Properties (IDD_LISTVIEW 99 / IDS_PROPERTIES 6600)", shot: "24-properties") {
            _ = ListViewDialog.run(properties, parent: nil)
        }

        var history = ListViewDialogOptions()
        history.title = Lang.text(6601, "Folders History")
        history.strings = [fixtures, TestPaths.realHome, "/tmp"]
        history.deleteIsAllowed = true
        sweep("Folders History (IDD_LISTVIEW 99 / IDS_FOLDERS_HISTORY 6601)", shot: "28-folders-history") {
            _ = ListViewDialog.run(history, parent: nil)
        }

        sweep("Text viewer (IDD_EDIT_DLG 94)", shot: "46-text-viewer") {
            TextViewerDialog.show(title: "readme.txt",
                                  text: (1...40).map { "line \($0) of the viewer" }.joined(separator: "\n"),
                                  parent: nil)
        }
        finishAudit("list dialogs")
    }

    // MARK: - 4.4 combo dialog (IDD_COMBO 98): Create Folder, Create File, Rename, Select

    func testComboDialogLayout() {
        continueAfterFailure = true
        sweep("Create Folder (IDD_COMBO 98 / IDS_CREATE_FOLDER 6300)", shot: "25-create-folder") {
            _ = ComboDialog.run(title: Lang.text(6300, "Create Folder"),
                                label: Lang.text(6302, "Folder name:"),
                                value: Lang.text(6304, "New Folder"), parent: nil)
        }
        sweep("Select (IDD_COMBO 98 / IDS_SELECT 6402)", shot: "47-select-mask") {
            _ = ComboDialog.run(title: Lang.text(6402, "Select"),
                                label: Lang.text(6404, "Mask:"), value: "*",
                                strings: ["*", "*.txt"], parent: nil)
        }
        finishAudit("combo dialogs")
    }

    // MARK: - 4.20 Split (IDD_SPLIT 7300) / 4.21 Combine (IDD_COMBINE 7400) / 4.24 Link (IDD_LINK 7700)

    func testToolsDialogLayout() {
        continueAfterFailure = true
        sweep("Split (IDD_SPLIT 7300)", shot: "26-split") {
            _ = SplitDialog.run(filePath: archive, path: fixtures, parent: nil)
        }
        sweep("Combine (IDD_COMBINE 7400)", shot: "29-combine") {
            _ = CombineDialog.run(title: Lang.text(7400, "Combine Files"),
                                  prompt: Lang.text(7402, "Combine to:"),
                                  info: TestPaths.fixture("multi.7z.001"),
                                  path: fixtures, parent: nil)
        }
        sweep("Link (IDD_LINK 7700)", shot: "27-link") {
            _ = LinkDialog.run(currentDirPrefix: fixtures + "/", filePath: archive,
                               anotherPath: TestPaths.realHome, parent: nil)
        }
        finishAudit("tools dialogs")
    }

    // MARK: - 4.14 About (IDD_ABOUT 2900) / 4.22 Benchmark (IDD_BENCHMARK 7600) / temp files

    func testAboutBenchmarkAndTempFilesLayout() {
        continueAfterFailure = true
        sweep("About (IDD_ABOUT 2900)", shot: "31-about") {
            AboutDialog.show(parent: nil)
        }
        sweep("Benchmark (IDD_BENCHMARK 7600)", shot: "32-benchmark", timeout: 60) {
            BenchmarkDialog.run(totalMode: false, parent: nil)
        }
        sweep("Delete Temporary Files (lang 910)", shot: "33-temp-files") {
            ToolsTempFilesDialog.show(parent: nil)
        }
        finishAudit("About / Benchmark / temp files")
    }

    // MARK: - 4.1 Extract (IDD_EXTRACT 3400)

    func testExtractDialogLayout() {
        continueAfterFailure = true
        var options = ExtractDialog.Options()
        options.directoryPath = fixtures + "/"
        options.archivePath = archive
        sweep("Extract (IDD_EXTRACT 3400)", shot: "37-extract") {
            _ = ExtractDialog.run(options)
        }
        finishAudit("Extract")
    }

    // MARK: - 4.2 Compress (IDD_COMPRESS 4000) and its Options sheet (IDD_COMPRESS_OPTIONS)

    func testCompressDialogLayout() {
        continueAfterFailure = true
        var input = CompressDialogInput()
        input.directoryPrefix = fixtures + "/"
        input.archiveBaseName = "Archive"
        input.itemPaths = [archive]
        sweep("Compress (IDD_COMPRESS 4000)", shot: "35-compress", timeout: 60) {
            _ = CompressDialogController.run(input)
        }

        var state = CompressOptionsSheet.State(
            formatName: "7z", formatTimeFlags: 0, formatFlags: 0,
            supportsMTime: true, supportsCTime: true, supportsATime: true,
            supportsSymLinks: true, supportsHardLinks: false, supportsAltStreams: false,
            supportsNtSecurity: false, isTar: false, isZip: false, isGZip: false,
            isKeepName: false, tarMethodName: "")
        sweep("Compress Options sheet (IDD_COMPRESS_OPTIONS 2100)", shot: "36-compress-options") {
            _ = CompressOptionsSheet.run(&state, parent: nil)
        }
        finishAudit("Compress")
    }

    // MARK: - the operation dialogs (opsinfra scope): Overwrite, Password, Messages, Memory, Progress

    func testOperationDialogLayout() throws {
        continueAfterFailure = true

        // IDD_OVERWRITE 3500, both variants: with the extra buttons (Auto Rename / No to All) and
        // without, which is the shape the copy path uses.
        let old = OverwriteDialog.FileInfo(path: archive, size: 838, time: Date())
        let new = OverwriteDialog.FileInfo(path: TestPaths.fixture("test.zip"), size: 1024, time: Date())
        sweep("Overwrite (IDD_OVERWRITE 3500)", shot: "41-overwrite") {
            _ = OverwriteDialog.run(oldFile: old, newFile: new, showExtraButtons: true, parent: nil)
        }
        sweep("Overwrite, no extra buttons (IDD_OVERWRITE 3500)", shot: "41b-overwrite-plain") {
            _ = OverwriteDialog.run(oldFile: old, newFile: new, showExtraButtons: false, parent: nil)
        }

        // IDD_PASSWORD 3800: the extract side, then the compress side (verify field + encrypt names).
        var extractSide = PasswordDialog.Options()
        extractSide.subject = archive
        sweep("Password, extract side (IDD_PASSWORD 3800)", shot: "42-password-extract") {
            _ = PasswordDialog.run(extractSide, parent: nil)
        }
        var compressSide = PasswordDialog.Options()
        compressSide.requiresVerification = true
        compressSide.showsEncryptFileNames = true
        sweep("Password, compress side (IDD_PASSWORD 3800)", shot: "43-password-compress") {
            _ = PasswordDialog.run(compressSide, parent: nil)
        }

        // IDD_MESSAGES: the diagnostic message list.
        sweep("Messages (IDD_MESSAGES)", shot: "44-messages") {
            MessagesDialog.show(messages: ["\(self.archive) : Data error in encrypted file. Wrong password?",
                                           "sub/big.txt : CRC failed"], parent: nil)
        }

        // IDD_MEMORY_USE 7800.
        var memory = MemoryUseDialog.Options()
        memory.requiredGB = 4
        memory.limitGB = 2
        memory.ramGB = 16
        memory.filePath = "sub/big.txt"
        memory.archivePath = archive
        memory.showRemember = true
        sweep("Memory usage (IDD_MEMORY_USE 7800)", shot: "45-memory") {
            _ = MemoryUseDialog.run(memory, parent: nil)
        }

        // IDD_PROGRESS 100 is not modal from a static entry point: it is built by the operation
        // runner and shown while the work happens, so the window is measured directly.
        for (name, compression, shot) in [("Progress (IDD_PROGRESS 100)", false, "40-progress"),
                                          ("Progress, compressing (IDD_PROGRESS 100)", true, "40b-progress-compress")] {
            let progress = ProgressDialog(title: Lang.text(3300, "Extracting"), showCompressionInfo: compression)
            progress.window.setContentSize(progress.window.contentMinSize)
            audit(progress.window, name, shot: shot)
        }
        finishAudit("operation dialogs")
    }

    // MARK: - 4.10 Comment (IDD_COMMENT 6400) and 7.x checksum results (IDS_CHECKSUM 7501)

    func testCommentAndChecksumLayout() throws {
        continueAfterFailure = true
        sweep("Comment (IDD_COMMENT 6400)", shot: "38-comment") {
            _ = CommentDialog.run(value: "a comment\nover two lines", parent: nil)
        }

        try SZCodecs.loadCodecs()
        let results = try SZHasher.hash(paths: ["readme.txt", "notes.md"], relativeTo: fixtures,
                                        methods: ["CRC32", "SHA256"], recursive: false, progress: nil)
        sweep("Checksum information (IDS_CHECKSUM 7501)", shot: "30-hash-results") {
            HashResultsDialog.show(results: results, parent: nil)
        }
        finishAudit("Comment / checksum")
    }

    // MARK: - 4.13 Options (IDD_OPTIONS 2100), all seven pages

    /// The Options window is not modal, so it is shown and each page selected directly instead of
    /// clicking a localized tab (which is what the XCUITest sweep had to do).
    func testOptionsPagesLayout() {
        continueAfterFailure = true
        let controller = OptionsWindowController.shared
        guard let window = controller.window else { return XCTFail("the Options window has no window") }
        let appeared = ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in }
        XCTAssertTrue(appeared, "the Options window did not come up")
        guard let tabs = firstTabView(in: window) else { return XCTFail("no NSTabView in the Options window") }
        XCTAssertEqual(tabs.numberOfTabViewItems, 7,
                       "OptionsDialog.cpp:13-20, no Plugins page, then the macOS tab (theme): \(tabs.tabViewItems.map(\.label))")
        for index in 0..<tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at: index)
            window.contentView?.layoutSubtreeIfNeeded()
            let label = tabs.tabViewItems[index].label
            audit(window, "Options > \(label)",
                  shot: String(format: "34-options-%d-%@", index + 1, slug(label)))
        }
        ModalProbe.close(window)
        finishAudit("Options pages")
    }

    // MARK: - small helpers

    private func firstTabView(in window: NSWindow) -> NSTabView? {
        func walk(_ view: NSView) -> NSTabView? {
            if let tabs = view as? NSTabView { return tabs }
            for child in view.subviews {
                if let found = walk(child) { return found }
            }
            return nil
        }
        guard let content = window.contentView else { return nil }
        return walk(content)
    }

    private func slug(_ text: String) -> String {
        let cleaned = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(String(cleaned).prefix(20))
    }
}
