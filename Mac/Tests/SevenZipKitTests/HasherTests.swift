// HasherTests.swift -- SZHasher (scope `tools`). Every expected digest is the output of the
// console `7zz h -scrc<method>` on the same bytes, so these are real cross-checks and not
// self-consistency tests.
//
// Reference file: "7-Zip macOS port hash fixture\n" (30 bytes).
// Reference tree: the Mac/Tests/Fixtures source tree (readme.txt 12 B, notes.md 21 B,
// sub/big.txt 3000 B, sub/deep/inner.txt 10 B; 3043 B total), which is also what test.7z holds.

import XCTest
import SevenZipKit

final class HasherTests: XCTestCase {

    /// `7zz h '-scrc*' fixture.txt` for the 30-byte reference file.
    static let referenceContent = "7-Zip macOS port hash fixture\n"
    static let referenceDigests: [String: String] = [
        "CRC32": "A76B9C2E",
        "CRC64": "FB5025AF433D1EC7",
        "XXH64": "5146539DDAA60C1F",
        "MD5": "739b2496bf5ea2a2b083480c40220d2b",
        "SHA1": "b5d5f9fa71eabfad20969f0e03a81ef16f783189",
        "SHA256": "74329aca8ca6bc1f31f1e92ece72f2f9049fe6aa8f66a3e71f9f1e2f7b6b5048",
        "SHA384": "b1952e8a58ffab8856d193aabc2a7c19e0cd19a385725a00c7d8ef9af3c7c0f4891f368049bc2ca39ac361ea3ddc8e54",
        "SHA512": "1480a5f7be4d020097d204135ab7b337af9d915f1876e9c2aed4e12f6626d0067ae1de80e657d888536c69742efb4afae186c49265b866de5470b4037145f181",
        "SHA3-256": "10a076042b3b1d05e3518889259c38868e73fd8794817b69b570d2c5f3c3ac8a",
        "BLAKE2sp": "f8988e4d093ddafc405bb20d1c73cf778d6c9a9dcc858bae399e063419e4808c",
    ]

    /// `7zz h -scrcSHA256 readme.txt notes.md sub` inside the fixture source tree.
    static let treeSHA256: [String: String] = [
        "readme.txt": "948bc6f06db76831933313dfd5192148c20c4557d45af55098b75c16742c21c8",
        "notes.md": "6ca9d5edb68deaadc1d3130c5fc3ec36e12db72ad54e93edcd63bdfb40a83300",
        "sub/big.txt": "f2eb889620bb1c00f5799d261cfa20adb68b0488ed8aa0945df50a5631867432",
        "sub/deep/inner.txt": "30cf6f2de471343739bcc1dde393c0c0771814ac3ad798f68c8a74495174521a",
    ]
    static let treeDataSum = "22f094a22972a416833d86ef346befecd1de14b6d10bc2c9509b99b137cf1b15-00000001"
    static let treeDataAndNamesSum = "01935729363064f1c60f53f97ff93f1465aa62df405318edf102804c40fa6690-00000003"

    override class func setUp() {
        super.setUp()
        try? SZCodecs.loadCodecs()
        try? SZLang.shared.loadLanguage(code: "-")
    }

    private var fixtures: String {
        guard let url = Bundle(for: HasherTests.self).resourceURL else { fatalError("no resources") }
        return url.appendingPathComponent("Fixtures").path
    }

    private func fixture(_ name: String) -> String { (fixtures as NSString).appendingPathComponent(name) }

