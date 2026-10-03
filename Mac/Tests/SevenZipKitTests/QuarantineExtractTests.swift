// QuarantineExtractTests.swift -- the macOS Zone.Identifier: `com.apple.quarantine` propagated from
// the archive to the files an ordinary extraction writes (01-fm-feature-inventory.md 9 #23,
// `-snz`, Options "Propagate Zone.Id stream", 01b 4.19). Scope `opsgaps`.
//
// The engine's own CArchiveExtractCallback does the work (ReadZoneFile_Of_BaseFile /
// WriteZoneFile_To_BaseFile, enabled for __APPLE__ in Mac/docs/upstream-patches.md), so the kOffice
// extension list is upstream's.

import XCTest
import SevenZipKit
import Darwin

final class QuarantineExtractTests: UpdaterTestCase {

    private static let attribute = "com.apple.quarantine"
    private static let value = "0083;66f00000;Safari;9A1B2C3D-0000-4000-8000-000000000001"

    private func quarantine(of path: String) -> String? {
        let size = getxattr(path, Self.attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard getxattr(path, Self.attribute, &buf, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return String(decoding: buf, as: UTF8.self)
    }

    private func setQuarantine(_ path: String) {
        let bytes = Array(Self.value.utf8)
        XCTAssertEqual(setxattr(path, Self.attribute, bytes, bytes.count, 0, 0), 0, String(cString: strerror(errno)))
    }

    /// A 7z with readme.txt, report.docx (an Office extension) and sub/inner.txt.
    private func makeArchive(quarantined: Bool) throws -> String {
        let src = try tempDir("qsrc")
        let fm = FileManager.default
        try "hello\n".write(toFile: (src as NSString).appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        try "not really word\n".write(toFile: (src as NSString).appendingPathComponent("report.docx"), atomically: true, encoding: .utf8)
        let sub = (src as NSString).appendingPathComponent("sub")
        try fm.createDirectory(atPath: sub, withIntermediateDirectories: true)
        try "inner\n".write(toFile: (sub as NSString).appendingPathComponent("inner.txt"), atomically: true, encoding: .utf8)
        let out = try tempDir("qarc")
        let archive = (out as NSString).appendingPathComponent("downloaded.7z")
        let options = SZUpdateOptions(archivePath: archive)
        options.formatName = "7z"
        try update(options, ["readme.txt", "report.docx", "sub"].map { (src as NSString).appendingPathComponent($0) })
        if quarantined { setQuarantine(archive) }
        return archive
    }

    private func extract(_ archive: String, mode: SZZoneIDMode) throws -> String {
        let out = try tempDir("qout")
        let options = SZExtractOptions()
        options.outputDirectory = out + "/"
        options.outDirMode = .direct
        options.overwriteMode = .overwrite
        options.zoneIDMode = mode
        let outcome: Result<SZExtractResult, Error> = offMain {
            do { return .success(try SZArchiveExtractor.extractArchives(at: [archive], options: options, progress: nil)) }
            catch { return .failure(error) }
        }
        XCTAssertTrue(try outcome.get().isOK)
        return out
    }

    private func path(_ dir: String, _ name: String) -> String { (dir as NSString).appendingPathComponent(name) }

    func testAllCopiesTheArchiveQuarantineToEveryFile() throws {
        let archive = try makeArchive(quarantined: true)
        let out = try extract(archive, mode: .all)
        for name in ["readme.txt", "report.docx", "sub/inner.txt"] {
            XCTAssertEqual(quarantine(of: path(out, name)), Self.value, name)
        }
    }

    func testOfficeOnlyMarksOfficeDocuments() throws {
        let archive = try makeArchive(quarantined: true)
        let out = try extract(archive, mode: .office)
        XCTAssertEqual(quarantine(of: path(out, "report.docx")), Self.value)
        XCTAssertNil(quarantine(of: path(out, "readme.txt")))
        XCTAssertNil(quarantine(of: path(out, "sub/inner.txt")))
    }

    func testNoneLeavesFilesUnmarked() throws {
        let archive = try makeArchive(quarantined: true)
        let out = try extract(archive, mode: .none)
        for name in ["readme.txt", "report.docx", "sub/inner.txt"] {
            XCTAssertNil(quarantine(of: path(out, name)), name)
        }
    }

    func testNothingIsInventedForAnUnquarantinedArchive() throws {
        let archive = try makeArchive(quarantined: false)
        let out = try extract(archive, mode: .all)
        for name in ["readme.txt", "report.docx", "sub/inner.txt"] {
            XCTAssertNil(quarantine(of: path(out, name)), name)
        }
    }

    /// The panel's F5 path: IFolderOperations::CopyTo on the archive folder (CPanel::CopyTo).
    func testPanelCopyOutHonoursTheZoneMode() throws {
        let archive = try makeArchive(quarantined: true)
        let root = try XCTUnwrap(SZFolder.folder(forPath: archive, passwordDelegate: nil))
        let indices = (0..<root.itemCount).map { NSNumber(value: $0) }

        let marked = try tempDir("qcopy-all")
        offMain { try? root.copyItems(at: indices, toPath: marked, zoneMode: .all, zoneSourcePath: nil, progress: nil) }
        XCTAssertEqual(quarantine(of: path(marked, "readme.txt")), Self.value)
        XCTAssertEqual(quarantine(of: path(marked, "sub/inner.txt")), Self.value)

        // The next call's policy replaces the previous one (PanelCopy.cpp sets it every time).
        let plain = try tempDir("qcopy-none")
        offMain { try? root.copyItems(at: indices, toPath: plain, zoneMode: .none, zoneSourcePath: nil, progress: nil) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path(plain, "readme.txt")))
        XCTAssertNil(quarantine(of: path(plain, "readme.txt")))
    }

    /// Get_ZoneId_Stream_from_ParentFolders: an explicit source (the outermost archive) wins.
    func testPanelCopyTakesTheZoneOfAnExplicitSource() throws {
        let archive = try makeArchive(quarantined: false)
        let outer = try makeArchive(quarantined: true)
        let root = try XCTUnwrap(SZFolder.folder(forPath: archive, passwordDelegate: nil))
        let indices = (0..<root.itemCount).map { NSNumber(value: $0) }
        let out = try tempDir("qcopy-outer")
        offMain { try? root.copyItems(at: indices, toPath: out, zoneMode: .office, zoneSourcePath: outer, progress: nil) }
        XCTAssertEqual(quarantine(of: path(out, "report.docx")), Self.value)
        XCTAssertNil(quarantine(of: path(out, "readme.txt")))
    }
}
