// BenchmarkDialog.swift -- Tools > Benchmark (IDM_BENCHMARK 901), the in-process port of
// GUI/BenchmarkDialog.cpp (IDD_BENCH 7600, resizable; IDD_BENCH_TOTAL 7699 for `-mm=*`).
//
// 7zFM spawns `7zG b`; the macOS app runs SZBenchmark in-process instead
// (01-fm-feature-inventory.md 2.5, 8.1, 9 #1). Every control keeps its Windows id in a
// comment. Parity: 01b-fm-dialogs-settings.md 4.26.

import AppKit
import SevenZipKit

final class BenchmarkDialog: NSObject, SZBenchmarkDelegate, NSWindowDelegate {

    // MARK: Windows constants

    private static let timerInterval: TimeInterval = 1.0      // kTimerElapse 1000 ms
    private static let processingString = "..."               // kProcessingString
    static let defaultPasses: UInt32 = 10                     // k_NumBenchIterations_Default

    // MARK: state

    private let window: NSWindow
    private let bench = SZBenchmark()
    private var timer: Timer?
    private var startTime = Date()
    private var finishTime: Date?
    private var needRestart = false
    private var wasStoppedInGUI = false
    private var exitWasAskedInGUI = false
    private var isModal = false
    private var elapsedPrevious = ""
    private var passesFinishedPrevious = UInt32.max

    /// TotalMode (`-mm=*`): a read-only fixed-pitch text view instead of the value grid.
    private let totalMode: Bool

    // MARK: controls

    private let dictionaryCombo = NSPopUpButton()             // IDC_BENCH_DICTIONARY 101
    private let memoryValue = DialogKit.label("")             // IDT_BENCH_MEMORY_VAL 102
    private let threadsCombo = NSPopUpButton()                // IDC_BENCH_NUM_THREADS 103
    private let hardwareThreads = DialogKit.label("")         // IDT_BENCH_HARDWARE_THREADS 104
    private let passesCombo = NSPopUpButton()                 // IDC_BENCH_NUM_PASSES 143
    private let elapsedValue = DialogKit.label("", alignment: .right)   // IDT_BENCH_ELAPSED_VAL 140
    private let passesValue = DialogKit.label("", alignment: .right)    // IDT_BENCH_PASSES_VAL 142
    private let errorMessage = DialogKit.label("", alignment: .right)   // IDT_BENCH_ERROR_MESSAGE 161
    private let logLabel = RcPlace.makeWrappingLabel("")      // IDT_BENCH_LOG 160 (a static)
    private let consoleEdit = NSTextView()                    // IDE_BENCH2_EDIT 100
    private let consoleScroll = WinScrollView()
    private let restartButton: NSButton                       // IDB_RESTART 443
    private let stopButton: NSButton                          // IDB_STOP 442
    private let helpButton: NSButton                          // IDHELP
    private let cancelButton: NSButton                        // IDCANCEL

    private let cpuLabel = DialogKit.label("", alignment: .right)   // IDT_BENCH_CPU 106
    private let versionLabel = DialogKit.label("", alignment: .right) // IDT_BENCH_VER 105
    private let featureLabel = DialogKit.label("")            // IDT_BENCH_CPU_FEATURE 109
    private let sys1Label = DialogKit.label("")               // IDT_BENCH_SYS1 107
    private let sys2Label = DialogKit.label("")               // IDT_BENCH_SYS2 108

    /// [usage, speed, rpu, rating, size] per row, in the k_Ids_* order.
    private var compressCurrent: [NSTextField] = []           // 114 110 116 112 170
    private var compressResulting: [NSTextField] = []         // 115 111 117 113 171
    private var decompressCurrent: [NSTextField] = []         // 122 118 124 120 172
    private var decompressResulting: [NSTextField] = []       // 123 119 125 121 173
    private var totalValues: [NSTextField] = []               // 133 (usage), 131 (rpu), 130 (rating)

    private var dictionarySizes: [UInt64] = []
    private var threadCounts: [UInt32] = []
    private var passCounts: [UInt32] = []

    // MARK: init

