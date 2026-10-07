// OptionsMenuPage.swift -- Options > 7-Zip (IDD_MENU 2300, "7-Zip"): the shell-integration page.
// 01b-fm-dialogs-settings.md section 4.13, 03-shell-integration-inventory.md sections 1.3 / 6.2 /
// 6.4 / 7, 01-fm-feature-inventory.md section 9 #2 and #23.
//
// On Windows the first checkbox registers 7-zip.dll as a context-menu handler. On macOS the
// context menu comes from the Finder Sync extension: the checkbox shows whether Finder uses *this*
// copy's extension and Apply switches it on or off through PlugInKit (`FinderExtensionControl`,
// appfeel), as MenuPage.cpp's OnApply calls SetContextMenuHandler. Everything else is stored under the same Options.* keys Windows
// uses, so the extension (the `finder` scope) reads them unchanged. The controls sit on the
// IDD_MENU template's rects (dlgfeel); the context-menu list shows all 14 items without a
// scroll bar, as on Windows.

import Cocoa
import SevenZipKit

final class OptionsMenuPage: OptionsPageBase, NSTableViewDataSource, NSTableViewDelegate {

    override var pageID: UInt32 { 2300 }                      // IDD_MENU
    override var fallbackTitle: String { "7-Zip" }
    override var helpTopic: String { "fm/options.htm#sevenZip" }

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

    // IDX_SYSTEM_INTEGRATE_TO_MENU 2301 -- the Finder extension's state (see the file header).
    // IDX_SYSTEM_INTEGRATE_TO_MENU_2 2310 (the 32-bit shell DLL on 64-bit Windows) has no
    // counterpart: there is one Finder extension (03 §1.8). MenuPage.cpp hides it the same way on
    // a 32-bit Windows (HideItem, the others keep their places).
    private let integrateCheckbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var cascadedCheckbox: NSButton!      // IDX_SYSTEM_CASCADED_MENU 2302
    private var iconsCheckbox: NSButton!         // IDX_SYSTEM_ICON_IN_MENU 2304
    private var elimDupCheckbox: NSButton!       // IDX_EXTRACT_ELIM_DUP 3430
    private let zoneLabel = OptionsUI.label(3440, "Propagate Zone.Id stream:")   // IDT_SYSTEM_ZONE 3440
    private let zoneCombo = NSPopUpButton(frame: .zero, pullsDown: false)        // IDC_SYSTEM_ZONE 101
    private let itemsLabel = OptionsUI.label(2303, "Context menu items:")        // IDT_SYSTEM_CONTEXT_MENU_ITEMS 2303
    private let itemsTable = NSTableView()                                        // IDL_SYSTEM_OPTIONS 100
    private var itemChecked = [Bool](repeating: true, count: OptionsMenuPage.menuItems.count)
    private var zoneRawValue = -1
    private var zoneChanged = false
    private var zoneWasDefined = false
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
    /// The Finder extension's state as `pluginkit` last reported it (nil while checking).
    private(set) var finderExtensionState: FinderExtensionControl.State?
    /// CShellDll::wasChanged: the box was clicked since the last Apply.
    private var integrateChanged = false
    /// The appex this copy carries (CShellDll::Path); nil disables the box (MenuPage.cpp:170-174).
    var embeddedAppexPath: String? = FinderExtensionControl.embeddedAppexPath

