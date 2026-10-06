// ArchGapsTests.swift -- the archive-engine gaps of `ai/parity.md` "Unfinished" items 7 and
// 13, asserted in the app's own process (`SevenZipAppTests`, see AppHostTestCase):
//
//   * raw properties (IArchiveGetRawProps) are panel columns and Properties lines (01 §3.2, §3.11);
//   * leaving a modified nested archive writes it back into its parent -- going up, binding another
//     path -- with the 3009 question, and a refused, failed or read-only write-back never touches
//     the parent and keeps the modified copy (01 §3.8, CloseOneLevel / OpenParentArchiveFolder).
//
// The questions are app-modal NSAlerts; `AlertAnswerer` clicks the scripted button from a timer
// in the modal run-loop mode, so no synthesized input is needed.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

/// Answers the app-modal alerts that come up while it runs, and records their texts.
private final class AlertAnswerer {
    private(set) var seen: [String] = []
    private let answer: (String) -> String
    private var timer: Timer?
    private var handled = Set<ObjectIdentifier>()

    init(answer: @escaping (String) -> String) { self.answer = answer }

    func start() {
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.tick() }
        for mode: RunLoop.Mode in [.modalPanel, .default, .eventTracking] { RunLoop.main.add(t, forMode: mode) }
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let window = NSApp.modalWindow, window.isVisible,
              !handled.contains(ObjectIdentifier(window)) else { return }
        let texts = Self.views(of: NSTextField.self, in: window.contentView).map(\.stringValue)
        let buttons = Self.views(of: NSButton.self, in: window.contentView)
        let text = texts.joined(separator: "\n")
        let title = answer(text)
        guard let button = buttons.first(where: { $0.title == title }) else { return }
        handled.insert(ObjectIdentifier(window))
        seen.append(text)
        button.performClick(nil)
    }

    private static func views<T: NSView>(of type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        var found: [T] = []
        if let match = root as? T { found.append(match) }
        for sub in root.subviews { found += views(of: type, in: sub) }
        return found
    }
}

/// A drop with nothing on the pasteboard: the in-process drag session names the source.
private final class EmptyDraggingInfo: NSObject, NSDraggingInfo {
    private let pasteboard = NSPasteboard(name: NSPasteboard.Name("archgaps-\(UUID().uuidString)"))
    deinit { pasteboard.releaseGlobally() }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.copy] }
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

final class ArchGapsTests: AppHostTestCase {

    override var screenshotPrefix: String { "archgaps" }

