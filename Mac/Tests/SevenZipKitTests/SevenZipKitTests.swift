import XCTest
import SevenZipKit

/// Fixtures are created by Mac/scripts/make-fixtures.sh from a fixed 4-file tree:
///   readme.txt (12 B), notes.md (21 B), sub/big.txt (3000 B), sub/deep/inner.txt (10 B)
/// all with mtime 2024-01-02 15:30 local time.
final class SevenZipKitTests: XCTestCase {

    static var fixtures: String {
        let bundle = Bundle(for: SevenZipKitTests.self)
        guard let url = bundle.resourceURL?.appendingPathComponent("Fixtures") else {
            fatalError("no resource URL")
        }
        return url.path
    }

    override class func setUp() {
        super.setUp()
        try? SZCodecs.loadCodecs()
        // tests assert English strings
        try? SZLang.shared.loadLanguage(code: "-")
    }

    private func fixture(_ name: String) -> String {
        (Self.fixtures as NSString).appendingPathComponent(name)
    }

    private func names(_ folder: SZFolder) -> [String] {
        (0..<folder.itemCount).map { folder.nameOfItem(at: $0) }.sorted()
    }

    private func index(of name: String, in folder: SZFolder) -> Int {
        for i in 0..<folder.itemCount where folder.nameOfItem(at: i) == name { return i }
        XCTFail("item \(name) not found in \(folder.fullPath)")
        return 0
    }

    private func checkFixtureTree(_ root: SZFolder, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(names(root), ["notes.md", "readme.txt", "sub"], file: file, line: line)
        let readme = index(of: "readme.txt", in: root)
        XCTAssertEqual(root.sizeOfItem(at: readme), 12, file: file, line: line)
        XCTAssertFalse(root.isDirectory(at: readme), file: file, line: line)
        XCTAssertEqual(root.sizeOfItem(at: index(of: "notes.md", in: root)), 21, file: file, line: line)
        let sub = index(of: "sub", in: root)
        XCTAssertTrue(root.isDirectory(at: sub), file: file, line: line)

        // mtime preserved by every format (minute precision is enough: zip has 2 s resolution)
        let mtime = try XCTUnwrap(root.propertyOfItem(at: readme, propID: .mtime) as? Date, file: file, line: line)
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: mtime)
        XCTAssertEqual([comps.year, comps.month, comps.day, comps.hour, comps.minute], [2024, 1, 2, 15, 30], file: file, line: line)
        XCTAssertFalse(root.displayStringOfItem(at: readme, propID: .mtime, timestampLevel: .min).isEmpty, file: file, line: line)

        // columns: Name must be first (CAgent renames kpidPath to kpidName)
        let props = root.properties
        XCTAssertEqual(props.first?.propID, .name, file: file, line: line)
        XCTAssertEqual(props.first?.localizedName, "Name", file: file, line: line)
        XCTAssertTrue(props.contains { $0.propID == .size }, file: file, line: line)

