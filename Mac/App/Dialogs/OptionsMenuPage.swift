// OptionsMenuPage.swift -- Options > 7-Zip (IDD_MENU 2300, "7-Zip"): the shell-integration page.
// 01b-fm-dialogs-settings.md section 4.13, 03-shell-integration-inventory.md sections 1.3 / 6.2 /
// 6.4 / 7, 01-fm-feature-inventory.md section 9 #2 and #23.
//
// On Windows the first checkbox registers 7-zip.dll as a context-menu handler. On macOS the
// context menu comes from the Finder Sync extension, which only the user can enable (System
// Settings > General > Login Items & Extensions), so the checkbox becomes a live status display
// plus the button and the pluginkit commands that turn it on. Everything else is stored under the
// same Options.* keys Windows uses, so the extension (the `finder` scope) reads them unchanged.

import Cocoa
import SevenZipKit

final class OptionsMenuPage: OptionsPageBase, NSTableViewDataSource, NSTableViewDelegate {

    override var pageID: UInt32 { 2300 }                      // IDD_MENU
    override var fallbackTitle: String { "7-Zip" }
    override var helpTopic: String { "fm/options.htm#sevenZip" }

    /// Bundle id of the Finder Sync extension (Mac/FinderSync/Info.plist).
    private static let finderSyncBundleID = "com.yrambler2001.7zip.FinderSync"

    /// One check-list row: MenuPage.cpp kMenuItems[] (:49-71), text built like :237-278.
    private struct MenuItemRow {
        let langID: UInt32
        let fallback: String
        let flag: Settings.ContextMenuFlags
        let suffix: String            // " >" for the cascaded entries
        let argument: String?         // "{0}" replacement (<Folder>, <Archive>.7z, ...)
        let literal: String?          // CRC SHA rows are hard-coded on Windows too
    }

    private static let menuItems: [MenuItemRow] = [
        MenuItemRow(langID: 2322, fallback: "Open archive", flag: .open, suffix: "", argument: nil, literal: nil),
        MenuItemRow(langID: 2322, fallback: "Open archive", flag: .openAs, suffix: " >", argument: nil, literal: nil),
        MenuItemRow(langID: 2323, fallback: "Extract files...", flag: .extractFiles, suffix: "", argument: nil, literal: nil),
        MenuItemRow(langID: 2326, fallback: "Extract Here", flag: .extractHere, suffix: "", argument: nil, literal: nil),
        MenuItemRow(langID: 2327, fallback: "Extract to {0}", flag: .extractTo, suffix: "", argument: "<Folder>", literal: nil),
        MenuItemRow(langID: 2325, fallback: "Test archive", flag: .test, suffix: "", argument: nil, literal: nil),
        MenuItemRow(langID: 2324, fallback: "Add to archive...", flag: .compress, suffix: "", argument: nil, literal: nil),
        MenuItemRow(langID: 2328, fallback: "Add to {0}", flag: .compressTo7z, suffix: "", argument: "<Archive>.7z", literal: nil),
        MenuItemRow(langID: 2328, fallback: "Add to {0}", flag: .compressToZip, suffix: "", argument: "<Archive>.zip", literal: nil),
        MenuItemRow(langID: 2329, fallback: "Compress and email...", flag: .compressEmail, suffix: "", argument: nil, literal: nil),
        MenuItemRow(langID: 2330, fallback: "Compress to {0} and email", flag: .compressTo7zEmail, suffix: "", argument: "<Archive>.7z", literal: nil),
        MenuItemRow(langID: 2330, fallback: "Compress to {0} and email", flag: .compressToZipEmail, suffix: "", argument: "<Archive>.zip", literal: nil),
        MenuItemRow(langID: 1046, fallback: "Checksum", flag: .crc, suffix: " >", argument: nil, literal: "CRC SHA"),
        MenuItemRow(langID: 1046, fallback: "Checksum", flag: .crcCascaded, suffix: " >", argument: nil, literal: "7-Zip > CRC SHA"),
    ]

