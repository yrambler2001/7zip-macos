// SplitCombineTests.swift -- SZSplitFile (scope `tools`): the volume-size parser, the
// volume naming and a split -> combine round trip that must be byte-for-byte identical.

import XCTest
import SevenZipKit

final class SplitCombineTests: XCTestCase {

    private func tempDir(_ name: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tools-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func offMain<T>(_ body: @escaping () -> T) -> T {
        var result: T!
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result = body()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 120), .success, "operation timed out")
        return result
    }

    // MARK: ParseVolumeSizes (SplitUtils.cpp:9-58)

    func testParseVolumeSizes() {
        func parse(_ s: String) -> [UInt64]? {
            SZSplitFile.parseVolumeSizes(s)?.map { $0.uint64Value }
        }
        XCTAssertEqual(parse("10M"), [10 << 20])
        XCTAssertEqual(parse("100m"), [100 << 20])
        XCTAssertEqual(parse("1000"), [1000])
        XCTAssertEqual(parse("512b"), [512])
        XCTAssertEqual(parse("2k"), [2048])
        XCTAssertEqual(parse("3g"), [3 << 30])
        XCTAssertEqual(parse("1t"), [UInt64(1) << 40])
        // "-" ends parsing: the combo's display suffix is ignored
        XCTAssertEqual(parse("650M - CD"), [650 << 20])
        XCTAssertEqual(parse("8128M - DVD DL"), [8128 << 20])
        // a list: successive sizes, the last one repeats
        XCTAssertEqual(parse("10M 20M 30M"), [10 << 20, 20 << 20, 30 << 20])
        // failures
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("abc"))
        XCTAssertNil(parse("0"))
        XCTAssertNil(parse("99999999999999999999t"))
        // every preset the dialog offers parses
        for preset in SZSplitVolumePresets() {
            XCTAssertNotNil(parse(preset), "preset \(preset) does not parse")
        }
        XCTAssertEqual(SZSplitVolumePresets().first, "10M")
        XCTAssertEqual(SZSplitVolumePresets().count, 9)
    }

    func testNumberOfVolumes() {
        XCTAssertEqual(SZSplitFile.numberOfVolumes(forSize: 0, volumeSizes: [1000]), 1)
        XCTAssertEqual(SZSplitFile.numberOfVolumes(forSize: 1000, volumeSizes: [1000]), 1)
        XCTAssertEqual(SZSplitFile.numberOfVolumes(forSize: 2500, volumeSizes: [1000]), 3)
        XCTAssertEqual(SZSplitFile.numberOfVolumes(forSize: 2500, volumeSizes: [1000, 500]), 4)
    }

    func testFirstVolumeNameParsing() {
        var unchanged: NSString?
        XCTAssertTrue(SZSplitFile.parseFirstVolumeName("data.bin.001", unchangedPart: &unchanged))
        XCTAssertEqual(unchanged as String?, "data.bin.")
        XCTAssertEqual(SZSplitFile.combinedName(forFirstVolume: "data.bin.001"), "data.bin")
        XCTAssertTrue(SZSplitFile.parseFirstVolumeName("x.0001", unchangedPart: &unchanged))
        XCTAssertEqual(unchanged as String?, "x.")
        XCTAssertFalse(SZSplitFile.parseFirstVolumeName("data.bin.002", unchangedPart: &unchanged))
        XCTAssertFalse(SZSplitFile.parseFirstVolumeName("data.bin", unchangedPart: &unchanged))
        // trailing dots trimmed, empty falls back to "file"
        XCTAssertEqual(SZSplitFile.combinedName(forFirstVolume: "...001"), "file")
    }

    // MARK: split then combine

    func testSplitAndCombineRoundTrip() throws {
        let dir = try tempDir("split")
        let source = (dir as NSString).appendingPathComponent("data.bin")
        // 700 KiB of non-repeating bytes, so a wrong order would be noticed
        var bytes = [UInt8]()
        bytes.reserveCapacity(700 * 1024)
        var seed: UInt32 = 12345
        for _ in 0..<(700 * 1024) {
            seed = seed &* 1103515245 &+ 12345
            bytes.append(UInt8((seed >> 16) & 0xFF))
        }
        let original = Data(bytes)
        try original.write(to: URL(fileURLWithPath: source))

        let volumeBase = (dir as NSString).appendingPathComponent("data.bin")
        let volumeSize: UInt64 = 200 * 1024
        let recorder = SplitProgressRecorder()
        let ok = offMain {
            (try? SZSplitFile.split(at: source, volumeBasePath: volumeBase,
                                    volumeSizes: [NSNumber(value: volumeSize)],
                                    progress: recorder)) != nil
        }
        XCTAssertTrue(ok)
        XCTAssertEqual(recorder.totals.first, UInt64(original.count))
        XCTAssertGreaterThan(recorder.currentFiles.count, 0)

        let fm = FileManager.default
        // 700 KiB / 200 KiB -> 4 volumes, the last one short
        for (i, expected) in [200 * 1024, 200 * 1024, 200 * 1024, 100 * 1024].enumerated() {
            let name = String(format: "data.bin.%03d", i + 1)
            let path = (dir as NSString).appendingPathComponent(name)
            XCTAssertTrue(fm.fileExists(atPath: path), "missing \(name)")
            let size = (try fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue
            XCTAssertEqual(size, expected, "wrong size for \(name)")
        }
        XCTAssertFalse(fm.fileExists(atPath: (dir as NSString).appendingPathComponent("data.bin.005")))

        // Combine detects the series and joins it
        let names = SZSplitFile.volumeNames(forFirstVolume: "data.bin.001", in: dir)
        XCTAssertEqual(names, ["data.bin.001", "data.bin.002", "data.bin.003", "data.bin.004"])
        let joined = (dir as NSString).appendingPathComponent("joined.bin")
        let combined = offMain {
            (try? SZSplitFile.combine(names, in: dir, to: joined, progress: recorder)) != nil
        }
        XCTAssertTrue(combined)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: joined)), original)

        // an existing destination is refused (Combine asks before calling us)
        XCTAssertThrowsError(try SZSplitFile.combine(names, in: dir, to: joined, progress: nil))
    }

    func testSplitWithSeveralVolumeSizes() throws {
        let dir = try tempDir("split2")
        let source = (dir as NSString).appendingPathComponent("v.bin")
        let original = Data(repeating: 0x5A, count: 1000)
        try original.write(to: URL(fileURLWithPath: source))
        let ok = offMain {
            (try? SZSplitFile.split(at: source, volumeBasePath: source,
                                    volumeSizes: [NSNumber(value: 100), NSNumber(value: 300)],
                                    progress: nil)) != nil
        }
        XCTAssertTrue(ok)
        let fm = FileManager.default
        // 100, then 300 repeating -> 100 + 300 + 300 + 300
        let sizes = (1...4).map { i -> Int in
            let p = (dir as NSString).appendingPathComponent(String(format: "v.bin.%03d", i))
            return ((try? fm.attributesOfItem(atPath: p)[.size]) as? NSNumber)?.intValue ?? -1
        }
        XCTAssertEqual(sizes, [100, 300, 300, 300])
    }
}

