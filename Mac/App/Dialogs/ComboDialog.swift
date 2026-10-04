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

        // ComboDialog.cpp:35-37: SetText(Value) + AddString(Strings[i]).
        combo.isEditable = true
        combo.completes = true
        combo.usesDataSource = false
        combo.numberOfVisibleItems = 12
        if !strings.isEmpty { combo.addItems(withObjectValues: strings) }
        combo.stringValue = value

        // IDD_COMBO 98 (ComboDialog.rc): 256 x 80 DLU = 384 x 130 px, resizable (WS_THICKFRAME);
        // OnSize keeps OK / Cancel at the bottom right and stretches the combo (dlgfeel).
        let rc = RcDialog(98)
        let form = RcFormView()
        form.add(DialogKit.label(label), rc, 100)                                // IDT_COMBO 100 (LTEXT)
        form.add(combo, rc, 101)
        // OK_CANCEL: OK is the default button, Cancel answers Escape.
        let ok = form.add(DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r"), rc, 1)
        let cancel = form.add(DialogKit.button(Lang.text(402, "Cancel"), target: self,
                                               action: #selector(cancelClicked), key: "\u{1b}"), rc, 2)
        let comboRect = rc.rect(101)
        form.onResize = { [combo] size in
            RcResize.bottomRightButtons([(cancel, rc.rect(2).size), (ok, rc.rect(1).size)], in: size)
            RcResize.setWidth(combo, size.width - 2 * RcResize.mx, rect: comboRect)
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

    @objc private func okClicked() {
        result = combo.stringValue                       // OnOK: _comboBox.GetText(Value)
        NSApp.stopModal()
    }

    @objc private func cancelClicked() {
        result = nil
        NSApp.stopModal()
    }
}
