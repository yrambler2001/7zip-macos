// ExtractDialog.swift -- CExtractDialog / IDD_EXTRACT 3400 "Extract"
// (GUI/ExtractDialog.cpp/.rc), built in code. Parity: 01b-fm-dialogs-settings.md §4.25,
// 01-fm-feature-inventory.md §8.3 step 1, PROGRESS.md §4.1.
//
// Every control keeps its Windows resource ID in a comment and takes its label from the lang
// table by ID (the `kLangIDs` list of ExtractDialog.cpp:75-89). The two mode controls are
// combo boxes because that is what the resource declares (`MY_COMBO`, IDC_EXTRACT_PATH_MODE 102
// and IDC_EXTRACT_OVERWRITE_MODE 103); 7zFM has no radio group here.
//
// Settings: every value is read from and written back to the `Extraction.*` keys through
// `Settings` with the Windows tri-state (CBoolPair) semantics -- see Mac/docs/api/options.md
// and NExtract::CInfo::Load/Save (UI/Common/ZipRegistry.cpp:103-175).

import AppKit
import SevenZipKit

final class ExtractDialog: NSObject, NSTextFieldDelegate {

    /// CExtractDialog's in/out members (ExtractDialog.h:76-92).
    struct Options {
        /// DirPath (in/out): the normalised output directory the caller proposes.
        var directoryPath: String = ""
        /// ArcPath: set only when exactly one archive is being extracted; appended to the
        /// caption as " : <ArcPath>" (ExtractDialog.cpp:141-150).
        var archivePath: String = ""
        /// Password (in/out), pre-filled when the caller already knows it (`-p`).
        var password: String = ""
        var pathMode: SZExtractPathMode = .curPaths
        /// PathMode_Force: the caller insists, so the stored setting must not override it.
        var pathModeForced = false
        var overwriteMode: SZOverwriteMode = .ask
        var overwriteModeForced = false
        /// ElimDup as a CBoolPair: nil = the caller has no opinion (Def == false).
        var eliminateDuplicateRoot: Bool?
        /// NtSecurity as a CBoolPair. The control is hidden on macOS (01 §9 #7).
        var restoreFileSecurity: Bool?
        /// Informational lines rendered above the buttons -- **only** for Extract inside an
        /// archive, where 7zFM shows `CCopyDialog` and this is its info text
        /// (`CApp::GetItemsInfoString`, App.cpp:500-547, max 11 lines). IDD_EXTRACT itself has no
        /// such control, so archives on disk and the 7zG command line leave it empty (winmatch).
        var summaryLines: [String] = []
        var parentWindow: NSWindow?
    }

    struct Result {
        /// DirPath: trimmed, slash-terminated, with the sub-folder name appended.
        var directoryPath: String
        var pathMode: SZExtractPathMode
        var overwriteMode: SZOverwriteMode
        var password: String
        var eliminateDuplicateRoot: Bool?
        var restoreFileSecurity: Bool?
    }

    // IDC_EXTRACT_PATH_MODE 102: kPathMode_IDs / kPathModeButtonsVals (ExtractDialog.cpp:33-57).
    // kCurPaths is not offered: a caller's kCurPaths shows as "Full pathnames" and is kept
    // unless the user picks something else (OnOK, :302-305).
    private static let pathModes: [(id: UInt32, fallback: String, value: SZExtractPathMode)] = [
        (3411, "Full pathnames", .fullPaths),       // IDS_EXTRACT_PATHS_FULL
        (3412, "No pathnames", .noPaths),           // IDS_EXTRACT_PATHS_NO
        (3413, "Absolute pathnames", .absPaths),    // IDS_EXTRACT_PATHS_ABS
    ]

    // IDC_EXTRACT_OVERWRITE_MODE 103: kOverwriteMode_IDs / kOverwriteButtonsVals (:40-69).
    private static let overwriteModes: [(id: UInt32, fallback: String, value: SZOverwriteMode)] = [
        (3421, "Ask before overwrite", .ask),               // IDS_EXTRACT_OVERWRITE_ASK
        (3422, "Overwrite without prompt", .overwrite),     // _WITHOUT_PROMPT
        (3423, "Skip existing files", .skip),               // _SKIP_EXISTING
        (3424, "Auto rename", .rename),                     // _RENAME
        (3425, "Auto rename existing files", .renameExisting), // _RENAME_EXISTING
    ]

