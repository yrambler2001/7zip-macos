// CompressDialog.swift -- "Add to Archive" (IDD_COMPRESS 4000), the port of
// CPP/7zip/UI/GUI/CompressDialog.cpp's UI half. Every control keeps its Windows resource ID
// in a comment and takes its label from the lang table by ID (`kLangIDs`,
// CompressDialog.cpp:45-84). The computation half lives in CompressModel.swift.
//
// Parity: 01b-fm-dialogs-settings.md section 4.23 (controls, combo cascades, OnOK
// validation), 01-fm-feature-inventory.md section 8.5 (what the result becomes).

import AppKit
import SevenZipKit

/// What `UpdateGUI.cpp`'s `ShowDialog` hands the dialog (`NCompressDialog::CInfo` in).
struct CompressDialogInput {
    /// `DirPrefix`: the folder the archive goes into, shown in IDT_COMPRESS_ARCHIVE_FOLDER 130.
    var directoryPrefix: String = ""
    /// `Info.ArcPath`: the archive path **without** extension (the dialog adds the format's).
    var archiveBaseName: String = ""
    /// The items being added. One regular file enables the `Flags_KeepName` formats.
    var itemPaths: [String] = []
    /// `-t<type>`: forces the format and lets hash handlers into the list.
    var forcedFormatName: String?
    /// `-p`.
    var password: String?
    var updateMode: SZUpdateMode = .add
    var pathMode: SZCompressPathMode = .relative
    var sfxMode = false
    /// `-sfx<module>` resolved by the caller (`SZUpdater.resolvedSFXModulePath`); nil = the
    /// bundled `7z.sfx`. Carried to `CompressDialogResult.sfxModulePath` unchanged, so a module
    /// named on the command line survives an `-ad` round trip (03 section 2.6, 01b section 4.23).
    var sfxModulePath: String?
    var openShareForWrite = false
    var deleteAfterCompressing = false
    /// Adding to an archive that already exists: volumes are refused
    /// ("Splitting to volumes is not supported", UpdateGUI.cpp:480).
    var isUpdatingExistingArchive = false
    var parentWindow: NSWindow?

    /// `oneFile`: exactly one item and it is a regular file.
    var isOneFile: Bool {
        guard itemPaths.count == 1 else { return false }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: itemPaths[0], isDirectory: &isDir) else { return false }
        return !isDir.boolValue
    }

    /// `OriginalFileName`: used unchanged by the `Flags_KeepName` formats.
    var originalFileName: String { (itemPaths.first as NSString?)?.lastPathComponent ?? "" }
}

// ---------------------------------------------------------------------------

final class CompressDialogController: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {

    // MARK: presentation

