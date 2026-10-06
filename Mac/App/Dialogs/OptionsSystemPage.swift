// OptionsSystemPage.swift -- Options > System (IDD_SYSTEM 2200, "System"): the file-association
// editor. 01b-fm-dialogs-settings.md section 4.21, 03-shell-integration-inventory.md sections
// 3.1 / 3.4 / 6.2, 01-fm-feature-inventory.md section 9 #3.
//
// Windows writes HKCU|HKLM\Software\Classes entries (two state columns: current user / all
// users). macOS has no machine-wide association store, so the page is the NUM_EXT_GROUPS == 1
// build of SystemPage.cpp: the Type column and one state column, headed with the user's name.
// The controls sit on the IDD_SYSTEM template's rects (dlgfeel): no Description or Default
// application column, no extra buttons, no note. Associating calls
// NSWorkspace.setDefaultApplication(at:toOpen:),
// which shows the system's own confirmation and answers asynchronously; releasing a type hands it
// back to the application that owned it when the page was opened, because macOS has no API to
// remove a default handler.

import Cocoa
import UniformTypeIdentifiers
import SevenZipKit

/// The list view (IDL_SYSTEM_ASSOCIATE 100) must see the raw keys Windows binds
/// (Space / + / - / * and Return), which NSTableView would otherwise consume for type-select.
final class OptionsAssociationTableView: NSTableView {
    var onKey: ((String) -> Bool)?
    override func keyDown(with event: NSEvent) {
        // Alt+key is left to the system, as OnListKeyDown returns false for VK_MENU.
        if !event.modifierFlags.contains(.option),
           let chars = event.charactersIgnoringModifiers, onKey?(chars) == true { return }
        super.keyDown(with: event)
    }
}

final class OptionsSystemPage: OptionsPageBase, NSTableViewDataSource, NSTableViewDelegate {

    override var pageID: UInt32 { 2200 }                      // IDD_SYSTEM
    override var fallbackTitle: String { "System" }
    override var helpTopic: String { "FM/options.htm#system" }

    /// One row: an extension of FileTypes.all (7z.dll string resource 100).
    private final class Row {
        let type: SevenZipFileType
        var utType: UTType?
        /// Handler that owns the type right now.
        var ownerURL: URL?
        /// Handler that owned it when the page was loaded (restored by "release").
        var originalOwnerURL: URL?
        /// State when the page was loaded (kExtState_7Zip vs kExtState_Clear/Other).
        var originalIsOurs = false
        /// State the user wants.
        var wantsOurs = false
        init(_ type: SevenZipFileType) { self.type = type }
    }

    private var rows: [Row] = []
    private let table = OptionsAssociationTableView()                               // IDL_SYSTEM_ASSOCIATE 100
    private let associateLabel = OptionsUI.label(2201, "Associate 7-Zip with:")     // IDT_SYSTEM_ASSOCIATE 2201
    private var typeColumn: NSTableColumn?
    private var userColumn: NSTableColumn?
    private let setButton = NSButton()         // IDB_SYSTEM_CURRENT 101 ("+")
    private static let ourBundleID = Bundle.main.bundleIdentifier ?? "com.yrambler2001.7zip"

    override func loadView() {
        super.loadView()
        rows = FileTypes.all.map { type in
            let row = Row(type)
            row.utType = type.utType
            return row
        }

        let userName = NSUserName().isEmpty ? "Current User" : NSUserName()     // GetUserNameW fallback
        // SystemPage.cpp:166-211: Type 80 px (LVCFMT_LEFT), the user's column 152 px LVCFMT_CENTER.
        typeColumn = OptionsUI.column("type", Lang.text(1020, "Type"), width: 80)    // IDS_PROP_FILE_TYPE 1020
        userColumn = OptionsUI.column("user", userName, width: 152, alignment: .center)
        table.addTableColumn(typeColumn!)
        table.addTableColumn(userColumn!)
        table.allowsMultipleSelection = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        // NM_CLICK (SystemPage.cpp:375-396): a plain click on the state column toggles that row.
        table.action = #selector(rowClicked(_:))
        table.onKey = { [weak self] chars in
            guard let self else { return false }
            switch chars {
            // NM_RETURN (SystemPage.cpp:369-373): ChangeState(0) on the selection, else every row.
            case "\r", "\u{3}": self.toggleSelectedRows(nil)
            case " ": self.toggleSelectedRows(nil)
            case "+", "=": self.setSelected(nil)
            case "-", "\u{2212}": self.clearSelected(nil)
            case "*": self.selectAllRows(nil)
            default: return false
            }
            return true
        }

        setButton.title = "+"
        setButton.bezelStyle = .rounded
        setButton.target = self
        setButton.action = #selector(setSelected(_:))

        let rc = self.rc
        form.add(associateLabel, rc, 2201)
        // IDB_SYSTEM_CURRENT sits over the user's column (x 138 = list 12 + Type 80 + 46); the
        // All-users button IDB_SYSTEM_ALL 102 has no column to sit over on macOS.
        form.add(setButton, rc, 101)
        let scroll = OptionsUI.listTable(table, header: true)
        form.addSubview(scroll)
        scroll.frame = rc.rect(100)
    }

