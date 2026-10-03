// PanelArchiveOpen.swift -- opening an archive in a panel the way 7zFM does it: under the
// "Opening" progress with Cancel (CFfpOpen::OpenFileFolderPlugin, FileFolderPluginOpen.cpp:220-370,
// COpenArchiveCallback in OpenCallback.cpp), with the per-level error text of a level that could
// not be opened (CPanel::OpenAsArc / OpenAsArc_Msg, PanelItemOpen.cpp:456-564), and with the
// password kept per archive level (CFolderLink::Password / UsePassword).
//
// Parity: 01 §6.7 "Opening", 01 §8.7, 01b §4.16; PROGRESS §2.3 (153, 155, 168).
//
// * The open runs on an `OperationRunner` worker while the panel queue waits for it, so the
//   folders are still touched by one thread at a time (the write-back in PanelNestedArchives does
//   the same). The runner's WaitMode is 7zFM's: nothing is shown for an open that finishes within
//   500 ms; after that a progress window titled "Opening" (IDS_OPENNING 3303) with the archive name,
//   the files / bytes the handler reports (Open_SetTotal / Open_SetCompleted) and Cancel. Cancel
//   aborts the open at the handler's next callback (Open_CheckBreak -> E_ABORT), which is silent.
// * The runner never shows its own failure box here: the open's outcome comes back as a value, and
//   the caller decides what 7zFM would say (`ArchiveOpenOutcome`).
// * Passwords: each `SZArchive` carries its own (`SZArchive.password`), set by the bridge from the
//   open and by an operation that asked for one. `rememberedPassword` is the innermost level's.

import AppKit
import SevenZipKit

/// What OpenAsArc_Msg / BindToPath make of a failed open.
enum ArchiveOpenFailure {
    /// E_ABORT (Cancel in the progress or in the password dialog): silent.
    case cancelled
    /// S_FALSE: no handler accepted the file. `encrypted` is CFfpOpen::Encrypted (a password was in
    /// use), `levelErrors` the non-open level's text (CFfpOpen::ErrorMessage).
    case notArchive(path: String, encrypted: Bool, levelErrors: String?, error: NSError)
    /// Any other HRESULT: HResultToMessage.
    case failed(NSError)

    init(_ error: Error) {
        let ns = error as NSError
        if ns.code == SZError.Code.cancelled.rawValue {
            self = .cancelled
        } else if ns.code == SZError.Code.notArchive.rawValue {
            self = .notArchive(path: ns.userInfo[SZArchiveOpenPathKey] as? String ?? "",
                               encrypted: (ns.userInfo[SZArchiveOpenEncryptedKey] as? NSNumber)?.boolValue ?? false,
                               levelErrors: ns.userInfo[SZArchiveOpenErrorMessageKey] as? String,
                               error: ns)
        } else {
            self = .failed(ns)
        }
    }

    /// OpenAsArc_Msg (PanelItemOpen.cpp:528-564): the box a panel shows for a failed open, or nil
    /// when 7zFM says nothing (cancel, and a plain "not an archive").
    func panelMessage(virtualPath: String) -> String? {
        switch self {
        case .cancelled:
            return nil
        case .notArchive(let path, let encrypted, _, _):
            guard encrypted else { return nil }          // 17.01: shown for encrypted only
            return Lang.format(Lang.text(3006, "Cannot open encrypted archive '{0}'. Wrong password?"),
                               virtualPath.isEmpty ? path : virtualPath)    // IDS_CANT_OPEN_ENCRYPTED_ARCHIVE
        case .failed(let error):
            return OperationRunner.failureMessage(for: error)              // HResultToMessage
        }
    }

    /// FM.cpp:997-1014, the box of a failed command-line open ("Error" + the level text).
    func launchMessage(fullPath: String) -> String? {
        switch self {
        case .cancelled:
            return nil                                    // E_ABORT: return -1 without a box
        case .notArchive(_, let encrypted, let levelErrors, _):
            var text = encrypted
                ? Lang.format(Lang.text(3006, "Cannot open encrypted archive '{0}'. Wrong password?"), fullPath)
                : Lang.format(Lang.text(3005, "Cannot open file '{0}' as archive"), fullPath)
            if let levelErrors, !levelErrors.isEmpty { text += "\n" + levelErrors }
            return text
        case .failed(let error):
            return OperationRunner.failureMessage(for: error) ?? "Error"
        }
    }
}

/// The innermost archive level of a panel's folder (CFolderLink = `_parentFolders.Back()`), kept
/// beside `folder` so the main thread can read its password without touching the queue-owned
/// folder. Weak: the folder chain owns the archive.
final class PanelArchiveLevel {
    private let lock = NSLock()
    private weak var archive: SZArchive?

