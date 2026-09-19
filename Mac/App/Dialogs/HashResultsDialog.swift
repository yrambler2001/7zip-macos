// HashResultsDialog.swift -- the checksum results window.
//
// 7zG has no dialog resource of its own here: ShowHashResults (GUI/HashGUI.cpp:310-335)
// fills the generic CListViewDialog (IDD_LISTVIEW 99, 01b-fm-dialogs-settings.md 4.11) with
// Title = IDS_CHECKSUM_INFORMATION 7501 "Checksum information", two columns, rows that Del
// removes and Ctrl+C copies as "<name>: <value>", and SelectFirst = false.
//
// `HashListDialogView` below is that generic list, owned by this scope for now. The `panel`
// scope needs the very same control for Properties / archive info (PanelMenu.cpp:183) and
// Folders History (PanelFolderChange.cpp:868) -- see Mac/docs/api/tools.md: it may be lifted
// into Dialogs/ListViewDialog.swift (which `panel` owns) unchanged and this file then just
// uses it.

import AppKit
import SevenZipKit

/// CListViewDialog (IDD_LISTVIEW 99): a 1- or 2-column list with OK / Cancel.
final class HashListDialogView: NSView, NSTableViewDataSource, NSTableViewDelegate {

    /// IDL_LISTVIEW 100
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private(set) var strings: [String] = []
    private(set) var values: [String] = []
    let numberOfColumns: Int
    /// DeleteIsAllowed: Del removes the selected rows.
    var deleteIsAllowed = false
    /// StringsWereChanged: set once rows were deleted.
    private(set) var stringsWereChanged = false
    /// FocusedItemIndex, stored by OnOK (used by Folders History).
    var focusedItemIndex: Int { tableView.selectedRow }
    /// Called on Enter / double click in a 1-column list (OnEnter -> OnOK).
    var onActivate: (() -> Void)?

    init(strings: [String], values: [String], selectFirst: Bool) {
        numberOfColumns = values.isEmpty ? 1 : 2
        self.strings = strings
        self.values = values
        super.init(frame: .zero)

        let nameColumn = NSTableColumn(identifier: .init("strings"))
        nameColumn.title = ""
        nameColumn.width = 220
        nameColumn.minWidth = 80
        tableView.addTableColumn(nameColumn)
        if numberOfColumns > 1 {
            let valueColumn = NSTableColumn(identifier: .init("values"))
            valueColumn.title = ""
            valueColumn.width = 420
            valueColumn.minWidth = 80
            tableView.addTableColumn(valueColumn)
        }
        // LVS_NOCOLUMNHEADER is removed only when NumColumns > 1 -- but both columns have
        // empty titles in the .rc, so no header is shown either way.
        tableView.headerView = nil
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.rowSizeStyle = .small
        tableView.style = .plain
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)
        tableView.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if selectFirst, !strings.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { true }

    func numberOfRows(in tableView: NSTableView) -> Int { strings.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < strings.count else { return nil }
        if tableColumn?.identifier.rawValue == "values" {
            return row < values.count ? values[row] : ""
        }
        return strings[row]
    }

    override func keyDown(with event: NSEvent) {
        let key = event.charactersIgnoringModifiers ?? ""
        if event.modifierFlags.contains(.command) {
            switch key.lowercased() {
            case "a": tableView.selectAll(nil); return       // Ctrl+A -> SelectAll
            case "c": copyToClipboard(); return              // Ctrl+C / Ctrl+Ins
            default: break
            }
        }
        if let scalar = key.unicodeScalars.first {
            // Del / Backspace -> DeleteItems (only when DeleteIsAllowed)
            if scalar == UnicodeScalar(NSDeleteFunctionKey) || scalar == "\u{7F}" || scalar == "\u{8}" {
                deleteSelectedItems()
                return
            }
            if scalar == "\r" || scalar == "\u{3}" {
                activate(alt: event.modifierFlags.contains(.option))
                return
            }
        }
        super.keyDown(with: event)
    }

    @objc private func doubleClicked() {
        activate(alt: NSEvent.modifierFlags.contains(.option))
    }

    /// OnEnter (ListViewDialog.cpp:247-256): OK for a 1-column list, ShowItemInfo when Alt is
    /// held or the list has 2 columns.
    private func activate(alt: Bool) {
        if numberOfColumns > 1 || alt {
            showItemInfo()
        } else {
            onActivate?()
        }
    }

    /// ShowItemInfo (:198-215): the row's text in a read-only editor (CEditDialog).
    private func showItemInfo() {
        let row = tableView.selectedRow
        guard row >= 0, row < strings.count else { return }
        let alert = NSAlert()
        alert.messageText = strings[row]
        alert.informativeText = row < values.count ? values[row] : ""
        alert.alertStyle = .informational
        alert.addButton(withTitle: Lang.text(401, "OK"))
        alert.runModal()
    }

    /// DeleteItems (:133-162): removes the selected rows and sets StringsWereChanged.
    func deleteSelectedItems() {
        guard deleteIsAllowed else { return }
        let selection = tableView.selectedRowIndexes
        guard !selection.isEmpty else { return }
        for index in selection.sorted(by: >) {
            if index < strings.count { strings.remove(at: index) }
            if index < values.count { values.remove(at: index) }
        }
        stringsWereChanged = true
        tableView.reloadData()
    }

    /// CopyToClipboard (:164-195): "<string>" or "<string>: <value>" per selected row.
    func copyToClipboard() {
        let rows = tableView.selectedRowIndexes.isEmpty
            ? IndexSet(integersIn: 0..<strings.count) : tableView.selectedRowIndexes
        var text = ""
        for row in rows.sorted() where row < strings.count {
            if numberOfColumns > 1 {
                text += "\(strings[row]): \(row < values.count ? values[row] : "")\n"
            } else {
                text += "\(strings[row])\n"
            }
        }
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    func selectAll() { tableView.selectAll(nil) }
}

/// ShowHashResults (GUI/HashGUI.cpp:310-335).
final class HashResultsDialog: NSObject {

    private let window: NSWindow
    private let list: HashListDialogView

    private init(results: SZHashResults, title: String, parent: NSWindow?) {
        window = DialogKit.window(title: title, resizable: true)
        list = HashListDialogView(strings: results.rows.map { $0.name },
                                  values: results.rows.map { $0.value },
                                  selectFirst: false)          // SelectFirst = false
        super.init()
        list.deleteIsAllowed = true                            // DeleteIsAllowed = true
        list.translatesAutoresizingMaskIntoConstraints = false
        list.addConstraint(NSLayoutConstraint(item: list, attribute: .height, relatedBy: .greaterThanOrEqual,
                                              toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 260))

        let copy = DialogKit.button(Lang.text(7203, "Copy"), target: self, action: #selector(copyClicked))
        let ok = DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r")
        let cancel = DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(okClicked),
                                      key: "\u{1b}")
        cancel.isHidden = true                                 // Esc closes; no separate button needed
        let buttonRow = NSStackView(views: [copy, NSView(), ok, cancel])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 10

        let stack = NSStackView(views: [list, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for view in [list, buttonRow] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 720)
        window.initialFirstResponder = list
    }

    @objc private func okClicked() { NSApp.stopModal() }
    @objc private func copyClicked() { list.selectAll(); list.copyToClipboard() }

    /// Shows the results modally over `parent`. `title` defaults to
    /// IDS_CHECKSUM_INFORMATION 7501 "Checksum information".
    static func show(results: SZHashResults,
                     title: String = Lang.text(7501, "Checksum information"),
                     parent: NSWindow? = nil) {
        let dialog = HashResultsDialog(results: results, title: title, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
    }
}
