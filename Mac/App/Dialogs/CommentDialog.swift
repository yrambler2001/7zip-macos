// CommentDialog.swift -- IDM_COMMENT 552 (CPanel::ChangeComment, PanelOperations.cpp:487+).
//
// 7zFM asks for a comment in the single-line Combo dialog (IDD_COMBO 98): Title
// "<rel path> : Comment" (IDS_COMMENT 6400), Static IDS_COMMENT2 6401 "&Comment:" (wincompare,
// dlgfeel: dlg-comment-file.txt). The panel calls ComboDialog itself (PanelOperations.swift);
// this entry point is the same dialog for a caller without an item name.
//
// Parity: 01-fm-feature-inventory.md §3.11 "Comment", 01b §4.4.

import AppKit

enum CommentDialog {
    /// Returns the new comment, or nil when the user cancelled.
    static func run(value: String, name: String? = nil, parent: NSWindow?) -> String? {
        var title = Lang.text(6400, "Comment")                                   // IDS_COMMENT
        if let name, !name.isEmpty { title = name + " : " + title }
        return ComboDialog.run(title: title, label: Lang.text(6401, "&Comment:"), value: value, parent: parent)
    }
}
