// ExtractCommands.swift -- the four extract/test commands, wired through the frozen
// `ActiveContext` contract and run with the shared `OperationRunner`.
//
// Windows equivalents (01-fm-feature-inventory.md §8.1, §2.9; 03-shell-integration-inventory.md §1.4):
//
//   kMenuCmdID_Toolbar_Extract 1071  CPanel::ExtractArchives (Panel.cpp:1008-1039)
//       FS folder  -> 7zG x -an -ai#map -o"<arcDir>/<subfolder>/" (one archive) or
//                     -o"<arcDir>/*/" (several) -ad   -> Extract dialog, then Extract()
//       in archive -> CPanel::OnCopy, i.e. the Agent's own extract path
//   kExtractHere                     out folder = the archive's folder, no dialog
//   kExtractTo                       out folder = GetSubFolderNameForExtract, no dialog, -spe
//                                    from Options.ElimDupExtract
//   kMenuCmdID_Toolbar_Test 1072     CPanel::TestArchives (Panel.cpp:1103-1177)
//       FS folder  -> 7zG t -an -ai#map          in archive -> CopyTo with testMode
//
// All of it runs in-process on a background thread (01 §9 #1) under the Progress dialog, and
// the panel is refreshed through ActiveContext.refresh() afterwards.

import AppKit
import SevenZipKit

enum ExtractCommands {

    /// Where the extracted files go, i.e. which of the three Explorer commands was used.
    enum Destination {
        /// `<arcDir>/<GetSubFolderNameForExtract2(name)>/`, or `<arcDir>/*/` for several
        /// archives (`*` is substituted per archive by the engine).
        case subfolderPerArchive
        /// `<arcDir>/`: "Extract Here".
        case archiveFolder
    }

    // MARK: - entry points

    /// Toolbar / menu "Extract files..." (kExtract): the Extract dialog, then the run.
    static func extractWithDialog() {
        guard let context = ActiveContext.current() else { return }
        if context.isArchive {
            extractFromArchiveFolder(context)
            return
        }
        run(context: context, destination: .subfolderPerArchive, showDialog: true,
            eliminateDuplicateRoot: nil)
    }

    /// "Extract Here" (kExtractHere): no dialog, straight into the archive's folder.
    static func extractHere() {
        guard let context = ActiveContext.current() else { return }
        if context.isArchive {
            extractFromArchiveFolder(context)
            return
        }
        run(context: context, destination: .archiveFolder, showDialog: false,
            eliminateDuplicateRoot: nil)
    }

    /// `Extract to "<name>/"` (kExtractTo): no dialog, one sub-folder per archive, and `-spe`
    /// from Options.ElimDupExtract (03 §1.3, ContextMenu.cpp:1287).
    static func extractToSubfolder() {
        guard let context = ActiveContext.current() else { return }
        if context.isArchive {
            extractFromArchiveFolder(context)
            return
        }
        run(context: context, destination: .subfolderPerArchive, showDialog: false,
            eliminateDuplicateRoot: Settings.elimDupExtractValue)
    }

    /// Toolbar / menu "Test archive" (kTest).
    static func testArchives() {
        guard let context = ActiveContext.current() else { return }
        if context.isArchive {
            testInsideArchive(context)
            return
        }
        guard let archives = archivePaths(context) else { return }

        // `t -thash` (03 §2.6, parity D item 4, opsgaps): when every operated item is a checksum
        // file the panel's Test verifies it, through the same command line as the context menu's
        // C13 "Test archive : Checksum" and Finder's, instead of the archive statistics box.
        if areChecksumFiles(archives) {
            _ = CommandExecutor.run(argv: ["t", "-thash", "--"] + archives, parentWindow: context.window)
            ActiveContext.refresh()
            return
        }

        let options = SZExtractOptions()
        options.testMode = true
        applyZoneMode(options)

        var runnerOptions = OperationRunner.Options(title: Lang.text(3302, "Testing"))
        runnerOptions.initialStatus = .testing
        runnerOptions.parentWindow = context.window
        runnerOptions.titleFileName = archives.count == 1 ? archives[0] : ""

        let window = context.window
        let result = OperationRunner.run(runnerOptions) { runner -> SZExtractResult in
            try SZArchiveExtractor.testArchives(at: archives, options: options, progress: runner)
        }
        // The statistics block is shown as an info box after the progress window closes, and
        // only when there were no errors (01 §8.3 step 4).
        if case .success(let extractResult) = result, let summary = extractResult.testSummary {
            showInfo(summary, parent: window)
        }
        ActiveContext.refresh()
    }

