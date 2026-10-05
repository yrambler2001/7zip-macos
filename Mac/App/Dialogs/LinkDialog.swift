// LinkDialog.swift -- File > Link... (IDM_LINK 558), CLinkDialog / IDD_LINK 7700 "Link",
// resizable. Parity: 01b-fm-dialogs-settings.md 4.10, 01 3.11, 01 9 #8.
//
// macOS has only two of the five Windows link types:
//   * "Hard Link"              -> link(2)            (IDR_LINK_TYPE_HARD 7711)
//   * "File Symbolic Link"     -> symlink(2)         (IDR_LINK_TYPE_SYM_FILE 7712)
//   * "Directory Symbolic Link"-> symlink(2)         (IDR_LINK_TYPE_SYM_DIR 7713)
// A POSIX symlink does not distinguish file from directory, so the two symbolic types differ
// only in the kind check they enforce, exactly like the Windows "Incorrect link type" test.
// "Directory Junction" (7714) and "WSL" (7715) are NTFS reparse-point flavours that do not
// exist here: their radio buttons are shown, as on Windows, but disabled (dlgfeel).

import AppKit

final class LinkDialog: NSObject {

    enum LinkType: Int {
        case hard = 7711        // IDR_LINK_TYPE_HARD
        case symbolicFile = 7712 // IDR_LINK_TYPE_SYM_FILE
        case symbolicDir = 7713  // IDR_LINK_TYPE_SYM_DIR
    }

    private let window: NSWindow
    private let fromCombo = WinComboBox()        // IDC_LINK_PATH_FROM 100
    private let toCombo = WinComboBox()          // IDC_LINK_PATH_TO 101
    private let currentTarget = DialogKit.label("")  // IDT_LINK_PATH_TO_CUR 102
    private let hardRadio: NSButton
    private let symFileRadio: NSButton
    private let symDirRadio: NSButton
    private let currentDirPrefix: String
    private var didCreateLink = false

