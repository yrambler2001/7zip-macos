// Settings.swift -- the single typed Swift facade over SZSettings (CFPreferences, domain
// com.yrambler2001.7zip). Every key is the Windows registry value name with the registry key
// path as a dotted prefix, exactly as the engine-side accessors write them
// (Mac/Core/Platform/ZipRegistryMac.cpp, 01b-fm-dialogs-settings.md sections 5.1-5.7), so the
// C++ layer (NExtract/NCompression/NWorkDir/CContextMenuInfo) and the Swift UI never disagree.
//
// Everything goes through SZSettings rather than UserDefaults.standard: SZSettings names the
// domain explicitly, so the same code works in the app, in a unit-test bundle and in an
// extension. The key -> property table is in Mac/docs/api/options.md.
//
// CBoolPair (tri-state) keys are `Bool?`: nil means the value is absent from the store
// (CBoolPair::Def == false, "not forced" / "use the handler default"). Each of those has a
// companion `...Value` property giving the effective value the engine uses when it is absent
// (Key_Get_BoolPair vs Key_Get_BoolPair_true, ZipRegistryMac.cpp:23-33).
//
// UInt32 keys that carry sentinels keep them: -1 = auto / not set (the engine deletes the value
// instead of writing -1, Key_Set_UInt32), Dictionary -2 = ">= 4 GB", BlockSize is a log2.

import Foundation
import SevenZipKit

enum Settings {

    // MARK: - Keys (01b section 5; the SZSettingsKey* constants where the bridge declares one)

    enum Key {
        // HKCU\Software\7-Zip (5.1)
        static let lang = SZSettingsKeyLang                                // "Lang"
        // HKCU\Software\7-Zip\FM (5.2)
        static let viewer = SZSettingsKeyFMViewer                          // "FM.Viewer"
        static let editor = SZSettingsKeyFMEditor                          // "FM.Editor"
        static let diff = SZSettingsKeyFMDiff                              // "FM.Diff"
        static let verCtrl = "FM.7vc"
        static let showDots = SZSettingsKeyFMShowDots
        static let showRealFileIcons = SZSettingsKeyFMShowRealFileIcons
        static let fullRow = SZSettingsKeyFMFullRow
        static let showGrid = SZSettingsKeyFMShowGrid
        static let singleClick = SZSettingsKeyFMSingleClick
        static let alternativeSelection = SZSettingsKeyFMAlternativeSelection
        static let showSystemMenu = SZSettingsKeyFMShowSystemMenu
        static let position = SZSettingsKeyFMPosition
        static let maximized = SZSettingsKeyFMMaximized
        static let numPanels = SZSettingsKeyFMNumPanels
        static let currentPanel = SZSettingsKeyFMCurrentPanel
        static let splitterPos = SZSettingsKeyFMSplitterPos
        static let toolbars = SZSettingsKeyFMToolbars
        static let folderHistory = SZSettingsKeyFMFolderHistory
        static let folderShortcuts = SZSettingsKeyFMFolderShortcuts
        static let copyHistory = SZSettingsKeyFMCopyHistory
        static let autoRefresh = "FM.AutoRefresh"                          // not persisted on Windows
        static let timestampShowUTC = "FM.TimestampShowUTC"                // g_Timestamp_Show_UTC
        static let timestampLevel = "FM.TimestampLevel"
        static let columnsPrefix = "FM.Columns."                           // 5.3, + <FolderTypeID>
        static func listMode(_ i: Int) -> String { i == 0 ? SZSettingsKeyFMListMode0 : SZSettingsKeyFMListMode1 }
        static func panelPath(_ i: Int) -> String { i == 0 ? SZSettingsKeyFMPanelPath0 : SZSettingsKeyFMPanelPath1 }
        static func flatViewArc(_ i: Int) -> String { i == 0 ? SZSettingsKeyFMFlatViewArc0 : SZSettingsKeyFMFlatViewArc1 }

        // HKCU\Software\7-Zip\Extraction (5.4)
        static let extractMode = "Extraction.ExtractMode"
        static let overwriteMode = "Extraction.OverwriteMode"
        static let extractShowPassword = "Extraction.ShowPassword"
        static let extractSplitDest = "Extraction.SplitDest"
        static let extractElimDup = "Extraction.ElimDup"
        static let extractSecurity = "Extraction.Security"
        static let extractPathHistory = "Extraction.PathHistory"
        static let extractMemLimit = "Extraction.MemLimit"

        // HKCU\Software\7-Zip\Compression (5.4)
        static let arcHistory = "Compression.ArcHistory"
        static let archiver = "Compression.Archiver"
        static let level = "Compression.Level"
        static let compressShowPassword = "Compression.ShowPassword"
        static let encryptHeaders = "Compression.EncryptHeaders"
        static let compressSecurity = "Compression.Security"
        static let compressAltStreams = "Compression.AltStreams"
        static let compressHardLinks = "Compression.HardLinks"
        static let compressSymLinks = "Compression.SymLinks"
        static let compressPreserveATime = "Compression.PreserveATime"
        /// macOS only (dlgfeel): the Add to Archive dialog's "Exclude Mac resource forks".
        static let compressExcludeMacResourceForks = "Compression.ExcludeMacResourceForks"
        static let formatOptionsPrefix = "Compression.Options."            // + <FormatID>.<name>

