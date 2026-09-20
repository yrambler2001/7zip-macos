// LocalizationFittingTests.swift -- the localization sweep over all 93 bundled languages
// (`Mac/Resources/Lang`), in one process instead of 93 app launches.
//
// What it replaces. `LocalizationTests.testLanguagesComeUp<n>of5` (Mac/Tests/UITests) launched the
// app once per language -- 93 launches, five XCUITest cases, the single most expensive thing in the
// suite -- and asserted, over the accessibility bus, that the menu bar was populated, that no menu
// title was empty, that the File menu had its items and that the panel had its columns and rows.
// Every one of those is a property of the objects the app builds from the lang file, so the loop
// becomes: load the language, rebuild the menu bar, look at it.
//
// And what it *adds*, which the launch-based sweep could not do at all: the layout of the dialogs
// in every language. The launch sweep screenshotted five hand-picked languages on a handful of
// dialogs and a human looked at the PNGs. Here the fitting question -- "does the translated text
// still fit the window?" -- is asked of every language on the dialogs whose labels are longest,
// and answered by `WindowAudit` as a number. `ar.txt`'s 78-character translator credit in lang id
// 2102, where English has the 9-character "Language:", is exactly the sort of string this catches.
//
// Recorded but not asserted, as on the XCUITest side: the number of menu items whose title is
// exactly the product name. Lang id 0 *is* "7-Zip" in every valid lang file
// (`CPP/Common/Lang.cpp` refuses a file whose id 0 is anything else), so an item that asks for id
// 0 gets "7-Zip" as soon as a translation is loaded. That is a known product bug filed in
// `Mac/docs/requests.md`, not a reason for a red suite.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class LocalizationFittingTests: AppHostTestCase {

    override var screenshotPrefix: String { "fastui-lang" }

    /// Every selectable language: the 92 `Lang/*.txt` files plus `"-"` (built-in English).
    /// `en.ttt` is the English template, which `availableLanguages` filters out, so `"-"` is how
    /// English is chosen -- 93 cases for the 93 bundled files.
    private static let codes: [String] = ["-"] + SZLang.shared.availableLanguages.map(\.code)

    // MARK: - 1. Every language comes up populated

    /// The five `testLanguagesComeUp<n>of5` cases, merged: 93 languages, no launch.
    func testEveryLanguageBuildsAPopulatedMenuBar() {
        continueAfterFailure = true
        let codes = Self.codes
        XCTAssertGreaterThanOrEqual(codes.count, 93,
                                    "expected at least 93 languages, found \(codes.count) in \(SZLang.langDirectoryPath)")

        var broken: [String] = []
        for code in codes {
            var problems: [String] = []
            useLanguage(code)
            if code != "-" {
                // A file that fails to load leaves English active, and then every assertion below
                // would pass while testing nothing.
                if SZLang.shared.currentLanguageCode != code {
                    problems.append("loaded as '\(SZLang.shared.currentLanguageCode)'")
                }
                if SZLang.shared.translatedString(forID: 401) == nil {
                    problems.append("no translation for lang id 401 (OK)")
                }
            }

            let bar = MainMenu.build()
            let top = bar.items.map { $0.submenu?.title ?? $0.title }
            // 7-Zip, File, Edit, View, Favorites, Tools, Window, Help (the Apple menu is the
            // system's and is not in the bar).
            if top.count != 8 { problems.append("\(top.count) top-level menus") }
            let blankTop = top.filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            if blankTop > 0 { problems.append("\(blankTop) top-level menu(s) with an empty title") }

            let fileItems = bar.items.count > 1 ? (bar.items[1].submenu?.items.count ?? 0) : 0
            if fileItems < 20 { problems.append("the File menu has \(fileItems) items") }

            var blankItems = 0
            var productNameItems = 0
            walk(bar) { item in
                guard !item.isSeparatorItem else { return }
                if item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { blankItems += 1 }
                if item.title == "7-Zip" { productNameItems += 1 }
            }
            // A blank item is invisible on a screenshot and unclickable in the app.
            if blankItems > 0 { problems.append("\(blankItems) menu item(s) with an empty title") }

            // The seven default columns of a file-system folder (01 section 3.2, FSFolderMac's
            // property list) are titled from the lang file too -- GetNameOfProperty reads lang id
            // 1000 + propID -- so a language that is missing one of them shows a blank header.
            // The launch sweep asserted this by counting the panel's headers; here the seven
            // property names are asked directly.
            let columns = Self.fileSystemColumnProperties.map { PanelProperties.propertyName($0) }
            for (propID, title) in zip(Self.fileSystemColumnProperties, columns)
            where title.trimmingCharacters(in: .whitespaces).isEmpty || title == "\(propID.rawValue)" {
                problems.append("column \(propID.rawValue) has no name (lang id \(1000 + propID.rawValue))")
            }
            let columnTitles = columns

            // The status bar (Refresh_StatusBar, PanelListNotify.cpp:759-820) is one lang string
            // put through MyFormatNew, so a translation that lost the "{0}" placeholder produces a
            // status line with no counts in it. The launch sweep asserted only that the label was
            // not empty; this asserts the substitution as well.
            let status = Lang.format(Lang.get(3002, "{0} object(s) selected"), "1 / 10")
            if status.trimmingCharacters(in: .whitespaces).isEmpty || !status.contains("1 / 10") {
                problems.append("the status template (IDS_N_SELECTED_ITEMS 3002) formats as '\(status)'")
            }
            // The Copy dialog's info block (GetItemsInfoString, App.cpp:500-547).
            for id in [UInt32(1031), 1032, 1007] where Lang.get(id, "").isEmpty {
                problems.append("lang id \(id) is empty (Copy dialog info block)")
            }

            print(["LANGSWEEP", code, "up", "menus=\(top.count)", "blanktop=\(blankTop)",
                   "file=\(fileItems)", "blankitems=\(blankItems)", "cols=\(columnTitles.count)",
                   "productname=\(productNameItems)",
                   "bar=" + top.dropFirst().prefix(4).joined(separator: "/"),
                   "problems=\(problems.count)"].joined(separator: "|"))
            if !problems.isEmpty { broken.append("\(code): \(problems.joined(separator: "; "))") }
        }
        XCTAssertTrue(broken.isEmpty,
                      "languages that did not come up populated:\n" + broken.joined(separator: "\n"))
    }

    // MARK: - 2. Every language's dialogs still fit their windows

    /// The fitting sweep: for each of the 93 languages, build the dialogs whose labels are the
    /// longest and assert that nothing is clipped and that the window honours the content's
    /// `fittingSize`. This is the assertion the XCUITest sweep left to a human looking at five
    /// screenshots.
    func testEveryLanguageFitsTheDialogs() {
        continueAfterFailure = true
        var failures: [String] = []
        for code in Self.codes {
            useLanguage(code)
            var findings: [String] = []
            for probe in DialogProbes.fittingSet {
                let name = "\(probe.name) [\(code)]"
                let appeared = ModalProbe.present(probe.present) { window in
                    findings += WindowAudit.defects(window, name: name)
                }
                if !appeared { findings.append("MISSING \(name): the dialog never came up") }
            }
            print("LANGFIT|\(code)|dialogs=\(DialogProbes.fittingSet.count)|defects=\(findings.count)")
            failures += findings
        }
        XCTAssertTrue(failures.isEmpty,
                      "dialogs that do not fit in some language:\n" + failures.joined(separator: "\n"))
    }

    /// The five scripts that stress layout differently, screenshotted for the record: a
    /// right-to-left one, a second RTL written the other way round, German compounds, CJK, and
    /// Cyrillic. `LocalizationTests.testRepresentativeLanguagesLayout`'s screenshots, without the
    /// five app launches per dialog.
    func testRepresentativeLanguagesAreScreenshotted() {
        continueAfterFailure = true
        for code in ["ar", "he", "de", "ja", "ru"] {
            useLanguage(code)
            for probe in DialogProbes.fittingSet {
                let name = "\(probe.name) [\(code)]"
                let appeared = ModalProbe.present(probe.present) { window in
                    self.audit(window, name, shot: "\(probe.shot)-\(code)")
                }
                XCTAssertTrue(appeared, "\(name) did not come up")
            }
            // The Options window carries the longest labels of the app; page 5 is the Language
            // page, where `ar.txt` puts a 78-character translator credit in lang id 2102.
            auditOptionsPages(code: code)
        }
        finishAudit("representative languages")
    }

    // MARK: - helpers

    private func auditOptionsPages(code: String) {
        let controller = OptionsWindowController.shared
        guard let window = controller.window else { return XCTFail("the Options window has no window") }
        let appeared = ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in }
        XCTAssertTrue(appeared, "the Options window did not come up in '\(code)'")
        guard let tabs = firstTabView(in: window) else { return XCTFail("no NSTabView in the Options window") }
        for index in 0..<tabs.numberOfTabViewItems {
            tabs.selectTabViewItem(at: index)
            window.contentView?.layoutSubtreeIfNeeded()
            audit(window, "Options page \(index + 1) [\(code)]", shot: "options-\(index + 1)-\(code)")
        }
        ModalProbe.close(window)
    }

    private func firstTabView(in window: NSWindow) -> NSTabView? {
        func search(_ view: NSView) -> NSTabView? {
            if let tabs = view as? NSTabView { return tabs }
            for child in view.subviews {
                if let found = search(child) { return found }
            }
            return nil
        }
        guard let content = window.contentView else { return nil }
        return search(content)
    }

    /// The default column set of a file-system folder, in `FSFolderMac`'s order (01 section 3.2):
    /// Name, Size, Modified, Created, Accessed, Attributes, Comment.
    static let fileSystemColumnProperties: [SZPropID] =
        [.name, .size, .mtime, .ctime, .atime, .attrib, .comment]

    private func walk(_ menu: NSMenu, _ body: (NSMenuItem) -> Void) {
        for item in menu.items {
            body(item)
            if let submenu = item.submenu { walk(submenu, body) }
        }
    }
}

