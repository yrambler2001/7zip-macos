// SettingsTests.swift -- the Swift settings facade (Mac/App/Support/Settings.swift) and the
// association list (FileTypes.swift). Both files are symlinked into this target so the tests run
// against the very same source the app compiles; they are plain Foundation code by design.
//
// The tests run against an isolated preferences domain: setUp points SEVENZIP_DEFAULTS_SUITE at
// "com.yrambler2001.7zip.tests", so nothing here can disturb the user's real settings or another
// agent's running app, and tearDown clears the suite again. testDefaultsSuiteOverride covers the
// override mechanism itself, including that the real domain stays untouched.

import XCTest
import SevenZipKit

final class SettingsTests: XCTestCase {

    /// The isolated domain these tests write to.
    private static let testSuite = "com.yrambler2001.7zip.tests"
    private static let appID = testSuite as CFString
    private static let realAppID = "com.yrambler2001.7zip" as CFString

    /// Every key these tests may write.
    private static let touchedKeys: [String] = [
        "FM.ShowDots", "FM.ShowRealFileIcons", "FM.FullRow", "FM.ShowGrid", "FM.SingleClick",
        "FM.AlternativeSelection", "FM.ShowSystemMenu", "FM.Viewer", "FM.Editor", "FM.Diff",
        "FM.ListMode0", "FM.ListMode1", "FM.PanelPath0", "FM.Toolbars", "FM.FolderHistory",
        "FM.FolderShortcuts", "FM.CopyHistory", "FM.Panels.numPanels", "FM.Columns.FSFolder",
        "FM.OptionsPage",
        "Lang",
        "Extraction.ExtractMode", "Extraction.OverwriteMode", "Extraction.SplitDest",
        "Extraction.ElimDup", "Extraction.ShowPassword", "Extraction.PathHistory",
        "Extraction.MemLimit",
        "Compression.Archiver", "Compression.Level", "Compression.SymLinks", "Compression.ArcHistory",
        "Compression.Options.7z.Method", "Compression.Options.7z.Level",
        "Compression.Options.7z.Dictionary", "Compression.Options.7z.BlockSize",
        "Compression.Options.7z.Order", "Compression.Options.7z.NumThreads",
        "Compression.Options.7z.TimePrec", "Compression.Options.7z.MemUse64",
        "Compression.Options.7z.MTime", "Compression.Options.7z.ATime",
        "Compression.Options.7z.CTime", "Compression.Options.7z.SetArcMTime",
        "Compression.Options.7z.Options", "Compression.Options.7z.EncryptionMethod",
        "Compression.Options.zip.Level", "Compression.Options.zip.Method",
        "Options.WorkDirType", "Options.WorkDirPath", "Options.TempRemovableOnly",
        "Options.CascadedMenu", "Options.MenuIcons", "Options.ElimDupExtract",
        "Options.WriteZoneIdExtract", "Options.ContextMenu",
    ]

    private var saved: [String: CFPropertyList?] = [:]

    private func rawValue(_ key: String) -> CFPropertyList? {
        CFPreferencesCopyAppValue(key as CFString, Self.appID)
    }

    private func setRawValue(_ value: CFPropertyList?, _ key: String) {
        CFPreferencesSetAppValue(key as CFString, value, Self.appID)
    }

    override func setUp() {
        super.setUp()
        setenv(SZSettingsSuiteEnvironmentVariable, Self.testSuite, 1)
        saved = [:]
        for key in Self.touchedKeys {
            saved[key] = rawValue(key)
            setRawValue(nil, key)
        }
        CFPreferencesAppSynchronize(Self.appID)
    }

    override func tearDown() {
        for key in Self.touchedKeys { setRawValue(nil, key) }
        CFPreferencesAppSynchronize(Self.appID)
        saved = [:]
        unsetenv(SZSettingsSuiteEnvironmentVariable)
        super.tearDown()
    }

    // MARK: Defaults when nothing is stored (01b 5.2, 5.4, 5.5)

