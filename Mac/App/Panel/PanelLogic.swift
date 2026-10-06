// PanelLogic.swift -- the panel's pure logic: the sort comparator (PanelSort.cpp), wildcard
// masks (Common/Wildcard.cpp), the "operated items" rule (PanelItems.cpp) and the column model
// with its per-folder-type persistence (PanelItems.cpp InitColumns / ViewSettings.cpp
// CListViewInfo). Foundation + SevenZipKit only, no AppKit: this file is also compiled into the
// unit-test target (Mac/Tests/SevenZipKitTests/PanelLogic.swift is a symlink to it).
//
// Parity: 01-fm-feature-inventory.md §3.2, §3.3, §3.6; 01b-fm-dialogs-settings.md §5.3.

import Foundation
import SevenZipKit

// MARK: - Sorting (PanelSort.cpp)

enum PanelSorting {

    /// SortItemsWithPropID (PanelSort.cpp:256-279): the same property toggles the direction, a
    /// new one starts ascending except for the five that start descending.
    static let descendingFirst: Set<SZPropID> = [.size, .packSize, .ctime, .atime, .mtime]

    static func startsDescending(_ propID: SZPropID) -> Bool { descendingFirst.contains(propID) }

    /// Next (sortID, ascending) pair when `tapped` is chosen while `current` is active.
    static func nextSort(current: SZPropID, ascending: Bool, tapped: SZPropID) -> (SZPropID, Bool) {
        if tapped == current { return (current, !ascending) }
        return (tapped, !startsDescending(tapped))
    }

    /// CompareItems2 (PanelSort.cpp:98-177). `folderCompare` is `IFolderCompare::CompareItems`
    /// when the folder implements it (archive folders do), else nil.
    ///
    /// Deviation worth knowing: ".." first and directories-before-files are *not* inverted by a
    /// descending sort (that is what 7zFM shows on screen), only the property rounds are.
    static func sorted(rows: [PanelRow], sortID: SZPropID, ascending: Bool, flatMode: Bool,
                       folderCompare: ((Int, Int, SZPropID) -> Int)? = nil) -> [PanelRow] {
        var rounds: [SZPropID] = []
        if sortID != .noProperty {
            rounds.append(sortID)
            if sortID != .name { rounds.append(.name) }
            if flatMode && sortID != .prefix { rounds.append(.prefix) }
        }
        return rows.sorted { a, b in
            if a.isParentRow != b.isParentRow { return a.isParentRow }        // ".." first
            if sortID != .noProperty && a.isDirectory != b.isDirectory { return a.isDirectory }
            var result = 0
            for pid in rounds {
                result = compare(a, b, pid, folderCompare: folderCompare)
                if result != 0 { break }
            }
            if result == 0 {                                                  // final tie-break
                return a.engineIndex < b.engineIndex
            }
            return ascending ? result < 0 : result > 0
        }
    }

    /// One property round of CompareItems2.
    static func compare(_ a: PanelRow, _ b: PanelRow, _ propID: SZPropID,
                        folderCompare: ((Int, Int, SZPropID) -> Int)? = nil) -> Int {
        switch propID {
        case .name:
            return clamp(SZFolder.compareFileName(a.name, with: b.name))
        case .extension:
            let r = clamp(SZFolder.compareFileName(a.pathExtension, with: b.pathExtension))
            return r
        case .prefix:
            return clamp(SZFolder.compareFileName(a.prefix, with: b.prefix))
        case .size:
            return a.size == b.size ? 0 : (a.size < b.size ? -1 : 1)
        default:
            break
        }
        if let folderCompare, !a.isParentRow, !b.isParentRow {
            let r = folderCompare(a.engineIndex, b.engineIndex, propID)
            if r != 0 { return clamp(r) }
            // 0 can mean "equal" or "not handled": fall through to the value comparison.
        }
        return compareValues(a.sortKeys[propID], b.sortKeys[propID], propID: propID)
    }

