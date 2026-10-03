// PanelContextActions.swift -- the handlers behind the 7-Zip block of the panel's item context
// menu (CZipContextMenu::InvokeCommand as 7zFM calls it, PanelMenu.cpp:999 InvokePluginCommand,
// 01 §2.8-§2.9), and the window-level half of IDM_DIFF 554 (CApp::DiffFiles across two panels,
// PanelItemOpen.cpp:747-792).
//
// The context menu (PanelContextMenu.swift) decides which verbs are *shown* -- that is the Windows
// rule, a verb that does not apply is left out rather than grayed -- and every verb it shows sends
// one of the `PanelContextCommands` selectors down the responder chain. They all land here, on the
// window controller, and each one calls the same command implementation the File menu, the
// toolbar and the Finder extension already use:
//
//   kOpen / kOpen + type      CPanel::OpenFocusedItemAsInternal(type) -- bind the panel
//   kExtract                  ExtractCommands.extractWithDialog()   (toolbar Extract 1071)
//   kExtractHere              ExtractCommands.extractHere()
//   kExtractTo                ExtractCommands.extractToSubfolder()
//   kTest                     ExtractCommands.testArchives()        (toolbar Test 1072)
//   kCompress                 CompressCommands.addToArchive(showDialog: true)  (toolbar Add 1070)
//   kCompressEmail            CompressCommands.addToArchive(showDialog: true, email: true)
//   kCompressTo7z / ToZip     CompressCommands.compressTo(formatName:) (+ email: true for the
//                             "Compress to <name> and email" twins)
//   C12 / C13 (CRC SHA >)     CommandExecutor.run(argv:) with the Finder extension's command line
//   kHash_* ("CRC SHA >")     MainWindowController.fileCalculateHash(_:) (tools scope, unchanged)
//
// The commands read their items through `ActiveContext` (the frozen contract), which is the
// focused panel's operated items; the menu was built from exactly those rows, and building it
// focuses the panel that was right-clicked (`makeItemContextMenu`).

import AppKit
import SevenZipKit

extension MainWindowController: PanelContextCommands {

    /// kOpen (IDS_CONTEXT_OPEN 2322): open the archive in this panel (same process, BindToPath).
    @objc func sevenZipOpenArchive(_ sender: Any?) {
        focusedPanel.openSelection(insideOnly: true, formatHint: nil)
    }

    /// kOpen with an ArcType from kOpenTypes ("*", "#", "#:e", "7z", "zip", "cab", "rar").
    @objc func sevenZipOpenArchiveAs(_ sender: Any?) {
        let hint = Self.contextTarget(sender)?.formatHint
        focusedPanel.openSelection(insideOnly: true, formatHint: hint)
    }

    /// kExtract (IDS_CONTEXT_EXTRACT 2323).
    @objc func sevenZipExtractFiles(_ sender: Any?) { ExtractCommands.extractWithDialog() }

    /// kExtractHere (IDS_CONTEXT_EXTRACT_HERE 2326).
    @objc func sevenZipExtractHere(_ sender: Any?) { ExtractCommands.extractHere() }

    /// kExtractTo (IDS_CONTEXT_EXTRACT_TO 2327).
    @objc func sevenZipExtractTo(_ sender: Any?) { ExtractCommands.extractToSubfolder() }

    /// kTest (IDS_CONTEXT_TEST 2325).
    @objc func sevenZipTestArchive(_ sender: Any?) { ExtractCommands.testArchives() }

    /// kCompress (IDS_CONTEXT_COMPRESS 2324).
    @objc func sevenZipCompress(_ sender: Any?) {
        CompressCommands.addToArchive(showDialog: true, email: false)
    }

    /// kCompressEmail (IDS_CONTEXT_COMPRESS_EMAIL 2329).
    @objc func sevenZipCompressEmail(_ sender: Any?) {
        CompressCommands.addToArchive(showDialog: true, email: true)
    }

    /// kCompressTo7z (IDS_CONTEXT_COMPRESS_TO 2328, `Add to "<name>.7z"`).
    @objc func sevenZipCompressTo7z(_ sender: Any?) {
        CompressCommands.compressTo(formatName: "7z", email: false)
    }

