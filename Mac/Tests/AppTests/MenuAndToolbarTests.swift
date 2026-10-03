// MenuAndToolbarTests.swift -- the 7zFM menu bar and toolbar inventory (01-fm-feature-inventory.md
// section 2, App.cpp `g_ArchiveButtons` / `g_StandardButtons`), asserted against the objects the
// app built instead of against the accessibility tree of a launched copy.
//
// This replaces `SmokeTests.testMenuBarStructure` and `SmokeTests.testToolbarButtons`. Those two
// cases launched the app, waited for a window and a listing, snapshotted the whole menu bar over
// the accessibility bus and then compared strings -- for assertions that are entirely about
// `NSApp.mainMenu` and one `NSToolbar`. Not one of them needed a window to be on screen.
//
// Two things to know about reading the menu in process:
//
//   * a top-level entry is an `NSMenuItem` with an **empty** title and a submenu whose title is
//     what the menu bar shows (`MainMenu.swift`: `let top = NSMenuItem(); top.submenu = menu`), so
//     the titles come from `item.submenu?.title`. Accessibility reports the same strings, which is
//     why the expected lists below are the XCUITest ones unchanged;
//   * the Apple menu is not in `NSApp.mainMenu` at all -- the system draws it -- so the expected
//     list is the XCUITest one with its leading "Apple" dropped, exactly as
//     `Array(topLevelMenuTitles.dropFirst())` was.

import AppKit
import XCTest
@testable import SevenZipAppHost

final class MenuAndToolbarTests: AppHostTestCase {

    // MARK: - helpers

    /// The menu bar the app is running with.
    private var menuBar: NSMenu {
        guard let bar = NSApp.mainMenu else {
            XCTFail("the app has no main menu")
            return NSMenu()
        }
        return bar
    }

    private func topLevelTitles(_ bar: NSMenu) -> [String] {
        bar.items.map { $0.submenu?.title ?? $0.title }
    }

    private func submenu(_ bar: NSMenu, _ title: String) -> NSMenu? {
        bar.items.first { ($0.submenu?.title ?? $0.title) == title }?.submenu
    }

    /// Item titles of one menu path, separators as "" -- the in-process twin of
    /// `SevenZipApp.itemTitles(in:)`.
    private func itemTitles(_ bar: NSMenu, _ path: [String]) -> [String] {
        guard var menu = submenu(bar, path[0]) else { return [] }
        for title in path.dropFirst() {
            guard let next = menu.items.first(where: { $0.title == title })?.submenu else { return [] }
            menu = next
        }
        return menu.items.map { $0.isSeparatorItem ? "" : $0.title }
    }

    private func assertMenu(_ bar: NSMenu, _ menu: String, contains expected: [String],
                            file: StaticString = #filePath, line: UInt = #line) {
        let titles = itemTitles(bar, [menu]).filter { !$0.isEmpty }
        for title in expected where !titles.contains(title) {
            XCTFail("menu \(menu) has no item '\(title)'; it has \(titles)", file: file, line: line)
        }
    }

