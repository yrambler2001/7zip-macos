// FinderSync.swift -- Finder Sync extension stub (Wave 1). Registers for the whole file
// system and shows one placeholder "7-Zip" item in Finder's context menu and toolbar menu.
// Later waves build the full 7-Zip menu (03-shell-integration-inventory.md sections 1 and 6)
// and forward commands to the app through the sevenzip:// URL scheme.

import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {

    override init() {
        super.init()
        // 7-Zip's Explorer extension is available everywhere; monitor the volume roots.
        FIFinderSyncController.default().directoryURLs = [
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/Volumes"),
            URL(fileURLWithPath: NSHomeDirectory() + "/Library/CloudStorage"),
        ]
    }

    override var toolbarItemName: String { "7-Zip" }
    override var toolbarItemToolTip: String { "7-Zip" }
    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "archivebox", accessibilityDescription: "7-Zip") ?? NSImage()
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "")
        // Placeholder: the real submenu (Open archive, Extract Here, Add to archive..., CRC SHA)
        // is built by the shell-integration wave from the ContextMenu flags.
        menu.addItem(withTitle: "7-Zip", action: #selector(placeholder(_:)), keyEquivalent: "")
        return menu
    }

    @objc private func placeholder(_ sender: AnyObject?) {
        // intentionally does nothing in Wave 1
    }
}
