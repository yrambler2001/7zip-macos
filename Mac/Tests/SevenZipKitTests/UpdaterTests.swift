// UpdaterTests.swift -- SZUpdater, the create/update bridge (scope `compress`).
// Parity references: 01b-fm-dialogs-settings.md sections 4.23, 4.24;
// 01-fm-feature-inventory.md section 8.5.
//
// Archives produced here are cross-checked with the console 7zz built from this tree
// (CPP/7zip/Bundles/Alone2/b/m_arm64/7zz) whenever it is present, and always by re-opening
// them through SZArchiveOpener / SZFolder.

import XCTest
import SevenZipKit

/// Minimal SZProgressDelegate for the update side: records what arrived, answers passwords,
/// and can cancel after N progress callbacks.
final class UpdateRecorder: NSObject, SZProgressDelegate {

    private let lock = NSLock()
    private var _statuses: [UInt32] = []
    private var _files: [String] = []
    private var _messages: [String] = []
    private var _scanned: (folders: UInt64, files: UInt64, size: UInt64) = (0, 0, 0)
    private var _total: UInt64 = 0
    private var _totalFiles: UInt64 = 0
    private var _numFiles: UInt64 = 0
    private var _completedCalls = 0
    private var _titleFileNames: [String] = []
    private var _movedArchive: (from: String, to: String)?

    var statuses: [UInt32] { lock.withLock { _statuses } }
    var currentFiles: [String] { lock.withLock { _files } }
    var messages: [String] { lock.withLock { _messages } }
    var scanned: (folders: UInt64, files: UInt64, size: UInt64) { lock.withLock { _scanned } }
    var total: UInt64 { lock.withLock { _total } }
    var totalFiles: UInt64 { lock.withLock { _totalFiles } }
    var filesProcessed: UInt64 { lock.withLock { _numFiles } }
    var titleFileNames: [String] { lock.withLock { _titleFileNames } }
    var movedArchive: (from: String, to: String)? { lock.withLock { _movedArchive } }

    /// Password handed to ICryptoGetTextPassword2 (nil = "no password").
    var encryptionPassword: String?
    /// Password handed to ICryptoGetTextPassword (re-opening an encrypted archive).
    var decryptionPassword: String?
    var encryptionCancelled = false
    /// Cancel once this many progressSetCompleted: calls arrived (0 = never).
    var cancelAfterCompletedCalls = 0
    private(set) var askedForEncryptionPassword = false

    func progressSetTotal(_ total: UInt64) { lock.withLock { _total = total } }

    func progressSetCompleted(_ completed: UInt64) {
        lock.withLock { _completedCalls += 1 }
    }

    func progressSetRatioInfo(inSize: UInt64, outSize: UInt64) {}

    func progressSetCurrentFile(_ path: String, isDirectory: Bool) {
        lock.withLock { if _files.last != path { _files.append(path) } }
    }

    func progressSetNumFilesProcessed(_ numFiles: UInt64) { lock.withLock { _numFiles = numFiles } }
    func progressSetTotalFiles(_ totalFiles: UInt64) { lock.withLock { _totalFiles = totalFiles } }
    func progressSetStatus(_ status: SZProgressStatus) { lock.withLock { _statuses.append(status.rawValue) } }
    func progressSetTitleFileName(_ name: String) { lock.withLock { _titleFileNames.append(name) } }
    func progressShowMessage(_ message: String) { lock.withLock { _messages.append(message) } }

    func progressScanFolders(_ numFolders: UInt64, files numFiles: UInt64, totalSize: UInt64,
                             path: String, isDirectory: Bool) {
        lock.withLock { _scanned = (numFolders, numFiles, totalSize) }
    }

    func progressSetOperationResult(_ result: SZOperationResult, path: String, isEncrypted: Bool) {}

    func progressAskOverwriteExisting(_ existName: String, existTime: Date?, existSize: NSNumber?,
                                      newName: String, newTime: Date?, newSize: NSNumber?,
                                      suggestedName: AutoreleasingUnsafeMutablePointer<NSString?>?)
        -> SZOverwriteAnswer { .yesToAll }

    func progressAskPassword(forPath path: String) -> String? { decryptionPassword }

    func progressAskPassword(forEncryptionCancelled cancelled: UnsafeMutablePointer<ObjCBool>) -> String? {
        askedForEncryptionPassword = true
        cancelled.pointee = ObjCBool(encryptionCancelled)
        return encryptionPassword
    }

    func progressMoveArchive(from sourcePath: String, toPath destinationPath: String, size: UInt64) {
        lock.withLock { _movedArchive = (sourcePath, destinationPath) }
    }

    func progressCheckBreak() -> Bool {
        lock.withLock { cancelAfterCompletedCalls > 0 && _completedCalls >= cancelAfterCompletedCalls }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}

// ---------------------------------------------------------------------------

class UpdaterTestCase: XCTestCase {

    /// The repository root, derived from this file's compile-time path, so the tests can find
    /// the bundled SFX stubs and the console 7zz without depending on the app bundle.
    static let repoRoot: String = {
        // <root>/Mac/Tests/SevenZipKitTests/UpdaterTests.swift
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url.path
    }()

    static var sfxDirectory: String { (repoRoot as NSString).appendingPathComponent("Mac/Resources/SFX") }

