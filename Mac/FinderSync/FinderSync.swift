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
//  * it never spawns a process: a `sevenzip://` URL opened in the containing app
//    (`ExtensionHandoff`) is the only hand-off, and the app's `CommandExecutor` is the single place
//    a command runs;
//  * Finder copies the returned menu into its own process and keeps only title, image, tag and
//    action: `representedObject` and `target` do not survive (finderfix). So each command item is
//    numbered by `tag` and the command is looked up again at invoke time
//    (`FinderMenuModel.resolveInvocation`);
//  * it never badges. `directoryURLs` contains `/`, so badging would be evaluated for every
//    visible item, and Finder shows at most one badge per item anyway when several extensions
//    overlap (03 section 6.3).

import Cocoa
import FinderSync
import os

private let log = Logger(subsystem: ExtensionHandoff.subsystem, category: "FinderSync")

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
        // The invoke may reach another instance of this class, so the one thing the tree depends
        // on that cannot be re-read at click time is kept process-wide.
        FinderSync.lastExtendedVerbs = extended
        FinderSync.lastSelection = selection

        // Finder inserts the extension's items into its own menu, so the flat mode's leading
        // separator is already the one `:667-675` adds; keep it for the same visual grouping.
        let menu = FinderMenuBuilder.menu(for: nodes, action: #selector(invoke(_:)),
                                          image: settings.menuIcons ? menuImage : nil)
        log.log("menu: \(FinderMenuModel.flattenCommands(nodes).count, privacy: .public) commands for \(urls.count, privacy: .public) items")
        return menu
    }

    /// `Shift` at the time the menu was built (`CMF_EXTENDEDVERBS`).
    private static var lastExtendedVerbs = false
    /// The selection the menu was built for, used when Finder reports none at click time.
    private static var lastSelection: FinderSelection?

    // MARK: - Invoke

    @objc private func invoke(_ sender: NSMenuItem) {
        // The selection is re-read so a long one gets its list file only now, which is also when
        // Explorer recomputes the real names (ContextMenu.cpp:1305-1323).
        let current = FIFinderSyncController.default().selectedItemURLs() ?? []
        let selection = current.isEmpty ? FinderSync.lastSelection : FinderSelection(urls: current)
        log.log("invoke: tag \(sender.tag, privacy: .public) \"\(sender.title, privacy: .public)\"")
        guard let selection, !selection.isEmpty else {
            ExtensionHandoff.report(.noItems, log: log)
            return
        }
        let settings = IntegrationSettings.current(extensionBundleID: SevenZipBundle.finderSync)
        let nodes = FinderMenuModel.build(selection: selection, settings: settings,
                                         extendedVerbs: FinderSync.lastExtendedVerbs)
        guard let command = FinderMenuModel.resolveInvocation(tag: sender.tag, title: sender.title,
                                                              nodes: nodes) else {
            ExtensionHandoff.report(.unknownCommand, log: log)
            return
        }
        let built = command.argv(for: selection.paths, listFileDirectory: NSTemporaryDirectory())
        guard let url = CommandURL.url(argv: built.argv, temporaryFiles: built.temporaryFiles) else {
            ExtensionHandoff.report(.unknownCommand, log: log)
            return
        }
        // A sandboxed extension may open a URL but not spawn a process; the app parses the same
        // argv 7zG would have received. Errors (a folder in an extract selection, an unsupported
        // type) are reported by the app, which owns the message boxes.
        log.log("invoke: \(command.verb, privacy: .public)")
        ExtensionHandoff.send(url, log: log)
    }
}