        // HKCU\Software\7-Zip\Options (5.5)
        static let workDirType = SZSettingsKeyWorkDirType                  // "Options.WorkDirType"
        static let workDirPath = SZSettingsKeyWorkDirPath
        static let tempRemovableOnly = SZSettingsKeyTempRemovableOnly
        static let cascadedMenu = "Options.CascadedMenu"
        static let menuIcons = "Options.MenuIcons"
        static let elimDupExtract = "Options.ElimDupExtract"
        static let writeZoneIdExtract = "Options.WriteZoneIdExtract"
        static let contextMenu = "Options.ContextMenu"
    }

    // MARK: - Change notification

    /// Which Options page / consumer group a key belongs to.
    enum Group: String {
        case language       // Lang
        case editor         // FM.Viewer / Editor / Diff / 7vc          (Options > Editor)
        case fm             // the seven CFmSettings booleans            (Options > Settings)
        case view           // window / panel / history / column state
        case extraction     // Extraction.*
        case compression    // Compression.*
        case workDir        // Options.WorkDir* + TempRemovableOnly      (Options > Folders)
        case contextMenu    // the other Options.*                      (Options > 7-Zip)

        var notificationName: Notification.Name { Notification.Name("SZSettings.\(rawValue)DidChange") }
    }

    /// Posted for every write, with `userInfo[Settings.keyUserInfoKey]` = the settings key and
    /// `userInfo[Settings.groupUserInfoKey]` = the `Group`. The group's own
    /// `Group.notificationName` is posted as well, so an observer can listen to one group only.
    static let didChangeNotification = Notification.Name("SZSettingsDidChange")
    static let keyUserInfoKey = "key"
    static let groupUserInfoKey = "group"

    /// Group of a settings key (prefix rules, 01b section 5).
    static func group(forKey key: String) -> Group {
        switch key {
        case Key.lang: return .language
        case Key.viewer, Key.editor, Key.diff, Key.verCtrl: return .editor
        case Key.showDots, Key.showRealFileIcons, Key.fullRow, Key.showGrid,
             Key.singleClick, Key.alternativeSelection, Key.showSystemMenu: return .fm
        case Key.workDirType, Key.workDirPath, Key.tempRemovableOnly: return .workDir
        default:
            if key.hasPrefix("Extraction.") { return .extraction }
            if key.hasPrefix("Compression.") { return .compression }
            if key.hasPrefix("Options.") { return .contextMenu }
            return .view
        }
    }

    private static func notify(_ key: String) {
        let g = group(forKey: key)
        let info: [AnyHashable: Any] = [keyUserInfoKey: key, groupUserInfoKey: g]
        let center = NotificationCenter.default
        center.post(name: didChangeNotification, object: nil, userInfo: info)
        center.post(name: g.notificationName, object: nil, userInfo: info)
    }

    // MARK: - Primitive access (every write goes through one of these)

    static func string(_ key: String) -> String? { SZSettings.string(forKey: key) }

    static func setString(_ value: String?, _ key: String) {
        SZSettings.setString(value, forKey: key)
        notify(key)
    }

    static func bool(_ key: String, default defaultValue: Bool = false) -> Bool {
        SZSettings.bool(forKey: key, defaultValue: defaultValue)
    }

    static func setBool(_ value: Bool, _ key: String) {
        SZSettings.setBool(value, forKey: key)
        notify(key)
    }

    /// CBoolPair: nil = absent (Def == false).
    static func boolPair(_ key: String) -> Bool? { SZSettings.boolPair(forKey: key)?.boolValue }

    static func setBoolPair(_ value: Bool?, _ key: String) {
        SZSettings.setBoolPair(value.map { NSNumber(value: $0) }, forKey: key)
        notify(key)
    }

    static func integer(_ key: String, default defaultValue: Int = 0) -> Int {
        SZSettings.integer(forKey: key, defaultValue: defaultValue)
    }

    static func setInteger(_ value: Int, _ key: String) {
        SZSettings.setInteger(value, forKey: key)
        notify(key)
    }

    /// Int? where absent means "not set" (no sentinel written).
    static func optionalInteger(_ key: String) -> Int? {
        SZSettings.hasKey(key) ? SZSettings.integer(forKey: key, defaultValue: 0) : nil
    }

    static func setOptionalInteger(_ value: Int?, _ key: String) {
        if let value { SZSettings.setInteger(value, forKey: key) } else { SZSettings.removeKey(key) }
        notify(key)
    }

    /// Key_Set_UInt32 / Key_Get_UInt32 (ZipRegistryMac.cpp:48-60): -1 is not stored, the key is
    /// removed instead, and a missing key reads back as -1.
    static func sentinelInteger(_ key: String) -> Int {
        SZSettings.integer(forKey: key, defaultValue: -1)
    }

    static func setSentinelInteger(_ value: Int, _ key: String) {
        if value == -1 { SZSettings.removeKey(key) } else { SZSettings.setInteger(value, forKey: key) }
        notify(key)
    }

    static func stringArray(_ key: String) -> [String] { SZSettings.stringArray(forKey: key) ?? [] }

    static func setStringArray(_ value: [String]?, _ key: String) {
        SZSettings.setStringArray(value, forKey: key)
        notify(key)
    }

    static func hasKey(_ key: String) -> Bool { SZSettings.hasKey(key) }

    static func removeKey(_ key: String) {
        SZSettings.removeKey(key)
        notify(key)
    }

    static func synchronize() { SZSettings.synchronize() }

    // MARK: - Root (01b 5.1)

    /// `Lang`: "" / absent = system language, "-" = built-in English, else a Lang/*.txt stem.
    static var language: String {
        get { string(Key.lang) ?? "" }
        set { setString(newValue, Key.lang) }
    }

    /// `LargePages` is not ported: macOS has no SeLockMemoryPrivilege equivalent
    /// (01 section 9 #16, PROGRESS 7.6). The Settings page shows the checkbox disabled.
    static let largePagesSupported = false

