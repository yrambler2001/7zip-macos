// PanelVerCtrl.swift -- the File menu's version-control items, IDM_VER_EDIT 580, IDM_VER_COMMIT 581,
// IDM_VER_REVERT 582 and IDM_VER_DIFF 583: CApp::VerCtrl (VerCtrl.cpp) and the menu rule of
// CFileMenu::Load (MyLoadMenu.cpp:697-732). 01 §2.1 rows 22-25, §2.6 "Version control", §9 #21.
//
// The store is the `FM.7vc` folder (ReadReg_VerCtrlPath; no UI sets it, as on Windows). A file
// `<dir>/<name>` is kept as `<7vc>/<dir with ':' -> '_'>/<name>` (ConvertPath_to_Ctrl); older
// versions move to `<that dir>/_7vc/<name>/NNN`. "Read-only" is the Windows attribute; on macOS it is
// the owner's write permission (the inventory's §9 #21 mapping), which is what the engine's
// CFileInfo::IsReadOnly reads on POSIX too.
//
//   * Edit (read-only file): store the current file as the newest version unless the store already
//     holds identical bytes and time, then make the file writable.
//   * Commit (writable file): round the modification time down to the hour / minute / 2 s / 1 s
//     -- the coarsest step that still leaves it newer than the stored version -- and make the file
//     read-only again.
//   * Revert (writable file): put the stored version back, after an Overwrite question (no extra
//     buttons, No by default) when the bytes differ; identical bytes only restore read-only.
//   * Diff (writable file): the Diff tool on stored vs current.
//
// The items only appear with a Diff tool and a 7vc folder configured and one file-system file
// selected, smaller than 2 GB: read-only shows Edit, writable shows the other three.

import AppKit
import SevenZipKit

/// The file operations of CApp::VerCtrl, Foundation only.
enum VersionControl {

    enum Command { case edit, commit, revert, diff }

    enum Outcome: Equatable {
        case done
        /// The Overwrite question of Revert was answered No.
        case declined
        /// The Diff tool should compare (stored, current).
        case diff(stored: String, current: String)
        /// MessageBox_Error text (the Windows strings are literal English, not lang ids).
        case error(String)
    }

    /// `<7vc>/<directory with ':' -> '_'>/<name>`.
    static func storedPath(of path: String, store: String) -> String {
        let directory = ((path as NSString).deletingLastPathComponent as NSString)
        let converted = (directory as String).replacingOccurrences(of: ":", with: "_")
        var root = store
        if !root.hasSuffix("/") { root += "/" }
        let relative = converted.hasPrefix("/") ? String(converted.dropFirst()) : converted
        return ((root + relative) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    struct FileState {
        let data: Data
        let modified: Date
        let created: Date?
        let permissions: Int
        var isReadOnly: Bool { permissions & 0o200 == 0 }

        init?(path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let data = FileManager.default.contents(atPath: path),
                  data.count <= 1 << 28 else { return nil }          // CFileDataInfo::Read limit
            self.data = data
            modified = attributes[.modificationDate] as? Date ?? .distantPast
            created = attributes[.creationDate] as? Date
            permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        }
    }

    /// The menu rule: which of the four items a file gets, or [] (MyLoadMenu.cpp:697-732).
    static func menuCommands(forFile path: String?, diffPath: String, store: String) -> [Command] {
        guard !diffPath.isEmpty, !store.isEmpty, let path,
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              (attributes[.type] as? FileAttributeType) != .typeDirectory,
              ((attributes[.size] as? NSNumber)?.uint64Value ?? 0) < (1 << 31) else { return [] }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o644
        return permissions & 0o200 == 0 ? [.edit] : [.commit, .revert, .diff]
    }

    /// CApp::VerCtrl(id) for one file. `askRevert` is the Overwrite question (true = Yes).
    static func run(_ command: Command, path: String, store: String,
                    askRevert: (_ current: FileState, _ stored: FileState, _ storedPath: String) -> Bool) -> Outcome {
        let path2 = storedPath(of: path, store: store)
        guard let current = FileState(path: path) else { return .error(lastError(path)) }
        let stored = FileState(path: path2)
        let sameData = stored.map { $0.data == current.data } ?? false
        let sameTime = stored.map { $0.modified == current.modified } ?? false
        let identical = sameData && sameTime
        let fm = FileManager.default

        switch command {
        case .edit:
            guard current.isReadOnly else { return .error("File is not read-only") }
            if !identical {
                do {
                    let directory = (path2 as NSString).deletingLastPathComponent
                    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
                    if stored != nil {
                        // the stored version moves to _7vc/<name>/NNN, NNN one past the highest
                        let history = (directory as NSString).appendingPathComponent("_7vc/" + (path as NSString).lastPathComponent)
                        let numbers = ((try? fm.contentsOfDirectory(atPath: history)) ?? []).compactMap { name -> UInt32? in
                            guard !name.isEmpty, name.allSatisfy(\.isNumber), let v = UInt32(name), v <= 0x7FFF_FFFF else { return nil }
                            return v
                        }
                        let next = (numbers.max() ?? 0) + 1
                        try fm.createDirectory(atPath: history, withIntermediateDirectories: true)
                        try fm.moveItem(atPath: path2, toPath: (history as NSString).appendingPathComponent(String(format: "%03u", next)))
                    }
                    guard !fm.fileExists(atPath: path2) else { return .error(lastError(path2)) }   // CREATE_NEW
                    try write(current, to: path2)
                } catch {
                    return .error(error.localizedDescription)
                }
            }
            return setPermissions(current.permissions | 0o200, path)

        case .commit, .revert, .diff:
            guard !current.isReadOnly else { return .error("File is read-only") }
        }

        switch command {
        case .commit:
            if sameData && !sameTime {
                return .error("Same data, but different timestamps.\nUse `Revert` to recover timestamp.")
            }
            let original = current.modified.timeIntervalSince1970
            let storedTime = stored?.modified.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude
            if original > storedTime {
                var rounded = original
                for precision in [3600.0, 60, 2, 1] {
                    rounded = (original / precision).rounded(.down) * precision
                    if rounded > storedTime { break }
                }
                if rounded != original && rounded > storedTime {
                    let time = Date(timeIntervalSince1970: rounded)
                    var attributes: [FileAttributeKey: Any] = [.modificationDate: time]
                    if let created = current.created, created > time { attributes[.creationDate] = time }
                    do { try fm.setAttributes(attributes, ofItemAtPath: path) } catch { return .error(error.localizedDescription) }
                }
            }
            return setPermissions(current.permissions & ~0o222, path)

        case .revert:
            guard let stored else { return .error("No file to revert") }
            if !sameData || !sameTime {
                if !sameData, !askRevert(current, stored, path2) { return .declined }
                do { try write(stored, to: path) } catch { return .error(error.localizedDescription) }
                return .done
            }
            return setPermissions(stored.permissions & ~0o222, path)

        case .diff:
            guard stored != nil else { return .done }
            return .diff(stored: path2, current: path)

        case .edit:
            return .done
        }
    }

    /// WriteFile: the bytes, then the times, then the attributes (the permissions here).
    private static func write(_ state: FileState, to path: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try? fm.setAttributes([.posixPermissions: 0o600 | state.permissions], ofItemAtPath: path)
        }
        try state.data.write(to: URL(fileURLWithPath: path))
        var attributes: [FileAttributeKey: Any] = [.modificationDate: state.modified, .posixPermissions: state.permissions]
        if let created = state.created { attributes[.creationDate] = created }
        try fm.setAttributes(attributes, ofItemAtPath: path)
    }

    private static func setPermissions(_ permissions: Int, _ path: String) -> Outcome {
        do {
            try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path)
            return .done
        } catch {
            return .error(error.localizedDescription)
        }
    }

