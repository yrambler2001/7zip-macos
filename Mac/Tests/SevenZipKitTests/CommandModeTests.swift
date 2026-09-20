// CommandModeTests.swift -- the `cmdmode` scope: 7zG command mode's exit-code ladder, the `rn`
// command, include/exclude wildcard expansion through the engine's own directory walk, `-scrc` on
// `x`/`t`, `-sfx<module>`, and the Dock-drop routing.
//
// Parity references: 03-shell-integration-inventory.md sections 2.2 (the switch set), 2.6 (`-scrc`),
// 2.7 (errors and exit codes), 1.7 + 6.2 (the drop handler / the Dock icon);
// 01b-fm-dialogs-settings.md section 4.23 (the SFX module rule).
//
// Archives and checksums produced here are cross-checked against the console 7zz built from this
// tree (CPP/7zip/Bundles/Alone2/b/m_arm64/7zz), which is the reference implementation.

import XCTest
import SevenZipKit

final class CommandModeTests: UpdaterTestCase {

    private func parse(_ line: String) throws -> SevenZipCommandLine {
        try SevenZipArguments.parse(line.split(separator: " ").map(String.init))
    }

    // MARK: - 03 section 2.7: exit codes and the exception ladder

    /// `NExitCode::EEnum` (Common/ExitCode.h:10-21). Exit code 8 was previously unreachable.
    func testExitCodeValues() {
        XCTAssertEqual(SevenZipExitCode.success.rawValue, 0)
        XCTAssertEqual(SevenZipExitCode.warning.rawValue, 1)
        XCTAssertEqual(SevenZipExitCode.fatalError.rawValue, 2)
        XCTAssertEqual(SevenZipExitCode.userError.rawValue, 7)
        XCTAssertEqual(SevenZipExitCode.memoryError.rawValue, 8)
        XCTAssertEqual(SevenZipExitCode.userBreak.rawValue, 255)
    }

    /// The Foundation-only ladder must keep agreeing with the bridge constants it mirrors, exactly
    /// as `ContextMenuItemFlags` mirrors `Settings.ContextMenuFlags`.
    func testFailureLadderConstantsMatchTheBridge() {
        XCTAssertEqual(SevenZipFailureLadder.errorDomain, SZErrorDomain)
        XCTAssertEqual(SevenZipFailureLadder.hresultUserInfoKey, SZErrorHRESULTKey)
        XCTAssertEqual(SevenZipFailureLadder.pathExceptionUserInfoKey, SZPathExceptionUserInfoKey)
        XCTAssertEqual(SevenZipFailureLadder.cancelledErrorCode, SZError.Code.cancelled.rawValue)
        XCTAssertEqual(SevenZipFailureLadder.outOfMemoryErrorCode, SZError.Code.outOfMemory.rawValue)
        // E_ABORT / E_OUTOFMEMORY as the bridge really reports them.
        let aborted = SZErrors.error(withHRESULT: SevenZipFailureLadder.abortHRESULT,
                                     message: nil) as NSError
        XCTAssertEqual(aborted.code, SZError.Code.cancelled.rawValue)
        let oom = SZErrors.error(withHRESULT: SevenZipFailureLadder.outOfMemoryHRESULT,
                                 message: nil) as NSError
        XCTAssertEqual(oom.code, SZError.Code.outOfMemory.rawValue)
    }

