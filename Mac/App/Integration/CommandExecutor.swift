// CommandExecutor.swift -- `Main2` (CPP/7zip/UI/GUI/GUI.cpp:137-402) plus `WinMain`'s exception
// mapping (`:408-494`), in the app. **Every** integration route ends here: the argv the process was
// launched with (`CommandLineEntry`), a `sevenzip://` URL from the Finder Sync extension or a Quick
// Action (`URLCommands`), a classic Service (`ServicesProvider`) and a document open. Behaviour
// therefore cannot drift between them (03-shell-integration-inventory.md section 2, section 6.4).
//
// Nothing about extraction, updating or hashing is reimplemented: `t`/`x`/`e` go to
// `SZArchiveExtractor` (which runs the engine's own `Extract()`), `a`/`u`/`d` to `SZUpdater`
// (`UpdateArchive()`), `h` to `SZHasher` (`HashCalc`), `b` to `BenchmarkDialog`, and the three
// dialogs are the `extract`, `compress` and `tools` scopes' own.
//
// Main thread only: it shows modal dialogs and drives `OperationRunner`, which runs a modal
// session (api/opsinfra.md section 5).

import AppKit
import SevenZipKit

enum CommandExecutor {

    /// `g_DisableUserQuestions` (MyMessages.cpp:16-20): `-y` silences every box.
    private static var suppressMessages = false

    // MARK: - Failures (GUI.cpp:437-494)

    /// `WinMain`'s exception ladder with IDS_MEM_ERROR resolved through the active language file
    /// (03 section 2.7). Every failure site in this file goes through it, so no code path can
    /// invent an exit code of its own any more.
    static func failure(for error: Error) -> SevenZipFailure {
        SevenZipFailureLadder.classify(
            error,
            memoryMessage: Lang.text(3000, SevenZipFailureLadder.englishMemoryErrorMessage))
    }

    /// Classifies, shows the box the ladder asks for, and returns the exit code. For a failure the
    /// Progress dialog already reported, use `failure(for:).exitCode` instead of this.
    private static func report(_ error: Error, parent: NSWindow?) -> SevenZipExitCode {
        let classified = failure(for: error)
        if let message = classified.message { showError(message, parent: parent) }
        return classified.exitCode
    }

    /// `SevenZipPathSpec` -> the bridge's `SZPathSpec`, so the censor entry reaches
    /// `NWildcard::CCensor` with its `r`/`w`/`m` modifiers intact.
    private static func bridgeSpec(_ spec: SevenZipPathSpec) -> SZPathSpec {
        SZPathSpec.spec(path: spec.path,
                        include: spec.include,
                        recursedType: SZRecursedType(rawValue: spec.recursedType.rawValue)
                            ?? .nonRecursed,
                        wildcardMatching: spec.wildcardMatching,
                        markMode: SZWildcardMarkMode(rawValue: spec.markMode.rawValue) ?? .fileOrDir)
    }

    /// `EnumerateDirItemsAndSort(options.arcCensor)` (GUI.cpp:285-304) / `EnumerateItems`: the
    /// engine's own directory walk expands the wildcards, sorts the result and applies the excludes.
    /// Only called when the censor actually needs it, so a Finder selection (`-aiw-!` per item)
    /// still never touches the disk.
    ///
    /// The walk is a blocking engine call, so it runs on an `OperationRunner` worker like every
    /// other one (opsinfra api §1), never on the main thread: for a wildcard over a large tree the
    /// app used to hang with no window and answer no URL, Apple event or accessibility query
    /// (requests.md, resetcmd -> cmdmode). WaitMode keeps a quick walk windowless; a slow one shows
    /// the Progress dialog with "Scanning...". The engine walk itself cannot be interrupted, so a
    /// Cancel takes effect when it returns: the command then ends as a user break.
    private static func expand(_ specs: [SevenZipPathSpec], fallback: [String],
                               sortedArchiveList: Bool, parent: NSWindow?) throws -> [String] {
        guard SevenZipCommandLine.needsCensorWalk(specs) else { return fallback }
        let bridged = specs.map(bridgeSpec)
        let walk = { try SZUpdater.expandPathSpecs(bridged, sortedArchiveList: sortedArchiveList) }
        guard Thread.isMainThread else { return try walk() }
        var options = OperationRunner.Options(title: "7-Zip")
        options.initialStatus = .scanning
        options.parentWindow = parent
        // The walk's own failure is returned inside the success value, so the caller's `report`
        // shows it once with the command's exit code, and the runner shows nothing itself.
        let outcome = OperationRunner.run(options) { runner -> Result<[String], Error> in
            let result = Result { try walk() }
            if runner.progressCheckBreak() {
                throw NSError(domain: SZErrorDomain, code: SZError.Code.cancelled.rawValue)
            }
            return result
        }
        return try outcome.get().get()
    }

