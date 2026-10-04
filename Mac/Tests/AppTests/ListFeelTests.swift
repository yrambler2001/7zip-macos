// ListFeelTests.swift -- the main list's look and feel against fresh-default 7zFM 26.03 on
// Windows 11 at 96 dpi (Mac/docs/reports/listfeel.md; the Windows numbers come from
// listfeel-data/win1/*.geom.txt, dlg-prop-*.txt and pixel measurements of the captures):
// row pitch, header height, icon and text placement, the selection fill's padding, default column
// widths, tabular digits, no sort arrow, the column menu's order, the rubber-band hit zones, the
// address drop-down, Properties routing (Finder Get Info outside an archive) and its rows, the
// toolbar's pressed offset, and the fresh one-panel default.
//
// Also writes the Mac half of the paired captures `screenshots/wincompare-listfeel-*-mac.png`.

import AppKit
import SevenZipKit
import XCTest
@testable import SevenZipAppHost

final class ListFeelTests: AppHostTestCase {

    override var screenshotPrefix: String { "listfeel" }

    private var controllers: [MainWindowController] = []
    private var scratchDirectories: [String] = []
    private var savedNumPanels = 1
    private var savedPanelPaths: [String?] = []
    private var savedFullRow = false
    private var savedListModes: [Int] = []
    private var savedAppearance: NSAppearance?
    private var savedSender: (([URL], @escaping (FinderInfo.Outcome) -> Void) -> Void)?

    override func setUpWithError() throws {
        try super.setUpWithError()
        savedNumPanels = Settings.numPanels
        savedPanelPaths = [Settings.panelPath(0), Settings.panelPath(1)]
        savedFullRow = Settings.fullRow
        savedListModes = [Settings.listMode(0), Settings.listMode(1)]
        savedAppearance = NSApp.appearance
        savedSender = FinderInfo.sender
        NSApp.appearance = NSAppearance(named: .aqua)
        Settings.fullRow = false
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
        NSApp.appearance = savedAppearance
        if let savedSender { FinderInfo.sender = savedSender }
        super.tearDown()
    }

    // MARK: helpers

