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

    /// Extra windows opened by the "Open archive" command: one file manager per archive, like
    /// `7zFM.exe "%1"` (03 section 6.2, 01 section 9 #32).
    private static var extraWindowControllers: [MainWindowController] = []

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
        // unattended run needs; see Mac/docs/api/finder.md.
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
            showError(error.localizedDescription, parent: parentWindow)
            return .fatalError
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

    static func openInFileManager(paths: [String], formatHint: String?) {
        guard !paths.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        let delegate = NSApp.delegate as? AppDelegate
        for (index, path) in paths.enumerated() {
            let full = (path as NSString).isAbsolutePath
                ? path
                : FileManager.default.currentDirectoryPath + "/" + path
            if index == 0, let controller = delegate?.mainWindowController {
                controller.openStartupPath(full, formatHint: formatHint)
                controller.showWindow(nil)
                continue
            }
            // Each further archive gets its own window, like one 7zFM per file.
            let controller = MainWindowController()
            extraWindowControllers.append(controller)
            controller.openStartupPath(full, formatHint: formatHint)
            controller.showWindow(nil)
            controller.window?.cascadeTopLeft(from: NSPoint(x: 40, y: 40))
        }
    }

    // MARK: - t / x / e  (GUI.cpp:245-326)

    private static func runExtractGroup(_ command: SevenZipCommandLine,
                                        parentWindow: NSWindow?) -> SevenZipExitCode {
        let archives = command.resolvedArchivePaths
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
                dialogOptions.summaryLines = summaryLines(for: archives)
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
            if testMode, let summary = extractResult.testSummary {
                showInfo(summary, parent: parentWindow)
            }
            // ":324-325": `!ecs->IsOK()` is exit code 2.
            return extractResult.isOK ? .success : .fatalError
        case .failure(let error as NSError) where error.code == SZError.Code.cancelled.rawValue:
            return .userBreak
        case .failure:
            return .fatalError          // the runner already showed the alert
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
        case .failure(let error as NSError) where error.code == SZError.Code.cancelled.rawValue:
            return .userBreak
        case .failure:
            return .fatalError
        }
    }

    // MARK: - a / u / d / rn  (GUI.cpp:328-375)

    private static func runUpdateGroup(_ command: SevenZipCommandLine,
                                       parentWindow: NSWindow?) -> SevenZipExitCode {
        guard let archivePath = command.archiveName, !archivePath.isEmpty else {
            showError("Cannot find archive name", parent: parentWindow)
            return .userError
        }
        let sources = command.resolvedItemPaths

        // `a -thash`: write a checksum file, not an archive (03 section 2.6).
        if command.command == .add,
           command.formatHint?.caseInsensitiveCompare("hash") == .orderedSame {
            return writeChecksumFile(at: archivePath, sources: sources, parentWindow: parentWindow)
        }

        if command.command == .delete {
            return deleteItems(named: sources, fromArchiveAt: archivePath, parentWindow: parentWindow)
        }
        if command.command == .rename {
            // `rn` needs old/new name pairs; the shell integration never generates it.
            showError("Unsupported command", parent: parentWindow)
            return .fatalError
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
            input.openShareForWrite = command.openShareForWrite
            input.deleteAfterCompressing = command.deleteAfterCompressing
            input.parentWindow = parentWindow
            guard let answer = CompressDialogController.run(input) else { return .userBreak }
            result = answer
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
            result.updateMode = command.command == .update ? .update : .add
            result.deleteAfterCompressing = command.deleteAfterCompressing
            result.openShareForWrite = command.openShareForWrite
            result.setArcMTime = command.setArchiveMTime ? true : nil
            result.preserveATime = command.preserveAccessTime ? true : nil
            result.symLinks = command.storeSymLinks
            result.hardLinks = command.storeHardLinks
            result.altStreams = command.storeAltStreams
        }

        let updateOptions = result.updateOptions()
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

        let outcome = OperationRunner.run(runnerOptions) { runner -> SZUpdateResult in
            try SZUpdater.update(with: updateOptions, sourcePaths: sources, progress: runner)
        }
        switch outcome {
        case .success(let updateResult):
            if email { CompressCommands.compose(email: updateResult.archivePath,
                                                address: command.emailAddress) }
            // ":369-374": failed files are exit code 1 (kWarning).
            return updateResult.failedPaths.isEmpty ? .success : .warning
        case .failure(let error as NSError) where error.code == SZError.Code.cancelled.rawValue:
            return .userBreak
        case .failure:
            return .fatalError
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
        case .failure(let error as NSError) where error.code == SZError.Code.cancelled.rawValue:
            return .userBreak
        case .failure:
            return .fatalError
        }
    }

    /// The console `d` command.
    private static func deleteItems(named names: [String], fromArchiveAt path: String,
                                    parentWindow: NSWindow?) -> SevenZipExitCode {
        guard !names.isEmpty else {
            showError(Lang.text(3015, "You must select one or more files"), parent: parentWindow)
            return .userError
        }
        var runnerOptions = OperationRunner.Options(title: Lang.text(3305, "Removing"))
        runnerOptions.initialStatus = .removing
        runnerOptions.titleFileName = path
        runnerOptions.parentWindow = parentWindow
        runnerOptions.waitMode = false

        let outcome = OperationRunner.run(runnerOptions) { runner -> SZUpdateResult in
            try SZUpdater.deleteItems(named: names, fromArchiveAt: path, options: nil,
                                      progress: runner)
        }
        switch outcome {
        case .success:
            return .success
        case .failure(let error as NSError) where error.code == SZError.Code.cancelled.rawValue:
            return .userBreak
        case .failure:
            return .fatalError
        }
    }

    // MARK: - h  (GUI.cpp:376-396 -> HashCalcGUI)

    private static func runHash(_ command: SevenZipCommandLine,
                                parentWindow: NSWindow?) -> SevenZipExitCode {
        let paths = command.resolvedItemPaths
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
        case .failure(let error as NSError) where error.code == SZError.Code.cancelled.rawValue:
            return .userBreak
        case .failure:
            return .fatalError
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

    /// `CApp::GetItemsInfoString` applied to the archives, like the Extract dialog's summary.
    private static func summaryLines(for archives: [String]) -> [String] {
        let maxLines = 11
        var lines = archives.prefix(maxLines).map(ArchiveNaming.lastComponent)
        if archives.count > maxLines { lines.append("...") }
        lines.append(Lang.text(3907, "Archives:") + " \(archives.count)")   // IDS_ARCHIVES_COLON
        return lines
    }

    static func showError(_ text: String, parent: NSWindow?) {
        guard !suppressMessages else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "7-Zip"
        alert.informativeText = text
        alert.addButton(withTitle: Lang.text(401, "OK"))
        alert.runModal()
    }

    static func showInfo(_ text: String, parent: NSWindow?) {
        guard !suppressMessages else { return }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "7-Zip"
        alert.informativeText = text
        alert.addButton(withTitle: Lang.text(401, "OK"))
        alert.runModal()
    }
}
