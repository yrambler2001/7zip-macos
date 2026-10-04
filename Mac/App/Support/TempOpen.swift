// TempOpen.swift -- opening, viewing, editing and diffing an item, including the temp-folder
// round trip for items that live inside an archive.
//
// Windows equivalents (01-fm-feature-inventory.md §3.9, §3.11, §9 #10, #11, #27;
// PROGRESS.md §4.6):
//
//   CPanel::OpenItemInArchive(index, tryInternal, tryExternal, editMode, type)
//       PanelItemOpen.cpp:1484-1803 -- extract to <Temp>/7zO<hex>/, warn when the archive is
//       read-only and editMode is on, IsVirus_Message, then StartEditApplication /
//       StartApplication, then the watcher.
//   MyThreadFunction (PanelItemOpen.cpp ~1110-1330) -- waits for the launched process, compares
//       size + mtime with CTempFileInfo, asks IDS_WANT_UPDATE_MODIFIED_FILE 3009 and calls
//       IFolderOperations::CopyFromFile on Yes, IDS_CANNOT_UPDATE_FILE 3010 on failure, then
//       deletes the temp folder.
//   CApp::DiffFiles (PanelItemOpen.cpp:747-815).
//
// On macOS the process wait is replaced by NSRunningApplication termination observation **plus**
// a DispatchSource write/rename watcher on the temp file (01 §9 #11), so a save is noticed even
// when the editor keeps running or was already open.

import AppKit
import SevenZipKit

// MARK: - the external tools (Options > Editor page: FM.Viewer / FM.Editor / FM.Diff)

/// StartEditApplication / StartApplication (PanelItemOpen.cpp:719, :867). A setting may be an
/// `.app` bundle, an executable, or a command line; empty falls back to Quick Look (viewer) or
/// TextEdit (editor), per 01 §9 #10.
enum ExternalTool {

    enum Kind {
        case viewer, editor, diff

        var configuredPath: String {
            switch self {
            case .viewer: return Settings.viewerPath
            case .editor: return Settings.editorPath
            case .diff: return Settings.diffPath
            }
        }
    }

    /// SplitCmdLineSmart: the program part and its leading arguments.
    static func splitCommandLine(_ command: String) -> (program: String, arguments: [String]) {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") {
            let rest = trimmed.dropFirst()
            if let end = rest.firstIndex(of: "\"") {
                let program = String(rest[rest.startIndex..<end])
                let tail = String(rest[rest.index(after: end)...])
                return (program, tail.split(separator: " ").map(String.init))
            }
        }
        // An existing path wins over a space split, so "/Applications/My App.app" works.
        if FileManager.default.fileExists(atPath: trimmed) { return (trimmed, []) }
        var parts = trimmed.split(separator: " ").map(String.init)
        guard let program = parts.first else { return (trimmed, []) }
        parts.removeFirst()
        return (program, parts)
    }

    /// Runs `kind` on `paths`. Returns false when nothing could be started, which the caller
    /// reports with IDS_CANNOT_START_EDITOR 3011.
    @discardableResult
    static func open(_ paths: [String], with kind: Kind,
                     completion: ((NSRunningApplication?) -> Void)? = nil) -> Bool {
        let configured = kind.configuredPath
        let urls = paths.map { URL(fileURLWithPath: $0) }

        if configured.isEmpty {
            switch kind {
            case .viewer:
                // Default viewer = Quick Look (01 §9 #10). `qlmanage -p` is the scriptable
                // equivalent of QLPreviewPanel and works from a non-document app.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/qlmanage")
                process.arguments = ["-p"] + paths
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { return openWithSystemDefault(urls, completion: completion) }
                completion?(nil)
                return true
            case .editor:
                return open(urls, withApplicationNamed: "TextEdit", completion: completion)
            case .diff:
                return false                 // IDM_DIFF is hidden without a configured tool
            }
        }

        let (program, leadingArguments) = splitCommandLine(configured)
        if program.hasSuffix(".app") || program.hasSuffix(".app/") {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = leadingArguments
            NSWorkspace.shared.open(urls, withApplicationAt: URL(fileURLWithPath: program),
                                    configuration: configuration) { app, _ in
                DispatchQueue.main.async { completion?(app) }
            }
            return true
        }
        if FileManager.default.isExecutableFile(atPath: program) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: program)
            process.arguments = leadingArguments + paths
            do { try process.run() } catch { return false }
            completion?(nil)
            return true
        }
        // Not a path: treat it as an application name ("TextEdit", "BBEdit").
        return open(urls, withApplicationNamed: program, completion: completion)
    }

    private static func open(_ urls: [URL], withApplicationNamed name: String,
                             completion: ((NSRunningApplication?) -> Void)?) -> Bool {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: name)
                ?? applicationURL(named: name) else {
            return openWithSystemDefault(urls, completion: completion)
        }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { app, _ in
            DispatchQueue.main.async { completion?(app) }
        }
        return true
    }

    private static func applicationURL(named name: String) -> URL? {
        let candidates = ["/System/Applications/\(name).app", "/Applications/\(name).app"]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// StartApplication: the shell "open" verb (NSWorkspace.open).
    @discardableResult
    static func openWithSystemDefault(_ urls: [URL],
                                      completion: ((NSRunningApplication?) -> Void)? = nil) -> Bool {
        guard let first = urls.first else { return false }
        if urls.count == 1 {
            NSWorkspace.shared.open(first, configuration: NSWorkspace.OpenConfiguration()) { app, _ in
                DispatchQueue.main.async { completion?(app) }
            }
            return true
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: first) else { return false }
        NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration()) { app, _ in
            DispatchQueue.main.async { completion?(app) }
        }
        return true
    }
}

