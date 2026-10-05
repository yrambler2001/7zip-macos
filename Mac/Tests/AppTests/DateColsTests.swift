// DateColsTests.swift -- the datecols scope (reports/datecols.md): with SF Pro 12.2 every Details
// column starts wide enough for the widest value of its kind -- a date at the View > Time level in
// force (with the "Z" of UTC), "9 999 999 999 999" in a size column -- checked on the real list
// cells, drawn, not on a measured string; the status bar's time is 7zFM's (seconds, local time,
// "Z" only with View > Time > UTC) and its size parts hold the widest size.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class DateColsTests: AppHostTestCase {

    override var screenshotPrefix: String { "datecols" }

    private var controllers: [MainWindowController] = []
    private var scratchRoot: String?
    private var saved: (panels: Int, path: String?, mode: Int, level: Int, utc: Bool) = (1, nil, 3, -1, false)

    /// The View > Time levels (g_App._timestampLevels) and the widest date each prints.
    private static let levels: [SZTimestampLevel] = [.day, .min, .sec, .NTFS, .NS]

    override func setUpWithError() throws {
        try super.setUpWithError()
        saved = (Settings.numPanels, Settings.panelPath(0), Settings.listMode(0),
                 Settings.timestampLevel, Settings.timestampShowUTC)
        Settings.timestampLevel = Int(SZTimestampLevel.min.rawValue)
        Settings.timestampShowUTC = false
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() {
        for controller in controllers { controller.window?.close() }
        controllers = []
        if let scratchRoot { try? FileManager.default.removeItem(atPath: scratchRoot) }
        Settings.numPanels = saved.panels
        Settings.setPanelPath(saved.path, 0)
        Settings.setListMode(saved.mode, 0)
        Settings.timestampLevel = saved.level
        Settings.timestampShowUTC = saved.utc
        Settings.removeKey("FM.Columns.FSFolder")
        Settings.removeKey("FM.Columns.7-Zip.7z")
        NSApp.appearance = nil
        super.tearDown()
    }

    // MARK: - 1. every default-width cell holds the widest value of its kind

    /// For each View > Time level, local and UTC: every column of a fresh file-system list and of a
    /// 7z archive starts at its default width (time: the level's date; size: 9.99 TB; else 100),
    /// every real cell (the folder's own values) is drawn whole, and so is each time / size cell
    /// given the widest value of its kind: "2024-12-31 23:59:59.123456789Z" at NS + UTC,
    /// "9 999 999 999 999" in Size and Packed Size.
    func testEveryDefaultWidthCellShowsTheWidestValueWhole() throws {
        let fixture = makeFixture()
        try FileManager.default.copyItem(atPath: TestPaths.fixture("test.7z"), toPath: fixture + "/test.7z")
        let (controller, panel) = try openPanel(on: fixture)
        var checkedTime = 0, checkedSize = 0
        for path in [fixture, fixture + "/test.7z"] {
            navigate(panel, to: path)
            for utc in [false, true] {
                for level in Self.levels {
                    setTime(controller, panel, level: level, utc: utc)
                    let (t, s) = try checkCells(panel, level: level, utc: utc, where: path)
                    checkedTime += t
                    checkedSize += s
                }
            }
        }
        XCTAssertGreaterThan(checkedTime, 25, "time cells checked")
        XCTAssertGreaterThan(checkedSize, 10, "size cells checked")
    }

    /// The width check itself sees a cut: a time cell 1 pt too narrow for its date draws an ellipsis.
    func testTheCheckSeesATruncatedCell() throws {
        let (_, panel) = try openPanel(on: makeFixture())
        let table = panel.tableView
        let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(String(SZPropID.mtime.rawValue)))
        XCTAssertGreaterThanOrEqual(index, 0)
        let cell = try XCTUnwrap(table.view(atColumn: index, row: 0, makeIfNecessary: true) as? NSTableCellView)
        let field = try XCTUnwrap(cell.textField)
        cell.layoutSubtreeIfNeeded()
        XCTAssertTrue(Self.isDrawnWhole(field), "'\(field.stringValue)' at the default width")
        // The text field ends at the column's edge (6 pt in from the left): one point short of the date.
        let needed = ceil(field.attributedStringValue.size().width)
        table.tableColumns[index].width = PanelMetrics.subitemPadding + needed - 1
        table.layoutSubtreeIfNeeded()
        cell.layoutSubtreeIfNeeded()
        XCTAssertFalse(Self.isDrawnWhole(field), "'\(field.stringValue)' 1 pt too narrow must be cut (\(field.frame.width) pt)")
    }

    // MARK: - 2. the status bar

    /// OnRefreshStatusBar (PanelListNotify.cpp:800-822): the fourth part is the focused item's
    /// kpidMTime by ConvertPropertyToShortString2 at its default level 0 -- seconds, whatever the
    /// list shows -- in local time; "Z" only with View > Time > UTC (g_Timestamp_Show_UTC).
    func testStatusBarShowsTheTimeWithSecondsInLocalTime() throws {
        let (controller, panel) = try openPanel(on: makeFixture())
        let row = try select(panel, "backup.7z")
        let date = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: row.fullPath)[.modificationDate] as? Date)
        XCTAssertEqual(row.cells[.mtime], TimeMenuDelegate.format(date, level: -1, utc: false), "the list: minutes")
        XCTAssertEqual(panel.statusBarTexts[3], TimeMenuDelegate.format(date, level: 0, utc: false),
                       "the status bar: seconds, local time, no Z")
        XCTAssertFalse(panel.statusBarTexts[3].hasSuffix("Z"))

        setTime(controller, panel, level: .min, utc: true)
        let utcRow = try select(panel, "backup.7z")
        XCTAssertEqual(utcRow.cells[.mtime], TimeMenuDelegate.format(date, level: -1, utc: true) + "Z")
        XCTAssertEqual(panel.statusBarTexts[3], TimeMenuDelegate.format(date, level: 0, utc: true) + "Z")

        setTime(controller, panel, level: .day, utc: false)
        _ = try select(panel, "backup.7z")
        XCTAssertEqual(panel.statusBarTexts[3], TimeMenuDelegate.format(date, level: 0, utc: false),
                       "the status bar keeps seconds at the day level")
    }

    /// The status bar's parts: both size parts hold "9 999 999 999 999", the time part the widest
    /// status date with its "Z", drawn whole; part 0 still ends at Windows' 220.
    func testStatusBarPartsHoldTheWidestValues() throws {
        let (_, panel) = try openPanel(on: makeFixture())
        let edges = PanelViewController.statusSectionEdges
        XCTAssertEqual(edges[0], 220)
        XCTAssertGreaterThanOrEqual(edges[1] - edges[0], 100)
        XCTAssertEqual(edges[1] - edges[0], edges[2] - edges[1])
        let texts = [PanelMetrics.widestSize, PanelMetrics.widestSize,
                     PanelMetrics.widestDate(level: .sec, utc: true)]
        for (field, text) in zip(panel.statusSections, texts) {
            field.stringValue = text
        }
        panel.view.layoutSubtreeIfNeeded()
        for field in panel.statusSections {
            XCTAssertTrue(Self.isDrawnWhole(field), "status part '\(field.stringValue)' is cut (\(field.frame.width) pt)")
        }
    }

    // MARK: - 3. View > Time

    /// g_Timestamp_Show_UTC follows the setting, whoever sets it (a test that restored the setting
    /// but not the engine's global left every later list in UTC: sffont-main.png's "21:58Z").
    func testTheUTCSettingDrivesTheEngine() {
        Settings.timestampShowUTC = true
        XCTAssertTrue(SZFolder.timestampShowUTC)
        Settings.timestampShowUTC = false
        XCTAssertFalse(SZFolder.timestampShowUTC)
    }

    /// A time column at the default width follows View > Time; one the user resized keeps its width.
    func testTimeColumnsFollowTheLevelButKeepAUserWidth() throws {
        let (controller, panel) = try openPanel(on: makeFixture())
        let modified = try column(panel, .mtime), created = try column(panel, .ctime)
        XCTAssertEqual(Int(modified.width), PanelMetrics.timeColumnWidth(level: .min, utc: false))
        created.width = 170
        panel.saveColumnLayout()
        setTime(controller, panel, level: .sec, utc: false)
        XCTAssertEqual(Int(modified.width), PanelMetrics.timeColumnWidth(level: .sec, utc: false))
        XCTAssertEqual(created.width, 170)
        setTime(controller, panel, level: .sec, utc: true)
        XCTAssertEqual(Int(modified.width), PanelMetrics.timeColumnWidth(level: .sec, utc: true))
        setTime(controller, panel, level: .min, utc: false)
        XCTAssertEqual(Int(modified.width), PanelMetrics.timeColumnWidth(level: .min, utc: false))
        XCTAssertEqual(created.width, 170)
        // A stored layout at another level's default (or the old 100) loads at today's default;
        // a width the user chose loads as it is. (Written here: every open panel showing a
        // file-system folder -- the host app's own window too -- saves FM.Columns.FSFolder.)
        var layout = try XCTUnwrap(Settings.columnLayout(forFolderType: "FSFolder"))
        for i in layout.columns.indices {
            if layout.columns[i].propID == Int(SZPropID.mtime.rawValue) {
                layout.columns[i].width = PanelMetrics.timeColumnWidth(level: .NS, utc: true)
            } else if layout.columns[i].propID == Int(SZPropID.ctime.rawValue) {
                layout.columns[i].width = 170
            } else if layout.columns[i].propID == Int(SZPropID.atime.rawValue) {
                layout.columns[i].width = 100
            }
        }
        Settings.setColumnLayout(layout, forFolderType: "FSFolder")
        let (_, again) = try openPanel(on: makeFixture(), keepLayout: true)
        XCTAssertEqual(Int(try column(again, .mtime).width), PanelMetrics.timeColumnWidth(level: .min, utc: false))
        XCTAssertEqual(try column(again, .ctime).width, 170)
        XCTAssertEqual(again.columnsModel.columns.first { $0.propID == .atime }?.width,
                       PanelMetrics.timeColumnWidth(level: .min, utc: false), "a hidden Accessed at the old 100")
    }

    // MARK: - 4. headers

    /// SysHeader32 draws in the list's font: the main list's "Modified" is SF Pro 12.2 wide on
    /// screen (50 pt), not the 11 pt NSTableHeaderCell draws whatever its `font` says (45.8 pt);
    /// the Options and temp-files lists' headers use the same cell.
    func testHeadersDrawInTheListFont() throws {
        let (_, panel) = try openPanel(on: makeFixture())
        let header = try XCTUnwrap(panel.tableView.headerView)
        let index = panel.tableView.column(withIdentifier: NSUserInterfaceItemIdentifier(String(SZPropID.mtime.rawValue)))
        let rect = header.headerRect(ofColumn: index)
        let rep = try XCTUnwrap(header.bitmapImageRepForCachingDisplay(in: rect))
        header.cacheDisplay(in: rect, to: rep)
        var minX = Int.max, maxX = -1
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), c.alphaComponent > 0.5,
                      c.brightnessComponent < 0.5 else { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        XCTAssertGreaterThan(maxX, minX, "the header title has ink")
        let ink = CGFloat(maxX - minX + 1) * rect.width / CGFloat(rep.pixelsWide)
        let title = try column(panel, .mtime).title
        let inFont = (title as NSString).size(withAttributes: [.font: PanelMetrics.listFont]).width
        let small = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
        XCTAssertGreaterThan(ink, small + 1.5, "'\(title)' ink \(ink) pt: drawn in 11 pt, not the list font (\(inFont))")
        XCTAssertLessThanOrEqual(ink, inFont + 1, "'\(title)' ink \(ink) pt")
        let options = OptionsUI.column("t", "Type", width: 80)
        XCTAssertTrue(options.headerCell is WinHeaderCell, "Options list headers draw in the list font")
    }

    // MARK: - checks

    /// Checks every visible column of `panel` at the current level; returns the number of time and
    /// size cells checked with their widest value.
    private func checkCells(_ panel: PanelViewController, level: SZTimestampLevel, utc: Bool,
                            where path: String) throws -> (Int, Int) {
        let table = panel.tableView
        let what = "\((path as NSString).lastPathComponent), level \(level.rawValue)\(utc ? " UTC" : "")"
        let rowCount = min(table.numberOfRows, 12)
        XCTAssertGreaterThan(rowCount, 0, what)
        var time = 0, size = 0
        for column in panel.columnsModel.visibleColumns where !column.isName {
            let index = table.column(withIdentifier: NSUserInterfaceItemIdentifier(String(column.propID.rawValue)))
            guard index >= 0 else { continue }
            let tableColumn = table.tableColumns[index]
            let isTime = column.varType == .fileTime
            let isSize = Formatting.sizePropIDs.contains(column.propID)
            let expected = isTime ? PanelMetrics.timeColumnWidth(level: level, utc: utc)
                : isSize ? PanelMetrics.sizeColumnWidth : PanelColumnsModel.otherWidth
            XCTAssertEqual(Int(tableColumn.width), expected, "\(what): \(column.title) default width")
            for row in 0..<rowCount {
                guard let cell = table.view(atColumn: index, row: row, makeIfNecessary: true) as? NSTableCellView,
                      let field = cell.textField else { continue }
                cell.layoutSubtreeIfNeeded()
                if !field.stringValue.isEmpty {
                    XCTAssertTrue(Self.isDrawnWhole(field),
                                  "\(what): \(column.title) row \(row) '\(field.stringValue)' is cut (\(field.frame.width) pt)")
                }
                guard row == 0, isTime || isSize else { continue }
                let real = field.stringValue
                field.stringValue = isTime ? Self.widestEngineDate(level: level, utc: utc) : PanelMetrics.widestSize
                cell.layoutSubtreeIfNeeded()
                XCTAssertTrue(Self.isDrawnWhole(field),
                              "\(what): \(column.title) '\(field.stringValue)' is cut at the default width (\(field.frame.width) pt)")
                field.stringValue = real
                if isTime { time += 1 } else { size += 1 }
            }
        }
        return (time, size)
    }

    /// 2024-12-31 23:59:59.123456789 as ConvertUtcFileTimeToString2 prints it at `level`
    /// (DateFormatter, independent of `PanelMetrics.widestDate`), "Z" appended for UTC.
    private static func widestEngineDate(level: SZTimestampLevel, utc: Bool) -> String {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second, c.nanosecond) = (2024, 12, 31, 23, 59, 59, 123_456_789)
        c.timeZone = TimeZone(secondsFromGMT: utc ? 0 : TimeZone.current.secondsFromGMT())
        let date = Calendar(identifier: .gregorian).date(from: c) ?? Date()
        return TimeMenuDelegate.format(date, level: Int(level.rawValue), utc: utc) + (utc ? "Z" : "")
    }

    /// Draws `field` as it is, and a copy of it that clips instead of truncating: the two bitmaps
    /// are the same only when the field shows its whole text (no ellipsis).
    static func isDrawnWhole(_ field: NSTextField) -> Bool {
        if let cell = field.cell, cell.expansionFrame(withFrame: field.bounds, in: field) != .zero { return false }
        let copy = NSTextField(labelWithString: field.stringValue)
        copy.font = field.font
        copy.alignment = field.alignment
        copy.textColor = field.textColor
        copy.baseWritingDirection = field.baseWritingDirection
        copy.lineBreakMode = .byClipping
        copy.cell?.truncatesLastVisibleLine = false
        copy.usesSingleLineMode = true
        copy.frame = NSRect(origin: .zero, size: field.bounds.size)
        copy.appearance = field.effectiveAppearance
        guard let a = bitmap(field), let b = bitmap(copy), a.count == b.count else { return false }
        return a == b
    }

    private static func bitmap(_ view: NSView) -> Data? {
        guard view.bounds.width >= 1, view.bounds.height >= 1,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let bytes = rep.bitmapData else { return nil }
        return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    // MARK: - helpers

    private func setTime(_ controller: MainWindowController, _ panel: PanelViewController,
                         level: SZTimestampLevel, utc: Bool) {
        if Settings.timestampShowUTC != utc { controller.viewTimeUTC(nil) }       // IDM_VIEW_TIME_UTC 799
        let item = NSMenuItem()
        item.representedObject = Int(level.rawValue)
        controller.viewTimestampLevel(item)                                       // IDM_VIEW_TIME + k
        // The engine prints at most the item's own precision (ConvertPropertyToShortString2): 7
        // digits for a 100 ns time at the NS level, so 7..9 there.
        let length = PanelMetrics.widestDate(level: level, utc: utc).count
        let lengths = level == .NS ? (length - 2)...length : length...length
        var seen = ""
        XCTAssertTrue(wait(for: "dates at level \(level.rawValue)") {
            guard let text = panel.rows.first(where: { !$0.isParentRow && !($0.cells[.mtime] ?? "").isEmpty })?.cells[.mtime]
            else { return false }
            seen = text
            return lengths.contains(text.count) && Int(panel.tableView.tableColumns.first {
                PanelViewController.propID(of: $0) == .mtime }?.width ?? 0) == PanelMetrics.timeColumnWidth(level: level, utc: utc)
        }, "level \(level.rawValue) utc \(utc): '\(seen)', Modified \(Int(panel.tableView.tableColumns.first { PanelViewController.propID(of: $0) == .mtime }?.width ?? 0))")
        panel.view.window?.contentView?.layoutSubtreeIfNeeded()
        panel.view.window?.contentView?.displayIfNeeded()
    }

    private func select(_ panel: PanelViewController, _ name: String) throws -> PanelRow {
        let index = try XCTUnwrap(panel.rows.firstIndex { $0.name == name })
        panel.tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        panel.focusedIndex = index
        panel.refreshStatusBar()
        return panel.rows[index]
    }

    private func column(_ panel: PanelViewController, _ pid: SZPropID) throws -> NSTableColumn {
        try XCTUnwrap(panel.tableView.tableColumns.first { PanelViewController.propID(of: $0) == pid })
    }

    private func navigate(_ panel: PanelViewController, to path: String) {
        var done = false
        panel.navigate(to: path) { _ in done = true }
        XCTAssertTrue(wait(for: "panel bound to \(path)") { done })
        panel.view.window?.contentView?.layoutSubtreeIfNeeded()
        panel.view.window?.contentView?.displayIfNeeded()
    }

    private func makeFixture() -> String {
        let root = scratchRoot ?? (TestPaths.artifacts as NSString).appendingPathComponent("datecols-\(UUID().uuidString)")
        scratchRoot = root
        let path = root + "/" + UUID().uuidString + "/Documents"
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/Projects", withIntermediateDirectories: true)
        let files: [(String, Int)] = [("backup.7z", 1_482_331), ("photos.zip", 25_731_040), ("notes.txt", 1_234),
                                      ("disk image.iso", 734_003), ("readme.md", 2_048)]
        for (name, size) in files { fm.createFile(atPath: path + "/" + name, contents: Data(count: size)) }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (2024, 11, 28, 22, 58, 31)
        if let date = Calendar.current.date(from: c) {
            for name in ((try? fm.contentsOfDirectory(atPath: path)) ?? []) + [""] {
                try? fm.setAttributes([.modificationDate: date, .creationDate: date],
                                      ofItemAtPath: name.isEmpty ? path : path + "/" + name)
            }
        }
        return path
    }

    private func openPanel(on folder: String, keepLayout: Bool = false) throws -> (MainWindowController, PanelViewController) {
        Settings.numPanels = 1
        Settings.setListMode(3, 0)
        if !keepLayout {
            Settings.removeKey("FM.Columns.FSFolder")
            Settings.removeKey("FM.Columns.7-Zip.7z")
        }
        let controller = MainWindowController()
        controllers.append(controller)
        controller.window?.setContentSize(NSSize(width: 1100, height: 420))
        controller.showWindow(nil)
        let panel = controller.focusedPanel
        navigate(panel, to: folder)
        controller.window?.makeFirstResponder(panel.tableView)
        XCTAssertTrue(wait(for: "rows") { panel.tableView.numberOfRows == panel.rows.count && panel.rows.count >= 5 })
        return (controller, panel)
    }
}
