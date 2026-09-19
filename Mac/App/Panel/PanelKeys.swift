// PanelKeys.swift -- CPanel::OnKeyDown (PanelKey.cpp:39-357) and PanelSelect.cpp: the full key
// map of the list and the address bar, and every selection command. Windows Ctrl maps to Command
// (01 §3.7 macOS note), the F-keys are unchanged, and Ctrl+W / Cmd+W closes the window.
//
// Keys bound as a menu key equivalent (Cmd+A, Cmd+R, Cmd+N, Cmd+Z, Cmd+1..4, Cmd+F3..F7, F2..F7,
// F9, Alt+F12, Alt+Enter, Shift+Enter, Cmd+Backspace, Cmd+Up, Cmd+PageDown) arrive through the
// menu, which sends the same selector to this panel; the rest is handled below.

import Cocoa
import SevenZipKit

/// The raw key codes the panel switches on (ASCII and NSxxxFunctionKey).
private enum PanelKey {
    static let tab = 0x09
    static let enter = 0x03
    static let ret = 0x0D
    static let backspace = 0x7F
    static let escape = 0x1B
    static let space = 0x20
    static let star = 0x2A
    static let plus = 0x2B
    static let minus = 0x2D
    static let slash = 0x2F
    static let backslash = 0x5C
    static let leftBracket = 0x5B
    static let rightBracket = 0x5D
}

extension PanelViewController {

    /// Returns true when the key was consumed.
    func handleListKeyDown(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = mods.contains(.shift)
        let option = mods.contains(.option)
        let command = mods.contains(.command)
        guard let scalar = (event.charactersIgnoringModifiers ?? "").unicodeScalars.first else { return false }
        let key = Int(scalar.value)

        if shift, selectionAnchor < 0 { selectionAnchor = focusedIndex }   // anchor (01 §3.7)
        if !shift { selectionAnchor = -1 }

        switch key {
        case PanelKey.tab:                                          // Tab -> OnTab
            if !command {
                delegate?.panelWantsNextPanel(self)
                return true
            }
        case PanelKey.ret, PanelKey.enter:                          // Return / Enter
            if !command {
                activateFocusedItem(modifiers: mods)
                return true
            }
        case PanelKey.backspace:                                    // Backspace -> parent folder
            if !command {
                goUp()
                return true
            }
        case NSDeleteFunctionKey:                                    // fn+Delete -> delete items
            deleteItems(toTrash: !shift)
            return true
        case PanelKey.star:                                         // Num * -> InvertSelection
            invertSelection()
            return true
        case PanelKey.plus:                                         // Num +
            // "+" on the main keyboard is Shift+"=", so only a real keypad key can mean Shift+Num+.
            let plusShift = shift && mods.contains(.numericPad)
            if option { selectByType(true) } else if plusShift { selectAll(true) } else { selectSpec(true) }
            return true
        case PanelKey.minus:                                        // Num -
            if option { selectByType(false) } else if shift { selectAll(false) } else { selectSpec(false) }
            return true
        case PanelKey.backslash, PanelKey.slash:                    // OpenDrivesFolder
            if !command && !option {
                openDrivesFolder()
                return true
            }
        case PanelKey.leftBracket:                                  // Cmd+[ -> Back (macOS idiom)
            if command {
                goBack()
                return true
            }
        case PanelKey.rightBracket:                                 // Cmd+] -> Forward
            if command {
                goForward()
                return true
            }
        case NSUpArrowFunctionKey:
            if option { delegate?.panel(self, setOtherPanelPath: currentPath); return true }   // Alt+Up
            if shift && usesAlternativeSelection { arrowWithShift(delta: -1); return true }
        case NSDownArrowFunctionKey:
            if shift && usesAlternativeSelection { arrowWithShift(delta: 1); return true }
        case NSLeftArrowFunctionKey, NSRightArrowFunctionKey:
            if option { setOtherPanelToFocusedSubFolder(); return true }                        // Alt+Left/Right
        case NSPageUpFunctionKey:
            if command && !option && !shift { goUp(); return true }                            // Ctrl+PgUp
        case NSPageDownFunctionKey:
            if command && !option && !shift { openSelection(insideOnly: true); return true }    // Ctrl+PgDn
        case NSF1FunctionKey:
            if option && !command { delegate?.panel(self, focusAddressBarOfPanel: 0); return true }
        case NSF2FunctionKey:
            if option && !command { delegate?.panel(self, focusAddressBarOfPanel: 1); return true }
        case NSF4FunctionKey:
            if shift && !command && !option { createFile(); return true }                       // Shift+F4
        case NSF5FunctionKey:
            if shift && !command && !option {
                delegate?.panel(self, copyOrMove: false, copyToSame: true)                      // Shift+F5
                return true
            }
        case NSF6FunctionKey:
            if shift && !command && !option {
                delegate?.panel(self, copyOrMove: true, copyToSame: true)                       // Shift+F6
                return true
            }
        case PanelKey.space:
            // Apple keyboards have no Insert key: in AlternativeSelection mode Space is the
            // "toggle the focused item and move down" of OnInsert (01 §3.6), and in the normal
            // mode it calculates the size of the focused folder (IFolderCalcItemFullSize), which
            // is what F3 does there too (01 §3.11 "View / Edit").
            if !command && !option && !shift {
                if usesAlternativeSelection { insertToggleAndAdvance() } else { calcFocusedItemSize() }
                return true
            }
        case PanelKey.escape:                                       // Esc in the list: nothing
            return false
        default:
            break
        }
        return false
    }