// MARK: - the virus-name check (IsVirus_Message, PanelItemOpen.cpp:867)

enum SuspiciousName {

    /// kExeExtensions (PanelItemOpen.cpp:629) plus the macOS executables of 01 §9 #27.
    static let executableExtensions = ["exe", "bat", "ps1", "com", "lnk",
                                       "app", "command", "sh", "pkg", "dmg"]

    /// True when the name hides its real extension behind many spaces, a right-to-left override,
    /// or trailing dots/spaces. The caller then asks IDS_VIRUS 3012 before launching.
    static func looksDangerous(_ name: String) -> Bool {
        if name.contains("\u{202E}") || name.contains("\u{202D}") || name.contains("\u{202B}") || name.contains("\u{202A}") { return true }
        if name.contains("     ") { return true }               // 5+ consecutive spaces
        var trimmed = name
        while let last = trimmed.last, last == "." || last == " " { trimmed.removeLast() }
        if trimmed != name {
            let ext = (trimmed as NSString).pathExtension.lowercased()
            if executableExtensions.contains(ext) { return true }
        }
        return false
    }

    /// IsVirus_Message (PanelItemOpen.cpp:944-967): 7zFM 26.03 does not ask -- it shows IDS_VIRUS
    /// 3012 with MessageBox_Error ("7-Zip", MB_ICONSTOP), the cleaned-up name and the name, and
    /// does not open the file. Always false (the caller stops); kept as "confirm" for its callers.
    static func confirm(_ name: String, parent: NSWindow?) -> Bool {
        WinMessageBox.run(message(for: name), icon: .error, owner: parent)
        return false
    }

