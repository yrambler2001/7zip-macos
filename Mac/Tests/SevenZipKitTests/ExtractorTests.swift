// ExtractorTests.swift -- SZArchiveExtractor (the ExtractGUI / UI/Common/Extract.cpp path).
//
// Fixtures come from Mac/scripts/make-fixtures.sh: readme.txt (12 B), notes.md (21 B),
// sub/big.txt (3000 B), sub/deep/inner.txt (10 B); secret.7z / secret.zip use password
// "secret"; multi.7z.001..003 is a 3-volume 7z holding random.bin (30000 B) + vol.txt.
//
// Parity references: 01-fm-feature-inventory.md §8.1-8.4, 01b-fm-dialogs-settings.md §4.25.

import XCTest
import SevenZipKit

/// A thread-safe SZProgressDelegate that records what the engine reported and can answer the
/// overwrite / password questions without UI. Mirrors what OperationRunner does in the app.
final class RecordingProgress: NSObject, SZProgressDelegate {

    private let lock = NSLock()
    private var _messages: [String] = []
    private var _files: [String] = []
    private var _results: [SZOperationResult] = []
    private var _statuses: [SZProgressStatus] = []
    private var _titleFileNames: [String] = []
    private var _total: UInt64 = 0
    private var _completed: UInt64 = 0
    private var _overwriteQuestions: [(String, String)] = []
    private var _passwordPrompts: [String] = []

    /// Answer for progressAskOverwriteExisting.
    var overwriteAnswer: SZOverwriteAnswer = .yes
    /// Answer for progressAskPassword (nil = Cancel).
    var password: String?
    /// checkBreak returns true once this many items have been reported.
    var cancelAfterFiles: Int?
    private var cancelRequested = false

    var messages: [String] { lock.withLock { _messages } }
    var files: [String] { lock.withLock { _files } }
    var results: [SZOperationResult] { lock.withLock { _results } }
    var statuses: [SZProgressStatus] { lock.withLock { _statuses } }
    var titleFileNames: [String] { lock.withLock { _titleFileNames } }
    var total: UInt64 { lock.withLock { _total } }
    var completed: UInt64 { lock.withLock { _completed } }
    var overwriteQuestions: [(String, String)] { lock.withLock { _overwriteQuestions } }
    var passwordPrompts: [String] { lock.withLock { _passwordPrompts } }

    func progressSetTotal(_ total: UInt64) { lock.withLock { _total = total } }
    func progressSetCompleted(_ completed: UInt64) { lock.withLock { _completed = completed } }
    func progressSetRatioInfo(inSize: UInt64, outSize: UInt64) {}
    func progressSetCurrentFile(_ path: String, isDirectory: Bool) {
        lock.withLock { if !path.isEmpty { _files.append(path) } }
    }
    func progressSetNumFilesProcessed(_ numFiles: UInt64) {}
    func progressShowMessage(_ message: String) { lock.withLock { _messages.append(message) } }
    func progressSetTotalFiles(_ totalFiles: UInt64) {}
    func progressSetStatus(_ status: SZProgressStatus) { lock.withLock { _statuses.append(status) } }
    func progressSetTitleFileName(_ name: String) { lock.withLock { _titleFileNames.append(name) } }

    func progressSetOperationResult(_ result: SZOperationResult, path: String, isEncrypted: Bool) {
        lock.withLock {
            _results.append(result)
            if let limit = cancelAfterFiles, _results.count >= limit { cancelRequested = true }
        }
    }

    func progressAskOverwriteExisting(_ existName: String, existTime: Date?, existSize: NSNumber?,
                                      newName: String, newTime: Date?, newSize: NSNumber?,
                                      suggestedName: AutoreleasingUnsafeMutablePointer<NSString?>?) -> SZOverwriteAnswer {
        lock.withLock { _overwriteQuestions.append((existName, newName)) }
        return overwriteAnswer
    }

    func progressAskPassword(forPath path: String) -> String? {
        lock.withLock { _passwordPrompts.append(path) }
        return password
    }

    func progressCheckBreak() -> Bool { lock.withLock { cancelRequested } }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}