    // MARK: - the file-system path (SZArchiveExtractor over UI/Common/Extract.cpp)

    private static func run(context: OperationContext, destination: Destination,
                            showDialog: Bool, eliminateDuplicateRoot: Bool?) {
        guard let archives = archivePaths(context) else { return }

        let directory = ExtractCommands.normalizeDirectory(context.folderPath)
        var outputDirectory: String
        switch destination {
        case .archiveFolder:
            outputDirectory = directory
        case .subfolderPerArchive:
            if archives.count == 1 {
                outputDirectory = directory + SZArchiveExtractor.subfolderName(
                    forArchiveNamed: (archives[0] as NSString).lastPathComponent) + "/"
            } else {
                outputDirectory = directory + "*/"
            }
        }

        let options = SZExtractOptions()
        options.outDirMode = .replaceAsterisk        // 7zG's default; `*` is per archive
        // CBoolPair: nil = "not defined", so the stored Extraction.ElimDup decides.
        options.eliminateDuplicateRoot = eliminateDuplicateRoot.map { NSNumber(value: $0) }
        applyZoneMode(options)
        // Not forced by the caller, so the stored Extraction.* values win (ZipRegistry.cpp:158-167).
        options.pathMode = SZExtractPathMode(rawValue: Settings.extractPathModeValue) ?? .curPaths
        options.overwriteMode = SZOverwriteMode(rawValue: Settings.extractOverwriteModeValue) ?? .ask
        options.outputDirectory = outputDirectory

        if showDialog {
            var dialogOptions = ExtractDialog.Options()
            dialogOptions.directoryPath = outputDirectory
            dialogOptions.archivePath = archives.count == 1 ? archives[0] : ""
            dialogOptions.pathMode = options.pathMode
            dialogOptions.overwriteMode = options.overwriteMode
            dialogOptions.eliminateDuplicateRoot = eliminateDuplicateRoot
            dialogOptions.summaryLines = itemsInfoLines(context)
            dialogOptions.parentWindow = context.window
            guard let answer = ExtractDialog.run(dialogOptions) else { return }   // Cancel -> E_ABORT
            options.outputDirectory = answer.directoryPath
            options.pathMode = answer.pathMode
            options.overwriteMode = answer.overwriteMode
            options.eliminateDuplicateRoot = answer.eliminateDuplicateRoot.map { NSNumber(value: $0) }
            options.restoreFileSecurity = answer.restoreFileSecurity.map { NSNumber(value: $0) }
            if !answer.password.isEmpty { options.password = answer.password }
            Settings.addToExtractPathHistory(answer.directoryPath)
        }

        // CreateComplexDir before starting, with IDS_CANNOT_CREATE_FOLDER on failure
        // (ExtractGUI.cpp:255-270). A `*` in the path is substituted per archive by the engine,
        // so only an asterisk-free path can be created up front.
        if !options.outputDirectory.contains("*") {
            do {
                try SZArchiveExtractor.createOutputDirectory(options.outputDirectory)
            } catch {
                showError(error.localizedDescription, parent: context.window)
                return
            }
        }

        var runnerOptions = OperationRunner.Options(title: Lang.text(3300, "Extracting"))
        runnerOptions.initialStatus = .extracting
        runnerOptions.parentWindow = context.window
        runnerOptions.titleFileName = archives.count == 1 ? archives[0] : ""
        runnerOptions.password = options.password

        OperationRunner.run(runnerOptions) { runner -> SZExtractResult in
            try SZArchiveExtractor.extractArchives(at: archives, options: options, progress: runner)
        }
        ActiveContext.refresh()
    }

    // MARK: - inside an archive (IArchiveFolder::Extract, the Agent's own path)

