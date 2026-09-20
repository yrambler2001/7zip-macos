// LocalizationTests.swift -- packaging scope: the localization sweep over all 93 bundled language
// files (`Mac/Resources/Lang`), which no earlier scope had run.
//
// Two halves, matching the two questions worth asking of a translation:
//
//  1. `testLanguagesComeUp<n>of5` -- for **every** selectable language, start the app with that
//     language seeded into its settings domain and assert that it comes up and is populated: a
//     window, a full menu bar with no empty title, the File menu's items, the panel's seven columns
//     and its ten fixture rows, a window title and a status line. Split into five chunks so no
//     single test case runs for minutes on end. Each language's measurements are printed as a
//     `LANGSWEEP|...` line, which is how `Mac/docs/reports/packaging.md` was tabulated.
//
//  2. `testRepresentativeLanguagesLayout` -- the four scripts that stress layout differently (a
//     right-to-left one, German-style compounds, CJK, Cyrillic) plus a second RTL, opened on the
//     main window and on several dialogs, screenshotted for clipped and truncated labels. The
//     screenshots are `Mac/docs/reports/screenshots/packaging-*.png`; what they show is written up
//     in `Mac/docs/reports/packaging.md`.
//
// A screenshot here is of the **whole screen**, not of the main window: the dialogs are separate
// windows or sheets that extend past the main window's frame, so `SevenZipApp.screenshot` (which
// captures `window`) would cut them off. `Mac/scripts/test.sh` exports the attachments by name.
//
// The sweep records, but does not fail on, the number of menu items whose title is exactly the
// product name. That is the detector for a `lang: 0` menu item -- lang id 0 *is* "7-Zip" in every
// valid language file (`CPP/Common/Lang.cpp` refuses a file whose id 0 is anything else), so an
// item that asks for it gets "7-Zip" as its title as soon as a translation is loaded. Failing on
// it would turn a known product bug into a red suite; it is filed in `Mac/docs/requests.md`
// instead, which is what the ownership rules ask for.

import Foundation
import XCTest

