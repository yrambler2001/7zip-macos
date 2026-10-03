// NestedWriteBackTests.swift -- writing a modified nested archive back into its parent
// (parity.md D item 13; 01 §3.8 OpenParentArchiveFolder / CloseOneLevel, PanelItemOpen.cpp:598,
// PanelFolderChange.cpp:999). The bridge half: SZArchive.tempFilePath / tempFileWasChanged /
// writeBackIntoOuterFolder(progress:) / keepTempDirectory.
//
// Fixture: nested.zip (stored) holds test.7z and test.tar.gz. A zip member has no seekable
// stream, so test.7z is opened from a 7zO temp copy -- the case 7zFM writes back.

import XCTest
import SevenZipKit

/// Cancels at the first checkBreak, like pressing Cancel in the progress dialog.
private final class CancellingProgress: NSObject, SZProgressDelegate {
    func progressSetTotal(_ total: UInt64) {}
    func progressSetCompleted(_ completed: UInt64) {}
    func progressSetRatioInfo(inSize: UInt64, outSize: UInt64) {}
    func progressSetCurrentFile(_ path: String, isDirectory: Bool) {}
    func progressSetNumFilesProcessed(_ numFiles: UInt64) {}
    func progressAskOverwriteExisting(_ existName: String, existTime: Date?, existSize: NSNumber?,
                                      newName: String, newTime: Date?, newSize: NSNumber?,
                                      suggestedName: AutoreleasingUnsafeMutablePointer<NSString?>?) -> SZOverwriteAnswer { .cancel }
    func progressAskPassword(forPath path: String) -> String? { nil }
    func progressShowMessage(_ message: String) {}
    func progressSetOperationResult(_ result: SZOperationResult, path: String, isEncrypted: Bool) {}
    func progressCheckBreak() -> Bool { true }
}

