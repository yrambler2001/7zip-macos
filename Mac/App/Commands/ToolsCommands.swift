// ToolsCommands.swift -- the Tools / CRC / Split / Combine / Link / Help commands of the
// menu bar, implemented on MainWindowController (the responder that owns the panels).
//
// Parity references: File > CRC submenu (01-fm-feature-inventory.md 2.1, 3.13),
// File > Split / Combine (3.14), File > Link (3.11, 01b 4.10), Tools > Benchmark (2.5),
// Tools > Delete Temporary Files (2.5, 01b 4.3), Help > Contents / About (2.6, 01b 4.1).

import AppKit
import SevenZipKit

// MARK: - reading the operated items out of a panel

/// What a command needs to know about the panel it acts on. The `panel` scope owns the panel
/// internals, so this reads only its public surface: `snapshot` (folder path, kind, rows),
/// `flatMode`, and the list selection through the panel's NSTableView.
/// See Mac/docs/api/tools.md: once `panel` exposes `operatedItems` this helper becomes a
/// one-line forward.
struct ToolsPanelItems {
    /// CPanel::GetFsPath() / the address-bar path, always with a trailing "/".
    var folderPath: String
    var isFileSystem: Bool
    var isArchive: Bool
    var isFlatView: Bool
    /// Get_ItemIndices_OperSmart: the selected rows, or the focused row when none is selected.
    var rows: [PanelRow]

    var names: [String] { rows.map { $0.name } }
    /// `<folder><prefix><name>` for a file-system folder (GetItemRelPath is prefix + name).
    var relativePaths: [String] { rows.map { $0.name } }
    var fullPaths: [String] { rows.map { folderPath + $0.name } }
}

enum ToolsPanelAccess {

