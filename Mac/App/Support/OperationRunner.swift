// OperationRunner.swift -- runs one blocking bridge call with the 7zFM progress machinery
// around it: CProgressThreadVirt + CProgressDialog + CProgressSync
// (ProgressDialog2.cpp:1412-1475, 01b-fm-dialogs-settings.md 4.17,
// 01-fm-feature-inventory.md 8.7) in Swift.
//
// It is the single entry point every long operation in the app uses:
//
//     let result = OperationRunner.run(.init(title: Lang.text(3300, "Extracting"))) { runner in
//         try folder.extractItems(at: indexes, toPath: dest, pathMode: .fullPaths,
//                                 overwriteMode: .ask, testMode: false, progress: runner)
//     }
//
// * `work` runs on a dedicated thread and gets the runner as its `SZProgressDelegate`.
// * The runner owns the Progress dialog, marshals the callbacks to the main thread
//   (a 200 ms timer reading the lock-protected ProgressSync, exactly like 7zFM), and
//   answers askOverwrite / askPassword / requestMemoryUse by running the matching dialog
//   modally while the worker blocks.
// * Cancel auto-pauses, asks Yes/No/Cancel (IDS_PROGRESS_ASK_CANCEL 448) and only then
//   stops the worker, which sees E_ABORT; Pause parks the worker inside checkBreak;
//   Background changes the *process* QoS (macOS equivalent of IDLE_PRIORITY_CLASS).
// * Messages collected during the run keep the dialog open at the end, and can be shown
//   again with `MessagesDialog.show(messages:)`.
//
// `run` must be called on the main thread; it returns once the dialog has closed.

import AppKit
import SevenZipKit

final class OperationRunner: NSObject, SZProgressDelegate, ProgressDialogDelegate {

    // MARK: options

    struct Options {
        /// The operation name in the window title ("Extracting", "Compressing", ...).
        var title: String
        /// CProgressDialog::MainTitle, used for message boxes.
        var mainTitle: String = "7-Zip"
        /// First status-line value, before the engine reports its own.
        var initialStatus: SZProgressStatus = .none
        /// ShowCompressionInfo: show the Compressed size / Compression ratio rows.
        var showCompressionInfo = false
        /// The window the dialogs are centred over.
        var parentWindow: NSWindow?
        /// WaitMode (kCreateDelay = 500 ms): operations that finish that fast without
        /// messages show no dialog at all.
        var waitMode = true
        /// FinalMessage.OkMessage: shown after a clean run (e.g. the Test summary).
        var okMessage: String?
        /// The archive shown in the title and in the password dialog.
        var titleFileName: String = ""
        /// Ask for a password to *encrypt* with (ICryptoGetTextPassword2, compress side).
        var asksPasswordForEncryption = false
        /// Show the "Encrypt file names" checkbox in that password dialog.
        var showsEncryptFileNames = false
        /// Pre-seeded password (7zFM remembers it per archive chain, CFolderLink).
        var password: String?

        init(title: String) { self.title = title }
    }

    // MARK: state

    private let options: Options
    private let sync = ProgressSync()
    private var dialog: ProgressDialog?
    private var timer: Timer?
    private var isBackground = false
    private let finishedSemaphore = DispatchSemaphore(value: 0)
    private var finishHandled = false
    private var isModal = false

    /// Password the user typed, kept so the caller can remember it (CFolderLink::Password).
    private(set) var password: String?
    /// YES when the engine asked for a password during the run (PasswordWasAsked).
    private(set) var passwordWasAsked = false
    /// "Encrypt file names" as answered in the compress-side password dialog.
    private(set) var encryptFileNames = false
    /// Every message the operation collected, in order (CProgressSync::Messages).
    var collectedMessages: [String] { sync.snapshot(background: isBackground).messages }
    /// True once the user confirmed Cancel (_cancelWasPressed).
    private(set) var cancelWasPressed = false

    private init(options: Options) {
        self.options = options
        self.password = options.password
        super.init()
    }

    // MARK: public entry point