    func testDefaultsWhenUnset() {
        XCTAssertFalse(Settings.showDots)
        XCTAssertFalse(Settings.showRealFileIcons)
        XCTAssertFalse(Settings.fullRow)
        XCTAssertFalse(Settings.showGrid)
        XCTAssertFalse(Settings.singleClick)
        XCTAssertFalse(Settings.alternativeSelection)
        XCTAssertFalse(Settings.showSystemMenu)
        XCTAssertEqual(Settings.viewerPath, "")
        XCTAssertEqual(Settings.editorPath, "")
        XCTAssertEqual(Settings.diffPath, "")
        XCTAssertEqual(Settings.language, "")
        XCTAssertEqual(Settings.listMode(0), 3)                       // details
        XCTAssertEqual(Settings.numPanels, 1)                         // kNumDefaultPanels
        XCTAssertEqual(Settings.toolbarsMask, 0x8000_0000 | 8 | 4 | 1) // kDefaultToolbarMask
        XCTAssertEqual(Settings.folderShortcuts.count, 10)
        XCTAssertTrue(Settings.folderHistory.isEmpty)

        // Extraction
        XCTAssertNil(Settings.extractPathMode)                        // not forced
        XCTAssertEqual(Settings.extractPathModeValue, Int(SZExtractPathMode.curPaths.rawValue))
        XCTAssertNil(Settings.extractOverwriteMode)
        XCTAssertEqual(Settings.extractOverwriteModeValue, Int(SZOverwriteMode.ask.rawValue))
        XCTAssertNil(Settings.extractSplitDest)
        XCTAssertTrue(Settings.extractSplitDestValue)                 // Key_Get_BoolPair_true
        XCTAssertTrue(Settings.extractElimDupValue)
        XCTAssertFalse(Settings.extractShowPasswordValue)
        XCTAssertEqual(Settings.extractMemLimitGB, -1)                // no limit
        XCTAssertFalse(Settings.extractMemLimitEnabled)

        // Compression
        XCTAssertEqual(Settings.archiverType, "7z")
        XCTAssertEqual(Settings.compressionLevel, 5)
        XCTAssertFalse(Settings.compressShowPassword)
        XCTAssertFalse(Settings.compressEncryptHeaders)
        XCTAssertNil(Settings.compressSymLinks)

        // Options
        XCTAssertEqual(Settings.workDirMode, .system)
        XCTAssertEqual(Settings.workDirPath, "")
        XCTAssertTrue(Settings.workDirForRemovableOnly)               // default true
        XCTAssertNil(Settings.cascadedMenu)
        XCTAssertTrue(Settings.cascadedMenuValue)                     // default true
        XCTAssertFalse(Settings.menuIconsValue)
        XCTAssertTrue(Settings.elimDupExtractValue)                   // default true
        XCTAssertEqual(Settings.writeZoneIdExtract, -1)
        XCTAssertFalse(Settings.contextMenuFlagsDefined)
        XCTAssertEqual(Settings.contextMenuFlags, .all)               // absent = every item
    }

    // MARK: CBoolPair tri-state (absent / false / true)