final class NestedWriteBackTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        try? SZCodecs.loadCodecs()
        try? SZLang.shared.loadLanguage(code: "-")
    }

    private var work = ""

    override func setUpWithError() throws {
        work = (NSTemporaryDirectory() as NSString).appendingPathComponent("archgaps-nested-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
        let fixture = Bundle(for: NestedWriteBackTests.self).resourceURL!
            .appendingPathComponent("Fixtures/nested.zip").path
        try FileManager.default.copyItem(atPath: fixture, toPath: outerPath)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: outerPath)
        try? FileManager.default.removeItem(atPath: work)
    }

    private var outerPath: String { (work as NSString).appendingPathComponent("nested.zip") }

    private func index(_ name: String, _ folder: SZFolder) throws -> Int {
        try XCTUnwrap((0..<folder.itemCount).first { folder.nameOfItem(at: $0) == name }, "no \(name)")
    }

    /// Opens nested.zip by path and test.7z inside it from a temp copy.
    private func openInner() throws -> (outer: SZFolder, inner: SZArchive, innerRoot: SZFolder) {
        let outerRoot = try SZFolder.folder(forPath: outerPath, passwordDelegate: nil)
        let inner = try SZArchiveOpener.openArchive(in: outerRoot, itemIndex: try index("test.7z", outerRoot),
                                                    formatHint: nil, passwordDelegate: nil)
        return (outerRoot, inner, try inner.rootFolder())
    }

    /// Replaces readme.txt inside the inner archive (what a TempOpen edit does), so its temp copy changes.
    private func editInner(_ innerRoot: SZFolder, text: String) throws {
        let file = (work as NSString).appendingPathComponent("readme.txt")
        try text.write(toFile: file, atomically: true, encoding: .utf8)
        try SZTempOpen.updateItem(at: try index("readme.txt", innerRoot), of: innerRoot, fromFilePath: file, progress: nil)
    }

    /// readme.txt as stored in test.7z inside nested.zip on disk right now.
    private func readmeOnDisk() throws -> String {
        let (_, _, innerRoot) = try openInner()
        let temp = try SZTempOpen.extractItem(at: try index("readme.txt", innerRoot), of: innerRoot,
                                              archiveFilePath: nil, archiveLevelCount: 2,
                                              zoneMode: .none, progress: nil)
        defer { SZTempOpen.removeTemporaryDirectory(atPath: temp.directoryPath) }
        return try String(contentsOfFile: temp.filePath, encoding: .utf8)
    }

    func testTempCopyIsRecordedAndUnchangedAfterOpening() throws {
        let (_, inner, _) = try openInner()
        let temp = try XCTUnwrap(inner.tempFilePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp))
        XCTAssertTrue(temp.hasPrefix(try XCTUnwrap(inner.tempDirectory)))
        XCTAssertFalse(inner.tempFileWasChanged)
        // an archive opened by path has no temp copy and never reports a change
        let byPath = try SZArchiveOpener.openArchive(atPath: outerPath, formatHint: nil, passwordDelegate: nil)
        XCTAssertNil(byPath.tempFilePath)
        XCTAssertFalse(byPath.tempFileWasChanged)
        XCTAssertThrowsError(try byPath.writeBackIntoOuterFolder(progress: nil))
    }

    func testEditInsideNestedArchiveIsWrittenBackIntoTheParent() throws {
        XCTAssertEqual(try readmeOnDisk(), "hello 7-zip\n")
        let (outer, inner, innerRoot) = try openInner()
        try editInner(innerRoot, text: "edited inside the nested archive\n")
        XCTAssertTrue(inner.tempFileWasChanged, "the inner update rewrote the temp copy")
        XCTAssertEqual(try readmeOnDisk(), "hello 7-zip\n", "the parent is untouched until the write-back")

        try inner.writeBackIntoOuterFolder(progress: nil)
        XCTAssertFalse(inner.tempFileWasChanged, "attributes re-recorded")
        XCTAssertEqual(try readmeOnDisk(), "edited inside the nested archive\n")
        // the parent kept its other member and was reloaded in place
        XCTAssertNoThrow(try index("test.tar.gz", outer))
        XCTAssertEqual(outer.nameOfItem(at: inner.outerItemIndex), "test.7z")
        // a second round is noticed and written back too
        try editInner(innerRoot, text: "second round\n")
        XCTAssertTrue(inner.tempFileWasChanged)
        try inner.writeBackIntoOuterFolder(progress: nil)
        XCTAssertEqual(try readmeOnDisk(), "second round\n")
    }

    func testCancelledWriteBackLeavesTheParentAndKeepsTheCopy() throws {
        let before = try Data(contentsOf: URL(fileURLWithPath: outerPath))
        var tempDirectory = ""
        try autoreleasepool {
            let (_, inner, innerRoot) = try openInner()
            try editInner(innerRoot, text: "never written\n")
            XCTAssertThrowsError(try inner.writeBackIntoOuterFolder(progress: CancellingProgress())) { error in
                XCTAssertEqual((error as NSError).code, SZError.Code.cancelled.rawValue)
            }
            XCTAssertTrue(inner.tempFileWasChanged, "still pending")
            inner.keepTempDirectory()
            tempDirectory = try XCTUnwrap(inner.tempDirectory)
            inner.close()
        }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: outerPath)), before, "parent byte-for-byte unchanged")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDirectory), "the modified copy survives the close")
        try? FileManager.default.removeItem(atPath: tempDirectory)
    }

    func testReadOnlyParentRefusesAndKeepsTheCopy() throws {
        // kpidReadOnly comes from the attributes CAgent::Open read (Is_Attrib_ReadOnly)
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: outerPath)
        let (outer, inner, innerRoot) = try openInner()
        XCTAssertTrue(outer.isReadOnly)
        try editInner(innerRoot, text: "read-only parent\n")
        let before = try Data(contentsOf: URL(fileURLWithPath: outerPath))
        XCTAssertThrowsError(try inner.writeBackIntoOuterFolder(progress: nil))
        XCTAssertTrue(inner.tempFileWasChanged)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: outerPath)), before)
        let dir = try XCTUnwrap(inner.tempDirectory)
        inner.keepTempDirectory()
        XCTAssertTrue(inner.keepsTempDirectory)
        inner.close()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir))
        try? FileManager.default.removeItem(atPath: dir)
    }

    func testUnchangedNestedArchiveCleansItsCopyOnClose() throws {
        let (_, inner, _) = try openInner()
        let dir = try XCTUnwrap(inner.tempDirectory)
        inner.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir))
    }

    /// The launch argument's `-t<type>` reaches CAgent::Open (PROGRESS §1.4).
    func testFolderForPathHonoursTheFormatHint() throws {
        let fixtures = Bundle(for: NestedWriteBackTests.self).resourceURL!.appendingPathComponent("Fixtures").path
        let path = fixtures + "/test.7z"
        XCTAssertNoThrow(try SZFolder.folder(forPath: path, formatHint: "7z", passwordDelegate: nil))
        XCTAssertNoThrow(try SZFolder.folder(forPath: path, formatHint: nil, passwordDelegate: nil))
        XCTAssertThrowsError(try SZFolder.folder(forPath: path, formatHint: "zip", passwordDelegate: nil))
        // inner paths still bind after a hinted open
        XCTAssertEqual(try SZFolder.folder(forPath: outerPath + "/test.7z", formatHint: "zip", passwordDelegate: nil).isArchive, true)
    }
}
