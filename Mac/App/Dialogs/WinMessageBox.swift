// WinMessageBox.swift -- Windows' MessageBoxW as 7zFM 26.03 shows it on Windows 11 at 96 dpi, the one
// message box of the app (Mac/docs/reports/recheck2.md section 2).
//
// 7zFM asks every question and reports every error with `::MessageBoxW(owner, text, caption, flags)`
// (01 §2.8, 01b §4.19): MB_OK / MB_OKCANCEL / MB_YESNO / MB_YESNOCANCEL, with MB_ICONSTOP,
// MB_ICONWARNING, MB_ICONINFORMATION, MB_ICONQUESTION or no icon. Measured on the reference PC
// (recheck2-data/win/mb-*.txt, -png; the same geometry for 7zFM's own delete confirmation,
// fm-delete.txt):
//
//   * a separate window with the caption 7zFM passes, **centred on the screen** of its owner -- not on
//     the owner: 7zFM's main window at (78,78) 1440 x 753 and the box's centre at the screen's centre
//     (963,540 on 1920 x 1080), the same as with no owner at all;
//   * a white message area and a (243,243,243) button band 42 px high under it;
//   * the 32 px icon at (21,23), the text at x 62 (11 without an icon), y 23, or centred on a 34 px
//     icon block when it is shorter; lines 13 px apart, wrapped at about 324 px (SS_EDITCONTROL: a
//     word longer than that is broken between characters);
//   * 75 x 23 buttons, right-aligned 15 px from the edge, 83 px apart, 9 px under the band's top
//     (10 when the icon is taller than the text); the client is wide enough for the text (+28), the
//     buttons (27 + buttons + 15) and the caption;
//   * the first button is the default (DM_GETDEFID); Esc and the close box answer IDCANCEL when there
//     is a Cancel button, IDOK for a lone OK, and nothing for MB_YESNO, whose close box is disabled
//     (SC_CLOSE absent from its system menu);
//   * "&Yes" / "&No" answer the Y / N keys; Ctrl+C copies the box as text.
//
// Modal to the app (`DialogKit.runModal(for:)`), always owned by a visible window when the app has one
// (`DialogKit.owner`), and safe without one: it is an ordinary titled window that its own buttons,
// Esc, the close box, Cmd+W and the test reset (`TestResetCoordinator.closeTransientUI`) all end --
// never an ownerless `NSAlert` (Mac/docs/reports/modalfix.md, infohang.md).
//
// The user's exceptions: the native title bar and native push buttons.

import AppKit

enum WinMessageBox {

    /// MB_OK 0, MB_OKCANCEL 1, MB_YESNOCANCEL 3, MB_YESNO 4 -- the four 7zFM uses.
    enum Buttons {
        case ok, okCancel, yesNo, yesNoCancel

        var results: [Result] {
            switch self {
            case .ok: return [.ok]
            case .okCancel: return [.ok, .cancel]
            case .yesNo: return [.yes, .no]
            case .yesNoCancel: return [.yes, .no, .cancel]
            }
        }

        /// What Esc, the close box and Cmd+W answer: IDCANCEL when there is a Cancel button, IDOK for
        /// a lone OK (measured: Esc ends an MB_OK box with 1), nothing for MB_YESNO.
        var escapeResult: Result? {
            switch self {
            case .ok: return .ok
            case .okCancel, .yesNoCancel: return .cancel
            case .yesNo: return nil
            }
        }
    }

    /// MB_ICONHAND / MB_ICONSTOP / MB_ICONERROR 0x10, MB_ICONQUESTION 0x20, MB_ICONWARNING 0x30,
    /// MB_ICONINFORMATION 0x40.
    enum Icon { case none, error, question, warning, information }

    /// IDOK 1, IDCANCEL 2, IDYES 6, IDNO 7.
    enum Result: Int {
        case ok = 1, cancel = 2, yes = 6, no = 7