    /// Every PanelViewController in the window, left to right. A view controller inserts
    /// itself into its view's responder chain, so the controllers can be found from the views.
    static func panels(in window: NSWindow?) -> [PanelViewController] {
        guard let root = window?.contentView else { return [] }
        var found: [PanelViewController] = []
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let controller = view.nextResponder as? PanelViewController, !found.contains(controller) {
                found.append(controller)
            }
            stack.append(contentsOf: view.subviews)
        }
        return found.sorted { $0.panelIndex < $1.panelIndex }
    }

    /// The panel's list view (the only PanelTableView in its subtree).
    static func tableView(of panel: PanelViewController) -> NSTableView? {
        var stack: [NSView] = [panel.view]
        while let view = stack.popLast() {
            if let table = view as? NSTableView { return table }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Get_ItemIndices_OperSmart (PanelItems.cpp): the selected items, or the focused one.
    static func operatedItems(of panel: PanelViewController) -> ToolsPanelItems? {
        guard let snapshot = panel.snapshot else { return nil }
        var rows: [PanelRow] = []
        if let table = tableView(of: panel) {
            let nameColumn = table.tableColumns.firstIndex {
                $0.identifier.rawValue == String(SZPropID.name.rawValue)
            }
            var indexes = table.selectedRowIndexes
            if indexes.isEmpty, table.selectedRow >= 0 { indexes = IndexSet(integer: table.selectedRow) }
            // The panel re-sorts its rows after loading, so the list index is not the snapshot
            // index; match on the displayed name instead (names are unique inside a folder).
            let byDisplayName = Dictionary(snapshot.rows.map { ($0.displayName, $0) },
                                           uniquingKeysWith: { a, _ in a })
            for index in indexes {
                guard let column = nameColumn,
                      let cell = table.view(atColumn: column, row: index, makeIfNecessary: true) as? NSTableCellView,
                      let text = cell.textField?.stringValue,
                      let row = byDisplayName[text], !row.isParentRow else { continue }
                rows.append(row)
            }
        }
        return ToolsPanelItems(folderPath: snapshot.fullPath,
                               isFileSystem: snapshot.isFileSystem,
                               isArchive: snapshot.isArchive,
                               isFlatView: panel.flatMode,
                               rows: rows)
    }
}

// MARK: - error boxes 7zFM shows before a command starts

enum ToolsAlerts {

    /// MessageBox_Error_UnsupportOperation (Panel.cpp): lang 6008.
    static func unsupportedOperation(_ window: NSWindow?) {
        error(Lang.text(6008, "The operation is not supported for this folder."), window)
    }

    /// MessageBox_Error_LangID
    static func error(_ text: String, _ window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = "7-Zip"
        alert.informativeText = text
        alert.alertStyle = .critical
        alert.addButton(withTitle: Lang.text(401, "OK"))
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    /// MB_YESNOCANCEL question; true only on Yes.
    static func confirm(title: String, message: String, _ window: NSWindow?) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: Lang.text(406, "Yes"))
        alert.addButton(withTitle: Lang.text(407, "No"))
        alert.addButton(withTitle: Lang.text(402, "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

// MARK: - the commands

extension MainWindowController {

    private var toolsWindow: NSWindow? { window }

    // MARK: File > CRC (IDM_CRC32 102 ... IDM_HASH_ALL 101) -- CApp::CalculateCrc

    @objc func fileCalculateHash(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag,
              let method = SZHasher.methodName(forMenuID: tag) else { return }
        calculateHash(method: method)
    }

    /// CApp::CalculateCrc2 (PanelCrc.cpp:338-411).
    func calculateHash(method: String) {
        let panel = focusedPanel
        guard let items = ToolsPanelAccess.operatedItems(of: panel), !items.rows.isEmpty else { return }

        // The progress title: the archive path uses the method name for a single named
        // method, everything else IDS_CHECKSUM_CALCULATING (PanelCopy.cpp:281-289).
        let calculating = Lang.text(7500, "Checksum calculating...")
        var options = OperationRunner.Options(title: calculating)
        options.initialStatus = .checksum
        options.parentWindow = toolsWindow
        options.titleFileName = items.folderPath
        options.waitMode = true

        let result: Result<SZHashResults, Error>
        if items.isFileSystem {
            let paths = items.fullPaths
            let base = items.folderPath
            let recursive = !items.isFlatView
            result = OperationRunner.run(options) { runner in
                try SZHasher.hash(paths: paths, relativeTo: base, methods: [method],
                                  recursive: recursive, progress: runner)
            }
        } else {
            if method != "*" { options.title = method }
            let folderPath = items.folderPath
            let names = Set(items.names)
            result = OperationRunner.run(options) { runner in
                let folder = try SZFolder.folder(forPath: folderPath, passwordDelegate: nil)
                try folder.loadItems()
                var indexes: [NSNumber] = []
                for i in 0..<folder.itemCount where names.contains(folder.nameOfItem(at: i)) {
                    indexes.append(NSNumber(value: i))
                }
                return try SZHasher.hash(itemsIn: folder, at: indexes, methods: [method],
                                         progress: runner)
            }
        }

        switch result {
        case .success(let results):
            HashResultsDialog.show(results: results, parent: toolsWindow)
        case .failure:
            break               // OperationRunner already reported it (E_ABORT is silent)
        }
    }

    // MARK: File > Split file... (IDM_SPLIT 549) -- CApp::Split

    @objc func fileSplit(_ sender: Any?) {
        let panel = focusedPanel
        guard let items = ToolsPanelAccess.operatedItems(of: panel) else { return }
        guard items.isFileSystem else {
            ToolsAlerts.unsupportedOperation(toolsWindow)
            return
        }
        guard items.rows.count == 1, let row = items.rows.first, !row.isDirectory else {
            if !items.rows.isEmpty {
                ToolsAlerts.error(Lang.text(3014, "You must select one file"), toolsWindow)
            }
            return
        }
        let sourcePath = items.folderPath + row.name
        var destination = items.folderPath
        let panels = ToolsPanelAccess.panels(in: toolsWindow)
        if panels.count > 1, let other = panels.first(where: { $0 !== panel }),
           let snapshot = other.snapshot, snapshot.isFileSystem {
            destination = snapshot.fullPath
        }

        guard let choice = SplitDialog.run(filePath: row.name, path: destination, parent: toolsWindow) else { return }

        let attributes = try? FileManager.default.attributesOfItem(atPath: sourcePath)
        guard let size = (attributes?[.size] as? NSNumber)?.uint64Value else {
            ToolsAlerts.error("Cannot find file", toolsWindow)
            return
        }
        guard let first = choice.volumeSizes.first, size > first else {
            ToolsAlerts.error(Lang.text(7306, "Volume size must be smaller than size of original file"), toolsWindow)
            return
        }
        let numVolumes = SZSplitFile.numberOfVolumes(forSize: size,
                                                    volumeSizes: choice.volumeSizes.map { NSNumber(value: $0) })
        if numVolumes >= 100 {
            let message = Lang.format(Lang.text(7305, "Are you sure you want to split file into {0} volumes?"),
                                      "\(numVolumes)")
            guard ToolsAlerts.confirm(title: Lang.text(7304, "Confirm Splitting"),
                                      message: message, toolsWindow) else { return }
        }

        var path = choice.path
        if !path.hasSuffix("/") { path += "/" }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            ToolsAlerts.error(Lang.format(Lang.text(3003, "Cannot create folder '{0}'"), path), toolsWindow)
            return
        }

        var options = OperationRunner.Options(title: Lang.text(7303, "Splitting..."))
        options.parentWindow = toolsWindow
        options.titleFileName = row.name
        options.waitMode = true
        let volumeBase = path + row.name
        let sizes = choice.volumeSizes.map { NSNumber(value: $0) }
        _ = OperationRunner.run(options) { runner in
            try SZSplitFile.split(at: sourcePath, volumeBasePath: volumeBase,
                                  volumeSizes: sizes, progress: runner)
        }
        panel.reload()
        for other in ToolsPanelAccess.panels(in: toolsWindow) where other !== panel { other.reload() }
    }

    // MARK: File > Combine files... (IDM_COMBINE 550) -- CApp::Combine

    @objc func fileCombine(_ sender: Any?) {
        let panel = focusedPanel
        guard let items = ToolsPanelAccess.operatedItems(of: panel) else { return }
        guard items.isFileSystem else {
            ToolsAlerts.error(Lang.text(6008, "Operation is not supported."), toolsWindow)
            return
        }
        guard items.rows.count == 1, let row = items.rows.first, !row.isDirectory else {
            if !items.rows.isEmpty {
                ToolsAlerts.error(Lang.text(7403, "Select only first part of split file"), toolsWindow)
            }
            return
        }
        var unchanged: NSString?
        guard SZSplitFile.parseFirstVolumeName(row.name, unchangedPart: &unchanged) else {
            ToolsAlerts.error(Lang.text(7404, "Cannot detect file as split file"), toolsWindow)
            return
        }
        let sourceDirectory = String(items.folderPath.dropLast())      // without the trailing "/"
        let names = SZSplitFile.volumeNames(forFirstVolume: row.name, in: sourceDirectory)
        guard names.count > 1 else {
            ToolsAlerts.error(Lang.text(7405, "Cannot find more than one part of split file"), toolsWindow)
            return
        }
        var total: UInt64 = 0
        for name in names {
            let path = (sourceDirectory as NSString).appendingPathComponent(name)
            total += ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.uint64Value ?? 0
        }
        guard total != 0 else {
            ToolsAlerts.error("No data", toolsWindow)
            return
        }

        // AddValuePair2(IDS_PROP_FILES, count, size) + the first two and the last part
        var info = "\(Lang.text(1032, "Files")): \(names.count)    ( \(Formatting.size(total)) bytes )\n"
        info += items.folderPath
        for name in names.prefix(2) { info += "\n  " + name }
        if names.count > 3 { info += "\n  ..." }
        if names.count > 2 { info += "\n  " + names[names.count - 1] }

        var destination = items.folderPath
        let panels = ToolsPanelAccess.panels(in: toolsWindow)
        if panels.count > 1, let other = panels.first(where: { $0 !== panel }),
           let snapshot = other.snapshot, snapshot.isFileSystem {
            destination = snapshot.fullPath
        }
        let title = Lang.text(7400, "Combine Files") + " " + row.name
        guard var path = CombineDialog.run(title: title,
                                           prompt: Lang.text(7401, "Combine to:"),
                                           info: info, path: destination, parent: toolsWindow) else { return }
        if !path.hasSuffix("/") { path += "/" }
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            ToolsAlerts.error(Lang.format(Lang.text(3003, "Cannot create folder '{0}'"), path), toolsWindow)
            return
        }
        let outputName = SZSplitFile.combinedName(forFirstVolume: row.name)
        let outputPath = path + outputName
        if FileManager.default.fileExists(atPath: outputPath) {
            ToolsAlerts.error(Lang.format(Lang.text(3008, "File {0} is already exist"), outputPath), toolsWindow)
            return
        }

        var options = OperationRunner.Options(title: Lang.text(7402, "Combining..."))
        options.parentWindow = toolsWindow
        options.titleFileName = outputName
        _ = OperationRunner.run(options) { runner in
            try SZSplitFile.combine(names, in: sourceDirectory, to: outputPath, progress: runner)
        }
        panel.reload()
        for other in ToolsPanelAccess.panels(in: toolsWindow) where other !== panel { other.reload() }
    }

    // MARK: File > Link... (IDM_LINK 558) -- CApp::Link

    @objc func fileLink(_ sender: Any?) {
        let panel = focusedPanel
        guard let items = ToolsPanelAccess.operatedItems(of: panel) else { return }
        guard items.isFileSystem else {
            ToolsAlerts.unsupportedOperation(toolsWindow)
            return
        }
        guard items.rows.count == 1, let row = items.rows.first else {
            if !items.rows.isEmpty {
                ToolsAlerts.error(Lang.text(3014, "You must select one file"), toolsWindow)
            }
            return
        }
        var anotherPath = items.folderPath
        let panels = ToolsPanelAccess.panels(in: toolsWindow)
        if panels.count > 1, let other = panels.first(where: { $0 !== panel }),
           let snapshot = other.snapshot, snapshot.isFileSystem {
            anotherPath = snapshot.fullPath
        }
        let created = LinkDialog.run(currentDirPrefix: items.folderPath,
                                    filePath: items.folderPath + row.name,
                                    anotherPath: anotherPath, parent: toolsWindow)
        if created {
            // RefreshTitleAlways + a panel refresh (the Link column may be visible).
            panel.reload()
            for other in panels where other !== panel { other.reload() }
        }
    }

    // MARK: Tools > Benchmark (IDM_BENCHMARK 901)

    @objc func toolsBenchmark(_ sender: Any?) {
        BenchmarkDialog.run(totalMode: false, parent: toolsWindow)
    }

    // MARK: Tools > Delete Temporary Files... (IDM_TEMP_DIR 910)

    @objc func toolsDeleteTempFiles(_ sender: Any?) {
        let observer = NotificationCenter.default.addObserver(
            forName: ToolsTempFilesDialog.openPathNotification, object: nil, queue: .main) { [weak self] note in
            guard let path = note.userInfo?["path"] as? String else { return }
            self?.focusedPanel.navigate(to: path)
        }
        ToolsTempFilesDialog.show(parent: toolsWindow)
        NotificationCenter.default.removeObserver(observer)
    }

    // MARK: Help > Contents (F1, IDM_HELP_CONTENTS 960) and About (IDM_ABOUT 961)

    @objc func helpContents(_ sender: Any?) {
        Help.show(topic: Help.contents)
    }

    /// The real CAboutDialog (IDD_ABOUT 2900). `MainWindowController.helpAbout` is the Wave 1
    /// placeholder that shows the standard macOS About panel; ToolsCommands.install() retargets
    /// the two About menu items here (see Mac/docs/requests.md).
    @objc func toolsShowAbout(_ sender: Any?) {
        AboutDialog.show(parent: toolsWindow)
    }
}

// MARK: - menu hook

enum ToolsCommands {

    /// Called from MainMenu.build(). Retargets the About items (tag 961) at the real dialog
    /// once the app has launched; everything else in this scope is reached through selectors
    /// nobody else implements.
    static func install() {
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                              object: nil, queue: .main) { _ in
            retargetAboutItems(NSApp.mainMenu)
        }
    }

    private static func retargetAboutItems(_ menu: NSMenu?) {
        guard let menu else { return }
        for item in menu.items {
            if item.tag == 961 {
                item.action = #selector(MainWindowController.toolsShowAbout(_:))
                item.target = nil            // straight down the responder chain
            }
            retargetAboutItems(item.submenu)
        }
    }
}