    func testTriStateRoundTrip() {
        for key in ["Options.CascadedMenu", "Options.MenuIcons", "Options.ElimDupExtract"] {
            XCTAssertFalse(SZSettings.hasKey(key))
        }
        XCTAssertNil(Settings.cascadedMenu)

        Settings.cascadedMenu = false
        XCTAssertEqual(Settings.cascadedMenu, false)
        XCTAssertFalse(Settings.cascadedMenuValue)                    // an explicit false wins
        XCTAssertTrue(SZSettings.hasKey("Options.CascadedMenu"))
        XCTAssertEqual(SZSettings.boolPair(forKey: "Options.CascadedMenu")?.boolValue, false)

        Settings.cascadedMenu = true
        XCTAssertEqual(Settings.cascadedMenu, true)
        XCTAssertEqual(SZSettings.boolPair(forKey: "Options.CascadedMenu")?.boolValue, true)

        Settings.cascadedMenu = nil                                   // Key_Set_BoolPair_Delete_IfNotDef
        XCTAssertNil(Settings.cascadedMenu)
        XCTAssertFalse(SZSettings.hasKey("Options.CascadedMenu"))
        XCTAssertTrue(Settings.cascadedMenuValue)                     // back to the engine default

        // SplitDest defaults to true but must still be able to hold an explicit false.
        Settings.extractSplitDest = false
        XCTAssertFalse(Settings.extractSplitDestValue)
        Settings.extractSplitDest = nil
        XCTAssertTrue(Settings.extractSplitDestValue)

        // Int? keys: absent means "not forced", 0 is a real value.
        Settings.extractPathMode = 0                                  // kFullPaths
        XCTAssertEqual(Settings.extractPathMode, 0)
        XCTAssertEqual(Settings.extractPathModeValue, 0)
        Settings.extractPathMode = nil
        XCTAssertNil(Settings.extractPathMode)
        XCTAssertFalse(SZSettings.hasKey("Extraction.ExtractMode"))
    }

    // MARK: the -1 / -2 sentinels and the log2 BlockSize (01b 5.4)

    func testSentinelEncodings() {
        // Key_Set_UInt32: -1 is never stored, the key is removed instead.
        Settings.extractMemLimitGB = 8
        XCTAssertEqual(SZSettings.integer(forKey: "Extraction.MemLimit", defaultValue: 0), 8)
        Settings.extractMemLimitGB = -1
        XCTAssertFalse(SZSettings.hasKey("Extraction.MemLimit"))
        XCTAssertEqual(Settings.extractMemLimitGB, -1)

        Settings.writeZoneIdExtract = 2
        XCTAssertEqual(SZSettings.integer(forKey: "Options.WriteZoneIdExtract", defaultValue: 0), 2)
        Settings.writeZoneIdExtract = -1
        XCTAssertFalse(SZSettings.hasKey("Options.WriteZoneIdExtract"))
    }

    func testFormatOptionsEncoding() {
        var fo = Settings.FormatOptions(formatID: "7z")
        fo.method = "LZMA2"
        fo.level = 9
        fo.dictionarySize = .bytes(64 << 20)
        fo.blockSize = .log2(24)                 // 16 MB solid block, stored as 24
        fo.order = 273
        fo.numThreads = 8
        fo.memUse = "80%"
        fo.mTime = true
        fo.aTime = nil
        Settings.setFormatOptions(fo)

        // Exactly the keys and values NCompression::CInfo::Save writes.
        XCTAssertEqual(SZSettings.string(forKey: "Compression.Options.7z.Method"), "LZMA2")
        XCTAssertEqual(SZSettings.integer(forKey: "Compression.Options.7z.Level", defaultValue: 0), 9)
        XCTAssertEqual(SZSettings.integer(forKey: "Compression.Options.7z.Dictionary", defaultValue: 0), 64 << 20)
        XCTAssertEqual(SZSettings.integer(forKey: "Compression.Options.7z.BlockSize", defaultValue: 0), 24)
        XCTAssertEqual(SZSettings.integer(forKey: "Compression.Options.7z.Order", defaultValue: 0), 273)
        XCTAssertEqual(SZSettings.string(forKey: "Compression.Options.7z.MemUse64"), "80%")
        XCTAssertEqual(SZSettings.boolPair(forKey: "Compression.Options.7z.MTime")?.boolValue, true)
        XCTAssertFalse(SZSettings.hasKey("Compression.Options.7z.ATime"))     // nil pair = no key
        XCTAssertFalse(SZSettings.hasKey("Compression.Options.7z.TimePrec")) // -1 = no key

        let back = Settings.formatOptions("7z")
        XCTAssertEqual(back, fo)
        XCTAssertEqual(back.blockSize, .log2(24))
        XCTAssertEqual(back.blockSize.bytes, 16 << 20)
        XCTAssertEqual(back.dictionarySize, .bytes(64 << 20))

        // The two dictionary sentinels.
        fo.dictionarySize = .atLeast4GB          // -2
        Settings.setFormatOptions(fo)
        XCTAssertEqual(SZSettings.integer(forKey: "Compression.Options.7z.Dictionary", defaultValue: 0), -2)
        XCTAssertEqual(Settings.formatOptions("7z").dictionarySize, .atLeast4GB)
        fo.dictionarySize = .auto                // -1 -> key removed
        Settings.setFormatOptions(fo)
        XCTAssertFalse(SZSettings.hasKey("Compression.Options.7z.Dictionary"))
        XCTAssertEqual(Settings.formatOptions("7z").dictionarySize, .auto)

        // BlockSize classification.
        XCTAssertEqual(Settings.BlockLogSize(raw: 0), .nonSolid)
        XCTAssertEqual(Settings.BlockLogSize(raw: 64), .solid)
        XCTAssertEqual(Settings.BlockLogSize(raw: -1), .auto)
        XCTAssertNil(Settings.BlockLogSize(raw: 64).bytes)

        // Format enumeration and removal, like NCompression::CInfo::Load / RemoveAllFormatOptions.
        var zip = Settings.FormatOptions(formatID: "zip")
        zip.level = 5
        zip.method = "Deflate"
        Settings.setFormatOptions(zip)
        let ids = Settings.formatOptionIDs
        XCTAssertTrue(ids.contains("7z"))
        XCTAssertTrue(ids.contains("zip"))
        Settings.removeFormatOptions("zip")
        XCTAssertFalse(Settings.formatOptionIDs.contains("zip"))
        XCTAssertTrue(Settings.formatOptionIDs.contains("7z"))
    }