        var title: String {
            switch self {
            case .ok: return Lang.text(401, "OK")
            case .cancel: return Lang.text(402, "Cancel")
            case .yes: return Lang.text(406, "Yes")
            case .no: return Lang.text(407, "No")
            }
        }

        /// The access key of "&Yes" / "&No" (lang 406 / 407), lower-cased; OK and Cancel have none.
        var accessKey: Character? {
            switch self {
            case .yes: return Self.mnemonic(Lang.get(406, "&Yes"))
            case .no: return Self.mnemonic(Lang.get(407, "&No"))
            case .ok, .cancel: return nil
            }
        }

        private static func mnemonic(_ s: String) -> Character? {
            var it = s.makeIterator()
            while let c = it.next() {
                if c == "&", let next = it.next(), next != "&" { return Character(next.lowercased()) }
            }
            return nil
        }
    }

    /// Every box as it comes up, before its modal session starts (tests answer boxes from here).
    static var observers: [(WinMessageBoxWindow) -> Void] = []

    /// MessageBoxW: shows the box and waits for the answer. `owner` is the window the box belongs
    /// to; when it is nil or gone, the key / main / a 7-Zip window is used, as `DialogKit.owner`
    /// resolves a dialog's owner. Main thread only.
    @discardableResult
    static func run(_ text: String, caption: String = "7-Zip", buttons: Buttons = .ok, icon: Icon = .none,
                    owner: NSWindow?) -> Result {
        run(text, caption: caption, buttons: buttons, icon: icon, owner: owner, asynchronous: false)
    }

    private static func run(_ text: String, caption: String, buttons: Buttons, icon: Icon, owner: NSWindow?,
                            asynchronous: Bool) -> Result {
        let box = WinMessageBoxWindow(text: text, caption: caption, buttons: buttons, icon: icon,
                                      owner: DialogKit.owner(for: nil, parent: owner))
        box.isAsynchronous = asynchronous
        #if DEBUG
        NSLog("7-Zip message box [%@]: %@", caption, text)
        #endif
        return box.runModal()
    }

    /// The same box, shown from the main run loop after the caller has returned (what used to be a
    /// sheet that did not block). The modal session starts in a run-loop block in the common modes,
    /// never inside the caller's main-queue block, so a worker's `DispatchQueue.main.sync` is still
    /// served while the box is up (requests.md, `navgaps`).
    static func show(_ text: String, caption: String = "7-Zip", buttons: Buttons = .ok, icon: Icon = .none,
                     owner: NSWindow?, completion: ((Result) -> Void)? = nil) {
        weak let weakOwner = owner
        let hadOwner = owner != nil
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            // The window it was for closed in the meantime: nobody to tell (ErrorAlert.present).
            if hadOwner, weakOwner == nil || weakOwner?.isVisible == false && weakOwner?.isMiniaturized == false {
                NSLog("7-Zip: %@ (its window is gone)", text)
                return
            }
            let result = run(text, caption: caption, buttons: buttons, icon: icon, owner: weakOwner, asynchronous: true)
            completion?(result)
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }

    /// The boxes on screen, innermost last.
    static var visibleBoxes: [WinMessageBoxWindow] {
        NSApp.windows.compactMap { $0 as? WinMessageBoxWindow }.filter(\.isVisible)
    }
}

// MARK: - geometry

/// The box's client-area geometry in points (one Windows pixel each), top-left origin.
struct WinMessageBoxLayout {

