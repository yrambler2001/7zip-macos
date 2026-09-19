// CompressOptionsSheet.swift -- the Compress dialog's "Options" sheet
// (IDD_COMPRESS_OPTIONS 14001, `COptionsDialog` in CompressDialog.cpp:3350-3830).
//
// Every value is a tri-state: a ":" set-box next to the real checkbox. Unchecked means
// "leave the handler default": the value box shows `DefaultVal`, is disabled, and nothing is
// emitted (`CBoolPair{Def, Val}`). Parity: 01b-fm-dialogs-settings.md section 4.24.

import AppKit
import SevenZipKit

final class CompressOptionsSheet: NSObject {

    /// Everything exchanged with the parent `CCompressDialog`.
    struct State {
        // Format facts (`CArcInfoEx`) the sheet needs.
        var formatName: String
        var formatTimeFlags: UInt32
        var formatFlags: UInt32
        var supportsMTime: Bool
        var supportsCTime: Bool
        var supportsATime: Bool
        var supportsSymLinks: Bool
        var supportsHardLinks: Bool
        var supportsAltStreams: Bool
        var supportsNtSecurity: Bool
        var isTar: Bool
        var isZip: Bool
        var isGZip: Bool
        /// `Flags_KeepName()`: a single-stream format, where mtime really is optional.
        var isKeepName: Bool
        /// "GNU" / "POSIX" for tar, shown in IDT_COMPRESS_TIME_INFO 191.
        var tarMethodName: String

        // Values (in and out).
        var timePrecision: Int?
        var mTime: Bool?
        var cTime: Bool?
        var aTime: Bool?
        var setArcMTime: Bool?
        var preserveATime: Bool?
        var symLinks: Bool?
        var hardLinks: Bool?
        var altStreams: Bool?
        var ntSecurity: Bool?

        /// `Flags_MTime_Default()` etc. (NArcInfoFlags bits 15 / 17 / 19).
        var mTimeDefault: Bool { formatFlags & (1 << 19) != 0 }
        var cTimeDefault: Bool { formatFlags & (1 << 15) != 0 }
        var aTimeDefault: Bool { formatFlags & (1 << 17) != 0 }
    }

    /// Runs the sheet modally. Returns true on OK, with `state` updated.
    static func run(_ state: inout State, parent: NSWindow?) -> Bool {
        let sheet = CompressOptionsSheet(state: state)
        sheet.build()
        sheet.reload()
        if let parent {
            parent.beginSheet(sheet.window) { _ in }
            NSApp.runModal(for: sheet.window)
            parent.endSheet(sheet.window)
        } else {
            NSApp.runModal(for: sheet.window)
            sheet.window.orderOut(nil)
        }
        guard sheet.accepted else { return false }
        state = sheet.state
        return true
    }

    private var state: State
    private var accepted = false
    private var window: NSWindow!

    private init(state: State) {
        self.state = state
        super.init()
    }

    // MARK: controls (Windows IDs in comments)

    private let symLinksBox = NSButton()          // IDX_COMPRESS_NT_SYM_LINKS 4040
    private let hardLinksBox = NSButton()         // IDX_COMPRESS_NT_HARD_LINKS 4041
    private let altStreamsBox = NSButton()        // IDX_COMPRESS_NT_ALT_STREAMS 4042
    private let ntSecurityBox = NSButton()        // IDX_COMPRESS_NT_SECUR 4043
    private var ntfsGroup: NSBox!                 // IDG_COMPRESS_NTFS 115
    private let typeInfoLabel = DialogKit.label("")            // IDT_COMPRESS_TIME_INFO 191
    private let precSetBox = NSButton()           // IDX_COMPRESS_PREC_SET 201
    private let precLabel = DialogKit.label("")   // IDT_COMPRESS_TIME_PREC 4081
    private let precCombo = NSPopUpButton()       // IDC_COMPRESS_TIME_PREC 190
    private let mTimeSetBox = NSButton()          // IDX_COMPRESS_MTIME_SET 202
    private let mTimeBox = NSButton()             // IDX_COMPRESS_MTIME 4082
    private let cTimeSetBox = NSButton()          // IDX_COMPRESS_CTIME_SET 203
    private let cTimeBox = NSButton()             // IDX_COMPRESS_CTIME 4083
    private let aTimeSetBox = NSButton()          // IDX_COMPRESS_ATIME_SET 204
    private let aTimeBox = NSButton()             // IDX_COMPRESS_ATIME 4084
    private let zTimeSetBox = NSButton()          // IDX_COMPRESS_ZTIME_SET 205
    private let zTimeBox = NSButton()             // IDX_COMPRESS_ZTIME 4085
    private let preserveATimeBox = NSButton()     // IDX_COMPRESS_PRESERVE_ATIME 4086
    private var timeGroup: NSBox!                 // IDG_COMPRESS_TIME 4080
    private var precRow: NSStackView!
    private var mTimeRow: NSStackView!
    private var cTimeRow: NSStackView!
    private var aTimeRow: NSStackView!

