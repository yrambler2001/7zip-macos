// ListViewDialog.swift -- CListViewDialog / IDD_LISTVIEW 99 (ListViewDialog.cpp/.rc) and the
// read-only text viewer it opens, CEditDialog / IDD_EDIT_DLG 94 (EditDialog.cpp/.rc), both
// built in code. Parity: 01b-fm-dialogs-settings.md 4.11 (list view) and 4.6 (text viewer).
//
// The list is the generic 1- or 2-column report list behind Properties / archive info
// (PanelMenu.cpp:183), Folders History (PanelFolderChange.cpp:868) and the hash results
// (HashGUI.cpp:312). 480 x 320 du, resizable; the .rc caption "ListView" is replaced by Title.
// Keys (OnNotify :258-315): Del = DeleteItems, Ctrl+A = SelectAll, Ctrl+C = CopyToClipboard,
// Enter / double-click = OnEnter (:247-256). The text viewer is 320 x 240 du, resizable, one
// read-only multiline edit IDE_EDIT 100 plus MY_BUTTON__CLOSE (IDCLOSE, DEFPUSHBUTTON).

import AppKit

// MARK: - IDD_LISTVIEW 99

/// The list's geometry in 7zFM 26.03's Properties dialog (listfeel-data/win1/dlg-prop-*.png/.txt,
/// LVM_GETCOLUMN and pixel measurements; listfeel.md §3): 17 px rows (no image list), a 24 px empty
/// header, the text 6 px into each column, and LVSCW_AUTOSIZE widths -- the first column the
/// widest name plus 8 px (80 px, set by the 72 px kSeparator), the second the widest value plus
/// 12 px (326 px for the archive's path).
enum ListViewMetrics {
    static let rowHeight: CGFloat = 17
    static let headerHeight: CGFloat = 24
    static let textX: CGFloat = 6
    static let firstColumnExtra: CGFloat = 8
    static let otherColumnExtra: CGFloat = 12
    /// kSeparator ("------------------------") in Segoe UI 9 pt: 72 px of ink. The Mac font's
    /// hyphen is wider, so the separator counts as what it measures on Windows and is cut at the
    /// column's edge instead of widening the column (it would make it 30 % wider than 7zFM's).
    static let separatorWidth: CGFloat = 72

    static func autosizedWidths(strings: [String], values: [String]) -> (strings: CGFloat, values: CGFloat) {
        func width(_ text: String) -> CGFloat {
            PanelPropertyLines.isSeparator(text) ? separatorWidth : PanelMetrics.textWidth(text)
        }
        let first = (strings.map(width).max() ?? 0) + firstColumnExtra
        let second = (values.map(PanelMetrics.textWidth).max() ?? 0) + otherColumnExtra
        return (max(24, first), max(24, second))
    }
}

struct ListViewDialogOptions {
    var title: String = ""
    var strings: [String] = []          // column 1 ("Strings")
    var values: [String] = []           // column 2 ("Values"); empty => 1 column
    var numColumns: Int = 1             // 1 or 2; header only when 2
    var selectFirst: Bool = false
    var deleteIsAllowed: Bool = false
    init() {}
}

struct ListViewDialogResult {
    var accepted: Bool                  // OK / Enter
    var focusedItemIndex: Int           // -1 when none
    var strings: [String]               // possibly shortened by Del
    var stringsWereChanged: Bool
}

/// The generic list dialog. Main thread only.
enum ListViewDialog {

    static func run(_ options: ListViewDialogOptions, parent: NSWindow?) -> ListViewDialogResult {
        let dialog = ListViewDialogController(options: options, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
        return dialog.result
    }
}

/// What the list's key handling asks of the dialog (the table only classifies the keys).
private protocol ListViewDialogTableKeyHandler: AnyObject {
    func tableDeleteSelection(_ table: ListViewDialogTable)
    func tableCopySelection(_ table: ListViewDialogTable)
    func tableActivate(_ table: ListViewDialogTable, showInfo: Bool)
}

/// IDL_LISTVIEW 100. Enter has to reach the list before the default button takes it
/// (LVN_ITEMACTIVATE wins over IDOK on Windows), hence performKeyEquivalent as well as keyDown.
private final class ListViewDialogTable: NSTableView {

