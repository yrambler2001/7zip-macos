// ToolsTempFilesDialog.swift -- Tools > Delete Temporary Files... (IDM_TEMP_DIR 910),
// CBrowseDialog2 / IDD_BROWSE2 93 ("7-Zip: Browse Temp Files"; the window title is the menu
// text with "..." stripped). Parity: 01b-fm-dialogs-settings.md 4.3, 01 2.5.
//
// The app's own temp entries are the `7zE*` / `7zO*` / `7zS*` directories 7-Zip creates
// (drag&drop/copy, open-inside, SFX setup) plus the `7z*` scratch files, all inside
// NSTemporaryDirectory(). Only those are listed in the exact temp folder; sub-folders are
// listed unfiltered.

import AppKit
import SevenZipKit

final class ToolsTempFilesDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {

    /// k_EnumerateDirsLimit / k_EnumerateFilesLimit (BrowseDialog2.cpp:85-86)
    private static let dirsLimit = 200
    private static let filesLimit = 2000
    private static let blockedLinkMessage = "link openning was blocked by 7-Zip"

    private struct Entry {
        var name: String
        var isDirectory: Bool
        var isSymbolicLink: Bool
        var modified: Date?
        var size: UInt64
        var numFiles: Int
        var numFolders: Int
        var countsAreComplete: Bool
        /// The name of the single root item inside a temp directory
        /// (_columnIndex_fileNameInDir, BrowseDialog2.cpp:1734).
        var innerName: String
    }

    private enum SortKey { case name, modified, size }

    private let window: NSWindow
    private let tempRoot: String
    private var directory: String
    private var entries: [Entry] = []
    private var sortKey: SortKey = .name

    private let tableView = ToolsTempFilesTableView()
    private let folderLabel = NSTextField(string: "")     // IDT_BROWSE2_FOLDER 101 (read-only)
    private let parentButton: NSButton                    // IDB_BROWSE2_PARENT 110 "<--"
    private let deleteButton: NSButton                    // IDS_BUTTON_DELETE 7205
    private let filterCombo = NSPopUpButton()             // IDC_BROWSE2_FILTER 103