    // MARK: string lists (CFArray of CFString, the macOS form of the REG_BINARY blob)

    func testStringLists() {
        Settings.folderHistory = ["/tmp", "/Users", "/tmp"]
        XCTAssertEqual(SZSettings.stringArray(forKey: "FM.FolderHistory"), ["/tmp", "/Users", "/tmp"])
        Settings.addToFolderHistory("/Volumes")
        XCTAssertEqual(Settings.folderHistory.first, "/Volumes")
        Settings.addToFolderHistory("/tmp")                        // moves to the head, no duplicate
        XCTAssertEqual(Settings.folderHistory, ["/tmp", "/Volumes", "/Users"])
        Settings.folderHistory = (0..<150).map { "/p\($0)" }
        XCTAssertEqual(Settings.folderHistory.count, 100)          // CFolderHistory::Normalize

        Settings.copyHistory = (0..<30).map { "/c\($0)" }
        XCTAssertEqual(Settings.copyHistory.count, 20)

        Settings.extractPathHistory = (0..<20).map { "/e\($0)" }
        XCTAssertEqual(Settings.extractPathHistory.count, 16)

        var slots = Settings.folderShortcuts
        XCTAssertEqual(slots.count, 10)
        slots[3] = "/Users/Shared"
        Settings.folderShortcuts = slots
        XCTAssertEqual(Settings.folderShortcuts[3], "/Users/Shared")
        XCTAssertEqual(Settings.folderShortcuts[0], "")            // empty slot = unset
        XCTAssertEqual(SZSettings.stringArray(forKey: "FM.FolderShortcuts")?.count, 10)

        Settings.archiveHistory = (0..<25).map { "/a\($0)" }
        XCTAssertEqual(Settings.archiveHistory.count, 20)
    }

    // MARK: the facade and SZSettings agree on the Windows-style key names (01b 5.7)

