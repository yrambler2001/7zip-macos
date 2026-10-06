# `options` scope — public API

What the other scopes may use from `mac/options`. Sources: `Mac/App/Support/Settings.swift`,
`Mac/App/Support/FileTypes.swift`, `Mac/App/Dialogs/Options*.swift`,
`Mac/App/Commands/OptionsCommands.swift`, plus `SZSettings` in the bridge.

Parity references: `01b-fm-dialogs-settings.md` sections 4.7-4.9, 4.13, 4.19, 4.21, 4.22 and all
of section 5; `03-shell-integration-inventory.md` sections 3 and 6; `01-fm-feature-inventory.md`
sections 7 and 9. Corrections to those documents are listed in `ai/requests.md`.

## 1. The preferences domain (and how to isolate it)

Everything is stored with CFPreferences in one domain: `com.yrambler2001.7zip` by default, or the
domain named by the **`SEVENZIP_DEFAULTS_SUITE`** environment variable when it is set and not
empty:

```sh
SEVENZIP_DEFAULTS_SUITE=7zip-uitests Mac/build/Debug/7-Zip.app/Contents/MacOS/7-Zip
defaults read 7zip-uitests          # everything the run stored
defaults delete 7zip-uitests        # clean up
```

The variable is resolved on **every** access (`NMacPrefs::ApplicationID()`,
`Mac/Core/Platform/MacPrefs.cpp`), so a test may switch domains with `setenv()` mid-process. It is
honoured by `SZSettings`, by the Swift `Settings` facade built on it, and by the engine-side
`ZipRegistry` accessors (`NExtract`, `NCompression`, `NWorkDir`, `CContextMenuInfo`) — the C++
code and the UI can never disagree about which domain they use.

```swift
SZSettings.applicationID      // the domain in use right now
SZSettings.usesOverrideSuite  // true when the variable points somewhere else
SZSettingsSuiteEnvironmentVariable / SZSettingsDefaultApplicationID   // the two constants
```

Use `Settings` (or `SZSettings`) for anything persistent. **Do not use `UserDefaults.standard`**:
it is the right domain only inside the app, and it ignores the override.

## 2. `Settings` — the typed facade

`enum Settings` (`Mac/App/Support/Settings.swift`) is Foundation-only, so it also compiles into
the test bundle and into an extension. Primitive helpers (`string`, `bool`, `boolPair`, `integer`,
`optionalInteger`, `sentinelInteger`, `stringArray`, `hasKey`, `removeKey`, `synchronize`) are
public; every write posts the notifications of section 4.

### 2.1 Encodings

| Windows shape | Swift shape | Rule |
|---|---|---|
| `CBoolPair {Def, Val}` | `Bool?` | `nil` = the key is absent (`Def == false`, "not forced" / "use the handler default"). Each tri-state key has a companion `…Value: Bool` giving the value the engine falls back to (`Key_Get_BoolPair` → false, `Key_Get_BoolPair_true` → true). Writing `nil` deletes the key. |
| `UInt32` with `-1` = auto | `Int` via `sentinelInteger` | `-1` is never stored: the key is removed instead, and a missing key reads back as `-1` (`Key_Set_UInt32`/`Key_Get_UInt32`). |
| `REG_DWORD` that may be absent | `Int?` via `optionalInteger` | absent = "not forced"; `0` is a real value. |
| `Dictionary` | `Int` + `Settings.DictionarySize` | `-1` = `.auto`, `-2` = `.atLeast4GB`, anything else = bytes. |
| `BlockSize` | `Int` + `Settings.BlockLogSize` | **log2** of the solid block size: `-1` = `.auto`, `0` = `.nonSolid`, `64` = `.solid`, `1…63` = `.log2(n)` (`.bytes` = `1 << n`). |
| string list (`REG_BINARY` blob) | `[String]` | stored as a CFArray of CFString; the facade trims to the Windows limits. |
| `REG_BINARY` `CListViewInfo` | `Settings.ColumnLayout` | JSON string (CFPreferences has no binary-blob idiom); fields unchanged. |

### 2.2 Key → property

`HKCU\Software\7-Zip` (01b §5.1)