    // MARK: - Entry point

    /// Runs one command line and returns the 7zG exit code. `argv` excludes argv[0].
    ///
    /// Two shapes are accepted, exactly as the two Windows binaries do:
    ///  * `7zG.exe <command> [switches] [archive] [items]` -- the full grammar;
    ///  * `7zFM.exe <path> [-t<type>]` -- a path opens as an archive or a folder (FM.cpp:646-656).
    @discardableResult
    static func run(argv: [String], temporaryFiles: [String] = [],
                    parentWindow: NSWindow? = nil) -> SevenZipExitCode {
        // The list files the sender wrote are consumed here; Windows releases its shared-memory
        // section at the same point (CEventSetEnd, ArchiveCommandLine.cpp:636-647).
        defer { CommandURL.removeTemporaryFiles(temporaryFiles) }

        // **Deliberate difference.** `Main2` sets `g_DisableUserQuestions` only *after* `Parse1`
        // (GUI.cpp:157-159), so a switch-syntax error still opens a message box even with `-y`.
        // The port honours `-y` from the start, which is what the switch says and what an
        // unattended run needs; see ai/api/finder.md.
        suppressMessages = argv.contains { $0.lowercased() == "-y" }
        defer { suppressMessages = false }

        guard let first = argv.first else {
            // Main2 (:146-150): no arguments at all -> "Specify command", exit 0.
            showError("Specify command", parent: parentWindow)
            return .success
        }

        // The file-manager shape: the first token is neither a command word nor a switch.
        if !first.hasPrefix("-"), SevenZipCommandType.parse(first) == nil {
            openInFileManager(paths: argv.filter { !$0.hasPrefix("-") },
                              formatHint: argv.first { $0.hasPrefix("-t") }.map { String($0.dropFirst(2)) })
            return .success
        }

        let command: SevenZipCommandLine
        do {
            command = try SevenZipArguments.parse(argv)
        } catch let error as SevenZipArgumentError {
            // CMessagePathException -> box with the message and the path, exit 7 (:461-470).
            showError(error.description, parent: parentWindow)
            return .userError
        } catch {
            return report(error, parent: parentWindow)
        }

        suppressMessages = command.yesToAll
        // A list file the sender generated (`7zL-<uuid>.txt`) is deleted once it has been read,
        // whichever route delivered the command; `removeTemporaryFiles` ignores anything else, so a
        // hand-written `-i@list` survives.
        defer { CommandURL.removeTemporaryFiles(command.consumedListFiles) }

        do {
            try SZCodecs.loadCodecs()
        } catch {
            // ":182-196": the static build cannot get here, but the string is kept so the lang
            // files keep working.
            showError("7-Zip cannot find the code that works with archives.", parent: parentWindow)
            return .fatalError
        }

        // ":198-217": -t and -stx are validated before anything runs.
        if let hint = command.formatHint, !isKnownOpenType(hint) {
            showError(Lang.text(3007, "Unsupported archive type"), parent: parentWindow)
            return .fatalError
        }
        for excluded in command.excludedFormats where SZCodecs.format(named: excluded) == nil {
            showError(Lang.text(3007, "Unsupported archive type"), parent: parentWindow)
            return .fatalError
        }

        switch command.command {
        case .benchmark:
            BenchmarkDialog.run(totalMode: isTotalBenchmark(command), parent: parentWindow)
            return .success
        case .test, .extractFull, .extractNoPaths:
            return runExtractGroup(command, parentWindow: parentWindow)
        case .add, .update, .delete, .rename:
            return runUpdateGroup(command, parentWindow: parentWindow)
        case .hash:
            return runHash(command, parentWindow: parentWindow)
        case .list, .info:
            // ":396-399": 7zG has no list or info UI.
            showError("Unsupported command", parent: parentWindow)
            return .fatalError
        }
    }

    // MARK: - Open in the file manager (7zFM argv)

    /// Every path gets a window of its own, like one `7zFM.exe "%1"` per archive (03 section 6.2,
    /// 01 section 9 #32; user decision, ai/reports/newwindow.md): an archive opened from
    /// Finder never replaces what a window already shows. A failed open closes that window, as the
    /// 7zFM process ends when `WM_CREATE` fails -- and when it was the only window, the app quits
    /// with it.
    static func openInFileManager(paths: [String], formatHint: String?) {
        guard !paths.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        for path in paths {
            let full = (path as NSString).isAbsolutePath
                ? path
                : FileManager.default.currentDirectoryPath + "/" + path
            let controller = MainWindows.open()
            controller.openStartupPath(full, formatHint: formatHint, closesWindowOnFailure: true)
        }
    }

