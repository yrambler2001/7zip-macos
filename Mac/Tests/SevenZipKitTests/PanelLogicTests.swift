// PanelLogicTests.swift -- the panel logic that is testable without UI: the sort comparator
// (PanelSort.cpp CompareItems2 / SortItemsWithPropID), the wildcard masks
// (Common/Wildcard.cpp EnhancedMaskTest), the "operated items" rule (PanelItems.cpp
// Get_ItemIndices_Operated) and the column model with its CListViewInfo persistence
// (PanelItems.cpp InitColumns, ViewSettings.cpp).
//
// PanelRow.swift and PanelLogic.swift are symlinked into this target so the tests run against the
// very same source the app compiles (as Settings.swift and FileTypes.swift already are).
//
// Parity: 01-fm-feature-inventory.md §3.2, §3.3, §3.6; 01b §5.3.

import XCTest
import SevenZipKit

final class PanelLogicTests: XCTestCase {

    // MARK: helpers

    private func row(_ name: String, dir: Bool = false, size: UInt64 = 0, index: Int,
                     prefix: String = "", mtime: Date? = nil) -> PanelRow {
        var keys: [SZPropID: Any] = [.name: name, .size: NSNumber(value: size)]
        if let mtime { keys[.mtime] = mtime }
        return PanelRow(engineIndex: index, name: name, displayName: name, isDirectory: dir, size: size,
                        prefix: prefix, cells: [:], sortKeys: keys)
    }

    private func names(_ rows: [PanelRow]) -> [String] { rows.map { $0.name } }

    // MARK: - Sorting (01 §3.3)

    func testParentRowAndDirectoriesComeFirst() {
        let rows = [PanelRow.parent,
                    row("b.txt", size: 10, index: 0),
                    row("adir", dir: true, index: 1),
                    row("a.txt", size: 20, index: 2),
                    row("zdir", dir: true, index: 3)]
        let sorted = PanelSorting.sorted(rows: rows, sortID: .name, ascending: true, flatMode: false)
        XCTAssertEqual(names(sorted), ["..", "adir", "zdir", "a.txt", "b.txt"])
    }

    func testDescendingKeepsDotDotAndDirectoriesOnTop() {
        let rows = [PanelRow.parent,
                    row("a.txt", size: 10, index: 0),
                    row("b.txt", size: 20, index: 1),
                    row("dir", dir: true, index: 2)]
        let sorted = PanelSorting.sorted(rows: rows, sortID: .size, ascending: false, flatMode: false)
        XCTAssertEqual(names(sorted), ["..", "dir", "b.txt", "a.txt"],
                       "a descending sort still keeps '..' and the folders on top, as 7zFM shows it")
    }

    func testNumericAwareNameOrder() {
        let rows = [row("file10.txt", index: 0), row("file2.txt", index: 1), row("File1.txt", index: 2)]
        let sorted = PanelSorting.sorted(rows: rows, sortID: .name, ascending: true, flatMode: false)
        XCTAssertEqual(names(sorted), ["File1.txt", "file2.txt", "file10.txt"],
                       "CompareFileNames_ForFolderList is case-insensitive and numeric-aware")
    }

    func testSizeSortFallsBackToName() {
        let rows = [row("b.txt", size: 100, index: 0),
                    row("a.txt", size: 100, index: 1),
                    row("c.txt", size: 5, index: 2)]
        let sorted = PanelSorting.sorted(rows: rows, sortID: .size, ascending: true, flatMode: false)
        XCTAssertEqual(names(sorted), ["c.txt", "a.txt", "b.txt"], "equal sizes are ordered by name")
    }

    func testExtensionSortUsesTheExtensionThenTheName() {
        let rows = [row("b.zip", index: 0), row("a.zip", index: 1), row("c.7z", index: 2)]
        let sorted = PanelSorting.sorted(rows: rows, sortID: .extension, ascending: true, flatMode: false)
        XCTAssertEqual(names(sorted), ["c.7z", "a.zip", "b.zip"])
    }

    func testFlatModeUsesThePrefixAsTheThirdKey() {
        let rows = [row("x.txt", index: 0, prefix: "sub/b/"),
                    row("x.txt", index: 1, prefix: "sub/a/")]
        let sorted = PanelSorting.sorted(rows: rows, sortID: .size, ascending: true, flatMode: true)
        XCTAssertEqual(sorted.map { $0.prefix }, ["sub/a/", "sub/b/"])
    }