    private static func lastError(_ path: String) -> String {
        String(cString: strerror(errno)) + "\n" + path
    }
}

extension MainWindowController {

    /// The single file-system file the Ver* items act on, or nil (isOneFsFile).
    func verCtrlTarget() -> String? {
        let panel = focusedPanel
        guard let snap = panel.snapshot, snap.isFileSystem else { return nil }
        let operated = panel.operatedRowIndices().map { panel.rows[$0] }
        guard operated.count == 1, !operated[0].isDirectory, !operated[0].fullPath.isEmpty else { return nil }
        return operated[0].fullPath
    }

    /// CFileMenu::Load's Ver* rule for one menu item: visible and enabled, or hidden.
    func verCtrlItemIsShown(_ command: VersionControl.Command) -> Bool {
        VersionControl.menuCommands(forFile: verCtrlTarget(), diffPath: Settings.diffPath,
                                    store: Settings.verCtrlPath).contains(command)
    }

    @objc func fileVerEdit(_ sender: Any?) { verCtrl(.edit) }        // IDM_VER_EDIT 580
    @objc func fileVerCommit(_ sender: Any?) { verCtrl(.commit) }    // IDM_VER_COMMIT 581
    @objc func fileVerRevert(_ sender: Any?) { verCtrl(.revert) }    // IDM_VER_REVERT 582
    @objc func fileVerDiff(_ sender: Any?) { verCtrl(.diff) }        // IDM_VER_DIFF 583

    /// CApp::VerCtrl(id).
    func verCtrl(_ command: VersionControl.Command) {
        let panel = focusedPanel
        guard let snap = panel.snapshot, snap.isFileSystem else {
            panel.showUnsupportedOperation()                   // !Is_IO_FS_Folder
            return
        }
        guard let path = verCtrlTarget() else { return }      // indices.Size() != 1: silently
        let store = Settings.verCtrlPath
        guard !store.isEmpty else { return }
        let outcome = VersionControl.run(command, path: path, store: store) { current, stored, storedPath in
            // COverwriteDialog: no extra buttons, DefaultButton_is_NO.
            OverwriteDialog.run(oldFile: .init(path: path, size: UInt64(current.data.count), time: current.modified),
                                newFile: .init(path: storedPath, size: UInt64(stored.data.count), time: stored.modified),
                                showExtraButtons: false, defaultIsNo: true, parent: window).answer == .yes
        }
        switch outcome {
        case .done, .declined:
            break
        case .diff(let stored, let current):
            ItemOpenCommands.diff(paths: [stored, current], parent: window)    // DiffFiles(path2, path)
        case .error(let message):
            panel.showError(message: message)
        }
        panel.refreshAfterOperation(selectNames: [(path as NSString).lastPathComponent])
    }
}