    /// kHistorySize (ExtractDialog.cpp:91).
    static let historySize = 16

    private let window: NSWindow
    private let options: Options
    private var result: Result?

    // Controls, with their Windows IDs.
    private let pathCombo = NSComboBox()                    // IDC_EXTRACT_PATH 100
    private let browseButton: NSButton                      // IDB_EXTRACT_SET_PATH 101
    private let nameEnableBox: NSButton                     // IDX_EXTRACT_NAME_ENABLE 131
    private let nameField = NSTextField()                   // IDE_EXTRACT_NAME 130
    private let pathModeCombo = NSPopUpButton()             // IDC_EXTRACT_PATH_MODE 102
    private let overwriteModeCombo = NSPopUpButton()         // IDC_EXTRACT_OVERWRITE_MODE 103
    private let elimDupBox: NSButton                        // IDX_EXTRACT_ELIM_DUP 3430
    private let ntSecurityBox: NSButton                     // IDX_EXTRACT_NT_SECUR 3431 (hidden)
    // IDX_EXTRACT_ALT_STREAMS 3432 is not built: NTFS alternate streams do not exist on macOS (01 §9 #6).
    private let passwordField = NSSecureTextField()          // IDE_EXTRACT_PASSWORD 120
    private let plainPasswordField = NSTextField()           // the same control with PasswordChar = 0
    private let showPasswordBox: NSButton                    // IDX_PASSWORD_SHOW 3803

    /// The settings snapshot, i.e. NExtract::CInfo after Load() (ZipRegistry.cpp:140-175).
    private struct StoredInfo {
        var pathMode: Int?        // Extraction.ExtractMode, nil = not forced
        var overwriteMode: Int?   // Extraction.OverwriteMode
        var splitDest: Bool?      // Extraction.SplitDest (effective default true)
        var elimDup: Bool?        // Extraction.ElimDup
        var ntSecurity: Bool?     // Extraction.Security
        var showPassword: Bool?   // Extraction.ShowPassword
        var paths: [String]       // Extraction.PathHistory
    }
    private var info: StoredInfo
    /// The path mode shown in the combo, i.e. `_info.PathMode` after the kCurPaths fixup.
    private var displayedPathMode: SZExtractPathMode

    // MARK: - construction (OnInit, ExtractDialog.cpp:137-244)

