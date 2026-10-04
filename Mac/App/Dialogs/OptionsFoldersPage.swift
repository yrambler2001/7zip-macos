// OptionsFoldersPage.swift -- Options > Folders (IDD_FOLDERS 2400, "Folders"): the working
// (temporary) folder used when an archive is updated. 01b-fm-dialogs-settings.md section 4.8 and
// 5.5. The three values go through NWorkDir::CInfo (SZWorkDirSettings) so the C++ GetWorkDir()
// used by every Agent update reads exactly what this page writes.

import Cocoa
import SevenZipKit

final class OptionsFoldersPage: OptionsPageBase {

    override var pageID: UInt32 { 2400 }                      // IDD_FOLDERS
    override var fallbackTitle: String { "Folders" }
    override var helpTopic: String { "fm/options.htm#folders" }

    private let workingLabel = OptionsUI.label(2401, "Working folder")     // IDT_FOLDERS_WORKING_FOLDER
    private var systemRadio: NSButton!        // IDR_FOLDERS_WORK_SYSTEM 2402
    private var currentRadio: NSButton!       // IDR_FOLDERS_WORK_CURRENT 2403
    private var specifiedRadio: NSButton!     // IDR_FOLDERS_WORK_SPECIFIED 2404
    private var pathField: NSTextField!       // IDE_FOLDERS_WORK_PATH 100
    private var browseButton: NSButton!       // IDB_FOLDERS_WORK_PATH 101
    private var removableCheckbox: NSButton!  // IDX_FOLDERS_WORK_FOR_REMOVABLE 2405
    private var needSave = false

    override func loadView() {
        super.loadView()
        systemRadio = OptionsUI.radio(2402, "System temp folder", self, #selector(modeChanged(_:)))
        currentRadio = OptionsUI.radio(2403, "Current", self, #selector(modeChanged(_:)))
        specifiedRadio = OptionsUI.radio(2404, "Specified:", self, #selector(modeChanged(_:)))
        pathField = OptionsUI.textField(self, #selector(pathEdited(_:)))
        browseButton = OptionsUI.browseButton(self, #selector(browse(_:)))
        removableCheckbox = OptionsUI.checkbox(2405, "Use for removable drives only", self, #selector(removableChanged(_:)))

        // IDD_FOLDERS (FoldersPage2.rc): every control on its template rect, no note (dlgfeel).
        let rc = self.rc
        form.add(workingLabel, rc, 2401)
        form.add(systemRadio, rc, 2402)
        form.add(currentRadio, rc, 2403)
        form.add(specifiedRadio, rc, 2404)
        form.add(pathField, rc, 100)
        form.add(browseButton, rc, 101)
        form.add(removableCheckbox, rc, 2405)
    }

    // MARK: OnInit (m_WorkDirInfo.Load())

    override func pageDidLoad() {
        let info = Settings.loadWorkDir()
        systemRadio.state = info.mode == .system ? .on : .off
        currentRadio.state = info.mode == .current ? .on : .off
        specifiedRadio.state = info.mode == .specified ? .on : .off
        pathField.stringValue = info.path
        removableCheckbox.state = info.forRemovableOnly ? .on : .off
        needSave = false
        enableControls()
        relabelPage()
    }

    override func relabelPage() {
        workingLabel.stringValue = Lang.text(2401, "Working folder")
        systemRadio.title = Lang.text(2402, "System temp folder")
        currentRadio.title = Lang.text(2403, "Current")
        specifiedRadio.title = Lang.text(2404, "Specified:")
        removableCheckbox.title = Lang.text(2405, "Use for removable drives only")
    }

    /// MyEnableControls (FoldersPage.cpp:71-76).
    private func enableControls() {
        let specified = specifiedRadio.state == .on
        pathField.isEnabled = specified
        browseButton.isEnabled = specified
    }

    private var selectedMode: SZWorkDirMode {
        if currentRadio.state == .on { return .current }
        if specifiedRadio.state == .on { return .specified }
        return .system
    }

    @objc private func modeChanged(_ sender: NSButton) {
        for radio in [systemRadio, currentRadio, specifiedRadio] { radio?.state = radio === sender ? .on : .off }
        enableControls()
        needSave = true
        changed()
    }

    @objc private func pathEdited(_ sender: Any?) {
        needSave = true
        changed()
    }

    @objc private func removableChanged(_ sender: Any?) {
        needSave = true
        changed()
    }

    /// MyBrowseForFolder(IDS_FOLDERS_SET_WORK_PATH_TITLE 2406) (FoldersPage.cpp:148-156).
    @objc private func browse(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = Lang.text(2406, "Specify a location for temporary archive files.")
        if !pathField.stringValue.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: pathField.stringValue)
        }
        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.pathField.stringValue = url.path
            self.needSave = true
            self.changed()
        }
    }

    // MARK: OnApply (FoldersPage.cpp:158-167 -- only when _needSave)

    override func applyPage() -> Bool {
        guard needSave else { return true }
        let info = SZWorkDirSettings()
        info.mode = selectedMode
        info.path = pathField.stringValue
        info.forRemovableOnly = removableCheckbox.state == .on
        Settings.saveWorkDir(info)
        needSave = false
        return true
    }
}
