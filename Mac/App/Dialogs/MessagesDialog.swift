// MessagesDialog.swift -- CMessagesDialog / IDD_MESSAGES 6602
// "7-Zip: Diagnostic messages" (MessagesDialog.cpp/.rc), built in code.
// Parity: 01b-fm-dialogs-settings.md 4.14. 440 x 160 du, resizable; list IDL_MESSAGE 100
// with an unnamed index column and "Message" (IDS_MESSAGE 6603); IDOK is "&Close".
//
// The progress dialog embeds a list of the same shape (MessageListView); this stand-alone
// dialog is what 7zFM shows after a drag-and-drop copy that collected messages
// (PanelDrag.cpp:1788).

import AppKit

final class MessagesDialog: NSObject {

    private let window: NSWindow
    private let list = MessageListView(showsHeader: true)     // IDL_MESSAGE 100

    private init(messages: [String], parent: NSWindow?) {
        window = DialogKit.window(title: "7-Zip: " + Lang.text(6602, "Diagnostic messages"), resizable: true)
        super.init()

        list.setMessages(messages)
        list.translatesAutoresizingMaskIntoConstraints = false
        list.addConstraint(NSLayoutConstraint(item: list, attribute: .height, relatedBy: .greaterThanOrEqual,
                                             toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 220))

        let close = DialogKit.button(Lang.text(408, "Close"), target: self, action: #selector(closeClicked), key: "\r")
        let buttonRow = NSStackView(views: [NSView(), close])
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [list, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        for view in [list, buttonRow] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 640)
    }

    @objc private func closeClicked() { NSApp.stopModal() }

    /// Shows the messages modally (main thread). Does nothing when there are none.
    static func show(messages: [String], parent: NSWindow? = nil) {
        guard !messages.isEmpty else { return }
        let dialog = MessagesDialog(messages: messages, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
    }
}
