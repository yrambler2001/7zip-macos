// NavGapsTests.swift -- the panel half of `mac/navgaps` (Mac/docs/reports/navgaps.md), in the app's
// own process (`SevenZipAppTests`, see AppHostTestCase):
//
//   * an archive whose inner level cannot be opened is entered, then the level text is shown
//     (CPanel::OpenAsArc, PanelItemOpen.cpp:512; PROGRESS 155);
//   * a wrong password is IDS_CANT_OPEN_ENCRYPTED_ARCHIVE 3006, a plain non-archive says nothing
//     (OpenAsArc_Msg, PanelItemOpen.cpp:528-564);
//   * the open runs under the "Opening" progress, and Cancel in its password dialog is silent
//     (CFfpOpen, COpenArchiveCallback; PROGRESS 153);
//   * the password belongs to the archive level (CFolderLink::Password; PROGRESS 168);
//   * the address bar binds the folder of a file that is not an archive (BindToPath);
//   * a failed command-line open shows "Error" and closes its window (FM.cpp:975-1014; PROGRESS 78).
//
// Modal dialogs (the password dialog, the app-modal launch box) are answered by a timer in the
// modal run-loop mode; panel errors are message boxes owned by the window (AppHostTestCase records them).

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

/// Answers modal windows while it runs: fills a password field when there is one, then clicks the
/// button the rule names. Records each window's texts and the titles of the other visible windows.
private final class ModalAnswerer {
    struct Seen { let text: String; let otherWindowTitles: [String] }
    private(set) var seen: [Seen] = []
    private let password: String?
    private let onlyPasswordDialogs: Bool
    private let button: (String) -> String
    private var timer: Timer?
    private var handled = Set<ObjectIdentifier>()

    init(password: String?, onlyPasswordDialogs: Bool, button: @escaping (String) -> String) {
        self.password = password
        self.onlyPasswordDialogs = onlyPasswordDialogs
        self.button = button
    }

    func start() {
        let t = Timer(timeInterval: 0.02, repeats: true) { [weak self] _ in self?.tick() }
        for mode: RunLoop.Mode in [.modalPanel, .default, .eventTracking] { RunLoop.main.add(t, forMode: mode) }
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let window = NSApp.modalWindow, window.isVisible,
              !handled.contains(ObjectIdentifier(window)) else { return }
        let fields = Self.views(of: NSTextField.self, in: window.contentView)
        let text = fields.map(\.stringValue).joined(separator: "\n")
        let secure = fields.compactMap { $0 as? NSSecureTextField }.filter { !$0.isHidden }
        // The "Opening" progress is a modal window too; only the password dialog is answered here.
        if onlyPasswordDialogs && secure.isEmpty { return }
        if let password, let field = secure.first { field.stringValue = password }
        let title = button(text)
        guard let target = Self.views(of: NSButton.self, in: window.contentView).first(where: { $0.title == title }) else { return }
        handled.insert(ObjectIdentifier(window))
        let others = NSApp.windows.filter { $0 !== window && $0.isVisible }.map(\.title)
        seen.append(Seen(text: text, otherWindowTitles: others))
        target.performClick(nil)
    }

    static func views<T: NSView>(of type: T.Type, in root: NSView?) -> [T] {
        guard let root else { return [] }
        var found: [T] = []
        if let match = root as? T { found.append(match) }
        for sub in root.subviews { found += views(of: type, in: sub) }
        return found
    }
}

final class NavGapsTests: AppHostTestCase {

    override var screenshotPrefix: String { "navgaps" }

