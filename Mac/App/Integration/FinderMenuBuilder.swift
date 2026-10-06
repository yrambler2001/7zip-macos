// FinderMenuBuilder.swift -- turns a `FinderMenuModel` tree into the `NSMenu` the Finder Sync
// extension returns from `menu(for:)` (03-shell-integration-inventory.md section 1.4).
//
// finderfix: Finder copies that menu into its own process and keeps only an item's title, image,
// tag, action and submenu -- never `representedObject` or `target`. Every command item is therefore
// numbered through `tag` in `FinderMenuModel.flattenCommands` order, which is what
// `FinderMenuModel.resolveInvocation` reads back when the click arrives. Split out of
// `FinderSync.swift` so the unit tests can build the very menu Finder receives.
//
// AppKit only; compiled into the Finder Sync appex and the unit tests.

import AppKit

enum FinderMenuBuilder {

    /// The menu for `nodes`. `action` is sent to the extension's principal object (Finder ignores
    /// `target`); `image` goes on every item when the user asked for menu icons.
    static func menu(for nodes: [FinderMenuNode], action: Selector, image: NSImage?) -> NSMenu {
        let menu = NSMenu(title: "")
        var counter = 0
        append(nodes, to: menu, counter: &counter, action: action, image: image)
        return menu
    }

    private static func append(_ nodes: [FinderMenuNode], to menu: NSMenu, counter: inout Int,
                               action: Selector, image: NSImage?) {
        for node in nodes {
            switch node {
            case .separator:
                menu.addItem(.separator())
            case .command(let command):
                let item = NSMenuItem(title: command.title, action: action, keyEquivalent: "")
                item.tag = FinderMenuModel.menuTag(forIndex: counter)
                counter += 1
                item.image = image
                menu.addItem(item)
            case .submenu(let title, _, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                item.image = image
                let submenu = NSMenu(title: title)
                append(children, to: submenu, counter: &counter, action: action, image: image)
                item.submenu = submenu
                menu.addItem(item)
            }
        }
    }

    /// Every command item of `menu`, depth first -- what a click can deliver.
    static func commandItems(of menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in
            if let submenu = item.submenu { return commandItems(of: submenu) }
            return item.action == nil || item.isSeparatorItem ? [] : [item]
        }
    }
}