    private init(options: Options) {
        self.options = options

        info = StoredInfo(pathMode: Settings.extractPathMode,
                          overwriteMode: Settings.extractOverwriteMode,
                          splitDest: Settings.extractSplitDest,
                          elimDup: Settings.extractElimDup,
                          ntSecurity: Settings.extractNtSecurity,
                          showPassword: Settings.extractShowPassword,
                          paths: Settings.extractPathHistory)

        // _info.Load(); a stored kCurPaths is shown as Full (:174-176).
        var storedPathMode = SZExtractPathMode(rawValue: info.pathMode ?? Int(SZExtractPathMode.curPaths.rawValue))
            ?? .curPaths
        if storedPathMode == .curPaths { storedPathMode = .fullPaths }

        // if (!PathMode_Force && _info.PathMode_Force) PathMode = _info.PathMode;
        var pathMode = options.pathMode
        if !options.pathModeForced, info.pathMode != nil { pathMode = storedPathMode }
        // (the overwrite combo reads the same rule from `currentOverwriteModeRawValue`)
        // A caller's kCurPaths is displayed as Full (:302-305 keeps it unless changed).
        displayedPathMode = (pathMode == .curPaths) ? .fullPaths : pathMode

        // Caption: the translated IDD_EXTRACT text (fallback "Extract") + " : <ArcPath>".
        var title = Lang.translated(3400) ?? "Extract"                     // IDD_EXTRACT 3400
        if !options.archivePath.isEmpty { title += " : " + options.archivePath }
        window = DialogKit.window(title: title, resizable: false)

        browseButton = DialogKit.button("...", target: nil, action: #selector(NSObject.description))
        nameEnableBox = DialogKit.checkbox("", target: nil, action: nil)
        elimDupBox = DialogKit.checkbox(Lang.text(3430, "Eliminate duplication of root folder"),
                                       target: nil, action: nil)
        ntSecurityBox = DialogKit.checkbox(Lang.text(3431, "Restore file security"), target: nil, action: nil)
        showPasswordBox = DialogKit.checkbox(Lang.dialogText(3400, 3803, "Show Password"), target: nil, action: nil)
        super.init()

        browseButton.target = self
        browseButton.action = #selector(browse)
        nameEnableBox.target = self
        nameEnableBox.action = #selector(toggleSubfolder)
        showPasswordBox.target = self
        showPasswordBox.action = #selector(toggleShowPassword)

        // CheckButton_TwoBools(IDX_EXTRACT_ELIM_DUP, ElimDup, _info.ElimDup): the caller's Def
        // wins, then the setting, else the caller's Val -- false for a CBoolPair nobody set
        // (GetBoolsVal, :114-119; ZipRegistry.cpp Key_Get_BoolPair).
        elimDupBox.state = Self.twoBools(options.eliminateDuplicateRoot, info.elimDup,
                                         fallback: Settings.extractElimDupValue) ? .on : .off
        ntSecurityBox.state = Self.twoBools(options.restoreFileSecurity, info.ntSecurity,
                                            fallback: false) ? .on : .off
        // 01 §9 #7: NT security descriptors do not exist on macOS, so the control is hidden;
        // the stored value still round-trips so a shared registry/plist keeps it.
        ntSecurityBox.isHidden = true

        showPasswordBox.state = Settings.extractShowPasswordValue ? .on : .off

        // Path combo + history (max kHistorySize entries).
        pathCombo.isEditable = true
        pathCombo.completes = false
        pathCombo.usesDataSource = false
        pathCombo.numberOfVisibleItems = Self.historySize
        pathCombo.addItems(withObjectValues: Array(info.paths.prefix(Self.historySize)))

        // SplitDest: the last path component goes into the name edit, the parent into the combo.
        var prefix = options.directoryPath
        let splitDest = info.splitDest ?? Settings.extractSplitDestValue
        nameEnableBox.state = splitDest ? .on : .off
        if splitDest {
            let (dirPrefix, name) = Self.splitPathToPartsSmart(options.directoryPath)
            if dirPrefix.isEmpty {
                prefix = name
            } else {
                prefix = dirPrefix
                nameField.stringValue = name
            }
        }
        pathCombo.stringValue = prefix
        nameField.isHidden = !splitDest

        for field in [passwordField, plainPasswordField] {
            field.stringValue = options.password
            field.delegate = self
        }

        // IDD_EXTRACT is a fixed 336 x 168 dialog-unit window (01b §4.25), so the macOS dialog is
        // laid out at a fixed size too: the stack is pinned to the top and the two side margins
        // and keeps its natural row heights. Sizing from `fittingSize` (DialogKit.install) lets
        // the stack compress its rows into each other when the grid and the box report late.
        let content = buildContent()
        let host = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -20),
            content.topAnchor.constraint(equalTo: host.topAnchor, constant: 20),
            content.bottomAnchor.constraint(lessThanOrEqualTo: host.bottomAnchor, constant: -20),
        ])
        window.contentView = host
        let summaryHeight = CGFloat(min(options.summaryLines.count, 12)) * 14
        window.setContentSize(NSSize(width: 560, height: 322 + summaryHeight))
        host.layoutSubtreeIfNeeded()
        DialogKit.center(window, over: options.parentWindow)   // the owner, not the screen
        applyShowPassword()
        window.initialFirstResponder = pathCombo
    }

    /// GetBoolsVal (ExtractDialog.cpp:114-119) with the effective default as the last resort.
    private static func twoBools(_ callers: Bool?, _ stored: Bool?, fallback: Bool) -> Bool {
        if let callers { return callers }
        if let stored { return stored }
        return fallback
    }

    /// SplitPathToParts_Smart (Common/Wildcard.cpp:188-202): the last component (with its
    /// trailing separator) and everything before it.
    static func splitPathToPartsSmart(_ path: String) -> (dirPrefix: String, name: String) {
        let chars = Array(path)
        if chars.isEmpty { return ("", "") }
        var p = chars.count
        if chars[p - 1] == "/" { p -= 1 }
        while p != 0, chars[p - 1] != "/" { p -= 1 }
        return (String(chars[0..<p]), String(chars[p...]))
    }

    private func buildContent() -> NSView {
        // "E&xtract to:" IDT_EXTRACT_EXTRACT_TO 3401
        let extractToLabel = DialogKit.label(Lang.text(3401, "Extract to:"))
        browseButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        let pathRow = NSStackView(views: [pathCombo, browseButton])
        pathRow.orientation = .horizontal
        pathRow.spacing = 6
        pathCombo.translatesAutoresizingMaskIntoConstraints = false
        pathCombo.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true

        // The unnamed checkbox + the sub-folder name edit (IDX_EXTRACT_NAME_ENABLE 131 /
        // IDE_EXTRACT_NAME 130). Windows draws the box to the left of the edit with no text.
        let nameRow = NSStackView(views: [nameEnableBox, nameField])
        nameRow.orientation = .horizontal
        nameRow.spacing = 6

        // "Path mode:" IDT_EXTRACT_PATH_MODE 3410 / "Overwrite mode:" IDT_EXTRACT_OVERWRITE_MODE 3420
        for (id, fallback, value) in Self.pathModes {
            pathModeCombo.addItem(withTitle: Lang.text(id, fallback))
            pathModeCombo.lastItem?.tag = Int(value.rawValue)
        }
        pathModeCombo.selectItem(at: Self.pathModes.firstIndex { $0.value == displayedPathMode } ?? 0)
        for (id, fallback, value) in Self.overwriteModes {
            overwriteModeCombo.addItem(withTitle: Lang.text(id, fallback))
            overwriteModeCombo.lastItem?.tag = Int(value.rawValue)
        }
        let overwriteValue = SZOverwriteMode(rawValue: currentOverwriteModeRawValue) ?? .ask
        overwriteModeCombo.selectItem(at: Self.overwriteModes.firstIndex { $0.value == overwriteValue } ?? 0)

        let modeGrid = NSGridView(views: [
            [DialogKit.label(Lang.text(3410, "Path mode:")), pathModeCombo],
            [DialogKit.label(Lang.text(3420, "Overwrite mode:")), overwriteModeCombo],
        ])
        modeGrid.rowSpacing = 6
        modeGrid.columnSpacing = 10
        modeGrid.column(at: 1).xPlacement = .fill

        // Password group: IDG_PASSWORD 3807 group box with IDE_EXTRACT_PASSWORD 120 and
        // IDX_PASSWORD_SHOW 3803.
        let passwordBox = NSBox()
        passwordBox.title = Lang.text(3807, "Password")
        passwordBox.titlePosition = .atTop
        let passwordStack = NSStackView(views: [passwordField, plainPasswordField, showPasswordBox])
        passwordStack.orientation = .vertical
        passwordStack.alignment = .leading
        passwordStack.spacing = 6
        passwordStack.translatesAutoresizingMaskIntoConstraints = false
        // NSBox does not constrain a hand-made content view, so pin it explicitly; without this
        // the box reports a zero fitting size and the whole dialog collapses.
        let passwordContent = NSView()
        passwordContent.translatesAutoresizingMaskIntoConstraints = false
        passwordContent.addSubview(passwordStack)
        NSLayoutConstraint.activate([
            passwordStack.leadingAnchor.constraint(equalTo: passwordContent.leadingAnchor, constant: 8),
            passwordStack.trailingAnchor.constraint(equalTo: passwordContent.trailingAnchor, constant: -8),
            passwordStack.topAnchor.constraint(equalTo: passwordContent.topAnchor, constant: 8),
            passwordStack.bottomAnchor.constraint(equalTo: passwordContent.bottomAnchor, constant: -8),
        ])
        passwordBox.contentView = passwordContent
        // ... and pin the content view to the box, which NSBox does not do for a view that opts
        // out of autoresizing: without it the box has no height and draws over its neighbour.
        NSLayoutConstraint.activate([
            passwordContent.leadingAnchor.constraint(equalTo: passwordBox.leadingAnchor),
            passwordContent.trailingAnchor.constraint(equalTo: passwordBox.trailingAnchor),
            passwordContent.topAnchor.constraint(equalTo: passwordBox.topAnchor, constant: 20),
            passwordContent.bottomAnchor.constraint(equalTo: passwordBox.bottomAnchor),
        ])
        for field in [passwordField, plainPasswordField] {
            field.translatesAutoresizingMaskIntoConstraints = false
            passwordStack.addConstraint(NSLayoutConstraint(item: field, attribute: .width, relatedBy: .equal,
                                                          toItem: passwordStack, attribute: .width,
                                                          multiplier: 1, constant: 0))
        }

        let ok = DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(accept), key: "\r")
        let cancel = DialogKit.button(Lang.text(402, "Cancel"), target: self, action: #selector(cancel), key: "\u{1b}")
        // IDHELP -> kHelpTopic "fm/plugins/7-zip/extract.htm" (ExtractDialog.cpp:414)
        let help = DialogKit.button(Lang.text(409, "Help"), target: self, action: #selector(showHelp))
        let buttons = NSStackView(views: [help, NSView(), cancel, ok])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        var views: [NSView] = [extractToLabel, pathRow, nameRow, modeGrid, elimDupBox, ntSecurityBox, passwordBox]
        if !options.summaryLines.isEmpty {
            let summary = DialogKit.label(options.summaryLines.joined(separator: "\n"))
            summary.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            summary.textColor = .secondaryLabelColor
            summary.maximumNumberOfLines = 12
            summary.lineBreakMode = .byTruncatingMiddle
            views.append(summary)
        }
        views.append(buttons)

        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        // Without this the stack happily compresses its rows into each other and the window is
        // sized from the compressed fitting size.
        stack.setHuggingPriority(.required, for: .vertical)
        stack.setClippingResistancePriority(.required, for: .vertical)
        stack.setClippingResistancePriority(.required, for: .horizontal)
        for view in views {
            view.setContentCompressionResistancePriority(.required, for: .vertical)
        }
        for view in [pathRow, nameRow, modeGrid, passwordBox, buttons] as [NSView] {
            stack.addConstraint(NSLayoutConstraint(item: view, attribute: .width, relatedBy: .equal,
                                                   toItem: stack, attribute: .width, multiplier: 1, constant: 0))
        }
        return stack
    }

    private var currentOverwriteModeRawValue: Int {
        if !options.overwriteModeForced, let stored = info.overwriteMode { return stored }
        return Int(options.overwriteMode.rawValue)
    }

    // MARK: - controls

    /// OnButtonClicked IDX_EXTRACT_NAME_ENABLE (:263-264): show / hide the name edit.
    @objc private func toggleSubfolder() {
        nameField.isHidden = nameEnableBox.state != .on
    }

    /// UpdatePasswordControl (:246-253): SetPasswordChar(show ? 0 : '*'). On macOS the secure
    /// and the plain field are swapped, as in PasswordDialog.
    @objc private func toggleShowPassword() { applyShowPassword() }

    private func applyShowPassword() {
        let show = showPasswordBox.state == .on
        plainPasswordField.isHidden = !show
        passwordField.isHidden = show
        if show {
            plainPasswordField.stringValue = passwordField.stringValue
        } else {
            passwordField.stringValue = plainPasswordField.stringValue
        }
    }

    private var enteredPassword: String {
        showPasswordBox.state == .on ? plainPasswordField.stringValue : passwordField.stringValue
    }

    /// OnButtonSetPath (:276-288): MyBrowseForFolder with IDS_EXTRACT_SET_FOLDER 3402, result
    /// normalised to a directory prefix. On macOS that is NSOpenPanel (01 §9 #25).
    @objc private func browse() {
        let panel = NSOpenPanel()
        panel.message = Lang.text(3402, "Specify a location for extracted files.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let current = pathCombo.stringValue
        if !current.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pathCombo.selectItem(at: -1)                 // _path.SetCurSel(-1)
        pathCombo.stringValue = Self.normalizeDirPathPrefix(url.path)
    }

    @objc private func showHelp() {
        // IDHELP: kHelpTopic "fm/plugins/7-zip/extract.htm" (ExtractDialog.cpp:414-418). 01 §9 #17:
        // the .chm is bundled as HTML, see `Help`.
        Help.show(topic: Help.extract)
    }

    /// NormalizeDirPathPrefix: a non-empty path gets a trailing "/".
    static func normalizeDirPathPrefix(_ path: String) -> String {
        if path.isEmpty || path.hasSuffix("/") { return path }
        return path + "/"
    }

    // MARK: - OK (OnOK, ExtractDialog.cpp:299-411)

    @objc private func accept() {
        let selectedPathMode = SZExtractPathMode(rawValue: pathModeCombo.selectedTag()) ?? .fullPaths
        // "if (PathMode != kCurPaths || pathMode2 != kFullPaths) PathMode = pathMode2": a
        // caller's kCurPaths survives unless the user picked another entry.
        var pathMode = options.pathMode
        if pathMode != .curPaths || selectedPathMode != .fullPaths { pathMode = selectedPathMode }
        let overwriteMode = SZOverwriteMode(rawValue: overwriteModeCombo.selectedTag()) ?? .ask

        // GetButton_Bools: the pair is marked Def only when the value changed.
        let elimDupValue = elimDupBox.state == .on
        var elimDup = options.eliminateDuplicateRoot
        var storedElimDup = info.elimDup
        if elimDupValue != Self.twoBools(options.eliminateDuplicateRoot, info.elimDup,
                                         fallback: Settings.extractElimDupValue) {
            elimDup = elimDupValue
            storedElimDup = elimDupValue
        }
        let ntValue = ntSecurityBox.state == .on
        var ntSecurity = options.restoreFileSecurity
        var storedNtSecurity = info.ntSecurity
        if ntValue != Self.twoBools(options.restoreFileSecurity, info.ntSecurity, fallback: false) {
            ntSecurity = ntValue
            storedNtSecurity = ntValue
        }

        // The combo text, or the selected history entry.
        var path: String
        let selected = pathCombo.indexOfSelectedItem
        if selected < 0 {
            path = pathCombo.stringValue
        } else {
            path = pathCombo.itemObjectValue(at: selected) as? String ?? pathCombo.stringValue
        }
        path = path.trimmingCharacters(in: .whitespaces)
        path = Self.normalizeDirPathPrefix(path)

        let splitDest = nameEnableBox.state == .on
        if splitDest {
            path += nameField.stringValue.trimmingCharacters(in: .whitespaces)
            path = Self.normalizeDirPathPrefix(path)
        }

        result = Result(directoryPath: path,
                        pathMode: pathMode,
                        overwriteMode: overwriteMode,
                        password: enteredPassword,
                        eliminateDuplicateRoot: elimDup,
                        restoreFileSecurity: ntSecurity)

        // _info.Save() -- only the values the dialog is allowed to persist.
        if info.pathMode != Int(selectedPathMode.rawValue) {
            Settings.extractPathMode = Int(selectedPathMode.rawValue)     // PathMode_Force = true
        }
        if !options.overwriteModeForced, info.overwriteMode != Int(overwriteMode.rawValue) {
            Settings.extractOverwriteMode = Int(overwriteMode.rawValue)   // OverwriteMode_Force
        }
        if splitDest != (info.splitDest ?? Settings.extractSplitDestValue) {
            Settings.extractSplitDest = splitDest
        }
        if storedElimDup != info.elimDup { Settings.extractElimDup = storedElimDup }
        if storedNtSecurity != info.ntSecurity { Settings.extractNtSecurity = storedNtSecurity }
        let showPassword = showPasswordBox.state == .on
        if showPassword != Settings.extractShowPasswordValue {
            Settings.extractShowPassword = showPassword
        }

        // _info.Paths = the new path first, then the other history entries, max kHistorySize
        // (AddUniqueString is case-insensitive).
        var history: [String] = [path]
        for i in 0..<pathCombo.numberOfItems where i != selected {
            guard let entry = (pathCombo.itemObjectValue(at: i) as? String)?
                    .trimmingCharacters(in: .whitespaces) else { continue }
            if entry.isEmpty { continue }
            if history.contains(where: { $0.caseInsensitiveCompare(entry) == .orderedSame }) { continue }
            history.append(entry)
        }
        Settings.extractPathHistory = Array(history.prefix(Self.historySize))

        NSApp.stopModal()
    }

    /// Cancel -> E_ABORT (ExtractGUI.cpp:213).
    @objc private func cancel() {
        result = nil
        NSApp.stopModal()
    }

    // MARK: - running

    /// Runs the dialog modally. nil = Cancel. Main thread only.
    static func run(_ options: Options) -> Result? {
        let dialog = ExtractDialog(options: options)
        NSApp.runModal(for: dialog.window)
        dialog.window.orderOut(nil)
        return dialog.result
    }
}
