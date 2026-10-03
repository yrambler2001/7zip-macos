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
    private let elapsedValue = DialogKit.value("")            // IDT_BENCH_ELAPSED_VAL 140
    private let passesValue = DialogKit.value("")             // IDT_BENCH_PASSES_VAL 142
    private let errorMessage = DialogKit.label("", alignment: .right)   // IDT_BENCH_ERROR_MESSAGE 161
    private let logLabel = NSTextView()                       // IDT_BENCH_LOG 160
    private let consoleEdit = NSTextView()                    // IDE_BENCH2_EDIT 100
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
        for label in [cpuLabel, featureLabel, sys1Label, sys2Label, hardwareThreads] {
            label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            label.lineBreakMode = .byTruncatingTail
        }
        versionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

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
        passesCombo.selectItem(at: 0)
        passesCombo.target = self
        passesCombo.action = #selector(comboChanged)

        for view in [logLabel, consoleEdit] {
            view.isEditable = false
            view.isSelectable = true
            view.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            view.drawsBackground = true
            view.backgroundColor = .textBackgroundColor
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.textContainer?.widthTracksTextView = true
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        }
        errorMessage.textColor = .systemRed
        errorMessage.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    }

    private func valueRow() -> [NSTextField] {
        (0..<5).map { _ in DialogKit.value(Self.processingString) }
    }

    private func buildLayout(parent: NSWindow?) {
        // ----- header: dictionary, memory usage, threads
        let header = NSGridView(numberOfColumns: 4, rows: 2)
        header.addRow(with: [DialogKit.label(Lang.text(4006, "Dictionary size:")),   // IDT_BENCH_DICTIONARY 4006
                             dictionaryCombo,
                             DialogKit.label(Lang.text(7601, "Memory usage:")),      // IDT_BENCH_MEMORY 7601
                             memoryValue])
        header.addRow(with: [DialogKit.label(Lang.dialogText(7600, 4009, "Number of CPU threads:")), // IDT_BENCH_NUM_THREADS 4009
                             threadsCombo,
                             DialogKit.label(""),
                             hardwareThreads])
        header.rowSpacing = 6
        header.columnSpacing = 8

        let content: NSView
        if totalMode {
            let scroll = NSScrollView()
            scroll.documentView = consoleEdit
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.translatesAutoresizingMaskIntoConstraints = false
            scroll.addConstraint(NSLayoutConstraint(item: scroll, attribute: .height, relatedBy: .greaterThanOrEqual,
                                                    toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 320))
            consoleEdit.minSize = NSSize(width: 0, height: 320)
            consoleEdit.autoresizingMask = [.width]
            content = scroll
        } else {
            content = buildResultsView()
        }

        let buttons = NSStackView(views: [restartButton, stopButton, NSView(), helpButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let info = NSStackView(views: [cpuLabel, versionLabel, featureLabel, sys1Label, sys2Label])
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 2

        let stack = NSStackView(views: [header, content, errorMessage, info, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for view in [header, content, errorMessage, info, buttons] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        DialogKit.install(stack, in: window, parent: parent, minimumWidth: totalMode ? 720 : 900)
    }

    /// The value grid plus the log column (IDD_BENCH is 332 + 140 du wide).
    private func buildResultsView() -> NSView {
        compressCurrent = valueRow()          // IDT_BENCH_COMPRESS_SIZE1 170 is element [4]
        compressResulting = valueRow()
        decompressCurrent = valueRow()        // the IDT_BENCH_CURRENT2 7656 row
        decompressResulting = valueRow()      // the IDT_BENCH_RESULTING2 7657 row
        totalValues = [DialogKit.value(Self.processingString),    // IDT_BENCH_TOTAL_USAGE_VAL 133
                       DialogKit.value(Self.processingString),    // IDT_BENCH_TOTAL_RPU_VAL 131
                       DialogKit.value(Self.processingString)]    // IDT_BENCH_TOTAL_RATING_VAL 130

        // Column headers, localized with the colon removed (kLangIDs_RemoveColon for Speed).
        func header(_ id: UInt32, _ text: String) -> NSTextField {
            DialogKit.label(Lang.text(id, text).replacingOccurrences(of: ":", with: ""), alignment: .right, bold: true)
        }
        let grid = NSGridView(numberOfColumns: 6, rows: 0)
        grid.addRow(with: [DialogKit.label(""),
                           header(1007, "Size"),          // IDT_BENCH_SIZE 1007
                           header(7608, "CPU Usage"),     // IDT_BENCH_USAGE_LABEL 7608
                           header(3903, "Speed:"),        // IDT_BENCH_SPEED 3903
                           header(7609, "Rating / Usage"),// IDT_BENCH_RPU_LABEL 7609
                           header(7604, "Rating")])       // IDT_BENCH_RATING_LABEL 7604

        func addGroup(_ title: String, current: [NSTextField], resulting: [NSTextField]) {
            let group = DialogKit.label(title, bold: true)
            grid.addRow(with: [group])
            // IDT_BENCH_CURRENT 7606 (IDT_BENCH_CURRENT2 7656 in the decompress group, which
            // Windows also labels with 7606 text)
            grid.addRow(with: [DialogKit.label("    " + Lang.text(7606, "Current")),
                               current[4], current[0], current[1], current[2], current[3]])
            // IDT_BENCH_RESULTING 7607 / IDT_BENCH_RESULTING2 7657
            grid.addRow(with: [DialogKit.label("    " + Lang.text(7607, "Resulting")),
                               resulting[4], resulting[0], resulting[1], resulting[2], resulting[3]])
        }
        addGroup(Lang.text(7602, "Compressing"), current: compressCurrent, resulting: compressResulting)  // IDG_BENCH_COMPRESSING 7602
        addGroup(Lang.text(7603, "Decompressing"), current: decompressCurrent, resulting: decompressResulting)  // IDG_BENCH_DECOMPRESSING 7603
        // IDG_BENCH_TOTAL_RATING 7605
        grid.addRow(with: [DialogKit.label(Lang.text(7605, "Total Rating"), bold: true),
                           DialogKit.label(""), totalValues[0], DialogKit.label(""),
                           totalValues[1], totalValues[2]])
        grid.rowSpacing = 4
        grid.columnSpacing = 10

        // Elapsed time / Passes
        let footer = NSGridView(numberOfColumns: 3, rows: 2)
        footer.addRow(with: [DialogKit.label(Lang.text(3900, "Elapsed time:")),   // IDT_BENCH_ELAPSED 3900
                             elapsedValue, DialogKit.label("")])
        footer.addRow(with: [DialogKit.label(Lang.text(7610, "Passes:")),         // IDT_BENCH_PASSES 7610
                             passesValue, passesCombo])
        footer.rowSpacing = 6
        footer.columnSpacing = 8

        let left = NSStackView(views: [grid, footer])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 12

        let logScroll = NSScrollView()
        logScroll.documentView = logLabel
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logLabel.minSize = NSSize(width: 0, height: 260)
        logLabel.autoresizingMask = [.width]
        logScroll.addConstraint(NSLayoutConstraint(item: logScroll, attribute: .width, relatedBy: .greaterThanOrEqual,
                                                   toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 260))
        logScroll.addConstraint(NSLayoutConstraint(item: logScroll, attribute: .height, relatedBy: .greaterThanOrEqual,
                                                   toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 260))

        let row = NSStackView(views: [left, logScroll])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 12
        return row
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
        logLabel.string = ""
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
        let alert = NSAlert()
        alert.messageText = "7-Zip"
        alert.informativeText = text
        alert.alertStyle = .critical
        alert.addButton(withTitle: Lang.text(401, "OK"))
        alert.runModal()
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
        logLabel.string = bench.logText
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
        NSApp.runModal(for: dialog.window)
        dialog.isModal = false
        dialog.bench.requestStop()
        dialog.bench.waitUntilFinished()
        dialog.window.orderOut(nil)
    }
}