    func testKeysMatchWindowsValueNames() {
        Settings.showDots = true
        Settings.fullRow = true
        Settings.singleClick = true
        Settings.viewerPath = "/Applications/TextEdit.app"
        Settings.language = "de"
        Settings.compressionLevel = 9
        Settings.archiverType = "zip"
        Settings.workDirMode = .specified
        Settings.workDirPath = "/tmp/7z-work"
        Settings.workDirForRemovableOnly = false
        Settings.contextMenuFlags = [.open, .extractHere, .crc]
        Settings.optionsLastPage = 4

        XCTAssertTrue(SZSettings.bool(forKey: "FM.ShowDots", defaultValue: false))
        XCTAssertTrue(SZSettings.bool(forKey: "FM.FullRow", defaultValue: false))
        XCTAssertTrue(SZSettings.bool(forKey: "FM.SingleClick", defaultValue: false))
        XCTAssertEqual(SZSettings.string(forKey: "FM.Viewer"), "/Applications/TextEdit.app")
        XCTAssertEqual(SZSettings.string(forKey: "Lang"), "de")
        XCTAssertEqual(SZSettings.integer(forKey: "Compression.Level", defaultValue: 0), 9)
        XCTAssertEqual(SZSettings.string(forKey: "Compression.Archiver"), "zip")
        XCTAssertEqual(SZSettings.integer(forKey: "Options.WorkDirType", defaultValue: 0), 2)
        XCTAssertEqual(SZSettings.string(forKey: "Options.WorkDirPath"), "/tmp/7z-work")
        XCTAssertFalse(SZSettings.bool(forKey: "Options.TempRemovableOnly", defaultValue: true))
        XCTAssertEqual(SZSettings.integer(forKey: "FM.OptionsPage", defaultValue: 0), 4)

        // 1<<5 | 1<<1 | 1<<31 read back as the same UInt32 bit pattern.
        let stored = SZSettings.integer(forKey: "Options.ContextMenu", defaultValue: 0)
        XCTAssertEqual(UInt32(truncatingIfNeeded: stored), (1 << 5) | (1 << 1) | (1 << 31))
        XCTAssertTrue(Settings.contextMenuFlagsDefined)
        XCTAssertEqual(Settings.contextMenuFlags, [.open, .extractHere, .crc])
        XCTAssertFalse(Settings.contextMenuFlags.contains(.test))

        // The empty string removes an editor path (empty = "use the default application").
        Settings.viewerPath = ""
        XCTAssertFalse(SZSettings.hasKey("FM.Viewer"))
    }

    /// NWorkDir::CInfo::Load: kSpecified with **no** WorkDirPath value falls back to kSystem
    /// (ZipRegistry.cpp:526-533 -- an empty stored string is a value and keeps kSpecified), and
    /// the engine bridge must see what the facade wrote.
    func testWorkDirBridge() {
        Settings.workDirMode = .specified
        SZSettings.removeKey("Options.WorkDirPath")
        XCTAssertEqual(Settings.loadWorkDir().mode, .system)

        Settings.workDirPath = ""            // present but empty: the mode stays kSpecified
        XCTAssertEqual(Settings.loadWorkDir().mode, .specified)

        Settings.workDirPath = "/tmp/7z-work"
        let loaded = Settings.loadWorkDir()
        XCTAssertEqual(loaded.mode, .specified)
        XCTAssertEqual(loaded.path, "/tmp/7z-work")

        let info = SZWorkDirSettings()
        info.mode = .current
        info.path = "/tmp/other"
        info.forRemovableOnly = false
        Settings.saveWorkDir(info)
        XCTAssertEqual(Settings.workDirMode, .current)
        XCTAssertEqual(Settings.workDirPath, "/tmp/other")
        XCTAssertFalse(Settings.workDirForRemovableOnly)
    }

    // MARK: column layout (01b 5.3)

    func testColumnLayoutRoundTrip() {
        let layout = Settings.ColumnLayout(sortID: 4, ascending: false, columns: [
            .init(propID: 10, visible: true, width: 200),
            .init(propID: 7, visible: false, width: 80),
        ])
        Settings.setColumnLayout(layout, forFolderType: "FSFolder")
        XCTAssertEqual(Settings.columnLayout(forFolderType: "FSFolder"), layout)
        XCTAssertNotNil(SZSettings.string(forKey: "FM.Columns.FSFolder"))
        Settings.setColumnLayout(nil, forFolderType: "FSFolder")
        XCTAssertNil(Settings.columnLayout(forFolderType: "FSFolder"))
    }