    /// Value comparison: strings with CompareFileNames_ForFolderList for path-like properties,
    /// numbers / dates / booleans by value. A missing value sorts first, as VT_EMPTY does.
    static func compareValues(_ x: Any?, _ y: Any?, propID: SZPropID) -> Int {
        switch (x, y) {
        case (nil, nil): return 0
        case (nil, _): return -1
        case (_, nil): return 1
        default: break
        }
        if let n1 = x as? NSNumber, let n2 = y as? NSNumber {
            return clamp(n1.compare(n2).rawValue)
        }
        if let d1 = x as? Date, let d2 = y as? Date {
            return clamp(d1.compare(d2).rawValue)
        }
        if let s1 = x as? String, let s2 = y as? String {
            // kpidNtReparse / kpidSymLink hold a decoded path: same rule as a name (01 §3.3).
            if propID == .ntReparse || propID == .symLink || propID == .path {
                return clamp(SZFolder.compareFileName(s1, with: s2))
            }
            return clamp(s1.compare(s2, options: [.caseInsensitive, .numeric]).rawValue)
        }
        return 0
    }

    private static func clamp(_ value: Int) -> Int { value == 0 ? 0 : (value < 0 ? -1 : 1) }
}

// MARK: - Wildcard masks (Common/Wildcard.cpp EnhancedMaskTest)

enum PanelMask {

    /// DoesWildcardMatchName: `*` any sequence, `?` any single character, case-insensitive.
    /// DoesWildcardMatchName with g_CaseSensitive: Windows never tells case apart; here a
    /// file-system folder on a case-sensitive volume does (01 §9 #24).
    static func matches(mask: String, name: String, caseSensitive: Bool = false) -> Bool {
        let m = Array(caseSensitive ? mask : mask.lowercased())
        let n = Array(caseSensitive ? name : name.lowercased())
        return test(m, 0, n, 0)
    }

    private static func test(_ mask: [Character], _ mi: Int, _ name: [Character], _ ni: Int) -> Bool {
        var mi = mi, ni = ni
        while true {
            if mi == mask.count { return ni == name.count }
            let m = mask[mi]
            if m == "*" {
                if test(mask, mi + 1, name, ni) { return true }
                if ni == name.count { return false }
            } else {
                if ni == name.count { return false }
                if m != "?" && m != name[ni] { return false }
                mi += 1
            }
            ni += 1
        }
    }

    static func containsWildcard(_ text: String) -> Bool {
        text.contains("*") || text.contains("?")
    }

    /// SelectByType (PanelSelect.cpp:169-204): a folder selects every folder, a name without an
    /// extension every extension-less file, otherwise `*.ext`.
    enum SelectByTypeRule: Equatable {
        case allFolders                 // the focused item is a folder
        case filesWithoutExtension      // its name has no extension
        case mask(String)               // "*.ext"
    }

    static func selectByTypeRule(name: String, isDirectory: Bool) -> SelectByTypeRule {
        if isDirectory { return .allFolders }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? .filesWithoutExtension : .mask("*." + ext)
    }
}

// MARK: - Operated items (PanelItems.cpp Get_ItemIndices_Operated)

enum PanelOperatedItems {

    /// Get_ItemIndices_Operated (PanelItems.cpp:984-1001): the selected rows; when none is
    /// selected, the focused row -- but only while that row is *list-selected*, which is the
    /// AlternativeSelection cursor (01 §3.6). In the normal mode a focused row that is not
    /// selected is not operated: a freshly opened folder shows "0 / N object(s) selected"
    /// (winmatch, `requests.md` wincompare -> panel). Never "..".
    static func operated(rows: [PanelRow], selected: IndexSet, focused: Int,
                         focusedIsListSelected: Bool) -> [Int] {
        var result = selected.filter { $0 >= 0 && $0 < rows.count && !rows[$0].isParentRow }
        if result.isEmpty, focusedIsListSelected, focused >= 0, focused < rows.count,
           !rows[focused].isParentRow {
            result = [focused]
        }
        return result
    }

    /// Get_ItemIndices_OperSmart: as above, but an empty result means "everything in the folder"
    /// (what Copy / Move, Test and the hash commands operate on when nothing is selected).
    static func operatedSmart(rows: [PanelRow], selected: IndexSet, focused: Int,
                              focusedIsListSelected: Bool) -> [Int] {
        let items = operated(rows: rows, selected: selected, focused: focused,
                             focusedIsListSelected: focusedIsListSelected)
        if !items.isEmpty { return items }
        return rows.indices.filter { !rows[$0].isParentRow }
    }
}