/// The dialogs the localization sweep builds for every language: the ones whose windows are sized
/// from their labels, so a long translation shows up as a clipped control or an unhonoured
/// `fittingSize`.
enum DialogProbes {

    struct Probe {
        let name: String
        let shot: String
        let present: () -> Void
    }

    static var fittingSet: [Probe] {
        let fixtures = TestPaths.fixtures
        let archive = TestPaths.fixture("test.7z")
        return [
            // IDD_COPY 96: label + editable combo + up to 11 info lines + OK/Cancel.
            Probe(name: "Copy (IDD_COPY 96)", shot: "copy") {
                _ = CopyMoveDialog.run(move: false, value: fixtures, history: [fixtures],
                                       info: archive, parent: nil)
            },
            // IDD_EXTRACT 3400: the widest dialog of the port, two combo rows plus a password block.
            Probe(name: "Extract (IDD_EXTRACT 3400)", shot: "extract") {
                var options = ExtractDialog.Options()
                options.directoryPath = fixtures + "/"
                options.archivePath = archive
                _ = ExtractDialog.run(options)
            },
            // IDD_PASSWORD 3800, compress side: three labels, two fields, two checkboxes.
            Probe(name: "Password (IDD_PASSWORD 3800)", shot: "password") {
                var options = PasswordDialog.Options()
                options.subject = archive
                options.requiresVerification = true
                options.showsEncryptFileNames = true
                _ = PasswordDialog.run(options, parent: nil)
            },
            // IDD_OVERWRITE 3500: two file blocks and five buttons in one row.
            Probe(name: "Overwrite (IDD_OVERWRITE 3500)", shot: "overwrite") {
                _ = OverwriteDialog.run(oldFile: .init(path: archive, size: 838, time: Date()),
                                        newFile: .init(path: fixtures + "/test.zip", size: 1024, time: Date()),
                                        showExtraButtons: true, parent: nil)
            },
            // IDD_ABOUT 2900: free text, and the one dialog whose height is all label.
            Probe(name: "About (IDD_ABOUT 2900)", shot: "about") {
                AboutDialog.show(parent: nil)
            },
        ]
    }
}
