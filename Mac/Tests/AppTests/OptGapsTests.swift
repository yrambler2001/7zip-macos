// OptGapsTests.swift -- the Options / Compress / dialog backlog closed by `mac/optgaps`, asserted in
// the app's own process (`SevenZipAppTests`, see AppHostTestCase).

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class OptGapsTests: AppHostTestCase {

    override var screenshotPrefix: String { "optgaps" }

    // MARK: - Options pages fit the window (requests.md, `fastui` -> `options`)

    /// Languages with the longest Options labels (measured by `fastui`: de, ru, ja, ar, he) plus
    /// built-in English.
    private let layoutLanguages = ["-", "de", "ru", "ja", "ar", "he", "fr", "uk"]

    func testOptionsPagesFitTheirWindow() {
        continueAfterFailure = true
        let controller = OptionsWindowController.shared
        guard let window = controller.window else { return XCTFail("the Options window has no window") }
        var problems: [String] = []
        for code in layoutLanguages {
            useLanguage(code)
            let appeared = ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in }
            XCTAssertTrue(appeared, "the Options window did not come up in '\(code)'")
            guard let content = window.contentView, let tabs = Self.firstTabView(in: content) else {
                return XCTFail("no NSTabView in the Options window")
            }
            for index in 0..<tabs.numberOfTabViewItems {
                tabs.selectTabViewItem(at: index)
                content.layoutSubtreeIfNeeded()
                let fitting = content.fittingSize
                let bounds = content.bounds.size
                let name = "\(code) page \(index + 1) \(tabs.tabViewItems[index].label)"
                print(String(format: "OPTFIT | %@ | needs %.0fx%.0f | has %.0fx%.0f", name,
                             fitting.width, fitting.height, bounds.width, bounds.height))
                if fitting.width > bounds.width + 1 || fitting.height > bounds.height + 1 {
                    var culprits: [String] = []
                    if let page = tabs.tabViewItems[index].view {
                        Self.collectWide(page, limit: page.bounds.width, path: "", into: &culprits)
                    }
                    problems.append(String(format: "%@ needs %.0fx%.0f in %.0fx%.0f", name,
                                           fitting.width, fitting.height, bounds.width, bounds.height)
                                    + culprits.map { "\n    " + $0 }.joined())
                }
            }
            ModalProbe.close(window)
        }
        XCTAssertTrue(problems.isEmpty, "Options pages that want more than the window:\n"
                      + problems.joined(separator: "\n"))
    }

    // MARK: - Options pages: helpers

    private func optionsPage<T: OptionsPageBase>(_ type: T.Type) throws -> T {
        let controller = OptionsWindowController.shared
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in })
        let tabs = try XCTUnwrap(window.contentView.flatMap(Self.firstTabView(in:)))
        let page = tabs.tabViewItems.compactMap { $0.viewController as? T }.first
        return try XCTUnwrap(page, "no \(T.self) in the Options window")
    }

    private func firstTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews {
            if let found = firstTable(in: child) { return found }
        }
        return nil
    }

    private func cellText(_ table: NSTableView, column id: String, row: Int) -> String {
        let column = table.column(withIdentifier: NSUserInterfaceItemIdentifier(id))
        return (table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?
            .textField?.stringValue ?? ""
    }

    // MARK: - Options > System (01b section 4.21, parity.md B 13 / D 12)

    /// The format icons are 7-Zip's own document icons, not the system's.
    func testSystemPageShowsTheFormatIcons() throws {
        for type in FileTypes.all {
            let image = try XCTUnwrap(OptionsSystemPage.formatIcon(for: type), "no icon for .\(type.ext)")
            let bundled = Bundle.main.url(forResource: "doc-" + type.iconFileName, withExtension: "icns")
            XCTAssertNotNil(bundled, "doc-\(type.iconFileName).icns is not in the bundle")
            // The .icns carries a real 16 px representation for the 16 pt row.
            XCTAssertTrue(image.representations.contains { $0.pixelsWide == 16 },
                          ".\(type.ext): no 16 px representation in \(image.representations)")
        }
    }

    /// NM_CLICK on the state column toggles that row; Return toggles the selection (NM_RETURN).
    func testSystemPageClickAndReturnToggleRows() throws {
        let page = try optionsPage(OptionsSystemPage.self)
        let table = try XCTUnwrap(firstTable(in: page.view) as? OptionsAssociationTableView)
        let userColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("user"))
        let typeColumn = table.column(withIdentifier: NSUserInterfaceItemIdentifier("type"))
        // A row macOS can associate (it has a type) and that 7-Zip does not own yet.
        let row = try XCTUnwrap((0..<table.numberOfRows).first { row in
            let state = cellText(table, column: "user", row: row)
            return state != "7-Zip" && state != "\u{2014}"
        }, "every associable row is already 7-Zip's")
        let before = cellText(table, column: "user", row: row)
        defer { page.withoutChangeTracking { page.pageDidLoad() }; page.clearChanged() }

        page.toggleRow(row, column: typeColumn)
        XCTAssertEqual(cellText(table, column: "user", row: row), before, "a click on Type must not toggle")

        page.toggleRow(row, column: userColumn)
        XCTAssertEqual(cellText(table, column: "user", row: row), "7-Zip")
        XCTAssertTrue(page.pageIsChanged)
        page.toggleRow(row, column: userColumn)
        XCTAssertEqual(cellText(table, column: "user", row: row), before)

        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        XCTAssertEqual(table.onKey?("\r"), true, "Return is NM_RETURN")
        XCTAssertEqual(cellText(table, column: "user", row: row), "7-Zip")
        XCTAssertEqual(table.onKey?("\r"), true)
        XCTAssertEqual(cellText(table, column: "user", row: row), before)
    }

    /// The columns are sized to their content, so nothing the System and Language lists exist to
    /// show is cut (requests.md, `packaging` -> `options`).
    func testSystemAndLanguageColumnsFitTheirContent() throws {
        let system = try optionsPage(OptionsSystemPage.self)
        let systemTable = try XCTUnwrap(firstTable(in: system.view))
        for column in systemTable.tableColumns {
            XCTAssertGreaterThanOrEqual(column.width + 1, column.headerCell.cellSize.width,
                                        "System column '\(column.title)' cuts its header")
        }
        let language = try optionsPage(OptionsLanguagePage.self)
        let languageTable = try XCTUnwrap(firstTable(in: language.view))
        let lines = languageTable.tableColumns[languageTable.column(withIdentifier: NSUserInterfaceItemIdentifier("lines"))]
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let total = SZLang.shared.englishStringCount
        let widest = ("\(total) / \(total) = 100%" as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThan(lines.width, widest, "the Strings column cuts \"\(total) / \(total) = 100%\"")
    }

    // MARK: - Options > Language (01b section 4.9, parity.md B 14 / D 12)

    /// The scan reports per file what LangPage.cpp:197-245 computes, and the files that do not load.
    func testLanguageScanListsMissingAndExtraIdsAndFailedFiles() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("optgaps-lang-\(getpid())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let de = (SZLang.langDirectoryPath as NSString).appendingPathComponent("de.txt")
        try FileManager.default.copyItem(atPath: de, toPath: dir.appendingPathComponent("de.txt").path)
        try "this is not a 7-Zip language file\n".write(to: dir.appendingPathComponent("broken.txt"),
                                                      atomically: true, encoding: .utf8)
        // A file with one known id and one id en.ttt does not have.
        try "\u{FEFF};!@Lang2@!UTF-8!\n;  Test translator\n0\n7-Zip\n401\nJa\n99999\nExtra\n"
            .write(to: dir.appendingPathComponent("xx.txt"), atomically: true, encoding: .utf8)

        var failed: NSArray?
        let infos = SZLang.shared.languages(inDirectory: dir.path, failedFiles: &failed)
        XCTAssertEqual(failed as? [String], ["broken.txt"])
        let german = try XCTUnwrap(infos.first { $0.code == "de" })
        let english = SZLang.shared.englishStringCount
        XCTAssertEqual(german.stringCount - german.extraLines.count + german.missingLines.count, english,
                       "matches + missing must be every en.ttt id")
        XCTAssertFalse(german.comments.isEmpty, "de.txt has translator comments")
        for line in german.missingLines {
            XCTAssertNotNil(line.range(of: #"^\d+ : "#, options: .regularExpression), "malformed line '\(line)'")
        }
        if let xx = infos.first(where: { $0.code == "xx" }) {
            XCTAssertEqual(xx.extraLines, ["99999 : Extra"])
            XCTAssertTrue(xx.missingLines.contains { $0.hasPrefix("402 : ") }, "402 Cancel is missing from xx")
            XCTAssertFalse(xx.missingLines.contains { $0.hasPrefix("401 : ") })
        } else {
            XCTFail("xx.txt did not load: \(failed ?? [])")
        }
    }

    /// IDT_LANG_INFO: name, count, comments, then the Missing / Extra sections (ShowLangInfo).
    func testLanguageInfoShowsTheIdLists() throws {
        let page = try optionsPage(OptionsLanguagePage.self)
        let incomplete = try XCTUnwrap(page.entries.first { !$0.missingLines.isEmpty && !$0.code.isEmpty
                                                             && $0.code != "-" })
        let english = SZLang.shared.englishStringCount
        let text = OptionsLanguagePage.langInfoText(incomplete, englishCount: english)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "\(incomplete.code) : \(incomplete.stringCount) / \(english) = "
                       + "\(incomplete.stringCount * 100 / english)%")
        XCTAssertTrue(text.contains("\n------ Missing lines: \(incomplete.missingLines.count) :\n"), text)
        XCTAssertTrue(text.contains(incomplete.missingLines[0]), text)
        // AddVectorToString: at most 50 rows per list.
        let listed = incomplete.missingLines.filter { text.contains($0 + "\n") }.count
        XCTAssertEqual(listed, min(incomplete.missingLines.count, 50))
        XCTAssertTrue(page.reportedLoadErrors.isEmpty, "a bundled lang file failed: \(page.reportedLoadErrors)")
    }

    // MARK: - Options window: closed toolbars, preferences domain

    /// reloadLangItems() skips the toolbar of a closed window instead of raising
    /// NSInternalInconsistencyException (requests.md, `modalfix` -> `options`).
    func testReloadLangItemsSkipsClosedWindows() {
        let savedPaths = (Settings.panelPath(0), Settings.panelPath(1))
        defer {
            Settings.setPanelPath(savedPaths.0 ?? "", 0)
            Settings.setPanelPath(savedPaths.1 ?? "", 1)
        }
        let controller = MainWindowController()
        controller.showWindow(nil)
        XCTAssertNotNil(controller.window?.toolbar)
        controller.window?.close()
        OptionsPostApply.reloadLangItems()           // raised before the fix
        XCTAssertNotNil(NSApp.mainMenu)
    }

    /// The default preferences domain is the running app's bundle identifier
    /// (requests.md, `resetcmd` -> MacPrefs.cpp owner).
    func testDefaultDomainIsTheRunningBundleIdentifier() throws {
        let identifier = try XCTUnwrap(Bundle.main.bundleIdentifier)
        XCTAssertEqual(SZSettings.defaultApplicationID, identifier)
        XCTAssertTrue(SZSettings.usesOverrideSuite, "the host must still run on its isolated suite")
    }

    // MARK: - dialog placement (requests.md, `polish` -> `opsinfra`)

    private func center(_ frame: NSRect) -> NSPoint { NSPoint(x: frame.midX, y: frame.midY) }

    func testDialogsCentreOnTheirOwnerWindow() throws {
        let screen = try XCTUnwrap(NSScreen.main?.visibleFrame)
        let parent = NSWindow(contentRect: NSRect(x: screen.minX + 40, y: screen.minY + 60, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)
        defer { parent.close() }

        var withParent: NSRect?
        XCTAssertTrue(ModalProbe.present({ _ = CommentDialog.run(value: "x", parent: parent) }) { window in
            withParent = window.frame
        })
        let a = try XCTUnwrap(withParent)
        XCTAssertEqual(center(a).x, center(parent.frame).x, accuracy: 1.5)
        XCTAssertEqual(center(a).y, center(parent.frame).y, accuracy: 1.5)

        // No parent: the key / main window, never the screen while a window is up.
        var owner: NSWindow?
        var withoutParent: NSRect?
        XCTAssertTrue(ModalProbe.present({ _ = CommentDialog.run(value: "x", parent: nil) }) { window in
            owner = DialogKit.owner(for: window, parent: nil)
            withoutParent = window.frame
        })
        let b = try XCTUnwrap(withoutParent)
        let ownerFrame = try XCTUnwrap(owner?.frame, "a visible window exists, so the dialog has an owner")
        let visible = (owner?.screen ?? NSScreen.main)?.visibleFrame ?? screen
        let expectedX = min(max((ownerFrame.midX - b.width / 2).rounded(), visible.minX), visible.maxX - b.width)
        let expectedY = min(max((ownerFrame.midY - b.height / 2).rounded(), visible.minY), visible.maxY - b.height)
        XCTAssertEqual(b.minX, expectedX, accuracy: 1.5)
        XCTAssertEqual(b.minY, expectedY, accuracy: 1.5)
    }

    // MARK: - IDD_LISTVIEW 99 accessibility (requests.md, `opsgaps` -> `panel`)

    func testListViewDialogRowsAreRealTextCells() {
        var options = ListViewDialogOptions()
        options.title = "Properties"
        options.strings = ["Path", "Size"]
        options.values = ["/tmp/a.7z", "838"]
        options.numColumns = 2
        var texts: [[String]] = []
        XCTAssertTrue(ModalProbe.present({ _ = ListViewDialog.run(options, parent: nil) }) { window in
            guard let table = window.contentView.flatMap(self.firstTable(in:)) else { return }
            texts = (0..<table.numberOfRows).map { row in
                (0..<table.numberOfColumns).map { column in
                    let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView
                    return (cell?.textField?.accessibilityValue() as? String) ?? ""
                }
            }
        })
        XCTAssertEqual(texts, [["Path", "/tmp/a.7z"], ["Size", "838"]])
    }

    // MARK: - right-to-left composite strings (requests.md, `packaging` -> `panel`)

    func testCompositeStringsIsolateTheirSegments() {
        let line = Bidi.labelValue("الملفات", "1")
        XCTAssertEqual(Bidi.stripped(line), "الملفات: 1")
        XCTAssertEqual(line, "\u{2068}الملفات\u{2069}: \u{2068}1\u{2069}")
        XCTAssertEqual(Bidi.join(["a", "", "b"], separator: " "), "\u{2068}a\u{2069}  \u{2068}b\u{2069}")

        var fields: [NSTextField] = []
        let info = "x.txt\n\n" + Bidi.labelValue("الملفات", "1")
        XCTAssertTrue(ModalProbe.present({
            _ = CopyMoveDialog.run(move: false, value: "/tmp", history: [], info: info, parent: nil)
        }) { window in
            func walk(_ view: NSView) {
                if let field = view as? NSTextField, !field.isEditable,
                   Bidi.stripped(field.stringValue) == "الملفات: 1" { fields.append(field) }
                view.subviews.forEach(walk)
            }
            window.contentView.map(walk)
        })
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields.first?.baseWritingDirection, .leftToRight)
    }

    // MARK: - Compress: the Browse filters (01b section 4.23, parity.md D 11)

    private let formatTable: [(name: String, extensions: [String], mainExtension: String)] = [
        ("7z", ["7z"], "7z"),
        ("zip", ["zip", "zipx", "jar", "xpi", "odt", "ods", "docx", "xlsx", "epub"], "zip"),
        ("tar", ["tar", "ova"], "tar"),
    ]

    func testCompressBrowseFiltersFollowOnButtonSetArchive() {
        let normal = CompressBrowseFilter.filters(formats: formatTable, selectedFormat: 1, sfx: false,
                                                  archiveLabel: "&Archive:", allFilesLabel: "All Files")
        XCTAssertEqual(normal.filters.map(\.title),
                       ["7z (7z)", "zip (zip zipx jar epub)", "tar (tar ova)", "Archive: (7z zip tar)", "All Files (*)"])
        XCTAssertEqual(normal.initial, 1, "the selected format's filter comes up first")
        XCTAssertEqual(normal.filters[1].formatListIndex, 1)
        XCTAssertNil(normal.filters[3].formatListIndex)
        XCTAssertTrue(normal.filters[4].extensions.isEmpty)
        XCTAssertTrue(normal.filters[4].contentTypes.isEmpty)
        XCTAssertFalse(normal.filters[1].extensions.contains("docx"), "k_DontSave_Exts")

        let sfx = CompressBrowseFilter.filters(formats: formatTable, selectedFormat: 1, sfx: true,
                                               archiveLabel: "Archive:", allFilesLabel: "All Files")
        XCTAssertEqual(sfx.filters.map(\.title), ["exe (exe)", "All Files (*)"])
        XCTAssertEqual(sfx.initial, 0)

        let main: (Int) -> String = { self.formatTable[$0].mainExtension }
        let zip = normal.filters[1]
        XCTAssertEqual(CompressBrowseFilter.resolvedPath("/a/b", filter: zip, sfx: false, mainExtension: main), "/a/b.zip")
        XCTAssertEqual(CompressBrowseFilter.resolvedPath("/a/b.JAR", filter: zip, sfx: false, mainExtension: main), "/a/b.JAR")
        XCTAssertEqual(CompressBrowseFilter.resolvedPath("/a/b.7z", filter: zip, sfx: false, mainExtension: main), "/a/b.7z.zip")
        XCTAssertEqual(CompressBrowseFilter.resolvedPath("/a/b.", filter: zip, sfx: false, mainExtension: main), "/a/b.zip")
        XCTAssertEqual(CompressBrowseFilter.resolvedPath("/a/b.7z", filter: normal.filters[4], sfx: false,
                                                         mainExtension: main), "/a/b.7z")
        XCTAssertEqual(CompressBrowseFilter.resolvedPath("/a.d/b.7z", filter: sfx.filters[0], sfx: true,
                                                         mainExtension: main), "/a.d/b.exe")
        XCTAssertEqual(CompressBrowseFilter.resolvedPath("/a.d/b", filter: sfx.filters[0], sfx: true,
                                                         mainExtension: main), "/a.d/b.exe")
    }

    /// `-sfx<module>` survives the dialog: input -> result -> SZUpdateOptions (requests.md,
    /// `cmdmode` -> `compress`).
    func testSFXModuleIsCarriedThroughTheDialogResult() {
        var result = CompressDialogResult()
        result.archivePath = "/tmp/x.exe"
        result.sfxMode = true
        result.sfxModulePath = "/tmp/custom.sfx"
        XCTAssertEqual(result.updateOptions().sfxModulePath, "/tmp/custom.sfx")
        result.sfxMode = false
        XCTAssertNil(result.updateOptions().sfxModulePath, "no module without SFX mode")
    }

    // MARK: - helpers

    static func firstTabView(in view: NSView) -> NSTabView? {
        if let tabs = view as? NSTabView { return tabs }
        for child in view.subviews {
            if let found = firstTabView(in: child) { return found }
        }
        return nil
    }

    /// The deepest views whose own fitting width exceeds `limit`.
    static func collectWide(_ view: NSView, limit: CGFloat, path: String, into out: inout [String]) {
        let name = path + "/" + String(describing: type(of: view))
        let wideChildren = view.subviews.filter { $0.fittingSize.width > limit + 1 }
        if wideChildren.isEmpty {
            if view.fittingSize.width > limit + 1 {
                var text = ""
                if let field = view as? NSTextField { text = " '" + field.stringValue.prefix(60) + "'" }
                if let button = view as? NSButton { text = " '" + button.title.prefix(60) + "'" }
                out.append(String(format: "%@ %.0f%@", name, view.fittingSize.width, text))
            }
            return
        }
        for child in wideChildren { collectWide(child, limit: limit, path: name, into: &out) }
    }
}
