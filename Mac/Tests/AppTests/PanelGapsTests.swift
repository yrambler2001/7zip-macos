// PanelGapsTests.swift -- the panel-side gaps of `Mac/docs/parity.md` "Unfinished" items 1, 5, 6 and
// 9, asserted in the app's own process (`SevenZipAppTests`, see AppHostTestCase):
//
//   * the 7-Zip block of the item context menu (01 §2.9) is backed by a handler for every verb it
//     shows, follows CZipContextMenu's needExtract rule, and its verbs run the real commands;
//   * IDM_DIFF 554 with one item selected in each of two panels (CApp::DiffFiles);
//   * Open Outside for an item inside an archive gets an archive context for exactly that row;
//   * drag and drop in the Large Icons / Small Icons / List modes (the NSCollectionView overlay);
//   * a drop on the window background compresses the *dropped* files (CompressDropFiles, 01 §3.15);
//   * View > Back / Forward keep their titles in a translation;
//   * the File-menu rules of 01 §2.1 that live on the window (Split / Combine / Link / Diff).
//
// No synthesized input: a context menu is built with `makeItemContextMenu()` and its item is sent
// the way AppKit would, to the first responder in the panel's chain that implements the action; a
// drag is the collection view's own delegate calls with a stub `NSDraggingInfo`.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class PanelGapsTests: AppHostTestCase {

    override var screenshotPrefix: String { "panelgaps" }

    private var controllers: [MainWindowController] = []
    private var scratchDirectories: [String] = []
    private var savedDiffPath = ""
    private var savedNumPanels = 1
    private var savedPanelPaths: [String?] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedDiffPath = Settings.diffPath
        savedNumPanels = Settings.numPanels
        savedPanelPaths = [Settings.panelPath(0), Settings.panelPath(1)]
    }

    override func tearDown() {
        for controller in controllers {
            controller.window?.toolbar = nil      // see PanelWindowlessErrorTests.tearDown
            controller.window?.close()
        }
        controllers = []
        for path in scratchDirectories { try? FileManager.default.removeItem(atPath: path) }
        scratchDirectories = []
        // A closing window saves its panels' paths (saveState), and those are the scratch folders
        // deleted just above: the next class's MainWindowController would restore them, fail to
        // bind, and greet its test with an error sheet that queues every later sheet behind it.
        for (i, path) in savedPanelPaths.enumerated() { Settings.setPanelPath(path, i) }
        Settings.diffPath = savedDiffPath
        Settings.numPanels = savedNumPanels
        super.tearDown()
    }

    // MARK: - fixtures

    /// A folder with an archive, a text file and a sub-folder.
    private func makeScratch(_ name: String) -> String {
        let path = (TestPaths.artifacts as NSString).appendingPathComponent("panelgaps-\(name)-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/dir", withIntermediateDirectories: true)
        try? fm.copyItem(atPath: TestPaths.fixtures + "/test.zip", toPath: path + "/arc.zip")
        fm.createFile(atPath: path + "/notes.txt", contents: Data("notes\n".utf8))
        scratchDirectories.append(path)
        return path
    }

    private func makeWindow(panels: Int) -> MainWindowController {
        Settings.numPanels = panels
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(NSSize(width: 1200, height: 800))
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        ActiveContext.register(controller)          // AppHostTestCase.tearDown puts the app's back
        return controller
    }

    private func navigate(_ panel: PanelViewController, to path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
    }

    private func select(_ panel: PanelViewController, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let index = panel.rows.firstIndex(where: { $0.name == name }) else {
            XCTFail("no row \(name) in \(panel.rows.map(\.name))", file: file, line: line)
            return
        }
        panel.setFocus(index)
    }

    /// The responder AppKit would send `action` to from the panel's list: the first one in the
    /// chain that implements it, then the app delegate.
    private func handler(for action: Selector, from panel: PanelViewController) -> NSObject? {
        var responder: NSResponder? = panel.tableView
        while let current = responder {
            if current.responds(to: action) { return current }
            responder = current.nextResponder
        }
        if let delegate = NSApp.delegate as? NSObject, delegate.responds(to: action) { return delegate }
        return nil
    }

    /// Send a menu item's action the way AppKit does, and report whether its validation enabled it.
    @discardableResult
    private func send(_ item: NSMenuItem, from panel: PanelViewController) -> Bool {
        guard let action = item.action, let target = handler(for: action, from: panel) else {
            XCTFail("nothing in the responder chain implements \(item.action.map(NSStringFromSelector) ?? "nil")")
            return false
        }
        if let validator = target as? NSMenuItemValidation, !validator.validateMenuItem(item) { return false }
        _ = target.perform(action, with: item)
        return true
    }

    private func sevenZipItems(_ menu: NSMenu) -> [NSMenuItem] {
        let verbs = Set(["sevenZipOpenArchive:", "sevenZipOpenArchiveAs:", "sevenZipExtractFiles:",
                         "sevenZipExtractHere:", "sevenZipExtractTo:", "sevenZipTestArchive:",
                         "sevenZipCompress:", "sevenZipCompressEmail:", "sevenZipCompressTo7z:",
                         "sevenZipCompressToZip:", "sevenZipCompressTo7zEmail:",
                         "sevenZipCompressToZipEmail:", "sevenZipChecksumCommand:", "fileCalculateHash:"])
        var found: [NSMenuItem] = []
        for item in menu.items {
            if let action = item.action, verbs.contains(NSStringFromSelector(action)) { found.append(item) }
            if let sub = item.submenu { found += sevenZipItems(sub) }
        }
        return found
    }

    private func titles(_ menu: NSMenu) -> [String] { menu.items.filter { !$0.isSeparatorItem }.map(\.title) }

    // MARK: - parity item 1: the context menu's 7-Zip verbs

    /// Every 7-Zip verb the menu shows has a handler, and validation leaves it enabled.
    func testEveryContextVerbHasAnEnabledHandler() {
        let savedFlags = Settings.contextMenuFlags
        defer { Settings.contextMenuFlags = savedFlags }
        Settings.contextMenuFlags = .all
        let scratch = makeScratch("verbs")
        let controller = makeWindow(panels: 1)
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        select(panel, "arc.zip")

        let menu = panel.makeItemContextMenu()
        let items = sevenZipItems(menu)
        // Open + 7 "Open archive >" types + Extract files / Here / To / Test + 5 Add-to verbs
        // (`Add to "arc.zip"` is the file's own name, so it is left out) + 11 hashes
        // + SHA-256 -> file + Test : Checksum
        XCTAssertEqual(items.count, 1 + 7 + 4 + 5 + 11 + 2, "menu: \(titles(menu))")
        for item in items {
            let action = item.action!
            guard let target = handler(for: action, from: panel) else {
                XCTFail("\(item.title) (\(NSStringFromSelector(action))) has no handler -- it would be grayed")
                continue
            }
            if let validator = target as? NSMenuItemValidation {
                XCTAssertTrue(validator.validateMenuItem(item), "\(item.title) is disabled")
            }
        }
        let shown = titles(menu)
        for title in ["Open archive", "Extract files...", "Extract Here", "Extract to \"arc/\"",
                      "Test archive", "Add to archive...", "Compress and email...",
                      "Add to \"arc.7z\"", "Compress to \"arc.7z\" and email",
                      "Compress to \"arc.zip\" and email"] {
            XCTAssertTrue(shown.contains(title), "missing \(title) in \(shown)")
        }
        XCTAssertFalse(shown.contains("Add to \"arc.zip\""),
                       "kCompressToZip is left out when arc.zip is the selected file (ContextMenu.cpp:973)")
    }

    /// needExtract (ContextMenu.cpp:797-825): a text file or a folder gets no Open / Extract / Test,
    /// several archives get `Extract to "*/"`.
    func testExtractVerbsFollowNeedExtract() {
        let savedFlags = Settings.contextMenuFlags
        defer { Settings.contextMenuFlags = savedFlags }
        Settings.contextMenuFlags = .all
        let scratch = makeScratch("needextract")
        try? FileManager.default.copyItem(atPath: scratch + "/arc.zip", toPath: scratch + "/arc2.zip")
        let controller = makeWindow(panels: 1)
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)

        select(panel, "notes.txt")
        var shown = titles(panel.makeItemContextMenu())
        XCTAssertFalse(shown.contains("Extract Here"), "a .txt is in kExtractExcludeExtensions: \(shown)")
        XCTAssertFalse(shown.contains("Open archive"))
        XCTAssertTrue(shown.contains("Add to archive..."))

        select(panel, "dir")
        shown = titles(panel.makeItemContextMenu())
        XCTAssertFalse(shown.contains("Test archive"), "a folder is never extracted: \(shown)")

        let a = panel.rows.firstIndex { $0.name == "arc.zip" }!
        let b = panel.rows.firstIndex { $0.name == "arc2.zip" }!
        panel.setSelectedIndexes(IndexSet([a, b]))
        shown = titles(panel.makeItemContextMenu())
        XCTAssertTrue(shown.contains("Extract to \"*/\""), "two archives: \(shown)")
        XCTAssertFalse(shown.contains("Open archive"), "Open is for a single file only")
    }

    /// Extract Here, Extract to "<name>/" and Add to "<name>.7z" run the real commands.
    func testContextVerbsRunTheCommands() {
        let scratch = makeScratch("run")
        let controller = makeWindow(panels: 1)
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        let fm = FileManager.default

        select(panel, "arc.zip")
        let extractTo = sevenZipItems(panel.makeItemContextMenu())
            .first { $0.action == #selector(PanelContextCommands.sevenZipExtractTo(_:)) }
        XCTAssertNotNil(extractTo)
        if let extractTo { XCTAssertTrue(send(extractTo, from: panel)) }
        XCTAssertTrue(wait(for: "arc/readme.txt") { fm.fileExists(atPath: scratch + "/arc/readme.txt") },
                      "Extract to \"arc/\" did not extract")

        let sub = scratch + "/here"
        try? fm.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try? fm.copyItem(atPath: scratch + "/arc.zip", toPath: sub + "/arc.zip")
        navigate(panel, to: sub)
        select(panel, "arc.zip")
        let here = sevenZipItems(panel.makeItemContextMenu())
            .first { $0.action == #selector(PanelContextCommands.sevenZipExtractHere(_:)) }
        if let here { XCTAssertTrue(send(here, from: panel)) } else { XCTFail("no Extract Here") }
        XCTAssertTrue(wait(for: "here/notes.md") { fm.fileExists(atPath: sub + "/notes.md") },
                      "Extract Here did not extract into the archive's folder")

        navigate(panel, to: scratch)
        select(panel, "notes.txt")
        let to7z = sevenZipItems(panel.makeItemContextMenu())
            .first { $0.action == #selector(PanelContextCommands.sevenZipCompressTo7z(_:)) }
        if let to7z { XCTAssertTrue(send(to7z, from: panel)) } else { XCTFail("no Add to \"notes.7z\"") }
        XCTAssertTrue(wait(for: "notes.7z") { fm.fileExists(atPath: scratch + "/notes.7z") },
                      "Add to \"notes.7z\" did not compress")
    }

    /// C12 / C13: `SHA-256 -> <name>.sha256` writes the checksum file next to the items, and
    /// `Test archive : Checksum` is offered for it.
    func testChecksumFileCommands() throws {
        let scratch = makeScratch("sha")
        let controller = makeWindow(panels: 1)
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        select(panel, "notes.txt")
        let items = sevenZipItems(panel.makeItemContextMenu())
            .filter { $0.action == #selector(PanelContextCommands.sevenZipChecksumCommand(_:)) }
        XCTAssertEqual(items.map(\.title), ["SHA-256 -> notes.txt.sha256", "Test archive : Checksum"])
        guard let generate = items.first else { return }
        XCTAssertTrue(send(generate, from: panel))
        let file = scratch + "/notes.txt.sha256"
        XCTAssertTrue(wait(for: "notes.txt.sha256") { FileManager.default.fileExists(atPath: file) })
        let text = try String(contentsOfFile: file, encoding: .utf8)
        // sha256("notes\n")
        XCTAssertTrue(text.contains("notes.txt"), text)
        XCTAssertTrue(text.lowercased().contains("444e0fffbd825e9610ff5b199485707a0c895339ae80c15cc8a8aee41b106fda"), text)

        select(panel, "dir")
        let dirItems = sevenZipItems(panel.makeItemContextMenu())
            .filter { $0.action == #selector(PanelContextCommands.sevenZipChecksumCommand(_:)) }
        XCTAssertEqual(dirItems.map(\.title), ["SHA-256 -> dir.sha256"], "C13 refuses directories")
    }

    /// kOpen binds the panel to the archive.
    func testOpenArchiveVerbBindsThePanel() {
        let scratch = makeScratch("open")
        let controller = makeWindow(panels: 1)
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        select(panel, "arc.zip")
        let open = sevenZipItems(panel.makeItemContextMenu())
            .first { $0.action == #selector(PanelContextCommands.sevenZipOpenArchive(_:)) }
        if let open { XCTAssertTrue(send(open, from: panel)) } else { XCTFail("no Open archive") }
        XCTAssertTrue(wait(for: "inside arc.zip") { panel.snapshot?.isArchive == true },
                      "Open archive did not bind the panel")
        XCTAssertTrue(panel.rows.contains { $0.name == "readme.txt" })
    }

    /// The right-clicked panel becomes the focused one, so ActiveContext names its items.
    func testContextMenuFocusesItsPanel() {
        let scratch = makeScratch("focus")
        let controller = makeWindow(panels: 2)
        navigate(controller.panels[0], to: TestPaths.fixtures)
        navigate(controller.panels[1], to: scratch)
        controller.setFocusedPanel(0)
        select(controller.panels[1], "arc.zip")
        _ = controller.panels[1].makeItemContextMenu()
        XCTAssertTrue(controller.focusedPanel === controller.panels[1])
        XCTAssertEqual(ActiveContext.current()?.names, ["arc.zip"])
    }

    // MARK: - parity item 5: Open Outside in an archive, Diff across two panels

    /// Open Outside inside an archive hands the extract scope's temp-open an archive context for
    /// exactly the row it opens (the old code refused with 6008).
    func testOpenOutsideContextForAnArchiveMember() {
        let scratch = makeScratch("outside")
        let controller = makeWindow(panels: 1)
        let panel = controller.focusedPanel
        navigate(panel, to: scratch + "/arc.zip")
        XCTAssertEqual(panel.snapshot?.isArchive, true)
        guard let index = panel.rows.firstIndex(where: { $0.name == "readme.txt" }) else {
            return XCTFail("no readme.txt in the archive")
        }
        let context = panel.operationContext(rowIndices: [index])
        XCTAssertEqual(context?.isArchive, true)
        XCTAssertEqual(context?.names, ["readme.txt"])
        XCTAssertEqual(context?.indices, [panel.rows[index].engineIndex])
        XCTAssertEqual(context?.paths, [], "an archive member has no file-system path")
        XCTAssertTrue(panel.isActionEnabled(#selector(PanelViewController.fileOpenOutside(_:))))
    }

    /// IDM_DIFF with one item selected in each panel runs the Diff tool on the two files; with
    /// nothing comparable selected in the other panel it uses the same relative path there.
    func testDiffAcrossTwoPanels() throws {
        let left = makeScratch("diff-left")
        let right = makeScratch("diff-right")
        FileManager.default.createFile(atPath: right + "/other.txt", contents: Data("x".utf8))
        let log = left + "/diff.log"
        let tool = left + "/difftool.sh"
        try "#!/bin/sh\nprintf '%s\\n' \"$1\" \"$2\" > \"\(log)\"\n".write(toFile: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool)
        Settings.diffPath = tool

        let controller = makeWindow(panels: 2)
        navigate(controller.panels[0], to: left)
        navigate(controller.panels[1], to: right)
        select(controller.panels[1], "other.txt")
        select(controller.panels[0], "notes.txt")
        controller.setFocusedPanel(0)

        XCTAssertEqual(controller.diffRequest(), .paths(left + "/notes.txt", right + "/other.txt"))
        controller.fileDiff(nil)
        XCTAssertTrue(wait(for: "diff tool ran") { FileManager.default.fileExists(atPath: log) })
        let lines = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [left + "/notes.txt", right + "/other.txt"])

        // The other panel's selection is ".." only: same relative path in its folder.
        controller.panels[1].setFocus(0)
        controller.panels[1].setSelectedIndexes(IndexSet())
        if controller.panels[1].diffSelectedRowIndices().count != 1 {
            XCTAssertEqual(controller.diffRequest(), .paths(left + "/notes.txt", right + "/notes.txt"))
        }

        // An archive on either side: MessageBox_Error_UnsupportOperation.
        navigate(controller.panels[1], to: right + "/arc.zip")
        controller.setFocusedPanel(0)
        XCTAssertEqual(controller.diffRequest(), .unsupported)
    }

    // MARK: - parity item 6: drag and drop in the icon modes, the background drop

    func testIconModesDragOutAndDropIn() {
        let scratch = makeScratch("dnd")
        let source = makeScratch("dnd-src")
        let controller = makeWindow(panels: 1)
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        for mode in 0...2 {
            panel.setListViewMode(mode)
            let iconView = panel.iconView!
            let cv = iconView.collectionView
            XCTAssertTrue(cv.registeredDraggedTypes.contains(.fileURL), "mode \(mode) accepts no file drop")

            // Drag-out of a file-system item is its file URL, as in Details view.
            let row = panel.rows.firstIndex { $0.name == "notes.txt" }!
            let writer = iconView.collectionView(cv, pasteboardWriterForItemAt: IndexPath(item: row, section: 0))
            XCTAssertEqual((writer as? NSURL)?.path, scratch + "/notes.txt", "mode \(mode)")
            if let parent = panel.rows.firstIndex(where: { $0.isParentRow }) {
                XCTAssertNil(iconView.collectionView(cv, pasteboardWriterForItemAt: IndexPath(item: parent, section: 0)))
            }
        }

        // Drop-in on a folder item copies into that folder; on the background into the panel's.
        let iconView = panel.iconView!
        let cv = iconView.collectionView
        let fileA = source + "/notes.txt"
        let info = StubDraggingInfo(urls: [URL(fileURLWithPath: fileA)])
        let dirRow = panel.rows.firstIndex { $0.name == "dir" }!
        var path = NSIndexPath(forItem: dirRow, inSection: 0)
        var op = NSCollectionView.DropOperation.on
        let effect = iconView.collectionView(cv, validateDrop: info, proposedIndexPath: &path, dropOperation: &op)
        XCTAssertFalse(effect.isEmpty, "a folder item refused the drop")
        XCTAssertEqual(op, .on)
        let optionCopy = iconView.collectionView(cv, acceptDrop: info, indexPath: IndexPath(item: dirRow, section: 0),
                                                 dropOperation: .on)
        XCTAssertTrue(optionCopy)
        XCTAssertTrue(wait(for: "dropped into dir") { FileManager.default.fileExists(atPath: scratch + "/dir/notes.txt") })

        // Background: a non-folder item proposes `.before`, i.e. the panel's own folder.
        FileManager.default.createFile(atPath: source + "/second.txt", contents: Data("2".utf8))
        let info2 = StubDraggingInfo(urls: [URL(fileURLWithPath: source + "/second.txt")])
        let fileRow = panel.rows.firstIndex { $0.name == "notes.txt" }!
        path = NSIndexPath(forItem: fileRow, inSection: 0)
        op = .on
        _ = iconView.collectionView(cv, validateDrop: info2, proposedIndexPath: &path, dropOperation: &op)
        XCTAssertEqual(op, .before, "a file item is not a drop target; the panel's folder is")
        XCTAssertTrue(iconView.collectionView(cv, acceptDrop: info2, indexPath: IndexPath(item: fileRow, section: 0),
                                              dropOperation: .before))
        XCTAssertTrue(wait(for: "dropped into the folder") { FileManager.default.fileExists(atPath: scratch + "/second.txt") })
        panel.setListViewMode(3)
    }

    /// Regression (`mac/uiverify`): in every icon mode the collection view's accessibility children
    /// are its items, each a Cell labelled with the item's name. AppKit alone exposed one section
    /// element with no children, so these modes were empty to VoiceOver and XCUITest.
    func testIconModeItemsAreAccessibilityCells() {
        let scratch = makeScratch("ax")
        let controller = makeWindow(panels: 1)
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        for mode in 0...2 {
            panel.setListViewMode(mode)
            let cv = panel.iconView.collectionView
            cv.layoutSubtreeIfNeeded()
            let children = (cv.accessibilityChildren() ?? []).compactMap { $0 as? NSView }
            let labels = children.compactMap { $0.isAccessibilityElement() ? $0.accessibilityLabel() : nil }
            XCTAssertEqual(Set(labels), Set(panel.rows.map(\.name)), "mode \(mode)")
            XCTAssertTrue(children.allSatisfy { $0.accessibilityRole() == .cell }, "mode \(mode)")
        }
        panel.setListViewMode(3)
    }

    /// Drag-out of an archive member from an icon mode is the same file promise as in Details.
    func testIconModeDragOutOfAnArchiveMemberIsAPromise() {
        let scratch = makeScratch("promise")
        let controller = makeWindow(panels: 1)
        let panel = controller.focusedPanel
        navigate(panel, to: scratch + "/arc.zip")
        panel.setListViewMode(1)
        defer { panel.setListViewMode(3) }
        let row = panel.rows.firstIndex { $0.name == "readme.txt" }!
        let iconView = panel.iconView!
        let writer = iconView.collectionView(iconView.collectionView, pasteboardWriterForItemAt: IndexPath(item: row, section: 0))
        let provider = writer as? NSFilePromiseProvider
        XCTAssertNotNil(provider, "an archive member must be dragged as a file promise")
        XCTAssertEqual((provider?.userInfo as? [String: Any])?["name"] as? String, "readme.txt")
    }

    /// CompressDropFiles: the dialog proposes an archive named after the *dropped* file, in that
    /// file's folder -- not after the panel's selection.
    func testBackgroundDropCompressesTheDroppedFiles() {
        let scratch = makeScratch("drop")
        // Not under the temp folder: names from there are redirected to the panel's folder
        // (AreThereNamesFromTemp), which is a different rule.
        let elsewhere = (TestPaths.repoRoot ?? NSHomeDirectory()) + "/Mac/build/panelgaps-drop-src-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        scratchDirectories.append(elsewhere)
        let dropped = elsewhere + "/dropped-file.txt"
        FileManager.default.createFile(atPath: dropped, contents: Data("d".utf8))
        let controller = makeWindow(panels: 1)
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        select(panel, "notes.txt")

        let context = panel.dropCompressContext(paths: [dropped])
        XCTAssertEqual(context?.paths, [dropped])
        XCTAssertEqual(context?.folderPath, elsewhere + "/")
        XCTAssertEqual(context?.isFileSystem, true)

        var proposed: [String] = []
        let shown = ModalProbe.present({
            _ = panel.compressDroppedFiles(info: StubDraggingInfo(urls: [URL(fileURLWithPath: dropped)]))
        }, inspect: { window in
            var stack: [NSView] = window.contentView.map { [$0] } ?? []
            while let view = stack.popLast() {
                if let combo = view as? NSComboBox { proposed.append(combo.stringValue) }
                stack += view.subviews
            }
        })
        XCTAssertTrue(shown, "the Add to Archive dialog did not open")
        // ... and a name from the temp folder makes the panel's folder the destination.
        let fromTemp = scratch + "/dir/notes-from-temp.txt"
        XCTAssertEqual(panel.dropCompressContext(paths: [fromTemp])?.folderPath, scratch + "/")
        XCTAssertTrue(proposed.contains { $0.contains("dropped-file") }, "archive name: \(proposed)")
        XCTAssertFalse(proposed.contains { $0.contains("notes") }, "the selection leaked in: \(proposed)")
    }

    // MARK: - requests.md (packaging -> panel): Back / Forward in a translation

    func testBackAndForwardKeepTheirTitlesInATranslation() {
        let savedServices = NSApp.servicesMenu
        defer { NSApp.servicesMenu = savedServices }
        useLanguage("de")
        let bar = MainMenu.build()
        var found: [Int: String] = [:]
        var stack = bar.items
        while let item = stack.popLast() {
            if item.tag == 780 || item.tag == 781 { found[item.tag] = item.title }
            if let sub = item.submenu { stack += sub.items }
        }
        XCTAssertEqual(found[780], "Back")
        XCTAssertEqual(found[781], "Forward")
    }

    // MARK: - parity item 9: File-menu rules that live on the window (01 §2.1)

    func testFileMenuRulesForSplitCombineLinkAndDiff() {
        let scratch = makeScratch("rules")
        let controller = makeWindow(panels: 1)
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)

        select(panel, "notes.txt")
        XCTAssertEqual(controller.fileMenuRule(#selector(MenuActions.fileSplit(_:))), true)
        XCTAssertEqual(controller.fileMenuRule(#selector(MenuActions.fileLink(_:))), true)
        select(panel, "dir")
        XCTAssertEqual(controller.fileMenuRule(#selector(MenuActions.fileSplit(_:))), false, "isOneFsFile")
        XCTAssertEqual(controller.fileMenuRule(#selector(MenuActions.fileCombine(_:))), false)

        let a = panel.rows.firstIndex { $0.name == "notes.txt" }!
        let b = panel.rows.firstIndex { $0.name == "arc.zip" }!
        panel.setSelectedIndexes(IndexSet([a, b]))
        XCTAssertEqual(controller.fileMenuRule(#selector(MenuActions.fileLink(_:))), false, "Link needs one item")

        let diff = NSMenuItem(title: "Diff", action: #selector(MenuActions.fileDiff(_:)), keyEquivalent: "")
        Settings.diffPath = ""
        _ = controller.validateMenuItem(diff)
        XCTAssertTrue(diff.isHidden, "IDM_DIFF is hidden without a Diff tool")
        Settings.diffPath = "/usr/bin/true"
        _ = controller.validateMenuItem(diff)
        XCTAssertFalse(diff.isHidden)

        navigate(panel, to: scratch + "/arc.zip")
        select(panel, "readme.txt")
        XCTAssertEqual(controller.fileMenuRule(#selector(MenuActions.fileSplit(_:))), false,
                       "Split is for a file-system file only")
    }
}

// MARK: - a drag without a mouse

/// The parts of `NSDraggingInfo` the panel reads: a pasteboard of file URLs, no source (an external
/// drag, as from Finder) and no modifier keys.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {

    private let pasteboard: NSPasteboard

    init(urls: [URL]) {
        pasteboard = NSPasteboard(name: NSPasteboard.Name("panelgaps-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        super.init()
    }

    deinit { pasteboard.releaseGlobally() }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