    func testUnsortedKeepsTheArchiveOrderAndMixesFoldersAndFiles() {
        let rows = [row("file", index: 0), row("dir", dir: true, index: 1), row("other", index: 2)]
        let sorted = PanelSorting.sorted(rows: rows, sortID: .noProperty, ascending: true, flatMode: false)
        XCTAssertEqual(names(sorted), ["file", "dir", "other"], "kpidNoProperty = native order")
    }

    func testMissingValuesSortFirst() {
        let now = Date()
        let rows = [row("with", index: 0, mtime: now), row("without", index: 1)]
        let sorted = PanelSorting.sorted(rows: rows, sortID: .mtime, ascending: true, flatMode: false)
        XCTAssertEqual(names(sorted), ["without", "with"], "VT_EMPTY sorts before a value")
    }

    func testIFolderCompareWinsOverTheValueComparison() {
        let rows = [row("a", index: 0), row("b", index: 1)]
        // the folder claims b < a for kpidCRC
        let sorted = PanelSorting.sorted(rows: rows, sortID: .crc, ascending: true, flatMode: false) { i, j, _ in
            i == 1 && j == 0 ? -1 : (i == 0 && j == 1 ? 1 : 0)
        }
        XCTAssertEqual(names(sorted), ["b", "a"])
    }

    func testSortDirectionRules() {
        // a new property starts ascending, except the five that start descending
        XCTAssertEqual(PanelSorting.nextSort(current: .name, ascending: true, tapped: .size).1, false)
        XCTAssertEqual(PanelSorting.nextSort(current: .name, ascending: true, tapped: .packSize).1, false)
        XCTAssertEqual(PanelSorting.nextSort(current: .name, ascending: true, tapped: .mtime).1, false)
        XCTAssertEqual(PanelSorting.nextSort(current: .name, ascending: true, tapped: .ctime).1, false)
        XCTAssertEqual(PanelSorting.nextSort(current: .name, ascending: true, tapped: .atime).1, false)
        XCTAssertEqual(PanelSorting.nextSort(current: .size, ascending: true, tapped: .name).1, true)
        // the same property toggles
        let again = PanelSorting.nextSort(current: .size, ascending: false, tapped: .size)
        XCTAssertEqual(again.0, .size)
        XCTAssertTrue(again.1)
    }

    // MARK: - Masks (01 §3.6)

    func testWildcardMatching() {
        XCTAssertTrue(PanelMask.matches(mask: "*", name: "anything"))
        XCTAssertTrue(PanelMask.matches(mask: "*.txt", name: "readme.TXT"), "masks are case-insensitive")
        XCTAssertFalse(PanelMask.matches(mask: "*.txt", name: "readme.txt.gz"))
        // a file-system folder on a case-sensitive volume tells case apart (01 §9 #24, navgaps)
        XCTAssertFalse(PanelMask.matches(mask: "*.txt", name: "readme.TXT", caseSensitive: true))
        XCTAssertTrue(PanelMask.matches(mask: "*.TXT", name: "readme.TXT", caseSensitive: true))
        XCTAssertTrue(PanelMask.matches(mask: "a?c", name: "abc"))
        XCTAssertFalse(PanelMask.matches(mask: "a?c", name: "ac"))
        XCTAssertTrue(PanelMask.matches(mask: "readme.txt", name: "README.TXT"), "an exact name matches")
        XCTAssertTrue(PanelMask.matches(mask: "*a*b*", name: "xxayybzz"))
        XCTAssertFalse(PanelMask.matches(mask: "*a*b*", name: "xxbyyazz"))
        XCTAssertTrue(PanelMask.matches(mask: "", name: ""))
        XCTAssertFalse(PanelMask.matches(mask: "", name: "x"))
        XCTAssertTrue(PanelMask.containsWildcard("a*"))
        XCTAssertFalse(PanelMask.containsWildcard("plain.txt"))
    }

    func testSelectByTypeRule() {
        XCTAssertEqual(PanelMask.selectByTypeRule(name: "folder", isDirectory: true), .allFolders)
        XCTAssertEqual(PanelMask.selectByTypeRule(name: "notes.md", isDirectory: false), .mask("*.md"))
        XCTAssertEqual(PanelMask.selectByTypeRule(name: "Makefile", isDirectory: false), .filesWithoutExtension,
                       "a name without an extension selects only the extension-less files, not every file")
    }

    // MARK: - Operated items (01 conventions)

