// MainMenu.swift -- the 7zFM menu bar (FileManager/resource.rc IDM_MENU, MyLoadMenu.cpp) built
// in code. Every item keeps its Windows resource ID in a comment, takes its title from the lang
// file (same ID) with the English resource text as fallback, and sends an @objc action down the
// responder chain. Items whose selector nobody implements are disabled by AppKit automatically.
//
// Shortcut mapping (01-fm-feature-inventory.md section 2): Ctrl -> Cmd, Alt -> Option, F-keys
// unchanged. Keys that 7zFM binds without a modifier (Enter, Backspace, Del, \, keypad +/-/*)
// are handled by the panel's key handler (PanelTableView) so they cannot swallow typing in the
// address bar; the menu shows the closest macOS equivalent where one exists.

import Cocoa

enum MainMenu {

    // Top-level popup IDs (k_LangID_TopMenuItems)
    static let idmFile: UInt32 = 500       // IDM_FILE
    static let idmEdit: UInt32 = 501       // IDM_EDIT
    static let idmView: UInt32 = 502       // IDM_VIEW
    static let idmFavorites: UInt32 = 503  // IDM_FAVORITES
    static let idmTools: UInt32 = 504      // IDM_TOOLS
    static let idmHelp: UInt32 = 505       // IDM_HELP

    static let kMenuIDOpenBookmark = 830   // k_MenuID_OpenBookmark
    static let kMenuIDSetBookmark = 810    // k_MenuID_SetBookmark
    static let idmViewTime = 761           // IDM_VIEW_TIME (+ level index)

    private static func fkey(_ n: Int) -> String {
        String(UnicodeScalar(NSF1FunctionKey + n - 1)!)
    }

    /// One menu item. `title` is the English resource text (with & and \t as in resource.rc).
    @discardableResult
    private static func item(_ menu: NSMenu, _ idm: Int, lang: UInt32, _ title: String,
                             key: String = "", mods: NSEvent.ModifierFlags = [],
                             action: Selector?, tag: Int? = nil, hidden: Bool = false) -> NSMenuItem {
        let it = NSMenuItem(title: Lang.menuTitle(lang, title), action: action, keyEquivalent: key)
        it.keyEquivalentModifierMask = mods
        it.tag = tag ?? idm
        it.isHidden = hidden
        menu.addItem(it)
        return it
    }

    static func build() -> NSMenu {
        OpsInfraDemo.installIfRequested()   // SZ_OPSINFRA_DEMO: opsinfra scope verification hook
        let bar = NSMenu(title: "MainMenu")
        bar.addItem(appMenu())
        bar.addItem(fileMenu())
        bar.addItem(editMenu())
        bar.addItem(viewMenu())
        bar.addItem(favoritesMenu())
        bar.addItem(toolsMenu())
        bar.addItem(windowMenu())
        bar.addItem(helpMenu())
        return bar
    }

    // MARK: Application menu (macOS standard; About/Preferences map to 7zFM commands)