    /// OnArrowWithShift (PanelSelect.cpp:43-133) in AlternativeSelection mode: toggle, then move.
    private func arrowWithShift(delta: Int) {
        let index = focusedIndex
        toggleMySelection(index)
        let next = max(0, min(rows.count - 1, index + delta))
        setFocus(next, extendingSelection: true)
    }

    /// OnInsert (PanelSelect.cpp:77-108).
    func insertToggleAndAdvance() {
        guard usesAlternativeSelection else { return }
        let index = focusedIndex
        toggleMySelection(index)
        setFocus(min(rows.count - 1, index + 1), extendingSelection: true)
    }

    func noteClickedRow(_ row: Int) {
        focusedIndex = row
    }

    /// Shift+click from the anchor (_prevFocusedItem) in AlternativeSelection mode.
    func selectRange(to row: Int) {
        let anchor = selectionAnchor >= 0 ? selectionAnchor : focusedIndex
        guard anchor >= 0 else { return }
        let range = anchor <= row ? anchor...row : row...anchor
        var set = IndexSet()
        for i in range where i >= 0 && i < rows.count && !rows[i].isParentRow { set.insert(i) }
        setSelectedIndexes(set)
        focusedIndex = row
    }

    // MARK: - Selection commands (PanelSelect.cpp)

    /// SelectAll(select) -- Shift+Num+ / Shift+Num- / Cmd+A (01 §3.6); ".." is excluded.
    func selectAll(_ select: Bool) {
        if select {
            var set = IndexSet()
            for (i, row) in rows.enumerated() where !row.isParentRow { set.insert(i) }
            setSelectedIndexes(set)
        } else {
            setSelectedIndexes(IndexSet())
        }
    }

    /// InvertSelection (Num *).
    func invertSelection() {
        let current = selectedIndexes
        var set = IndexSet()
        for (i, row) in rows.enumerated() where !row.isParentRow && !current.contains(i) { set.insert(i) }
        setSelectedIndexes(set)
    }

    /// KillSelection (after drag & drop and copy, PanelSelect.cpp:243).
    func killSelection() {
        setSelectedIndexes(IndexSet())
    }

    /// SelectSpec (PanelSelect.cpp:154-167): the Combo dialog with a wildcard mask.
    func selectSpec(_ select: Bool) {
        let title = select ? Lang.text(6402, "Select") : Lang.text(6403, "Deselect")    // IDS_SELECT / IDS_DESELECT
        guard let mask = ComboDialog.run(title: title, label: Lang.text(6404, "Mask:"), value: "*",
                                        strings: [], parent: view.window) else { return }
        applyMask(mask, select: select)
    }

    /// SelectByType (PanelSelect.cpp:169-204): Alt+Num+ / Alt+Num-.
    func selectByType(_ select: Bool) {
        guard let focused = focusedRow(), !focused.isParentRow else { return }
        switch PanelMask.selectByTypeRule(name: focused.name, isDirectory: focused.isDirectory) {
        case .allFolders:
            applyPredicate(select: select) { $0.isDirectory }
        case .filesWithoutExtension:
            applyPredicate(select: select) { !$0.isDirectory && $0.pathExtension.isEmpty }
        case .mask(let mask):
            applyMask(mask, select: select, filesOnly: true)
        }
    }

    private func applyPredicate(select: Bool, _ matches: (PanelRow) -> Bool) {
        var set = selectedIndexes
        for (i, row) in rows.enumerated() where !row.isParentRow && matches(row) {
            if select { set.insert(i) } else { set.remove(i) }
        }
        setSelectedIndexes(set)
    }

    private func applyMask(_ mask: String, select: Bool, filesOnly: Bool = false) {
        var set = selectedIndexes
        for (i, row) in rows.enumerated() where !row.isParentRow {
            if filesOnly && row.isDirectory { continue }
            guard PanelMask.matches(mask: mask, name: row.name) else { continue }
            if select { set.insert(i) } else { set.remove(i) }
        }
        setSelectedIndexes(set)
    }

    // MARK: - Menu commands (the Edit menu, 01 §2.2 -- each one refreshes the status bar)

    @objc func editSelectAll(_ sender: Any?) { selectAll(true); refreshStatusBar() }          // IDM_SELECT_ALL 600
    @objc func editDeselectAll(_ sender: Any?) { selectAll(false); refreshStatusBar() }       // IDM_DESELECT_ALL 601
    @objc func editInvertSelection(_ sender: Any?) { invertSelection(); refreshStatusBar() }  // IDM_INVERT_SELECTION 602
    @objc func editSelect(_ sender: Any?) { selectSpec(true); refreshStatusBar() }            // IDM_SELECT 603
    @objc func editDeselect(_ sender: Any?) { selectSpec(false); refreshStatusBar() }         // IDM_DESELECT 604
    @objc func editSelectByType(_ sender: Any?) { selectByType(true); refreshStatusBar() }    // IDM_SELECT_BY_TYPE 605
    @objc func editDeselectByType(_ sender: Any?) { selectByType(false); refreshStatusBar() } // IDM_DESELECT_BY_TYPE 606
}