    // MARK: - Editor page (01b 4.7, 5.2)

    /// `FM.Viewer`: empty = Quick Look. May be an .app bundle path, an executable, or a command
    /// line with arguments (SplitCmdLineSmart).
    static var viewerPath: String {
        get { string(Key.viewer) ?? "" }
        set { setString(newValue.isEmpty ? nil : newValue, Key.viewer) }
    }

    /// `FM.Editor`: empty = TextEdit (the notepad.exe fallback).
    static var editorPath: String {
        get { string(Key.editor) ?? "" }
        set { setString(newValue.isEmpty ? nil : newValue, Key.editor) }
    }

    /// `FM.Diff`: empty hides the Diff command.
    static var diffPath: String {
        get { string(Key.diff) ?? "" }
        set { setString(newValue.isEmpty ? nil : newValue, Key.diff) }
    }

    /// `FM.7vc`: read-only on Windows too (no UI); empty hides the Ver* items.
    static var verCtrlPath: String { string(Key.verCtrl) ?? "" }

    // MARK: - Settings page: CFmSettings (01b 4.19, 5.2; all default false)

    static var showDots: Bool {
        get { bool(Key.showDots) }
        set { setBool(newValue, Key.showDots) }
    }

    static var showRealFileIcons: Bool {
        get { bool(Key.showRealFileIcons) }
        set { setBool(newValue, Key.showRealFileIcons) }
    }

    static var fullRow: Bool {
        get { bool(Key.fullRow) }
        set { setBool(newValue, Key.fullRow) }
    }

    static var showGrid: Bool {
        get { bool(Key.showGrid) }
        set { setBool(newValue, Key.showGrid) }
    }

    static var singleClick: Bool {
        get { bool(Key.singleClick) }
        set { setBool(newValue, Key.singleClick) }
    }

    static var alternativeSelection: Bool {
        get { bool(Key.alternativeSelection) }
        set { setBool(newValue, Key.alternativeSelection) }
    }

    static var showSystemMenu: Bool {
        get { bool(Key.showSystemMenu) }
        set { setBool(newValue, Key.showSystemMenu) }
    }

    // MARK: - Window and panel state (01b 5.2)

    /// NSStringFromRect of the last window frame; nil = system placement.
    static var windowFrame: String? {
        get { string(Key.position) }
        set { setString(newValue, Key.position) }
    }

    static var maximized: Bool {
        get { bool(Key.maximized) }
        set { setBool(newValue, Key.maximized) }
    }

    /// 1 or 2 (kNumDefaultPanels = 1).
    static var numPanels: Int {
        get { min(max(integer(Key.numPanels, default: 1), 1), 2) }
        set { setInteger(newValue, Key.numPanels) }
    }

    static var currentPanel: Int {
        get { min(max(integer(Key.currentPanel), 0), 1) }
        set { setInteger(newValue, Key.currentPanel) }
    }

    /// Splitter position as a ratio of the window width (7zFM stores it over 1 << 16).
    static var splitterPos: Double {
        get {
            let v = SZSettings.double(forKey: Key.splitterPos, defaultValue: 0)
            return v > 0 && v < 1 ? v : 0.5
        }
        set {
            SZSettings.setDouble(newValue, forKey: Key.splitterPos)
            notify(Key.splitterPos)
        }
    }

    /// Toolbars mask: bit0 labels, bit1 large buttons, bit2 standard toolbar, bit3 archive
    /// toolbar; bit31 = "never saved" (kDefaultToolbarMask = bit31 | 8 | 4 | 1).
    static var toolbarsMask: UInt32 {
        get {
            guard hasKey(Key.toolbars) else { return 0x8000_0000 | 8 | 4 | 1 }
            return UInt32(truncatingIfNeeded: integer(Key.toolbars))
        }
        set { setInteger(Int(Int32(truncatingIfNeeded: newValue)), Key.toolbars) }
    }

    static func panelPath(_ index: Int) -> String? { string(Key.panelPath(index)) }

    static func setPanelPath(_ path: String?, _ index: Int) { setString(path, Key.panelPath(index)) }

    /// 0 large icons, 1 small icons, 2 list, 3 details (default).
    static func listMode(_ index: Int) -> Int { integer(Key.listMode(index), default: 3) }

    static func setListMode(_ mode: Int, _ index: Int) { setInteger(mode, Key.listMode(index)) }

    static func flatView(_ index: Int) -> Bool { bool(Key.flatViewArc(index)) }

    static func setFlatView(_ flat: Bool, _ index: Int) { setBool(flat, Key.flatViewArc(index)) }

    /// Favorites: exactly 10 slots (FolderShortcuts); an empty string means "unset".
    static var folderShortcuts: [String] {
        get {
            var list = stringArray(Key.folderShortcuts)
            while list.count < 10 { list.append("") }
            return Array(list.prefix(10))
        }
        set { setStringArray(Array(newValue.prefix(10)), Key.folderShortcuts) }
    }

    /// Folders History (max 100, most recent first).
    static var folderHistory: [String] {
        get { stringArray(Key.folderHistory) }
        set { setStringArray(Array(newValue.prefix(100)), Key.folderHistory) }
    }

    static func addToFolderHistory(_ path: String) {
        guard !path.isEmpty else { return }
        var list = folderHistory.filter { $0 != path }
        list.insert(path, at: 0)
        folderHistory = list
    }

    /// Copy dialog history (max 20, newest first, AddUniqueStringToHeadOfList).
    static var copyHistory: [String] {
        get { stringArray(Key.copyHistory) }
        set { setStringArray(Array(newValue.prefix(20)), Key.copyHistory) }
    }

