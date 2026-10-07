// ArchivePreviewModelTests.swift -- the Quick Look preview's listing / summary model
// (Mac/QuickLook/ArchivePreviewModel.swift, quicklook scope) over the checked-in fixtures
// (Mac/scripts/make-fixtures.sh: one 4-file tree, 2024-01-02 14:30:00 UTC):
//
//   readme.txt (12)  notes.md (21)  sub/big.txt (3000)  sub/deep/inner.txt (10)
//
// The tree (folders first, then CompareFileNames_ForFolderList, 01 §3.3), the summary (01 §3.11),
// the caps (time, entries), the encrypted-header case (no password asked), corrupt and
// non-archive files, and the first volume of a multi-volume set read on its own, which is what
// the sandboxed extension sees.

import XCTest
import SevenZipKit

final class ArchivePreviewModelTests: XCTestCase {

    private var fixtures: String {
        guard let url = Bundle(for: ArchivePreviewModelTests.self).resourceURL else { fatalError("no resources") }
        return url.appendingPathComponent("Fixtures").path
    }

    private func fixture(_ name: String) -> String { (fixtures as NSString).appendingPathComponent(name) }

    private func names(_ node: ArchivePreviewNode) -> [String] { node.children.map(\.name) }

    private func child(_ node: ArchivePreviewNode, _ name: String) throws -> ArchivePreviewNode {
        try XCTUnwrap(node.children.first { $0.name == name }, "\(name) in \(names(node))")
    }

    /// The fixture tree, whatever the format.
    private func checkTree(_ preview: ArchivePreview, exactTime: Bool = true,
                           file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(names(preview.root), ["sub", "notes.md", "readme.txt"], "folders first, then by name",
                       file: file, line: line)
        let sub = try child(preview.root, "sub")
        XCTAssertTrue(sub.isDirectory)
        XCTAssertEqual(names(sub), ["deep", "big.txt"], file: file, line: line)
        let deep = try child(sub, "deep")
        XCTAssertEqual(names(deep), ["inner.txt"], file: file, line: line)
        XCTAssertEqual(try child(preview.root, "readme.txt").size, 12, file: file, line: line)
        XCTAssertEqual(try child(sub, "big.txt").size, 3000, file: file, line: line)
        XCTAssertEqual(sub.size, 3010, "a folder's size is the sum of its contents", file: file, line: line)
        XCTAssertEqual(preview.summary.folders, 2, file: file, line: line)
        XCTAssertEqual(preview.summary.files, 4, file: file, line: line)
        XCTAssertEqual(preview.summary.size, 3043, file: file, line: line)
        XCTAssertEqual(preview.listedEntries, 6, file: file, line: line)
        XCTAssertEqual(preview.totalEntries, 6, file: file, line: line)
        let readme = try child(preview.root, "readme.txt")
        if exactTime {
            XCTAssertEqual(readme.modified, Date(timeIntervalSince1970: 1_704_205_800), "2024-01-02 14:30:00 UTC",
                           file: file, line: line)
        } else {
            // zip's DOS time is wall-clock in the fixture maker's zone (make-fixtures.sh).
            XCTAssertEqual(readme.modified?.timeIntervalSince1970 ?? 0, 1_704_205_800, accuracy: 15 * 3600,
                           file: file, line: line)
        }
        XCTAssertTrue(readme.modifiedText.hasPrefix("2024-01-0"), readme.modifiedText, file: file, line: line)
    }

    // MARK: - formats

    func test7zListsTheTreeAndTheSummary() throws {
        let preview = ArchivePreviewBuilder.build(path: fixture("test.7z"))
        XCTAssertEqual(preview.status, .complete)
        try checkTree(preview)
        let s = preview.summary
        XCTAssertEqual(s.fileName, "test.7z")
        XCTAssertEqual(s.types, ["7z"])
        XCTAssertTrue(s.method?.contains("LZMA2") ?? false, "\(String(describing: s.method))")
        XCTAssertEqual(s.solid, true, "make-fixtures writes a solid 7z")
        XCTAssertFalse(s.encrypted)
        XCTAssertFalse(s.multiVolume)
        XCTAssertEqual(s.physicalSize, 296)
        XCTAssertNotNil(s.ratioPercent)
        XCTAssertNil(s.warning)
    }

