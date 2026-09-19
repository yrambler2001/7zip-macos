// ToolsTempFilesDialog.swift -- Tools > Delete Temporary Files... (IDM_TEMP_DIR 910),
// CBrowseDialog2 / IDD_BROWSE2 93 ("7-Zip: Browse Temp Files"; the window title is the menu
// text with "..." stripped). Parity: 01b-fm-dialogs-settings.md 4.3, 01 2.5.
//
// The app's own temp entries are the `7zE*` / `7zO*` / `7zS*` directories 7-Zip creates
// (drag&drop/copy, open-inside, SFX setup) plus the `7z*` scratch files, all inside
// NSTemporaryDirectory(). Only those are listed in the exact temp folder; sub-folders are
// listed unfiltered.

import AppKit

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

    private let tableView = NSTableView()
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

        folderLabel.isEditable = false
        folderLabel.isBordered = true
        folderLabel.drawsBackground = true
        folderLabel.backgroundColor = .textBackgroundColor
        folderLabel.lineBreakMode = .byTruncatingHead

        for (identifier, title, width) in [
            ("name", Lang.text(1004, "Name"), CGFloat(260)),          // IDS_PROP_NAME
            ("modified", Lang.text(1012, "Modified"), CGFloat(150)),  // IDS_PROP_MTIME
            ("size", Lang.text(1007, "Size"), CGFloat(110)),          // IDS_PROP_SIZE
            ("files", Lang.text(1032, "Files"), CGFloat(70)),         // IDS_PROP_FILES
            ("folders", Lang.text(1031, "Folders"), CGFloat(70)),     // IDS_PROP_FOLDERS
            ("inner", Lang.text(1004, "Name"), CGFloat(200)),         // second Name column
        ] {
            let column = NSTableColumn(identifier: .init(identifier))
            column.title = title
            column.width = width
            column.minWidth = 50
            tableView.addTableColumn(column)
        }
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.rowSizeStyle = .small
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openSelection)
        tableView.menu = contextMenu()

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addConstraint(NSLayoutConstraint(item: scroll, attribute: .height, relatedBy: .greaterThanOrEqual,
                                               toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 320))

        let topRow = NSStackView(views: [deleteButton, refresh, parentButton, NSView()])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        let bottomRow = NSStackView(views: [filterCombo, NSView(), help, close, escape])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8

        let stack = NSStackView(views: [topRow, folderLabel, scroll, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [topRow, folderLabel, scroll, bottomRow] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 900)
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
            guard let date = entry.modified else { return "" }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            return formatter.string(from: date)
        case "size": return Formatting.size(entry.size) + plus
        case "files": return entry.isDirectory ? "\(entry.numFiles)\(plus)" : ""
        case "folders": return entry.isDirectory ? "\(entry.numFolders)\(plus)" : ""
        case "inner": return entry.innerName
        default: return nil
        }
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
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: Lang.text(406, "Yes"))
        alert.addButton(withTitle: Lang.text(407, "No"))
        alert.addButton(withTitle: Lang.text(402, "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

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

    private func showInfo(_ text: String) {
        let alert = NSAlert()
        alert.messageText = "7-Zip"
        alert.informativeText = text
        alert.alertStyle = .informational
        alert.addButton(withTitle: Lang.text(401, "OK"))
        alert.runModal()
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
        let dialog = ToolsTempFilesDialog(title: title, tempRoot: NSTemporaryDirectory(), parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
    }
}