    // MARK: OnInit (CExtDatabase::Read + CShellExtInfo::ReadFromRegistry)

    override func pageDidLoad() {
        let workspace = NSWorkspace.shared
        let ourURL = Bundle.main.bundleURL
        for row in rows {
            let owner = row.utType.flatMap { workspace.urlForApplication(toOpen: $0) }
            row.ownerURL = owner
            row.originalOwnerURL = owner
            row.originalIsOurs = Self.isOurs(owner, ourURL: ourURL)
            row.wantsOurs = row.originalIsOurs
        }
        relabelPage()
    }

    override func relabelPage() {
        associateLabel.stringValue = Lang.text(2201, "Associate 7-Zip with:")
        typeColumn?.title = Lang.text(1020, "Type")
        table.reloadData()
    }

    // MARK: Format icons (7z.dll's icon resources, 01b section 4.21)

    private static var iconCache: [String: NSImage] = [:]

    /// The 7-Zip icon of the row's format, drawn exactly as the panel list draws it (docicons2):
    /// the `.ico`'s 16 x 16 frame, enlarged by whole pixels nearest-neighbour on Retina
    /// (`PanelArchiveIcons`, sffont). Windows draws `assoc.GetIconIndex()` from 7z.dll
    /// (SystemPage.cpp:95), an ImageList of small (16 px) icons from ExtractIconExW. Falls back to
    /// the bundled `doc-<name>.icns`, then to the system's icon for the type.
    static func formatIcon(for type: SevenZipFileType) -> NSImage? {
        let name = "doc-" + type.iconFileName
        if let cached = iconCache[name] { return cached }
        let image = PanelArchiveIcons.icon(named: type.iconFileName, large: false)
            ?? Bundle.main.url(forResource: name, withExtension: "icns").flatMap(NSImage.init(contentsOf:))
            ?? type.utType.map { NSWorkspace.shared.icon(for: $0) }
        if let image { iconCache[name] = image }
        return image
    }

    private static func isOurs(_ url: URL?, ourURL: URL) -> Bool {
        guard let url else { return false }
        return url.standardizedFileURL == ourURL.standardizedFileURL
    }

    /// The application's name without the ".app" extension.
    private static func displayName(_ url: URL) -> String {
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private static func isOther7Zip(_ url: URL?) -> Bool {
        guard let url else { return false }
        if let bundle = Bundle(url: url), bundle.bundleIdentifier == ourBundleID { return true }
        return url.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains("7-zip")
    }

    /// Cell text per state (SystemPage.cpp:41-53, 03 section 3.4): empty = no association,
    /// "7-Zip" = this install, "[7-Zip]" = another 7-Zip install, else the handler's name.
    private func stateText(_ row: Row) -> String {
        if row.wantsOurs { return "7-Zip" }
        guard let url = pendingOwner(row) else { return "" }
        if Self.isOurs(url, ourURL: Bundle.main.bundleURL) { return "7-Zip" }
        if Self.isOther7Zip(url) { return "[7-Zip]" }
        return Self.displayName(url)
    }

    /// Who would own the type after Apply.
    private func pendingOwner(_ row: Row) -> URL? {
        row.wantsOurs ? Bundle.main.bundleURL : (row.originalIsOurs ? nil : row.originalOwnerURL)
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row rowIndex: Int) -> NSView? {
        let row = rows[rowIndex]
        switch tableColumn?.identifier.rawValue ?? "" {
        case "type":
            // The format icon at the item's left, as Windows draws it from 7z.dll (SystemPage.cpp:95),
            // then the extension.
            let cell = NSTableCellView()
            let image = NSImageView(frame: NSRect(x: 4, y: 0, width: 16, height: 16))
            image.image = Self.formatIcon(for: row.type)
            image.imageScaling = .scaleProportionallyDown
            image.autoresizingMask = [.minYMargin, .maxYMargin]
            cell.addSubview(image)
            cell.imageView = image
            let text = NSTextField(labelWithString: row.type.ext)
            text.font = PanelMetrics.listFont
            text.lineBreakMode = .byTruncatingTail
            text.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 20),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        default:
            let cell = OptionsUI.cellText(stateText(row), alignment: .center)
            if row.utType == nil { cell.textField?.stringValue = "" }
            return cell
        }
    }