    // MARK: - t / x / e  (GUI.cpp:245-326)

    private static func runExtractGroup(_ command: SevenZipCommandLine,
                                        parentWindow: NSWindow?) -> SevenZipExitCode {
        let archives: [String]
        do {
            // The archive list is the sorted one, so "Cannot find archive" is exit 7 as upstream.
            archives = try expand(command.archiveSpecs, fallback: command.resolvedArchivePaths,
                                  sortedArchiveList: true, parent: parentWindow)
        } catch {
            return report(error, parent: parentWindow)
        }
        guard !archives.isEmpty else {
            showError(Lang.text(3015, "You must select one or more files"), parent: parentWindow)
            return .userError
        }
        // InvokeCommandCommon (:1280-1284): a directory among the items refuses the whole command.
        if let bad = archives.first(where: { isDirectory($0) }) {
            _ = bad
            showError(Lang.text(3015, "You must select one or more files"), parent: parentWindow)
            return .userError
        }

        // `t -thash`: verify a checksum file instead of opening it as an archive
        // (03 section 2.6; api/tools.md section 2).
        if command.command == .test,
           command.formatHint?.caseInsensitiveCompare("hash") == .orderedSame {
            return verifyChecksumFiles(archives, parentWindow: parentWindow)
        }

        let options = SZExtractOptions()
        options.testMode = command.command.isTestCommand
        options.outDirMode = .replaceAsterisk                 // 7zG's default, `*` per archive
        options.pathMode = SZExtractPathMode(rawValue: command.command.defaultExtractPathMode) ?? .fullPaths
        if let full = command.fullPathMode {
            options.pathMode = full == 2 ? .absPaths : .fullPaths
            options.pathModeForced = true
        }
        if let mode = command.overwriteMode {
            options.overwriteMode = SZOverwriteMode(rawValue: mode.rawValue) ?? .ask
            options.overwriteModeForced = true
        } else if command.yesToAll {
            options.overwriteMode = .overwrite                // -y: overwrite all (:1751-1755)
            options.overwriteModeForced = true
        }
        options.eliminateDuplicateRoot = command.eliminateDuplicateRoot.map { NSNumber(value: $0) }
        if let zone = command.zoneIDMode {
            options.zoneIDMode = SZZoneIDMode(rawValue: zone.rawValue) ?? .none
        }
        if let password = command.password { options.password = password }
        if let hint = command.formatHint, !hint.isEmpty { options.formatHint = hint }
        // `-scrc[method]` on `x`/`t`: the engine hashes the *extracted* data and the digests are
        // shown in the hash list dialog instead of the test summary (03 section 2.6,
        // GUI.cpp:275-283 `hb.SetMethods`, ExtractGUI.cpp:81-98, :129-136). A bare `-scrc`
        // contributes an empty name, which `CHashBundle::SetMethods` reads as CRC32.
        if !command.hashMethods.isEmpty {
            var methods = command.hashMethods.filter { !$0.isEmpty }
            if methods.isEmpty { methods = ["CRC32"] }
            for method in methods where !SZHasher.isMethodSupported(method) {
                // ThrowException_if_Error(hb.SetMethods(...)) -> CSystemException -> exit 2.
                showError("Unsupported hash method: " + method, parent: parentWindow)
                return .fatalError
            }
            options.hashMethods = methods
        }
        options.excludeDirectoryItems = command.excludeDirectoryItems
        options.excludeFileItems = command.excludeFileItems
        if let symlinks = command.storeSymLinks { options.extractSymbolicLinks = NSNumber(value: symlinks) }
        if let hardlinks = command.storeHardLinks { options.extractHardLinks = NSNumber(value: hardlinks) }
        if let alt = command.storeAltStreams { options.extractAlternateStreams = NSNumber(value: alt) }
        options.preserveAccessTime = command.preserveAccessTime
        options.restoreFileSecurity = command.restoreNtSecurity ? NSNumber(value: true) : nil

        if !options.testMode {
            // ExtractGUI.cpp:197-248: `-o` or the current directory, then the dialog with `-ad`.
            var outputDirectory = command.outputDirectory ?? FileManager.default.currentDirectoryPath
            outputDirectory = ArchiveNaming.withTrailingSeparator(outputDirectory)
            if command.showDialog {
                var dialogOptions = ExtractDialog.Options()
                dialogOptions.directoryPath = outputDirectory
                dialogOptions.archivePath = archives.count == 1 ? archives[0] : ""
                dialogOptions.pathMode = options.pathMode
                dialogOptions.pathModeForced = options.pathModeForced
                dialogOptions.overwriteMode = options.overwriteMode
                dialogOptions.overwriteModeForced = options.overwriteModeForced
                dialogOptions.eliminateDuplicateRoot = command.eliminateDuplicateRoot
                dialogOptions.password = command.password ?? ""
                dialogOptions.parentWindow = parentWindow
                guard let answer = ExtractDialog.run(dialogOptions) else { return .userBreak }
                outputDirectory = answer.directoryPath
                options.pathMode = answer.pathMode
                options.overwriteMode = answer.overwriteMode
                options.eliminateDuplicateRoot = answer.eliminateDuplicateRoot.map { NSNumber(value: $0) }
                options.restoreFileSecurity = answer.restoreFileSecurity.map { NSNumber(value: $0) }
                if !answer.password.isEmpty { options.password = answer.password }
                Settings.addToExtractPathHistory(answer.directoryPath)
            }
            options.outputDirectory = outputDirectory
            // CreateComplexDir before starting (ExtractGUI.cpp:255-270). A `*` is substituted per
            // archive by the engine, so only an asterisk-free path can be created up front.
            if !outputDirectory.contains("*") {
                do {
                    try SZArchiveExtractor.createOutputDirectory(outputDirectory)
                } catch {
                    showError(error.localizedDescription, parent: parentWindow)
                    return .fatalError
                }
            }
        }

        var runnerOptions = OperationRunner.Options(
            title: options.testMode ? Lang.text(3302, "Testing") : Lang.text(3300, "Extracting"))
        runnerOptions.initialStatus = options.testMode ? .testing : .extracting
        runnerOptions.parentWindow = parentWindow
        runnerOptions.titleFileName = archives.count == 1 ? archives[0] : ""
        runnerOptions.password = options.password
        runnerOptions.waitMode = false          // 7zG always shows its progress window

        let testMode = options.testMode
        let result = OperationRunner.run(runnerOptions) { runner -> SZExtractResult in
            testMode
                ? try SZArchiveExtractor.testArchives(at: archives, options: options, progress: runner)
                : try SZArchiveExtractor.extractArchives(at: archives, options: options, progress: runner)
        }

        switch result {
        case .success(let extractResult):
            if let hashes = extractResult.hashResults {
                // ExtractGUI.cpp:129-136: with `-scrc` the hash list replaces the test summary,
                // for `x` as much as for `t`.
                HashResultsDialog.show(results: hashes, parent: parentWindow)
            } else if testMode, let summary = extractResult.testSummary {
                showInfo(summary, parent: parentWindow)
            }
            // ":324-325": `!ecs->IsOK()` is exit code 2.
            return extractResult.isOK ? .success : .fatalError
        case .failure(let error):
            // The Progress dialog already showed the message (01b section 4.17); only the exit
            // code is ours, through the same ladder as everything else.
            return failure(for: error).exitCode
        }
    }

