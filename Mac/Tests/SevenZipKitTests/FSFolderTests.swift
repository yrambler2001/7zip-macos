import XCTest
import SevenZipKit

/// A self-contained SZProgressDelegate for the file-system operations. Deliberately does not
/// use the shared operation runner (owned by another scope) so these tests stand alone.
/// Every callback arrives on the worker thread that runs the operation, so the state is
/// guarded by a lock.
final class FSProgressStub: NSObject, SZProgressDelegate {

    private let lock = NSLock()

    private(set) var total: UInt64 = 0
    private(set) var completed: UInt64 = 0
    private(set) var numFilesReported: UInt64 = 0
    private(set) var currentFiles: [String] = []
    private(set) var messages: [String] = []
    private(set) var overwriteQuestions: [(exist: String, new: String)] = []
    private(set) var checkBreakCalls = 0

    /// Answer for the next overwrite question.
    var overwriteAnswer: SZOverwriteAnswer = .yes
    /// Name to hand back for `.autoRename`.
    var suggestedName: String?
    /// Ask the operation to break once this many bytes have been reported.
    var breakAfterBytes: UInt64?
    /// Ask the operation to break as soon as anything is reported.
    var breakImmediately = false

    private var shouldBreak = false

    // MARK: SZProgressDelegate

    func progressSetTotal(_ total: UInt64) {
        lock.lock(); self.total = total; lock.unlock()
    }

    func progressSetCompleted(_ completed: UInt64) {
        lock.lock()
        self.completed = completed
        if let limit = breakAfterBytes, completed >= limit { shouldBreak = true }
        lock.unlock()
    }

    func progressSetRatioInfo(inSize: UInt64, outSize: UInt64) {}

    func progressSetCurrentFile(_ path: String, isDirectory: Bool) {
        lock.lock(); currentFiles.append(path); lock.unlock()
    }

    func progressSetNumFilesProcessed(_ numFiles: UInt64) {
        lock.lock(); numFilesReported = numFiles; lock.unlock()
    }

    func progressAskOverwriteExisting(_ existName: String,
                                      existTime: Date?,
                                      existSize: NSNumber?,
                                      newName: String,
                                      newTime: Date?,
                                      newSize: NSNumber?,
                                      suggestedName: AutoreleasingUnsafeMutablePointer<NSString?>?) -> SZOverwriteAnswer {
        lock.lock()
        overwriteQuestions.append((exist: existName, new: newName))
        let answer = overwriteAnswer
        let suggestion = self.suggestedName
        lock.unlock()
        if let suggestion { suggestedName?.pointee = suggestion as NSString }
        return answer
    }

    func progressAskPassword(forPath path: String) -> String? { nil }

    func progressShowMessage(_ message: String) {
        lock.lock(); messages.append(message); lock.unlock()
    }

    func progressSetOperationResult(_ result: SZOperationResult, path: String, isEncrypted: Bool) {}

    func progressCheckBreak() -> Bool {
        lock.lock()
        checkBreakCalls += 1
        let result = shouldBreak || breakImmediately
        lock.unlock()
        return result
    }
}

/// Every test builds its own temporary tree, so nothing depends on the machine's contents.
final class FSFolderTests: XCTestCase {

    private var root: String = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("sz-fsfolder-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    // MARK: helpers

    private func path(_ components: String...) -> String {
        components.reduce(root) { ($0 as NSString).appendingPathComponent($1) }
    }

    private func write(_ contents: String, to relativePath: String) throws {
        let full = path(relativePath)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent,
                                               withIntermediateDirectories: true)
        try contents.write(toFile: full, atomically: true, encoding: .utf8)
    }

    private func mkdir(_ relativePath: String) throws {
        try FileManager.default.createDirectory(atPath: path(relativePath), withIntermediateDirectories: true)
    }

    private func names(_ folder: SZFolder) -> [String] {
        (0..<folder.itemCount).map { folder.nameOfItem(at: $0) }.sorted()
    }

    private func index(of name: String, in folder: SZFolder) throws -> Int {
        for i in 0..<folder.itemCount where folder.nameOfItem(at: i) == name { return i }
        throw XCTSkip("item \(name) not found")
    }

    private func folder(_ subPath: String? = nil) throws -> SZFileSystemFolder {
        try SZFileSystemFolder.folder(withPath: subPath.map { path($0) } ?? root)
    }

    // MARK: - Phase 1: listing