    private func tempDir(_ name: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("tools-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    /// The reference tree Mac/scripts/make-fixtures.sh builds test.7z from.
    private func makeReferenceTree() throws -> String {
        let root = try tempDir("tree")
        let fm = FileManager.default
        try fm.createDirectory(atPath: (root as NSString).appendingPathComponent("sub/deep"),
                               withIntermediateDirectories: true)
        try "hello 7-zip\n".write(toFile: (root as NSString).appendingPathComponent("readme.txt"),
                                 atomically: true, encoding: .utf8)
        try "line 1\nline 2\nline 3\n".write(toFile: (root as NSString).appendingPathComponent("notes.md"),
                                            atomically: true, encoding: .utf8)
        try String(repeating: "A", count: 3000).write(
            toFile: (root as NSString).appendingPathComponent("sub/big.txt"), atomically: true, encoding: .utf8)
        try "deep file\n".write(toFile: (root as NSString).appendingPathComponent("sub/deep/inner.txt"),
                               atomically: true, encoding: .utf8)
        return root
    }

    private func makeReferenceFile() throws -> (dir: String, path: String) {
        let dir = try tempDir("one")
        let path = (dir as NSString).appendingPathComponent("fixture.txt")
        try Self.referenceContent.write(toFile: path, atomically: true, encoding: .utf8)
        return (dir, path)
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

    // MARK: methods are enumerated, not hard-coded

    func testAvailableMethodsAreEnumerated() {
        let methods = SZHasher.availableMethods
        XCTAssertGreaterThanOrEqual(methods.count, 10)
        let names = Set(methods.map { $0.name })
        for expected in ["CRC32", "CRC64", "XXH64", "MD5", "SHA1", "SHA256", "SHA384", "SHA512",
                         "SHA3-256", "BLAKE2sp"] {
            XCTAssertTrue(names.contains(expected), "missing hasher \(expected)")
        }
        // digest sizes come from IHasher::GetDigestSize
        let byName = Dictionary(uniqueKeysWithValues: methods.map { ($0.name, $0.digestSize) })
        XCTAssertEqual(byName["CRC32"], 4)
        XCTAssertEqual(byName["CRC64"], 8)
        XCTAssertEqual(byName["SHA256"], 32)
        XCTAssertEqual(byName["SHA512"], 64)
        // menu wording (resource.rc:56-69)
        let titles = Dictionary(uniqueKeysWithValues: methods.map { ($0.name, $0.menuTitle) })
        XCTAssertEqual(titles["CRC32"], "CRC-32")
        XCTAssertEqual(titles["SHA256"], "SHA-256")
        XCTAssertEqual(titles["BLAKE2sp"], "BLAKE2sp")
    }

    func testMenuIDMapping() {
        XCTAssertEqual(SZHasher.methodName(forMenuID: 102), "CRC32")   // IDM_CRC32
        XCTAssertEqual(SZHasher.methodName(forMenuID: 121), "BLAKE2sp")// IDM_BLAKE2SP
        XCTAssertEqual(SZHasher.methodName(forMenuID: 101), "*")       // IDM_HASH_ALL
        XCTAssertNil(SZHasher.methodName(forMenuID: 999))
        XCTAssertTrue(SZHasher.isMethodSupported("sha256"))
        XCTAssertFalse(SZHasher.isMethodSupported("NOSUCHHASH"))
    }

    // MARK: every method against 7zz h

    func testEveryMethodMatchesConsole() throws {
        let (dir, path) = try makeReferenceFile()
        for (method, expected) in Self.referenceDigests {
            let results: SZHashResults? = offMain {
                try? SZHasher.hash(paths: [path], relativeTo: dir, methods: [method],
                                   recursive: true, progress: nil)
            }
            let r = try XCTUnwrap(results, "hashing failed for \(method)")
            XCTAssertEqual(r.numFiles, 1)
            XCTAssertEqual(r.filesSize, 30)
            XCTAssertEqual(r.dataDigests[method], expected, "wrong \(method) digest")
            // single file: one row per method with the plain hex (HashGUI.cpp:213-218)
            let row = r.rows.first { $0.name == method }
            XCTAssertEqual(row?.value, expected)
        }
    }

    func testAllMethodsAtOnce() throws {
        let (dir, path) = try makeReferenceFile()
        let r = try XCTUnwrap(offMain {
            try? SZHasher.hash(paths: [path], relativeTo: dir, methods: ["*"],
                               recursive: true, progress: nil)
        })
        XCTAssertEqual(r.methodNames.count, SZHasher.availableMethods.count)
        for (method, expected) in Self.referenceDigests {
            XCTAssertEqual(r.dataDigests[method], expected, "wrong \(method) digest")
        }
    }

    // MARK: multiple files: data / data-and-names variants

    func testMultipleFilesDataAndNames() throws {
        let tree = try makeReferenceTree()
        let paths = ["readme.txt", "notes.md", "sub"].map { (tree as NSString).appendingPathComponent($0) }
        let r = try XCTUnwrap(offMain {
            try? SZHasher.hash(paths: paths, relativeTo: tree, methods: ["SHA256"],
                               recursive: true, progress: nil)
        })
        XCTAssertEqual(r.numFiles, 4)
        XCTAssertEqual(r.numFolders, 2)
        XCTAssertEqual(r.filesSize, 3043)
        XCTAssertEqual(r.dataDigests["SHA256"], Self.treeDataSum)
        XCTAssertEqual(r.dataAndNamesDigests["SHA256"], Self.treeDataAndNamesSum)

        // per-file digests, with names relative to the base folder
        var byPath: [String: String] = [:]
        for file in r.fileResults where !file.isDirectory {
            byPath[file.path] = file.digests["SHA256"]
        }
        XCTAssertEqual(byPath, Self.treeSHA256)

        // rows: Folders + Files + Size, then the two per-method rows (HashGUI.cpp:179-231)
        let names = r.rows.map { $0.name }
        XCTAssertEqual(names.prefix(3).map { $0 }, ["Folders", "Files", "Size"])
        XCTAssertTrue(names.contains("SHA256 checksum for data"))
        XCTAssertTrue(names.contains("SHA256 checksum for data and names"))
        XCTAssertFalse(names.contains(where: { $0.contains("streams and names") }))
        // text form is "name: value" per line
        XCTAssertTrue(r.text.contains("Files: 4"))
        XCTAssertTrue(r.text.contains("Size: 3 043 bytes"))
        // Ctrl+C copies the selected rows as "name: value"
        let copied = r.clipboardText(forRowsAt: IndexSet(integer: 1))
        XCTAssertEqual(copied, "Files: 4\n")
    }

    func testSingleFileRowsUseNameAndPlainDigest() throws {
        let (dir, path) = try makeReferenceFile()
        let r = try XCTUnwrap(offMain {
            try? SZHasher.hash(paths: [path], relativeTo: dir, methods: ["CRC32"],
                               recursive: true, progress: nil)
        })
        XCTAssertEqual(r.rows.map { $0.name }, ["Name", "Size", "CRC32"])
        XCTAssertEqual(r.rows[0].value, "fixture.txt")
        XCTAssertEqual(r.rows[2].value, "A76B9C2E")
        XCTAssertEqual(r.numErrors, 0)
    }

    // MARK: inside an archive (stream mode, nothing extracted)

    func testHashItemsInsideArchive() throws {
        let r: SZHashResults = offMain {
            let folder = try! SZFolder.folder(forPath: self.fixture("test.7z"), passwordDelegate: nil)
            try! folder.loadItems()
            return try! SZHasher.hash(itemsIn: folder, at: nil, methods: ["SHA256"], progress: nil)
        }
        XCTAssertEqual(r.numFiles, 4)
        XCTAssertEqual(r.filesSize, 3043)
        var byPath: [String: String] = [:]
        for file in r.fileResults where !file.isDirectory {
            byPath[file.path] = file.digests["SHA256"]
        }
        XCTAssertEqual(byPath, Self.treeSHA256)
        XCTAssertEqual(r.dataDigests["SHA256"], Self.treeDataSum)
    }

    func testHashSingleItemInsideArchive() throws {
        let r: SZHashResults = offMain {
            let folder = try! SZFolder.folder(forPath: self.fixture("test.7z"), passwordDelegate: nil)
            try! folder.loadItems()
            var index = 0
            for i in 0..<folder.itemCount where folder.nameOfItem(at: i) == "readme.txt" { index = i }
            return try! SZHasher.hash(itemsIn: folder, at: [NSNumber(value: index)],
                                      methods: ["SHA256"], progress: nil)
        }
        XCTAssertEqual(r.numFiles, 1)
        XCTAssertEqual(r.filesSize, 12)
        XCTAssertEqual(r.dataDigests["SHA256"], Self.treeSHA256["readme.txt"])
        XCTAssertEqual(r.rows.first?.name, "Name")
    }

    // MARK: progress and cancellation

    func testProgressAndCancellation() throws {
        let tree = try makeReferenceTree()
        let recorder = HashProgressRecorder()
        let r = offMain {
            try? SZHasher.hash(paths: [tree], relativeTo: nil, methods: ["SHA256"],
                               recursive: true, progress: recorder)
        }
        XCTAssertNotNil(r)
        XCTAssertGreaterThan(recorder.totals.count, 0)
        XCTAssertTrue(recorder.statuses.contains(SZProgressStatus.scanning.rawValue))
        XCTAssertTrue(recorder.statuses.contains(SZProgressStatus.checksum.rawValue))
        XCTAssertGreaterThan(recorder.currentFiles.count, 0)

        let canceller = HashProgressRecorder()
        canceller.breakImmediately = true
        var thrown: Error?
        let cancelled: SZHashResults? = offMain {
            do {
                return try SZHasher.hash(paths: [tree], relativeTo: nil, methods: ["SHA256"],
                                         recursive: true, progress: canceller)
            } catch {
                thrown = error
                return nil
            }
        }
        XCTAssertNil(cancelled)
        XCTAssertEqual((thrown as NSError?)?.code, SZError.Code.cancelled.rawValue)
    }

    // MARK: checksum files

    func testWriteAndVerifyChecksumFile() throws {
        let tree = try makeReferenceTree()
        let destination = (tree as NSString).appendingPathComponent("tree.sha256")
        let paths = ["readme.txt", "notes.md", "sub"].map { (tree as NSString).appendingPathComponent($0) }

        _ = offMain {
            try? SZHasher.writeChecksumFile(at: destination, forPaths: paths, relativeTo: tree,
                                            method: "SHA256", recursive: true, progress: nil)
        }
        let text = try String(contentsOfFile: destination, encoding: .utf8)
        // coreutils text form: "<hex>  <name>" (HashCalc.cpp WriteLine)
        XCTAssertTrue(text.contains("\(Self.treeSHA256["readme.txt"]!)  readme.txt\n"))
        XCTAssertTrue(text.contains("\(Self.treeSHA256["sub/deep/inner.txt"]!)  sub/deep/inner.txt\n"))
        XCTAssertEqual(text.split(separator: "\n").count, 4)

        let ok = try XCTUnwrap(offMain { try? SZHasher.verifyChecksumFile(at: destination, progress: nil) })
        XCTAssertTrue(ok.succeeded)
        XCTAssertEqual(ok.numOK, 4)
        XCTAssertEqual(ok.numFailed, 0)
        XCTAssertTrue(ok.text.contains("There are no errors"))

        // corrupt one file -> the verification reports it
        try "tampered\n".write(toFile: (tree as NSString).appendingPathComponent("readme.txt"),
                               atomically: true, encoding: .utf8)
        let bad = try XCTUnwrap(offMain { try? SZHasher.verifyChecksumFile(at: destination, progress: nil) })
        XCTAssertFalse(bad.succeeded)
        XCTAssertEqual(bad.numFailed, 1)
        XCTAssertEqual(bad.numOK, 3)
        XCTAssertTrue(bad.messages.contains { $0.hasPrefix("readme.txt : ") })

        // a missing file is reported too
        try FileManager.default.removeItem(atPath: (tree as NSString).appendingPathComponent("notes.md"))
        let missing = try XCTUnwrap(offMain { try? SZHasher.verifyChecksumFile(at: destination, progress: nil) })
        XCTAssertEqual(missing.numMissing, 1)
    }

    func testChecksumFileNaming() {
        XCTAssertEqual(SZHasher.checksumFileName(forPaths: ["/tmp/a/readme.txt"], relativeToPath: "/tmp/a",
                                                 method: "SHA256"), "readme.txt.sha256")
        XCTAssertEqual(SZHasher.checksumFileName(forPaths: ["/tmp/a/x", "/tmp/a/y"], relativeToPath: "/tmp/a",
                                                 method: "SHA3-256"), "a.sha3256")
    }

    func testVerifyBSDTagForm() throws {
        let (dir, _) = try makeReferenceFile()
        let checksumPath = (dir as NSString).appendingPathComponent("tags.txt")
        let digest = Self.referenceDigests["SHA256"]!
        try "SHA256 (fixture.txt) = \(digest)\n".write(toFile: checksumPath, atomically: true, encoding: .utf8)
        let v = try XCTUnwrap(offMain { try? SZHasher.verifyChecksumFile(at: checksumPath, progress: nil) })
        XCTAssertTrue(v.succeeded)
        XCTAssertEqual(v.numOK, 1)
        XCTAssertEqual(v.methodNames, ["SHA256"])
    }
}

/// Minimal SZProgressDelegate for the hashing tests.
final class HashProgressRecorder: NSObject, SZProgressDelegate {
    private let lock = NSLock()
    private var _totals: [UInt64] = []
    private var _statuses: [UInt32] = []
    private var _currentFiles: [String] = []
    private var _messages: [String] = []
    var breakImmediately = false

    var totals: [UInt64] { lock.lock(); defer { lock.unlock() }; return _totals }
    var statuses: [UInt32] { lock.lock(); defer { lock.unlock() }; return _statuses }
    var currentFiles: [String] { lock.lock(); defer { lock.unlock() }; return _currentFiles }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return _messages }

    func progressSetTotal(_ total: UInt64) { lock.lock(); _totals.append(total); lock.unlock() }
    func progressSetCompleted(_ completed: UInt64) {}
    func progressSetRatioInfo(inSize: UInt64, outSize: UInt64) {}
    func progressSetCurrentFile(_ path: String, isDirectory: Bool) {
        lock.lock(); _currentFiles.append(path); lock.unlock()
    }
    func progressSetNumFilesProcessed(_ numFiles: UInt64) {}
    func progressSetStatus(_ status: SZProgressStatus) {
        lock.lock(); _statuses.append(status.rawValue); lock.unlock()
    }
    func progressShowMessage(_ message: String) { lock.lock(); _messages.append(message); lock.unlock() }
    func progressSetOperationResult(_ result: SZOperationResult, path: String, isEncrypted: Bool) {}
    func progressAskOverwriteExisting(_ existName: String, existTime: Date?, existSize: NSNumber?,
                                     newName: String, newTime: Date?, newSize: NSNumber?,
                                     suggestedName: AutoreleasingUnsafeMutablePointer<NSString?>?) -> SZOverwriteAnswer {
        .yesToAll
    }
    func progressAskPassword(forPath path: String) -> String? { nil }
    func progressCheckBreak() -> Bool { breakImmediately }
}
