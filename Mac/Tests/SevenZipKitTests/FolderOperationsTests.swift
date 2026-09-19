// FolderOperationsTests.swift -- SZFolderOperations + SZCallbackAdapters (scope `opsinfra`).
// Fixtures come from Mac/scripts/make-fixtures.sh: readme.txt (12 B), notes.md (21 B),
// sub/big.txt (3000 B), sub/deep/inner.txt (10 B) -> 3043 B in total.

import XCTest
import SevenZipKit

/// Records every callback in arrival order, so tests can assert the protocol sequence.
/// Engine callbacks arrive on the worker thread; a lock keeps the arrays consistent.
final class RecordingProgressDelegate: NSObject, SZProgressDelegate {

    enum Event: Equatable {
        case total(UInt64)
        case completed(UInt64)
        case ratio(UInt64, UInt64)
        case currentFile(String, Bool)
        case numFiles(UInt64)
        case totalFiles(UInt64)
        case status(UInt32)
        case titleFileName(String)
        case message(String)
        case result(Int, String, Bool)
        case askOverwrite(String)
        case askPassword(String)
    }

    private let lock = NSLock()
    private var _events: [Event] = []
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return _events }

    /// Answers handed back to the engine.
    var password: String?
    var overwriteAnswer: SZOverwriteAnswer = .yesToAll
    /// Cancel once this many `progressSetCompleted:` calls have arrived (0 = never).
    var cancelAfterCompletedCalls = 0

    private var completedCalls = 0

    private func add(_ e: Event) { lock.lock(); _events.append(e); lock.unlock() }

    func first<T>(_ transform: (Event) -> T?) -> T? { events.compactMap(transform).first }

    func progressSetTotal(_ total: UInt64) { add(.total(total)) }

    func progressSetCompleted(_ completed: UInt64) {
        lock.lock(); completedCalls += 1; lock.unlock()
        add(.completed(completed))
    }

    func progressSetRatioInfo(inSize: UInt64, outSize: UInt64) { add(.ratio(inSize, outSize)) }
    func progressSetCurrentFile(_ path: String, isDirectory: Bool) { add(.currentFile(path, isDirectory)) }
    func progressSetNumFilesProcessed(_ numFiles: UInt64) { add(.numFiles(numFiles)) }
    func progressSetTotalFiles(_ totalFiles: UInt64) { add(.totalFiles(totalFiles)) }
    func progressSetStatus(_ status: SZProgressStatus) { add(.status(status.rawValue)) }
    func progressSetTitleFileName(_ name: String) { add(.titleFileName(name)) }
    func progressShowMessage(_ message: String) { add(.message(message)) }

    func progressSetOperationResult(_ result: SZOperationResult, path: String, isEncrypted: Bool) {
        add(.result(result.rawValue, path, isEncrypted))
    }

    func progressAskOverwriteExisting(_ existName: String, existTime: Date?, existSize: NSNumber?,
                                     newName: String, newTime: Date?, newSize: NSNumber?,
                                     suggestedName: AutoreleasingUnsafeMutablePointer<NSString?>?) -> SZOverwriteAnswer {
        add(.askOverwrite(existName))
        return overwriteAnswer
    }

    func progressAskPassword(forPath path: String) -> String? {
        add(.askPassword(path))
        return password
    }

    func progressCheckBreak() -> Bool {
        lock.lock(); let calls = completedCalls; lock.unlock()
        return cancelAfterCompletedCalls > 0 && calls >= cancelAfterCompletedCalls
    }
}