    static func addToCopyHistory(_ path: String) {
        guard !path.isEmpty else { return }
        var list = copyHistory.filter { $0 != path }
        list.insert(path, at: 0)
        copyHistory = list
    }

    static var autoRefresh: Bool {
        get { bool(Key.autoRefresh, default: true) }
        set { setBool(newValue, Key.autoRefresh) }
    }

    static var timestampShowUTC: Bool {
        get { bool(Key.timestampShowUTC) }
        set {
            setBool(newValue, Key.timestampShowUTC)
            // The engine's g_Timestamp_Show_UTC follows the setting, so the list, the status bar
            // and the dialogs never disagree (datecols: a test that restored only the setting left
            // the global on, and every later list printed "...Z").
            SZFolder.timestampShowUTC = newValue
        }
    }

    static var timestampLevel: Int {
        get { integer(Key.timestampLevel, default: Int(SZTimestampLevel.min.rawValue)) }
        set { setInteger(newValue, Key.timestampLevel) }
    }

    // MARK: - Column layout per folder type (01b 5.3)

    /// CListViewInfo. Windows stores a version-1 REG_BINARY blob per folder type ID; this port
    /// keeps the same fields in one JSON string under `FM.Columns.<FolderTypeID>` because
    /// CFPreferences has no binary-blob idiom (shape documented in Mac/docs/api/options.md).
    struct ColumnLayout: Codable, Equatable {
        struct Column: Codable, Equatable {
            var propID: Int
            var visible: Bool
            var width: Int
        }
        var sortID: Int
        var ascending: Bool
        var columns: [Column]
    }