final class SplitProgressRecorder: NSObject, SZProgressDelegate {
    private let lock = NSLock()
    private var _totals: [UInt64] = []
    private var _currentFiles: [String] = []
    var totals: [UInt64] { lock.lock(); defer { lock.unlock() }; return _totals }
    var currentFiles: [String] { lock.lock(); defer { lock.unlock() }; return _currentFiles }

    func progressSetTotal(_ total: UInt64) { lock.lock(); _totals.append(total); lock.unlock() }
    func progressSetCompleted(_ completed: UInt64) {}
    func progressSetRatioInfo(inSize: UInt64, outSize: UInt64) {}
    func progressSetCurrentFile(_ path: String, isDirectory: Bool) {
        lock.lock(); _currentFiles.append(path); lock.unlock()
    }
    func progressSetNumFilesProcessed(_ numFiles: UInt64) {}
    func progressShowMessage(_ message: String) {}
    func progressSetOperationResult(_ result: SZOperationResult, path: String, isEncrypted: Bool) {}
    func progressAskOverwriteExisting(_ existName: String, existTime: Date?, existSize: NSNumber?,
                                     newName: String, newTime: Date?, newSize: NSNumber?,
                                     suggestedName: AutoreleasingUnsafeMutablePointer<NSString?>?) -> SZOverwriteAnswer {
        .yesToAll
    }
    func progressAskPassword(forPath path: String) -> String? { nil }
    func progressCheckBreak() -> Bool { false }
}