final class FolderOperationsTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        try? SZCodecs.loadCodecs()
        try? SZLang.shared.loadLanguage(code: "-")
    }

    private var fixtures: String {
        guard let url = Bundle(for: FolderOperationsTests.self).resourceURL else { fatalError("no resources") }
        return url.appendingPathComponent("Fixtures").path
    }

    private func fixture(_ name: String) -> String { (fixtures as NSString).appendingPathComponent(name) }

    private func tempDir(_ name: String) throws -> String {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("opsinfra-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    /// The bridge blocks, so operations run off the main thread exactly as documented.
    private func offMain<T>(_ body: @escaping () -> T) -> T {
        var result: T!
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result = body()
            done.signal()
        }
        XCTAssertEqual(done.wait(timeout: .now() + 60), .success, "operation timed out")
        return result
    }

    private func archiveRoot(_ name: String, password: String? = nil) throws -> SZFolder {
        let delegate = password.map { FixedPassword(password: $0) }
        let folder = try XCTUnwrap(SZFolder.folder(forPath: fixture(name), passwordDelegate: delegate))
        XCTAssertTrue(folder.isArchive)
        return folder
    }

    final class FixedPassword: NSObject, SZPasswordDelegate {
        let password: String
        init(password: String) { self.password = password }
        func passwordForArchive(atPath path: String) -> String? { password }
    }

    // MARK: capabilities

    func testCapabilities() throws {
        let root = try archiveRoot("test.7z")
        XCTAssertTrue(root.supportsArchiveExtract)          // IArchiveFolder
        XCTAssertTrue(root.supportsOperations)              // CAgentFolder implements IFolderOperations
        XCTAssertFalse(root.supportsCalcItemFullSize)       // the Agent has no IFolderCalcItemFullSize

        let fs = try XCTUnwrap(SZFileSystemFolder.folder(withPath: fixtures))
        XCTAssertFalse(fs.supportsArchiveExtract)
        XCTAssertTrue(fs.supportsOperations)                // declared; methods land with `fsfolder`
    }

    // MARK: extract

    func testExtractProgressCallbackOrder() throws {
        let root = try archiveRoot("test.7z")
        let out = try tempDir("extract")
        let delegate = RecordingProgressDelegate()

        let summary = offMain {
            try? root.extractItems(at: nil, toPath: out, pathMode: .fullPaths,
                                   overwriteMode: .overwrite, testMode: false, progress: delegate)
        }
        let result = try XCTUnwrap(summary)
        XCTAssertEqual(result.filesProcessed, 6)            // 4 files + the dirs sub, sub/deep
        XCTAssertEqual(result.errorCount, 0)
        XCTAssertEqual(result.firstFailure, .OK)
        XCTAssertFalse(result.passwordWasAsked)

        let events = delegate.events
        // status and the archive title arrive before any data
        XCTAssertEqual(events.first, .status(SZProgressStatus.extracting.rawValue))
        XCTAssertTrue(events.contains(.titleFileName(root.fullPath)))
        // SetTotal precedes every SetCompleted, and completion is monotonic
        let totalIndex = try XCTUnwrap(events.firstIndex { if case .total = $0 { return true }; return false })
        let firstCompleted = try XCTUnwrap(events.firstIndex { if case .completed = $0 { return true }; return false })
        XCTAssertLessThan(totalIndex, firstCompleted)
        var last: UInt64 = 0
        for case let .completed(v) in events { XCTAssertGreaterThanOrEqual(v, last); last = v }
        XCTAssertGreaterThan(last, 0)
        // every item announces itself (PrepareOperation) before its result is reported
        let firstFile = try XCTUnwrap(events.firstIndex { if case .currentFile = $0 { return true }; return false })
        let firstResult = try XCTUnwrap(events.firstIndex { if case .result = $0 { return true }; return false })
        XCTAssertLessThan(firstFile, firstResult)
        // the running file counter ends at the number of items
        let processed: [UInt64] = events.compactMap { event in
            if case let .numFiles(n) = event { return n }
            return nil
        }
        XCTAssertEqual(processed.last, 6)
        // ICompressProgressInfo is wired too
        XCTAssertTrue(events.contains { if case .ratio = $0 { return true }; return false })

        // and the files really are on disk
        let fm = FileManager.default
        for (name, size) in [("readme.txt", 12), ("notes.md", 21),
                             ("sub/big.txt", 3000), ("sub/deep/inner.txt", 10)] {
            let path = (out as NSString).appendingPathComponent(name)
            XCTAssertTrue(fm.fileExists(atPath: path), name)
            let attrs = try fm.attributesOfItem(atPath: path)
            XCTAssertEqual(attrs[.size] as? Int, size, name)
        }
    }

    func testExtractSelectedItemsNoPaths() throws {
        let root = try archiveRoot("test.zip")
        let out = try tempDir("selected")
        let index = (0..<root.itemCount).first { root.nameOfItem(at: $0) == "sub" }
        let summary = offMain {
            try? root.extractItems(at: [NSNumber(value: index!)], toPath: out, pathMode: .noPaths,
                                   overwriteMode: .overwrite, testMode: false, progress: nil)
        }
        XCTAssertNotNil(summary)
        // kNoPaths flattens: big.txt and inner.txt land directly in `out`
        XCTAssertTrue(FileManager.default.fileExists(atPath: (out as NSString).appendingPathComponent("big.txt")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: (out as NSString).appendingPathComponent("inner.txt")))
    }

    func testTestModeWritesNothing() throws {
        let root = try archiveRoot("test.7z")
        let out = try tempDir("test-mode")
        let delegate = RecordingProgressDelegate()
        let summary = offMain {
            try? root.extractItems(at: nil, toPath: out, pathMode: .fullPaths,
                                   overwriteMode: .overwrite, testMode: true, progress: delegate)
        }
        XCTAssertEqual(try XCTUnwrap(summary).errorCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out), [])
        XCTAssertTrue(delegate.events.contains(.status(SZProgressStatus.testing.rawValue)))
    }

    func testCancelFailsWithCancelledError() throws {
        let root = try archiveRoot("test.7z")
        let out = try tempDir("cancel")
        let delegate = RecordingProgressDelegate()
        delegate.cancelAfterCompletedCalls = 1       // stop as soon as data starts flowing

        let error: NSError? = offMain {
            do {
                _ = try root.extractItems(at: nil, toPath: out, pathMode: .fullPaths,
                                          overwriteMode: .overwrite, testMode: false, progress: delegate)
                return nil
            } catch {
                return error as NSError
            }
        }
        let e = try XCTUnwrap(error, "cancel must fail the operation")
        XCTAssertEqual(e.domain, SZErrorDomain)
        XCTAssertEqual(e.code, SZError.Code.cancelled.rawValue)
    }

    // MARK: passwords

    func testPasswordDelegateUnlocksEncryptedZip() throws {
        // secret.zip lists without a password; the data needs one (ZipCrypto).
        let root = try archiveRoot("secret.zip")
        let out = try tempDir("secret-zip")
        let delegate = RecordingProgressDelegate()
        delegate.password = "secret"

        let summary = offMain {
            try? root.extractItems(at: nil, toPath: out, pathMode: .fullPaths,
                                   overwriteMode: .overwrite, testMode: false, progress: delegate)
        }
        let result = try XCTUnwrap(summary)
        XCTAssertEqual(result.errorCount, 0)
        XCTAssertTrue(result.passwordWasAsked)
        XCTAssertTrue(delegate.events.contains { if case .askPassword = $0 { return true }; return false })
        let readme = (out as NSString).appendingPathComponent("readme.txt")
        XCTAssertEqual(try String(contentsOfFile: readme, encoding: .utf8), "hello 7-zip\n")
    }

    func testEncryptedHeadersArchiveExtractsWithPassword() throws {
        // secret.7z (-mhe=on): the password is needed to open *and* to extract.
        let root = try archiveRoot("secret.7z", password: "secret")
        let out = try tempDir("secret-7z")
        let delegate = RecordingProgressDelegate()
        delegate.password = "secret"
        let summary = offMain {
            try? root.extractItems(at: nil, toPath: out, pathMode: .fullPaths,
                                   overwriteMode: .overwrite, testMode: false, progress: delegate)
        }
        XCTAssertEqual(try XCTUnwrap(summary).errorCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: (out as NSString).appendingPathComponent("notes.md")))
    }

    func testWrongPasswordReportsWrongPassword() throws {
        let root = try archiveRoot("secret.zip")
        let out = try tempDir("wrong-password")
        let delegate = RecordingProgressDelegate()
        delegate.password = "not-the-password"

        let outcome: (SZOperationSummary?, NSError?) = offMain {
            do {
                return (try root.extractItems(at: nil, toPath: out, pathMode: .fullPaths,
                                              overwriteMode: .overwrite, testMode: false,
                                              progress: delegate), nil)
            } catch {
                return (nil, error as NSError)
            }
        }
        // ZipCrypto detects the bad key per item: the engine itself returns S_OK and the
        // failures arrive as per-item results + messages (ExtractCallback.cpp:375-413).
        if let error = outcome.1 {
            XCTAssertEqual(error.domain, SZErrorDomain)
        }
        let failures = delegate.events.compactMap { event -> (Int, String, Bool)? in
            if case let .result(code, path, encrypted) = event, code != SZOperationResult.OK.rawValue {
                return (code, path, encrypted)
            }
            return nil
        }
        XCTAssertFalse(failures.isEmpty, "a wrong password must fail the encrypted items")
        XCTAssertTrue(failures.contains { $0.2 }, "the failures must be flagged as encrypted")
        XCTAssertTrue(failures.contains { [SZOperationResult.wrongPassword.rawValue,
                                           SZOperationResult.crcError.rawValue,
                                           SZOperationResult.dataError.rawValue].contains($0.0) },
                      "expected wrong password / CRC / data error, got \(failures)")
        XCTAssertTrue(failures.contains { $0.1.hasSuffix("readme.txt") },
                      "the failing item must be named: \(failures)")
        if let summary = outcome.0 {
            XCTAssertGreaterThan(summary.errorCount, 0)
            XCTAssertNotEqual(summary.firstFailure, .OK)
        }
        // and nothing readable was written
        let readme = (out as NSString).appendingPathComponent("readme.txt")
        if let text = try? String(contentsOfFile: readme, encoding: .utf8) {
            XCTAssertNotEqual(text, "hello 7-zip\n")
        }
        XCTAssertTrue(delegate.events.contains { event in
            if case let .message(m) = event { return !m.isEmpty }
            return false
        }, "the failure must produce a diagnostic message")
    }

    func testPasswordCancelAbortsExtraction() throws {
        let root = try archiveRoot("secret.zip")
        let out = try tempDir("password-cancel")
        let delegate = RecordingProgressDelegate()
        delegate.password = nil                     // "Cancel" in the password dialog

        let error: NSError? = offMain {
            do {
                _ = try root.extractItems(at: nil, toPath: out, pathMode: .fullPaths,
                                          overwriteMode: .overwrite, testMode: false, progress: delegate)
                return nil
            } catch {
                return error as NSError
            }
        }
        let e = try XCTUnwrap(error)
        XCTAssertEqual(e.code, SZError.Code.cancelled.rawValue)
    }

    // MARK: overwrite

    func testOverwriteAskGoesThroughTheDelegate() throws {
        let root = try archiveRoot("test.7z")
        let out = try tempDir("overwrite")
        // extract once so the files exist
        _ = offMain {
            try? root.extractItems(at: nil, toPath: out, pathMode: .fullPaths,
                                   overwriteMode: .overwrite, testMode: false, progress: nil)
        }
        let delegate = RecordingProgressDelegate()
        delegate.overwriteAnswer = .noToAll
        let summary = offMain {
            try? root.extractItems(at: nil, toPath: out, pathMode: .fullPaths,
                                   overwriteMode: .ask, testMode: false, progress: delegate)
        }
        XCTAssertNotNil(summary)
        let asked = delegate.events.filter { if case .askOverwrite = $0 { return true }; return false }
        XCTAssertEqual(asked.count, 1, "No to All must be asked once and then remembered")
    }

    // MARK: sizes

    func testCalcSizeMatchesFixtures() throws {
        let root = try archiveRoot("test.7z")
        let all = (0..<root.itemCount).map { NSNumber(value: $0) }
        let total = offMain { try? root.calcSize(at: all, progress: nil) }
        XCTAssertEqual(try XCTUnwrap(total).uint64Value, 3043)      // 12 + 21 + 3000 + 10

        let subIndex = try XCTUnwrap((0..<root.itemCount).first { root.nameOfItem(at: $0) == "sub" })
        let sub = offMain { try? root.calcSize(at: [NSNumber(value: subIndex)], progress: nil) }
        XCTAssertEqual(try XCTUnwrap(sub).uint64Value, 3010)        // 3000 + 10

        let readme = try XCTUnwrap((0..<root.itemCount).first { root.nameOfItem(at: $0) == "readme.txt" })
        let one = offMain { try? root.calcSize(at: [NSNumber(value: readme)], progress: nil) }
        XCTAssertEqual(try XCTUnwrap(one).uint64Value, 12)
    }

    func testCalcSizeOnFileSystemFolderWalksTheTree() throws {
        // A real directory tree: the Fixtures folder itself (no IFolderCalcItemFullSize,
        // so this exercises the BindToFolder fallback).
        let work = try tempDir("calc-fs")
        let sub = (work as NSString).appendingPathComponent("sub")
        try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try Data(count: 100).write(to: URL(fileURLWithPath: (work as NSString).appendingPathComponent("a.bin")))
        try Data(count: 250).write(to: URL(fileURLWithPath: (sub as NSString).appendingPathComponent("b.bin")))

        let folder = try XCTUnwrap(SZFileSystemFolder.folder(withPath: work))
        let all = (0..<folder.itemCount).map { NSNumber(value: $0) }
        let total = offMain { try? folder.calcSize(at: all, progress: nil) }
        XCTAssertEqual(try XCTUnwrap(total).uint64Value, 350)
    }

    // MARK: unimplemented file-system operations

    func testFileSystemOperationsReportClearError() throws {
        // Until the `fsfolder` scope implements IFolderOperations, the file-system folder
        // answers E_NOTIMPL and the bridge must say so clearly (lang 6008 text).
        let work = try tempDir("fs-ops")
        let folder = try XCTUnwrap(SZFileSystemFolder.folder(withPath: work))
        do {
            try folder.createFolder(named: "new", progress: nil)
            // If the operation is implemented (fsfolder landed), the folder must exist.
            XCTAssertTrue(FileManager.default.fileExists(atPath: (work as NSString).appendingPathComponent("new")))
        } catch let error as NSError {
            XCTAssertEqual(error.domain, SZErrorDomain)
            XCTAssertEqual(error.code, SZError.Code.notImplemented.rawValue)
            XCTAssertTrue(error.localizedDescription.contains("not supported"), error.localizedDescription)
        }
    }

    func testArchiveMoveIsNotImplemented() throws {
        // CAgentFolder::CopyTo refuses moveMode (ArchiveFolder.cpp:56), like 7zFM.
        let root = try archiveRoot("test.7z")
        let out = try tempDir("archive-move")
        do {
            try root.moveItems(at: [0], toPath: out, progress: nil)
            XCTFail("moving out of an archive must fail")
        } catch let error as NSError {
            XCTAssertEqual(error.code, SZError.Code.notImplemented.rawValue)
        }
    }

    // MARK: copy out through IFolderOperations::CopyTo

    func testCopyItemsOutOfArchive() throws {
        let root = try archiveRoot("test.zip")
        let out = try tempDir("copy-to")
        let delegate = RecordingProgressDelegate()
        let readme = try XCTUnwrap((0..<root.itemCount).first { root.nameOfItem(at: $0) == "readme.txt" })
        offMain { try? root.copyItems(at: [NSNumber(value: readme)], toPath: out, progress: delegate) }
        XCTAssertEqual(try String(contentsOfFile: (out as NSString).appendingPathComponent("readme.txt"),
                                  encoding: .utf8), "hello 7-zip\n")
        XCTAssertTrue(delegate.events.contains(.status(SZProgressStatus.copying.rawValue)))
    }
}
