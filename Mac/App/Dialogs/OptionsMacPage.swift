// OptionsMacPage.swift -- Options > macOS: a macOS addition, no Windows counterpart (7zFM's
// property sheet has six pages, OptionsDialog.cpp:13-20). The last tab, after Language, so the
// six Windows pages keep their order and their layout untouched (reports/theme.md).
//
// The page is laid out like the others: a template in dialog units on the 316 x 296 DLU page
// (IDD_* MY_PAGE size), placed with the same `RcPlace` rules, in the dialog font. Its controls:
//
//   Theme:  [Light v]           label + CBS_DROPDOWNLIST row, as "Archive format:" in IDD_COMPRESS
//                               (LTEXT 2 DLU under the combo's top). `AppTheme`, FM.Theme.
//   [ ] Show grid lines         the list's LVS_EX_GRIDLINES, the *same* setting as Windows' own
//                               IDX_SETTINGS_SHOW_GRID 2505 on the Settings page (FM.ShowGrid,
//                               off by default as on a fresh Windows install). Both checkboxes
//                               mirror each other while the sheet is open
//                               (`OptionsGridLines.toggled`), and either page's Apply writes it.
//   [x] Check for updates at startup  pub3: FM.CheckUpdates (default on), UpdateCheck.swift; lang
//                               9950. Help > Check for Updates... checks whatever it says.
//   [Reset All Settings...]     fix112: PUSHBUTTON, lang 9960. Asks (WinMessageBox, Yes / No, lang
//                               9961), then empties the settings domain and restarts the app
//                               (`SettingsReset`). Acts at once, not on Apply: the sheet's pending
//                               changes are dropped with everything else.
//
// Apply / OK write what changed; the theme takes effect at once (`AppTheme` follows FM.Theme), the
// grid through OptionsPostApply's panel refresh, as the Settings page's checkbox does.

import Cocoa

/// The two "Show grid lines" checkboxes (Settings page, macOS page) agree while the sheet is open.
enum OptionsGridLines {
    /// Posted by the page whose checkbox the user clicked; `object` is that page, the value is in
    /// `userInfo["on"]`.
    static let toggled = Notification.Name("SZOptionsGridLinesToggled")

    static func post(_ on: Bool, from page: AnyObject) {
        NotificationCenter.default.post(name: toggled, object: page, userInfo: ["on": on])
    }
}

extension RcDialog {
    /// A template that is not in the generated `RcTemplates` (a macOS-only page).
    init(template: RcTemplate) { self.template = template }
}

final class OptionsMacPage: OptionsPageBase {

    // No IDD_* resource: pageID 0 makes the tab title the fallback (OptionsWindowController.pageTitle).
    override var pageID: UInt32 { 0 }
    override var fallbackTitle: String { "macOS" }
    override var helpTopic: String { "fm/options.htm" }

    /// Control IDs of this page's own template (macOS only; the grid box reuses 2505's lang text).
    enum ID {
        static let themeLabel = 9900        // LTEXT "Theme:"
        static let themeCombo = 9910        // COMBOBOX, CBS_DROPDOWNLIST
        static let showGrid = 9920          // checkbox, lang 2505 "Show &grid lines"
        static let checkUpdates = 9930      // checkbox, lang 9950 "Check for updates at startup" (pub3)
        static let resetAll = 9940          // PUSHBUTTON, lang 9960 "Reset All Settings..." (fix112)
    }

    /// The page template in DLUs, in the IDD_SETTINGS style (m = 8, rows from y 8).
    static let template = RcTemplate(id: -9900, caption: "macOS", width: 316, height: 296, resizable: false, controls: [
        RcControl(id: ID.themeLabel, kind: .ltext, x: 8, y: 10, width: 76, height: 8, text: "Theme:"),
        RcControl(id: ID.themeCombo, kind: .comboList, x: 88, y: 8, width: 120, height: 64, text: ""),
        RcControl(id: ID.showGrid, kind: .check, x: 8, y: 30, width: 300, height: 10, text: "Show &grid lines"),
        RcControl(id: ID.checkUpdates, kind: .check, x: 8, y: 46, width: 300, height: 10, text: "Check for updates at startup"),
        RcControl(id: ID.resetAll, kind: .push, x: 8, y: 66, width: 100, height: 14, text: "Reset All Settings..."),
    ])

    override var rc: RcDialog { RcDialog(template: Self.template) }