    /// `t -thash`: `SZHasher.verifyChecksumFile` per listed file (api/tools.md section 2).
    private static func verifyChecksumFiles(_ paths: [String],
                                            parentWindow: NSWindow?) -> SevenZipExitCode {
        var runnerOptions = OperationRunner.Options(title: Lang.text(3302, "Testing"))
        runnerOptions.initialStatus = .checksum
        runnerOptions.parentWindow = parentWindow
        runnerOptions.waitMode = false

        let result = OperationRunner.run(runnerOptions) { runner -> [SZChecksumVerification] in
            try paths.map { try SZHasher.verifyChecksumFile(at: $0, progress: runner) }
        }
        switch result {
        case .success(let verifications):
            var lines: [String] = []
            var ok = true
            for verification in verifications {
                lines.append(verification.text)
                if !verification.succeeded { ok = false }
            }
            if ok {
                showInfo(lines.joined(separator: "\n\n"), parent: parentWindow)
                return .success
            }
            MessagesDialog.show(messages: lines, parent: parentWindow)
            return .fatalError
        case .failure(let error):
            return failure(for: error).exitCode
        }
    }

    // MARK: - a / u / d / rn  (GUI.cpp:328-375)

    private static func runUpdateGroup(_ command: SevenZipCommandLine,
                                       parentWindow: NSWindow?) -> SevenZipExitCode {
        guard let archivePath = command.archiveName, !archivePath.isEmpty else {
            showError("Cannot find archive name", parent: parentWindow)
            return .userError
        }
        let itemSpecs = command.itemSpecs

        // `rn`: the positional strings were old/new pairs, so there is no source list at all.
        if command.command == .rename {
            return renameItems(command, archivePath: archivePath, parentWindow: parentWindow)
        }

        if command.command == .delete {
            return deleteItems(specs: itemSpecs, fromArchiveAt: archivePath,
                               parentWindow: parentWindow)
        }

        // Everything below wants a real file list: for the Compress dialog's info block, for the
        // hash writer and for `-thash`. `expand` is a no-op unless a censor entry needs the walk.
        let sources: [String]
        do {
            // The item censor's walk: an empty result is "nothing to add", not an error.
            sources = try expand(itemSpecs, fallback: command.resolvedItemPaths,
                                 sortedArchiveList: false, parent: parentWindow)
        } catch {
            return report(error, parent: parentWindow)
        }

        // `a -thash`: write a checksum file, not an archive (03 section 2.6).
        if command.command == .add,
           command.formatHint?.caseInsensitiveCompare("hash") == .orderedSame {
            return writeChecksumFile(at: archivePath, sources: sources, parentWindow: parentWindow)
        }

        guard !sources.isEmpty else {
            showError(Lang.text(3015, "You must select one or more files"), parent: parentWindow)
            return .userError
        }

        // ":329-334": InitFormatIndex / SetArcPath, else IDS_UPDATE_NOT_SUPPORTED and exit 2.
        let formatName = command.formatHint
            ?? SZCodecs.format(forArchiveName: archivePath)?.name
            ?? "7z"
        guard SZUpdater.formatSupportsUpdate(formatName) else {
            // IDS_UPDATE_NOT_SUPPORTED 3004 (GUI/ExtractRes.h:4).
            showError(Lang.text(3004, "Update operations are not supported for this archive."),
                      parent: parentWindow)
            return .fatalError
        }

        // `-sfx[module]` (01b section 4.23 "SFX"): resolve and validate the stub **before** any
        // dialog, so a missing or bogus module is an error instead of a plain archive nobody asked
        // for. Update.cpp:1167-1191 does the same check, but only after the dialog and only for a
        // run that already decided it is in SFX mode.
        var sfxModulePath: String?
        if let module = command.sfxModule {
            guard SZUpdater.formatSupportsSFX(formatName) else {
                showError("Self-extracting archives are not supported for this format\n"
                          + formatName, parent: parentWindow)
                return .fatalError
            }
            do {
                sfxModulePath = try SZUpdater.resolvedSFXModulePath(module.isEmpty ? nil : module)
            } catch {
                return report(error, parent: parentWindow)
            }
        }

        let email = command.emailMode
        var directory = ArchiveNaming.directoryPrefix(archivePath)
        var finalArchivePath = archivePath
        if email {
            // `-seml.`: the archive is built in a fresh temp folder and the mail composer gets it
            // (Update.cpp:1445-1453 + 03 section 2.5). The folder is purged on the next run,
            // because macOS has no synchronous "mail sent" callback.
            CompressCommands.purgeStaleEmailDirectories()
            guard let temp = CompressCommands.makeEmailDirectory() else { return .fatalError }
            directory = ArchiveNaming.withTrailingSeparator(temp)
            finalArchivePath = directory + ArchiveNaming.lastComponent(archivePath)
        }
        if directory.isEmpty {
            directory = ArchiveNaming.withTrailingSeparator(FileManager.default.currentDirectoryPath)
            finalArchivePath = directory + archivePath
        }
        if email, !command.volumeSizes.isEmpty {
            // Update.cpp:1164 refuses the combination.
            showError("Splitting to volumes is not supported in email mode", parent: parentWindow)
            return .fatalError
        }

        var result = CompressDialogResult()
        var commandLineProperties: [String] = []
        if command.showDialog {
            // UpdateGUI.cpp:315-541: the Compress dialog, pre-filled from the command line. The
            // archive path is shown without its extension, which is what `-saa` then re-adds.
            var input = CompressDialogInput()
            input.directoryPrefix = directory
            input.archiveBaseName = strippedExtension(finalArchivePath,
                                                      keep: command.archiveNameMode != .add)
            input.itemPaths = sources
            input.forcedFormatName = command.formatHint
            input.password = command.password
            input.pathMode = SZCompressPathMode(rawValue: command.fullPathMode ?? 0) ?? .relative
            input.sfxMode = command.sfxModule != nil
            input.sfxModulePath = sfxModulePath
            input.openShareForWrite = command.openShareForWrite
            input.deleteAfterCompressing = command.deleteAfterCompressing
            input.parentWindow = parentWindow
            // di.UpdateMode = FindActionSet(Commands.Front().ActionSet) (UpdateGUI.cpp:446-453):
            // `a` / `u` and any `-u` switches pick the combo item; a set that is none of the four
            // is E_NOTIMPL before the dialog opens.
            guard let updateMode = command.dialogUpdateMode,
                  let mode = SZUpdateMode(rawValue: updateMode.rawValue) else {
                showError("Not implemented", parent: parentWindow)          // HResultToMessage(E_NOTIMPL)
                return .fatalError
            }
            input.updateMode = mode
            guard let answer = CompressDialogController.run(input) else { return .userBreak }
            result = answer
            // `ParseProperties(options.MethodMode.Properties, di)` pre-parses `-m tm/tc/ta` into
            // di.MTime / CTime / ATime, but CCompressDialog::OnOK overwrites all three from the
            // format's stored options (CompressDialog.cpp:1201-1205), so they never reach the
            // dialog. What does survive is the command line's own `-m` list: `SetOutProperties`
            // *appends* the dialog's properties to `options.MethodMode.Properties`, so the command
            // line's come first and a dialog value of the same name wins (applied below).
            commandLineProperties = command.methodProperties
        } else {
            // Without `-ad` the archive path is used as given; `-sae` means exactly that and
            // `-saa` appends the format's extension (Update.cpp:115-145).
            result.archivePath = command.archiveNameMode == .add
                ? finalArchivePath + "." + (SZCodecs.format(named: formatName)?.mainExtension ?? formatName)
                : finalArchivePath
            result.formatName = formatName
            result.formatIndex = SZCodecs.format(named: formatName)?.index ?? -1
            result.level = -1                 // nothing emitted: the handler's own defaults
            result.password = command.password
            result.parameters = command.methodProperties
                .map { "-m" + $0 }
                .joined(separator: " ")
            result.updateMode = command.dialogUpdateMode.flatMap { SZUpdateMode(rawValue: $0.rawValue) }
                ?? (command.command == .update ? .update : .add)
            // The bug this replaces: `sfxMode` was only ever set from the Compress dialog, so
            // `a -sfx …` without `-ad` silently wrote a plain archive. `UpdateGUI.cpp:561-565`
            // fills the default module whether the dialog ran or not.
            result.sfxMode = sfxModulePath != nil
            result.sfxModulePath = sfxModulePath
            result.deleteAfterCompressing = command.deleteAfterCompressing
            result.openShareForWrite = command.openShareForWrite
            result.setArcMTime = command.setArchiveMTime ? true : nil
            result.preserveATime = command.preserveAccessTime ? true : nil
            result.symLinks = command.storeSymLinks
            result.hardLinks = command.storeHardLinks
            result.altStreams = command.storeAltStreams
        }

        let updateOptions = result.updateOptions()
        if !commandLineProperties.isEmpty {
            updateOptions.properties = commandLineProperties.map { text -> SZUpdateProperty in
                guard let eq = text.firstIndex(of: "=") else { return SZUpdateProperty(name: text, value: "") }
                return SZUpdateProperty(name: String(text[..<eq]), value: String(text[text.index(after: eq)...]))
            } + updateOptions.properties
        }
        if let sfxModulePath {
            // UpdateGUI.cpp:517 is `if (di.SFXMode) options.SfxMode = true;` — the dialog can turn
            // SFX **on**, never off, because `-sfx` already set it on `options`.
            updateOptions.sfxMode = true
            updateOptions.sfxModulePath = sfxModulePath
        }
        updateOptions.emailMode = email
        updateOptions.emailRemoveAfter = command.emailRemoveAfter
        updateOptions.emailAddress = command.emailAddress
        if let workingDirectory = command.workingDirectory, !workingDirectory.isEmpty {
            updateOptions.workingDirectory = workingDirectory
        }
        updateOptions.stopAfterOpenError = command.stopAfterOpenError

        var runnerOptions = OperationRunner.Options(title: Lang.text(3301, "Compressing"))
        runnerOptions.initialStatus = .compressing
        runnerOptions.showCompressionInfo = true
        runnerOptions.titleFileName = result.archivePath
        runnerOptions.parentWindow = parentWindow
        runnerOptions.asksPasswordForEncryption = true
        runnerOptions.showsEncryptFileNames = result.encryptHeadersIsAllowed
        runnerOptions.password = result.password
        runnerOptions.waitMode = false

        // The censor entries go to the engine unexpanded, so `a arc.7z -ir!src/*.c` stores
        // `sub/x.c` rather than `x.c`: `UpdateArchive` calls `AddPathsToCensor` + `EnumerateItems`
        // itself (Update.cpp:1159-1161).
        // "Exclude Mac resource forks" from the -ad dialog (dlgfeel); without the dialog the same
        // excludes are the switches -xr!._* -xr!.DS_Store -xr!__MACOSX.
        CompressMacMetadata.apply(to: updateOptions, exclude: result.excludeMacResourceForks)
        let bridgeSpecs = CompressMacMetadata.pathSpecs(items: itemSpecs.map(bridgeSpec),
                                                        exclude: result.excludeMacResourceForks)
        let outcome = OperationRunner.run(runnerOptions) { runner -> SZUpdateResult in
            try SZUpdater.update(with: updateOptions, pathSpecs: bridgeSpecs, progress: runner)
        }
        switch outcome {
        case .success(let updateResult):
            if email { CompressCommands.compose(email: updateResult.archivePath,
                                                address: command.emailAddress) }
            // ":369-374": failed files are exit code 1 (kWarning).
            return updateResult.failedPaths.isEmpty ? .success : .warning
        case .failure(let error):
            return failure(for: error).exitCode
        }
    }

