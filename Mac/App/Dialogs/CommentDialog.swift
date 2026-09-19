// CommentDialog.swift -- IDM_COMMENT 552 (CPanel::ChangeComment, PanelOperations.cpp:487+).
//
// 7zFM reuses the single-line Combo dialog (IDS_COMMENT 6400 / IDS_COMMENT2 6401) for the comment,
// but a zip archive comment and a descript.ion entry can both be multi-line, so this port shows a
// resizable multi-line editor with the same two strings. The value is written with
// SetProperty(kpidComment) by PanelOperations.swift.
//
// Parity: 01-fm-feature-inventory.md §3.11 "Comment", 01b §4.4.

import AppKit

final class CommentDialog: NSObject {

    private let window: NSWindow
    private let textView = NSTextView()
    private var accepted = false

    private init(value: String, parent: NSWindow?) {
        window = DialogKit.window(title: Lang.text(6400, "Comment"), resizable: true)   // IDS_COMMENT
        super.init()

        let label = DialogKit.label(Lang.text(6401, "Comment:"))                        // IDS_COMMENT2
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.string = value
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        scroll.addConstraint(NSLayoutConstraint(item: scroll, attribute: .height, relatedBy: .greaterThanOrEqual,
                                               toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 120))

        let ok = DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okClicked), key: "\r")
        let cancel = DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(cancelClicked), key: "\u{1b}")
        let buttons = NSStackView(views: [NSView(), cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [label, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [scroll, buttons] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 460)
        window.initialFirstResponder = textView
    }

    @objc private func okClicked() {
        accepted = true
        NSApp.stopModal()
    }

    @objc private func cancelClicked() {
        accepted = false
        NSApp.stopModal()
    }

    /// Returns the new comment, or nil when the user cancelled.
    static func run(value: String, parent: NSWindow?) -> String? {
        let dialog = CommentDialog(value: value, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
        return dialog.accepted ? dialog.textView.string : nil
    }
}
