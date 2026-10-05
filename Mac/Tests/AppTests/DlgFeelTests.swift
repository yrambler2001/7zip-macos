// DlgFeelTests.swift -- the dialogs measured against 7zFM 26.03 (reports/dlgfeel.md): every
// dialog's client size and resizability, the controls the user had removed or added, the Options
// pages without scrolling in several languages, and "Exclude Mac resource forks" end to end.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class DlgFeelTests: AppHostTestCase {

    override var screenshotPrefix: String { "dlgfeel" }

    private var fixtures: String { TestPaths.fixtures }
    private var archive: String { TestPaths.fixture("test.7z") }

    // MARK: - helpers

    private func probe(_ name: String, timeout: TimeInterval = 30, file: StaticString = #filePath,
                       line: UInt = #line, _ present: () -> Void, _ body: @escaping (NSWindow) -> Void) {
        let appeared = ModalProbe.present(timeout: timeout, present, inspect: body)
        XCTAssertTrue(appeared, "\(name) never came up", file: file, line: line)
    }

    private func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        var found: [T] = []
        if let match = view as? T { found.append(match) }
        for child in view.subviews { found += views(type, in: child) }
        return found
    }

    private func texts(in view: NSView?) -> [String] {
        views(NSTextField.self, in: view).map(\.stringValue)
            + views(NSButton.self, in: view).map(\.title)
            + views(WinGroupBox.self, in: view).map(\.title)
    }

    /// The client size and WS_THICKFRAME of each dialog in 7zFM 26.03 (dlgfeel-data/win/*.txt).
    private func assertWindow(_ window: NSWindow, _ name: String, size: NSSize, resizable: Bool,
                              file: StaticString = #filePath, line: UInt = #line) {
        let content = window.contentView?.bounds.size ?? .zero
        // sffont: the widths are Windows' stretched by DLU.scaleX (SF Pro 12.2 is 10 % wider than
        // Segoe UI); the heights are Windows' own.
        XCTAssertEqual(content.width, DLU.px(size.width), accuracy: 2.5, "\(name): client width", file: file, line: line)
        XCTAssertEqual(content.height, size.height, accuracy: 0.5, "\(name): client height", file: file, line: line)
        XCTAssertEqual(window.styleMask.contains(.resizable), resizable, "\(name): resizable", file: file, line: line)
        if !resizable {
            XCTAssertEqual(window.contentMaxSize, window.contentMinSize, "\(name): a fixed dialog cannot be resized",
                           file: file, line: line)
        }
    }

    // MARK: - sizes and resizability (findings 8, 14, 23, 25 and the sweep)

    func testDialogSizesAndResizabilityMatchWindows() throws {
        continueAfterFailure = true
        probe("About") { AboutDialog.show(parent: nil) } _: {
            self.assertWindow($0, "About", size: NSSize(width: 240, height: 260), resizable: false)
        }
        probe("Copy") {
            _ = CopyMoveDialog.run(move: false, value: "/tmp/", history: [], info: "", parent: nil)
        } _: { self.assertWindow($0, "Copy", size: NSSize(width: 504, height: 260), resizable: true) }
        probe("Create Folder") {
            _ = ComboDialog.run(title: "Create Folder", label: "Folder name:", value: "New Folder", parent: nil)
        } _: { self.assertWindow($0, "Combo", size: NSSize(width: 384, height: 130), resizable: true) }
        probe("Split") {
            _ = SplitDialog.run(filePath: self.archive, path: self.fixtures, parent: nil)
        } _: { self.assertWindow($0, "Split", size: NSSize(width: 456, height: 182), resizable: true) }
        probe("Link") {
            _ = LinkDialog.run(currentDirPrefix: self.fixtures + "/", filePath: self.archive,
                               anotherPath: TestPaths.realHome, parent: nil)
        } _: { self.assertWindow($0, "Link", size: NSSize(width: 456, height: 374), resizable: true) }
        var history = ListViewDialogOptions()
        history.title = "Folders History"
        history.strings = ["/tmp"]
        probe("ListView") { _ = ListViewDialog.run(history, parent: nil) } _: {
            self.assertWindow($0, "ListView", size: NSSize(width: 744, height: 546), resizable: true)
        }
        var extract = ExtractDialog.Options()
        extract.directoryPath = fixtures + "/"
        extract.archivePath = archive
        probe("Extract") { _ = ExtractDialog.run(extract) } _: {
            self.assertWindow($0, "Extract", size: NSSize(width: 528, height: 299), resizable: false)
        }
        var input = CompressDialogInput()
        input.directoryPrefix = fixtures + "/"
        input.archiveBaseName = "a"
        input.itemPaths = [archive]
        probe("Add to Archive", timeout: 60) { _ = CompressDialogController.run(input) } _: {
            self.assertWindow($0, "Add to Archive", size: NSSize(width: 624, height: 546), resizable: false)
        }
        let old = OverwriteDialog.FileInfo(path: archive, size: 1, time: Date())
        probe("Overwrite") { _ = OverwriteDialog.run(oldFile: old, newFile: old, parent: nil) } _: {
            self.assertWindow($0, "Overwrite", size: NSSize(width: 534, height: 351), resizable: false)
        }
        probe("Password") { _ = PasswordDialog.run(PasswordDialog.Options(), parent: nil) } _: {
            self.assertWindow($0, "Password", size: NSSize(width: 324, height: 143), resizable: false)
        }
        probe("Benchmark", timeout: 60) { BenchmarkDialog.run(totalMode: false, parent: nil) } _: {
            self.assertWindow($0, "Benchmark", size: NSSize(width: 732, height: 429), resizable: true)
        }
        probe("Delete Temporary Files") { ToolsTempFilesDialog.show(parent: nil) } _: {
            self.assertWindow($0, "Temp files", size: NSSize(width: 699, height: 559), resizable: true)
        }
        let progress = ProgressDialog(title: "Extracting", showCompressionInfo: false)
        assertWindow(progress.window, "Progress", size: NSSize(width: 564, height: 332), resizable: true)

        let controller = OptionsWindowController.shared
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in })
        assertWindow(window, "Options", size: NSSize(width: 494, height: 550), resizable: false)
        ModalProbe.close(window)
    }

    /// Compress Options (IDD_COMPRESS_OPTIONS): a modal dialog of its own, 384 x 403, fixed, with
    /// the timestamp-precision set box and combo on their template rects (finding 25).
    func testCompressOptionsDialogIsTheWindowsOne() throws {
        try SZCodecs.loadCodecs()
        let zip = try XCTUnwrap(SZCodecs.format(named: "zip"))
        var state = CompressOptionsSheet.State(
            formatName: zip.name, formatTimeFlags: zip.timeFlags, formatFlags: zip.flags,
            supportsMTime: zip.supportsMTime, supportsCTime: zip.supportsCTime, supportsATime: zip.supportsATime,
            supportsSymLinks: zip.supportsSymLinks, supportsHardLinks: zip.supportsHardLinks,
            supportsAltStreams: zip.supportsAltStreams, supportsNtSecurity: zip.supportsNtSecurity,
            isTar: false, isZip: true, isGZip: false, isKeepName: zip.keepName, tarMethodName: "")
        probe("Compress Options") { _ = CompressOptionsSheet.run(&state, parent: nil) } _: { window in
            self.assertWindow(window, "Compress Options", size: NSSize(width: 384, height: 403), resizable: false)
            XCTAssertNil(window.sheetParent, "not a sheet: a dialog with its own caption")
            let boxes = self.views(NSButton.self, in: window.contentView)
            // IDX_COMPRESS_PREC_SET 201 ":" at 24,185 next to "Timestamp precision:" (51,185).
            let precSet = boxes.first { $0.title == ":" && abs($0.frame.minY - 185) < 1 && $0.frame.minX < 30 }
            XCTAssertNotNil(precSet, "the precision set box")
            XCTAssertTrue(self.views(NSPopUpButton.self, in: window.contentView).contains {
                abs($0.frame.minX - DLU.px(246)) < 1.5 && abs($0.frame.minY - 182) < 1 && abs($0.frame.width - DLU.px(114)) < 1.5
            }, "IDC_COMPRESS_TIME_PREC 190 at 246,182 114 wide")
        }
    }

    // MARK: - About (finding 8)

    func testAboutIsWindowsLayoutWithTheMacCredit() {
        probe("About") { AboutDialog.show(parent: nil) } _: { window in
            let all = self.texts(in: window.contentView)
            XCTAssertTrue(all.contains(AboutDialog.macCredit), "the macOS credit line")
            let fields = self.views(NSTextField.self, in: window.contentView)
            let copyright = fields.first { $0.stringValue.hasPrefix("Copyright") }
            let credit = fields.first { $0.stringValue == AboutDialog.macCredit }
            XCTAssertNotNil(copyright)
            if let copyright, let credit {
                // the next line at the copyright line's 21 px pitch (y 130 -> 151)
                XCTAssertEqual(credit.frame.minY - copyright.frame.minY, 21, accuracy: 0.5)
                XCTAssertEqual(credit.frame.minX, copyright.frame.minX, accuracy: 0.5)
            }
            XCTAssertEqual(self.views(NSButton.self, in: window.contentView).map(\.title).sorted(),
                           ["OK", "www.7-zip.org"])
        }
    }

    // MARK: - Options (findings 12-22)

    private func optionsPage<T: OptionsPageBase>(_ type: T.Type) throws -> T {
        let controller = OptionsWindowController.shared
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in })
        let tabs = try XCTUnwrap(views(NSTabView.self, in: window.contentView).first)
        return try XCTUnwrap(tabs.tabViewItems.compactMap { $0.viewController as? T }.first)
    }

    func testOptionsHasTheWindowsPagesAndNoMacNotes() throws {
        let controller = OptionsWindowController.shared
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in })
        defer { ModalProbe.close(window) }
        let tabs = try XCTUnwrap(views(NSTabView.self, in: window.contentView).first)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["System", "7-Zip", "Folders", "Editor", "Settings", "Language"],
                       "OptionsDialog.cpp's six pages, no Plugins page (finding 22)")
        let banned = ["macOS keeps file associations", "\u{201C}Current\u{201D} means", "Options.WorkDirType",
                      "A value may be an application bundle", "macOS: adds Finder", "Use large memory pages",
                      "Default application", "Description", "Open Login Items", "pluginkit",
                      "com.apple.quarantine", "SeLockMemoryPrivilege"]
        for index in 0..<tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at: index)
            let page = try XCTUnwrap(tabs.tabViewItem(at: index).view)
            var all = texts(in: page)
            for table in views(NSTableView.self, in: page) { all += table.tableColumns.map(\.title) }
            for text in all {
                for bad in banned {
                    XCTAssertFalse(text.contains(bad), "page \(index): '\(text)' (findings 12, 17, 18, 19, 20)")
                }
            }
            for field in views(NSTextField.self, in: page) where field.isEditable {
                XCTAssertTrue(field.placeholderString?.isEmpty ?? true, "page \(index): a placeholder (finding 18)")
            }
        }
    }

    func testSystemPageColumnsAreWindows() throws {
        let page = try optionsPage(OptionsSystemPage.self)
        let table = try XCTUnwrap(views(NSTableView.self, in: page.view).first)
        XCTAssertEqual(table.tableColumns.map(\.width), [80, 152])
        XCTAssertEqual(table.tableColumns[1].title, NSUserName())
        XCTAssertEqual(table.tableColumns[1].headerCell.alignment, .center)
        // one "+" (IDB_SYSTEM_CURRENT 101) over the user's column, no "-" / "*" buttons
        let buttons = views(NSButton.self, in: page.view).map(\.title)
        XCTAssertEqual(buttons, ["+"])
    }

    func testEditorPageIsLabelThenFullWidthField() throws {
        let page = try optionsPage(OptionsEditorPage.self)
        let fields = views(NSTextField.self, in: page.view).filter(\.isEditable).sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(fields.count, 3)
        let labels = views(NSTextField.self, in: page.view).filter { !$0.isEditable }.sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(labels.count, 3)
        for (label, field) in zip(labels, fields) {
            XCTAssertLessThan(label.frame.maxY, field.frame.maxY, "label above its field")
            XCTAssertGreaterThan(field.frame.width, 400, "the field spans the page (408 px)")
        }
    }

    func testLanguagePageIsOneDropDownList() throws {
        let page = try optionsPage(OptionsLanguagePage.self)
        let popups = views(NSPopUpButton.self, in: page.view)
        XCTAssertEqual(popups.count, 1)
        XCTAssertEqual(popups.first?.frame.width ?? 0, DLU.px(240), accuracy: 1)
        XCTAssertTrue(views(NSTableView.self, in: page.view).isEmpty)
        XCTAssertEqual(page.comboTitles.first, "English : English  ---")
    }

    /// Nothing on any page needs scrolling or reaches past the page, and the 7-Zip page lists every
    /// context-menu item without a scroll bar (finding 15), in several languages.
    func testOptionsPagesDoNotScrollInSeveralLanguages() throws {
        continueAfterFailure = true
        let controller = OptionsWindowController.shared
        let window = try XCTUnwrap(controller.window)
        for code in ["-", "de", "ru", "fr", "ja", "uk"] {
            useLanguage(code)
            XCTAssertTrue(ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in })
            let tabs = try XCTUnwrap(views(NSTabView.self, in: window.contentView).first)
            for index in 0..<tabs.numberOfTabViewItems {
                tabs.selectTabViewItem(at: index)
                window.contentView?.layoutSubtreeIfNeeded()
                let page = try XCTUnwrap(tabs.tabViewItem(at: index).view)
                for child in page.subviews where !child.isHidden {
                    XCTAssertTrue(page.bounds.insetBy(dx: -1, dy: -1).contains(child.frame),
                                  "\(code) page \(index): \(type(of: child)) \(child.frame) leaves \(page.bounds)")
                }
                if tabs.tabViewItem(at: index).viewController is OptionsMenuPage {
                    let scroll = try XCTUnwrap(views(NSScrollView.self, in: page).first)
                    let table = try XCTUnwrap(scroll.documentView as? NSTableView)
                    table.layoutSubtreeIfNeeded()
                    let needed = CGFloat(table.numberOfRows) * table.rowHeight
                    XCTAssertEqual(table.numberOfRows, 14)
                    XCTAssertLessThanOrEqual(needed, scroll.contentView.bounds.height,
                                             "\(code): the context-menu items need a scroll bar")
                }
            }
            ModalProbe.close(window)
        }
        useLanguage("-")
    }

    // MARK: - Benchmark (finding 23)

    func testBenchmarkColumnsDoNotMoveAndHaveGroupBoxes() {
        probe("Benchmark", timeout: 60) { BenchmarkDialog.run(totalMode: false, parent: nil) } _: { window in
            let content = window.contentView
            let groups = self.views(WinGroupBox.self, in: content).map(\.title)
            XCTAssertEqual(groups, ["Compressing", "Decompressing", "Total Rating"])
            let rightAligned = self.views(NSTextField.self, in: content).filter { $0.stringValue == "..." }
            XCTAssertFalse(rightAligned.isEmpty)
            XCTAssertTrue(rightAligned.allSatisfy { $0.alignment == .right }, "the values are RTEXT")
            let before = rightAligned.map(\.frame)
            // A wider window only stretches the log (OnSize); the values stay where they were.
            window.setContentSize(NSSize(width: 900, height: 520))
            content?.layoutSubtreeIfNeeded()
            XCTAssertEqual(rightAligned.map(\.frame), before)
        }
    }

    // MARK: - Add to Archive (findings 25, 28)

    func testAddToArchiveHasTheExcludeBoxUncheckedInTheOptionsGroup() throws {
        let saved = Settings.compressExcludeMacResourceForks
        Settings.compressExcludeMacResourceForks = false
        defer { Settings.compressExcludeMacResourceForks = saved }
        var input = CompressDialogInput()
        input.directoryPrefix = fixtures + "/"
        input.archiveBaseName = "a"
        input.itemPaths = [archive]
        probe("Add to Archive", timeout: 60) { _ = CompressDialogController.run(input) } _: { window in
            let content = window.contentView
            let box = self.views(NSButton.self, in: content)
                .first { $0.title == CompressDialogController.excludeMacResourceForksTitle }
            XCTAssertNotNil(box, "the checkbox")
            XCTAssertEqual(box?.state, .off, "unchecked by default")
            let group = self.views(WinGroupBox.self, in: content).first { $0.title == "Options" }
            if let box, let group {
                XCTAssertTrue(group.frame.contains(box.frame), "inside the Options group box")
            }
            let titles = self.views(WinGroupBox.self, in: content).map(\.title)
            XCTAssertEqual(titles, ["Options", "Encryption"])
        }
    }

    /// The archive with the box off has the Mac metadata the folder holds; with it on it has none.
    func testExcludeMacResourceForksKeepsMacMetadataOutOfTheArchive() throws {
        try SZCodecs.loadCodecs()
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("dlgfeel-forks-\(getpid())")
        try? FileManager.default.removeItem(atPath: root)
        let src = (root as NSString).appendingPathComponent("folder")
        try FileManager.default.createDirectory(atPath: src + "/__MACOSX", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: src + "/sub", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }
        try "hello".write(toFile: src + "/a.txt", atomically: true, encoding: .utf8)
        try "fork".write(toFile: src + "/._a.txt", atomically: true, encoding: .utf8)
        try "ds".write(toFile: src + "/.DS_Store", atomically: true, encoding: .utf8)
        try "ds".write(toFile: src + "/sub/.DS_Store", atomically: true, encoding: .utf8)
        try "x".write(toFile: src + "/sub/b.txt", atomically: true, encoding: .utf8)
        try "fork".write(toFile: src + "/sub/._b.txt", atomically: true, encoding: .utf8)
        try "fork".write(toFile: src + "/__MACOSX/._a.txt", atomically: true, encoding: .utf8)
        // a resource fork and a Finder-info attribute on a.txt
        let fork = Array("resource".utf8)
        XCTAssertEqual(setxattr(src + "/a.txt", "com.apple.ResourceFork", fork, fork.count, 0, 0), 0)
        XCTAssertEqual(setxattr(src + "/a.txt", "com.apple.metadata:kMDItemWhereFroms", fork, fork.count, 0, 0), 0)

        func archive(_ name: String, exclude: Bool) throws -> [String] {
            let path = (root as NSString).appendingPathComponent(name)
            let options = SZUpdateOptions(archivePath: path)
            options.formatName = "7z"
            CompressMacMetadata.apply(to: options, exclude: exclude)
            let specs = CompressMacMetadata.pathSpecs(items: [SZPathSpec.literal(src)], exclude: exclude)
            _ = try SZUpdater.update(with: options, pathSpecs: specs, progress: nil)
            var names: [String] = []
            let folder = try SZFolder.folder(forPath: path, passwordDelegate: nil)
            func walk(_ f: SZFolder, _ prefix: String) throws {
                try f.loadItems()
                for i in 0..<f.itemCount {
                    let full = prefix.isEmpty ? f.nameOfItem(at: i) : prefix + "/" + f.nameOfItem(at: i)
                    names.append(full)
                    if f.isDirectory(at: i) { try walk(f.bindToFolder(at: i), full) }
                }
            }
            try walk(folder, "")
            return names.sorted()
        }

        let kept = try archive("kept.7z", exclude: false)
        XCTAssertEqual(kept, ["folder", "folder/.DS_Store", "folder/._a.txt", "folder/__MACOSX",
                              "folder/__MACOSX/._a.txt", "folder/a.txt", "folder/sub", "folder/sub/.DS_Store",
                              "folder/sub/._b.txt", "folder/sub/b.txt"],
                       "unchecked: what the port has always stored")
        let clean = try archive("clean.7z", exclude: true)
        XCTAssertEqual(clean, ["folder", "folder/a.txt", "folder/sub", "folder/sub/b.txt"],
                       "checked: no AppleDouble files, no .DS_Store, no __MACOSX")
        for name in kept + clean {
            XCTAssertFalse(name.contains(":"), "no extended-attribute stream (\(name))")
        }
    }

    func testExcludeMacResourceForksIsRemembered() {
        let saved = Settings.compressExcludeMacResourceForks
        defer { Settings.compressExcludeMacResourceForks = saved }
        Settings.compressExcludeMacResourceForks = true
        XCTAssertTrue(Settings.compressExcludeMacResourceForks)
        Settings.compressExcludeMacResourceForks = false
        XCTAssertFalse(Settings.compressExcludeMacResourceForks)
        XCTAssertEqual(CompressMacMetadata.excludedNames, ["._*", ".DS_Store", "__MACOSX"])
        let specs = CompressMacMetadata.excludeSpecs
        XCTAssertTrue(specs.allSatisfy { !$0.include && $0.recursedType == .recursed && $0.wildcardMatching })
    }

    // MARK: - the sweep

    /// The group boxes are Windows', and the dialogs that have them on Windows have them here.
    func testGroupBoxesWhereWindowsHasThem() {
        var extract = ExtractDialog.Options()
        extract.directoryPath = fixtures + "/"
        extract.archivePath = archive
        probe("Extract") { _ = ExtractDialog.run(extract) } _: { window in
            XCTAssertEqual(self.views(WinGroupBox.self, in: window.contentView).map(\.title), ["Password"])
        }
        probe("Link") {
            _ = LinkDialog.run(currentDirPrefix: self.fixtures + "/", filePath: self.archive,
                               anotherPath: TestPaths.realHome, parent: nil)
        } _: { window in
            XCTAssertEqual(self.views(WinGroupBox.self, in: window.contentView).map(\.title), ["Link Type"])
            let radios = self.views(NSButton.self, in: window.contentView).filter { $0.title == "WSL" || $0.title == "Directory Junction" }
            XCTAssertEqual(radios.count, 2, "all five link types, the NTFS ones disabled")
            XCTAssertTrue(radios.allSatisfy { !$0.isEnabled })
            XCTAssertFalse(self.texts(in: window.contentView).contains { $0.contains("NTFS reparse") })
        }
    }

    /// Checksum results are the plain IDD_LISTVIEW: OK and Cancel, no extra Copy button.
    func testChecksumResultsAreTheListViewDialog() throws {
        try SZCodecs.loadCodecs()
        let results = try SZHasher.hash(paths: ["test.7z"], relativeTo: fixtures, methods: ["CRC32"],
                                        recursive: false, progress: nil)
        probe("Checksum") { HashResultsDialog.show(results: results, parent: nil) } _: { window in
            XCTAssertEqual(self.views(NSButton.self, in: window.contentView).filter { !$0.isHidden }.map(\.title).sorted(),
                           ["Cancel", "OK"])
            self.assertWindow(window, "Checksum", size: NSSize(width: 744, height: 546), resizable: true)
        }
    }

    /// A resizable dialog lays itself out again like its OnSize: Copy keeps "..." at the right
    /// edge and OK / Cancel at the bottom right.
    func testResizableDialogsFollowOnSize() {
        probe("Copy") {
            _ = CopyMoveDialog.run(move: false, value: "/tmp/", history: [], info: "a\nb", parent: nil)
        } _: { window in
            window.setContentSize(NSSize(width: 704, height: 360))
            let content = window.contentView!
            let buttons = self.views(NSButton.self, in: content)
            let dots = buttons.first { $0.title == "..." }
            let cancel = buttons.first { $0.title == "Cancel" }
            XCTAssertEqual(dots?.frame.maxX ?? 0, 704 - 12 - 1, accuracy: 1, "\"...\" at the right margin")
            XCTAssertEqual(cancel?.frame.maxX ?? 0, 704 - 12 - 1, accuracy: 1)
            XCTAssertEqual(cancel?.frame.maxY ?? 0, 360 - 13, accuracy: 1, "the buttons at the bottom margin")
        }
    }
}
