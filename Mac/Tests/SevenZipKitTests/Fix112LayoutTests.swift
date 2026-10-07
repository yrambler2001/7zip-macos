// Fix112LayoutTests.swift -- stored column layouts are sanitised on load and nothing stored can
// stop a header click from sorting (ai/reports/fix112.md §1). The app-hosted half, with real
// panels and Show "..", is Mac/Tests/AppTests/Fix112Tests.swift.

import Foundation
import SevenZipKit
import XCTest

final class Fix112LayoutTests: XCTestCase {

    /// A layout with the shape of a real 1.1.1 user's FM.Columns.FSFolder (column and sort values
    /// only): sorted by Created (10) ascending, Name 464 wide, many columns hidden.
    static let userFSFolderJSON = """
    {"sortID":10,"ascending":true,"columns":[{"visible":true,"width":464,"propID":4},\
    {"visible":true,"width":126,"propID":7},{"visible":true,"width":124,"propID":12},\
    {"visible":true,"width":123,"propID":10},{"visible":true,"width":100,"propID":28},\
    {"visible":true,"width":100,"propID":31},{"visible":true,"width":100,"propID":32},\
    {"visible":false,"width":123,"propID":11},{"visible":false,"width":123,"propID":98},\
    {"visible":false,"width":100,"propID":9},{"visible":false,"width":126,"propID":8},\
    {"visible":false,"width":100,"propID":53},{"visible":false,"width":100,"propID":25},\
    {"visible":false,"width":100,"propID":26},{"visible":false,"width":100,"propID":89},\
    {"visible":false,"width":100,"propID":91},{"visible":false,"width":100,"propID":37}]}
    """

    private func decode(_ json: String) -> Settings.ColumnLayout? {
        try? JSONDecoder().decode(Settings.ColumnLayout.self, from: Data(json.utf8))
    }

    private func fsProperties() throws -> [SZPropertyInfo] {
        try SZFileSystemFolder.folder(withPath: NSTemporaryDirectory()).properties
    }

    private func model(_ layout: Settings.ColumnLayout?) throws -> PanelColumnsModel {
        PanelColumnsModel(properties: try fsProperties(), folderType: "FSFolder", isFileSystem: true,
                          hiddenByDefault: Set(SZFileSystemFolder.defaultHiddenPropIDs.map { $0.uint32Value }),
                          layout: layout)
    }

    func testTheUserLayoutLoadsAndHeaderClicksChangeTheSort() throws {
        let layout = try XCTUnwrap(decode(Self.userFSFolderJSON))
        var m = try model(layout)
        XCTAssertEqual(m.sortID, .ctime)
        XCTAssertTrue(m.ascending)
        XCTAssertEqual(m.columns.first?.propID, .name)
        XCTAssertEqual(m.columns.first?.width, 464)
        m.sort(by: .name)
        XCTAssertEqual(m.sortID, .name); XCTAssertTrue(m.ascending)
        m.sort(by: .name)
        XCTAssertFalse(m.ascending)
        m.sort(by: .size)
        XCTAssertEqual(m.sortID, .size); XCTAssertFalse(m.ascending)
    }

    /// The comparator path the panel takes for a folder with IFolderCompare: the ".." row of Show
    /// ".." is not an engine item, and must not make the rows look stale (the 1.1.1 bug).
    func testParentRowDoesNotInvalidateTheEngineRows() {
        let rows = [PanelRow.parent] + (0..<3).map {
            PanelRow(engineIndex: $0, name: "f\($0)", displayName: "f\($0)", isDirectory: false, size: UInt64($0))
        }
        XCTAssertTrue(PanelSorting.engineIndicesAreValid(rows, itemCount: 3), "4 rows, 3 items, one of them ..")
        XCTAssertFalse(PanelSorting.engineIndicesAreValid(rows, itemCount: 2), "the folder shrank meanwhile")
        XCTAssertTrue(PanelSorting.engineIndicesAreValid([.parent], itemCount: 0))
    }

    func testCorruptLayoutsAreSanitised() throws {
        // duplicate, unknown, negative and missing column IDs; Name missing; absurd widths
        let messy = """
        {"sortID":12,"ascending":false,"columns":[{"propID":7,"visible":true,"width":-5},\
        {"propID":7,"visible":false,"width":300},{"propID":99999,"visible":true,"width":100},\
        {"propID":-1,"visible":true,"width":100},{"visible":true,"width":100},"junk",\
        {"propID":12,"visible":true,"width":1000000000}]}
        """
        let layout = try XCTUnwrap(decode(messy), "one bad entry does not lose the layout")
        XCTAssertEqual(layout.columns.map(\.propID), [7, 7, 99999, -1, 12])
        var m = try model(layout)
        XCTAssertEqual(m.columns.first?.propID, .name, "Name is always first and visible")
        XCTAssertTrue(m.columns.first?.visible ?? false)
        XCTAssertEqual(m.columns.filter { $0.propID == .size }.count, 1, "a duplicate is dropped")
        XCTAssertEqual(m.columns.first { $0.propID == .size }?.width, 24, "a negative width is clamped")
        XCTAssertEqual(m.columns.first { $0.propID == .mtime }?.width, PanelColumnsModel.maxWidth)
        XCTAssertEqual(Set(m.columns.map(\.propID)).count, m.columns.count)
        XCTAssertEqual(m.sortID, .mtime)
        m.sort(by: .name)
        XCTAssertEqual(m.sortID, .name)

        // a sort on a column the folder does not have, or on no column at all
        for json in [#"{"sortID":4242,"ascending":false,"columns":[]}"#,
                     #"{"sortID":"x","columns":[]}"#,
                     #"{"columns":[{"propID":4}]}"#,
                     #"{}"#] {
            let l = try XCTUnwrap(decode(json), json)
            var m = try model(l)
            XCTAssertEqual(m.sortID, .name, json)
            m.sort(by: .size)
            XCTAssertEqual(m.sortID, .size, json)
        }

        // a sort on a hidden column is kept (7zFM allows it: Ctrl+F3..F7) and still changes
        let hidden = try XCTUnwrap(decode(#"{"sortID":11,"ascending":true,"columns":[{"propID":11,"visible":false,"width":100}]}"#))
        var h = try model(hidden)
        XCTAssertEqual(h.sortID, .atime)
        XCTAssertFalse(h.visibleColumns.contains { $0.propID == .atime })
        h.sort(by: .name)
        XCTAssertEqual(h.sortID, .name)

        // values of the wrong type: numbers as strings, booleans as numbers
        let typed = try XCTUnwrap(decode(#"{"sortID":"7","ascending":0,"columns":[{"propID":"7","visible":1,"width":"200"}]}"#))
        XCTAssertEqual(typed, Settings.ColumnLayout(sortID: 7, ascending: false,
                                                     columns: [.init(propID: 7, visible: true, width: 200)]))

        // not JSON at all: no layout, the defaults
        XCTAssertNil(decode("not json"))
        XCTAssertNil(decode("[1,2,3]"))
    }

    func testLayoutRoundTripIsUnchanged() throws {
        let layout = try XCTUnwrap(decode(Self.userFSFolderJSON))
        let data = try JSONEncoder().encode(layout)
        XCTAssertEqual(try JSONDecoder().decode(Settings.ColumnLayout.self, from: data), layout)
    }
}
