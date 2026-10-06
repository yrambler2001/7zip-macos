// WinCompareSupport.swift -- text dumps of the app's own windows and menus, in the same shape as
// the dumps the `wincompare` scope took of the real 7zFM 25.01 on Windows (Win32 control walk,
// GetMenuItemInfo, LVM_GETITEMTEXT), so the two can be diffed line by line.
//
// ai/reports/wincompare.md explains how the Windows half was captured. Nothing here asserts:
// it only describes. The assertions that came out of the comparison live in WinCompareTests.

import AppKit
@testable import SevenZipAppHost

enum WinCompareDump {

    // MARK: - menus

    /// One line per item: title, key equivalent, Windows id (the tag), DISABLED / CHECKED.
    /// `validate` answers whether AppKit would enable the item.
    static func menu(_ menu: NSMenu, depth: Int = 0, validate: (NSMenuItem) -> Bool) -> String {
        var out = ""
        menu.delegate?.menuNeedsUpdate?(menu)
        for item in menu.items {
            let pad = String(repeating: "  ", count: depth)
            if item.isSeparatorItem { out += pad + "----\n"; continue }
            if item.isHidden { continue }
            var flags: [String] = []
            if item.submenu == nil, !validate(item) { flags.append("DISABLED") }
            if item.state == .on { flags.append("CHECKED") }
            let key = keyText(item)
            out += pad + item.title + (key.isEmpty ? "" : "\\t" + key)
                + "  [id " + (item.submenu != nil ? "sub" : "\(item.tag)") + "]"
                + (flags.isEmpty ? "" : " " + flags.joined(separator: ",")) + "\n"
            if let sub = item.submenu { out += Self.menu(sub, depth: depth + 1, validate: validate) }
        }
        return out
    }

    static func keyText(_ item: NSMenuItem) -> String {
        guard !item.keyEquivalent.isEmpty else { return "" }
        var s = ""
        let m = item.keyEquivalentModifierMask
        if m.contains(.control) { s += "Ctrl+" }
        if m.contains(.option) { s += "Opt+" }
        if m.contains(.shift) { s += "Shift+" }
        if m.contains(.command) { s += "Cmd+" }
        if m.contains(.numericPad) { s += "Num" }
        let k = item.keyEquivalent
        let scalar = k.unicodeScalars.first!.value
        switch scalar {
        case 0xF704...0xF70F: s += "F\(scalar - 0xF704 + 1)"
        case 0xF700: s += "Up"
        case 0xF701: s += "Down"
        case 0xF72C: s += "PgUp"
        case 0xF72D: s += "PgDn"
        case 0x0D: s += "Return"
        case 0x08: s += "Backspace"
        case 0x7F: s += "Delete"
        case 0x1B: s += "Esc"
        default: s += k.uppercased() == k && k.lowercased() != k && !m.contains(.shift) ? "Shift+" + k : k.uppercased()
        }
        return s
    }

    // MARK: - views

    /// Every visible view with its class, frame in top-left window coordinates and its text, the
    /// AppKit counterpart of the Win32 child-window walk.
    static func window(_ window: NSWindow) -> String {
        guard let content = window.contentView else { return "no content view\n" }
        content.layoutSubtreeIfNeeded()
        var out = "WINDOW '\(window.title)' frame=\(Int(window.frame.width))x\(Int(window.frame.height))"
            + " content=\(Int(content.bounds.width))x\(Int(content.bounds.height))\n"
        walk(content, in: content, depth: 1, into: &out)
        return out
    }

