// ProgressDialogSupport.swift -- the pieces the progress UI and OperationRunner share:
// the worker/UI hand-off (CProgressSync, ProgressDialog2.h:32-103), the value formatters
// from ProgressDialog2.cpp, the numbered message list (IDL_PROGRESS_MESSAGES 101 /
// IDL_MESSAGE 100) and a few AppKit control factories used by all five dialogs.
//
// Parity: 01b-fm-dialogs-settings.md 4.17, 01-fm-feature-inventory.md 8.7.

import AppKit
import SevenZipKit

// MARK: - CProgressSync

/// One snapshot of the operation state, taken on the main thread by the dialog's timer.
struct ProgressSnapshot {
    var totalBytes: UInt64?
    var completedBytes: UInt64 = 0
    var totalFiles: UInt64?
    var currentFiles: UInt64 = 0
    var inSize: UInt64?
    var outSize: UInt64?
    var status: SZProgressStatus = .none
    var filePath: String = ""
    var isDir = false
    var titleFileName: String = ""
    var messages: [String] = []
    var paused = false
    var background = false
    var finished = false
    var elapsed: TimeInterval = 0
}

/// The lock-protected state the engine's worker thread writes and the dialog reads
/// (CProgressSync). `checkStop()` is what makes Pause and Cancel work: the worker parks
/// inside it while paused (kPauseSleepTime = 100 ms) and gets `true` once stopped.
final class ProgressSync {

    private let lock = NSLock()

    private var totalBytes: UInt64?
    private var completedBytes: UInt64 = 0
    private var totalFiles: UInt64?
    private var currentFiles: UInt64 = 0
    private var inSize: UInt64?
    private var outSize: UInt64?
    private var status: SZProgressStatus = .none
    private var filePath = ""
    private var isDir = false
    private var titleFileName = ""
    private var messages: [String] = []
    private var stopped = false
    private var paused = false
    private var finished = false
    private var startDate = Date()

    /// kPauseSleepTime (ProgressDialog2.cpp:36)
    static let pauseSleepTime: TimeInterval = 0.1
    /// kTimerElapse (ProgressDialog2.cpp:33)
    static let timerInterval: TimeInterval = 0.2
    /// kCreateDelay (ProgressDialog2.cpp:38): no dialog at all for operations that finish
    /// this fast without messages.
    static let createDelay: TimeInterval = 0.5

    // MARK: worker side

    func setTotal(_ value: UInt64) { lock.lock(); totalBytes = value; lock.unlock() }
    func setCompleted(_ value: UInt64) { lock.lock(); completedBytes = value; lock.unlock() }
    func setRatio(inSize: UInt64, outSize: UInt64) {
        lock.lock(); self.inSize = inSize; self.outSize = outSize; lock.unlock()
    }
    func setTotalFiles(_ value: UInt64) { lock.lock(); totalFiles = value; lock.unlock() }
    func setCurrentFiles(_ value: UInt64) { lock.lock(); currentFiles = value; lock.unlock() }
    func setStatus(_ value: SZProgressStatus) { lock.lock(); status = value; lock.unlock() }
    func setFilePath(_ path: String, isDir: Bool) {
        lock.lock(); filePath = path; self.isDir = isDir; lock.unlock()
    }
    func setTitleFileName(_ name: String) { lock.lock(); titleFileName = name; lock.unlock() }

    /// AddMessage (ProgressDialog2.cpp:1173) splits multi-line text into separate rows.
    func addMessage(_ message: String) {
        let lines = message.components(separatedBy: "\n")
        lock.lock()
        messages.append(contentsOf: lines.isEmpty ? [message] : lines)
        lock.unlock()
    }

    /// CProgressSync::CheckStop: true = the worker must return E_ABORT. Blocks while paused.
    func checkStop() -> Bool {
        while true {
            lock.lock()
            let stop = stopped
            let isPaused = paused
            lock.unlock()
            if stop { return true }
            if !isPaused { return false }
            Thread.sleep(forTimeInterval: ProgressSync.pauseSleepTime)
        }
    }

    // MARK: UI side