    /// Runs `work` with the progress UI. Main thread only; returns when the dialog closed.
    /// `completion` (optional) is called with the same result just before returning.
    @discardableResult
    static func run<T>(_ options: Options,
                       work: @escaping (OperationRunner) throws -> T,
                       completion: ((Result<T, Error>) -> Void)? = nil) -> Result<T, Error> {
        precondition(Thread.isMainThread, "OperationRunner.run must be called on the main thread")
        let runner = OperationRunner(options: options)
        let result = runner.execute(work: work)
        completion?(result)
        return result
    }

    private func execute<T>(work: @escaping (OperationRunner) throws -> T) -> Result<T, Error> {
        sync.setStatus(options.initialStatus)
        if !options.titleFileName.isEmpty {
            sync.setTitleFileName(options.titleFileName)
        }
        sync.restartClock()

        var outcome: Result<T, Error>?
        // CProgressThreadVirt::Process (:1432-1470): the worker catches everything and the
        // result becomes FinalMessage.
        let thread = Thread { [weak self] in
            guard let self else { return }
            do {
                outcome = .success(try work(self))
            } catch {
                outcome = .failure(error)
            }
            self.sync.setFinished()
            self.finishedSemaphore.signal()
            // The 200 ms tick picks this up; the post only shortens the latency when the
            // main thread happens to be in a mode that delivers it.
            DispatchQueue.main.async { [weak self] in self?.workerDidFinish() }
        }
        thread.name = "7-Zip operation"
        thread.stackSize = 8 << 20          // the engine recurses (nested archives)
        thread.qualityOfService = .userInitiated
        thread.start()

        // WaitMode: wait kCreateDelay for a fast operation before showing anything.
        if options.waitMode,
           finishedSemaphore.wait(timeout: .now() + ProgressSync.createDelay) == .success,
           sync.messageCount == 0 {
            finishHandled = true
            restoreForegroundPriority()
            return finish(outcome: outcome, showedDialog: false)
        }

        let progressDialog = ProgressDialog(title: options.title, mainTitle: options.mainTitle,
                                            showCompressionInfo: options.showCompressionInfo)
        progressDialog.delegate = self
        dialog = progressDialog
        update()
        progressDialog.window.makeKeyAndOrderFront(nil)

        // .common covers the modal-panel and event-tracking modes, so the 200 ms tick keeps
        // running while a nested question dialog is up. The tick is also what notices that
        // the worker finished (CheckNeedClose, ProgressDialog2.cpp:1296): a main-queue block
        // is not delivered reliably inside NSApp.runModal, a timer is.
        let ticker = Timer(timeInterval: ProgressSync.timerInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.update()
            if self.sync.isFinished && !self.finishHandled {
                self.workerDidFinish()
            }
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker

        if sync.isFinished && !finishHandled {
            workerDidFinish()               // finished during the create delay, with messages
        }
        if !finishHandled || sync.messageCount != 0 {
            isModal = true
            NSApp.runModal(for: progressDialog.window)
            isModal = false
        }

        ticker.invalidate()
        timer = nil
        progressDialog.window.orderOut(nil)
        dialog = nil
        restoreForegroundPriority()
        return finish(outcome: outcome, showedDialog: true)
    }

    /// OnExternalCloseMessage (:991-1035) + CProgressThreadVirt result handling.
    private func finish<T>(outcome: Result<T, Error>?, showedDialog: Bool) -> Result<T, Error> {
        let messages = collectedMessages
        let result: Result<T, Error> = outcome ?? .failure(NSError(
            domain: SZErrorDomain, code: SZError.Code.unknown.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "The operation did not produce a result"]))

        switch result {
        case .failure(let error as NSError) where error.code == SZError.Code.cancelled.rawValue:
            break                                   // E_ABORT is silent (8.7)
        case .failure(let error):
            let alert = NSAlert()
            alert.messageText = options.mainTitle
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .critical
            alert.addButton(withTitle: Lang.text(401, "OK"))
            alert.runModal()
        case .success:
            // FinalMessage.OkMessage is only shown when nothing went wrong (:1023-1034).
            if let okMessage = options.okMessage, messages.isEmpty {
                let alert = NSAlert()
                alert.messageText = options.mainTitle
                alert.informativeText = okMessage
                alert.alertStyle = .informational
                alert.addButton(withTitle: Lang.text(401, "OK"))
                alert.runModal()
            } else if !messages.isEmpty && !showedDialog {
                // Messages without a progress dialog (a fast operation): show them the way
                // 7zFM does after a drag-and-drop copy (PanelDrag.cpp:1788).
                MessagesDialog.show(messages: messages, parent: options.parentWindow)
            }
        }
        return result
    }

