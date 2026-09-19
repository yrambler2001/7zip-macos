// CompressCommands.swift -- the commands that create and update archives.
//
// * the toolbar "Add" button (kMenuCmdID_Toolbar_Add 1070) -> `CPanel::AddToArchive`
//   (Panel.cpp:922-958, 01-fm-feature-inventory.md section 8.1): file-system panels only,
//   destination = the current folder, name = `CreateArchiveName(operated items)`, dialog shown;
// * the Explorer quick commands `CompressTo7z` / `CompressToZip` (+ their email variants,
//   ContextMenu.cpp:1297-1339, 03-shell-integration-inventory.md section 1.6): no dialog, the
//   default name plus the format's extension, `addExtension = false`;
// * "Compress and email" (`-seml`, 01 section 8.5 step 4 / section 9 #22): the archive is built
//   in a fresh temp folder and handed to `NSSharingService.composeEmail`;
// * adding files to the archive an open panel is already inside.
//
// Everything runs under `OperationRunner` (Mac/docs/api/opsinfra.md section 5) with the
// progress title IDS_PROGRESS_COMPRESSING 3301 and the Packed size / Ratio rows, like
// `CThreadUpdating` under `CProgressDialog` (UpdateGUI.cpp:579).

import AppKit
import SevenZipKit

// ---------------------------------------------------------------------------

extension MainWindowController {

    /// Toolbar "Add" (kMenuCmdID_Toolbar_Add 1070). `CPanel::AddToArchive`.
    @objc func toolbarAddToArchive(_ sender: Any?) {
        CompressCommands.addToArchive(showDialog: true, email: false)
    }

    /// "Compress to <name>.7z" — the Explorer quick command, no dialog.
    @objc func compressToSevenZip(_ sender: Any?) {
        CompressCommands.compressTo(formatName: "7z", email: false)
    }

    /// "Compress to <name>.zip".
    @objc func compressToZip(_ sender: Any?) {
        CompressCommands.compressTo(formatName: "zip", email: false)
    }

    /// "Compress and email..." — the dialog, then the system mail composer.
    @objc func compressAndEmail(_ sender: Any?) {
        CompressCommands.addToArchive(showDialog: true, email: true)
    }

    /// "Compress to <name>.7z and email".
    @objc func compressToSevenZipAndEmail(_ sender: Any?) {
        CompressCommands.compressTo(formatName: "7z", email: true)
    }

    /// "Compress to <name>.zip and email".
    @objc func compressToZipAndEmail(_ sender: Any?) {
        CompressCommands.compressTo(formatName: "zip", email: true)
    }

    /// Add files from outside into the archive the active panel is inside.
    @objc func compressAddToOpenArchive(_ sender: Any?) {
        CompressCommands.addFilesToOpenArchive()
    }
}

// ---------------------------------------------------------------------------

enum CompressCommands {

    // MARK: - Add to archive (the dialog path)

    /// `CompressFiles(prefix, CreateArchiveName(paths), "", addExtension: true, paths, email,
    /// showDialog: true, waitFinish: false)`.
    static func addToArchive(showDialog: Bool, email: Bool, forcedFormatName: String? = nil) {
        guard let context = ActiveContext.current() else { return }
        guard let paths = operatedFileSystemPaths(context) else { return }

        var base = SZUpdater.archiveBaseName(forItemPaths: paths, isHash: false, baseName: nil)
        var directory = context.folderPath
        if email {
            // The archive must not land in the browsed folder: 7zG builds it in a temp dir and
            // deletes it afterwards (`-seml.`). macOS cannot delete it synchronously, so the
            // folder is purged on the next compress-and-email (01 section 9 #22).
            purgeStaleEmailDirectories()
            guard let temp = makeEmailDirectory() else { return }
            directory = temp
        }
        if directory.isEmpty { directory = NSHomeDirectory() }
        if !directory.hasSuffix("/") { directory += "/" }

        var input = CompressDialogInput()
        input.directoryPrefix = directory
        input.archiveBaseName = (directory as NSString).appendingPathComponent(base)
        input.itemPaths = paths
        input.forcedFormatName = forcedFormatName
        input.parentWindow = context.window
        input.isUpdatingExistingArchive = false

        guard showDialog else {
            // Without a dialog the name already carries its extension.
            if let format = forcedFormatName.flatMap({ SZCodecs.format(named: $0) }) {
                base += "." + format.mainExtension
            }
            let path = (directory as NSString).appendingPathComponent(base)
            runQuickUpdate(archivePath: path, formatName: forcedFormatName ?? "7z",
                           sourcePaths: paths, email: email, context: context)
            return
        }

        guard let result = CompressDialogController.run(input) else { return }   // Cancel = E_ABORT
        run(result, sourcePaths: paths, email: email, context: context)
    }