    func testListingAllColumns() throws {
        try write("hello world!", to: "readme.txt")          // 12 bytes
        try mkdir("sub")
        try write("x", to: "sub/inner.txt")

        let f = try folder()
        XCTAssertEqual(names(f), ["readme.txt", "sub"])

        let i = try index(of: "readme.txt", in: f)
        XCTAssertEqual(f.sizeOfItem(at: i), 12)
        XCTAssertFalse(f.isDirectory(at: i))
        XCTAssertEqual(f.fullPathOfItem(at: i), path("readme.txt"))

        // Name / Extension
        XCTAssertEqual(f.propertyOfItem(at: i, propID: .name) as? String, "readme.txt")
        XCTAssertEqual(f.propertyOfItem(at: i, propID: .extension) as? String, "txt")

        // Size and Packed Size (physical size on disk: st_blocks * 512, a whole number of blocks)
        XCTAssertEqual((f.propertyOfItem(at: i, propID: .size) as? NSNumber)?.uint64Value, 12)
        let packed = try XCTUnwrap(f.propertyOfItem(at: i, propID: .packSize) as? NSNumber).uint64Value
        XCTAssertGreaterThanOrEqual(packed, 512)
        XCTAssertEqual(packed % 512, 0)

        // three timestamps + the metadata-changed one
        for propID: SZPropID in [.mtime, .ctime, .atime, .changeTime] {
            XCTAssertNotNil(f.propertyOfItem(at: i, propID: propID) as? Date, "\(propID)")
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: path("readme.txt"))
        let mtime = try XCTUnwrap(f.propertyOfItem(at: i, propID: .mtime) as? Date)
        let realMtime = try XCTUnwrap(attrs[.modificationDate] as? Date)
        XCTAssertEqual(mtime.timeIntervalSince1970, realMtime.timeIntervalSince1970, accuracy: 1.0)

        // Attributes: A (archive, i.e. not a directory) + the POSIX mode string
        let attribText = f.displayStringOfItem(at: i, propID: .attrib, timestampLevel: .min)
        XCTAssertTrue(attribText.hasPrefix("A"), attribText)
        XCTAssertTrue(attribText.contains("-rw"), attribText)
        XCTAssertNotNil(f.propertyOfItem(at: i, propID: .posixAttrib) as? NSNumber)
        XCTAssertNotNil(f.propertyOfItem(at: i, propID: .inode) as? NSNumber)
        XCTAssertEqual((f.propertyOfItem(at: i, propID: .links) as? NSNumber)?.uint64Value, 1)
        XCTAssertEqual(f.propertyOfItem(at: i, propID: .user) as? String, NSUserName())
        XCTAssertNotNil(f.propertyOfItem(at: i, propID: .group) as? String)

        // kpidIsDir, and folders show no size until it is calculated (FSFolder.cpp GetProperty)
        let sub = try index(of: "sub", in: f)
        XCTAssertEqual(f.propertyOfItem(at: sub, propID: .isDir) as? NSNumber, NSNumber(value: true))
        XCTAssertTrue(f.isDirectory(at: sub))
        XCTAssertNil(f.propertyOfItem(at: sub, propID: .size))
        XCTAssertNil(f.propertyOfItem(at: sub, propID: .packSize))
        XCTAssertNil(f.propertyOfItem(at: sub, propID: .numSubDirs))
        XCTAssertNil(f.propertyOfItem(at: sub, propID: .numSubFiles))
        XCTAssertEqual(f.displayStringOfItem(at: sub, propID: .attrib, timestampLevel: .min).prefix(1), "D")

        // alternate streams and Windows security are hidden (01 "Windows-only" decisions)
        XCTAssertFalse(f.properties.contains { $0.propID == .isAltStream || $0.propID == .ntSecure })
        XCTAssertEqual(f.propertyOfItem(at: i, propID: .isAltStream) as? NSNumber, NSNumber(value: false))

        // default-hidden columns
        let hidden = SZFileSystemFolder.defaultHiddenPropIDs
        for propID: SZPropID in [.atime, .changeTime, .attrib, .packSize, .inode, .links, .ntReparse,
                                 .posixAttrib, .user, .group] {
            XCTAssertTrue(hidden.contains(NSNumber(value: propID.rawValue)), "\(propID)")
        }
        XCTAssertFalse(hidden.contains(NSNumber(value: SZPropID.name.rawValue)))
        XCTAssertFalse(hidden.contains(NSNumber(value: SZPropID.size.rawValue)))
    }

    func testSymlinkListing() throws {
        try write("target contents", to: "target.txt")
        try mkdir("realdir")
        try FileManager.default.createSymbolicLink(atPath: path("link.txt"), withDestinationPath: "target.txt")
        try FileManager.default.createSymbolicLink(atPath: path("dirlink"), withDestinationPath: "realdir")
        try FileManager.default.createSymbolicLink(atPath: path("broken"), withDestinationPath: "nowhere")

        let f = try folder()
        XCTAssertEqual(names(f), ["broken", "dirlink", "link.txt", "realdir", "target.txt"])

        let link = try index(of: "link.txt", in: f)
        XCTAssertTrue(f.isSymbolicLink(at: link))
        XCTAssertFalse(f.isDirectory(at: link), "a link to a file is not a directory")
        // the link is not followed: the size is the length of the target string
        XCTAssertEqual(f.sizeOfItem(at: link), UInt64("target.txt".utf8.count))
        XCTAssertEqual(f.linkTargetOfItem(at: link), "target.txt")
        XCTAssertEqual(f.propertyOfItem(at: link, propID: .ntReparse) as? String, "target.txt")
        XCTAssertEqual(f.propertyOfItem(at: link, propID: .symLink) as? String, "target.txt")
        let attribText = f.displayStringOfItem(at: link, propID: .attrib, timestampLevel: .min)
        XCTAssertTrue(attribText.contains("L"), attribText)

        // a symlink to a directory navigates like a directory
        let dirlink = try index(of: "dirlink", in: f)
        XCTAssertTrue(f.isDirectory(at: dirlink))
        XCTAssertTrue(f.isSymbolicLink(at: dirlink))
        XCTAssertEqual(f.linkTargetOfItem(at: dirlink), "realdir")

        // a broken link still lists
        let broken = try index(of: "broken", in: f)
        XCTAssertTrue(f.isSymbolicLink(at: broken))
        XCTAssertEqual(f.linkTargetOfItem(at: broken), "nowhere")
        XCTAssertFalse(f.isDirectory(at: broken))

        let plain = try index(of: "target.txt", in: f)
        XCTAssertFalse(f.isSymbolicLink(at: plain))
        XCTAssertNil(f.linkTargetOfItem(at: plain))
    }