    private func update() {
        guard let dialog else { return }
        dialog.update(sync.snapshot(background: isBackground))
    }

    /// kCloseMessage (:1305): the worker is done.
    private func workerDidFinish() {
        guard !finishHandled else { return }
        finishHandled = true
        update()
        let hasMessages = sync.messageCount != 0
        guard let dialog else { return }
        dialog.operationDidFinish(hasMessages: hasMessages)
        if !hasMessages && isModal {
            NSApp.stopModal()               // the dialog closes itself
        }
    }

    // MARK: process priority (OnPriorityButton :1150)

    /// IDLE_PRIORITY_CLASS <-> NORMAL_PRIORITY_CLASS for the whole process. On macOS the
    /// equivalent is the Darwin background priority band, which also throttles I/O.
    private func setBackgroundPriority(_ background: Bool) {
        isBackground = background
        setpriority(PRIO_DARWIN_PROCESS, 0, background ? PRIO_DARWIN_BG : 0)
    }

    private func restoreForegroundPriority() {
        if isBackground { setBackgroundPriority(false) }
    }

    // MARK: ProgressDialogDelegate

    func progressDialog(_ dialog: ProgressDialog, didSetPaused paused: Bool) {
        sync.setPaused(paused)
    }

    func progressDialog(_ dialog: ProgressDialog, didSetBackground background: Bool) {
        setBackgroundPriority(background)
    }

    func progressDialogDidConfirmCancel(_ dialog: ProgressDialog) {
        cancelWasPressed = true
        sync.setStopped(true)               // Sync.Set_Stopped(true) -> workers get E_ABORT
    }

    func progressDialogDidRequestClose(_ dialog: ProgressDialog) {
        if isModal { NSApp.stopModal() }
    }

    // MARK: SZProgressDelegate (worker thread)

    func progressSetTotal(_ total: UInt64) { sync.setTotal(total) }
    func progressSetCompleted(_ completed: UInt64) { sync.setCompleted(completed) }

    func progressSetRatioInfo(inSize: UInt64, outSize: UInt64) {
        sync.setRatio(inSize: inSize, outSize: outSize)
    }

    func progressSetCurrentFile(_ path: String, isDirectory: Bool) {
        sync.setFilePath(path, isDir: isDirectory)
    }

    func progressSetNumFilesProcessed(_ numFiles: UInt64) { sync.setCurrentFiles(numFiles) }
    func progressShowMessage(_ message: String) { sync.addMessage(message) }

    func progressSetTotalFiles(_ totalFiles: UInt64) { sync.setTotalFiles(totalFiles) }

    func progressSetStatus(_ status: SZProgressStatus) { sync.setStatus(status) }

    func progressSetTitleFileName(_ name: String) { sync.setTitleFileName(name) }

    func progressSetOperationResult(_ result: SZOperationResult, path: String, isEncrypted: Bool) {
        // The message text was already produced by the callback adapter
        // (SetExtractErrorMessage); nothing else to do here.
    }

    func progressScanFolders(_ numFolders: UInt64, files: UInt64, totalSize: UInt64,
                             path: String, isDirectory: Bool) {
        sync.setStatus(.scanning)
        sync.setTotalFiles(files)
        sync.setFilePath(path, isDir: isDirectory)
    }

    func progressCheckBreak() -> Bool { sync.checkStop() }

    // MARK: questions (worker thread blocks while the dialog runs on the main thread)