    static func columnLayout(forFolderType typeID: String) -> ColumnLayout? {
        guard let json = string(Key.columnsPrefix + typeID), let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ColumnLayout.self, from: data)
    }

    static func setColumnLayout(_ layout: ColumnLayout?, forFolderType typeID: String) {
        let key = Key.columnsPrefix + typeID
        guard let layout, let data = try? JSONEncoder().encode(layout) else {
            setString(nil, key)
            return
        }
        setString(String(decoding: data, as: UTF8.self), key)
    }

    // MARK: - Extraction (01b 5.4; NExtract::CInfo)

    /// `Extraction.ExtractMode` (NPathMode); nil = not forced (PathMode_Force == false).
    static var extractPathMode: Int? {
        get { optionalInteger(Key.extractMode) }
        set { setOptionalInteger(newValue, Key.extractMode) }
    }

    /// Effective path mode: kCurPaths (1) when not forced (ZipRegistryMac.cpp Load).
    static var extractPathModeValue: Int { extractPathMode ?? Int(SZExtractPathMode.curPaths.rawValue) }

    /// `Extraction.OverwriteMode` (NOverwriteMode); nil = not forced.
    static var extractOverwriteMode: Int? {
        get { optionalInteger(Key.overwriteMode) }
        set { setOptionalInteger(newValue, Key.overwriteMode) }
    }

    /// Effective overwrite mode: kAsk (0) when not forced.
    static var extractOverwriteModeValue: Int { extractOverwriteMode ?? Int(SZOverwriteMode.ask.rawValue) }

    /// `Extraction.ShowPassword` (bool pair, default false).
    static var extractShowPassword: Bool? {
        get { boolPair(Key.extractShowPassword) }
        set { setBoolPair(newValue, Key.extractShowPassword) }
    }

    static var extractShowPasswordValue: Bool { extractShowPassword ?? false }

    /// `Extraction.SplitDest` (bool pair, **default true**: Key_Get_BoolPair_true).
    static var extractSplitDest: Bool? {
        get { boolPair(Key.extractSplitDest) }
        set { setBoolPair(newValue, Key.extractSplitDest) }
    }

    static var extractSplitDestValue: Bool { extractSplitDest ?? true }

    /// `Extraction.ElimDup` (bool pair, Key_Get_BoolPair: absent = false). With no caller opinion
    /// either, GetBoolsVal returns the caller's Val, which is false too, so the Extract dialog
    /// opened from the toolbar starts unchecked -- as 7zG 25.01 does (wincompare.md).
    static var extractElimDup: Bool? {
        get { boolPair(Key.extractElimDup) }
        set { setBoolPair(newValue, Key.extractElimDup) }
    }

    static var extractElimDupValue: Bool { extractElimDup ?? false }

    /// `Extraction.Security` (bool pair). Kept for compatibility only: NT security is hidden on
    /// macOS (01 section 9 #7).
    static var extractNtSecurity: Bool? {
        get { boolPair(Key.extractSecurity) }
        set { setBoolPair(newValue, Key.extractSecurity) }
    }

    /// `Extraction.PathHistory` (max 16, newest first).
    static var extractPathHistory: [String] {
        get { stringArray(Key.extractPathHistory) }
        set { setStringArray(Array(newValue.prefix(16)), Key.extractPathHistory) }
    }

    static func addToExtractPathHistory(_ path: String) {
        guard !path.isEmpty else { return }
        var list = extractPathHistory.filter { $0 != path }
        list.insert(path, at: 0)
        extractPathHistory = list
    }

    /// `Extraction.MemLimit` in GB; -1 (absent) = no limit (Read_LimitGB / Save_LimitGB).
    static var extractMemLimitGB: Int {
        get { sentinelInteger(Key.extractMemLimit) }
        set { setSentinelInteger(newValue, Key.extractMemLimit) }
    }

    /// The Settings page checkbox state: a limit is set when the value is neither -1 nor 0.
    static var extractMemLimitEnabled: Bool {
        let v = extractMemLimitGB
        return v > 0 && v != -1
    }

    // MARK: - Compression (01b 5.4; NCompression::CInfo)

    /// `Compression.ArcHistory` (max 20).
    static var archiveHistory: [String] {
        get { stringArray(Key.arcHistory) }
        set { setStringArray(Array(newValue.prefix(20)), Key.arcHistory) }
    }

    /// `Compression.Archiver`: last archive format name (default "7z").
    static var archiverType: String {
        get {
            let s = string(Key.archiver) ?? ""
            return s.isEmpty ? "7z" : s
        }
        set { setString(newValue, Key.archiver) }
    }

    /// `Compression.Level` (default 5). The Compress dialog reads the per-format level.
    static var compressionLevel: Int {
        get { integer(Key.level, default: 5) }
        set { setInteger(newValue, Key.level) }
    }

    static var compressShowPassword: Bool {
        get { bool(Key.compressShowPassword) }
        set { setBool(newValue, Key.compressShowPassword) }
    }

    /// `Compression.ExcludeMacResourceForks` (bool, default false): the Add to Archive dialog's
    /// macOS checkbox, remembered like Compression.ShowPassword.
    static var compressExcludeMacResourceForks: Bool {
        get { bool(Key.compressExcludeMacResourceForks) }
        set { setBool(newValue, Key.compressExcludeMacResourceForks) }
    }

    static var compressEncryptHeaders: Bool {
        get { bool(Key.encryptHeaders) }
        set { setBool(newValue, Key.encryptHeaders) }
    }

    /// `Compression.Security` (bool pair). Compatibility only on macOS (01 section 9 #7).
    static var compressNtSecurity: Bool? {
        get { boolPair(Key.compressSecurity) }
        set { setBoolPair(newValue, Key.compressSecurity) }
    }

    /// `Compression.AltStreams` (bool pair). Compatibility only (01 section 9 #6).
    static var compressAltStreams: Bool? {
        get { boolPair(Key.compressAltStreams) }
        set { setBoolPair(newValue, Key.compressAltStreams) }
    }

    static var compressHardLinks: Bool? {
        get { boolPair(Key.compressHardLinks) }
        set { setBoolPair(newValue, Key.compressHardLinks) }
    }

    static var compressSymLinks: Bool? {
        get { boolPair(Key.compressSymLinks) }
        set { setBoolPair(newValue, Key.compressSymLinks) }
    }

    static var compressPreserveATime: Bool? {
        get { boolPair(Key.compressPreserveATime) }
        set { setBoolPair(newValue, Key.compressPreserveATime) }
    }

    // MARK: - Per-format compression options (01b 5.4; NCompression::CFormatOptions)

    /// `Compression.Options.<FormatID>.Dictionary`: bytes, with the two sentinels the Compress
    /// dialog uses (CompressDialog.cpp:3256-3290).
    enum DictionarySize: Equatable {
        case auto                 // -1
        case atLeast4GB           // -2
        case bytes(UInt32)

        init(raw: Int) {
            switch raw {
            case -1: self = .auto
            case -2: self = .atLeast4GB
            default: self = .bytes(UInt32(truncatingIfNeeded: raw))
            }
        }

        var raw: Int {
            switch self {
            case .auto: return -1
            case .atLeast4GB: return -2
            case .bytes(let b): return Int(Int32(truncatingIfNeeded: b))
            }
        }
    }

    /// `…\BlockSize` is the **log2** of the solid block size (CFormatOptions::BlockLogSize).
    enum BlockLogSize: Equatable {
        case auto                 // -1
        case nonSolid             // 0
        case solid                // 64
        case log2(Int)            // 1..63

        init(raw: Int) {
            switch raw {
            case -1: self = .auto
            case 0: self = .nonSolid
            case 64: self = .solid
            default: self = .log2(raw)
            }
        }

        var raw: Int {
            switch self {
            case .auto: return -1
            case .nonSolid: return 0
            case .solid: return 64
            case .log2(let n): return n
            }
        }

        /// Block size in bytes, or nil for auto / non-solid / fully solid.
        var bytes: UInt64? {
            if case .log2(let n) = self, (1...63).contains(n) { return UInt64(1) << UInt64(n) }
            return nil
        }
    }

    /// One `Compression.Options.<FormatID>.*` group. Integer fields keep -1 = "not set"; the
    /// engine removes such keys instead of writing -1 (Key_Set_UInt32).
    struct FormatOptions: Equatable {
        var formatID: String
        var method = ""                  // Method       (e.g. "LZMA2"; "" = auto)
        var options = ""                 // Options      (the "Parameters" text)
        var encryptionMethod = ""        // EncryptionMethod ("AES256" for zip)
        var memUse = ""                  // MemUse64     ("NN%", "<N>M", "<N>G")
        var level = -1                   // Level
        var dictionary = -1              // Dictionary   (-1 auto, -2 >= 4 GB, else bytes)
        var order = -1                   // Order        (word size / PPMd order)
        var blockLogSize = -1            // BlockSize    (log2; 0 non-solid, 64 solid, -1 auto)
        var numThreads = -1              // NumThreads
        var timePrec = -1                // TimePrec
        var mTime: Bool?                 // MTime        (bool pair)
        var aTime: Bool?                 // ATime
        var cTime: Bool?                 // CTime
        var setArcMTime: Bool?           // SetArcMTime

        init(formatID: String) { self.formatID = formatID }

        var dictionarySize: DictionarySize {
            get { DictionarySize(raw: dictionary) }
            set { dictionary = newValue.raw }
        }

        var blockSize: BlockLogSize {
            get { BlockLogSize(raw: blockLogSize) }
            set { blockLogSize = newValue.raw }
        }
    }

    /// `Compression.Options.<formatID>.<name>` (NCompression::FormatKey).
    static func formatOptionKey(_ formatID: String, _ name: String) -> String {
        Key.formatOptionsPrefix + formatID + "." + name
    }

    /// Format IDs that have stored options, exactly as NCompression::CInfo::Load enumerates them.
    static var formatOptionIDs: [String] {
        var seen: [String] = []
        let prefix = Key.formatOptionsPrefix
        for key in SZSettings.keys(withPrefix: prefix) {
            let rest = key.dropFirst(prefix.count)
            guard let dot = rest.firstIndex(of: "."), dot != rest.startIndex else { continue }
            let id = String(rest[rest.startIndex..<dot])
            if !seen.contains(id) { seen.append(id) }
        }
        return seen
    }

    static func formatOptions(_ formatID: String) -> FormatOptions {
        var fo = FormatOptions(formatID: formatID)
        func str(_ name: String) -> String { string(formatOptionKey(formatID, name)) ?? "" }
        func num(_ name: String) -> Int { sentinelInteger(formatOptionKey(formatID, name)) }
        func pair(_ name: String) -> Bool? { boolPair(formatOptionKey(formatID, name)) }
        fo.method = str("Method")
        fo.options = str("Options")
        fo.encryptionMethod = str("EncryptionMethod")
        fo.memUse = str("MemUse64")
        fo.level = num("Level")
        fo.dictionary = num("Dictionary")
        fo.order = num("Order")
        fo.blockLogSize = num("BlockSize")
        fo.numThreads = num("NumThreads")
        fo.timePrec = num("TimePrec")
        fo.mTime = pair("MTime")
        fo.aTime = pair("ATime")
        fo.cTime = pair("CTime")
        fo.setArcMTime = pair("SetArcMTime")
        return fo
    }

    static func setFormatOptions(_ fo: FormatOptions) {
        func setStr(_ value: String, _ name: String) {
            setString(value.isEmpty ? nil : value, formatOptionKey(fo.formatID, name))
        }
        func setNum(_ value: Int, _ name: String) {
            setSentinelInteger(value, formatOptionKey(fo.formatID, name))
        }
        func setPair(_ value: Bool?, _ name: String) {
            setBoolPair(value, formatOptionKey(fo.formatID, name))
        }
        setStr(fo.method, "Method")
        setStr(fo.options, "Options")
        setStr(fo.encryptionMethod, "EncryptionMethod")
        setStr(fo.memUse, "MemUse64")
        setNum(fo.level, "Level")
        setNum(fo.dictionary, "Dictionary")
        setNum(fo.order, "Order")
        setNum(fo.blockLogSize, "BlockSize")
        setNum(fo.numThreads, "NumThreads")
        setNum(fo.timePrec, "TimePrec")
        setPair(fo.mTime, "MTime")
        setPair(fo.aTime, "ATime")
        setPair(fo.cTime, "CTime")
        setPair(fo.setArcMTime, "SetArcMTime")
    }

    /// NCompression::CInfo::Save calls RemoveAllFormatOptions first.
    static func removeFormatOptions(_ formatID: String) {
        let prefix = Key.formatOptionsPrefix + formatID + "."
        for key in SZSettings.keys(withPrefix: prefix) { SZSettings.removeKey(key) }
        notify(prefix)
    }

    // MARK: - Folders page: working folder (01b 4.8, 5.5; NWorkDir::CInfo)

    /// `Options.WorkDirType`: 0 system temp, 1 current (archive) folder, 2 specified.
    static var workDirMode: SZWorkDirMode {
        get { SZWorkDirMode(rawValue: integer(Key.workDirType, default: 0)) ?? .system }
        set { setInteger(newValue.rawValue, Key.workDirType) }
    }

    /// `Options.WorkDirPath`.
    static var workDirPath: String {
        get { string(Key.workDirPath) ?? "" }
        set { setString(newValue, Key.workDirPath) }
    }

    /// `Options.TempRemovableOnly` (**default true**).
    static var workDirForRemovableOnly: Bool {
        get { bool(Key.tempRemovableOnly, default: true) }
        set { setBool(newValue, Key.tempRemovableOnly) }
    }

    /// NWorkDir::CInfo::Load through the engine, which also applies the fallback
    /// "kSpecified without a path -> kSystem" (ZipRegistryMac.cpp:399-420).
    static func loadWorkDir() -> SZWorkDirSettings { SZWorkDirSettings.loadFromSettings() }

    /// NWorkDir::CInfo::Save (writes all three values).
    static func saveWorkDir(_ info: SZWorkDirSettings) {
        info.save()
        notify(Key.workDirType)
    }

    // MARK: - 7-Zip page: shell / Finder integration (01b 4.13, 5.5; CContextMenuInfo)

    /// Explorer/ContextMenuFlags.h. The Finder Sync extension uses the same bits (03 section 1.3).
    struct ContextMenuFlags: OptionSet {
        let rawValue: UInt32
        static let extractFiles = ContextMenuFlags(rawValue: 1 << 0)        // kExtract
        static let extractHere = ContextMenuFlags(rawValue: 1 << 1)         // kExtractHere
        static let extractTo = ContextMenuFlags(rawValue: 1 << 2)           // kExtractTo
        static let test = ContextMenuFlags(rawValue: 1 << 4)                // kTest
        static let open = ContextMenuFlags(rawValue: 1 << 5)                // kOpen
        static let openAs = ContextMenuFlags(rawValue: 1 << 6)              // kOpenAs
        static let compress = ContextMenuFlags(rawValue: 1 << 8)            // kCompress
        static let compressTo7z = ContextMenuFlags(rawValue: 1 << 9)        // kCompressTo7z
        static let compressEmail = ContextMenuFlags(rawValue: 1 << 10)      // kCompressEmail
        static let compressTo7zEmail = ContextMenuFlags(rawValue: 1 << 11)  // kCompressTo7zEmail
        static let compressToZip = ContextMenuFlags(rawValue: 1 << 12)      // kCompressToZip
        static let compressToZipEmail = ContextMenuFlags(rawValue: 1 << 13) // kCompressToZipEmail
        static let crcCascaded = ContextMenuFlags(rawValue: 1 << 30)        // kCRC_Cascaded
        static let crc = ContextMenuFlags(rawValue: 1 << 31)                // kCRC
        /// Flags = (UInt32)-1 when the value is absent: every item enabled.
        static let all = ContextMenuFlags(rawValue: 0xFFFF_FFFF)
    }

    /// `Options.CascadedMenu` (bool pair, **default true**).
    static var cascadedMenu: Bool? {
        get { boolPair(Key.cascadedMenu) }
        set { setBoolPair(newValue, Key.cascadedMenu) }
    }

    static var cascadedMenuValue: Bool { cascadedMenu ?? true }

    /// `Options.MenuIcons` (bool pair, default false).
    static var menuIcons: Bool? {
        get { boolPair(Key.menuIcons) }
        set { setBoolPair(newValue, Key.menuIcons) }
    }

    static var menuIconsValue: Bool { menuIcons ?? false }

    /// `Options.ElimDupExtract` (bool pair, **default true**).
    static var elimDupExtract: Bool? {
        get { boolPair(Key.elimDupExtract) }
        set { setBoolPair(newValue, Key.elimDupExtract) }
    }

    static var elimDupExtractValue: Bool { elimDupExtract ?? true }

    /// `Options.WriteZoneIdExtract`: -1 not set (= no), 0 no, 1 yes, 2 Office files only.
    /// On macOS this drives `com.apple.quarantine` propagation (01 section 9 #23).
    static var writeZoneIdExtract: Int {
        get { sentinelInteger(Key.writeZoneIdExtract) }
        set { setSentinelInteger(newValue, Key.writeZoneIdExtract) }
    }

    /// `Options.ContextMenu`: absent = all items (Flags = (UInt32)-1, Flags_Def = false).
    static var contextMenuFlags: ContextMenuFlags {
        get {
            guard hasKey(Key.contextMenu) else { return .all }
            return ContextMenuFlags(rawValue: UInt32(truncatingIfNeeded: integer(Key.contextMenu)))
        }
        set { setInteger(Int(Int32(truncatingIfNeeded: newValue.rawValue)), Key.contextMenu) }
    }

    /// CContextMenuInfo::Flags_Def -- whether the user ever changed the item list.
    static var contextMenuFlagsDefined: Bool { hasKey(Key.contextMenu) }

    /// Everything the Finder Sync extension needs, as plain property-list values, for the
    /// `x-7zip:///settings` handshake (03 section 6.4). Key names are unchanged so the
    /// extension can also read them straight from a shared suite.
    static func finderIntegrationSettings() -> [String: Any] {
        [
            Key.cascadedMenu: cascadedMenuValue,
            Key.menuIcons: menuIconsValue,
            Key.elimDupExtract: elimDupExtractValue,
            Key.writeZoneIdExtract: writeZoneIdExtract,
            Key.contextMenu: Int(Int32(truncatingIfNeeded: contextMenuFlags.rawValue)),
        ]
    }
}

