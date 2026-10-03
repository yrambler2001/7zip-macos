// SelColorsTests.swift -- selection, focus and grid colours of the panel list and of every other
// list in the app (Mac/docs/reports/selcolors.md). Rows are rendered in each state, Light and Dark,
// and every visible cell text is measured against what is really drawn behind it: the WCAG
// contrast of the text's most distinct pixel against the cell's dominant colour must be >= 4.5.
// The bug this guards: with "Full row select" off, a selected row's Size / Modified / ... cells
// were drawn white on the white list background.
//
// Also writes the Mac half of the paired captures, `screenshots/wincompare-selection-<state>-mac.png`
// (the Windows half is 7zFM 25.01, `selcolors-data/win/`).

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

// MARK: - pixels

struct RGB: Hashable, CustomStringConvertible {
    var r: Int, g: Int, b: Int
    var description: String { "(\(r),\(g),\(b))" }

    /// WCAG 2 relative luminance of an sRGB colour.
    var luminance: Double {
        func lin(_ v: Int) -> Double {
            let c = Double(v) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    func contrast(_ other: RGB) -> Double {
        let (a, b) = (luminance, other.luminance)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    func isClose(to other: RGB, tolerance: Int = 4) -> Bool {
        abs(r - other.r) <= tolerance && abs(g - other.g) <= tolerance && abs(b - other.b) <= tolerance
    }

    static let highlight = RGB(r: 0, g: 120, b: 212)
    static let white = RGB(r: 255, g: 255, b: 255)
}

enum ContrastProbe {

    struct Reading { var background: RGB; var text: RGB; var ratio: Double }

    /// `rect` of `view` rendered into an sRGB bitmap at 2x, as a pixel list. The pixels are taken
    /// from the window's frame view when there is one, so a table that leaves its background to
    /// the window is measured on the window's real background.
    static func pixels(of view: NSView, in rect: NSRect) -> [RGB] {
        var source = view
        var area = rect.intersection(view.bounds)
        if let frameView = view.window?.contentView?.superview {
            area = view.convert(area, to: frameView)
            source = frameView
        }
        area = area.integral
        let scale = 2
        guard area.width >= 1, area.height >= 1,
              let raw = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(area.width) * scale,
                                         pixelsHigh: Int(area.height) * scale, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32),
              let rep = raw.retagging(with: .sRGB) else { return [] }
        rep.size = area.size
        source.cacheDisplay(in: area, to: rep)
        guard let data = rep.bitmapData else { return [] }
        var out: [RGB] = []
        out.reserveCapacity(rep.pixelsWide * rep.pixelsHigh)
        for y in 0..<rep.pixelsHigh {
            let line = data + y * rep.bytesPerRow
            for x in 0..<rep.pixelsWide {
                let p = line + x * 4
                // Premultiplied RGBA; composite a transparent pixel over white.
                let a = Int(p[3])
                out.append(RGB(r: Int(p[0]) + 255 - a, g: Int(p[1]) + 255 - a, b: Int(p[2]) + 255 - a))
            }
        }
        return out
    }

    /// The dominant colour is the background; the text is the pixel that differs most from it.
    static func measure(_ view: NSView, _ rect: NSRect) -> Reading? {
        let px = pixels(of: view, in: rect)
        guard !px.isEmpty else { return nil }
        var counts: [RGB: Int] = [:]
        for p in px { counts[p, default: 0] += 1 }
        let background = counts.max { $0.value < $1.value }!.key
        let text = px.max { background.contrast($0) < background.contrast($1) }!
        return Reading(background: background, text: text, ratio: background.contrast(text))
    }
}

// MARK: - tests

final class SelColorsTests: AppHostTestCase {

    override var screenshotPrefix: String { "selcolors" }

    private var controllers: [MainWindowController] = []
    private var scratchDirectories: [String] = []
    private var savedNumPanels = 1
    private var savedPanelPaths: [String?] = []
    private var savedFullRow = false
    private var savedShowGrid = false
    private var savedListModes: [Int] = []
    private var savedAppearance: NSAppearance?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedNumPanels = Settings.numPanels
        savedPanelPaths = [Settings.panelPath(0), Settings.panelPath(1)]
        savedFullRow = Settings.fullRow
        savedShowGrid = Settings.showGrid
        savedListModes = [Settings.listMode(0), Settings.listMode(1)]
        savedAppearance = NSApp.appearance
    }

    override func tearDown() {
        while NSApp.modalWindow != nil { NSApp.abortModal() }
        for controller in controllers { controller.window?.close() }
        controllers = []
        for path in scratchDirectories { try? FileManager.default.removeItem(atPath: path) }
        scratchDirectories = []
        for (i, path) in savedPanelPaths.enumerated() { Settings.setPanelPath(path, i) }
        for (i, mode) in savedListModes.enumerated() { Settings.setListMode(mode, i) }
        Settings.numPanels = savedNumPanels
        Settings.fullRow = savedFullRow
        Settings.showGrid = savedShowGrid
        NSApp.appearance = savedAppearance
        super.tearDown()
    }

    // MARK: helpers

    /// The folder the Windows captures used: sub, a.txt, b.bin, c.txt, notes.md.
    private func makeScratch() -> String {
        let path = (TestPaths.artifacts as NSString).appendingPathComponent("selcolors-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/sel/sub", withIntermediateDirectories: true)
        for (name, size) in [("a.txt", 1234), ("b.bin", 100_000), ("c.txt", 20), ("notes.md", 300)] {
            fm.createFile(atPath: path + "/sel/" + name, contents: Data(repeating: 0x78, count: size))
        }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2024, 1, 15, 10, 30)
        if let date = Calendar.current.date(from: c) {
            for name in ["sub", "a.txt", "b.bin", "c.txt", "notes.md"] {
                try? fm.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: path + "/sel/" + name)
            }
        }
        scratchDirectories.append(path)
        return path + "/sel"
    }

    private func makeWindow(panels: Int = 1) -> MainWindowController {
        Settings.numPanels = panels
        Settings.setListMode(3, 0)
        Settings.setListMode(3, 1)
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(NSSize(width: 1000, height: 600))
        controller.showWindow(nil)
        return controller
    }

    private func navigate(_ panel: PanelViewController, to path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
    }

    private func row(_ panel: PanelViewController, _ name: String) -> Int {
        panel.rows.firstIndex { $0.displayName == name } ?? -1
    }

    private func select(_ panel: PanelViewController, _ names: [String], focus: String?) {
        let indexes = IndexSet(names.map { row(panel, $0) }.filter { $0 >= 0 })
        if panel.listViewMode == 3 {
            panel.tableView.selectRowIndexes(indexes, byExtendingSelection: false)
        } else {
            panel.iconView.setSelectionIndexes(indexes)
        }
        if let focus { panel.focusedIndex = row(panel, focus) }
        panel.refreshSelectionAppearance()
        panel.view.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func appearanceName(_ dark: Bool) -> String { dark ? "dark" : "light" }

    /// Every non-empty cell of every row of the Details table: contrast >= 4.5, and highlighted
    /// exactly where 7zFM highlights.
    private func checkDetails(_ panel: PanelViewController, state: String, selected: Set<Int>,
                              focused: Bool, fullRow: Bool) {
        let table = panel.tableView
        table.layoutSubtreeIfNeeded()
        for r in 0..<table.numberOfRows {
            for c in 0..<table.numberOfColumns {
                guard let cell = table.view(atColumn: c, row: r, makeIfNecessary: false) as? NSTableCellView,
                      let field = cell.textField, !field.stringValue.isEmpty else { continue }
                let isName = PanelViewController.propID(of: table.tableColumns[c]) == .name
                var rect = field.convert(field.bounds, to: table)
                if isName {         // only the text: the name label's highlight is the text's width
                    rect.size.width = min(rect.width, field.intrinsicContentSize.width)
                }
                // Only what is on screen: a column (partly) scrolled out of the window is skipped.
                guard table.visibleRect.contains(rect) else { continue }
                guard let m = ContrastProbe.measure(table, rect) else { XCTFail("no pixels"); continue }
                let what = "\(state) row \(r) '\(field.stringValue)' col \(table.tableColumns[c].title)"
                XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "\(what): text \(m.text) on \(m.background)")
                let lit = focused && selected.contains(r) && (isName || fullRow)
                if lit {
                    XCTAssertTrue(m.background.isClose(to: .highlight), "\(what): \(m.background) is not the highlight")
                    XCTAssertTrue(m.text.isClose(to: .white, tolerance: 8), "\(what): text \(m.text) is not white")
                } else {
                    XCTAssertFalse(m.background.isClose(to: .highlight, tolerance: 30),
                                   "\(what): highlighted, 7zFM does not highlight it")
                }
            }
        }
    }

    // MARK: - Details

    /// Light and Dark, FullRow on and off, list focused and not, single and multi selection, a
    /// focused-but-unselected row, grid lines: every cell readable, the fill where 7zFM puts it.
    func testDetailsRowsAreReadableInEveryState() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        controller.window?.makeFirstResponder(panel.tableView)
        continueAfterFailure = true
        let a = row(panel, "a.txt"), b = row(panel, "b.bin"), c = row(panel, "c.txt")
        XCTAssertTrue(a >= 0 && b >= 0 && c >= 0, "fixture rows")
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for fullRow in [false, true] {
                for grid in [false, true] {
                    Settings.fullRow = fullRow
                    Settings.showGrid = grid
                    panel.applyListSettings()
                    XCTAssertTrue(wait(for: "reload") { panel.rows.count == 5 })
                    for focused in [true, false] {
                        panel.listFocusOverride = focused
                        let tag = "\(appearanceName(dark)) fr\(fullRow ? 1 : 0) g\(grid ? 1 : 0) \(focused ? "focused" : "unfocused")"
                        select(panel, ["b.bin"], focus: "b.bin")
                        checkDetails(panel, state: tag + " single", selected: [b], focused: focused, fullRow: fullRow)
                        select(panel, ["a.txt", "c.txt"], focus: "c.txt")
                        checkDetails(panel, state: tag + " multi", selected: [a, c], focused: focused, fullRow: fullRow)
                        select(panel, [], focus: "b.bin")
                        checkDetails(panel, state: tag + " focus only", selected: [], focused: focused, fullRow: fullRow)
                    }
                }
            }
        }
        panel.listFocusOverride = nil
    }

    /// Inside an archive (its 11 columns: Attributes, CRC, Method, ...) and in flat mode (the Path
    /// column), Light and Dark, FullRow on and off: every cell of the selected rows readable.
    func testArchiveAndFlatRowsAreReadable() {
        let controller = makeWindow()
        let panel = controller.focusedPanel
        var done = false
        panel.navigate(to: TestPaths.fixture("test.7z")) { _ in done = true }
        XCTAssertTrue(wait(for: "inside test.7z") { done && !panel.rows.isEmpty })
        continueAfterFailure = true
        for flat in [false, true] {
            if panel.flatMode != flat {
                let before = panel.loadGeneration
                panel.setFlatMode(flat)
                XCTAssertTrue(wait(for: "flat \(flat)") { panel.loadGeneration != before && !panel.rows.isEmpty })
            }
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for fullRow in [false, true] {
                    Settings.fullRow = fullRow
                    panel.listFocusOverride = true
                    let names = panel.rows.prefix(2).map(\.displayName)
                    select(panel, names, focus: names.last)
                    checkDetails(panel, state: "test.7z flat=\(flat) \(appearanceName(dark)) fr\(fullRow ? 1 : 0)",
                                 selected: Set(0..<min(2, panel.rows.count)), focused: true, fullRow: fullRow)
                }
            }
        }
        if panel.flatMode { panel.setFlatMode(false) }
        panel.listFocusOverride = nil
    }

    /// The exact bug report: Light, "Full row select" off (the default), a selected row's other
    /// columns. Before the fix AppKit drew them white (emphasized) on the white list.
    func testUnhighlightedColumnsOfASelectedRowKeepTheirColour() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        NSApp.appearance = NSAppearance(named: .aqua)
        Settings.fullRow = false
        panel.applyListSettings()
        XCTAssertTrue(wait(for: "reload") { panel.rows.count == 5 })
        panel.listFocusOverride = true
        select(panel, ["b.bin"], focus: "b.bin")
        let r = row(panel, "b.bin")
        for c in 0..<panel.tableView.numberOfColumns {
            guard let cell = panel.tableView.view(atColumn: c, row: r, makeIfNecessary: false) as? PanelCellView else { continue }
            XCTAssertEqual(cell.backgroundStyle, .normal, "AppKit's emphasized style must not reach the cell")
            let isName = PanelViewController.propID(of: panel.tableView.tableColumns[c]) == .name
            XCTAssertEqual(cell.isHighlighted, isName)
        }
        // AppKit itself sets `.emphasized` on a selected row's cells; the cell refuses it.
        if let cell = panel.tableView.view(atColumn: 1, row: r, makeIfNecessary: false) as? PanelCellView {
            cell.backgroundStyle = .emphasized
            XCTAssertEqual(cell.backgroundStyle, .normal)
        }
        panel.listFocusOverride = nil
    }

    /// AlternativeSelection's pink rows (01 §3.6) stay readable in Dark mode too.
    func testAlternativeSelectionRowsAreReadable() {
        for dark in [false, true] {
            let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
            view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let field = NSTextField(labelWithString: "selected by Insert")
            field.textColor = PanelSelectionStyle.normalText(isDeleted: false)
            field.frame = view.bounds
            let fill = FillView(frame: view.bounds, color: PanelSelectionStyle.mySelected)
            view.addSubview(fill)
            view.addSubview(field)
            let m = ContrastProbe.measure(view, field.frame.insetBy(dx: 0, dy: 2))
            XCTAssertGreaterThanOrEqual(m?.ratio ?? 0, 4.5, "\(appearanceName(dark)): \(String(describing: m))")
        }
    }

    // MARK: - icon modes

    /// Large Icons, Small Icons, List: the label of a selected item white on the highlight, the
    /// others in the normal colour; nothing highlighted while the list is unfocused.
    func testIconModesAreReadable() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        continueAfterFailure = true
        for mode in 0...2 {
            panel.setListViewMode(mode)
            let cv = panel.iconView.collectionView
            XCTAssertTrue(wait(for: "icon items") {
                controller.window?.contentView?.layoutSubtreeIfNeeded()
                return cv.visibleItems().count == 5
            })
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for focused in [true, false] {
                    panel.listFocusOverride = focused
                    select(panel, ["a.txt", "c.txt"], focus: "c.txt")
                    cv.layoutSubtreeIfNeeded()
                    for i in 0..<panel.rows.count {
                        guard let item = cv.item(at: IndexPath(item: i, section: 0)), let field = item.textField else { continue }
                        var rect = field.convert(field.bounds, to: cv)
                        let w = min(rect.width, field.intrinsicContentSize.width)
                        if mode == 0 { rect.origin.x = rect.midX - w / 2 }
                        rect.size.width = w
                        guard let m = ContrastProbe.measure(cv, rect) else { continue }
                        let what = "mode \(mode) \(appearanceName(dark)) \(focused ? "focused" : "unfocused") '\(field.stringValue)'"
                        XCTAssertGreaterThanOrEqual(m.ratio, 4.5, "\(what): \(m.text) on \(m.background)")
                        let lit = focused && ["a.txt", "c.txt"].contains(field.stringValue)
                        XCTAssertEqual(m.background.isClose(to: .highlight), lit, "\(what): background \(m.background)")
                    }
                }
            }
        }
        panel.listFocusOverride = nil
        panel.setListViewMode(3)
    }

    // MARK: - which list has the focus

    /// Two panels: only the panel whose list is the first responder of the key window draws its
    /// selection (7zFM's inactive panel shows none, LVS_SHOWSELALWAYS is off); the address bar
    /// taking the focus hides it too.
    func testOnlyTheFocusedListDrawsItsSelection() throws {
        let scratch = makeScratch()
        let controller = makeWindow(panels: 2)
        let window = try XCTUnwrap(controller.window)
        let panels = controller.panels
        XCTAssertEqual(panels.count, 2)
        for panel in panels { navigate(panel, to: scratch); select(panel, ["a.txt"], focus: "a.txt") }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        guard wait(for: "key window", timeout: 5, until: { window.isKeyWindow }) else {
            throw XCTSkip("the host app could not take the key window (another app is frontmost)")
        }
        window.makeFirstResponder(panels[0].tableView)
        XCTAssertTrue(panels[0].listHasKeyboardFocus)
        XCTAssertFalse(panels[1].listHasKeyboardFocus)
        let r = row(panels[0], "a.txt")
        XCTAssertTrue(panels[0].cellIsHighlighted(row: r, isName: true))
        XCTAssertFalse(panels[1].cellIsHighlighted(row: r, isName: true))
        window.makeFirstResponder(panels[1].tableView)
        XCTAssertFalse(panels[0].cellIsHighlighted(row: r, isName: true))
        XCTAssertTrue(panels[1].cellIsHighlighted(row: r, isName: true))
        let rowView = panels[0].tableView.rowView(atRow: r, makeIfNecessary: false) as? PanelRowView
        XCTAssertEqual(rowView?.drawsHighlight, false, "the inactive panel's row view draws no fill")
        window.makeFirstResponder(panels[1].pathCombo)
        XCTAssertFalse(panels[1].listHasKeyboardFocus, "the address bar has the focus")
    }

    // MARK: - the drop target

    func testDropTargetRowIsHighlightedAndReadable() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        panel.listFocusOverride = false
        select(panel, [], focus: nil)
        let r = row(panel, "sub")
        guard let rowView = panel.tableView.rowView(atRow: r, makeIfNecessary: false) as? PanelRowView,
              let cell = panel.tableView.view(atColumn: 0, row: r, makeIfNecessary: false) as? NSTableCellView,
              let field = cell.textField else { return XCTFail("no row view") }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            rowView.isTargetForDropOperation = true
            var rect = field.convert(field.bounds, to: panel.tableView)
            rect.size.width = min(rect.width, field.intrinsicContentSize.width)
            let m = ContrastProbe.measure(panel.tableView, rect)
            XCTAssertTrue(m?.background.isClose(to: .highlight) == true, "\(String(describing: m))")
            XCTAssertGreaterThanOrEqual(m?.ratio ?? 0, 4.5)
            rowView.isTargetForDropOperation = false
        }
        panel.listFocusOverride = nil
    }

    // MARK: - every other list in the app

    /// The dialogs' own tables (ListViewDialog, checksum results, Messages, Options pages, the
    /// temporary-files list): a selected row, emphasized (key window) and not, Light and Dark.
    func testDialogListsAreReadableWhenSelected() throws {
        continueAfterFailure = true
        var properties = ListViewDialogOptions()
        properties.title = "Properties"
        properties.strings = ["Path", "Size", "Modified"]
        properties.values = ["/tmp/test.7z", "838", "2026-09-12 10:00:00"]
        properties.numColumns = 2
        properties.selectFirst = true
        var history = ListViewDialogOptions()
        history.title = "Folders History"
        history.strings = ["/tmp", "/Users", "/Applications"]
        try SZCodecs.loadCodecs()
        let fixtures = (TestPaths.fixture("test.7z") as NSString).deletingLastPathComponent
        let results = try SZHasher.hash(paths: ["test.7z"], relativeTo: fixtures, methods: ["CRC32", "SHA256"],
                                        recursive: false, progress: nil)
        let dialogs: [(String, () -> Void)] = [
            ("Properties", { _ = ListViewDialog.run(properties, parent: nil) }),
            ("Folders History", { _ = ListViewDialog.run(history, parent: nil) }),
            ("Checksum", { HashResultsDialog.show(results: results, parent: nil) }),
            ("Messages", { MessagesDialog.show(messages: ["a.7z : Data error", "b : CRC failed"], parent: nil) }),
        ]
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for (name, present) in dialogs {
                let shown = ModalProbe.present(present) { window in
                    self.auditTables(in: window, "\(name) \(self.appearanceName(dark))")
                }
                XCTAssertTrue(shown, "\(name) never came up")
            }
            let options = OptionsWindowController.shared
            if let window = options.window {
                XCTAssertTrue(ModalProbe.present({ OptionsWindowController.showOptions() }) { _ in })
                if let tabs = Self.firstTabView(in: window.contentView) {
                    for item in tabs.tabViewItems {
                        tabs.selectTabViewItem(item)
                        window.contentView?.layoutSubtreeIfNeeded()
                        auditTables(in: window, "Options \(item.label) \(appearanceName(dark))")
                    }
                    tabs.selectTabViewItem(at: 0)
                }
                ModalProbe.close(window)
            }
        }
    }

    private static func firstTabView(in view: NSView?) -> NSTabView? {
        guard let view else { return nil }
        if let tabs = view as? NSTabView { return tabs }
        for child in view.subviews { if let found = firstTabView(in: child) { return found } }
        return nil
    }

    private func tables(in view: NSView) -> [NSTableView] {
        ((view as? NSTableView).map { [$0] } ?? []) + view.subviews.flatMap(tables(in:))
    }

    /// Mark each of the first rows of every visible table selected, emphasized and not, and
    /// measure every text field and checkbox title in it. The row view is marked directly rather
    /// than through the table's selection, so no delegate acts on it (the Language page would
    /// switch the app's language).
    private func auditTables(in window: NSWindow, _ name: String) {
        guard let content = window.contentView else { return }
        for table in tables(in: content) where !table.isHiddenOrHasHiddenAncestor && table.numberOfRows > 0 {
            var measured = 0, onAccent = 0
            for r in 0..<min(table.numberOfRows, 3) {
                table.scrollRowToVisible(r)
                guard let rowView = table.rowView(atRow: r, makeIfNecessary: true) else { continue }
                let (wasSelected, wasEmphasized) = (rowView.isSelected, rowView.isEmphasized)
                for emphasized in [true, false] {
                    rowView.isSelected = true
                    rowView.isEmphasized = emphasized
                    window.layoutIfNeeded()
                    window.displayIfNeeded()
                    for c in 0..<table.numberOfColumns {
                        guard let cell = table.view(atColumn: c, row: r, makeIfNecessary: true) else { continue }
                        for control in controls(in: cell) {
                            let text = (control as? NSTextField)?.stringValue ?? (control as? NSButton)?.title ?? ""
                            guard !text.isEmpty, control.frame.width > 1 else { continue }
                            var rect = control.convert(control.bounds, to: table)
                            if let field = control as? NSTextField {
                                rect.size.width = min(rect.width, field.intrinsicContentSize.width)
                            }
                            guard let m = ContrastProbe.measure(table, rect) else { continue }
                            if emphasized {           // the emphasized selection is the accent colour
                                measured += 1
                                if m.background.b > m.background.r + 60 { onAccent += 1 }
                            }
                            XCTAssertGreaterThanOrEqual(m.ratio, 4.5,
                                "\(name) row \(r) '\(text)' \(emphasized ? "emphasized" : "unemphasized"): \(m.text) on \(m.background)")
                        }
                    }
                }
                rowView.isSelected = wasSelected
                rowView.isEmphasized = wasEmphasized
            }
            // The audit really saw selected rows: on a table that draws selection, the text sat on
            // the accent fill (a table with no selection style draws none and is skipped).
            if table.selectionHighlightStyle != .none, measured > 0 {
                XCTAssertGreaterThan(onAccent, 0, "\(name): no selected text was measured on the selection fill")
            }
        }
    }

    private func controls(in view: NSView) -> [NSControl] {
        ((view as? NSTextField).map { [$0] } ?? []) + ((view as? NSButton).map { [$0] } ?? [])
            + view.subviews.flatMap(controls(in:))
    }

    // MARK: - paired captures with 7zFM

    /// The Mac half of `wincompare-selection-<state>-*.png`, light appearance, list area at 1x.
    func testPairedSelectionCaptures() throws {
        NSApp.appearance = NSAppearance(named: .aqua)
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        let states: [(String, Bool, Bool, Int, [String], String, Bool)] = [
            // name, fullRow, grid, mode, selected, focus, focused
            ("details-multi", false, false, 3, ["a.txt", "c.txt"], "c.txt", true),
            ("details-multi-fullrow", true, false, 3, ["a.txt", "c.txt"], "c.txt", true),
            ("details-multi-fullrow-grid", true, true, 3, ["a.txt", "c.txt"], "c.txt", true),
            ("details-focusonly", false, false, 3, [], "b.bin", true),
            ("details-focusonly-fullrow", true, false, 3, [], "b.bin", true),
            ("details-unfocused", false, false, 3, ["a.txt", "c.txt"], "c.txt", false),
            ("large-multi", false, false, 0, ["a.txt", "c.txt"], "a.txt", true),
            ("list-multi", false, false, 2, ["a.txt", "c.txt"], "a.txt", true),
        ]
        for (name, fullRow, grid, mode, selection, focus, focused) in states {
            Settings.fullRow = fullRow
            Settings.showGrid = grid
            panel.applyListSettings()
            XCTAssertTrue(wait(for: "reload") { panel.rows.count == 5 })
            if panel.listViewMode != mode { panel.setListViewMode(mode) }
            if mode != 3 {
                XCTAssertTrue(wait(for: "icon items") {
                    controller.window?.contentView?.layoutSubtreeIfNeeded()
                    return panel.iconView.collectionView.visibleItems().count == 5
                })
            }
            panel.listFocusOverride = focused
            select(panel, selection, focus: focus)
            capture(panel, "wincompare-selection-\(name)-mac.png")
        }
        panel.listFocusOverride = nil
        panel.setListViewMode(3)
    }

    /// The panel's list (header and the first rows), 760 x 140 pt at 1x, like the Windows crops.
    private func capture(_ panel: PanelViewController, _ file: String) {
        guard let window = panel.view.window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let list: NSView = panel.listViewMode == 3 ? (panel.tableView.enclosingScrollView ?? panel.tableView)
                                                   : panel.iconView
        var rect = list.convert(list.bounds, to: content)
        rect = NSRect(x: rect.minX, y: rect.maxY - 140, width: min(760, rect.width), height: 140)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(rect.width), pixelsHigh: Int(rect.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = rect.size
        content.cacheDisplay(in: rect, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = file
        attachment.lifetime = .keepAlways
        add(attachment)
        try? png.write(to: URL(fileURLWithPath: TestPaths.screenshots).appendingPathComponent(file), options: .atomic)
    }
}

private final class FillView: NSView {
    let color: NSColor
    init(frame: NSRect, color: NSColor) { self.color = color; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); bounds.fill() }
}