    /// The console 7zz built from this tree, or nil when it has not been built.
    static var consoleTool: String? {
        let p = (repoRoot as NSString).appendingPathComponent("CPP/7zip/Bundles/Alone2/b/m_arm64/7zz")
        return FileManager.default.isExecutableFile(atPath: p) ? p : nil
    }

    override class func setUp() {
        super.setUp()
        // SZUpdater.defaultSFXModulePath looks at SEVENZIP_SFX_DIR first; the app finds the
        // stubs in its own bundle, the test bundle has no app around it.
        setenv("SEVENZIP_SFX_DIR", sfxDirectory, 1)
        try? SZCodecs.loadCodecs()
        try? SZLang.shared.loadLanguage(code: "-")
    }

    // MARK: helpers

    func tempDir(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("compress-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    /// A small tree: readme.txt, notes.md, sub/big.txt (3000 B), sub/deep/inner.txt.
    /// The same shape `Mac/scripts/make-fixtures.sh` builds, so sizes are predictable.
    @discardableResult
    func makeSourceTree(in dir: String) throws -> [String] {
        let fm = FileManager.default
        let sub = (dir as NSString).appendingPathComponent("sub")
        let deep = (sub as NSString).appendingPathComponent("deep")
        try fm.createDirectory(atPath: deep, withIntermediateDirectories: true)
        try "hello 7-zip\n".write(toFile: (dir as NSString).appendingPathComponent("readme.txt"),
                                 atomically: true, encoding: .utf8)
        try "# notes\nsecond line\n".write(toFile: (dir as NSString).appendingPathComponent("notes.md"),
                                          atomically: true, encoding: .utf8)
        try String(repeating: "A", count: 3000).write(toFile: (sub as NSString).appendingPathComponent("big.txt"),
                                                     atomically: true, encoding: .utf8)
        try "inner\n".write(toFile: (deep as NSString).appendingPathComponent("inner.txt"),
                            atomically: true, encoding: .utf8)
        return [(dir as NSString).appendingPathComponent("readme.txt"),
                (dir as NSString).appendingPathComponent("notes.md"),
                sub]
    }

    /// The bridge blocks, so every call runs off the main thread as documented.
    func offMain<T>(timeout: TimeInterval = 120, _ body: @escaping () -> T) -> T {
        var result: T!
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result = body()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + timeout), .success, "operation timed out")
        return result
    }

    @discardableResult
    func update(_ options: SZUpdateOptions, _ paths: [String],
                progress: SZProgressDelegate? = nil) throws -> SZUpdateResult {
        let outcome: Result<SZUpdateResult, Error> = offMain {
            do { return .success(try SZUpdater.update(with: options, sourcePaths: paths, progress: progress)) }
            catch { return .failure(error) }
        }
        return try outcome.get()
    }

    /// Runs the console 7zz and returns its stdout, or nil when the tool is not built.
    func runConsole(_ arguments: [String]) -> (status: Int32, output: String)? {
        guard let tool = Self.consoleTool else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Names of every item of the archive, recursively, through the bridge (SZFolder).
    func archiveEntryNames(_ path: String, password: String? = nil) throws -> [String] {
        let delegate = password.map { FixedPasswordDelegate(password: $0) }
        var names: [String] = []
        let outcome: Result<[String], Error> = offMain {
            do {
                let root = try SZFolder.folder(forPath: path, passwordDelegate: delegate)
                func walk(_ folder: SZFolder, prefix: String) throws {
                    try folder.loadItems()
                    for i in 0..<folder.itemCount {
                        let name = folder.nameOfItem(at: i)
                        let full = prefix.isEmpty ? name : prefix + "/" + name
                        names.append(full)
                        if folder.isDirectory(at: i) {
                            try walk(folder.bindToFolder(at: i), prefix: full)
                        }
                    }
                }
                try walk(root, prefix: "")
                return .success(names.sorted())
            } catch { return .failure(error) }
        }
        return try outcome.get()
    }

    final class FixedPasswordDelegate: NSObject, SZPasswordDelegate {
        let password: String
        init(password: String) { self.password = password }
        func passwordForArchive(atPath path: String) -> String? { password }
    }
}

// ---------------------------------------------------------------------------

final class UpdaterBasicsTests: UpdaterTestCase {

    func testSFXStubsAreBundled() throws {
        let gui = try XCTUnwrap(SZUpdater.defaultSFXModulePath, "7z.sfx not found")
        XCTAssertTrue(gui.hasSuffix("7z.sfx"))
        XCTAssertNotNil(SZUpdater.sfxModulePath(named: "7zCon.sfx"))
        XCTAssertNil(SZUpdater.sfxModulePath(named: "nosuch.sfx"))
    }

    func testFormatSupportsUpdate() {
        XCTAssertTrue(SZUpdater.formatSupportsUpdate("7z"))
        XCTAssertTrue(SZUpdater.formatSupportsUpdate("zip"))
        XCTAssertTrue(SZUpdater.formatSupportsUpdate("tar"))
        XCTAssertFalse(SZUpdater.formatSupportsUpdate("rar"))    // read-only handler
        XCTAssertFalse(SZUpdater.formatSupportsUpdate("nosuch"))
    }