    /// Every arm of `WinMain`'s catch chain (GUI.cpp:437-494), code and message.
    func testExitCodeLadder() {
        let memory = "MEM"

        // CNewException / CSystemException(E_OUTOFMEMORY) -> IDS_MEM_ERROR + 8.
        let oomByCode = SZErrors.error(with: .outOfMemory, message: "whatever the engine said")
        var classified = SevenZipFailureLadder.classify(oomByCode, memoryMessage: memory)
        XCTAssertEqual(classified, SevenZipFailure(exitCode: .memoryError, message: memory))

        let oomByHRESULT = SZErrors.error(withHRESULT: 0x8007_000E, message: nil)
        classified = SevenZipFailureLadder.classify(oomByHRESULT, memoryMessage: memory)
        XCTAssertEqual(classified, SevenZipFailure(exitCode: .memoryError, message: memory))

        // std::bad_alloc is CNewException on this platform, and reaches Swift as E_OUTOFMEMORY.
        classified = SevenZipFailureLadder.classify(
            NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM)), memoryMessage: memory)
        XCTAssertEqual(classified.exitCode, SevenZipExitCode.memoryError)

        // CMessagePathException -> the two-line box + 7.
        classified = SevenZipFailureLadder.classify(
            SevenZipArgumentError("Cannot find archive name", "x.7z"), memoryMessage: memory)
        XCTAssertEqual(classified.exitCode, SevenZipExitCode.userError)
        XCTAssertEqual(classified.message, "Cannot find archive name\nx.7z")

        // CSystemException(E_ABORT) -> 255, and no box at all.
        classified = SevenZipFailureLadder.classify(SZErrors.error(with: .cancelled, message: "x"),
                                                    memoryMessage: memory)
        XCTAssertEqual(classified, SevenZipFailure(exitCode: .userBreak, message: nil))
        classified = SevenZipFailureLadder.classify(SZErrors.error(withHRESULT: 0x8000_4004, message: nil),
                                                   memoryMessage: memory)
        XCTAssertEqual(classified, SevenZipFailure(exitCode: .userBreak, message: nil))

        // CSystemException(other) -> HResultToMessage + 2.
        let engine = SZErrors.error(withHRESULT: 0x8000_4005, message: nil)   // E_FAIL
        classified = SevenZipFailureLadder.classify(engine, memoryMessage: memory)
        XCTAssertEqual(classified.exitCode, SevenZipExitCode.fatalError)
        XCTAssertEqual(classified.message, engine.localizedDescription)
        XCTAssertFalse(engine.localizedDescription.isEmpty, "MyFormatMessage must produce a text")

        // A string exception -> box with the text + 2.
        classified = SevenZipFailureLadder.classify(
            SZErrors.error(with: .engine, message: "cannot open SFX module"),
            memoryMessage: memory)
        XCTAssertEqual(classified, SevenZipFailure(exitCode: .fatalError,
                                                  message: "cannot open SFX module"))

        // catch (int n) -> "Error: N" + 2. The bridge spells it "Internal Error #N".
        classified = SevenZipFailureLadder.classify(
            SZErrors.error(with: .engine, message: "Internal Error #17"), memoryMessage: memory)
        XCTAssertEqual(classified, SevenZipFailure(exitCode: .fatalError, message: "Error: 17"))

        // catch (...) -> "Unknown error" + 2.
        classified = SevenZipFailureLadder.classify(
            SZErrors.error(with: .engine, message: ""), memoryMessage: memory)
        XCTAssertEqual(classified, SevenZipFailure(exitCode: .fatalError, message: "Unknown error"))

        // CMessagePathException from the bridge -> exit 7, like a syntax error (:452-456).
        let pathError = NSError(domain: SZErrorDomain, code: SZError.Code.invalidArgument.rawValue,
                                userInfo: [NSLocalizedDescriptionKey: "Cannot find archive",
                                           SevenZipFailureLadder.pathExceptionUserInfoKey: true])
        classified = SevenZipFailureLadder.classify(pathError, memoryMessage: memory)
        XCTAssertEqual(classified, SevenZipFailure(exitCode: .userError,
                                                  message: "Cannot find archive"))

        // A plain Swift error is still the fatal arm, never a crash.
        struct Odd: Error {}
        XCTAssertEqual(SevenZipFailureLadder.exitCode(for: Odd()), SevenZipExitCode.fatalError)
    }

    /// The default memory message is the built-in English of IDS_MEM_ERROR 3000, and the lang table
    /// really carries that id, so the app's `Lang.text(3000, ...)` resolves rather than falls back.
    func testMemoryErrorMessageComesFromLangID3000() {
        XCTAssertEqual(SevenZipFailureLadder.englishMemoryErrorMessage,
                       "The system cannot allocate the required amount of memory")
        XCTAssertEqual(SZLang.shared.englishString(forID: 3000),
                       SevenZipFailureLadder.englishMemoryErrorMessage)
        XCTAssertEqual(SevenZipFailureLadder.classify(SZErrors.error(with: .outOfMemory,
                                                                    message: "")).message,
                       SevenZipFailureLadder.englishMemoryErrorMessage)
    }

    // MARK: - 03 section 2.2: `rn`

    func testRenameCommandParsesPairs() throws {
        let command = try parse("rn /tmp/a.7z old1.txt new1.txt old2.txt new2.txt")
        XCTAssertEqual(command.command, .rename)
        XCTAssertEqual(command.archiveName, "/tmp/a.7z")
        XCTAssertEqual(command.renamePairs, [
            SevenZipRenamePair(oldName: "old1.txt", newName: "new1.txt"),
            SevenZipRenamePair(oldName: "old2.txt", newName: "new2.txt"),
        ])
        // The positional strings are pairs, so nothing lands in the item censor.
        XCTAssertEqual(command.itemPaths, [])
    }

    /// `AddToCensorFromNonSwitchesStrings` (:624): an odd number of names is a user error.
    func testRenameCommandRefusesAnOddNumberOfNames() {
        XCTAssertThrowsError(try parse("rn /tmp/a.7z only-one.txt")) { error in
            let e = error as? SevenZipArgumentError
            XCTAssertEqual(e?.message, "There is no second file name for rename pair:")
            XCTAssertEqual(e?.line, "only-one.txt")
        }
    }

    /// `CRenamePair::Prepare` (Update.cpp:288-295) / `AddRenamePair` (:500-522).
    func testRenameCommandRefusesAWildcardInTheOldName() {
        XCTAssertThrowsError(try parse("rn /tmp/a.7z *.txt new.txt")) { error in
            XCTAssertEqual((error as? SevenZipArgumentError)?.message, "Unsupported rename command:")
        }
        // `-spd` turns wildcard parsing off, and then the name is taken literally and accepted.
        XCTAssertNoThrow(try parse("rn /tmp/a.7z -spd *.txt new.txt"))
        XCTAssertEqual(try parse("rn /tmp/a.7z -spd *.txt new.txt").renamePairs.first?.wildcardParsing,
                       false)
    }

    func testRenameCommandReadsPairsFromAListFile() throws {
        let dir = try tempDir("rn-list")
        let list = (dir as NSString).appendingPathComponent("pairs.txt")
        try "readme.txt\r\nREADME.md\nnotes.md\nNOTES.md\n".write(toFile: list, atomically: true,
                                                                 encoding: .utf8)
        let command = try parse("rn /tmp/a.7z @\(list)")
        XCTAssertEqual(command.renamePairs, [
            SevenZipRenamePair(oldName: "readme.txt", newName: "README.md"),
            SevenZipRenamePair(oldName: "notes.md", newName: "NOTES.md"),
        ])
        XCTAssertEqual(command.consumedListFiles, [list])

        // An odd count in the list file is `kIncorrectListFile`.
        let odd = (dir as NSString).appendingPathComponent("odd.txt")
        try "a\nb\nc\n".write(toFile: odd, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try parse("rn /tmp/a.7z @\(odd)"))
    }

    /// The real thing: rename two members of a 7z archive and read the result back, cross-checked
    /// against `7zz l`.
    func testRenameRewritesTheArchive() throws {
        let dir = try tempDir("rn-run")
        try makeSourceTree(in: dir)
        let archive = (dir as NSString).appendingPathComponent("arc.7z")
        let options = SZUpdateOptions.options(archivePath: archive)
        try update(options, [(dir as NSString).appendingPathComponent("readme.txt"),
                            (dir as NSString).appendingPathComponent("notes.md")])
        XCTAssertEqual(try archiveEntryNames(archive), ["notes.md", "readme.txt"])

        let pairs = [SZRenamePair.pair(oldName: "readme.txt", newName: "README.1st",
                                      wildcardParsing: true)]
        let outcome: Result<SZUpdateResult, Error> = offMain {
            do {
                return .success(try SZUpdater.renameItems(pairs: pairs, inArchiveAt: archive,
                                                          itemSpecs: [], options: nil,
                                                          progress: nil))
            } catch { return .failure(error) }
        }
        _ = try outcome.get()
        XCTAssertEqual(try archiveEntryNames(archive), ["README.1st", "notes.md"])

        if let console = runConsole(["l", "-slt", archive]) {
            XCTAssertEqual(console.status, 0, console.output)
            let paths = values("Path", in: console.output)
            XCTAssertTrue(paths.contains("README.1st"),
                          "7zz must list the renamed member\n\(console.output)")
            XCTAssertFalse(paths.contains("readme.txt"), console.output)
            XCTAssertTrue(paths.contains("notes.md"), console.output)
        }
    }

    /// An unsupported pair is refused by the bridge too, not only by the parser.
    func testRenameBridgeRefusesAnUnsupportedPair() throws {
        let dir = try tempDir("rn-bad")
        try makeSourceTree(in: dir)
        let archive = (dir as NSString).appendingPathComponent("arc.7z")
        try update(SZUpdateOptions.options(archivePath: archive),
                   [(dir as NSString).appendingPathComponent("readme.txt")])

        let bad = SZRenamePair.pair(oldName: "*.txt", newName: "x.txt", wildcardParsing: true)
        XCTAssertFalse(bad.isSupported)
        XCTAssertEqual(bad.unsupportedDetail, "*.txt\nx.txt\n")
        let outcome: Result<SZUpdateResult, Error> = offMain {
            do {
                return .success(try SZUpdater.renameItems(pairs: [bad], inArchiveAt: archive,
                                                          itemSpecs: [], options: nil, progress: nil))
            } catch { return .failure(error) }
        }
        XCTAssertThrowsError(try outcome.get()) { error in
            XCTAssertTrue((error as NSError).localizedDescription
                .hasPrefix("Unsupported rename command:"), "\(error)")
            XCTAssertEqual(SevenZipFailureLadder.exitCode(for: error), SevenZipExitCode.fatalError)
        }
        // An empty pair list is the parser's "no second file name" case, i.e. a user error.
        let empty: Result<SZUpdateResult, Error> = offMain {
            do {
                return .success(try SZUpdater.renameItems(pairs: [], inArchiveAt: archive,
                                                          itemSpecs: [], options: nil, progress: nil))
            } catch { return .failure(error) }
        }
        XCTAssertThrowsError(try empty.get())
    }

    // MARK: - 03 section 2.2: `-i` / `-x` wildcards

    func testIncludeSwitchModifiersAreRecorded() throws {
        var command = try parse("a /tmp/a.7z -i!*.txt")
        XCTAssertEqual(command.includeSpecs, [SevenZipPathSpec(path: "*.txt", include: true,
                                                              recursedType: .nonRecursed,
                                                              wildcardMatching: true,
                                                              markMode: .fileOrDir)])
        command = try parse("a /tmp/a.7z -ir!*.c -xr0!*.o -i!plain")
        XCTAssertEqual(command.includeSpecs.map(\.path), ["*.c", "plain"])
        XCTAssertEqual(command.includeSpecs.map(\.recursedType), [.recursed, .nonRecursed])
        XCTAssertEqual(command.excludeSpecs.map(\.recursedType), [.wildcardOnlyRecursed])
        XCTAssertEqual(command.excludeSpecs.map(\.include), [false])

        // The Finder transport: `w-` means "no wildcard matching", which is what lets a real file
        // name containing `*` survive (api/finder.md section 5).
        command = try parse("x -an -aiw-!/tmp/star*.7z")
        XCTAssertEqual(command.archiveIncludeSpecs.map(\.wildcardMatching), [false])
        XCTAssertFalse(SevenZipCommandLine.needsCensorWalk(command.archiveSpecs),
                       "a literal selection must not trigger a directory walk")

        // `-spd` turns matching off globally; the `m` modifier sets the mark mode.
        command = try parse("a /tmp/a.7z -spd -i!*.txt")
        XCTAssertEqual(command.includeSpecs.map(\.wildcardMatching), [false])
        command = try parse("a /tmp/a.7z -im2!*.txt -xm-!skip")
        XCTAssertEqual(command.includeSpecs.map(\.markMode), [.strictFileIfWildcard])
        XCTAssertEqual(command.excludeSpecs.map(\.markMode), [.fileOrDir])

        // `-r` is the default for positional paths and for `-i!` without its own modifier.
        command = try parse("a /tmp/a.7z -r -i!*.txt sub")
        XCTAssertEqual(command.defaultRecursedType, .recursed)
        XCTAssertEqual(command.itemSpecs.map(\.recursedType), [.recursed, .recursed])
        XCTAssertEqual(command.itemSpecs.map(\.path), ["*.txt", "sub"])
    }

    /// The point of the whole exercise: the **engine** expands the pattern, against a real tree.
    func testExpandPathSpecsWalksTheRealTreeLikeTheEngine() throws {
        let dir = try tempDir("expand")
        try makeSourceTree(in: dir)          // readme.txt notes.md sub/big.txt sub/deep/inner.txt
        let fm = FileManager.default
        try "log\n".write(toFile: (dir as NSString).appendingPathComponent("noise.log"),
                          atomically: true, encoding: .utf8)
        XCTAssertTrue(fm.fileExists(atPath: (dir as NSString).appendingPathComponent("noise.log")))

        func expand(_ specs: [SZPathSpec]) throws -> [String] {
            let out: Result<[String], Error> = offMain {
                do { return .success(try SZUpdater.expandPathSpecs(specs, sortedArchiveList: true)) }
                catch { return .failure(error) }
            }
            return try out.get().map { ($0 as NSString).lastPathComponent }
        }
        func spec(_ path: String, include: Bool = true,
                  recursed: SZRecursedType = .nonRecursed,
                  wildcard: Bool = true) -> SZPathSpec {
            SZPathSpec.spec(path: path, include: include, recursedType: recursed,
                            wildcardMatching: wildcard, markMode: .fileOrDir)
        }
        let star = (dir as NSString).appendingPathComponent("*.txt")

        // Non-recursed: only the top level.
        XCTAssertEqual(try expand([spec(star)]), ["readme.txt"])

        // -r: the whole tree.
        XCTAssertEqual(try expand([spec(star, recursed: .recursed)]).sorted(),
                       ["big.txt", "inner.txt", "readme.txt"])

        // -r0 recurses only because the name has a wildcard.
        XCTAssertEqual(try expand([spec(star, recursed: .wildcardOnlyRecursed)]).sorted(),
                       ["big.txt", "inner.txt", "readme.txt"])

        // An exclude entry is applied by the engine as well.
        XCTAssertEqual(try expand([spec(star, recursed: .recursed),
                                   spec((dir as NSString).appendingPathComponent("*big*"),
                                        include: false, recursed: .recursed)]).sorted(),
                       ["inner.txt", "readme.txt"])

        // `*` at the top level, minus the logs. Measured, not assumed: a *matched directory* is
        // walked whole even without `-r` (`7z a arc *` behaves the same), and
        // `EnumerateDirItemsAndSort` reports files, never the directories it descended into.
        XCTAssertEqual(try expand([spec((dir as NSString).appendingPathComponent("*")),
                                   spec((dir as NSString).appendingPathComponent("*.log"),
                                        include: false)]).sorted(),
                       ["big.txt", "inner.txt", "notes.md", "readme.txt"])

        // w-: the pattern is a literal name, so it names a file that does not exist. In the
        // **archive-list** walk that is `CMessagePathException("Cannot find archive")`
        // (EnumDirItems.cpp:1496-1500), which `WinMain` puts on the exit-7 arm, not the exit-2 one.
        XCTAssertThrowsError(try expand([spec(star, wildcard: false)])) { error in
            XCTAssertNotNil((error as NSError).userInfo[SevenZipFailureLadder.pathExceptionUserInfoKey])
            XCTAssertEqual(SevenZipFailureLadder.exitCode(for: error), SevenZipExitCode.userError)
            XCTAssertEqual(SevenZipFailureLadder.classify(error).message, "Cannot find archive")
        }

        // The **item-censor** walk (EnumerateItems, what UpdateArchive and HashCalc run) has no such
        // rule: nothing matched is a legitimate empty list, so `a arc -i!*.nothing` is not an
        // exception inside the engine.
        let itemWalk: Result<[String], Error> = offMain {
            do {
                return .success(try SZUpdater.expandPathSpecs(
                    [spec((dir as NSString).appendingPathComponent("*.nothing"))],
                    sortedArchiveList: false))
            } catch { return .failure(error) }
        }
        XCTAssertEqual(try itemWalk.get(), [])
        // ... and the same walk really does expand a pattern that matches.
        let itemHits: Result<[String], Error> = offMain {
            do {
                return .success(try SZUpdater.expandPathSpecs([spec(star, recursed: .recursed)],
                                                              sortedArchiveList: false))
            } catch { return .failure(error) }
        }
        XCTAssertEqual(try itemHits.get().map { ($0 as NSString).lastPathComponent }.sorted(),
                       ["big.txt", "inner.txt", "readme.txt"])

        // No include entry at all -> empty, without touching the disk.
        XCTAssertEqual(try expand([spec(star, include: false)]), [])
    }

    /// A real file whose name contains `*` must survive a literal spec — the reason `-aiw-!` exists.
    func testLiteralSpecKeepsAStarInARealFileName() throws {
        let dir = try tempDir("expand-star")
        let odd = (dir as NSString).appendingPathComponent("we*rd.txt")
        try "x\n".write(toFile: odd, atomically: true, encoding: .utf8)
        let out: Result<[String], Error> = offMain {
            do { return .success(try SZUpdater.expandPathSpecs([SZPathSpec.literal(odd)], sortedArchiveList: true)) }
            catch { return .failure(error) }
        }
        XCTAssertEqual(try out.get().map { ($0 as NSString).lastPathComponent }, ["we*rd.txt"])
    }

    /// The archive censor of `t`/`x`: `-ai!*.7z` must reach the engine's sorted archive list
    /// (GUI.cpp:285-304), and `-ax!` must remove one.
    func testArchiveCensorExpandsWildcards() throws {
        let dir = try tempDir("arc-censor")
        try makeSourceTree(in: dir)
        for name in ["one", "two", "three"] {
            let archive = (dir as NSString).appendingPathComponent("\(name).7z")
            try update(SZUpdateOptions.options(archivePath: archive),
                       [(dir as NSString).appendingPathComponent("readme.txt")])
        }
        let command = try parse("t -an -ai!\((dir as NSString).appendingPathComponent("*.7z")) "
                                + "-ax!\((dir as NSString).appendingPathComponent("two.7z"))")
        XCTAssertTrue(SevenZipCommandLine.needsCensorWalk(command.archiveSpecs))
        let specs = command.archiveSpecs.map {
            SZPathSpec.spec(path: $0.path, include: $0.include,
                            recursedType: SZRecursedType(rawValue: $0.recursedType.rawValue)!,
                            wildcardMatching: $0.wildcardMatching,
                            markMode: SZWildcardMarkMode(rawValue: $0.markMode.rawValue)!)
        }
        let out: Result<[String], Error> = offMain {
            do { return .success(try SZUpdater.expandPathSpecs(specs, sortedArchiveList: true)) }
            catch { return .failure(error) }
        }
        XCTAssertEqual(try out.get().map { ($0 as NSString).lastPathComponent }.sorted(),
                       ["one.7z", "three.7z"])
    }

    /// Passing the specs straight to `UpdateArchive` is what keeps the stored names right: with
    /// `-ir!*.txt` the engine stores `sub/big.txt`, not `big.txt`.
    func testUpdateWithSpecsKeepsTheRelativePathsTheEngineComputes() throws {
        let dir = try tempDir("spec-update")
        try makeSourceTree(in: dir)
        let archive = (dir as NSString).appendingPathComponent("arc.7z")
        let specs = [SZPathSpec.spec(path: (dir as NSString).appendingPathComponent("*.txt"),
                                     include: true, recursedType: .recursed,
                                     wildcardMatching: true, markMode: .fileOrDir)]
        let out: Result<SZUpdateResult, Error> = offMain {
            do {
                return .success(try SZUpdater.update(with: SZUpdateOptions.options(archivePath: archive),
                                                     pathSpecs: specs, progress: nil))
            } catch { return .failure(error) }
        }
        _ = try out.get()
        let names = try archiveEntryNames(archive)
        // The relative prefix is the point: `sub/big.txt`, not `big.txt`.
        XCTAssertTrue(names.contains("readme.txt"), "\(names)")
        XCTAssertTrue(names.contains("sub/big.txt"), "\(names)")
        XCTAssertTrue(names.contains("sub/deep/inner.txt"), "\(names)")
        XCTAssertFalse(names.contains("big.txt"), "\(names)")
        XCTAssertFalse(names.contains("notes.md"), "-i!*.txt must not match notes.md: \(names)")
        if let console = runConsole(["t", archive]) {
            XCTAssertEqual(console.status, 0, "7zz t failed\n\(console.output)")
        }
    }

    /// `d` with an exclude-only censor must not fall back to the universal wildcard and delete the
    /// whole archive. The command layer guards it too, but the bridge is the last line.
    func testDeleteWithNoIncludeEntryIsRefused() throws {
        let dir = try tempDir("d-guard")
        try makeSourceTree(in: dir)
        let archive = (dir as NSString).appendingPathComponent("arc.7z")
        try update(SZUpdateOptions.options(archivePath: archive),
                   [(dir as NSString).appendingPathComponent("readme.txt"),
                    (dir as NSString).appendingPathComponent("notes.md")])

        let excludeOnly = [SZPathSpec.spec(path: "*.md", include: false,
                                           recursedType: .nonRecursed, wildcardMatching: true,
                                           markMode: .fileOrDir)]
        let outcome: Result<SZUpdateResult, Error> = offMain {
            do {
                return .success(try SZUpdater.deleteItems(specs: excludeOnly, fromArchiveAt: archive,
                                                          options: nil, progress: nil))
            } catch { return .failure(error) }
        }
        XCTAssertThrowsError(try outcome.get())
        XCTAssertEqual(try archiveEntryNames(archive), ["notes.md", "readme.txt"],
                       "the archive must be untouched")

        // With an include entry it really deletes just that one.
        let ok = [SZPathSpec.spec(path: "*.md", include: true, recursedType: .nonRecursed,
                                  wildcardMatching: true, markMode: .fileOrDir)]
        let done: Result<SZUpdateResult, Error> = offMain {
            do {
                return .success(try SZUpdater.deleteItems(specs: ok, fromArchiveAt: archive,
                                                          options: nil, progress: nil))
            } catch { return .failure(error) }
        }
        _ = try done.get()
        XCTAssertEqual(try archiveEntryNames(archive), ["readme.txt"])
    }

    // MARK: - 03 section 2.6: `-scrc` on `x` / `t`

    func testScrcIsParsedForExtractAndTest() throws {
        XCTAssertEqual(try parse("x -an -scrcSHA256 -aiw-!/tmp/a.7z").hashMethods, ["SHA256"])
        XCTAssertEqual(try parse("t -an -scrc -aiw-!/tmp/a.7z").hashMethods, [""])
        XCTAssertEqual(try parse("t -an -scrcCRC32 -scrcSHA1 -aiw-!/tmp/a.7z").hashMethods,
                       ["CRC32", "SHA1"])
    }

    /// The command half of item 4: the digests the bridge reports for an extraction and for a test
    /// are the extracted data's, and they match `7zz t -scrcSHA256`.
    func testChecksumsWhileExtractingAndTesting() throws {
        guard Self.consoleTool != nil else { throw XCTSkip("console 7zz is not built") }
        let dir = try tempDir("scrc")
        try makeSourceTree(in: dir)
        let archive = (dir as NSString).appendingPathComponent("arc.7z")
        try update(SZUpdateOptions.options(archivePath: archive),
                   [(dir as NSString).appendingPathComponent("readme.txt"),
                    (dir as NSString).appendingPathComponent("notes.md")])

        func digest(testMode: Bool) throws -> String {
            // Exactly what CommandExecutor.runExtractGroup does with the parsed switch.
            let line = testMode ? "t -an -scrcSHA256 -aiw-!\(archive)"
                                : "x -an -scrcSHA256 -aiw-!\(archive)"
            let command = try parse(line)
            var methods = command.hashMethods.filter { !$0.isEmpty }
            if methods.isEmpty { methods = ["CRC32"] }
            for method in methods { XCTAssertTrue(SZHasher.isMethodSupported(method)) }

            let options = SZExtractOptions()
            options.testMode = testMode
            options.hashMethods = methods
            if !testMode {
                let out = try tempDir("scrc-out-\(testMode)")
                options.outputDirectory = out + "/"
                options.outDirMode = .direct
                options.overwriteMode = .overwrite
            }
            let out: Result<SZExtractResult, Error> = offMain {
                do {
                    return .success(testMode
                        ? try SZArchiveExtractor.testArchives(at: [archive], options: options,
                                                              progress: nil)
                        : try SZArchiveExtractor.extractArchives(at: [archive], options: options,
                                                                 progress: nil))
                } catch { return .failure(error) }
            }
            let result = try out.get()
            XCTAssertTrue(result.isOK)
            // ExtractGUI.cpp:129-152: with -scrc the hash list replaces the test summary box.
            XCTAssertNil(result.testSummary, "the hash list replaces the summary")
            let hashes = try XCTUnwrap(result.hashResults)
            XCTAssertEqual(hashes.methodNames, ["SHA256"])
            return try XCTUnwrap(hashes.dataDigests["SHA256"]).uppercased()
        }

        let whileExtracting = try digest(testMode: false)
        let whileTesting = try digest(testMode: true)
        XCTAssertEqual(whileExtracting, whileTesting,
                       "the same bytes must hash the same whether extracted or only tested")

        let console = try XCTUnwrap(runConsole(["t", "-scrcSHA256", archive]))
        XCTAssertEqual(console.status, 0, console.output)
        XCTAssertTrue(console.output.uppercased().contains(whileExtracting),
                      "7zz must report the same SHA-256 \(whileExtracting)\n\(console.output)")
    }

    // MARK: - 01b section 4.23: `-sfx<module>`

    func testSfxSwitchIsParsedWithAndWithoutAModule() throws {
        XCTAssertEqual(try parse("a /tmp/a.7z -sfx x.txt").sfxModule, "")
        XCTAssertEqual(try parse("a /tmp/a.7z -sfx7zCon.sfx x.txt").sfxModule, "7zCon.sfx")
        XCTAssertNil(try parse("a /tmp/a.7z x.txt").sfxModule)
    }

    func testSfxModuleResolution() throws {
        // Only 7z carries a stub (kFF_SFX, CompressDialog.cpp:364).
        XCTAssertTrue(SZUpdater.formatSupportsSFX("7z"))
        XCTAssertTrue(SZUpdater.formatSupportsSFX("7Z"))
        XCTAssertFalse(SZUpdater.formatSupportsSFX("zip"))

        // Bare -sfx -> the bundled 7z.sfx.
        let dflt = try SZUpdater.resolvedSFXModulePath(nil)
        XCTAssertEqual((dflt as NSString).lastPathComponent, "7z.sfx")
        // A bare name is looked up next to the program (here Resources/SFX) first.
        let console = try SZUpdater.resolvedSFXModulePath("7zCon.sfx")
        XCTAssertEqual((console as NSString).lastPathComponent, "7zCon.sfx")
        // An absolute path is used as given.
        XCTAssertEqual(try SZUpdater.resolvedSFXModulePath(console), console)

        // Missing -> "cannot find specified SFX module".
        XCTAssertThrowsError(try SZUpdater.resolvedSFXModulePath("/nope/none.sfx")) { error in
            let e = error as NSError
            XCTAssertEqual(e.code, SZError.Code.fileNotFound.rawValue)
            XCTAssertTrue(e.localizedDescription.hasPrefix("cannot find specified SFX module"),
                          e.localizedDescription)
            XCTAssertEqual(SevenZipFailureLadder.exitCode(for: error), SevenZipExitCode.fatalError)
        }
        XCTAssertThrowsError(try SZUpdater.resolvedSFXModulePath("no-such-stub.sfx"))

        // There but not an executable -> "cannot open SFX module".
        let dir = try tempDir("sfx-bogus")
        let bogus = (dir as NSString).appendingPathComponent("bogus.sfx")
        try String(repeating: "not an executable\n", count: 200)
            .write(toFile: bogus, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SZUpdater.resolvedSFXModulePath(bogus)) { error in
            let e = error as NSError
            XCTAssertEqual(e.code, SZError.Code.invalidArgument.rawValue)
            XCTAssertTrue(e.localizedDescription.hasPrefix("cannot open SFX module"),
                          e.localizedDescription)
        }
        // Too short to be a stub, even with the right magic.
        let tiny = (dir as NSString).appendingPathComponent("tiny.sfx")
        try "MZ".write(toFile: tiny, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try SZUpdater.resolvedSFXModulePath(tiny))
        // A directory is not a module either.
        XCTAssertThrowsError(try SZUpdater.resolvedSFXModulePath(dir))
    }

    /// A self-extracting archive built from a **named** module: the stub is the console one, byte
    /// for byte, and the payload behind it is a real 7z the console tool can list.
    func testSfxArchiveIsBuiltFromTheNamedModule() throws {
        let dir = try tempDir("sfx-named")
        try makeSourceTree(in: dir)
        let module = try SZUpdater.resolvedSFXModulePath("7zCon.sfx")
        let stub = try Data(contentsOf: URL(fileURLWithPath: module))

        let options = SZUpdateOptions.options(archivePath: (dir as NSString)
            .appendingPathComponent("payload.exe"))
        options.formatName = "7z"
        options.sfxMode = true
        options.sfxModulePath = module
        let result = try update(options, [(dir as NSString).appendingPathComponent("readme.txt")])

        let produced = try Data(contentsOf: URL(fileURLWithPath: result.archivePath))
        XCTAssertTrue(produced.count > stub.count, "the payload must follow the stub")
        XCTAssertEqual(produced.prefix(stub.count), stub,
                       "the named module must be the prefix, byte for byte")
        XCTAssertEqual(try archiveEntryNames(result.archivePath), ["readme.txt"])
        if let console = runConsole(["l", "-slt", result.archivePath]) {
            XCTAssertEqual(console.status, 0, console.output)
            XCTAssertTrue(values("Path", in: console.output).contains("readme.txt"), console.output)
        }

        // The default stub is a different one, so "named module honoured" is a real assertion.
        let dflt = try Data(contentsOf: URL(fileURLWithPath:
            try SZUpdater.resolvedSFXModulePath(nil)))
        XCTAssertNotEqual(dflt.prefix(4096), stub.prefix(4096))
    }

    /// The surprise this replaces: a missing or bogus module used to fall back to the bundled stub,
    /// and a non-7z format used to write a plain archive. Both are errors now.
    func testSfxFailsInsteadOfWritingSomethingElse() throws {
        let dir = try tempDir("sfx-refuse")
        try makeSourceTree(in: dir)
        let options = SZUpdateOptions.options(archivePath: (dir as NSString)
            .appendingPathComponent("out.exe"))
        options.formatName = "zip"
        options.sfxMode = true
        XCTAssertThrowsError(try update(options, [(dir as NSString)
            .appendingPathComponent("readme.txt")])) { error in
            XCTAssertTrue((error as NSError).localizedDescription
                .hasPrefix("Self-extracting archives are not supported for this format"),
                          (error as NSError).localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: (dir as NSString)
            .appendingPathComponent("out.exe")), "nothing may be written")

        options.formatName = "7z"
        options.sfxModulePath = "/nope/none.sfx"
        XCTAssertThrowsError(try update(options, [(dir as NSString)
            .appendingPathComponent("readme.txt")]))
    }

    // MARK: - 03 section 1.7 / 6.2: dropping on the Dock icon

    func testDockDropRoutesOneArchiveToOpenAndEverythingElseToCompress() {
        let archives: Set<String> = ["/tmp/a.7z", "/tmp/b.zip"]
        func route(_ paths: [String], _ flags: [Bool]) -> DockDropAction {
            DockDropRouter.action(paths: paths, directoryFlags: flags,
                                  isRecognisedArchive: { archives.contains($0) })
        }
        // One archive -> open (a double-click is the same event).
        XCTAssertEqual(route(["/tmp/a.7z"], [false]), .open(["/tmp/a.7z"]))
        // Two archives -> add to archive, like dragging two files onto 7-Zip in Explorer.
        XCTAssertEqual(route(["/tmp/a.7z", "/tmp/b.zip"], [false, false]), .addToArchive)
        // A folder, even alone, is never an open.
        XCTAssertEqual(route(["/tmp/dir"], [true]), .addToArchive)
        // A file the engine does not know -> add to archive.
        XCTAssertEqual(route(["/tmp/notes.txt"], [false]), .addToArchive)
        // An extension on the ContextMenu exclude list (kExtractExcludeExtensions) is never opened,
        // even if the engine would take the file.
        XCTAssertEqual(route(["/tmp/a.txt"], [false]), .addToArchive)
        XCTAssertEqual(route([], []), .nothing)
    }

    /// The compress command a Dock drop runs is the very one Finder's own menu builds, so the two
    /// cannot drift (03 section 1.4 item B5).
    func testDockDropCompressCommandIsTheFinderMenuCommand() throws {
        let selection = FinderSelection(paths: ["/tmp/src/one.txt", "/tmp/src/two.txt"],
                                        directoryFlags: [false, false])
        let command = try XCTUnwrap(FinderMenuModel.command(verb: "SevenZipCompress",
                                                            selection: selection))
        let argv = command.argv(for: selection.paths).argv
        XCTAssertEqual(argv.first, "a")
        XCTAssertTrue(argv.contains("-ad"))
        XCTAssertTrue(argv.contains("-saa"))
        XCTAssertTrue(argv.contains("--"))
        XCTAssertEqual(argv.last, "/tmp/src/src")     // CreateArchiveName of the common folder
        // And it parses back into a real command line.
        let parsed = try SevenZipArguments.parse(argv)
        XCTAssertEqual(parsed.command, .add)
        XCTAssertTrue(parsed.showDialog)
        XCTAssertEqual(parsed.archiveNameMode, .add)
        XCTAssertEqual(parsed.resolvedItemPaths, selection.paths)
    }

    /// The Info.plist half: the Dock only accepts a drop of types the app claims, so there has to be
    /// a catch-all group — and it must stay out of "Open With" and out of every handler race.
    func testInfoPlistClaimsAnyItemForTheDockDropOnly() throws {
        let url = URL(fileURLWithPath: Self.repoRoot)
            .appendingPathComponent("Mac/App/Info.plist")
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(
            from: try Data(contentsOf: url), format: nil) as? [String: Any])
        let types = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let catchAll = try XCTUnwrap(types.first {
            ($0["LSItemContentTypes"] as? [String])?.contains("public.item") == true
        })
        XCTAssertEqual(catchAll["LSItemContentTypes"] as? [String], ["public.item", "public.folder"])
        XCTAssertEqual(catchAll["LSHandlerRank"] as? String, "None")
        XCTAssertEqual(catchAll["CFBundleTypeRole"] as? String, "Viewer")
        XCTAssertNil(catchAll["CFBundleTypeExtensions"],
                     "it must claim no extension, or it would enter the handler race")
        // Exactly one such group, and it is the last one, so no earlier entry is shadowed.
        XCTAssertEqual(types.filter {
            ($0["LSItemContentTypes"] as? [String])?.contains("public.item") == true
        }.count, 1)
        XCTAssertEqual(types.last?["CFBundleTypeName"] as? String,
                       "Any file or folder (drop to compress)")
    }
}