final class LocalizationTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "packaging" }

    // MARK: - The language set

    /// Every selectable language: the 92 `Lang/*.txt` files plus `"-"` (built-in English).
    /// `en.ttt` is the English template and `SZLang.availableLanguages` filters it out, so `"-"`
    /// is how English is chosen; that makes 93 cases for the 93 bundled files.
    static let codes: [String] = {
        guard let root = TestPaths.repoRoot else { return ["-"] }
        let dir = root + "/Mac/Resources/Lang"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let translations = files.filter { $0.hasSuffix(".txt") }.map { String($0.dropLast(4)) }.sorted()
        return ["-"] + translations
    }()

    /// How many rows the fixtures folder must list, read from the folder itself so adding a
    /// fixture does not silently weaken the assertion.
    static let fixtureRowCount: Int = {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: TestPaths.fixtures)) ?? []
        return files.filter { !$0.hasPrefix(".") }.count
    }()

    // MARK: - 1. Every language comes up

    func testLanguagesComeUp1of5() { sweep(chunk: 0) }
    func testLanguagesComeUp2of5() { sweep(chunk: 1) }
    func testLanguagesComeUp3of5() { sweep(chunk: 2) }
    func testLanguagesComeUp4of5() { sweep(chunk: 3) }
    func testLanguagesComeUp5of5() { sweep(chunk: 4) }

    private static let chunks = 5

    private func sweep(chunk: Int) {
        continueAfterFailure = true
        let all = Self.codes
        XCTAssertGreaterThanOrEqual(all.count, 93, "expected at least 93 languages, found \(all.count); TestPaths.repoRoot = \(TestPaths.repoRoot ?? "nil")")
        XCTAssertGreaterThan(Self.fixtureRowCount, 0, "no fixtures at \(TestPaths.fixtures)")
        let size = (all.count + Self.chunks - 1) / Self.chunks
        let lower = min(chunk * size, all.count)
        let upper = min(lower + size, all.count)
        guard lower < upper else { return }

        var broken: [String] = []
        for code in all[lower..<upper] {
            let o = inspect(code)
            print(o.line)
            if !o.problems.isEmpty { broken.append("\(code): \(o.problems.joined(separator: "; "))") }
            sevenZip.terminate()
        }
        XCTAssertTrue(broken.isEmpty,
                      "languages that did not come up populated:\n" + broken.joined(separator: "\n"))
    }

    private struct Outcome {
        var code = ""
        var problems: [String] = []
        var line = ""
    }

    private func inspect(_ code: String) -> Outcome {
        var out = Outcome()
        out.code = code
        sevenZip.seedName = "lang-" + (code == "-" ? "en" : code)
        let window = launch(seed: .typed([SettingsDomain.Key.lang: code,
                                          SettingsDomain.Key.panelPath0: TestPaths.fixtures,
                                          SettingsDomain.Key.numPanels: 1,
                                          SettingsDomain.Key.listMode0: 3]))
        guard window.exists else {
            out.problems.append("no window appeared")
            out.line = "LANGSWEEP|\(code)|DOWN"
            return out
        }

        let top = sevenZip.topLevelMenuTitles
        // Apple, 7-Zip, File, Edit, View, Favorites, Tools, Window, Help.
        if top.count < 9 { out.problems.append("only \(top.count) top-level menus") }
        let blank = top.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        if blank > 0 { out.problems.append("\(blank) top-level menu(s) with an empty title") }

        // The File menu, addressed by its localized title (index 2: Apple, app, File, ...).
        let fileItems = top.count > 2 ? sevenZip.itemTitles(in: top[2]).count : 0
        if fileItems < 20 { out.problems.append("the File menu has \(fileItems) items") }

        let panel = sevenZip.panel(0)
        let rows = panel.rowCount
        let columns = panel.columnTitles
        if rows != Self.fixtureRowCount { out.problems.append("\(rows) rows, expected \(Self.fixtureRowCount)") }
        // The file-system folder's default column set is seven wide (Name, Size, Modified,
        // Created, Accessed, Attributes, Comment -- `PanelLogic` / `01 section 3.2`), not the four
        // of `api/harness.md`'s example. What matters per language is that they are all there and
        // none of the headers came out blank.
        if columns.count < 7 { out.problems.append("\(columns.count) columns, expected 7") }
        if columns.contains(where: { $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            out.problems.append("a column header is empty")
        }
        let status = panel.status
        if status.trimmingCharacters(in: .whitespaces).isEmpty { out.problems.append("the status line is empty") }
        if sevenZip.windowTitle.trimmingCharacters(in: .whitespaces).isEmpty {
            out.problems.append("the window title is empty")
        }

        // Recorded, not asserted: see the file comment. The View menu is where the two `lang: 0`
        // items live (`MainMenu.swift:227-228`), so it is counted on its own as well.
        let productName = menuItemsTitled("7-Zip")
        let viewProductName = top.count > 4 ? sevenZip.itemTitles(in: top[4]).filter { $0 == "7-Zip" }.count : -1

        out.line = [
            "LANGSWEEP", code, "up",
            "menus=\(top.count)", "blank=\(blank)", "file=\(fileItems)",
            "rows=\(rows)", "cols=\(columns.count)",
            "status=\(status.isEmpty ? "EMPTY" : "ok")",
            "productname=\(productName)", "viewproductname=\(viewProductName)",
            "bar=" + top.dropFirst(2).prefix(4).joined(separator: "/"),
            "problems=\(out.problems.count)",
        ].joined(separator: "|")
        return out
    }

    /// How many menu-bar items and menu items carry exactly this title, over one snapshot.
    private func menuItemsTitled(_ title: String) -> Int {
        guard let snapshot = try? sevenZip.menuBar.snapshot() else { return -1 }
        var count = 0
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .menuItem || node.elementType == .menuBarItem {
                if node.title == title { count += 1 }
            }
            node.children.forEach(walk)
        }
        walk(snapshot)
        return count
    }

    // MARK: - 2. Layout of a representative subset

    func testRepresentativeLanguagesLayout() {
        continueAfterFailure = true

        // ar: right-to-left, and the language whose Options > Language label is a 78-character
        //     translator credit where English has "Language:" (9).
        // he: a second right-to-left script, written the other way round from Arabic's shaping.
        // de: German compounds -- the long-string case (its 7308 string is 120 characters).
        // ja: CJK, wide glyphs, no spaces to wrap on.
        // ru: Cyrillic, the widest of the European scripts here.
        for (index, code) in [(10, "ar"), (11, "he"), (12, "de"), (13, "ja"), (14, "ru")] {
            launchLocalized(code)
            shot("\(index)-main-\(code)")
            sevenZip.terminate()
        }

        // The Options window, page 4 = Settings (OptionsDialog.cpp order: System, Menu, Folders,
        // Editor, Settings, Language, Plugins), the page with the longest labels.
        for (index, code) in [(20, "ar"), (21, "de"), (22, "ja"), (23, "ru")] {
            openOptions(code, page: 4, shotName: "\(index)-options-settings-\(code)")
        }
        // Page 5 = Language, in Arabic: `ar.txt` puts a 78-character translator credit where
        // lang id 2102 should hold the 9-character "Language:" label (the row sits exactly where
        // `en.ttt` has it, so it is one wrong row rather than a positional shift). This is the
        // screenshot that shows what that does to the page.
        openOptions("ar", page: 5, shotName: "24-options-language-ar")

        // Every Options page in German, the worst case for a fixed-width control.
        let pageNames = ["system", "menu", "folders", "editor", "settings", "language", "plugins"]
        for page in [0, 1, 2, 3, 5, 6] {
            openOptions("de", page: page, shotName: "3\(page)-options-\(pageNames[page])-de")
        }

        // Dialogs reached by selector, so the menu titles may be in any language.
        openDialog(code: "ar", selector: "fileCopyTo:", select: "test.7z", shotName: "40-copy-ar")
        openDialog(code: "de", selector: "fileCopyTo:", select: "test.7z", shotName: "41-copy-de")
        openDialog(code: "de", selector: "fileProperties:", select: "test.7z", shotName: "42-properties-de")
        openDialog(code: "ja", selector: "fileProperties:", select: "test.7z", shotName: "43-properties-ja")
        openDialog(code: "de", selector: "toolsBenchmark:", select: nil, shotName: "44-benchmark-de")
        openDialog(code: "ru", selector: "toolsBenchmark:", select: nil, shotName: "45-benchmark-ru")
    }

    @discardableResult
    private func launchLocalized(_ code: String, extra: [String: Any] = [:]) -> XCUIElement {
        sevenZip.seedName = "layout-" + code
        var seed: [String: Any] = [SettingsDomain.Key.lang: code,
                                   SettingsDomain.Key.panelPath0: TestPaths.fixtures,
                                   SettingsDomain.Key.numPanels: 1,
                                   SettingsDomain.Key.listMode0: 3]
        seed.merge(extra) { _, new in new }
        return launch(seed: .typed(seed))
    }

    private func openOptions(_ code: String, page: Int, shotName: String) {
        // "FM.OptionsPage" is the stored last page (Settings.optionsLastPage), so the page can be
        // chosen through the seed rather than by clicking a localized tab.
        launchLocalized(code, extra: ["FM.OptionsPage": page])
        if clickMenuItem(selector: "toolsOptions:") {
            _ = waitForExtraWindow()
            shot(shotName)
        } else {
            XCTFail("could not open Options in '\(code)'")
        }
        sevenZip.terminate()
    }

    private func openDialog(code: String, selector: String, select: String?, shotName: String) {
        launchLocalized(code)
        if let name = select {
            let panel = sevenZip.panel(0)
            XCTAssertTrue(panel.waitForRow(named: name), "no row '\(name)' in '\(code)'")
            panel.select(name)
        }
        if clickMenuItem(selector: selector) {
            _ = waitForExtraWindow()
            shot(shotName)
        } else {
            XCTFail("could not open \(selector) in '\(code)'")
        }
        sevenZip.terminate()
    }

    /// Wait until a second window or a sheet is on screen. False when nothing appeared, which the
    /// screenshot then shows anyway.
    @discardableResult
    private func waitForExtraWindow(timeout: TimeInterval = 15) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.sheets.count > 0 || app.dialogs.count > 0 || app.windows.count > 1 { return true }
            usleep(200_000)
        }
        return false
    }

    // MARK: - Language-independent menu driving

    /// The menu path of the item that sends `selector`, in whatever language the titles are.
    /// `SevenZipApp.menuItem(selector:)` resolves the element but cannot be clicked without its
    /// menus being opened, and `selectMenuItem` is variadic, so the path is what is needed.
    private func menuPath(selector: String) -> [String]? {
        guard let snapshot = try? sevenZip.menuBar.snapshot() else { return nil }
        var found: [String]?
        func walk(_ node: XCUIElementSnapshot, _ path: [String]) {
            if found != nil { return }
            for child in node.children {
                switch child.elementType {
                case .menuBarItem, .menuItem:
                    let next = path + [child.title]
                    if child.identifier == selector { found = next; return }
                    walk(child, next)
                case .menu:
                    walk(child, path)
                default:
                    break
                }
            }
        }
        walk(snapshot, [])
        return found
    }

    /// Open the menus down to the item that sends `selector` and click it.
    @discardableResult
    private func clickMenuItem(selector: String) -> Bool {
        guard let path = menuPath(selector: selector), path.count >= 2 else {
            XCTFail("no menu item sends \(selector)")
            return false
        }
        let bar = sevenZip.menuBar
        let top = bar.children(matching: .menuBarItem)
            .matching(NSPredicate(format: "title == %@", path[0])).firstMatch
        guard top.waitForExistence(timeout: 10) else { return false }
        top.click()
        var owner = top
        for (offset, title) in path.enumerated() where offset > 0 {
            let item = owner.children(matching: .menu).firstMatch
                .children(matching: .menuItem)
                .matching(NSPredicate(format: "title == %@", title)).firstMatch
            guard item.waitForExistence(timeout: 10) else {
                sevenZip.closeOpenMenus()
                return false
            }
            if offset == path.count - 1 {
                guard item.isEnabled else {
                    sevenZip.closeOpenMenus()
                    XCTFail("\(selector) is disabled (\(path.joined(separator: " > ")))")
                    return false
                }
                item.click()
            } else {
                item.hover()
                owner = item
            }
        }
        return true
    }

    // MARK: - Screenshots

    /// The whole screen, so a dialog that is not inside the main window's frame is still in it.
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(screenshotPrefix)-\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