    private var controllers: [MainWindowController] = []
    private var scratch = ""
    private var savedNumPanels = 1
    private var savedPanelPaths: [String?] = []
    private var answerer: AlertAnswerer?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedNumPanels = Settings.numPanels
        savedPanelPaths = [Settings.panelPath(0), Settings.panelPath(1)]
        scratch = (TestPaths.artifacts as NSString).appendingPathComponent("archgaps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        for name in ["nested.zip", "test.wim", "test.xar"] {
            try FileManager.default.copyItem(atPath: TestPaths.fixtures + "/" + name, toPath: scratch + "/" + name)
        }
    }

    override func tearDown() {
        for controller in controllers {
            controller.window?.toolbar = nil      // see PanelWindowlessErrorTests.tearDown
            controller.window?.close()
        }
        controllers = []
        answerer?.stop()
        answerer = nil
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: scratch + "/nested.zip")
        try? FileManager.default.removeItem(atPath: scratch)
        // panel.md test hygiene: a closing window saved the scratch folder as PanelPath<N>.
        for (i, path) in savedPanelPaths.enumerated() { Settings.setPanelPath(path, i) }
        Settings.numPanels = savedNumPanels
        super.tearDown()
    }

    // MARK: - helpers

    private func makePanel() -> PanelViewController { makeWindow(panels: 1).focusedPanel }

    private func makeWindow(panels: Int) -> MainWindowController {
        Settings.numPanels = panels
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(NSSize(width: 1200, height: 800))
        controller.showWindow(nil)
        controller.window?.layoutIfNeeded()
        ActiveContext.register(controller)
        return controller
    }

    private func navigate(_ panel: PanelViewController, to path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
    }

    private func answer(_ rule: @escaping (String) -> String) {
        let a = AlertAnswerer(answer: rule)
        a.start()
        answerer = a
    }

    private func row(_ panel: PanelViewController, _ name: String) throws -> PanelRow {
        try XCTUnwrap(panel.rows.first { $0.name == name }, "no row \(name) in \(panel.rows.map(\.name))")
    }

    /// Enters nested.zip/test.7z (a temp copy: a zip member has no seekable stream).
    private func enterNested(_ panel: PanelViewController) throws {
        navigate(panel, to: scratch + "/nested.zip")
        panel.openRow(try row(panel, "test.7z"), insideOnly: true, formatHint: nil)
        XCTAssertTrue(wait(for: "inside test.7z") { panel.snapshot?.fullPath.contains("test.7z") ?? false })
    }

    /// What an Edit round does to the nested copy: readme.txt replaced inside it.
    private func editNested(_ panel: PanelViewController, text: String) throws {
        let file = scratch + "/readme.txt"
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        var failure: Error?
        panel.queue.sync {
            do {
                let folder = try XCTUnwrap(panel.folder)
                let index = try XCTUnwrap((0..<folder.itemCount).first { folder.nameOfItem(at: $0) == "readme.txt" })
                try SZTempOpen.updateItem(at: index, of: folder, fromFilePath: file, progress: nil)
            } catch { failure = error }
        }
        if let failure { throw failure }
        XCTAssertTrue(panel.queue.sync { panel.folder?.archive?.tempFileWasChanged ?? false })
    }

    /// readme.txt of test.7z inside nested.zip as it is on disk now.
    private func readmeOnDisk() throws -> String {
        let inner = try SZFolder.folder(forPath: scratch + "/nested.zip/test.7z", passwordDelegate: nil)
        let index = try XCTUnwrap((0..<inner.itemCount).first { inner.nameOfItem(at: $0) == "readme.txt" })
        let temp = try SZTempOpen.extractItem(at: index, of: inner, archiveFilePath: nil, archiveLevelCount: 2,
                                              zoneMode: .none, progress: nil)
        defer { SZTempOpen.removeTemporaryDirectory(atPath: temp.directoryPath) }
        return try String(contentsOfFile: temp.filePath, encoding: .utf8)
    }

    private static let modifiedQuestion = "was modified"

    // MARK: - raw properties (parity D 7)

    func testRawPropertiesAreColumnsAndPropertiesLines() throws {
        let panel = makePanel()
        navigate(panel, to: scratch + "/test.wim")
        let column = try XCTUnwrap(panel.columnsModel.columns.first { $0.propID == .sha1 }, "SHA-1 column")
        XCTAssertTrue(column.visible)
        XCTAssertFalse(panel.columnsModel.columns.contains { $0.propID == .ntSecure }, "NT security hidden")
        let readme = try row(panel, "readme.txt")
        XCTAssertEqual(readme.cells[.sha1], "6e2988371ac7aef631f90a38c9d022794bd8df14")
        XCTAssertEqual(try row(panel, "sub").cells[.sha1], "")

        // Properties (IDM_PROPERTIES 551): the raw line after the folder's own properties
        let snapshot = try XCTUnwrap(panel.snapshot)
        let lines = panel.queue.sync { () -> PanelPropertyLines in
            PanelProperties.build(folder: panel.folder!, itemIndices: [readme.engineIndex],
                                  snapshot: snapshot, level: .min)
        }
        let sha = try XCTUnwrap(lines.names.firstIndex(of: "SHA-1"), "\(lines.names)")
        XCTAssertEqual(lines.values[sha], "6e2988371ac7aef631f90a38c9d022794bd8df14")
        XCTAssertGreaterThan(sha, try XCTUnwrap(lines.names.firstIndex(of: "Size")))

        // sorting by the raw column goes through the folder's raw comparison (CompareItems2)
        panel.sort(by: .sha1, toggle: true)
        XCTAssertEqual(panel.columnsModel.sortID, .sha1)
        let fileHashes = { panel.rows.filter { !$0.isDirectory }.map { $0.cells[.sha1] ?? "" } }
        XCTAssertTrue(wait(for: "sorted by SHA-1") { fileHashes() == fileHashes().sorted(by: { panel.columnsModel.ascending ? $0 < $1 : $0 > $1 }) },
                      "\(fileHashes())")

        navigate(panel, to: scratch + "/test.xar")
        XCTAssertEqual(try row(panel, "readme.txt").cells[.checksum], "6e2988371ac7aef631f90a38c9d022794bd8df14")
        if let window = panel.view.window { _ = attach(window, "archgaps-01-xar-checksum-column") }
    }

    // MARK: - nested write-back (parity D 13)

    func testGoingUpWritesTheModifiedNestedArchiveBack() throws {
        let panel = makePanel()
        answer { $0.contains(Self.modifiedQuestion) ? Lang.text(406, "Yes") : Lang.text(401, "OK") }
        try enterNested(panel)
        try editNested(panel, text: "edited in the panel\n")
        panel.goUp()
        XCTAssertTrue(wait(for: "back in nested.zip") { panel.snapshot?.fullPath.hasSuffix("nested.zip/") ?? false })
        XCTAssertEqual(answerer?.seen.filter { $0.contains(Self.modifiedQuestion) }.count, 1, "\(answerer?.seen ?? [])")
        XCTAssertTrue(answerer?.seen.first?.contains("test.7z") ?? false)
        XCTAssertEqual(try readmeOnDisk(), "edited in the panel\n")
        XCTAssertNotNil(panel.rows.first { $0.name == "test.7z" }, "the parent was reloaded in place")
    }

    func testBindingAnotherPathWritesBackFirst() throws {
        let panel = makePanel()
        answer { $0.contains(Self.modifiedQuestion) ? Lang.text(406, "Yes") : Lang.text(401, "OK") }
        try enterNested(panel)
        try editNested(panel, text: "written back before the bind\n")
        navigate(panel, to: scratch)
        XCTAssertEqual(answerer?.seen.count, 1)
        XCTAssertEqual(try readmeOnDisk(), "written back before the bind\n")
        // re-entering through the path sees the updated parent
        navigate(panel, to: scratch + "/nested.zip/test.7z")
        XCTAssertNotNil(panel.rows.first { $0.name == "readme.txt" && $0.size == 29 })
    }

    func testUnchangedNestedArchiveAsksNothing() throws {
        let panel = makePanel()
        answer { _ in Lang.text(406, "Yes") }
        try enterNested(panel)
        panel.goUp()
        XCTAssertTrue(wait(for: "back in nested.zip") { panel.snapshot?.fullPath.hasSuffix("nested.zip/") ?? false })
        XCTAssertEqual(answerer?.seen ?? [], [])
    }

    func testNoLeavesTheParentUntouched() throws {
        let before = try Data(contentsOf: URL(fileURLWithPath: scratch + "/nested.zip"))
        let panel = makePanel()
        answer { $0.contains(Self.modifiedQuestion) ? Lang.text(407, "No") : Lang.text(401, "OK") }
        try enterNested(panel)
        try editNested(panel, text: "discarded\n")
        panel.goUp()
        XCTAssertTrue(wait(for: "back in nested.zip") { panel.snapshot?.fullPath.hasSuffix("nested.zip/") ?? false })
        XCTAssertEqual(answerer?.seen.count, 1)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: scratch + "/nested.zip")), before)
    }

    func testFailedWriteBackKeepsTheCopyAndTheParent() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: scratch + "/nested.zip")
        let before = try Data(contentsOf: URL(fileURLWithPath: scratch + "/nested.zip"))
        let panel = makePanel()
        answer { $0.contains(Self.modifiedQuestion) ? Lang.text(406, "Yes") : Lang.text(401, "OK") }
        try enterNested(panel)
        try editNested(panel, text: "nowhere to go\n")
        let copy = try XCTUnwrap(panel.queue.sync { panel.folder?.archive?.tempFilePath })
        panel.goUp()
        XCTAssertTrue(wait(for: "back in nested.zip") { panel.snapshot?.fullPath.hasSuffix("nested.zip/") ?? false })
        XCTAssertTrue(wait(for: "IDS_CANNOT_UPDATE_FILE") { self.answerer?.seen.contains { $0.contains(copy) } ?? false },
                      "\(answerer?.seen ?? [])")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: scratch + "/nested.zip")), before, "parent untouched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy), "the modified copy is kept")
        try? FileManager.default.removeItem(atPath: (copy as NSString).deletingLastPathComponent)
    }

    // MARK: - smaller gaps found by the audit

    /// PROGRESS §2.3 (168): CFolderLink::Password is per archive level (`mac/navgaps`). A level
    /// keeps its own password while the panel moves inside it, a nested level starts without one,
    /// and the file system has none.
    func testRememberedPasswordIsPerArchiveLevel() throws {
        let panel = makePanel()
        navigate(panel, to: scratch + "/nested.zip")
        panel.rememberedPassword = "outer"
        navigate(panel, to: scratch + "/nested.zip/test.7z")     // a new chain: closed and reopened
        XCTAssertNil(panel.rememberedPassword, "the nested level has its own (no) password")
        panel.rememberedPassword = "inner"
        panel.goUp()                                              // still inside nested.zip
        XCTAssertTrue(wait(for: "back in nested.zip") { panel.snapshot?.fullPath.hasSuffix("nested.zip/") ?? false })
        XCTAssertEqual(panel.rememberedPassword, "outer", "the re-bound outer level kept its password")
        panel.goUp()                                              // out of every archive
        XCTAssertTrue(wait(for: "in the scratch folder") { panel.snapshot?.isFileSystem ?? false })
        XCTAssertNil(panel.rememberedPassword)
    }

    /// PROGRESS §4.7: archive members dropped on an archive panel are added through a 7zE folder.
    func testDropFromOneArchiveIntoAnother() throws {
        let controller = makeWindow(panels: 2)
        let target = controller.panels[0], source = controller.panels[1]
        answer { _ in Lang.text(406, "Yes") }                     // 6011 "copy files to archive"
        navigate(target, to: scratch + "/nested.zip")
        navigate(source, to: scratch + "/test.xar")
        let index = try XCTUnwrap(source.rows.firstIndex { $0.name == "readme.txt" })
        PanelDragDrop.current = PanelDragDrop.Session(panel: source, rowIndices: [index],
                                                     isArchiveSource: true, tempDirectory: nil)
        defer { PanelDragDrop.current = nil }
        XCTAssertTrue(target.acceptListDrop(info: EmptyDraggingInfo(), proposedRow: -1))
        let outer = try SZFolder.folder(forPath: scratch + "/nested.zip", passwordDelegate: nil)
        let names = (0..<outer.itemCount).map { outer.nameOfItem(at: $0) }
        XCTAssertTrue(names.contains("readme.txt"), "\(names)")
        XCTAssertTrue(names.contains("test.7z"))
    }
}
