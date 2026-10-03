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

    override func loadView() {
        // Frame-driven on purpose: NSTabView sets the page frame, the content inside is
        // laid out with constraints.
        view = NSView()
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

    /// The page content, inset like a dialog's client area.
    func install(_ content: NSView) {
        content.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
        ])
        OptionsUI.capWrappingLabels(in: content)
    }

    /// A wrapping label's intrinsic width is its text on **one** line until it has been told how
    /// wide it may be, so every note on a page used to ask for 700-1000 pt and the Options window's
    /// fitting size came out at up to 1018 pt in a 660 pt window (requests.md, `fastui` ->
    /// `options`). `capWrappingLabels` gives each one a page-sized cap when the page is built; here,
    /// after every layout pass, a label narrower than that is told its real width so its height is
    /// measured for the lines it actually wraps into (the Windows pages are fixed-size dialogs whose statics wrap at
    /// their template width, 01b section 4.22).
    override func viewDidLayout() {
        super.viewDidLayout()
        var changed = false
        OptionsUI.forEachWrappingLabel(in: view) { field in
            // Never more than the cap: a label told its own full width feeds that width back into
            // the page's fitting size, which then only ever grows with the window.
            let width = min(field.frame.width, OptionsUI.wrappingLabelWidth)
            if width > 1, abs(field.preferredMaxLayoutWidth - width) > 0.5 {
                field.preferredMaxLayoutWidth = width
                changed = true
            }
        }
        if changed { view.needsLayout = true }
    }
}

// MARK: - Small control factory (dialog controls keep their Windows resource id in a comment)

enum OptionsUI {

    /// The widest a wrapping label may ask to be: the content width of a page in the 660 pt
    /// Options window, less some room for a label that shares a row.
    static let wrappingLabelWidth: CGFloat = 520

    /// Every text field in `view` that wraps onto more than one line.
    static func forEachWrappingLabel(in view: NSView, _ body: (NSTextField) -> Void) {
        for child in view.subviews {
            if let field = child as? NSTextField, !field.isEditable, field.maximumNumberOfLines != 1,
               field.cell?.wraps == true || field.lineBreakMode == .byWordWrapping
                || field.lineBreakMode == .byCharWrapping {
                body(field)
            }
            // A table's cells are laid out by the table, not by the page.
            if child is NSScrollView || child is NSTableView { continue }
            forEachWrappingLabel(in: child, body)
        }
    }

    /// Caps the one-line intrinsic width of every wrapping label (see `viewDidLayout`).
    static func capWrappingLabels(in view: NSView) {
        forEachWrappingLabel(in: view) { field in
            if field.preferredMaxLayoutWidth == 0 || field.preferredMaxLayoutWidth > wrappingLabelWidth {
                field.preferredMaxLayoutWidth = wrappingLabelWidth
            }
        }
    }

    static func label(_ langID: UInt32, _ fallback: String) -> NSTextField {
        let f = NSTextField(labelWithString: Lang.text(langID, fallback))
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 3
        return f
    }

    /// LangSetDlgItems_Colon: the lang text with a trailing ":".
    static func colonLabel(_ langID: UInt32, _ fallback: String) -> NSTextField {
        let base = Lang.text(langID, fallback)
        let text = base.hasSuffix(":") ? base : base + ":"
        let f = NSTextField(labelWithString: text)
        f.lineBreakMode = .byWordWrapping
        f.maximumNumberOfLines = 2
        return f
    }

    static func note(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        f.isSelectable = true
        return f
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

    static func button(_ title: String, _ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: target, action: action)
        b.bezelStyle = .rounded
        return b
    }

    /// The `"..."` browse button next to a path field.
    static func browseButton(_ target: AnyObject, _ action: Selector) -> NSButton {
        let b = NSButton(title: "...", target: target, action: action)
        b.bezelStyle = .rounded
        b.setContentHuggingPriority(.defaultHigh, for: .horizontal)
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

    static func vstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = .leading
        s.spacing = spacing
        return s
    }