    /// 01b 4.23 "Parameter generation": the property list is passed through verbatim.
    func testPropertySwitchText() {
        XCTAssertEqual(SZUpdateProperty(name: "x", value: "9").switchText, "x=9")
        XCTAssertEqual(SZUpdateProperty(name: "rsfx", value: nil).switchText, "rsfx")
    }

    func testCreate7zAndReopen() throws {
        let src = try tempDir("src7z")
        let items = try makeSourceTree(in: src)
        let out = try tempDir("out7z")
        let archive = (out as NSString).appendingPathComponent("a.7z")

        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        options.properties = [SZUpdateProperty(name: "x", value: "5")]
        let recorder = UpdateRecorder()
        let result = try update(options, items, progress: recorder)

        XCTAssertEqual(result.archivePath, archive)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive))
        XCTAssertGreaterThan(result.archiveSize, 0)
        XCTAssertEqual(result.errorCount, 0)
        XCTAssertEqual(result.failedPaths, [])
        // 4 files were scanned and compressed.
        XCTAssertEqual(recorder.scanned.files, 4)
        XCTAssertEqual(result.scannedFileCount, 4)
        XCTAssertEqual(recorder.statuses.first, SZProgressStatus.scanning.rawValue)
        XCTAssertTrue(recorder.statuses.contains(SZProgressStatus.compressing.rawValue))
        XCTAssertTrue(recorder.statuses.contains(SZProgressStatus.add.rawValue))

        // Relative path mode (the dialog default): names are relative to the common prefix.
        let names = try archiveEntryNames(archive)
        XCTAssertEqual(names, ["notes.md", "readme.txt", "sub", "sub/big.txt", "sub/deep",
                               "sub/deep/inner.txt"])

        if let console = runConsole(["t", archive]) {
            XCTAssertEqual(console.status, 0, console.output)
            XCTAssertTrue(console.output.contains("Everything is Ok"), console.output)
        }
    }
}

// ---------------------------------------------------------------------------

/// Every updatable format the Compress dialog offers (01b 4.23 "Format table"), plus the
/// level / method matrix for the main ones.
final class UpdaterFormatsTests: UpdaterTestCase {

    @discardableResult
    private func createAndVerify(format: String, extension ext: String,
                                 properties: [SZUpdateProperty] = [],
                                 singleFile: Bool = false,
                                 file: StaticString = #filePath, line: UInt = #line) throws -> SZUpdateResult {
        let src = try tempDir("src-\(format)")
        let items: [String]
        if singleFile {
            // Flags_KeepName formats (gzip / bzip2 / xz) take exactly one regular file.
            let one = (src as NSString).appendingPathComponent("readme.txt")
            try String(repeating: "single stream payload\n", count: 40).write(toFile: one, atomically: true,
                                                                             encoding: .utf8)
            items = [one]
        } else {
            items = try makeSourceTree(in: src)
        }
        let out = try tempDir("out-\(format)")
        let archive = (out as NSString).appendingPathComponent("a." + ext)

        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = format
        options.properties = properties
        let result = try update(options, items)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive), "no archive for \(format)",
                      file: file, line: line)
        XCTAssertGreaterThan(result.archiveSize, 0, file: file, line: line)
        XCTAssertEqual(result.errorCount, 0, file: file, line: line)

        // Reopening through the bridge must list something.
        let names = try archiveEntryNames(archive)
        XCTAssertFalse(names.isEmpty, "\(format): nothing listed", file: file, line: line)

        // And the console must accept it.
        if let console = runConsole(["t", archive]) {
            XCTAssertEqual(console.status, 0, "\(format): 7zz t failed\n\(console.output)",
                           file: file, line: line)
        }
        return result
    }

    func testCreate7z() throws { try createAndVerify(format: "7z", extension: "7z") }
    func testCreateZip() throws { try createAndVerify(format: "zip", extension: "zip") }
    func testCreateTar() throws { try createAndVerify(format: "tar", extension: "tar") }
    func testCreateWim() throws { try createAndVerify(format: "wim", extension: "wim") }
    func testCreateGZip() throws { try createAndVerify(format: "gzip", extension: "gz", singleFile: true) }
    func testCreateBZip2() throws { try createAndVerify(format: "bzip2", extension: "bz2", singleFile: true) }
    func testCreateXz() throws { try createAndVerify(format: "xz", extension: "xz", singleFile: true) }

    /// Tar's two header formats are its "methods" (g_TarMethods = GNU, POSIX).
    func testTarHeaderMethods() throws {
        for method in ["GNU", "POSIX"] {
            _ = try createAndVerify(format: "tar", extension: "tar",
                                    properties: [SZUpdateProperty(name: "m", value: method)])
        }
    }

    /// 7z levels 0...9; level 0 is Store, level 9 Ultra (01b 4.23 level list).
    func test7zAllLevels() throws {
        var sizes: [Int: UInt64] = [:]
        for level in 0...9 {
            let r = try createAndVerify(format: "7z", extension: "7z",
                                        properties: [SZUpdateProperty(name: "x", value: "\(level)")])
            sizes[level] = r.archiveSize
        }
        // Store (0) keeps the payload uncompressed, so it must be the largest.
        XCTAssertGreaterThan(try XCTUnwrap(sizes[0]), try XCTUnwrap(sizes[9]))
    }

    /// The 7z method combo: LZMA2 (auto/first), LZMA, PPMd, BZip2 (Copy/Deflate/Deflate64 are
    /// hidden in the dialog but the handler accepts them).
    func test7zMethods() throws {
        for method in ["LZMA2", "LZMA", "PPMd", "BZip2", "Copy", "Deflate"] {
            _ = try createAndVerify(format: "7z", extension: "7z",
                                    properties: [SZUpdateProperty(name: "0", value: method)])
        }
    }

    /// The zip method combo: g_ZipMethods = Deflate, Deflate64, BZip2, LZMA, PPMd.
    func testZipMethods() throws {
        for method in ["Deflate", "Deflate64", "BZip2", "LZMA", "PPMd"] {
            _ = try createAndVerify(format: "zip", extension: "zip",
                                    properties: [SZUpdateProperty(name: "m", value: method)])
        }
    }

    /// Zip's level list is 0, 1, 3, 5, 7, 9 (LevelsMask).
    func testZipLevels() throws {
        for level in [0, 1, 3, 5, 7, 9] {
            _ = try createAndVerify(format: "zip", extension: "zip",
                                    properties: [SZUpdateProperty(name: "x", value: "\(level)")])
        }
    }

    /// A read-only handler must be refused before anything is written (IDS_UPDATE_NOT_SUPPORTED).
    func testReadOnlyFormatRefused() throws {
        let out = try tempDir("ro")
        let options = SZUpdateOptions(archivePath: (out as NSString).appendingPathComponent("a.rar"))
        options.formatName = "rar"
        XCTAssertThrowsError(try update(options, [])) { error in
            XCTAssertEqual((error as NSError).code, SZError.Code.unsupported.rawValue)
        }
    }
}

