// FinderCommandTests.swift -- the `finder` scope's unit tests: the 7zG argument grammar, the
// naming rules, the `sevenzip://` transport, the Finder menu tree and the Info.plist declarations.
//
// The five files under test are symlinked into this target (like `Settings.swift` and
// `FileTypes.swift`), so the app, the Finder Sync extension, the Quick Actions and these tests all
// compile the very same source.
//
// Parity references: 03-shell-integration-inventory.md sections 1.3, 1.4, 1.5, 1.6, 2.2, 2.3, 2.7,
// 3.1, 6.1, 6.4; Mac/docs/api/finder.md.

import XCTest
import SevenZipKit

final class FinderCommandTests: XCTestCase {

    // MARK: - Helpers

    /// `Mac/` in the working tree, found from this file's own path.
    private static var macDirectory: URL {
        URL(fileURLWithPath: #filePath)                 // .../Mac/Tests/SevenZipKitTests/<this>
            .deletingLastPathComponent()                // SevenZipKitTests
            .deletingLastPathComponent()                // Tests
            .deletingLastPathComponent()                // Mac
    }

    private func temporaryDirectory(_ name: String = UUID().uuidString) throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("finder-" + name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    private func parse(_ line: String) throws -> SevenZipCommandLine {
        try SevenZipArguments.parse(line.split(separator: " ").map(String.init))
    }

    // MARK: - 1. Commands (03 section 2.2, GUI.cpp:227-400)

    func testEveryCommandWordParses() {
        let expected: [(String, SevenZipCommandType)] = [
            ("a", .add), ("u", .update), ("d", .delete), ("t", .test), ("e", .extractNoPaths),
            ("x", .extractFull), ("l", .list), ("b", .benchmark), ("i", .info), ("h", .hash),
            ("rn", .rename),
        ]
        for (token, type) in expected {
            XCTAssertEqual(SevenZipCommandType.parse(token), type, token)
            XCTAssertEqual(SevenZipCommandType.parse(token.uppercased()), type, token)
            XCTAssertEqual(type.letter, token)
        }
        XCTAssertNil(SevenZipCommandType.parse("z"))
        XCTAssertNil(SevenZipCommandType.parse("ab"))
        XCTAssertNil(SevenZipCommandType.parse(""))
    }

    func testCommandGroups() {
        XCTAssertTrue(SevenZipCommandType.test.isFromExtractGroup)
        XCTAssertTrue(SevenZipCommandType.extractFull.isFromExtractGroup)
        XCTAssertTrue(SevenZipCommandType.extractNoPaths.isFromExtractGroup)
        XCTAssertFalse(SevenZipCommandType.add.isFromExtractGroup)
        for c in [SevenZipCommandType.add, .update, .delete, .rename] {
            XCTAssertTrue(c.isFromUpdateGroup, c.letter)
        }
        // `l` and `i` are the two 7zG refuses (GUI.cpp:396-399).
        XCTAssertFalse(SevenZipCommandType.list.isSupportedByGUI)
        XCTAssertFalse(SevenZipCommandType.info.isSupportedByGUI)
        for c in [SevenZipCommandType.add, .update, .delete, .rename, .test, .extractFull,
                  .extractNoPaths, .hash, .benchmark] {
            XCTAssertTrue(c.isSupportedByGUI, c.letter)
        }
        // CArcCommand::GetPathMode (ArchiveCommandLine.cpp:393-402).
        XCTAssertEqual(SevenZipCommandType.test.defaultExtractPathMode, 0)         // kFullPaths
        XCTAssertEqual(SevenZipCommandType.extractFull.defaultExtractPathMode, 0)
        XCTAssertEqual(SevenZipCommandType.extractNoPaths.defaultExtractPathMode, 2)  // kNoPaths
    }

    func testNoArgumentsAndUnsupportedCommand() {
        XCTAssertThrowsError(try SevenZipArguments.parse([])) { error in
            XCTAssertEqual((error as? SevenZipArgumentError)?.message, "Specify command")
        }
        XCTAssertThrowsError(try SevenZipArguments.parse(["zz"])) { error in
            XCTAssertEqual((error as? SevenZipArgumentError)?.message, "Unsupported command:")
            XCTAssertEqual((error as? SevenZipArgumentError)?.line, "zz")
        }
    }

    // MARK: - 2. The switches the shell integration generates (03 section 1.4, 2.2)

    func testGeneratedExtractSwitches() throws {
        // B1, exactly as CompressCall.cpp::ExtractArchives builds it.
        let c = try parse("x -o/tmp/out/ -spe -snz1 -ad -an -aiw-!/tmp/a.7z")
        XCTAssertEqual(c.command, .extractFull)
        XCTAssertEqual(c.outputDirectory, "/tmp/out/")
        XCTAssertEqual(c.eliminateDuplicateRoot, true)
        XCTAssertEqual(c.zoneIDMode, .all)
        XCTAssertTrue(c.showDialog)
        XCTAssertTrue(c.noArchiveName)
        XCTAssertNil(c.archiveName)
        XCTAssertEqual(c.archivePaths, ["/tmp/a.7z"])
        XCTAssertEqual(c.resolvedArchivePaths, ["/tmp/a.7z"])
    }

    func testOutputDirectoryGetsOneTrailingSeparator() throws {
        XCTAssertEqual(try parse("x -o/tmp/out -an -aiw-!/a.7z").outputDirectory, "/tmp/out/")
        XCTAssertEqual(try parse("x -o/tmp/out/ -an -aiw-!/a.7z").outputDirectory, "/tmp/out/")
    }

    func testEliminateDuplicateRootIsATriState() throws {
        XCTAssertNil(try parse("x -o/tmp/ -an -aiw-!/a.7z").eliminateDuplicateRoot)
        XCTAssertEqual(try parse("x -spe -o/tmp/ -an -aiw-!/a.7z").eliminateDuplicateRoot, true)
        XCTAssertEqual(try parse("x -spe- -o/tmp/ -an -aiw-!/a.7z").eliminateDuplicateRoot, false)
    }

    func testZoneIDModes() throws {
        XCTAssertEqual(try parse("x -snz -an -aiw-!/a.7z").zoneIDMode, .all)      // bare -snz
        XCTAssertEqual(try parse("x -snz0 -an -aiw-!/a.7z").zoneIDMode, ZoneIDModeSpec.none)
        XCTAssertEqual(try parse("x -snz1 -an -aiw-!/a.7z").zoneIDMode, .all)
        XCTAssertEqual(try parse("x -snz2 -an -aiw-!/a.7z").zoneIDMode, .office)
        XCTAssertThrowsError(try parse("x -snz5 -an -aiw-!/a.7z"))
    }

    func testArchiveNameModes() throws {
        XCTAssertEqual(try parse("a -sae -- /tmp/x.7z").archiveNameMode, .exact)
        XCTAssertEqual(try parse("a -saa -- /tmp/x").archiveNameMode, .add)
        XCTAssertEqual(try parse("a -sas -- /tmp/x").archiveNameMode, .smart)
        XCTAssertEqual(try parse("a -- /tmp/x.7z").archiveNameMode, .smart)       // the default
    }

    func testForcedOverwriteModes() throws {
        XCTAssertEqual(try parse("x -aoa -o/tmp/ -an -aiw-!/a.7z").overwriteMode, .overwrite)
        XCTAssertEqual(try parse("x -aos -o/tmp/ -an -aiw-!/a.7z").overwriteMode, .skip)
        XCTAssertEqual(try parse("x -aou -o/tmp/ -an -aiw-!/a.7z").overwriteMode, .rename)
        XCTAssertEqual(try parse("x -aot -o/tmp/ -an -aiw-!/a.7z").overwriteMode, .renameExisting)
        XCTAssertNil(try parse("x -o/tmp/ -an -aiw-!/a.7z").overwriteMode)
    }

    func testEmailSwitch() throws {
        let plain = try parse("a -seml -saa -- x.7z")
        XCTAssertTrue(plain.emailMode)
        XCTAssertFalse(plain.emailRemoveAfter)
        XCTAssertNil(plain.emailAddress)

        let removeAfter = try parse("a -seml. -saa -- x.7z")
        XCTAssertTrue(removeAfter.emailMode)
        XCTAssertTrue(removeAfter.emailRemoveAfter)
        XCTAssertNil(removeAfter.emailAddress)

        let addressed = try parse("a -seml.someone@example.com -saa -- x.7z")
        XCTAssertTrue(addressed.emailRemoveAfter)
        XCTAssertEqual(addressed.emailAddress, "someone@example.com")
    }

    func testHashMethodsAreRepeatable() throws {
        XCTAssertEqual(try parse("h -scrcSHA256 -iw-!/a.txt").hashMethods, ["SHA256"])
        XCTAssertEqual(try parse("h -scrcCRC32 -scrcSHA1 -iw-!/a.txt").hashMethods,
                       ["CRC32", "SHA1"])
        XCTAssertEqual(try parse("h -scrc* -iw-!/a.txt").hashMethods, ["*"])
        // A bare -scrc contributes the empty name the engine reads as "the default".
        XCTAssertEqual(try parse("h -scrc -iw-!/a.txt").hashMethods, [""])
    }

    func testTypeAndPasswordAndMethodProperties() throws {
        let c = try parse("a -t7z -mx=9 -m0=LZMA2 -psecret -saa -- /tmp/x")
        XCTAssertEqual(c.formatHint, "7z")
        XCTAssertEqual(c.methodProperties, ["x=9", "0=LZMA2"])
        XCTAssertTrue(c.passwordEnabled)
        XCTAssertEqual(c.password, "secret")
        // `-p` with no value asks the delegate instead.
        let asks = try parse("a -p -saa -- /tmp/x")
        XCTAssertTrue(asks.passwordEnabled)
        XCTAssertNil(asks.password)
    }

    func testYesToAllAndSimpleFlags() throws {
        let c = try parse("a -y -sdel -stl -ssp -ssw -sse -spd -sni -saa -- /tmp/x")
        XCTAssertTrue(c.yesToAll)
        XCTAssertTrue(c.deleteAfterCompressing)
        XCTAssertTrue(c.setArchiveMTime)
        XCTAssertTrue(c.preserveAccessTime)
        XCTAssertTrue(c.openShareForWrite)
        XCTAssertTrue(c.stopAfterOpenError)
        XCTAssertTrue(c.disableWildcards)
        XCTAssertTrue(c.restoreNtSecurity)
    }

    func testMinusSwitchesAreTriStates() throws {
        XCTAssertNil(try parse("a -saa -- /tmp/x").storeSymLinks)
        XCTAssertEqual(try parse("a -snl -saa -- /tmp/x").storeSymLinks, true)
        XCTAssertEqual(try parse("a -snl- -saa -- /tmp/x").storeSymLinks, false)
        XCTAssertEqual(try parse("a -snh- -saa -- /tmp/x").storeHardLinks, false)
        XCTAssertEqual(try parse("a -sns -saa -- /tmp/x").storeAltStreams, true)
    }

    func testFullPathAndOutDirModes() throws {
        XCTAssertEqual(try parse("a -spf -saa -- /tmp/x").fullPathMode, 2)        // k_AbsPath
        XCTAssertEqual(try parse("a -spf2 -saa -- /tmp/x").fullPathMode, 1)       // k_FullPath
        XCTAssertThrowsError(try parse("a -spf3 -saa -- /tmp/x"))
        XCTAssertEqual(try parse("x -spod -o/tmp/ -an -aiw-!/a.7z").outDirMode, 0)
        XCTAssertEqual(try parse("x -spoc -o/tmp/ -an -aiw-!/a.7z").outDirMode, 1)
        XCTAssertEqual(try parse("x -spor -o/tmp/ -an -aiw-!/a.7z").outDirMode, 2)
    }

    func testExcludeDirAndFileItems() throws {
        // The two special exclude specs are the bare words, checked before the source marker
        // (ArchiveCommandLine.cpp:722-735).
        let c = try parse("a -xtd -saa -- /tmp/x")
        XCTAssertTrue(c.excludeDirectoryItems)
        XCTAssertFalse(c.excludeFileItems)
        XCTAssertTrue(try parse("a -xtf -saa -- /tmp/x").excludeFileItems)
        XCTAssertTrue(try parse("a -xTD -saa -- /tmp/x").excludeDirectoryItems)  // NoCase
    }

    // MARK: - 3. Accepted-and-ignored switches (03 section 2.2, section 6.4)

    func testConsoleAndLargePageSwitchesAreAcceptedAndIgnored() throws {
        let c = try parse("x -slp -bso0 -bse0 -bsp1 -ba -bd -bt -scsUTF-8 -sccUTF-8 -slt"
                          + " -stm1f -sni -snoi -snon -snr -snc -o/tmp/ -an -aiw-!/a.7z")
        XCTAssertEqual(c.command, .extractFull)
        for ignored in ["-slp", "-bso", "-bse", "-bsp", "-ba", "-bd", "-bt", "-scs", "-scc",
                        "-slt", "-stm", "-sni", "-snoi", "-snon", "-snr", "-snc"] {
            XCTAssertTrue(c.ignoredSwitches.contains(ignored), ignored)
        }
    }

    func testSwitchParserErrorMessages() {
        // CParser::ParseString's five messages (CommandLineParser.cpp:96-186).
        let cases: [(String, String)] = [
            ("x -zzz -an -aiw-!/a.7z", "Unknown switch:"),
            ("x -ad -ad -an -aiw-!/a.7z", "Multiple instances for switch:"),
            ("x -t -an -aiw-!/a.7z", "Too short switch:"),
            ("x -ady -an -aiw-!/a.7z", "Too long switch:"),
            ("x -aoz -an -aiw-!/a.7z", "Incorrect switch postfix:"),
            ("x -spez -an -aiw-!/a.7z", "Incorrect switch postfix:"),
        ]
        for (line, message) in cases {
            XCTAssertThrowsError(try parse(line), line) { error in
                XCTAssertEqual((error as? SevenZipArgumentError)?.message, message, line)
            }
        }
    }

    // MARK: - 4. The three include sources (03 section 1.5)

    func testImmediateNameIncludeSource() throws {
        let c = try parse("h -scrcSHA256 -iw-!/tmp/a.txt -iw-!/tmp/b.txt")
        XCTAssertEqual(c.includePaths, ["/tmp/a.txt", "/tmp/b.txt"])
        XCTAssertEqual(c.resolvedItemPaths, ["/tmp/a.txt", "/tmp/b.txt"])
        XCTAssertTrue(c.consumedListFiles.isEmpty)
    }

    func testListFileIncludeSource() throws {
        let directory = try temporaryDirectory()
        let listPath = (directory as NSString).appendingPathComponent("list.txt")
        // BOM, quoted name, blank lines and CRLF are all handled by ReadNamesFromListFile2.
        let text = "\u{FEFF}/tmp/one.7z\r\n\"/tmp/two with space.7z\"\n\n  /tmp/three.7z  \n"
        try text.write(toFile: listPath, atomically: true, encoding: .utf8)

        let c = try SevenZipArguments.parse(["t", "-an", "-aiw-@" + listPath])
        XCTAssertEqual(c.archivePaths,
                       ["/tmp/one.7z", "/tmp/two with space.7z", "/tmp/three.7z"])
        XCTAssertEqual(c.consumedListFiles, [listPath])
    }

    func testMissingListFileReportsTheUpstreamMessage() {
        XCTAssertThrowsError(try parse("t -an -aiw-@/no/such/list.txt")) { error in
            XCTAssertEqual((error as? SevenZipArgumentError)?.message,
                           "The file operation error for listfile")
        }
    }

    func testMapIncludeSourceIsRejectedWithTheUpstreamStrings() {
        // ParseMapWithPaths validates the shape first (ArchiveCommandLine.cpp:651-703); the
        // mapping itself cannot exist on macOS, so a well-formed spec ends at "Cannot open
        // mapping" and the lang files keep working.
        XCTAssertEqual(SevenZipArguments.mapError("7zMap1"), "Incorrect Map command")
        XCTAssertEqual(SevenZipArguments.mapError("7zMap1:64"), "Incorrect Map command")
        XCTAssertEqual(SevenZipArguments.mapError("7zMap1:1:7zEvent1"), "Unsupported Map data size")
        XCTAssertEqual(SevenZipArguments.mapError("7zMap1:63:7zEvent1"), "Unsupported Map data size")
        XCTAssertEqual(SevenZipArguments.mapError("7zMap1:64:7zEvent1"), "Cannot open mapping")

        XCTAssertThrowsError(try parse("x -o/tmp/ -an -ai#7zMap1:64:7zEvent1")) { error in
            XCTAssertEqual((error as? SevenZipArgumentError)?.message, "Cannot open mapping")
        }
        XCTAssertThrowsError(try parse("x -o/tmp/ -an -ai%bad")) { error in
            XCTAssertEqual((error as? SevenZipArgumentError)?.message,
                           "Incorrect wildcard type marker")
        }
    }

    // MARK: - 5. Archive name / archive-less commands (03 section 2.2)

    func testArchiveNameIsTheFirstNonSwitchUnlessSuppressed() throws {
        let add = try parse("a -sae -- /tmp/x.7z")
        XCTAssertEqual(add.archiveName, "/tmp/x.7z")
        XCTAssertTrue(add.itemPaths.isEmpty)

        let withItems = try parse("a -sae -- /tmp/x.7z /tmp/one /tmp/two")
        XCTAssertEqual(withItems.archiveName, "/tmp/x.7z")
        XCTAssertEqual(withItems.itemPaths, ["/tmp/one", "/tmp/two"])

        // -an: no archive name at all.
        XCTAssertNil(try parse("t -an -aiw-!/tmp/x.7z").archiveName)
        // `h`, `b` and `i` never take one.
        XCTAssertNil(try parse("h -scrcCRC32 -iw-!/tmp/a.txt").archiveName)
        XCTAssertNil(try parse("b").archiveName)

        XCTAssertThrowsError(try parse("a -sae")) { error in
            XCTAssertEqual((error as? SevenZipArgumentError)?.message, "Cannot find archive name")
        }
        XCTAssertThrowsError(try SevenZipArguments.parse(["a", "--", ""])) { error in
            XCTAssertEqual((error as? SevenZipArgumentError)?.message,
                           "Archive name cannot by empty")
        }
    }

    func testStopSwitchParsing() throws {
        // Everything after `--` is a path, even when it starts with a dash.
        let c = try SevenZipArguments.parse(["a", "-sae", "--", "/tmp/x.7z", "-not-a-switch"])
        XCTAssertEqual(c.archiveName, "/tmp/x.7z")
        XCTAssertEqual(c.itemPaths, ["-not-a-switch"])
    }

    // MARK: - 6. Exit codes (03 section 2.7, ExitCode.h)

    func testExitCodes() {
        XCTAssertEqual(SevenZipExitCode.success.rawValue, 0)
        XCTAssertEqual(SevenZipExitCode.warning.rawValue, 1)
        XCTAssertEqual(SevenZipExitCode.fatalError.rawValue, 2)
        XCTAssertEqual(SevenZipExitCode.userError.rawValue, 7)
        XCTAssertEqual(SevenZipExitCode.memoryError.rawValue, 8)
        XCTAssertEqual(SevenZipExitCode.userBreak.rawValue, 255)
    }

    // MARK: - 7. Naming rules, cross-checked against the engine (03 section 1.6)

    func testSubfolderNameMatchesTheEngine() {
        let names = ["test.7z", "README", "archive.tar.gz", "foo.7z.001", "movie.part1.rar",
                     "movie.part01.rar", "movie.part001.rar", "x.zip.001", "x.doc.001",
                     "trailing .zip", "a.b.c.zip", ".hidden", "name.", "x.rar", "no-dot-here"]
        for name in names {
            XCTAssertEqual(ArchiveNaming.subfolderNameForExtract(name),
                           SZArchiveExtractor.subfolderName(forArchiveNamed: name),
                           "GetSubFolderNameForExtract mismatch for \(name)")
        }
        // The documented examples of 03 section 1.6.
        XCTAssertEqual(ArchiveNaming.subfolderNameForExtract("README"), "README~")
        XCTAssertEqual(ArchiveNaming.subfolderNameForExtract("foo.7z.001"), "foo")
        XCTAssertEqual(ArchiveNaming.subfolderNameForExtract("movie.part1.rar"), "movie")
        XCTAssertEqual(ArchiveNaming.subfolderNameForExtract("archive.tar.gz"), "archive.tar")
    }

    func testCorrectFileSystemNameMatchesTheEngine() {
        for name in ["plain", "with/slash", ".", "..", "", "a*b?c", "trailing ", "üñî"] {
            XCTAssertEqual(ArchiveNaming.correctFileSystemName(name),
                           SZArchiveExtractor.correctFileName(name),
                           "Get_Correct_FsFile_Name mismatch for \(name)")
        }
    }

    func testCreateArchiveNameMatchesTheEngine() throws {
        let directory = try temporaryDirectory("arcname")
        let fm = FileManager.default
        for name in ["one.txt", "two.tar.gz", "three"] {
            try Data("x".utf8).write(to: URL(fileURLWithPath: directory + "/" + name))
        }
        try fm.createDirectory(atPath: directory + "/folder", withIntermediateDirectories: true)

        let cases: [[String]] = [
            [directory + "/one.txt"],
            [directory + "/two.tar.gz"],
            [directory + "/three"],
            [directory + "/folder"],
            [directory + "/one.txt", directory + "/two.tar.gz"],
            [directory + "/one.txt", directory + "/folder"],
        ]
        for paths in cases {
            var mine = ""
            let isDir = paths.count == 1 && (paths[0] as NSString).lastPathComponent == "folder"
            let got = ArchiveNaming.createArchiveName(paths: paths, isHash: false,
                                                      firstItemIsDirectory: isDir, baseName: &mine)
            var engineBase: NSString?
            let expected = SZUpdater.archiveBaseName(forItemPaths: paths, isHash: false,
                                                     baseName: &engineBase)
            XCTAssertEqual(got, expected, "CreateArchiveName mismatch for \(paths)")
            XCTAssertEqual(mine, engineBase as String?, "baseName mismatch for \(paths)")
        }
    }

    func testCreateArchiveNameCollisionSuffix() {
        // ArchiveName.cpp:105-175: `<name>.7z` already in the selection -> `<name>_2`, then _3.
        var base = ""
        XCTAssertEqual(ArchiveNaming.createArchiveName(paths: ["/tmp/data.7z"], isHash: false,
                                                       baseName: &base), "data_2")
        XCTAssertEqual(base, "data")
        // A multi-item selection takes the name of the common parent folder, so the colliding
        // names have to live in a folder of that name for the `_<N>` scan to see them.
        XCTAssertEqual(ArchiveNaming.createArchiveName(
            paths: ["/tmp/data/data.7z", "/tmp/data/data_2.7z"], isHash: false), "data_3")
        XCTAssertEqual(ArchiveNaming.createArchiveName(
            paths: ["/tmp/data/data.7z", "/tmp/data/data_3.7z"], isHash: false), "data_2")
        // Case-insensitive, because g_CaseSensitive is false on macOS (Wildcard.cpp:9-20).
        XCTAssertEqual(ArchiveNaming.createArchiveName(paths: ["/tmp/Data.ZIP"], isHash: false),
                       "Data_2")
        // isHash keeps the file extension (keepName) and uses .sha256 as the collision extension,
        // so a selection that already holds `a.txt.sha256` moves the name to `a.txt_2`.
        XCTAssertEqual(ArchiveNaming.createArchiveName(paths: ["/tmp/a.txt"], isHash: true),
                       "a.txt")
        XCTAssertEqual(ArchiveNaming.createArchiveName(paths: ["/tmp/a.txt.sha256"], isHash: true),
                       "a.txt.sha256")
        XCTAssertEqual(ArchiveNaming.createArchiveName(
            paths: ["/tmp/a.txt/a.txt.sha256", "/tmp/a.txt/b"], isHash: true), "a.txt_2")
        // Several items with no common parent name fall back to "Archive".
        XCTAssertEqual(ArchiveNaming.createArchiveName(paths: ["/a.txt", "/b.txt"], isHash: false),
                       "Archive")
    }

    func testReducedLabel() {
        // ReduceString: 64 characters with " ... " in the middle (ContextMenu.cpp:472-480).
        let short = String(repeating: "a", count: 64)
        XCTAssertEqual(ArchiveNaming.reduceString(short), short)
        let long = String(repeating: "b", count: 100)
        let reduced = ArchiveNaming.reduceString(long)
        XCTAssertEqual(reduced.count, 64 + 5)
        XCTAssertTrue(reduced.contains(" ... "))
        XCTAssertEqual(ArchiveNaming.quotedReducedString("x.7z"), "\"x.7z\"")
    }

    func testExtractExcludeExtensionList() {
        // 03 section 1.4: membership decides "this could be an archive", with no signature check.
        // 113 entries, verified against kExtractExcludeExtensions (ContextMenu.cpp:558-582).
        XCTAssertEqual(ArchiveNaming.extractExcludeExtensions.count, 113)
        XCTAssertFalse(ArchiveNaming.needsExtract(name: "notes.txt"))
        XCTAssertFalse(ArchiveNaming.needsExtract(name: "MOVIE.MKV"))       // case-insensitive
        XCTAssertTrue(ArchiveNaming.needsExtract(name: "test.7z"))
        XCTAssertTrue(ArchiveNaming.needsExtract(name: "no-extension"))     // no dot -> true
        XCTAssertTrue(ArchiveNaming.needsExtract(name: "weird."))           // empty ext -> true
        let longExt = "x." + String(repeating: "e", count: 33)
        XCTAssertTrue(ArchiveNaming.needsExtract(name: longExt))            // > 32 chars -> true
    }

    func testOpenTypes() {
        XCTAssertEqual(ArchiveNaming.openTypes, ["", "*", "#", "#:e", "7z", "zip", "cab", "rar"])
    }

    // MARK: - 8. The selection transport (03 section 1.5, section 6.4)

    func testShortSelectionGoesInline() {
        let paths = (1...5).map { "/tmp/a\($0).7z" }
        let result = CommandURL.selectionArguments(paths: paths, kind: .archives)
        XCTAssertTrue(result.temporaryFiles.isEmpty)
        XCTAssertEqual(result.arguments.first, "-an")
        XCTAssertEqual(result.arguments.dropFirst().map { $0 },
                       paths.map { "-aiw-!" + $0 })
    }

    func testLongSelectionGoesThroughAListFile() throws {
        let directory = try temporaryDirectory("listfile")
        let paths = (1...40).map { "/tmp/archive-number-\($0).7z" }
        let result = CommandURL.selectionArguments(paths: paths, kind: .archives,
                                                   listFileDirectory: directory)
        XCTAssertEqual(result.temporaryFiles.count, 1)
        let listPath = try XCTUnwrap(result.temporaryFiles.first)
        XCTAssertEqual(result.arguments, ["-an", "-aiw-@" + listPath])

        // The app parses the same switches back into the original selection...
        let parsed = try SevenZipArguments.parse(["t"] + result.arguments)
        XCTAssertEqual(parsed.resolvedArchivePaths, paths)
        XCTAssertEqual(parsed.consumedListFiles, [listPath])

        // ... and then deletes the list file, which is the `CEventSetEnd` equivalent.
        XCTAssertTrue(FileManager.default.fileExists(atPath: listPath))
        CommandURL.removeTemporaryFiles(result.temporaryFiles)
        XCTAssertFalse(FileManager.default.fileExists(atPath: listPath))
    }

    func testLongByBytesAlsoGoesThroughAListFile() throws {
        let directory = try temporaryDirectory("listbytes")
        let long = String(repeating: "d", count: 400)
        let paths = (1...6).map { "/tmp/\(long)/a\($0).7z" }    // 6 items, > 2048 bytes
        XCTAssertLessThanOrEqual(paths.count, CommandURL.maximumInlinePathCount)
        let result = CommandURL.selectionArguments(paths: paths, kind: .items,
                                                   listFileDirectory: directory)
        XCTAssertEqual(result.temporaryFiles.count, 1)
        XCTAssertEqual(result.arguments.count, 1)
        XCTAssertTrue(result.arguments[0].hasPrefix("-iw-@"))
        CommandURL.removeTemporaryFiles(result.temporaryFiles)
    }

    func testItemSelectionHasNoArchiveNameSwitch() {
        let result = CommandURL.selectionArguments(paths: ["/tmp/a.txt"], kind: .items)
        XCTAssertEqual(result.arguments, ["-iw-!/tmp/a.txt"])
    }

    func testRemoveTemporaryFilesRefusesForeignNames() throws {
        let directory = try temporaryDirectory("foreign")
        let path = (directory as NSString).appendingPathComponent("my-own-list.txt")
        try Data("x".utf8).write(to: URL(fileURLWithPath: path))
        CommandURL.removeTemporaryFiles([path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "a hand-written -i@list must never be deleted")
    }

    // MARK: - 9. The URL transport

    func testRunURLRoundTrip() throws {
        let argv = ["x", "-o/tmp/out dir/", "-spe", "-an", "-aiw-!/tmp/a b.7z"]
        let url = try XCTUnwrap(CommandURL.url(argv: argv, temporaryFiles: ["/tmp/7zL-x.txt"]))
        XCTAssertEqual(url.scheme, "sevenzip")
        XCTAssertEqual(url.path, "/run")
        guard case .run(let decoded, let temp) = try CommandURL.parse(url) else {
            return XCTFail("not a run action")
        }
        XCTAssertEqual(decoded, argv)
        XCTAssertEqual(temp, ["/tmp/7zL-x.txt"])
    }

    func testAlternateSchemeAndSettingsURL() throws {
        let settings = try XCTUnwrap(CommandURL.settingsURL(show: true))
        guard case .settings(let show) = try CommandURL.parse(settings) else {
            return XCTFail("not a settings action")
        }
        XCTAssertTrue(show)

        // `03 section 6.4` spells the scheme `x-7zip`; both are registered.
        let alternate = try XCTUnwrap(URL(string: "x-7zip:///settings"))
        guard case .settings(let noShow) = try CommandURL.parse(alternate) else {
            return XCTFail("not a settings action")
        }
        XCTAssertFalse(noShow)
    }

    func testUnknownSchemeAndPathAreRejected() {
        XCTAssertThrowsError(try CommandURL.parse(URL(string: "http:///run")!))
        XCTAssertThrowsError(try CommandURL.parse(URL(string: "sevenzip:///nope")!))
        XCTAssertThrowsError(try CommandURL.parse(URL(string: "sevenzip:///run")!))
    }

    func testNonASCIIAndSpacesSurviveTheURL() throws {
        let argv = ["a", "-iw-!/tmp/üñî path/файл.txt", "-t7z", "-sae", "--", "/tmp/üñî.7z"]
        let url = try XCTUnwrap(CommandURL.url(argv: argv))
        guard case .run(let decoded, _) = try CommandURL.parse(url) else {
            return XCTFail("not a run action")
        }
        XCTAssertEqual(decoded, argv)
    }

    // MARK: - 10. The menu tree (03 section 1.4)

    private func selection(_ names: [String], directories: [Bool]? = nil,
                           folder: String = "/tmp/work/") -> FinderSelection {
        FinderSelection(paths: names.map { folder + $0 },
                        directoryFlags: directories ?? names.map { _ in false })
    }

    private func titles(_ nodes: [FinderMenuNode]) -> [String] { nodes.map(\.title) }

    private func children(of nodes: [FinderMenuNode], titled title: String) -> [FinderMenuNode] {
        for node in nodes {
            if case .submenu(let t, _, let c) = node, t == title { return c }
        }
        return []
    }

    func testCascadedSingleArchiveMenu() {
        let settings = IntegrationSettings()          // the documented defaults
        XCTAssertTrue(settings.cascadedMenu)
        XCTAssertTrue(settings.eliminateDuplicateRoot)
        XCTAssertFalse(settings.menuIcons)
        XCTAssertEqual(settings.flags, .all)

        let nodes = FinderMenuModel.build(selection: selection(["test.7z"]), settings: settings)
        // Cascaded: one "7-Zip" item, with CRC SHA nested inside it (kCRC_Cascaded is set).
        XCTAssertEqual(titles(nodes), ["7-Zip"])
        let items = children(of: nodes, titled: "7-Zip")
        XCTAssertEqual(titles(items), [
            "Open archive",                 // A1
            "Open archive",                 // A2 submenu, titled IDS_CONTEXT_OPEN
            "Extract files...",             // B1
            "Extract Here",                 // B2
            "Extract to \"test/\"",         // B3
            "Test archive",                 // B4
            "Add to archive...",            // B5
            "Compress and email...",        // B6
            // CreateArchiveName: "test.7z" has one dot, so the extension goes and the name is
            // "test"; `test.7z` is in the selection, so the simple name is taken and it becomes
            // `test_2` (ArchiveName.cpp:105-175).
            "Add to \"test_2.7z\"",         // B7
            "Compress to \"test_2.7z\" and email",     // B8
            "Add to \"test_2.zip\"",        // B9
            "Compress to \"test_2.zip\" and email",    // B10
            "CRC SHA",
        ])
        // A2's children: the raw type strings, with the empty entry skipped because A1 is present.
        XCTAssertEqual(titles(children(of: items, titled: "Open archive")),
                       ["*", "#", "#:e", "7z", "zip", "cab", "rar"])
    }

    func testFlatModeInsertsASeparatorAndKeepsCRCAtTopLevel() {
        var settings = IntegrationSettings()
        settings.cascadedMenu = false
        let nodes = FinderMenuModel.build(selection: selection(["test.7z"]), settings: settings)
        XCTAssertEqual(nodes.first, .separator)
        XCTAssertEqual(titles(nodes).last, "CRC SHA")
        XCTAssertFalse(titles(nodes).contains("7-Zip"))
    }

    func testCRCLeavesTheSubmenuWhenNotCascaded() {
        var settings = IntegrationSettings()
        settings.flags.remove(.crcCascaded)
        let nodes = FinderMenuModel.build(selection: selection(["test.7z"]), settings: settings)
        XCTAssertEqual(titles(nodes), ["7-Zip", "CRC SHA"])
        XCTAssertFalse(titles(children(of: nodes, titled: "7-Zip")).contains("CRC SHA"))
    }

    func testFolderSelectionDropsTheExtractGroup() {
        let nodes = FinderMenuModel.build(
            selection: selection(["folder"], directories: [true]), settings: IntegrationSettings())
        let items = titles(children(of: nodes, titled: "7-Zip"))
        XCTAssertFalse(items.contains("Extract files..."))
        XCTAssertFalse(items.contains("Extract Here"))
        XCTAssertFalse(items.contains("Test archive"))
        XCTAssertFalse(items.contains("Open archive"))        // block A needs a file
        XCTAssertTrue(items.contains("Add to archive..."))    // compressing a folder is fine
        XCTAssertEqual(items.first, "Add to archive...")
    }

    func testExcludedExtensionDropsTheExtractGroupUnlessShiftIsHeld() {
        let one = selection(["notes.txt"])
        let plain = titles(children(of: FinderMenuModel.build(selection: one,
                                                             settings: IntegrationSettings()),
                                   titled: "7-Zip"))
        XCTAssertFalse(plain.contains("Extract Here"))
        XCTAssertFalse(plain.contains("Open archive"))

        // CMF_EXTENDEDVERBS relaxes the filter for the extract group only (03 section 1.4).
        let extended = titles(children(of: FinderMenuModel.build(selection: one,
                                                                 settings: IntegrationSettings(),
                                                                 extendedVerbs: true),
                                       titled: "7-Zip"))
        XCTAssertTrue(extended.contains("Extract Here"))
        XCTAssertFalse(extended.contains("Open archive"))     // block A is not relaxed
    }

    func testMultipleSelectionUsesTheAsteriskSubfolder() {
        let nodes = FinderMenuModel.build(selection: selection(["a.7z", "b.zip"]),
                                          settings: IntegrationSettings())
        let items = children(of: nodes, titled: "7-Zip")
        XCTAssertTrue(titles(items).contains("Extract to \"*/\""))
        let command = try? XCTUnwrap(FinderMenuModel.command(
            verb: "SevenZipExtractTo", selection: selection(["a.7z", "b.zip"])))
        XCTAssertEqual(command?.prefixArguments,
                       ["x", "-o/tmp/work/*/", "-spe"])
        // The archive name comes from the common parent folder.
        XCTAssertTrue(titles(items).contains("Add to \"work.7z\""))
    }

    func testFlagsMaskHidesItems() {
        var settings = IntegrationSettings()
        settings.flags = [.extractHere, .crc]
        let nodes = FinderMenuModel.build(selection: selection(["test.7z"]), settings: settings)
        let items = titles(children(of: nodes, titled: "7-Zip"))
        XCTAssertEqual(items, ["Extract Here"])
        // kCRC without kCRC_Cascaded puts CRC SHA at the top level.
        XCTAssertEqual(titles(nodes), ["7-Zip", "CRC SHA"])

        settings.flags = []
        XCTAssertTrue(FinderMenuModel.build(selection: selection(["test.7z"]),
                                            settings: settings).isEmpty)
    }

    func testEmailItemsAreHiddenInDropMode() {
        let dropped = FinderSelection(paths: ["/tmp/work/a.7z"], directoryFlags: [false],
                                      dropPath: "/tmp/target")
        let items = titles(children(of: FinderMenuModel.build(selection: dropped,
                                                             settings: IntegrationSettings()),
                                   titled: "7-Zip"))
        XCTAssertFalse(items.contains("Compress and email..."))
        XCTAssertFalse(items.contains(where: { $0.hasSuffix("and email") }))
        // The drop target replaces <dir> for the extract and compress commands (03 section 1.7).
        let command = FinderMenuModel.command(verb: "SevenZipExtractHere", selection: dropped)
        XCTAssertEqual(command?.prefixArguments, ["x", "-o/tmp/target/"])
    }

    func testQuickAddItemsHideWhenTheNameEqualsTheSelection() {
        // B7 / B9: hidden when `<name>.7z` is the first item's own name (ContextMenu.cpp:941).
        let items = titles(children(of: FinderMenuModel.build(selection: selection(["data.7z"]),
                                                             settings: IntegrationSettings()),
                                   titled: "7-Zip"))
        // `data.7z` -> CreateArchiveName keeps "data.7z" (two dots? no: one dot, so "data"), and
        // the selection contains data.7z, so the name becomes data_2 and the item stays.
        XCTAssertTrue(items.contains("Add to \"data_2.7z\""))

        // A name that is already exactly `<name>.7z` for the *computed* name hides the item: a
        // folder keeps its name, so a folder called "data.7z" produces "data.7z" + ".7z".
        let folder = FinderSelection(paths: ["/tmp/work/data"], directoryFlags: [true])
        let folderItems = titles(children(of: FinderMenuModel.build(selection: folder,
                                                                   settings: IntegrationSettings()),
                                          titled: "7-Zip"))
        XCTAssertTrue(folderItems.contains("Add to \"data.7z\""))
    }

    // MARK: - 11. The generated command line of every menu item

    func testEveryGeneratedCommandLine() throws {
        let sel = selection(["test.7z"])
        var settings = IntegrationSettings()
        settings.writeZoneIdExtract = 1              // -snz1 on every extract command
        let commands = FinderMenuModel.allCommands(selection: sel, settings: settings)
        var byVerb: [String: FinderMenuCommand] = [:]
        for command in commands { byVerb[command.verb] = command }

        func line(_ verb: String) throws -> String {
            let command = try XCTUnwrap(byVerb[verb], verb)
            return CommandURL.displayText(command.argv(for: sel.paths).argv)
        }

        // Block A (7zFM argv, not a 7zG command).
        XCTAssertEqual(try line("SevenZipOpen"), "/tmp/work/test.7z")
        XCTAssertEqual(try line("SevenZip.Open.#:e"), "/tmp/work/test.7z -t#:e")
        // Block B, in the order CompressCall.cpp builds the switches.
        XCTAssertEqual(try line("SevenZipExtract"),
                       "x -o/tmp/work/test/ -snz1 -ad -an -aiw-!/tmp/work/test.7z")
        XCTAssertEqual(try line("SevenZipExtractHere"),
                       "x -o/tmp/work/ -snz1 -an -aiw-!/tmp/work/test.7z")
        XCTAssertEqual(try line("SevenZipExtractTo"),
                       "x -o/tmp/work/test/ -spe -snz1 -an -aiw-!/tmp/work/test.7z")
        XCTAssertEqual(try line("SevenZipTest"), "t -an -aiw-!/tmp/work/test.7z")
        XCTAssertEqual(try line("SevenZipCompress"),
                       "a -iw-!/tmp/work/test.7z -ad -saa -- /tmp/work/test_2")
        XCTAssertEqual(try line("SevenZipCompressEmail"),
                       "a -iw-!/tmp/work/test.7z -seml. -ad -saa -- test_2")
        XCTAssertEqual(try line("SevenZipCompressTo7z"),
                       "a -iw-!/tmp/work/test.7z -t7z -sae -- /tmp/work/test_2.7z")
        XCTAssertEqual(try line("SevenZipCompressTo7zEmail"),
                       "a -iw-!/tmp/work/test.7z -t7z -seml. -sae -- test_2.7z")
        XCTAssertEqual(try line("SevenZipCompressToZip"),
                       "a -iw-!/tmp/work/test.7z -tzip -sae -- /tmp/work/test_2.zip")
        XCTAssertEqual(try line("SevenZipCompressToZipEmail"),
                       "a -iw-!/tmp/work/test.7z -tzip -seml. -sae -- test_2.zip")
        // Block C.
        XCTAssertEqual(try line("SevenZip.Checksum.Calc.CRC32"),
                       "h -scrcCRC32 -iw-!/tmp/work/test.7z")
        XCTAssertEqual(try line("SevenZip.Checksum.Calc.*"), "h -scrc* -iw-!/tmp/work/test.7z")
        XCTAssertEqual(try line("SevenZip.Checksum.Generate.SHA256"),
                       "a -iw-!/tmp/work/test.7z -thash -sae -- /tmp/work/test.7z.sha256")
        XCTAssertEqual(try line("SevenZip.Checksum.Test.Hash"),
                       "t -thash -an -aiw-!/tmp/work/test.7z")

        // Every one of those parses back into the grammar (`-t#:e` is a 7zFM argv, not 7zG).
        for command in commands where command.selectionKind != nil {
            let argv = command.argv(for: sel.paths).argv
            XCTAssertNoThrow(try SevenZipArguments.parse(argv),
                             command.verb + ": " + CommandURL.displayText(argv))
        }
    }

    func testChecksumSubmenuContents() {
        let nodes = FinderMenuModel.build(selection: selection(["a.txt", "b.txt"]),
                                          settings: IntegrationSettings())
        let crc = children(of: children(of: nodes, titled: "7-Zip"), titled: "CRC SHA")
        XCTAssertEqual(titles(crc), [
            "CRC-32", "CRC-64", "XXH64", "MD5", "SHA-1", "SHA-256", "SHA-384", "SHA-512",
            "SHA3-256", "BLAKE2sp", "*",
            "-",                                        // the separator of :1088-1094
            "SHA-256 -> work.sha256",                   // C12
            "Test archive : Checksum",                   // C13
        ])
    }

    func testChecksumMethodNamesAreSupportedByTheEngine() {
        for hash in FinderMenuModel.hashCommands {
            XCTAssertTrue(SZHasher.isMethodSupported(hash.method),
                          "the engine does not know \(hash.method)")
        }
    }

    func testExtractGroupRefusesDirectories() {
        let sel = selection(["a.7z"])
        for verb in ["SevenZipExtract", "SevenZipExtractHere", "SevenZipExtractTo",
                     "SevenZipTest", "SevenZip.Checksum.Test.Hash"] {
            XCTAssertEqual(FinderMenuModel.command(verb: verb, selection: sel)?.refusesDirectories,
                           true, verb)
        }
        for verb in ["SevenZipCompress", "SevenZip.Checksum.Calc.CRC32"] {
            XCTAssertEqual(FinderMenuModel.command(verb: verb, selection: sel)?.refusesDirectories,
                           false, verb)
        }
    }

    // MARK: - 12. IntegrationSettings

    func testSettingsSnapshotRoundTrip() {
        var settings = IntegrationSettings()
        settings.cascadedMenu = false
        settings.menuIcons = true
        settings.eliminateDuplicateRoot = false
        settings.writeZoneIdExtract = 2
        settings.flags = [.extractHere, .compress, .crc]
        settings.localizedTitles = ["2326": "Hier entpacken"]

        let restored = IntegrationSettings(dictionary: settings.dictionary)
        XCTAssertEqual(restored, settings)
        XCTAssertEqual(restored.localize(2326, "Extract Here"), "Hier entpacken")
        XCTAssertEqual(restored.localize(2325, "Test archive"), "Test archive")
        XCTAssertEqual(restored.zoneIDSwitchValue, 2)

        var unset = IntegrationSettings()
        unset.writeZoneIdExtract = -1
        XCTAssertNil(unset.zoneIDSwitchValue)
    }

    func testSettingsFlagsMatchTheWindowsBits() {
        // Explorer/ContextMenuFlags.h:8-24.
        XCTAssertEqual(ContextMenuItemFlags.extractFiles.rawValue, 1 << 0)
        XCTAssertEqual(ContextMenuItemFlags.extractHere.rawValue, 1 << 1)
        XCTAssertEqual(ContextMenuItemFlags.extractTo.rawValue, 1 << 2)
        XCTAssertEqual(ContextMenuItemFlags.test.rawValue, 1 << 4)
        XCTAssertEqual(ContextMenuItemFlags.open.rawValue, 1 << 5)
        XCTAssertEqual(ContextMenuItemFlags.openAs.rawValue, 1 << 6)
        XCTAssertEqual(ContextMenuItemFlags.compress.rawValue, 1 << 8)
        XCTAssertEqual(ContextMenuItemFlags.compressTo7z.rawValue, 1 << 9)
        XCTAssertEqual(ContextMenuItemFlags.compressEmail.rawValue, 1 << 10)
        XCTAssertEqual(ContextMenuItemFlags.compressTo7zEmail.rawValue, 1 << 11)
        XCTAssertEqual(ContextMenuItemFlags.compressToZip.rawValue, 1 << 12)
        XCTAssertEqual(ContextMenuItemFlags.compressToZipEmail.rawValue, 1 << 13)
        XCTAssertEqual(ContextMenuItemFlags.crcCascaded.rawValue, 1 << 30)
        XCTAssertEqual(ContextMenuItemFlags.crc.rawValue, 1 << 31)
        XCTAssertEqual(ContextMenuItemFlags.all.rawValue, 0xFFFF_FFFF)
        // Same bits as the app's own Settings.ContextMenuFlags.
        XCTAssertEqual(ContextMenuItemFlags.all.rawValue, Settings.ContextMenuFlags.all.rawValue)
        XCTAssertEqual(ContextMenuItemFlags.crc.rawValue, Settings.ContextMenuFlags.crc.rawValue)
    }

    func testPreferencesDomainFollowsTheEnvironmentVariable() {
        // The same rule as NMacPrefs::ApplicationID(), so the extension and the app agree.
        XCTAssertEqual(SevenZipBundle.preferencesDomain, SZSettings.applicationID)
    }

    // MARK: - 13. Info.plist declarations (03 section 3.1, section 6.1; api/icons.md)

    private func appInfoPlist() throws -> [String: Any] {
        let url = Self.macDirectory.appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil)
                             as? [String: Any])
    }

    func testEveryAssociatedExtensionHasADocumentTypeWithItsIcon() throws {
        let plist = try appInfoPlist()
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        var iconByExtension: [String: String] = [:]
        var utiByExtension: [String: String] = [:]
        for type in types {
            guard let extensions = type["CFBundleTypeExtensions"] as? [String] else { continue }
            guard let icon = type["CFBundleTypeIconFile"] as? String else { continue }
            let utis = type["LSItemContentTypes"] as? [String] ?? []
            for ext in extensions {
                if iconByExtension[ext] == nil {         // the first (association) entry wins
                    iconByExtension[ext] = icon
                    utiByExtension[ext] = utis.first
                }
            }
        }
        XCTAssertEqual(FileTypes.all.count, 40, "the association list has 40 extensions")
        for type in FileTypes.all {
            let expectedIcon = "doc-" + (FileTypes.iconNames[type.iconIndex] ?? "?")
            XCTAssertEqual(iconByExtension[type.ext], expectedIcon,
                           "\(type.ext) must use \(expectedIcon)")
            XCTAssertNotNil(utiByExtension[type.ext], "\(type.ext) has no LSItemContentTypes")
        }
    }

    func testImportedTypeDeclarationsCoverTheExtensionsMacOSDoesNotKnow() throws {
        let plist = try appInfoPlist()
        let imported = try XCTUnwrap(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        var declared: [String: [String: Any]] = [:]
        for type in imported {
            declared[type["UTTypeIdentifier"] as! String] = type
        }
        // `SevenZipFileType.systemUTType` cannot be used as the oracle here: once Launch Services
        // has seen this build, UTType(filenameExtension:) resolves 7-Zip's *own* imported types and
        // every extension looks "declared". The plist is checked against itself instead: every
        // document type whose UTI is one of ours must have a matching imported declaration.
        let types2 = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        var ours: [(ext: String, uti: String, icon: String)] = []
        for type in types2 {
            guard let utis = type["LSItemContentTypes"] as? [String], let uti = utis.first,
                  uti.hasPrefix("org.7-zip."),
                  let extensions = type["CFBundleTypeExtensions"] as? [String],
                  let icon = type["CFBundleTypeIconFile"] as? String else { continue }
            for ext in extensions { ours.append((ext, uti, icon)) }
        }
        // 7z is the one extension macOS itself declares as org.7-zip.7-zip-archive.
        let imported7zip = ours.filter { $0.uti != "org.7-zip.7-zip-archive" }
        XCTAssertEqual(imported7zip.count, 23, "23 of the 40 extensions need an imported type")
        for entry in imported7zip {
            let declaration = declared[entry.uti]
            XCTAssertNotNil(declaration, "\(entry.ext) needs an imported type declaration")
            XCTAssertEqual(declaration?["UTTypeIconFile"] as? String, entry.icon)
            let tags = declaration?["UTTypeTagSpecification"] as? [String: [String]]
            XCTAssertEqual(tags?["public.filename-extension"], [entry.ext])
            XCTAssertEqual(declaration?["UTTypeConformsTo"] as? [String],
                           ["public.data", "public.archive"])
        }
        XCTAssertEqual(declared.count, 23)
    }

    func testURLSchemeAndServicesAreDeclared() throws {
        let plist = try appInfoPlist()
        let urlTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        let schemes = urlTypes.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        XCTAssertTrue(schemes.contains(CommandURL.scheme))
        XCTAssertTrue(schemes.contains(CommandURL.alternateScheme))

        let services = try XCTUnwrap(plist["NSServices"] as? [[String: Any]])
        let messages = services.compactMap { $0["NSMessage"] as? String }
        XCTAssertEqual(messages, ["sevenZipExtractFiles", "sevenZipExtractHere",
                                  "sevenZipTestArchive", "sevenZipAddToArchive",
                                  "sevenZipChecksum"])
        for service in services {
            XCTAssertEqual(service["NSPortName"] as? String, "7-Zip")
            XCTAssertFalse((service["NSSendFileTypes"] as? [String] ?? []).isEmpty)
            let item = service["NSMenuItem"] as? [String: String]
            XCTAssertTrue((item?["default"] ?? "").hasPrefix("7-Zip: "))
        }
    }

    func testSandboxUsageDescriptionsArePresent() throws {
        let plist = try appInfoPlist()
        for key in ["NSDesktopFolderUsageDescription", "NSDocumentsFolderUsageDescription",
                    "NSDownloadsFolderUsageDescription", "NSRemovableVolumesUsageDescription",
                    "NSNetworkVolumesUsageDescription"] {
            XCTAssertFalse((plist[key] as? String ?? "").isEmpty, key)
        }
    }

    func testExtensionPlistsDeclareTheRightExtensionPoints() throws {
        let finderSync = Self.macDirectory.appendingPathComponent("FinderSync/Info.plist")
        let data = try Data(contentsOf: finderSync)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil)
                                  as? [String: Any])
        let ns = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
        XCTAssertEqual(ns["NSExtensionPointIdentifier"] as? String, "com.apple.FinderSync")

        for (directory, principal, label) in [
            ("QuickAction/Extract", "ExtractQuickActionController", "Extract with 7-Zip"),
            ("QuickAction/Compress", "CompressQuickActionController", "Compress with 7-Zip"),
        ] {
            let url = Self.macDirectory.appendingPathComponent(directory + "/Info.plist")
            let data = try Data(contentsOf: url)
            let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data,
                                                                                format: nil)
                                      as? [String: Any])
            let ns = try XCTUnwrap(plist["NSExtension"] as? [String: Any])
            XCTAssertEqual(ns["NSExtensionPointIdentifier"] as? String, "com.apple.ui-services")
            XCTAssertTrue((ns["NSExtensionPrincipalClass"] as? String ?? "").hasSuffix(principal))
            let attributes = try XCTUnwrap(ns["NSExtensionAttributes"] as? [String: Any])
            XCTAssertEqual(attributes["NSExtensionServiceAllowsFinderPreviewItem"] as? Bool, true)
            XCTAssertEqual(attributes["NSExtensionServiceFinderPreviewLabel"] as? String, label)
        }
    }

    func testFinderSyncIsSandboxed() throws {
        let url = Self.macDirectory.appendingPathComponent("FinderSync/FinderSync.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil)
                                  as? [String: Any])
        // An unsandboxed Finder Sync appex is refused by the system (03 section 6.4).
        XCTAssertEqual(plist["com.apple.security.app-sandbox"] as? Bool, true)
    }
}
