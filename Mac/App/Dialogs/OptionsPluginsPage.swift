// OptionsPluginsPage.swift -- Options > Plugins: informational.
//
// 7-Zip 26.03 has no plugin chooser: CExtPlugins.Plugins only ever holds the built-in
// CArchiveFolderManager and the plugin enumeration in FilePlugins.cpp:21-41 is commented out
// (03-shell-integration-inventory.md section 3.4, 01-fm-feature-inventory.md section 6.8), and the
// macOS build links every codec statically into SevenZipCore (01 section 9 #29). So instead of an
// empty page this one lists what the engine actually loaded, which is what a user would look for
// here: the archive handlers from SZCodecs with their extensions and whether they can write.

import Cocoa
import SevenZipKit

final class OptionsPluginsPage: OptionsPageBase, NSTableViewDataSource, NSTableViewDelegate {

    override var pageID: UInt32 { 0 }                        // no IDD_* : macOS-only page
    override var fallbackTitle: String { "Plugins" }
    override var helpTopic: String { "fm/plugins/index.htm" }

    private let table = NSTableView()
    private let headerLabel = NSTextField(wrappingLabelWithString: "")
    private var formats: [SZFormatInfo] = []

    override func loadView() {
        super.loadView()
        table.addTableColumn(OptionsUI.column("name", "Format", width: 110))
        table.addTableColumn(OptionsUI.column("update", "Create", width: 56))
        table.addTableColumn(OptionsUI.column("ext", "Extensions", width: 260))
        table.addTableColumn(OptionsUI.column("flags", "Capabilities", width: 170))
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.rowHeight = 18
        table.dataSource = self
        table.delegate = self

        headerLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.isSelectable = true

        let scroll = OptionsUI.scrollTable(table, minHeight: 300)
        let stack = OptionsUI.vstack([headerLabel, scroll], spacing: 8)
        install(stack)
        NSLayoutConstraint.activate([
            headerLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    override func pageDidLoad() {
        formats = SZCodecs.formats
        relabelPage()
        table.reloadData()
    }

    override func relabelPage() {
        let writable = formats.filter(\.updateEnabled).count
        headerLabel.stringValue = """
            7-Zip \(SZEngineVersionString()) \u{2014} the codecs and archive handlers are linked into the \
            application, so there is nothing to add or remove (7-Zip 26.03 has no plugin chooser either).
            \(formats.count) handlers loaded, \(writable) of them can create or update archives.
            """
    }

    func numberOfRows(in tableView: NSTableView) -> Int { formats.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let format = formats[row]
        let text: String
        switch tableColumn?.identifier.rawValue ?? "" {
        case "name": text = format.name
        case "update": text = format.updateEnabled ? "yes" : ""
        case "ext": text = format.extensions.joined(separator: " ")
        default:
            var caps: [String] = []
            if format.isHashHandler { caps.append("hash") }
            if format.supportsAltStreams { caps.append("streams") }
            if format.supportsSymLinks { caps.append("symlinks") }
            if format.supportsHardLinks { caps.append("hardlinks") }
            if format.supportsNtSecurity { caps.append("security") }
            if format.findSignature { caps.append("signature") }
            text = caps.joined(separator: ", ")
        }
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingTail
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}