    func testOperatedItemsRule() {
        let rows = [PanelRow.parent, row("a", index: 0), row("b", index: 1), row("c", index: 2)]
        // the selection wins
        XCTAssertEqual(PanelOperatedItems.operated(rows: rows, selected: IndexSet([2, 3]), focused: 1,
                                                   focusedIsListSelected: false), [2, 3])
        // nothing selected, the focused row only focused (a folder just opened, Deselect All):
        // nothing is operated, "0 / 3 object(s) selected" (PanelItems.cpp:984-1001, winmatch)
        XCTAssertEqual(PanelOperatedItems.operated(rows: rows, selected: IndexSet(), focused: 2,
                                                   focusedIsListSelected: false), [])
        // AlternativeSelection: no marked item, the list-selected cursor row is operated
        XCTAssertEqual(PanelOperatedItems.operated(rows: rows, selected: IndexSet(), focused: 2,
                                                   focusedIsListSelected: true), [2])
        // ".." is never operated on
        XCTAssertEqual(PanelOperatedItems.operated(rows: rows, selected: IndexSet(integer: 0), focused: 0,
                                                   focusedIsListSelected: true), [])
        XCTAssertEqual(PanelOperatedItems.operated(rows: rows, selected: IndexSet(), focused: 0,
                                                   focusedIsListSelected: true), [])
        // OperSmart: an empty result means the whole folder
        XCTAssertEqual(PanelOperatedItems.operatedSmart(rows: rows, selected: IndexSet(), focused: 2,
                                                        focusedIsListSelected: false), [1, 2, 3])
        XCTAssertEqual(PanelOperatedItems.operatedSmart(rows: rows, selected: IndexSet(integer: 1), focused: 0,
                                                        focusedIsListSelected: false), [1])
    }

    // MARK: - Columns (01 §3.2, 01b §5.3)

    /// The real property list of a file-system folder, so the test uses the shipped column order.
    private func fsProperties() throws -> [SZPropertyInfo] {
        let folder = try SZFileSystemFolder.folder(withPath: NSTemporaryDirectory())
        return folder.properties
    }

    func testColumnDefaults() throws {
        let properties = try fsProperties()
        let hidden = Set(SZFileSystemFolder.defaultHiddenPropIDs.map { $0.uint32Value })
        let model = PanelColumnsModel(properties: properties, folderType: "FSFolder", isFileSystem: true,
                                      hiddenByDefault: hidden, layout: nil)
        XCTAssertEqual(model.columns.first?.propID, .name, "kpidName comes first (NameFirst)")
        XCTAssertFalse(model.columns.contains { $0.propID == .isDir }, "kpidIsDir is skipped")
        XCTAssertEqual(model.columns.first?.width, 160, "kpidName is 160 px wide")
        // GetColumnWidth: every other column 100 px, times and raw properties included
        // (fresh-default 7zFM 26.03, listfeel.md §2).
        XCTAssertTrue(model.columns.dropFirst().allSatisfy { $0.width == 100 }, "other columns are 100 px")
        // ShowColumnsContextMenu lists `_columns`, the folder's property order.
        XCTAssertEqual(model.menuColumns.map { $0.propID }, properties.filter { $0.propID != .isDir }.map { $0.propID })
        XCTAssertEqual(model.sortID, .name)
        XCTAssertTrue(model.ascending)
        let visible = Set(model.visibleColumns.map { $0.propID })
        XCTAssertTrue(visible.contains(.size))
        XCTAssertTrue(visible.contains(.mtime))
        for pid in [SZPropID.atime, .changeTime, .attrib, .packSize, .inode, .links, .ntReparse] {
            XCTAssertFalse(visible.contains(pid), "\(pid) is hidden by default on a file-system folder")
        }
        XCTAssertTrue(model.visibleColumns.contains { $0.propID == .name })
    }

    func testRootFolderStartsUnsorted() {
        let model = PanelColumnsModel(properties: [], folderType: "RootFolder", isFileSystem: false,
                                      hiddenByDefault: [], layout: nil)
        XCTAssertEqual(model.sortID, .noProperty, "the root and the volumes list keep their native order")
    }

    /// listfeel §5: the header's column menu keeps the folder's property order (`_columns`) after
    /// a header drag and a stored layout, as 7zFM 26.03 does ("Name, Size, Modified, Created,
    /// Accessed, ..." whatever the header shows).
    func testColumnMenuKeepsThePropertyOrder() throws {
        let properties = try fsProperties()
        let order = properties.filter { $0.propID != .isDir }.map { $0.propID }
        var model = PanelColumnsModel(properties: properties, folderType: "FSFolder", isFileSystem: true,
                                      hiddenByDefault: [], layout: nil)
        model.setVisible(false, propID: .size)
        model.reorder(to: [.name, .comment, .mtime])
        XCTAssertEqual(model.columns.dropFirst().first?.propID, .comment)
        XCTAssertEqual(model.menuColumns.map { $0.propID }, order)
        let restored = PanelColumnsModel(properties: properties, folderType: "FSFolder", isFileSystem: true,
                                         hiddenByDefault: [], layout: model.layout())
        XCTAssertEqual(restored.menuColumns.map { $0.propID }, order)
        XCTAssertEqual(restored.columns.dropFirst().first?.propID, .comment, "the header keeps the dragged order")
    }

