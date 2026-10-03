// CopyMoveDialog.swift -- CCopyDialog / IDD_COPY 96 (CopyDialog.cpp/.rc), built in code.
// Parity: 01b-fm-dialogs-settings.md 4.5. 320 x 144 du, resizable (OnSize stretches the combo
// and the info text); the .rc caption "Copy" is replaced by Title (IDS_COPY 6000 / IDS_MOVE 6001).
// Label IDT_COPY 100 = IDS_COPY_TO 6002 / IDS_MOVE_TO 6003, the edit combo IDC_COPY 101 lists
// the CopyHistory and starts with Value, "..." IDB_COPY_SET_PATH 102 browses for a folder, and
// IDT_COPY_INFO 103 (SS_NOPREFIX | SS_LEFTNOWORDWRAP) shows at most kCopyDialog_NumInfoLines
// = 11 lines of Info (CopyDialog.h:11). OnOK (:99-103) reads the edit text back untrimmed.

import AppKit

/// The Copy / Move destination dialog. Main thread only.
enum CopyMoveDialog {

    /// `move` picks the Move titles, `info` is the pre-formatted multi-line info text.
    /// Returns the typed destination path, or nil when cancelled.
    static func run(move: Bool, value: String, history: [String], info: String,
                    parent: NSWindow?) -> String? {
        let dialog = CopyMoveDialogController(move: move, value: value, history: history,
                                              info: info, parent: parent)
        return dialog.run()
    }
}

private final class CopyMoveDialogController: NSObject {

    /// kCopyDialog_NumInfoLines (CopyDialog.h:11)
    private static let numInfoLines = 11

    private let window: NSWindow
    private let combo = NSComboBox()                    // IDC_COPY 101 (MY_COMBO_WITH_EDIT)
    private var result: String?

    init(move: Bool, value: String, history: [String], info: String, parent: NSWindow?) {
        // IDD_COPY 96: Title = IDS_COPY 6000 "Copy" / IDS_MOVE 6001 "Move" (App.cpp).
        window = DialogKit.window(title: move ? Lang.text(6001, "Move") : Lang.text(6000, "Copy"), resizable: true)
        super.init()

        // IDT_COPY 100: IDS_COPY_TO 6002 "Copy to:" / IDS_MOVE_TO 6003 "Move to:".
        let label = DialogKit.label(move ? Lang.text(6003, "Move to:") : Lang.text(6002, "Copy to:"))

        // CopyDialog.cpp:30-32: AddString(Strings[i]) + SetText(Value).
        combo.isEditable = true
        combo.completes = true
        combo.usesDataSource = false
        combo.numberOfVisibleItems = 12
        combo.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if !history.isEmpty { combo.addItems(withObjectValues: history) }
        combo.stringValue = value
        combo.translatesAutoresizingMaskIntoConstraints = false
        combo.addConstraint(NSLayoutConstraint(item: combo, attribute: .width, relatedBy: .greaterThanOrEqual,
                                               toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 420))
        combo.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // IDB_COPY_SET_PATH 102: PUSHBUTTON "..." (bxsDots wide), right of the combo.
        let dots = DialogKit.button("...", target: self, action: #selector(browseClicked))
        dots.setContentHuggingPriority(.required, for: .horizontal)
        let pathRow = NSStackView(views: [combo, dots])
        pathRow.orientation = .horizontal
        pathRow.spacing = 6

        // IDT_COPY_INFO 103
        let infoView = CopyMoveDialogController.infoView(info)

        // OK_CANCEL: OK is the default button, Cancel answers Escape.
        let ok = DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r")
        let cancel = DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(cancelClicked), key: "\u{1b}")
        let buttons = NSStackView(views: [cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let buttonRow = NSStackView(views: [NSView(), buttons])   // OnSize keeps them bottom-right
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [label, pathRow, infoView, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [label, pathRow, infoView, buttonRow] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }

        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 480)
        window.initialFirstResponder = combo
    }

    /// IDT_COPY_INFO 103: SS_LEFTNOWORDWRAP text, at most kCopyDialog_NumInfoLines lines. One
    /// single-line, tail-truncating label per line: a single NSTextField with
    /// maximumNumberOfLines soft-wraps long lines, which the Windows control never does.
    private static func infoView(_ info: String) -> NSView {
        let lines = info.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .prefix(numInfoLines)
        let labels: [NSView] = lines.map { line in
            let field = NSTextField(labelWithString: String(line))
            field.alignment = .left
            // The info lines arrive bidi-isolated (PanelFormat.itemsInfo); a left-to-right base
            // keeps "Files: 1" in that order in Arabic or Hebrew too (`Bidi`, requests.md).
            Bidi.makeLeftToRight(field)
            field.usesSingleLineMode = true
            field.maximumNumberOfLines = 1
            field.lineBreakMode = .byTruncatingTail
            field.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return field
        }
        let stack = NSStackView(views: labels)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        for view in labels {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        return stack
    }

    /// Runs modally on the main thread; the whole value is selected first so typing replaces it.
    func run() -> String? {
        window.makeKeyAndOrderFront(nil)
        combo.selectText(nil)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return result
    }

    /// OnButtonSetPath (CopyDialog.cpp:84-97): MyBrowseForFolder(IDS_SET_FOLDER 6007, current
    /// text); the answer is a dir prefix and replaces the text.
    @objc private func browseClicked() {
        // IDS_SET_FOLDER has no built-in English string on Windows (01b §4.5); every call site
        // (Copy, Split, Combine, Link) uses the same fallback, the line of the English template
        // `Lang/en.ttt`.
        let title = Lang.text(6007, "Select destination folder.")
        guard let path = BrowseDialog.forFolder(title: title, initialPath: combo.stringValue, parent: window) else {
            return
        }
        combo.stringValue = path
    }

    @objc private func okClicked() {
        result = combo.stringValue                       // OnOK: _path.GetText(Value), untrimmed
        NSApp.stopModal()
    }

    @objc private func cancelClicked() {
        result = nil
        NSApp.stopModal()
    }
}