    override func loadView() {
        super.loadView()

        integrateCheckbox.target = self
        integrateCheckbox.action = #selector(integrateClicked(_:))
        cascadedCheckbox = OptionsUI.checkbox(2302, "Cascaded context menu", self, #selector(optionClicked(_:)))
        iconsCheckbox = OptionsUI.checkbox(2304, "Icons in context menu", self, #selector(optionClicked(_:)))
        elimDupCheckbox = OptionsUI.checkbox(3430, "Eliminate duplication of root folder", self, #selector(optionClicked(_:)))
        zoneCombo.target = self
        zoneCombo.action = #selector(optionClicked(_:))

        // LVS_REPORT | LVS_SINGLESEL | LVS_NOCOLUMNHEADER with LVS_EX_CHECKBOXES |
        // LVS_EX_FULLROWSELECT, one 200 px column (MenuPage.cpp:230-236).
        itemsTable.addTableColumn(OptionsUI.column("item", "", width: 200))
        itemsTable.dataSource = self
        itemsTable.delegate = self
        let itemsScroll = OptionsUI.listTable(itemsTable, header: false)

        let rc = self.rc
        form.add(integrateCheckbox, rc, 2301)
        form.add(cascadedCheckbox, rc, 2302)
        form.add(iconsCheckbox, rc, 2304)
        form.add(elimDupCheckbox, rc, 3430)
        form.add(zoneLabel, rc, 3440)
        form.add(zoneCombo, rc, 101)
        form.add(itemsLabel, rc, 2303)
        form.addSubview(itemsScroll)
        itemsScroll.frame = rc.rect(100)
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
        zoneWasDefined = Settings.writeZoneIdExtractDefined
        zoneChanged = false
        rebuildZoneCombo()
        cascadedChanged = false
        iconsChanged = false
        elimDupChanged = false
        flagsChanged = false
        integrateChanged = false
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
            // sec113: the `*` marks the default, which is Yes (All) on macOS -- a deliberate
            // difference from Windows' `* No` (docs/parity.md).
            case 0: title = Lang.text(407, "No")
            case 1: title = "* " + Lang.text(406, "Yes")
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

    /// CheckContextMenuHandler (MenuPage.cpp:170-180): the box is checked when Finder uses this
    /// copy's extension, disabled when this copy has none.
    func refreshIntegrationState(completion: (() -> Void)? = nil) {
        let embedded = embeddedAppexPath
        integrateCheckbox.isEnabled = embedded != nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = FinderExtensionControl.currentState(embeddedPath: embedded)
            DispatchQueue.main.async {
                self?.show(state)
                completion?()
            }
        }
    }

    private func show(_ state: FinderExtensionControl.State) {
        finderExtensionState = state
        integrateCheckbox.isEnabled = state != .notEmbedded
        // A click that has not been applied yet wins over a late answer from pluginkit.
        if !integrateChanged { integrateCheckbox.state = state.isOn ? .on : .off }
        integrateCheckbox.toolTip = FinderExtensionControl.describe(state)
    }

    /// OnButtonClicked(IDX_SYSTEM_INTEGRATE_TO_MENU): only marks the page changed; Apply acts.
    @objc private func integrateClicked(_ sender: Any?) {
        guard embeddedAppexPath != nil else { return }
        integrateChanged = true
        changed()
    }

    /// OnApply's SetContextMenuHandler (MenuPage.cpp:299-316): switch, report a failure in a
    /// "7-Zip" error box (ShowMenuErrorMessage), re-read the state into the box. When the election
    /// did not take, the System Settings pane is offered as the way that always works.
    private func applyIntegration(completion: (() -> Void)? = nil) {
        guard integrateChanged, let embedded = embeddedAppexPath else { completion?(); return }
        integrateChanged = false
        let wanted = integrateCheckbox.state == .on
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = FinderExtensionControl.setEnabled(wanted, embeddedPath: embedded)
            DispatchQueue.main.async {
                let failed = state.isOn != wanted && state != .notEmbedded
                guard let self else {
                    // OK closed the window before PlugInKit answered: still offer the pane.
                    if failed { FinderExtensionControl.showManagementInterface() }
                    completion?()
                    return
                }
                self.show(state)
                if failed {
                    // MenuPage.cpp:293: MessageBoxW(hwnd, m, "7-Zip", MB_ICONERROR).
                    let text = (wanted
                        ? "The Finder extension could not be turned on."
                        : "The Finder extension could not be turned off.")
                        + " Use System Settings > General > Login Items & Extensions > Finder.\n\n"
                        + FinderExtensionControl.describe(state)
                    WinMessageBox.show(text, icon: .error, owner: self.view.window ?? NSApp.mainWindow) { _ in
                        FinderExtensionControl.showManagementInterface()
                    }
                }
                completion?()
            }
        }
    }

    /// For the tests: Apply's PlugInKit half, with a completion.
    func applyIntegrationForTesting(completion: @escaping () -> Void) {
        applyIntegration(completion: completion)
    }

    @objc private func optionClicked(_ sender: Any?) {
        switch sender {
        case let combo as NSPopUpButton where combo === zoneCombo:
            zoneRawValue = combo.selectedItem?.tag ?? 0
            zoneChanged = true
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
        applyIntegration()
        if cascadedChanged || cascadedWasDefined { Settings.cascadedMenu = cascadedCheckbox.state == .on }
        if iconsChanged || iconsWasDefined { Settings.menuIcons = iconsCheckbox.state == .on }
        if elimDupChanged || elimDupWasDefined { Settings.elimDupExtract = elimDupCheckbox.state == .on }
        // MenuPage.cpp:337-342 stores index <= 0 as -1 ("not set" = No). sec113: unset means Yes
        // on macOS, so an explicit No is stored as 0, and nothing is written unless the user
        // changed the value or had already chosen one.
        if zoneChanged || zoneWasDefined { Settings.writeZoneIdExtract = max(zoneRawValue, 0) }
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
        // LVS_EX_CHECKBOXES: the state box 4 px in, the text after it in the list font.
        let box = NSButton(checkboxWithTitle: Self.title(for: Self.menuItems[row]),
                           target: self, action: #selector(itemToggled(_:)))
        box.tag = row
        box.state = itemChecked[row] ? .on : .off
        box.font = PanelMetrics.listFont
        box.controlSize = .small
        let cell = NSTableCellView()
        box.frame = NSRect(x: 4, y: 0, width: 196, height: 17)
        box.autoresizingMask = [.width]
        cell.addSubview(box)
        return cell
    }

    @objc private func itemToggled(_ sender: NSButton) {
        guard itemChecked.indices.contains(sender.tag) else { return }
        itemChecked[sender.tag] = sender.state == .on
        flagsChanged = true
        changed()
    }
}