// MARK: - Columns (PanelItems.cpp InitColumns, ViewSettings.cpp CListViewInfo)

struct PanelColumn {
    let propID: SZPropID
    let varType: SZVarType
    let title: String
    var visible: Bool
    var width: Int

    /// kpidName is never hidden and is always first (ShowColumnsContextMenu grays it, 01 §2.8).
    var isName: Bool { propID == .name }
}

struct PanelColumnsModel {

    static let nameWidth = 160        // GetColumnWidth (PanelItems.cpp:44-51), 96 dpi px == pt here
    static let otherWidth = 100

    /// Default width of a new column: GetColumnWidth (PanelItems.cpp:44-51) gives kpidName 160 px
    /// and every other column, raw properties included, 100 px -- measured on a fresh-default
    /// 7zFM 26.03 for the file-system, 7z and zip folders (ai/reports/listfeel.md §2). The
    /// port used to start time columns at 120 pt and hex columns at 160-470 pt because its 13 pt
    /// list font did not fit a date into 100 pt; the list font now has Segoe UI 9 pt metrics
    /// (`PanelMetrics.listFont`), so "2024-01-15 11:30" fits as it does on Windows.
    ///
    /// sffont: with SF Pro 12.2 (tabular digits) the date is 111 pt, so a time column starts at the
    /// date's width plus Windows' two 6 px margins (88 + 12 = 100 on Windows), never below 100:
    /// the full date is never cut at the default width.
    ///
    /// datecols: the time width follows View > Time (the level's full date, plus "Z" with UTC),
    /// and a size column starts wide enough for "9 999 999 999 999" (PanelMetrics).
    static func defaultWidth(for info: SZPropertyInfo) -> Int {
        if info.propID == .name { return nameWidth }
        if info.varType == .fileTime { return timeWidth }
        if sizeColumnIDs.contains(info.propID) { return sizeWidth }
        return otherWidth
    }

    /// A full date at the current View > Time level in the columns' font plus the margins on both
    /// sides; set by the panel from its font (`PanelMetrics.timeColumnWidth`) before it builds a
    /// column model. This file is also compiled into the unit tests, which have no font: 100 there.
    static var timeWidth = otherWidth
    /// Every width an earlier build or another View > Time level gave a time column by default
    /// (100, and each level with and without UTC in the current font): a stored time column at one
    /// of them is still "at the default" and gets today's (`PanelMetrics.timeColumnDefaults`).
    static var timeWidthDefaults: Set<Int> = []
    /// The size columns (`Formatting.sizePropIDs`) and their default width, set by the panel
    /// (`PanelMetrics.sizeColumnWidth`); empty / 100 in the unit tests.
    static var sizeColumnIDs: Set<SZPropID> = []
    static var sizeWidth = otherWidth

    var columns: [PanelColumn]
    /// The folder's own property order (`_columns`, PanelItems.cpp:127-195). The header's column
    /// menu lists the columns in this order, visible or not, whatever order the header shows them
    /// in (ShowColumnsContextMenu, PanelItems.cpp:1396-1413; listfeel.md §5).
    private(set) var propertyOrder: [SZPropID] = []
    var sortID: SZPropID
    var ascending: Bool