    // MARK: change notifications

    func testChangeNotifications() {
        let global = expectation(description: "global notification with the key payload")
        let group = expectation(description: "per-group notification")
        let center = NotificationCenter.default
        let t1 = center.addObserver(forName: Settings.didChangeNotification, object: nil, queue: nil) { note in
            guard note.userInfo?[Settings.keyUserInfoKey] as? String == "FM.ShowGrid" else { return }
            XCTAssertEqual(note.userInfo?[Settings.groupUserInfoKey] as? Settings.Group, .fm)
            global.fulfill()
        }
        let t2 = center.addObserver(forName: Settings.Group.fm.notificationName, object: nil, queue: nil) { _ in
            group.fulfill()
        }
        Settings.showGrid = true
        wait(for: [global, group], timeout: 2)
        center.removeObserver(t1)
        center.removeObserver(t2)

        XCTAssertEqual(Settings.group(forKey: "Lang"), .language)
        XCTAssertEqual(Settings.group(forKey: "FM.Editor"), .editor)
        XCTAssertEqual(Settings.group(forKey: "FM.ShowDots"), .fm)
        XCTAssertEqual(Settings.group(forKey: "FM.PanelPath0"), .view)
        XCTAssertEqual(Settings.group(forKey: "Extraction.MemLimit"), .extraction)
        XCTAssertEqual(Settings.group(forKey: "Compression.Options.7z.Level"), .compression)
        XCTAssertEqual(Settings.group(forKey: "Options.WorkDirPath"), .workDir)
        XCTAssertEqual(Settings.group(forKey: "Options.ContextMenu"), .contextMenu)
    }

    /// The Finder extension reads these five keys (03 section 6.4).
    func testFinderIntegrationExport() {
        Settings.cascadedMenu = false
        Settings.menuIcons = true
        Settings.writeZoneIdExtract = 2
        Settings.contextMenuFlags = [.extractHere, .compressTo7z]
        let export = Settings.finderIntegrationSettings()
        XCTAssertEqual(export["Options.CascadedMenu"] as? Bool, false)
        XCTAssertEqual(export["Options.MenuIcons"] as? Bool, true)
        XCTAssertEqual(export["Options.ElimDupExtract"] as? Bool, true)
        XCTAssertEqual(export["Options.WriteZoneIdExtract"] as? Int, 2)
        XCTAssertEqual(export["Options.ContextMenu"] as? Int, (1 << 1) | (1 << 9))
    }

    // MARK: the SEVENZIP_DEFAULTS_SUITE override (requests.md: harness -> options)

