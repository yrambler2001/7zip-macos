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

    private let elapsedValue = DialogKit.label("", alignment: .right)        // IDT_PROGRESS_ELAPSED_VAL 120
    private let remainingValue = DialogKit.label("", alignment: .right)      // IDT_PROGRESS_REMAINING_VAL 121
    private let filesValue = DialogKit.label("", alignment: .right)          // IDT_PROGRESS_FILES_VAL 111
    private let filesTotalValue = DialogKit.label("", alignment: .right)     // IDT_PROGRESS_FILES_TOTAL 112
    private let errorsLabel = DialogKit.label(Lang.text(3906, "Errors:"))   // IDT_PROGRESS_ERRORS 3906
    private let errorsValue = DialogKit.label("", alignment: .right)         // IDT_PROGRESS_ERRORS_VAL 126
    private let totalValue = DialogKit.label("", alignment: .right)          // IDT_PROGRESS_TOTAL_VAL 122
    private let speedValue = DialogKit.label("", alignment: .right)          // IDT_PROGRESS_SPEED_VAL 123
    private let processedValue = DialogKit.label("", alignment: .right)      // IDT_PROGRESS_PROCESSED_VAL 124
    // kLangIDs_Colon (ProgressDialog2.cpp:66-70): IDT_PROGRESS_PACKED and IDT_PROGRESS_FILES take
    // the property name from the lang file plus ":" (LangSetDlgItems_Colon) -- 7zFM 25.01 shows
    // "Files:" (Mac/docs/reports/wincompare.md).
    private let packedLabel = DialogKit.label(Lang.dialogTextColon(97, 1008, "Compressed size:"))  // IDT_PROGRESS_PACKED 1008
    private let packedValue = DialogKit.label("", alignment: .right)         // IDT_PROGRESS_PACKED_VAL 110
    private let ratioLabel = DialogKit.label(Lang.text(3905, "Compression ratio:")) // IDT_PROGRESS_RATIO 3905
    private let ratioValue = DialogKit.label("", alignment: .right)          // IDT_PROGRESS_RATIO_VAL 125
    private let statusLabel = DialogKit.label("")       // IDT_PROGRESS_STATUS 103
    private let fileNameLabel = DialogKit.label("")     // IDT_PROGRESS_FILE_NAME 102 (two lines)
    private let progressBar = WinProgressBar()          // IDC_PROGRESS1 100 (msctls_progress32)
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

        // Errors label/value appear only once a message arrives (EnableErrorsControls :332)
        errorsRow = [errorsLabel, errorsValue]
        setErrorsControlsVisible(false)
        if !showCompressionInfo {
            packedLabel.isHidden = true
            packedValue.isHidden = true
            ratioLabel.isHidden = true
            ratioValue.isHidden = true
        }
        messageList.isHidden = true

        // IDD_PROGRESS 97 (ProgressDialog2a.rc): 376 x 204 DLU = 564 x 332 px, resizable. Every
        // control starts on its template rect and OnSize (ProgressDialog2.cpp:455-565) lays the
        // label / value pairs, the status and file lines, the bar, the message list and the three
        // buttons out for the client size (dlgfeel).
        let rc = RcDialog(97)
        let form = RcFormView()
        let pairs: [(NSTextField?, NSTextField, Int, Int)] = [
            (DialogKit.label(Lang.text(3900, "Elapsed time:")), elapsedValue, 3900, 120),     // IDT_PROGRESS_ELAPSED
            (DialogKit.label(Lang.text(3901, "Remaining time:")), remainingValue, 3901, 121), // IDT_PROGRESS_REMAINING
            (DialogKit.label(Lang.dialogTextColon(97, 1032, "Files:")), filesValue, 1032, 111), // IDT_PROGRESS_FILES
            (nil, filesTotalValue, 0, 112),                                                    // IDT_PROGRESS_FILES_TOTAL
            (errorsLabel, errorsValue, 3906, 126),                                             // IDT_PROGRESS_ERRORS
            (DialogKit.label(Lang.text(3902, "Total size:")), totalValue, 3902, 122),         // IDT_PROGRESS_TOTAL
            (DialogKit.label(Lang.dialogText(97, 3903, "Speed:")), speedValue, 3903, 123),    // IDT_PROGRESS_SPEED
            (DialogKit.label(Lang.text(3904, "Processed:")), processedValue, 3904, 124),      // IDT_PROGRESS_PROCESSED
            (packedLabel, packedValue, 1008, 110),                                             // IDT_PROGRESS_PACKED
            (ratioLabel, ratioValue, 3905, 125),                                               // IDT_PROGRESS_RATIO
        ]
        for (label, value, labelID, valueID) in pairs {
            if let label { form.add(label, rc, labelID) }
            form.add(value, rc, valueID)
        }
        form.add(statusLabel, rc, 103)                                                         // IDT_PROGRESS_STATUS 103
        form.add(fileNameLabel, rc, 102)                                                       // IDT_PROGRESS_FILE_NAME 102
        form.addSubview(progressBar)
        progressBar.frame = rc.rect(100)                                                       // IDC_PROGRESS1 100
        form.addSubview(messageList)
        messageList.frame = rc.rect(101)                                                       // IDL_PROGRESS_MESSAGES 101
        form.add(backgroundButton, rc, 444)
        form.add(pauseButton, rc, 446)
        form.add(cancelButton, rc, 2)

        let mx = rc.rect(3900).minX, my = rc.rect(3900).minY
        let sY = rc.rect(3900).height, sStep = rc.rect(3901).minY - my
        let button = rc.rect(2).size
        let statusRect = rc.rect(103), fileRect = rc.rect(102), barRect = rc.rect(100), listRect = rc.rect(101)
        form.onResize = { [weak self] size in
            guard let self else { return }
            let xSizeClient = size.width - mx * 2
            let yPos = size.height - my - button.height
            RcPlace.label(self.statusLabel, NSRect(x: statusRect.minX, y: statusRect.minY, width: xSizeClient, height: statusRect.height))
            RcPlace.label(self.fileNameLabel, NSRect(x: fileRect.minX, y: fileRect.minY, width: xSizeClient, height: fileRect.height))
            self.progressBar.frame = NSRect(x: barRect.minX, y: barRect.minY, width: xSizeClient, height: barRect.height)
            // the buttons: 3 x 120 px with mx between them, squeezed when the window is narrow
            var bSizeX = button.width
            var mx2 = mx
            while bSizeX * 3 + mx2 * 2 > xSizeClient {
                if mx2 < 5 { bSizeX = (xSizeClient - mx2 * 2) / 3; break }
                mx2 -= 1
            }
            bSizeX = max(2, bSizeX)
            var listHeight = yPos - my - listRect.minY
            var listWidth = xSizeClient
            if listHeight < button.height * 7 / 4 {
                listHeight = button.height * 7 / 4
                if listWidth > bSizeX * 2 { listWidth -= bSizeX }
            }
            self.messageList.frame = NSRect(x: mx, y: listRect.minY, width: listWidth, height: listHeight)
            var x = size.width - mx - bSizeX
            for b in [self.cancelButton, self.pauseButton, self.backgroundButton] {
                RcPlace.button(b, NSRect(x: x, y: yPos, width: bSizeX, height: button.height))
                x -= mx2 + bSizeX
            }
            // the two label / value columns
            let valueSize = DLU.x(72)                            // MY_PROGRESS_VAL_UNITS
            var labelSize = DLU.x(60)                            // MY_PROGRESS_LABEL_UNITS_MIN
            // MY_PROGRESS_PAD_UNITS: 4 DLU; 7zFM 26.03 lays the columns out as if it were 7 px
            // (labels 135, values 108, second column at 309 in a 564 px client: dlg-progress-run.txt).
            let required = (labelSize + valueSize) * 2 + 7
            if required < xSizeClient {
                labelSize += ((xSizeClient - required) / 3).rounded(.down)
            } else {
                labelSize = max(0, ((xSizeClient - valueSize * 2 - 7) / 2).rounded(.down))
            }
            let gSize = labelSize + valueSize
            let padSize = xSizeClient - gSize * 2
            var y = my
            for (i, pair) in pairs.enumerated() {
                if i == 5 { y = my }
                let x = i < 5 ? mx : mx + gSize + padSize
                if let label = pair.0 { RcPlace.label(label, NSRect(x: x, y: y, width: labelSize, height: sY)) }
                RcPlace.label(pair.1, NSRect(x: x + labelSize, y: y, width: valueSize, height: sY))
                y += sStep
            }
        }

        window.delegate = self
        // Centred on the window the operation was started from (the key / main window), as
        // CProgressDialog is created with the main window as its owner -- not on the screen.
        RcPlace.install(form, in: window, size: rc.size, parent: nil)
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
            // ShowItem(IDL_PROGRESS_MESSAGES) in its place; the window keeps its size.
            messageList.isHidden = false
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
        // No status text of its own: OnExternalCloseMessage only re-labels the buttons, so the
        // count stays in the Errors row and IDT_PROGRESS_STATUS 103 is empty (winmatch,
        // wincompare dlg-test-broken-final).
        if hasMessages { statusLabel.stringValue = "" }
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
