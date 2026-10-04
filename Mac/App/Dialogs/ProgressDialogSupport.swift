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

    /// ConvertSizeToString (ProgressDialog2.cpp:623-638): plain digits, then KB / MB / GB from
    /// 100000 of the smaller unit -- "67584 KB", "340 MB", "5722 MB" (recheck §5, measured).
    static func size(_ v: UInt64) -> String {
        if v >= UInt64(100000) << 20 { return "\(v >> 30) GB" }
        if v >= UInt64(100000) << 10 { return "\(v >> 20) MB" }
        if v >= 100000 { return "\(v >> 10) KB" }
        return "\(v)"
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
        // A report list like 7zFM's: 17 px rows, a 24 px header, no alternating rows (dlgfeel).
        tableView.headerView = showsHeader ? NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: 24)) : nil
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.allowsMultipleSelection = true
        tableView.dataSource = self
        tableView.style = .plain
        tableView.usesAutomaticRowHeights = false
        tableView.rowHeight = 17
        tableView.intercellSpacing = .zero

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
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

// MARK: - the dialog window

/// The window class of every `DialogKit` dialog. `NSApp.runModal(for:)` **centres a window on the
/// screen** when it orders it in, which undid `install`'s placement for every dialog that went
/// straight into `runModal` -- only Copy / Move / Create Folder, which order themselves front first,
/// stayed on the main window (requests.md, `polish` -> `opsinfra`, measured in
/// `OptGapsTests.testDialogsCentreOnTheirOwnerWindow`). Here `center()` means DS_CENTER: centre on
/// the owner window, and on the screen only when the app shows no window.
final class DialogWindow: NSWindow {

    /// The parent the dialog was installed with (nil = the key / main window, resolved late).
    weak var owner: NSWindow?

    override func center() {
        DialogKit.center(self, over: owner)
    }

    /// The plain AppKit behaviour, for a dialog with no owner at all.
    func centerOnScreen() {
        super.center()
    }

    // MARK: closing a modal dialog (Mac/docs/reports/infohang.md)
    //
    // Every dialog here is run with `NSApp.runModal(for:)` and ends its session from its own
    // buttons. The title-bar close button (and Cmd+W) did not: AppKit closed the window and left
    // the modal session running for a window nobody could see, so every click on the main window
    // was refused and the menus stayed disabled -- the app looked hung ("I clicked Info, closed it
    // and the app became unresponsive"). On Windows the close box of a dialog is WM_CLOSE, which
    // DefDlgProc turns into WM_COMMAND IDCANCEL, i.e. the dialog's own Cancel path.

    /// The close box / Cmd+W of a modal dialog: IDCANCEL. A delegate's `windowShouldClose` still
    /// decides first (the progress and benchmark windows answer it with their own Cancel).
    override func performClose(_ sender: Any?) {
        guard NSApp.modalWindow === self else { super.performClose(sender); return }
        if let delegate, delegate.windowShouldClose?(self) == false { return }
        if let cancel = Self.cancelButton(in: contentView) {
            cancel.performClick(sender)             // the dialog's own OnCancel
        } else {
            NSApp.stopModal(withCode: .cancel)      // CModalDialog::OnCancel -> EndDialog(IDCANCEL)
        }
        if isVisible, NSApp.modalWindow === self { orderOut(nil) }
    }

    /// Cmd+W in a modal dialog closes the dialog, as Alt+F4 (WM_CLOSE -> IDCANCEL) does on Windows.
    /// The menu's Cmd+W is File > Exit (IDCLOSE), which targets the main window and is disabled
    /// while a dialog is modal, so without this the key did nothing at all.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, NSApp.modalWindow === self,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "w" {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Esc in a dialog with no Cancel button (About): DefDlgProc still sends IDCANCEL, which
    /// CModalDialog::OnCancel ends the dialog with -- measured, Esc closes 7zFM's About (recheck §6).
    override func cancelOperation(_ sender: Any?) {
        guard NSApp.modalWindow === self, Self.cancelButton(in: contentView) == nil else { return }
        performClose(sender)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
           NSApp.modalWindow === self, Self.cancelButton(in: contentView) == nil {
            performClose(nil)
            return
        }
        super.keyDown(with: event)
    }

