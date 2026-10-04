// OverwriteDialog.swift -- COverwriteDialog / IDD_OVERWRITE 3500 "Confirm File Replace"
// (OverwriteDialog.cpp/.rc), built in code. Parity: 01b-fm-dialogs-settings.md 4.15.
//
// Answers map one-to-one onto NOverwriteAnswer (SZOverwriteAnswer):
//   IDYES -> .yes, IDB_YES_TO_ALL 440 -> .yesToAll, IDNO -> .no, IDB_NO_TO_ALL 441 ->
//   .noToAll, IDB_AUTO_RENAME 3505 -> .autoRename, IDCANCEL -> .cancel.
// 7zFM has no "Auto Rename Existing" button: that is an *overwrite mode* of the Extract
// dialog (IDS_EXTRACT_OVERWRITE_RENAME_EXISTING 3425) and there is no NOverwriteAnswer for
// it, so the six buttons above are the complete set.

import AppKit
import SevenZipKit
import UniformTypeIdentifiers

final class OverwriteDialog: NSObject {

    /// COverwriteDialog::CFileInfo (OverwriteDialog.h:13-40).
    struct FileInfo {
        var path: String
        var size: UInt64?
        var time: Date?
        /// Is_FileSystemFile: use the file's own icon instead of the extension's.
        var isFileSystemFile: Bool = true

        init(path: String, size: UInt64? = nil, time: Date? = nil, isFileSystemFile: Bool = true) {
            self.path = path
            self.size = size
            self.time = time
            self.isFileSystemFile = isFileSystemFile
        }
    }

    struct Result {
        var answer: SZOverwriteAnswer
        /// The name the dialog suggests for .autoRename (AutoRenamePath equivalent).
        var suggestedName: String?
    }

    /// kCurrentFileNameSizeLimit (OverwriteDialog.cpp:34)
    private static let nameSizeLimit = 72

    private let window: NSWindow
    private var result = Result(answer: .cancel, suggestedName: nil)
    private let oldInfo: FileInfo
    private let newInfo: FileInfo