    /// 7zFM turns the Extract command inside an archive into `CPanel::OnCopy`, which asks for a
    /// destination and then runs `CAgentFolder::CopyTo` (01 §8.1). The macOS port shows the
    /// Extract dialog instead of the Copy dialog: it is the same question plus the path and
    /// overwrite modes, and it keeps the Extraction.* history in one place. The extraction
    /// itself is the archive folder's own extract path, with kCurPaths (what CopyTo uses).
    private static func extractFromArchiveFolder(_ context: OperationContext) {
        guard !context.indices.isEmpty else { return }
        let archivePath = realFileSystemPath(context.displayPath)
        let proposal = ExtractCommands.normalizeDirectory(
            context.otherPanelPath ?? (archivePath as NSString).deletingLastPathComponent)

        var dialogOptions = ExtractDialog.Options()
        dialogOptions.directoryPath = proposal
        dialogOptions.archivePath = archivePath
        dialogOptions.pathMode = .curPaths          // CAgentFolder::CopyTo
        dialogOptions.overwriteMode = SZOverwriteMode(rawValue: Settings.extractOverwriteModeValue) ?? .ask
        dialogOptions.summaryLines = itemsInfoLines(context)
        dialogOptions.parentWindow = context.window
        guard let answer = ExtractDialog.run(dialogOptions) else { return }
        Settings.addToExtractPathHistory(answer.directoryPath)

        do {
            try SZArchiveExtractor.createOutputDirectory(answer.directoryPath)
        } catch {
            showError(error.localizedDescription, parent: context.window)
            return
        }

        var runnerOptions = OperationRunner.Options(title: Lang.text(3300, "Extracting"))
        runnerOptions.initialStatus = .extracting
        runnerOptions.parentWindow = context.window
        runnerOptions.titleFileName = context.displayPath
        let folder = context.folder
        // CPanel::CopyTo passes fl.Password and writes it back afterwards (PanelCopy.cpp,
        // requests.md navgaps -> extract): the archive level's own password, per level.
        runnerOptions.password = answer.password.isEmpty ? folder.archive?.password : answer.password
        let indices = context.indices.map { NSNumber(value: $0) }
        // The panel showing this archive is parked while the worker uses its folder.
        let parking = PanelViewController.parkPanels(showing: folder)
        OperationRunner.run(runnerOptions) { runner -> SZOperationSummary in
            parking.waitUntilParked()
            defer { PanelViewController.rememberPassword(of: runner, in: folder) }
            // CPanel::CopyTo with NeedRegistryZone (PanelCopy.cpp:188-198): the quarantine of
            // the archive is propagated per Options.WriteZoneIdExtract (01 §9 #23, opsgaps).
            return try folder.extractItems(at: indices, toPath: answer.directoryPath,
                                           pathMode: answer.pathMode, overwriteMode: answer.overwriteMode,
                                           testMode: false, zoneMode: SZFolder.registryZoneMode,
                                           zoneSourcePath: nil, progress: runner)
        }
        parking.release()
        ActiveContext.refresh()
    }

    /// Test inside an archive: `CopyTo` with `testMode = true` (Panel.cpp:1103-1126), then the
    /// same "no errors" summary the FM shows.
    private static func testInsideArchive(_ context: OperationContext) {
        var runnerOptions = OperationRunner.Options(title: Lang.text(3302, "Testing"))
        runnerOptions.initialStatus = .testing
        runnerOptions.parentWindow = context.window
        runnerOptions.titleFileName = context.displayPath

        let folder = context.folder
        runnerOptions.password = folder.archive?.password        // fl.Password, as for Extract
        let indices = context.indices.isEmpty ? nil : context.indices.map { NSNumber(value: $0) }
        let window = context.window
        let parking = PanelViewController.parkPanels(showing: folder)
        let result = OperationRunner.run(runnerOptions) { runner -> SZOperationSummary in
            parking.waitUntilParked()
            defer { PanelViewController.rememberPassword(of: runner, in: folder) }
            return try folder.extractItems(at: indices, toPath: TestSupport.temporaryDirectory,
                                           pathMode: .curPaths, overwriteMode: .skip,
                                           testMode: true, progress: runner)
        }
        parking.release()
        if case .success(let summary) = result, summary.errorCount == 0 {
            // The Agent has no CDecompressStat, so only the file count and the "no errors" line
            // are available here; the full statistics block is the 7zG `t` path above.
            var text = "\(Lang.text(1032, "Files")): \(summary.filesProcessed)\n\n"
            text += Lang.text(3001, "There are no errors")
            showInfo(text, parent: window)
        }
        ActiveContext.refresh()
    }

    // MARK: - helpers