    var isStopped: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }
    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }
    var messageCount: Int { lock.lock(); defer { lock.unlock() }; return messages.count }

    func setStopped(_ value: Bool) { lock.lock(); stopped = value; lock.unlock() }
    func setPaused(_ value: Bool) { lock.lock(); paused = value; lock.unlock() }
    /// Before_ArcReopen (UpdateCallback100.cpp:124): the caller needs the archive re-opened.
    func clearStopStatus() { lock.lock(); stopped = false; lock.unlock() }
    func setFinished() { lock.lock(); finished = true; lock.unlock() }
    func restartClock() { lock.lock(); startDate = Date(); lock.unlock() }

    func snapshot(background: Bool) -> ProgressSnapshot {
        lock.lock()
        defer { lock.unlock() }
        var s = ProgressSnapshot()
        s.totalBytes = totalBytes
        s.completedBytes = completedBytes
        s.totalFiles = totalFiles
        s.currentFiles = currentFiles
        s.inSize = inSize
        s.outSize = outSize
        s.status = status
        s.filePath = filePath
        s.isDir = isDir
        s.titleFileName = titleFileName
        s.messages = messages
        s.paused = paused
        s.background = background
        s.finished = finished
        s.elapsed = Date().timeIntervalSince(startDate)
        return s
    }
}

// MARK: - value formatting (ProgressDialog2.cpp)

enum ProgressFormatting {

    /// GetTimeString (ProgressDialog2.cpp:602): hh:mm:ss.
    static func time(_ seconds: TimeInterval) -> String {
        let total = UInt64(max(0, seconds.rounded(.down)))
        return String(format: "%02llu:%02llu:%02llu", total / 3600, (total / 60) % 60, total % 60)
    }

    /// elapsed * (total - done) / done (MyMultAndDiv, ProgressDialog2.cpp:795-800).
    static func remaining(elapsed: TimeInterval, total: UInt64?, completed: UInt64) -> String {
        guard let total, completed > 0, total >= completed else { return "" }
        return time(elapsed * Double(total - completed) / Double(completed))
    }

    /// ProgressDialog2.cpp:806-826: B/s below 10000, then KB/s, then MB/s.
    static func speed(bytes: UInt64, elapsed: TimeInterval) -> String {
        guard elapsed > 0 else { return "" }
        let bps = Double(bytes) / elapsed
        if bps < 10000 { return "\(UInt64(bps)) B/s" }
        let kbps = bps / 1024
        if kbps < 10000 { return "\(UInt64(kbps)) KB/s" }
        return "\(UInt64(kbps / 1024)) MB/s"
    }

    /// Set_Ratio (ProgressDialog2.cpp:176): out * 100 / in, as a percentage.
    static func ratio(inSize: UInt64?, outSize: UInt64?) -> String {
        guard let inSize, let outSize, inSize > 0 else { return "" }
        return "\(outSize * 100 / inSize)%"
    }

    /// Percent for the title and the bar (0...100).
    static func percent(completed: UInt64, total: UInt64?) -> Int? {
        guard let total, total > 0 else { return nil }
        return Int(min(100, completed * 100 / total))
    }

    /// The file name field (IDT_PROGRESS_FILE_NAME 102) shows the path on two lines:
    /// folder part and name part (ProgressDialog2.cpp:907-928).
    static func twoLinePath(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let folder = String(path[path.startIndex...slash])
        let name = String(path[path.index(after: slash)...])
        return name.isEmpty ? folder : folder + "\n" + name
    }

    /// kTitleFileNameSizeLimit / kCurrentFileNameSizeLimit (ReduceString, :36-47).
    static func reduce(_ s: String, limit: Int) -> String {
        guard s.count > limit, limit > 4 else { return s }
        let head = limit / 2
        let tail = limit - head - 3
        return String(s.prefix(head)) + "..." + String(s.suffix(tail))
    }
}

// MARK: - numbered message list

/// The error/warning list: the progress dialog's embedded `IDL_PROGRESS_MESSAGES 101`
/// (report mode, no column header) and the Messages dialog's `IDL_MESSAGE 100`
/// (index column + "Message" `IDS_MESSAGE 6603`). Cmd+A / Cmd+C copy, like the
/// Ctrl+A / Ctrl+C of CProgressDialog::CopyToClipboard (ProgressDialog2.cpp:1369).
final class MessageListView: NSView, NSTableViewDataSource {

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private(set) var messages: [String] = []