    // MARK: - Quick commands (no dialog)

    /// `CompressTo7z` / `CompressToZip`: `<CreateArchiveName>.<ext>` in the current folder, the
    /// stored per-format options, no dialog (ContextMenu.cpp:1303-1339).
    static func compressTo(formatName: String, email: Bool) {
        guard let context = ActiveContext.current() else { return }
        guard let paths = operatedFileSystemPaths(context) else { return }
        guard let format = SZCodecs.format(named: formatName), format.updateEnabled else {
            showError(Lang.text(3007, "Unsupported archive type"), parent: context.window)  // IDS_UNSUPPORTED_ARCHIVE_TYPE
            return
        }
        var directory = context.folderPath
        if email {
            purgeStaleEmailDirectories()
            guard let temp = makeEmailDirectory() else { return }
            directory = temp
        }
        if directory.isEmpty { directory = NSHomeDirectory() }
        let base = SZUpdater.archiveBaseName(forItemPaths: paths, isHash: false, baseName: nil)
        let path = (directory as NSString).appendingPathComponent(base + "." + format.mainExtension)
        runQuickUpdate(archivePath: path, formatName: format.name, sourcePaths: paths,
                       email: email, context: context)
    }

    /// The quick path builds its `-m` list from the stored per-format options only, the way
    /// 7zG does when no dialog is shown (`options.MethodMode.Properties` stays as parsed from
    /// the command line, i.e. empty, and the handler applies its own defaults).
    private static func runQuickUpdate(archivePath: String, formatName: String,
                                       sourcePaths: [String], email: Bool,
                                       context: OperationContext) {
        var result = CompressDialogResult()
        result.archivePath = archivePath
        result.formatName = formatName
        result.formatIndex = SZCodecs.format(named: formatName)?.index ?? -1
        result.level = -1                 // nothing emitted: the handler's own default
        run(result, sourcePaths: sourcePaths, email: email, context: context)
    }

    // MARK: - Adding to an archive the panel is inside

