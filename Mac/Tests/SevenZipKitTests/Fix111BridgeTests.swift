// Fix111BridgeTests.swift -- the bridge half of the 1.1.1 fixes (ai/reports/fix111.md):
//
//   * a directory (an app bundle such as a Chrome web-app shim, any package) tried as an archive
//     answered E_FAIL ("Unspecified error") instead of "not an archive";
//   * a folder holding odd entries -- broken and looping symlinks, unreadable files and folders, a
//     FIFO, resource forks and Finder info, the Finder's "Icon\r", names with line breaks -- lists,
//     and every property of every entry reads;
//   * a name with a character outside the BMP (an emoji, a flag, a musical symbol) came back empty:
//     the engine keeps UTF-16 surrogates in its 32-bit wchar_t, which a UTF-32 decode rejected.

import XCTest
import SevenZipKit

final class Fix111BridgeTests: XCTestCase {

    private var root = ""

    override class func setUp() {
        super.setUp()
        try? SZCodecs.loadCodecs()
        try? SZLang.shared.loadLanguage(code: "-")
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("sz-fix111-\(getpid())-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // chmod 000 entries cannot be removed until they are writable again
        if let walker = FileManager.default.enumerator(atPath: root) {
            for case let rel as String in walker { chmod(root + "/" + rel, 0o755) }
        }
        chmod(root + "/noread", 0o755)
        try? FileManager.default.removeItem(atPath: root)
        try super.tearDownWithError()
    }

    private func path(_ rel: String) -> String { (root as NSString).appendingPathComponent(rel) }

    private func touch(_ rel: String, _ text: String = "") {
        XCTAssertTrue(FileManager.default.createFile(atPath: path(rel), contents: Data(text.utf8)), rel)
    }

    private func names(_ folder: SZFolder) -> [String] {
        (0..<folder.itemCount).map { folder.nameOfItem(at: $0) }
    }

    private func index(of name: String, in folder: SZFolder) throws -> Int {
        try XCTUnwrap((0..<folder.itemCount).first { folder.nameOfItem(at: $0) == name }, "no item \(name.debugDescription)")
    }

    /// A Chrome "web app" shim as Chrome writes it into ~/Applications/Chrome Apps.localized/.
    private func makeChromeShim(_ rel: String) throws {
        let fm = FileManager.default
        for dir in ["Contents/MacOS", "Contents/Resources/en-US.lproj", "Contents/_CodeSignature"] {
            try fm.createDirectory(atPath: path(rel + "/" + dir), withIntermediateDirectories: true)
        }
        touch(rel + "/Contents/Info.plist", "<plist><dict><key>CFBundlePackageType</key><string>APPL</string></dict></plist>")
        touch(rel + "/Contents/PkgInfo", "APPL????")
        touch(rel + "/Contents/MacOS/app_mode_loader", "#!/bin/sh\n")
        chmod(path(rel + "/Contents/MacOS/app_mode_loader"), 0o755)
        touch(rel + "/Contents/Resources/app.icns")
        chmod(path(rel + "/Contents/Resources"), 0o700)
        touch(rel + "/Contents/_CodeSignature/CodeResources")
    }

    /// `xattr -w`: Finder info, a resource fork, the quarantine flag.
    private func setXattr(_ rel: String, _ name: String, _ value: [UInt8]) {
        let result = value.withUnsafeBytes { setxattr(path(rel), name, $0.baseAddress, value.count, 0, XATTR_NOFOLLOW) }
        XCTAssertEqual(result, 0, "setxattr \(name) on \(rel): errno \(errno)")
    }

    // MARK: - bug 1: E_FAIL on an app bundle

    func testADirectoryIsNotAnArchive() throws {
        let fm = FileManager.default
        try makeChromeShim("Shim.app")
        try fm.createDirectory(atPath: path("plain"), withIntermediateDirectories: true)
        try fm.createDirectory(atPath: path(".localized"), withIntermediateDirectories: true)
        let folder = try SZFileSystemFolder.folder(withPath: root)
        for name in ["Shim.app", "plain", ".localized"] {
            let i = try index(of: name, in: folder)
            XCTAssertThrowsError(try SZArchiveOpener.openArchive(in: folder, itemIndex: i, formatHint: nil,
                                                                 passwordDelegate: nil)) { error in
                let e = error as NSError
                XCTAssertEqual(e.domain, SZErrorDomain)
                XCTAssertEqual(e.code, SZError.Code.notArchive.rawValue,
                               "\(name): \(e.localizedDescription) -- a directory must read as 'not an archive', never E_FAIL")
            }
        }
    }

    func testAnAppBundleOpensAsAFolderAtEveryLevel() throws {
        try makeChromeShim("Chrome Apps.localized/Panasonic - Osprzęt elektroinstalacyjny.app")
        touch("Chrome Apps.localized/Icon\r")
        setXattr("Chrome Apps.localized/Icon\r", "com.apple.ResourceFork", Array(repeating: 7, count: 600))
        setXattr("Chrome Apps.localized/Icon\r", "com.apple.FinderInfo", [UInt8](repeating: 0, count: 32))
        try FileManager.default.createDirectory(atPath: path("Chrome Apps.localized/.localized"), withIntermediateDirectories: true)
        touch("Chrome Apps.localized/.localized/en_US.strings", "\"Chrome Apps\" = \"Chrome Apps\";")
        setXattr("Chrome Apps.localized", "com.apple.FinderInfo", [UInt8](repeating: 0, count: 32))

        let apps = try SZFolder.folder(forPath: path("Chrome Apps.localized"), passwordDelegate: nil)
        XCTAssertTrue(apps.isFileSystem)
        let fs = try XCTUnwrap(apps as? SZFileSystemFolder)
        fs.showHiddenFiles = true
        try fs.loadItems()
        XCTAssertEqual(Set(names(apps)), ["Icon\r", ".localized", "Panasonic - Osprzęt elektroinstalacyjny.app"])
        let shimIndex = try index(of: "Panasonic - Osprzęt elektroinstalacyjny.app", in: apps)
        XCTAssertTrue(fs.isPackage(at: shimIndex))
        let shim = try apps.bindToFolder(at: shimIndex)
        XCTAssertEqual(names(shim), ["Contents"])
        let contents = try shim.bindToFolder(named: "Contents")
        XCTAssertEqual(Set(names(contents)), ["MacOS", "Resources", "_CodeSignature", "Info.plist", "PkgInfo"])
        // and straight from a path, as the address bar and the command line bind it
        let direct = try SZFolder.folder(forPath: path("Chrome Apps.localized/Panasonic - Osprzęt elektroinstalacyjny.app"),
                                         passwordDelegate: nil)
        XCTAssertEqual(names(direct), ["Contents"])
        // a real, signed application bundle
        let calculator = try SZFolder.folder(forPath: "/System/Applications/Calculator.app", passwordDelegate: nil)
        XCTAssertEqual(names(calculator), ["Contents"])
        XCTAssertGreaterThan(try calculator.bindToFolder(named: "Contents").itemCount, 2)
    }

    // MARK: - per-item problems never fail the folder

    func testOddEntriesDoNotFailTheFolder() throws {
        let fm = FileManager.default
        try fm.createSymbolicLink(atPath: path("broken"), withDestinationPath: "nowhere")
        try fm.createSymbolicLink(atPath: path("loop1"), withDestinationPath: "loop2")
        try fm.createSymbolicLink(atPath: path("loop2"), withDestinationPath: "loop1")
        try fm.createSymbolicLink(atPath: path("dirlink"), withDestinationPath: "/System/Applications")
        try fm.createDirectory(atPath: path("noread"), withIntermediateDirectories: true)
        touch("noread/hidden.txt", "x")
        chmod(path("noread"), 0)
        touch("nofile", "secret")
        chmod(path("nofile"), 0)
        XCTAssertEqual(mkfifo(path("pipe"), 0o644), 0)
        touch("rsrc", "data")
        setXattr("rsrc", "com.apple.ResourceFork", Array(repeating: 1, count: 4000))
        setXattr("rsrc", "com.apple.quarantine", Array("0081;00000000;Chrome;".utf8))
        touch("Icon\r")
        touch("two\nlines")
        touch("tab\there")
        touch("bell\u{7}")
        touch("emoji 😀🇺🇦.txt")
        try makeChromeShim("Copied.app")
        try fm.createDirectory(atPath: path("x.localized"), withIntermediateDirectories: true)

        let folder = try SZFileSystemFolder.folder(withPath: root)
        let expected: Set<String> = ["broken", "loop1", "loop2", "dirlink", "noread", "nofile", "pipe", "rsrc",
                                     "Icon\r", "two\nlines", "tab\there", "bell\u{7}", "emoji 😀🇺🇦.txt",
                                     "Copied.app", "x.localized"]
        XCTAssertEqual(Set(names(folder)), expected)
        // Every property of every item reads (the list asks for all of them).
        for i in 0..<folder.itemCount {
            for info in folder.properties {
                _ = folder.propertyOfItem(at: i, propID: info.propID)
                _ = folder.displayStringOfItem(at: i, propID: info.propID, timestampLevel: .min)
            }
            _ = folder.isPackage(at: i)
            _ = folder.linkTargetOfItem(at: i)
        }
        XCTAssertTrue(folder.isDirectory(at: try index(of: "dirlink", in: folder)), "a link to a folder navigates")
        XCTAssertFalse(folder.isDirectory(at: try index(of: "broken", in: folder)))
        // Entering an unreadable folder is an error of that folder only (Windows: the same box);
        // the parent stays listed.
        XCTAssertThrowsError(try folder.bindToFolder(at: try index(of: "noread", in: folder)))
        try folder.loadItems()
        XCTAssertEqual(folder.itemCount, expected.count)
        // Flat view walks past the unreadable folder instead of failing.
        folder.flatMode = true
        try folder.loadItems()
        XCTAssertGreaterThanOrEqual(folder.itemCount, expected.count)
    }

    // MARK: - non-BMP names

    func testNamesOutsideTheBMPSurviveTheBridge() throws {
        let names = ["a😀", "b🇺🇦", "c𝄞", "d👩‍👩‍👧", "e€"]
        for name in names { touch(name) }
        try FileManager.default.createDirectory(atPath: path("dir 🎉"), withIntermediateDirectories: true)
        touch("dir 🎉/inner 🐱.txt")
        let folder = try SZFileSystemFolder.folder(withPath: root)
        XCTAssertEqual(Set(self.names(folder)), Set(names + ["dir 🎉"]))
        XCTAssertFalse(self.names(folder).contains(""), "a name came back empty")
        let sub = try folder.bindToFolder(named: "dir 🎉")
        XCTAssertEqual(self.names(sub), ["inner 🐱.txt"])
        let i = try index(of: "a😀", in: folder)
        XCTAssertEqual(folder.fullPathOfItem(at: i), path("a😀"))
        XCTAssertEqual(folder.displayStringOfItem(at: i, propID: .name, timestampLevel: .min), "a😀")
        XCTAssertEqual(try folder.bindToPath("dir 🎉", passwordDelegate: nil).path, sub.path)
    }

    func testNamesOutsideTheBMPInsideAnArchive() throws {
        touch("cat 🐱.txt", "meow")
        try FileManager.default.createDirectory(atPath: path("dir 🎉"), withIntermediateDirectories: true)
        touch("dir 🎉/𝄞.txt", "music")
        for format in ["7z", "zip", "tar"] {
            let archive = path("arc." + format)
            let options = SZUpdateOptions.options(archivePath: archive)
            options.formatName = format
            _ = try SZUpdater.update(with: options, sourcePaths: [path("cat 🐱.txt"), path("dir 🎉")], progress: nil)
            let opened = try SZArchiveOpener.openArchive(atPath: archive, formatHint: nil, passwordDelegate: nil)
            let top = try opened.rootFolder()
            XCTAssertEqual(Set(names(top)), ["cat 🐱.txt", "dir 🎉"], format)
            let sub = try top.bindToFolder(named: "dir 🎉")
            XCTAssertEqual(names(sub), ["𝄞.txt"], format)
        }
    }
}