// ---------------------------------------------------------------------------

/// Solid blocks, encryption, volumes, SFX, delete-after, timestamps, cancellation:
/// the parts of 01b 4.23 / 4.24 that change the produced bytes.
final class UpdaterOptionsTests: UpdaterTestCase {

    /// `s=0b` (Non-solid) vs `s=<2^log>b`: a non-solid 7z has one folder per file, so a
    /// per-file extraction of one entry does not need the others.
    func testSolidAndNonSolid() throws {
        let src = try tempDir("solid-src")
        let items = try makeSourceTree(in: src)
        let out = try tempDir("solid-out")

        let solidPath = (out as NSString).appendingPathComponent("solid.7z")
        let solid = SZUpdateOptions(archivePath: solidPath)
        solid.formatName = "7z"
        solid.properties = [SZUpdateProperty(name: "x", value: "5"),
                            SZUpdateProperty(name: "s", value: "18446744073709551615b")]  // "Solid"
        _ = try update(solid, items)

        let nonSolidPath = (out as NSString).appendingPathComponent("nonsolid.7z")
        let nonSolid = SZUpdateOptions(archivePath: nonSolidPath)
        nonSolid.formatName = "7z"
        nonSolid.properties = [SZUpdateProperty(name: "x", value: "5"),
                               SZUpdateProperty(name: "s", value: "0b")]  // IDS_COMPRESS_NON_SOLID
        _ = try update(nonSolid, items)

        // Both list the same items.
        XCTAssertEqual(try archiveEntryNames(solidPath), try archiveEntryNames(nonSolidPath))

        guard let listSolid = runConsole(["l", "-slt", solidPath]),
              let listNonSolid = runConsole(["l", "-slt", nonSolidPath]) else { return }
        // In a solid archive the three data files share one block, so only the first entry of
        // the block carries a Block index change; a non-solid archive has one block each.
        let blocksSolid = Set(blockIDs(in: listSolid.output))
        let blocksNonSolid = Set(blockIDs(in: listNonSolid.output))
        XCTAssertEqual(blocksSolid.count, 1, listSolid.output)
        XCTAssertGreaterThan(blocksNonSolid.count, blocksSolid.count, listNonSolid.output)
    }

    private func blockIDs(in listing: String) -> [String] {
        listing.split(separator: "\n")
            .filter { $0.hasPrefix("Block = ") }
            .map { String($0.dropFirst("Block = ".count)) }
    }

    /// "Enter password" (IDE_COMPRESS_PASSWORD1 120): the archive lists without a password but
    /// needs one to extract.
    func testEncrypted7zListsButNeedsPasswordToRead() throws {
        let src = try tempDir("enc-src")
        let items = try makeSourceTree(in: src)
        let out = try tempDir("enc-out")
        let archive = (out as NSString).appendingPathComponent("enc.7z")

        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        options.password = "secret"
        _ = try update(options, items)

        // Names are visible (he=off).
        XCTAssertTrue(try archiveEntryNames(archive).contains("readme.txt"))
        if let bad = runConsole(["t", "-pwrong", archive]) {
            XCTAssertNotEqual(bad.status, 0, "wrong password accepted:\n\(bad.output)")
        }
        if let good = runConsole(["t", "-psecret", archive]) {
            XCTAssertEqual(good.status, 0, good.output)
        }
    }