    private var controllers: [MainWindowController] = []
    private var scratch = ""
    private var savedNumPanels = 1
    private var savedPanelPaths: [String?] = []
    private var answerer: ModalAnswerer?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedNumPanels = Settings.numPanels
        savedPanelPaths = [Settings.panelPath(0), Settings.panelPath(1)]
        scratch = (TestPaths.artifacts as NSString).appendingPathComponent("navgaps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        for name in ["test.7z", "secret.7z", "test.zip"] {
            try FileManager.default.copyItem(atPath: TestPaths.fixtures + "/" + name, toPath: scratch + "/" + name)
        }
        // off.zip: text in front of a zip -- no handler opens it ("Cannot open the file as [zip]").
        var off = Data("hello\n".utf8)
        off.append(try Data(contentsOf: URL(fileURLWithPath: scratch + "/test.zip")))
        try off.write(to: URL(fileURLWithPath: scratch + "/off.zip"))
        // v.7z.001/.002: a split set whose joined content is a broken 7z (NavGapsBridgeTests).
        var broken = try Data(contentsOf: URL(fileURLWithPath: scratch + "/test.7z")).prefix(40)
        broken.append(Data((0..<2000).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }))
        try Data(broken.prefix(1020)).write(to: URL(fileURLWithPath: scratch + "/v.7z.001"))
        try Data(broken.dropFirst(1020)).write(to: URL(fileURLWithPath: scratch + "/v.7z.002"))
    }

    override func tearDown() {
        for controller in controllers {
            if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
            controller.window?.toolbar = nil      // see PanelWindowlessErrorTests.tearDown
            controller.window?.close()
        }
        controllers = []
        answerer?.stop()
        answerer = nil
        try? FileManager.default.removeItem(atPath: scratch)
        // panel.md test hygiene: a closing window saved the scratch folder as PanelPath<N>.
        for (i, path) in savedPanelPaths.enumerated() { Settings.setPanelPath(path, i) }
        Settings.numPanels = savedNumPanels
        super.tearDown()
    }

    // MARK: - helpers

    private func makeWindow() -> MainWindowController {
        Settings.numPanels = 1
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(NSSize(width: 1000, height: 700))
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

    private func answer(password: String? = nil, onlyPasswordDialogs: Bool = false,
                        _ rule: @escaping (String) -> String) {
        let a = ModalAnswerer(password: password, onlyPasswordDialogs: onlyPasswordDialogs, button: rule)
        a.start()
        answerer = a
    }

    private func row(_ panel: PanelViewController, _ name: String) throws -> PanelRow {
        try XCTUnwrap(panel.rows.first { $0.name == name }, "no row \(name) in \(panel.rows.map(\.name))")
    }

    /// The text of the message box `window` owns (a sheet before recheck2), nil when there was none.
    private func sheetText(_ window: NSWindow?) -> String? {
        boxText(ownedBy: window)
    }

    /// Lets queued main-thread work run, then asserts nothing was presented.
    private func settle(_ seconds: TimeInterval = 0.8) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    private var ok: String { Lang.text(401, "OK") }

    // MARK: - open errors (PROGRESS 155)

    /// OpenAsArc enters the Split level and then shows ffp.ErrorMessage, the text of the 7z level
    /// that could not be opened.
    func testEnteringAnArchiveShowsTheNonOpenLevel() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        panel.openRow(try row(panel, "v.7z.001"), insideOnly: true, formatHint: nil)
        XCTAssertTrue(wait(for: "inside the split set") { panel.snapshot?.isArchive ?? false })
        XCTAssertTrue(wait(for: "the level text") { self.sheetText(controller.window) != nil })
        let text = try XCTUnwrap(sheetText(controller.window))
        XCTAssertTrue(text.contains("Cannot open the file as [7z] archive"), text)
        XCTAssertTrue(text.contains("v.7z"), text)
        XCTAssertEqual(panel.rows.filter { !$0.isParentRow }.map(\.name), ["v.7z"], "the panel entered the split level")
        _ = attach(try XCTUnwrap(controller.window), "navgaps-01-non-open-level")
    }

    /// OpenAsArc_Msg: a plain "not an archive" says nothing, and Open Inside then does nothing.
    func testOpenInsideANonArchiveIsSilent() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        panel.openRow(try row(panel, "off.zip"), insideOnly: true, formatHint: nil)
        settle()
        XCTAssertNil(sheetText(controller.window), "no box for S_FALSE")
        XCTAssertEqual(panel.snapshot?.isFileSystem, true)
    }

    // MARK: - passwords and the Opening progress (PROGRESS 153, 168)

    /// A wrong password is IDS_CANT_OPEN_ENCRYPTED_ARCHIVE; the password dialog sits on the
    /// "Opening" progress, which appeared because the open took longer than 500 ms.
    func testWrongPasswordIsTheEncryptedArchiveMessage() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        answer(password: "wrong", onlyPasswordDialogs: true) { _ in self.ok }
        panel.openRow(try row(panel, "secret.7z"), insideOnly: true, formatHint: nil)
        XCTAssertTrue(wait(for: "the encrypted-archive box") { self.sheetText(controller.window) != nil })
        let text = try XCTUnwrap(sheetText(controller.window))
        XCTAssertTrue(text.contains("Cannot open encrypted archive"), text)       // 3006
        XCTAssertTrue(text.contains("secret.7z"), text)
        XCTAssertEqual(panel.snapshot?.isFileSystem, true)
        let asked = try XCTUnwrap(answerer?.seen.first)
        let opening = Lang.text(3303, "Opening")
        XCTAssertTrue(asked.otherWindowTitles.contains { $0.contains(opening) && $0.contains("secret.7z") },
                      "the Opening progress was up: \(asked.otherWindowTitles)")
    }

    /// Cancel in the password dialog is E_ABORT: silent, and the panel stays where it was.
    func testCancelledOpenIsSilent() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        answer(onlyPasswordDialogs: true) { _ in Lang.text(402, "Cancel") }
        panel.openRow(try row(panel, "secret.7z"), insideOnly: true, formatHint: nil)
        XCTAssertTrue(wait(for: "the password dialog was answered") { !(self.answerer?.seen.isEmpty ?? true) })
        settle()
        XCTAssertNil(sheetText(controller.window))
        XCTAssertEqual(panel.snapshot?.isFileSystem, true)
        XCTAssertFalse(OperationRunner.hasActiveOperation)
    }

    /// The password stays with the level: kept inside it, gone outside, and never handed to an
    /// unrelated archive.
    func testThePasswordBelongsToTheArchiveLevel() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        answer(password: "secret", onlyPasswordDialogs: true) { _ in self.ok }
        panel.openRow(try row(panel, "secret.7z"), insideOnly: true, formatHint: nil)
        XCTAssertTrue(wait(for: "inside secret.7z") { panel.snapshot?.isArchive ?? false })
        XCTAssertEqual(panel.rememberedPassword, "secret")
        XCTAssertEqual(answerer?.seen.count, 1)
        // binding a path inside the same archive re-opens it without asking again
        navigate(panel, to: scratch + "/secret.7z/sub")
        XCTAssertEqual(panel.snapshot?.isArchive, true)
        XCTAssertEqual(answerer?.seen.count, 1, "the level lent its password to the re-open")
        XCTAssertEqual(panel.rememberedPassword, "secret")
        navigate(panel, to: scratch)
        XCTAssertNil(panel.rememberedPassword)
        navigate(panel, to: scratch + "/test.7z")
        XCTAssertNil(panel.rememberedPassword, "an unrelated archive gets no password")
    }

    // MARK: - BindToPath (address bar)

    /// A file on the path that is not an archive binds its folder, silently (OpenAsArc without _Msg).
    func testAddressBarFileThatIsNotAnArchiveBindsItsFolder() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: NSHomeDirectory())
        navigate(panel, to: scratch + "/off.zip")
        settle()
        XCTAssertNil(sheetText(controller.window))
        XCTAssertEqual(panel.snapshot?.isFileSystem, true)
        XCTAssertEqual(panel.currentPath, scratch + "/")
    }

    // MARK: - the command-line open (PROGRESS 78)

    /// FM.cpp:997-1014: "Cannot open file '<path>' as archive" plus the level text, then the window
    /// is gone (WM_CREATE returns -1).
    func testFailedLaunchOpenShowsErrorAndClosesItsWindow() throws {
        let controller = makeWindow()
        answer { _ in self.ok }
        let path = scratch + "/off.zip"
        controller.openStartupPath(path, formatHint: nil, closesWindowOnFailure: true)
        XCTAssertTrue(wait(for: "the Error box") { !(self.answerer?.seen.isEmpty ?? true) })
        let text = try XCTUnwrap(answerer?.seen.first?.text)
        XCTAssertTrue(text.contains("Cannot open file '\(path)' as archive"), text)   // 3005
        XCTAssertTrue(text.contains("[zip]"), text)
        XCTAssertTrue(wait(for: "the window closed") { !(controller.window?.isVisible ?? false) })
    }

    /// Opening a file in a window that already shows something: the box is a sheet and the window
    /// keeps its folder.
    func testFailedOpenInAnExistingWindowKeepsIt() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        controller.openStartupPath(scratch + "/off.zip", formatHint: nil, closesWindowOnFailure: false)
        XCTAssertTrue(wait(for: "the Error sheet") { self.sheetText(controller.window) != nil })
        XCTAssertTrue(controller.window?.isVisible ?? false)
        XCTAssertEqual(panel.currentPath, scratch + "/")
    }

    func testLaunchOpenEntersTheArchiveWithItsFormatHint() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        controller.openStartupPath(scratch + "/test.7z", formatHint: "7z", closesWindowOnFailure: true)
        XCTAssertTrue(wait(for: "inside test.7z") { panel.snapshot?.isArchive ?? false })
        XCTAssertTrue(controller.window?.isVisible ?? false)
    }

    /// BindToPath's walk up: a path that does not exist shows its nearest existing folder.
    func testLaunchPathThatDoesNotExistBindsTheNearestFolder() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        controller.openStartupPath(scratch + "/missing/deeper", formatHint: nil, closesWindowOnFailure: true)
        XCTAssertTrue(wait(for: "the scratch folder") { panel.currentPath == self.scratch + "/" })
        XCTAssertNil(sheetText(controller.window))
    }

    // MARK: - window chrome (PROGRESS 81, 83, 108)

    /// Refresh_StatusBar's four parts at the right edges {220, 320, 420, rest}.
    func testStatusBarHasFourSections() throws {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        panel.selectAll(true)
        XCTAssertTrue(wait(for: "status") { panel.statusBarTexts[0].contains("/") })
        let texts = panel.statusBarTexts
        XCTAssertEqual(texts.count, 4)
        XCTAssertTrue(Bidi.stripped(texts[0]).contains("\(panel.rows.filter { !$0.isParentRow }.count) / "), texts[0])
        XCTAssertFalse(texts[1].isEmpty, "the selected size")
        XCTAssertFalse(texts[3].isEmpty, "the focused item's time")
        // SetParts {220, 320, 420, -1}; datecols widened the two size parts for SF Pro.
        XCTAssertEqual(PanelViewController.statusSectionEdges, PanelMetrics.statusSectionEdges)
        XCTAssertEqual(PanelViewController.statusSectionEdges.first, 220)
        _ = attach(try XCTUnwrap(controller.window), "navgaps-02-status-sections")
    }

    /// The 7-Zip toolbar bitmaps, large and small; no toolbar at all when both are off; a 4 pt splitter.
    func testToolbarBitmapsAndVisibility() throws {
        let savedMask = Settings.toolbarsMask
        defer { Settings.toolbarsMask = savedMask }
        Settings.toolbarsMask = 0xF
        let controller = makeWindow()
        for id in [NSToolbarItem.Identifier.szAdd, .szExtract, .szTest, .szCopy, .szMove, .szDelete, .szInfo] {
            let large = try XCTUnwrap(MainWindowController.toolbarBitmap(id, large: true), "\(id)")
            let small = try XCTUnwrap(MainWindowController.toolbarBitmap(id, large: false), "\(id)")
            XCTAssertEqual(large.size, NSSize(width: 48, height: 36))
            XCTAssertEqual(small.size, NSSize(width: 24, height: 24))
        }
        // The 7zFM strip (FMToolbar.swift, winmatch): the button size follows the bitmap size.
        let toolbar = controller.toolbarView
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        XCTAssertFalse(toolbar.isHidden)
        XCTAssertEqual(toolbar.buttonSize.height, 36 + 6 + 16, "Large Buttons is on")
        _ = attach(try XCTUnwrap(controller.window), "navgaps-03-toolbar-bitmaps")
        controller.viewToolbarsLargeButtons(nil)
        XCTAssertEqual(toolbar.buttonSize.height, 24 + 6 + 16)
        controller.viewArchiveToolbar(nil)
        controller.viewStandardToolbar(nil)
        XCTAssertTrue(toolbar.isHidden, "no logical toolbar, no toolbar")
        controller.viewStandardToolbar(nil)
        XCTAssertFalse(toolbar.isHidden)
        XCTAssertEqual(PanelSplitView().dividerThickness, 4)
    }

    // MARK: - Ver Edit / Commit / Revert / Diff (PROGRESS 94, 01 §2.1 rows 22-25)

    func testVersionControlCycle() throws {
        let fm = FileManager.default
        let store = scratch + "/vc"
        let dir = scratch + "/work"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let file = dir + "/a.txt"
        try Data("one\n".utf8).write(to: URL(fileURLWithPath: file))
        try fm.setAttributes([.posixPermissions: 0o444,
                              .modificationDate: Date(timeIntervalSince1970: 1_577_836_800)], ofItemAtPath: file)  // 2020
        let stored = VersionControl.storedPath(of: file, store: store)
        XCTAssertEqual(stored, store + dir + "/a.txt")

        XCTAssertEqual(VersionControl.menuCommands(forFile: file, diffPath: "", store: store), [], "no Diff tool, no items")
        XCTAssertEqual(VersionControl.menuCommands(forFile: file, diffPath: "/usr/bin/opendiff", store: store), [.edit])
        let never: (VersionControl.FileState, VersionControl.FileState, String) -> Bool = { _, _, _ in XCTFail("no question"); return false }

        // Edit: the file is stored and becomes writable
        XCTAssertEqual(VersionControl.run(.commit, path: file, store: store, askRevert: never), .error("File is read-only"))
        XCTAssertEqual(VersionControl.run(.edit, path: file, store: store, askRevert: never), .done)
        XCTAssertEqual(fm.contents(atPath: stored), Data("one\n".utf8))
        XCTAssertEqual(VersionControl.menuCommands(forFile: file, diffPath: "x", store: store), [.commit, .revert, .diff])

        // Commit: read-only again, the time rounded to a whole step
        try Data("two\n".utf8).write(to: URL(fileURLWithPath: file))
        XCTAssertEqual(VersionControl.run(.diff, path: file, store: store, askRevert: never), .diff(stored: stored, current: file))
        XCTAssertEqual(VersionControl.run(.commit, path: file, store: store, askRevert: never), .done)
        let committed = try XCTUnwrap(fm.attributesOfItem(atPath: file)[.modificationDate] as? Date).timeIntervalSince1970
        XCTAssertEqual(committed.truncatingRemainder(dividingBy: 3600), 0, "rounded down to the hour: still newer than 2020")
        XCTAssertEqual(VersionControl.menuCommands(forFile: file, diffPath: "x", store: store), [.edit])

        // Edit again: the old stored version moves to _7vc/a.txt/001
        XCTAssertEqual(VersionControl.run(.edit, path: file, store: store, askRevert: never), .done)
        let history = (stored as NSString).deletingLastPathComponent + "/_7vc/a.txt/001"
        XCTAssertEqual(fm.contents(atPath: history), Data("one\n".utf8))
        XCTAssertEqual(fm.contents(atPath: stored), Data("two\n".utf8))

        // Revert after a change: asked, then the stored version is back, read-only
        try Data("three\n".utf8).write(to: URL(fileURLWithPath: file))
        var asked = 0
        XCTAssertEqual(VersionControl.run(.revert, path: file, store: store) { _, _, _ in asked += 1; return false }, .declined)
        XCTAssertEqual(VersionControl.run(.revert, path: file, store: store) { _, _, _ in asked += 1; return true }, .done)
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(fm.contents(atPath: file), Data("two\n".utf8))
        XCTAssertEqual(VersionControl.menuCommands(forFile: file, diffPath: "x", store: store), [.edit])
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file)
    }
}
