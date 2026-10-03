// SevenZipApp.swift -- the XCUITest driver for 7-Zip.app: launching with a known settings
// domain, addressing the window, the panels, the toolbar and the menu bar, waiting for dialogs
// and taking named screenshots. Later waves build their tests on this; see
// Mac/docs/api/harness.md for the documented API and examples.
//
// Everything is addressed through what the app already exposes to accessibility -- element type
// plus AX title/value -- so no test hook is needed inside the app:
//   * window            : the only Window of the app, title = focused panel path or "7-Zip"
//   * panel i           : direct children of the window's SplitGroup, left to right
//                         (Button "Up One Level", ComboBox = address bar, ScrollView > Table,
//                          StaticText = status bar)
//   * row               : TableRow > Cell > StaticText whose `value` is the cell text; the
//                         leftmost cell is the Name column
//   * column header     : Button with the column title, inside the Table
//   * toolbar button    : Button with title "Add" / "Extract" / "Test" / "Copy" / "Move" /
//                         "Delete" / "Info" inside the window's Toolbar
//   * menu item         : MenuBar > MenuBarItem > Menu > MenuItem (nested for submenus); the AX
//                         identifier of an item is its selector, e.g. "viewTwoPanels:"
//   * alert / dialog    : Sheet (or Window) whose first StaticText is the message text

import Foundation
import XCTest

public final class SevenZipApp {

    /// The app this shard drives. Every UI-test target is built against an app target with its own
    /// bundle identifier so the read-only shards can run at the same time (`TestShard`); the input
    /// shard drives the shipping identifier.
    public static var bundleIdentifier: String { TestShard.appBundleIdentifier }
    /// Title of the application menu and of its Quit item (from the bundle name).
    public static let appMenuTitle = "7-Zip"
    public static let quitItemTitle = "Quit 7-Zip"

    /// The underlying XCUIApplication; use it for anything this driver does not wrap.
    public let app: XCUIApplication
    /// The real preferences domain (`com.yrambler2001.7zip`). Only reachable from an unsandboxed
    /// process; a UI test seeds `seedFile` instead.
    public let settings: SettingsDomain
    /// The property-list file the last `launch(seed:)` gave the app as its whole settings domain.
    /// `relaunch()` / `launch(seed: .keep)` reuse it, so persistence is asserted against the file
    /// the app itself wrote, and nothing leaks into the next test.
    public private(set) var seedFile: SettingsSeedFile?
    /// Name the seed files carry, so a leftover file says which test wrote it.
    public var seedName = "uitest"
    /// The test class this instance belongs to. `SZ_STATE_DIR` is derived from it, so two classes --
    /// and two shards -- never share a work directory (contract, "Running several instances").
    public var owner = "ui"
    /// How the last `prepare(...)` brought the app to its state, for the report and for a test that
    /// wants to assert the fast path is really being taken.
    public private(set) var lastPreparation: ResetOutcome?

    public init(app: XCUIApplication = XCUIApplication(), settings: SettingsDomain = SettingsDomain()) {
        self.app = app
        self.settings = settings
    }

    // MARK: - Launching

    /// Launch the app with known settings and wait until the first panel is listed.
    ///
    /// - Parameters:
    ///   - seed: the settings the app starts with (`.clean` by default; see `SettingsSeed`). They
    ///     are written to a property-list file private to this test and handed over as
    ///     `SEVENZIP_DEFAULTS_SUITE`, so the real domain is never read or written and the app's
    ///     save-on-quit cannot reach the next test. `.keep` reuses the previous file.
    ///   - path: `7zFM.exe [path]` argv -- the folder or archive panel 0 opens in. It must be the
    ///     first argument, which is why it is passed here and not in `arguments`.
    ///   - formatHint: `-t<type>` argv for `path`.
    ///   - arguments: extra launch arguments (`["-FM.ShowDots", "1"]`); a launch argument still
    ///     wins over the seed file for keys the app reads as a string.
    ///   - environment: extra environment variables for the app process. Passing
    ///     `SEVENZIP_DEFAULTS_SUITE` here overrides the seed file.
    /// - Returns: the main window element.
    @discardableResult
    public func launch(seed: SettingsSeed = .clean,
                       path: String? = nil,
                       formatHint: String? = nil,
                       arguments: [String] = [],
                       environment: [String: String] = [:],
                       timeout: TimeInterval = 60) -> XCUIElement {
        var args: [String] = []
        if let path { args.append(path) }                 // AppDelegate reads argv[0] as the path
        if let formatHint { args.append("-t" + formatHint) }
        args += arguments
        app.launchArguments = args
        var env = environment
        env["SEVENZIP_UITEST"] = "1"
        // The test-support contract: the affordances on, animations at zero duration, and a state
        // directory of this class's own so parallel shards cannot collide.
        env.merge(TestShard.environment(for: owner)) { mine, _ in mine }
        if env[SettingsDomain.suiteEnvironmentVariable] == nil {
            if let values = seed.preferences {
                // A fresh domain per launch. A failure to write it would silently hand the app the
                // real domain, so it is a hard error rather than a fallback.
                seedFile = try? SettingsSeedFile.make(name: seedName, values: values)
                XCTAssertNotNil(seedFile, "could not write the settings seed file in \(TestPaths.artifacts)")
            }
            if let seedFile { env.merge(seedFile.launchEnvironment) { _, new in new } }
        }
        app.launchEnvironment = env
        // An instance from another worktree (or a previous test) is attached to instead of being
        // replaced, and its death then fails the test with "Lost connection to the application".
        if isRunning { app.terminate() }
        app.launch()
        if !window.waitForExistence(timeout: timeout) {
            // Rare flake: "Application has not loaded accessibility" / no window. One retry.
            app.terminate()
            app.launch()
            _ = window.waitForExistence(timeout: timeout)
        }
        _ = panel(0).table.waitForExistence(timeout: timeout)
        return window
    }

