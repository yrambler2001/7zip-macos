// OptionsWindow.swift -- the Options window (Tools > Options, IDM_OPTIONS 900): the macOS
// equivalent of 7zFM's property sheet, OptionsDialog.cpp:13-50 / 01b-fm-dialogs-settings.md
// section 4.22. One NSTabView with the Windows page order and the Windows page titles
// (LangString_OnlyFromLangFile(IDD_*) with the .rc caption as fallback), OK / Cancel / Apply /
// Help, and per-page change tracking so a page writes only what the user touched.
//
// Windows property sheets apply per page: Apply and OK run every changed page's OnApply, a page
// that returns "invalid" keeps the sheet open on that page, and a page that has already been
// applied is not rolled back by Cancel. This window behaves the same way.

import Cocoa
import SevenZipKit

// MARK: - Page protocol

/// One property-sheet page.
protocol OptionsPage: AnyObject {
    /// `IDD_*` resource id -- also the lang id of the tab title.
    var pageID: UInt32 { get }
    /// The `.rc` caption, used when the lang file has no string for `pageID`.
    var fallbackTitle: String { get }
    /// `7-zip.chm` topic of the page's Help button (OnNotifyHelp).
    var helpTopic: String { get }
    /// OnInit: (re)load the stored values into the controls.
    func pageDidLoad()
    /// OnApply: write the changed values. false = PSNRET_INVALID (stay on this page).
    func applyPage() -> Bool
    /// Whether anything on the page changed since the last apply (Changed()).
    var pageIsChanged: Bool { get }
    /// Undo anything the page applied live (only the Language page does that).
    func cancelPage()
    /// Re-read every Lang string (the Language page switched language).
    func relabelPage()
}

/// Base class for the pages: an NSViewController that reports changes to the window.
class OptionsPageBase: NSViewController, OptionsPage {

    weak var owner: OptionsWindowController?

    var pageID: UInt32 { 0 }
    var fallbackTitle: String { "" }
    var helpTopic: String { "fm/options.htm" }

    private(set) var wasChanged = false
    var pageIsChanged: Bool { wasChanged }

    /// Set while pageDidLoad() fills the controls, so the control callbacks do not mark the page
    /// changed (CPropertyPage::_initMode).
    var initMode = false

    /// The page's client area: the .rc template IDD_* (316 x 296 DLU = 474 x 481 px), flipped so
    /// every control goes on its template rect (RcLayout, dlgfeel).
    var form: RcFormView { view as! RcFormView }

    /// The page's template.
    var rc: RcDialog { RcDialog(Int(pageID)) }

    override func loadView() {
        view = RcFormView(frame: NSRect(origin: .zero, size: OptionsWindowController.pageSize))
    }

    /// Changed(): enables the Apply button.
    func changed() {
        guard !initMode else { return }
        wasChanged = true
        owner?.pageDidChange()
    }

    func clearChanged() { wasChanged = false }

    func pageDidLoad() {}
    func applyPage() -> Bool { true }
    func cancelPage() {}
    func relabelPage() {}

    /// Runs `body` with change tracking suppressed.
    func withoutChangeTracking(_ body: () -> Void) {
        let old = initMode
        initMode = true
        body()
        initMode = old
    }
}

// MARK: - Small control factory (dialog controls keep their Windows resource id in a comment)

enum OptionsUI {

    static func label(_ langID: UInt32, _ fallback: String) -> NSTextField {
        RcPlace.makeLabel(Lang.text(langID, fallback))
    }

    static func checkbox(_ langID: UInt32, _ fallback: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(checkboxWithTitle: Lang.text(langID, fallback), target: target, action: action)
        b.tag = Int(langID)
        return b
    }

    static func radio(_ langID: UInt32, _ fallback: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(radioButtonWithTitle: Lang.text(langID, fallback), target: target, action: action)
        b.tag = Int(langID)
        return b
    }