    weak var keyHandler: ListViewDialogTableKeyHandler?

    private static func isEnter(_ event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers ?? ""
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return (chars == "\r" || chars == "\u{3}") && mods.isDisjoint(with: [.command, .control])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self, ListViewDialogTable.isEnter(event) {
            keyHandler?.tableActivate(self, showInfo: event.modifierFlags.contains(.option))   // Alt+Enter
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        if mods.contains(.command) {
            switch chars.lowercased() {
            case "a": selectAll(nil); return                            // Ctrl+A -> SelectAll
            case "c": keyHandler?.tableCopySelection(self); return      // Ctrl+C / Ctrl+Ins -> CopyToClipboard
            default: break
            }
        } else if ListViewDialogTable.isEnter(event) {
            keyHandler?.tableActivate(self, showInfo: mods.contains(.option))
            return
        } else if chars == "\u{7f}" || chars == "\u{8}"
                    || chars.unicodeScalars.first?.value == UInt32(NSDeleteFunctionKey) {
            keyHandler?.tableDeleteSelection(self)                       // Del -> DeleteItems
            return
        }
        super.keyDown(with: event)
    }

    /// Edit > Copy reaches the first responder through the menu bar before keyDown does.
    @objc func copy(_ sender: Any?) { keyHandler?.tableCopySelection(self) }
}

private final class ListViewDialogController: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                                              ListViewDialogTableKeyHandler {

    let window: NSWindow
    private let table = ListViewDialogTable()             // IDL_LISTVIEW 100
    private let options: ListViewDialogOptions
    private var strings: [String]
    private var values: [String]
    private var stringsWereChanged = false
    private var accepted = false
    private var focusedItemIndex = -1

    private static let stringsColumn = NSUserInterfaceItemIdentifier("strings")
    private static let valuesColumn = NSUserInterfaceItemIdentifier("values")

    var result: ListViewDialogResult {
        ListViewDialogResult(accepted: accepted, focusedItemIndex: focusedItemIndex,
                             strings: strings, stringsWereChanged: stringsWereChanged)
    }

    init(options: ListViewDialogOptions, parent: NSWindow?) {
        self.options = options
        strings = options.strings
        values = options.values
        // IDD_LISTVIEW 99: caption "ListView" in the .rc, replaced by Title.
        window = DialogKit.window(title: options.title, resizable: true)
        super.init()

        // OnInit (ListViewDialog.cpp:34-131): LVS_REPORT | LVS_SHOWSELALWAYS, LVS_EX_FULLROWSELECT,
        // the header only when NumColumns > 1; columns "Strings" / "Values", auto-sized.
        let stringsColumn = NSTableColumn(identifier: ListViewDialogController.stringsColumn)
        // ListViewDialog.rc inserts both columns without a header text, so the port does the
        // same (a lang ID here showed an unrelated string in the Properties dialog).
        stringsColumn.title = ""
        stringsColumn.minWidth = 24
        table.addTableColumn(stringsColumn)
        // SetColumnWidthAuto (LVSCW_AUTOSIZE) on both columns after filling the list
        // (ListViewDialog.cpp:124-126): each column as wide as its widest text (ListViewMetrics).
        let widths = ListViewMetrics.autosizedWidths(strings: strings, values: values)
        stringsColumn.width = widths.strings
        if options.numColumns > 1 {
            let valuesColumn = NSTableColumn(identifier: ListViewDialogController.valuesColumn)
            valuesColumn.title = ""
            valuesColumn.minWidth = 24
            valuesColumn.width = widths.values
            table.addTableColumn(valuesColumn)
            table.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 600, height: ListViewMetrics.headerHeight))
        } else {
            table.headerView = nil                          // LVS_NOCOLUMNHEADER
        }
        table.allowsMultipleSelection = true
        table.allowsColumnSelection = false
        table.allowsEmptySelection = true
        // A plain report list: no alternating rows, 17 px rows, no gaps (7zFM 26.03, listfeel §3).
        table.usesAlternatingRowBackgroundColors = false
        table.style = .plain
        table.usesAutomaticRowHeights = false
        table.rowHeight = ListViewMetrics.rowHeight
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = self
        table.delegate = self
        table.keyHandler = self
        table.target = self
        table.doubleAction = #selector(rowActivated(_:))    // LVN_ITEMACTIVATE
        if Settings.singleClick {
            table.action = #selector(rowActivated(_:))      // LVS_EX_ONECLICKACTIVATE | LVS_EX_TRACKSELECT
        }

        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addConstraint(NSLayoutConstraint(item: scrollView, attribute: .height, relatedBy: .greaterThanOrEqual,
                                                    toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 400))

