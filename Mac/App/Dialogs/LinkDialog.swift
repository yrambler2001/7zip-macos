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
// exist here; the dialog says so in a footnote instead of hiding the fact.

import AppKit

final class LinkDialog: NSObject {

    enum LinkType: Int {
        case hard = 7711        // IDR_LINK_TYPE_HARD
        case symbolicFile = 7712 // IDR_LINK_TYPE_SYM_FILE
        case symbolicDir = 7713  // IDR_LINK_TYPE_SYM_DIR
    }

    private let window: NSWindow
    private let fromCombo = NSComboBox()          // IDC_LINK_PATH_FROM 100
    private let toCombo = NSComboBox()            // IDC_LINK_PATH_TO 101
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
            combo.translatesAutoresizingMaskIntoConstraints = false
            combo.addConstraint(NSLayoutConstraint(item: combo, attribute: .width, relatedBy: .greaterThanOrEqual,
                                                  toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 400))
        }
        currentTarget.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let browseFrom = DialogKit.button("...", target: self, action: #selector(browseFromClicked))  // IDB_LINK_PATH_FROM 103
        let browseTo = DialogKit.button("...", target: self, action: #selector(browseToClicked))      // IDB_LINK_PATH_TO 104
        let fromRow = NSStackView(views: [fromCombo, browseFrom])
        fromRow.orientation = .horizontal
        fromRow.spacing = 8
        let toRow = NSStackView(views: [toCombo, browseTo])
        toRow.orientation = .horizontal
        toRow.spacing = 8

        // IDG_LINK_TYPE 7710 "Link Type"
        let typeStack = NSStackView(views: [hardRadio, symFileRadio, symDirRadio])
        typeStack.orientation = .vertical
        typeStack.alignment = .leading
        typeStack.spacing = 4
        let typeBox = NSBox()
        typeBox.title = Lang.text(7710, "Link Type")
        // The stack goes into a *wrapper* that becomes the box's content view. Constraining it
        // against `typeBox.contentView` after assigning the stack as that content view made every
        // constraint self-referential ("leading == own leading + 8"), Auto Layout broke them and
        // the box collapsed onto its own title, over the third radio button.
        let typeContent = NSView()
        typeStack.translatesAutoresizingMaskIntoConstraints = false
        typeContent.addSubview(typeStack)
        NSLayoutConstraint.activate([
            typeStack.leadingAnchor.constraint(equalTo: typeContent.leadingAnchor, constant: 8),
            typeStack.topAnchor.constraint(equalTo: typeContent.topAnchor, constant: 6),
            typeStack.bottomAnchor.constraint(equalTo: typeContent.bottomAnchor, constant: -6),
            typeStack.trailingAnchor.constraint(lessThanOrEqualTo: typeContent.trailingAnchor, constant: -8),
        ])
        typeBox.contentView = typeContent

        // IDR_LINK_TYPE_JUNCTION 7714 and IDR_LINK_TYPE_WSL 7715 are NTFS-only.
        let footnote = DialogKit.label("Directory Junction and WSL links are NTFS reparse points; macOS has no equivalent.")
        footnote.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        footnote.textColor = .secondaryLabelColor

        let link = DialogKit.button(Lang.text(7701, "Link"), target: self, action: #selector(linkClicked), key: "\r")  // IDB_LINK_LINK 7701
        let cancel = DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(cancelClicked),
                                      key: "\u{1b}")
        let buttons = NSStackView(views: [NSView(), link, cancel])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [
            DialogKit.label(Lang.text(7702, "Link from:")),      // IDT_LINK_PATH_FROM 7702
            fromRow,
            DialogKit.label(Lang.text(7703, "Link to:")),        // IDT_LINK_PATH_TO 7703
            toRow,
            currentTarget,
            typeBox,
            footnote,
            buttons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [fromRow, toRow, typeBox, buttons] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 540)
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
        panel.message = Lang.text(6007, "Specify a folder:")     // IDS_SET_FOLDER
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
        let alert = NSAlert()
        alert.messageText = "7-Zip"
        alert.informativeText = text
        alert.alertStyle = .critical
        alert.addButton(withTitle: Lang.text(401, "OK"))
        alert.beginSheetModal(for: window)
    }

    /// Returns true when a link was created (the caller then refreshes the panel).
    @discardableResult
    static func run(currentDirPrefix: String, filePath: String, anotherPath: String,
                    parent: NSWindow? = nil) -> Bool {
        let dialog = LinkDialog(currentDirPrefix: currentDirPrefix, filePath: filePath,
                                anotherPath: anotherPath, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
        return dialog.didCreateLink
    }
}
