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

        // IDD_MESSAGES 6602 (MessagesDialog.rc): 456 x 176 DLU = 684 x 286 px, resizable; OnSize
        // (MessagesDialog.cpp:62-76): Close at the bottom right, the list above it in the margins.
        let rc = RcDialog(6602)
        let form = RcFormView()
        form.addSubview(list)
        let close = form.add(DialogKit.button(Lang.text(408, "Close"), target: self, action: #selector(closeClicked),
                                              key: "\r"), rc, 1)
        form.onResize = { [list] size in
            let mx = RcResize.mx, my = RcResize.my
            let y = RcResize.bottomRightButtons([(close, rc.rect(1).size)], in: size)
            list.frame = NSRect(x: mx, y: my, width: max(0, size.width - 2 * mx), height: max(0, y - 2 * my))
        }
        RcPlace.install(form, in: window, size: rc.size, parent: parent)
    }

    @objc private func closeClicked() { NSApp.stopModal() }

    /// Shows the messages modally (main thread). Does nothing when there are none.
    static func show(messages: [String], parent: NSWindow? = nil) {
        guard !messages.isEmpty else { return }
        let dialog = MessagesDialog(messages: messages, parent: parent)
        DialogKit.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
    }
}