extension Settings {

    // MARK: - Options window state (not a Windows value: property sheets remember the active
    // page only for the lifetime of the process; the port keeps it across launches)

    /// Index of the last visited Options page.
    static var optionsLastPage: Int {
        get { integer(Key.optionsLastPage) }
        set { setInteger(newValue, Key.optionsLastPage) }
    }
}

extension Settings.Key {
    static let optionsLastPage = "FM.OptionsPage"
}

// ---------------------------------------------------------------------------
// MARK: - Test support (`mac/resetcmd`)
//
// `Mac/docs/test-support-contract.md` and `Mac/docs/api/resetcmd.md`. Everything here is inert
// unless `SZ_TEST_SUPPORT=1` is in the environment: `TestSupport.isEnabled` gates the other two
// variables, so an app started the normal way behaves exactly as it always has.
//
// It lives in this file rather than in one of its own because `Settings.swift` is already compiled
// into the `SevenZipKitTests` target (`project.yml`), which is what makes the environment parsing,
// the state-directory rule and the domain replacement unit-testable without the GUI.

/// The three environment switches of the test-support contract.
enum TestSupport {

    static let supportVariable = SZSettingsTestSupportEnvironmentVariable       // "SZ_TEST_SUPPORT"
    static let animationsVariable = "SZ_DISABLE_ANIMATIONS"
    static let stateDirectoryVariable = SZSettingsStateDirectoryEnvironmentVariable  // "SZ_STATE_DIR"

