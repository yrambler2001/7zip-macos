// NavGapsBridgeTests.swift -- the bridge half of `mac/navgaps` (Mac/docs/reports/navgaps.md):
//
//   * the per-level open error text (GetFolderError, FileFolderPluginOpen.cpp:96-217) on a failed
//     open, and CFfpOpen::Encrypted (01 §6.7, PROGRESS 155);
//   * `SZArchive.openErrorMessage` is nil for archives whose opened levels only carry warnings --
//     7zFM shows nothing for those on entering (PanelItemOpen.cpp:512-522);
//   * the "Opening" progress: Open_SetTotal / Open_SetCompleted reach the delegate and
//     progressCheckBreak cancels (COpenArchiveCallback, OpenCallback.cpp:20-60; PROGRESS 153);
//   * the password belongs to an archive level (CFolderLink::Password; PROGRESS 168);
//   * 7zO<8 hex> temp folders (CTempDir::Create; PROGRESS 69);
//   * per-volume case sensitivity (01 §9 #24; PROGRESS 140).

import XCTest
import SevenZipKit

private final class OpenProgress: NSObject, SZProgressDelegate {
    var cancel = false
    private let lock = NSLock()
    private var _totals: [UInt64] = []
    private var _completed: [UInt64] = []
    private var _breakChecks = 0
    private var _status: SZProgressStatus?
    var totals: [UInt64] { lock.lock(); defer { lock.unlock() }; return _totals }
    var completed: [UInt64] { lock.lock(); defer { lock.unlock() }; return _completed }
    var breakChecks: Int { lock.lock(); defer { lock.unlock() }; return _breakChecks }
    var status: SZProgressStatus? { lock.lock(); defer { lock.unlock() }; return _status }

    func progressSetTotal(_ total: UInt64) { lock.lock(); _totals.append(total); lock.unlock() }
    func progressSetCompleted(_ value: UInt64) { lock.lock(); _completed.append(value); lock.unlock() }
    func progressSetRatioInfo(inSize: UInt64, outSize: UInt64) {}
    func progressSetCurrentFile(_ path: String, isDirectory: Bool) {}
    func progressSetNumFilesProcessed(_ numFiles: UInt64) {}
    func progressSetStatus(_ status: SZProgressStatus) { lock.lock(); _status = status; lock.unlock() }
    func progressAskOverwriteExisting(_ existName: String, existTime: Date?, existSize: NSNumber?,
                                      newName: String, newTime: Date?, newSize: NSNumber?,
                                      suggestedName: AutoreleasingUnsafeMutablePointer<NSString?>?) -> SZOverwriteAnswer { .cancel }
    func progressAskPassword(forPath path: String) -> String? { nil }
    func progressShowMessage(_ message: String) {}
    func progressSetOperationResult(_ result: SZOperationResult, path: String, isEncrypted: Bool) {}
    func progressCheckBreak() -> Bool {
        lock.lock(); _breakChecks += 1; lock.unlock()
        return cancel
    }
}

private final class Passwords: NSObject, SZPasswordDelegate {
    let answer: String?
    private(set) var asked: [String] = []
    init(_ answer: String?) { self.answer = answer }
    func passwordForArchive(atPath path: String) -> String? { asked.append(path); return answer }
}