        // OK_CANCEL: OK is the default button, Cancel answers Escape.
        let ok = DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r")
        let cancel = DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(cancelClicked), key: "\u{1b}")
        let buttons = NSStackView(views: [cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let buttonRow = NSStackView(views: [NSView(), buttons])
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for view in [scrollView, buttonRow] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }

        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 720)
        if options.selectFirst, !strings.isEmpty {              // SelectFirst: first row focused + selected
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        window.initialFirstResponder = table
    }

    // MARK: NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { strings.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < strings.count else { return nil }
        if tableColumn?.identifier == ListViewDialogController.valuesColumn {
            return row < values.count ? values[row] : ""
        }
        return strings[row]
    }

    // MARK: NSTableViewDelegate

    /// A view-based row: an `NSTableCellView` with a real text field, so each row is an
    /// accessibility cell with a static text that VoiceOver reads and XCUITest resolves -- the
    /// cell-based list exposed no row text at all (requests.md, `opsgaps` -> `panel`; the same fix
    /// `mac/opsgaps` made in `HashListDialogView`).
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("ListViewCell." + (tableColumn?.identifier.rawValue ?? "strings"))
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let field = NSTextField(labelWithString: "")
            field.font = PanelMetrics.listFont              // the list's Segoe UI 9 pt metrics
            field.lineBreakMode = .byTruncatingTail
            field.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(field)
            cell.textField = field
            // The text 6 px into the column; it may run to the column's edge before it is cut.
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: cell.leadingAnchor,
                                               constant: ListViewMetrics.textX - PanelMetrics.textFieldInset),
                field.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        let text = self.tableView(tableView, objectValueFor: tableColumn, row: row) as? String ?? ""
        cell.textField?.stringValue = text
        // A kSeparator row is a run of hyphens cut at the column's edge, as on Windows.
        cell.textField?.lineBreakMode = PanelPropertyLines.isSeparator(text) ? .byClipping : .byTruncatingTail
        cell.setAccessibilityLabel(text)
        return cell
    }

    // MARK: actions

    @objc private func okClicked() { accept() }

    @objc private func cancelClicked() {
        accepted = false
        NSApp.stopModal()
    }

    /// LVN_ITEMACTIVATE from a double-click (or a single click with FM SingleClick).
    @objc private func rowActivated(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        activate(showInfo: NSEvent.modifierFlags.contains(.option))
    }

    /// OnOK (ListViewDialog.cpp:317-321): FocusedItemIndex is what Folders History opens.
    private func accept() {
        accepted = true
        focusedItemIndex = table.selectedRow
        NSApp.stopModal()
    }

    /// OnEnter (:247-256): OK for a 1-column list, ShowItemInfo when Alt is held or NumColumns > 1.
    private func activate(showInfo: Bool) {
        if showInfo || options.numColumns > 1 {
            showItemInfo()
        } else {
            accept()
        }
    }

    /// ShowItemInfo (:198-215): 1 column -> Title + the row; 2 columns -> the row's name + value.
    private func showItemInfo() {
        let row = table.selectedRow
        guard row >= 0, row < strings.count else { return }
        if options.numColumns > 1 {
            TextViewerDialog.show(title: strings[row], text: row < values.count ? values[row] : "", parent: window)
        } else {
            TextViewerDialog.show(title: options.title, text: strings[row], parent: window)
        }
    }

    // MARK: ListViewDialogTableKeyHandler

    /// DeleteItems (:135-160): drop the selected rows from Strings (and Values), then focus the
    /// row that took their place.
    func tableDeleteSelection(_ table: ListViewDialogTable) {
        guard options.deleteIsAllowed else { return }
        let rows = table.selectedRowIndexes.filteredIndexSet(includeInteger: { $0 < strings.count })
        guard let first = rows.first else { return }
        for row in rows.reversed() {
            strings.remove(at: row)
            if row < values.count { values.remove(at: row) }
        }
        stringsWereChanged = true
        table.reloadData()
        if !strings.isEmpty {
            let next = min(first, strings.count - 1)
            table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
            table.scrollRowToVisible(next)
        }
    }

    /// CopyToClipboard (:164-195): "<string>" or "<string>: <value>" per selected row, one per line.
    func tableCopySelection(_ table: ListViewDialogTable) {
        let rows = table.selectedRowIndexes.filteredIndexSet(includeInteger: { $0 < strings.count })
        guard !rows.isEmpty else { return }
        let lines: [String] = rows.map { row in
            if options.numColumns > 1 {
                return strings[row] + ": " + (row < values.count ? values[row] : "")
            }
            return strings[row]
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func tableActivate(_ table: ListViewDialogTable, showInfo: Bool) {
        activate(showInfo: showInfo)
    }
}

// MARK: - IDD_EDIT_DLG 94

/// CEditDialog: the read-only text viewer (01b 4.6). Its only caller is the list dialog.
enum TextViewerDialog {

    /// Shows `text` under `title` modally on the main thread.
    static func show(title: String, text: String, parent: NSWindow?) {
        let dialog = TextViewerDialogController(title: title, text: text, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
    }
}

/// IDE_EDIT 100: ES_MULTILINE | ES_READONLY | WS_VSCROLL | WS_HSCROLL. Enter and Escape close
/// the dialog the way IDCLOSE / IDCANCEL do on Windows.
private final class TextViewerTextView: NSTextView {

    var onClose: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        if chars == "\r" || chars == "\u{3}" || chars == "\u{1b}" {
            onClose?()
            return
        }
        super.keyDown(with: event)
    }
}

private final class TextViewerDialogController: NSObject {

    let window: NSWindow

    init(title: String, text: String, parent: NSWindow?) {
        // IDD_EDIT_DLG 94: caption "Edit" in the .rc, replaced by Title; 320 x 240 du, resizable.
        window = DialogKit.window(title: title, resizable: true)
        super.init()

        // Non-wrapping text view with both scrollers (WS_HSCROLL), monospaced like a plain edit control.
        let textView = TextViewerTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width, .height]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.onClose = { NSApp.stopModal() }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addConstraint(NSLayoutConstraint(item: scrollView, attribute: .height, relatedBy: .greaterThanOrEqual,
                                                    toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 320))

        // MY_BUTTON__CLOSE: IDCLOSE "&Close" (IDS_CLOSE 408), DEFPUSHBUTTON.
        let close = DialogKit.button(Lang.text(408, "Close"), target: self, action: #selector(closeClicked), key: "\r")
        let buttonRow = NSStackView(views: [NSView(), close])
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [scrollView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for view in [scrollView, buttonRow] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }

        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 480)
        window.initialFirstResponder = textView
    }

    @objc private func closeClicked() { NSApp.stopModal() }
}