    /// `CPanel::GetFilePaths` + the two preconditions of `CPanel::ExtractArchives`: a
    /// file-system folder, at least one operated item and no directory among them, else
    /// IDS_SELECT_FILES 3015 "Select files" / IDS_OPERATION_IS_NOT_SUPPORTED 6008.
    static func archivePaths(_ context: OperationContext) -> [String]? {
        guard context.isFileSystem else {
            showError(Lang.text(6008, "The operation is not supported for this folder."),
                      parent: context.window)
            return nil
        }
        let paths = context.paths
        guard !paths.isEmpty else {
            showError(Lang.text(3015, "Select files"), parent: context.window)
            return nil
        }
        let fm = FileManager.default
        for path in paths {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                showError(Lang.text(3015, "Select files"), parent: context.window)
                return nil
            }
        }
        return paths
    }

    /// True when every path has one of the hash pseudo-format's extensions (`.sha256`, `.md5`, ...,
    /// `SZCodecs.format(named: "hash")`), i.e. the items C13 would verify.
    static func areChecksumFiles(_ paths: [String]) -> Bool {
        guard !paths.isEmpty, let hash = SZCodecs.format(named: "hash") else { return false }
        let extensions = Set(hash.extensions.map { $0.lowercased() })
        return paths.allSatisfy { extensions.contains(($0 as NSString).pathExtension.lowercased()) }
    }

    /// Options.WriteZoneIdExtract -> `-snz<N>` on every extract command (03 §1.3). On macOS the
    /// Zone.Identifier stream is the com.apple.quarantine xattr (01 §9 #23).
    private static func applyZoneMode(_ options: SZExtractOptions) {
        switch Settings.writeZoneIdExtract {
        case 1: options.zoneIDMode = .all
        case 2: options.zoneIDMode = .office
        default: options.zoneIDMode = .none      // -1 (unset) and 0 both mean "no"
        }
    }

    static func normalizeDirectory(_ path: String) -> String {
        if path.isEmpty { return path }
        return path.hasSuffix("/") ? path : path + "/"
    }

    /// Reduce_Path_To_RealFileSystemPath (App.cpp:420): walk up an address-bar path such as
    /// "/a/b/test.7z/sub/" until a component exists on disk. Used to recover the archive file
    /// from an archive folder's display path without touching the panel's folder object.
    static func realFileSystemPath(_ displayPath: String) -> String {
        var path = displayPath
        while path.hasSuffix("/") { path.removeLast() }
        let fm = FileManager.default
        while !path.isEmpty, path != "/" {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue {
                return path
            }
            path = (path as NSString).deletingLastPathComponent
        }
        return displayPath
    }

    /// `CApp::GetItemsInfoString` (App.cpp:500-547): up to kCopyDialog_NumInfoLines = 11 item
    /// names, then the Folders / Files / Size totals.
    static func itemsInfoLines(_ context: OperationContext) -> [String] {
        let maxLines = 11
        var lines = Array(context.names.prefix(maxLines))
        if context.names.count > maxLines { lines.append("...") }

        // Sizes come from the file system for an FS folder; inside an archive the panel's
        // folder object would have to be queried off-queue, so only the counts are shown.
        if context.isFileSystem {
            var total: UInt64 = 0
            var files = 0
            var folders = 0
            let fm = FileManager.default
            for path in context.paths {
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    folders += 1
                } else {
                    files += 1
                    if let size = (try? fm.attributesOfItem(atPath: path)[.size]) as? NSNumber {
                        total += size.uint64Value
                    }
                }
            }
            if folders > 0 { lines.append("\(Lang.text(1031, "Folders")): \(folders)") }
            lines.append("\(Lang.text(1032, "Files")): \(files)")
            lines.append("\(Lang.text(1007, "Size")): \(Formatting.size(total))")
        } else {
            lines.append("\(Lang.text(1032, "Files")): \(context.indices.count)")
        }
        return lines
    }

    private static func showError(_ text: String, parent: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "7-Zip"
        alert.informativeText = text
        alert.addButton(withTitle: Lang.text(401, "OK"))
        if let parent { alert.beginSheetModal(for: parent, completionHandler: nil) } else { alert.runModal() }
    }

    private static func showInfo(_ text: String, parent: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "7-Zip"
        alert.informativeText = text
        alert.addButton(withTitle: Lang.text(401, "OK"))
        alert.runModal()
    }
}

// MARK: - menu / toolbar selectors

extension MainWindowController {

    /// kMenuCmdID_Toolbar_Extract 1071 (toolbar "Extract") and the File > 7-Zip >
    /// "Extract files..." item (kExtract, context-menu id kSevenZipStartMenuID + 2).
    @objc func toolbarExtractArchives(_ sender: Any?) { ExtractCommands.extractWithDialog() }

    /// kExtractHere -- IDS_CONTEXT_EXTRACT_HERE 2326 "Extract Here".
    @objc func extractHere(_ sender: Any?) { ExtractCommands.extractHere() }

