// ProgressDialog.swift -- the operation progress window: CProgressDialog / IDD_PROGRESS 97
// (ProgressDialog2.cpp/.rc + ProgressDialog2a.rc), built in code.
// Every control keeps its Windows ID in a comment and its text from the lang file by ID.
// Parity: 01b-fm-dialogs-settings.md 4.17, 01-fm-feature-inventory.md 8.7.
//
// The dialog is passive: OperationRunner drives it from a 200 ms timer (kTimerElapse) with
// a ProgressSnapshot and answers the button callbacks. All methods are main-thread only.

import AppKit
import SevenZipKit

protocol ProgressDialogDelegate: AnyObject {
    /// IDB_PAUSE 446 / IDS_CONTINUE 411 -- Sync.Set_Paused(paused)
    func progressDialog(_ dialog: ProgressDialog, didSetPaused paused: Bool)
    /// IDB_PROGRESS_BACKGROUND 444 / IDS_PROGRESS_FOREGROUND 445 -- process priority
    func progressDialog(_ dialog: ProgressDialog, didSetBackground background: Bool)
    /// IDCANCEL after the user confirmed IDS_PROGRESS_ASK_CANCEL -- Sync.Set_Stopped(true)
    func progressDialogDidConfirmCancel(_ dialog: ProgressDialog)
    /// IDCANCEL turned into IDS_CLOSE 408 once the worker finished (MessagesDisplayed).
    func progressDialogDidRequestClose(_ dialog: ProgressDialog)
}

final class ProgressDialog: NSObject, NSWindowDelegate {

    // MARK: window

    let window: NSWindow
    weak var delegate: ProgressDialogDelegate?

    /// "7-Zip" -- CProgressDialog::MainTitle, used for the message boxes.
    let mainTitle: String
    /// The operation name in the title ("Extracting", "Compressing", ...).
    private let operationTitle: String
    /// ShowCompressionInfo: the Compressed size / Compression ratio rows (:408).
    private let showCompressionInfo: Bool

    private(set) var isPaused = false
    private(set) var isBackground = false
    /// _waitCloseByCancelButton: the worker finished and messages are on screen.
    private(set) var isFinished = false

    // MARK: controls (Windows IDs in comments)

    private let elapsedValue = DialogKit.value()        // IDT_PROGRESS_ELAPSED_VAL 120
    private let remainingValue = DialogKit.value()      // IDT_PROGRESS_REMAINING_VAL 121
    private let filesValue = DialogKit.value()          // IDT_PROGRESS_FILES_VAL 111
    private let filesTotalValue = DialogKit.value()     // IDT_PROGRESS_FILES_TOTAL 112
    private let errorsLabel = DialogKit.label(Lang.text(3906, "Errors:"))   // IDT_PROGRESS_ERRORS 3906
    private let errorsValue = DialogKit.value()         // IDT_PROGRESS_ERRORS_VAL 126
    private let totalValue = DialogKit.value()          // IDT_PROGRESS_TOTAL_VAL 122
    private let speedValue = DialogKit.value()          // IDT_PROGRESS_SPEED_VAL 123
    private let processedValue = DialogKit.value()      // IDT_PROGRESS_PROCESSED_VAL 124
    private let packedLabel = DialogKit.label(Lang.text(1008, "Compressed size:"))  // IDT_PROGRESS_PACKED 1008
    private let packedValue = DialogKit.value()         // IDT_PROGRESS_PACKED_VAL 110
    private let ratioLabel = DialogKit.label(Lang.text(3905, "Compression ratio:")) // IDT_PROGRESS_RATIO 3905
    private let ratioValue = DialogKit.value()          // IDT_PROGRESS_RATIO_VAL 125
    private let statusLabel = DialogKit.label("")       // IDT_PROGRESS_STATUS 103
    private let fileNameLabel = DialogKit.label("")     // IDT_PROGRESS_FILE_NAME 102 (two lines)
    private let progressBar = NSProgressIndicator()     // IDC_PROGRESS1 100
    private let messageList = MessageListView(showsHeader: false)  // IDL_PROGRESS_MESSAGES 101
    private let backgroundButton: NSButton              // IDB_PROGRESS_BACKGROUND 444
    private let pauseButton: NSButton                   // IDB_PAUSE 446
    private let cancelButton: NSButton                  // IDCANCEL -> IDS_CLOSE 408

