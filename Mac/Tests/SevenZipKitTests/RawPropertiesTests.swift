// RawPropertiesTests.swift -- IArchiveGetRawProps in the panel columns and in Properties
// (01 §3.2, §3.11; PanelItems.cpp:177-199, PanelListNotify.cpp:265-349, PanelMenu.cpp:212-246,
// PanelSort.cpp:99-132). parity.md D item 7 / B item 11.
//
// Fixtures (Mac/scripts/make-fixtures.sh): test.wim from 7zz (SHA-1, reparse data and NT security
// are the WIM handler's raw properties) and test.xar from /usr/bin/xar (the per-file checksum).
// The expected digests are `shasum` of the fixture files' contents.

import XCTest
import SevenZipKit

final class RawPropertiesTests: XCTestCase {

    private static let readmeSHA1 = "6e2988371ac7aef631f90a38c9d022794bd8df14"   // "hello 7-zip\n"

    override class func setUp() {
        super.setUp()
        try? SZCodecs.loadCodecs()
        try? SZLang.shared.loadLanguage(code: "-")
    }

    private func fixture(_ name: String) -> String {
        let url = Bundle(for: RawPropertiesTests.self).resourceURL!.appendingPathComponent("Fixtures")
        return url.appendingPathComponent(name).path
    }

    private func root(_ name: String) throws -> SZFolder {
        let archive = try SZArchiveOpener.openArchive(atPath: fixture(name), formatHint: nil, passwordDelegate: nil)
        return try archive.rootFolder()
    }

    private func index(_ name: String, _ folder: SZFolder) throws -> Int {
        try XCTUnwrap((0..<folder.itemCount).first { folder.nameOfItem(at: $0) == name },
                       "no \(name) in \((0..<folder.itemCount).map { folder.nameOfItem(at: $0) })")
    }

    private func sha1(ofFixtureMember text: String) -> String {
        // shasum of the member's bytes, computed here so the test does not hard-code more digests
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try? process.run()
        input.fileHandleForWriting.write(text.data(using: .utf8)!)
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        let line = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return String(line.prefix(40))
    }

    /// Tree handlers go through CProxyArc2; before the AgentProxy.cpp patch (upstream-patches.md)
    /// every name was a run of NULs on macOS.
    func testTreeHandlerItemNamesAreReadable() throws {
        for name in ["test.wim", "test.xar"] {
            let folder = try root(name)
            let names = (0..<folder.itemCount).map { folder.nameOfItem(at: $0) }.filter { !$0.hasPrefix("[") }
            XCTAssertEqual(names.sorted(), ["notes.md", "readme.txt", "sub"], name)
        }
    }

    func testWimListsRawColumnsAfterTheFolderOwnAndHidesNTSecurity() throws {
        let folder = try root("test.wim")
        let props = folder.properties
        let raw = props.filter { $0.isRawProperty }
        XCTAssertEqual(raw.map { $0.propID }, [.sha1, .ntReparse], "WimHandler kRawProps minus kpidNtSecure")
        XCTAssertFalse(props.contains { $0.propID == .ntSecure }, "NT security stays hidden (01 §9 #7)")
        // raw columns come last, as CPanel::InitColumns appends them
        let firstRaw = try XCTUnwrap(props.firstIndex { $0.isRawProperty })
        XCTAssertTrue(props[firstRaw...].allSatisfy { $0.isRawProperty })
        XCTAssertEqual(raw.first?.varType, .empty)
        XCTAssertEqual(raw.first?.localizedName, "SHA-1")
        XCTAssertFalse(props.first { $0.propID == .name }?.isRawProperty ?? true)
    }

    func testWimSha1CellAndPropertiesTextAreLowerCaseHex() throws {
        let folder = try root("test.wim")
        let readme = try index("readme.txt", folder)
        XCTAssertEqual(folder.displayStringOfItem(at: readme, propID: .sha1, timestampLevel: .min), Self.readmeSHA1)
        XCTAssertEqual(folder.rawPropertyString(at: readme, propID: .sha1, forPropertiesDialog: true), Self.readmeSHA1)
        XCTAssertEqual(folder.rawPropertyOfItem(at: readme, propID: .sha1)?.count, 20)
        let notes = try index("notes.md", folder)
        XCTAssertEqual(folder.displayStringOfItem(at: notes, propID: .sha1, timestampLevel: .min),
                       sha1(ofFixtureMember: "line 1\nline 2\nline 3\n"))
        // a directory has no stream and no hash; no reparse data on a plain file
        let sub = try index("sub", folder)
        XCTAssertEqual(folder.displayStringOfItem(at: sub, propID: .sha1, timestampLevel: .min), "")
        XCTAssertNil(folder.rawPropertyOfItem(at: sub, propID: .sha1))
        XCTAssertEqual(folder.displayStringOfItem(at: readme, propID: .ntReparse, timestampLevel: .min), "")
        // not a raw property of this folder
        XCTAssertNil(folder.rawPropertyOfItem(at: readme, propID: .checksum))
        XCTAssertEqual(folder.rawPropertyString(at: readme, propID: .size, forPropertiesDialog: false), "")
    }