    /// `rn` — the console rename command (GUI.cpp:328-375 update group, Update.cpp:477-520).
    /// Windows dispatches it through `UpdateGUI`, so the progress window is the Compressing one and
    /// a failed file is still exit code 1.
    private static func renameItems(_ command: SevenZipCommandLine, archivePath: String,
                                   parentWindow: NSWindow?) -> SevenZipExitCode {
        guard !command.renamePairs.isEmpty else {
            // The parser already refuses an odd count; this is `rn arc` with no pair at all.
            showError(Lang.text(3015, "You must select one or more files"), parent: parentWindow)
            return .userError
        }
        let pairs = command.renamePairs.map {
            SZRenamePair.pair(oldName: $0.oldName, newName: $0.newName,
                              wildcardParsing: $0.wildcardParsing)
        }
        let options = SZUpdateOptions.options(archivePath: archivePath)
        options.openShareForWrite = command.openShareForWrite
        options.stopAfterOpenError = command.stopAfterOpenError
        if let password = command.password { options.password = password }
        if let workingDirectory = command.workingDirectory, !workingDirectory.isEmpty {
            options.workingDirectory = workingDirectory
        }

        var runnerOptions = OperationRunner.Options(title: Lang.text(3301, "Compressing"))
        runnerOptions.initialStatus = .compressing
        runnerOptions.titleFileName = archivePath
        runnerOptions.parentWindow = parentWindow
        runnerOptions.password = command.password
        runnerOptions.waitMode = false

        // The `-i`/`-x` masks decide which archive items are considered
        // (ArchiveCommandLine.cpp:574-591); an empty list is the universal wildcard `*`.
        let specs = command.itemSpecs.map(bridgeSpec)
        let outcome = OperationRunner.run(runnerOptions) { runner -> SZUpdateResult in
            try SZUpdater.renameItems(pairs: pairs, inArchiveAt: archivePath, itemSpecs: specs,
                                      options: options, progress: runner)
        }
        switch outcome {
        case .success(let updateResult):
            return updateResult.failedPaths.isEmpty ? .success : .warning
        case .failure(let error):
            return failure(for: error).exitCode
        }
    }

