// CodecsSignatureTests.swift -- `SZCodecs` lookup by signature (architecture "SZCodecs singleton",
// 03 §3.2): the header bytes of each fixture match its own handler, and a concurrent first load
// from several threads hands every caller the full table (the codecs are built on a worker at
// launch, `AppDelegate`, 01 §1.1).

import XCTest
import SevenZipKit

final class CodecsSignatureTests: XCTestCase {

    private func fixture(_ name: String) -> String {
        guard let url = Bundle(for: CodecsSignatureTests.self).resourceURL else { fatalError("no resources") }
        return url.appendingPathComponent("Fixtures").appendingPathComponent(name).path
    }

    private func header(of name: String) throws -> Data {
        let handle = try XCTUnwrap(FileHandle(forReadingAtPath: fixture(name)))
        defer { try? handle.close() }
        return handle.readData(ofLength: 1 << 16)
    }

    func testFixturesMatchTheirOwnHandlerBySignature() throws {
        try SZCodecs.loadCodecs()
        let expected = ["test.7z": "7z", "test.zip": "zip", "test.tar.gz": "gzip",
                        "test.tar.xz": "xz", "test.wim": "wim", "test.xar": "xar"]
        for (file, format) in expected {
            let names = SZCodecs.formats(matchingHeader: try header(of: file)).map(\.name.localizedLowercase)
            XCTAssertTrue(names.contains(format), "\(file): matched \(names), expected \(format)")
        }
    }

    func testSignaturesAreExposed() throws {
        try SZCodecs.loadCodecs()
        let sevenZip = try XCTUnwrap(SZCodecs.format(named: "7z"))
        XCTAssertEqual(sevenZip.signatureCount, sevenZip.signatures.count)
        XCTAssertEqual(sevenZip.signatures.first, Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]))
        XCTAssertEqual(sevenZip.signatureOffset, 0)
    }

    func testRandomBytesMatchNoSignatureHandler() {
        let noise = Data(repeating: 0x5A, count: 512)
        XCTAssertTrue(SZCodecs.formats(matchingHeader: noise).isEmpty)
        XCTAssertTrue(SZCodecs.formats(matchingHeader: Data()).isEmpty)
    }

    func testConcurrentReadersSeeTheWholeTable() {
        let counts = NSMutableArray()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let n = SZCodecs.formats.count
            objc_sync_enter(counts); counts.add(n); objc_sync_exit(counts)
        }
        let values = Set(counts.compactMap { $0 as? Int })
        XCTAssertEqual(values.count, 1, "every reader saw the same table: \(values)")
        XCTAssertGreaterThan(values.first ?? 0, 50)
    }
}