    private init(currentDirPrefix: String, filePath: String, anotherPath: String, parent: NSWindow?) {
        self.currentDirPrefix = currentDirPrefix
        window = DialogKit.window(title: Lang.text(7700, "Link"), resizable: true)
        // AppKit groups radio buttons that share a superview AND an action; without an
        // action they would all stay selectable at once (WS_GROUP equivalent).
        hardRadio = DialogKit.radio(Lang.text(7711, "Hard Link"), target: nil,
                                    action: #selector(linkTypeChanged))
        symFileRadio = DialogKit.radio(Lang.text(7712, "File Symbolic Link"), target: nil,
                                       action: #selector(linkTypeChanged))
        symDirRadio = DialogKit.radio(Lang.text(7713, "Directory Symbolic Link"), target: nil,
                                      action: #selector(linkTypeChanged))
        super.init()
        for radio in [hardRadio, symFileRadio, symDirRadio] { radio.target = self }

        let fm = FileManager.default
        var isDirectory = false
        var exists = false
        var isLink = false
        var linkTarget: String?
        if let attributes = try? fm.attributesOfItem(atPath: filePath) {
            exists = true
            isLink = (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
            if isLink {
                linkTarget = try? fm.destinationOfSymbolicLink(atPath: filePath)
                var resolved = ObjCBool(false)
                _ = fm.fileExists(atPath: filePath, isDirectory: &resolved)
                isDirectory = resolved.boolValue
            } else {
                isDirectory = (attributes[.type] as? FileAttributeType) == .typeDirectory
            }
        }

        // OnInit (:87-179): an existing symlink edits itself, otherwise the other panel's
        // folder is the link to create and FilePath is the target.
        if isLink {
            fromCombo.stringValue = filePath
            toCombo.stringValue = linkTarget ?? filePath
            currentTarget.stringValue = linkTarget ?? ""
        } else {
            fromCombo.stringValue = anotherPath
            toCombo.stringValue = filePath
            currentTarget.stringValue = ""
        }
        for radio in [hardRadio, symFileRadio, symDirRadio] { radio.state = .off }
        if exists, !isLink, !isDirectory {
            hardRadio.state = .on                 // default for a plain file (:171)
        } else if isDirectory {
            symDirRadio.state = .on               // default for a folder / dir symlink (:164)
        } else {
            symFileRadio.state = .on              // default when FilePath is missing (:102)
        }

        for combo in [fromCombo, toCombo] {
            combo.usesDataSource = false
            combo.completes = false
        }
        // IDR_LINK_TYPE_JUNCTION 7714 / IDR_LINK_TYPE_WSL 7715: NTFS-only, so never selectable.
        let junctionRadio = DialogKit.radio(Lang.text(7714, "Directory Junction"), target: self,
                                            action: #selector(linkTypeChanged))
        let wslRadio = DialogKit.radio(Lang.text(7715, "WSL"), target: self, action: #selector(linkTypeChanged))
        for radio in [junctionRadio, wslRadio] {
            radio.state = .off
            radio.isEnabled = false
        }

        // IDD_LINK 7700 (LinkDialog.rc): 304 x 230 DLU = 456 x 374 px, resizable; OnSize
        // (LinkDialog.cpp:182-212) keeps the two "..." at the right, stretches the combos and keeps
        // Link / Cancel at the bottom right (dlgfeel).
        let rc = RcDialog(7700)
        let form = RcFormView()
        form.add(DialogKit.label(Lang.text(7702, "Link from:")), rc, 7702)       // IDT_LINK_PATH_FROM 7702
        form.add(fromCombo, rc, 100)
        let browseFrom = form.add(DialogKit.button("...", target: self, action: #selector(browseFromClicked)), rc, 103)  // IDB_LINK_PATH_FROM 103
        form.add(DialogKit.label(Lang.text(7703, "Link to:")), rc, 7703)         // IDT_LINK_PATH_TO 7703
        form.add(toCombo, rc, 101)
        let browseTo = form.add(DialogKit.button("...", target: self, action: #selector(browseToClicked)), rc, 104)      // IDB_LINK_PATH_TO 104
        form.add(currentTarget, rc, 102)
        form.add(WinGroupBox(title: Lang.text(7710, "Link Type")), rc, 7710)     // IDG_LINK_TYPE 7710
        form.add(hardRadio, rc, 7711)
        form.add(symFileRadio, rc, 7712)
        form.add(symDirRadio, rc, 7713)
        form.add(junctionRadio, rc, 7714)
        form.add(wslRadio, rc, 7715)
        let link = form.add(DialogKit.button(Lang.text(7701, "Link"), target: self, action: #selector(linkClicked),
                                             key: "\r"), rc, 7701)             // IDB_LINK_LINK 7701
        let cancel = form.add(DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(cancelClicked),
                                               key: "\u{1b}"), rc, 2)
        let fromRect = rc.rect(100), toRect = rc.rect(101), dotsFrom = rc.rect(103), dotsTo = rc.rect(104)
        form.onResize = { [fromCombo, toCombo] size in
            let mx = RcResize.mx
            RcResize.bottomRightButtons([(cancel, rc.rect(2).size), (link, rc.rect(7701).size)], in: size)
            let x = size.width - mx - dotsFrom.width
            RcPlace.button(browseFrom, NSRect(x: x, y: dotsFrom.minY, width: dotsFrom.width, height: dotsFrom.height))
            RcPlace.button(browseTo, NSRect(x: x, y: dotsTo.minY, width: dotsTo.width, height: dotsTo.height))
            RcResize.setWidth(fromCombo, x - mx - mx, rect: fromRect)
            RcResize.setWidth(toCombo, x - mx - mx, rect: toRect)
        }
        RcPlace.install(form, in: window, size: rc.size, parent: parent)
        window.initialFirstResponder = fromCombo
    }

    @objc private func linkTypeChanged(_ sender: Any?) {}

    private var selectedType: LinkType {
        if hardRadio.state == .on { return .hard }
        if symDirRadio.state == .on { return .symbolicDir }
        return .symbolicFile
    }

    @objc private func browseFromClicked() { browse(into: fromCombo) }
    @objc private func browseToClicked() { browse(into: toCombo) }

    private func browse(into combo: NSComboBox) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = Lang.text(6007, "Select destination folder.")     // IDS_SET_FOLDER
        if !combo.stringValue.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: combo.stringValue)
        }
        if panel.runModal() == .OK, let url = panel.url {
            combo.stringValue = url.path + "/"
        }
    }

    /// OnButton_Link (:262-350).
    @objc private func linkClicked() {
        var from = fromCombo.stringValue
        let to = toCombo.stringValue
        if from.isEmpty {
            showError("Incorrect link")
            return
        }
        if !from.hasPrefix("/") {
            from = currentDirPrefix + from      // a relative "from" gets CurDirPrefix
        }
        let fm = FileManager.default
        let type = selectedType

        // A directory as "from" means "create the link inside it", like the Windows dialog
        // where the other panel's folder is offered as the link location.
        var fromIsDir = ObjCBool(false)
        if fm.fileExists(atPath: from, isDirectory: &fromIsDir), fromIsDir.boolValue,
           !isSymbolicLink(from) {
            from = (from as NSString).appendingPathComponent((to as NSString).lastPathComponent)
        }

        // The existing paths must match the dir/file kind of the chosen type.
        var toIsDir = ObjCBool(false)
        let toExists = fm.fileExists(atPath: to, isDirectory: &toIsDir)
        if toExists {
            if type == .symbolicDir && !toIsDir.boolValue {
                showError("Incorrect link type")
                return
            }
            if type != .symbolicDir && toIsDir.boolValue {
                showError("Incorrect link type")
                return
            }
        }

        if to.isEmpty {
            // Empty target removes an existing link (NIO::DeleteReparseData).
            if isSymbolicLink(from) {
                do { try fm.removeItem(atPath: from) } catch { showError(error.localizedDescription); return }
                didCreateLink = true
                NSApp.stopModal()
                return
            }
            showError("Incorrect link")
            return
        }

        // Refuse to hide the data of an existing non-empty regular file.
        if let attributes = try? fm.attributesOfItem(atPath: from),
           (attributes[.type] as? FileAttributeType) == .typeRegular,
           (attributes[.size] as? NSNumber)?.int64Value ?? 0 > 0 {
            showError("WARNING: reparse point will hide the data of existing file")
            return
        }
        if isSymbolicLink(from) || fm.fileExists(atPath: from) {
            // replacing an existing empty file / link
            try? fm.removeItem(atPath: from)
        }

        do {
            if type == .hard {
                // link(2): both pointers must stay valid for the whole call.
                let status = to.withCString { target in from.withCString { newPath in link(target, newPath) } }
                if status != 0 {
                    let code = errno
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                                  userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
                }
            } else {
                try fm.createSymbolicLink(atPath: from, withDestinationPath: to)
            }
        } catch {
            showError(error.localizedDescription)
            return
        }
        didCreateLink = true
        NSApp.stopModal()
    }

    private func isSymbolicLink(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    @objc private func cancelClicked() {
        didCreateLink = false
        NSApp.stopModal()
    }

    /// MessageBoxW(MyFormatMessage(GetLastError()), "7-Zip", MB_ICONERROR)
    private func showError(_ text: String) {
        WinMessageBox.run(text, icon: .error, owner: window)
    }

    /// Returns true when a link was created (the caller then refreshes the panel).
    @discardableResult
    static func run(currentDirPrefix: String, filePath: String, anotherPath: String,
                    parent: NSWindow? = nil) -> Bool {
        let dialog = LinkDialog(currentDirPrefix: currentDirPrefix, filePath: filePath,
                                anotherPath: anotherPath, parent: parent)
        DialogKit.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
        return dialog.didCreateLink
    }
}