    /// `a -thash -sae -- "<dir><name>.sha256"` (C12): `SZHasher.writeChecksumFile`.
    private static func writeChecksumFile(at path: String, sources: [String],
                                          parentWindow: NSWindow?) -> SevenZipExitCode {
        guard !sources.isEmpty else {
            showError(Lang.text(3015, "You must select one or more files"), parent: parentWindow)
            return .userError
        }
        // The method is the checksum file's own extension, which is what the hash handler does.
        let method = (ArchiveNaming.extractableExtension(of: path) ?? "sha256").uppercased()
        let base = ArchiveNaming.directoryPrefix(sources[0])

        var runnerOptions = OperationRunner.Options(
            title: Lang.text(7500, "Checksum calculating..."))      // IDS_CHECKSUM_CALCULATING
        runnerOptions.initialStatus = .checksum
        runnerOptions.parentWindow = parentWindow
        runnerOptions.waitMode = false

        let outcome = OperationRunner.run(runnerOptions) { runner -> Bool in
            try SZHasher.writeChecksumFile(at: path, forPaths: sources, relativeTo: base,
                                           method: method, recursive: true, progress: runner)
            return true
        }
        switch outcome {
        case .success:
            return .success
        case .failure(let error):
            return failure(for: error).exitCode
        }
    }

