// PanelTableView.swift -- the details list. Keys that 7zFM handles in CPanel::OnKeyDown
// (PanelKey.cpp) without a modifier are handled here: Enter opens, Backspace goes up,
// "\" or "/" opens the root folder. Everything with a modifier is a menu key equivalent.

import Cocoa

protocol PanelTableViewKeyHandler: AnyObject {
    func tableViewOpenSelection(_ tableView: PanelTableView, outside: Bool)
    func tableViewGoUp(_ tableView: PanelTableView)
    func tableViewGoRoot(_ tableView: PanelTableView)
    func tableViewDidBecomeFirstResponder(_ tableView: PanelTableView)
}

final class PanelTableView: NSTableView {

    weak var keyHandler: PanelTableViewKeyHandler?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { keyHandler?.tableViewDidBecomeFirstResponder(self) }
        return ok
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        switch chars {
        case "\r", "\u{3}":   // Return / Enter (IDM_OPEN; Shift+Enter = IDM_OPEN_OUTSIDE)
            if mods.isSubset(of: [.shift, .numericPad, .function]) {
                keyHandler?.tableViewOpenSelection(self, outside: mods.contains(.shift))
                return
            }
        case "\u{7f}", "\u{8}":   // Backspace (IDM_OPEN_PARENT_FOLDER)
            if mods.isEmpty {
                keyHandler?.tableViewGoUp(self)
                return
            }
        case "\\", "/":   // IDM_OPEN_ROOT_FOLDER
            if mods.isEmpty {
                keyHandler?.tableViewGoRoot(self)
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }
}
