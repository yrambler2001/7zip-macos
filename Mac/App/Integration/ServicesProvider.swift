// ServicesProvider.swift -- the classic `NSServices` route (03-shell-integration-inventory.md
// section 6.1 "NSServices", section 6.3 recommendation 2).
//
// Services are the fallback that needs **no** extension enabled and no sandbox hop: Finder (and
// every other app) puts the entries in its contextual menu > Services and in the app menu >
// Services, and AppKit delivers the pasteboard straight to the running host app. The items are the
// same commands as the Finder Sync menu, built by the same `FinderMenuModel`, so the naming rules
// (`GetSubFolderNameForExtract`, `CreateArchiveName`) and the generated switches cannot drift.
//
// The `NSMessage` names below must match `NSServices` in `Mac/App/Info.plist`.

import AppKit
import os

private let servicesLog = Logger(subsystem: "com.yrambler2001.7zip", category: "Services")

final class ServicesProvider: NSObject {

    static let shared = ServicesProvider()

    // MARK: - The five services

    /// "7-Zip: Extract files…"  -> `x -o"<dir><spec>/" -ad -an -ai…`
    @objc func sevenZipExtractFiles(_ pasteboard: NSPasteboard, userData: String?,
                                    error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        perform(verb: "SevenZipExtract", pasteboard: pasteboard, error: error)
    }

    /// "7-Zip: Extract Here"  -> `x -o"<dir>" -an -ai…`
    @objc func sevenZipExtractHere(_ pasteboard: NSPasteboard, userData: String?,
                                   error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        perform(verb: "SevenZipExtractHere", pasteboard: pasteboard, error: error)
    }

    /// "7-Zip: Test archive"  -> `t -an -ai…`
    @objc func sevenZipTestArchive(_ pasteboard: NSPasteboard, userData: String?,
                                   error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        perform(verb: "SevenZipTest", pasteboard: pasteboard, error: error)
    }

    /// "7-Zip: Add to archive…"  -> `a -i… -ad -saa -- "<dir><name>"`
    @objc func sevenZipAddToArchive(_ pasteboard: NSPasteboard, userData: String?,
                                   error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        perform(verb: "SevenZipCompress", pasteboard: pasteboard, error: error)
    }

    /// "7-Zip: Checksum…"  -> `h -scrc* -i…`, the `*` entry of the CRC SHA submenu.
    @objc func sevenZipChecksum(_ pasteboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        perform(verb: FinderMenuModel.checksumCascadedVerb + ".Calc.*",
                pasteboard: pasteboard, error: error)
    }

    // MARK: - Shared body

    /// Reads the file URLs off the pasteboard, asks `FinderMenuModel` for the command with that
    /// verb and runs it through the one executor.
    private func perform(verb: String, pasteboard: NSPasteboard,
                         error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let selection = ServicesProvider.selection(from: pasteboard)
        guard !selection.isEmpty else {
            // IDS_SELECT_FILES 3015, the same refusal the shell extension shows.
            error.pointee = Lang.text(3015, "You must select one or more files") as NSString
            return
        }
        guard let command = FinderMenuModel.command(verb: verb, selection: selection,
                                                   settings: FinderSettingsBridge.snapshot()) else {
            error.pointee = Lang.text(6008, "The operation is not supported for this folder.") as NSString
            return
        }
        if command.refusesDirectories, selection.firstDirectoryIndex != -1 {
            error.pointee = Lang.text(3015, "You must select one or more files") as NSString
            return
        }
        let built = command.argv(for: selection.paths)
        // sec113: any process can invoke a service (`NSPerformService`) with a pasteboard of its
        // choosing, a sandboxed one included. The command is the menu's own, but the items are
        // not the user's choice then, so the same target checks as a URL apply: nothing in
        // `~/Library` or a system folder, no symbolic link that leads there (`URLCommandPolicy`).
        let checked: (argv: [String], temporaryFiles: [String])
        switch URLCommandPolicy.standard().evaluate(argv: built.argv, temporaryFiles: built.temporaryFiles) {
        case .refuse(let reason):
            CommandURL.removeTemporaryFiles(built.temporaryFiles)
            servicesLog.error("refused service \(verb, privacy: .public): \(reason, privacy: .public)")
            error.pointee = URLCommandPolicy.refusalMessage as NSString
            return
        case .allow(let argv, let temporaryFiles):
            checked = (argv, temporaryFiles)
        }
        // 7zG mode (GMode.swift): its own windows, not a file-manager window's sheets.
        GMode.submit {
            _ = GMode.run {
                CommandExecutor.run(argv: checked.argv, temporaryFiles: checked.temporaryFiles, parentWindow: nil)
            }
        }
    }

    /// `NSPasteboard` -> `FinderSelection`. The host app is not sandboxed, so `isDirectory` can be
    /// read from disk here; the Finder Sync extension uses the URL's trailing slash instead.
    static func selection(from pasteboard: NSPasteboard) -> FinderSelection {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        let paths = urls.map(\.path)
        let flags = paths.map { path -> Bool in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return false }
            return isDir.boolValue
        }
        return FinderSelection(paths: paths, directoryFlags: flags)
    }
}