    /// The text font: the dialogs' Segoe UI 9 pt stand-in (DialogMetrics.font, SF Pro 12.2).
    static var font: NSFont { DialogMetrics.font }
    /// Segoe UI 9 pt is about 3.5 % wider than Helvetica Neue 11 over 7zFM's messages (226 px for
    /// "Are you sure you want to delete 'notes.md'?" against 218): widths were scaled by it so the
    /// box had the Windows size and broke its lines where Windows does. A font wider than Segoe UI
    /// (sffont: SF Pro 12.2, `DLU.scaleX` 1.10) is measured as it is, and the box's horizontal
    /// metrics are stretched instead, as the dialogs' are.
    static var segoeScale: CGFloat { DLU.scaleX > 1 ? 1 : 1.035 }
    /// The widest line before a break (Windows px): 321 px still fits ("path"), a word that would
    /// reach 332 px goes to the next line ("wide1").
    static var wrapWidth: CGFloat { DLU.px(324) }
    /// 13 px lines on Windows; a taller font (SF Pro 12.2: 11.8 + 2.6) gets its own glyph height.
    static let lineHeight: CGFloat = max(13, ceil(font.ascender - font.descender))
    /// The first baseline below the text's top (cap top 3 px down, cap height 8): 11, or the
    /// font's ascender when it is taller (12 for SF Pro 12.2).
    static let firstBaseline: CGFloat = max(11, font.ascender.rounded())
    static let iconRect = NSRect(x: 21, y: 23, width: 32, height: 32)
    static let iconBlock: CGFloat = 34
    static var buttonSize: NSSize { NSSize(width: DLU.px(75), height: 23) }
    static var buttonPitch: CGFloat { DLU.px(83) }
    static let bandHeight: CGFloat = 42

    let lines: [String]
    let clientSize: NSSize
    let textFrame: NSRect
    let iconFrame: NSRect?
    let bandTop: CGFloat
    let buttonFrames: [NSRect]

    /// The width Windows would give `s` in the message font.
    static func width(_ s: String) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width * segoeScale
    }

    init(text: String, caption: String, buttonCount: Int, hasIcon: Bool) {
        lines = Self.wrap(text, width: Self.wrapWidth)
        let widest = lines.map(Self.width).max() ?? 0
        let staticWidth = ceil(widest) + 2
        let staticHeight = CGFloat(lines.count) * Self.lineHeight + 2
        let textX: CGFloat = hasIcon ? 62 : 11
        let rightMargin: CGFloat = hasIcon ? 28 : 30
        let iconTaller = hasIcon && staticHeight < Self.iconBlock
        let textY: CGFloat = iconTaller ? 23 + ceil((Self.iconBlock - staticHeight) / 2) : 23
        let content = hasIcon ? max(staticHeight, Self.iconBlock) : staticHeight
        bandTop = 23 + content + 21
        let n = CGFloat(max(buttonCount, 1))
        let buttonsWidth = (n * Self.buttonSize.width + (n - 1) * (Self.buttonPitch - Self.buttonSize.width + 0.5)).rounded()
        let width = max(textX + staticWidth + rightMargin,
                        27 + buttonsWidth + 15,
                        ceil(Self.width(caption)) + 54)
        clientSize = NSSize(width: width, height: bandTop + Self.bandHeight)
        // The static fills the width the box ended up with (askcancel: 243 px for a 169 px text).
        textFrame = NSRect(x: textX, y: textY, width: width - textX - rightMargin, height: staticHeight)
        iconFrame = hasIcon ? Self.iconRect : nil
        let buttonY = bandTop + (iconTaller ? 10 : 9)
        let lastX = width - 15 - Self.buttonSize.width
        buttonFrames = (0..<Int(n)).map { i in
            NSRect(x: lastX - CGFloat(Int(n) - 1 - i) * Self.buttonPitch, y: buttonY,
                   width: Self.buttonSize.width, height: Self.buttonSize.height)
        }
    }

    /// DrawText(DT_WORDBREAK | DT_EXPANDTABS) on an SS_EDITCONTROL static: "\n" ends a line, words
    /// wrap at `width`, and a word wider than a line is broken between characters.
    static func wrap(_ text: String, width: CGFloat) -> [String] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "        ")
        var lines: [String] = []
        for paragraph in normalized.components(separatedBy: "\n") {
            var line = ""
            for word in paragraph.components(separatedBy: " ") {
                let candidate = line.isEmpty ? word : line + " " + word
                if Self.width(candidate) <= width || (line.isEmpty && word.isEmpty) {
                    line = candidate
                    continue
                }
                if !line.isEmpty { lines.append(line) }
                var rest = Substring(word)
                while Self.width(String(rest)) > width, rest.count > 1 {
                    var count = 1
                    while count < rest.count, Self.width(String(rest.prefix(count + 1))) <= width { count += 1 }
                    lines.append(String(rest.prefix(count)))
                    rest = rest.dropFirst(count)
                }
                line = String(rest)
            }
            lines.append(line)
        }
        return lines
    }
}

