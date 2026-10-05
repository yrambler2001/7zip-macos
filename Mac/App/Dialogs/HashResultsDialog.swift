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
    private let scrollView = WinScrollView()
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

    /// A view-based row: an `NSTableCellView` with a real text field, so every row is an
    /// accessibility cell with a static text (requests.md, `finder` -> `tools`: the cell-based
    /// list exposed no row text to XCUITest or VoiceOver). opsgaps.
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("HashListCell." + (tableColumn?.identifier.rawValue ?? "strings"))
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.font = tableView.font
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let text = self.tableView(tableView, objectValueFor: tableColumn, row: row) as? String ?? ""
        cell.textField?.stringValue = text
        cell.setAccessibilityLabel(text)
        return cell
    }

    /// The rows as the list shows them, for tests: `[string]` or `[string, value]` per row.
    var displayedRows: [[String]] {
        (0..<tableView.numberOfRows).map { row in
            (0..<tableView.numberOfColumns).map { column in
                (tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? NSTableCellView)?
                    .textField?.stringValue ?? ""
            }
        }
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
        // CEditDialog (IDD_EDIT_DLG 94), as 7zFM: one column -> the row's text with no title,
        // two -> the name as the title and the value as the text (ListViewDialog.cpp:207-215).
        if numberOfColumns == 1 {
            TextViewerDialog.show(title: "", text: strings[row], parent: window)
        } else {
            TextViewerDialog.show(title: strings[row], text: row < values.count ? values[row] : "", parent: window)
        }
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

/// ShowHashResults (GUI/HashGUI.cpp:310-335): the generic CListViewDialog (IDD_LISTVIEW 99) with
/// two columns, OK and Cancel, Del removing rows and Ctrl+C copying "<name>: <value>" -- the
/// port's ListViewDialog, laid out like every IDD_LISTVIEW (dlgfeel: no extra Copy button).
enum HashResultsDialog {

    /// Shows the results modally over `parent`. `title` defaults to
    /// IDS_CHECKSUM_INFORMATION 7501 "Checksum information".
    static func show(results: SZHashResults,
                     title: String = Lang.text(7501, "Checksum information"),
                     parent: NSWindow? = nil) {
        var options = ListViewDialogOptions()
        options.title = title
        options.strings = results.rows.map { $0.name }
        options.values = results.rows.map { $0.value }
        options.numColumns = 2
        options.selectFirst = false                            // SelectFirst = false
        options.deleteIsAllowed = true                         // DeleteIsAllowed = true
        _ = ListViewDialog.run(options, parent: parent)
    }
}
