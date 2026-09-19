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