final class NavGapsBridgeTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        try? SZCodecs.loadCodecs()
        try? SZLang.shared.loadLanguage(code: "-")
    }

    private var work = ""

    override func setUpWithError() throws {
        work = (NSTemporaryDirectory() as NSString).appendingPathComponent("navgaps-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: work, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: work)
    }

    private func fixture(_ name: String) -> String {
        Bundle(for: NavGapsBridgeTests.self).resourceURL!.appendingPathComponent("Fixtures/\(name)").path
    }

    private func write(_ data: Data, _ name: String) throws -> String {
        let path = (work as NSString).appendingPathComponent(name)
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }

    private func openError(_ body: () throws -> Any) -> NSError? {
        do { _ = try body(); return nil } catch { return error as NSError }
    }

    // MARK: - open errors (PROGRESS 155)

    /// A zip with text in front of it: no handler opens it, and the zip handler says why. 7zz
    /// prints "Open ERROR: Cannot open the file as [zip] archive / Is not archive" for the same file.
    func testNotArchiveCarriesTheNonOpenLevelText() throws {
        var bytes = Data("hello\n".utf8)
        bytes.append(try Data(contentsOf: URL(fileURLWithPath: fixture("test.zip"))))
        let path = try write(bytes, "off.zip")
        let error = try XCTUnwrap(openError { try SZArchiveOpener.openArchive(atPath: path, formatHint: nil, passwordDelegate: nil) })
        XCTAssertEqual(error.code, SZError.Code.notArchive.rawValue)
        XCTAssertEqual(error.userInfo[SZArchiveOpenPathKey] as? String, path)
        XCTAssertEqual((error.userInfo[SZArchiveOpenEncryptedKey] as? NSNumber)?.boolValue, false)
        let level = try XCTUnwrap(error.userInfo[SZArchiveOpenErrorMessageKey] as? String, "\(error.userInfo)")
        XCTAssertTrue(level.contains("[zip]"), level)                  // IDS_CANT_OPEN_AS_TYPE 3017
        XCTAssertTrue(level.hasPrefix(path), "GetFolderError starts with the level's path: \(level)")
        // FM.cpp's launch box: IDS_CANT_OPEN_ARCHIVE 3005, then the level text.
        XCTAssertTrue(error.localizedDescription.hasPrefix("Cannot open file '\(path)' as archive"), error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains(level))
    }

    /// The non-open level below an opened one: `-tgzip.tar` on a gzip whose content is not a tar.
    func testNonOpenInnerLevelIsNamed() throws {
        let raw = try write(Data(repeating: 0x41, count: 4096), "junk.tar")
        let gzip = Process()
        gzip.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        gzip.arguments = ["-k", raw]
        try gzip.run()
        gzip.waitUntilExit()
        let path = raw + ".gz"
        let error = try XCTUnwrap(openError { try SZArchiveOpener.openArchive(atPath: path, formatHint: "gzip.tar", passwordDelegate: nil) })
        XCTAssertEqual(error.code, SZError.Code.notArchive.rawValue)
        let level = try XCTUnwrap(error.userInfo[SZArchiveOpenErrorMessageKey] as? String, "\(error.userInfo)")
        XCTAssertTrue(level.contains("[tar]"), level)
    }

    /// A split set whose joined content is a broken 7z: the Split level opens, the 7z level
    /// does not. CFfpOpen::ErrorMessage names it, and 7zFM enters the split level and shows it.
    func testOpenedArchiveWithANonOpenLevelCarriesItsText() throws {
        try makeBrokenSplitSet()
        let archive = try SZArchiveOpener.openArchive(atPath: work + "/v.7z.001", formatHint: nil, passwordDelegate: nil)
        XCTAssertEqual(archive.type, "Split")
        let text = try XCTUnwrap(archive.openErrorMessage)
        XCTAssertTrue(text.hasPrefix("v.7z\n"), text)                      // NonOpen_ArcPath first
        XCTAssertTrue(text.contains("Cannot open the file as [7z] archive"), text)
        XCTAssertTrue(text.contains("Headers Error"), text)                // kpidErrorFlags
    }

    /// The first 40 bytes of test.7z (signature and start header) and then garbage, cut in two.
    func makeBrokenSplitSet() throws {
        var broken = try Data(contentsOf: URL(fileURLWithPath: fixture("test.7z"))).prefix(40)
        broken.append(Data((0..<2000).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) }))
        _ = try write(Data(broken.prefix(1020)), "v.7z.001")
        _ = try write(Data(broken.dropFirst(1020)), "v.7z.002")
    }

    /// Warnings of a level that did open are not 7zFM's entering message (they are in Properties).
    func testOpenedArchivesHaveNoLevelText() throws {
        let clean = try SZArchiveOpener.openArchive(atPath: fixture("test.7z"), formatHint: nil, passwordDelegate: nil)
        XCTAssertNil(clean.openErrorMessage)
        var tail = try Data(contentsOf: URL(fileURLWithPath: fixture("test.zip")))
        tail.append(Data("JUNKJUNKJUNK\n".utf8))               // "There are data after the end of archive"
        let withTail = try SZArchiveOpener.openArchive(atPath: try write(tail, "tail.zip"), formatHint: nil, passwordDelegate: nil)
        XCTAssertNil(withTail.openErrorMessage)
    }

    /// CFfpOpen::Encrypted: a wrong password for encrypted headers is S_FALSE with a password in
    /// use, i.e. IDS_CANT_OPEN_ENCRYPTED_ARCHIVE 3006.
    func testWrongPasswordIsAnEncryptedFailure() throws {
        let path = fixture("secret.7z")
        let error = try XCTUnwrap(openError { try SZArchiveOpener.openArchive(atPath: path, formatHint: nil, passwordDelegate: Passwords("wrong")) })
        XCTAssertEqual(error.code, SZError.Code.notArchive.rawValue, "\(error)")
        XCTAssertEqual((error.userInfo[SZArchiveOpenEncryptedKey] as? NSNumber)?.boolValue, true)
        XCTAssertTrue(error.localizedDescription.contains("encrypted"), error.localizedDescription)
    }

    // MARK: - passwords per level (PROGRESS 168)

    func testTheOpenPasswordStaysWithTheArchive() throws {
        let asker = Passwords("secret")
        let archive = try SZArchiveOpener.openArchive(atPath: fixture("secret.7z"), formatHint: nil, passwordDelegate: asker)
        XCTAssertEqual(archive.password, "secret")
        XCTAssertEqual(asker.asked.count, 1)
        let plain = try SZArchiveOpener.openArchive(atPath: fixture("test.7z"), formatHint: nil, passwordDelegate: asker)
        XCTAssertNil(plain.password, "UsePassword is false for an archive that needed none")
    }

    /// OpenItemInArchive copies an item with the password of the level it is in.
    func testCopyOfAnItemUsesItsLevelsPassword() throws {
        let root = try SZFolder.folder(forPath: fixture("secret.zip"), passwordDelegate: nil)
        let index = try XCTUnwrap((0..<root.itemCount).first { root.nameOfItem(at: $0) == "readme.txt" })
        // without the level's password and nobody to ask: the copy needs one
        let noPassword = try XCTUnwrap(openError { try SZArchiveOpener.openArchive(in: root, itemIndex: index, formatHint: nil, passwordDelegate: nil) })
        XCTAssertEqual(noPassword.code, SZError.Code.passwordRequired.rawValue, "\(noPassword)")
        // with it: the copy succeeds, and readme.txt is then simply not an archive
        root.archive?.password = "secret"
        let notArchive = try XCTUnwrap(openError { try SZArchiveOpener.openArchive(in: root, itemIndex: index, formatHint: nil, passwordDelegate: nil) })
        XCTAssertEqual(notArchive.code, SZError.Code.notArchive.rawValue, "\(notArchive)")
    }

    // MARK: - the "Opening" progress (PROGRESS 153)

    func testOpenReportsToTheProgressAndCanBeCancelled() throws {
        let progress = OpenProgress()
        let archive = try SZArchiveOpener.openArchive(atPath: fixture("multi.7z.001"), formatHint: nil,
                                                      passwordDelegate: nil, progress: progress)
        XCTAssertNotNil(archive)
        XCTAssertEqual(progress.status, .opening)
        XCTAssertGreaterThan(progress.breakChecks, 0, "Open_CheckBreak / SetTotal / SetCompleted reach the delegate")
        XCTAssertFalse(progress.totals.isEmpty && progress.completed.isEmpty, "some volume of work is reported")

        let cancelling = OpenProgress()
        cancelling.cancel = true
        let error = try XCTUnwrap(openError {
            try SZArchiveOpener.openArchive(atPath: self.fixture("test.7z"), formatHint: nil,
                                            passwordDelegate: nil, progress: cancelling)
        })
        XCTAssertEqual(error.code, SZError.Code.cancelled.rawValue, "\(error)")
    }

    func testCancellingTheNestedCopyCancelsTheOpen() throws {
        let outer = try SZFolder.folder(forPath: fixture("nested.zip"), passwordDelegate: nil)
        let index = try XCTUnwrap((0..<outer.itemCount).first { outer.nameOfItem(at: $0) == "test.7z" })
        let cancelling = OpenProgress()
        cancelling.cancel = true
        let error = try XCTUnwrap(openError {
            try SZArchiveOpener.openArchive(in: outer, itemIndex: index, formatHint: nil,
                                            passwordDelegate: nil, progress: cancelling)
        })
        XCTAssertEqual(error.code, SZError.Code.cancelled.rawValue, "\(error)")
    }

    func testFolderForPathPassesTheProgressDown() throws {
        let progress = OpenProgress()
        let folder = try SZFolder.folder(forPath: fixture("nested.zip") + "/test.7z", formatHint: nil,
                                         passwordDelegate: nil, progress: progress)
        XCTAssertTrue(folder.isArchive)
        XCTAssertGreaterThan(progress.breakChecks, 0)
    }

    // MARK: - temp folder names (PROGRESS 69)

    func testTempFoldersAreNamedLikeWindows() throws {
        let dir = try SZTempOpen.createTemporaryDirectory(prefix: "7zO")
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let name = (dir as NSString).lastPathComponent
        XCTAssertNotNil(name.range(of: "^7zO[0-9A-F]{8}$", options: .regularExpression), name)
        let mode = try FileManager.default.attributesOfItem(atPath: dir)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
    }

    // MARK: - case sensitivity per volume (PROGRESS 140)

    func testVolumeCaseSensitivityMatchesTheVolume() throws {
        let url = URL(fileURLWithPath: work)
        let expected = try url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames
        XCTAssertEqual(SZFolder.volumeIsCaseSensitive(atPath: work), expected)
        // a path that does not exist yet is judged by its nearest existing ancestor
        XCTAssertEqual(SZFolder.volumeIsCaseSensitive(atPath: work + "/not/yet/there"), expected)
    }

    /// On a case-insensitive volume a name typed in another case still finds its item; the
    /// folder lookup follows the volume.
    func testBindToPathFollowsTheVolumesCase() throws {
        try FileManager.default.createDirectory(atPath: work + "/Sub", withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: fixture("test.7z"), toPath: work + "/Sub/Inner.7z")
        let base = try SZFolder.folder(forPath: work, passwordDelegate: nil)
        let typed = try? base.bindToPath("Sub/inner.7z", passwordDelegate: nil)
        if SZFolder.volumeIsCaseSensitive(atPath: work) {
            XCTAssertNil(typed, "a case-sensitive volume has no inner.7z")
        } else {
            XCTAssertEqual(typed?.isArchive, true)
        }
    }

    // MARK: - raw-property column widths (archgaps follow-up)

    func testRawPropertyColumnsStartWideEnoughForTheirHex() throws {
        let wim = try SZFolder.folder(forPath: fixture("test.wim"), passwordDelegate: nil)
        let model = PanelColumnsModel(properties: wim.properties, folderType: wim.folderType,
                                      isFileSystem: false, hiddenByDefault: [], layout: nil)
        let sha1 = try XCTUnwrap(model.columns.first { $0.propID == .sha1 })
        XCTAssertEqual(sha1.width, 300)
        XCTAssertEqual(model.columns.first { $0.propID == .size }?.width, 100, "ordinary columns keep 7zFM's 100")
        let xar = try SZFolder.folder(forPath: fixture("test.xar"), passwordDelegate: nil)
        let xarModel = PanelColumnsModel(properties: xar.properties, folderType: xar.folderType,
                                         isFileSystem: false, hiddenByDefault: [], layout: nil)
        XCTAssertEqual(xarModel.columns.first { $0.propID == .checksum }?.width, 300)
    }
}
