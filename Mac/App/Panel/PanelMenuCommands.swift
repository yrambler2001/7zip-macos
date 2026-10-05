// PanelMenuCommands.swift -- the menu selectors the panel answers (MenuActions in
// MainMenu.swift) and the File-menu enable rules 7zFM evaluates when the menu opens
// (CFileMenu::Load, MyLoadMenu.cpp:588-734, 01 §2.1). Also the in-place rename commit.

import Cocoa
import SevenZipKit

extension PanelViewController: NSUserInterfaceValidations {

    /// Toolbar buttons and any other NSValidatedUserInterfaceItem use the same rules.
    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        isActionEnabled(item.action)
    }

    // MARK: File menu

    @objc func fileOpen(_ sender: Any?) { openSelectedItems(tryInternal: true) }                     // IDM_OPEN 540
    @objc func fileOpenInside(_ sender: Any?) { openSelection(insideOnly: true) }                    // IDM_OPEN_INSIDE 541
    @objc func fileOpenInsideOne(_ sender: Any?) { openSelection(insideOnly: true, formatHint: "*") } // IDM_OPEN_INSIDE_ONE 590
    @objc func fileOpenInsideParser(_ sender: Any?) { openSelection(insideOnly: true, formatHint: "#") } // IDM_OPEN_INSIDE_PARSER 591
    @objc func fileOpenOutside(_ sender: Any?) {                                                    // IDM_OPEN_OUTSIDE 542
        openSelectionOutside()
    }

    /// Sends `action` to the first responder *after* this panel that implements it (the window
    /// controller, then the app delegate). Returns false when nobody does.
    @discardableResult
    func forwardToNextResponder(_ action: Selector, sender: Any?) -> Bool {
        var responder: NSResponder? = nextResponder
        while let current = responder {
            if current !== self, current.responds(to: action) {
                _ = current.perform(action, with: sender)
                return true
            }
            responder = current.nextResponder
        }
        if let delegate = NSApp.delegate as? NSObject, delegate.responds(to: action) {
            _ = delegate.perform(action, with: sender)
            return true
        }
        return false
    }

    /// EditItem(false) (PanelItems.cpp:1043): F3 on a folder calculates its full size instead of
    /// opening it; a file goes to the configured Viewer, else to the default application.
    @objc func fileView(_ sender: Any?) {                                                            // IDM_FILE_VIEW 543
        guard let focused = focusedRow(), !focused.isParentRow else { return }
        if focused.isDirectory { calcFocusedItemSize(); return }     // F3 on a folder = CalcItemFullSize
        if focused.fullPath.isEmpty, forwardToNextResponder(#selector(fileView(_:)), sender: sender) { return }
        openWithExternalTool(path: focused.fullPath, tool: Settings.viewerPath)
    }

    @objc func fileEdit(_ sender: Any?) {                                                            // IDM_FILE_EDIT 544
        guard let focused = focusedRow(), !focused.isParentRow, !focused.isDirectory else { return }
        if focused.fullPath.isEmpty, forwardToNextResponder(#selector(fileEdit(_:)), sender: sender) { return }
        openWithExternalTool(path: focused.fullPath, tool: Settings.editorPath)
    }

    /// StartEditApplication (PanelItemOpen.cpp:719). Items inside an archive need the temp-file
    /// flow of the `extract` scope (PROGRESS §4.6), which is not on this branch.
    private func openWithExternalTool(path: String, tool: String) {
        guard !path.isEmpty else { showUnsupportedOperation(); return }
        let url = URL(fileURLWithPath: path)
        guard !tool.isEmpty else {
            NSWorkspace.shared.open(url)
            return
        }
        if tool.hasSuffix(".app") {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.open([url], withApplicationAt: URL(fileURLWithPath: tool),
                                    configuration: configuration)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "\(tool) \"$1\"", "sh", path]
        do {
            try process.run()
        } catch {
            showError(message: Lang.text(3011, "Cannot start editor"))
        }
    }

    @objc func fileRename(_ sender: Any?) { renameFocusedItem() }                 // IDM_RENAME 545
    @objc func fileDelete(_ sender: Any?) {                                       // IDM_DELETE 548
        let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
        deleteItems(toTrash: !shift)
    }
    @objc func fileProperties(_ sender: Any?) { showProperties() }                // IDM_PROPERTIES 551
    @objc func fileComment(_ sender: Any?) { changeComment() }                    // IDM_COMMENT 552
    @objc func fileCreateFolder(_ sender: Any?) { createFolder() }                // IDM_CREATE_FOLDER 555
    @objc func fileCreateFile(_ sender: Any?) { createFile() }                    // IDM_CREATE_FILE 556

    // MARK: View menu

    @objc func viewLargeIcons(_ sender: Any?) { setListViewMode(0) }              // IDM_VIEW_LARGE_ICONS 700
    @objc func viewSmallIcons(_ sender: Any?) { setListViewMode(1) }              // IDM_VIEW_SMALL_ICONS 701
    @objc func viewList(_ sender: Any?) { setListViewMode(2) }                    // IDM_VIEW_LIST 702
    @objc func viewDetails(_ sender: Any?) { setListViewMode(3) }                 // IDM_VIEW_DETAILS 703
    @objc func viewArrangeByName(_ sender: Any?) { sort(by: .name) }              // IDM_VIEW_ARANGE_BY_NAME 710
    @objc func viewArrangeByType(_ sender: Any?) { sort(by: .extension) }         // IDM_VIEW_ARANGE_BY_TYPE 711
    @objc func viewArrangeByDate(_ sender: Any?) { sort(by: .mtime) }             // IDM_VIEW_ARANGE_BY_DATE 712
    @objc func viewArrangeBySize(_ sender: Any?) { sort(by: .size) }              // IDM_VIEW_ARANGE_BY_SIZE 713
    @objc func viewArrangeNoSort(_ sender: Any?) { sort(by: .noProperty) }        // IDM_VIEW_ARANGE_NO_SORT 730
    @objc func viewFlatView(_ sender: Any?) { setFlatMode(!flatMode) }            // IDM_VIEW_FLAT_VIEW 731
    @objc func viewOpenRootFolder(_ sender: Any?) { goRoot() }                    // IDM_OPEN_ROOT_FOLDER 734
    @objc func viewOpenParentFolder(_ sender: Any?) { goUp() }                    // IDM_OPEN_PARENT_FOLDER 735
    @objc func viewFoldersHistory(_ sender: Any?) { showFoldersHistory() }        // IDM_FOLDERS_HISTORY 736
    @objc func viewRefresh(_ sender: Any?) { reload(keepScroll: true) }           // IDM_VIEW_REFRESH 737
    @objc func viewGoBack(_ sender: Any?) { goBack() }                            // macOS addition
    @objc func viewGoForward(_ sender: Any?) { goForward() }                      // macOS addition

    // MARK: - Enable rules (01 §2.1)

    /// CFileMenu::Load evaluates isFsFolder / isHashFolder / readOnly / numItems / allAreFiles /
    /// isOneFsFile when the menu opens; the same rules drive the toolbar buttons.
    func isActionEnabled(_ action: Selector?) -> Bool {
        guard let action, let snap = snapshot else { return false }
        let operated = operatedRowIndices().map { rows[$0] }
        let readOnly = snap.chainIsReadOnly || !snap.supportsOperations
        let hash = snap.isHashFolder
        // CFileMenu::Load grays an item only for readOnly, isHashFolder, Split / Combine without
        // isOneFsFile and Link without one item -- never for "nothing selected": a folder just
        // opened (0 / N selected) has every File item enabled (wincompare menu-noselection,
        // winmatch). A command with nothing to operate on then does nothing, as on Windows.
        switch action {
        case #selector(fileOpen(_:)), #selector(fileOpenInside(_:)), #selector(fileOpenInsideOne(_:)),
             #selector(fileOpenInsideParser(_:)), #selector(fileOpenOutside(_:)),
             #selector(fileView(_:)), #selector(fileEdit(_:)):
            return !hash
        case #selector(fileRename(_:)), #selector(fileDelete(_:)):
            return !readOnly
        case #selector(fileComment(_:)):
            return !readOnly && !hash
        case #selector(fileCreateFolder(_:)), #selector(fileCreateFile(_:)):
            return !readOnly && !hash
        case #selector(viewOpenParentFolder(_:)):
            return !snap.isRoot
        case #selector(viewFlatView(_:)):
            return snap.supportsFlatMode
        case #selector(editSelect(_:)), #selector(editDeselect(_:)),
             #selector(editSelectByType(_:)), #selector(editDeselectByType(_:)),
             #selector(editSelectAll(_:)), #selector(editDeselectAll(_:)), #selector(editInvertSelection(_:)):
            return !rows.isEmpty
        case #selector(paste(_:)):
            return !readOnly && PanelDragDrop.pasteboardHasFileURLs()
        case #selector(copy(_:)), #selector(cut(_:)):
            return !operated.isEmpty
        case #selector(quickLook(_:)):
            return operated.contains { !$0.fullPath.isEmpty }
        case #selector(viewGoBack(_:)):
            return canGoBack
        case #selector(viewGoForward(_:)):
            return canGoForward
        default:
            return true
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(viewFlatView(_:)): item.state = flatMode ? .on : .off
        case #selector(viewArrangeByName(_:)): item.state = sortPropID == .name ? .on : .off
        case #selector(viewArrangeByType(_:)): item.state = sortPropID == .extension ? .on : .off
        case #selector(viewArrangeByDate(_:)): item.state = sortPropID == .mtime ? .on : .off
        case #selector(viewArrangeBySize(_:)): item.state = sortPropID == .size ? .on : .off
        case #selector(viewArrangeNoSort(_:)): item.state = sortPropID == .noProperty ? .on : .off
        case #selector(viewLargeIcons(_:)): item.state = listViewMode == 0 ? .on : .off
        case #selector(viewSmallIcons(_:)): item.state = listViewMode == 1 ? .on : .off
        case #selector(viewList(_:)): item.state = listViewMode == 2 ? .on : .off
        case #selector(viewDetails(_:)): item.state = listViewMode == 3 ? .on : .off
        default: break
        }
        return isActionEnabled(item.action)
    }

    // MARK: - In-place rename commit (NSTextFieldDelegate)

    @objc func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field !== pathCombo, let index = renamingRow else { return }
        renamingRow = nil
        (field.superview as? PanelCellView)?.editingConstraint?.isActive = false
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        let text = field.stringValue
        if listViewMode != 3, index < rows.count,
           let item = iconView.collectionView.item(at: IndexPath(item: index, section: 0)) as? PanelCollectionItem,
           item.textField === field {
            item.endLabelEdit(displayName: rows[index].displayName)
            view.window?.makeFirstResponder(iconView.collectionView)
        }
        performRename(index: index, to: text)
    }
}