    /// With the variable set, everything -- SZSettings, the Swift facade and the engine-side
    /// ZipRegistry accessors -- reads and writes that suite, and the real domain is untouched.
    func testDefaultsSuiteOverride() {
        let probe = "FM.PanelPath0"
        let engineProbe = "Options.WorkDirPath"

        // What the real domain holds right now; nothing below may change it.
        unsetenv(SZSettingsSuiteEnvironmentVariable)
        XCTAssertEqual(SZSettings.applicationID, SZSettingsDefaultApplicationID)
        XCTAssertFalse(SZSettings.usesOverrideSuite)
        CFPreferencesAppSynchronize(Self.realAppID)
        let realProbeBefore = CFPreferencesCopyAppValue(probe as CFString, Self.realAppID) as? String
        let realEngineBefore = CFPreferencesCopyAppValue(engineProbe as CFString, Self.realAppID) as? String

        setenv(SZSettingsSuiteEnvironmentVariable, Self.testSuite, 1)
        XCTAssertEqual(SZSettings.applicationID, Self.testSuite)
        XCTAssertTrue(SZSettings.usesOverrideSuite)

        // Swift facade -> suite
        Settings.setPanelPath("/tmp/suite-only", 0)
        XCTAssertEqual(Settings.panelPath(0), "/tmp/suite-only")
        XCTAssertEqual(SZSettings.string(forKey: probe), "/tmp/suite-only")
        XCTAssertEqual(CFPreferencesCopyAppValue(probe as CFString, Self.appID) as? String, "/tmp/suite-only")

        // Engine side (NWorkDir::CInfo::Save/Load through ZipRegistryMac) -> the same suite
        let info = SZWorkDirSettings()
        info.mode = .specified
        info.path = "/tmp/suite-workdir"
        info.forRemovableOnly = false
        info.save()
        XCTAssertEqual(SZWorkDirSettings.loadFromSettings().path, "/tmp/suite-workdir")
        XCTAssertEqual(Settings.workDirPath, "/tmp/suite-workdir")
        XCTAssertEqual(CFPreferencesCopyAppValue(engineProbe as CFString, Self.appID) as? String, "/tmp/suite-workdir")

        // The real domain never saw any of it.
        CFPreferencesAppSynchronize(Self.realAppID)
        XCTAssertEqual(CFPreferencesCopyAppValue(probe as CFString, Self.realAppID) as? String, realProbeBefore)
        XCTAssertEqual(CFPreferencesCopyAppValue(engineProbe as CFString, Self.realAppID) as? String, realEngineBefore)

        // Switching back mid-process works too (the domain is resolved per access).
        unsetenv(SZSettingsSuiteEnvironmentVariable)
        XCTAssertEqual(SZSettings.applicationID, SZSettingsDefaultApplicationID)
        XCTAssertEqual(SZSettings.string(forKey: probe), realProbeBefore)
        setenv(SZSettingsSuiteEnvironmentVariable, Self.testSuite, 1)
        XCTAssertEqual(SZSettings.string(forKey: probe), "/tmp/suite-only")
    }

    // MARK: FileTypes (03 section 3.1)

    func testFileTypesTable() {
        // 7z.dll STRINGTABLE 100 has 40 "ext:index" pairs in 26.03 (the inventory prose says 39).
        XCTAssertEqual(FileTypes.all.count, 40)
        XCTAssertEqual(Set(FileTypes.extensions).count, 40)
        XCTAssertEqual(FileTypes.extensions.first, "7z")
        XCTAssertEqual(FileTypes.extensions.last, "apfs")

        XCTAssertEqual(FileTypes.type(forExtension: "7z")?.iconIndex, 0)
        XCTAssertEqual(FileTypes.type(forExtension: "zip")?.iconIndex, 1)
        XCTAssertEqual(FileTypes.type(forExtension: "RAR")?.iconIndex, 3)      // lookup is case-insensitive
        XCTAssertEqual(FileTypes.type(forExtension: "001")?.iconIndex, 9)
        XCTAssertEqual(FileTypes.type(forExtension: "tbz2")?.iconIndex, 2)
        XCTAssertEqual(FileTypes.type(forExtension: "tzst")?.iconIndex, 26)
        XCTAssertEqual(FileTypes.type(forExtension: "esd")?.iconIndex, 15)
        XCTAssertEqual(FileTypes.type(forExtension: "apfs")?.iconIndex, 25)
        XCTAssertNil(FileTypes.type(forExtension: "jar"))                     // openable but never associated

        for type in FileTypes.all {
            XCTAssertTrue((0...26).contains(type.iconIndex), "\(type.ext) icon index")
            XCTAssertNotNil(FileTypes.iconNames[type.iconIndex], "\(type.ext) icon name")
            XCTAssertEqual(type.progID, "7-Zip." + type.ext)
            XCTAssertEqual(type.localizedDescription, type.ext.uppercased() + " Archive")
            XCTAssertFalse(type.format.isEmpty, "\(type.ext) format")
        }
        XCTAssertEqual(FileTypes.type(forExtension: "7z")?.iconFileName, "7z")
        XCTAssertEqual(FileTypes.type(forExtension: "001")?.iconFileName, "split")

        // Every listed format name must exist in the engine's format table.
        if SZCodecs.isLoaded {
            for type in FileTypes.all {
                XCTAssertNotNil(SZCodecs.format(named: type.format), "format \(type.format) for .\(type.ext)")
            }
        }
    }
}
