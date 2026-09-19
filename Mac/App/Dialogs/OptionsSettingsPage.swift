// OptionsSettingsPage.swift -- Options > Settings (IDD_SETTINGS 2500, "Settings"): the file
// manager's own behaviour switches (CFmSettings) plus the unpack memory limit.
// 01b-fm-dialogs-settings.md section 4.19 / 5.2, 01-fm-feature-inventory.md section 9 #16.
//
// Windows-only rows, handled as the inventory's mapping table agreed (01 section 9): "Use large
// memory pages" stays visible but disabled with the reason (#16), and "Show system menu" is kept
// because the panel context menu gets the macOS equivalents of the shell System submenu (#2).

import Cocoa
import SevenZipKit

final class OptionsSettingsPage: OptionsPageBase {

    override var pageID: UInt32 { 2500 }                      // IDD_SETTINGS
    override var fallbackTitle: String { "Settings" }
    override var helpTopic: String { "FM/options.htm#settings" }

    /// The seven CFmSettings checkboxes, in SettingsPage2.rc order.
    private struct Flag {
        let langID: UInt32
        let fallback: String
        let get: () -> Bool
        let set: (Bool) -> Void
        let note: String
    }

    private var flags: [Flag] = []
    private var boxes: [NSButton] = []
    private var largePagesBox: NSButton!      // IDX_SETTINGS_LARGE_PAGES 2508
    private var memSetBox: NSButton!          // IDX_SETTINGS_MEM_SET 100
    private var memField: NSTextField!        // IDE_SETTINGS_MEM_SPIN_EDIT 101
    private var memStepper: NSStepper!        // IDC_SETTINGS_MEM_SPIN 102
    private let memLabel = OptionsUI.label(7816, "Maximum amount of RAM memory usage allowed to unpack archives:")  // IDT_MEM_USAGE_EXTRACT
    private let memUnit = NSTextField(labelWithString: "GB")   // IDT_SETTINGS_MEM_GB 103
    private var fmChanged = false
    private var memChanged = false

    /// SettingsPage.cpp:217-228: 64 when the RAM size is unknown, else min(RAM_GB - 1, 16384).
    private var maxMemGB: Int {
        let ram = ProcessInfo.processInfo.physicalMemory
        guard ram > 0 else { return 64 }
        let gb = Int(ram >> 30)
        return max(1, min(gb - 1, 16384))
    }

    private var ramGB: Int { Int(ProcessInfo.processInfo.physicalMemory >> 30) }