    init(showsHeader: Bool) {
        super.init(frame: .zero)

        let indexColumn = NSTableColumn(identifier: .init("index"))
        indexColumn.title = ""                                  // 30 du unnamed column
        indexColumn.width = 34
        indexColumn.minWidth = 26
        let messageColumn = NSTableColumn(identifier: .init("message"))
        messageColumn.title = Lang.text(6603, "Message")         // IDS_MESSAGE 6603
        messageColumn.width = 520
        tableView.addTableColumn(indexColumn)
        tableView.addTableColumn(messageColumn)
        tableView.headerView = showsHeader ? NSTableHeaderView() : nil
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.rowSizeStyle = .small
        tableView.dataSource = self
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// UpdateMessagesDialog (ProgressDialog2.cpp:1202): move the new rows into the list.
    func setMessages(_ newMessages: [String]) {
        guard newMessages.count != messages.count else { return }
        messages = newMessages
        tableView.reloadData()
        if !messages.isEmpty {
            tableView.scrollRowToVisible(messages.count - 1)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { messages.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        guard row < messages.count else { return nil }
        if tableColumn?.identifier.rawValue == "index" { return "\(row + 1)" }
        return messages[row]
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "a": tableView.selectAll(nil); return
            case "c": copyToClipboard(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    func copyToClipboard() {
        let rows = tableView.selectedRowIndexes.isEmpty
            ? IndexSet(integersIn: 0..<messages.count) : tableView.selectedRowIndexes
        let text = rows.map { "\($0 + 1)\t\(messages[$0])" }.joined(separator: "\n")
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - control factories

/// Small helpers so every dialog is laid out the same way (GuiCommon.rc: margin m = 8,
/// buttons bxs = 64 x bys = 16 dialog units; on macOS the AppKit metrics stand in).
enum DialogKit {

    static func label(_ text: String, alignment: NSTextAlignment = .left, bold: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = alignment
        field.lineBreakMode = .byTruncatingMiddle
        if bold { field.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) }
        return field
    }

    /// A right-aligned value cell (all progress values are RTEXT in ProgressDialog2a.rc).
    static func value(_ text: String = "") -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        field.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.lineBreakMode = .byClipping
        return field
    }

    static func button(_ title: String, target: AnyObject?, action: Selector, key: String = "") -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .rounded
        button.keyEquivalent = key
        return button
    }

    static func checkbox(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        let box = NSButton(checkboxWithTitle: title, target: target, action: action)
        box.state = .off
        return box
    }

    static func radio(_ title: String, target: AnyObject?, action: Selector?) -> NSButton {
        NSButton(radioButtonWithTitle: title, target: target, action: action)
    }

    /// A modal window without a nib: MY_MODAL_DIALOG_STYLE (caption + close, centred).
    static func window(title: String, resizable: Bool) -> NSWindow {
        var style: NSWindow.StyleMask = [.titled, .closable]
        if resizable { style.insert(.resizable) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                              styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        return window
    }

    /// The margin between the window edge and the dialog's content (GuiCommon.rc m = 8 du).
    static let margin: CGFloat = 20

    /// Fills the window with `content` inset by the standard margin and sizes the window
    /// to fit, then centres it over `parent` (or on screen).
    static func install(_ content: NSView, in window: NSWindow, parent: NSWindow?, minimumWidth: CGFloat) {
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: margin),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -margin),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: margin),
            // -margin, not +margin: Auto Layout's `bottom` grows downwards even in AppKit's
            // flipped-free coordinate space, so a positive constant pushed the whole content
            // `margin` points *below* the window and clipped the button row off the bottom edge
            // (the "Copy dialog is 30 pt too short" report; it hit all 21 DialogKit dialogs).
            content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -margin),
        ])
        window.contentView = host
        host.layoutSubtreeIfNeeded()          // so fittingSize sees the final stack layout
        // Size from the content itself: the host only adds the margins, and its own fitting size
        // can lag behind a stack view that was just populated.
        let fitting = content.fittingSize
        let size = NSSize(width: max(minimumWidth, fitting.width + 2 * margin),
                          height: fitting.height + 2 * margin)
        window.setContentSize(size)
        // A resizable dialog must not be shrinkable into its own controls: the content's fitting
        // size is the floor (01b -- every dialog is fixed-size on Windows, so nothing smaller is
        // a shape the spec asks for).
        window.contentMinSize = size
        host.layoutSubtreeIfNeeded()
        if let parent {
            let frame = parent.frame
            let windowSize = window.frame.size
            window.setFrameOrigin(NSPoint(x: frame.midX - windowSize.width / 2,
                                          y: frame.midY - windowSize.height / 2))
        } else {
            window.center()
        }
    }
}
