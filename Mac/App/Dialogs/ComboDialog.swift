// ComboDialog.swift -- CComboDialog / IDD_COMBO 98 (ComboDialog.cpp/.rc), built in code.
// Parity: 01b-fm-dialogs-settings.md 4.4. 240 x 64 du, MY_MODAL_RESIZE_DIALOG_STYLE: the
// caption is `Title`, static IDT_COMBO 100 shows `Static`, the edit combo IDC_COMBO 101 is
// pre-filled with `Value` and lists `Strings`; OnOK (:60-64) reads the edit text back.
//
// Callers (01b 4.4): Select/Deselect by mask (PanelSelect.cpp), Create Folder / Create File /
// Comment (PanelOperations.cpp) and the Browse dialog's "+" button (Dlg_CreateFolder).

import AppKit

/// The single-value input dialog. Main thread only.
enum ComboDialog {

    /// Returns the edit-field text, or nil when the user cancelled.
    static func run(title: String, label: String, value: String = "",
                    strings: [String] = [], parent: NSWindow?) -> String? {
        let dialog = ComboDialogController(title: title, label: label, value: value,
                                           strings: strings, parent: parent)
        return dialog.run()
    }
}

private final class ComboDialogController: NSObject {

    private let window: NSWindow
    private let combo = NSComboBox()                    // IDC_COMBO 101 (MY_COMBO_WITH_EDIT)
    private var result: String?

    init(title: String, label: String, value: String, strings: [String], parent: NSWindow?) {
        // IDD_COMBO 98: caption "Combo" in the .rc, replaced by Title at OnInit.
        window = DialogKit.window(title: title, resizable: true)
        super.init()

        let staticText = DialogKit.label(label)         // IDT_COMBO 100 (LTEXT)

        // ComboDialog.cpp:35-37: SetText(Value) + AddString(Strings[i]).
        combo.isEditable = true
        combo.completes = true
        combo.usesDataSource = false
        combo.numberOfVisibleItems = 12
        combo.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        if !strings.isEmpty { combo.addItems(withObjectValues: strings) }
        combo.stringValue = value
        combo.translatesAutoresizingMaskIntoConstraints = false
        combo.addConstraint(NSLayoutConstraint(item: combo, attribute: .width, relatedBy: .greaterThanOrEqual,
                                               toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 320))

        // OK_CANCEL: OK is the default button, Cancel answers Escape.
        let ok = DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r")
        let cancel = DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(cancelClicked), key: "\u{1b}")
        let buttons = NSStackView(views: [cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let buttonRow = NSStackView(views: [NSView(), buttons])   // OnSize keeps them bottom-right
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [staticText, combo, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [staticText, combo, buttonRow] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }

        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 360)
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

    @objc private func okClicked() {
        result = combo.stringValue                       // OnOK: _comboBox.GetText(Value)
        NSApp.stopModal()
    }

    @objc private func cancelClicked() {
        result = nil
        NSApp.stopModal()
    }
}