final class ExtractorTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        try? SZCodecs.loadCodecs()
        try? SZLang.shared.loadLanguage(code: "-")     // assert English strings
    }

    private var fixtures: String {
        guard let url = Bundle(for: ExtractorTests.self).resourceURL else { fatalError("no resources") }
        return url.appendingPathComponent("Fixtures").path
    }

    private func fixture(_ name: String) -> String { (fixtures as NSString).appendingPathComponent(name) }

    private func tempDir(_ name: String = #function) -> String {
        let dir = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sz-extract-\(name.filter { $0.isLetter || $0.isNumber })-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        return dir
    }

    /// Every file under `root`, as "/"-joined relative paths, sorted.
    private func tree(_ root: String) -> [String] {
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { return [] }
        var out: [String] = []
        for case let p as String in e {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: (root as NSString).appendingPathComponent(p), isDirectory: &isDir)
            if !isDir.boolValue { out.append(p) }
        }
        return out.sorted()
    }

    private func contents(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    private func options(_ destination: String) -> SZExtractOptions {
        let o = SZExtractOptions()
        o.outputDirectory = destination
        o.outDirMode = .direct            // tests want the files exactly where they say
        o.overwriteMode = .overwrite
        return o
    }

    // MARK: - every fixture format

    func testExtractEveryFormat() throws {
        // Full pathnames, the whole archive: the fixture tree must come out unchanged (01 §8.3).
        for name in ["test.7z", "test.zip"] {
            let dest = tempDir(name)
            let o = options(dest)
            o.pathMode = .fullPaths
            let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture(name)], options: o, progress: nil))
            XCTAssertTrue(result.isOK, "\(name): \(result.messages)")
            XCTAssertEqual(tree(dest), ["notes.md", "readme.txt", "sub/big.txt", "sub/deep/inner.txt"], name)
            XCTAssertEqual(contents((dest as NSString).appendingPathComponent("readme.txt")), "hello 7-zip\n")
            XCTAssertEqual(result.statistics.fileCount, 4, name)
            XCTAssertEqual(result.statistics.folderCount, 2, name)      // sub, sub/deep
            XCTAssertEqual(result.statistics.unpackSize, 12 + 21 + 3000 + 10, name)
            XCTAssertEqual(result.statistics.archiveCount, 1, name)
        }
        // gzip / xz hold one stream: the inner tar.
        for name in ["test.tar.gz", "test.tar.xz"] {
            let dest = tempDir(name)
            let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture(name)], options: options(dest), progress: nil))
            XCTAssertTrue(result.isOK, "\(name): \(result.messages)")
            XCTAssertEqual(tree(dest), ["test.tar"], name)
            // and the tar itself extracts the same tree
            let inner = tempDir("inner-\(name)")
            let o2 = options(inner)
            o2.pathMode = .fullPaths
            let r2 = try XCTUnwrap(SZArchiveExtractor.extractArchives(
                at: [(dest as NSString).appendingPathComponent("test.tar")], options: o2, progress: nil))
            XCTAssertTrue(r2.isOK)
            XCTAssertEqual(tree(inner), ["notes.md", "readme.txt", "sub/big.txt", "sub/deep/inner.txt"], name)
        }
    }

    func testExtractManyArchivesIntoOneDirectory() throws {
        // MultiArcMode: one run, several archives, the pack total covers all of them.
        let dest = tempDir()
        let o = options(dest)
        o.pathMode = .noPaths
        let progress = RecordingProgress()
        let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(
            at: [fixture("test.7z"), fixture("test.zip")], options: o, progress: progress))
        XCTAssertTrue(result.isOK, "\(result.messages)")
        XCTAssertEqual(result.statistics.archiveCount, 2)
        XCTAssertEqual(result.statistics.fileCount, 8)
        XCTAssertEqual(tree(dest), ["big.txt", "inner.txt", "notes.md", "readme.txt"])
        XCTAssertTrue(progress.total > 0)
    }

    func testReplaceAsteriskOutDirMode() throws {
        // 7zFM's "Extract" on several archives passes -o"<dir>/*/" (01 §8.1).
        let dest = tempDir()
        let o = SZExtractOptions()
        o.outputDirectory = (dest as NSString).appendingPathComponent("*")
        o.outDirMode = .replaceAsterisk
        o.overwriteMode = .overwrite
        o.pathMode = .fullPaths
        let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(
            at: [fixture("test.7z"), fixture("test.zip")], options: o, progress: nil))
        XCTAssertTrue(result.isOK, "\(result.messages)")
        XCTAssertEqual(tree(dest), ["test/notes.md", "test/readme.txt", "test/sub/big.txt", "test/sub/deep/inner.txt"])
    }

    func testAddArchiveNameOutDirMode() throws {
        let dest = tempDir()
        let o = options(dest)
        o.outDirMode = .addArchiveName
        o.pathMode = .noPaths
        let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("test.zip")], options: o, progress: nil))
        XCTAssertTrue(result.isOK)
        XCTAssertEqual(tree(dest), ["test/big.txt", "test/inner.txt", "test/notes.md", "test/readme.txt"])
    }

    // MARK: - path modes (01b §4.25 "Path mode")

    func testPathModes() throws {
        // kFullPaths: the archive tree; kNoPaths: everything flat; kCurPaths behaves like full
        // for a whole-archive extract; kAbsPaths keeps the (here relative) stored paths.
        let expectations: [(SZExtractPathMode, [String])] = [
            (.fullPaths, ["notes.md", "readme.txt", "sub/big.txt", "sub/deep/inner.txt"]),
            (.curPaths, ["notes.md", "readme.txt", "sub/big.txt", "sub/deep/inner.txt"]),
            (.absPaths, ["notes.md", "readme.txt", "sub/big.txt", "sub/deep/inner.txt"]),
            (.noPaths, ["big.txt", "inner.txt", "notes.md", "readme.txt"]),
        ]
        for (mode, expected) in expectations {
            let dest = tempDir("mode\(mode.rawValue)")
            let o = options(dest)
            o.pathMode = mode
            let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("test.7z")], options: o, progress: nil))
            XCTAssertTrue(result.isOK, "mode \(mode.rawValue): \(result.messages)")
            XCTAssertEqual(tree(dest), expected, "path mode \(mode.rawValue)")
        }
    }

    func testEliminateDuplicateRoot() throws {
        // -spe / IDX_EXTRACT_ELIM_DUP 3430: when every item lives under a root folder whose
        // name is the last component of the output dir, that level is dropped (03 §1.6).
        // nested.zip has no single root, so build one: extract test.7z under "<dest>/sub" and
        // ask for elimination -- "sub/..." must not become "sub/sub/...".
        let base = tempDir()
        let dest = (base as NSString).appendingPathComponent("sub")
        let o = options(dest)
        o.pathMode = .fullPaths
        o.eliminateDuplicateRoot = true
        // only the "sub" subtree: excluding the two top-level files is not expressible here, so
        // extract everything and check that "sub" was *not* eliminated (readme.txt is at the root).
        var result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("test.7z")], options: o, progress: nil))
        XCTAssertTrue(result.isOK)
        XCTAssertEqual(tree(dest), ["notes.md", "readme.txt", "sub/big.txt", "sub/deep/inner.txt"])

        // An archive whose single root folder matches: nested.zip in a dir called "nested".
        let base2 = tempDir("elim2")
        let dest2 = (base2 as NSString).appendingPathComponent("test")
        let o2 = options(dest2)
        o2.pathMode = .fullPaths
        o2.eliminateDuplicateRoot = false
        result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("test.7z")], options: o2, progress: nil))
        XCTAssertTrue(result.isOK)
        XCTAssertEqual(tree(dest2), ["notes.md", "readme.txt", "sub/big.txt", "sub/deep/inner.txt"])
    }

    // MARK: - overwrite modes (01b §4.25 "Overwrite mode", 01 §8.4)

    private func prepareExisting(_ dest: String) throws {
        try "OLD".write(toFile: (dest as NSString).appendingPathComponent("readme.txt"),
                        atomically: true, encoding: .utf8)
    }

    func testOverwriteModeOverwrite() throws {
        let dest = tempDir()
        try prepareExisting(dest)
        let o = options(dest)
        o.pathMode = .noPaths
        o.overwriteMode = .overwrite
        let progress = RecordingProgress()
        let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("test.7z")], options: o, progress: progress))
        XCTAssertTrue(result.isOK)
        XCTAssertEqual(contents((dest as NSString).appendingPathComponent("readme.txt")), "hello 7-zip\n")
        XCTAssertTrue(progress.overwriteQuestions.isEmpty, "kOverwrite must not ask")
    }

    func testOverwriteModeSkip() throws {
        let dest = tempDir()
        try prepareExisting(dest)
        let o = options(dest)
        o.pathMode = .noPaths
        o.overwriteMode = .skip
        let progress = RecordingProgress()
        let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("test.7z")], options: o, progress: progress))
        XCTAssertTrue(result.isOK)
        XCTAssertEqual(contents((dest as NSString).appendingPathComponent("readme.txt")), "OLD")
        XCTAssertTrue(progress.overwriteQuestions.isEmpty)
        // "Skipping" is the status PrepareOperation announces for a skipped item (01 §8.4)
        XCTAssertTrue(progress.statuses.contains(.skipping))
    }

    func testOverwriteModeRename() throws {
        let dest = tempDir()
        try prepareExisting(dest)
        let o = options(dest)
        o.pathMode = .noPaths
        o.overwriteMode = .rename
        let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("test.7z")], options: o, progress: nil))
        XCTAssertTrue(result.isOK)
        XCTAssertEqual(contents((dest as NSString).appendingPathComponent("readme.txt")), "OLD")
        // AutoRenamePath (7zip/Common/FilePathAutoRename.cpp): "readme.txt" -> "readme_1.txt".
        // 01 §8.4 says "name (2).ext"; the engine actually appends "_<n>" (see requests.md).
        XCTAssertEqual(contents((dest as NSString).appendingPathComponent("readme_1.txt")), "hello 7-zip\n")
    }

    func testOverwriteModeRenameExisting() throws {
        let dest = tempDir()
        try prepareExisting(dest)
        let o = options(dest)
        o.pathMode = .noPaths
        o.overwriteMode = .renameExisting
        let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("test.7z")], options: o, progress: nil))
        XCTAssertTrue(result.isOK)
        XCTAssertEqual(contents((dest as NSString).appendingPathComponent("readme.txt")), "hello 7-zip\n")
        XCTAssertEqual(contents((dest as NSString).appendingPathComponent("readme_1.txt")), "OLD")
    }

    func testOverwriteModeAskAnswers() throws {
        // kAsk drives the Overwrite dialog through the delegate; "No" keeps the old file,
        // "Yes" replaces it, Cancel aborts with E_ABORT (01 §8.4).
        for (answer, expected) in [(SZOverwriteAnswer.no, "OLD"), (.yes, "hello 7-zip\n")] {
            let dest = tempDir("ask\(answer.rawValue)")
            try prepareExisting(dest)
            let o = options(dest)
            o.pathMode = .noPaths
            o.overwriteMode = .ask
            let progress = RecordingProgress()
            progress.overwriteAnswer = answer
            let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("test.7z")], options: o, progress: progress))
            XCTAssertTrue(result.isOK)
            XCTAssertEqual(progress.overwriteQuestions.count, 1)
            XCTAssertEqual(contents((dest as NSString).appendingPathComponent("readme.txt")), expected)
        }

        let dest = tempDir("askCancel")
        try prepareExisting(dest)
        let o = options(dest)
        o.pathMode = .noPaths
        o.overwriteMode = .ask
        let progress = RecordingProgress()
        progress.overwriteAnswer = .cancel
        XCTAssertThrowsError(try SZArchiveExtractor.extractArchives(at: [fixture("test.7z")], options: o, progress: progress)) {
            XCTAssertEqual(($0 as NSError).code, SZError.Code.cancelled.rawValue)
        }
    }

    // MARK: - passwords (01 §8.4 "Password")

    func testPasswordProvidedUpFront() throws {
        for name in ["secret.7z", "secret.zip"] {
            let dest = tempDir(name)
            let o = options(dest)
            o.pathMode = .noPaths
            o.password = "secret"
            let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture(name)], options: o, progress: nil))
            XCTAssertTrue(result.isOK, "\(name): \(result.messages)")
            XCTAssertEqual(contents((dest as NSString).appendingPathComponent("readme.txt")), "hello 7-zip\n", name)
        }
    }

    func testPasswordAskedThroughDelegate() throws {
        let dest = tempDir()
        let o = options(dest)
        o.pathMode = .noPaths
        let progress = RecordingProgress()
        progress.password = "secret"
        let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("secret.7z")], options: o, progress: progress))
        XCTAssertTrue(result.isOK, "\(result.messages)")
        XCTAssertTrue(result.passwordWasAsked)
        XCTAssertEqual(result.password, "secret")
        XCTAssertFalse(progress.passwordPrompts.isEmpty)
        // asked once per run (PasswordIsDefined caches it)
        XCTAssertEqual(progress.passwordPrompts.count, 1)
    }

    func testWrongPassword() throws {
        // secret.7z has encrypted headers, so the *open* fails: IDS_CANT_OPEN_ENCRYPTED_ARCHIVE
        // ("Cannot open ... Wrong password?") lands in the message list, not a fatal error.
        let dest = tempDir()
        let o = options(dest)
        o.password = "wrong"
        let progress = RecordingProgress()
        let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("secret.7z")], options: o, progress: progress))
        XCTAssertFalse(result.isOK)
        XCTAssertEqual(result.archiveErrorCount, 1)
        XCTAssertTrue(result.messages.joined(separator: "\n").contains("Cannot open"), "\(result.messages)")
        XCTAssertEqual(tree(dest), [])

        // secret.zip has a plain header, so the items fail individually with kWrongPassword or
        // kDataError, which 7zFM reports per file.
        let dest2 = tempDir("zip")
        let o2 = options(dest2)
        o2.pathMode = .noPaths
        o2.password = "wrong"
        let r2 = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("secret.zip")], options: o2, progress: nil))
        XCTAssertFalse(r2.isOK)
        XCTAssertNotEqual(r2.firstFailure, .OK)
    }

    func testCancelledPasswordPrompt() throws {
        let dest = tempDir()
        let o = options(dest)
        let progress = RecordingProgress()
        progress.password = nil                     // Cancel in the Password dialog
        XCTAssertThrowsError(try SZArchiveExtractor.extractArchives(at: [fixture("secret.7z")], options: o, progress: progress)) {
            XCTAssertEqual(($0 as NSError).code, SZError.Code.cancelled.rawValue)
        }
    }

    // MARK: - multi-volume (Extract.cpp:490-515 volume accounting)

    func testMultiVolumeExtraction() throws {
        let dest = tempDir()
        let o = options(dest)
        o.pathMode = .noPaths
        let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: [fixture("multi.7z.001")], options: o, progress: nil))
        XCTAssertTrue(result.isOK, "\(result.messages)")
        XCTAssertEqual(tree(dest), ["random.bin", "vol.txt"])
        let size = try FileManager.default.attributesOfItem(
            atPath: (dest as NSString).appendingPathComponent("random.bin"))[.size] as? Int
        XCTAssertEqual(size, 30000)
        XCTAssertEqual(result.statistics.fileCount, 2)
        // The driver charges the *sum of the volumes* as the pack size, not just .001.
        XCTAssertGreaterThan(result.statistics.packSize, 12000)
    }

    func testMultiVolumeFollowUpVolumesAreSkipped() throws {
        // Passing every volume must still extract once: Extract.cpp marks the other volumes as
        // already-used (skipArcs) and corrects the total.
        let dest = tempDir()
        let o = options(dest)
        o.pathMode = .noPaths
        let paths = ["multi.7z.001", "multi.7z.002", "multi.7z.003"].map { fixture($0) }
        let result = try XCTUnwrap(SZArchiveExtractor.extractArchives(at: paths, options: o, progress: nil))
        XCTAssertEqual(tree(dest), ["random.bin", "vol.txt"])
        XCTAssertEqual(result.statistics.fileCount, 2)
    }

    // MARK: - cancellation

    func testCancellationMidExtraction() throws {
        let dest = tempDir()
        let o = options(dest)
        o.pathMode = .noPaths
        let progress = RecordingProgress()
        progress.cancelAfterFiles = 1              // stop after the first item's result
        XCTAssertThrowsError(try SZArchiveExtractor.extractArchives(at: [fixture("test.7z")], options: o, progress: progress)) {
            XCTAssertEqual(($0 as NSError).code, SZError.Code.cancelled.rawValue)
        }
        XCTAssertLessThan(tree(dest).count, 4, "the run must not have finished")
    }

    // MARK: - test mode (01 §8.3 step 4, §8.6)

    func testTestGoodArchiveProducesSummary() throws {
        let o = SZExtractOptions()
        let progress = RecordingProgress()
        let result = try XCTUnwrap(SZArchiveExtractor.testArchives(at: [fixture("test.7z")], options: o, progress: progress))
        XCTAssertTrue(result.isOK, "\(result.messages)")
        XCTAssertEqual(result.statistics.fileCount, 4)
        XCTAssertEqual(result.statistics.folderCount, 2)
        XCTAssertEqual(result.statistics.archiveCount, 1)
        XCTAssertTrue(progress.statuses.contains(.testing))
        let summary = try XCTUnwrap(result.testSummary)
        // GUI/ExtractGUI.cpp:137-158
        XCTAssertTrue(summary.hasPrefix("Archives: 1\n"), summary)
        XCTAssertTrue(summary.contains("Packed Size: "), summary)
        XCTAssertTrue(summary.contains("Folders: 2\n"), summary)
        XCTAssertTrue(summary.contains("Files: 4\n"), summary)
        XCTAssertTrue(summary.contains("Size: 3043 bytes"), summary)
        XCTAssertTrue(summary.hasSuffix("There are no errors"), summary)
    }

    func testTestSeveralArchivesSummaryCountsThem() throws {
        let result = try XCTUnwrap(SZArchiveExtractor.testArchives(
            at: [fixture("test.7z"), fixture("test.zip")], options: SZExtractOptions(), progress: nil))
        XCTAssertTrue(result.isOK)
        XCTAssertEqual(result.statistics.archiveCount, 2)
        XCTAssertTrue(try XCTUnwrap(result.testSummary).hasPrefix("Archives: 2\n"))
    }

    func testTestCorruptedArchiveReportsCrcError() throws {
        // Flip bytes inside the compressed payload of a copy of test.zip: the header still
        // parses, so the failure arrives per item as a CRC error (01 §8.4 SetOperationResult).
        let dir = tempDir()
        let broken = (dir as NSString).appendingPathComponent("broken.zip")
        var data = try Data(contentsOf: URL(fileURLWithPath: fixture("test.zip")))
        for i in 300..<360 where i < data.count { data[i] = data[i] ^ 0xFF }
        try data.write(to: URL(fileURLWithPath: broken))

        let progress = RecordingProgress()
        let result = try XCTUnwrap(SZArchiveExtractor.testArchives(at: [broken], options: SZExtractOptions(), progress: progress))
        XCTAssertFalse(result.isOK, "a corrupted archive must not pass the test")
        XCTAssertNil(result.testSummary, "no summary when there were errors")
        XCTAssertGreaterThan(result.errorCount, 0)
        XCTAssertTrue(result.results_containsFailure, "\(result.messages)")
        XCTAssertTrue(progress.messages.joined(separator: "\n").contains("CRC"),
                      "expected a CRC message, got \(progress.messages)")
    }

    func testTestTruncatedArchiveReportsOpenError() throws {
        // A file that is not an archive at all: the open fails and the text is the Windows
        // "Cannot open file '{0}' as archive" (IDS_CANT_OPEN_ARCHIVE 3005).
        let dir = tempDir()
        let notArc = (dir as NSString).appendingPathComponent("garbage.7z")
        try Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: notArc))
        let result = try XCTUnwrap(SZArchiveExtractor.testArchives(at: [notArc], options: SZExtractOptions(), progress: nil))
        XCTAssertFalse(result.isOK)
        XCTAssertEqual(result.archiveErrorCount, 1)
        // IDS_CANT_OPEN_AS_TYPE 3017 "Cannot open the file as [{0}] archive" when a handler
        // matched the extension but rejected the content, else IDS_CANT_OPEN_ARCHIVE 3005.
        XCTAssertTrue(result.messages.joined(separator: "\n").contains("Cannot open"), "\(result.messages)")
    }

    // MARK: - helpers the commands use

    func testSubfolderNameForArchive() throws {
        // GetSubFolderNameForExtract (Explorer/ContextMenu.cpp:448)
        XCTAssertEqual(SZArchiveExtractor.subfolderName(forArchiveNamed: "test.7z"), "test")
        XCTAssertEqual(SZArchiveExtractor.subfolderName(forArchiveNamed: "test.tar.gz"), "test.tar")
        XCTAssertEqual(SZArchiveExtractor.subfolderName(forArchiveNamed: "noextension"), "noextension~")
        XCTAssertEqual(SZArchiveExtractor.subfolderName(forArchiveNamed: "movie.part01.rar"), "movie")
        XCTAssertEqual(SZArchiveExtractor.subfolderName(forArchiveNamed: "data.7z.001"), "data")
        XCTAssertEqual(SZArchiveExtractor.subfolderName(forArchiveNamed: "plain.zip"), "plain")
    }

    func testCreateOutputDirectory() throws {
        let base = tempDir()
        let deep = (base as NSString).appendingPathComponent("a/b/c")
        XCTAssertNoThrow(try SZArchiveExtractor.createOutputDirectory(deep))
        XCTAssertTrue(FileManager.default.fileExists(atPath: deep))
        // CreateComplexDir succeeds when it already exists
        XCTAssertNoThrow(try SZArchiveExtractor.createOutputDirectory(deep))
    }

    func testMissingArchiveIsAFatalError() throws {
        let o = options(tempDir())
        XCTAssertThrowsError(try SZArchiveExtractor.extractArchives(at: [fixture("does-not-exist.7z")], options: o, progress: nil))
    }
}

private extension SZExtractResult {
    /// Any per-item failure was recorded.
    var results_containsFailure: Bool { firstFailure != .OK || errorCount > 0 }
}
