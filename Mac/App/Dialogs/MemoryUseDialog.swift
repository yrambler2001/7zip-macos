// MemoryUseDialog.swift -- CMemDialog / IDD_MEM 7800 "Memory usage request"
// (MemDialog.cpp/.rc), built in code. Parity: 01b-fm-dialogs-settings.md 4.12.
//
// Shown from IArchiveRequestMemoryUseCallback::RequestMemoryUse when a decoder needs more
// memory than the allowed limit (the adapter has already applied the stored
// Extraction/MemLimit). The answer maps onto NRequestMemoryAnswerFlags:
//   Allow radio (IDR_MEM_ACTION_ALLOW 7820) -> k_Allow
//   Skip radio  (IDR_MEM_ACTION_SKIP_ARC 7821) -> k_SkipArc
//   Cancel      (IDCANCEL) -> k_Stop + E_ABORT

import AppKit
import SevenZipKit

final class MemoryUseDialog: NSObject {

    struct Options {
        /// Required_GB (in/out in CMemDialog): the size the decoder asked for.
        var requiredGB: UInt32 = 1
        /// Limit_GB: the currently allowed limit.
        var limitGB: UInt32 = 1
        /// RAM size in GB, 0 when unknown (drives IDS_MEM_ERROR and the spin range).
        var ramGB: UInt32 = 0
        /// TestMode: "Testing:" instead of "Extracting:" in the message.
        var testMode = false
        /// FilePath / ArcPath lines of the message.
        var filePath: String = ""
        var archivePath: String = ""
        /// ShowRemember: multi-archive mode / an item is known (:172-173).
        var showRemember = false
    }

    struct Result {
        var answer: SZMemoryUseAnswer
        /// The limit the user allows, in GB (Limit_GB).
        var limitGB: UInt32
        /// Remember: repeat this answer for the rest of the operation.
        var remember: Bool
        /// NeedSave: write the limit to the settings (NExtract::Save_LimitGB).
        var saveLimit: Bool
    }

    private let window: NSWindow
    private let options: Options
    private var result: Result?

    // Controls (Windows IDs in comments)
    private let messageLabel = DialogKit.label("")            // IDT_MEM_MESSAGE 101
    private let saveLimitBox: NSButton                        // IDX_MEM_SAVE_LIMIT 7801
    private let limitField = NSTextField()                    // IDE_MEM_SPIN_EDIT 110
    private let limitStepper = NSStepper()                    // IDC_MEM_SPIN 111
    private let unitLabel = DialogKit.label("GB")             // IDT_MEM_GB 112
    private let allowRadio: NSButton                          // IDR_MEM_ACTION_ALLOW 7820
    private let skipRadio: NSButton                           // IDR_MEM_ACTION_SKIP_ARC 7821
    private let rememberBox: NSButton                         // IDX_MEM_REMEMBER 7802