    /// Bring the app to `seed` for the next test: a `sevenzip://test/reset` of the running instance
    /// when the contract allows it, a launch when it does not.
    ///
    /// A reset is used only when **all** of this holds: the app is running, it implements the
    /// contract (`testSupportIsImplemented`), and the test asks for nothing a reset cannot express --
    /// no argv path, no extra launch arguments, no extra environment, and a seed that is a set of
    /// values rather than `.keep`. Anything else launches a process, which is what the whole suite
    /// did for every test before this. The decision is recorded in `lastPreparation`.
    @discardableResult
    public func prepare(seed: SettingsSeed = .clean,
                        path: String? = nil,
                        formatHint: String? = nil,
                        arguments: [String] = [],
                        environment: [String: String] = [:],
                        timeout: TimeInterval = 60) -> XCUIElement {
        func relaunch() -> XCUIElement {
            lastPreparation = .relaunched
            return launch(seed: seed, path: path, formatHint: formatHint,
                          arguments: arguments, environment: environment, timeout: timeout)
        }
        guard isRunning, window.exists,
              path == nil, formatHint == nil, arguments.isEmpty, environment.isEmpty,
              let values = seed.preferences, let domain = seedFile,
              testSupportIsImplemented else {
            return relaunch()
        }
        // The app's whole settings domain is this file, so the seed is applied by rewriting it and
        // telling the reset to reload from it.
        do {
            try domain.write(values)
        } catch {
            XCTFail("could not rewrite the settings domain at \(domain.url.path): \(error)")
            return relaunch()
        }
        var options = ResetOptions()
        options.defaults = domain.url.path
        options.language = values[SettingsDomain.Key.lang] as? String
        options.panels = values[SettingsDomain.Key.numPanels] as? Int
        options.path0 = values[SettingsDomain.Key.panelPath0] as? String
        options.path1 = values[SettingsDomain.Key.panelPath1] as? String
        options.view = values[SettingsDomain.Key.listMode0] as? Int
        let outcome = reset(options, seed: seed, timeout: min(timeout, 30))
        lastPreparation = outcome
        switch outcome {
        case .reset:
            _ = panel(0).table.waitForExistence(timeout: timeout)
            return window
        case .relaunched:
            return window
        case .failed(let why):
            // The app said it implements the contract and then did not honour it. That is a defect
            // worth failing on, but the test itself still gets a usable app.
            XCTFail("sevenzip://test/reset did not complete: \(why)")
            return relaunch()
        }
    }

    /// Quit gracefully (so `applicationWillTerminate` saves the state) and launch again with the
    /// domain untouched: the way to assert that something persisted.
    @discardableResult
    public func relaunch(timeout: TimeInterval = 60) -> XCUIElement {
        _ = quit()
        return launch(seed: .keep, timeout: timeout)
    }

    /// Quit through the application menu so the app saves its state; `false` if it did not exit.
    @discardableResult
    public func quit(timeout: TimeInterval = 30) -> Bool {
        guard isRunning else { return true }
        if !selectMenuItem(Self.appMenuTitle, Self.quitItemTitle) {
            app.terminate()
        }
        return app.wait(for: .notRunning, timeout: timeout)
    }