    override func loadView() {
        super.loadView()
        flags = [
            Flag(langID: 2501, fallback: "Show \"..\" item", get: { Settings.showDots },
                 set: { Settings.showDots = $0 }, note: ""),
            Flag(langID: 2502, fallback: "Show real file icons", get: { Settings.showRealFileIcons },
                 set: { Settings.showRealFileIcons = $0 }, note: ""),
            Flag(langID: 2504, fallback: "Full row select", get: { Settings.fullRow },
                 set: { Settings.fullRow = $0 }, note: ""),
            Flag(langID: 2505, fallback: "Show grid lines", get: { Settings.showGrid },
                 set: { Settings.showGrid = $0 }, note: ""),
            Flag(langID: 2506, fallback: "Single-click to open an item", get: { Settings.singleClick },
                 set: { Settings.singleClick = $0 }, note: ""),
            Flag(langID: 2507, fallback: "Alternative selection mode", get: { Settings.alternativeSelection },
                 set: { Settings.alternativeSelection = $0 }, note: ""),
            Flag(langID: 2503, fallback: "Show system menu", get: { Settings.showSystemMenu },
                 set: { Settings.showSystemMenu = $0 },
                 note: "macOS: adds Finder's own commands (Open With, Show in Finder, Quick Look, Get Info) "
                     + "to the panel context menu instead of the Windows shell System submenu."),
        ]
        var views: [NSView] = []
        boxes = flags.map { flag in
            let box = OptionsUI.checkbox(flag.langID, flag.fallback, self, #selector(flagClicked(_:)))
            views.append(box)
            if !flag.note.isEmpty { views.append(indented(OptionsUI.note(flag.note))) }
            return box
        }

        largePagesBox = OptionsUI.checkbox(2508, "Use large memory pages", self, #selector(flagClicked(_:)))
        largePagesBox.isEnabled = Settings.largePagesSupported
        views.append(largePagesBox)
        views.append(indented(OptionsUI.note("Disabled: macOS has no SeLockMemoryPrivilege equivalent, so the "
                                             + "Windows LargePages setting and the -slp switch are not ported "
                                             + "(01 section 9 #16).")))

        memSetBox = NSButton(checkboxWithTitle: ":", target: self, action: #selector(memSetClicked(_:)))
        memField = NSTextField(string: "1")
        memField.translatesAutoresizingMaskIntoConstraints = false
        memField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        memField.delegate = self
        memStepper = NSStepper()
        memStepper.target = self
        memStepper.action = #selector(memStepped(_:))
        memStepper.minValue = 1
        memStepper.maxValue = Double(maxMemGB)
        memStepper.increment = 1
        memStepper.valueWraps = false
        memUnit.textColor = .labelColor

        views.append(separator())
        views.append(memLabel)
        views.append(OptionsUI.hstack([memSetBox, memField, memStepper, memUnit], spacing: 6))
        let stack = OptionsUI.vstack(views, spacing: 6)
        install(stack)
        NSLayoutConstraint.activate([
            memLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func indented(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        container.translatesAutoresizingMaskIntoConstraints = false
        container.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        return container
    }

    private func separator() -> NSView {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(greaterThanOrEqualToConstant: 420).isActive = true
        return box
    }

    // MARK: OnInit

    override func pageDidLoad() {
        for (index, flag) in flags.enumerated() { boxes[index].state = flag.get() ? .on : .off }
        largePagesBox.state = .off
        // SettingsPage.cpp:229-240: unchecked (spin disabled) when MemLimit is 0 or -1.
        let limit = Settings.extractMemLimitGB
        let enabled = limit > 0
        memSetBox.state = enabled ? .on : .off
        let value = enabled ? min(limit, maxMemGB) : 1
        memField.stringValue = String(value)
        memStepper.maxValue = Double(maxMemGB)
        memStepper.integerValue = value
        fmChanged = false
        memChanged = false
        enableMemControls()
        relabelPage()
    }

    override func relabelPage() {
        for (index, flag) in flags.enumerated() { boxes[index].title = Lang.text(flag.langID, flag.fallback) }
        largePagesBox.title = Lang.text(2508, "Use large memory pages")
        memLabel.stringValue = Lang.text(7816, "Maximum amount of RAM memory usage allowed to unpack archives:")
        // IDT_SETTINGS_MEM_GB 103 becomes "GB / <RAM> GB (RAM)" once the RAM size is known.
        memUnit.stringValue = ramGB > 0 ? "GB / \(ramGB) GB (RAM)" : "GB"
    }

    private func enableMemControls() {
        let on = memSetBox.state == .on
        memField.isEnabled = on
        memStepper.isEnabled = on
    }

    @objc private func flagClicked(_ sender: Any?) {
        fmChanged = true
        changed()
    }

    @objc private func memSetClicked(_ sender: Any?) {
        enableMemControls()
        memChanged = true
        changed()
    }

    @objc private func memStepped(_ sender: Any?) {
        memField.stringValue = String(memStepper.integerValue)
        memChanged = true
        changed()
    }

    // MARK: OnApply (SettingsPage.cpp:272-321)

    override func applyPage() -> Bool {
        if fmChanged {
            for (index, flag) in flags.enumerated() { flag.set(boxes[index].state == .on) }
            fmChanged = false
        }
        if memChanged {
            if memSetBox.state == .on {
                // ConvertStringToUInt32, <= 2^30, else E_INVALIDARG and the page stays invalid.
                guard let value = UInt32(memField.stringValue.trimmingCharacters(in: .whitespaces)),
                      value >= 1, value <= (1 << 30) else {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = "7-Zip"
                    // ShowErrorMessage(MyFormatMessage(E_INVALIDARG)) -- not a lang string
                    alert.informativeText = SZErrors.message(forHRESULT: 0x8007_0057)
                    alert.runModal()
                    return false
                }
                Settings.extractMemLimitGB = Int(value)
            } else {
                Settings.extractMemLimitGB = -1
            }
            memChanged = false
        }
        return true
    }
}

extension OptionsSettingsPage: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === memField else { return }
        if let value = Int(field.stringValue), value >= 1 { memStepper.integerValue = value }
        memChanged = true
        changed()
    }
}