| Key | Type | Default | Property |
|---|---|---|---|
| `Lang` | String | `""` = system language | `Settings.language` (`"-"` = built-in English, else a `Lang/*.txt` stem) |
| `LargePages` | — | — | not ported; `Settings.largePagesSupported` is `false` (01 §9 #16) |

`HKCU\Software\7-Zip\FM` (01b §5.2)

| Key | Type | Default | Property |
|---|---|---|---|
| `FM.Viewer` / `FM.Editor` / `FM.Diff` | String | `""` | `viewerPath` / `editorPath` / `diffPath` (empty removes the key; may be an `.app` bundle, an executable or a command line) |
| `FM.7vc` | String | `""` | `verCtrlPath` (read-only, as on Windows) |
| `FM.ShowDots` | Bool | false | `showDots` |
| `FM.ShowRealFileIcons` | Bool | false | `showRealFileIcons` |
| `FM.FullRow` | Bool | false | `fullRow` |
| `FM.ShowGrid` | Bool | false | `showGrid` |
| `FM.SingleClick` | Bool | false | `singleClick` |
| `FM.AlternativeSelection` | Bool | false | `alternativeSelection` |
| `FM.ShowSystemMenu` | Bool | false | `showSystemMenu` |
| `FM.Position` | String | absent | `windowFrame` (`NSStringFromRect`) |
| `FM.Maximized` | Bool | false | `maximized` |
| `FM.Panels.numPanels` | Int | 1 | `numPanels` (clamped 1…2) |
| `FM.Panels.currentPanel` | Int | 0 | `currentPanel` |
| `FM.Panels.splitterPos` | Double (stored as a string) | 0.5 | `splitterPos` (ratio 0…1) |
| `FM.Toolbars` | Int mask | `0x8000000D` | `toolbarsMask` (bit0 labels, bit1 large, bit2 standard, bit3 archive, bit31 defaults) |
| `FM.ListMode0/1` | Int | 3 (details) | `listMode(_:)` / `setListMode(_:_:)` |
| `FM.PanelPath0/1` | String | absent | `panelPath(_:)` / `setPanelPath(_:_:)` |
| `FM.FlatViewArc0/1` | Bool | false | `flatView(_:)` / `setFlatView(_:_:)` |
| `FM.FolderHistory` | [String] ≤ 100 | empty | `folderHistory`, `addToFolderHistory(_:)` |
| `FM.FolderShortcuts` | [String] = 10 slots | 10 × `""` | `folderShortcuts` (empty slot = unset) |
| `FM.CopyHistory` | [String] ≤ 20 | empty | `copyHistory`, `addToCopyHistory(_:)` |
| `FM.Columns.<FolderTypeID>` | JSON String | absent | `columnLayout(forFolderType:)` / `setColumnLayout(_:forFolderType:)` (01b §5.3) |
| `FM.AutoRefresh` | Bool | **true** | `autoRefresh` (not a Windows value) |
| `FM.TimestampShowUTC` | Bool | false | `timestampShowUTC` (not a Windows value) |
| `FM.TimestampLevel` | Int | `SZTimestampLevel.min` (-1) | `timestampLevel` (not a Windows value) |
| `FM.OptionsPage` | Int | 0 | `optionsLastPage` (not a Windows value: which Options tab to reopen) |
| `FM.Theme` | String | absent = `system` | `Settings.theme: AppTheme` (`system` / `light` / `dark`; macOS only, Options > macOS, `Support/AppTheme.swift`; written -> `NSApp.appearance` at once) |
| `FM.FirstLaunchIntegration` | Bool | absent | marker of `FirstLaunchIntegration` (macOS only: the first launch of an installed copy turned the Finder integration on) |

`HKCU\Software\7-Zip\Extraction` (01b §5.4)

| Key | Type | Default | Property |
|---|---|---|---|
| `Extraction.ExtractMode` | Int? | absent = not forced | `extractPathMode`, effective `extractPathModeValue` (= `kCurPaths`) |
| `Extraction.OverwriteMode` | Int? | absent = not forced | `extractOverwriteMode`, effective `extractOverwriteModeValue` (= `kAsk`) |
| `Extraction.ShowPassword` | Bool? | absent | `extractShowPassword`, `extractShowPasswordValue` (false) |
| `Extraction.SplitDest` | Bool? | absent | `extractSplitDest`, `extractSplitDestValue` (**true**) |
| `Extraction.ElimDup` | Bool? | absent | `extractElimDup`, `extractElimDupValue` (**true**) |
| `Extraction.Security` | Bool? | absent | `extractNtSecurity` (compatibility only, 01 §9 #7) |
| `Extraction.PathHistory` | [String] ≤ 16 | empty | `extractPathHistory`, `addToExtractPathHistory(_:)` |
| `Extraction.MemLimit` | Int GB, `-1` = none | `-1` | `extractMemLimitGB`, `extractMemLimitEnabled` |

`HKCU\Software\7-Zip\Compression` (01b §5.4)

| Key | Type | Default | Property |
|---|---|---|---|
| `Compression.ArcHistory` | [String] ≤ 20 | empty | `archiveHistory` |
| `Compression.Archiver` | String | `"7z"` | `archiverType` |
| `Compression.Level` | Int | 5 | `compressionLevel` |
| `Compression.ShowPassword` | Bool | false | `compressShowPassword` |
| `Compression.EncryptHeaders` | Bool | false | `compressEncryptHeaders` |
| `Compression.Security` / `AltStreams` | Bool? | absent | `compressNtSecurity` / `compressAltStreams` (compatibility only) |
| `Compression.HardLinks` / `SymLinks` / `PreserveATime` | Bool? | absent | `compressHardLinks` / `compressSymLinks` / `compressPreserveATime` |

Per format, `Compression.Options.<FormatID>.<name>` ↔ `Settings.FormatOptions`
(`formatOptions(_:)`, `setFormatOptions(_:)`, `formatOptionIDs`, `removeFormatOptions(_:)`,
`formatOptionKey(_:_:)`); `FormatID` is the engine format name (`7z`, `zip`, …):

| name | Type | `FormatOptions` field |
|---|---|---|
| `Method` | String | `method` (`""` = auto, key removed) |
| `Options` | String | `options` (the "Parameters" text) |
| `EncryptionMethod` | String | `encryptionMethod` |
| `MemUse64` | String | `memUse` (`"NN%"`, `"<N>M"`, `"<N>G"`; one key, macOS is 64-bit only) |
| `Level` | Int (`-1` = unset) | `level` |
| `Dictionary` | Int | `dictionary` / `dictionarySize` (`-1` auto, `-2` ≥ 4 GB, else bytes) |
| `Order` | Int (`-1`) | `order` |
| `BlockSize` | Int (**log2**) | `blockLogSize` / `blockSize` |
| `NumThreads` | Int (`-1`) | `numThreads` |
| `TimePrec` | Int (`-1`) | `timePrec` |
| `MTime` / `ATime` / `CTime` / `SetArcMTime` | Bool? | `mTime` / `aTime` / `cTime` / `setArcMTime` |

`HKCU\Software\7-Zip\Options` (01b §5.5)

| Key | Type | Default | Property |
|---|---|---|---|
| `Options.WorkDirType` | Int 0/1/2 | 0 (system temp) | `workDirMode` (`SZWorkDirMode`) |
| `Options.WorkDirPath` | String | `""` | `workDirPath` |
| `Options.TempRemovableOnly` | Bool | **true** | `workDirForRemovableOnly` |
| all three at once | | | `loadWorkDir()` / `saveWorkDir(_:)` — go through `NWorkDir::CInfo`, which also applies the "kSpecified with **no** path value → kSystem" fallback (an empty stored string keeps kSpecified) |
| `Options.CascadedMenu` | Bool? | absent | `cascadedMenu`, `cascadedMenuValue` (**true**) |
| `Options.MenuIcons` | Bool? | absent | `menuIcons`, `menuIconsValue` (false) |
| `Options.ElimDupExtract` | Bool? | absent | `elimDupExtract`, `elimDupExtractValue` (**true**) |
| `Options.WriteZoneIdExtract` | Int | `-1` | `writeZoneIdExtract` (`-1` unset/no, 0 no, 1 yes, 2 Office files only → `com.apple.quarantine`) |
| `Options.ContextMenu` | Int mask | absent = every item | `contextMenuFlags` (`Settings.ContextMenuFlags` OptionSet), `contextMenuFlagsDefined` |

`Settings.ContextMenuFlags` carries the `Explorer/ContextMenuFlags.h` bits:
`extractFiles 1<<0`, `extractHere 1<<1`, `extractTo 1<<2`, `test 1<<4`, `open 1<<5`,
`openAs 1<<6`, `compress 1<<8`, `compressTo7z 1<<9`, `compressEmail 1<<10`,
`compressTo7zEmail 1<<11`, `compressToZip 1<<12`, `compressToZipEmail 1<<13`,
`crcCascaded 1<<30`, `crc 1<<31`, and `.all` = `0xFFFFFFFF`.

`Settings.finderIntegrationSettings() -> [String: Any]` returns the five `Options.*` values the
Finder extension needs, keyed by the same names, for the `x-7zip:///settings` handshake
(03 §6.4).

## 3. `FileTypes` — the association list

`Mac/App/Support/FileTypes.swift` is plain data (Foundation + UniformTypeIdentifiers only), for
the `finder` scope to generate `CFBundleDocumentTypes` / `UTImportedTypeDeclarations` from, and
for the Options > System page.

```swift
struct SevenZipFileType {
    let ext: String            // lowercase, no dot: "7z", "tbz2", "001"
    let iconIndex: Int         // 0...26, the icon index inside 7z.dll
    let format: String         // SZCodecs format name that owns it ("7z", "Rar5", "bzip2", ...)
    var localizedDescription: String   // "<EXT> Archive" (the Windows ProgID title)
    var progID: String                 // "7-Zip.<ext>"
    var iconFileName: String           // CPP/7zip/Archive/Icons/<name>.ico
    var systemUTType: UTType?          // the declared system type, nil if macOS has none
    var importedTypeIdentifier: String // "org.7-zip.<ext>-archive" for the ones it has none for
    var utType: UTType?                // systemUTType ?? UTType(importedTypeIdentifier)
}
FileTypes.all          // [SevenZipFileType], in 7z.dll STRINGTABLE 100 order
FileTypes.extensions   // [String]
FileTypes.iconNames    // [Int: String], icon index -> .ico file name
FileTypes.type(forExtension:)   // case-insensitive
```

**The list has 40 extensions, not 39.** `03-shell-integration-inventory.md` section 3.1 and
`PROGRESS.md` section 7.2 say 39; the 26.03 resource string
(`CPP/7zip/Bundles/Format7zF/resource.rc:38`) holds 40 `ext:index` pairs, and the table in that
same section lists all 40. `FileTypes.all` is the resource verbatim:

```
7z:0 zip:1 rar:3 001:9 cab:7 iso:8 xz:23 txz:23 lzma:16 tar:13 cpio:12 bz2:2 bzip2:2 tbz2:2
tbz:2 gz:14 gzip:14 tgz:14 tpz:14 zst:26 tzst:26 z:5 taz:5 lzh:6 lha:6 rpm:10 deb:11 arj:4
vhd:20 vhdx:20 wim:15 swm:15 esd:15 fat:21 ntfs:22 dmg:17 hfs:18 xar:19 squashfs:24 apfs:25
```

`utType` is `nil` for an extension macOS does not declare **and** this app does not import yet
(`bzip2`, `tbz`, `tzst`, `001`, `swm`, `esd`, `taz`, `tpz`, …). The System page shows those rows
as not associable; adding the imported type declarations to `Mac/App/Info.plist` (the `finder`
scope) is what turns them on — no change here is needed, `utType` picks them up automatically.

## 4. Change notifications

Every write through `Settings` posts two notifications on `NotificationCenter.default`:

- `Settings.didChangeNotification` (`"SZSettingsDidChange"`) with
  `userInfo[Settings.keyUserInfoKey] as? String` = the settings key and
  `userInfo[Settings.groupUserInfoKey] as? Settings.Group` = its group;
- `group.notificationName` (`"SZSettings.<group>DidChange"`) with the same `userInfo`, so an
  observer can watch one group only.

`Settings.Group` (also `Settings.group(forKey:)`): `.language` (`Lang`), `.editor` (`FM.Viewer`,
`FM.Editor`, `FM.Diff`, `FM.7vc`), `.fm` (the seven `CFmSettings` booleans — the "SetListSettings"
group), `.view` (every other `FM.*`), `.extraction`, `.compression`, `.workDir`
(`Options.WorkDir*`, `Options.TempRemovableOnly`), `.contextMenu` (the other `Options.*`).

A language switch also posts `Settings.Group.language.notificationName` **before** the `Lang` key
is written, because the Options > Language page applies the switch live.

## 5. Opening the window, and what runs after it applies

```swift
OptionsWindowController.showOptions()   // Tools > Options, IDM_OPTIONS 900
```

`MainWindowController.toolsOptions(_:)` (in `Mac/App/Commands/OptionsCommands.swift`) already
implements the menu selector; no other scope needs to wire it.

`OptionsPostApply` mirrors `OptionsDialog.cpp:31-50`:

- `settingsApplied(languageChanged:)` — posts the `.fm` group notification and reloads every
  panel (`SetListSettings` + `RefreshAllPanels`);
- `reloadLangItems()` — rebuilds `NSApp.mainMenu` and re-creates every window's toolbar items so
  they take the new lang file (`MyLoadMenu(true)`, `ReloadToolbars`, `ReloadLangItems`);
- `allPanels()` — every `PanelViewController` of every window, found through the view hierarchy.

To add a page, subclass `OptionsPageBase` (`pageID` = the `IDD_*` id and the lang id of the tab
title, `fallbackTitle` = the `.rc` caption, `helpTopic`, `pageDidLoad`, `applyPage() -> Bool`,
`cancelPage`, `relabelPage`, and `changed()` when a control changes) and add it to the `pages`
array in `OptionsWindowController.buildContent()`. `OptionsUI` has the control factory
(`label`, `colonLabel`, `note`, `checkbox`, `radio`, `button`, `browseButton`, `textField`,
`vstack`, `hstack`, `scrollTable`, `column`).

## Note — 2026-10-03 (`mac/optgaps`)

Appended; the sections above still hold except where this note says so.

* **Preferences domain (§1).** Without `SEVENZIP_DEFAULTS_SUITE` the domain is now
  `NMacPrefs::DefaultApplicationID()` = the running application's bundle identifier (main bundle of
  package type `APPL`), else `com.yrambler2001.7zip` (the xctest runner, the extensions). The shipping
  app's identifier is that constant, so nothing moves for users. `SZSettings.defaultApplicationID`
  reports it; `usesOverrideSuite` now means "the variable is set to another domain than that".
* **Page layout (§5).** `OptionsPageBase.install` caps every wrapping label at
  `OptionsUI.wrappingLabelWidth` (520 pt) and `viewDidLayout` re-tells a narrower label its real width;
  a page added later gets this for free. `OptionsUI.sizeColumnsToContent(_:texts:extra:)` sizes a
  table's columns to header + widest cell, last column elastic. The window is 660 × 580.
* **System page.** `OptionsSystemPage.formatIcon(for:)` (the `doc-<name>.icns` image, cached);
  `toggleRow(_:column:)` is NM_CLICK's body; `associationsDidChange()` is the SHCNE_ASSOCCHANGED step
  (`lsregister -f` + `NSUpdateDynamicServices`, Services only under `SZ_TEST_SUPPORT`), with
  `launchServicesRefreshCount` for tests. `OptionsAssociationTableView.onKey` also takes Return.
* **Language page / `SZLang`.** `SZLanguageInfo.comments`, `.missingLines`, `.extraLines`
  (`"<id> : <text>"`, LangPage.cpp:197-245); `SZLang.failedLanguageFiles`;
  `SZLang.languages(inDirectory:failedFiles:)` for any directory. `OptionsLanguagePage.langInfoText`
  is ShowLangInfo; `entries` and `reportedLoadErrors` are readable for tests.
* **`OptionsPostApply.reloadLangItems()`** skips windows that are neither visible nor miniaturized.

## Options > macOS (theme scope)

`OptionsMacPage` (`Mac/App/Dialogs/OptionsMacPage.swift`) is a seventh, macOS-only page after
Language (pageID 0, title "macOS"), laid out from its own DLU template with `RcPlace`
(`RcDialog(template:)`). It holds the Theme drop-down (`FM.Theme`, lang IDs 9900-9903, "System"
falls back to 2200) and a "Show grid lines" checkbox bound to `FM.ShowGrid`, the same value as the
Settings page's IDX_SETTINGS_SHOW_GRID 2505; the two checkboxes mirror each other through
`OptionsGridLines.toggled` while the sheet is open. See `reports/theme.md`.
