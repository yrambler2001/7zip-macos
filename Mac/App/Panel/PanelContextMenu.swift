// PanelContextMenu.swift -- the list context menu (CPanel::OnContextMenu / CreateFileMenu,
// PanelMenu.cpp:921-1160) and the column header menu (ShowColumnsContextMenu,
// PanelItems.cpp:1396-1449).
//
// Composition for a non-archive folder, in Windows order (01 §2.8):
//   1. the 7-Zip Explorer commands (CreateSevenZipMenu, IDs from kMenuCmdID_Plugin_Start 1100),
//   2. the "System" submenu (IDS_SYSTEM 7103) when ShowSystemMenu is on -- on macOS the shell
//      verbs become Open With / Show in Finder / Quick Look / Get Info (01 §9 #2),
//   3. the File-menu items without Exit.
// Inside an archive only step 3 is shown, exactly as on Windows.
//
// The archive verbs send the selectors below down the responder chain. `MainWindowController`
// implements every one of them (`Mac/App/Commands/PanelContextActions.swift`) by calling the very
// command the File menu, the toolbar and Finder use -- see Mac/docs/api/panel.md section 3.

import Cocoa
import Quartz
import SevenZipKit

/// The 7-Zip context verbs a command scope may implement (01 §2.9). `sender.representedObject`
/// carries the `PanelContextTarget` the menu was built for.
@objc protocol PanelContextCommands {
    func sevenZipOpenArchive(_ sender: Any?)          // kOpen
    func sevenZipOpenArchiveAs(_ sender: Any?)        // kOpen with a type ("*", "#", "7z", ...)
    func sevenZipExtractFiles(_ sender: Any?)         // kExtract
    func sevenZipExtractHere(_ sender: Any?)          // kExtractHere
    func sevenZipExtractTo(_ sender: Any?)            // kExtractTo
    func sevenZipTestArchive(_ sender: Any?)          // kTest
    func sevenZipCompress(_ sender: Any?)             // kCompress
    func sevenZipCompressEmail(_ sender: Any?)        // kCompressEmail
    func sevenZipCompressTo7z(_ sender: Any?)         // kCompressTo7z
    func sevenZipCompressToZip(_ sender: Any?)        // kCompressToZip
}

/// What a context command applies to; handed over as the menu item's representedObject.
final class PanelContextTarget: NSObject {
    let paths: [String]
    let folderPath: String
    let names: [String]
    let formatHint: String?
    let archiveName: String?
    init(paths: [String], folderPath: String, names: [String], formatHint: String? = nil, archiveName: String? = nil) {
        self.paths = paths
        self.folderPath = folderPath
        self.names = names
        self.formatHint = formatHint
        self.archiveName = archiveName
    }
}

extension PanelViewController {

    /// Extensions that are never offered Open / Extract / Test (kExtractExcludeExtensions,
    /// ContextMenu.cpp:494-517).
    static let extractExcludeExtensions: Set<String> = [
        "3gp", "aac", "ans", "ape", "asc", "asm", "asp", "aspx", "avi", "awk", "bas", "bat", "bmp",
        "c", "cs", "cls", "clw", "cmd", "cpp", "csproj", "css", "ctl", "cxx", "def", "dep", "dlg",
        "dsp", "dsw", "eps", "f", "f77", "f90", "f95", "fla", "flac", "frm", "gif", "h", "hpp",
        "hta", "htm", "html", "hxx", "ico", "idl", "inc", "ini", "inl", "java", "jpeg", "jpg", "js",
        "la", "lnk", "log", "mak", "manifest", "wmv", "mov", "mp3", "mp4", "mpe", "mpeg", "mpg",
        "m4a", "ofr", "ogg", "pac", "pas", "pdf", "php", "php3", "php4", "php5", "phptml", "pl",
        "pm", "png", "ps", "py", "pyo", "ra", "rb", "rc", "reg", "rka", "rm", "rtf", "sed", "sh",
        "shn", "shtml", "sln", "sql", "srt", "swa", "tcl", "tex", "tiff", "tta", "txt", "vb",
        "vcproj", "vbs", "mkv", "wav", "webm", "wma", "wv", "xml", "xsd", "xsl", "xslt",
    ]

    /// kOpenTypes (ContextMenu.cpp:524) for the "Open archive >" sub-menu.
    static let openTypes: [String] = ["*", "#", "#:e", "7z", "zip", "cab", "rar"]