    /// The text of that box: without the "(...)" reason unless the name has 5+ spaces in a row,
    /// then name2 (runs of spaces cut to one, RLO shown as "[RLO]", trailing dots and spaces as
    /// "_") and the name itself.
    static func message(for name: String) -> String {
        var s = Lang.text(3012, "The file looks like a virus (the file name contains long spaces in name).")
        let isSpaceError = name.contains("     ")
        if !isSpaceError, let open = s.firstIndex(of: "("), let close = s[open...].firstIndex(of: ")") {
            var start = open
            if start > s.startIndex, s[s.index(before: start)] == " " { start = s.index(before: start) }
            s.removeSubrange(start...close)
        }
        var name2 = ""
        var spaces = 0
        for c in name {
            spaces = c == " " ? spaces + 1 : 0
            if spaces <= 1 { name2.append(c) }
        }
        name2 = name2.replacingOccurrences(of: "\u{202E}", with: "[RLO]")
        var chars = Array(name2)
        var i = chars.count
        while i > 0, chars[i - 1] == "." || chars[i - 1] == " " { i -= 1; chars[i] = "_" }
        name2 = String(chars)
        let name3 = name.replacingOccurrences(of: "\n", with: "_")
        return s + "\n" + name2.replacingOccurrences(of: "\n", with: "_") + "\n" + name3
    }
}

// MARK: - one open item and its watcher

/// CTempFileInfo + the watcher thread of PanelItemOpen.cpp, as one object.
final class TempOpenSession: NSObject {

    let tempFile: SZTempFile
    private let folder: SZFolder
    private let archiveIsReadOnly: Bool
    private let displayPath: String
    private weak var window: NSWindow?

    private var fileDescriptor: CInt = -1
    private var watcher: DispatchSourceFileSystemObject?
    private var applicationObserver: NSObjectProtocol?
    private var launched: NSRunningApplication?
    private var finished = false
    private var changeSeen = false

    init(tempFile: SZTempFile, folder: SZFolder, archiveIsReadOnly: Bool,
         displayPath: String, window: NSWindow?) {
        // NSObject so the change-coalescing perform(_:with:afterDelay:) is available.
        self.tempFile = tempFile
        self.folder = folder
        self.archiveIsReadOnly = archiveIsReadOnly
        self.displayPath = displayPath
        self.window = window
        super.init()
    }