    func testZipListsTheTreeWithPackedSizes() throws {
        let preview = ArchivePreviewBuilder.build(path: fixture("test.zip"))
        XCTAssertEqual(preview.status, .complete)
        try checkTree(preview, exactTime: false)
        XCTAssertEqual(preview.summary.types, ["zip"])
        let big = try child(try child(preview.root, "sub"), "big.txt")
        XCTAssertNotNil(big.packedSize)
        XCTAssertLessThan(big.packedSize ?? .max, 3000, "Deflate shrinks 3000 A's")
        XCTAssertNotNil(preview.summary.packedSize)
        XCTAssertEqual(preview.summary.ratioPercent,
                       Int((Double(preview.summary.packedSize!) * 100 / 3043).rounded()))
    }

    /// A .tar.gz opens both levels (CArchiveLink), as 7zFM does: the tree is tar's.
    func testTarGzListsTheTarLevel() throws {
        let preview = ArchivePreviewBuilder.build(path: fixture("test.tar.gz"))
        XCTAssertEqual(preview.status, .complete)
        try checkTree(preview)
        XCTAssertEqual(preview.summary.types, ["gzip", "tar"])
        XCTAssertEqual(preview.summary.typeText, "gzip \u{2192} tar")
        XCTAssertEqual(preview.summary.physicalSize, 260, "the outer level's physical size")
    }

    func testTarXzListsTheTarLevel() throws {
        let preview = ArchivePreviewBuilder.build(path: fixture("test.tar.xz"))
        XCTAssertEqual(preview.status, .complete)
        try checkTree(preview)
        XCTAssertEqual(preview.summary.types, ["xz", "tar"])
    }

    func testEncryptedFilesListWithoutAPassword() throws {
        let preview = ArchivePreviewBuilder.build(path: fixture("secret.zip"))
        XCTAssertEqual(preview.status, .complete)
        try checkTree(preview, exactTime: false)
        XCTAssertTrue(preview.summary.encrypted)
        XCTAssertFalse(preview.summary.headersEncrypted)
        XCTAssertTrue(try child(preview.root, "readme.txt").isEncrypted)
    }

    /// Nested archives are files in the tree; nothing is opened (or extracted) inside them.
    func testNestedArchivesAreFiles() throws {
        let preview = ArchivePreviewBuilder.build(path: fixture("nested.zip"))
        XCTAssertEqual(preview.status, .complete)
        XCTAssertEqual(names(preview.root), ["test.7z", "test.tar.gz"])
        XCTAssertFalse(try child(preview.root, "test.7z").isDirectory)
    }

    // MARK: - encrypted headers, corrupt, not an archive

    /// secret.7z has -mhe=on: the open needs the password; the preview asks for none and says so.
    func testEncryptedHeadersAskForNoPassword() {
        let preview = ArchivePreviewBuilder.build(path: fixture("secret.7z"))
        XCTAssertEqual(preview.status, .encrypted)
        XCTAssertTrue(preview.summary.headersEncrypted)
        XCTAssertTrue(preview.summary.encrypted)
        XCTAssertEqual(preview.summary.types, ["7z"], "the type by name")
        XCTAssertTrue(preview.root.children.isEmpty)
        XCTAssertEqual(preview.summary.physicalSize, 382)
    }

    func testCorruptArchiveFailsCleanly() {
        let preview = ArchivePreviewBuilder.build(path: fixture("corrupt.7z"))
        guard case .failed = preview.status else { return XCTFail("\(preview.status)") }
        XCTAssertTrue(preview.root.children.isEmpty)
        XCTAssertFalse(preview.summary.multiVolume)
    }

    func testNotAnArchiveFailsCleanly() {
        let preview = ArchivePreviewBuilder.build(path: fixture("notarchive.zip"))
        guard case .failed = preview.status else { return XCTFail("\(preview.status)") }
        XCTAssertTrue(preview.root.children.isEmpty)
    }

