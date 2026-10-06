// ThemeTests.swift -- the theme scope (ai/reports/theme.md): Options > macOS (Theme, Show
// grid lines), the forced Light / Dark themes through the setting, the contrast of every text in
// the main window and the dialogs under each, the screenshots, and the first-launch Finder
// integration decision (pure logic, no PlugInKit call ever reaches the machine).

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class ThemeTests: AppHostTestCase {

    override var screenshotPrefix: String { "theme" }

    private var controllers: [MainWindowController] = []
    private var savedTheme: String?
    private var savedShowGrid: Bool?
    private var savedNumPanels = 1
    private var savedPanelPath: String?
    private var savedListMode = 3
    private var savedLastPage = 0
    private var savedAppearance: NSAppearance?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedTheme = Settings.string(Settings.Key.theme)
        savedShowGrid = Settings.hasKey(Settings.Key.showGrid) ? Settings.showGrid : nil
        savedNumPanels = Settings.numPanels
        savedPanelPath = Settings.panelPath(0)
        savedListMode = Settings.listMode(0)
        savedLastPage = Settings.optionsLastPage
        savedAppearance = NSApp.appearance
    }

    override func tearDown() {
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        if let window = OptionsWindowController.shared.window, window.isVisible { ModalProbe.close(window) }
        for controller in controllers { controller.window?.close() }
        controllers = []
        Settings.setString(savedTheme, Settings.Key.theme)
        if let savedShowGrid { Settings.showGrid = savedShowGrid } else { Settings.removeKey(Settings.Key.showGrid) }
        Settings.numPanels = savedNumPanels
        Settings.setPanelPath(savedPanelPath, 0)
        Settings.setListMode(savedListMode, 0)
        Settings.optionsLastPage = savedLastPage
        NSApp.appearance = savedAppearance
        super.tearDown()
    }

    // MARK: - helpers

    private func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    /// The part of `frame` the field's text covers, by its alignment.
    static func textRect(_ frame: NSRect, _ field: NSTextField) -> NSRect {
        var rect = frame
        let w = min(rect.width, field.intrinsicContentSize.width)
        switch field.alignment {
        case .right: rect.origin.x = rect.maxX - w
        case .center: rect.origin.x = rect.midX - w / 2
        default: break
        }
        rect.size.width = w
        return rect
    }

    private func force(_ theme: AppTheme) {
        Settings.theme = theme                      // AppTheme follows the key at once
        XCTAssertEqual(NSApp.appearance?.name, theme.appearance?.name, "\(theme) applied")
    }

    private func makeWindow() -> MainWindowController {
        Settings.numPanels = 1
        Settings.setListMode(3, 0)
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(NSSize(width: 900, height: 520))
        controller.showWindow(nil)
        let panel = controller.focusedPanel
        var done = false
        panel.navigate(to: TestPaths.fixtures) { _ in done = true }
        XCTAssertTrue(wait(for: "fixtures listed") { done && !panel.rows.isEmpty })
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return controller
    }

    private func openOptions() throws -> (OptionsWindowController, NSWindow, NSTabView) {
        let controller = OptionsWindowController.shared
        let window = try XCTUnwrap(controller.window)
        XCTAssertTrue(ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in })
        let tabs = try XCTUnwrap(views(NSTabView.self, in: window.contentView).first)
        return (controller, window, tabs)
    }

    private func page<T: OptionsPageBase>(_ type: T.Type, _ tabs: NSTabView) throws -> T {
        try XCTUnwrap(tabs.tabViewItems.compactMap { $0.viewController as? T }.first)
    }

    private func applyButton(_ window: NSWindow) throws -> NSButton {
        try XCTUnwrap(views(NSButton.self, in: window.contentView).first { $0.title == "Apply" })
    }

    private func shot(_ window: NSWindow, _ name: String) {
        guard let data = DlgSnap.png(window) else { return XCTFail("no image for \(name)") }
        try? FileManager.default.createDirectory(atPath: TestPaths.screenshots, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: TestPaths.screenshots).appendingPathComponent("theme-\(name).png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = "theme-\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Every enabled, visible text of `window` -- labels, check boxes, radio buttons, drop-down
    /// titles -- against what is drawn behind it: WCAG contrast >= 4.5.
    private func checkTexts(in window: NSWindow, _ what: String, minimum: Int = 3) {
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        var measured = 0
        for field in views(NSTextField.self, in: window.contentView) {
            guard !field.isHiddenOrHasHiddenAncestor, field.isEnabled, !field.stringValue.isEmpty,
                  field.frame.width > 4, field.alphaValue > 0.5,
                  field.textColor != .disabledControlTextColor, !(field is NSComboBox),
                  !(field.textColor?.isEqual(NSColor.secondaryLabelColor) ?? false) else { continue }
            // only a field shown whole (not a list row scrolled under its clip view)
            let rect = Self.textRect(field.bounds, field)
            guard field.visibleRect.insetBy(dx: -1, dy: -1).contains(rect.insetBy(dx: 0, dy: 2)) else { continue }
            guard let m = ContrastProbe.measure(field, rect) else { continue }
            if m.text == m.background { continue }                 // nothing drawn (clipped out)
            measured += 1
            XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "\(what): '\(field.stringValue)' \(m.text) on \(m.background)")
        }
        for button in views(NSButton.self, in: window.contentView) {
            guard !button.isHiddenOrHasHiddenAncestor, button.isEnabled, !button.title.isEmpty,
                  button.frame.width > 30 else { continue }
            let isPopup = button is NSPopUpButton
            let role = button.accessibilityRole()
            let isCheck = !isPopup && (role == .checkBox || role == .radioButton)
            if !isPopup, !isCheck { continue }                      // push buttons: AppKit's own bezel
            var rect = button.bounds
            if isCheck { rect.origin.x += 18; rect.size.width -= 18 }
            else { rect = rect.insetBy(dx: 4, dy: 4); rect.size.width -= 17 }
            guard rect.width > 4, let m = ContrastProbe.measure(button, rect) else { continue }
            measured += 1
            XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "\(what): '\(button.title)' \(m.text) on \(m.background)")
        }
        XCTAssertGreaterThanOrEqual(measured, minimum, "\(what): texts measured")
    }

    // MARK: - the setting

    func testThemeSettingDefaultsToSystemAndAppliesAtOnce() {
        Settings.removeKey(Settings.Key.theme)
        XCTAssertEqual(Settings.theme, .system, "absent = System")
        AppTheme.applyStored()
        XCTAssertNil(NSApp.appearance, "System leaves the appearance to macOS")
        force(.dark)
        XCTAssertEqual(Settings.string(Settings.Key.theme), "dark")
        force(.light)
        XCTAssertEqual(Settings.string(Settings.Key.theme), "light")
        force(.system)
        XCTAssertFalse(Settings.hasKey(Settings.Key.theme), "System is stored as no key")
        Settings.setString("bogus", Settings.Key.theme)
        XCTAssertEqual(Settings.theme, .system, "an unknown value reads as System")
        // A test reset replaces the domain and posts keyless notifications: the theme follows.
        Settings.setString("dark", Settings.Key.theme)
        NSApp.appearance = nil
        Settings.notifyAllGroups()
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua, "re-applied after a domain reset")
    }

    // MARK: - Options > macOS

    func testMacTabIsLastAndAppliesTheThemeOnApply() throws {
        Settings.removeKey(Settings.Key.theme)
        AppTheme.applyStored()
        let (controller, window, tabs) = try openOptions()
        XCTAssertEqual(tabs.tabViewItems.last?.label, "macOS")
        XCTAssertEqual(tabs.tabViewItems.map(\.label).prefix(6),
                       ["System", "7-Zip", "Folders", "Editor", "Settings", "Language"], "the Windows pages first, unchanged")
        let mac = try page(OptionsMacPage.self, tabs)
        controller.selectPage(controller.pageCount - 1)
        XCTAssertEqual(mac.themePopup.itemTitles, ["System", "Light", "Dark"])
        XCTAssertEqual(mac.themeLabel.stringValue, "Theme:")
        XCTAssertEqual(mac.selectedTheme, .system)
        mac.themePopup.selectItem(at: 2)
        mac.themeChosen(mac.themePopup)
        XCTAssertNil(NSApp.appearance, "nothing changes before Apply")
        let apply = try applyButton(window)
        XCTAssertTrue(apply.isEnabled)
        apply.performClick(nil)
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua, "Apply switches the whole app to Dark")
        XCTAssertEqual(window.effectiveAppearance.name, .darkAqua, "the Options window itself too")
        // persisted in the domain's file
        Settings.synchronize()
        if let path = Settings.domainPlistPath(), let dict = NSDictionary(contentsOfFile: path) {
            XCTAssertEqual(dict[Settings.Key.theme] as? String, "dark", "FM.Theme on disk")
        }
        // reopening shows the stored value
        ModalProbe.close(window)
        let (_, _, tabs2) = try openOptions()
        XCTAssertEqual(try page(OptionsMacPage.self, tabs2).selectedTheme, .dark)
    }

    // MARK: - Show grid lines

    func testGridLinesAreOffByDefaultAndBothCheckboxesAgree() throws {
        Settings.removeKey(Settings.Key.showGrid)
        force(.light)
        XCTAssertFalse(Settings.showGrid, "LVS_EX_GRIDLINES off on a fresh install")
        let main = makeWindow()
        let panel = main.focusedPanel
        panel.applyListSettings()
        XCTAssertEqual(panel.tableView.gridStyleMask, [], "the list draws no grid by default")
        XCTAssertEqual(gridInk(panel), 0, "no grid pixels by default")

        let (_, window, tabs) = try openOptions()
        let mac = try page(OptionsMacPage.self, tabs)
        let settings = try page(OptionsSettingsPage.self, tabs)
        let settingsBox = try XCTUnwrap(views(NSButton.self, in: settings.view).first { $0.tag == 2505 })
        XCTAssertEqual(mac.gridBox.state, .off)
        XCTAssertEqual(settingsBox.state, .off)
        XCTAssertEqual(mac.gridBox.title, settingsBox.title, "the same caption (lang 2505)")

        mac.gridBox.performClick(nil)                      // on, on the macOS tab
        XCTAssertEqual(settingsBox.state, .on, "the Settings tab follows")
        try applyButton(window).performClick(nil)
        XCTAssertTrue(Settings.showGrid)
        XCTAssertTrue(wait(for: "grid on in the panel") { panel.tableView.gridStyleMask != [] })
        XCTAssertGreaterThan(gridInk(panel), 0, "Apply redraws the list with grid lines")

        settingsBox.performClick(nil)                      // off, on the Settings tab
        XCTAssertEqual(mac.gridBox.state, .off, "the macOS tab follows")
        try applyButton(window).performClick(nil)
        XCTAssertFalse(Settings.showGrid)
        XCTAssertTrue(wait(for: "grid off in the panel") { panel.tableView.gridStyleMask == [] })
        XCTAssertEqual(gridInk(panel), 0, "Apply redraws the list without them: \(gridInkInfo)")

        // persisted, and a fresh open shows it on both tabs
        Settings.showGrid = true
        ModalProbe.close(window)
        let (_, _, tabs2) = try openOptions()
        XCTAssertEqual(try page(OptionsMacPage.self, tabs2).gridBox.state, .on)
        let box2 = try XCTUnwrap(views(NSButton.self, in: try page(OptionsSettingsPage.self, tabs2).view).first { $0.tag == 2505 })
        XCTAssertEqual(box2.state, .on)
    }

    /// Non-white pixels in a 3 px strip on the first column's right edge, over the listed rows.
    private var gridInkInfo = ""

    private func gridInk(_ panel: PanelViewController) -> Int {
        let table = panel.tableView
        panel.listFocusOverride = false
        table.deselectAll(nil)
        table.layoutSubtreeIfNeeded()
        table.display()
        let rows = table.rect(ofRow: max(0, table.numberOfRows - 1)).maxY
        let column = table.rect(ofColumn: 0)
        let strip = NSRect(x: column.maxX - 2, y: 0, width: 3, height: rows)
        let pixels = ContrastProbe.pixels(of: table, in: strip)
        panel.listFocusOverride = nil
        let ink = pixels.filter { !$0.isClose(to: .white, tolerance: 6) }
        gridInkInfo = "mask=\(table.gridStyleMask.rawValue) strip=\(strip) colours=\(Set(ink).prefix(6)) window=\(table.window?.title ?? "nil") rows=\(table.numberOfRows)"
        return ink.count
    }

    // MARK: - fits

    /// The macOS tab: every control inside the page, every text inside its frame, and the tab row
    /// (now seven tabs) inside the sheet, in the six test languages.
    func testMacTabFitsWithoutScrollingInSixLanguages() throws {
        continueAfterFailure = true
        for code in ["-", "de", "ru", "fr", "ja", "ar"] {
            useLanguage(code)
            let (controller, window, tabs) = try openOptions()
            controller.selectPage(controller.pageCount - 1)
            window.contentView?.layoutSubtreeIfNeeded()
            let mac = try page(OptionsMacPage.self, tabs)
            let pageView = mac.view
            for child in pageView.subviews where !child.isHidden {
                XCTAssertTrue(pageView.bounds.insetBy(dx: -1, dy: -1).contains(child.frame),
                              "\(code): \(type(of: child)) \(child.frame) leaves \(pageView.bounds)")
            }
            XCTAssertTrue(views(NSScrollView.self, in: pageView).isEmpty, "\(code): nothing scrolls")
            XCTAssertLessThanOrEqual(mac.themeLabel.intrinsicContentSize.width, mac.themeLabel.frame.width + 0.5,
                                     "\(code): '\(mac.themeLabel.stringValue)' fits")
            XCTAssertLessThan(mac.themeLabel.frame.maxX, mac.themePopup.frame.minX + 1, "\(code): label left of the combo")
            let checkText = (mac.gridBox.title as NSString).size(withAttributes: [.font: mac.gridBox.font ?? DialogMetrics.font]).width
            XCTAssertLessThanOrEqual(checkText + 20, mac.gridBox.frame.width, "\(code): '\(mac.gridBox.title)' fits")
            for title in mac.themePopup.itemTitles {
                let w = (title as NSString).size(withAttributes: [.font: DialogMetrics.font]).width
                XCTAssertLessThanOrEqual(w, mac.themePopup.frame.width - 24, "\(code): '\(title)' fits the combo")
            }
            let tabControl = try XCTUnwrap(views(OptionsTabControl.self, in: window.contentView).first)
            let tabEnd = tabControl.tabRects().last?.maxX ?? 0
            XCTAssertLessThanOrEqual(tabEnd + 2, tabControl.bounds.width, "\(code): the seven tabs fit in one row")
            ModalProbe.close(window)
        }
        useLanguage("-")
    }

    // MARK: - forced themes: contrast + screenshots

    func testMainWindowIsReadableInBothForcedThemes() throws {
        continueAfterFailure = true
        let main = makeWindow()
        let window = try XCTUnwrap(main.window)
        for theme in [AppTheme.light, .dark] {
            force(theme)
            XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]),
                           theme == .dark ? .darkAqua : .aqua)
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            checkTexts(in: window, "main \(theme)", minimum: 1)
            // the list's cells, the header titles, the toolbar labels
            let panel = main.focusedPanel
            panel.listFocusOverride = true
            panel.tableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            panel.refreshSelectionAppearance()
            let table = panel.tableView
            table.layoutSubtreeIfNeeded()
            var cells = 0
            for r in 0..<min(4, table.numberOfRows) {
                for c in 0..<table.numberOfColumns {
                    guard let field = (table.view(atColumn: c, row: r, makeIfNecessary: false) as? NSTableCellView)?.textField,
                          !field.stringValue.isEmpty else { continue }
                    let rect = Self.textRect(field.convert(field.bounds, to: table), field)
                    guard table.visibleRect.contains(rect), let m = ContrastProbe.measure(table, rect) else { continue }
                    cells += 1
                    XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "\(theme) row \(r) '\(field.stringValue)': \(m.text) on \(m.background)")
                }
            }
            XCTAssertGreaterThan(cells, 4)
            if let header = table.headerView {
                for c in 0..<min(3, table.numberOfColumns) {
                    let rect = header.headerRect(ofColumn: c).insetBy(dx: 4, dy: 3)
                    guard let m = ContrastProbe.measure(header, rect) else { continue }
                    XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "\(theme) header \(c): \(m.text) on \(m.background)")
                }
            }
            for button in main.toolbarView.buttons.prefix(4) {
                let r = button.bounds
                let label = NSRect(x: r.minX + 2, y: button.isFlipped ? r.maxY - 16 : r.minY, width: r.width - 4, height: 15)
                guard let m = ContrastProbe.measure(button, label) else { continue }
                XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "\(theme) toolbar '\(button.title)': \(m.text) on \(m.background)")
            }
            // the address field's text
            let combo = panel.pathCombo
            if let m = ContrastProbe.measure(combo, combo.bounds.insetBy(dx: 30, dy: 4)) {
                XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "\(theme) address: \(m.text) on \(m.background)")
            }
            // the Windows-grey face: light (240) in Light, dark in Dark
            let face = ContrastProbe.pixels(of: main.toolbarView, in: NSRect(x: main.toolbarView.bounds.maxX - 6, y: 2, width: 4, height: 4))
            if let p = face.first {
                if theme == .dark { XCTAssertLessThan(p.luminance, 0.1, "Dark face \(p)") }
                else { XCTAssertTrue(p.isClose(to: RGB(r: 240, g: 240, b: 240), tolerance: 4), "Light face \(p)") }
            }
            panel.listFocusOverride = nil
            shot(window, "main-\(theme.rawValue)")
        }
    }

    func testDialogsAreReadableInBothForcedThemes() throws {
        continueAfterFailure = true
        try SZCodecs.loadCodecs()
        let fixtures = TestPaths.fixtures, archive = TestPaths.fixture("test.7z")
        for theme in [AppTheme.light, .dark] {
            force(theme)
            // Options: every page, and the macOS tab's screenshots
            let (controller, window, _) = try openOptions()
            for index in 0..<controller.pageCount {
                controller.selectPage(index)
                window.contentView?.layoutSubtreeIfNeeded()
                checkTexts(in: window, "Options page \(index) \(theme)", minimum: 1)
            }
            controller.selectPage(controller.pageCount - 1)
            shot(window, "options-macos-tab-\(theme.rawValue)")
            if theme == .dark {
                controller.selectPage(4)                    // Settings, a Windows page
                shot(window, "options-dark")
            }
            ModalProbe.close(window)
            // Add to Archive
            var input = CompressDialogInput()
            input.directoryPrefix = fixtures + "/"
            input.archiveBaseName = "test"
            input.itemPaths = [archive]
            XCTAssertTrue(ModalProbe.present(timeout: 60, { _ = CompressDialogController.run(input) }) { w in
                self.checkTexts(in: w, "Compress \(theme)", minimum: 10)
                if theme == .dark { self.shot(w, "compress-dark") }
            })
            // a message box
            XCTAssertTrue(ModalProbe.present({
                _ = WinMessageBox.run("Theme test: " + archive, caption: "7-Zip", buttons: .yesNoCancel,
                                      icon: .question, owner: nil)
            }) { w in
                self.checkTexts(in: w, "message box \(theme)", minimum: 0)
                if let text = self.views(WinMessageBoxText.self, in: w.contentView).first,
                   let m = ContrastProbe.measure(text, text.bounds) {
                    XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "message box text \(theme): \(m.text) on \(m.background)")
                }
                if theme == .dark { self.shot(w, "msgbox-dark") }
            })
            // progress (the 7zG-mode window too)
            let progress = ProgressDialog(title: "Extracting", showCompressionInfo: true)
            progress.window.makeKeyAndOrderFront(nil)
            checkTexts(in: progress.window, "progress \(theme)", minimum: 3)
            progress.window.orderOut(nil)
        }
    }

    // MARK: - first launch Finder integration (pure decision; no pluginkit)

    private func env(_ change: (inout FirstLaunchIntegration.Environment) -> Void = { _ in }) -> FirstLaunchIntegration.Environment {
        var e = FirstLaunchIntegration.Environment(
            testSupport: false, xctestLoaded: false, bundleIdentifier: "com.yrambler2001.7zip",
            bundlePath: "/Applications/7-Zip.app", homeDirectory: "/Users/someone",
            hasEmbeddedAppex: true, markerSet: false, cascadedDefined: false)
        change(&e)
        return e
    }

    func testFirstLaunchDecision() {
        typealias F = FirstLaunchIntegration
        XCTAssertEqual(F.decide(env()), .enable, "fresh, installed in /Applications")
        XCTAssertEqual(F.decide(env { $0.bundlePath = "/Users/someone/Applications/7-Zip.app" }), .enable, "~/Applications")
        XCTAssertEqual(F.decide(env { $0.bundlePath = "/Applications/Utilities/7-Zip.app" }), .enable, "a subfolder")
        XCTAssertEqual(F.decide(env { $0.markerSet = true }), .alreadyDone, "only once")
        XCTAssertEqual(F.decide(env { $0.cascadedDefined = true }), .alreadyDone, "the user chose already")
        for path in ["/Volumes/7-Zip/7-Zip.app", "/Users/someone/Downloads/7-Zip.app",
                     "/Users/someone/src/7zip/Mac/build/Debug/7-Zip.app",
                     "/private/var/folders/xy/T/AppTranslocation/ABC/d/7-Zip.app",
                     "/ApplicationsX/7-Zip.app"] {
            guard case .deferred = F.decide(env { $0.bundlePath = path }) else { XCTFail("\(path) must defer"); continue }
        }
        for e in [env { $0.testSupport = true }, env { $0.xctestLoaded = true },
                  env { $0.bundleIdentifier = "com.yrambler2001.7zip-host" },
                  env { $0.bundleIdentifier = "com.yrambler2001.7zip-p1" },
                  env { $0.bundleIdentifier = nil }, env { $0.hasEmbeddedAppex = false },
                  env { $0.testSupport = true; $0.markerSet = false }] {
            guard case .skip = F.decide(e) else { XCTFail("\(e) must skip"); continue }
        }
        // This very process (the test host) never qualifies.
        guard case .skip = F.decide(F.currentEnvironment()) else { return XCTFail("the test host must skip") }
    }

    func testFirstLaunchRunWritesOnceAndNeverReenables() {
        let marker = FirstLaunchIntegration.markerKey
        let savedMarker = Settings.hasKey(marker)
        let savedCascaded = Settings.cascadedMenu
        defer {
            if savedMarker { Settings.setBool(true, marker) } else { Settings.removeKey(marker) }
            Settings.cascadedMenu = savedCascaded
        }
        Settings.removeKey(marker)
        Settings.cascadedMenu = nil
        var elections = 0
        // fresh: cascaded on, marker set, the PlugInKit half called once
        var e = env { $0.cascadedDefined = Settings.cascadedMenu != nil; $0.markerSet = Settings.hasKey(marker) }
        XCTAssertEqual(FirstLaunchIntegration.run(e) { elections += 1 }, .enable)
        XCTAssertEqual(elections, 1)
        XCTAssertEqual(Settings.cascadedMenu, true)
        XCTAssertTrue(Settings.hasKey(marker))
        // the user unticks Cascaded; the next launches leave it alone
        Settings.cascadedMenu = false
        e = env { $0.cascadedDefined = Settings.cascadedMenu != nil; $0.markerSet = Settings.hasKey(marker) }
        XCTAssertEqual(FirstLaunchIntegration.run(e) { elections += 1 }, .alreadyDone)
        XCTAssertEqual(elections, 1, "never re-enabled")
        XCTAssertEqual(Settings.cascadedMenu, false)
        // a deferred (DMG) launch writes nothing
        Settings.removeKey(marker)
        Settings.cascadedMenu = nil
        e = env { $0.bundlePath = "/Volumes/7-Zip/7-Zip.app" }
        guard case .deferred = FirstLaunchIntegration.run(e, elect: { elections += 1 }) else { return XCTFail("defer") }
        XCTAssertFalse(Settings.hasKey(marker))
        XCTAssertNil(Settings.cascadedMenu)
        XCTAssertEqual(elections, 1)
    }

    /// The PlugInKit half with the runner replaced: which commands it would send.
    func testFirstLaunchElectionCommands() throws {
        let saved = FinderExtensionControl.runner
        defer { FinderExtensionControl.runner = saved }
        let scratch = (TestPaths.artifacts as NSString).appendingPathComponent("theme-\(UUID().uuidString)/7-Zip.app/Contents/PlugIns")
        defer { try? FileManager.default.removeItem(atPath: ((scratch as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent) }
        for name in ["FinderSync", "QuickActionExtract", "QuickActionCompress"] {
            try FileManager.default.createDirectory(atPath: scratch + "/\(name).appex", withIntermediateDirectories: true)
        }
        let appex = FinderExtensionControl.canonical(scratch + "/FinderSync.appex")
        var calls: [[String]] = []
        FinderExtensionControl.runner = { args in
            calls.append(args)
            if args.first == "-m", args.contains("com.yrambler2001.7zip.QuickActionExtract") {
                return (0, "+    com.yrambler2001.7zip.QuickActionExtract(26.03)\tX\t2026\t/Volumes/Old/7-Zip.app/Contents/PlugIns/QuickActionExtract.appex\n")
            }
            if args.first == "-m", args.contains(FinderExtensionControl.identifier) {
                return (0, "+    \(FinderExtensionControl.identifier)(26.03)\tX\t2026\t\(appex)\n")
            }
            return (0, "")
        }
        FirstLaunchIntegration.electAll(embeddedPath: appex)
        XCTAssertTrue(calls.contains(["-e", "use", "-i", FinderExtensionControl.identifier]), "\(calls)")
        for id in FirstLaunchIntegration.quickActionIdentifiers {
            XCTAssertTrue(calls.contains(["-e", "use", "-i", id]), "\(id) elected")
        }
        XCTAssertTrue(calls.contains(["-r", "/Volumes/Old/7-Zip.app/Contents/PlugIns/QuickActionExtract.appex"]),
                      "another copy's Quick Action removed")
        XCTAssertTrue(calls.contains { $0.first == "-a" && $0.last?.hasSuffix("QuickActionCompress.appex") == true })
    }
}
