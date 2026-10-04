// CombineDialog.swift -- File > Combine files... (IDM_COMBINE 550). 7zFM reuses the Copy
// dialog (CCopyDialog / IDD_COPY 96) with Title = IDS_COMBINE 7400 "Combine Files" + the
// first part's name, the static IDS_COMBINE_TO 7401 "Combine to:" and an info block listing
// the detected parts (AddInfoFileName, PanelSplitFile.cpp:412-492). The port does the same: it
// is CopyMoveDialog with that caption and label (dlgfeel).
// Parity: 01-fm-feature-inventory.md 3.14, 01b 4.5.

import AppKit

enum CombineDialog {
    /// Returns the destination directory, or nil when cancelled.
    static func run(title: String, prompt: String, info: String, path: String,
                    parent: NSWindow? = nil) -> String? {
        CopyMoveDialog.run(title: title, label: prompt, value: path, history: [], info: info, parent: parent)
    }
}
