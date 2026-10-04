// OptionsSettingsPage.swift -- Options > Settings (IDD_SETTINGS 2500, "Settings"): the file
// manager's own behaviour switches (CFmSettings) plus the unpack memory limit.
// 01b-fm-dialogs-settings.md section 4.19 / 5.2, 01-fm-feature-inventory.md section 9 #16.
//
// Windows-only rows: "Use large memory pages" (IDX_SETTINGS_LARGE_PAGES 2508) is not shown
// (dlgfeel finding 19; macOS has no SeLockMemoryPrivilege, 01 section 9 #16) and the controls
// under it keep their template places. "Show system menu" is kept with its Windows caption: on
// macOS it adds Finder's own commands to the panel context menu (01 section 9 #2). Every control
// sits on the IDD_SETTINGS template's rect (dlgfeel).

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
    }

    private var flags: [Flag] = []
    private var boxes: [NSButton] = []
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
            // IDX_SETTINGS_SHOW_DOTS 2501
            Flag(langID: 2501, fallback: "Show \"..\" item", get: { Settings.showDots },
                 set: { Settings.showDots = $0 }),
            // IDX_SETTINGS_SHOW_REAL_FILE_ICONS 2502
            Flag(langID: 2502, fallback: "Show real file icons", get: { Settings.showRealFileIcons },
                 set: { Settings.showRealFileIcons = $0 }),
            // IDX_SETTINGS_FULL_ROW 2504
            Flag(langID: 2504, fallback: "Full row select", get: { Settings.fullRow },
                 set: { Settings.fullRow = $0 }),
            // IDX_SETTINGS_SHOW_GRID 2505
            Flag(langID: 2505, fallback: "Show grid lines", get: { Settings.showGrid },
                 set: { Settings.showGrid = $0 }),
            // IDX_SETTINGS_SINGLE_CLICK 2506
            Flag(langID: 2506, fallback: "Single-click to open an item", get: { Settings.singleClick },
                 set: { Settings.singleClick = $0 }),
            // IDX_SETTINGS_ALTERNATIVE_SELECTION 2507
            Flag(langID: 2507, fallback: "Alternative selection mode", get: { Settings.alternativeSelection },
                 set: { Settings.alternativeSelection = $0 }),
            // IDX_SETTINGS_SHOW_SYSTEM_MENU 2503
            Flag(langID: 2503, fallback: "Show system menu", get: { Settings.showSystemMenu },
                 set: { Settings.showSystemMenu = $0 }),
        ]
        let rc = self.rc
        boxes = flags.map { flag in
            let box = OptionsUI.checkbox(flag.langID, flag.fallback, self, #selector(flagClicked(_:)))
            form.add(box, rc, Int(flag.langID))
            return box
        }

        memSetBox = NSButton(checkboxWithTitle: ":", target: self, action: #selector(memSetClicked(_:)))
        memField = NSTextField(string: "1")
        memField.alignment = .center                                  // ES_CENTER
        memField.delegate = self
        memStepper = NSStepper()
        memStepper.target = self
        memStepper.action = #selector(memStepped(_:))
        memStepper.minValue = 1
        memStepper.maxValue = Double(maxMemGB)
        memStepper.increment = 1
        memStepper.valueWraps = false
        memUnit.font = DialogMetrics.font
        memUnit.textColor = .labelColor

        form.add(memLabel, rc, 7816)
        form.add(memSetBox, rc, 100)
        // UDS_ALIGNRIGHT | UDS_AUTOBUDDY: the up-down control (18 x 20) takes the right end of the
        // 75 px edit, which keeps 59 px (measured: edit 57,254 59x20, up-down 114,254 18x20).
        let editRect = rc.rect(101)
        form.addSubview(memField)
        RcPlace.edit(memField, NSRect(x: editRect.minX, y: editRect.minY, width: editRect.width - 16, height: 20))
        form.addSubview(memStepper)
        memStepper.controlSize = .small
        memStepper.frame = NSRect(x: editRect.maxX - 18, y: editRect.minY - 1, width: 18, height: 22)
        form.add(memUnit, rc, 103)
    }

    // MARK: OnInit

    override func pageDidLoad() {
        for (index, flag) in flags.enumerated() { boxes[index].state = flag.get() ? .on : .off }
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
