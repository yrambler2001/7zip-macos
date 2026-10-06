// FinderContextMenuTests.swift -- Finder's **own** context menu, driven end to end (finderfix).
//
// `FinderIntegrationTests` sends the `sevenzip://` URLs the extensions build; this file checks that
// the extensions actually build and deliver them when the user clicks. That is where the shipped
// bug was: the 7-Zip submenu appeared in Finder but "Open archive", "Add to archive..." and the
// "Extract with 7-Zip" Quick Action did nothing (Mac/docs/reports/finderfix.md):
//  * Finder copies the extension's menu and drops `representedObject`, so the Finder Sync action
//    found no command and returned;
//  * Finder hands a Quick Action an attachment typed `public.zip-archive` only, never
//    `public.file-url`, so the Quick Action found no file and returned.
//
// How Finder is driven without Automation permission: XCUITest reaches any app through the
// accessibility channel the test runner already has. A real right-click opens the context menu;
// submenus are entered with the arrow keys and an item is chosen with Return (synthesized hovers
// do not open Finder's submenus). The file is revealed with
// `NSWorkspace.activateFileViewerSelecting`, which is a Launch Services call, not an Apple event.
//
// Which 7-Zip answers is whichever copy's extension Finder runs (normally the installed
// /Applications/7-Zip.app; `pluginkit -m -v -i com.yrambler2001.7zip.FinderSync` shows it). The
// extension now aims its URL at its own containing app, so the app that reacts is that copy. When
// the Finder extension is switched off the menu has no "7-Zip" item and the tests are skipped, not
// failed: that is a machine setting, not a regression.
//
// Parity references: 03-shell-integration-inventory.md sections 1.4 (the menu items), 6.1 (the
// Quick Actions), 6.4 (the URL hand-off).

import AppKit
import XCTest

final class FinderContextMenuTests: XCTestCase {

    private let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
    /// The shipping identifier. Several copies may carry it (this target's Debug app, the
    /// installed one), so a query goes to the copy that is actually running, by its URL.
    private static let appID = "com.yrambler2001.7zip"

    /// The running 7-Zip the command reached; nil until one is running.
    private func runningSevenZip(timeout: TimeInterval = 30) -> XCUIApplication? {
        var found: URL?
        waitFor(timeout) {
            found = NSRunningApplication.runningApplications(withBundleIdentifier: Self.appID)
                .first?.bundleURL
            return found != nil
        }
        return found.map { XCUIApplication(url: $0) }
    }