    private init(title: String, tempRoot: String, parent: NSWindow?) {
        self.tempRoot = Self.normalized(tempRoot)
        self.directory = self.tempRoot
        window = DialogKit.window(title: title, resizable: true)
        parentButton = DialogKit.button("<--", target: nil, action: #selector(parentClicked))
        deleteButton = DialogKit.button(Lang.text(7205, "Delete"), target: nil, action: #selector(deleteClicked))
        super.init()
        parentButton.target = self
        deleteButton.target = self

        let refresh = DialogKit.button(Lang.text(737, "Refresh"), target: self, action: #selector(refreshClicked))
        refresh.keyEquivalent = "r"
        refresh.keyEquivalentModifierMask = [.command]
        let close = DialogKit.button(Lang.text(408, "Close"), target: self, action: #selector(closeClicked))
        let help = DialogKit.button(Lang.text(409, "Help"), target: self, action: #selector(helpClicked))
        let escape = DialogKit.button("", target: self, action: #selector(closeClicked), key: "\u{1b}")
        escape.isHidden = true

        filterCombo.addItem(withTitle: "7-Zip temp files (7z*)")      // the single fixed string (:349)
        filterCombo.isEnabled = false

        // IDT_BROWSE2_FOLDER: a read-only EDITTEXT (ES_READONLY), drawn on the dialog face
        folderLabel.isEditable = false
        folderLabel.isSelectable = true
        folderLabel.isBezeled = true
        folderLabel.drawsBackground = true
        folderLabel.backgroundColor = .windowBackgroundColor
        folderLabel.lineBreakMode = .byTruncatingHead

        // BrowseDialog2.cpp:398-422 sizes every column with LVSCW_AUTOSIZE over a sample row
        // ("123...890" x 27, "2009-09-09 09:09:09", "99999 MB+", "123456789+", 20 digits); in
        // 7zFM 26.03 that is 186 / 111 / 67 / 72 / 72 / 132 px (dlg-tempfiles.txt).
        for (identifier, title, width) in [
            ("name", Lang.text(1004, "Name"), CGFloat(186)),          // IDS_PROP_NAME
            ("modified", Lang.text(1012, "Modified"), CGFloat(111)),  // IDS_PROP_MTIME
            ("size", Lang.text(1007, "Size"), CGFloat(67)),           // IDS_PROP_SIZE
            ("files", Lang.text(1032, "Files"), CGFloat(72)),         // IDS_PROP_FILES
            ("folders", Lang.text(1031, "Folders"), CGFloat(72)),     // IDS_PROP_FOLDERS
            ("inner", Lang.text(1004, "Name") + "-2", CGFloat(132)),  // LangString(IDS_PROP_NAME) + "-2"
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            // Size, Files and Folders are LVCFMT_RIGHT (BrowseDialog2.cpp:372-391).
            if ["size", "files", "folders"].contains(identifier) {
                column.headerCell.alignment = .right
                (column.dataCell as? NSCell)?.alignment = .right
            }
            column.width = width
            column.minWidth = 10
            WinHeaderCell.install(on: column, font: PanelMetrics.listFont)   // datecols: drawn in the font
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.style = .plain
        tableView.rowHeight = 17
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection)
        tableView.menu = contextMenu()
        // Keys of CBrowseDialog2 (:640-680, :1803-1835): Enter opens, Shift+Enter reveals in
        // the Finder, Alt+Enter shows the properties box, Backspace goes up, Del deletes,
        // Cmd+A selects all, Cmd+F3/F5/F6 sort by name / mtime / size.
        tableView.keyHandler = { [weak self] event in
            guard let self else { return false }
            let flags = event.modifierFlags
            if flags.contains(.command), let key = event.charactersIgnoringModifiers {
                if key.lowercased() == "a" { self.tableView.selectAll(nil); return true }
                if let scalar = key.unicodeScalars.first {
                    switch Int(scalar.value) {
                    case NSF3FunctionKey: self.sortKey = .name; self.applySort(); return true
                    case NSF5FunctionKey: self.sortKey = .modified; self.applySort(); return true
                    case NSF6FunctionKey: self.sortKey = .size; self.applySort(); return true
                    default: break
                    }
                }
                if key == "\u{7F}" { self.deleteClicked(); return true }
            }
            guard let scalar = (event.charactersIgnoringModifiers ?? "").unicodeScalars.first else { return false }
            switch scalar {
            case "\r", "\u{3}":
                if flags.contains(.shift) { self.openOutside() }
                else if flags.contains(.option) { self.showProperties() }
                else { self.openSelection() }
                return true
            case "\u{7F}", "\u{8}":
                self.parentClicked()
                return true
            case UnicodeScalar(NSDeleteFunctionKey)!:
                self.deleteClicked()
                return true
            default: return false
            }
        }

        let scroll = WinScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder

        // IDD_BROWSE2 93 (BrowseDialog2.rc): 466 x 344 DLU = 699 x 559 px, resizable; OnSize
        // (BrowseDialog2.cpp:483-530) stretches the folder edit, the list and the filter combo and
        // keeps Close / Help at the bottom right (dlgfeel).
        let rc = RcDialog(93)
        let form = RcFormView()
        form.add(deleteButton, rc, 7205)                                         // IDS_BUTTON_DELETE 7205
        form.add(refresh, rc, 737)                                               // IDM_VIEW_REFRESH 737
        form.add(parentButton, rc, 110)                                          // IDB_BROWSE2_PARENT 110
        form.add(folderLabel, rc, 101)                                           // IDT_BROWSE2_FOLDER 101
        form.addSubview(scroll)
        form.tabStop(scroll, rc, 100)
        scroll.frame = rc.rect(100)                                              // IDL_BROWSE2 100
        form.add(filterCombo, rc, 103)                                           // IDC_BROWSE2_FILTER 103
        form.add(close, rc, 8)                                                   // IDCLOSE
        form.add(help, rc, 9)                                                    // IDHELP
        form.addSubview(escape)
        let mx = rc.rect(7205).minX, my = rc.rect(7205).minY
        let folderRect = rc.rect(101), listRect = rc.rect(100), filterRect = rc.rect(103)
        let closeSize = rc.rect(8).size, helpSize = rc.rect(9).size
        form.onResize = { [folderLabel, filterCombo] size in
            let xLim = size.width - mx
            RcPlace.edit(folderLabel, NSRect(x: folderRect.minX, y: folderRect.minY,
                                             width: xLim - folderRect.minX, height: folderRect.height))
            let y = size.height - my - closeSize.height
            let x = xLim - closeSize.width
            RcPlace.button(close, NSRect(x: x - mx - helpSize.width, y: y, width: closeSize.width, height: closeSize.height))
            RcPlace.button(help, NSRect(x: x, y: y, width: helpSize.width, height: helpSize.height))
            // yFilterSize: GetClientRectOfItem gives the closed combo 23 px here (the list ends at
            // 471 and the combo starts at 484 in 7zFM 26.03's 559 px client, dlg-tempfiles.txt).
            let filterY = y - my - 23
            RcPlace.popup(filterCombo, NSRect(x: filterRect.minX, y: filterY, width: xLim - filterRect.minX,
                                              height: RcPlace.comboHeight))
            scroll.frame = NSRect(x: listRect.minX, y: listRect.minY, width: xLim - listRect.minX,
                                  height: max(0, filterY - my - listRect.minY))
        }
        RcPlace.install(form, in: window, size: rc.size, parent: parent)
        window.initialFirstResponder = tableView
        reload()
    }

    private static func normalized(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        if p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        return p
    }

    // MARK: listing

    /// IsExactTempFolder (:264): the filter only applies to the temp folder itself.
    private var isExactTempFolder: Bool { directory == tempRoot }

    /// `7z` + `E`|`O`|`S` + exactly 8 hex chars (:1546-1558). The app also leaves plain
    /// `7z*` scratch files behind, so the filter combo says "7z*" and those match too.
    private func matchesTempFilter(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.hasPrefix("7z") else { return false }
        let rest = lower.dropFirst(2)
        guard let kind = rest.first, "eos".contains(kind) else { return false }
        let hex = rest.dropFirst()
        guard hex.count == 8 else { return false }
        return hex.allSatisfy { $0.isHexDigit }
    }

    private func reload() {
        let fm = FileManager.default
        folderLabel.stringValue = directory + "/"
        parentButton.isEnabled = !isExactTempFolder            // disabled in the temp folder (:1603)
        var found: [Entry] = []
        let names = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        for name in names {
            if isExactTempFolder && !matchesTempFilter(name) { continue }
            let full = (directory as NSString).appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: full) else { continue }
            let type = attributes[.type] as? FileAttributeType
            let isLink = type == .typeSymbolicLink
            let isDir = type == .typeDirectory
            var entry = Entry(name: name, isDirectory: isDir, isSymbolicLink: isLink,
                              modified: attributes[.modificationDate] as? Date,
                              size: (attributes[.size] as? NSNumber)?.uint64Value ?? 0,
                              numFiles: 0, numFolders: 0, countsAreComplete: true, innerName: "")
            if isDir && !isLink {
                let counts = Self.enumerate(full)
                entry.size = counts.size
                entry.numFiles = counts.files
                entry.numFolders = counts.folders
                entry.countsAreComplete = counts.complete
                let children = (try? fm.contentsOfDirectory(atPath: full)) ?? []
                if children.count == 1 { entry.innerName = children[0] }
            }
            found.append(entry)
        }
        entries = found
        applySort()
    }

    /// CBrowseEnumerator (:85-160): recursive counts, never descending into a reparse point,
    /// stopping at 200 directories / 2000 files (an interrupted count shows a "+").
    private static func enumerate(_ path: String) -> (files: Int, folders: Int, size: UInt64, complete: Bool) {
        let fm = FileManager.default
        var files = 0, folders = 0
        var size: UInt64 = 0
        var complete = true
        var stack = [path]
        while let current = stack.popLast() {
            let names = (try? fm.contentsOfDirectory(atPath: current)) ?? []
            for name in names {
                let full = (current as NSString).appendingPathComponent(name)
                guard let attributes = try? fm.attributesOfItem(atPath: full) else { continue }
                let type = attributes[.type] as? FileAttributeType
                if type == .typeSymbolicLink {
                    files += 1                      // counted, never followed (:150)
                    continue
                }
                if type == .typeDirectory {
                    folders += 1
                    if folders > dirsLimit { complete = false; return (files, folders, size, complete) }
                    stack.append(full)
                } else {
                    files += 1
                    size += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    if files > filesLimit { complete = false; return (files, folders, size, complete) }
                }
            }
        }
        return (files, folders, size, complete)
    }

    private func applySort() {
        switch sortKey {
        case .name: entries.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .modified: entries.sort { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        case .size: entries.sort { $0.size < $1.size }
        }
        tableView.reloadData()
    }

    // MARK: table

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < entries.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let entry = entries[row]
        let plus = entry.countsAreComplete ? "" : "+"
        switch id {
        case "name": return entry.name + (entry.isSymbolicLink ? " ->" : "")
        case "modified":
            // ConvertUtcFileTimeToString(kTimestampPrintLevel_MIN), local unless View > Time > UTC
            guard let date = entry.modified else { return "" }
            return TimeMenuDelegate.format(date, level: -1, utc: SZFolder.timestampShowUTC)
        case "size": return Self.browseSizeText(entry.size) + plus
        // Empty for zero (BrowseDialog2.cpp:1709-1731), as 7zFM 25.01 shows it (wincompare.md).
        case "files": return entry.isDirectory && entry.numFiles != 0 ? "\(entry.numFiles)\(plus)" : ""
        case "folders": return entry.isDirectory && entry.numFolders != 0 ? "\(entry.numFolders)\(plus)" : ""
        case "inner": return entry.innerName
        default: return nil
        }
    }

    /// A view-based row in the list's font: the system's small icon before the name (the
    /// list has the shell's small image list, BrowseDialog2.cpp:366) and every text 6 px from the
    /// column's aligned edge, as in the main list (PanelMetrics).
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let text = self.tableView(tableView, objectValueFor: column, row: row) as? String ?? ""
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.font = PanelMetrics.listFont
        field.lineBreakMode = .byTruncatingTail
        let right = ["size", "files", "folders"].contains(column.identifier.rawValue)
        field.alignment = right ? .right : .left
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        var leading: CGFloat = 4
        if column.identifier.rawValue == "name", row < entries.count {
            let icon = NSImageView(frame: NSRect(x: 4, y: 0, width: 16, height: 16))
            icon.image = NSWorkspace.shared.icon(forFile: (directory as NSString).appendingPathComponent(entries[row].name))
            icon.imageScaling = .scaleProportionallyDown
            icon.autoresizingMask = [.minYMargin, .maxYMargin]
            cell.addSubview(icon)
            cell.imageView = icon
            leading = 22
        }
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: leading),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// Browse_ConvertSizeToString (BrowseDialog.cpp:552-567): plain digits below 10000, then
    /// KB / MB / GB (truncated) from 10000 bytes / 10000 KB / 10000 MB.
    static func browseSizeText(_ size: UInt64) -> String {
        if size >= UInt64(10000) << 20 { return "\(size >> 30) GB" }
        if size >= UInt64(10000) << 10 { return "\(size >> 20) MB" }
        if size >= 10000 { return "\(size >> 10) KB" }
        return "\(size)"
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
        switch tableColumn.identifier.rawValue {
        case "name": sortKey = .name
        case "modified": sortKey = .modified
        case "size": sortKey = .size
        default: return
        }
        applySort()
    }

    // MARK: actions

    private var selectedEntries: [Entry] {
        tableView.selectedRowIndexes.compactMap { $0 < entries.count ? entries[$0] : nil }
    }

    @objc private func refreshClicked() { reload() }

    @objc private func parentClicked() {
        guard !isExactTempFolder else { return }
        directory = Self.normalized((directory as NSString).deletingLastPathComponent)
        reload()
    }

    @objc private func closeClicked() { NSApp.stopModal() }
    @objc private func helpClicked() { Help.show(topic: Help.tempFiles) }

    /// OnDelete (:896-975): confirm with 6100-6105 (+ the first 10 names), then delete
    /// permanently (no Trash, like RemoveDirWithSubItems / DeleteFileAlways).
    @objc private func deleteClicked() {
        let selection = selectedEntries
        guard !selection.isEmpty else { return }
        let title: String
        let message: String
        if selection.count == 1 {
            let entry = selection[0]
            title = entry.isDirectory ? Lang.text(6101, "Confirm Folder Delete")
                                      : Lang.text(6100, "Confirm File Delete")
            let template = entry.isDirectory
                ? Lang.text(6104, "Are you sure you want to delete the folder '{0}' and all its contents?")
                : Lang.text(6103, "Are you sure you want to delete '{0}'?")
            message = Lang.format(template, entry.name)
        } else {
            title = Lang.text(6102, "Confirm Multiple File Delete")
            var text = Lang.format(Lang.text(6105, "Are you sure you want to delete these {0} items?"),
                                   "\(selection.count)")
            text += "\n\n" + selection.prefix(10).map { $0.name }.joined(separator: "\n")
            if selection.count > 10 { text += "\n..." }
            message = text
        }
        // BrowseDialog2.cpp:949-951: LangString(titleID), MB_YESNOCANCEL | MB_ICONQUESTION.
        guard WinMessageBox.run(message, caption: title, buttons: .yesNoCancel, icon: .question,
                                owner: window) == .yes else { return }

        var failures: [String] = []
        for entry in selection {
            let full = (directory as NSString).appendingPathComponent(entry.name)
            do {
                try FileManager.default.removeItem(atPath: full)
            } catch {
                failures.append("\(entry.name) : \(error.localizedDescription)")
            }
        }
        reload()
        if !failures.isEmpty {
            MessagesDialog.show(messages: failures, parent: window)
        }
    }

    /// Enter / double click: enter a folder, open a file. A symlink is never followed (:1824).
    @objc private func openSelection() {
        guard let entry = selectedEntries.first else { return }
        if entry.isSymbolicLink {
            showInfo(Self.blockedLinkMessage)
            return
        }
        let full = (directory as NSString).appendingPathComponent(entry.name)
        if entry.isDirectory {
            directory = Self.normalized(full)
            reload()
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: full))
        }
    }

    /// Shift+Enter / "Open Outside": reveal in the Finder (Explorer on Windows).
    @objc private func openOutside() {
        guard let entry = selectedEntries.first else { return }
        if entry.isSymbolicLink {
            showInfo(Self.blockedLinkMessage)
            return
        }
        let full = (directory as NSString).appendingPathComponent(entry.name)
        NSWorkspace.shared.selectFile(full, inFileViewerRootedAtPath: directory)
    }

    /// "Open Outside : 7-Zip": a new 7-Zip window at that path.
    @objc private func openInSevenZip() {
        guard let entry = selectedEntries.first else { return }
        let full = (directory as NSString).appendingPathComponent(entry.name)
        NotificationCenter.default.post(name: ToolsTempFilesDialog.openPathNotification,
                                        object: nil, userInfo: ["path": full])
        NSApp.stopModal()
    }

    /// Alt+Enter / "Properties" (Show_FileProps_Window :881).
    @objc private func showProperties() {
        guard let entry = selectedEntries.first else { return }
        var lines = ["\(Lang.text(1004, "Name")): \(entry.name)",
                     "\(Lang.text(1007, "Size")): \(Formatting.size(entry.size))"]
        if let date = entry.modified {
            lines.append("\(Lang.text(1012, "Modified")): \(date)")
        }
        let full = (directory as NSString).appendingPathComponent(entry.name)
        if let attributes = try? FileManager.default.attributesOfItem(atPath: full),
           let mode = attributes[.posixPermissions] as? NSNumber {
            lines.append("\(Lang.text(1009, "Attributes")): \(String(mode.intValue, radix: 8))")
        }
        if entry.isDirectory {
            lines.append("\(Lang.text(1032, "Files")): \(entry.numFiles)")
            lines.append("\(Lang.text(1031, "Folders")): \(entry.numFolders)")
        }
        showInfo(lines.joined(separator: "\n"))
    }

    /// BrowseDialog2.cpp:885: MessageBoxW(s, LangString(IDS_PROPERTIES 6600), MB_OK).
    private func showInfo(_ text: String) {
        WinMessageBox.run(text, caption: Lang.text(6600, "Properties"), owner: window)
    }

    /// The context menu of the list (:1200-1235).
    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: Lang.text(7205, "Delete"), action: #selector(deleteClicked), keyEquivalent: "")
        menu.addItem(withTitle: Lang.text(542, "Open Outside"), action: #selector(openOutside), keyEquivalent: "")
        menu.addItem(withTitle: Lang.text(542, "Open Outside") + " : 7-Zip",
                     action: #selector(openInSevenZip), keyEquivalent: "")
        menu.addItem(withTitle: Lang.text(6600, "Properties"), action: #selector(showProperties), keyEquivalent: "")
        for item in menu.items { item.target = self }
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { !selectedEntries.isEmpty }

    /// Posted when the user picks "Open Outside : 7-Zip"; the window controller navigates.
    static let openPathNotification = Notification.Name("SZToolsTempFilesOpenPath")

    /// MyBrowseForTempFolder (:1853-1873).
    static func show(parent: NSWindow? = nil) {
        // The menu text without "..." (fallback "Delete Temporary Files").
        var title = Lang.text(910, "Delete Temporary Files...")
        while title.hasSuffix(".") { title.removeLast() }
        let dialog = ToolsTempFilesDialog(title: title, tempRoot: TestSupport.temporaryDirectory, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
    }
}


/// The list of the temp browser; CBrowseDialog2 handles its keys itself.
final class ToolsTempFilesTableView: NSTableView {
    /// Return true from the handler when the key was consumed.
    var keyHandler: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if keyHandler?(event) == true { return }
        super.keyDown(with: event)
    }
}
