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
        window = DialogKit.window(title: Lang.text(7300, "Split File"), resizable: true)
        super.init()

        pathCombo.stringValue = path
        pathCombo.usesDataSource = false
        pathCombo.completes = false
        pathCombo.translatesAutoresizingMaskIntoConstraints = false
        pathCombo.addConstraint(NSLayoutConstraint(item: pathCombo, attribute: .width, relatedBy: .greaterThanOrEqual,
                                                  toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 380))

        volumeCombo.usesDataSource = false
        volumeCombo.removeAllItems()
        volumeCombo.addItems(withObjectValues: SZSplitVolumePresets())     // AddVolumeItems
        volumeCombo.stringValue = SZSplitVolumePresets().first ?? "10M"    // first entry selected
        volumeCombo.translatesAutoresizingMaskIntoConstraints = false
        volumeCombo.addConstraint(NSLayoutConstraint(item: volumeCombo, attribute: .width, relatedBy: .equal,
                                                    toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 200))

        // IDB_SPLIT_PATH 101 "..." -> MyBrowseForFolder(IDS_SET_FOLDER)
        let browse = DialogKit.button("...", target: self, action: #selector(browseClicked))
        let pathRow = NSStackView(views: [pathCombo, browse])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8

        let ok = DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r")
        let cancel = DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(cancelClicked),
                                      key: "\u{1b}")
        let buttons = NSStackView(views: [NSView(), ok, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let info = DialogKit.label(filePath)
        info.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let stack = NSStackView(views: [
            DialogKit.label(Lang.text(7301, "Split to:")),          // IDT_SPLIT_PATH 7301
            pathRow,
            info,
            DialogKit.label(Lang.text(7302, "Split to volumes,  bytes:")),   // IDT_SPLIT_VOLUME 7302
            volumeCombo,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [pathRow, buttons] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 480)
        window.initialFirstResponder = volumeCombo
    }

    @objc private func browseClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = Lang.text(6007, "Specify a folder:")        // IDS_SET_FOLDER
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