    /// Whatever closed it, a dialog that is gone must not keep its modal session: once the window
    /// is off screen and the session is still its own on the next run-loop pass, end it.
    override func close() {
        let wasModal = NSApp.modalWindow === self
        super.close()
        guard wasModal else { return }
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak self] in
            guard let self, NSApp.modalWindow === self, !self.isVisible else { return }
            NSApp.stopModal(withCode: .abort)
        }
    }

    /// The button that answers Escape (`DialogKit.button(..., key: "\u{1b}")`): IDCANCEL.
    static func cancelButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.keyEquivalent == "\u{1b}", button.isEnabled,
           !button.isHiddenOrHasHiddenAncestor {
            return button
        }
        for subview in view.subviews {
            if let found = cancelButton(in: subview) { return found }
        }
        return nil
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
        let window = DialogWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 200),
                                  styleMask: style, backing: .buffered, defer: false)
        window.title = title
        window.backgroundColor = WinChrome.face          // COLOR_BTNFACE (recheck §2)
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // SZ_DISABLE_ANIMATIONS: every dialog this app builds goes through here, so one call
        // covers all 21 of them appearing and disappearing (a no-op without the switch).
        TestAnimations.apply(to: window)
        return window
    }

    /// The margin between the window edge and the dialog's content (GuiCommon.rc m = 8 du).
    static let margin: CGFloat = 20

    /// Fills the window with `content` inset by the standard margin and sizes the window
    /// to fit, then centres it on its owner: `parent`, or the key / main window when `parent` is
    /// nil (`center(_:over:)`), and on the screen only when the app shows no window.
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
        center(window, over: parent)
    }

    // MARK: placement

    /// The window a dialog belongs to: `parent` when it is on screen, else the key window, else the
    /// main window, else the app's own main 7-Zip window -- never `window` itself. nil only when the
    /// app shows no window at all (7zG / command mode before anything is up).
    ///
    /// Every 7zFM dialog is `MY_MODAL_DIALOG_STYLE` with `DS_CENTER` and is created with an owner,
    /// so Windows centres it on that owner (the main window, or the dialog it was opened from).
    /// Several call sites here have no window at hand and passed nil -- the progress dialog, the
    /// Tools-menu dialogs, Compress Options without a sheet parent, Options -- and those were
    /// centred on the **screen** while Copy / Move / Create Folder sat on the main window
    /// (requests.md, `polish` -> `opsinfra`). Resolving the owner here fixes all of them at once.
    static func owner(for window: NSWindow?, parent: NSWindow?) -> NSWindow? {
        func usable(_ candidate: NSWindow?) -> NSWindow? {
            guard let candidate, candidate !== window, candidate.isVisible || candidate.isMiniaturized,
                  candidate.styleMask.contains(.titled) else { return nil }
            return candidate
        }
        if let parent = usable(parent) { return parent }
        if let key = usable(NSApp.keyWindow) { return key }
        if let main = usable(NSApp.mainWindow) { return main }
        if let ours = usable((NSApp.delegate as? AppDelegate)?.mainWindowController?.window) { return ours }
        return NSApp.orderedWindows.first { usable($0) != nil && $0.windowController is MainWindowController }
    }

    /// Centres `window` on its owner (see `owner(for:parent:)`), kept inside the owner's screen as
    /// `CenterWindow` keeps a dialog inside the work area; on the screen when there is no owner.
    static func center(_ window: NSWindow, over parent: NSWindow?) {
        // Remembered for the `center()` that `runModal(for:)` sends when it orders the window in.
        if let parent, let dialog = window as? DialogWindow { dialog.owner = parent }
        guard let owner = owner(for: window, parent: parent) else {
            if let dialog = window as? DialogWindow { dialog.centerOnScreen() } else { window.center() }
            return
        }
        let frame = owner.frame
        let size = window.frame.size
        var origin = NSPoint(x: (frame.midX - size.width / 2).rounded(),
                             y: (frame.midY - size.height / 2).rounded())
        if let visible = (owner.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width))
            origin.y = min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height))
        }
        window.setFrameOrigin(origin)
    }
}