    func testHiddenFileFiltering() throws {
        try write("visible", to: "visible.txt")
        try write("dot", to: ".hidden")

        // Windows 7zFM always lists hidden files, so YES is the default
        let f = try folder()
        XCTAssertTrue(f.showHiddenFiles)
        XCTAssertEqual(names(f), [".hidden", "visible.txt"])
        let dot = try index(of: ".hidden", in: f)
        let attribText = f.displayStringOfItem(at: dot, propID: .attrib, timestampLevel: .min)
        XCTAssertTrue(attribText.contains("H"), attribText)

        f.showHiddenFiles = false
        try f.loadItems()
        XCTAssertEqual(names(f), ["visible.txt"])

        f.showHiddenFiles = true
        try f.loadItems()
        XCTAssertEqual(names(f), [".hidden", "visible.txt"])
    }

    func testPackagesAreDirectories() throws {
        try mkdir("Demo.app/Contents")
        try write("plain", to: "plain")
        let f = try folder()
        let app = try index(of: "Demo.app", in: f)
        XCTAssertTrue(f.isDirectory(at: app))
        XCTAssertTrue(f.isPackage(at: app))
        XCTAssertFalse(f.isPackage(at: try index(of: "plain", in: f)))
        // and it can still be entered like any directory
        let inside = try f.bindToFolder(at: app)
        XCTAssertEqual(names(inside), ["Contents"])
    }

    // MARK: - Phase 2: operations

    func testCreateFolderAndFile() throws {
        let f = try folder()
        XCTAssertNoThrow(try f.createFolder(named: "made"))
        XCTAssertNoThrow(try f.createFolder(named: "a/b/c"))        // complex path
        XCTAssertNoThrow(try f.createFile(named: "made.txt"))
        try f.loadItems()
        XCTAssertEqual(names(f), ["a", "made", "made.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("a/b/c")))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("made.txt"))).count, 0)

        // name collisions fail, like Windows (CREATE_NEW / CreateDir)
        XCTAssertThrowsError(try f.createFile(named: "made.txt"))
        XCTAssertThrowsError(try f.createFolder(named: "made"))
    }

    func testRenameAndCollision() throws {
        try write("a", to: "one.txt")
        try write("b", to: "two.txt")
        try mkdir("dir")
        let f = try folder()
        try f.renameItem(at: try index(of: "one.txt", in: f), to: "renamed.txt")
        try f.loadItems()
        XCTAssertEqual(names(f), ["dir", "renamed.txt", "two.txt"])

        // an existing name must not be silently replaced (rename(2) would)
        XCTAssertThrowsError(try f.renameItem(at: try index(of: "two.txt", in: f), to: "renamed.txt"))
        XCTAssertEqual(try String(contentsOfFile: path("renamed.txt"), encoding: .utf8), "a")

        // "sub/name" moves the item into a sub-folder (01 section 3.11)
        try f.renameItem(at: try index(of: "two.txt", in: f), to: "dir/moved.txt")
        try f.loadItems()
        XCTAssertEqual(names(f), ["dir", "renamed.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("dir/moved.txt")))
    }

    func testCopyItemsToDirectory() throws {
        try write(String(repeating: "x", count: 5000), to: "big.txt")
        try write("small", to: "small.txt")
        try mkdir("dest")
        try mkdir("tree/nested")
        try write("deep", to: "tree/nested/deep.txt")
        try FileManager.default.createSymbolicLink(atPath: path("tree/link"), withDestinationPath: "nested/deep.txt")

        let f = try folder()
        let stub = FSProgressStub()
        try f.copyItems(at: [try index(of: "big.txt", in: f),
                             try index(of: "small.txt", in: f),
                             try index(of: "tree", in: f)].map(NSNumber.init(value:)),
                        toPath: path("dest") + "/",
                        move: false,
                        delegate: stub)

        XCTAssertEqual(try String(contentsOfFile: path("dest/small.txt"), encoding: .utf8), "small")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path("dest/big.txt"))).count, 5000)
        XCTAssertEqual(try String(contentsOfFile: path("dest/tree/nested/deep.txt"), encoding: .utf8), "deep")
        // the source is untouched
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("big.txt")))