    /// The `"..."` browse button next to a path field.
    static func browseButton(_ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: "...", target: target, action: action)
        b.bezelStyle = .rounded
        return b
    }

    static func textField(_ target: AnyObject, _ action: Selector) -> NSTextField {
        let f = NSTextField(string: "")
        f.target = target
        f.action = action
        f.isEditable = true
        f.isSelectable = true
        f.usesSingleLineMode = true
        f.cell?.lineBreakMode = .byTruncatingHead
        return f
    }

    /// A report-style list view (SysListView32 with WS_BORDER): the list font, 17 px rows, a
    /// 24 px header (or none), full-row selection, no alternating rows -- as the Windows control
    /// draws in the Options pages.
    static func listTable(_ table: NSTableView, header: Bool) -> NSScrollView {
        table.style = .plain
        table.rowHeight = 17
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = []
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsColumnReordering = false
        if header {
            let headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
            table.headerView = headerView
        } else {
            table.headerView = nil
        }
        let scroll = WinScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .lineBorder
        return scroll
    }

    static func column(_ id: String, _ title: String, width: CGFloat, alignment: NSTextAlignment = .left) -> NSTableColumn {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        c.title = title
        c.width = width
        c.minWidth = 10
        c.resizingMask = .userResizingMask
        c.headerCell.alignment = alignment
        WinHeaderCell.install(on: c, font: PanelMetrics.listFont)   // datecols: drawn in the font
        return c
    }

    /// A list cell: the list font, `inset` px from the column's aligned edge (LVCFMT_LEFT text is
    /// 6 px in, as in the main list, PanelMetrics).
    static func cellText(_ text: String, alignment: NSTextAlignment = .left) -> NSTableCellView {
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.font = PanelMetrics.listFont
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingTail
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(field)
        cell.textField = field
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - The window

final class OptionsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {

    static let shared = OptionsWindowController()

    // The property sheet as 7zFM 26.03 shows it (dlgfeel-data/win/dlg-options-*.txt): a fixed
    // 494 x 550 client area (no WS_THICKFRAME), the tab control at 6,7 482x507, the page at
    // 10,29 474x481 (the IDD_* templates' 316 x 296 DLU), and the four 75 x 23 buttons at y 520.
    // sffont: the horizontal metrics are stretched by DLU.scaleX with the pages (316 DLU wide), so
    // a wider dialog font keeps Windows' proportions; at scale 1 they are the pixels above.
    static var pageWidth: CGFloat { DLU.x(316) }
    static var clientSize: NSSize { NSSize(width: pageWidth + 20, height: 550) }
    static var tabControlRect: NSRect { NSRect(x: 6, y: 7, width: pageWidth + 8, height: 507) }
    static var pageRect: NSRect { NSRect(x: 10, y: 29, width: pageWidth, height: 481) }
    static var pageSize: NSSize { pageRect.size }
    /// The four 50 x 14 DLU buttons, 4 DLU apart, the last 4 DLU from the right edge.
    private static func buttonRect(_ fromRight: Int) -> NSRect {
        let w = DLU.x(50), gap = DLU.x(4)
        return NSRect(x: clientSize.width - gap - w - CGFloat(fromRight) * (w + gap), y: 520, width: w, height: 23)
    }
    static var okRect: NSRect { buttonRect(3) }          // IDOK
    static var cancelRect: NSRect { buttonRect(2) }      // IDCANCEL
    static var applyRect: NSRect { buttonRect(1) }       // ID_APPLY_NOW 12321
    static var helpRect: NSRect { buttonRect(0) }        // IDHELP

    private let tabView = NSTabView()
    private let tabControl = OptionsTabControl(frame: OptionsWindowController.tabControlRect)
    private var pages: [OptionsPageBase] = []
    private let okButton = NSButton()
    private let cancelButton = NSButton()
    private let applyButton = NSButton()
    private let helpButton = NSButton()
    private var languageWasChanged = false      // CLangPage::LangWasChanged

    init() {
        // Not resizable: a property sheet has a fixed frame (user finding 14).
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.clientSize),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = Lang.text(2100, "Options")     // IDS_OPTIONS 2100
        window.backgroundColor = WinChrome.face          // COLOR_BTNFACE (recheck §2)
        window.tabbingMode = .disallowed
        TestAnimations.apply(to: window)
        window.isReleasedWhenClosed = false          // the controller reuses it on every open
        super.init(window: window)
        window.delegate = self
        buildContent()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Tools > Options (IDM_OPTIONS 900).
    static func showOptions() {
        let controller = shared
        let wasVisible = controller.window?.isVisible ?? false
        controller.reloadPages()
        controller.showWindow(nil)
        // The property sheet is centred on the main window (PropertySheet with the main window as
        // its parent), not on the screen.
        if !wasVisible, let window = controller.window { DialogKit.center(window, over: nil) }
        controller.window?.makeKeyAndOrderFront(nil)
    }

    // MARK: Layout

    private func buildContent() {
        guard let window else { return }
        let content = OptionsSheetView(frame: NSRect(origin: .zero, size: Self.clientSize))
        content.owner = self

        // The small-screen templates IDD_SYSTEM_2, IDD_MENU_2, IDD_FOLDERS_2, IDD_EDIT_2,
        // IDD_SETTINGS_2, IDD_LANG_2 -- and likewise IDD_BENCH_2, IDD_COMPRESS_2, IDD_EXTRACT_2,
        // IDD_OVERWRITE_2, IDD_PROGRESS_2 of the other dialogs -- are not ported: macOS always gets
        // the full-size dialog (01 §9 #14, PROGRESS "Not applicable on macOS").
        // Page order = OptionsDialog.cpp:13-20. 26.03 has no Plugins page (user finding 22).
        pages = [
            OptionsSystemPage(),      // IDD_SYSTEM 2200
            OptionsMenuPage(),        // IDD_MENU 2300  ("7-Zip")
            OptionsFoldersPage(),     // IDD_FOLDERS 2400
            OptionsEditorPage(),      // IDD_EDIT 2103
            OptionsSettingsPage(),    // IDD_SETTINGS 2500
            OptionsLanguagePage(),    // IDD_LANG 2101
            OptionsMacPage(),         // macOS addition (theme): Theme, Show grid lines
        ]
        tabView.tabViewType = .noTabsNoBorder
        tabView.drawsBackground = false
        tabView.frame = Self.pageRect
        for page in pages {
            page.owner = self
            let item = NSTabViewItem(viewController: page)
            item.label = pageTitle(page)
            tabView.addTabViewItem(item)
        }
        // Only now: adding the first item selects it, and that must not overwrite the stored
        // "last page" before reloadPages() has read it.
        tabView.delegate = self
        tabControl.setTitles(pages.map(pageTitle))
        tabControl.onSelect = { [weak self] index in self?.tabView.selectTabViewItem(at: index) }

        configure(okButton, Lang.text(401, "OK"), #selector(okPressed(_:)))            // IDOK -> lang 401
        configure(cancelButton, Lang.text(402, "Cancel"), #selector(cancelPressed(_:)))  // IDCANCEL -> 402
        // "&Apply" comes from comctl32 on Windows (PSBTN_APPLYNOW), so no lang id exists for it
        configure(applyButton, "Apply", #selector(applyPressed(_:)))
        configure(helpButton, Lang.text(409, "Help"), #selector(helpPressed(_:)))        // IDHELP -> 409
        okButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        applyButton.isEnabled = false

        content.addSubview(tabControl)
        content.addSubview(tabView)
        for (button, rect) in [(okButton, Self.okRect), (cancelButton, Self.cancelRect),
                               (applyButton, Self.applyRect), (helpButton, Self.helpRect)] {
            content.addSubview(button)
            RcPlace.button(button, rect)
        }
        window.contentView = content
        window.setContentSize(Self.clientSize)
        window.contentMinSize = Self.clientSize
        window.contentMaxSize = Self.clientSize
    }

    private func configure(_ button: NSButton, _ title: String, _ action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
    }

    /// The number of pages (PSM_GETTABCONTROL item count).
    var pageCount: Int { pages.count }

    /// PSM_SETCURSEL: show page `index`.
    func selectPage(_ index: Int) {
        tabView.selectTabViewItem(at: index)
    }

    /// Ctrl+Tab / Ctrl+Shift+Tab / Ctrl+PgDn / Ctrl+PgUp move between the pages, as in every
    /// property sheet.
    fileprivate func cyclePage(by delta: Int) {
        guard !pages.isEmpty else { return }
        let current = tabView.selectedTabViewItem.map { tabView.indexOfTabViewItem($0) } ?? 0
        tabView.selectTabViewItem(at: (current + delta + pages.count) % pages.count)
    }

    /// Page titles come only from the lang file, with the .rc caption as fallback
    /// (LangString_OnlyFromLangFile(page.ID), OptionsDialog.cpp).
    private func pageTitle(_ page: OptionsPageBase) -> String {
        // pageID 0 means "no IDD_* resource" (the macOS-only Plugins page); lang id 0 is the
        // product name, so it must not be used as a title.
        if page.pageID != 0, let translated = Lang.translated(page.pageID), !translated.isEmpty {
            return Lang.stripMnemonic(Lang.dropAccelerator(translated))
        }
        return page.fallbackTitle
    }

    // MARK: Open / close

    private func reloadPages() {
        for page in pages {
            // NSTabView loads a page's view lazily, but OnInit touches its controls.
            page.loadViewIfNeeded()
            page.clearChanged()
            page.withoutChangeTracking { page.pageDidLoad() }
        }
        applyButton.isEnabled = false
        languageWasChanged = false
        let index = min(max(Settings.optionsLastPage, 0), pages.count - 1)
        tabView.selectTabViewItem(at: index)
        tabControl.select(index)
        window?.title = Lang.text(2100, "Options")
    }

    func pageDidChange() {
        applyButton.isEnabled = pages.contains { $0.pageIsChanged }
    }

    /// The Language page switched language: re-label this window, the menu bar and the toolbars
    /// (OptionsDialog.cpp:31-50 -> MyLoadMenu(true), ReloadToolbars, ReloadLangItems).
    func languageDidChange() {
        languageWasChanged = true
        window?.title = Lang.text(2100, "Options")
        okButton.title = Lang.text(401, "OK")
        cancelButton.title = Lang.text(402, "Cancel")
        applyButton.title = "Apply"   // not in the lang files (comctl32 string)
        helpButton.title = Lang.text(409, "Help")
        tabControl.setTitles(pages.map(pageTitle))
        for (i, page) in pages.enumerated() {
            tabView.tabViewItem(at: i).label = pageTitle(page)
            page.loadViewIfNeeded()
            page.withoutChangeTracking { page.relabelPage() }
        }
        OptionsPostApply.reloadLangItems()
    }

    /// PSN_APPLY on every changed page, in page order.
    @discardableResult
    private func applyChangedPages() -> Bool {
        for (i, page) in pages.enumerated() where page.pageIsChanged {
            if page.applyPage() {
                page.clearChanged()
            } else {
                tabView.selectTabViewItem(at: i)
                pageDidChange()
                return false
            }
        }
        pageDidChange()
        Settings.synchronize()
        OptionsPostApply.settingsApplied(languageChanged: languageWasChanged)
        return true
    }

    @objc private func applyPressed(_ sender: Any?) {
        applyChangedPages()
    }

    @objc private func okPressed(_ sender: Any?) {
        guard applyChangedPages() else { return }
        close()
    }

    @objc private func cancelPressed(_ sender: Any?) {
        for page in pages {
            page.cancelPage()
            page.clearChanged()
        }
        if languageWasChanged { OptionsPostApply.reloadLangItems() }
        pageDidChange()
        close()
    }

    /// OnNotifyHelp (PSN_HELP -> each page's OnNotifyHelp -> ShowHelpWindow(k*Topic)): the
    /// active page's topic in the bundled help (01 section 9 #17, opsgaps).
    @objc func helpPressed(_ sender: Any?) {
        Help.show(topic: currentHelpTopic)
    }

    /// The kHelpTopic of the page on screen.
    var currentHelpTopic: String {
        (tabView.selectedTabViewItem?.viewController as? OptionsPageBase)?.helpTopic ?? Help.options
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        guard let item = tabViewItem, let index = tabView.tabViewItems.firstIndex(of: item) else { return }
        tabControl.select(index)
        Settings.optionsLastPage = index
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        for page in pages where page.pageIsChanged { page.clearChanged() }
        pageDidChange()
        return true
    }
}

/// The sheet's client area: flipped like the .rc, and the property sheet's page keys.
final class OptionsSheetView: RcFormView {
    weak var owner: OptionsWindowController?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if mods.contains(.control), !mods.contains(.command), !mods.contains(.option),
           let key = event.charactersIgnoringModifiers?.unicodeScalars.first.map({ Int($0.value) }) {
            switch key {
            case 0x09, 0x19:                    // Tab, Shift+Tab (backtab)
                owner?.cyclePage(by: mods.contains(.shift) || key == 0x19 ? -1 : 1)
                return true
            case NSPageDownFunctionKey:
                owner?.cyclePage(by: 1)
                return true
            case NSPageUpFunctionKey:
                owner?.cyclePage(by: -1)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