    /// kExtractTo -- IDS_CONTEXT_EXTRACT_TO 2327 `Extract to "{0}"`.
    @objc func extractToSubfolder(_ sender: Any?) { ExtractCommands.extractToSubfolder() }

    /// kMenuCmdID_Toolbar_Test 1072 (toolbar "Test") / kTest IDS_CONTEXT_TEST 2325.
    @objc func toolbarTestArchives(_ sender: Any?) { ExtractCommands.testArchives() }
}

// MARK: - dynamic menu titles

/// Fills `{0}` in IDS_CONTEXT_EXTRACT_TO 2327 with the sub-folder name of the current
/// selection, which `CZipContextMenu::QueryContextMenu` computes while building the menu
/// (ContextMenu.cpp:836, `specFolder = GetSubFolderNameForExtract(fi0.Name)`; `*` when more
/// than one item is selected). Installed as the delegate of the File > 7-Zip submenu.
final class ExtractMenuTitles: NSObject, NSMenuDelegate {

    static let shared = ExtractMenuTitles()

    /// Menu item tag of the "Extract to ..." item (= its lang ID).
    private static let extractToTag = 2327

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let item = menu.items.first(where: { $0.tag == Self.extractToTag }) else { return }
        let template = Lang.text(UInt32(Self.extractToTag), "Extract to {0}")
        var name = "*"
        if let context = ActiveContext.current(), context.isFileSystem, context.names.count == 1 {
            name = SZArchiveExtractor.subfolderName(forArchiveNamed: context.names[0])
        }
        item.title = Lang.format(template, "\"\(name)/\"")
    }
}

// MARK: - verification hook (this scope's stand-in for the panel's context provider)

/// Lets the extract commands be driven before the `panel` scope registers the real
/// `OperationContextProviding`, so this scope can be verified in the running app:
///
///   SEVENZIP_DEFAULTS_SUITE=7zip-extract SZ_EXTRACT_CONTEXT=<folder or archive path> \
///   SZ_EXTRACT_SELECT=readme.txt,notes.md  7-Zip.app/Contents/MacOS/7-Zip
///
/// With no `SZ_EXTRACT_SELECT` every item of the folder is operated on. Not part of the shipping
/// UI: without the variable nothing is installed and `ActiveContext` stays untouched.
final class ExtractVerificationContext: NSObject, OperationContextProviding {

    private let folder: SZFolder
    private let path: String
    private var indices: [Int] = []
    /// ActiveContext.provider is weak (the panel owns the real one), so the stand-in has to be
    /// kept alive here.
    private static var installed: ExtractVerificationContext?

    static func installIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["SZ_EXTRACT_CONTEXT"], !path.isEmpty else { return }
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification,
                                              object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let provider = ExtractVerificationContext(
                    path: path, selection: environment["SZ_EXTRACT_SELECT"]) else {
                    NSLog("extract-verify: cannot open %@", path)
                    return
                }
                installed = provider
                ActiveContext.register(provider)
                NSLog("extract-verify: context = %@ (%ld items operated)", path, provider.indices.count)
            }
        }
    }

    private init?(path: String, selection: String?) {
        guard let folder = try? SZFolder.folder(forPath: path, passwordDelegate: nil) else { return nil }
        self.folder = folder
        self.path = path
        super.init()
        try? folder.loadItems()
        let wanted = (selection?.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) ?? []
        for i in 0..<folder.itemCount {
            if wanted.isEmpty || wanted.contains(folder.nameOfItem(at: i)) { indices.append(i) }
        }
    }

    func currentOperationContext() -> OperationContext? {
        let names = indices.map { folder.nameOfItem(at: $0) }
        let isFileSystem = folder.isFileSystem
        let folderPath = isFileSystem ? ExtractCommands.normalizeDirectory(folder.path) : ""
        let paths = isFileSystem ? names.map { (folderPath as NSString).appendingPathComponent($0) } : []
        return OperationContext(folder: folder,
                                displayPath: folder.fullPath,
                                isArchive: folder.isArchive,
                                isFileSystem: isFileSystem,
                                indices: indices,
                                names: names,
                                paths: paths,
                                folderPath: folderPath,
                                otherPanelPath: nil,
                                window: NSApp.mainWindow)
    }

    func refreshAfterOperation() { NSLog("extract-verify: refreshAfterOperation") }
    func refreshAllPanels() { NSLog("extract-verify: refreshAllPanels") }
}