        // navigate into sub, then deep, then back up
        let subFolder = try root.bindToFolder(at: sub)
        XCTAssertEqual(names(subFolder), ["big.txt", "deep"], file: file, line: line)
        XCTAssertEqual(subFolder.sizeOfItem(at: index(of: "big.txt", in: subFolder)), 3000, file: file, line: line)
        XCTAssertTrue(subFolder.isArchive, file: file, line: line)
        XCTAssertTrue(subFolder.fullPath.hasSuffix("/sub/"), subFolder.fullPath, file: file, line: line)
        let deep = try subFolder.bindToFolder(named: "deep")
        XCTAssertEqual(names(deep), ["inner.txt"], file: file, line: line)
        XCTAssertEqual(deep.sizeOfItem(at: 0), 10, file: file, line: line)
        let backToSub = try deep.bindToParentFolder()
        XCTAssertEqual(names(backToSub), ["big.txt", "deep"], file: file, line: line)
        let backToRoot = try backToSub.bindToParentFolder()
        XCTAssertEqual(names(backToRoot), ["notes.md", "readme.txt", "sub"], file: file, line: line)
    }

    // MARK: - Codecs

    func testCodecsLoad() throws {
        try SZCodecs.loadCodecs()
        XCTAssertTrue(SZCodecs.isLoaded)
        XCTAssertGreaterThanOrEqual(SZCodecs.formatCount, 61, "7zz build has 61 handlers + hash handler")
        let sevenZ = try XCTUnwrap(SZCodecs.format(forExtension: "7z"))
        XCTAssertEqual(sevenZ.name, "7z")
        XCTAssertTrue(sevenZ.updateEnabled)
        XCTAssertEqual(sevenZ.mainExtension, "7z")
        let zip = try XCTUnwrap(SZCodecs.format(named: "zip"))
        XCTAssertTrue(zip.extensions.contains("jar"))
        XCTAssertEqual(SZCodecs.format(forArchiveName: "/x/y/archive.tar.gz")?.name.lowercased(), "gzip")
        XCTAssertTrue(SZCodecs.allExtensions.contains("xz"))
        XCTAssertNil(SZCodecs.format(forExtension: "definitely-not-an-archive-ext"))
        XCTAssertTrue(SZCodecs.formats.contains { $0.isHashHandler })
        XCTAssertEqual(SZEngineVersionString(), "26.03")
    }

    // MARK: - Opening archives

    func testOpen7z() throws {
        let archive = try SZArchiveOpener.openArchive(atPath: fixture("test.7z"), formatHint: nil, passwordDelegate: nil)
        XCTAssertEqual(archive.type, "7z")
        XCTAssertNil(archive.errorMessage)
        let root = try archive.rootFolder()
        XCTAssertEqual(root.folderType, "7-Zip.7z")
        XCTAssertEqual(root.path, "")
        XCTAssertEqual(root.fullPath, fixture("test.7z") + "/")
        try checkFixtureTree(root)
        // arc props: level 0 = 7z with a Method
        let props = try XCTUnwrap(root.arcProps)
        XCTAssertEqual(props.levelCount, 1)
        XCTAssertFalse(props.displayString(atLevel: 0, propID: .method).isEmpty)
        // parent of the archive root is the directory it lives in
        let outer = try root.bindToParentFolder()
        XCTAssertTrue(outer.isFileSystem)
        XCTAssertEqual(outer.path, Self.fixtures + "/")
        XCTAssertEqual(archive.outerItemIndex, index(of: "test.7z", in: outer))
    }

    func testOpenZip() throws {
        let archive = try SZArchiveOpener.openArchive(atPath: fixture("test.zip"), formatHint: nil, passwordDelegate: nil)
        XCTAssertEqual(archive.type, "zip")
        try checkFixtureTree(try archive.rootFolder())
    }

    /// Like 7zFM and `7zz l`, a .tar.gz opens as the gzip level with the single item test.tar;
    /// the tar is opened as a nested archive. gzip has no seekable item stream, so this goes
    /// through the temp-file path.
    func testOpenTarGz() throws {
        let archive = try SZArchiveOpener.openArchive(atPath: fixture("test.tar.gz"), formatHint: nil, passwordDelegate: nil)
        XCTAssertEqual(archive.type, "gzip")
        let root = try archive.rootFolder()
        XCTAssertEqual(names(root), ["test.tar"])
        XCTAssertEqual(root.sizeOfItem(at: 0), 8704)
        let tar = try SZArchiveOpener.openArchive(in: root, itemIndex: 0, formatHint: nil, passwordDelegate: nil)
        XCTAssertEqual(tar.type, "tar")
        XCTAssertNotNil(tar.tempDirectory, "gzip items are not seekable: extracted to a temp folder")
        XCTAssertEqual(tar.path, fixture("test.tar.gz") + "/test.tar")
        try checkFixtureTree(try tar.rootFolder())
        let temp = try XCTUnwrap(tar.tempDirectory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp + "/test.tar"))
        tar.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp), "temp folder removed on close")
    }

    /// xz implements IInArchiveGetStream, so the nested tar opens from the stream (no temp file).
    func testOpenTarXz() throws {
        let archive = try SZArchiveOpener.openArchive(atPath: fixture("test.tar.xz"), formatHint: nil, passwordDelegate: nil)
        XCTAssertEqual(archive.type, "xz")
        let root = try archive.rootFolder()
        XCTAssertEqual(names(root), ["test.tar"])
        let tar = try SZArchiveOpener.openArchive(in: root, itemIndex: 0, formatHint: nil, passwordDelegate: nil)
        XCTAssertEqual(tar.type, "tar")
        XCTAssertNil(tar.tempDirectory, "xz provides a seekable stream")
        try checkFixtureTree(try tar.rootFolder())
        // and by path in one go
        let deep = try SZFolder.folder(forPath: fixture("test.tar.xz") + "/test.tar/sub/deep", passwordDelegate: nil)
        XCTAssertEqual(names(deep), ["inner.txt"])
    }

    func testFormatHint() throws {
        let archive = try SZArchiveOpener.openArchive(atPath: fixture("test.zip"), formatHint: "zip", passwordDelegate: nil)
        XCTAssertEqual(archive.type, "zip")
        XCTAssertThrowsError(try SZArchiveOpener.openArchive(atPath: fixture("test.zip"), formatHint: "7z", passwordDelegate: nil))
    }

    func testNotAnArchive() throws {
        let tmp = NSTemporaryDirectory() + "sz-not-archive-\(getpid()).txt"
        try "just text\n".write(toFile: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        XCTAssertThrowsError(try SZArchiveOpener.openArchive(atPath: tmp, formatHint: nil, passwordDelegate: nil)) { error in
            let e = error as NSError
            XCTAssertEqual(e.domain, SZErrorDomain)
            XCTAssertEqual(e.code, SZError.notArchive.rawValue, "\(e)")
        }
        XCTAssertThrowsError(try SZArchiveOpener.openArchive(atPath: "/nonexistent/x.7z", formatHint: nil, passwordDelegate: nil)) { error in
            XCTAssertEqual((error as NSError).code, SZError.fileNotFound.rawValue)
        }
    }

    // MARK: - Nested archives

    func testNestedArchive() throws {
        let outer = try SZArchiveOpener.openArchive(atPath: fixture("nested.zip"), formatHint: nil, passwordDelegate: nil)
        let outerRoot = try outer.rootFolder()
        XCTAssertEqual(names(outerRoot), ["test.7z", "test.tar.gz"])
        let idx = index(of: "test.7z", in: outerRoot)
        let inner = try SZArchiveOpener.openArchive(in: outerRoot, itemIndex: idx, formatHint: nil, passwordDelegate: nil)
        XCTAssertEqual(inner.type, "7z")
        XCTAssertNotNil(inner.tempDirectory, "zip has no IInArchiveGetStream: temp extraction")
        XCTAssertEqual(inner.path, fixture("nested.zip") + "/test.7z")
        let innerRoot = try inner.rootFolder()
        try checkFixtureTree(innerRoot)
        // Up from the inner archive root lands in the outer archive
        let back = try innerRoot.bindToParentFolder()
        XCTAssertEqual(names(back), ["test.7z", "test.tar.gz"])
        XCTAssertEqual(back.folderType, "7-Zip.zip")

        // and the same through folderForPath with a path that crosses two archives
        let deep = try SZFolder.folder(forPath: fixture("nested.zip") + "/test.tar.gz/test.tar/sub/deep", passwordDelegate: nil)
        XCTAssertEqual(names(deep), ["inner.txt"])
        XCTAssertEqual(deep.fullPath, fixture("nested.zip") + "/test.tar.gz/test.tar/sub/deep/")
        XCTAssertEqual(deep.archive?.outerFolder?.archive?.outerFolder?.folderType, "7-Zip.zip", "three archive levels chained")
    }

    // MARK: - Passwords

    final class Password: NSObject, SZPasswordDelegate {
        let value: String?
        var asked = 0
        init(_ value: String?) { self.value = value }
        func passwordForArchive(atPath path: String) -> String? { asked += 1; return value }
    }

    func testEncryptedHeadersNeedPassword() throws {
        XCTAssertThrowsError(try SZArchiveOpener.openArchive(atPath: fixture("secret.7z"), formatHint: nil, passwordDelegate: nil)) { error in
            XCTAssertEqual((error as NSError).code, SZError.passwordRequired.rawValue, "\(error)")
        }
        let cancel = Password(nil)
        XCTAssertThrowsError(try SZArchiveOpener.openArchive(atPath: fixture("secret.7z"), formatHint: nil, passwordDelegate: cancel)) { error in
            XCTAssertEqual((error as NSError).code, SZError.cancelled.rawValue, "\(error)")
        }
        XCTAssertEqual(cancel.asked, 1)
        let ok = Password("secret")
        let archive = try SZArchiveOpener.openArchive(atPath: fixture("secret.7z"), formatHint: nil, passwordDelegate: ok)
        XCTAssertEqual(ok.asked, 1)
        try checkFixtureTree(try archive.rootFolder())
    }

    func testEncryptedZipListsWithoutPassword() throws {
        let archive = try SZArchiveOpener.openArchive(atPath: fixture("secret.zip"), formatHint: nil, passwordDelegate: nil)
        let root = try archive.rootFolder()
        XCTAssertEqual(names(root), ["notes.md", "readme.txt", "sub"])
        let encrypted = root.propertyOfItem(at: index(of: "readme.txt", in: root), propID: .encrypted) as? Bool
        XCTAssertEqual(encrypted, true)
    }

    // MARK: - File system and root folders

    func testFileSystemFolder() throws {
        let folder = try SZFileSystemFolder.folder(withPath: Self.fixtures)
        XCTAssertEqual(folder.folderType, "FSFolder")
        XCTAssertTrue(folder.isFileSystem)
        XCTAssertEqual(folder.directoryPath, Self.fixtures + "/")
        XCTAssertEqual(folder.fullPath, folder.directoryPath)
        XCTAssertTrue(names(folder).contains("test.7z"))
        let i = index(of: "test.7z", in: folder)
        let attrs = try FileManager.default.attributesOfItem(atPath: fixture("test.7z"))
        XCTAssertEqual(folder.sizeOfItem(at: i), (attrs[.size] as? NSNumber)?.uint64Value)
        XCTAssertEqual(folder.fullPathOfItem(at: i), fixture("test.7z"))
        XCTAssertFalse(folder.isDirectory(at: i))
        // full FSFolder column set (FSFolder.cpp kProps, 7zFM 26.03's order, then the macOS-only
        // columns; listfeel.md §5); see FSFolderTests for the details
        XCTAssertEqual(folder.properties.map { $0.localizedName },
                       ["Name", "Size", "Modified", "Created", "Accessed", "Metadata Changed", "Attributes",
                        "Packed Size", "iNode", "Links", "Comment", "Folders", "Files", "Link", "Mode", "User", "Group"])
        XCTAssertEqual(folder.properties.map { $0.propID },
                       [.name, .size, .mtime, .ctime, .atime, .changeTime, .attrib,
                        .packSize, .inode, .links, .comment, .numSubDirs, .numSubFiles,
                        .ntReparse, .posixAttrib, .user, .group])
        XCTAssertTrue(folder.displayStringOfItem(at: i, propID: .attrib, timestampLevel: .min).contains("-rw"))
        XCTAssertNotNil(folder.propertyOfItem(at: i, propID: .mtime) as? Date)
        XCTAssertTrue(folder.supportsCompare)
        XCTAssertTrue(folder.supportsChangeNotification)
        XCTAssertNil(folder.archive)
        XCTAssertFalse(folder.isArchive)

        // open an archive item from the folder
        let archive = try SZArchiveOpener.openArchive(in: folder, itemIndex: i, formatHint: nil, passwordDelegate: nil)
        try checkFixtureTree(try archive.rootFolder())

        // parent chain: Fixtures -> ... -> "/" -> root folder -> nil
        let parent = try folder.bindToParentFolder()
        XCTAssertTrue(parent.isFileSystem)
        XCTAssertEqual(parent.path, (Self.fixtures as NSString).deletingLastPathComponent + "/")
        let slash = try SZFileSystemFolder.folder(withPath: "/")
        let root = try slash.bindToParentFolder()
        XCTAssertTrue(root.isRootFolder)
        XCTAssertTrue(try root.bindToParentFolder().isRootFolder, "root stays at the root")

        XCTAssertThrowsError(try SZFileSystemFolder.folder(withPath: fixture("test.7z"))) { error in
            XCTAssertEqual((error as NSError).code, SZError.notFolder.rawValue)
        }
        XCTAssertThrowsError(try SZFileSystemFolder.folder(withPath: "/no/such/dir")) { error in
            XCTAssertEqual((error as NSError).code, SZError.fileNotFound.rawValue)
        }
    }

    func testFileSystemChangeNotification() throws {
        let dir = NSTemporaryDirectory() + "sz-watch-\(getpid())"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let folder = try SZFileSystemFolder.folder(withPath: dir)
        XCTAssertFalse(folder.wasChanged, "first poll only arms the watcher")
        Thread.sleep(forTimeInterval: 0.2)
        try "x".write(toFile: dir + "/new.txt", atomically: true, encoding: .utf8)
        var changed = false
        for _ in 0..<40 where !changed {
            Thread.sleep(forTimeInterval: 0.1)
            changed = folder.wasChanged
        }
        XCTAssertTrue(changed, "FSEvents did not report the new file")
        XCTAssertFalse(folder.wasChanged, "flag is consumed")
        try folder.loadItems()
        XCTAssertEqual(names(folder), ["new.txt"])
    }

    func testRootFolder() throws {
        let root = SZRootFolder.makeRootFolder()
        XCTAssertTrue(root.isRootFolder)
        XCTAssertEqual(root.itemCount, 4)
        XCTAssertEqual(root.path, "")
        XCTAssertEqual(root.fullPath, "")
        XCTAssertEqual(root.nameOfItem(at: 0), "Computer")
        XCTAssertEqual(root.nameOfItem(at: 3), "Documents")
        XCTAssertEqual(SZRootFolder.rootEntryNames, ["Computer", "Volumes", "Home", "Documents"])
        XCTAssertTrue(root.isDirectory(at: 0))
        let computer = try root.bindToFolder(at: 0)
        XCTAssertEqual(computer.path, "/")
        XCTAssertTrue(computer.isFileSystem)
        let home = try root.bindToFolder(named: "Home")
        XCTAssertEqual(home.path, NSHomeDirectory() + "/")
        let byPath = try root.bindToFolder(named: Self.fixtures)
        XCTAssertEqual(byPath.path, Self.fixtures + "/")

        let volumes = try root.bindToFolder(at: 1)
        XCTAssertEqual(volumes.folderType, "FSDrives")
        XCTAssertGreaterThanOrEqual(volumes.itemCount, 1)
        XCTAssertEqual(volumes.properties.map { $0.propID }, [.name, .totalSize, .freeSpace, .type, .volumeName, .fileSystem, .clusterSize])
        // The listing order and the number of mounted volumes are both out of this test's hands:
        // another agent attaching or detaching a RAM disk must not fail it (the flake the
        // orchestrator found in FSFolderTests). Everything below is pinned to the boot volume.
        func bootIndex(of folder: SZFolder) -> Int? {
            (0..<folder.itemCount).first { (try? folder.bindToFolder(at: $0))?.path == "/" }
        }
        let boot = try XCTUnwrap(bootIndex(of: volumes), "no volume is mounted at /")
        let total = try XCTUnwrap(volumes.propertyOfItem(at: boot, propID: .totalSize) as? NSNumber)
        XCTAssertGreaterThan(total.uint64Value, 0)
        XCTAssertFalse((volumes.propertyOfItem(at: boot, propID: .fileSystem) as? String ?? "").isEmpty)
        XCTAssertTrue(try volumes.bindToFolder(at: boot).isFileSystem)
        XCTAssertTrue(try volumes.bindToParentFolder().isRootFolder)
        XCTAssertNotNil(bootIndex(of: SZRootFolder.makeVolumesFolder()),
                        "a second enumeration must list the boot volume too")

        // folderForPath variants
        XCTAssertTrue(try SZFolder.folder(forPath: "", passwordDelegate: nil).isRootFolder)
        XCTAssertEqual(try SZFolder.folder(forPath: "Volumes", passwordDelegate: nil).folderType, "FSDrives")
        XCTAssertEqual(try SZFolder.folder(forPath: "~", passwordDelegate: nil).path, NSHomeDirectory() + "/")
        let inArchive = try SZFolder.folder(forPath: fixture("test.7z") + "/sub", passwordDelegate: nil)
        XCTAssertEqual(names(inArchive), ["big.txt", "deep"])
        XCTAssertThrowsError(try SZFolder.folder(forPath: fixture("test.7z") + "/nope", passwordDelegate: nil))
    }

    func testCompareFileNames() {
        XCTAssertLessThan(SZFolder.compareFileName("file2", with: "file10"), 0)
        XCTAssertGreaterThan(SZFolder.compareFileName("file10", with: "file2"), 0)
        XCTAssertEqual(SZFolder.compareFileName("Abc", with: "abc"), 0)
        XCTAssertLessThan(SZFolder.compareFileName("a", with: "b"), 0)
    }

    // MARK: - Lang

    func testLangEnglishTable() throws {
        let lang = SZLang.shared
        XCTAssertEqual(lang.englishStringCount, 444)
        XCTAssertEqual(lang.englishString(forID: 0), "7-Zip")
        XCTAssertEqual(lang.englishString(forID: 1), "English")
        XCTAssertEqual(lang.englishString(forID: 401), "OK")
        XCTAssertEqual(lang.englishString(forID: 402), "Cancel")
        XCTAssertEqual(lang.englishString(forID: 403), "", "blank line consumes the ID without a string")
        XCTAssertEqual(lang.englishString(forID: 406), "&Yes")
        XCTAssertEqual(lang.englishString(forID: 500), "&File")
        XCTAssertEqual(lang.englishString(forID: 540), "&Open")
        XCTAssertEqual(lang.englishString(forID: 541), "Open &Inside")
        XCTAssertEqual(lang.englishString(forID: 7100), "Computer")
        XCTAssertEqual(lang.englishString(forID: 3002), "{0} object(s) selected")
        XCTAssertEqual(lang.englishString(forID: 1004), "Name")
        XCTAssertEqual(lang.englishString(forID: 1019), "CRC", "PropertyName.rc string absent from en.ttt")
        XCTAssertEqual(lang.string(forID: 1019), "CRC")
        XCTAssertTrue(lang.englishString(forID: 3009).contains("\n"), "\\n escape becomes a newline")
        XCTAssertEqual(lang.string(forID: 999_999, fallback: "fb"), "fb")
        XCTAssertEqual(lang.string(forID: 999_999), "")
    }

    func testLangLoadGerman() throws {
        let lang = SZLang.shared
        defer { try? lang.loadLanguage(code: "-") }
        try lang.loadLanguage(code: "de")
        XCTAssertEqual(lang.currentLanguageCode, "de")
        XCTAssertEqual(lang.string(forID: 0), "7-Zip")
        XCTAssertEqual(lang.string(forID: 1), "German")
        XCTAssertEqual(lang.string(forID: 2), "Deutsch")
        XCTAssertEqual(lang.string(forID: 402), "Abbrechen")
        XCTAssertEqual(lang.string(forID: 500), "&Datei")
        XCTAssertEqual(lang.translatedString(forID: 500), "&Datei")
        XCTAssertNil(lang.translatedString(forID: 999_999))
        XCTAssertEqual(lang.string(forID: 999_999), "")
        XCTAssertFalse(lang.comments.isEmpty, "translator credit lines")
        // fallback to English for an ID the translation lacks
        var missing: UInt32?
        for id in UInt32(0)...8000 where lang.translatedString(forID: id) == nil && !lang.englishString(forID: id).isEmpty {
            missing = id; break
        }
        if let id = missing {
            XCTAssertEqual(lang.string(forID: id), lang.englishString(forID: id))
        }
        // switching back
        try lang.loadLanguage(code: "-")
        XCTAssertEqual(lang.currentLanguageCode, "")
        XCTAssertEqual(lang.string(forID: 402), "Cancel")
        XCTAssertThrowsError(try lang.loadLanguage(code: "zz-nope"))
        // enumeration for the Language page
        let langs = SZLang.shared.availableLanguages
        XCTAssertEqual(langs.count, 92)
        let de = try XCTUnwrap(langs.first { $0.code == "de" })
        XCTAssertEqual(de.englishName, "German")
        XCTAssertEqual(de.nativeName, "Deutsch")
        XCTAssertGreaterThan(de.stringCount, 300)
        XCTAssertFalse(SZLang.systemLanguageCandidates.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: SZLang.langDirectoryPath + "/en.ttt"))
    }

    // MARK: - Settings

    func testSettingsRoundTrip() throws {
        let k = "Test.\(getpid())."
        defer { for key in SZSettings.keys(withPrefix: k) { SZSettings.removeKey(key) } }
        XCTAssertEqual(SZSettings.applicationID, "com.yrambler2001.7zip")

        XCTAssertNil(SZSettings.string(forKey: k + "s"))
        SZSettings.setString("héllo/wörld", forKey: k + "s")
        XCTAssertEqual(SZSettings.string(forKey: k + "s"), "héllo/wörld")
        XCTAssertTrue(SZSettings.hasKey(k + "s"))
        SZSettings.setString(nil, forKey: k + "s")
        XCTAssertFalse(SZSettings.hasKey(k + "s"))

        XCTAssertEqual(SZSettings.integer(forKey: k + "i", defaultValue: 7), 7)
        SZSettings.setInteger(-3, forKey: k + "i")
        XCTAssertEqual(SZSettings.integer(forKey: k + "i", defaultValue: 7), -3)
        SZSettings.setInteger(0x8000_0000 - 1, forKey: k + "i")
        XCTAssertEqual(SZSettings.integer(forKey: k + "i", defaultValue: 0), 0x7FFF_FFFF)

        XCTAssertTrue(SZSettings.bool(forKey: k + "b", defaultValue: true))
        SZSettings.setBool(false, forKey: k + "b")
        XCTAssertFalse(SZSettings.bool(forKey: k + "b", defaultValue: true))

        XCTAssertNil(SZSettings.boolPair(forKey: k + "bp"))
        SZSettings.setBoolPair(true, forKey: k + "bp")
        XCTAssertEqual(SZSettings.boolPair(forKey: k + "bp"), true)
        SZSettings.setBoolPair(nil, forKey: k + "bp")
        XCTAssertNil(SZSettings.boolPair(forKey: k + "bp"))

        SZSettings.setDouble(0.375, forKey: k + "d")
        XCTAssertEqual(SZSettings.double(forKey: k + "d", defaultValue: 0), 0.375, accuracy: 1e-9)

        XCTAssertNil(SZSettings.stringArray(forKey: k + "a"))
        SZSettings.setStringArray(["/a", "/b c", ""], forKey: k + "a")
        XCTAssertEqual(SZSettings.stringArray(forKey: k + "a"), ["/a", "/b c", ""])
        XCTAssertEqual(Set(SZSettings.keys(withPrefix: k)), [k + "i", k + "b", k + "d", k + "a"])

        // the engine-side accessor (NWorkDir::CInfo) shares the domain
        let original = SZWorkDirSettings.loadFromSettings()
        defer { original.save() }
        let wd = SZWorkDirSettings()
        wd.mode = .specified
        wd.path = "/tmp/sz-work"
        wd.forRemovableOnly = false
        wd.save()
        XCTAssertEqual(SZSettings.integer(forKey: SZSettingsKeyWorkDirType, defaultValue: -1), 2)
        XCTAssertEqual(SZSettings.string(forKey: SZSettingsKeyWorkDirPath), "/tmp/sz-work")
        let back = SZWorkDirSettings.loadFromSettings()
        XCTAssertEqual(back.mode, .specified)
        XCTAssertEqual(back.path, "/tmp/sz-work")
        XCTAssertFalse(back.forRemovableOnly)
    }
}