    private static func walk(_ view: NSView, in content: NSView, depth: Int, into out: inout String) {
        if view.isHidden { return }
        let pad = String(repeating: "  ", count: depth)
        let r = view.convert(view.bounds, to: content)
        let y = content.isFlipped ? r.minY : content.bounds.height - r.maxY
        var line = pad + String(describing: type(of: view)) + String(format: " @%.0f,%.0f %.0fx%.0f", r.minX, y, r.width, r.height)
        var descend = true
        switch view {
        case let popup as NSPopUpButton:
            line += (popup.isEnabled ? "" : " DISABLED") + " sel=\(popup.indexOfSelectedItem) items=["
                + popup.itemArray.map { $0.isSeparatorItem ? "---" : $0.title }.joined(separator: " | ") + "]"
            descend = false
        case let combo as NSComboBox:
            line += (combo.isEnabled ? "" : " DISABLED") + " '\(esc(combo.stringValue))' items=["
                + (0..<combo.numberOfItems).map { "\(combo.itemObjectValue(at: $0))" }.joined(separator: " | ") + "]"
            descend = false
        case let seg as NSSegmentedControl:
            line += " segments=[" + (0..<seg.segmentCount).map { seg.label(forSegment: $0) ?? "" }.joined(separator: " | ") + "]"
            descend = false
        case let button as NSButton:
            line += (button.isEnabled ? "" : " DISABLED") + " '\(esc(button.title))'"
            if let type = button.cell?.value(forKey: "buttonType") as? UInt {
                // checkboxes (3) and radios (4) report their state; push buttons do not
                if type == 3 || type == 4 { line += type == 3 ? " check=\(button.state == .on ? 1 : 0)" : " radio=\(button.state == .on ? 1 : 0)" }
            }
            if button.keyEquivalent == "\r" { line += " DEFAULT" }
            descend = false
        case let field as NSTextField:
            line += (field.isEnabled ? "" : " DISABLED") + (field.isEditable ? " EDIT" : "") + " '\(esc(field.stringValue))'"
            descend = false
        case let text as NSTextView:
            line += " '\(esc(String(text.string.prefix(400))))'"
            descend = false
        case let box as NSBox:
            if box.boxType == .primary || box.boxType == .custom, !box.title.isEmpty, box.titlePosition != .noTitle {
                line += " group '\(esc(box.title))'"
            }
        case let tabs as NSTabView:
            line += " tabs=[" + tabs.tabViewItems.map(\.label).joined(separator: " | ") + "] selected="
                + "\(tabs.selectedTabViewItem.map { tabs.indexOfTabViewItem($0) } ?? -1)"
        case let table as NSTableView:
            out += line + "\n" + Self.table(table, indent: pad + "  ")
            return
        case let image as NSImageView:
            line += image.image == nil ? " (no image)" : ""
            descend = false
        case let progress as NSProgressIndicator:
            line += String(format: " value=%.0f/%.0f", progress.doubleValue, progress.maxValue)
            descend = false
        default:
            break
        }
        out += line + "\n"
        guard descend else { return }
        if let tabs = view as? NSTabView {
            if let selected = tabs.selectedTabViewItem?.view { walk(selected, in: content, depth: depth + 1, into: &out) }
            return
        }
        for child in view.subviews { walk(child, in: content, depth: depth + 1, into: &out) }
    }

    /// A table's columns (title, width, alignment) and its rows as the cells show them.
    static func table(_ table: NSTableView, indent: String = "  ") -> String {
        var out = indent + "TABLE rows=\(table.numberOfRows) columns=\(table.tableColumns.count)\n"
        for (i, column) in table.tableColumns.enumerated() where !column.isHidden {
            let align: String
            switch column.headerCell.alignment {
            case .right: align = "right"
            case .center: align = "center"
            default: align = "left"
            }
            out += indent + "COL \(i) '\(column.title)' width=\(Int(column.width)) align=\(align)\n"
        }
        let columns = table.tableColumns.filter { !$0.isHidden }
        for row in 0..<min(table.numberOfRows, 300) {
            let texts: [String] = columns.map { column in
                if let view = table.delegate?.tableView?(table, viewFor: column, row: row) {
                    return cellText(view)
                }
                if let value = table.dataSource?.tableView?(table, objectValueFor: column, row: row) {
                    return "\(value)"
                }
                return ""
            }
            out += indent + (table.selectedRowIndexes.contains(row) ? "S " : "  ") + texts.joined(separator: " | ") + "\n"
        }
        return out
    }

    private static func cellText(_ view: NSView) -> String {
        if let cell = view as? NSTableCellView, let field = cell.textField { return field.stringValue }
        if let field = view as? NSTextField { return field.stringValue }
        for child in view.subviews { let t = cellText(child); if !t.isEmpty { return t } }
        return ""
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: "\\t").replacingOccurrences(of: "\n", with: "\\n")
    }
}