    /// "Encrypt file names" IDX_COMPRESS_ENCRYPT_FILE_NAMES 4016 -> `he=on`: listing without a
    /// password must fail.
    func testEncryptedHeadersCannotListWithoutPassword() throws {
        let src = try tempDir("hdr-src")
        let items = try makeSourceTree(in: src)
        let out = try tempDir("hdr-out")
        let archive = (out as NSString).appendingPathComponent("hdr.7z")

        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        options.password = "secret"
        options.properties = [SZUpdateProperty(name: "he", value: "on")]
        _ = try update(options, items)

        XCTAssertThrowsError(try archiveEntryNames(archive)) { error in
            let code = (error as NSError).code
            XCTAssertTrue(code == SZError.Code.passwordRequired.rawValue
                          || code == SZError.Code.wrongPassword.rawValue
                          || code == SZError.Code.notArchive.rawValue,
                          "unexpected code \(code)")
        }
        XCTAssertEqual(try archiveEntryNames(archive, password: "secret").contains("readme.txt"), true)
    }

    /// Zip + AES-256 through `em=AES256` (IDC_COMPRESS_ENCRYPTION_METHOD 122); ZipCrypto is the
    /// default and emits nothing.
    func testZipEncryptionMethods() throws {
        let src = try tempDir("zipenc-src")
        let items = try makeSourceTree(in: src)
        let out = try tempDir("zipenc-out")

        for (name, props) in [("zipcrypto.zip", [SZUpdateProperty]()),
                              ("aes.zip", [SZUpdateProperty(name: "em", value: "AES256")])] {
            let archive = (out as NSString).appendingPathComponent(name)
            let options = SZUpdateOptions(archivePath: archive)
            options.formatName = "zip"
            options.password = "secret"
            options.properties = props
            _ = try update(options, items)
            if let console = runConsole(["t", "-psecret", archive]) {
                XCTAssertEqual(console.status, 0, "\(name): \(console.output)")
            }
        }
        if let listing = runConsole(["l", "-slt", "-psecret",
                                    (out as NSString).appendingPathComponent("aes.zip")]) {
            XCTAssertTrue(listing.output.contains("AES"), listing.output)
        }
    }