    func progressAskOverwriteExisting(_ existName: String, existTime: Date?, existSize: NSNumber?,
                                      newName: String, newTime: Date?, newSize: NSNumber?,
                                      suggestedName: AutoreleasingUnsafeMutablePointer<NSString?>?) -> SZOverwriteAnswer {
        let answer = onMain { () -> OverwriteDialog.Result in
            OverwriteDialog.run(
                oldFile: .init(path: existName, size: existSize?.uint64Value, time: existTime,
                               isFileSystemFile: true),
                newFile: .init(path: newName, size: newSize?.uint64Value, time: newTime,
                               isFileSystemFile: false),
                showExtraButtons: true,
                parent: self.dialog?.window ?? self.options.parentWindow)
        }
        if let name = answer.suggestedName, answer.answer == .autoRename {
            suggestedName?.pointee = name as NSString
        }
        _ = sync.checkStop()                 // Sync.CheckStop after the dialog (8.4)
        return answer.answer
    }

    func progressAskPassword(forPath path: String) -> String? {
        passwordWasAsked = true
        if let password { return password }          // asked once per run (PasswordIsDefined)
        let entered = onMain { () -> String? in
            PasswordDialog.askPassword(forPath: path.isEmpty ? self.options.titleFileName : path,
                                       parent: self.dialog?.window ?? self.options.parentWindow)
        }
        password = entered
        _ = sync.checkStop()
        return entered
    }

    func progressAskPassword(forEncryptionCancelled cancelled: UnsafeMutablePointer<ObjCBool>) -> String? {
        passwordWasAsked = true
        if let password { return password }
        var options = PasswordDialog.Options()
        options.subject = self.options.titleFileName
        options.requiresVerification = true
        options.showsEncryptFileNames = self.options.showsEncryptFileNames
        let result = onMain { () -> PasswordDialog.Result? in
            PasswordDialog.run(options, parent: self.dialog?.window ?? self.options.parentWindow)
        }
        guard let result else {
            cancelled.pointee = ObjCBool(true)
            return nil
        }
        password = result.password.isEmpty ? nil : result.password
        encryptFileNames = result.encryptFileNames
        _ = sync.checkStop()
        return password
    }

    func progressRequestMemoryUse(forPath path: String?, requiredSize: UInt64,
                                  allowedSize: UnsafeMutablePointer<UInt64>,
                                  testMode: Bool, allowSkipArchive: Bool) -> SZMemoryUseAnswer {
        let gb: (UInt64) -> UInt32 = { UInt32(min(UInt64(UInt32.max), ($0 + (1 << 30) - 1) >> 30)) }
        var memOptions = MemoryUseDialog.Options()
        memOptions.requiredGB = gb(requiredSize)
        memOptions.limitGB = gb(allowedSize.pointee)
        memOptions.ramGB = UInt32(ProcessInfo.processInfo.physicalMemory >> 30)
        memOptions.testMode = testMode
        memOptions.filePath = path ?? ""
        memOptions.archivePath = options.titleFileName
        memOptions.showRemember = allowSkipArchive
        let result = onMain { () -> MemoryUseDialog.Result? in
            MemoryUseDialog.run(memOptions, parent: self.dialog?.window ?? self.options.parentWindow)
        }
        _ = sync.checkStop()
        guard let result else { return .stop }
        allowedSize.pointee = UInt64(result.limitGB) << 30
        return result.answer
    }

    // MARK: temp-archive move (IFolderArchiveUpdateCallback_MoveArc)

    func progressMoveArchive(from sourcePath: String, toPath destinationPath: String, size: UInt64) {
        sync.setStatus(.moving)
        sync.setFilePath(destinationPath, isDir: false)
        sync.setTotal(size)
    }

    func progressMoveArchiveCompleted(_ current: UInt64, total: UInt64) {
        sync.setTotal(total)
        sync.setCompleted(current)
    }

    func progressMoveArchiveFinished() {
        sync.setStatus(.none)
    }

    /// Before_ArcReopen: clear the break state so the archive can be re-opened.
    func progressClearCancelState() {
        sync.clearStopStatus()
    }

    // MARK: helpers

    /// Runs `body` on the main thread and blocks the worker until it answers. Safe from the
    /// main thread too (a question raised before the dialog exists).
    private func onMain<T>(_ body: @escaping () -> T) -> T {
        if Thread.isMainThread { return body() }
        var value: T!
        DispatchQueue.main.sync { value = body() }
        return value
    }
}