    /// Runs the dialog modally. nil = Cancel (`E_ABORT`).
    static func run(_ input: CompressDialogInput) -> CompressDialogResult? {
        guard (try? SZCodecs.loadCodecs()) != nil else { return nil }
        let controller = CompressDialogController(input: input)
        guard controller.buildFormatList() else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "No Update Engines"
            alert.runModal()
            return nil
        }
        controller.buildWindow()
        controller.loadInitialState()
        NSApp.runModal(for: controller.window)
        controller.window.orderOut(nil)
        return controller.result
    }

    private let input: CompressDialogInput
    private var result: CompressDialogResult?
    private var model: CompressModel!

    /// `dialog.ArcIndices`: the engine format indices offered, sorted by name (CBS_SORT).
    private var formats: [SZFormatInfo] = []
    private var formatIndexInList = 0

    /// Set while the code is filling controls, so the action handlers do not re-cascade.
    private var isUpdatingControls = false
    /// `ArcPath_WasChanged`: the user edited the name, so the folder line is authoritative.
    private var directoryPrefix = ""

    private init(input: CompressDialogInput) {
        self.input = input
        self.directoryPrefix = input.directoryPrefix
        super.init()
    }

    // MARK: controls (Windows IDs in comments)

    private var window: NSWindow!
    private let folderLabel = DialogKit.label("")                     // IDT_COMPRESS_ARCHIVE_FOLDER 130
    private let archiveCombo = NSComboBox()                           // IDC_COMPRESS_ARCHIVE 100
    private let browseButton = NSButton()                             // IDB_COMPRESS_SET_ARCHIVE 101
    private let formatCombo = NSPopUpButton()                         // IDC_COMPRESS_FORMAT 104
    private let levelCombo = NSPopUpButton()                          // IDC_COMPRESS_LEVEL 102
    private let methodCombo = NSPopUpButton()                         // IDC_COMPRESS_METHOD 106
    private let dictionaryCombo = NSPopUpButton()                     // IDC_COMPRESS_DICTIONARY 107
    private let orderCombo = NSPopUpButton()                          // IDC_COMPRESS_ORDER 108
    private let solidCombo = NSPopUpButton()                          // IDC_COMPRESS_SOLID 109
    private let threadsCombo = NSPopUpButton()                        // IDC_COMPRESS_THREADS 110
    private let hardwareThreadsLabel = DialogKit.label("", alignment: .right) // IDT_COMPRESS_HARDWARE_THREADS 112
    private let memUseCombo = NSPopUpButton()                         // IDC_COMPRESS_MEM_USE 117
    private let memoryValueLabel = DialogKit.label("")                // IDT_COMPRESS_MEMORY_VALUE 113
    private let memoryDeValueLabel = DialogKit.label("", alignment: .right) // IDT_COMPRESS_MEMORY_DE_VALUE 114
    private let volumeCombo = NSComboBox()                            // IDC_COMPRESS_VOLUME 105
    private let parametersField = NSTextField()                       // IDE_COMPRESS_PARAMETERS 111
    private let optionsButton = NSButton()                            // IDB_COMPRESS_OPTIONS 2100
    private let optionsSummary = DialogKit.label("")                  // IDT_COMPRESS_OPTIONS 141
    private let updateModeCombo = NSPopUpButton()                     // IDC_COMPRESS_UPDATE_MODE 103
    private let pathModeCombo = NSPopUpButton()                       // IDC_COMPRESS_PATH_MODE 116
    private let sfxBox = NSButton()                                   // IDX_COMPRESS_SFX 4012
    private let sharedBox = NSButton()                                // IDX_COMPRESS_SHARED 4013
    private let deleteBox = NSButton()                                // IDX_COMPRESS_DEL 4019
    private let password1Field = NSSecureTextField()                  // IDE_COMPRESS_PASSWORD1 120
    private let password1Plain = NSTextField()                        // shown instead when "Show Password"
    private let password2Field = NSSecureTextField()                  // IDE_COMPRESS_PASSWORD2 121
    private let password2Label = DialogKit.label("")                  // IDT_PASSWORD_REENTER 3802
    private let showPasswordBox = NSButton()                          // IDX_PASSWORD_SHOW 3803
    private let encryptionMethodCombo = NSPopUpButton()               // IDC_COMPRESS_ENCRYPTION_METHOD 122
    private let encryptNamesBox = NSButton()                          // IDX_COMPRESS_ENCRYPT_FILE_NAMES 4016
    /// macOS addition the user asked for (dlgfeel finding 28): in the Options group, under
    /// IDX_COMPRESS_DEL. Off by default; on, the archive gets no AppleDouble `._*` files, no
    /// `.DS_Store` / `__MACOSX` and no resource-fork or extended-attribute streams.
    private let excludeMacBox = NSButton()
    private var encryptionGroupViews: [NSView] = []
    private let optionsGroup = WinGroupBox(title: "")                 // IDG_COMPRESS_OPTIONS 4011
    private let encryptionGroup = WinGroupBox(title: "")              // IDG_COMPRESS_ENCRYPTION 4014
    private let enterLabel = DialogKit.label("")                      // IDT_PASSWORD_ENTER 3801

    // Labels that need enabling/hiding with their control.
    private let methodLabel = DialogKit.label("")                     // IDT_COMPRESS_METHOD 4005
    private let dictionaryLabel = DialogKit.label("")                 // IDT_COMPRESS_DICTIONARY 4006
    private let orderLabel = DialogKit.label("")                      // IDT_COMPRESS_ORDER 4007
    private let solidLabel = DialogKit.label("")                      // IDT_COMPRESS_SOLID 4008
    private let threadsLabel = DialogKit.label("")                    // IDT_COMPRESS_THREADS 4009
    private let memoryLabel = DialogKit.label("")                     // IDT_COMPRESS_MEMORY 4017
    private let memoryDeLabel = DialogKit.label("")                   // IDT_COMPRESS_MEMORY_DE 4018

    // MARK: model state mirrored from the Options sheet

    private var timePrecision: Int?          // fo.TimePrec
    private var mTime: Bool?
    private var cTime: Bool?
    private var aTime: Bool?
    private var setArcMTime: Bool?
    private var preserveATime: Bool?
    private var symLinks: Bool?
    private var hardLinks: Bool?
    private var altStreams: Bool?
    private var ntSecurity: Bool?

    /// Per-format options in memory, as `m_RegistryInfo.Formats` is on Windows: the dialog
    /// keeps a working copy per format and writes them all at OK (`SaveOptionsInMem`).
    private var formatOptions: [String: Settings.FormatOptions] = [:]

    // MARK: - Format list (UpdateGUI.cpp:398-419)

    private func buildFormatList() -> Bool {
        let forced = input.forcedFormatName.flatMap { SZCodecs.format(named: $0) }
        let oneFile = input.isOneFile
        var list: [SZFormatInfo] = []
        for info in SZCodecs.formats {
            guard info.updateEnabled else { continue }
            if !oneFile && info.keepName { continue }
            if info.index != (forced?.index ?? -1) {
                if info.isHashHandler { continue }
                if info.name.caseInsensitiveCompare("swfc") == .orderedSame {
                    let name = input.originalFileName.lowercased()
                    if !oneFile || !name.hasSuffix(".swf") { continue }
                }
            }
            list.append(info)
        }
        // CBS_SORT sorts the combo alphabetically.
        formats = list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !formats.isEmpty else { return false }

        // Selection: -t, then Compression.Archiver, then the first entry (:503-522).
        var selected = 0
        if let forced, let i = formats.firstIndex(where: { $0.index == forced.index }) {
            selected = i
        } else {
            let stored = Settings.archiverType
            if let i = formats.firstIndex(where: { $0.name.caseInsensitiveCompare(stored) == .orderedSame }) {
                selected = i
            }
        }
        formatIndexInList = selected
        model = CompressModel(arcInfo: formats[selected])
        model.sfxMode = input.sfxMode
        return true
    }

    private var currentFormat: SZFormatInfo { formats[formatIndexInList] }

    private func options(for formatName: String) -> Settings.FormatOptions {
        if let existing = formatOptions[formatName] { return existing }
        let loaded = Settings.formatOptions(formatName)
        formatOptions[formatName] = loaded
        return loaded
    }

    // MARK: - Window construction

    /// The caption of the macOS-only checkbox (no lang id: no language file has it).
    static let excludeMacResourceForksTitle = "Exclude Mac resource forks"

    /// The extra checkbox takes one more checkbox row (16 DLU) in the Options group, so the
    /// group and everything in the Encryption group below it move down by that much; the
    /// Encryption group still ends 16 DLU above the button row.
    static let macRowDLU = 16

    private func buildWindow() {
        window = DialogKit.window(title: Lang.text(4000, "Add to Archive"), resizable: false)

        archiveCombo.isEditable = true
        archiveCombo.usesDataSource = false
        archiveCombo.completes = false
        archiveCombo.delegate = self
        archiveCombo.removeAllItems()
        archiveCombo.addItems(withObjectValues: Settings.archiveHistory)

        browseButton.title = "..."
        browseButton.bezelStyle = .rounded
        browseButton.target = self
        browseButton.action = #selector(browseForArchive(_:))

        for combo in [formatCombo, levelCombo, methodCombo, dictionaryCombo, orderCombo,
                      solidCombo, threadsCombo, memUseCombo, updateModeCombo, pathModeCombo,
                      encryptionMethodCombo] {
            combo.target = self
            combo.action = #selector(controlChanged(_:))
        }

        volumeCombo.isEditable = true
        volumeCombo.usesDataSource = false
        volumeCombo.completes = false
        volumeCombo.removeAllItems()
        volumeCombo.addItems(withObjectValues: CompressVolumes.presets)

        parametersField.placeholderString = ""
        optionsButton.title = Lang.text(2100, "Options")
        optionsButton.bezelStyle = .rounded
        optionsButton.target = self
        optionsButton.action = #selector(showOptionsSheet(_:))

        sfxBox.setButtonType(.switch)
        sfxBox.title = Lang.text(4012, "Create SFX archive")
        sfxBox.target = self
        sfxBox.action = #selector(sfxToggled(_:))
        sharedBox.setButtonType(.switch)
        sharedBox.title = Lang.text(4013, "Compress shared files")
        deleteBox.setButtonType(.switch)
        deleteBox.title = Lang.text(4019, "Delete files after compression")
        excludeMacBox.setButtonType(.switch)
        excludeMacBox.title = Self.excludeMacResourceForksTitle
        excludeMacBox.setAccessibilityIdentifier("compressExcludeMacResourceForks")

        showPasswordBox.setButtonType(.switch)
        showPasswordBox.title = Lang.dialogText(4000, 3803, "Show Password")
        showPasswordBox.target = self
        showPasswordBox.action = #selector(showPasswordToggled(_:))
        encryptNamesBox.setButtonType(.switch)
        encryptNamesBox.title = Lang.text(4016, "Encrypt file names")

        methodLabel.stringValue = Lang.text(4005, "Compression method:")
        dictionaryLabel.stringValue = Lang.text(4006, "Dictionary size:")
        orderLabel.stringValue = Lang.text(4007, "Word size:")
        solidLabel.stringValue = Lang.text(4008, "Solid Block size:")
        threadsLabel.stringValue = Lang.dialogText(4000, 4009, "Number of CPU threads:")
        memoryLabel.stringValue = Lang.text(4017, "Memory usage for Compressing:")
        memoryDeLabel.stringValue = Lang.text(4018, "Memory usage for Decompressing:")
        enterLabel.stringValue = Lang.dialogText(4000, 3801, "Enter password:")
        password2Label.stringValue = Lang.text(3802, "Reenter password:")
        optionsGroup.title = Lang.text(4011, "Options")
        encryptionGroup.title = Lang.text(4014, "Encryption")
        // The secure field and the plain one share IDE_COMPRESS_PASSWORD1's rect; "Show Password"
        // swaps them (UpdatePasswordControl clears the password char on Windows).
        password1Plain.isHidden = true

        // IDD_COMPRESS 4000 (CompressDialog.rc): 416 x 336 DLU = 624 x 546 px, fixed size; every
        // control on its template rect (RcLayout, reports/dlgfeel.md "Add to Archive").
        let rc = RcDialog(4000)
        let form = RcFormView()
        form.add(folderLabel, rc, 130)
        form.add(DialogKit.label(Lang.text(4001, "Archive:")), rc, 4001)          // IDT_COMPRESS_ARCHIVE 4001
        form.add(archiveCombo, rc, 100)
        form.add(browseButton, rc, 101)
        // the left column
        form.add(DialogKit.label(Lang.text(4003, "Archive format:")), rc, 4003)   // IDT_COMPRESS_FORMAT 4003
        form.add(formatCombo, rc, 104)
        form.add(DialogKit.label(Lang.text(4004, "Compression level:")), rc, 4004) // IDT_COMPRESS_LEVEL 4004
        form.add(levelCombo, rc, 102)
        form.add(methodLabel, rc, 4005)
        form.add(methodCombo, rc, 106)
        form.add(dictionaryLabel, rc, 4006)
        form.add(dictionaryCombo, rc, 107)
        form.add(orderLabel, rc, 4007)
        form.add(orderCombo, rc, 108)
        form.add(solidLabel, rc, 4008)
        form.add(solidCombo, rc, 109)
        form.add(threadsLabel, rc, 4009)
        form.add(threadsCombo, rc, 110)
        form.add(hardwareThreadsLabel, rc, 112)
        form.add(memoryLabel, rc, 4017)
        form.add(memUseCombo, rc, 117)
        form.add(memoryValueLabel, rc, 113)
        form.add(memoryDeLabel, rc, 4018)
        form.add(memoryDeValueLabel, rc, 114)
        form.add(DialogKit.label(Lang.dialogText(4000, 7302, "Split to volumes, bytes:")), rc, 7302) // IDT_SPLIT_TO_VOLUMES 7302
        form.add(volumeCombo, rc, 105)
        form.add(DialogKit.label(Lang.text(4010, "Parameters:")), rc, 4010)        // IDT_COMPRESS_PARAMETERS 4010
        form.add(parametersField, rc, 111)
        form.add(optionsButton, rc, 2100)
        form.add(optionsSummary, rc, 141)
        // the right column
        form.add(DialogKit.label(Lang.text(4002, "Update mode:")), rc, 4002)       // IDT_COMPRESS_UPDATE_MODE 4002
        form.add(updateModeCombo, rc, 103)
        form.add(DialogKit.label(Lang.text(3410, "Path mode:")), rc, 3410)         // IDT_COMPRESS_PATH_MODE 3410
        form.add(pathModeCombo, rc, 116)
        let rowShift = DLU.y(Self.macRowDLU)
        form.add(optionsGroup, rc, 4011)
        optionsGroup.frame.size.height += rowShift
        form.add(sfxBox, rc, 4012)
        form.add(sharedBox, rc, 4013)
        form.add(deleteBox, rc, 4019)
        form.addSubview(excludeMacBox)
        form.tabStop(excludeMacBox, rc, 4019, after: true)    // Tab: right after "Delete files after compression"
        RcPlace.check(excludeMacBox, rc.rect(4019).offsetBy(dx: 0, dy: rowShift))
        for (view, id) in [(encryptionGroup, 4014), (enterLabel, 3801), (password1Field, 120),
                           (password2Label, 3802), (password2Field, 121), (showPasswordBox, 3803),
                           (DialogKit.label(Lang.text(4015, "Encryption method:")), 4015),  // IDT_COMPRESS_ENCRYPTION_METHOD 4015
                           (encryptionMethodCombo, 122), (encryptNamesBox, 4016)] as [(NSView, Int)] {
            form.add(view, rc, id)
            view.frame.origin.y += rowShift
        }
        form.addSubview(password1Plain)
        password1Plain.frame = password1Field.frame
        password1Plain.font = password1Field.font
        password1Plain.controlSize = password1Field.controlSize
        encryptionGroupViews = [enterLabel, password1Field, password1Plain, password2Label,
                                password2Field, showPasswordBox, encryptionMethodCombo]
        // the buttons
        form.add(DialogKit.button(Lang.text(401, "OK"), target: self, action: #selector(okPressed(_:)), key: "\r"), rc, 1)
        form.add(DialogKit.button(Lang.text(402, "Cancel"), target: self,
                                  action: #selector(cancelPressed(_:)), key: "\u{1b}"), rc, 2)
        form.add(DialogKit.button(Lang.text(409, "Help"), target: self, action: #selector(helpPressed(_:))), rc, 9)

        RcPlace.install(form, in: window, size: rc.size, parent: input.parentWindow)
        window.initialFirstResponder = archiveCombo
    }

    // MARK: - Initial state (OnInit)

    private func loadInitialState() {
        isUpdatingControls = true

        // Update mode combo: k_UpdateMode_IDs (CompressDialog.cpp:378-384)
        updateModeCombo.removeAllItems()
        for (id, fallback) in [(UInt32(4060), "Add and replace files"), (4061, "Update and add files"),
                               (4062, "Freshen existing files"), (4063, "Synchronize files")] {
            updateModeCombo.addItem(withTitle: Lang.text(id, fallback))
        }
        updateModeCombo.selectItem(at: min(max(input.updateMode.rawValue, 0), 3))

        // Path mode combo: k_PathMode_IDs (:396-401)
        pathModeCombo.removeAllItems()
        for (id, fallback) in [(UInt32(3414), "Relative pathnames"),   // IDS_PATH_MODE_RELAT
                               (3411, "Full pathnames"),               // IDS_EXTRACT_PATHS_FULL
                               (3413, "Absolute pathnames")] {         // IDS_EXTRACT_PATHS_ABS
            pathModeCombo.addItem(withTitle: Lang.text(id, fallback))
        }
        pathModeCombo.selectItem(at: min(max(input.pathMode.rawValue, 0), 2))

        sharedBox.state = input.openShareForWrite ? .on : .off
        deleteBox.state = input.deleteAfterCompressing ? .on : .off
        sfxBox.state = input.sfxMode ? .on : .off
        excludeMacBox.state = Settings.compressExcludeMacResourceForks ? .on : .off
        showPasswordBox.state = Settings.compressShowPassword ? .on : .off
        encryptNamesBox.state = Settings.compressEncryptHeaders ? .on : .off
        password1Field.stringValue = input.password ?? ""
        password1Plain.stringValue = input.password ?? ""
        volumeCombo.stringValue = ""
        volumeCombo.isEnabled = !input.isUpdatingExistingArchive

        // The tri-state link/stream options: the command line wins, else the settings
        // (`SET_GUI_BOOL` / `Combine_Two_BoolPairs`).
        symLinks = Settings.compressSymLinks
        hardLinks = Settings.compressHardLinks
        altStreams = Settings.compressAltStreams
        ntSecurity = Settings.compressNtSecurity
        preserveATime = Settings.compressPreserveATime

        formatCombo.removeAllItems()
        for f in formats { formatCombo.addItem(withTitle: f.name) }
        formatCombo.selectItem(at: formatIndexInList)

        hardwareThreadsLabel.stringValue = model.hardwareThreadsText
        isUpdatingControls = false

        formatChanged(isChanged: false)
        setArchiveName(input.archiveBaseName)
        updateFolderLabel()
    }

    // MARK: - The cascade

    /// `FormatChanged` (CompressDialog.cpp:698-765).
    private func formatChanged(isChanged: Bool) {
        let previous = isUpdatingControls
        isUpdatingControls = true
        defer { isUpdatingControls = previous }

        model.setFormat(currentFormat)
        let fo = options(for: currentFormat.name)

        // Level: per-format `Level` (-1 -> 5, > 9 -> 9), default 5.
        var level = 5
        if fo.level >= 0 && fo.level <= 9 { level = fo.level }
        else if fo.level > 9 { level = 9 }
        setLevelCombo(preferred: level)

        // Method depends on the level, everything else on the method.
        setMethodCombo(storedMethod: fo.method)
        setDependentCombos()

        // Parameters (SetParams :3244-3254)
        parametersField.stringValue = fo.options

        timePrecision = fo.timePrec >= 0 ? fo.timePrec : nil
        mTime = fo.mTime
        cTime = fo.cTime
        aTime = fo.aTime
        setArcMTime = fo.setArcMTime

        checkSFXControlsEnable()
        updateEncryptionControls(storedMethod: fo.encryptionMethod)
        updateOptionsSummary()
        updateMemoryUsage()
    }

    private func setLevelCombo(preferred: Int) {
        let items = model.levelItems { Lang.text($0, $1) }
        levelCombo.removeAllItems()
        for item in items { levelCombo.addItem(withTitle: item.title) }
        levelCombo.isEnabled = items.count > 1
        // SetNearestSelectComboBox: the last item whose value is <= preferred.
        var selection = items.isEmpty ? -1 : 0
        for (i, item) in items.enumerated() where item.data <= Int64(preferred) { selection = i }
        if selection >= 0 {
            levelCombo.selectItem(at: selection)
            model.level = Int(items[selection].data)
        } else {
            model.level = -1
        }
    }

    /// `SetMethod2` (:1627-1709). `keepMethod` re-selects the same method after a level change.
    private func setMethodCombo(storedMethod: String, keepMethod: Int? = nil) {
        let items = model.methodItems
        methodCombo.removeAllItems()
        for item in items { methodCombo.addItem(withTitle: item.title) }
        // EnableMultiCombo(IDC_COMPRESS_METHOD) (CompressDialog.h:228): a one-method format
        // (bzip2, gzip, xz) shows its method grayed, as 7zG 25.01 does (wincompare.md).
        methodCombo.isEnabled = items.count > 1
        methodLabel.textColor = items.isEmpty ? .disabledControlTextColor : .labelColor
        guard !items.isEmpty else {
            model.selectedMethodRaw = nil
            return
        }
        var selection = 0
        if let keep = keepMethod, let i = items.firstIndex(where: { $0.data == Int64(keep) }) {
            selection = i
        } else if !storedMethod.isEmpty {
            for (i, item) in items.enumerated() where i > 0 {
                let name = CompressMethodID(rawValue: Int(item.data))?.name ?? item.title
                if name.caseInsensitiveCompare(storedMethod) == .orderedSame { selection = i; break }
            }
        }
        methodCombo.selectItem(at: selection)
        model.selectedMethodRaw = items[selection].isAuto ? nil : Int(items[selection].data)
    }

    /// Dictionary + word size + solid + threads + memory (the `MethodChanged` cascade).
    private func setDependentCombos() {
        let fo = options(for: currentFormat.name)
        let methodMatches = model.isMethodEqual(to: fo.method)

        let dict = model.dictionaryItems(storedDictionary: methodMatches ? Int64(fo.dictionary) : nil)
        fill(dictionaryCombo, dict.items, selection: dict.selection, label: dictionaryLabel)
        model.dictionary = dict.selection >= 0 ? dict.items[dict.selection].data : CompressModel.autoValue

        let order = model.orderItems(storedOrder: methodMatches ? Int64(fo.order) : nil)
        fill(orderCombo, order.items, selection: order.selection, label: orderLabel)
        model.order = order.selection >= 0 ? order.items[order.selection].data : CompressModel.autoValue

        setSolidCombo()
        setMemUseCombo()
        setThreadsCombo()
    }

    private func setSolidCombo() {
        let fo = options(for: currentFormat.name)
        let methodMatches = model.isMethodEqual(to: fo.method)
        let solid = model.solidItems(storedBlockLogSize: methodMatches ? Int64(fo.blockLogSize) : nil) {
            Lang.text($0, $1)
        }
        fill(solidCombo, solid.items, selection: solid.selection, label: solidLabel)
        model.blockLogSize = solid.selection >= 0 ? solid.items[solid.selection].data : CompressModel.autoValue
    }

    private func setThreadsCombo() {
        let fo = options(for: currentFormat.name)
        let methodMatches = model.isMethodEqual(to: fo.method)
        let threads = model.threadItems(storedNumThreads: methodMatches ? Int64(fo.numThreads) : nil)
        fill(threadsCombo, threads.items, selection: threads.selection, label: threadsLabel)
        model.numThreads = threads.selection >= 0 ? threads.items[threads.selection].data : CompressModel.autoValue
        hardwareThreadsLabel.stringValue = threads.items.isEmpty ? "" : model.hardwareThreadsText
    }

    private var memUseItems: [CompressModel.MemUseItem] = []

    private func setMemUseCombo() {
        let fo = options(for: currentFormat.name)
        let result = model.memUseItems(stored: fo.memUse)
        memUseItems = result.items
        memUseCombo.removeAllItems()
        for item in result.items { memUseCombo.addItem(withTitle: item.title) }
        let show = !result.items.isEmpty
        // ShowItem_Bool on the five memory controls (CompressDialog.cpp:2775-2780).
        for view in [memoryLabel, memoryValueLabel, memoryDeLabel, memoryDeValueLabel, memUseCombo] as [NSView] {
            view.isHidden = !show
        }
        memUseCombo.isEnabled = show
        if show, result.selection >= 0 {
            memUseCombo.selectItem(at: result.selection)
            model.memUseSpec = result.items[result.selection].spec
        } else {
            model.memUseSpec = ""
        }
    }

    private func fill(_ combo: NSPopUpButton, _ items: [CompressComboItem], selection: Int, label: NSTextField) {
        combo.removeAllItems()
        for item in items { combo.addItem(withTitle: item.title) }
        // EnableMultiCombo: <= 1 item means nothing to choose.
        combo.isEnabled = items.count > 1
        label.textColor = items.count > 1 ? .labelColor : .disabledControlTextColor
        if selection >= 0 && selection < items.count { combo.selectItem(at: selection) }
    }

    /// `CheckSFXControlsEnable` (:618-631).
    private func checkSFXControlsEnable() {
        var enable = model.staticFormat.flags.contains(.sfx)
        if enable {
            if let m = model.method { enable = m.isSupportedBySFX }
        }
        if !enable { sfxBox.state = .off }
        sfxBox.isEnabled = enable
        model.sfxMode = sfxBox.state == .on && enable
    }

    /// The encryption group (`FormatChanged` :747-762 + `SetEncryptionMethod`).
    private func updateEncryptionControls(storedMethod: String) {
        let encrypt = model.staticFormat.flags.contains(.encrypt)
        encryptionGroup.isEnabled = encrypt               // EnableItem(IDG_COMPRESS_ENCRYPTION)
        for v in encryptionGroupViews { (v as? NSControl)?.isEnabled = encrypt }
        enterLabel.textColor = encrypt ? .labelColor : .disabledControlTextColor
        password2Label.textColor = encrypt ? .labelColor : .disabledControlTextColor
        let namesAllowed = model.staticFormat.flags.contains(.encryptFileNames)
        encryptNamesBox.isEnabled = namesAllowed
        encryptNamesBox.isHidden = !namesAllowed          // ShowItem_Bool (:760)

        let e = model.encryptionMethodItems(stored: storedMethod)
        encryptionMethodCombo.removeAllItems()
        for item in e.items { encryptionMethodCombo.addItem(withTitle: item) }
        encryptionMethodCombo.isEnabled = encrypt        // EnableItem(..., encrypt) on Windows
        if e.selection >= 0 { encryptionMethodCombo.selectItem(at: e.selection) }
        encryptionDefaultIndex = e.defaultIndex
        updatePasswordControl()
    }

    private var encryptionDefaultIndex = -1

    /// `UpdatePasswordControl` (:570-584): "Show Password" swaps the secure field for a plain
    /// one and hides the re-enter row.
    private func updatePasswordControl() {
        let show = showPasswordBox.state == .on
        if show {
            password1Plain.stringValue = password1Field.stringValue
        } else {
            password1Field.stringValue = password1Plain.stringValue
        }
        password1Field.isHidden = show
        password1Plain.isHidden = !show
        password2Label.isHidden = show                    // ShowItem_Bool(IDT_PASSWORD_REENTER)
        password2Field.isHidden = show
    }

    private var currentPassword: String {
        showPasswordBox.state == .on ? password1Plain.stringValue : password1Field.stringValue
    }

    /// `ShowOptionsString` (:3353-3371).
    private func updateOptionsSummary() {
        var parts: [String] = []
        if let tp = timePrecision { parts.append("tp\(tp)") }
        func boolPair(_ name: String, _ value: Bool?) {
            guard let value else { return }
            parts.append(value ? name : name + "-")
        }
        boolPair("tm", mTime)
        boolPair("tc", cTime)
        boolPair("ta", aTime)
        boolPair("-stl", setArcMTime)
        if currentFormat.supportsSymLinks, symLinks == true { parts.append("SL") }
        if currentFormat.supportsHardLinks, hardLinks == true { parts.append("HL") }
        if currentFormat.supportsAltStreams, altStreams == true { parts.append("AS") }
        if currentFormat.supportsNtSecurity, ntSecurity == true { parts.append("Sec") }
        optionsSummary.stringValue = parts.joined(separator: " ")
    }

    private func updateMemoryUsage() {
        memoryValueLabel.stringValue = model.memoryUsageText
        memoryDeValueLabel.stringValue = model.decompressionMemoryText
    }

    // MARK: - Archive name (SetArchiveName / SetArchiveName2)

    private var previousFormatIndexInList = 0
    private var previousWasSFX = false

    /// `SetArchiveName` (:1477-1517).
    private func setArchiveName(_ name: String) {
        var fileName = name
        let info = currentFormat
        if info.keepName {
            fileName = input.originalFileName
        } else if !keepNameForSelection {
            if let dot = extensionDotIndex(fileName) {
                fileName = String(fileName[fileName.startIndex..<dot])
            }
        }
        if model.sfxMode {
            fileName += ".exe"
        } else {
            var ext = info.mainExtension
            if info.isHashHandler {
                let estimated = model.estimatedMethodName
                if !estimated.isEmpty { ext = estimated.lowercased() }
            }
            fileName += "." + ext
        }
        archiveCombo.stringValue = fileName
        previousFormatIndexInList = formatIndexInList
        previousWasSFX = model.sfxMode
    }

    /// `Info.KeepName` = `!oneFile`: with several items the name is not stripped.
    private var keepNameForSelection: Bool { !input.isOneFile }

    /// `SetArchiveName2` (:1450-1475): strip the previous format's extension first.
    private func setArchiveName2(previousWasSFX: Bool) {
        var fileName = archiveCombo.stringValue
        let previous = formats[previousFormatIndexInList]
        if previous.keepName || keepNameForSelection {
            let previousExtension = previousWasSFX ? ".exe" : "." + previous.mainExtension
            if fileName.count >= previousExtension.count,
               fileName.lowercased().hasSuffix(previousExtension.lowercased()) {
                fileName.removeLast(previousExtension.count)
            }
        }
        setArchiveName(fileName)
    }

    /// `GetExtDotPos` (:772-778): the last dot after the last separator.
    private func extensionDotIndex(_ s: String) -> String.Index? {
        guard let dot = s.lastIndex(of: ".") else { return nil }
        if let slash = s.lastIndex(of: "/"), dot <= slash { return nil }
        return dot
    }

    /// `SetArcPathFields` (:830-858) / `ArcPath_WasChanged`.
    private func updateFolderLabel() {
        let typed = archiveCombo.stringValue
        if (typed as NSString).isAbsolutePath {
            let dir = (typed as NSString).deletingLastPathComponent
            directoryPrefix = dir.hasSuffix("/") ? dir : dir + "/"
            archiveCombo.stringValue = (typed as NSString).lastPathComponent
        }
        folderLabel.stringValue = directoryPrefix
    }

    /// `GetFinalPath_Smart` (:811-828): resolve the typed name against the folder prefix.
    private func finalArchivePath() -> String? {
        let name = archiveCombo.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if (name as NSString).isAbsolutePath { return (name as NSString).standardizingPath }
        var prefix = directoryPrefix
        if prefix.isEmpty { prefix = FileManager.default.currentDirectoryPath }
        return ((prefix as NSString).appendingPathComponent(name) as NSString).standardizingPath
    }

    // MARK: - Actions

    @objc private func controlChanged(_ sender: NSPopUpButton) {
        guard !isUpdatingControls else { return }
        switch sender {
        case formatCombo:
            // SaveOptionsInMem for the *previous* format, then FormatChanged + SetArchiveName2.
            saveOptionsInMemory()
            let wasSFX = model.sfxMode
            formatIndexInList = formatCombo.indexOfSelectedItem
            formatChanged(isChanged: true)
            setArchiveName2(previousWasSFX: wasSFX)
        case levelCombo:
            // ResetForLevelChange, SetMethod, SetSolidBlockSize, SetNumThreads, SetMemoryUsage.
            model.level = Int(model.levelItems { Lang.text($0, $1) }[levelCombo.indexOfSelectedItem].data)
            resetForLevelChange()
            let keep = model.selectedMethodRaw
            isUpdatingControls = true
            setMethodCombo(storedMethod: options(for: currentFormat.name).method, keepMethod: keep)
            setDependentCombos()
            checkSFXControlsEnable()
            isUpdatingControls = false
            updateMemoryUsage()
        case methodCombo:
            let items = model.methodItems
            let i = methodCombo.indexOfSelectedItem
            if i >= 0 && i < items.count {
                model.selectedMethodRaw = items[i].isAuto ? nil : Int(items[i].data)
            }
            isUpdatingControls = true
            setDependentCombos()
            checkSFXControlsEnable()
            isUpdatingControls = false
            // For hash handlers the extension follows the method.
            if currentFormat.isHashHandler { setArchiveName2(previousWasSFX: model.sfxMode) }
            updateMemoryUsage()
        case dictionaryCombo:
            let items = model.dictionaryItems(storedDictionary: nil).items
            let i = dictionaryCombo.indexOfSelectedItem
            if i >= 0 && i < items.count { model.dictionary = items[i].data }
            // The stored block size is reset unless it was Non-solid / Solid.
            var fo = options(for: currentFormat.name)
            if fo.blockLogSize != Int(CompressModel.solidLogNonSolid)
                && fo.blockLogSize != Int(CompressModel.solidLogFullSolid) {
                fo.blockLogSize = -1
                formatOptions[currentFormat.name] = fo
            }
            isUpdatingControls = true
            setSolidCombo()
            setThreadsCombo()
            isUpdatingControls = false
            updateMemoryUsage()
        case orderCombo:
            let items = model.orderItems(storedOrder: nil).items
            let i = orderCombo.indexOfSelectedItem
            if i >= 0 && i < items.count { model.order = items[i].data }
            updateMemoryUsage()
        case solidCombo:
            let items = model.solidItems(storedBlockLogSize: nil) { Lang.text($0, $1) }.items
            let i = solidCombo.indexOfSelectedItem
            if i >= 0 && i < items.count { model.blockLogSize = items[i].data }
            updateMemoryUsage()
        case threadsCombo:
            let items = model.threadItems(storedNumThreads: nil).items
            let i = threadsCombo.indexOfSelectedItem
            if i >= 0 && i < items.count { model.numThreads = items[i].data }
            updateMemoryUsage()
        case memUseCombo:
            let i = memUseCombo.indexOfSelectedItem
            if i >= 0 && i < memUseItems.count { model.memUseSpec = memUseItems[i].spec }
            isUpdatingControls = true
            setThreadsCombo()
            isUpdatingControls = false
            updateMemoryUsage()
        default:
            updateMemoryUsage()
        }
    }

    /// `CFormatOptions::ResetForLevelChange`.
    private func resetForLevelChange() {
        var fo = options(for: currentFormat.name)
        fo.blockLogSize = -1
        fo.numThreads = -1
        fo.level = -1
        fo.dictionary = -1
        fo.order = -1
        fo.method = ""
        formatOptions[currentFormat.name] = fo
    }

    @objc private func sfxToggled(_ sender: NSButton) {
        // OnButtonSFX (:781-809): swap the extension, then re-fill the method list.
        checkSFXControlsEnable()
        var fileName = archiveCombo.stringValue
        if model.sfxMode {
            if let dot = extensionDotIndex(fileName) { fileName = String(fileName[fileName.startIndex..<dot]) }
            archiveCombo.stringValue = fileName + ".exe"
        } else {
            if let dot = extensionDotIndex(fileName),
               String(fileName[dot...]).caseInsensitiveCompare(".exe") == .orderedSame {
                archiveCombo.stringValue = String(fileName[fileName.startIndex..<dot])
            }
            setArchiveName2(previousWasSFX: false)
        }
        isUpdatingControls = true
        setMethodCombo(storedMethod: options(for: currentFormat.name).method, keepMethod: model.selectedMethodRaw)
        setDependentCombos()
        isUpdatingControls = false
        updateMemoryUsage()
    }

    @objc private func showPasswordToggled(_ sender: NSButton) {
        updatePasswordControl()
    }

    @objc private func browseForArchive(_ sender: NSButton) {
        // OnButtonSetArchive (:879-1016): a save panel with one filter per listed format, the
        // "Archive:" aggregate and "All Files"; "exe" only in SFX mode (01b section 4.23).
        let panel = NSSavePanel()
        panel.title = Lang.text(4070, "Browse")                  // IDS_COMPRESS_SET_ARCHIVE_BROWSE
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: directoryPrefix, isDirectory: true)
        panel.nameFieldStringValue = archiveCombo.stringValue
        let chooser = browseFilterChooser(for: panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let filter = chooser.selected
        let path = CompressBrowseFilter.resolvedPath(url.path, filter: filter, sfx: model.sfxMode) {
            self.formats[$0].mainExtension
        }
        directoryPrefix = (path as NSString).deletingLastPathComponent + "/"
        var name = (path as NSString).lastPathComponent
        if let index = filter.formatListIndex {
            // The format was confirmed by the filter: the combo follows it (:1008-1014).
            if index != formatIndexInList {
                saveOptionsInMemory()
                formatIndexInList = index
                isUpdatingControls = true
                formatCombo.selectItem(at: index)
                isUpdatingControls = false
                formatChanged(isChanged: true)
            }
        } else if !model.sfxMode, let info = SZCodecs.format(forArchiveName: name),
                  let i = formats.firstIndex(where: { $0.index == info.index }), i != formatIndexInList {
            // The aggregate / All Files filters: a typed extension that names another format
            // switches the combo (macOS addition, the Windows dialog keeps the format).
            saveOptionsInMemory()
            formatIndexInList = i
            isUpdatingControls = true
            formatCombo.selectItem(at: i)
            isUpdatingControls = false
            formatChanged(isChanged: true)
        } else if (name as NSString).pathExtension.isEmpty {
            name += "." + (model.sfxMode ? "exe" : currentFormat.mainExtension)
        }
        archiveCombo.stringValue = name
        folderLabel.stringValue = directoryPrefix
        // The name now carries this format's extension: the next format switch strips that one.
        previousFormatIndexInList = formatIndexInList
        previousWasSFX = model.sfxMode
    }

    /// The filter list of OnButtonSetArchive for the current format list and SFX state, installed
    /// on `panel` as an accessory pop-up. Internal so a test can inspect it without running the panel.
    func browseFilterChooser(for panel: NSSavePanel) -> CompressBrowseFilterChooser {
        let list = CompressBrowseFilter.filters(
            formats: formats.map { ($0.name, $0.extensions, $0.mainExtension) },
            selectedFormat: formatIndexInList, sfx: model.sfxMode,
            archiveLabel: Lang.text(4001, "Archive:"),               // IDT_COMPRESS_ARCHIVE
            allFilesLabel: Lang.text(4071, "All Files"))             // IDS_OPEN_TYPE_ALL_FILES
        return CompressBrowseFilterChooser(filters: list.filters, initial: list.initial, panel: panel)
    }

    @objc private func showOptionsSheet(_ sender: NSButton) {
        var state = CompressOptionsSheet.State(
            formatName: currentFormat.name,
            formatTimeFlags: currentFormat.timeFlags,
            formatFlags: currentFormat.flags,
            supportsMTime: currentFormat.supportsMTime,
            supportsCTime: currentFormat.supportsCTime,
            supportsATime: currentFormat.supportsATime,
            supportsSymLinks: currentFormat.supportsSymLinks,
            supportsHardLinks: currentFormat.supportsHardLinks,
            supportsAltStreams: currentFormat.supportsAltStreams,
            supportsNtSecurity: currentFormat.supportsNtSecurity,
            isTar: model.isTar,
            isZip: model.isZip,
            isGZip: model.isGZip,
            isKeepName: currentFormat.keepName,
            tarMethodName: model.isTar ? model.estimatedMethodName : "",
            timePrecision: timePrecision,
            mTime: mTime, cTime: cTime, aTime: aTime, setArcMTime: setArcMTime,
            preserveATime: preserveATime, symLinks: symLinks, hardLinks: hardLinks,
            altStreams: altStreams, ntSecurity: ntSecurity)
        guard CompressOptionsSheet.run(&state, parent: window) else { return }
        timePrecision = state.timePrecision
        mTime = state.mTime
        cTime = state.cTime
        aTime = state.aTime
        setArcMTime = state.setArcMTime
        preserveATime = state.preserveATime
        symLinks = state.symLinks
        hardLinks = state.hardLinks
        altStreams = state.altStreams
        ntSecurity = state.ntSecurity
        var fo = options(for: currentFormat.name)
        fo.timePrec = timePrecision ?? -1
        fo.mTime = mTime
        fo.cTime = cTime
        fo.aTime = aTime
        fo.setArcMTime = setArcMTime
        formatOptions[currentFormat.name] = fo
        updateOptionsSummary()
    }

    @objc private func helpPressed(_ sender: NSButton) {
        // IDHELP: kHelpTopic = "fm/plugins/7-zip/add.htm" (CompressDialog.cpp:1254-1259), bundled help
        Help.show(topic: Help.add)
    }

    @objc private func cancelPressed(_ sender: NSButton) {
        result = nil
        NSApp.stopModal()
    }

    // MARK: - OnOK (CompressDialog.cpp:1066-1252)

    @objc private func okPressed(_ sender: NSButton) {
        let password = currentPassword

        // 1. zip: ASCII only, and <= 99 characters with AES.
        if model.isZip {
            if password.unicodeScalars.contains(where: { $0.value > 127 }) {
                showError(Lang.text(3805, "Use only English letters, numbers and special characters "
                                          + "(!, #, $, ...) for password."))
                return
            }
            let method = encryptionMethodSpec()
            if method.lowercased().hasPrefix("aes") && password.count > 99 {
                showError(Lang.text(3806, "Password is too long"))
                return
            }
        }
        // 2. The two fields must match unless the password is shown.
        if showPasswordBox.state != .on, password2Field.stringValue != password {
            showError(Lang.text(3804, "Passwords do not match"))
            return
        }
        // 3. The estimate must fit the memory limit.
        if let usage = model.memoryEstimate.compressed {
            let limit = model.memUseLimitBytes
            if usage > limit {
                let blocked = Lang.text(7810, "The operation was blocked by 7-Zip.")
                let requires = Lang.text(7811, "The operation can require big amount of RAM (memory):")
                showError("\(blocked)\n\(requires)\n"
                          + "\(CompressModel.memUsageText(usage))\n"
                          + "\(CompressModel.memUsageText(limit))\n"
                          + "\(CompressModel.memUsageText(model.ramSize))")
                return
            }
        }
        // 4. SaveOptionsInMem + GetFinalPath_Smart.
        saveOptionsInMemory()
        guard let archivePath = finalArchivePath() else {
            showError("Incorrect archive path")
            return
        }
        // 6. Volumes.
        let volumeText = volumeCombo.stringValue.trimmingCharacters(in: .whitespaces)
        var volumeSizes: [UInt64] = []
        if !volumeText.isEmpty {
            guard let parsed = CompressVolumes.parse(volumeText) else {
                showError(Lang.text(7307, "Incorrect volume size"))
                return
            }
            volumeSizes = parsed
            if let last = volumeSizes.last, last < (100 << 10) {
                let template = Lang.text(7308, "Specified volume size: {0} bytes.\n"
                                               + "Are you sure you want to split archive into such volumes?")
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "7-Zip"
                alert.informativeText = Lang.format(template, "\(last)")
                alert.addButton(withTitle: Lang.text(406, "Yes"))      // MY_IDYES
                alert.addButton(withTitle: Lang.text(407, "No"))       // MY_IDNO
                alert.addButton(withTitle: Lang.text(402, "Cancel"))
                if alert.runModal() != .alertFirstButtonReturn { return }
            }
        }

        // 5. Fill the result.
        var r = CompressDialogResult()
        r.archivePath = archivePath
        r.formatIndex = currentFormat.index
        r.formatName = currentFormat.name
        r.level = model.level
        r.method = model.methodSpec
        r.dictionary = model.dictionarySpec
        r.order = model.orderSpec
        r.orderMode = model.orderMode
        r.numThreads = model.numThreadsSpec
        r.memUse = CompressMemUse(spec: model.memUseSpec)
        r.solidBlockSize = model.solidBlockSizeBytes
        r.encryptionMethod = encryptionMethodSpec()
        r.encryptHeadersIsAllowed = model.staticFormat.flags.contains(.encryptFileNames)
        r.encryptHeaders = encryptNamesBox.state == .on
        r.parameters = parametersField.stringValue.trimmingCharacters(in: .whitespaces)
        r.updateMode = SZUpdateMode(rawValue: updateModeCombo.indexOfSelectedItem) ?? .add
        r.pathMode = SZCompressPathMode(rawValue: pathModeCombo.indexOfSelectedItem) ?? .relative
        r.sfxMode = model.sfxMode
        r.sfxModulePath = input.sfxModulePath
        r.openShareForWrite = sharedBox.state == .on
        r.deleteAfterCompressing = deleteBox.state == .on
        r.excludeMacResourceForks = excludeMacBox.state == .on
        r.password = password.isEmpty ? nil : password
        r.volumeSizes = volumeSizes
        r.timePrecision = timePrecision
        r.mTime = mTime
        r.cTime = cTime
        r.aTime = aTime
        r.setArcMTime = setArcMTime
        // Unsupported link/stream options are cleared (`SET_FINAL_BOOL_PAIRS`).
        r.preserveATime = preserveATime
        r.symLinks = currentFormat.supportsSymLinks ? symLinks : nil
        r.hardLinks = currentFormat.supportsHardLinks ? hardLinks : nil
        r.altStreams = currentFormat.supportsAltStreams ? altStreams : nil
        r.ntSecurity = currentFormat.supportsNtSecurity ? ntSecurity : nil

        // 7. Settings.
        Settings.archiverType = currentFormat.name
        Settings.compressShowPassword = showPasswordBox.state == .on
        Settings.compressExcludeMacResourceForks = excludeMacBox.state == .on
        Settings.compressEncryptHeaders = r.encryptHeaders
        Settings.compressSymLinks = symLinks
        Settings.compressHardLinks = hardLinks
        Settings.compressAltStreams = altStreams
        Settings.compressNtSecurity = ntSecurity
        Settings.compressPreserveATime = preserveATime
        var history = [archivePath]
        for old in Settings.archiveHistory where history.count < 20 {
            if !history.contains(old) { history.append(old) }
        }
        Settings.archiveHistory = history
        for (_, fo) in formatOptions { Settings.setFormatOptions(fo) }
        Settings.synchronize()

        result = r
        NSApp.stopModal()
    }

    private func encryptionMethodSpec() -> String {
        let items = (0..<encryptionMethodCombo.numberOfItems).map { encryptionMethodCombo.item(at: $0)?.title ?? "" }
        return model.encryptionMethodSpec(selectedIndex: encryptionMethodCombo.indexOfSelectedItem,
                                         items: items, defaultIndex: encryptionDefaultIndex)
    }

    /// `SaveOptionsInMem` (:3256-3318): store the current combo values into the format's options.
    private func saveOptionsInMemory() {
        var fo = options(for: currentFormat.name)
        fo.options = parametersField.stringValue.trimmingCharacters(in: .whitespaces)
        fo.level = model.level
        if let dict = model.dictionarySpec {
            // A value that does not fit 32 bits is stored as the -2 "big value" marker.
            fo.dictionary = dict > UInt64(UInt32.max) ? -2 : Int(Int32(bitPattern: UInt32(truncatingIfNeeded: dict)))
        } else {
            fo.dictionary = -1
        }
        fo.order = Int(model.orderSpec ?? -1)
        fo.method = model.methodSpec
        fo.encryptionMethod = encryptionMethodSpec()
        fo.numThreads = Int(model.numThreadsSpec ?? -1)
        fo.blockLogSize = Int(model.blockLogSizeSpec ?? -1)
        fo.memUse = model.memUseSpec
        fo.timePrec = timePrecision ?? -1
        fo.mTime = mTime
        fo.cTime = cTime
        fo.aTime = aTime
        fo.setArcMTime = setArcMTime
        formatOptions[currentFormat.name] = fo
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "7-Zip"
        alert.informativeText = text
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: NSComboBoxDelegate / NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSComboBox) === archiveCombo else { return }
        updateFolderLabel()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        guard (notification.object as? NSComboBox) === archiveCombo else { return }
        // k_Message_ArcChanged: the folder part of a history entry moves to the folder line.
        DispatchQueue.main.async { [weak self] in self?.updateFolderLabel() }
    }
}