    private static func appMenu() -> NSMenuItem {
        let menu = NSMenu(title: "7-Zip")
        item(menu, 961, lang: 961, "&About 7-Zip...", action: #selector(MenuActions.helpAbout(_:)))   // IDM_ABOUT
        menu.addItem(.separator())
        item(menu, 900, lang: 900, "&Options...", key: ",", mods: [.command], action: #selector(MenuActions.toolsOptions(_:)))   // IDM_OPTIONS (Preferences...)
        menu.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        menu.addItem(services)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide 7-Zip", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit 7-Zip", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let top = NSMenuItem()
        top.submenu = menu
        return top
    }

    // MARK: File (IDM_FILE 500) -- CFileMenu::Load, MyLoadMenu.cpp:588-734

    private static func fileMenu() -> NSMenuItem {
        let menu = NSMenu(title: Lang.menuTitle(idmFile, "&File"))
        let a = MenuActions.self
        item(menu, 540, lang: 540, "&Open\tEnter", key: String(UnicodeScalar(NSDownArrowFunctionKey)!), mods: [.command], action: #selector(a.fileOpen(_:)))                  // IDM_OPEN
        item(menu, 541, lang: 541, "Open &Inside\tCtrl+PgDn", key: String(UnicodeScalar(NSPageDownFunctionKey)!), mods: [.command], action: #selector(a.fileOpenInside(_:)))  // IDM_OPEN_INSIDE
        let inside = Lang.stripMnemonic(Lang.dropAccelerator(Lang.translated(541) ?? "Open &Inside"))
        let one = item(menu, 590, lang: 590, "Open Inside *", action: #selector(a.fileOpenInsideOne(_:)))          // IDM_OPEN_INSIDE_ONE
        one.title = inside + " *"
        let parser = item(menu, 591, lang: 591, "Open Inside #", action: #selector(a.fileOpenInsideParser(_:)))    // IDM_OPEN_INSIDE_PARSER
        parser.title = inside + " #"
        item(menu, 542, lang: 542, "Open O&utside\tShift+Enter", key: "\r", mods: [.shift], action: #selector(a.fileOpenOutside(_:)))  // IDM_OPEN_OUTSIDE
        item(menu, 543, lang: 543, "&View\tF3", key: fkey(3), action: #selector(a.fileView(_:)))                   // IDM_FILE_VIEW
        item(menu, 544, lang: 544, "&Edit\tF4", key: fkey(4), action: #selector(a.fileEdit(_:)))                   // IDM_FILE_EDIT
        menu.addItem(.separator())
        item(menu, 545, lang: 545, "Rena&me\tF2", key: fkey(2), action: #selector(a.fileRename(_:)))               // IDM_RENAME
        item(menu, 546, lang: 546, "&Copy To...\tF5", key: fkey(5), action: #selector(a.fileCopyTo(_:)))           // IDM_COPY_TO
        item(menu, 547, lang: 547, "&Move To...\tF6", key: fkey(6), action: #selector(a.fileMoveTo(_:)))           // IDM_MOVE_TO
        item(menu, 548, lang: 548, "&Delete\tDel", key: "\u{8}", mods: [.command], action: #selector(a.fileDelete(_:)))   // IDM_DELETE (Del -> Cmd+Backspace)
        menu.addItem(.separator())
        item(menu, 549, lang: 549, "&Split file...", action: #selector(a.fileSplit(_:)))                           // IDM_SPLIT
        item(menu, 550, lang: 550, "Com&bine files...", action: #selector(a.fileCombine(_:)))                      // IDM_COMBINE
        menu.addItem(.separator())
        item(menu, 551, lang: 551, "P&roperties\tAlt+Enter", key: "\r", mods: [.option], action: #selector(a.fileProperties(_:)))   // IDM_PROPERTIES
        item(menu, 552, lang: 552, "Comme&nt...\tCtrl+Z", key: "z", mods: [.command], action: #selector(a.fileComment(_:)))         // IDM_COMMENT
        // popup "CRC" (resource id 0; IDM_CRC 553 is defined but unused by the .rc)
        let crc = NSMenuItem(title: Lang.menuTitle(553, "CRC"), action: nil, keyEquivalent: "")
        let crcMenu = NSMenu(title: crc.title)
        for (idm, name) in [(102, "CRC-32"), (103, "CRC-64"), (120, "XXH64"), (122, "MD5"), (104, "SHA-1"),
                            (105, "SHA-256"), (106, "SHA-384"), (107, "SHA-512"), (108, "SHA3-256"),
                            (121, "BLAKE2sp"), (101, "*")] {
            // IDM_CRC32 102, IDM_CRC64 103, IDM_XXH64 120, IDM_MD5 122, IDM_SHA1 104, IDM_SHA256 105,
            // IDM_SHA384 106, IDM_SHA512 107, IDM_SHA3_256 108, IDM_BLAKE2SP 121, IDM_HASH_ALL 101
            let it = NSMenuItem(title: name, action: #selector(a.fileCalculateHash(_:)), keyEquivalent: "")
            it.tag = idm
            crcMenu.addItem(it)
        }
        crc.submenu = crcMenu
        menu.addItem(crc)
        item(menu, 554, lang: 554, "Di&ff", action: #selector(a.fileDiff(_:)))                                     // IDM_DIFF (hidden unless a Diff tool is configured)
        menu.addItem(.separator())
        item(menu, 555, lang: 555, "Create Folder\tF7", key: fkey(7), action: #selector(a.fileCreateFolder(_:)))   // IDM_CREATE_FOLDER
        item(menu, 556, lang: 556, "Create File\tCtrl+N", key: "n", mods: [.command], action: #selector(a.fileCreateFile(_:)))   // IDM_CREATE_FILE
        menu.addItem(.separator())
        item(menu, 558, lang: 558, "&Link...", action: #selector(a.fileLink(_:)))                                  // IDM_LINK
        // IDM_ALT_STREAMS 559: NTFS alternate streams are hidden on macOS (00-orchestration.md)
        item(menu, 559, lang: 559, "&Alternate streams", action: #selector(a.fileAltStreams(_:)), hidden: true)
        // IDM_VER_EDIT 580 .. IDM_VER_DIFF 583: appended only when Diff + 7vc are configured (MyLoadMenu.cpp:697-732)
        item(menu, 580, lang: 580, "Ver Edit (&1)", action: #selector(a.fileVerEdit(_:)), hidden: true)
        item(menu, 581, lang: 581, "Ver Commit", action: #selector(a.fileVerCommit(_:)), hidden: true)
        item(menu, 582, lang: 582, "Ver Revert", action: #selector(a.fileVerRevert(_:)), hidden: true)
        item(menu, 583, lang: 583, "Ver Diff (&0)", action: #selector(a.fileVerDiff(_:)), hidden: true)
        menu.addItem(.separator())
        item(menu, 8, lang: 557, "E&xit\tAlt+F4", key: "w", mods: [.command], action: #selector(a.fileExit(_:)))   // IDCLOSE (lang 557)
        let top = NSMenuItem()
        top.submenu = menu
        return top
    }

    // MARK: Edit (IDM_EDIT 501)

    private static func editMenu() -> NSMenuItem {
        let menu = NSMenu(title: Lang.menuTitle(idmEdit, "&Edit"))
        let a = MenuActions.self
        item(menu, 600, lang: 600, "Select &All\tShift+[Grey +]", key: "a", mods: [.command], action: #selector(a.editSelectAll(_:)))          // IDM_SELECT_ALL (also Ctrl+A)
        item(menu, 601, lang: 601, "Deselect All\tShift+[Grey -]", key: "-", mods: [.shift, .numericPad], action: #selector(a.editDeselectAll(_:)))   // IDM_DESELECT_ALL
        item(menu, 602, lang: 602, "&Invert Selection\tGrey *", key: "*", mods: [.numericPad], action: #selector(a.editInvertSelection(_:)))  // IDM_INVERT_SELECTION
        item(menu, 603, lang: 603, "Select...\tGrey +", key: "+", mods: [.numericPad], action: #selector(a.editSelect(_:)))                  // IDM_SELECT
        item(menu, 604, lang: 604, "Deselect...\tGrey -", key: "-", mods: [.numericPad], action: #selector(a.editDeselect(_:)))              // IDM_DESELECT
        menu.addItem(.separator())   // MY_MFT_MENUBARBREAK column break in the .rc
        item(menu, 605, lang: 605, "Select by Type\tAlt+[Grey +]", key: "+", mods: [.option, .numericPad], action: #selector(a.editSelectByType(_:)))     // IDM_SELECT_BY_TYPE
        item(menu, 606, lang: 606, "Deselect by Type\tAlt+[Grey -]", key: "-", mods: [.option, .numericPad], action: #selector(a.editDeselectByType(_:))) // IDM_DESELECT_BY_TYPE
        let top = NSMenuItem()
        top.submenu = menu
        return top
    }

    // MARK: View (IDM_VIEW 502)

    private static func viewMenu() -> NSMenuItem {
        let menu = NSMenu(title: Lang.menuTitle(idmView, "&View"))
        let a = MenuActions.self
        item(menu, 700, lang: 700, "Lar&ge Icons\tCtrl+1", key: "1", mods: [.command], action: #selector(a.viewLargeIcons(_:)))   // IDM_VIEW_LARGE_ICONS
        item(menu, 701, lang: 701, "S&mall Icons\tCtrl+2", key: "2", mods: [.command], action: #selector(a.viewSmallIcons(_:)))   // IDM_VIEW_SMALL_ICONS
        item(menu, 702, lang: 702, "&List\tCtrl+3", key: "3", mods: [.command], action: #selector(a.viewList(_:)))                // IDM_VIEW_LIST
        item(menu, 703, lang: 703, "&Details\tCtrl+4", key: "4", mods: [.command], action: #selector(a.viewDetails(_:)))          // IDM_VIEW_DETAILS (default)
        menu.addItem(.separator())
        // kIDLangPairs: the arrange items use the property-name strings 1004/1020/1012/1007
        item(menu, 710, lang: 1004, "Name\tCtrl+F3", key: fkey(3), mods: [.command], action: #selector(a.viewArrangeByName(_:)))   // IDM_VIEW_ARANGE_BY_NAME
        item(menu, 711, lang: 1020, "Type\tCtrl+F4", key: fkey(4), mods: [.command], action: #selector(a.viewArrangeByType(_:)))   // IDM_VIEW_ARANGE_BY_TYPE
        item(menu, 712, lang: 1012, "Date\tCtrl+F5", key: fkey(5), mods: [.command], action: #selector(a.viewArrangeByDate(_:)))   // IDM_VIEW_ARANGE_BY_DATE
        item(menu, 713, lang: 1007, "Size\tCtrl+F6", key: fkey(6), mods: [.command], action: #selector(a.viewArrangeBySize(_:)))   // IDM_VIEW_ARANGE_BY_SIZE
        item(menu, 730, lang: 730, "Unsorted\tCtrl+F7", key: fkey(7), mods: [.command], action: #selector(a.viewArrangeNoSort(_:)))   // IDM_VIEW_ARANGE_NO_SORT
        menu.addItem(.separator())
        item(menu, 731, lang: 731, "Flat View", action: #selector(a.viewFlatView(_:)))                                            // IDM_VIEW_FLAT_VIEW
        item(menu, 732, lang: 732, "&2 Panels\tF9", key: fkey(9), action: #selector(a.viewTwoPanels(_:)))                         // IDM_VIEW_TWO_PANELS
        // popup 2017 IDM_VIEW_TIME_POPUP 760: label = current UTC time (day level), rebuilt each time the menu opens
        let time = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        time.tag = 760
        let timeMenu = NSMenu(title: "")
        timeMenu.delegate = TimeMenuDelegate.shared
        time.submenu = timeMenu
        menu.addItem(time)
        TimeMenuDelegate.shared.rebuild(timeMenu, popupItem: time)
        // popup IDM_VIEW_TOOLBARS 733
        let toolbars = NSMenuItem(title: Lang.menuTitle(733, "Toolbars"), action: nil, keyEquivalent: "")
        let toolbarsMenu = NSMenu(title: toolbars.title)
        item(toolbarsMenu, 750, lang: 750, "Archive Toolbar", action: #selector(a.viewArchiveToolbar(_:)))                    // IDM_VIEW_ARCHIVE_TOOLBAR
        item(toolbarsMenu, 751, lang: 751, "Standard Toolbar", action: #selector(a.viewStandardToolbar(_:)))                  // IDM_VIEW_STANDARD_TOOLBAR
        toolbarsMenu.addItem(.separator())
        item(toolbarsMenu, 752, lang: 752, "Large Buttons", action: #selector(a.viewToolbarsLargeButtons(_:)))                // IDM_VIEW_TOOLBARS_LARGE_BUTTONS
        item(toolbarsMenu, 753, lang: 753, "Show Buttons Text", action: #selector(a.viewToolbarsShowButtonsText(_:)))         // IDM_VIEW_TOOLBARS_SHOW_BUTTONS_TEXT
        toolbars.submenu = toolbarsMenu
        menu.addItem(toolbars)
        item(menu, 734, lang: 734, "Open Root Folder\t\\", action: #selector(a.viewOpenRootFolder(_:)))                       // IDM_OPEN_ROOT_FOLDER ("\" or "/" typed in the list)
        item(menu, 735, lang: 735, "Up One Level\tBackspace", key: String(UnicodeScalar(NSUpArrowFunctionKey)!), mods: [.command], action: #selector(a.viewOpenParentFolder(_:)))   // IDM_OPEN_PARENT_FOLDER (Backspace in the list; Cmd+Up here)
        item(menu, 736, lang: 736, "Folders History...\tAlt+F12", key: fkey(12), mods: [.option], action: #selector(a.viewFoldersHistory(_:)))   // IDM_FOLDERS_HISTORY
        item(menu, 737, lang: 737, "&Refresh\tCtrl+R", key: "r", mods: [.command], action: #selector(a.viewRefresh(_:)))       // IDM_VIEW_REFRESH
        item(menu, 738, lang: 738, "Auto Refresh", action: #selector(a.viewAutoRefresh(_:)))                                   // IDM_VIEW_AUTO_REFRESH
        let top = NSMenuItem()
        top.submenu = menu
        return top
    }

    // MARK: Favorites (IDM_FAVORITES 503) -- OnMenuActivating, MyLoadMenu.cpp:508-547

    private static func favoritesMenu() -> NSMenuItem {
        let menu = NSMenu(title: Lang.menuTitle(idmFavorites, "F&avorites"))
        menu.delegate = FavoritesMenuDelegate.shared
        FavoritesMenuDelegate.shared.rebuild(menu)
        let top = NSMenuItem()
        top.submenu = menu
        return top
    }

    // MARK: Tools (IDM_TOOLS 504)

    private static func toolsMenu() -> NSMenuItem {
        let menu = NSMenu(title: Lang.menuTitle(idmTools, "&Tools"))
        let a = MenuActions.self
        item(menu, 900, lang: 900, "&Options...", action: #selector(a.toolsOptions(_:)))                        // IDM_OPTIONS
        menu.addItem(.separator())
        item(menu, 901, lang: 901, "&Benchmark", action: #selector(a.toolsBenchmark(_:)))                       // IDM_BENCHMARK
        // IDM_BENCHMARK2 902 exists only in the Windows CE build (01-fm-feature-inventory.md 2.5)
        menu.addItem(.separator())
        item(menu, 910, lang: 910, "Delete Temporary Files...", action: #selector(a.toolsDeleteTempFiles(_:)))  // IDM_TEMP_DIR
        let top = NSMenuItem()
        top.submenu = menu
        return top
    }

    // MARK: Window (macOS standard, not in 7zFM)

    private static func windowMenu() -> NSMenuItem {
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        let top = NSMenuItem()
        top.submenu = menu
        return top
    }

    // MARK: Help (IDM_HELP 505)

    private static func helpMenu() -> NSMenuItem {
        let menu = NSMenu(title: Lang.menuTitle(idmHelp, "&Help"))
        let a = MenuActions.self
        item(menu, 960, lang: 960, "&Contents...\tF1", key: fkey(1), action: #selector(a.helpContents(_:)))    // IDM_HELP_CONTENTS
        menu.addItem(.separator())
        item(menu, 961, lang: 961, "&About 7-Zip...", action: #selector(a.helpAbout(_:)))                      // IDM_ABOUT
        NSApp.helpMenu = menu
        let top = NSMenuItem()
        top.submenu = menu
        return top
    }
}

// MARK: - Dynamic submenus

/// IDM_VIEW_TIME_POPUP: label and items show the current UTC time at each precision
/// (MyLoadMenu.cpp:437-506). Rebuilt every time the View menu opens.
final class TimeMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = TimeMenuDelegate()
    /// g_App._timestampLevels: DAY, MIN, SEC, NTFS, NS (kTimestampPrintLevel_*)
    static let levels: [Int] = [-3, -1, 0, 7, 9]
    private weak var popupItem: NSMenuItem?

    func rebuild(_ menu: NSMenu, popupItem: NSMenuItem?) {
        if let popupItem { self.popupItem = popupItem }
        menu.removeAllItems()
        let now = Date()
        self.popupItem?.title = Self.format(now, level: -3, utc: true)
        for (k, level) in Self.levels.enumerated() {
            let it = NSMenuItem(title: Self.format(now, level: level, utc: true),
                                action: #selector(MenuActions.viewTimestampLevel(_:)), keyEquivalent: "")
            it.tag = MainMenu.idmViewTime + k   // IDM_VIEW_TIME + k
            it.representedObject = level
            menu.addItem(it)
        }
        let utc = NSMenuItem(title: "UTC", action: #selector(MenuActions.viewTimeUTC(_:)), keyEquivalent: "")
        utc.tag = 799   // IDM_VIEW_TIME_UTC
        menu.addItem(utc)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu, popupItem: nil)
    }

    /// ConvertUtcFileTimeToString2 layout: "YYYY-MM-DD", "... HH:MM", "... HH:MM:SS", 7 or 9 digits.
    static func format(_ date: Date, level: Int, utc: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = utc ? TimeZone(secondsFromGMT: 0) : TimeZone.current
        switch level {
        case -3: f.dateFormat = "yyyy-MM-dd"
        case -1: f.dateFormat = "yyyy-MM-dd HH:mm"
        case 0: f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        case 7: f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSS"
        default: f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSSSS"
        }
        return f.string(from: date)
    }
}

/// Favorites: "Add folder to Favorites as" popup with 10 slots, then the 10 bookmarks.
final class FavoritesMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = FavoritesMenuDelegate()

    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let add = NSMenuItem(title: Lang.menuTitle(800, "&Add folder to Favorites as"), action: nil, keyEquivalent: "")   // IDM_ADD_TO_FAVORITES
        let addMenu = NSMenu(title: add.title)
        let bookmark = Lang.text(801, "Bookmark")   // IDS_BOOKMARK
        for i in 0..<10 {
            let it = NSMenuItem(title: "\(bookmark) \(i)", action: #selector(MenuActions.favoritesSetBookmark(_:)), keyEquivalent: "\(i)")
            it.keyEquivalentModifierMask = [.option, .shift]   // Alt+Shift+<i>
            it.tag = MainMenu.kMenuIDSetBookmark + i           // k_MenuID_SetBookmark + i
            addMenu.addItem(it)
        }
        add.submenu = addMenu
        menu.addItem(add)
        menu.addItem(.separator())
        let shortcuts = Settings.folderShortcuts
        for i in 0..<10 {
            var path = shortcuts[i]
            if path.isEmpty { path = "-" }
            if path.count > 100 { path = String(path.prefix(50)) + " ... " + String(path.suffix(50)) }
            let it = NSMenuItem(title: path, action: #selector(MenuActions.favoritesOpenBookmark(_:)), keyEquivalent: "\(i)")
            it.keyEquivalentModifierMask = [.option]           // Alt+<i>
            it.tag = MainMenu.kMenuIDOpenBookmark + i          // k_MenuID_OpenBookmark + i
            menu.addItem(it)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }
}

// MARK: - Action selectors

/// Declares every menu command as an Objective-C selector so that `#selector` can name it
/// before any responder implements it. Implementations live in the window controller and panel
/// (and in later waves' extensions); AppKit disables items nobody responds to.
@objc protocol MenuActions {
    // File
    func fileOpen(_ sender: Any?)                 // IDM_OPEN 540
    func fileOpenInside(_ sender: Any?)           // IDM_OPEN_INSIDE 541
    func fileOpenInsideOne(_ sender: Any?)        // IDM_OPEN_INSIDE_ONE 590
    func fileOpenInsideParser(_ sender: Any?)     // IDM_OPEN_INSIDE_PARSER 591
    func fileOpenOutside(_ sender: Any?)          // IDM_OPEN_OUTSIDE 542
    func fileView(_ sender: Any?)                 // IDM_FILE_VIEW 543
    func fileEdit(_ sender: Any?)                 // IDM_FILE_EDIT 544
    func fileRename(_ sender: Any?)               // IDM_RENAME 545
    func fileCopyTo(_ sender: Any?)               // IDM_COPY_TO 546
    func fileMoveTo(_ sender: Any?)               // IDM_MOVE_TO 547
    func fileDelete(_ sender: Any?)               // IDM_DELETE 548
    func fileSplit(_ sender: Any?)                // IDM_SPLIT 549
    func fileCombine(_ sender: Any?)              // IDM_COMBINE 550
    func fileProperties(_ sender: Any?)           // IDM_PROPERTIES 551
    func fileComment(_ sender: Any?)              // IDM_COMMENT 552
    func fileCalculateHash(_ sender: Any?)        // IDM_CRC32.. IDM_HASH_ALL (tag = id)
    func fileDiff(_ sender: Any?)                 // IDM_DIFF 554
    func fileCreateFolder(_ sender: Any?)         // IDM_CREATE_FOLDER 555
    func fileCreateFile(_ sender: Any?)           // IDM_CREATE_FILE 556
    func fileLink(_ sender: Any?)                 // IDM_LINK 558
    func fileAltStreams(_ sender: Any?)           // IDM_ALT_STREAMS 559
    func fileVerEdit(_ sender: Any?)              // IDM_VER_EDIT 580
    func fileVerCommit(_ sender: Any?)            // IDM_VER_COMMIT 581
    func fileVerRevert(_ sender: Any?)            // IDM_VER_REVERT 582
    func fileVerDiff(_ sender: Any?)              // IDM_VER_DIFF 583
    func fileExit(_ sender: Any?)                 // IDCLOSE 8
    // Edit
    func editSelectAll(_ sender: Any?)            // IDM_SELECT_ALL 600
    func editDeselectAll(_ sender: Any?)          // IDM_DESELECT_ALL 601
    func editInvertSelection(_ sender: Any?)      // IDM_INVERT_SELECTION 602
    func editSelect(_ sender: Any?)               // IDM_SELECT 603
    func editDeselect(_ sender: Any?)             // IDM_DESELECT 604
    func editSelectByType(_ sender: Any?)         // IDM_SELECT_BY_TYPE 605
    func editDeselectByType(_ sender: Any?)       // IDM_DESELECT_BY_TYPE 606
    // View
    func viewLargeIcons(_ sender: Any?)           // IDM_VIEW_LARGE_ICONS 700
    func viewSmallIcons(_ sender: Any?)           // IDM_VIEW_SMALL_ICONS 701
    func viewList(_ sender: Any?)                 // IDM_VIEW_LIST 702
    func viewDetails(_ sender: Any?)              // IDM_VIEW_DETAILS 703
    func viewArrangeByName(_ sender: Any?)        // IDM_VIEW_ARANGE_BY_NAME 710
    func viewArrangeByType(_ sender: Any?)        // IDM_VIEW_ARANGE_BY_TYPE 711
    func viewArrangeByDate(_ sender: Any?)        // IDM_VIEW_ARANGE_BY_DATE 712
    func viewArrangeBySize(_ sender: Any?)        // IDM_VIEW_ARANGE_BY_SIZE 713
    func viewArrangeNoSort(_ sender: Any?)        // IDM_VIEW_ARANGE_NO_SORT 730
    func viewFlatView(_ sender: Any?)             // IDM_VIEW_FLAT_VIEW 731
    func viewTwoPanels(_ sender: Any?)            // IDM_VIEW_TWO_PANELS 732
    func viewTimestampLevel(_ sender: Any?)       // IDM_VIEW_TIME 761 + k
    func viewTimeUTC(_ sender: Any?)              // IDM_VIEW_TIME_UTC 799
    func viewArchiveToolbar(_ sender: Any?)       // IDM_VIEW_ARCHIVE_TOOLBAR 750
    func viewStandardToolbar(_ sender: Any?)      // IDM_VIEW_STANDARD_TOOLBAR 751
    func viewToolbarsLargeButtons(_ sender: Any?) // IDM_VIEW_TOOLBARS_LARGE_BUTTONS 752
    func viewToolbarsShowButtonsText(_ sender: Any?) // IDM_VIEW_TOOLBARS_SHOW_BUTTONS_TEXT 753
    func viewOpenRootFolder(_ sender: Any?)       // IDM_OPEN_ROOT_FOLDER 734
    func viewOpenParentFolder(_ sender: Any?)     // IDM_OPEN_PARENT_FOLDER 735
    func viewFoldersHistory(_ sender: Any?)       // IDM_FOLDERS_HISTORY 736
    func viewRefresh(_ sender: Any?)              // IDM_VIEW_REFRESH 737
    func viewAutoRefresh(_ sender: Any?)          // IDM_VIEW_AUTO_REFRESH 738
    // Favorites
    func favoritesSetBookmark(_ sender: Any?)     // k_MenuID_SetBookmark 810 + i
    func favoritesOpenBookmark(_ sender: Any?)    // k_MenuID_OpenBookmark 830 + i
    // Tools
    func toolsOptions(_ sender: Any?)             // IDM_OPTIONS 900
    func toolsBenchmark(_ sender: Any?)           // IDM_BENCHMARK 901
    func toolsDeleteTempFiles(_ sender: Any?)     // IDM_TEMP_DIR 910
    // Help
    func helpContents(_ sender: Any?)             // IDM_HELP_CONTENTS 960
    func helpAbout(_ sender: Any?)                // IDM_ABOUT 961
    // Toolbar-only commands (kMenuCmdID_Toolbar_Add/Extract/Test 1070-1072)
    func toolbarAddToArchive(_ sender: Any?)
    func toolbarExtractArchives(_ sender: Any?)
    func toolbarTestArchives(_ sender: Any?)
}