    func makeItemContextMenu() -> NSMenu {
        // A right click focuses the panel it lands in (NM_RCLICK on the list sets the focus), so
        // the command an item sends acts on *this* panel's operated items through ActiveContext.
        delegate?.panelDidBecomeActive(self)
        let menu = NSMenu()
        let snap = snapshot
        let items = operatedRowIndices().map { rows[$0] }
        if let snap, !snap.isArchive {
            addSevenZipCommands(to: menu, items: items, snapshot: snap)
            if Settings.showSystemMenu {
                addSystemMenu(to: menu, items: items)
            }
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
        }
        addFileMenuItems(to: menu)
        return menu
    }

    /// CreateSevenZipMenu (PanelMenu.cpp:792) filtered by the ContextMenu flag mask (01 §2.9).
    private func addSevenZipCommands(to menu: NSMenu, items: [PanelRow], snapshot snap: PanelSnapshot) {
        guard !items.isEmpty else { return }
        let flags = Settings.contextMenuFlags
        let paths = items.compactMap { $0.fullPath.isEmpty ? nil : $0.fullPath }
        guard !paths.isEmpty else { return }
        let names = items.map { $0.name }
        let target = PanelContextTarget(paths: paths, folderPath: snap.fullPath, names: names)
        let single = items.count == 1 ? items[0] : nil
        let needExtract = Self.needExtract(items: items, extendedVerbs: Self.extendedVerbsRequested)
        // kOpen and its "Open archive >" sub-menu: one file that passes DoNeedExtract
        // (ContextMenu.cpp:741-788).
        let archiveLike = single.map { Self.needExtract(items: [$0], extendedVerbs: false) } ?? false

        if archiveLike, flags.contains(.open) {
            add(menu, Lang.text(2322, "Open archive"), #selector(PanelContextCommands.sevenZipOpenArchive(_:)), target)
            if flags.contains(.openAs) {
                let openAs = NSMenuItem(title: Lang.text(2322, "Open archive"), action: nil, keyEquivalent: "")
                let sub = NSMenu()
                for type in Self.openTypes {
                    let item = NSMenuItem(title: type, action: #selector(PanelContextCommands.sevenZipOpenArchiveAs(_:)),
                                          keyEquivalent: "")
                    item.representedObject = PanelContextTarget(paths: paths, folderPath: snap.fullPath,
                                                               names: names, formatHint: type)
                    sub.addItem(item)
                }
                openAs.submenu = sub
                menu.addItem(openAs)
            }
        }
        if needExtract {
            if flags.contains(.extractFiles) {
                add(menu, Lang.text(2323, "Extract files..."), #selector(PanelContextCommands.sevenZipExtractFiles(_:)), target)
            }
            if flags.contains(.extractHere) {
                add(menu, Lang.text(2326, "Extract Here"), #selector(PanelContextCommands.sevenZipExtractHere(_:)), target)
            }
            if flags.contains(.extractTo) {
                // GetSubFolderNameForExtract for one archive, "*" for several (ContextMenu.cpp:836).
                let folder = single.map { SZArchiveExtractor.subfolderName(forArchiveNamed: $0.name) } ?? "*"
                add(menu, Lang.format(Lang.get(2327, "Extract to {0}"), "\"" + folder + "/\""),
                    #selector(PanelContextCommands.sevenZipExtractTo(_:)), target)
            }
            if flags.contains(.test) {
                add(menu, Lang.text(2325, "Test archive"), #selector(PanelContextCommands.sevenZipTestArchive(_:)), target)
            }
        }
        if flags.contains(.compress) {
            add(menu, Lang.text(2324, "Add to archive..."), #selector(PanelContextCommands.sevenZipCompress(_:)), target)
        }
        if flags.contains(.compressEmail) {
            add(menu, Lang.text(2329, "Compress and email..."), #selector(PanelContextCommands.sevenZipCompressEmail(_:)), target)
        }
        let base = PanelContextMenuNaming.archiveBaseName(names: names, folderPath: snap.fullPath)
        if flags.contains(.compressTo7z) {
            add(menu, Lang.format(Lang.get(2328, "Add to {0}"), "\"" + base + ".7z\""),
                #selector(PanelContextCommands.sevenZipCompressTo7z(_:)),
                PanelContextTarget(paths: paths, folderPath: snap.fullPath, names: names,
                                   archiveName: base + ".7z"))
        }
        if flags.contains(.compressToZip) {
            add(menu, Lang.format(Lang.get(2328, "Add to {0}"), "\"" + base + ".zip\""),
                #selector(PanelContextCommands.sevenZipCompressToZip(_:)),
                PanelContextTarget(paths: paths, folderPath: snap.fullPath, names: names,
                                   archiveName: base + ".zip"))
        }
        if flags.contains(.crc) {
            let crc = NSMenuItem(title: Lang.text(2350, "CRC SHA"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (tag, name) in [(102, "CRC-32"), (103, "CRC-64"), (120, "XXH64"), (122, "MD5"), (104, "SHA-1"),
                                (105, "SHA-256"), (106, "SHA-384"), (107, "SHA-512"), (108, "SHA3-256"),
                                (121, "BLAKE2sp"), (101, "*")] {
                let item = NSMenuItem(title: name, action: #selector(MenuActions.fileCalculateHash(_:)), keyEquivalent: "")
                item.tag = tag
                sub.addItem(item)
            }
            crc.submenu = sub
            menu.addItem(crc)
        }
    }

    /// `needExtract` of CZipContextMenu::QueryContextMenu (ContextMenu.cpp:797-825): no directory
    /// among the items and every name passes DoNeedExtract (its extension is not in
    /// kExtractExcludeExtensions). With the extended verbs (Shift held, CMF_EXTENDEDVERBS) the name
    /// check is skipped and only the directory rule is left.
    static func needExtract(items: [PanelRow], extendedVerbs: Bool) -> Bool {
        guard !items.isEmpty, !items.contains(where: { $0.isDirectory || $0.isParentRow }) else { return false }
        if extendedVerbs { return true }
        return items.allSatisfy { !extractExcludeExtensions.contains($0.pathExtension.lowercased()) }
    }

    /// CMF_EXTENDEDVERBS: Shift held while the menu is requested.
    static var extendedVerbsRequested: Bool {
        NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, _ target: PanelContextTarget) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.representedObject = target
        menu.addItem(item)
    }

    /// CreateSystemMenu (PanelMenu.cpp:688) replaced by the macOS equivalents (01 §9 #2).
    private func addSystemMenu(to menu: NSMenu, items: [PanelRow]) {
        let paths = items.compactMap { $0.fullPath.isEmpty ? nil : $0.fullPath }
        guard !paths.isEmpty else { return }
        let system = NSMenuItem(title: Lang.text(7103, "System"), action: nil, keyEquivalent: "")
        let sub = NSMenu()
        // The three macOS verbs have no 7-Zip lang ID; "Get Info" opens the Properties dialog.
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let appsMenu = NSMenu()
        if let first = paths.first {
            for app in NSWorkspace.shared.urlsForApplications(toOpen: URL(fileURLWithPath: first)).prefix(12) {
                let item = NSMenuItem(title: FileManager.default.displayName(atPath: app.path),
                                      action: #selector(openWithApplication(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = [app.path, paths] as [Any]
                appsMenu.addItem(item)
            }
        }
        openWith.submenu = appsMenu
        sub.addItem(openWith)
        let reveal = NSMenuItem(title: "Show in Finder", action: #selector(showInFinder(_:)), keyEquivalent: "")
        reveal.target = self
        sub.addItem(reveal)
        let quickLook = NSMenuItem(title: "Quick Look", action: #selector(quickLook(_:)), keyEquivalent: "")
        quickLook.target = self
        sub.addItem(quickLook)
        let info = NSMenuItem(title: Lang.text(6600, "Properties"), action: #selector(fileProperties(_:)), keyEquivalent: "")
        sub.addItem(info)
        system.submenu = sub
        menu.addItem(system)
    }

    /// CFileMenu::Load without Exit (01 §2.1, §2.8).
    private func addFileMenuItems(to menu: NSMenu) {
        func item(_ lang: UInt32, _ fallback: String, _ action: Selector) {
            menu.addItem(NSMenuItem(title: Lang.text(lang, fallback), action: action, keyEquivalent: ""))
        }
        item(540, "Open", #selector(fileOpen(_:)))                                  // IDM_OPEN
        item(541, "Open Inside", #selector(fileOpenInside(_:)))                     // IDM_OPEN_INSIDE
        item(542, "Open Outside", #selector(fileOpenOutside(_:)))                   // IDM_OPEN_OUTSIDE
        item(543, "View", #selector(fileView(_:)))                                  // IDM_FILE_VIEW
        item(544, "Edit", #selector(fileEdit(_:)))                                  // IDM_FILE_EDIT
        menu.addItem(.separator())
        item(545, "Rename", #selector(fileRename(_:)))                              // IDM_RENAME
        item(546, "Copy To...", #selector(MenuActions.fileCopyTo(_:)))               // IDM_COPY_TO
        item(547, "Move To...", #selector(MenuActions.fileMoveTo(_:)))               // IDM_MOVE_TO
        item(548, "Delete", #selector(fileDelete(_:)))                              // IDM_DELETE
        menu.addItem(.separator())
        item(549, "Split file...", #selector(MenuActions.fileSplit(_:)))             // IDM_SPLIT
        item(550, "Combine files...", #selector(MenuActions.fileCombine(_:)))        // IDM_COMBINE
        menu.addItem(.separator())
        item(551, "Properties", #selector(fileProperties(_:)))                       // IDM_PROPERTIES
        item(552, "Comment...", #selector(fileComment(_:)))                          // IDM_COMMENT
        item(554, "Diff", #selector(MenuActions.fileDiff(_:)))                        // IDM_DIFF
        menu.addItem(.separator())
        item(555, "Create Folder", #selector(fileCreateFolder(_:)))                  // IDM_CREATE_FOLDER
        item(556, "Create File", #selector(fileCreateFile(_:)))                      // IDM_CREATE_FILE
        item(558, "Link...", #selector(MenuActions.fileLink(_:)))                     // IDM_LINK
    }

    // MARK: - Column header menu (ShowColumnsContextMenu)

    func makeColumnsContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false        // so the Name item stays grayed, as on Windows
        for column in columnsModel.columns {
            let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
            item.target = self
            item.state = column.visible ? .on : .off
            item.tag = Int(column.propID.rawValue)
            item.isEnabled = !column.isName                 // Name is grayed and always on
            menu.addItem(item)
        }
        return menu
    }

    @objc private func toggleColumn(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let pid = SZPropID(rawValue: UInt32(truncatingIfNeeded: item.tag)) else { return }
        let visible = item.state != .on
        columnsModel.setVisible(visible, propID: pid)
        Settings.setColumnLayout(columnsModel.layout(), forFolderType: snapshot?.folderType ?? "")
        rebuildVisibleColumns()
    }

    /// Re-init the columns after a visibility change (InitColumns).
    func rebuildVisibleColumns() {
        for column in tableView.tableColumns { tableView.removeTableColumn(column) }
        for info in columnsModel.visibleColumns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(info.propID.rawValue)))
            column.title = info.title
            column.width = CGFloat(info.width)
            column.minWidth = 24
            column.maxWidth = 2000
            column.headerCell.alignment = PanelFormat.alignment(for: info.varType, propID: info.propID)
            tableView.addTableColumn(column)
        }
        tableView.reloadData()
    }

    // MARK: - System submenu actions

    @objc private func openWithApplication(_ sender: Any?) {
        guard let info = (sender as? NSMenuItem)?.representedObject as? [Any], info.count == 2,
              let appPath = info[0] as? String, let paths = info[1] as? [String] else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(paths.map { URL(fileURLWithPath: $0) },
                                withApplicationAt: URL(fileURLWithPath: appPath),
                                configuration: configuration)
    }

    @objc private func showInFinder(_ sender: Any?) {
        let urls = operatedRowIndices().map { rows[$0] }.filter { !$0.fullPath.isEmpty }
            .map { URL(fileURLWithPath: $0.fullPath) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    @objc func quickLook(_ sender: Any?) {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

/// CreateArchiveName (ArchiveName.cpp): the base name a "Add to <name>.7z" command proposes.
enum PanelContextMenuNaming {
    static func archiveBaseName(names: [String], folderPath: String) -> String {
        if names.count == 1 {
            let name = names[0]
            let base = (name as NSString).deletingPathExtension
            return base.isEmpty ? name : base
        }
        var folder = folderPath
        if folder.hasSuffix("/") { folder.removeLast() }
        let last = (folder as NSString).lastPathComponent
        return last.isEmpty ? "Archive" : last
    }
}

// MARK: - Quick Look data source (the System submenu's Quick Look entry)

extension PanelViewController: QLPreviewPanelDataSource, QLPreviewPanelDelegate {

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        operatedRowIndices().filter { !rows[$0].fullPath.isEmpty }.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        let paths = operatedRowIndices().map { rows[$0].fullPath }.filter { !$0.isEmpty }
        guard index >= 0, index < paths.count else { return nil }
        return URL(fileURLWithPath: paths[index]) as QLPreviewItem
    }
}
