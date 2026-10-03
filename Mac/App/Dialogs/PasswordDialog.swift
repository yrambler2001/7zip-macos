// PasswordDialog.swift -- CPasswordDialog / IDD_PASSWORD 3800 "Enter password"
// (PasswordDialog.cpp/.rc), built in code. Parity: 01b-fm-dialogs-settings.md 4.16.
//
// The extract/open side shows the password field + "Show password"; the compress side
// (CCompressDialog's password block, CompressDialogRes.h:27-45) adds the verify field
// (IDT_PASSWORD_REENTER 3802 / IDE_COMPRESS_PASSWORD2 121) and "Encrypt file names"
// (IDX_COMPRESS_ENCRYPT_FILE_NAMES 4016). Both live behind `Options` so the `compress`
// scope can reuse this dialog.

import AppKit
import SevenZipKit

final class PasswordDialog: NSObject, NSTextFieldDelegate {

    struct Options {
        /// Shown under the title; the archive or file the password is for.
        var subject: String = ""
        /// Show the verify field and validate that both entries match (compress side).
        var requiresVerification = false
        /// Show the "Encrypt file names" checkbox (7z header encryption, -mhe).
        var showsEncryptFileNames = false
        var encryptFileNames = false
        /// NExtract::Read_ShowPassword(): the remembered state of the Show checkbox.
        var showPassword = SZSettings.bool(forKey: "Extraction.ShowPassword", defaultValue: false)
        var password = ""
    }

    struct Result {
        var password: String
        var showPassword: Bool
        var encryptFileNames: Bool
    }

    private let window: NSWindow
    private let options: Options
    private var result: Result?

    // Controls (Windows IDs in comments)
    private let passwordField = NSSecureTextField()     // IDE_PASSWORD_PASSWORD 120
    private let plainField = NSTextField()              // same control with PasswordChar = 0
    private let verifyField = NSSecureTextField()       // IDE_COMPRESS_PASSWORD2 121
    private let plainVerifyField = NSTextField()
    private let showBox: NSButton                       // IDX_PASSWORD_SHOW 3803
    private let encryptNamesBox: NSButton               // IDX_COMPRESS_ENCRYPT_FILE_NAMES 4016
    private let mismatchLabel = DialogKit.label("")     // IDS_PASSWORD_NOT_MATCH 3804
    private let okButton: NSButton                      // IDOK

    private init(options: Options, parent: NSWindow?) {
        self.options = options
        window = DialogKit.window(title: Lang.text(3800, "Enter password"), resizable: false)
        showBox = DialogKit.checkbox(Lang.dialogText(3800, 3803, "Show password"), target: nil, action: nil)
        encryptNamesBox = DialogKit.checkbox(Lang.text(4016, "Encrypt file names"), target: nil, action: nil)
        okButton = DialogKit.button(Lang.text(401, "OK"), target: nil, action: #selector(NSObject.doesNotRecognizeSelector(_:)), key: "\r")
        super.init()

        okButton.target = self
        okButton.action = #selector(accept)
        let cancel = DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(cancel), key: "\u{1b}")
        showBox.target = self
        showBox.action = #selector(toggleShowPassword)
        showBox.state = options.showPassword ? .on : .off
        encryptNamesBox.state = options.encryptFileNames ? .on : .off
        encryptNamesBox.isHidden = !options.showsEncryptFileNames

        for field in [passwordField, plainField, verifyField, plainVerifyField] {
            field.stringValue = options.password
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.addConstraint(NSLayoutConstraint(item: field, attribute: .width, relatedBy: .greaterThanOrEqual,
                                                  toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: 260))
        }
        mismatchLabel.textColor = .systemRed

        let enterLabel = DialogKit.label(Lang.dialogText(3800, 3801, "Enter password:"))     // IDT_PASSWORD_ENTER 3801
        let reenterLabel = DialogKit.label(Lang.text(3802, "Reenter password:")) // IDT_PASSWORD_REENTER 3802

        var views: [NSView] = []
        if !options.subject.isEmpty {
            views.append(DialogKit.label(options.subject))
        }
        views.append(enterLabel)
        views.append(contentsOf: [passwordField, plainField])
        if options.requiresVerification {
            views.append(reenterLabel)
            views.append(contentsOf: [verifyField, plainVerifyField])
            views.append(mismatchLabel)
        }
        views.append(showBox)
        if options.showsEncryptFileNames { views.append(encryptNamesBox) }

        let buttons = NSStackView(views: [cancel, okButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        let buttonRow = NSStackView(views: [NSView(), buttons])
        buttonRow.orientation = .horizontal
        views.append(buttonRow)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        for view in [passwordField, plainField, verifyField, plainVerifyField, buttonRow] as [NSView] where views.contains(view) {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }

        DialogKit.install(stack, in: window, parent: parent, minimumWidth: 340)
        applyShowPassword()
        window.initialFirstResponder = options.showPassword ? plainField : passwordField
    }

    /// SetTextSpec (PasswordDialog.cpp:43-52): SetPasswordChar(show ? 0 : '*') and re-set
    /// the text — implemented on macOS by swapping the secure and the plain field.
    private func applyShowPassword() {
        let show = showBox.state == .on
        plainField.isHidden = !show
        passwordField.isHidden = show
        plainVerifyField.isHidden = !show
        verifyField.isHidden = show
        if show {
            plainField.stringValue = passwordField.stringValue
            plainVerifyField.stringValue = verifyField.stringValue
        } else {
            passwordField.stringValue = plainField.stringValue
            verifyField.stringValue = plainVerifyField.stringValue
        }
        window.makeFirstResponder(show ? plainField : passwordField)
    }

    private var enteredPassword: String {
        showBox.state == .on ? plainField.stringValue : passwordField.stringValue
    }

    private var enteredVerification: String {
        showBox.state == .on ? plainVerifyField.stringValue : verifyField.stringValue
    }

    @objc private func toggleShowPassword() { applyShowPassword() }

    @objc private func accept() {
        // OnOK (:54-58) -> ReadControls. The compress side also checks IDS_PASSWORD_NOT_MATCH.
        if options.requiresVerification, enteredPassword != enteredVerification {
            mismatchLabel.stringValue = Lang.text(3804, "Passwords do not match")
            NSSound.beep()
            return
        }
        result = Result(password: enteredPassword,
                        showPassword: showBox.state == .on,
                        encryptFileNames: encryptNamesBox.state == .on)
        NSApp.stopModal()
    }

    @objc private func cancel() {
        result = nil
        NSApp.stopModal()
    }

    // MARK: running

    /// Runs the dialog modally on the main thread. nil = Cancel (the caller returns E_ABORT).
    /// Saves the Show-password state like CExtractCallbackImp does (Save_ShowPassword).
    static func run(_ options: Options = Options(), parent: NSWindow? = nil) -> Result? {
        let dialog = PasswordDialog(options: options, parent: parent)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
        if let result = dialog.result, result.showPassword != options.showPassword {
            Settings.extractShowPassword = result.showPassword   // through Settings, so observers hear it
        }
        return dialog.result
    }

    /// Convenience for the extract side: just the password for `path`, nil on Cancel.
    static func askPassword(forPath path: String, parent: NSWindow? = nil) -> String? {
        var options = Options()
        options.subject = (path as NSString).lastPathComponent
        return run(options, parent: parent)?.password
    }
}