    private func terminateSevenZip() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Self.appID) {
            app.forceTerminate()
        }
        waitFor(10) { NSRunningApplication.runningApplications(withBundleIdentifier: Self.appID).isEmpty }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
        // A clean slate: no 7-Zip left over with a modal dialog that would queue the next URL.
        terminateSevenZip()
    }

    override func tearDown() {
        // Close what the commands opened (dialogs, archive windows) and the Finder windows.
        terminateSevenZip()
        finder.typeKey("w", modifierFlags: [.command, .option])
        super.tearDown()
    }

    // MARK: - Fixtures

    private func makeFolder() throws -> String {
        let dir = (TestPaths.artifacts as NSString)
            .appendingPathComponent("finderfix-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    private func makeZip() throws -> String {
        let zip = (try makeFolder() as NSString).appendingPathComponent("probe.zip")
        try FileManager.default.copyItem(atPath: TestPaths.fixture("test.zip"), toPath: zip)
        return zip
    }

    private func makeTextFile() throws -> String {
        let file = (try makeFolder() as NSString).appendingPathComponent("probe-notes.txt")
        try Data("finderfix\n".utf8).write(to: URL(fileURLWithPath: file))
        return file
    }

    // MARK: - Driving Finder

    /// Reveals `path` in a fresh Finder window and right-clicks it.
    private func openContextMenu(on path: String) throws {
        finder.activate()
        finder.typeKey("w", modifierFlags: [.command, .option])
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        finder.activate()
        let name = (path as NSString).lastPathComponent
        let item = finder.windows.firstMatch.descendants(matching: .any)
            .matching(NSPredicate(format: "value == %@", name)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "Finder did not show \(name)")
        item.rightClick()
        XCTAssertTrue(waitFor(10) { self.contextMenu() != nil }, "the context menu did not open")
    }

    /// The open context menu: the visible menu that has a "Get Info" item.
    private func contextMenu() -> XCUIElementSnapshot? {
        for menu in finder.menus.allElementsBoundByIndex {
            guard let snap = try? menu.snapshot(), snap.frame.width > 0 else { continue }
            if snap.children.contains(where: { $0.title == "Get Info" && $0.frame.width > 0 }) {
                return snap
            }
        }
        return nil
    }

    /// The selectable rows of a menu, top to bottom: visible, titled, enabled items, one per row
    /// (an alternate such as "Always Open With" shares its row with "Open With").
    private func rows(of menu: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        var seen = Set<Int>()
        return menu.children
            .filter { $0.elementType == .menuItem && $0.frame.width > 0 && !$0.title.isEmpty }
            .sorted { $0.frame.minY < $1.frame.minY }
            .filter { seen.insert(Int($0.frame.minY)).inserted && $0.isEnabled }
    }

    /// Chooses `item` inside the context menu's submenu `submenu` with the keyboard: Up from no
    /// selection starts at the bottom row, Right enters the submenu at its first row, Down walks to
    /// the item, Return invokes it -- what a user does with the arrow keys.
    /// Returns false (and closes the menu) when the context menu has no `submenu` row.
    private func choose(_ item: String, in submenu: String) -> Bool {
        guard let menu = contextMenu() else { return false }
        let top = rows(of: menu)
        guard let index = top.firstIndex(where: { $0.title == submenu }) else {
            finder.typeKey(.escape, modifierFlags: [])
            return false
        }
        for _ in index..<top.count { finder.typeKey(.upArrow, modifierFlags: []) }
        finder.typeKey(.rightArrow, modifierFlags: [])

        var children: [XCUIElementSnapshot] = []
        _ = waitFor(10) {
            for menu in self.finder.menus.allElementsBoundByIndex {
                guard let snap = try? menu.snapshot(), snap.frame.width > 0 else { continue }
                let r = self.rows(of: snap)
                if r.first?.isSelected == true, r.contains(where: { $0.title == item })
                    || (r.first?.isSelected == true && snap.frame.minX > 0 && !r.contains { $0.title == "Get Info" }) {
                    children = r
                    return true
                }
            }
            return false
        }
        guard let target = children.firstIndex(where: { $0.title == item }) else {
            XCTFail("the \(submenu) submenu has no \(item) item: \(children.map(\.title))")
            return false
        }
        for _ in 0..<target { finder.typeKey(.downArrow, modifierFlags: []) }
        attach("menu-\(item.filter { $0.isLetter || $0.isNumber })")
        finder.typeKey(.return, modifierFlags: [])
        return true
    }

    /// Skips when Finder offers no 7-Zip submenu (the extension is switched off on this machine).
    private func chooseSevenZip(_ item: String) throws {
        guard choose(item, in: "7-Zip") else {
            throw XCTSkip("Finder shows no 7-Zip submenu: the Finder extension is not enabled")
        }
    }

    // MARK: - Helpers

    @discardableResult
    private func waitFor(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if condition() { return true }
            usleep(200_000)
        } while Date() < deadline
        return condition()
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "finderfix-\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// The Add to Archive dialog (IDD_COMPRESS 4000), found by its "Archive format:" label as in
    /// `FinderIntegrationTests`.
    private func compressDialogAppears() -> Bool {
        guard let app = runningSevenZip() else { return false }
        return app.staticTexts["Archive format:"].waitForExistence(timeout: 30)
    }

    // MARK: - Finder Sync menu (03 section 1.4)

    /// A1 "Open archive" -> the file manager opens the archive (`7zFM.exe "<file>"`): a window whose
    /// title is the archive path with a trailing separator.
    func testOpenArchiveFromFinderMenuOpensTheArchive() throws {
        let zip = try makeZip()
        try openContextMenu(on: zip)
        try chooseSevenZip("Open archive")
        let app = try XCTUnwrap(runningSevenZip(), "no 7-Zip was started")
        let window = app.windows.matching(NSPredicate(format: "title ENDSWITH 'probe.zip/'")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 30), "7-Zip did not open the archive")
        attach("open-archive")
    }

    /// B5 "Add to archive..." -> the Add to Archive dialog over the selection.
    func testAddToArchiveFromFinderMenuShowsTheCompressDialog() throws {
        let zip = try makeZip()
        try openContextMenu(on: zip)
        try chooseSevenZip("Add to archive...")
        XCTAssertTrue(compressDialogAppears(), "7-Zip did not show Add to Archive")
        attach("add-to-archive")
    }

    /// B3 `Extract to "probe/"` -> no dialog, the folder appears next to the archive.
    func testExtractToFromFinderMenuExtracts() throws {
        let zip = try makeZip()
        let out = ((zip as NSString).deletingLastPathComponent as NSString).appendingPathComponent("probe")
        try openContextMenu(on: zip)
        try chooseSevenZip("Extract to \"probe/\"")
        XCTAssertTrue(waitFor(30) { FileManager.default.fileExists(atPath: out + "/readme.txt") },
                      "nothing was extracted to \(out)")
    }

    // MARK: - Quick Actions (03 section 6.1)

    /// "Extract with 7-Zip" -> `SevenZipExtractTo`: the folder appears next to the archive.
    func testQuickActionExtractExtracts() throws {
        let zip = try makeZip()
        let out = ((zip as NSString).deletingLastPathComponent as NSString).appendingPathComponent("probe")
        try openContextMenu(on: zip)
        guard choose("Extract with 7-Zip", in: "Quick Actions") else {
            throw XCTSkip("Finder offers no Quick Actions for a .zip here")
        }
        XCTAssertTrue(waitFor(30) { FileManager.default.fileExists(atPath: out + "/readme.txt") },
                      "the Quick Action extracted nothing to \(out)")
    }

    /// "Compress with 7-Zip" -> `SevenZipCompress`: the Add to Archive dialog.
    func testQuickActionCompressShowsTheCompressDialog() throws {
        let file = try makeTextFile()
        try openContextMenu(on: file)
        guard choose("Compress with 7-Zip", in: "Quick Actions") else {
            throw XCTSkip("Finder offers no Quick Actions for a .txt here")
        }
        XCTAssertTrue(compressDialogAppears(), "the Quick Action did not show Add to Archive")
        attach("quick-action-compress")
    }
}