    static func hstack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = .firstBaseline
        s.spacing = spacing
        return s
    }

    static func scrollTable(_ table: NSTableView, minHeight: CGFloat = 200) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        return scroll
    }

    /// Sizes every column of `table` to its header and to the widest of `texts[id]` (the strings
    /// its cells will show), plus `extra[id]` for an icon, and lets the last column take what is
    /// left. A list view column on Windows is sized by the page code the same way
    /// (`ListView_SetColumnWidth(LVSCW_AUTOSIZE_USEHEADER)`); without it the fixed widths of the
    /// System and Language pages added up to more than the page and the table squeezed them all,
    /// cutting "Default application" and "444 / 444 = 100%" (requests.md, `packaging` -> `options`).
    static func sizeColumnsToContent(_ table: NSTableView, texts: [String: [String]],
                                     extra: [String: CGFloat] = [:]) {
        let cellFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let padding: CGFloat = 14
        for column in table.tableColumns {
            let id = column.identifier.rawValue
            var width = column.headerCell.cellSize.width + padding
            for text in texts[id] ?? [] {
                let size = (text as NSString).size(withAttributes: [.font: cellFont])
                width = max(width, ceil(size.width) + padding + (extra[id] ?? 0))
            }
            column.minWidth = min(width, 60)
            column.width = width
        }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.enclosingScrollView?.hasHorizontalScroller = true
        table.enclosingScrollView?.autohidesScrollers = true
    }

    static func column(_ id: String, _ title: String, width: CGFloat) -> NSTableColumn {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        c.title = title
        c.width = width
        c.minWidth = 40
        return c
    }
}

// MARK: - The window

final class OptionsWindowController: NSWindowController, NSWindowDelegate, NSTabViewDelegate {

    static let shared = OptionsWindowController()

    private let tabView = NSTabView()
    private var pages: [OptionsPageBase] = []
    private let okButton = NSButton()
    private let cancelButton = NSButton()
    private let applyButton = NSButton()
    private let helpButton = NSButton()
    private var languageWasChanged = false      // CLangPage::LangWasChanged

    init() {
        // A property sheet is as large as its largest page (PropertySheet sizes to the biggest
        // template). 580 pt holds the tallest page -- the 7-Zip page in French, Russian, Hebrew or
        // Ukrainian once the Finder-extension status has wrapped to three lines, measured at
        // 566 pt (OptGapsTests.testOptionsPagesFitTheirWindow).
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 580),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = Lang.text(2100, "Options")     // IDS_OPTIONS 2100
        window.minSize = NSSize(width: 560, height: 420)
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
        let content = NSView()

        // Page order = OptionsDialog.cpp:13-20. The Plugins page is macOS-only (informational:
        // 26.03 has no plugin chooser, 03 section 3.4) and comes last so the Windows order holds.
        pages = [
            OptionsSystemPage(),      // IDD_SYSTEM 2200
            OptionsMenuPage(),        // IDD_MENU 2300  ("7-Zip")
            OptionsFoldersPage(),     // IDD_FOLDERS 2400
            OptionsEditorPage(),      // IDD_EDIT 2103
            OptionsSettingsPage(),    // IDD_SETTINGS 2500
            OptionsLanguagePage(),    // IDD_LANG 2101
            OptionsPluginsPage(),     // macOS only
        ]
        tabView.translatesAutoresizingMaskIntoConstraints = false
        for page in pages {
            page.owner = self
            let item = NSTabViewItem(viewController: page)
            item.label = pageTitle(page)
            tabView.addTabViewItem(item)
        }
        // Only now: adding the first item selects it, and that must not overwrite the stored
        // "last page" before reloadPages() has read it.
        tabView.delegate = self

        configure(okButton, Lang.text(401, "OK"), #selector(okPressed(_:)))            // IDOK -> lang 401
        configure(cancelButton, Lang.text(402, "Cancel"), #selector(cancelPressed(_:)))  // IDCANCEL -> 402
        // "Apply" comes from comctl32 on Windows (PSBTN_APPLYNOW), so no lang id exists for it
        configure(applyButton, "Apply", #selector(applyPressed(_:)))
        configure(helpButton, Lang.text(409, "Help"), #selector(helpPressed(_:)))        // IDHELP -> 409
        okButton.keyEquivalent = "\r"
        cancelButton.keyEquivalent = "\u{1b}"
        applyButton.isEnabled = false

        let buttons = NSStackView(views: [helpButton, NSView(), applyButton, cancelButton, okButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(tabView)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            buttons.topAnchor.constraint(equalTo: tabView.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.contentView = content
    }

    private func configure(_ button: NSButton, _ title: String, _ action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
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
        Settings.optionsLastPage = index
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        for page in pages where page.pageIsChanged { page.clearChanged() }
        pageDidChange()
        return true
    }
}