    // IDX_SYSTEM_INTEGRATE_TO_MENU 2301 -- read-only on macOS (see the file header).
    // IDX_SYSTEM_INTEGRATE_TO_MENU_2 2310 (the 32-bit shell DLL on 64-bit Windows) has no
    // counterpart: there is one Finder extension (03 §1.8).
    private let integrateCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let integrateStatus = OptionsUI.note("")
    private let enableButton = NSButton()
    private let diagnosticsField = NSTextField(labelWithString: "")
    private var cascadedCheckbox: NSButton!      // IDX_SYSTEM_CASCADED_MENU 2302
    private var iconsCheckbox: NSButton!         // IDX_SYSTEM_ICON_IN_MENU 2304
    private var elimDupCheckbox: NSButton!       // IDX_EXTRACT_ELIM_DUP 3430
    private let zoneLabel = OptionsUI.label(3440, "Propagate Zone.Id stream:")   // IDT_SYSTEM_ZONE 3440
    private let zoneCombo = NSPopUpButton(frame: .zero, pullsDown: false)        // IDC_SYSTEM_ZONE 101
    private let zoneNote = OptionsUI.note("")
    private let itemsLabel = OptionsUI.label(2303, "Context menu items:")        // IDT_SYSTEM_CONTEXT_MENU_ITEMS 2303
    private let itemsTable = NSTableView()                                        // IDL_SYSTEM_OPTIONS 100
    private var itemChecked = [Bool](repeating: true, count: OptionsMenuPage.menuItems.count)
    private var zoneRawValue = -1
    // Per-control change flags: CMenuPage keeps one _*_Changed per control and
    // CContextMenuInfo::Save writes a bool pair only when its CBoolPair::Def is set
    // (MenuPage.cpp:370-436, ZipRegistryMac.cpp:433-443).
    private var cascadedChanged = false
    private var iconsChanged = false
    private var elimDupChanged = false
    private var flagsChanged = false
    private var cascadedWasDefined = false
    private var iconsWasDefined = false
    private var elimDupWasDefined = false