    /// The Windows fixture folder's plain files (wincompare's `cmp`, same names and sizes) plus the
    /// test archives.
    private func makeScratch() -> String {
        let path = (TestPaths.artifacts as NSString).appendingPathComponent("listfeel-\(UUID().uuidString)")
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path + "/cmp/sub", withIntermediateDirectories: true)
        for (name, size) in [("a.txt", 1234), ("b.bin", 100_000), ("empty.txt", 0), ("notes.md", 20)] {
            fm.createFile(atPath: path + "/cmp/" + name, contents: Data(repeating: 0x61, count: size))
        }
        fm.createFile(atPath: path + "/cmp/sub/c.txt", contents: Data(repeating: 0x30, count: 10))
        for name in ["test.7z", "test.zip"] {
            try? fm.copyItem(atPath: TestPaths.fixture(name), toPath: path + "/cmp/" + name)
        }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2024, 1, 15, 10, 30)
        if let date = Calendar.current.date(from: c) {
            for name in (try? fm.contentsOfDirectory(atPath: path + "/cmp")) ?? [] {
                try? fm.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: path + "/cmp/" + name)
            }
        }
        scratchDirectories.append(path)
        return path + "/cmp"
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
        panel.view.window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func row(_ panel: PanelViewController, _ name: String) -> Int {
        panel.rows.firstIndex { $0.displayName == name } ?? -1
    }

    private func select(_ panel: PanelViewController, _ names: [String], focus: String?) {
        panel.tableView.selectRowIndexes(IndexSet(names.map { row(panel, $0) }.filter { $0 >= 0 }), byExtendingSelection: false)
        if let focus { panel.focusedIndex = row(panel, focus) }
        panel.refreshSelectionAppearance()
        panel.view.window?.contentView?.layoutSubtreeIfNeeded()
    }

    /// `rect` (table coordinates) rendered at 2x into sRGB; pixel (x, y) in points from its top-left.
    private struct Render {
        let rep: NSBitmapImageRep
        let rect: NSRect
        /// Premultiplied sRGB bytes, composited over white (the list's background).
        func rgb(_ x: Int, _ y: Int) -> RGB {
            guard let data = rep.bitmapData, x >= 0, y >= 0, x < rep.pixelsWide, y < rep.pixelsHigh else { return .white }
            let p = data + y * rep.bytesPerRow + x * 4
            let a = Int(p[3])
            return RGB(r: Int(p[0]) + 255 - a, g: Int(p[1]) + 255 - a, b: Int(p[2]) + 255 - a)
        }
        /// Bounding box (points, relative to `rect`'s top-left) of the pixels matching `test`.
        func bbox(_ test: (RGB) -> Bool) -> NSRect? {
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide where test(rgb(x, y)) {
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            guard maxX >= 0 else { return nil }
            return NSRect(x: CGFloat(minX) / 2, y: CGFloat(minY) / 2,
                          width: CGFloat(maxX - minX + 1) / 2, height: CGFloat(maxY - minY + 1) / 2)
        }
    }

    private func render(_ table: NSTableView, _ rect: NSRect) -> Render? {
        let area = rect.integral
        guard let raw = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(area.width) * 2,
                                         pixelsHigh: Int(area.height) * 2, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 32),
              let rep = raw.retagging(with: .sRGB) else { return nil }
        rep.size = area.size
        table.cacheDisplay(in: area, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: TestPaths.artifacts)
                .appendingPathComponent("listfeel-render-\(Int(area.minX))-\(Int(area.minY)).png"))
        }
        return Render(rep: rep, rect: area)
    }

    private static func isInk(_ p: RGB) -> Bool { (p.r + p.g + p.b) / 3 < 140 }

    // MARK: - 1. rows, header, cells

    /// 19 pt rows with no gap, a 24 pt header, the list font with Segoe UI 9 pt metrics.
    func testRowPitchHeaderAndFont() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        let table = panel.tableView
        XCTAssertEqual(table.rect(ofRow: 1).minY - table.rect(ofRow: 0).minY, 19, "LVIR_BOUNDS height 19 px")
        XCTAssertEqual(table.rect(ofRow: 0).height, 19)
        XCTAssertEqual(table.intercellSpacing, .zero)
        XCTAssertEqual(table.headerView?.frame.height, 24, "SysHeader32 24 px")
        let font = PanelMetrics.listFont
        // Segoe UI 9 pt advance widths, measured on the PC (LVM_GETSTRINGWIDTH / pixel ink).
        XCTAssertEqual(PanelMetrics.textWidth("a.txt"), 22, accuracy: 1)
        XCTAssertEqual(PanelMetrics.textWidth("vol.7z.001"), 51, accuracy: 1)
        XCTAssertEqual(PanelMetrics.textWidth("2024-01-15 11:30"), 89, accuracy: 1)
        // Tabular digits (Segoe UI's are): every digit is as wide as every other.
        let digitWidths = Set((0...9).map { ("\($0)" as NSString).size(withAttributes: [.font: font]).width })
        XCTAssertEqual(digitWidths.count, 1, "tabular digits: \(digitWidths)")
        for c in 0..<table.numberOfColumns {
            XCTAssertNil(table.indicatorImage(in: table.tableColumns[c]), "7zFM draws no sort arrow")
            XCTAssertEqual(table.tableColumns[c].headerCell.font, font)
        }
        XCTAssertNil(table.highlightedTableColumn, "no highlighted column")
    }

    /// The name cell's icon at x 4 (1 pt from the row top), its text 2 pt into the label at x 20,
    /// the other columns' text 6 pt from the edge it is aligned to; ink rows as on Windows
    /// ("b.bin": 5 pt below the row's top to 13).
    func testCellLayoutMatchesTheWindowsList() throws {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        let table = panel.tableView
        let b = row(panel, "b.bin")
        let nameColumn = try XCTUnwrap(table.tableColumns.firstIndex { PanelViewController.propID(of: $0) == .name })
        let sizeColumn = try XCTUnwrap(table.tableColumns.firstIndex { PanelViewController.propID(of: $0) == .size })
        let mtimeColumn = try XCTUnwrap(table.tableColumns.firstIndex { PanelViewController.propID(of: $0) == .mtime })
        let cell = try XCTUnwrap(table.view(atColumn: nameColumn, row: b, makeIfNecessary: true) as? PanelCellView)
        cell.layoutSubtreeIfNeeded()
        let icon = try XCTUnwrap(cell.imageView).convert(cell.imageView!.bounds, to: table)
        let rowRect = table.rect(ofRow: b)
        XCTAssertEqual(icon.minX - table.rect(ofColumn: nameColumn).minX, 4, "LVIR_ICON x 4")
        XCTAssertEqual(icon.width, 16)
        XCTAssertEqual(icon.minY - rowRect.minY, 1, "the icon 1 px from the row top")

        // The ink, rendered: name text from x 22-23, b.bin's 'b' 5 pt from the row top to 13.
        let nameRect = NSRect(x: table.rect(ofColumn: nameColumn).minX + 20, y: rowRect.minY,
                              width: 100, height: rowRect.height)
        let ink = try XCTUnwrap(render(table, nameRect)?.bbox(Self.isInk), "no name ink")
        XCTAssertEqual(ink.minX, 3, accuracy: 1, "Windows: ink 3 px into the label (x 23)")
        XCTAssertEqual(ink.minY, 5, accuracy: 1, "Windows: 'b' ascender 5 px below the row top")
        XCTAssertEqual(ink.maxY, 14, accuracy: 1, "Windows: baseline 14 px below the row top")

        // Size, right-aligned: the ink ends 6 pt before the column's right edge.
        let sizeRect = table.rect(ofColumn: sizeColumn).intersection(rowRect)
        let sizeInk = try XCTUnwrap(render(table, sizeRect)?.bbox(Self.isInk), "no size ink")
        XCTAssertEqual(sizeRect.width - sizeInk.maxX, 6, accuracy: 1.5, "Windows: 6 px right margin")
        // Modified, left-aligned: the ink starts 6 pt into the column, and the whole date fits.
        let timeRect = table.rect(ofColumn: mtimeColumn).intersection(rowRect)
        let timeInk = try XCTUnwrap(render(table, timeRect)?.bbox(Self.isInk), "no date ink")
        XCTAssertEqual(timeInk.minX, 6, accuracy: 1.5, "Windows: 6 px left margin")
        let timeCell = try XCTUnwrap(table.view(atColumn: mtimeColumn, row: b, makeIfNecessary: true) as? NSTableCellView)
        let field = try XCTUnwrap(timeCell.textField)
        XCTAssertLessThanOrEqual(field.intrinsicContentSize.width, field.frame.width + 0.5,
                                 "the date '\(field.stringValue)' is cut in a \(table.tableColumns[mtimeColumn].width) pt column")
    }

    // MARK: - 2. the selection fill

    /// The name's fill: from the label (x 20) to 6 pt after the text, the text 2 pt in -- "a.txt"
    /// is 30 px wide on Windows. White ink starts 3 pt into the fill and ends 6-7 pt before its end.
    func testSelectionFillPaddingMatchesWindows() throws {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        controller.window?.makeFirstResponder(panel.tableView)
        panel.listFocusOverride = true
        defer { panel.listFocusOverride = nil }
        select(panel, ["a.txt"], focus: "b.bin")
        let table = panel.tableView
        let a = row(panel, "a.txt")
        let rowRect = table.rect(ofRow: a)
        let r = try XCTUnwrap(render(table, NSRect(x: 0, y: rowRect.minY, width: 160, height: rowRect.height)))
        let fill = try XCTUnwrap(r.bbox { $0.isClose(to: .highlight) }, "no fill")
        XCTAssertEqual(fill.minX, 20, accuracy: 0.5, "LVIR_LABEL starts at 20")
        XCTAssertEqual(fill.width, 30, accuracy: 1.5, "Windows fills 30 px for a.txt")
        XCTAssertEqual(fill.height, 19, accuracy: 0.5, "the fill is the row's full height")
        // White ink inside the fill only.
        var minX = CGFloat.greatestFiniteMagnitude, maxX: CGFloat = 0
        for y in Int(fill.minY * 2)..<Int(fill.maxY * 2) {
            for x in Int(fill.minX * 2)..<Int(fill.maxX * 2) {
                let p = r.rgb(x, y)
                if p.r > 170 && p.g > 170 && p.b > 200 { minX = min(minX, CGFloat(x) / 2); maxX = max(maxX, CGFloat(x + 1) / 2) }
            }
        }
        XCTAssertEqual(minX - fill.minX, 3, accuracy: 1, "Windows: text ink 3 px after the fill starts")
        // Windows: 6 px of fill after the text's advance (its ink ends at the advance in Segoe UI;
        // Helvetica Neue's 't' has 1-2 pt of right side bearing).
        XCTAssertEqual(fill.maxX - maxX, 7, accuracy: 1.6, "fill after the text ink")
        if let window = controller.window { _ = attach(window, "listfeel-01-selection") }
    }

    // MARK: - 3. columns

    /// GetColumnWidth: Name 160, every other column 100, in a folder and inside archives.
    func testDefaultColumnWidthsAreTheWindowsOnes() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        for (path, type) in [(scratch, "FSFolder"), (scratch + "/test.7z", "7-Zip.7z"), (scratch + "/test.zip", "7-Zip.zip")] {
            Settings.removeKey("FM.Columns." + type)
            navigate(panel, to: path)
            for column in panel.tableView.tableColumns {
                let pid = PanelViewController.propID(of: column)
                XCTAssertEqual(column.width, pid == .name ? 160 : 100, "\(type) \(column.title)")
            }
        }
    }

    /// ShowColumnsContextMenu lists `_columns`: the folder's property order, whatever the header
    /// shows -- 7zFM 26.03's file-system list, then the macOS-only columns (listfeel-data/win1/hdrmenu-fs.txt).
    func testColumnMenuOrder() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        Settings.removeKey("FM.Columns.FSFolder")
        navigate(panel, to: scratch)
        let titles = panel.makeColumnsContextMenu().items.map { $0.title }
        let windows = ["Name", "Size", "Modified", "Created", "Accessed", "Metadata Changed", "Attributes",
                       "Packed Size", "iNode", "Links", "Comment", "Folders", "Files", "Link"]
        XCTAssertEqual(Array(titles.prefix(windows.count)), windows)
        XCTAssertEqual(Array(titles.dropFirst(windows.count)), ["Mode", "User", "Group"], "the macOS-only columns last")
        // A header drag does not reorder the menu.
        panel.tableView.moveColumn(3, toColumn: 1)
        panel.saveColumnLayout()
        XCTAssertEqual(Array(panel.makeColumnsContextMenu().items.map { $0.title }.prefix(windows.count)), windows)
        let archiveMenu = { () -> [String] in
            self.navigate(panel, to: scratch + "/test.7z")
            return panel.makeColumnsContextMenu().items.map { $0.title }
        }()
        XCTAssertEqual(archiveMenu.first, "Name")
        XCTAssertEqual(archiveMenu, panel.columnsModel.menuColumns.map { $0.title })
    }

    // MARK: - 4. rubber band

    /// LVHT_ONITEM, measured with real input on 7zFM: FullRow off -- the icon and the label's fill
    /// are the item, the rest of the name column, the other columns and the space below the rows
    /// are the background; FullRow on -- the whole row up to the last column is the item.
    func testRubberBandHitZones() throws {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        let table = panel.tableView
        let a = row(panel, "a.txt"), b = row(panel, "b.bin")
        let nameColumn = try XCTUnwrap(table.tableColumns.firstIndex { PanelViewController.propID(of: $0) == .name })
        let sizeColumn = try XCTUnwrap(table.tableColumns.firstIndex { PanelViewController.propID(of: $0) == .size })
        let name = table.rect(ofColumn: nameColumn), size = table.rect(ofColumn: sizeColumn)
        let last = table.rect(ofColumn: table.numberOfColumns - 1)
        func point(_ x: CGFloat, _ r: Int) -> NSPoint { NSPoint(x: x, y: table.rect(ofRow: r).midY) }

        Settings.fullRow = false
        XCTAssertTrue(table.isOnItem(point(name.minX + 10, a), row: a), "the icon")
        XCTAssertTrue(table.isOnItem(point(name.minX + 30, a), row: a), "the name's text")
        XCTAssertFalse(table.isOnItem(point(name.minX + 140, a), row: a), "the blank part of the name column")
        XCTAssertFalse(table.isOnItem(point(size.midX, a), row: a), "the Size cell")
        XCTAssertFalse(table.isOnItem(point(last.maxX + 20, a), row: a), "right of the last column")
        XCTAssertFalse(table.isOnItem(NSPoint(x: 30, y: table.rect(ofRow: panel.rows.count - 1).maxY + 40), row: -1), "below the rows")
        // The marquee selects by the item area: over Size / Modified nothing, over the names those rows.
        let rows = table.rect(ofRow: a).union(table.rect(ofRow: b))
        XCTAssertEqual(table.rowsHit(by: NSRect(x: size.minX + 10, y: rows.minY, width: 150, height: rows.height)), [])
        XCTAssertEqual(table.rowsHit(by: NSRect(x: name.minX + 10, y: rows.minY, width: 20, height: rows.height)),
                       IndexSet(min(a, b)...max(a, b)))

        Settings.fullRow = true
        XCTAssertTrue(table.isOnItem(point(size.midX, a), row: a), "FullRow: the Size cell is the item")
        XCTAssertTrue(table.isOnItem(point(name.minX + 140, a), row: a))
        XCTAssertFalse(table.isOnItem(point(last.maxX + 20, a), row: a), "FullRow: right of the columns is background")
        XCTAssertEqual(table.rowsHit(by: NSRect(x: last.maxX - 30, y: rows.minY, width: 80, height: rows.height)),
                       IndexSet(min(a, b)...max(a, b)), "FullRow: the rows the band crosses")
    }

    // MARK: - 5. address bar

    /// CBN_DROPDOWN's list: the path's components by name, indented, then Documents, Computer and
    /// the volumes; a mouse pick binds at once (CBN_SELENDOK), the arrow keys do not.
    func testAddressDropdownEntriesAndCommit() throws {
        let entries = AddressDropdown.entries(currentPath: "/Users/me/arc.7z/sub/", documents: "/Users/me/Documents/",
                                              volumes: ["/", "/Volumes/Data"])
        XCTAssertEqual(entries.map { $0.title }, ["/", "   Users", "      me", "         arc.7z", "            sub",
                                                  "Documents", "Computer", "   /", "   /Volumes/Data"])
        XCTAssertEqual(entries.map { $0.path }, ["/", "/Users/", "/Users/me/", "/Users/me/arc.7z/", "/Users/me/arc.7z/sub/",
                                                 "/Users/me/Documents/", "", "/", "/Volumes/Data/"])
        let mouse = NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: [], timestamp: 0,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                   context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 125)
        XCTAssertTrue(AddressDropdown.isCommitEvent(mouse))
        XCTAssertFalse(AddressDropdown.isCommitEvent(key))
        XCTAssertFalse(AddressDropdown.isCommitEvent(nil))

        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch + "/sub")
        XCTAssertEqual(panel.pathCombo.focusRingType, .none, "no focus ring on the address bar")
        panel.rebuildAddressDropdown()
        let parent = try XCTUnwrap(panel.addressDropdownPaths.firstIndex(of: scratch + "/"), "\(panel.addressDropdownPaths)")
        panel.commitAddressDropdownEntry(at: parent)
        XCTAssertTrue(wait(for: "bound to the picked entry") { panel.currentPath == scratch + "/" })
        XCTAssertTrue(wait(for: "the list has the focus") { controller.window?.firstResponder === panel.tableView })
    }

    // MARK: - 6. Properties

    /// CPanel::Properties: an archive folder gets the list; the file system goes to the system
    /// (Finder Get Info) for the operated items, and nothing happens without one; the root too.
    func testPropertiesRouting() {
        XCTAssertEqual(FinderInfo.route(isArchive: true, isFileSystem: false, isVolumesFolder: false, itemPaths: []), .listDialog)
        XCTAssertEqual(FinderInfo.route(isArchive: false, isFileSystem: true, isVolumesFolder: false, itemPaths: ["/a", "/b"]),
                       .finder([URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]))
        XCTAssertEqual(FinderInfo.route(isArchive: false, isFileSystem: true, isVolumesFolder: false, itemPaths: []), .nothing)
        XCTAssertEqual(FinderInfo.route(isArchive: false, isFileSystem: false, isVolumesFolder: true, itemPaths: ["/"]),
                       .finder([URL(fileURLWithPath: "/")]))
        XCTAssertEqual(FinderInfo.route(isArchive: false, isFileSystem: false, isVolumesFolder: false, itemPaths: ["/x"]), .nothing)
        let many = (0..<30).map { "/f\($0)" }
        if case .finder(let urls) = FinderInfo.route(isArchive: false, isFileSystem: true, isVolumesFolder: false, itemPaths: many) {
            XCTAssertEqual(urls.count, FinderInfo.maxWindows)
        } else { XCTFail("not routed to Finder") }
        XCTAssertFalse(FinderInfo.sendsRealEvents, "no Apple Event may be sent from a test")
        // The object specifier: information window ('iwnd') of the file.
        let spec = FinderInfo.informationWindow(of: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(spec.descriptorType, DescType(typeObjectSpecifier))
        XCTAssertEqual(spec.forKeyword(AEKeyword(keyAEKeyData))?.typeCodeValue, FinderInfo.fourCharCode("iwnd"))
    }

    /// The file system: Finder is asked for the selected items; when it refuses (Automation denied)
    /// the 7-Zip list comes up instead, and when it shows the windows nothing else does.
    func testPropertiesOutsideAnArchiveAskFinderAndFallBack() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch)
        select(panel, ["a.txt", "b.bin"], focus: "b.bin")
        var asked: [URL] = []
        FinderInfo.sender = { urls, done in asked = urls; done(.shown) }
        panel.showProperties()
        XCTAssertEqual(asked.map { $0.lastPathComponent }.sorted(), ["a.txt", "b.bin"])
        XCTAssertNil(NSApp.modalWindow, "Finder showed the windows: no 7-Zip dialog")

        FinderInfo.sender = { urls, done in asked = urls; done(.denied) }
        let appeared = ModalProbe.present({ panel.showProperties() }) { window in
            XCTAssertEqual(window.title, "Properties", "the fallback list")
        }
        XCTAssertTrue(appeared, "no fallback dialog after Finder refused")

        select(panel, [], focus: "b.bin")
        asked = []
        panel.showProperties()
        XCTAssertEqual(panel.lastPropertiesRoute, .nothing, "nothing operated: InvokeSystemCommand returns")
        XCTAssertTrue(asked.isEmpty)
    }

    /// The rows of the list for a file, two files, a folder and nothing inside test.7z, in 7zFM's
    /// structure (listfeel-data/win1/dlg-prop-7z-*.txt): no title rows, "------------------------"
    /// separators, the summary block for several items, the folder's own block, the archive level,
    /// and the two closing separators.
    func testPropertiesRowsFollowPanelMenuCpp() throws {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        navigate(panel, to: scratch + "/test.7z")
        let snapshot = try XCTUnwrap(panel.snapshot)
        func lines(_ names: [String]) -> PanelPropertyLines {
            let indices = names.map { n in panel.rows.first { $0.name == n }!.engineIndex }
            return panel.queue.sync { PanelProperties.build(folder: panel.folder!, itemIndices: indices, snapshot: snapshot, level: .min) }
        }
        let sep = PanelPropertyLines.separator
        let file = lines(["notes.md"])
        XCTAssertEqual(file.names.first, "Name")
        XCTAssertEqual(file.values.first, "notes.md")
        XCTAssertTrue(file.names.contains("Encrypted"), "VT_BOOL false is '-', not dropped: \(file.names)")
        XCTAssertEqual(file.values[file.names.firstIndex(of: "Encrypted")!], "-")
        XCTAssertFalse(file.names.contains { $0.hasPrefix("----Path") }, "no level title rows")
        XCTAssertFalse(file.names.contains("ArcFileName"))
        XCTAssertEqual(Array(file.names.suffix(2)), [sep, sep], "the NonOpen level's two separators")
        let firstSep = try XCTUnwrap(file.names.firstIndex(of: sep))
        XCTAssertEqual(Array(file.names[(firstSep + 1)...].prefix(5)), ["Size", "Packed Size", "Folders", "Files", "CRC"],
                       "IFolderProperties of the archive folder")
        XCTAssertTrue(file.names.contains("Physical Size") && file.names.contains("Headers Size") && file.names.contains("Solid"))

        let two = lines(["notes.md", "readme.txt"])
        XCTAssertEqual(two.names.first, "")
        XCTAssertEqual(two.values.first, "2 object(s) selected")
        XCTAssertEqual(Array(two.names.prefix(5)), ["", "Files", "Size", "Packed Size", sep])

        let mixed = lines(["notes.md", "sub"])
        XCTAssertEqual(Array(mixed.names.prefix(6)), ["", "Folders", "Files", "Size", "Packed Size", sep])
        XCTAssertEqual(mixed.values[1], "2", "sub and sub/deep")
        XCTAssertEqual(mixed.values[2], "3", "notes.md, big.txt, inner.txt")

        let none = lines([])
        XCTAssertEqual(Array(none.names.prefix(5)), ["Size", "Packed Size", "Folders", "Files", "CRC"])

        navigate(panel, to: scratch + "/test.7z/sub")
        let inSub = panel.queue.sync { PanelProperties.build(folder: panel.folder!, itemIndices: [], snapshot: panel.snapshot!, level: .min) }
        XCTAssertEqual(inSub.names.first, "Name")
        XCTAssertEqual(inSub.values.first, "sub/", "GetFolderProperty(kpidPath) under the name of kpidName")

        // The dialog: autosized columns, 80 / text + 12 as on Windows, 17 pt rows.
        let widths = ListViewMetrics.autosizedWidths(strings: file.names, values: file.values)
        XCTAssertEqual(widths.strings, 80, accuracy: 0.5, "the 72 px separator + 8")
        let appeared = ModalProbe.present({ PropertiesDialog.show(lines: file, parent: controller.window) }) { window in
            guard let table = Self.firstTable(in: window.contentView) else { return XCTFail("no list") }
            XCTAssertEqual(table.tableColumns[0].width, widths.strings, accuracy: 0.5)
            XCTAssertEqual(table.tableColumns[1].width, widths.values, accuracy: 0.5)
            XCTAssertEqual(table.rect(ofRow: 1).minY - table.rect(ofRow: 0).minY, 17)
            XCTAssertFalse(table.usesAlternatingRowBackgroundColors)
            XCTAssertEqual(table.headerView?.frame.height, 24)
            _ = self.attach(window, "listfeel-02-properties")
        }
        XCTAssertTrue(appeared)
    }

    private static func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView { return table }
        for sub in view.subviews { if let t = firstTable(in: sub) { return t } }
        return nil
    }

    // MARK: - 7. toolbar

    /// comctl32 v6 on Windows 11: while pressed, the bitmap and the label move 1 px right, no rows
    /// move (Info button, real mouse-down on 7zFM 26.03).
    func testToolbarPressedOffset() throws {
        let controller = makeWindow()
        let toolbar = try XCTUnwrap(Self.find(FMToolbarView.self, in: controller.window?.contentView))
        let button = try XCTUnwrap(toolbar.button("sz.info") ?? toolbar.buttons.last)
        func inkBox() -> NSRect? {
            let rep = try? XCTUnwrap(button.bitmapImageRepForCachingDisplay(in: button.bounds))
            guard let rep else { return nil }
            button.cacheDisplay(in: button.bounds, to: rep)
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            for y in 0..<rep.pixelsHigh {
                for x in 0..<rep.pixelsWide {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.5,
                          (c.redComponent + c.greenComponent + c.blueComponent) / 3 < 0.45 else { continue }
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            let scale = CGFloat(rep.pixelsWide) / button.bounds.width
            return maxX < 0 ? nil : NSRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale,
                                           width: CGFloat(maxX - minX) / scale, height: CGFloat(maxY - minY) / scale)
        }
        button.isHighlighted = false
        let rest = try XCTUnwrap(inkBox())
        button.isHighlighted = true
        let pressed = try XCTUnwrap(inkBox())
        button.isHighlighted = false
        XCTAssertEqual(pressed.minX - rest.minX, 1, accuracy: 0.01)
        XCTAssertEqual(pressed.minY - rest.minY, 0, accuracy: 0.01)
        XCTAssertEqual(FMToolbarView.pressedOffset, NSSize(width: 1, height: 0))
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for sub in view.subviews { if let found = find(type, in: sub) { return found } }
        return nil
    }

    // MARK: - 8. fresh defaults

    /// kNumDefaultPanels = 1 (FM.cpp:127): with no stored value the window starts with one panel,
    /// as 7zFM does with HKCU\Software\7-Zip deleted (listfeel-data/win1/log.txt "fresh lists=1").
    func testFreshDefaultIsOnePanel() {
        Settings.removeKey(Settings.Key.numPanels)
        XCTAssertEqual(Settings.numPanels, 1)
        let controller = MainWindowController()
        controllers.append(controller)
        XCTAssertEqual(controller.numPanels, 1)
    }

    // MARK: - paired captures

    /// The Mac half of `wincompare-listfeel-<state>-*.png`: the list's top-left 760 x 200 pt at 1x.
    func testPairedCaptures() {
        let scratch = makeScratch()
        let controller = makeWindow()
        let panel = controller.focusedPanel
        Settings.removeKey("FM.Columns.FSFolder")
        navigate(panel, to: scratch)
        controller.window?.makeFirstResponder(panel.tableView)
        panel.listFocusOverride = true
        defer { panel.listFocusOverride = nil }
        select(panel, ["a.txt"], focus: "a.txt")
        capture(panel, "wincompare-listfeel-list-mac.png")
        Settings.removeKey("FM.Columns.7-Zip.7z")
        navigate(panel, to: scratch + "/test.7z")
        select(panel, [], focus: nil)
        capture(panel, "wincompare-listfeel-archive-mac.png")
    }

    private func capture(_ panel: PanelViewController, _ file: String) {
        guard let window = panel.view.window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let list: NSView = panel.tableView.enclosingScrollView ?? panel.tableView
        var rect = list.convert(list.bounds, to: content)
        rect = NSRect(x: rect.minX, y: rect.maxY - 200, width: min(760, rect.width), height: 200)
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