    /// Starts the watcher: a DispatchSource on the file plus, when we know which application was
    /// launched, its termination.
    func startWatching(launchedApplication: NSRunningApplication?) {
        launched = launchedApplication
        fileDescriptor = open(tempFile.filePath, O_EVTONLY)
        if fileDescriptor >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor, eventMask: [.write, .rename, .delete, .extend],
                queue: .main)
            source.setEventHandler { [weak self] in self?.fileDidChange() }
            source.setCancelHandler { [weak self] in
                guard let self, self.fileDescriptor >= 0 else { return }
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
            source.resume()
            watcher = source
        }
        if let app = launchedApplication {
            applicationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                queue: .main) { [weak self] note in
                    guard let self,
                          let terminated = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                            as? NSRunningApplication,
                          terminated.processIdentifier == app.processIdentifier else { return }
                    self.applicationDidTerminate()
                }
        }
    }

    /// A save arrived while the application is still running: offer the update right away, the
    /// way Windows does when the process exits.
    private func fileDidChange() {
        guard !finished else { return }
        changeSeen = true
        // Coalesce the burst of write events an editor produces.
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(settle), object: nil)
        perform(#selector(settle), with: nil, afterDelay: 0.6)
    }

    @objc private func settle() {
        guard !finished, tempFile.wasModified else { return }
        offerUpdate(finishAfterwards: false)
    }

    private func applicationDidTerminate() {
        guard !finished else { return }
        if tempFile.wasModified {
            offerUpdate(finishAfterwards: true)
        } else {
            finish()
        }
    }

    /// IDS_WANT_UPDATE_MODIFIED_FILE 3009 -> CopyFromFile under the Progress dialog.
    private func offerUpdate(finishAfterwards: Bool) {
        if archiveIsReadOnly {
            // Step 3 of OpenItemInArchive: a read-only archive cannot take the change back.
            showError(Lang.format(Lang.text(3010, "Cannot update file '{0}'"), tempFile.itemName))
            if finishAfterwards { finish() }
            return
        }
        // PanelItemOpen.cpp:1282: "7-Zip", MB_YESNOCANCEL | MB_ICONQUESTION; only Yes updates.
        let question = Lang.format(
            Lang.text(3009, "File '{0}' was modified.\nDo you want to update it in the archive?"),
            tempFile.itemName)
        guard WinMessageBox.run(question, buttons: .yesNoCancel, icon: .question, owner: window) == .yes else {
            if finishAfterwards { finish() }
            return
        }

        var runnerOptions = OperationRunner.Options(title: Lang.text(3301, "Compressing"))
        runnerOptions.initialStatus = .update
        runnerOptions.parentWindow = window
        runnerOptions.titleFileName = displayPath
        let folder = self.folder
        let index = tempFile.itemIndex
        let path = tempFile.filePath
        // The panels inside this archive chain are parked: the folder captured when the item was
        // opened belongs to the same archive objects the panel may be using right now.
        let parking = PanelViewController.parkPanels(showing: folder)
        let result = OperationRunner.run(runnerOptions) { runner -> Void in
            parking.waitUntilParked()
            try SZTempOpen.updateItem(at: index, of: folder, fromFilePath: path, progress: runner)
        }
        parking.release()
        switch result {
        case .success:
            tempFile.refreshRecordedAttributes()
            ActiveContext.refresh()
        case .failure(let error as NSError) where error.code == SZError.Code.cancelled.rawValue:
            break
        case .failure:
            // The runner already showed the alert; add the Windows-specific text.
            showError(Lang.format(Lang.text(3010, "Cannot update file '{0}'"), tempFile.itemName))
        }
        if finishAfterwards { finish() }
    }

    /// Stops watching and removes the temp folder (the last step of OpenItemInArchive).
    func finish() {
        guard !finished else { return }
        finished = true
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(settle), object: nil)
        watcher?.cancel()
        watcher = nil
        if let observer = applicationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            applicationObserver = nil
        }
        SZTempOpen.removeTemporaryDirectory(atPath: tempFile.directoryPath)
        TempOpenManager.shared.forget(self)
    }

    /// True when the edited item lives in `archive` (any folder of it).
    func belongs(to archive: SZArchive) -> Bool { folder.archive === archive }

    /// Called at quit: 7zFM waits for every watcher before the window closes (01 §1.1).
    func finishAtShutdown() {
        if !finished, tempFile.wasModified, !archiveIsReadOnly {
            offerUpdate(finishAfterwards: true)
        } else {
            finish()
        }
    }

    /// "7-Zip", MB_OK | MB_ICONSTOP (PanelItemOpen.cpp:1277).
    private func showError(_ text: String) {
        WinMessageBox.run(text, icon: .error, owner: window)
    }
}

/// Keeps the open sessions alive and closes them at quit.
final class TempOpenManager {

    static let shared = TempOpenManager()

    private var sessions: [TempOpenSession] = []

    private init() {
        // 7zFM waits for every watcher before the window closes (01 §1.1 "Shutdown"). The
        // observer is installed here instead of in AppDelegate so this scope owns the whole
        // mechanism.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                              object: nil, queue: .main) { [weak self] _ in
            self?.finishAll()
        }
    }

    func track(_ session: TempOpenSession) {
        sessions.append(session)
    }

    func forget(_ session: TempOpenSession) {
        sessions.removeAll { $0 === session }
    }

    var openCount: Int { sessions.count }

    /// The panel is leaving `archive` (a nested archive about to be written back into its parent,
    /// `PanelNestedArchives.swift`): a pending edit of an item inside it is offered first, so the
    /// write-back carries it, and its watcher stops -- 7zFM deletes the nested copy at that point
    /// (CFolderLink::DeleteDirAndFile), so a later save could not reach the parent anyway.
    func finishSessions(inside archive: SZArchive) {
        for session in sessions where session.belongs(to: archive) { session.finishAtShutdown() }
    }

    /// Called from applicationWillTerminate: ask about every modified temp file, then clean up.
    func finishAll() {
        for session in sessions { session.finishAtShutdown() }
        sessions.removeAll()
    }
}