    /// The precisions currently offered, parallel to `precCombo`'s items.
    private var precisions: [Int] = []
    /// `_auto_Prec`: `Get_DefaultTimePrec()` (gzip forced to Unix).
    private var autoPrecision = 0

    // MARK: build

    private func build() {
        // The caption is localized from IDB_COMPRESS_OPTIONS (CompressDialog.cpp:3701).
        window = DialogKit.window(title: Lang.text(2100, "Options"), resizable: false)

        for (box, id, fallback) in [(symLinksBox, UInt32(4040), "Store symbolic links"),
                                    (hardLinksBox, 4041, "Store hard links"),
                                    (altStreamsBox, 4042, "Store alternate data streams"),
                                    (ntSecurityBox, 4043, "Store file security")] {
            box.setButtonType(.switch)
            box.title = Lang.text(id, fallback)
            box.target = self
            box.action = #selector(valueChanged(_:))
        }
        let ntfsStack = NSStackView(views: [symLinksBox, hardLinksBox, altStreamsBox, ntSecurityBox])
        ntfsStack.orientation = .vertical
        ntfsStack.alignment = .leading
        ntfsStack.spacing = 4
        ntfsGroup = NSBox()
        ntfsGroup.title = Lang.text(115, "NTFS")
        ntfsGroup.contentView = wrap(ntfsStack)

        precLabel.stringValue = Lang.text(4081, "Timestamp precision:")
        precSetBox.setButtonType(.switch)
        precSetBox.title = ":"
        precSetBox.target = self
        precSetBox.action = #selector(precSetToggled(_:))
        precCombo.target = self
        precCombo.action = #selector(precChanged(_:))
        precRow = NSStackView(views: [precSetBox, precLabel, precCombo])
        precRow.orientation = .horizontal
        precRow.spacing = 6

        func timeRow(_ setBox: NSButton, _ box: NSButton, _ id: UInt32, _ fallback: String) -> NSStackView {
            setBox.setButtonType(.switch)
            setBox.title = ":"
            setBox.target = self
            setBox.action = #selector(setBoxToggled(_:))
            box.setButtonType(.switch)
            box.title = Lang.text(id, fallback)
            box.target = self
            box.action = #selector(valueChanged(_:))
            let row = NSStackView(views: [setBox, box])
            row.orientation = .horizontal
            row.spacing = 6
            return row
        }
        mTimeRow = timeRow(mTimeSetBox, mTimeBox, 4082, "Store modification time")
        cTimeRow = timeRow(cTimeSetBox, cTimeBox, 4083, "Store creation time")
        aTimeRow = timeRow(aTimeSetBox, aTimeBox, 4084, "Store last access time")
        let zRow = timeRow(zTimeSetBox, zTimeBox, 4085, "Set archive time to latest file time")

        preserveATimeBox.setButtonType(.switch)
        preserveATimeBox.title = Lang.text(4086, "Do not change source files last access time")
        preserveATimeBox.target = self
        preserveATimeBox.action = #selector(valueChanged(_:))

        let timeStack = NSStackView(views: [precRow, mTimeRow, cTimeRow, aTimeRow, zRow])
        timeStack.orientation = .vertical
        timeStack.alignment = .leading
        timeStack.spacing = 6
        timeGroup = NSBox()
        timeGroup.title = Lang.text(4080, "Time")
        timeGroup.contentView = wrap(timeStack)

        let okButton = DialogKit.button(Lang.text(2, "OK"), target: self, action: #selector(okPressed(_:)), key: "\r")
        let cancelButton = DialogKit.button(Lang.text(1, "Cancel"), target: self,
                                            action: #selector(cancelPressed(_:)), key: "\u{1b}")
        let helpButton = DialogKit.button(Lang.text(3, "Help"), target: self, action: #selector(helpPressed(_:)))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [helpButton, spacer, cancelButton, okButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let content = NSStackView(views: [ntfsGroup, typeInfoLabel, timeGroup, preserveATimeBox, buttons])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        for v in [ntfsGroup, timeGroup, buttons] as [NSView] {
            v.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        DialogKit.install(content, in: window, parent: nil, minimumWidth: 420)
    }

    private func wrap(_ view: NSView) -> NSView {
        let host = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 8),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
            view.topAnchor.constraint(equalTo: host.topAnchor, constant: 6),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -6),
        ])
        return host
    }

    // MARK: - OnInit / SetPrec / SetTimeMAC

    private func reload() {
        // NTFS group: hidden with all four boxes when nothing is supported (:3709-3719).
        symLinksBox.isHidden = !state.supportsSymLinks
        hardLinksBox.isHidden = !state.supportsHardLinks
        // Alt streams and file security are Windows-only concepts; hidden on macOS
        // (01 section 9 #6, #7) but kept so the settings round-trip.
        altStreamsBox.isHidden = true
        ntSecurityBox.isHidden = true
        ntfsGroup.isHidden = !(state.supportsSymLinks || state.supportsHardLinks)
        symLinksBox.state = (state.symLinks ?? false) ? .on : .off
        hardLinksBox.state = (state.hardLinks ?? false) ? .on : .off
        altStreamsBox.state = (state.altStreams ?? false) ? .on : .off
        ntSecurityBox.state = (state.ntSecurity ?? false) ? .on : .off
        preserveATimeBox.state = (state.preserveATime ?? false) ? .on : .off

        setPrec()
    }

    /// `SetPrec` (:3482-3582).
    private func setPrec() {
        // IDT_COMPRESS_TIME_INFO 191: "Type: <format>" (+ ":GNU" / ":POSIX" for tar).
        var info = Lang.text(1, "Type") + ": " + state.formatName
        if state.isTar, !state.tarMethodName.isEmpty { info += ":" + state.tarMethodName }
        typeInfoLabel.stringValue = info

        autoPrecision = CompressTimePrecision.defaultPrecision(timeFlags: state.formatTimeFlags,
                                                               isGZip: state.isGZip)
        precisions = CompressTimePrecision.available(timeFlags: state.formatTimeFlags,
                                                     defaultPrecision: autoPrecision)
        let secText = Lang.text(4090, "sec")
        let nsText = Lang.text(4091, "ns")
        precCombo.removeAllItems()
        var selection = -1
        let selected = state.timePrecision ?? autoPrecision
        for (i, prec) in precisions.enumerated() {
            precCombo.addItem(withTitle: CompressTimePrecision.title(prec, secText: secText, nsText: nsText))
            if prec == selected { selection = i }
        }
        // An unknown stored precision above DOS is added as its own item.
        if selection < 0, selected > CompressTimePrecision.dos {
            precisions.append(selected)
            precCombo.addItem(withTitle: CompressTimePrecision.title(selected, secText: secText, nsText: nsText))
            selection = precisions.count - 1
        }
        if selection < 0, let i = precisions.firstIndex(of: autoPrecision) { selection = i }
        if selection >= 0 { precCombo.selectItem(at: selection) }

        let isSet = state.timePrecision != nil
        let count = precisions.count
        let showPrec = count != 0
        precCombo.isHidden = !showPrec
        precLabel.isHidden = !showPrec
        precCombo.isEnabled = isSet && count > 1
        precSetBox.state = isSet ? .on : .off
        let setIsSupported = isSet || count > 1
        precSetBox.isEnabled = setIsSupported
        precSetBox.isHidden = !setIsSupported

        setTimeMAC()
    }

    /// `SetTimeMAC` (:3584-3653).
    private func setTimeMAC() {
        var mAllow = state.supportsMTime
        var cAllow = state.supportsCTime
        var aAllow = state.supportsATime

        if state.isTar {
            cAllow = false
            aAllow = state.tarMethodName.caseInsensitiveCompare("POSIX") == .orderedSame
        }
        if state.isZip {
            let prec = state.timePrecision ?? autoPrecision
            if prec != CompressTimePrecision.win {
                cAllow = false
                aAllow = false
            }
        }
        // MTime is always stored for a multi-file format, so the set-box is hidden and the
        // value box disabled unless it was explicitly set.
        var mSetVisible = true
        if mAllow, state.mTime == nil, !state.isKeepName {
            mSetVisible = false
            mAllow = false
        }

        configure(row: mTimeRow, setBox: mTimeSetBox, box: mTimeBox,
                  supported: state.supportsMTime, enabled: mAllow, setVisible: mSetVisible,
                  value: state.mTime, defaultValue: state.mTimeDefault)
        configure(row: cTimeRow, setBox: cTimeSetBox, box: cTimeBox,
                  supported: state.supportsCTime, enabled: cAllow, setVisible: cAllow,
                  value: state.cTime, defaultValue: state.cTimeDefault)
        configure(row: aTimeRow, setBox: aTimeSetBox, box: aTimeBox,
                  supported: state.supportsATime, enabled: aAllow, setVisible: aAllow,
                  value: state.aTime, defaultValue: state.aTimeDefault)
        // "Set archive time to latest file time" is always shown, default off.
        zTimeSetBox.state = state.setArcMTime != nil ? .on : .off
        zTimeBox.state = (state.setArcMTime ?? false) ? .on : .off
        zTimeBox.isEnabled = state.setArcMTime != nil
    }

    /// `CheckButton_BoolBox`: the tri-state pair.
    private func configure(row: NSStackView, setBox: NSButton, box: NSButton,
                           supported: Bool, enabled: Bool, setVisible: Bool,
                           value: Bool?, defaultValue: Bool) {
        row.isHidden = !supported
        setBox.isHidden = !setVisible
        setBox.state = value != nil ? .on : .off
        box.state = (value ?? defaultValue) ? .on : .off
        box.isEnabled = enabled && value != nil
    }

    // MARK: actions

    @objc private func precSetToggled(_ sender: NSButton) {
        // On_CheckBoxSet_Prec_Clicked (:3652-3664): unchecking resets TimePrec to -1.
        if sender.state == .on {
            let i = precCombo.indexOfSelectedItem
            state.timePrecision = (i >= 0 && i < precisions.count) ? precisions[i] : autoPrecision
        } else {
            state.timePrecision = nil
        }
        setPrec()
    }

    @objc private func precChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        if i >= 0 && i < precisions.count { state.timePrecision = precisions[i] }
        // A precision change re-evaluates the zip C/A availability (:3765-3779).
        setTimeMAC()
    }

    @objc private func setBoxToggled(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case mTimeSetBox: state.mTime = on ? (state.mTime ?? state.mTimeDefault) : nil
        case cTimeSetBox: state.cTime = on ? (state.cTime ?? state.cTimeDefault) : nil
        case aTimeSetBox: state.aTime = on ? (state.aTime ?? state.aTimeDefault) : nil
        case zTimeSetBox: state.setArcMTime = on ? (state.setArcMTime ?? false) : nil
        default: break
        }
        setTimeMAC()
    }

    @objc private func valueChanged(_ sender: NSButton) {
        let on = sender.state == .on
        switch sender {
        case mTimeBox: state.mTime = on
        case cTimeBox: state.cTime = on
        case aTimeBox: state.aTime = on
        case zTimeBox: state.setArcMTime = on
        // The link / stream boxes are plain `CBool1`s: they only mean something when supported.
        case symLinksBox: state.symLinks = on
        case hardLinksBox: state.hardLinks = on
        case altStreamsBox: state.altStreams = on
        case ntSecurityBox: state.ntSecurity = on
        case preserveATimeBox: state.preserveATime = on ? true : nil
        default: break
        }
    }

    @objc private func okPressed(_ sender: NSButton) {
        accepted = true
        NSApp.stopModal()
    }

    @objc private func cancelPressed(_ sender: NSButton) {
        accepted = false
        NSApp.stopModal()
    }

    @objc private func helpPressed(_ sender: NSButton) {
        // kHelpTopic_Options = "fm/plugins/7-zip/add.htm#options" (CompressDialog.cpp:1255)
        if let url = URL(string: "https://www.7-zip.org/fm/plugins/7-zip/add.htm#options") {
            NSWorkspace.shared.open(url)
        }
    }
}