    override func loadView() {
        super.loadView()

        integrateCheckbox.target = self
        integrateCheckbox.action = #selector(integrateClicked(_:))
        enableButton.title = "Open Login Items & Extensions\u{2026}"
        enableButton.bezelStyle = .rounded
        enableButton.target = self
        enableButton.action = #selector(openSystemSettings(_:))
        diagnosticsField.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        diagnosticsField.textColor = .secondaryLabelColor
        diagnosticsField.isSelectable = true
        diagnosticsField.lineBreakMode = .byTruncatingTail
        // `lineBreakMode` alone only says *how* to truncate: a label still resists compression
        // below its full text, and this one's text is a pluginkit command line with a bundle
        // identifier, a version and a path in it. Tied to the stack width, that pushed the whole
        // Options window out to 2191 pt -- wider than the screen, with the tab strip and the
        // OK / Cancel buttons off the right edge. Let it be squeezed and truncated instead.
        diagnosticsField.cell?.usesSingleLineMode = true
        diagnosticsField.maximumNumberOfLines = 1
        diagnosticsField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        cascadedCheckbox = OptionsUI.checkbox(2302, "Cascaded context menu", self, #selector(optionClicked(_:)))
        iconsCheckbox = OptionsUI.checkbox(2304, "Icons in context menu", self, #selector(optionClicked(_:)))
        elimDupCheckbox = OptionsUI.checkbox(3430, "Eliminate duplication of root folder", self, #selector(optionClicked(_:)))

        zoneCombo.target = self
        zoneCombo.action = #selector(optionClicked(_:))
        zoneCombo.translatesAutoresizingMaskIntoConstraints = false
        zoneCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        // LVS_SINGLESEL | LVS_NOCOLUMNHEADER with LVS_EX_CHECKBOXES (MenuPage.cpp:232-236).
        itemsTable.addTableColumn(OptionsUI.column("item", "", width: 420))
        itemsTable.headerView = nil
        itemsTable.rowHeight = 20
        itemsTable.style = .plain
        itemsTable.dataSource = self
        itemsTable.delegate = self
        let itemsScroll = OptionsUI.scrollTable(itemsTable, minHeight: 120)

        let zoneRow = OptionsUI.hstack([zoneLabel, zoneCombo])
        let stack = OptionsUI.vstack([
            integrateCheckbox, integrateStatus,
            OptionsUI.hstack([enableButton]), diagnosticsField,
            separator(),
            cascadedCheckbox, iconsCheckbox, elimDupCheckbox,
            zoneRow, zoneNote,
            itemsLabel, itemsScroll,
        ], spacing: 7)
        install(stack)
        NSLayoutConstraint.activate([
            itemsScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            integrateStatus.widthAnchor.constraint(equalTo: stack.widthAnchor),
            diagnosticsField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            zoneNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 400).isActive = true
        return box
    }

    /// MenuPage.cpp:241-278.
    private static func title(for row: MenuItemRow) -> String {
        var s = row.literal ?? Lang.text(row.langID, row.fallback)
        if let argument = row.argument { s = Lang.format(s, argument) }
        return s + row.suffix
    }

    // MARK: OnInit

    override func pageDidLoad() {
        relabelPage()
        cascadedCheckbox.state = Settings.cascadedMenuValue ? .on : .off
        iconsCheckbox.state = Settings.menuIconsValue ? .on : .off
        elimDupCheckbox.state = Settings.elimDupExtractValue ? .on : .off
        zoneRawValue = Settings.writeZoneIdExtract
        rebuildZoneCombo()
        cascadedChanged = false
        iconsChanged = false
        elimDupChanged = false
        flagsChanged = false
        cascadedWasDefined = Settings.cascadedMenu != nil
        iconsWasDefined = Settings.menuIcons != nil
        elimDupWasDefined = Settings.elimDupExtract != nil
        let flags = Settings.contextMenuFlags
        itemChecked = Self.menuItems.map { flags.contains($0.flag) }
        itemsTable.reloadData()
        refreshIntegrationState()
    }

    override func relabelPage() {
        integrateCheckbox.title = Lang.text(2301, "Integrate 7-Zip to shell context menu")
        cascadedCheckbox.title = Lang.text(2302, "Cascaded context menu")
        iconsCheckbox.title = Lang.text(2304, "Icons in context menu")
        elimDupCheckbox.title = Lang.text(3430, "Eliminate duplication of root folder")
        zoneLabel.stringValue = Lang.text(3440, "Propagate Zone.Id stream:")
        itemsLabel.stringValue = Lang.text(2303, "Context menu items:")
        zoneNote.stringValue = "On macOS this propagates the com.apple.quarantine attribute to "
            + "extracted files instead of the Windows Zone.Identifier stream."
        itemsTable.reloadData()
        rebuildZoneCombo()
    }

    /// The combo of MenuPage.cpp:196-228: `* No` (lang 406), `Yes` (407), `For Office files`
    /// (IDT_ZONE_FOR_OFFICE 3441) and the raw number when the stored value is >= 3.
    private func rebuildZoneCombo() {
        let selected = zoneRawValue
        zoneCombo.removeAllItems()
        var values: [Int] = [0, 1, 2]
        if selected >= 3 { values.append(selected) }
        for value in values {
            let title: String
            switch value {
            // MenuPage.cpp:213-216: MY_IDNO is lang id 407, MY_IDYES is 406 (kLangPairs).
            case 0: title = "* " + Lang.text(407, "No")
            case 1: title = Lang.text(406, "Yes")
            case 2: title = Lang.text(3441, "For Office files")
            default: title = String(value)
            }
            zoneCombo.addItem(withTitle: title)
            zoneCombo.lastItem?.tag = value
        }
        let index = values.firstIndex(of: max(selected, 0)) ?? 0
        zoneCombo.selectItem(at: index)
    }

    // MARK: Finder Sync state (03 section 6.4 / section 7)

    private func refreshIntegrationState() {
        integrateCheckbox.isEnabled = false
        integrateStatus.stringValue = "Checking the Finder integration state\u{2026}"
        setDiagnostics("pluginkit -e use -i \(Self.finderSyncBundleID)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let output = Self.runPluginkit()
            let line = output.split(separator: "\n").first { $0.contains(Self.finderSyncBundleID) }
            let enabled = line?.hasPrefix("+") ?? false
            let registered = line != nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.integrateCheckbox.state = enabled ? .on : .off
                if enabled {
                    self.integrateStatus.stringValue = "The Finder extension is enabled. Finder shows the 7-Zip menu "
                        + "for the items you select."
                } else if registered {
                    self.integrateStatus.stringValue = "The Finder extension is registered but not enabled. Enable "
                        + "\u{201C}7-Zip\u{201D} in System Settings > General > Login Items & Extensions "
                        + "(File Providers / Finder), or run the command below."
                } else {
                    self.integrateStatus.stringValue = "The Finder extension is not registered yet. Launch the app "
                        + "from /Applications once, then enable it in System Settings > General > "
                        + "Login Items & Extensions."
                }
                self.setDiagnostics("pluginkit -e use -i \(Self.finderSyncBundleID)"
                    + "   |   " + (line.map(String.init) ?? "pluginkit -m -p com.apple.FinderSync -v: not listed"))
            }
        }
    }

    /// The field truncates (it must not widen the window), so the full command stays reachable
    /// as a tool tip and by selecting the text.
    private func setDiagnostics(_ text: String) {
        diagnosticsField.stringValue = text
        diagnosticsField.toolTip = text
    }

    private static func runPluginkit() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-p", "com.apple.FinderSync", "-v"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    @objc private func integrateClicked(_ sender: Any?) {
        // Not user-settable from inside the app; keep the displayed state truthful.
        refreshIntegrationState()
    }

    @objc private func openSystemSettings(_ sender: Any?) {
        let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")
            ?? URL(fileURLWithPath: "/System/Applications/System Settings.app")
        NSWorkspace.shared.open(url)
    }

    @objc private func optionClicked(_ sender: Any?) {
        switch sender {
        case let combo as NSPopUpButton where combo === zoneCombo:
            zoneRawValue = combo.selectedItem?.tag ?? 0
        case let button as NSButton where button === cascadedCheckbox:
            cascadedChanged = true
        case let button as NSButton where button === iconsCheckbox:
            iconsChanged = true
        case let button as NSButton where button === elimDupCheckbox:
            elimDupChanged = true
        default:
            flagsChanged = true          // one of the context-menu item checkboxes
        }
        changed()
    }

    // MARK: OnApply (MenuPage.cpp:299-358: write only what changed)

    override func applyPage() -> Bool {
        if cascadedChanged || cascadedWasDefined { Settings.cascadedMenu = cascadedCheckbox.state == .on }
        if iconsChanged || iconsWasDefined { Settings.menuIcons = iconsCheckbox.state == .on }
        if elimDupChanged || elimDupWasDefined { Settings.elimDupExtract = elimDupCheckbox.state == .on }
        // MenuPage.cpp:337-342: index <= 0 is stored as -1 ("not set").
        Settings.writeZoneIdExtract = zoneRawValue <= 0 ? -1 : zoneRawValue
        if flagsChanged || Settings.contextMenuFlagsDefined {
            var flags: Settings.ContextMenuFlags = []
            for (i, checked) in itemChecked.enumerated() where checked {
                flags.insert(Self.menuItems[i].flag)
            }
            Settings.contextMenuFlags = flags
        }
        cascadedChanged = false
        iconsChanged = false
        elimDupChanged = false
        flagsChanged = false
        cascadedWasDefined = Settings.cascadedMenu != nil
        iconsWasDefined = Settings.menuIcons != nil
        elimDupWasDefined = Settings.elimDupExtract != nil
        return true
    }

    // MARK: The context-menu item check-list

    func numberOfRows(in tableView: NSTableView) -> Int { Self.menuItems.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let box = NSButton(checkboxWithTitle: Self.title(for: Self.menuItems[row]),
                           target: self, action: #selector(itemToggled(_:)))
        box.tag = row
        box.state = itemChecked[row] ? .on : .off
        let cell = NSTableCellView()
        box.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            box.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    @objc private func itemToggled(_ sender: NSButton) {
        guard itemChecked.indices.contains(sender.tag) else { return }
        itemChecked[sender.tag] = sender.state == .on
        flagsChanged = true
        changed()
    }
}