    /// "Split to volumes, bytes:" IDC_COMPRESS_VOLUME 105 (-v): .001/.002 next to each other,
    /// and the set rejoins.
    func testSplitVolumes() throws {
        let src = try tempDir("vol-src")
        let big = (src as NSString).appendingPathComponent("big.bin")
        // 300 KB of incompressible-ish data so the volumes really split.
        var data = Data(count: 0)
        var seed: UInt32 = 1
        for _ in 0..<(300 * 1024) {
            seed = seed &* 1103515245 &+ 12345
            data.append(UInt8(truncatingIfNeeded: seed >> 16))
        }
        try data.write(to: URL(fileURLWithPath: big))

        let out = try tempDir("vol-out")
        let archive = (out as NSString).appendingPathComponent("v.7z")
        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        options.volumeSizes = [NSNumber(value: 64 * 1024)]
        let result = try update(options, [big])

        XCTAssertTrue(result.isMultiVolume)
        XCTAssertGreaterThan(result.volumeCount, 1)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: archive + ".001"))
        XCTAssertTrue(fm.fileExists(atPath: archive + ".002"))
        XCTAssertFalse(fm.fileExists(atPath: archive), "an unsplit archive was written too")

        // The volume set rejoins. `-v` is a plain byte split of one archive stream, so
        // concatenating the volumes must give a valid single-file archive, and the console
        // (which has the IArchiveOpenVolumeCallback chain) must accept the .001 as it stands.
        let fm2 = FileManager.default
        let volumeNames = try fm2.contentsOfDirectory(atPath: out)
            .filter { $0.hasPrefix("v.7z.") }.sorted()
        XCTAssertEqual(volumeNames.count, Int(result.volumeCount))
        var joined = Data()
        for name in volumeNames {
            joined.append(try Data(contentsOf: URL(fileURLWithPath: (out as NSString)
                .appendingPathComponent(name))))
        }
        let rejoined = (out as NSString).appendingPathComponent("rejoined.7z")
        try joined.write(to: URL(fileURLWithPath: rejoined))
        XCTAssertEqual(try archiveEntryNames(rejoined), ["big.bin"])
        if let console = runConsole(["t", archive + ".001"]) {
            XCTAssertEqual(console.status, 0, console.output)
        }
    }

    /// "Create SFX archive" IDX_COMPRESS_SFX 4012: the bundled stub is prepended byte for byte
    /// and the payload still extracts.
    func testSFXArchive() throws {
        let src = try tempDir("sfx-src")
        let items = try makeSourceTree(in: src)
        let out = try tempDir("sfx-out")
        let archive = (out as NSString).appendingPathComponent("s.exe")

        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        options.sfxMode = true
        let result = try update(options, items)
        XCTAssertEqual(result.archivePath, archive)

        let stubPath = try XCTUnwrap(SZUpdater.defaultSFXModulePath)
        let stub = try Data(contentsOf: URL(fileURLWithPath: stubPath))
        let produced = try Data(contentsOf: URL(fileURLWithPath: archive))
        XCTAssertGreaterThan(produced.count, stub.count)
        XCTAssertEqual(produced.prefix(stub.count), stub, "the SFX stub prefix is not byte-identical")
        XCTAssertEqual(produced.prefix(2), Data([0x4D, 0x5A]))  // "MZ": a Windows executable

        // The payload behind the stub is a normal 7z archive.
        XCTAssertEqual(try archiveEntryNames(archive),
                       ["notes.md", "readme.txt", "sub", "sub/big.txt", "sub/deep", "sub/deep/inner.txt"])
        if let console = runConsole(["t", "-t7z", archive]) {
            XCTAssertEqual(console.status, 0, console.output)
        }
    }

    /// "Delete files after compression" IDX_COMPRESS_DEL 4019 (-sdel).
    func testDeleteAfterCompressingRemovesSources() throws {
        let src = try tempDir("del-src")
        let items = try makeSourceTree(in: src)
        let out = try tempDir("del-out")
        let archive = (out as NSString).appendingPathComponent("d.7z")

        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        options.deleteAfterCompressing = true
        let recorder = UpdateRecorder()
        let result = try update(options, items, progress: recorder)

        let fm = FileManager.default
        for item in items {
            XCTAssertFalse(fm.fileExists(atPath: item), "\(item) survived -sdel")
        }
        XCTAssertFalse(result.deletedPaths.isEmpty)
        XCTAssertTrue(recorder.statuses.contains(SZProgressStatus.removing.rawValue))
    }

    /// A failed run must leave the sources alone: the archive cannot be written into a
    /// non-existent directory, so nothing is deleted.
    func testDeleteAfterCompressingKeepsSourcesOnFailure() throws {
        let src = try tempDir("delfail-src")
        let items = try makeSourceTree(in: src)
        let archive = "/nonexistent-7zip-dir-\(UUID().uuidString)/d.7z"

        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        options.deleteAfterCompressing = true
        options.workingDirectory = ""      // build in place, so the failure happens at create
        XCTAssertThrowsError(try update(options, items))

        let fm = FileManager.default
        for item in items {
            XCTAssertTrue(fm.fileExists(atPath: item), "\(item) was deleted although the run failed")
        }
    }

    /// Cancelling mid-compression: E_ABORT -> SZErrorCodeCancelled and no archive left behind
    /// (the engine writes a temp file and only moves it on success).
    func testCancelLeavesNoArchive() throws {
        let src = try tempDir("cancel-src")
        let big = (src as NSString).appendingPathComponent("big.bin")
        var data = Data()
        var seed: UInt32 = 7
        for _ in 0..<(8 * 1024 * 1024) {
            seed = seed &* 1103515245 &+ 12345
            data.append(UInt8(truncatingIfNeeded: seed >> 16))
        }
        try data.write(to: URL(fileURLWithPath: big))

        let out = try tempDir("cancel-out")
        let archive = (out as NSString).appendingPathComponent("c.7z")
        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        options.properties = [SZUpdateProperty(name: "x", value: "9")]
        let recorder = UpdateRecorder()
        recorder.cancelAfterCompletedCalls = 1

        XCTAssertThrowsError(try update(options, [big], progress: recorder)) { error in
            XCTAssertEqual((error as NSError).code, SZError.Code.cancelled.rawValue)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive),
                       "a partial archive was left behind")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: out)
        XCTAssertEqual(leftovers, [], "temp files left in the output directory: \(leftovers)")
    }

    /// Compress Options: `tm`/`tc`/`ta` and `tp` (01b 4.24). zip stores mtime only unless the
    /// Windows precision is asked for, so `tc=on tp=0` must make a creation time appear.
    func testZipTimestampOptions() throws {
        let src = try tempDir("time-src")
        let one = (src as NSString).appendingPathComponent("readme.txt")
        try "t\n".write(toFile: one, atomically: true, encoding: .utf8)
        let out = try tempDir("time-out")

        let plain = (out as NSString).appendingPathComponent("plain.zip")
        let p = SZUpdateOptions(archivePath: plain)
        p.formatName = "zip"
        _ = try update(p, [one])

        let withTimes = (out as NSString).appendingPathComponent("times.zip")
        let t = SZUpdateOptions(archivePath: withTimes)
        t.formatName = "zip"
        t.properties = [SZUpdateProperty(name: "tc", value: "on"),
                        SZUpdateProperty(name: "ta", value: "on"),
                        SZUpdateProperty(name: "tp", value: "0")]      // kTimePrec_Win
        _ = try update(t, [one])

        guard let plainList = runConsole(["l", "-slt", plain]),
              let timesList = runConsole(["l", "-slt", withTimes]) else { return }
        XCTAssertFalse(plainList.output.contains("Created = "), plainList.output)
        XCTAssertTrue(timesList.output.contains("Created = "), timesList.output)
        XCTAssertTrue(timesList.output.contains("Accessed = "), timesList.output)

        // `tm=off` drops the modification time for a KeepName format (gzip stores it by default).
        let noMTime = (out as NSString).appendingPathComponent("nomtime.gz")
        let g = SZUpdateOptions(archivePath: noMTime)
        g.formatName = "gzip"
        g.properties = [SZUpdateProperty(name: "tm", value: "off")]
        _ = try update(g, [one])
        if let gzList = runConsole(["l", "-slt", noMTime]) {
            XCTAssertFalse(gzList.output.contains("Modified = "), gzList.output)
        }
    }

    /// "Set archive time to latest file time" IDX_COMPRESS_ZTIME 4085 (-stl).
    func testSetArchiveMTime() throws {
        let src = try tempDir("stl-src")
        let one = (src as NSString).appendingPathComponent("readme.txt")
        try "t\n".write(toFile: one, atomically: true, encoding: .utf8)
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: one)

        let out = try tempDir("stl-out")
        let archive = (out as NSString).appendingPathComponent("stl.7z")
        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        options.setArchiveMTime = true
        _ = try update(options, [one])

        let attrs = try FileManager.default.attributesOfItem(atPath: archive)
        let mtime = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertEqual(mtime.timeIntervalSince1970, past.timeIntervalSince1970, accuracy: 2)
    }

    /// "Store symbolic links" IDX_COMPRESS_NT_SYM_LINKS 4040 (-snl): on the archive keeps the
    /// link, off follows it.
    func testSymbolicLinkOption() throws {
        let src = try tempDir("link-src")
        let target = (src as NSString).appendingPathComponent("target.txt")
        try "payload\n".write(toFile: target, atomically: true, encoding: .utf8)
        let link = (src as NSString).appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "target.txt")

        let out = try tempDir("link-out")
        for (name, store) in [("stored.7z", true), ("followed.7z", false)] {
            let archive = (out as NSString).appendingPathComponent(name)
            let options = SZUpdateOptions(archivePath: archive)
            options.formatName = "7z"
            options.storeSymLinks = NSNumber(value: store)
            _ = try update(options, [target, link])
            guard let listing = runConsole(["l", "-slt", archive]) else { continue }
            // A stored link has the symlink attribute bit; a followed link is a plain copy.
            let hasLinkAttr = listing.output.contains("Attributes = ")
                && listing.output.split(separator: "\n").contains { $0.hasPrefix("Attributes = ") && $0.contains("l") }
            XCTAssertEqual(hasLinkAttr, store, "\(name): \(listing.output)")
        }
    }
}

