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

    public static let bundleIdentifier = "com.yrambler2001.7zip"
    /// Title of the application menu and of its Quit item (from the bundle name).
    public static let appMenuTitle = "7-Zip"
    public static let quitItemTitle = "Quit 7-Zip"

    /// The underlying XCUIApplication; use it for anything this driver does not wrap.
    public let app: XCUIApplication
    /// The preferences domain the app reads its settings from.
    public let settings: SettingsDomain

    public init(app: XCUIApplication = XCUIApplication(), settings: SettingsDomain = SettingsDomain()) {
        self.app = app
        self.settings = settings
    }

    // MARK: - Launching

    /// Launch the app with known settings and wait until the first panel is listed.
    ///
    /// - Parameters:
    ///   - seed: the settings the app starts with, as launch arguments (`.clean` by default; see
    ///     `SettingsSeed`). They shadow whatever is stored and are gone when the app exits.
    ///   - path: `7zFM.exe [path]` argv -- the folder or archive panel 0 opens in. It must be the
    ///     first argument, which is why it is passed here and not in `arguments`.
    ///   - formatHint: `-t<type>` argv for `path`.
    ///   - arguments: extra launch arguments, appended after the seed (`["-FM.ShowDots", "1"]`).
    ///   - environment: extra environment variables for the app process.
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
        args += seed.launchArguments
        args += arguments
        app.launchArguments = args
        var env = environment
        env["SEVENZIP_UITEST"] = "1"
        app.launchEnvironment = env
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

    /// The details list (NSTableView).
    public var table: XCUIElement { window.tables.element(boundBy: index) }
    /// The editable path combo box.
    public var addressBar: XCUIElement { splitGroup.children(matching: .comboBox).element(boundBy: index) }
    /// The "Up One Level" button left of the address bar (kParentFolderID).
    public var upButton: XCUIElement { splitGroup.children(matching: .button).element(boundBy: index) }
    /// The panel's own status bar ("N / M object(s) selected   <size>   <mtime>").
    public var statusText: XCUIElement { splitGroup.children(matching: .staticText).element(boundBy: index) }

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
    public func nameCell(named name: String) -> XCUIElement {
        let matches = table.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value == %@", name))
            .allElementsBoundByAccessibilityElement
        if matches.count > 1, let leftmost = matches.min(by: { $0.frame.minX < $1.frame.minX }) {
            return leftmost
        }
        return table.descendants(matching: .staticText)
            .matching(NSPredicate(format: "value == %@", name)).firstMatch
    }

    public func hasRow(named name: String) -> Bool { nameCell(named: name).exists }

    @discardableResult
    public func waitForRow(named name: String, timeout: TimeInterval = 20) -> Bool {
        nameCell(named: name).waitForExistence(timeout: timeout)
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

    /// Type a path into the address bar and press Return (CPanel::OnNotifyComboEnter). Inline
    /// completion from the folder history is undone before Return so the typed path wins.
    public func navigate(to newPath: String) {
        let bar = addressBar
        bar.click()
        bar.typeKey("a", modifierFlags: .command)
        bar.typeText(newPath)
        if let shown = bar.value as? String, shown != newPath {
            bar.typeKey(.delete, modifierFlags: [])      // drop the selected completion
        }
        bar.typeKey(.return, modifierFlags: [])
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