    private init(oldInfo: FileInfo, newInfo: FileInfo, showExtraButtons: Bool, defaultIsNo: Bool, parent: NSWindow?) {
        self.oldInfo = oldInfo
        self.newInfo = newInfo
        // IDD_OVERWRITE 3500, caption "Confirm File Replace", MY_MODAL_DIALOG_STYLE
        window = DialogKit.window(title: Lang.text(3500, "Confirm File Replace"), resizable: false)
        super.init()

        // IDD_OVERWRITE 3500 (OverwriteDialog.rc): 356 x 216 DLU = 534 x 351 px, fixed; every
        // control on its template rect (dlgfeel). No DEFPUSHBUTTON in the resource.
        let rc = RcDialog(3500)
        let form = RcFormView()
        form.add(DialogKit.label(Lang.text(3501, "Destination folder already contains processed file.")), rc, 3501)  // IDT_OVERWRITE_HEADER 3501
        form.add(DialogKit.label(Lang.text(3502, "Would you like to replace the existing file")), rc, 3502)  // IDT_OVERWRITE_QUESTION_BEGIN 3502
        // IDI_OVERWRITE_OLD_FILE 100 / IDT_OVERWRITE_OLD_FILE_SIZE_TIME 102
        form.add(Self.iconView(oldInfo), rc, 100).frame.size = NSSize(width: 32, height: 32)
        form.add(RcPlace.makeWrappingLabel(Self.infoText(oldInfo)), rc, 102)
        form.add(DialogKit.label(Lang.text(3503, "with this one?")), rc, 3503)                            // IDT_OVERWRITE_QUESTION_END 3503
        // IDI_OVERWRITE_NEW_FILE 110 / IDT_OVERWRITE_NEW_FILE_SIZE_TIME 112
        form.add(Self.iconView(newInfo), rc, 110).frame.size = NSSize(width: 32, height: 32)
        form.add(RcPlace.makeWrappingLabel(Self.infoText(newInfo)), rc, 112)

        let yes = form.add(DialogKit.button(Lang.text(406, "Yes"), target: self, action: #selector(answerYes)), rc, 6)
        let yesToAll = form.add(DialogKit.button(Lang.text(440, "Yes to All"), target: self,
                                                 action: #selector(answerYesToAll)), rc, 440)
        let autoRename = form.add(DialogKit.button(Lang.text(3505, "Auto Rename"), target: self,
                                                   action: #selector(answerAutoRename)), rc, 3505)
        let no = form.add(DialogKit.button(Lang.text(407, "No"), target: self, action: #selector(answerNo)), rc, 7)
        let noToAll = form.add(DialogKit.button(Lang.text(441, "No to All"), target: self,
                                                action: #selector(answerNoToAll)), rc, 441)
        form.add(DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(answerCancel),
                                  key: "\u{1b}"), rc, 2)
        // ShowItem_Bool(false) when a single item is processed (:248): the places stay empty.
        yesToAll.isHidden = !showExtraButtons
        noToAll.isHidden = !showExtraButtons
        autoRename.isHidden = !showExtraButtons

        RcPlace.install(form, in: window, size: rc.size, parent: parent)
        // DefaultButton_is_NO (:255-261)
        window.initialFirstResponder = defaultIsNo ? no : yes
        (defaultIsNo ? no : yes).keyEquivalent = "\r"
    }

    /// The 32 x 32 file icon (SHGetFileInfo SHGFI_ICON), at the static's top left.
    private static func iconView(_ info: FileInfo) -> NSImageView {
        let icon = NSImageView()
        icon.image = OverwriteDialog.icon(for: info)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.imageAlignment = .alignTopLeft
        return icon
    }

    /// SetFileInfoControl (OverwriteDialog.cpp:90-118): the folder part (up to the last separator)
    /// and the name on two lines, each ReduceString-ed, then AddSizeValue and "Modified: <time>"
    /// (:96-117). An undefined size or time leaves its line empty, as on Windows.
    private static func infoText(_ info: FileInfo) -> String {
        let slash = info.path.range(of: "/", options: .backwards)
        let folderPart = slash.map { String(info.path[..<$0.upperBound]) } ?? ""
        let namePart = slash.map { String(info.path[$0.upperBound...]) } ?? info.path
        var lines: [String] = [ProgressFormatting.reduce(folderPart, limit: nameSizeLimit),
                               ProgressFormatting.reduce(namePart, limit: nameSizeLimit)]
        lines.append(info.size.map { Formatting.sizeValue($0) } ?? "")
        if let time = info.time {
            // IDS_PROP_MTIME (lang 1000 + kpidMTime = 1012) + ConvertUtcFileTimeToString
            lines.append(Lang.text(1012, "Modified") + ": " + TimeMenuDelegate.format(time, level: 0, utc: SZFolder.timestampShowUTC))
        }
        return lines.joined(separator: "\n")
    }

    /// AddSizeValue (:68-88): " (N K)" / " (N M)" / " (N G)".
    private static func icon(for info: FileInfo) -> NSImage {
        if info.isFileSystemFile, FileManager.default.fileExists(atPath: info.path) {
            return NSWorkspace.shared.icon(forFile: info.path)
        }
        let ext = (info.path as NSString).pathExtension
        if !ext.isEmpty {
            return NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    // MARK: running

    /// Shows the dialog modally on the main thread and returns the answer.
    /// `showExtraButtons` = CExtractCallbackImp's "more than one item" flag.
    @discardableResult
    static func run(oldFile: FileInfo, newFile: FileInfo, showExtraButtons: Bool = true,
                    defaultIsNo: Bool = false, parent: NSWindow? = nil) -> Result {
        let dialog = OverwriteDialog(oldInfo: oldFile, newInfo: newFile,
                                    showExtraButtons: showExtraButtons, defaultIsNo: defaultIsNo, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
        return dialog.result
    }

    private func finish(_ answer: SZOverwriteAnswer, suggestedName: String? = nil) {
        result = Result(answer: answer, suggestedName: suggestedName)
        NSApp.stopModal()
    }

    @objc private func answerYes() { finish(.yes) }
    @objc private func answerYesToAll() { finish(.yesToAll) }
    @objc private func answerNo() { finish(.no) }
    @objc private func answerNoToAll() { finish(.noToAll) }
    @objc private func answerCancel() { finish(.cancel) }

    @objc private func answerAutoRename() {
        // The engine renames with AutoRenamePath ("name (2).ext"); the dialog only reports
        // the answer, and hands over a suggestion when it can compute one itself.
        finish(.autoRename, suggestedName: OverwriteDialog.autoRenamedName(for: oldInfo.path))
    }

    /// AutoRenamePath (CPP/7zip/Common/FilePathAutoRename.cpp): "name (2).ext", "name (3).ext"...
    static func autoRenamedName(for path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return nil }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        let directory = (path as NSString).deletingLastPathComponent
        var index = 2
        while index < 10000 {
            let candidate = ext.isEmpty ? "\(base) (\(index))" : "\(base) (\(index)).\(ext)"
            let full = directory.isEmpty ? candidate : (directory as NSString).appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: full) { return candidate }
            index += 1
        }
        return nil
    }
}
