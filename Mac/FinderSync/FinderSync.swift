// FinderSync.swift -- the 7-Zip Finder Sync extension: the macOS stand-in for `7-zip.dll`'s
// `IContextMenu` / `IExplorerCommand` handlers (03-shell-integration-inventory.md section 1,
// section 6.1, section 6.3 recommendation 1).
//
// The item set, its order, its nesting and every condition come from `FinderMenuModel`, which is
// `CZipContextMenu::QueryContextMenu` ported one to one and unit-tested. This file only turns that
// tree into an `NSMenu` and, on invoke, hands the command to the app.
//
// Sandbox rules this file obeys (03 section 6.4):
//  * the appex is sandboxed (`FinderSync.entitlements`); an unsandboxed one is refused by the
//    system;
//  * it never reads or writes a selected file: the item list goes to the app as `-aiw-!<path>`
//    switches, or -- for a long selection -- as a UTF-8 list file inside its **own** container,
//    which the unsandboxed app can read and then deletes;
//  * it never spawns a process: `NSWorkspace.open(URL)` with the `sevenzip://` scheme is the only
//    hand-off, and the app's `CommandExecutor` is the single place a command runs;
//  * it never badges. `directoryURLs` contains `/`, so badging would be evaluated for every
//    visible item, and Finder shows at most one badge per item anyway when several extensions
//    overlap (03 section 6.3).

import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {

    /// The 16 pt menu image, built once (`IDB_MENU_LOGO` / `MenuLogo.bmp`, 03 section 1.3).
    private lazy var menuImage: NSImage? = {
        let icon = NSWorkspace.shared.icon(forFile: SevenZipBundle.containingAppURL.path)
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }()

    override init() {
        super.init()
        // 7-Zip's Explorer extension is available everywhere, so the whole file system is
        // monitored. `/Volumes` and `~/Library/CloudStorage` are added because items on File
        // Provider domains and some network volumes are not under `/` from Finder's point of view
        // (03 section 6.3).
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/Volumes"),
            URL(fileURLWithPath: SevenZipBundle.realHomeDirectory + "/Library/CloudStorage"),
        ]
    }

    // MARK: - Observation (deliberate no-ops)

    override func beginObservingDirectory(at url: URL) {
        // No badges, so there is nothing to watch: monitoring `/` would otherwise make Finder
        // evaluate a badge for every visible item.
    }

    override func endObservingDirectory(at url: URL) {}

    override func requestBadgeIdentifier(for url: URL) {
        // Intentionally empty: `setBadgeImage` is never called (03 section 6.3).
    }

    // MARK: - Toolbar button

    override var toolbarItemName: String { "7-Zip" }
    override var toolbarItemToolTip: String { "7-Zip" }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "archivebox", accessibilityDescription: "7-Zip") ?? NSImage()
    }

    // MARK: - The menu

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        switch menuKind {
        case .contextualMenuForItems, .toolbarItemMenu:
            break
        default:
            // The sidebar and the folder-background menus stay empty: 7-Zip's Explorer handler is
            // registered for selected items and for drag-drop targets only (03 section 1.1).
            return nil
        }

        let urls = FIFinderSyncController.default().selectedItemURLs() ?? []
        guard !urls.isEmpty else { return nil }

        let selection = FinderSelection(urls: urls)
        let settings = IntegrationSettings.current(extensionBundleID: SevenZipBundle.finderSync)
        // `CMF_EXTENDEDVERBS`: Shift+right-click relaxes the extension filter for the extract
        // group (03 section 1.4).
        let extended = NSEvent.modifierFlags.contains(.shift)
        let nodes = FinderMenuModel.build(selection: selection, settings: settings,
                                         extendedVerbs: extended)
        guard !nodes.isEmpty else { return nil }

        let menu = NSMenu(title: "")
        // Finder inserts the extension's items into its own menu, so the flat mode's leading
        // separator is already the one `:667-675` adds; keep it for the same visual grouping.
        append(nodes, to: menu, selection: selection, showIcons: settings.menuIcons)
        return menu
    }

    private func append(_ nodes: [FinderMenuNode], to menu: NSMenu,
                        selection: FinderSelection, showIcons: Bool) {
        for node in nodes {
            switch node {
            case .separator:
                menu.addItem(.separator())
            case .command(let command):
                let item = NSMenuItem(title: command.title, action: #selector(invoke(_:)),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = InvocationTarget(command: command, selection: selection)
                if showIcons { item.image = menuImage }
                menu.addItem(item)
            case .submenu(let title, _, let children):
                let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                if showIcons { item.image = menuImage }
                let submenu = NSMenu(title: title)
                append(children, to: submenu, selection: selection, showIcons: showIcons)
                item.submenu = submenu
                menu.addItem(item)
            }
        }
    }

    /// What a menu item carries; Finder re-creates the menu per click, so this is short-lived.
    private final class InvocationTarget: NSObject {
        let command: FinderMenuCommand
        let selection: FinderSelection
        init(command: FinderMenuCommand, selection: FinderSelection) {
            self.command = command
            self.selection = selection
        }
    }

    // MARK: - Invoke

    @objc private func invoke(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? InvocationTarget else { return }
        // The selection is re-read so a long one gets its list file only now, which is also when
        // Explorer recomputes the real names (ContextMenu.cpp:1305-1323).
        let paths = FIFinderSyncController.default().selectedItemURLs()?.map(\.path)
            ?? target.selection.paths
        let built = target.command.argv(for: paths, listFileDirectory: NSTemporaryDirectory())
        guard let url = CommandURL.url(argv: built.argv, temporaryFiles: built.temporaryFiles) else {
            return
        }
        // A sandboxed extension may open a URL but not spawn a process; the app parses the same
        // argv 7zG would have received. Errors (a folder in an extract selection, an unsupported
        // type) are reported by the app, which owns the message boxes.
        NSWorkspace.shared.open(url)
    }
}
