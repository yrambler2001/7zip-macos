// EditMenuCleanup.swift -- keeps the Edit menu 7zFM's (recheck2, recheck.md section 8 item 4).
//
// AppKit appends "AutoFill", "Start Dictation..." and "Emoji & Symbols" to the menu it takes for the
// Edit menu. 7zFM's Edit menu (IDM_EDIT 501) has none of them (recheck-data/win/menu-main.txt), and
// nothing in the app uses them. Dictation and the character palette have AppKit's own switches
// (NSDisabledDictationMenuItem, NSDisabledCharacterPaletteMenuItem, registered before the menu bar
// is built); AutoFill has none, so every item AppKit adds is taken out again as it arrives and
// before the menu opens.

import AppKit

final class EditMenuCleanup: NSObject, NSMenuDelegate {

    static let shared = EditMenuCleanup()

    /// Call with the Edit menu as it is built (applicationWillFinishLaunching, before AppKit adds
    /// its items).
    static func adopt(_ menu: NSMenu) {
        UserDefaults.standard.register(defaults: ["NSDisabledDictationMenuItem": true,
                                                  "NSDisabledCharacterPaletteMenuItem": true])
        menu.delegate = shared
        NotificationCenter.default.addObserver(shared, selector: #selector(itemAdded(_:)),
                                               name: NSMenu.didAddItemNotification, object: menu)
    }

    /// True for an item AppKit adds to an Edit menu.
    static func isSystemItem(_ item: NSMenuItem) -> Bool {
        let action = item.action.map(NSStringFromSelector) ?? ""
        if action == "startDictation:" || action == "orderFrontCharacterPalette:" { return true }
        if action.range(of: "autofill", options: .caseInsensitive) != nil { return true }
        if item.title.range(of: "autofill", options: .caseInsensitive) != nil { return true }
        if let submenu = item.submenu, !submenu.items.isEmpty, submenu.items.allSatisfy(isSystemItem) { return true }
        return false
    }

    static func clean(_ menu: NSMenu) {
        for item in menu.items.reversed() where isSystemItem(item) { menu.removeItem(item) }
        // A separator AppKit put in front of its items, now trailing.
        while let last = menu.items.last, last.isSeparatorItem { menu.removeItem(last) }
    }

    @objc private func itemAdded(_ note: Notification) {
        guard let menu = note.object as? NSMenu else { return }
        // Not while AppKit is still inserting: once the current pass is done.
        DispatchQueue.main.async { Self.clean(menu) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { Self.clean(menu) }
    func menuWillOpen(_ menu: NSMenu) { Self.clean(menu) }
}
