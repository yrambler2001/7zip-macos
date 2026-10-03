// BrowseDialog.swift -- MyBrowseForFolder / CBrowseInfo::BrowseForFile (BrowseDialog.cpp/.h,
// IDD_BROWSE 95 "7-Zip: Browse"). Parity: 01b-fm-dialogs-settings.md 4.2.
//
// 01b 4.2: 7-Zip's own CBrowseDialog is replaced by the native panel (macOS parity choice).
// On Windows the system pickers (SHBrowseForFolder / GetOpenFileName / GetSaveFileName) are
// used first and the custom dialog only steps in for super ("\\?\") or device paths and paths
// of MAX_PATH or more, cases that do not exist on macOS. NSOpenPanel / NSSavePanel provide
// what the custom dialog's controls did: parent navigation (IDB_BROWSE_PARENT 110), "New
// Folder" (IDB_BROWSE_CREATE_DIR 112), the list (IDL_BROWSE 100), the path field
// (IDE_BROWSE_PATH 102), the current-folder label (IDT_BROWSE_FOLDER 101) and the type filter
// (IDC_BROWSE_FILTER 103).

import AppKit
import UniformTypeIdentifiers

/// Thin NSOpenPanel / NSSavePanel wrappers with 7-Zip's calling conventions. Main thread only.
enum BrowseDialog {

    /// MyBrowseForFolder: NSOpenPanel with canChooseDirectories. Returns a path with a
    /// trailing "/" (a directory prefix), or nil when cancelled.
    static func forFolder(title: String, initialPath: String, parent: NSWindow?) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = title                                       // Title (sets the caption when non-empty)
        panel.directoryURL = URL(fileURLWithPath: deepestExistingDirectory(initialPath), isDirectory: true)
        guard present(panel, parent: parent) == .OK, let url = panel.url else { return nil }
        return directoryPrefix(url.path)                            // FolderMode normalizes to a dir prefix
    }

    /// CBrowseInfo::BrowseForFile. `allowedExtensions` empty = any file.
    static func forFile(title: String, initialPath: String, allowedExtensions: [String],
                        save: Bool, parent: NSWindow?) -> String? {
        let panel: NSSavePanel
        if save {                                                   // SaveMode: GetSaveFileName
            let savePanel = NSSavePanel()
            savePanel.canCreateDirectories = true
            savePanel.nameFieldStringValue = (initialPath as NSString).lastPathComponent
            panel = savePanel
        } else {                                                    // GetOpenFileName
            let openPanel = NSOpenPanel()
            openPanel.canChooseFiles = true
            openPanel.canChooseDirectories = false
            openPanel.allowsMultipleSelection = false
            panel = openPanel
        }
        panel.message = title
        panel.directoryURL = URL(fileURLWithPath: deepestExistingDirectory(initialPath), isDirectory: true)
        let types = contentTypes(for: allowedExtensions)            // Filters -> IDC_BROWSE_FILTER 103
        if !types.isEmpty {
            panel.allowedContentTypes = types
            panel.allowsOtherFileTypes = save                       // a typed name may use another extension
        }
        guard present(panel, parent: parent) == .OK, let url = panel.url else { return nil }
        return url.path
    }

    // MARK: helpers

    /// UTTypes for the filter masks; extensions with no UTType (and "*" / "" = any file) are skipped.
    private static func contentTypes(for extensions: [String]) -> [UTType] {
        var types: [UTType] = []
        for raw in extensions {
            let ext = raw.trimmingCharacters(in: CharacterSet(charactersIn: "*. "))
            if ext.isEmpty { return [] }                            // "*.*" means every file
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    /// The deepest existing directory of `path` (CBrowseDialog::OnInit walks up the parents until
    /// a Reload succeeds, BrowseDialog.cpp:240-275); the home folder when nothing of it exists.
    private static func deepestExistingDirectory(_ path: String) -> String {
        var candidate = (path as NSString).standardizingPath
        while !candidate.isEmpty {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), isDirectory.boolValue {
                return candidate
            }
            let parent = (candidate as NSString).deletingLastPathComponent
            if parent == candidate { break }
            candidate = parent
        }
        return NSHomeDirectory()
    }

    /// A dir prefix: the path with a single trailing separator (NormalizeDirPathPrefix).
    private static func directoryPrefix(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
    }

    /// runModal() without a parent; as a sheet of `parent` otherwise, kept synchronous by running
    /// a nested modal loop for the panel until the completion handler delivers the answer.
    private static func present(_ panel: NSSavePanel, parent: NSWindow?) -> NSApplication.ModalResponse {
        guard let parent else { return panel.runModal() }
        var response: NSApplication.ModalResponse?
        panel.beginSheetModal(for: parent) { result in
            response = result
            // Only the panel's own session may be stopped, never the caller's dialog.
            if NSApp.modalWindow === panel { NSApp.stopModal() }
        }
        NSApp.runModal(for: panel)
        // The handler runs inside the nested loop; should AppKit have ended that loop when the
        // sheet was ordered out, give the queued handler a moment to deliver the response.
        var attempts = 0
        while response == nil, attempts < 20 {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
            attempts += 1
        }
        return response ?? .cancel
    }
}