    /// kCompressToZip (IDS_CONTEXT_COMPRESS_TO 2328, `Add to "<name>.zip"`).
    @objc func sevenZipCompressToZip(_ sender: Any?) {
        CompressCommands.compressTo(formatName: "zip", email: false)
    }

    /// kCompressTo7zEmail (IDS_CONTEXT_COMPRESS_TO_EMAIL 2330).
    @objc func sevenZipCompressTo7zEmail(_ sender: Any?) {
        CompressCommands.compressTo(formatName: "7z", email: true)
    }

    /// kCompressToZipEmail (IDS_CONTEXT_COMPRESS_TO_EMAIL 2330).
    @objc func sevenZipCompressToZipEmail(_ sender: Any?) {
        CompressCommands.compressTo(formatName: "zip", email: true)
    }

    /// C12 / C13 of the "CRC SHA >" submenu: 7zFM runs these through 7zG
    /// (CZipContextMenu::InvokeCommand -> CalcChecksum / TestArchives with `-thash`); the port runs
    /// the same command line in-process through `CommandExecutor`, as the Finder extension does.
    @objc func sevenZipChecksumCommand(_ sender: Any?) {
        guard let request = (sender as? NSMenuItem)?.representedObject as? PanelChecksumCommand else { return }
        let built = request.command.argv(for: request.paths)
        CommandExecutor.run(argv: built.argv, temporaryFiles: built.temporaryFiles, parentWindow: window)
        ActiveContext.refresh()
    }

    static func contextTarget(_ sender: Any?) -> PanelContextTarget? {
        (sender as? NSMenuItem)?.representedObject as? PanelContextTarget
    }

    // MARK: - IDM_DIFF across two panels (CApp::DiffFiles)

    /// What `CApp::DiffFiles` does with the current selection, before it reads the Diff tool.
    enum DiffRequest: Equatable {
        /// Not the two-panel case: two items in the focused panel (or nothing to do) -- the
        /// single-panel path of `ItemOpenCommands.diff()` handles it.
        case singlePanel
        /// MessageBox_Error_UnsupportOperation: one of the two panels is not a file-system folder.
        case unsupported
        /// The two files to compare.
        case paths(String, String)
    }

    /// PanelItemOpen.cpp:747-792. One item selected in the focused panel and two panels open: the
    /// other panel's single selected item, else the item of the same relative path in the other
    /// panel's folder (its plain name when only the source panel is in flat view).
    func diffRequest() -> DiffRequest {
        let panel = focusedPanel
        let selected = panel.diffSelectedRowIndices()
        guard selected.count == 1, numPanels == 2, let other = otherPanel(of: panel) else { return .singlePanel }
        guard let snap = panel.snapshot, snap.isFileSystem,
              let otherSnap = other.snapshot, otherSnap.isFileSystem else { return .unsupported }
        let row = panel.rows[selected[0]]
        let path1 = row.fullPath
        let otherSelected = other.diffSelectedRowIndices()
        let path2: String
        if otherSelected.count == 1 {
            path2 = other.rows[otherSelected[0]].fullPath
        } else {
            // GetItemRelPath2: prefix + name in flat view; just the name when the other panel is
            // not flat as well.
            let relative = (panel.flatMode && !other.flatMode) ? row.name : row.prefix + row.name
            let base = otherSnap.fullPath.hasSuffix("/") ? otherSnap.fullPath : otherSnap.fullPath + "/"
            path2 = base + relative
        }
        guard !path1.isEmpty, !path2.isEmpty else { return .unsupported }
        return .paths(path1, path2)
    }
}

extension PanelViewController {

    /// Get_ItemIndices_Selected as IDM_DIFF reads it. On macOS the focused row of a fresh folder is
    /// also its selected row (api/panel.md §7.6), so the operated items are what the user sees
    /// highlighted; ".." never counts.
    func diffSelectedRowIndices() -> [Int] {
        operatedRowIndices().filter { $0 < rows.count && !rows[$0].isParentRow }
    }
}