    private var targetRowIndices: [Int] {
        let selected = table.selectedRowIndexes
        return selected.isEmpty ? Array(rows.indices) : Array(selected)
    }

    /// NM_CLICK (SystemPage.cpp:375-396): with no modifier key (`uKeyFlags == 0`), a click on a
    /// state column (`iSubItem` 1-2; here the one "user" column) toggles that row alone.
    @objc private func rowClicked(_ sender: Any?) {
        let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.shift, .command, .option, .control]) ?? []
        guard modifiers.isEmpty else { return }
        toggleRow(table.clickedRow, column: table.clickedColumn)
    }

    /// The body of NM_CLICK, separated from the event so a test can drive it.
    func toggleRow(_ rowIndex: Int, column: Int) {
        guard rows.indices.contains(rowIndex), table.tableColumns.indices.contains(column),
              table.tableColumns[column] === userColumn else { return }
        setRows([rowIndex], ours: !rows[rowIndex].wantsOurs)
    }

    /// ChangeState: kExtState_Clear <-> kExtState_7Zip (SystemPage.cpp:100-153).
    @objc private func toggleSelectedRows(_ sender: Any?) {
        let indices = targetRowIndices
        setRows(indices, ours: indices.contains { !rows[$0].wantsOurs })
    }

    @objc private func setSelected(_ sender: Any?) { setRows(targetRowIndices, ours: true) }

    @objc private func clearSelected(_ sender: Any?) { setRows(targetRowIndices, ours: false) }

    @objc private func selectAllRows(_ sender: Any?) { table.selectAll(nil) }

    private func setRows(_ indices: [Int], ours: Bool) {
        var touched = false
        for i in indices where rows[i].wantsOurs != ours {
            // A type macOS cannot name is not associable.
            guard rows[i].utType != nil else { continue }
            // Releasing needs a previous owner: macOS has no "remove default handler" API.
            if !ours && rows[i].originalIsOurs && rows[i].originalOwnerURL == nil { continue }
            rows[i].wantsOurs = ours
            touched = true
        }
        guard touched else { return }
        table.reloadData(forRowIndexes: IndexSet(indices),
                         columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns))
        changed()
    }

    // MARK: OnApply (SystemPage.cpp:278-337)

    /// How many times `associationsDidChange` ran (for tests).
    private(set) static var launchServicesRefreshCount = 0

    /// SHChangeNotify(SHCNE_ASSOCCHANGED) (SystemPage.cpp:325): tell the system that file
    /// associations changed so Finder redraws the documents with their new icons. On macOS that is
    /// re-registering the bundle with Launch Services (`lsregister -f`, which also refreshes the
    /// document-type icons) plus `NSUpdateDynamicServices()`. A test instance only refreshes the
    /// Services list: `lsregister` on a throwaway build is a per-user mutation
    /// (`LaunchServicesRegistration.registerIfNeeded`).
    static func associationsDidChange() {
        launchServicesRefreshCount += 1
        if TestSupport.isEnabled {
            NSUpdateDynamicServices()
        } else {
            LaunchServicesRegistration.register()
        }
    }

    override func applyPage() -> Bool {
        let changedRows = rows.filter { $0.wantsOurs != $0.originalIsOurs }
        guard !changedRows.isEmpty else { return true }
        let workspace = NSWorkspace.shared
        let group = DispatchGroup()
        var firstError: Error?
        let lock = NSLock()

        for row in changedRows {
            guard let ut = row.utType,
                  let target = row.wantsOurs ? Bundle.main.bundleURL : row.originalOwnerURL else { continue }
            group.enter()
            workspace.setDefaultApplication(at: target, toOpen: ut) { error in
                if let error {
                    lock.lock()
                    if firstError == nil { firstError = error }
                    lock.unlock()
                }
                group.leave()
            }
        }

        // The system confirmation is asynchronous: refresh the rows when every request answered
        // and report only the first error, as SystemPage::OnApply reports only the first HRESULT.
        group.notify(queue: .main) { [weak self] in
            Self.associationsDidChange()
            guard let self else { return }
            self.withoutChangeTracking { self.pageDidLoad() }
            guard let error = firstError else { return }
            // The requests are asynchronous, so the Options window may have been closed while they
            // were in flight: present on the app's main window then, never app-modal with no owner
            // (`ErrorAlert`, `Mac/docs/reports/fastui.md` section 6.10).
            // SystemPage.cpp:333: "7-Zip", MB_ICONERROR.
            ErrorAlert.present(error.localizedDescription, on: self.view.window ?? NSApp.mainWindow)
        }
        return true
    }
}