    func testMissingFileFailsCleanly() {
        let preview = ArchivePreviewBuilder.build(path: fixture("no-such-file.7z"))
        guard case .failed = preview.status else { return XCTFail("\(preview.status)") }
    }

    // MARK: - multi-volume

    /// With every volume readable (outside the sandbox) the set lists whole and is marked as one.
    func testFirstVolumeOfAReadableSet() throws {
        let preview = ArchivePreviewBuilder.build(path: fixture("multi.7z.001"))
        XCTAssertEqual(preview.status, .complete)
        XCTAssertEqual(preview.summary.types.last, "7z")
        XCTAssertTrue(preview.summary.multiVolume)
        XCTAssertEqual(names(preview.root), ["random.bin", "vol.txt"])
    }

    /// The sandboxed extension can read only the file it previews: the first volume alone must
    /// give what it can, marked multi-volume, and never claim to be the whole archive.
    func testFirstVolumeAlone() throws {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("ql-multivol-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let only = (dir as NSString).appendingPathComponent("multi.7z.001")
        try FileManager.default.copyItem(atPath: fixture("multi.7z.001"), toPath: only)
        let preview = ArchivePreviewBuilder.build(path: only)
        XCTAssertTrue(preview.summary.multiVolume, "\(preview.status)")
        XCTAssertNotEqual(names(preview.root), ["random.bin", "vol.txt"], "one volume of three is not the archive")
        if case .failed = preview.status {
            XCTAssertEqual(PreviewNoticeProbe.isVolumeFailure(preview), true)
        }
    }

    func testVolumeNames() {
        for name in ["a.7z.001", "a.zip.002", "a.part1.rar", "a.part12.rar", "a.z01", "a.r00"] {
            XCTAssertTrue(ArchivePreviewBuilder.isVolumeName(name), name)
        }
        for name in ["a.7z", "a.rar", "a.zip", "partial.rar", "a.tar.gz", "a.mp3", "a.part.rar"] {
            XCTAssertFalse(ArchivePreviewBuilder.isVolumeName(name), name)
        }
    }

    // MARK: - caps

    func testEntryCapTruncatesTheTreeButCountsEverything() throws {
        var limits = ArchivePreviewLimits()
        limits.maxListedEntries = 3
        let preview = ArchivePreviewBuilder.build(path: fixture("test.7z"), limits: limits)
        XCTAssertEqual(preview.listedEntries, 3)
        XCTAssertEqual(preview.totalEntries, 6)
        XCTAssertEqual(preview.status, .truncated(notShown: 3))
        XCTAssertEqual(preview.summary.files, 4, "the summary counts every entry")
        XCTAssertEqual(preview.summary.folders, 2)
        XCTAssertEqual(preview.summary.size, 3043)
    }

    /// No time left: the open (or, for a tiny archive that opens before the first check, the
    /// listing) stops; nothing hangs and the result says so.
    func testTimeCapStops() {
        var limits = ArchivePreviewLimits()
        limits.timeLimit = 0
        limits.fallbackTimeLimit = 0
        for name in ["test.tar.gz", "test.7z", "test.zip"] {
            let preview = ArchivePreviewBuilder.build(path: fixture(name), limits: limits)
            guard case .stopped = preview.status else { XCTFail("\(name): \(preview.status)"); continue }
            XCTAssertLessThanOrEqual(preview.listedEntries, preview.totalEntries, name)
        }
    }

    /// A stopped open of a stream compressor falls back to its outer level, so the preview can
    /// still say what the file is.
    func testStoppedOpenFallsBackToTheOuterLevel() {
        var preview = ArchivePreview()
        preview.status = .stopped(openStopped: true, tooManyEntries: false)
        ArchivePreviewBuilder.openOuterLevel(path: fixture("test.tar.gz"), into: &preview,
                                             limits: ArchivePreviewLimits(), timestampLevel: .min,
                                             isCancelled: { false })
        XCTAssertEqual(preview.status, .stopped(openStopped: true, tooManyEntries: false), "the status stays")
        XCTAssertEqual(preview.summary.types, ["gzip"])
        XCTAssertEqual(names(preview.root), ["test.tar"])
        XCTAssertEqual(preview.root.children.first?.isDirectory, false)
    }

    /// The entry cap of the open itself (memory): an archive reporting more items is stopped.
    func testOpenEntryCapStops() {
        var limits = ArchivePreviewLimits()
        limits.maxOpenedEntries = 1
        let preview = ArchivePreviewBuilder.build(path: fixture("test.tar.gz"), limits: limits)
        guard case .stopped(true, true) = preview.status else {
            // A handler that never reports a file count during the open lists normally.
            XCTAssertEqual(preview.status, .complete)
            return
        }
    }

    func testCancelledBeforeTheOpen() {
        let preview = ArchivePreviewBuilder.build(path: fixture("test.7z"), isCancelled: { true })
        XCTAssertEqual(preview.status, .cancelled)
    }

    // MARK: - pieces

    func testRatio() {
        var s = ArchivePreviewSummary()
        s.size = 1000
        s.packedSize = 250
        XCTAssertEqual(s.ratioPercent, 25)
        s.packedSize = nil
        s.physicalSize = 500
        XCTAssertEqual(s.ratioPercent, 50, "the physical size when no item has a packed size")
        s.size = 0
        XCTAssertNil(s.ratioPercent)
    }

    func testSortIsFoldersFirstThenNaturalName() {
        let root = ArchivePreviewNode(name: "", isDirectory: true)
        for name in ["file10.txt", "File2.txt", "b"] { root.add(ArchivePreviewNode(name: name, isDirectory: false)) }
        _ = root.folder(named: "zdir")
        _ = root.folder(named: "Adir")
        root.sortRecursively()
        XCTAssertEqual(root.children.map(\.name), ["Adir", "zdir", "b", "File2.txt", "file10.txt"])
    }

    func testImplicitFoldersAreMadeOnce() {
        let root = ArchivePreviewNode(name: "", isDirectory: true)
        let a = root.folder(named: "a")
        XCTAssertTrue(root.folder(named: "a") === a)
        a.add(ArchivePreviewNode(name: "x", isDirectory: false))
        XCTAssertEqual(root.descendantCount, 2)
    }

    // MARK: - the display settings the app pushes (QuickLookPreferences)

    func testPreferencesRoundTripThroughTheContainer() throws {
        let home = (NSTemporaryDirectory() as NSString).appendingPathComponent("ql-home-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: home) }
        let prefs = QuickLookPreferences(language: "de", theme: "dark", timestampLevel: 0, timestampShowUTC: true)
        XCTAssertFalse(prefs.write(home: home), "no container yet: nothing is written")
        try FileManager.default.createDirectory(at: QuickLookPreferences.containerURL(home: home),
                                                withIntermediateDirectories: true)
        XCTAssertTrue(prefs.write(home: home))
        XCTAssertEqual(QuickLookPreferences.load(from: QuickLookPreferences.snapshotURL(home: home)), prefs)
        XCTAssertTrue(QuickLookPreferences.snapshotURL(home: home).path
            .hasSuffix("Library/Containers/com.yrambler2001.7zip.QuickLook/Data/Library/Preferences/com.yrambler2001.7zip.quicklook.plist"))
        XCTAssertEqual(QuickLookPreferences.realHomeDirectory("/Users/me/Library/Containers/x/Data"), "/Users/me")
        XCTAssertEqual(QuickLookPreferences.realHomeDirectory("/Users/me"), "/Users/me")
        XCTAssertEqual(Set(prefs.dictionary.keys), ["Lang", "FM.Theme", "FM.TimestampLevel", "FM.TimestampShowUTC"],
                       "the four display settings and nothing else (no URL secret)")
    }
}

/// The view's notice rule lives in the AppKit file; the unit tests only need the volume case.
private enum PreviewNoticeProbe {
    static func isVolumeFailure(_ preview: ArchivePreview) -> Bool {
        if case .failed = preview.status { return preview.summary.multiVolume }
        return false
    }
}

// MARK: - streamed tar (SZStreamTar): bigger sets made here with the system's bsdtar

final class ArchivePreviewStreamedTarTests: XCTestCase {

    private var work = ""

    override func setUpWithError() throws {
        work = (NSTemporaryDirectory() as NSString).appendingPathComponent("ql-stream-\(UUID().uuidString)")
        let src = (work as NSString).appendingPathComponent("src/dir")
        try FileManager.default.createDirectory(atPath: src, withIntermediateDirectories: true)
        for i in 0..<40 {
            try Data(repeating: UInt8(i), count: 100 + i).write(to: URL(fileURLWithPath: "\(src)/f\(i).bin"))
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: work)
    }

    /// `/usr/bin/tar -c<flag>f <name> -C src dir`.
    private func makeTar(_ name: String, _ flag: String) throws -> String {
        let out = (work as NSString).appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-c\(flag)f", out, "-C", (work as NSString).appendingPathComponent("src"), "dir"]
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "bsdtar could not write \(name)")
        return out
    }

    func testTarGzListsEveryEntry() throws {
        let path = try makeTar("set.tar.gz", "z")
        let preview = ArchivePreviewBuilder.build(path: path)
        XCTAssertEqual(preview.status, .complete)
        XCTAssertEqual(preview.summary.types, ["gzip", "tar"])
        XCTAssertEqual(preview.summary.files, 40)
        XCTAssertEqual(preview.summary.folders, 1)
        XCTAssertEqual(preview.root.children.map(\.name), ["dir"])
        XCTAssertEqual(preview.root.children.first?.children.count, 40)
        XCTAssertEqual(preview.root.children.first?.children.first?.name, "f0.bin", "natural order: f0 < f1 < f2 < f10")
        XCTAssertEqual(preview.root.children.first?.children[2].name, "f2.bin")
        XCTAssertEqual(preview.summary.size, (0..<40).reduce(UInt64(0)) { $0 + UInt64(100 + $1) })
    }

    func testTarBz2AndTgzName() throws {
        let bz2 = ArchivePreviewBuilder.build(path: try makeTar("set.tar.bz2", "j"))
        XCTAssertEqual(bz2.summary.types, ["bzip2", "tar"])
        XCTAssertEqual(bz2.summary.files, 40)
        let tgz = ArchivePreviewBuilder.build(path: try makeTar("set.tgz", "z"))
        XCTAssertEqual(tgz.summary.types, ["gzip", "tar"])
        XCTAssertEqual(tgz.summary.files, 40)
    }

    func testStreamedEntryCap() throws {
        var limits = ArchivePreviewLimits()
        limits.maxListedEntries = 10
        let preview = ArchivePreviewBuilder.build(path: try makeTar("set.tar.gz", "z"), limits: limits)
        XCTAssertEqual(preview.listedEntries, 10)
        XCTAssertEqual(preview.totalEntries, 41)
        XCTAssertEqual(preview.status, .truncated(notShown: 31))
        XCTAssertEqual(preview.summary.files, 40, "counted to the end")
    }

    /// Out of time while streaming: stopped, never hanging, the outer level kept.
    func testStreamedTimeCap() throws {
        let path = try makeTar("set.tar.gz", "z")
        var preview = ArchivePreviewBuilder.build(path: path)
        preview.status = .complete
        let start = Date()
        _ = ArchivePreviewBuilder.listStreamedTar(path: path, outerFormat: "gzip", into: &preview,
                                                  limits: ArchivePreviewLimits(), deadline: Date.distantPast,
                                                  timestampLevel: .min, isCancelled: { false })
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        guard case .stopped = preview.status else { return XCTFail("\(preview.status)") }
    }

    /// A gzip that holds no tar keeps the gzip listing.
    func testGzipOfAPlainFile() throws {
        let plain = (work as NSString).appendingPathComponent("notes.txt")
        try Data("not a tar\n".utf8).write(to: URL(fileURLWithPath: plain))
        let gz = (work as NSString).appendingPathComponent("notes.tar.gz")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-k", plain]
        try process.run()
        process.waitUntilExit()
        try FileManager.default.moveItem(atPath: plain + ".gz", toPath: gz)
        let preview = ArchivePreviewBuilder.build(path: gz)
        XCTAssertEqual(preview.status, .complete)
        XCTAssertEqual(preview.summary.types, ["gzip"])
        XCTAssertEqual(preview.root.children.count, 1)
    }
}
