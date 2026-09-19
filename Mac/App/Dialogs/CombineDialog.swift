// CombineDialog.swift -- File > Combine files... (IDM_COMBINE 550). 7zFM reuses the Copy
// dialog (CCopyDialog / IDD_COPY 96) with Title = IDS_COMBINE 7400 "Combine Files" + the
// first part's name, the static IDS_COMBINE_TO 7401 "Combine to:" and an info block listing
// the detected parts (AddInfoFileName, PanelSplitFile.cpp:412-492).
//
// The Copy dialog itself belongs to the `panel` scope (Dialogs/CopyMove*.swift), so this
// scope carries its own minimal version until that lands; the two can be merged later.
// Parity: 01-fm-feature-inventory.md 3.14, 01b 4.5.

import AppKit

final class CombineDialog: NSObject {

    private let window: NSWindow
    private let pathCombo = NSComboBox()
    private var result: String?

    private init(title: String, prompt: String, info: String, path: String, parent: NSWindow?) {
        window = DialogKit.window(title: title, resizable: true)
        super.init()

        pathCombo.usesDataSource = false
        pathCombo.completes = false
        pathCombo.stringValue = path
        pathCombo.translatesAutoresizingMaskIntoConstraints = false
        pathCombo.addConstraint(NSLayoutConstraint(item: pathCombo, attribute: .width, relatedBy: .greaterThanOrEqual,
                                                  toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 400))

        let browse = DialogKit.button("...", target: self, action: #selector(browseClicked))
        let pathRow = NSStackView(views: [pathCombo, browse])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8

        let infoLabel = DialogKit.label(info)
        infoLabel.font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        infoLabel.lineBreakMode = .byTruncatingMiddle
        infoLabel.maximumNumberOfLines = 8

        let ok = DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r")
        let cancel = DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(cancelClicked),
                                      key: "\u{1b}")
        let buttons = NSStackView(views: [NSView(), ok, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [DialogKit.label(prompt), pathRow, infoLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [pathRow, infoLabel, buttons] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 520)
        window.initialFirstResponder = pathCombo
    }

    @objc private func browseClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = Lang.text(6007, "Specify a folder:")
        panel.directoryURL = URL(fileURLWithPath: pathCombo.stringValue)
        if panel.runModal() == .OK, let url = panel.url {
            pathCombo.stringValue = url.path + "/"
        }
    }

    @objc private func okClicked() {
        result = pathCombo.stringValue
        NSApp.stopModal()
    }

    @objc private func cancelClicked() {
        result = nil
        NSApp.stopModal()
    }

    /// Returns the destination directory, or nil when cancelled.
    static func run(title: String, prompt: String, info: String, path: String,
                    parent: NSWindow? = nil) -> String? {
        let dialog = CombineDialog(title: title, prompt: prompt, info: info, path: path, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
        return dialog.result
    }
}