    func testWimSubfolderAndFlatModeKeepTheRawValues() throws {
        let folder = try root("test.wim")
        let sub = try folder.bindToFolder(at: try index("sub", folder))
        let deep = try sub.bindToFolder(at: try index("deep", sub))
        let inner = try index("inner.txt", deep)
        XCTAssertEqual(deep.displayStringOfItem(at: inner, propID: .sha1, timestampLevel: .min),
                       sha1(ofFixtureMember: "deep file\n"))
        folder.flatMode = true
        try folder.loadItems()
        let flatReadme = try index("readme.txt", folder)
        XCTAssertEqual(folder.displayStringOfItem(at: flatReadme, propID: .sha1, timestampLevel: .min), Self.readmeSHA1)
    }

    func testRawSortPutsEmptyValuesFirstAndOrdersByBytes() throws {
        let folder = try root("test.wim")
        let readme = try index("readme.txt", folder)
        let notes = try index("notes.md", folder)
        let sub = try index("sub", folder)
        XCTAssertLessThan(folder.compareItem(at: sub, with: readme, propID: .sha1), 0, "empty first")
        XCTAssertGreaterThan(folder.compareItem(at: readme, with: sub, propID: .sha1), 0)
        XCTAssertEqual(folder.compareItem(at: sub, with: sub, propID: .sha1), 0)
        let a = folder.displayStringOfItem(at: readme, propID: .sha1, timestampLevel: .min)
        let b = folder.displayStringOfItem(at: notes, propID: .sha1, timestampLevel: .min)
        let expected = a < b ? -1 : 1
        XCTAssertEqual(folder.compareItem(at: readme, with: notes, propID: .sha1).signum(), expected,
                       "byte order = lower-case hex order")
        XCTAssertEqual(folder.compareItem(at: notes, with: readme, propID: .sha1).signum(), -expected)
    }

    func testXarChecksumIsARawColumn() throws {
        let folder = try root("test.xar")
        let raw = folder.properties.filter { $0.isRawProperty }
        XCTAssertEqual(raw.map { $0.propID }, [.checksum])
        let readme = try index("readme.txt", folder)
        // 20 bytes > 8, so lower case even for kpidChecksum
        XCTAssertEqual(folder.displayStringOfItem(at: readme, propID: .checksum, timestampLevel: .min), Self.readmeSHA1)
    }

    func testFormatsWithoutRawPropertiesListNone() throws {
        for name in ["test.7z", "test.zip", "test.tar.gz"] {
            XCTAssertFalse(try root(name).properties.contains { $0.isRawProperty }, name)
        }
        let fs = try SZFolder.folder(forPath: (fixture("test.7z") as NSString).deletingLastPathComponent,
                                     passwordDelegate: nil)
        XCTAssertFalse(fs.properties.contains { $0.isRawProperty })
    }

    /// Archive-level "2" properties exist only between two levels; level 0 used to read
    /// CArchiveLink::Arcs[-1] and crash the Properties dialog of every archive.
    func testArcProps2OnlyBetweenLevels() throws {
        let single = try XCTUnwrap(try root("test.wim").arcProps)
        XCTAssertEqual(single.levelCount, 1)
        XCTAssertEqual(single.properties2(atLevel: 0), [])
        XCTAssertNil(single.property2(atLevel: 0, propID: .size))
        XCTAssertEqual(single.properties(atLevel: 5), [])
        // a .tar.gz opens as one gzip level here (the tar is an item), so it has none either
        let gz = try XCTUnwrap(try root("test.tar.gz").arcProps)
        XCTAssertEqual(gz.properties2(atLevel: gz.levelCount - 1), [])
    }

    /// The two upstream renderers: the list cell (64-byte limit, reparse decoded) and the
    /// Properties dialog (256-byte limit), hex upper case only for a CRC / checksum <= 8 bytes.
    func testRawFormatterLimitsAndCase() {
        let crc = Data([0xde, 0xad, 0xbe, 0xef])
        XCTAssertEqual(SZFolder.rawPropertyString(data: crc, propID: .checksum, forPropertiesDialog: false), "DEADBEEF")
        XCTAssertEqual(SZFolder.rawPropertyString(data: crc, propID: .crc, forPropertiesDialog: true), "DEADBEEF")
        XCTAssertEqual(SZFolder.rawPropertyString(data: crc, propID: .sha1, forPropertiesDialog: false), "deadbeef")
        let nine = Data(repeating: 0xab, count: 9)
        XCTAssertEqual(SZFolder.rawPropertyString(data: nine, propID: .checksum, forPropertiesDialog: false),
                       String(repeating: "ab", count: 9))
        let big = Data(repeating: 1, count: 65)
        XCTAssertEqual(SZFolder.rawPropertyString(data: big, propID: .sha256, forPropertiesDialog: false), "data:65")
        XCTAssertEqual(SZFolder.rawPropertyString(data: big, propID: .sha256, forPropertiesDialog: true),
                       String(repeating: "01", count: 65))
        XCTAssertEqual(SZFolder.rawPropertyString(data: Data(repeating: 1, count: 257), propID: .sha256,
                                                  forPropertiesDialog: true), "data:257")
        XCTAssertEqual(SZFolder.rawPropertyString(data: Data(), propID: .sha1, forPropertiesDialog: true), "")
    }
}