// ---------------------------------------------------------------------------

/// Updating an existing archive: add, update modes, entry deletion, MoveArc.
final class UpdaterInPlaceTests: UpdaterTestCase {

    private func make7z(_ dir: String, _ items: [String]) throws -> String {
        let archive = (dir as NSString).appendingPathComponent("a.7z")
        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        _ = try update(options, items)
        return archive
    }

    func testAddToExistingArchive() throws {
        let src = try tempDir("inplace-src")
        let one = (src as NSString).appendingPathComponent("readme.txt")
        try "one\n".write(toFile: one, atomically: true, encoding: .utf8)
        let out = try tempDir("inplace-out")
        let archive = try make7z(out, [one])
        XCTAssertEqual(try archiveEntryNames(archive), ["readme.txt"])

        let two = (src as NSString).appendingPathComponent("extra.md")
        try "two\n".write(toFile: two, atomically: true, encoding: .utf8)
        let recorder = UpdateRecorder()
        let outcome: Result<SZUpdateResult, Error> = offMain {
            do { return .success(try SZUpdater.addPaths([two], toArchiveAt: archive, options: nil,
                                                        progress: recorder)) }
            catch { return .failure(error) }
        }
        _ = try outcome.get()
        XCTAssertEqual(try archiveEntryNames(archive), ["extra.md", "readme.txt"])
        // The finished temp archive is moved over the original (IFolderArchiveUpdateCallback_MoveArc).
        XCTAssertNotNil(recorder.movedArchive)
    }

    func testDeleteEntryFromArchive() throws {
        let src = try tempDir("deent-src")
        let items = try makeSourceTree(in: src)
        let out = try tempDir("deent-out")
        let archive = try make7z(out, items)
        XCTAssertTrue(try archiveEntryNames(archive).contains("notes.md"))

        let outcome: Result<SZUpdateResult, Error> = offMain {
            do { return .success(try SZUpdater.deleteItems(named: ["notes.md"], fromArchiveAt: archive,
                                                           options: nil, progress: nil)) }
            catch { return .failure(error) }
        }
        _ = try outcome.get()
        let names = try archiveEntryNames(archive)
        XCTAssertFalse(names.contains("notes.md"))
        XCTAssertTrue(names.contains("readme.txt"))
    }

    /// "Freshen existing files" only refreshes what is already inside; a new file is not added.
    func testFreshenMode() throws {
        let src = try tempDir("fresh-src")
        let one = (src as NSString).appendingPathComponent("readme.txt")
        try "v1\n".write(toFile: one, atomically: true, encoding: .utf8)
        let out = try tempDir("fresh-out")
        let archive = try make7z(out, [one])

        let two = (src as NSString).appendingPathComponent("new.txt")
        try "new\n".write(toFile: two, atomically: true, encoding: .utf8)
        try "v2 longer content\n".write(toFile: one, atomically: true, encoding: .utf8)

        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        options.nameMode = .exact
        options.updateMode = .fresh
        _ = try update(options, [one, two])

        XCTAssertEqual(try archiveEntryNames(archive), ["readme.txt"])
        if let listing = runConsole(["l", archive]) {
            XCTAssertTrue(listing.output.contains("18"), listing.output)   // the refreshed size
        }

        // Add mode does take the new file.
        let add = SZUpdateOptions(archivePath: archive)
        add.formatName = "7z"
        add.nameMode = .exact
        add.updateMode = .add
        _ = try update(add, [one, two])
        XCTAssertEqual(try archiveEntryNames(archive), ["new.txt", "readme.txt"])
    }