    /// Asks for files and adds them to the archive the active panel shows. At the archive root
    /// this is `SZUpdater.addPaths(_:toArchiveAt:)` (the engine's in-place update); inside a
    /// sub-folder it is the Agent's `IFolderOperations::CopyFrom`, which is what 7zFM's
    /// drag-into-an-archive does (01 section 3.10).
    static func addFilesToOpenArchive() {
        guard let context = ActiveContext.current(), context.isArchive else {
            if let window = ActiveContext.current()?.window {
                showError(Lang.text(6008, "The operation is not supported for this folder."),
                          parent: window)
            }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = Lang.text(7200, "Add")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addFiles(panel.urls.map(\.path), to: context)
    }

    /// Adds `paths` to the archive `context` is inside. Public so the panel's drag-and-drop and
    /// the `finder` scope can reuse it.
    static func addFiles(_ paths: [String], to context: OperationContext) {
        guard context.isArchive, let archive = context.folder.archive else { return }
        let archivePath = archive.path
        let internalPath = context.folder.path

        var options = OperationRunner.Options(title: Lang.text(3301, "Compressing"))
        options.initialStatus = .compressing
        options.showCompressionInfo = true
        options.titleFileName = archivePath
        options.parentWindow = context.window
        options.asksPasswordForEncryption = true

        let folder = context.folder
        let outcome: Result<Void, Error>
        if internalPath.isEmpty {
            outcome = OperationRunner.run(options) { runner in
                _ = try SZUpdater.addPaths(paths, toArchiveAt: archivePath, options: nil,
                                           progress: runner)
            }
        } else {
            // CopyFrom wants names relative to one folder; group by parent directory.
            let groups = Dictionary(grouping: paths) { ($0 as NSString).deletingLastPathComponent }
            outcome = OperationRunner.run(options) { runner in
                for (directory, members) in groups {
                    try folder.copyItems(named: members.map { ($0 as NSString).lastPathComponent },
                                         fromFolderPath: directory, moveMode: false, progress: runner)
                }
            }
        }
        if case .success = outcome { ActiveContext.refreshAll() }
    }

    // MARK: - Running an update

    /// Runs the update the dialog (or a quick command) asked for, then refreshes the panel and,
    /// in email mode, opens the mail composer.
    static func run(_ result: CompressDialogResult, sourcePaths: [String], email: Bool,
                    context: OperationContext) {
        let updateOptions = result.updateOptions()
        updateOptions.emailMode = email
        updateOptions.emailRemoveAfter = email
        if email && !updateOptions.volumeSizes.isEmpty {
            // Update.cpp:1164 refuses the combination; 7zG shows the error before starting.
            showError("Splitting to volumes is not supported in email mode", parent: context.window)
            return
        }

        var options = OperationRunner.Options(
            title: result.formatName.caseInsensitiveCompare("hash") == .orderedSame
                ? Lang.text(7500, "Checksum calculating...")        // IDS_CHECKSUM_CALCULATING
                : Lang.text(3301, "Compressing"))                   // IDS_PROGRESS_COMPRESSING
        options.initialStatus = .compressing
        options.showCompressionInfo = true                          // Packed size / Ratio rows
        options.titleFileName = result.archivePath
        options.parentWindow = context.window
        options.asksPasswordForEncryption = true
        options.showsEncryptFileNames = result.encryptHeadersIsAllowed
        options.password = result.password

        let outcome = OperationRunner.run(options) { runner -> SZUpdateResult in
            try SZUpdater.update(with: updateOptions, sourcePaths: sourcePaths, progress: runner)
        }

        switch outcome {
        case .success(let updateResult):
            // Failed files mean exit code 1 (kWarning, 03 section 2.3): the Progress dialog has
            // already listed them, so only the panel refresh is left.
            ActiveContext.refreshAll()
            if email { compose(email: updateResult.archivePath, address: nil) }
        case .failure:
            // OperationRunner already showed the alert (E_ABORT is silent).
            ActiveContext.refreshAll()
        }
    }

    // MARK: - Email

    /// `SendMailAttachment` (Update.cpp:1700-1850) replaced by the system sharing service
    /// (03 section 2.5, section 6.2).
    static func compose(email archivePath: String, address: String?) {
        guard FileManager.default.fileExists(atPath: archivePath) else { return }
        guard let service = NSSharingService(named: .composeEmail) else {
            showError("No mail application is configured", parent: nil)
            return
        }
        if let address, !address.isEmpty { service.recipients = [address] }
        let url = URL(fileURLWithPath: archivePath)
        if service.canPerform(withItems: [url]) {
            service.perform(withItems: [url])
        } else {
            // Nothing can compose mail: at least reveal the archive so it can be attached.
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// A fresh `7zE-<uuid>` folder in the system temp directory, like 7zG's email mode.
    static func makeEmailDirectory() -> String? {
        let path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("7zE-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            return path
        } catch {
            showError(Lang.format(Lang.text(3003, "Cannot create folder '{0}'"), path), parent: nil)  // IDS_CANNOT_CREATE_FOLDER
            return nil
        }
    }

    /// `EMailRemoveAfter` cannot be honoured synchronously (the mail app still needs the file),
    /// so yesterday's `7zE-*` folders are removed instead (01 section 9 #22).
    static func purgeStaleEmailDirectories() {
        let fm = FileManager.default
        let temp = NSTemporaryDirectory()
        guard let entries = try? fm.contentsOfDirectory(atPath: temp) else { return }
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        for entry in entries where entry.hasPrefix("7zE-") {
            let path = (temp as NSString).appendingPathComponent(entry)
            let created = (try? fm.attributesOfItem(atPath: path)[.creationDate] as? Date) ?? nil
            if let created, created > cutoff { continue }
            try? fm.removeItem(atPath: path)
        }
    }

    // MARK: - Helpers

    /// The operated items as file-system paths, with 7zFM's two refusals:
    /// not a file-system folder -> `MessageBox_Error_UnsupportOperation`, nothing selected ->
    /// IDS_SELECT_FILES 3008 (Panel.cpp:922-935).
    static func operatedFileSystemPaths(_ context: OperationContext) -> [String]? {
        guard context.isFileSystem else {
            showError(Lang.text(6008, "The operation is not supported for this folder."),
                      parent: context.window)
            return nil
        }
        let paths = context.paths.filter { !$0.isEmpty }
        guard !paths.isEmpty else {
            showError(Lang.text(3015, "Select files"), parent: context.window)   // IDS_SELECT_FILES
            return nil
        }
        return paths
    }

    static func showError(_ text: String, parent: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "7-Zip"
        alert.informativeText = text
        if let parent {
            alert.beginSheetModal(for: parent, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