    /// Kill the app without letting it save (SIGKILL); safe to call when it is not running.
    public func terminate() {
        if isRunning { app.terminate() }
    }

    public var isRunning: Bool { app.state != .notRunning && app.state != .unknown }

    // MARK: - Window, panels

    public var window: XCUIElement { app.windows.element(boundBy: 0) }
    /// CApp::RefreshTitle: the focused panel's path, "7-Zip" when it is empty.
    public var windowTitle: String { window.title }
    private var splitGroup: XCUIElement { window.splitGroups.element(boundBy: 0) }

    /// 1 or 2 -- how many panels the window shows.
    public var panelCount: Int { window.tables.count }

    /// Panel 0 is the left one, panel 1 the right one.
    public func panel(_ index: Int) -> SevenZipPanel {
        SevenZipPanel(index: index, window: window, splitGroup: splitGroup)
    }

    /// True when the panel indexes really run left to right (a sanity check for two-panel tests).
    public var panelsAreOrderedLeftToRight: Bool {
        guard panelCount > 1 else { return true }
        return panel(0).table.frame.minX < panel(1).table.frame.minX
    }

    /// Bring the window to 1 or 2 panels with View > 2 Panels, whatever it shows now. Needed
    /// because the number of panels is stored as an integer and launch arguments cannot express
    /// one (SettingsDomain, "Limits"); `false` when the toggle did not take effect.
    @discardableResult
    public func ensurePanelCount(_ wanted: Int, timeout: TimeInterval = 15) -> Bool {
        guard panelCount != wanted else { return true }
        guard selectMenuItem("View", "2 Panels") else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if panelCount == wanted { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    // MARK: - Toolbar (App.cpp g_ArchiveButtons / g_StandardButtons)

    public var toolbar: XCUIElement { window.toolbars.element(boundBy: 0) }

    /// A toolbar button by its label: "Add", "Extract", "Test", "Copy", "Move", "Delete", "Info".
    public func toolbarButton(_ title: String) -> XCUIElement {
        toolbar.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", title, title)).firstMatch
    }

    public var toolbarButtonTitles: [String] {
        guard let snap = try? toolbar.snapshot() else { return [] }
        return snap.children.filter { $0.elementType == .button }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { $0.title }
    }

    // MARK: - Menu bar (MainMenu.swift; item identifier == selector)

    public var menuBar: XCUIElement { app.menuBars.element(boundBy: 0) }

    /// "Apple", "7-Zip", "File", "Edit", "View", "Favorites", "Tools", "Window", "Help".
    /// Read from one accessibility snapshot: resolving menu elements one by one is slow and has
    /// crashed the test runner (see Mac/docs/reports/harness.md).
    public var topLevelMenuTitles: [String] {
        guard let snap = try? menuBar.snapshot() else { return [] }
        return snap.children.filter { $0.elementType == .menuBarItem }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map { $0.title }
    }

    public func menuBarItem(_ title: String) -> XCUIElement {
        menuBar.children(matching: .menuBarItem).matching(titled: title).firstMatch
    }

    /// A menu item by its menu path, e.g. `menuItem("View", "2 Panels")` or
    /// `menuItem("File", "CRC", "MD5")`. Resolves without opening the menu.
    public func menuItem(_ path: String...) -> XCUIElement { menuItem(path: path) }

    public func menuItem(path: [String]) -> XCUIElement {
        guard let first = path.first else { return menuBar }
        var element = menuBarItem(first)
        for title in path.dropFirst() {
            element = childItem(of: element, titled: title)
        }
        return element
    }

    /// A menu item by the selector it sends, e.g. `menuItem(selector: "viewTwoPanels:")`.
    /// Independent of the language the titles are in.
    public func menuItem(selector: String) -> XCUIElement {
        menuBar.descendants(matching: .menuItem).matching(identifier: selector).firstMatch
    }

    /// The item titles of one menu (separators appear as ""), e.g. `itemTitles(in: "View")` or
    /// `itemTitles(in: "File", "CRC")`. One snapshot of the whole menu bar, no menu is opened.
    public func itemTitles(in path: String...) -> [String] {
        guard let snap = try? menuBar.snapshot() else { return [] }
        var owner: XCUIElementSnapshot? = snap.children
            .first { $0.elementType == .menuBarItem && $0.title == path[0] }
        for title in path.dropFirst() {
            owner = owner?.children.first { $0.elementType == .menu }?
                .children.first { $0.elementType == .menuItem && $0.title == title }
        }
        guard let menu = owner?.children.first(where: { $0.elementType == .menu }) else { return [] }
        return menu.children.filter { $0.elementType == .menuItem }.map { $0.title }
    }

    /// Open the menus along `path` and click the last item. `false` if an item never appeared.
    @discardableResult
    public func selectMenuItem(_ path: String..., timeout: TimeInterval = 10) -> Bool {
        guard let first = path.first, path.count >= 2 else { return false }
        let top = menuBarItem(first)
        guard top.waitForExistence(timeout: timeout) else { return false }
        top.click()
        var owner = top
        for (offset, title) in path.enumerated() where offset > 0 {
            let item = childItem(of: owner, titled: title)
            guard item.waitForExistence(timeout: timeout) else {
                closeOpenMenus()
                return false
            }
            if offset == path.count - 1 {
                item.click()
            } else {
                item.hover()
                owner = item
            }
        }
        return true
    }

    public func isMenuItemEnabled(_ path: String...) -> Bool {
        menuItem(path: path).isEnabled
    }

    /// Escape out of any menu left open by a failed `selectMenuItem`.
    public func closeOpenMenus() {
        app.typeKey(.escape, modifierFlags: [])
    }

    private func childItem(of owner: XCUIElement, titled title: String) -> XCUIElement {
        owner.children(matching: .menu).firstMatch
            .children(matching: .menuItem).matching(titled: title).firstMatch
    }

    // MARK: - Dialogs

    /// Wait for a sheet/dialog/window whose window title or whose message text (the first
    /// StaticText of an NSAlert) is `title`; nil when none appeared before `timeout`.
    public func waitForDialog(title: String, timeout: TimeInterval = 15) -> XCUIElement? {
        let titled = NSPredicate(format: "title == %@", title)
        let texted = NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", title, title)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for query in [app.sheets, app.dialogs, app.windows] {
                let byTitle = query.matching(titled).firstMatch
                if byTitle.exists { return byTitle }
                let byText = query.containing(texted).firstMatch
                if byText.exists { return byText }
            }
            usleep(200_000)
        } while Date() < deadline
        return nil
    }

