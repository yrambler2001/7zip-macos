// PanelNestedArchives.swift -- writing a modified nested archive back into its parent when the
// panel leaves it: CPanel::CloseOneLevel -> OpenParentArchiveFolder (PanelFolderChange.cpp:999-1014,
// PanelItemOpen.cpp:598-624). parity.md D item 13; 01 §3.8 ("OpenParentFolder", "CloseOneLevel").
//
// 7zFM keeps one CFolderLink per archive level. An archive found inside another archive is
// extracted to a 7zO temp copy and opened from there; an edit inside it (Edit / Open Outside, a
// delete, a rename, a copy in) rewrites that copy. When the panel closes the level -- going up out
// of its root, binding another path, opening the drives list, closing the window -- the copy's
// size and time are compared with what was recorded at open (WasChanged_from_FolderLink), the
// user is asked IDS_WANT_UPDATE_MODIFIED_FILE 3009, and on Yes the copy replaces the item in the
// parent through CopyFromFile (OnOpenItemChanged, CThreadCopyFrom). A failure shows
// IDS_CANNOT_UPDATE_FILE 3010 with the copy's path and leaves the copy on disk; the parent is
// rewritten through a temp file, so it is never damaged. Several levels unwind innermost first,
// so a write-back that changes a parent that is itself a copy is asked about when that level
// closes in turn.
//
// The bridge half is SZArchive.tempFilePath / tempFileWasChanged / writeBackIntoOuterFolder
// (ai/api/panel.md, archgaps note).

import AppKit
import SevenZipKit

extension PanelViewController {

    /// The archives `folder` lives in, innermost first -- the CFolderLink chain (_parentFolders).
    static func archiveChain(of folder: SZFolder?) -> [SZArchive] {
        var chain: [SZArchive] = []
        var current = folder
        while let archive = current?.archive, !chain.contains(where: { $0 === archive }) {
            chain.append(archive)
            current = archive.outerFolder
        }
        return chain
    }

    /// CloseOneLevel for every archive of `old`'s chain that `new` is not inside, innermost first.
    /// Runs on the panel queue (the folders belong to it); the questions and the progress dialog
    /// are put on the main thread while the queue waits, so no other block touches the folders.
    /// Also callable on the main thread from inside `queue.sync` (shutdown). Returns true when a
    /// parent archive was rewritten.
    @discardableResult
    func leaveNestedArchives(from old: SZFolder?, to new: SZFolder?) -> Bool {
        let staying = Self.archiveChain(of: new)
        let leaving = Self.archiveChain(of: old)
        var wroteBack = false
        for archive in leaving where !staying.contains(where: { $0 === archive }) {
            if closeNestedLevel(archive) { wroteBack = true }
        }
        // CFolderLink::Password dies with its link: each level carries its own password
        // (SZArchive.password), so nothing has to be forgotten here.
        return wroteBack
    }

    /// Main thread, at window close / quit: the panel's whole chain closes (CPanel's destructor
    /// runs CloseOpenFolders). Asked once.
    func closeNestedArchivesForShutdown() {
        guard !nestedArchivesClosedForShutdown else { return }
        nestedArchivesClosedForShutdown = true
        // Only the stat of each copy is read here; the queue is entered only when there is
        // something to write back (or an editor session inside a copy), so closing a window
        // never waits on a busy panel queue for nothing.
        let chain = Self.archiveChain(of: folder).filter { $0.tempFilePath != nil }
        guard chain.contains(where: { $0.tempFileWasChanged }) || TempOpenManager.shared.openCount > 0,
              !chain.isEmpty else { return }
        queueHeldForMain += 1
        queue.sync { _ = self.leaveNestedArchives(from: self.folder, to: nil) }
        queueHeldForMain -= 1
    }

    /// OpenParentArchiveFolder for one level. True when the parent was updated.
    private func closeNestedLevel(_ archive: SZArchive) -> Bool {
        guard let copyPath = archive.tempFilePath, archive.outerFolder != nil else { return false }
        var updated = false
        Self.onMain { [self] in
            queueHeldForMain += 1                   // the panel queue waits for this block
            defer { queueHeldForMain -= 1 }
            // An item of this archive still open in an editor: its pending save goes into the
            // nested copy first, so the write-back below carries it.
            TempOpenManager.shared.finishSessions(inside: archive)
            guard archive.tempFileWasChanged else { return }
            let name = (archive.path as NSString).lastPathComponent
            guard askWriteBack(name) else { return }      // No and Cancel both skip (MB_YESNOCANCEL)

            var options = OperationRunner.Options(title: Lang.text(3301, "Compressing"))
            options.initialStatus = .update
            options.parentWindow = hostWindow
            options.titleFileName = name
            // folderLinkPrev.UsePassword / Password: the level that holds the nested archive
            // (PanelItemOpen.cpp:614-615).
            options.password = archive.outerFolder?.archive?.password
            let result = OperationRunner.run(options) { runner -> Void in
                try archive.writeBackIntoOuterFolder(progress: runner)
            }
            switch result {
            case .success:
                updated = true
            case .failure:
                // Never lose the edit: the copy stays where the message says (7zFM returns before
                // DeleteDirAndFile), and the parent was not touched.
                archive.keepTempDirectory()
                showCannotUpdate(copyPath)
            }
        }
        return updated
    }

    /// IDS_WANT_UPDATE_MODIFIED_FILE 3009, MB_YESNOCANCEL | MB_ICONQUESTION.
    private func askWriteBack(_ name: String) -> Bool {
        let text = Lang.format(
            Lang.text(3009, "File '{0}' was modified.\nDo you want to update it in the archive?"), name)
        return WinMessageBox.run(text, buttons: .yesNoCancel, icon: .question, owner: hostWindow) == .yes
    }

    /// IDS_CANNOT_UPDATE_FILE 3010 with the temp copy's path (folderLink.FilePath).
    private func showCannotUpdate(_ path: String) {
        // PanelItemOpen.cpp:617-618: "7-Zip", MB_OK | MB_ICONSTOP.
        WinMessageBox.run(Lang.format(Lang.text(3010, "Cannot update file '{0}'"), path), icon: .error,
                          owner: hostWindow)
    }

    /// Through the main run loop, not the main queue: the body runs OperationRunner, whose worker
    /// may need `DispatchQueue.main.sync` for a question (PanelArchiveOpen.performOnMainRunLoop).
    private static func onMain(_ body: @escaping () -> Void) {
        performOnMainRunLoop(body)
    }
}