    private init(totalMode: Bool, parent: NSWindow?) {
        self.totalMode = totalMode
        window = DialogKit.window(title: Lang.text(7600, "Benchmark"), resizable: true)
        restartButton = DialogKit.button(Lang.text(443, "Restart"), target: nil, action: #selector(restartClicked))
        stopButton = DialogKit.button(Lang.text(442, "Stop"), target: nil, action: #selector(stopClicked))
        helpButton = DialogKit.button(Lang.text(409, "Help"), target: nil, action: #selector(helpClicked))
        cancelButton = DialogKit.button(Lang.text(402, "Cancel"), target: nil, action: #selector(cancelClicked),
                                        key: "\u{1b}")
        super.init()
        for button in [restartButton, stopButton, helpButton, cancelButton] { button.target = self }
        bench.delegate = self
        bench.totalMode = totalMode
        window.delegate = self
        buildControls()
        buildLayout(parent: parent)
        restartBenchmark()
    }

    // MARK: control construction (OnInit, BenchmarkDialog.cpp:449-630)

    private func buildControls() {
        // ----- statics set once
        cpuLabel.stringValue = SZBenchmark.cpuName
        versionLabel.stringValue = SZBenchmark.versionWithCPUText
        featureLabel.stringValue = SZBenchmark.cpuFeaturesText
        sys1Label.stringValue = SZBenchmark.systemInfoLine1
        sys2Label.stringValue = SZBenchmark.systemInfoLine2
        sys1Label.isHidden = sys1Label.stringValue.isEmpty
        sys2Label.isHidden = sys2Label.stringValue.isEmpty
        hardwareThreads.stringValue = SZBenchmark.hardwareThreadsText

        // ----- Number of CPU threads (:531-548): 1, 2, 4, 6, ... up to 2 x system threads
        let processThreads = SZBenchmark.processThreadCount
        let systemThreads = max(1, SZBenchmark.systemThreadCount)
        var numThreads = processThreads & ~UInt32(1)
        if numThreads == 0 { numThreads = 1 }
        numThreads = min(numThreads, 1 << 14)
        let comboLimit = systemThreads * 2
        var value: UInt32 = 1
        var selected = 0
        while value <= comboLimit {
            threadCounts.append(value)
            var index = threadCounts.count - 1
            let next = value + (value < 2 ? 1 : 2)
            if value <= numThreads, numThreads < next || next > comboLimit {
                if value != numThreads {
                    threadCounts.append(numThreads)
                    index = threadCounts.count - 1
                }
                selected = index
            }
            value = next
        }
        threadsCombo.removeAllItems()
        threadsCombo.addItems(withTitles: threadCounts.map { "\($0)" })
        threadsCombo.selectItem(at: min(selected, threadCounts.count - 1))
        threadsCombo.target = self
        threadsCombo.action = #selector(comboChanged)

        // ----- Dictionary size (:585-604): 2*2^n and 3*2^n from 256 KB to 4 GB
        let ramKnown = SZBenchmark.ramSize != 0
        var initialDictionary: UInt64 = 1 << 25                 // dicSizeLog = 25 (32 MB)
        if ramKnown {
            var log = 25
            while log > Int(SZBenchmark.minimumDictionaryLog) {
                let usage = SZBenchmark.memoryUsage(forThreads: currentThreadCount, level: -1,
                                                    dictionary: UInt64(1) << log, totalMode: totalMode)
                if SZBenchmark.isMemoryUsageOK(usage) { break }
                log -= 1
            }
            initialDictionary = UInt64(1) << log
        }
        initialDictionary = max(SZBenchmark.minimumDictionarySize,
                                min(SZBenchmark.maximumDictionarySize, initialDictionary))
        var titles: [String] = []
        var dictSelected = 0
        var i = (Int(SZBenchmark.minimumDictionaryLog) - 1) * 2
        while i <= (32 - 1) * 2 {
            let dict = UInt64(2 + (i & 1)) << (i / 2)
            let text: String
            if dict >= (UInt64(1) << 31) {
                text = "\(dict >> 30) GB"
            } else if dict >= (UInt64(1) << 21) {
                text = "\(dict >> 20) MB"
            } else {
                text = "\(dict >> 10) KB"
            }
            dictionarySizes.append(dict)
            titles.append(text)
            if dict <= initialDictionary { dictSelected = dictionarySizes.count - 1 }
            if dict >= SZBenchmark.maximumDictionarySize { break }
            i += 1
        }
        dictionaryCombo.removeAllItems()
        dictionaryCombo.addItems(withTitles: titles)
        dictionaryCombo.selectItem(at: dictSelected)
        dictionaryCombo.target = self
        dictionaryCombo.action = #selector(comboChanged)

        // ----- Passes (:609-633): 1, 2, 5, 10, 20, 50 ... 10000000
        var pass: UInt32 = 1
        while true {
            passCounts.append(pass)
            let isLast = pass >= 10_000_000
            var next = pass * 10
            if pass < 2 { next = 2 } else if pass < 5 { next = 5 } else if pass < 10 { next = 10 }
            pass = next
            if isLast { break }
        }
        passesCombo.removeAllItems()
        passesCombo.addItems(withTitles: passCounts.map { "\($0)" })
        // NumPasses_Limit = k_NumBenchIterations_Default (10) when 7zFM starts `7zG b`
        // (GUI.cpp:229-234); 7zFM 26.03 shows "10" (dlgfeel-data/win/dlg-bench-start.txt).
        passesCombo.selectItem(at: passCounts.firstIndex(of: Self.defaultPasses) ?? 0)
        passesCombo.target = self
        passesCombo.action = #selector(comboChanged)

        for view in [consoleEdit] {
            view.isEditable = false
            view.isSelectable = true
            // IDE_BENCH2_EDIT gets a fixed-pitch font (BenchmarkDialog.cpp: CreateFont "Courier New").
            view.font = NSFont(name: "Courier New", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            view.drawsBackground = true
            view.backgroundColor = .textBackgroundColor
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.textContainer?.widthTracksTextView = true
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        }
    }

    private func valueRow() -> [NSTextField] {
        (0..<5).map { _ in DialogKit.label(Self.processingString, alignment: .right) }
    }

    /// IDD_BENCH 7600 (BenchmarkDialog.rc): 488 x 264 DLU = 732 x 429 px, every control on its
    /// template rect; the value columns never move. The window is resizable as on Windows
    /// (WS_THICKFRAME, measured), and OnSize only stretches the log static IDT_BENCH_LOG
    /// (BenchmarkDialog.cpp:645-659, dlgfeel-data/win/dlg-bench-resized.txt).
    /// IDD_BENCH_TOTAL 7699 for TotalMode: the console edit fills the window, Help / Cancel stay
    /// at the bottom right.
    private func buildLayout(parent: NSWindow?) {
        let form = RcFormView()
        let rc: RcDialog
        if totalMode {
            rc = RcDialog(7699)
            form.add(DialogKit.label(Lang.text(3900, "Elapsed time:")), rc, 3900)       // IDT_BENCH_ELAPSED 3900
            form.add(elapsedValue, rc, 140)
            consoleScroll.documentView = consoleEdit
            consoleScroll.hasVerticalScroller = true
            consoleScroll.hasHorizontalScroller = true
            consoleScroll.borderType = .lineBorder
            consoleEdit.autoresizingMask = [.width]
            form.addSubview(consoleScroll)
            consoleScroll.frame = rc.rect(100)
            form.add(helpButton, rc, 9)
            form.add(cancelButton, rc, 2)
            let margin = RcDialog.margin
            form.onResize = { [weak self] size in
                guard let self else { return }
                // OnSize (TotalMode): Cancel and Help at the bottom right, the edit above them.
                let cancel = rc.rect(2), help = rc.rect(9)
                let y = size.height - margin.height - cancel.height
                RcPlace.button(self.cancelButton, NSRect(x: size.width - margin.width - cancel.width, y: y,
                                                         width: cancel.width, height: cancel.height))
                RcPlace.button(self.helpButton, NSRect(x: size.width - margin.width - cancel.width - margin.width - help.width,
                                                       y: y, width: help.width, height: help.height))
                let top = rc.rect(100).minY
                self.consoleScroll.frame = NSRect(x: margin.width, y: top, width: size.width - 2 * margin.width,
                                                  height: max(20, y - margin.height - top))
            }
        } else {
            rc = RcDialog(7600)
            buildResultsView(form, rc)
            form.onResize = { [weak self] size in
                guard let self else { return }
                let log = rc.rect(160)
                let margin = RcDialog.margin
                RcPlace.label(self.logLabel, NSRect(x: log.minX, y: log.minY,
                                                    width: max(0, size.width - log.minX - margin.width),
                                                    height: max(0, size.height - log.minY - margin.height)))
            }
        }
        window.contentView = form
        RcPlace.install(form, in: window, size: rc.size, parent: parent)
    }

    private func buildResultsView(_ form: RcFormView, _ rc: RcDialog) {
        compressCurrent = valueRow()          // IDT_BENCH_COMPRESS_SIZE1 170 is element [4]
        compressResulting = valueRow()
        decompressCurrent = valueRow()        // the IDT_BENCH_CURRENT2 7656 row
        decompressResulting = valueRow()      // the IDT_BENCH_RESULTING2 7657 row
        totalValues = (0..<3).map { _ in DialogKit.label(Self.processingString, alignment: .right) }

        form.add(DialogKit.label(Lang.text(4006, "Dictionary size:")), rc, 4006)        // IDT_BENCH_DICTIONARY 4006
        form.add(dictionaryCombo, rc, 101)
        form.add(DialogKit.label(Lang.text(7601, "Memory usage:")), rc, 7601)           // IDT_BENCH_MEMORY 7601
        form.add(memoryValue, rc, 102)
        form.add(DialogKit.label(Lang.dialogText(7600, 4009, "Number of CPU threads:")), rc, 4009)  // IDT_BENCH_NUM_THREADS 4009
        form.add(threadsCombo, rc, 103)
        form.add(hardwareThreads, rc, 104)
        form.add(restartButton, rc, 443)
        form.add(stopButton, rc, 442)

        // Column headers (RTEXT), localized with the colon removed (kLangIDs_RemoveColon: Speed).
        func header(_ id: UInt32, _ text: String) {
            form.add(DialogKit.label(Lang.text(id, text).replacingOccurrences(of: ":", with: ""), alignment: .right),
                     rc, Int(id))
        }
        header(1007, "Size")             // IDT_BENCH_SIZE 1007
        header(7608, "CPU Usage")        // IDT_BENCH_USAGE_LABEL 7608
        header(3903, "Speed:")           // IDT_BENCH_SPEED 3903
        header(7609, "Rating / Usage")   // IDT_BENCH_RPU_LABEL 7609
        header(7604, "Rating")           // IDT_BENCH_RATING_LABEL 7604

        form.add(WinGroupBox(title: Lang.text(7602, "Compressing")), rc, 7602)          // IDG_BENCH_COMPRESSING 7602
        form.add(WinGroupBox(title: Lang.text(7603, "Decompressing")), rc, 7603)        // IDG_BENCH_DECOMPRESSING 7603
        form.add(WinGroupBox(title: Lang.text(7605, "Total Rating")), rc, 7605)         // IDG_BENCH_TOTAL_RATING 7605
        // IDT_BENCH_CURRENT 7606 / IDT_BENCH_RESULTING 7607, and their decompress twins 7656 / 7657
        // (labelled with the 7606 / 7607 texts, BenchmarkDialog.cpp kLangIDs).
        form.add(DialogKit.label(Lang.text(7606, "Current")), rc, 7606)
        form.add(DialogKit.label(Lang.text(7607, "Resulting")), rc, 7607)
        form.add(DialogKit.label(Lang.text(7606, "Current")), rc, 7656)
        form.add(DialogKit.label(Lang.text(7607, "Resulting")), rc, 7657)
        // [usage, speed, rpu, rating, size] -> the k_Ids_* of each row
        let rows: [([NSTextField], [Int])] = [(compressCurrent, [114, 110, 116, 112, 170]),
                                              (compressResulting, [115, 111, 117, 113, 171]),
                                              (decompressCurrent, [122, 118, 124, 120, 172]),
                                              (decompressResulting, [123, 119, 125, 121, 173])]
        for (fields, ids) in rows {
            for (field, id) in zip(fields, ids) { form.add(field, rc, id) }
        }
        for (field, id) in zip(totalValues, [133, 131, 130]) { form.add(field, rc, id) }  // IDT_BENCH_TOTAL_*_VAL
        form.add(errorMessage, rc, 161)
        form.add(DialogKit.label(Lang.text(3900, "Elapsed time:")), rc, 3900)           // IDT_BENCH_ELAPSED 3900
        form.add(DialogKit.label(Lang.text(7610, "Passes:")), rc, 7610)                 // IDT_BENCH_PASSES 7610
        form.add(elapsedValue, rc, 140)
        form.add(passesValue, rc, 142)
        form.add(passesCombo, rc, 143)
        form.add(cpuLabel, rc, 106)
        form.add(versionLabel, rc, 105)
        form.add(featureLabel, rc, 109)
        form.add(sys1Label, rc, 107)
        form.add(sys2Label, rc, 108)
        // The machine's own description (uname, the CPU's name and features) is longer on a Mac
        // than Windows' and has no room to grow: its last visible line ends in an ellipsis rather
        // than half a line (sffont).
        for label in [cpuLabel, versionLabel, featureLabel, sys1Label, sys2Label] {
            label.cell?.truncatesLastVisibleLine = true
        }
        form.add(logLabel, rc, 160)
        form.add(helpButton, rc, 9)
        form.add(cancelButton, rc, 2)
    }

    // MARK: current combo values

    private var currentDictionarySize: UInt64 {
        let index = dictionaryCombo.indexOfSelectedItem
        guard index >= 0, index < dictionarySizes.count else { return 1 << 25 }
        return dictionarySizes[index]
    }

    private var currentThreadCount: UInt32 {
        let index = threadsCombo.indexOfSelectedItem
        guard index >= 0, index < threadCounts.count else { return 1 }
        return threadCounts[index]
    }

    private var currentPassCount: UInt32 {
        let index = passesCombo.indexOfSelectedItem
        guard index >= 0, index < passCounts.count else { return 1 }
        return passCounts[index]
    }

    /// OnChangeDictionary (:740-765) + Print_MemUsage (:732-738): "<N> MB / <RAM> MB".
    @discardableResult
    private func updateMemoryUsage() -> UInt64 {
        let dictionary = currentDictionarySize
        let usage = SZBenchmark.memoryUsage(forThreads: currentThreadCount, level: -1,
                                           dictionary: dictionary, totalMode: totalMode)
        func mb(_ bytes: UInt64) -> String { "\((bytes + (1 << 20) - 1) >> 20) MB" }
        var text = mb(usage)
        let ram = SZBenchmark.ramSize
        if ram != 0 { text += " / " + mb(ram) }
        memoryValue.stringValue = text
        return usage
    }

    // MARK: start / restart / stop (:857-980)

    private func startBenchmark() {
        needRestart = false
        wasStoppedInGUI = false
        errorMessage.stringValue = ""
        killTimer()

        let usage = updateMemoryUsage()
        for field in compressCurrent + compressResulting + decompressCurrent + decompressResulting + totalValues {
            field.stringValue = Self.processingString
        }
        logLabel.stringValue = ""
        elapsedValue.stringValue = ""
        passesValue.stringValue = ""
        passesFinishedPrevious = UInt32.max
        elapsedPrevious = ""

        if !SZBenchmark.isMemoryUsageOK(usage) {
            // SetErrorMessage_MemUsage (:880-900): an error box and no run.
            let required = Lang.text(7812, "required memory usage size")
            let text = "\(required): \((usage + (1 << 20) - 1) >> 20) MB / \((SZBenchmark.ramSizeLimit + (1 << 20) - 1) >> 20) MB"
            showError("ERROR: " + text)
            return
        }

        stopButton.isEnabled = true
        startTime = Date()
        finishTime = nil

        bench.dictionarySize = currentDictionarySize
        bench.numberOfThreads = currentThreadCount
        bench.numberOfPasses = currentPassCount
        bench.level = -1
        printTime()

        do {
            try bench.start()
        } catch {
            showError("ERROR: " + error.localizedDescription)
            return
        }
        let ticker = Timer(timeInterval: Self.timerInterval, repeats: true) { [weak self] _ in
            self?.updateGui()
        }
        RunLoop.main.add(ticker, forMode: .common)
        timer = ticker
    }

    /// RestartBenchmark (:922-935)
    private func restartBenchmark() {
        if exitWasAskedInGUI { return }
        if bench.isRunning {
            needRestart = true
            sendExit(status: "Stop for restart ...")
        } else {
            startBenchmark()
        }
    }

    private func sendExit(status: String) {
        errorMessage.stringValue = status
        bench.requestStop()
    }

    private func disableStopButton() {
        if window.firstResponder === stopButton { window.makeFirstResponder(restartButton) }
        stopButton.isEnabled = false
    }

    private func killTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func showError(_ text: String) {
        errorMessage.stringValue = text
        WinMessageBox.run(text, icon: .error, owner: window)    // BenchmarkDialog.cpp:370, MB_ICONERROR
    }

    // MARK: actions

    @objc private func restartClicked() { restartBenchmark() }

    /// OnStopButton (:949-961)
    @objc private func stopClicked() {
        if exitWasAskedInGUI { return }
        disableStopButton()
        wasStoppedInGUI = true
        if bench.isRunning { sendExit(status: "Stop ...") }
    }

    @objc private func helpClicked() { Help.show(topic: Help.benchmark) }

    /// OnCancel (:965-978): ask the worker to exit, close only when the thread has ended.
    @objc private func cancelClicked() {
        exitWasAskedInGUI = true
        cancelButton.isEnabled = false
        if bench.isRunning {
            sendExit(status: "Cancel ...")
        } else {
            closeWindow()
        }
    }

    /// Combo changes restart the run (OnCommand :1385-1396).
    @objc private func comboChanged(_ sender: Any?) {
        updateMemoryUsage()
        restartBenchmark()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancelClicked()
        return false
    }

    private func closeWindow() {
        killTimer()
        if isModal { NSApp.stopModal() }
    }

    // MARK: SZBenchmarkDelegate (worker thread)

    func benchmarkDidUpdate() {
        // The 1000 ms timer is what repaints; nothing to do here (7zFM posts a message too).
    }

    func benchmarkDidFinish(error: Error?) {
        DispatchQueue.main.async { [weak self] in self?.workerDidFinish(error: error) }
    }

    func benchmarkDidPrintText(_ text: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.totalMode else { return }
            self.consoleEdit.string = self.bench.totalModeText
        }
    }

    /// OnMessage / k_Msg_WPARM_Thread_Finished (:1177-1232)
    private func workerDidFinish(error: Error?) {
        finishTime = Date()
        killTimer()
        bench.waitUntilFinished()
        if !wasStoppedInGUI {
            wasStoppedInGUI = true
            disableStopButton()
        }
        updateGui()
        if let error {
            errorMessage.stringValue = "ERROR: " + error.localizedDescription
        }
        if exitWasAskedInGUI {
            closeWindow()
            return
        }
        if let error {
            showError("ERROR: " + error.localizedDescription)
            return
        }
        errorMessage.stringValue = ""
        if needRestart {
            startBenchmark()
        }
    }

    // MARK: UpdateGui (:1249-1389)

    private func printTime() {
        let end = finishTime ?? Date()
        let elapsed = end.timeIntervalSince(startTime)
        let text: String
        if finishTime != nil {
            text = String(format: "%.0f.%03d s", floor(elapsed), Int((elapsed - floor(elapsed)) * 1000))
        } else {
            text = "\(Int(elapsed)) s"
        }
        if text == elapsedPrevious { return }
        elapsedPrevious = text
        elapsedValue.stringValue = text
    }

    private func updateGui() {
        printTime()
        if totalMode {
            consoleEdit.string = bench.totalModeText
            return
        }
        let finished = bench.passesFinished
        if finished != passesFinishedPrevious {
            passesValue.stringValue = "\(finished) /"       // "<finished> /"
            passesFinishedPrevious = finished
        }
        apply(bench.currentEncode, to: compressCurrent)
        apply(bench.resultingEncode, to: compressResulting)
        apply(bench.currentDecode, to: decompressCurrent)
        apply(bench.resultingDecode, to: decompressResulting)
        if bench.didFinishAllPasses {
            let total = bench.totalRating
            if total.isDefined {
                totalValues[0].stringValue = total.usageString
                totalValues[1].stringValue = total.ratingPerUsageString
                totalValues[2].stringValue = total.ratingString
            }
        }
        logLabel.stringValue = bench.logText
    }

    /// PrintBenchRes (:1139-1170): [usage, speed, rpu, rating, size].
    private func apply(_ result: SZBenchmarkResult, to fields: [NSTextField]) {
        guard result.isDefined, fields.count == 5 else { return }
        fields[0].stringValue = result.usageString
        fields[1].stringValue = result.speedString
        fields[2].stringValue = result.ratingPerUsageString
        fields[3].stringValue = result.ratingString
        fields[4].stringValue = result.sizeString
    }

    // MARK: entry point

    /// MyBenchmark(totalMode) -- runs modally; returns once the worker thread has ended.
    static func run(totalMode: Bool = false, parent: NSWindow? = nil) {
        let dialog = BenchmarkDialog(totalMode: totalMode, parent: parent)
        dialog.isModal = true
        DialogKit.runModal(for: dialog.window)
        dialog.isModal = false
        dialog.bench.requestStop()
        dialog.bench.waitUntilFinished()
        dialog.window.orderOut(nil)
    }
}