    private init(options: Options, parent: NSWindow?) {
        self.options = options
        window = DialogKit.window(title: Lang.text(7800, "Memory usage request"), resizable: false)
        saveLimitBox = DialogKit.checkbox(Lang.text(7801, "Change allowed limit for next operations"),
                                        target: nil, action: nil)
        allowRadio = DialogKit.radio(Lang.text(7820, "Allow archive unpacking"), target: nil, action: nil)
        skipRadio = DialogKit.radio(Lang.text(7821, "Skip archive unpacking"), target: nil, action: nil)
        rememberBox = DialogKit.checkbox(Lang.text(7802, "Repeat selected action for current operation"),
                                       target: nil, action: nil)
        super.init()

        messageLabel.stringValue = MemoryUseDialog.message(options)
        messageLabel.maximumNumberOfLines = 10
        messageLabel.lineBreakMode = .byWordWrapping

        // Spin range: 1 .. 64 without RAM info, else min(RAM - 1, 16384) (:128-142)
        let maxGB = options.ramGB == 0 ? 64 : max(1, min(options.ramGB - 1, 16384))
        limitStepper.minValue = 1
        limitStepper.maxValue = Double(maxGB)
        limitStepper.increment = 1
        limitStepper.integerValue = Int(max(1, options.requiredGB))       // initial = Required_GB (:143-150)
        limitStepper.target = self
        limitStepper.action = #selector(stepperChanged)
        limitField.integerValue = limitStepper.integerValue
        limitField.alignment = .right
        limitField.translatesAutoresizingMaskIntoConstraints = false
        limitField.addConstraint(NSLayoutConstraint(item: limitField, attribute: .width, relatedBy: .equal,
                                                  toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 70))
        unitLabel.stringValue = options.ramGB == 0 ? "GB" : "GB / \(options.ramGB) GB (RAM)"

        saveLimitBox.target = self
        saveLimitBox.action = #selector(toggleSaveLimit)
        // is_Allowed (:99, :155-163): Allow is the default when the RAM can hold it
        let isAllowed = options.ramGB != 0 && options.ramGB >= options.requiredGB
        allowRadio.state = isAllowed ? .on : .off
        skipRadio.state = isAllowed ? .off : .on
        rememberBox.isHidden = !options.showRemember
        setSpinEnabled(false)

        let spinRow = NSStackView(views: [limitField, limitStepper, unitLabel])
        spinRow.orientation = .horizontal
        spinRow.spacing = 6

        let actionLabel = DialogKit.label(Lang.text(7803, "Action"), bold: true)   // IDG_MEM_ACTION 7803
        let continueButton = DialogKit.button(Lang.text(411, "Continue"), target: self,
                                             action: #selector(continueClicked), key: "\r")   // IDCONTINUE
        let cancelButton = DialogKit.button(Lang.text(402, "Cancel"), target: self,
                                           action: #selector(cancelClicked), key: "\u{1b}")
        let buttons = NSStackView(views: [cancelButton, continueButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let buttonRow = NSStackView(views: [NSView(), buttons])
        buttonRow.orientation = .horizontal

        var views: [NSView] = [messageLabel, saveLimitBox, spinRow, actionLabel, allowRadio, skipRadio]
        if options.showRemember { views.append(rememberBox) }
        views.append(buttonRow)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for view in [messageLabel, buttonRow] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 480)
    }

    /// MemDialog.cpp:82-127 (AddInfoMessage_To_String).
    private static func message(_ options: Options) -> String {
        var lines: [String] = []
        if options.ramGB != 0 && options.ramGB < options.requiredGB {
            lines.append(Lang.text(3000, "The system cannot allocate the required amount of memory"))  // IDS_MEM_ERROR
        }
        lines.append(Lang.text(7811, "The operation requires big amount of memory (RAM)."))            // 7811
        lines.append("    \(options.requiredGB) GB : " + Lang.text(7812, "required memory usage size"))
        lines.append("    \(options.limitGB) GB : " + Lang.text(7813, "allowed memory usage limit"))
        if options.ramGB != 0 {
            lines.append("    \(options.ramGB) GB : " + Lang.text(7815, "RAM size"))                   // 7815
        }
        if !options.filePath.isEmpty {
            lines.append("File: " + options.filePath)
        }
        if !options.archivePath.isEmpty {
            let label = options.testMode ? Lang.text(3302, "Testing") : Lang.text(3300, "Extracting")
            lines.append("\(label): " + options.archivePath)
        }
        return lines.joined(separator: "\n")
    }

    private func setSpinEnabled(_ enabled: Bool) {
        // EnableSpin (:178-187): the spin edit follows the checkbox
        limitField.isEnabled = enabled
        limitStepper.isEnabled = enabled
    }

    @objc private func toggleSaveLimit() { setSpinEnabled(saveLimitBox.state == .on) }
    @objc private func stepperChanged() { limitField.integerValue = limitStepper.integerValue }

    @objc private func continueClicked() {
        // OnContinue (:189-218): validate the limit, then end with IDCONTINUE.
        var limit = UInt32(max(1, limitStepper.integerValue))
        let needSave = saveLimitBox.state == .on
        if needSave {
            let typed = limitField.integerValue
            guard typed >= 1, typed <= (1 << 30) else {
                NSSound.beep()
                return
            }
            limit = UInt32(typed)
        }
        result = Result(answer: skipRadio.state == .on ? .skipArchive : .allow,
                        limitGB: limit,
                        remember: rememberBox.state == .on,
                        saveLimit: needSave)
        if needSave {
            // NExtract::Save_LimitGB (ExtractCallback.cpp:1075)
            Settings.extractMemLimitGB = Int(limit)   // through Settings, so the Options page hears it
        }
        NSApp.stopModal()
    }

    @objc private func cancelClicked() {
        result = nil
        NSApp.stopModal()
    }

    // MARK: running

    /// Runs modally on the main thread. nil = Cancel, which the caller turns into
    /// k_Stop + E_ABORT.
    static func run(_ options: Options, parent: NSWindow? = nil) -> Result? {
        let dialog = MemoryUseDialog(options: options, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
        return dialog.result
    }
}
