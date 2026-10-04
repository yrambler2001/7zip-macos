// SplitDialog.swift -- File > Split file... (IDM_SPLIT 549), CSplitDialog / IDD_SPLIT 7300
// "Split File", resizable. Parity: 01b-fm-dialogs-settings.md 4.20, 01 3.14.

import AppKit
import SevenZipKit

final class SplitDialog: NSObject {

    struct Result {
        /// The destination directory (IDC_SPLIT_PATH 100).
        var path: String
        /// The parsed volume sizes (IDC_SPLIT_VOLUME 102 through ParseVolumeSizes).
        var volumeSizes: [UInt64]
    }

    private let window: NSWindow
    private let pathCombo = NSComboBox()          // IDC_SPLIT_PATH 100 (MY_COMBO_WITH_EDIT)
    private let volumeCombo = NSComboBox()        // IDC_SPLIT_VOLUME 102
    private var result: Result?
    private let filePath: String

    private init(filePath: String, path: String, parent: NSWindow?) {
        self.filePath = filePath
        // CSplitDialog::OnInit: the caption gets " <FilePath>" appended ("Split File b.bin" in
        // 7zFM 25.01, Mac/docs/reports/wincompare.md); IDD_SPLIT has no separate file-name label.
        let caption = Lang.text(7300, "Split File")
        window = DialogKit.window(title: filePath.isEmpty ? caption : caption + " " + filePath, resizable: true)
        super.init()

        pathCombo.stringValue = path
        pathCombo.usesDataSource = false
        pathCombo.completes = false

        volumeCombo.usesDataSource = false
        volumeCombo.removeAllItems()
        volumeCombo.addItems(withObjectValues: SZSplitVolumePresets())     // AddVolumeItems
        volumeCombo.stringValue = SZSplitVolumePresets().first ?? "10M"    // first entry selected

        // IDD_SPLIT 7300 (SplitDialog.rc): 304 x 112 DLU = 456 x 182 px, resizable; OnSize
        // (SplitDialog.cpp:50-74) keeps "..." at the right, stretches the path combo and keeps
        // OK / Cancel at the bottom right (dlgfeel).
        let rc = RcDialog(7300)
        let form = RcFormView()
        form.add(DialogKit.label(Lang.text(7301, "Split to:")), rc, 7301)                          // IDT_SPLIT_PATH 7301
        form.add(pathCombo, rc, 100)
        // IDB_SPLIT_PATH 101 "..." -> MyBrowseForFolder(IDS_SET_FOLDER)
        let dots = form.add(DialogKit.button("...", target: self, action: #selector(browseClicked)), rc, 101)
        form.add(DialogKit.label(Lang.dialogText(7300, 7302, "Split to volumes,  bytes:")), rc, 7302)  // IDT_SPLIT_VOLUME 7302
        form.add(volumeCombo, rc, 102)
        let ok = form.add(DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r"), rc, 1)
        let cancel = form.add(DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(cancelClicked),
                                               key: "\u{1b}"), rc, 2)
        let pathRect = rc.rect(100), dotsRect = rc.rect(101)
        form.onResize = { [pathCombo] size in
            let mx = RcResize.mx
            RcResize.bottomRightButtons([(cancel, rc.rect(2).size), (ok, rc.rect(1).size)], in: size)
            RcPlace.button(dots, NSRect(x: size.width - mx - dotsRect.width, y: dotsRect.minY,
                                        width: dotsRect.width, height: dotsRect.height))
            RcResize.setWidth(pathCombo, size.width - mx - mx - dotsRect.width - mx, rect: pathRect)
        }
        RcPlace.install(form, in: window, size: rc.size, parent: parent)
        window.initialFirstResponder = volumeCombo
    }

    @objc private func browseClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = Lang.text(6007, "Select destination folder.")        // IDS_SET_FOLDER
        panel.directoryURL = URL(fileURLWithPath: pathCombo.stringValue)
        if panel.runModal() == .OK, let url = panel.url {
            pathCombo.stringValue = url.path + "/"
        }
    }

    /// OnOK (:102-115): ParseVolumeSizes must succeed, else IDS_INCORRECT_VOLUME_SIZE 7307
    /// and the dialog stays open.
    @objc private func okClicked() {
        guard let sizes = SZSplitFile.parseVolumeSizes(volumeCombo.stringValue), !sizes.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "7-Zip"
            alert.informativeText = Lang.text(7307, "Incorrect volume size")
            alert.alertStyle = .critical
            alert.addButton(withTitle: Lang.text(401, "OK"))
            alert.beginSheetModal(for: window)
            return
        }
        result = Result(path: pathCombo.stringValue, volumeSizes: sizes.map { $0.uint64Value })
        NSApp.stopModal()
    }

    @objc private func cancelClicked() {
        result = nil
        NSApp.stopModal()
    }

    /// Shows the dialog; nil when the user cancelled.
    static func run(filePath: String, path: String, parent: NSWindow? = nil) -> Result? {
        let dialog = SplitDialog(filePath: filePath, path: path, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
        return dialog.result
    }
}