    private var errorsRow: [NSView] = []
    private var lastPercent: Int = -1
    private var lastTitleFileName = ""

    /// kTitleFileNameSizeLimit (ProgressDialog2.cpp:31)
    private static let titleFileNameSizeLimit = 80
    /// _numReduceSymbols for the file-name field (:324)
    private static let fileNameSizeLimit = 96

    init(title: String, mainTitle: String = "7-Zip", showCompressionInfo: Bool) {
        self.operationTitle = title
        self.mainTitle = mainTitle
        self.showCompressionInfo = showCompressionInfo
        // MY_MODAL_RESIZE_DIALOG_STYLE, caption "Progress" -- BIG_DIALOG_SIZE(360, 192)
        window = DialogKit.window(title: title.isEmpty ? mainTitle : title, resizable: true)
        backgroundButton = DialogKit.button(Lang.text(444, "Background"), target: nil, action: #selector(NSObject.doesNotRecognizeSelector(_:)))
        pauseButton = DialogKit.button(Lang.text(446, "Pause"), target: nil, action: #selector(NSObject.doesNotRecognizeSelector(_:)))
        cancelButton = DialogKit.button(Lang.text(402, "Cancel"), target: nil, action: #selector(NSObject.doesNotRecognizeSelector(_:)), key: "\u{1b}")
        super.init()
        build()
    }

    // MARK: layout

    private func build() {
        backgroundButton.target = self
        backgroundButton.action = #selector(togglePriority(_:))
        pauseButton.target = self
        pauseButton.action = #selector(togglePause(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked(_:))

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.doubleValue = 0
        progressBar.controlSize = .regular
        progressBar.style = .bar

        statusLabel.lineBreakMode = .byTruncatingTail
        fileNameLabel.maximumNumberOfLines = 2
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        // Two label/value columns, exactly the row order of ProgressDialog2a.rc.
        let grid = NSGridView(views: [
            [DialogKit.label(Lang.text(3900, "Elapsed time:")), elapsedValue,      // 3900 / 120
             DialogKit.label(Lang.text(3902, "Total size:")), totalValue],         // 3902 / 122
            [DialogKit.label(Lang.text(3901, "Remaining time:")), remainingValue,  // 3901 / 121
             DialogKit.label(Lang.text(3903, "Speed:")), speedValue],              // 3903 / 123
            [DialogKit.label(Lang.text(1032, "Files:")), filesValue,               // 1032 / 111
             DialogKit.label(Lang.text(3904, "Processed:")), processedValue],       // 3904 / 124
            [DialogKit.label(""), filesTotalValue,                                 //        112
             packedLabel, packedValue],                                            // 1008 / 110
            [errorsLabel, errorsValue,                                             // 3906 / 126
             ratioLabel, ratioValue],                                              // 3905 / 125
        ])
        grid.rowSpacing = 4
        grid.columnSpacing = 10
        grid.column(at: 1).width = 110
        grid.column(at: 3).width = 110
        grid.column(at: 1).xPlacement = .trailing
        grid.column(at: 3).xPlacement = .trailing

        // Errors label/value appear only once a message arrives (EnableErrorsControls :332)
        errorsRow = [errorsLabel, errorsValue]
        setErrorsControlsVisible(false)
        if !showCompressionInfo {
            packedLabel.isHidden = true
            packedValue.isHidden = true
            ratioLabel.isHidden = true
            ratioValue.isHidden = true
        }

        let buttons = NSStackView(views: [backgroundButton, pauseButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        let buttonRow = NSStackView(views: [NSView(), buttons])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fill

        let stack = NSStackView(views: [grid, statusLabel, fileNameLabel, progressBar, messageList, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setHuggingPriority(.defaultLow, for: .horizontal)

        for view in [grid, statusLabel, fileNameLabel, progressBar, messageList, buttonRow] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        messageList.isHidden = true
        messageList.addConstraint(NSLayoutConstraint(item: messageList, attribute: .height, relatedBy: .greaterThanOrEqual,
                                                    toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 110))
        fileNameLabel.addConstraint(NSLayoutConstraint(item: fileNameLabel, attribute: .height, relatedBy: .equal,
                                                      toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 30))

        window.delegate = self
        DialogKit.install(stack, in: window, parent: nil, minimumWidth: 560)
        window.center()
        updateTitle(percent: nil, fileName: "")
    }

    private func setErrorsControlsVisible(_ visible: Bool) {
        for view in errorsRow { view.isHidden = !visible }
    }

    // MARK: updates (main thread, every kTimerElapse = 200 ms)

    func update(_ snapshot: ProgressSnapshot) {
        elapsedValue.stringValue = ProgressFormatting.time(snapshot.elapsed)
        remainingValue.stringValue = ProgressFormatting.remaining(elapsed: snapshot.elapsed,
                                                                  total: snapshot.totalBytes,
                                                                  completed: snapshot.completedBytes)
        filesValue.stringValue = snapshot.currentFiles == 0 && snapshot.totalFiles == nil
            ? "" : Formatting.size(snapshot.currentFiles)
        filesTotalValue.stringValue = snapshot.totalFiles.map { "/ " + Formatting.size($0) } ?? ""
        totalValue.stringValue = snapshot.totalBytes.map { Formatting.size($0) } ?? ""
        processedValue.stringValue = Formatting.size(snapshot.completedBytes)
        speedValue.stringValue = ProgressFormatting.speed(bytes: snapshot.completedBytes, elapsed: snapshot.elapsed)
        if showCompressionInfo {
            packedValue.stringValue = snapshot.outSize.map { Formatting.size($0) } ?? ""
            ratioValue.stringValue = ProgressFormatting.ratio(inSize: snapshot.inSize, outSize: snapshot.outSize)
        }

        statusLabel.stringValue = snapshot.status == .none
            ? "" : Lang.text(snapshot.status.rawValue, ProgressDialog.fallbackStatus(snapshot.status))
        fileNameLabel.stringValue = ProgressFormatting.twoLinePath(
            ProgressFormatting.reduce(snapshot.filePath, limit: ProgressDialog.fileNameSizeLimit))

        if let total = snapshot.totalBytes, total > 0 {
            progressBar.isIndeterminate = false
            progressBar.maxValue = Double(total)
            progressBar.doubleValue = Double(min(snapshot.completedBytes, total))
        } else if !snapshot.finished {
            progressBar.maxValue = 1
            progressBar.doubleValue = 0
        }

        if !snapshot.messages.isEmpty {
            setErrorsControlsVisible(true)
            errorsValue.stringValue = "\(snapshot.messages.count)"
            if messageList.isHidden {
                messageList.isHidden = false
                if let content = window.contentView {
                    content.layoutSubtreeIfNeeded()
                    let fitting = content.fittingSize
                    window.setContentSize(NSSize(width: max(content.frame.width, fitting.width),
                                                 height: fitting.height))
                }
            }
            messageList.setMessages(snapshot.messages)
        }

        let percent = ProgressFormatting.percent(completed: snapshot.completedBytes, total: snapshot.totalBytes)
        if percent != lastPercent || snapshot.titleFileName != lastTitleFileName
            || snapshot.paused != isPaused {
            lastPercent = percent ?? -1
            lastTitleFileName = snapshot.titleFileName
            isPaused = snapshot.paused
            updateTitle(percent: percent, fileName: snapshot.titleFileName)
        }
    }

    /// SetTitleText (:1084-1127): "<Paused> <NN%> <Title> <Background> <fileName>".
    private func updateTitle(percent: Int?, fileName: String) {
        var parts: [String] = []
        if isPaused { parts.append(Lang.text(447, "Paused")) }          // IDS_PROGRESS_PAUSED 447
        if let percent { parts.append("\(percent)%") }
        if !operationTitle.isEmpty { parts.append(operationTitle) }
        if isBackground { parts.append(Lang.text(444, "Background")) }  // IDB_PROGRESS_BACKGROUND 444
        let name = (fileName as NSString).lastPathComponent
        if !name.isEmpty {
            parts.append(ProgressFormatting.reduce(name, limit: ProgressDialog.titleFileNameSizeLimit))
        }
        window.title = parts.isEmpty ? mainTitle : parts.joined(separator: " ")
    }

    private static func fallbackStatus(_ status: SZProgressStatus) -> String {
        switch status {
        case .extracting: return "Extracting"
        case .compressing: return "Compressing"
        case .testing: return "Testing"
        case .opening: return "Opening..."
        case .scanning: return "Scanning..."
        case .removing: return "Removing"
        case .add: return "Adding"
        case .update: return "Updating"
        case .analyze: return "Analyzing"
        case .replicate: return "Replicating"
        case .repack: return "Repacking"
        case .skipping: return "Skipping"
        case .delete: return "Deleting"
        case .header: return "Header creating"
        case .copying: return "Copying..."
        case .moving: return "Moving..."
        case .renaming: return "Renaming..."
        case .deleting: return "Deleting..."
        case .checksum: return "Checksum calculating..."
        default: return ""
        }
    }

    // MARK: finish (OnExternalCloseMessage, :991-1035)

    /// The worker is done. With messages on screen the window stays open and Cancel becomes
    /// Close (MessagesDisplayed); without them the runner closes the dialog itself.
    func operationDidFinish(hasMessages: Bool) {
        isFinished = true
        pauseButton.isHidden = true
        backgroundButton.isHidden = true
        cancelButton.title = Lang.text(408, "Close")     // IDS_CLOSE 408
        cancelButton.keyEquivalent = "\r"
        if hasMessages {
            statusLabel.stringValue = Lang.text(3906, "Errors:") + " \(messageList.messages.count)"
        }
    }

    // MARK: actions

    @objc private func togglePause(_ sender: Any?) {
        // OnPauseButton (:1130): Sync.Set_Paused(!paused); the worker parks in CheckStop.
        setPaused(!isPaused)
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        pauseButton.title = paused ? Lang.text(411, "Continue") : Lang.text(446, "Pause")
        delegate?.progressDialog(self, didSetPaused: paused)
        updateTitle(percent: lastPercent >= 0 ? lastPercent : nil, fileName: lastTitleFileName)
    }

    @objc private func togglePriority(_ sender: Any?) {
        // OnPriorityButton (:1150): IDLE_PRIORITY_CLASS <-> NORMAL_PRIORITY_CLASS for the
        // whole process; on macOS the runner changes the process QoS instead.
        isBackground = !isBackground
        backgroundButton.title = isBackground ? Lang.text(445, "Foreground") : Lang.text(444, "Background")
        delegate?.progressDialog(self, didSetBackground: isBackground)
        updateTitle(percent: lastPercent >= 0 ? lastPercent : nil, fileName: lastTitleFileName)
    }

    @objc private func cancelClicked(_ sender: Any?) {
        if isFinished {
            delegate?.progressDialogDidRequestClose(self)
            return
        }
        // OnButtonClicked (:1234-1294): auto-pause, ask, and only on Yes stop the worker.
        let wasPaused = isPaused
        if !wasPaused { setPaused(true) }

        let alert = NSAlert()
        alert.messageText = window.title
        alert.informativeText = Lang.text(448, "Are you sure you want to cancel?")   // IDS_PROGRESS_ASK_CANCEL 448
        alert.alertStyle = .warning
        alert.addButton(withTitle: Lang.text(406, "Yes"))      // MY_IDYES 406
        alert.addButton(withTitle: Lang.text(407, "No"))       // MY_IDNO 407
        alert.addButton(withTitle: Lang.text(402, "Cancel"))   // IDCANCEL
        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            if !wasPaused { setPaused(false) }     // undo the automatic pause, then abort
            delegate?.progressDialogDidConfirmCancel(self)
        } else if !wasPaused {
            setPaused(false)
        }
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // The close box behaves like Cancel (WM_CLOSE -> OnButtonClicked).
        cancelClicked(nil)
        return false
    }
}