    func testColumnLayoutRoundTripAndReorder() throws {
        let properties = try fsProperties()
        var model = PanelColumnsModel(properties: properties, folderType: "FSFolder", isFileSystem: true,
                                      hiddenByDefault: [], layout: nil)
        model.setVisible(false, propID: .mtime)
        model.setWidth(240, propID: .size)
        model.sort(by: .size)                          // starts descending
        XCTAssertEqual(model.sortID, .size)
        XCTAssertFalse(model.ascending)
        let layout = model.layout()
        XCTAssertEqual(layout.sortID, Int(SZPropID.size.rawValue))
        XCTAssertFalse(layout.ascending)

        // JSON encoding is what lands in FM.Columns.<FolderTypeID>
        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(Settings.ColumnLayout.self, from: data)
        XCTAssertEqual(decoded, layout)

        let restored = PanelColumnsModel(properties: properties, folderType: "FSFolder", isFileSystem: true,
                                         hiddenByDefault: [], layout: decoded)
        XCTAssertEqual(restored.sortID, .size)
        XCTAssertFalse(restored.ascending)
        XCTAssertFalse(restored.columns.first { $0.propID == .mtime }?.visible ?? true)
        XCTAssertEqual(restored.columns.first { $0.propID == .size }?.width, 240)

        // a header drag reorders, kpidName stays first after a reload
        var reordered = restored
        reordered.reorder(to: [.size, .name, .mtime])
        XCTAssertEqual(reordered.columns.first?.propID, .size)
        let afterReload = PanelColumnsModel(properties: properties, folderType: "FSFolder", isFileSystem: true,
                                            hiddenByDefault: [], layout: reordered.layout())
        XCTAssertEqual(afterReload.columns.first?.propID, .name, "Name is moved back to the front on init")
        XCTAssertEqual(afterReload.columns.dropFirst().first?.propID, .size)
    }

    func testColumnLayoutIgnoresUnknownAndKeepsNameVisible() throws {
        let properties = try fsProperties()
        let stored = Settings.ColumnLayout(
            sortID: Int(SZPropID.name.rawValue), ascending: true,
            columns: [.init(propID: 60000, visible: true, width: 50),          // not a real PROPID
                      .init(propID: Int(SZPropID.name.rawValue), visible: false, width: 10)])
        let model = PanelColumnsModel(properties: properties, folderType: "FSFolder", isFileSystem: true,
                                      hiddenByDefault: [], layout: stored)
        XCTAssertFalse(model.columns.contains { $0.propID.rawValue == 60000 })
        XCTAssertTrue(model.columns.first?.visible ?? false, "kpidName can never be hidden")
        XCTAssertEqual(model.columns.first?.width, 24, "a stored width is clamped to the minimum")
    }

    /// The same value the panel writes and reads through the settings facade (01b §5.3).
    func testColumnLayoutPersistence() throws {
        let suite = "com.yrambler2001.7zip.tests.panel"
        setenv(SZSettingsSuiteEnvironmentVariable, suite, 1)
        defer {
            Settings.setColumnLayout(nil, forFolderType: "7-Zip.7z")
            CFPreferencesAppSynchronize(suite as CFString)
            unsetenv(SZSettingsSuiteEnvironmentVariable)
        }
        Settings.setColumnLayout(nil, forFolderType: "7-Zip.7z")
        XCTAssertNil(Settings.columnLayout(forFolderType: "7-Zip.7z"))
        let layout = Settings.ColumnLayout(sortID: Int(SZPropID.packSize.rawValue), ascending: false,
                                           columns: [.init(propID: Int(SZPropID.name.rawValue), visible: true, width: 160),
                                                     .init(propID: Int(SZPropID.packSize.rawValue), visible: false, width: 120)])
        Settings.setColumnLayout(layout, forFolderType: "7-Zip.7z")
        XCTAssertEqual(Settings.columnLayout(forFolderType: "7-Zip.7z"), layout)
        XCTAssertNil(Settings.columnLayout(forFolderType: "7-Zip.zip"), "layouts are per folder type")
    }
}