        // a symlink is copied as a link, not as its target
        let destLink = path("dest/tree/link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destLink), "nested/deep.txt")

        // progress: total = 5000 + 5 + 4 + link length, and it ends full
        XCTAssertEqual(stub.total, 5000 + 5 + 4 + UInt64("nested/deep.txt".utf8.count))
        XCTAssertEqual(stub.completed, stub.total)
        XCTAssertEqual(stub.numFilesReported, 4)
        XCTAssertEqual(stub.currentFiles.count, 4)
        XCTAssertTrue(stub.messages.isEmpty, "\(stub.messages)")
        XCTAssertTrue(stub.overwriteQuestions.isEmpty)

        // timestamps and POSIX mode are preserved
        let srcAttrs = try FileManager.default.attributesOfItem(atPath: path("big.txt"))
        let dstAttrs = try FileManager.default.attributesOfItem(atPath: path("dest/big.txt"))
        let srcTime = try XCTUnwrap(srcAttrs[.modificationDate] as? Date)
        let dstTime = try XCTUnwrap(dstAttrs[.modificationDate] as? Date)
        XCTAssertEqual(srcTime.timeIntervalSince1970, dstTime.timeIntervalSince1970, accuracy: 0.01)
        XCTAssertEqual(srcAttrs[.posixPermissions] as? NSNumber, dstAttrs[.posixPermissions] as? NSNumber)
    }

    func testCopyItemToExactPath() throws {
        try write("payload", to: "one.txt")
        try mkdir("dest")
        let f = try folder()
        // no trailing separator: the destination is the exact target name
        try f.copyItems(at: [NSNumber(value: try index(of: "one.txt", in: f))],
                        toPath: path("dest/other.txt"), move: false, delegate: nil)
        XCTAssertEqual(try String(contentsOfFile: path("dest/other.txt"), encoding: .utf8), "payload")
        // more than one item with an exact path is rejected (Windows rule)
        try write("second", to: "two.txt")
        try f.loadItems()
        XCTAssertThrowsError(try f.copyItems(at: [NSNumber(value: 0), NSNumber(value: 1)],
                                            toPath: path("dest/other.txt"), move: false, delegate: nil))
    }

    func testCopyExtendedAttributesAndFlags() throws {
        try write("body", to: "file.txt")
        try mkdir("dest")
        let url = URL(fileURLWithPath: path("file.txt"))
        let value = "hello".data(using: .utf8)!
        value.withUnsafeBytes { raw in
            let rc = setxattr(url.path, "org.7zip.test", raw.baseAddress, raw.count, 0, 0)
            XCTAssertEqual(rc, 0, "setxattr failed: \(errno)")
        }

        let f = try folder()
        try f.copyItems(at: [NSNumber(value: try index(of: "file.txt", in: f))],
                        toPath: path("dest") + "/", move: false, delegate: nil)

        let destPath = path("dest/file.txt")
        let size = getxattr(destPath, "org.7zip.test", nil, 0, 0, 0)
        XCTAssertEqual(size, 5, "extended attribute was not copied")
    }