// MARK: - the window

final class WinMessageBoxWindow: NSWindow {

    let message: String
    let caption: String
    let boxButtons: WinMessageBox.Buttons
    let icon: WinMessageBox.Icon
    let layout: WinMessageBoxLayout
    /// The window the box belongs to (nil only when the app shows no window).
    private(set) weak var ownerWindow: NSWindow?
    /// The push buttons, in the Windows order (Yes, No, Cancel / OK, Cancel).
    private(set) var pushButtons: [NSButton] = []
    private(set) var result: WinMessageBox.Result?
    /// Shown with `WinMessageBox.show`: nobody waits for the answer (an error report).
    var isAsynchronous = false

    init(text: String, caption: String, buttons: WinMessageBox.Buttons, icon: WinMessageBox.Icon, owner: NSWindow?) {
        message = text
        self.caption = caption
        boxButtons = buttons
        self.icon = icon
        ownerWindow = owner
        layout = WinMessageBoxLayout(text: text, caption: caption, buttonCount: buttons.results.count,
                                     hasIcon: icon != .none)
        // MB_YESNO has no Cancel: its close box is disabled (SC_CLOSE is not in its system menu).
        super.init(contentRect: NSRect(origin: .zero, size: layout.clientSize),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = caption
        isReleasedWhenClosed = false
        animationBehavior = .alertPanel
        hidesOnDeactivate = false
        build()
        standardWindowButton(.closeButton)?.isEnabled = buttons.escapeResult != nil
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func build() {
        let content = WinMessageBoxContentView(frame: NSRect(origin: .zero, size: layout.clientSize))
        content.bandTop = layout.bandTop
        if let frame = layout.iconFrame {
            let iconView = WinMessageBoxIconView(frame: frame)
            iconView.icon = icon
            content.addSubview(iconView)
        }
        let text = WinMessageBoxText(labelWithString: message)
        text.lines = layout.lines
        text.frame = layout.textFrame
        content.addSubview(text)
        for (i, answer) in boxButtons.results.enumerated() {
            let button = NSButton(title: answer.title, target: self, action: #selector(buttonClicked(_:)))
            button.bezelStyle = .rounded
            button.font = DialogMetrics.font
            button.tag = answer.rawValue
            // The first button is the default (DM_GETDEFID: IDYES / IDOK); Escape belongs to Cancel.
            if i == 0 { button.keyEquivalent = "\r" } else if answer == .cancel { button.keyEquivalent = "\u{1b}" }
            // RcPlace.button: the push bezel fills its frame; Windows draws 1 px inside its rect.
            button.frame = layout.buttonFrames[i].insetBy(dx: 1, dy: 0)
            content.addSubview(button)
            pushButtons.append(button)
        }
        contentView = content
        initialFirstResponder = pushButtons.first
    }

    // MARK: answering

    @objc private func buttonClicked(_ sender: NSButton) {
        guard let answer = WinMessageBox.Result(rawValue: sender.tag) else { return }
        self.answer(answer)
    }

    /// Ends the box with `answer` (EndDialog).
    func answer(_ answer: WinMessageBox.Result) {
        guard result == nil else { return }
        result = answer
        if NSApp.modalWindow === self { NSApp.stopModal(withCode: NSApplication.ModalResponse(rawValue: answer.rawValue)) }
        orderOut(nil)
    }

    /// Shows the box modally and returns the answer. A session ended from outside (the test reset)
    /// answers what Esc would, or No for MB_YESNO.
    func runModal() -> WinMessageBox.Result {
        for observer in WinMessageBox.observers { observer(self) }
        placeOnOwnersScreen()
        if result == nil { _ = DialogKit.runModal(for: self) }
        if isVisible { orderOut(nil) }
        ownerWindow?.makeKeyAndOrderFront(nil)
        return result ?? boxButtons.escapeResult ?? .no
    }

    /// The centre of the owner's screen, the whole frame (MessageBox centres on the monitor, title
    /// bar included; the owner's own position does not matter).
    private func placeOnOwnersScreen() {
        guard let screen = ownerWindow?.screen ?? NSScreen.main else { return }
        let size = frame.size
        setFrameOrigin(NSPoint(x: (screen.frame.midX - size.width / 2).rounded(),
                               y: (screen.frame.midY - size.height / 2).rounded()))
    }

    /// `runModal(for:)` centres the window it orders in; the box keeps its own place.
    override func center() { placeOnOwnersScreen() }

    // MARK: keys and the close box

    /// The close box and Cmd+W: WM_CLOSE, which a message box turns into its Esc answer.
    override func performClose(_ sender: Any?) {
        if let answer = boxButtons.escapeResult { self.answer(answer) } else { NSSound.beep() }
    }

    override func cancelOperation(_ sender: Any?) {
        if let answer = boxButtons.escapeResult { self.answer(answer) }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.keyCode == 53, flags.isEmpty { cancelOperation(nil); return }
        if flags.isEmpty || flags == .shift, let c = event.charactersIgnoringModifiers?.lowercased().first,
           let answer = boxButtons.results.first(where: { $0.accessKey == c }) {
            self.answer(answer)
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .keyDown, flags == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w": performClose(nil); return true
            case "c": copyAsText(); return true
            case ".": cancelOperation(nil); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Ctrl+C in a Windows message box: the caption, the text and the buttons between dashed lines.
    func copyAsText() {
        let rule = String(repeating: "-", count: 27)
        let buttons = boxButtons.results.map { $0.title + "   " }.joined()
        let text = [rule, caption, rule, message, rule, buttons, rule, ""].joined(separator: "\r\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Whatever closed it, a box that is gone must not keep its modal session (DialogWindow.close).
    override func close() {
        let wasModal = NSApp.modalWindow === self
        super.close()
        guard wasModal else { return }
        RunLoop.main.perform(inModes: [.default, .modalPanel]) { [weak self] in
            guard let self, NSApp.modalWindow === self, !self.isVisible else { return }
            NSApp.stopModal(withCode: .abort)
        }
    }

    override var canBecomeKey: Bool { true }

    override func accessibilitySubrole() -> NSAccessibility.Subrole? { .dialog }
}

// MARK: - views

/// The white message area over the (243,243,243) button band.
final class WinMessageBoxContentView: NSView {
    var bandTop: CGFloat = 0

    static let face = WinChrome.dynamic(WinChrome.gray(255), .textBackgroundColor)
    static let band = WinChrome.dynamic(WinChrome.gray(243), .windowBackgroundColor)

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Self.face.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: bandTop).fill()
        Self.band.setFill()
        NSRect(x: 0, y: bandTop, width: bounds.width, height: bounds.height - bandTop).fill()
    }
}

/// The static: its `stringValue` is the whole message (what accessibility and the tests read); it
/// draws the lines the layout broke, 13 px apart, on the Windows baselines.
final class WinMessageBoxText: NSTextField {
    var lines: [String] = []

    static let color = WinChrome.dynamic(WinChrome.gray(0), .labelColor)

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        font = WinMessageBoxLayout.font                    // what it draws in (sffont: the UI font)
    }

    override func draw(_ dirtyRect: NSRect) {
        let font = WinMessageBoxLayout.font
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Self.color]
        for (i, line) in lines.enumerated() {
            let baseline = WinMessageBoxLayout.firstBaseline + CGFloat(i) * WinMessageBoxLayout.lineHeight
            (line as NSString).draw(at: NSPoint(x: 0, y: baseline - font.ascender), withAttributes: attributes)
        }
    }
}

/// The Windows 11 message box icons (imageres), drawn: the bitmaps are Windows artwork. Shapes and
/// colours from the 32 x 32 captures (recheck2-data/win/mb-err, -warn, -info, -delfile .png).
final class WinMessageBoxIconView: NSView {
    var icon: WinMessageBox.Icon = .none { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    private static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor { WinChrome.rgb(r, g, b) }

    override func draw(_ dirtyRect: NSRect) {
        switch icon {
        case .none: break
        case .error: drawError()
        case .warning: drawWarning()
        case .information: drawInformation()
        case .question: drawQuestion()
        }
    }

    private func circle(top: NSColor, bottom: NSColor) {
        let path = NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: 90)
    }

    /// MB_ICONSTOP: an orange-red disc, (240,121,43) at the top to (227,85,0) at the bottom, a white
    /// X over x/y 10...21.
    private func drawError() {
        circle(top: Self.c(241, 123, 45), bottom: Self.c(226, 84, 0))
        let x = NSBezierPath()
        x.move(to: NSPoint(x: 11.3, y: 11.3)); x.line(to: NSPoint(x: 20.7, y: 20.7))
        x.move(to: NSPoint(x: 20.7, y: 11.3)); x.line(to: NSPoint(x: 11.3, y: 20.7))
        x.lineWidth = 2.4
        x.lineCapStyle = .square
        Self.c(250, 236, 230).setStroke()
        x.stroke()
    }

    /// MB_ICONQUESTION / MB_ICONINFORMATION's disc: (17,170,230) at the top to (0,139,216).
    private func blueDisc() { circle(top: Self.c(18, 172, 232), bottom: Self.c(0, 136, 212)) }

    private func drawInformation() {
        blueDisc()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: 14.9, y: 7.8, width: 2.2, height: 2.4), xRadius: 1, yRadius: 1).fill()
        NSRect(x: 15, y: 13, width: 2, height: 11.4).fill()
    }

    private func drawQuestion() {
        blueDisc()
        NSColor.white.setStroke()
        NSColor.white.setFill()
        let q = NSBezierPath()
        // In flipped coordinates angles run clockwise: from the left (180) over the top (270) to the
        // right below the middle (380 = 20).
        q.appendArc(withCenter: NSPoint(x: 15.9, y: 12.4), radius: 3.9, startAngle: 180, endAngle: 380, clockwise: false)
        q.curve(to: NSPoint(x: 16, y: 18), controlPoint1: NSPoint(x: 18.6, y: 14.6), controlPoint2: NSPoint(x: 16, y: 15.6))
        q.line(to: NSPoint(x: 16, y: 20.4))
        q.lineWidth = 2
        q.stroke()
        NSBezierPath(ovalIn: NSRect(x: 14.85, y: 22.4, width: 2.3, height: 2.3)).fill()
    }

    /// MB_ICONWARNING: a yellow triangle, (255,226,0) at the top to (255,197,0), a darker 1 px base
    /// (230,166,0), and a near-black exclamation mark.
    private func drawWarning() {
        let t = NSBezierPath()
        t.move(to: NSPoint(x: 16, y: 1.6))
        t.line(to: NSPoint(x: 30.6, y: 29.4))
        t.line(to: NSPoint(x: 1.4, y: 29.4))
        t.close()
        t.lineJoinStyle = .round
        NSGradient(starting: Self.c(255, 227, 0), ending: Self.c(255, 196, 0))?.draw(in: t, angle: 90)
        Self.c(238, 186, 0).setStroke()
        t.lineWidth = 0.8
        t.stroke()
        Self.c(229, 163, 0).setFill()
        NSRect(x: 2.4, y: 29, width: 27.2, height: 1).fill()
        NSGradient(starting: Self.c(60, 60, 60), ending: Self.c(28, 28, 28))?
            .draw(in: NSRect(x: 15, y: 8, width: 2, height: 12), angle: 90)
        Self.c(5, 5, 5).setFill()
        NSBezierPath(ovalIn: NSRect(x: 14.5, y: 22.6, width: 3, height: 3)).fill()
    }
}