    let themeLabel = RcPlace.makeLabel(AppTheme.labelText)
    let themePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private(set) var gridBox: NSButton!
    private(set) var updatesBox: NSButton!
    private(set) var resetButton: NSButton!
    private var themeChanged = false
    private var gridChanged = false
    private var updatesChanged = false
    private var gridObserver: NSObjectProtocol?

    deinit {
        if let gridObserver { NotificationCenter.default.removeObserver(gridObserver) }
    }

    override func loadView() {
        super.loadView()
        let rc = self.rc
        themePopup.removeAllItems()
        for theme in AppTheme.allCases {
            themePopup.addItem(withTitle: theme.title)
            themePopup.lastItem?.representedObject = theme.rawValue
        }
        themePopup.target = self
        themePopup.action = #selector(themeChosen(_:))
        themePopup.setAccessibilityIdentifier("optionsTheme")
        themeLabel.setAccessibilityIdentifier("optionsThemeLabel")
        gridBox = OptionsUI.checkbox(2505, "Show grid lines", self, #selector(gridClicked(_:)))
        gridBox.setAccessibilityIdentifier("optionsMacShowGrid")
        form.add(themeLabel, rc, ID.themeLabel)
        form.add(themePopup, rc, ID.themeCombo)
        form.add(gridBox, rc, ID.showGrid)
        updatesBox = OptionsUI.checkbox(UpdateCheck.LangID.checkAtStartup, "Check for updates at startup",
                                        self, #selector(updatesClicked(_:)))
        updatesBox.setAccessibilityIdentifier("optionsMacCheckUpdates")
        form.add(updatesBox, rc, ID.checkUpdates)
        resetButton = NSButton(title: SettingsReset.buttonTitle, target: self, action: #selector(resetAllClicked(_:)))
        resetButton.bezelStyle = .rounded
        resetButton.setAccessibilityIdentifier("optionsMacResetAll")
        form.add(resetButton, rc, ID.resetAll)
        gridObserver = NotificationCenter.default.addObserver(
            forName: OptionsGridLines.toggled, object: nil, queue: nil) { [weak self] note in
            guard let self, note.object as AnyObject? !== self, let on = note.userInfo?["on"] as? Bool else { return }
            self.gridBox.state = on ? .on : .off
        }
    }

    // MARK: OnInit

    override func pageDidLoad() {
        selectTheme(Settings.theme)
        gridBox.state = Settings.showGrid ? .on : .off
        updatesBox.state = Settings.checkUpdates ? .on : .off
        themeChanged = false
        gridChanged = false
        updatesChanged = false
        relabelPage()
    }

    override func relabelPage() {
        themeLabel.stringValue = AppTheme.labelText
        for (i, theme) in AppTheme.allCases.enumerated() { themePopup.item(at: i)?.title = theme.title }
        themePopup.needsDisplay = true
        gridBox.title = Lang.text(2505, "Show grid lines")
        updatesBox.title = UpdateCheck.checkAtStartupText
        resetButton.title = SettingsReset.buttonTitle
    }

    var selectedTheme: AppTheme {
        (themePopup.selectedItem?.representedObject as? String).flatMap(AppTheme.init(rawValue:)) ?? Settings.defaultTheme
    }

    func selectTheme(_ theme: AppTheme) {
        themePopup.selectItem(at: AppTheme.allCases.firstIndex(of: theme) ?? 0)
    }

    @objc func themeChosen(_ sender: Any?) {
        themeChanged = true
        changed()
    }

    @objc func gridClicked(_ sender: Any?) {
        gridChanged = true
        OptionsGridLines.post(gridBox.state == .on, from: self)
        changed()
    }

    @objc func updatesClicked(_ sender: Any?) {
        updatesChanged = true
        changed()
    }

    /// Reset All Settings... (fix112): Yes empties the domain and restarts; No leaves everything,
    /// the sheet's unapplied changes included.
    @objc func resetAllClicked(_ sender: Any?) {
        SettingsReset.confirmAndRun(owner: view.window)
    }

    // MARK: OnApply

    override func applyPage() -> Bool {
        if themeChanged {
            Settings.theme = selectedTheme             // AppTheme applies it at once
            themeChanged = false
        }
        if gridChanged {
            Settings.showGrid = gridBox.state == .on
            gridChanged = false
        }
        if updatesChanged {
            Settings.checkUpdates = updatesBox.state == .on
            updatesChanged = false
        }
        return true
    }
}