    /// InitColumns: the folder's property list (kpidName first, kpidIsDir skipped) merged with
    /// the persisted layout of this folder type.
    init(properties: [SZPropertyInfo], folderType: String, isFileSystem: Bool,
         hiddenByDefault: Set<UInt32>, layout: Settings.ColumnLayout?) {
        var infos = properties.filter { $0.propID != .isDir }
        // ItemProperty_Compare_NameFirst (PanelItems.cpp:90): stable, Name first.
        if let nameIndex = infos.firstIndex(where: { $0.propID == .name }), nameIndex != 0 {
            let name = infos.remove(at: nameIndex)
            infos.insert(name, at: 0)
        }
        propertyOrder = infos.map { $0.propID }
        var built: [PanelColumn] = infos.map { info in
            PanelColumn(propID: info.propID, varType: info.varType, title: info.localizedName,
                        visible: info.propID == .name || !hiddenByDefault.contains(info.propID.rawValue),
                        width: Self.defaultWidth(for: info))
        }
        // Default sort: kpidName ascending for file-system and archive folders, native order
        // (kpidNoProperty) for the root and the volumes list (PanelItems.cpp:96+).
        var defaultSort: SZPropID = (isFileSystem || folderType.hasPrefix("7-Zip.")) ? .name : .noProperty
        if !built.contains(where: { $0.propID == defaultSort }) && defaultSort != .noProperty {
            defaultSort = .noProperty
        }
        sortID = defaultSort
        ascending = true

        if let layout {
            var ordered: [PanelColumn] = []
            for stored in layout.columns {
                guard let pid = SZPropID(rawValue: UInt32(truncatingIfNeeded: stored.propID)),
                      let index = built.firstIndex(where: { $0.propID == pid }) else { continue }
                var column = built.remove(at: index)
                column.visible = column.isName ? true : stored.visible
                column.width = max(24, stored.width)
                // A time column still at the old 100 px default (saved before sffont) would cut
                // the date in SF Pro: it gets the new default; so does one at another level's
                // default (datecols). A size column at the old 100 px gets the size default.
                if column.varType == .fileTime,
                   stored.width == Self.otherWidth || Self.timeWidthDefaults.contains(stored.width) {
                    column.width = Self.timeWidth
                }
                if Self.sizeColumnIDs.contains(column.propID), stored.width == Self.otherWidth {
                    column.width = Self.sizeWidth
                }
                ordered.append(column)
            }
            // Columns the stored layout did not know about keep their defaults and stay in the
            // folder's order behind the known ones.
            ordered.append(contentsOf: built)
            if let nameIndex = ordered.firstIndex(where: { $0.isName }), nameIndex != 0 {
                let name = ordered.remove(at: nameIndex)
                ordered.insert(name, at: 0)
            }
            built = ordered
            if let pid = SZPropID(rawValue: UInt32(truncatingIfNeeded: layout.sortID)),
               pid == .noProperty || built.contains(where: { $0.propID == pid }) {
                sortID = pid
                ascending = layout.ascending
            }
        }
        columns = built
    }

    /// SaveListViewInfo: the blob written under FM.Columns.<FolderTypeID>.
    func layout() -> Settings.ColumnLayout {
        Settings.ColumnLayout(sortID: Int(sortID.rawValue), ascending: ascending,
                              columns: columns.map {
                                  Settings.ColumnLayout.Column(propID: Int($0.propID.rawValue),
                                                               visible: $0.visible, width: $0.width)
                              })
    }

    var visibleColumns: [PanelColumn] { columns.filter { $0.visible } }

    /// The columns in the folder's property order, for the header's column menu.
    var menuColumns: [PanelColumn] {
        let ordered = propertyOrder.compactMap { pid in columns.first { $0.propID == pid } }
        return ordered.count == columns.count ? ordered : columns
    }

    mutating func setVisible(_ visible: Bool, propID: SZPropID) {
        guard let index = columns.firstIndex(where: { $0.propID == propID }), !columns[index].isName else { return }
        columns[index].visible = visible
    }

    mutating func setWidth(_ width: Int, propID: SZPropID) {
        guard let index = columns.firstIndex(where: { $0.propID == propID }) else { return }
        columns[index].width = max(24, width)
    }

    /// Reorders to `order` (the PROPIDs left to right after a header drag).
    mutating func reorder(to order: [SZPropID]) {
        var remaining = columns
        var result: [PanelColumn] = []
        for pid in order {
            if let index = remaining.firstIndex(where: { $0.propID == pid }) {
                result.append(remaining.remove(at: index))
            }
        }
        result.append(contentsOf: remaining)
        columns = result
    }

    mutating func sort(by propID: SZPropID) {
        let next = PanelSorting.nextSort(current: sortID, ascending: ascending, tapped: propID)
        sortID = next.0
        ascending = next.1
    }
}