    /// Every static text of a dialog, top to bottom: `[messageText, informativeText, ...]`.
    public func texts(of dialog: XCUIElement) -> [String] {
        dialog.descendants(matching: .staticText).allElementsBoundByAccessibilityElement
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { ($0.value as? String) ?? $0.label }
    }

    /// Click a button of a dialog ("OK", "Cancel", ...); `false` if it is not there.
    @discardableResult
    public func dismissDialog(_ dialog: XCUIElement, button: String = "OK", timeout: TimeInterval = 10) -> Bool {
        let b = dialog.buttons.matching(NSPredicate(format: "title == %@ OR label == %@", button, button)).firstMatch
        guard b.waitForExistence(timeout: timeout) else { return false }
        b.click()
        return true
    }

    public func waitForNoDialog(timeout: TimeInterval = 10) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.sheets.count == 0 && app.dialogs.count == 0 { return true }
            usleep(200_000)
        }
        return false
    }

    // MARK: - Screenshots

    /// Write the whole accessibility tree of the app to `Mac/build/uitests/<name>-tree.txt` and
    /// return the file URL -- the fastest way to find out how a new view is exposed.
    @discardableResult
    public func dumpTree(_ name: String = "app") -> URL? {
        let url = URL(fileURLWithPath: TestPaths.artifacts).appendingPathComponent("\(name)-tree.txt")
        let text = app.debugDescription + "\n\n=== menu bar ===\n" + menuBar.debugDescription
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    /// Screenshot of the app window (or of the screen when the app is gone), named
    /// `<prefix>-<name>.png`.
    ///
    /// It is attached to the test result (lifetime `.keepAlways`), and `Mac/scripts/test.sh`
    /// exports every attachment of a run into `Mac/docs/reports/screenshots/` -- the sandboxed
    /// test runner cannot write there itself. When the runner is *not* sandboxed the file is also
    /// written directly and its URL returned.
    @discardableResult
    public func screenshot(_ name: String, prefix: String = "harness", test: XCTestCase? = nil) -> URL? {
        let base = name.hasPrefix(prefix + "-") ? name : "\(prefix)-\(name)"
        let file = base.hasSuffix(".png") ? base : base + ".png"
        let shot: XCUIScreenshot
        if isRunning && window.exists {
            shot = window.screenshot()
        } else {
            shot = XCUIScreen.main.screenshot()
        }
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = file                      // test.sh matches this name
        attachment.lifetime = .keepAlways
        if let test {
            test.add(attachment)
        } else {
            XCTContext.runActivity(named: file) { $0.add(attachment) }
        }
        guard !TestPaths.isSandboxed else { return nil }
        let url = URL(fileURLWithPath: TestPaths.screenshots).appendingPathComponent(file)
        try? FileManager.default.createDirectory(atPath: TestPaths.screenshots, withIntermediateDirectories: true)
        do {
            try shot.pngRepresentation.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - One panel (CPanel)

/// The views of one 7zFM panel. Elements are resolved lazily on every access, so a handle stays
/// valid when the app rebuilds its columns or rows.
public struct SevenZipPanel {

    public let index: Int
    private let window: XCUIElement
    private let splitGroup: XCUIElement

    init(index: Int, window: XCUIElement, splitGroup: XCUIElement) {
        self.index = index
        self.window = window
        self.splitGroup = splitGroup
    }

    // MARK: views

    // AppKit flattens each panel's container view away: the Up button, the folder icon, the address
    // combo, the list's scroll view and the status label are all *siblings* inside the window's
    // SplitGroup, panel 0's first and panel 1's after the NSSplitView divider (an AX element of type
    // .splitter). So `children(matching: .comboBox).element(boundBy: panelIndex)` only works while
    // there is one panel; with two it is the index over *both* panels' combo boxes that matters.
    // `ordinal(of:)` works that index out from one snapshot, using the divider as the boundary, and
    // every accessor below goes through it -- so `table`, `addressBar`, `upButton` and `statusText`
    // are guaranteed to belong to the same panel (requests.md: orchestrator -> harness).

    /// The details list (NSTableView). The window's tables really are in panel order -- each
    /// panel's list sits in its own scroll view and `MainWindowController.showSecondPanel` inserts
    /// the arranged subviews by index -- and this is the hottest accessor of the driver, so it is
    /// left as the cheap one-query form.
    public var table: XCUIElement { window.tables.element(boundBy: index) }
    /// The editable path combo box.
    public var addressBar: XCUIElement {
        splitGroup.children(matching: .comboBox).element(boundBy: ordinal(of: .comboBox))
    }
    /// The "Up One Level" button left of the address bar (kParentFolderID).
    public var upButton: XCUIElement {
        splitGroup.children(matching: .button).element(boundBy: ordinal(of: .button))
    }
    /// Section 0 of the panel's status bar ("N / M object(s) selected").
    ///
    /// Since `mac/navgaps` the status bar is four labels (01 §1.2, Panel.cpp CreateStatusBar
    /// `{220, 320, 420, -1}`): this one, then the selected size, the focused item's size and its
    /// time. All four are static texts of the split group, so the panel's ordinal alone no longer
    /// names section 0; `statusOrdinal()` picks the leftmost label of the panel's bottom row.
    public var statusText: XCUIElement {
        splitGroup.children(matching: .staticText).element(boundBy: statusOrdinal())
    }

    /// The visible status-bar sections left to right (a section past a narrow panel's edge is hidden,
    /// so there may be fewer than four). Bidi isolates (U+2066-U+2069) are stripped, so the text
    /// compares as typed.
    public var statusParts: [String] {
        guard let snap = try? splitGroup.snapshot() else { return [] }
        return statusRow(of: snap).map { Self.stripIsolates(($0.value as? String) ?? "") }
    }

    /// Index of this panel's `type` element among the split group's children of that type. The
    /// children are sorted left to right and cut at the divider, so the answer holds whichever
    /// order accessibility reports them in and whatever the splitter position is.
    private func ordinal(of type: XCUIElement.ElementType) -> Int {
        guard index > 0, let snap = try? splitGroup.snapshot() else { return index == 0 ? 0 : index }
        let children = snap.children.sorted { $0.frame.minX < $1.frame.minX }
        guard let divider = children.first(where: { $0.elementType == .splitter }) else { return index }
        var seen = 0
        for child in children where child.elementType == type {
            // the divider's own x is the boundary; a panel-1 view starts at or after it
            if child.frame.minX >= divider.frame.minX { return seen }
            seen += 1
        }
        return index
    }

    /// This panel's static texts in the split group's bottom row (the status bar), left to right,
    /// as (AX index among the split group's static texts, snapshot).
    private func statusRowIndexed(of snap: XCUIElementSnapshot) -> [(Int, XCUIElementSnapshot)] {
        let texts = snap.children.filter { $0.elementType == .staticText }
        let divider = snap.children.first { $0.elementType == .splitter }
        let mine = texts.enumerated().filter { _, text in
            guard let divider else { return index == 0 }
            return (text.frame.minX >= divider.frame.minX) == (index > 0)
        }
        guard let bottom = mine.map({ $0.element.frame.maxY }).max() else { return [] }
        return mine.filter { abs($0.element.frame.maxY - bottom) < 6 }
            .sorted { $0.element.frame.minX < $1.element.frame.minX }
            .map { ($0.offset, $0.element) }
    }

    private func statusRow(of snap: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        statusRowIndexed(of: snap).map { $0.1 }
    }

    private func statusOrdinal() -> Int {
        guard let snap = try? splitGroup.snapshot(),
              let first = statusRowIndexed(of: snap).first else { return ordinal(of: .staticText) }
        return first.0
    }

    private static func stripIsolates(_ text: String) -> String {
        String(text.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) }.map(Character.init))
    }

    // MARK: icon views (Large Icons / Small Icons / List)

    // In the three icon view modes the list is an `NSCollectionView` (`PanelIconView`) laid **over**
    // the table; the table stays in the hierarchy, so `table`, `panelCount` and the row helpers keep
    // resolving -- but they read the hidden details list, not what is on screen (requests.md: panel
    // -> harness). A view-mode test reads these instead. The hidden icon view of a panel in Details
    // mode is not in the accessibility tree, so `iconView.exists` is also "this panel shows icons".

    /// The panel's collection view, or a non-existent element when the panel is in Details mode.
    public var iconView: XCUIElement {
        let query = splitGroup.descendants(matching: .collectionView)
        guard let snap = try? splitGroup.snapshot() else { return query.element(boundBy: index) }
        var views: [XCUIElementSnapshot] = []
        func walk(_ node: XCUIElementSnapshot) {
            for child in node.children {
                if child.elementType == .collectionView { views.append(child) } else { walk(child) }
            }
        }
        walk(snap)
        let divider = snap.children.first { $0.elementType == .splitter }
        for (k, view) in views.enumerated() {
            let onRight = divider.map { view.frame.minX >= $0.frame.minX } ?? false
            if onRight == (index > 0) { return query.element(boundBy: k) }
        }
        // Not shown: an element bound past the end, which reports `exists == false`.
        return query.element(boundBy: views.count)
    }

    /// The item names of the icon view in reading order (top to bottom, then left to right), from
    /// one snapshot. Empty in Details mode.
    public var iconNames: [String] {
        let view = iconView
        guard view.exists, let snap = try? view.snapshot() else { return [] }
        var texts: [XCUIElementSnapshot] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .staticText { texts.append(node) }
            node.children.forEach(walk)
        }
        walk(snap)
        return texts.sorted {
            abs($0.frame.minY - $1.frame.minY) > 4 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX
        }.map { ($0.value as? String) ?? $0.title }
    }

    /// The label of the icon item called `name` -- the thing to click, right-click or drag.
    public func iconItem(named name: String) -> XCUIElement {
        iconView.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value == %@ OR title == %@", name, name)).firstMatch
    }

    /// Wait until the icon view shows an item called `name`.
    @discardableResult
    public func waitForIcon(named name: String, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if iconNames.contains(name) { return true }
            usleep(100_000)
        } while Date() < deadline
        return iconNames.contains(name)
    }

    // MARK: state

    /// The folder shown, as the address bar spells it ("" for the root folder).
    public var path: String { (addressBar.value as? String) ?? "" }
    public var status: String { (statusText.value as? String) ?? "" }
    public var rowCount: Int { table.tableRows.count }
    public var exists: Bool { table.exists }

    /// Column titles left to right, e.g. ["Name", "Size", "Modified", "Created"].
    public var columnTitles: [String] {
        guard let snap = try? table.snapshot() else { return [] }
        return Self.headerButtons(of: snap).map { $0.title }
    }

    /// The Name column of every row, top to bottom. One accessibility snapshot of the list, so it
    /// is cheap even for a long directory.
    public var names: [String] {
        guard let snap = try? table.snapshot() else { return [] }
        return Self.rows(of: snap).map { Self.nameOfRow($0) }
    }

    // MARK: rows

    /// The row whose Name cell reads `name` (TableRow element).
    public func row(named name: String) -> XCUIElement {
        table.tableRows.containing(NSPredicate(format: "elementType == %d AND value == %@",
                                              XCUIElement.ElementType.staticText.rawValue, name)).firstMatch
    }

    /// The Name cell (StaticText) of the row called `name` -- the thing to click.
    ///
    /// The leftmost match, because a value can repeat across columns (a file called "12" and a size
    /// of 12). How many matches there are comes from **one snapshot** rather than from
    /// `allElementsBoundByAccessibilityElement`, which resolves every match over the accessibility
    /// bus one element at a time; with one match -- the normal case -- nothing but `firstMatch` is
    /// resolved at all.
    public func nameCell(named name: String) -> XCUIElement {
        let query = table.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value == %@", name))
        if let snap = try? table.snapshot(), Self.countOfText(name, in: snap) > 1 {
            let all = query.allElementsBoundByAccessibilityElement
            if let leftmost = all.min(by: { $0.frame.minX < $1.frame.minX }) { return leftmost }
        }
        return query.firstMatch
    }

    /// Is there a row with this name? Read from one snapshot of the list: an element query costs a
    /// round trip per candidate and, before it, a wait for the app to go idle.
    public func hasRow(named name: String) -> Bool {
        guard let snap = try? table.snapshot() else { return false }
        return Self.rows(of: snap).contains { Self.nameOfRow($0) == name }
    }

    /// Wait for a row to appear, polling the same snapshot. The listing arrives on the panel's own
    /// queue, so this is a condition wait and never a delay.
    @discardableResult
    public func waitForRow(named name: String, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if hasRow(named: name) { return true }
            usleep(100_000)
        } while Date() < deadline
        return hasRow(named: name)
    }

    /// Wait until the address bar shows `path` (a trailing "/" is ignored).
    @discardableResult
    public func waitForPath(_ expected: String, timeout: TimeInterval = 20) -> Bool {
        let want = Self.normalize(expected)
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if Self.normalize(path) == want { return true }
            usleep(200_000)
        } while Date() < deadline
        return false
    }

    /// Text of one cell of a row, by column index (0 = Name).
    public func cellText(row name: String, column: Int) -> String {
        guard let snap = try? table.snapshot(),
              let row = Self.rows(of: snap).first(where: { Self.nameOfRow($0) == name }) else { return "" }
        let cells = row.children.filter { $0.elementType == .cell }.sorted { $0.frame.minX < $1.frame.minX }
        guard column < cells.count else { return "" }
        return Self.firstText(in: cells[column])
    }

    // MARK: actions

    /// Single-click the row (selects it; refreshes the status bar).
    public func select(_ name: String) {
        let cell = nameCell(named: name)
        XCTAssertTrue(scrollIntoView(cell), "row '\(name)' is not clickable in panel \(index)")
        cell.click()
    }

    /// Double-click the row: a directory is entered, an archive is opened inside
    /// (CPanel::OpenItem), anything else goes to the default application.
    public func open(_ name: String) {
        let cell = nameCell(named: name)
        XCTAssertTrue(scrollIntoView(cell), "row '\(name)' is not clickable in panel \(index)")
        cell.doubleClick()
    }

    /// The "Up One Level" button (IDM_OPEN_PARENT_FOLDER / Backspace).
    public func goUp() {
        upButton.click()
    }

    /// Click a column header: sorts by that column, or reverses the order (PanelSort.cpp
    /// OnColumnClick; size and time columns start descending).
    public func clickColumnHeader(_ title: String) {
        let button = table.descendants(matching: .button).matching(titled: title).firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10), "no column header '\(title)' in panel \(index)")
        button.click()
    }

    /// Type a path into the address bar and press Return (CPanel::OnNotifyComboEnter); `false` when
    /// the bar never showed exactly `newPath`, so a half-typed path cannot be mistaken for a
    /// navigation that simply did not happen.
    ///
    /// Two traps, both of which used to leave the old text in place and append to it:
    ///
    /// * **Cmd+A never reaches the field editor.** It is the key equivalent of the app's
    ///   Edit > Select All (IDM_SELECT_ALL 600), and AppKit offers a key equivalent to the menu
    ///   bar before the key window's responder chain, so the panel selected all its *rows* and the
    ///   typed path was appended to the path already in the combo. The existing text is selected
    ///   with the standard line motions instead -- Cmd+Right to the end, Shift+Cmd+Left back to the
    ///   start -- which `MainMenu.swift` does not bind (it binds Cmd+Up/Down, Cmd+[/], Cmd+A,
    ///   Cmd+Backspace, Cmd+R, Cmd+Z, Cmd+N, and the numeric-pad and function keys).
    /// * **`pathCombo.completes = true`**, so inline completion appends a *selected* suffix while
    ///   the path is typed. One Delete drops it -- but only when the value really is `newPath` plus
    ///   a suffix, otherwise Delete eats the last character that was meant to be there.
    @discardableResult
    public func navigate(to newPath: String, attempts: Int = 3) -> Bool {
        let bar = addressBar
        guard bar.waitForExistence(timeout: 10) else { return false }
        bar.click()
        for _ in 0..<attempts {
            bar.typeKey(.rightArrow, modifierFlags: .command)                 // caret to the end
            bar.typeKey(.leftArrow, modifierFlags: [.command, .shift])        // select back to the start
            bar.typeText(newPath)
            if let shown = bar.value as? String, shown != newPath, shown.hasPrefix(newPath) {
                bar.typeKey(.delete, modifierFlags: [])
            }
            if (bar.value as? String) == newPath { break }
        }
        guard (bar.value as? String) == newPath else { return false }
        bar.typeKey(.return, modifierFlags: [])
        return true
    }

    /// Right-click a row and return the list context menu (CPanel::OnContextMenu / CreateFileMenu).
    ///
    /// The menu is a child of the *table* in the accessibility tree, because it is the
    /// NSTableView's `menu(for:)`. `app.menus.firstMatch` is the Apple menu -- every menu-bar menu
    /// is in `app.menus` too, all of them with an empty title and a zero frame while closed -- so
    /// it must be addressed from the table (requests.md: orchestrator -> harness).
    public func openContextMenu(onRow name: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let cell = nameCell(named: name)
        guard scrollIntoView(cell) else { return nil }
        cell.rightClick()
        let menu = table.descendants(matching: .menu).firstMatch
        guard menu.waitForExistence(timeout: timeout) else { return nil }
        return menu
    }

    /// The item titles of an open menu, top to bottom, from one snapshot (separators are "").
    public func menuItemTitles(of menu: XCUIElement) -> [String] {
        guard let snap = try? menu.snapshot() else { return [] }
        return snap.children.filter { $0.elementType == .menuItem }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map { $0.title }
    }

    /// Give the list keyboard focus (so Enter / Backspace / `\` reach the panel).
    public func focusList() {
        table.click()
    }

    // MARK: helpers

    /// The rows of a list snapshot, top to bottom.
    private static func rows(of table: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        table.children.filter { $0.elementType == .tableRow }.sorted { $0.frame.minY < $1.frame.minY }
    }

    /// The Name cell text of a row snapshot (the leftmost cell).
    private static func nameOfRow(_ row: XCUIElementSnapshot) -> String {
        guard let first = row.children.filter({ $0.elementType == .cell })
            .min(by: { $0.frame.minX < $1.frame.minX }) else { return "" }
        return firstText(in: first)
    }

    /// How many static texts of this subtree carry `text` as their value -- the snapshot answer to
    /// "is this name ambiguous across columns?".
    private static func countOfText(_ text: String, in node: XCUIElementSnapshot) -> Int {
        var count = node.elementType == .staticText && (node.value as? String) == text ? 1 : 0
        for child in node.children { count += countOfText(text, in: child) }
        return count
    }

    private static func firstText(in cell: XCUIElementSnapshot) -> String {
        for child in cell.children where child.elementType == .staticText {
            return child.value as? String ?? child.label
        }
        return ""
    }

    /// The column header buttons of a list snapshot, left to right (they sit in a Group inside the
    /// Table; the zero-height one is the corner view).
    private static func headerButtons(of table: XCUIElementSnapshot) -> [XCUIElementSnapshot] {
        var found: [XCUIElementSnapshot] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .button, node.frame.height > 0, !node.title.isEmpty { found.append(node) }
            node.children.forEach(walk)
        }
        walk(table)
        return found.sorted { $0.frame.minX < $1.frame.minX }
    }

    /// Scroll the list until `element` can be clicked (long listings expose every row to
    /// accessibility, but only the visible ones are hittable).
    private func scrollIntoView(_ element: XCUIElement, attempts: Int = 24) -> Bool {
        guard element.exists else { return false }
        if element.isHittable { return true }
        for _ in 0..<attempts {
            let target = element.frame
            let visible = table.frame
            let delta: CGFloat = target.midY < visible.midY ? 120 : -120
            table.scroll(byDeltaX: 0, deltaY: delta)
            if element.isHittable { return true }
        }
        return element.isHittable
    }

    private static func normalize(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

// MARK: - Query sugar

public extension XCUIElementQuery {
    /// Match on the accessibility title (menu items, buttons, column headers).
    func matching(titled title: String) -> XCUIElementQuery {
        matching(NSPredicate(format: "title == %@", title))
    }
    /// Match on the accessibility value (table cells, address bar, status bar).
    func matching(value: String) -> XCUIElementQuery {
        matching(NSPredicate(format: "value == %@", value))
    }
}