    /// The console `d` command. The censor entries reach the engine unexpanded, so `d arc -x!*.log`
    /// and a wildcard in a positional name both work.
    private static func deleteItems(specs: [SevenZipPathSpec], fromArchiveAt path: String,
                                    parentWindow: NSWindow?) -> SevenZipExitCode {
        guard specs.contains(where: { $0.include }) else {
            showError(Lang.text(3015, "You must select one or more files"), parent: parentWindow)
            return .userError
        }
        var runnerOptions = OperationRunner.Options(title: Lang.text(3305, "Removing"))
        runnerOptions.initialStatus = .removing
        runnerOptions.titleFileName = path
        runnerOptions.parentWindow = parentWindow
        runnerOptions.waitMode = false

        let bridgeSpecs = specs.map(bridgeSpec)
        let outcome = OperationRunner.run(runnerOptions) { runner -> SZUpdateResult in
            try SZUpdater.deleteItems(specs: bridgeSpecs, fromArchiveAt: path, options: nil,
                                      progress: runner)
        }
        switch outcome {
        case .success:
            return .success
        case .failure(let error):
            return failure(for: error).exitCode
        }
    }

    // MARK: - h  (GUI.cpp:376-396 -> HashCalcGUI)

    private static func runHash(_ command: SevenZipCommandLine,
                                parentWindow: NSWindow?) -> SevenZipExitCode {
        let paths: [String]
        do {
            paths = try expand(command.itemSpecs, fallback: command.resolvedItemPaths,
                               sortedArchiveList: false, parent: parentWindow)
        } catch {
            return report(error, parent: parentWindow)
        }
        guard !paths.isEmpty else {
            showError(Lang.text(3015, "You must select one or more files"), parent: parentWindow)
            return .userError
        }
        // `CHashBundle::SetMethods` with an empty list uses CRC32; a bare `-scrc` contributes an
        // empty name, which is the same thing.
        var methods = command.hashMethods.filter { !$0.isEmpty }
        if methods.isEmpty { methods = ["CRC32"] }
        for method in methods where !SZHasher.isMethodSupported(method) {
            showError("Unsupported hash method: " + method, parent: parentWindow)
            return .fatalError
        }
        let base = ArchiveNaming.directoryPrefix(paths[0])

        var runnerOptions = OperationRunner.Options(title: Lang.text(7500, "Checksum calculating..."))
        runnerOptions.initialStatus = .checksum
        runnerOptions.parentWindow = parentWindow
        runnerOptions.titleFileName = base
        runnerOptions.waitMode = false

        let outcome = OperationRunner.run(runnerOptions) { runner -> SZHashResults in
            try SZHasher.hash(paths: paths, relativeTo: base, methods: methods,
                              recursive: true, progress: runner)
        }
        switch outcome {
        case .success(let results):
            // HashGUI.cpp:283-327: ShowHashResults unless E_ABORT.
            HashResultsDialog.show(results: results, parent: parentWindow)
            return results.numErrors == 0 ? .success : .warning
        case .failure(let error):
            return failure(for: error).exitCode
        }
    }