    func testMoveWithinVolume() throws {
        try write("payload", to: "file.txt")
        try mkdir("tree/nested")
        try write("deep", to: "tree/nested/deep.txt")
        try mkdir("dest")

        let f = try folder()
        let stub = FSProgressStub()
        try f.copyItems(at: [try index(of: "file.txt", in: f), try index(of: "tree", in: f)].map(NSNumber.init(value:)),
                        toPath: path("dest") + "/",
                        move: true,
                        delegate: stub)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path("file.txt")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("tree")))
        XCTAssertEqual(try String(contentsOfFile: path("dest/file.txt"), encoding: .utf8), "payload")
        XCTAssertEqual(try String(contentsOfFile: path("dest/tree/nested/deep.txt"), encoding: .utf8), "deep")
        XCTAssertEqual(stub.completed, stub.total, "progress must end full even for a rename")
        try f.loadItems()
        XCTAssertEqual(names(f), ["dest"])
    }

    func testMoveOntoItselfIsRefused() throws {
        try write("payload", to: "file.txt")
        let f = try folder()
        let stub = FSProgressStub()
        XCTAssertThrowsError(try f.copyItems(at: [NSNumber(value: try index(of: "file.txt", in: f))],
                                            toPath: root + "/", move: true, delegate: stub)) { error in
            XCTAssertEqual((error as NSError).code, SZError.cancelled.rawValue)
        }
        XCTAssertEqual(stub.messages, ["Cannot move file onto itself : \(path("file.txt"))"])
        XCTAssertEqual(try String(contentsOfFile: path("file.txt"), encoding: .utf8), "payload")
    }

    func testCopyFromExternalPaths() throws {
        // an "external" tree outside the destination folder
        try mkdir("outside")
        try write("one", to: "outside/one.txt")
        try mkdir("outside/dir")
        try write("two", to: "outside/dir/two.txt")
        try mkdir("inside")

        let dest = try folder("inside")
        let stub = FSProgressStub()
        try dest.copy(paths: [path("outside/one.txt"), path("outside/dir")], move: false, delegate: stub)
        try dest.loadItems()
        XCTAssertEqual(names(dest), ["dir", "one.txt"])
        XCTAssertEqual(try String(contentsOfFile: path("inside/dir/two.txt"), encoding: .utf8), "two")
        XCTAssertEqual(stub.total, 6)
        XCTAssertEqual(stub.completed, stub.total)
        // the sources survive a copy
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("outside/one.txt")))

        // and the class-level drag & drop entry point moves
        try SZFileSystemFolder.copy(paths: [path("outside/one.txt")],
                                    toDirectory: path("inside/dir"), move: true, delegate: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("outside/one.txt")))
        XCTAssertEqual(try String(contentsOfFile: path("inside/dir/one.txt"), encoding: .utf8), "one")
    }

    func testOverwriteQuestionAnswers() throws {
        try write("new contents", to: "file.txt")
        try mkdir("dest")
        try write("old", to: "dest/file.txt")
        let f = try folder()
        let i = NSNumber(value: try index(of: "file.txt", in: f))
        let destDir = path("dest") + "/"

        // No: the destination is kept and the total shrinks by the skipped size
        let no = FSProgressStub()
        no.overwriteAnswer = .no
        try f.copyItems(at: [i], toPath: destDir, move: false, delegate: no)
        XCTAssertEqual(no.overwriteQuestions.count, 1)
        XCTAssertEqual(no.overwriteQuestions.first?.exist, path("dest/file.txt"))
        XCTAssertEqual(no.overwriteQuestions.first?.new, path("file.txt"))
        XCTAssertEqual(try String(contentsOfFile: path("dest/file.txt"), encoding: .utf8), "old")

        // Auto rename: the destination is kept and a "file_2.txt" style copy appears
        let rename = FSProgressStub()
        rename.overwriteAnswer = .autoRename
        try f.copyItems(at: [i], toPath: destDir, move: false, delegate: rename)
        XCTAssertEqual(try String(contentsOfFile: path("dest/file.txt"), encoding: .utf8), "old")
        let renamed = try FileManager.default.contentsOfDirectory(atPath: path("dest")).sorted()
        XCTAssertEqual(renamed.count, 2, "\(renamed)")
        let copyName = try XCTUnwrap(renamed.first { $0 != "file.txt" })
        XCTAssertEqual(try String(contentsOfFile: path("dest/\(copyName)"), encoding: .utf8), "new contents")
        try FileManager.default.removeItem(atPath: path("dest/\(copyName)"))

        // Yes: overwritten
        let yes = FSProgressStub()
        yes.overwriteAnswer = .yes
        try f.copyItems(at: [i], toPath: destDir, move: false, delegate: yes)
        XCTAssertEqual(try String(contentsOfFile: path("dest/file.txt"), encoding: .utf8), "new contents")

        // Cancel: E_ABORT reaches the caller
        try write("third", to: "dest/file.txt")
        let cancel = FSProgressStub()
        cancel.overwriteAnswer = .cancel
        XCTAssertThrowsError(try f.copyItems(at: [i], toPath: destDir, move: false, delegate: cancel)) { error in
            XCTAssertEqual((error as NSError).code, SZError.cancelled.rawValue)
        }
        XCTAssertEqual(try String(contentsOfFile: path("dest/file.txt"), encoding: .utf8), "third")

        // No delegate at all: the copy proceeds (the panel scope supplies the dialog)
        try f.copyItems(at: [i], toPath: destDir, move: false, delegate: nil)
        XCTAssertEqual(try String(contentsOfFile: path("dest/file.txt"), encoding: .utf8), "new contents")
    }

    func testCancelLongCopy() throws {
        // 8 MiB is > 100 progress chunks, so the break is noticed well before the end
        let big = Data(count: 8 << 20)
        try big.write(to: URL(fileURLWithPath: path("big.bin")))
        try mkdir("dest")

        let f = try folder()
        let stub = FSProgressStub()
        stub.breakAfterBytes = 1     // break at the first non-zero progress report
        XCTAssertThrowsError(try f.copyItems(at: [NSNumber(value: try index(of: "big.bin", in: f))],
                                            toPath: path("dest") + "/",
                                            move: false,
                                            delegate: stub)) { error in
            XCTAssertEqual((error as NSError).code, SZError.cancelled.rawValue)
            XCTAssertEqual((error as NSError).domain, SZErrorDomain)
        }
        XCTAssertGreaterThan(stub.checkBreakCalls, 0)
        XCTAssertLessThan(stub.completed, stub.total, "the copy must stop early")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("dest/big.bin")),
                       "the truncated destination must be removed")
    }

    func testDeleteToTrashAndPermanently() throws {
        try write("perm", to: "perm.txt")
        try mkdir("permdir/nested")
        try write("deep", to: "permdir/nested/deep.txt")
        try write("trashed", to: "trashme.txt")

        let f = try folder()
        XCTAssertTrue(f.deleteToTrash, "macOS Delete goes to the Trash by default")

        // permanent delete of a file and of a whole tree
        let stub = FSProgressStub()
        try f.deleteItems(at: [try index(of: "perm.txt", in: f), try index(of: "permdir", in: f)].map(NSNumber.init(value:)),
                          toTrash: false,
                          delegate: stub)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("perm.txt")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("permdir")))
        XCTAssertEqual(stub.total, 2, "SetTotal(numItems), like FSFolder::Delete")
        XCTAssertEqual(stub.completed, 2)
        XCTAssertTrue(stub.messages.isEmpty, "\(stub.messages)")

        // to the Trash
        try f.loadItems()
        try f.deleteItems(at: [NSNumber(value: try index(of: "trashme.txt", in: f))], toTrash: true, delegate: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("trashme.txt")))
        // Listing ~/.Trash needs Full Disk Access, which the test host may not have; when it is
        // readable, check the file really landed there (the Trash renames on a name clash).
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: false),
           let trashNames = try? FileManager.default.contentsOfDirectory(atPath: trash.path) {
            XCTAssertTrue(trashNames.contains { $0.hasPrefix("trashme") }, "not found in \(trash.path)")
            for name in trashNames where name.hasPrefix("trashme") {
                try? FileManager.default.removeItem(at: trash.appendingPathComponent(name))
            }
        }

        try f.loadItems()
        XCTAssertEqual(names(f), [])
    }

    func testDeleteReadOnlyAndLockedItems() throws {
        try write("locked", to: "locked.txt")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o444)],
                                             ofItemAtPath: path("locked.txt"))
        XCTAssertEqual(chflags(path("locked.txt"), UInt32(UF_IMMUTABLE)), 0)
        let f = try folder()
        let i = try index(of: "locked.txt", in: f)
        XCTAssertTrue(f.displayStringOfItem(at: i, propID: .attrib, timestampLevel: .min).contains("R"))
        try f.deleteItems(at: [NSNumber(value: i)], toTrash: false, delegate: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("locked.txt")))
    }

    func testCalculateFullSize() throws {
        // a known tree: 3 files of 10 + 20 + 30 bytes in 2 sub-directories
        try mkdir("tree/a/b")
        try write(String(repeating: "1", count: 10), to: "tree/one.txt")
        try write(String(repeating: "2", count: 20), to: "tree/a/two.txt")
        try write(String(repeating: "3", count: 30), to: "tree/a/b/three.txt")

        let f = try folder()
        let tree = try index(of: "tree", in: f)
        XCTAssertNil(f.propertyOfItem(at: tree, propID: .size))

        let stub = FSProgressStub()
        try f.calculateFullSize(at: tree, delegate: stub)
        XCTAssertEqual(f.sizeOfItem(at: tree), 0, "GetItemSize keeps reporting 0 for folders")
        XCTAssertEqual((f.propertyOfItem(at: tree, propID: .size) as? NSNumber)?.uint64Value, 60)
        XCTAssertEqual((f.propertyOfItem(at: tree, propID: .numSubDirs) as? NSNumber)?.uint64Value, 2)
        XCTAssertEqual((f.propertyOfItem(at: tree, propID: .numSubFiles) as? NSNumber)?.uint64Value, 3)
        XCTAssertNotNil(f.propertyOfItem(at: tree, propID: .packSize))

        // cancellable
        let breaker = FSProgressStub()
        breaker.breakImmediately = true
        let f2 = try folder()
        XCTAssertThrowsError(try f2.calculateFullSize(at: try index(of: "tree", in: f2), delegate: breaker)) { error in
            XCTAssertEqual((error as NSError).code, SZError.cancelled.rawValue)
        }
    }

    func testFlatMode() throws {
        try mkdir("a/b")
        try write("1", to: "top.txt")
        try write("2", to: "a/mid.txt")
        try write("3", to: "a/b/deep.txt")
        try FileManager.default.createSymbolicLink(atPath: path("a/loop"), withDestinationPath: "..")

        let f = try folder()
        XCTAssertTrue(f.supportsFlatMode)
        XCTAssertFalse(f.flatMode)
        XCTAssertEqual(names(f), ["a", "top.txt"])
        // Path Prefix is not a column outside flat view (GetNumberOfProperties drops it)
        XCTAssertFalse(f.properties.contains { $0.propID == .prefix })

        f.flatMode = true
        try f.loadItems()
        XCTAssertTrue(f.properties.contains { $0.propID == .prefix })
        XCTAssertEqual(names(f), ["a", "b", "deep.txt", "loop", "mid.txt", "top.txt"])

        let deep = try index(of: "deep.txt", in: f)
        XCTAssertEqual(f.prefixOfItem(at: deep), "a/b/")
        XCTAssertEqual(f.propertyOfItem(at: deep, propID: .prefix) as? String, "a/b/")
        XCTAssertEqual(f.fullPathOfItem(at: deep), path("a/b/deep.txt"))
        XCTAssertEqual(f.prefixOfItem(at: try index(of: "top.txt", in: f)), "")
        // the symlink to ".." is listed but never followed, so the listing terminates
        XCTAssertTrue(f.isSymbolicLink(at: try index(of: "loop", in: f)))

        f.flatMode = false
        try f.loadItems()
        XCTAssertEqual(names(f), ["a", "top.txt"])
    }

    func testCommentRoundTrip() throws {
        try write("body", to: "file.txt")
        let f = try folder()
        let i = try index(of: "file.txt", in: f)
        XCTAssertNil(f.propertyOfItem(at: i, propID: .comment))
        try f.setComment("a nice file", forItem: i)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("descript.ion")))
        try f.loadItems()
        let j = try index(of: "file.txt", in: f)
        XCTAssertEqual(f.propertyOfItem(at: j, propID: .comment) as? String, "a nice file")
        try f.setComment(nil, forItem: j)
        try f.loadItems()
        XCTAssertNil(f.propertyOfItem(at: try index(of: "file.txt", in: f), propID: .comment))
    }

    // MARK: - Phase 3: volumes root

    func testVolumesRoot() throws {
        let root = SZRootFolder.makeRootFolder()
        XCTAssertTrue(root.isRootFolder)
        XCTAssertFalse(root.isVolumesFolder)
        XCTAssertEqual(SZRootFolder.rootEntryNames.count, 4)

        let volumes = SZRootFolder.makeVolumesFolder()
        XCTAssertEqual(volumes.folderType, "FSDrives")
        XCTAssertTrue(volumes.isVolumesFolder)
        XCTAssertGreaterThanOrEqual(volumes.itemCount, 1)
        XCTAssertTrue(volumes.supportsChangeNotification, "volumes appearing / disappearing")

        var sawBootVolume = false
        for i in 0..<volumes.itemCount {
            XCTAssertTrue(volumes.isDirectory(at: i))
            XCTAssertFalse(volumes.nameOfItem(at: i).isEmpty)
            let mount = try XCTUnwrap(volumes.mountPathOfItem(at: i), "no mount path for item \(i)")
            XCTAssertTrue(mount.hasSuffix("/"), mount)
            XCTAssertTrue(FileManager.default.fileExists(atPath: mount), mount)
            if mount == "/" { sawBootVolume = true }
            XCTAssertFalse((volumes.propertyOfItem(at: i, propID: .fileSystem) as? String ?? "").isEmpty)
            let type = try XCTUnwrap(volumes.propertyOfItem(at: i, propID: .type) as? String)
            XCTAssertTrue(["Fixed", "Removable", "Remote", "CD-ROM"].contains(type), type)
            XCTAssertNotNil(volumes.propertyOfItem(at: i, propID: .volumeName) as? String)
            XCTAssertNotNil(volumes.propertyOfItem(at: i, propID: .outName) as? String)
            XCTAssertNotNil(volumes.propertyOfItem(at: i, propID: .totalSize) as? NSNumber)
            XCTAssertNotNil(volumes.propertyOfItem(at: i, propID: .freeSpace) as? NSNumber)
            XCTAssertNotNil(volumes.propertyOfItem(at: i, propID: .clusterSize) as? NSNumber)

            // navigating into a volume lands in the file-system folder of its mount point
            let fs = try volumes.bindToFolder(at: i)
            XCTAssertTrue(fs.isFileSystem)
            XCTAssertEqual(fs.path, mount)
        }
        XCTAssertTrue(sawBootVolume, "the boot volume \"/\" must be listed")

        // the mount table did not change between two polls
        XCTAssertFalse(volumes.wasChanged)
        XCTAssertTrue(try volumes.bindToParentFolder().isRootFolder)

        // a mount point goes up to the volumes list (Windows: a drive root goes up to Computer)
        let slash = try SZFileSystemFolder.folder(withPath: "/")
        XCTAssertTrue(try slash.bindToParentFolder().isRootFolder)
    }

    /// Cross-volume copy and move (the EXDEV path: rename fails, so it is copy + delete) and the
    /// volumes folder noticing a mount and an unmount. Uses a RAM disk; skipped where one cannot
    /// be created.
    func testCrossVolumeCopyMoveAndVolumeRefresh() throws {
        func run(_ tool: String, _ args: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw XCTSkip("\(tool) \(args.joined(separator: " ")) exited \(process.terminationStatus)")
            }
            return String(data: data, encoding: .utf8) ?? ""
        }

        // the volumes folder must exist before the mount so that wasChanged can notice it
        let volumes = SZRootFolder.makeVolumesFolder()
        XCTAssertFalse(volumes.wasChanged)

        // Never assert the *total* number of volumes: another process (a parallel agent, Time
        // Machine, a .dmg opened by hand) can mount or unmount a disk while this test runs and the
        // total then disagrees for a reason that has nothing to do with the code under test
        // (ai/requests.md, orchestrator -> fsfolder). Assert only that this test's own volume
        // appears and disappears again.
        func volumeNames() throws -> [String] {
            try volumes.loadItems()
            return (0..<volumes.itemCount).map { volumes.nameOfItem(at: $0) }
        }
        func waitForVolume(_ name: String, listed: Bool) throws -> Bool {
            let deadline = Date().addingTimeInterval(20)
            repeat {
                if try volumeNames().contains(name) == listed { return true }
                Thread.sleep(forTimeInterval: 0.2)
            } while Date() < deadline
            return false
        }

        let volumeName = "sz-fsfolder-\(getpid())"
        let device = try run("/usr/bin/hdiutil", ["attach", "-nomount", "ram://32768"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard device.hasPrefix("/dev/disk") else { throw XCTSkip("no RAM disk: \(device)") }
        var detached = false
        defer { if !detached { _ = try? run("/usr/bin/hdiutil", ["detach", device]) } }
        _ = try run("/usr/sbin/diskutil", ["eraseVolume", "HFS+", volumeName, device])
        let mount = "/Volumes/\(volumeName)"
        guard FileManager.default.fileExists(atPath: mount) else { throw XCTSkip("RAM disk not mounted") }

        func pollVolumesChanged() -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if volumes.wasChanged { return true }
                Thread.sleep(forTimeInterval: 0.2)
            }
            return false
        }

        XCTAssertTrue(pollVolumesChanged(), "a new mount must be reported")
        XCTAssertTrue(try waitForVolume(volumeName, listed: true),
                      "the new volume is not listed")
        let vol = try index(of: volumeName, in: volumes)
        XCTAssertEqual(volumes.mountPathOfItem(at: vol), mount + "/")
        XCTAssertEqual(volumes.propertyOfItem(at: vol, propID: .fileSystem) as? String, "hfs")
        XCTAssertEqual(volumes.propertyOfItem(at: vol, propID: .type) as? String, "Removable")
        XCTAssertGreaterThan(try XCTUnwrap(volumes.propertyOfItem(at: vol, propID: .totalSize) as? NSNumber).uint64Value, 0)
        let volFolder = try volumes.bindToFolder(at: vol)
        XCTAssertTrue(volFolder.isFileSystem)
        XCTAssertEqual(volFolder.path, mount + "/")

        // ---- cross-volume copy
        try write(String(repeating: "c", count: 2000), to: "copyme.txt")
        try mkdir("tree/nested")
        try write("deep", to: "tree/nested/deep.txt")
        try FileManager.default.createSymbolicLink(atPath: path("tree/link"), withDestinationPath: "nested/deep.txt")
        try write(String(repeating: "m", count: 1500), to: "moveme.txt")

        let f = try folder()
        let copyStub = FSProgressStub()
        try f.copyItems(at: [try index(of: "copyme.txt", in: f), try index(of: "tree", in: f)].map(NSNumber.init(value:)),
                        toPath: mount + "/", move: false, delegate: copyStub)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: mount + "/copyme.txt")).count, 2000)
        XCTAssertEqual(try String(contentsOfFile: mount + "/tree/nested/deep.txt", encoding: .utf8), "deep")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: mount + "/tree/link"),
                       "nested/deep.txt")
        XCTAssertEqual(copyStub.completed, copyStub.total)
        XCTAssertTrue(copyStub.messages.isEmpty, "\(copyStub.messages)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path("copyme.txt")))

        // ---- cross-volume move: rename(2) returns EXDEV, so it becomes copy + delete
        let moveStub = FSProgressStub()
        try f.copyItems(at: [try index(of: "moveme.txt", in: f)].map(NSNumber.init(value:)),
                        toPath: mount + "/", move: true, delegate: moveStub)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: mount + "/moveme.txt")).count, 1500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("moveme.txt")),
                       "a cross-volume move must delete the source")
        XCTAssertEqual(moveStub.completed, moveStub.total)

        // ---- moving a whole tree across volumes
        try f.loadItems()
        try f.copyItems(at: [NSNumber(value: try index(of: "tree", in: f))],
                        toPath: mount + "/moved/", move: true, delegate: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path("tree")))
        XCTAssertEqual(try String(contentsOfFile: mount + "/moved/tree/nested/deep.txt", encoding: .utf8), "deep")

        // ---- unmount is reported too
        _ = try run("/usr/bin/hdiutil", ["detach", device])
        detached = true
        XCTAssertTrue(pollVolumesChanged(), "an unmount must be reported")
        XCTAssertTrue(try waitForVolume(volumeName, listed: false),
                      "the detached volume is still listed")
    }

    // MARK: - Phase 4: change notification

    func testChangeNotificationForThisDirectoryOnly() throws {
        try mkdir("sub")
        let f = try folder()
        XCTAssertTrue(f.supportsChangeNotification)
        XCTAssertFalse(f.wasChanged, "the first poll only arms the watcher")
        XCTAssertFalse(f.directoryWasRemoved)

        func waitForChange(_ timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if f.wasChanged { return true }
                Thread.sleep(forTimeInterval: 0.05)
            }
            return false
        }

        Thread.sleep(forTimeInterval: 0.3)
        try write("new", to: "new.txt")
        XCTAssertTrue(waitForChange(5), "FSEvents did not report the new file")
        XCTAssertFalse(f.wasChanged, "the flag is consumed")

        // An atomic write is a create plus a rename, so a second coalesced batch can still be
        // in flight; drain until the stream is quiet.
        func drain() {
            for _ in 0..<10 {
                _ = f.wasChanged
                Thread.sleep(forTimeInterval: 0.2)
            }
            _ = f.wasChanged
        }
        drain()

        // a change inside a sub-directory is not our directory's business (non-recursive,
        // like FindFirstChangeNotification(bWatchSubtree = false))
        try write("deep", to: "sub/deep.txt")
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertFalse(f.wasChanged, "a sub-directory change must not mark the folder as changed")
    }

    func testWatchedDirectoryDisappears() throws {
        let f = try folder()
        XCTAssertFalse(f.wasChanged)          // arms the watcher
        Thread.sleep(forTimeInterval: 0.3)
        try FileManager.default.removeItem(atPath: root)

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline && !f.directoryWasRemoved {
            _ = f.wasChanged
            Thread.sleep(forTimeInterval: 0.1)
        }
        XCTAssertTrue(f.directoryWasRemoved, "the panel must be told to navigate up")
    }
}