    /// The value of `name` in the current environment, nil when unset or empty.
    ///
    /// `getenv`, not `ProcessInfo.processInfo.environment`: the variables are read on every access
    /// so a test may `setenv()` mid-process (the same rule as `NMacPrefs::ApplicationID()`), and
    /// `ProcessInfo`'s dictionary is a snapshot that need not follow `setenv`.
    static func environmentValue(_ name: String) -> String? {
        guard let raw = getenv(name) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    /// `SZ_TEST_SUPPORT=1`. The master switch: nothing else in this file does anything without it.
    static var isEnabled: Bool { SZSettings.testSupportEnabled }

    /// `SZ_DISABLE_ANIMATIONS=1` **and** test support on. Window and view animation durations are
    /// zero, automatic window animation and window tabbing are off, no dialog animates in or out.
    static var animationsDisabled: Bool {
        isEnabled && environmentValue(animationsVariable) == "1"
    }

    /// `SZ_STATE_DIR`: the absolute directory this instance uses for everything it would otherwise
    /// put in a shared location. nil when test support is off or the value is not an absolute path.
    /// Resolved by the bridge so the C++/ObjC++ side and Swift can never disagree.
    static var stateDirectory: String? { SZSettings.stateDirectory }

    /// `<SZ_STATE_DIR>/tmp/`, created on demand, or `NSTemporaryDirectory()` when there is none.
    static var temporaryDirectory: String { SZSettings.temporaryDirectory }

    /// A named subdirectory of the state directory, created on demand; nil without a state
    /// directory, so a caller keeps its old behaviour.
    static func stateSubdirectory(_ name: String) -> String? {
        guard let stateDirectory else { return nil }
        let path = (stateDirectory as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Called first in `applicationWillFinishLaunching`, before anything reads a setting.
    ///
    /// With a state directory and no explicit `SEVENZIP_DEFAULTS_SUITE`, the settings domain is
    /// pointed at `<state>/preferences.plist`: CFPreferences takes an absolute path as an
    /// application ID (`Mac/docs/api/harness.md` section 3), so two instances then keep entirely
    /// separate settings even when they were built with the same bundle identifier. An explicit
    /// suite always wins -- that is how the UI harness seeds one plist per test.
    static func prepareForLaunch() {
        guard isEnabled, let stateDirectory else { return }
        try? FileManager.default.createDirectory(atPath: stateDirectory, withIntermediateDirectories: true)
        if environmentValue(SZSettingsSuiteEnvironmentVariable) == nil {
            let plist = (stateDirectory as NSString).appendingPathComponent("preferences.plist")
            setenv(SZSettingsSuiteEnvironmentVariable, plist, 1)
        }
    }
}

extension Settings {

    /// Replaces the whole settings domain with the property list at `path`
    /// (`sevenzip://test/reset?defaults=…`). Every existing key is removed first, so the result is
    /// the file and nothing else; values keep their property-list types, which the typed accessors
    /// could not do. Returns false when the file is missing or is not a dictionary.
    @discardableResult
    static func replaceDomainContents(fromPlistAt path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = plist as? [String: Any] else { return false }
        replaceDomainContents(with: dictionary)
        return true
    }

    /// The same, from values already in memory (the unit tests use this shape).
    static func replaceDomainContents(with dictionary: [String: Any]) {
        for key in allDomainKeys() {
            SZSettings.setPropertyListValue(nil, forKey: key)
        }
        for (key, value) in dictionary {
            SZSettings.setPropertyListValue(value, forKey: key)
        }
        SZSettings.synchronize()
    }

    /// Everything the domain holds, for a test that wants to assert what the app saved.
    static func domainContents() -> [String: Any] {
        var out: [String: Any] = [:]
        for key in allDomainKeys() {
            if let value = SZSettings.propertyListValue(forKey: key) { out[key] = value }
        }
        return out
    }

    /// Every key the domain currently holds.
    ///
    /// **Measured, and the reason this is not just `SZSettings.keys(withPrefix: "")`:**
    /// `CFPreferencesCopyKeyList` is live for a domain *named* like a bundle id, but for a domain
    /// that is an absolute **plist path** -- which is what `SEVENZIP_DEFAULTS_SUITE` is in every UI
    /// test (`Mac/docs/api/harness.md` section 3) -- it answers from a cache populated by its first
    /// call in the process and never updates, even after `CFPreferencesAppSynchronize`. Values read
    /// back correctly; only the key *list* goes stale. The file on disk is written on every
    /// synchronize and is authoritative, so its keys are unioned in. Without this, a reset with
    /// `defaults=` would leave behind every key the app had written since launch.
    static func allDomainKeys() -> [String] {
        var keys = Set(SZSettings.keys(withPrefix: ""))
        if let path = domainPlistPath(),
           let data = FileManager.default.contents(atPath: path),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dictionary = plist as? [String: Any] {
            keys.formUnion(dictionary.keys)
        }
        return Array(keys)
    }

    /// The file a plist-path domain lives in, or nil for a named domain. CFPreferences appends
    /// `.plist` when the path it was given has no extension (measured: `/a/b/seed` and
    /// `/a/b/seed.plist` are the same domain).
    static func domainPlistPath() -> String? {
        let id = SZSettings.applicationID
        guard (id as NSString).isAbsolutePath else { return nil }
        return (id as NSString).pathExtension.isEmpty ? id + ".plist" : id
    }

    /// Posts the change notification for every group, as though each had been written. Used after
    /// the domain was replaced wholesale: the observers cannot know which keys moved, so they are
    /// all told to re-read (`OptionsPostApply.settingsApplied` does the panel half of this).
    static func notifyAllGroups() {
        for group in [Group.language, .editor, .fm, .view, .extraction, .compression, .workDir, .contextMenu] {
            let info: [AnyHashable: Any] = [groupUserInfoKey: group]
            NotificationCenter.default.post(name: group.notificationName, object: nil, userInfo: info)
            NotificationCenter.default.post(name: didChangeNotification, object: nil, userInfo: info)
        }
    }
}
