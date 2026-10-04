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
        // IDD_COPY 96: Title = IDS_COPY 6000 "Copy" / IDS_MOVE 6001 "Move" (App.cpp); IDT_COPY 100:
        // IDS_COPY_TO 6002 "Copy to:" / IDS_MOVE_TO 6003 "Move to:".
        run(title: move ? Lang.text(6001, "Move") : Lang.text(6000, "Copy"),
            label: move ? Lang.text(6003, "Move to:") : Lang.text(6002, "Copy to:"),
            value: value, history: history, info: info, parent: parent)
    }

    /// The same dialog with another caption and label: Combine (IDS_COMBINE 7400 + the first
    /// part's name, IDS_COMBINE_TO 7401, PanelSplitFile.cpp:412-492).
    static func run(title: String, label: String, value: String, history: [String], info: String,
                    parent: NSWindow?) -> String? {
        let dialog = CopyMoveDialogController(title: title, label: label, value: value, history: history,
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

    init(title: String, label: String, value: String, history: [String], info: String, parent: NSWindow?) {
        window = DialogKit.window(title: title, resizable: true)
        super.init()

        // CopyDialog.cpp:30-32: AddString(Strings[i]) + SetText(Value).
        combo.isEditable = true
        combo.completes = true
        combo.usesDataSource = false
        combo.numberOfVisibleItems = 12
        if !history.isEmpty { combo.addItems(withObjectValues: history) }
        combo.stringValue = value

        // IDD_COPY 96 (CopyDialog.rc): 336 x 160 DLU = 504 x 260 px, resizable; OnSize
        // (CopyDialog.cpp:38-68) keeps "..." at the right, stretches the combo and the info text,
        // and keeps OK / Cancel at the bottom right (dlgfeel).
        let rc = RcDialog(96)
        let form = RcFormView()
        form.add(DialogKit.label(label), rc, 100)                                // IDT_COPY 100
        form.add(combo, rc, 101)                                                 // IDC_COPY 101
        // IDB_COPY_SET_PATH 102: PUSHBUTTON "..." right of the combo.
        let dots = form.add(DialogKit.button("...", target: self, action: #selector(browseClicked)), rc, 102)
        // IDT_COPY_INFO 103 (SS_NOPREFIX | SS_LEFTNOWORDWRAP): at most kCopyDialog_NumInfoLines
        // lines, never wrapped, clipped at the right edge.
        let lines = info.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .prefix(Self.numInfoLines)
        let infoField = RcPlace.makeLabel(lines.joined(separator: "\n"))
        // The info lines arrive bidi-isolated (PanelFormat.itemsInfo); a left-to-right base
        // keeps "Files: 1" in that order in Arabic or Hebrew too (`Bidi`, requests.md).
        Bidi.makeLeftToRight(infoField)
        form.add(infoField, rc, 103)
        infoField.cell?.wraps = false
        infoField.lineBreakMode = .byClipping
        // OK_CANCEL: OK is the default button, Cancel answers Escape.
        let ok = form.add(DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r"), rc, 1)
        let cancel = form.add(DialogKit.button(Lang.text(402, "Cancel"), target: self,
                                               action: #selector(cancelClicked), key: "\u{1b}"), rc, 2)
        let comboRect = rc.rect(101), dotsRect = rc.rect(102), infoRect = rc.rect(103)
        form.onResize = { [combo] size in
            let mx = RcResize.mx
            let y = RcResize.bottomRightButtons([(cancel, rc.rect(2).size), (ok, rc.rect(1).size)], in: size)
            RcPlace.button(dots, NSRect(x: size.width - mx - dotsRect.width, y: dotsRect.minY,
                                        width: dotsRect.width, height: dotsRect.height))
            RcResize.setWidth(combo, size.width - mx - mx - dotsRect.width - mx, rect: comboRect)
            RcPlace.label(infoField, NSRect(x: mx, y: infoRect.minY, width: size.width - 2 * mx,
                                            height: max(0, y - 2 - infoRect.minY)))
            infoField.cell?.wraps = false
            infoField.lineBreakMode = .byClipping
        }
        RcPlace.install(form, in: window, size: rc.size, parent: parent)
        window.initialFirstResponder = combo
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