    /// "Synchronize files": an archive entry the censor covers but that is gone from disk is
    /// dropped (k_ActionSet_Sync: kOnlyInArchive -> kIgnore). An entry the censor does *not*
    /// cover is kNotMasked -> kCopy and survives, which is why 7zFM's Sync is used with the
    /// whole folder selected.
    func testSyncMode() throws {
        let src = try tempDir("sync-src")
        let dir = (src as NSString).appendingPathComponent("tree")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let a = (dir as NSString).appendingPathComponent("a.txt")
        let b = (dir as NSString).appendingPathComponent("b.txt")
        try "a\n".write(toFile: a, atomically: true, encoding: .utf8)
        try "b\n".write(toFile: b, atomically: true, encoding: .utf8)
        let out = try tempDir("sync-out")
        let archive = try make7z(out, [dir])
        XCTAssertEqual(try archiveEntryNames(archive), ["tree", "tree/a.txt", "tree/b.txt"])

        try FileManager.default.removeItem(atPath: b)
        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        options.nameMode = .exact
        options.updateMode = .sync
        _ = try update(options, [dir])
        XCTAssertEqual(try archiveEntryNames(archive), ["tree", "tree/a.txt"])

        // Add mode keeps it instead (kOnlyInArchive -> kCopy).
        let archive2 = try make7z(try tempDir("sync-out2"), [dir])
        XCTAssertEqual(try archiveEntryNames(archive2), ["tree", "tree/a.txt"])
    }

    /// Path modes (IDC_COMPRESS_PATH_MODE 116): relative vs absolute names in the archive.
    func testPathModes() throws {
        let src = try tempDir("pm-src")
        let sub = (src as NSString).appendingPathComponent("sub")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        let inner = (sub as NSString).appendingPathComponent("inner.txt")
        try "i\n".write(toFile: inner, atomically: true, encoding: .utf8)
        let out = try tempDir("pm-out")

        let relative = (out as NSString).appendingPathComponent("rel.7z")
        let r = SZUpdateOptions(archivePath: relative)
        r.formatName = "7z"
        r.pathMode = .relative
        _ = try update(r, [inner])
        XCTAssertEqual(try archiveEntryNames(relative), ["inner.txt"])

        let absolute = (out as NSString).appendingPathComponent("abs.7z")
        let a = SZUpdateOptions(archivePath: absolute)
        a.formatName = "7z"
        a.pathMode = .absolute
        _ = try update(a, [inner])
        // k_AbsPath keeps the whole path (without the leading separator) inside the archive.
        let names = try archiveEntryNames(absolute)
        XCTAssertTrue(names.contains { $0.hasSuffix("inner.txt") && $0.contains("/") }, "\(names)")
    }

    /// The default archive name rules of 03 section 1.6 (CreateArchiveName).
    func testArchiveBaseName() throws {
        let dir = try tempDir("name")
        let fm = FileManager.default
        let file = (dir as NSString).appendingPathComponent("report.txt")
        try "x".write(toFile: file, atomically: true, encoding: .utf8)
        var base: NSString?
        // one file -> name without the single-dot extension
        XCTAssertEqual(SZUpdater.archiveBaseName(forItemPaths: [file], isHash: false, baseName: &base),
                       "report")
        // a folder keeps its name
        let folder = (dir as NSString).appendingPathComponent("my.folder")
        try fm.createDirectory(atPath: folder, withIntermediateDirectories: true)
        XCTAssertEqual(SZUpdater.archiveBaseName(forItemPaths: [folder], isHash: false, baseName: &base),
                       "my.folder")
        // several items -> the common parent folder's name
        let names = SZUpdater.archiveBaseName(forItemPaths: [file, folder], isHash: false, baseName: &base)
        XCTAssertEqual(names, (dir as NSString).lastPathComponent)
        // Several items whose parent folder is "pack" and one of them is "pack.7z" -> "pack_2"
        // (CreateArchiveName's collision loop; 03 section 1.6).
        let pack = (dir as NSString).appendingPathComponent("pack")
        try fm.createDirectory(atPath: pack, withIntermediateDirectories: true)
        let inside = (pack as NSString).appendingPathComponent("a.txt")
        let packArchive = (pack as NSString).appendingPathComponent("pack.7z")
        try "x".write(toFile: inside, atomically: true, encoding: .utf8)
        try "x".write(toFile: packArchive, atomically: true, encoding: .utf8)
        XCTAssertEqual(SZUpdater.archiveBaseName(forItemPaths: [inside, packArchive], isHash: false,
                                                 baseName: &base), "pack_2")
        XCTAssertEqual(base, "pack")
        // With pack_2.7z there too the next free number is used.
        let pack2 = (pack as NSString).appendingPathComponent("pack_2.7z")
        try "x".write(toFile: pack2, atomically: true, encoding: .utf8)
        XCTAssertEqual(SZUpdater.archiveBaseName(forItemPaths: [inside, packArchive, pack2],
                                                 isHash: false, baseName: &base), "pack_3")
    }
}