    // MARK: - Helpers

    /// `ParseOpenTypes` (OpenArchive.cpp:3591-3630): a format name, `*`, `#` or `#:<flags>`.
    static func isKnownOpenType(_ type: String) -> Bool {
        if type.isEmpty || type == "*" { return true }
        if type.hasPrefix("#") { return true }
        if type.caseInsensitiveCompare("hash") == .orderedSame { return true }
        return SZCodecs.format(named: type) != nil
    }

    /// `-mm=*` puts the benchmark dialog into its total-mode variant (CompressCall.cpp:332-343).
    private static func isTotalBenchmark(_ command: SevenZipCommandLine) -> Bool {
        command.methodProperties.contains { $0.lowercased() == "m=*" }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
        return isDir.boolValue
    }

    /// `CArchivePath::ParseFromPath` for the dialog's "path without extension" field.
    private static func strippedExtension(_ path: String, keep: Bool) -> String {
        guard !keep else { return path }
        return (path as NSString).deletingPathExtension
    }

    /// `parent` used to be accepted and ignored: every message was app-modal with no owner window,
    /// which is right for 7zG (a command line in a process with no window) and wrong the moment the
    /// app *has* a window -- a URL command that failed then raised an alert nothing owned, the same
    /// wedge as `ai/reports/fastui.md` section 6.10. `ErrorAlert.run` makes it a sheet of
    /// `parent` when there is one and keeps it synchronous, so the callers' `return`-after-message
    /// flow is unchanged.
    static func showError(_ text: String, parent: NSWindow?) {
        guard !suppressMessages else { return }
        ErrorAlert.run(text, on: parent)                                  // MB_ICONERROR
    }

    static func showInfo(_ text: String, parent: NSWindow?) {
        guard !suppressMessages else { return }
        ErrorAlert.run(text, icon: .none, on: parent)                     // MB_OK
    }
}