    func set(_ archive: SZArchive?) {
        lock.lock(); defer { lock.unlock() }
        self.archive = archive
    }

    var current: SZArchive? {
        lock.lock(); defer { lock.unlock() }
        return archive
    }
}

extension PanelViewController {

    /// Runs `open` under the "Opening" progress (see the file comment). Called on the panel queue;
    /// the queue waits on the main thread while a runner worker does the open. Also callable on
    /// the main thread.
    func runArchiveOpen<T>(name: String, _ open: @escaping (SZProgressDelegate) throws -> T) -> Result<T, Error> {
        var result: Result<T, Error> = .failure(NSError(domain: SZErrorDomain, code: SZError.Code.cancelled.rawValue))
        let body = { [self] in
            queueHeldForMain += 1                           // the panel queue waits for this block
            defer { queueHeldForMain -= 1 }
            var options = OperationRunner.Options(title: Lang.text(3303, "Opening"))   // IDS_OPENNING
            options.initialStatus = .opening
            options.parentWindow = hostWindow
            options.titleFileName = name
            options.waitMode = true                       // pd.WaitMode = true: 500 ms before showing
            let outer = OperationRunner.run(options) { runner -> Result<T, Error> in
                do { return .success(try open(runner)) } catch { return .failure(error) }
            }
            switch outer {
            case .success(let inner): result = inner
            case .failure(let error): result = .failure(error)
            }
        }
        Self.performOnMainRunLoop(body)
        return result
    }

    /// Runs `body` on the main thread and waits for it -- through the main *run loop*
    /// (CFRunLoopPerformBlock in the common modes), not the main dispatch queue. A body that runs a
    /// modal session (OperationRunner, a question) must not be a main-queue block: the main queue is
    /// serial, so while that block runs, a worker's own `DispatchQueue.main.sync` (the password
    /// dialog, the overwrite question) could never be delivered and both would wait forever. A
    /// run-loop block leaves the main queue free for them inside the modal loop.
    static func performOnMainRunLoop(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body(); return }
        let done = DispatchSemaphore(value: 0)
        let mainLoop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(mainLoop, CFRunLoopMode.commonModes.rawValue) {
            body()
            done.signal()
        }
        CFRunLoopWakeUp(mainLoop)
        done.wait()
    }

    /// True when binding `path` cannot open an archive: the root, a virtual root name, an existing
    /// directory. Those binds skip the progress machinery entirely.
    static func bindNeedsNoArchiveOpen(_ path: String) -> Bool {
        if path.isEmpty || !path.hasPrefix("/") { return true }
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// BindToPath reuses the open CFolderLinks of the chain it is leaving (PanelFolderChange.cpp:
    /// 88-125); this port re-opens instead, so the levels being left lend their passwords to the
    /// re-open of the same archive and nothing is asked twice. Called from the open's worker while
    /// the panel queue waits, so `folder` is not changing under it.
    func reusablePassword(forArchivePath path: String) -> String? {
        for archive in Self.archiveChain(of: folder) where archive.path == path {
            if let password = archive.password { return password }
        }
        return nil
    }

    /// CPanel::Create's BindToPath with needOpenArc (Panel.cpp:104-107, FM.cpp:975-1014): `path`
    /// is an existing file named on the command line, opened as an archive with `formatHint`
    /// (`-t`). On success the panel enters it, and a non-open level's text is shown as
    /// CPanel::OpenAsArc shows it. On failure the panel is left as it was and `completion` gets
    /// what FM.cpp makes of it; the caller shows the "Error" box and closes the window.
    func openLaunchArchive(_ path: String, formatHint: String?,
                           completion: @escaping (ArchiveOpenFailure?) -> Void) {
        runOnQueue { [self] in
            self.leaveNestedArchives(from: self.folder, to: nil)
            let outcome = self.runArchiveOpen(name: (path as NSString).lastPathComponent) { progress -> SZFolder in
                let archive = try SZArchiveOpener.openArchive(atPath: path, formatHint: formatHint,
                                                              passwordDelegate: self, progress: progress)
                let root = try archive.rootFolder()
                if root.supportsFlatMode, self.flatModeForArc {
                    root.flatMode = true
                    try root.loadItems()
                }
                return root
            }
            switch outcome {
            case .success(let root):
                self.folder = root
                let snap = self.makeSnapshot(root)
                let levelErrors = root.archive?.openErrorMessage
                DispatchQueue.main.async {
                    self.apply(snap, selectNames: [])
                    if let levelErrors { self.showError(message: levelErrors) }
                    completion(nil)
                }
            case .failure(let error):
                DispatchQueue.main.async { completion(ArchiveOpenFailure(error)) }
            }
        }
    }
}
