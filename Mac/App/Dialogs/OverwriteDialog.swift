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

        let header = DialogKit.label(Lang.text(3501, "Destination folder already contains processed file."))
        header.maximumNumberOfLines = 2                                      // IDT_OVERWRITE_HEADER 3501
        // IDT_OVERWRITE_QUESTION_BEGIN 3502
        let questionBegin = DialogKit.label(Lang.text(3502, "Would you like to replace the existing file"))
        let questionEnd = DialogKit.label(Lang.text(3503, "with this one?"))  // IDT_OVERWRITE_QUESTION_END 3503

        // IDI_OVERWRITE_OLD_FILE 100 / IDT_OVERWRITE_OLD_FILE_SIZE_TIME 102
        let oldBlock = OverwriteDialog.fileBlock(oldInfo)
        // IDI_OVERWRITE_NEW_FILE 110 / IDT_OVERWRITE_NEW_FILE_SIZE_TIME 112
        let newBlock = OverwriteDialog.fileBlock(newInfo)

        // Buttons in two rows, like the .rc (by2: Yes / Yes to All / Auto Rename,
        // by1: No / No to All / Cancel). No DEFPUSHBUTTON in the resource.
        let yes = DialogKit.button(Lang.text(406, "Yes"), target: self, action: #selector(answerYes))
        let yesToAll = DialogKit.button(Lang.text(440, "Yes to All"), target: self, action: #selector(answerYesToAll))
        let autoRename = DialogKit.button(Lang.text(3505, "Auto Rename"), target: self, action: #selector(answerAutoRename))
        let no = DialogKit.button(Lang.text(407, "No"), target: self, action: #selector(answerNo))
        let noToAll = DialogKit.button(Lang.text(441, "No to All"), target: self, action: #selector(answerNoToAll))
        let cancel = DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(answerCancel), key: "\u{1b}")

        yesToAll.isHidden = !showExtraButtons     // hidden when a single item is processed (:248)
        noToAll.isHidden = !showExtraButtons
        autoRename.isHidden = !showExtraButtons

        let topRow = NSStackView(views: [yes, yesToAll, autoRename])
        let bottomRow = NSStackView(views: [no, noToAll, cancel])
        for row in [topRow, bottomRow] {
            row.orientation = .horizontal
            row.spacing = 10
            row.distribution = .fillEqually
        }

        let stack = NSStackView(views: [header, questionBegin, oldBlock, questionEnd, newBlock, topRow, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        for view in [header, questionBegin, oldBlock, questionEnd, newBlock, topRow, bottomRow] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }

        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 520)
        // DefaultButton_is_NO (:255-261)
        window.initialFirstResponder = defaultIsNo ? no : yes
        (defaultIsNo ? no : yes).keyEquivalent = "\r"
    }

    /// SetFileInfoControl (OverwriteDialog.cpp:90-118): icon + shortened path + size + time.
    private static func fileBlock(_ info: FileInfo) -> NSView {
        let icon = NSImageView()
        icon.image = OverwriteDialog.icon(for: info)                    // SHGetFileInfo equivalent
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.addConstraint(NSLayoutConstraint(item: icon, attribute: .width, relatedBy: .equal, toItem: nil,
                                              attribute: .notAnAttribute, multiplier: 1, constant: 32))
        icon.addConstraint(NSLayoutConstraint(item: icon, attribute: .height, relatedBy: .equal, toItem: nil,
                                              attribute: .notAnAttribute, multiplier: 1, constant: 32))

        var lines: [String] = ["\"" + ProgressFormatting.reduce(info.path, limit: nameSizeLimit) + "\""]
        if let size = info.size {
            // IDS_FILE_SIZE 3504 "{0} bytes" + the K/M/G approximation (AddSizeValue :68-88)
            var line = Lang.format(Lang.text(3504, "{0} bytes"), Formatting.size(size))
            if size >= 1024 { line += " (\(approximate(size)))" }
            lines.append(line)
        }
        if let time = info.time {
            // IDS_PROP_MTIME (lang 1000 + kpidMTime = 1012) + ConvertUtcFileTimeToString
            lines.append(Lang.text(1012, "Modified") + ": " + TimeMenuDelegate.format(time, level: 0, utc: SZFolder.timestampShowUTC))
        }
        let text = DialogKit.label(lines.joined(separator: "\n"))
        text.maximumNumberOfLines = 4
        text.lineBreakMode = .byTruncatingMiddle

        let row = NSStackView(views: [icon, text])
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        return row
    }

    /// AddSizeValue (:68-88): " (N K)" / " (N M)" / " (N G)".
    private static func approximate(_ size: UInt64) -> String {
        let units: [(UInt64, String)] = [(1 << 30, "G"), (1 << 20, "M"), (1 << 10, "K")]
        for (factor, suffix) in units where size >= factor {
            return "\(size / factor) \(suffix)"
        }
        return "\(size)"
    }

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