    /// Every menu item of the bar, depth first (dynamic submenus are built by their delegate when
    /// the menu opens, so `update()` is sent first).
    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.update()
        var found: [NSMenuItem] = []
        for item in menu.items {
            found.append(item)
            if let submenu = item.submenu { found += allItems(submenu) }
        }
        return found
    }

    // MARK: - 01 section 2: the menu bar

    /// The 7zFM menus with the expected items. `SmokeTests.testMenuBarStructure`, minus the launch.
    func testMenuBarStructure() throws {
        continueAfterFailure = true
        let bar = menuBar
        // Titles come from the lang file; `AppHostTestCase.setUp` loads built-in English ("-"), so
        // the resource texts are what must be there. If that failed, everything below is moot.
        try XCTSkipUnless(itemTitles(bar, ["Tools"]).contains("Benchmark"),
                          "the app is not running with English strings")

        XCTAssertEqual(topLevelTitles(bar),
                       ["7-Zip", "File", "Edit", "View", "Favorites", "Tools", "Window", "Help"],
                       "top level menus: \(topLevelTitles(bar))")

        assertMenu(bar, "File", contains: ["Open", "Open Inside", "Open Inside *", "Open Inside #",
                                           "Open Outside", "View", "Edit", "Rename", "Copy To...",
                                           "Move To...", "Delete", "Split file...", "Combine files...",
                                           "Properties", "Comment...", "CRC", "Diff", "Create Folder",
                                           "Create File", "Link...", "Exit"])
        assertMenu(bar, "Edit", contains: ["Select All", "Deselect All", "Invert Selection", "Select...",
                                           "Deselect...", "Select by Type", "Deselect by Type"])
        assertMenu(bar, "View", contains: ["Large Icons", "Small Icons", "List", "Details", "Name", "Type",
                                           "Date", "Size", "Unsorted", "Flat View", "2 Panels", "Toolbars",
                                           "Open Root Folder", "Up One Level", "Folders History...",
                                           "Refresh", "Auto Refresh"])
        assertMenu(bar, "Tools", contains: ["Options...", "Benchmark", "Delete Temporary Files..."])
        assertMenu(bar, "Help", contains: ["Contents...", "About 7-Zip..."])
        XCTAssertEqual(itemTitles(bar, ["Favorites"]).first, "Add folder to Favorites as")

        // The nested CRC submenu, titled from lang id 553 which no .ttt translates.
        XCTAssertEqual(itemTitles(bar, ["File", "CRC"]),
                       ["CRC-32", "CRC-64", "XXH64", "MD5", "SHA-1", "SHA-256", "SHA-384",
                        "SHA-512", "SHA3-256", "BLAKE2sp", "*"],
                       "the CRC submenu is titled from lang id 553")
    }

    /// Items are addressable by the selector they are *declared* with, whatever gets installed on
    /// them later. `AboutAndDragOutTests.testAboutItemsHaveAStableAccessibilityIdentity`'s first
    /// half: the accessibility identifier of every item with an action is that action's name, and
    /// both IDM_ABOUT 961 items report `helpAbout:` rather than a runtime replacement.
    func testMenuItemsAreAddressableBySelector() {
        continueAfterFailure = true
        let items = allItems(menuBar)
        XCTAssertTrue(items.contains { $0.accessibilityIdentifier() == "viewTwoPanels:" },
                      "no item sends viewTwoPanels:")
        let about = items.filter { $0.accessibilityIdentifier() == "helpAbout:" }
        XCTAssertEqual(about.count, 2,
                       "IDM_ABOUT 961 sits in the 7-Zip menu and in Help; found \(about.count)")
        for item in about { XCTAssertEqual(item.title, "About 7-Zip...") }
        XCTAssertEqual(items.filter { $0.accessibilityIdentifier() == "toolsShowAbout:" }.count, 0,
                       "the runtime retarget is gone, so no item reports that selector")

        // Every item that sends an action declares it as its accessibility identity -- the rule
        // that makes `menuItem(selector:)` language independent (MainMenu.item).
        for item in items where item.action != nil && !item.isSeparatorItem {
            let identifier = item.accessibilityIdentifier()
            guard !identifier.isEmpty else { continue }      // the standard AppKit items set none
            XCTAssertEqual(identifier, NSStringFromSelector(item.action!),
                           "'\(item.title)' reports \(identifier) but sends \(item.action!)")
        }
    }

    /// No menu item comes up with an empty title in English. The detector for a `lang:` id that
    /// resolves to nothing -- a blank menu entry is invisible on a screenshot but obvious here.
    func testNoMenuItemHasAnEmptyTitle() {
        continueAfterFailure = true
        for item in allItems(menuBar) where !item.isSeparatorItem {
            XCTAssertFalse(item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "an item of '\(item.parent?.title ?? "?")' has an empty title")
        }
    }

    // MARK: - App.cpp g_ArchiveButtons / g_StandardButtons: the toolbar

    /// The seven 7zFM toolbar buttons, in order, all enabled.
    /// `SmokeTests.testToolbarButtons`, minus the launch.
    func testToolbarButtons() {
        let controller = MainWindowController()
        defer { controller.window?.close() }
        // The 7zFM strip (FMToolbar.swift, winmatch), not an NSToolbar.
        let buttons = controller.toolbarView.buttons
        let titles = buttons.map(\.title)
        XCTAssertEqual(titles, ["Add", "Extract", "Test", "Copy", "Move", "Delete", "Info"],
                       "toolbar items: \(titles)")
        for button in buttons {
            XCTAssertNotNil(button.action, "toolbar button '\(button.title)' sends nothing")
            XCTAssertTrue(button.isEnabled)
        }
        // The compress scope implemented Add, so it must be wired, not a placeholder
        // (kMenuCmdID_Toolbar_Add 1070).
        XCTAssertEqual(buttons.first?.action.map(NSStringFromSelector), "toolbarAddToArchive:",
                       "Add must send the toolbar Add selector")
    }
}
