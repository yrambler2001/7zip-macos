# Architecture of the macOS port

Companion to `00-orchestration.md`. Inventories: `01-fm-feature-inventory.md`, `01b-fm-dialogs-settings.md`, `02-engine-api.md`, `03-shell-integration-inventory.md`, `04-toolchain.md`. The scaffold agent appends an "As built" section at the end; later agents keep it current.

## Targets (`Mac/project.yml`, XcodeGen)

| Target | Kind | Language | Contents |
|---|---|---|---|
| `SevenZipCore` | static library | C, C++, arm64 asm | The 7zz source set minus the 11 Console files (`02-engine-api.md` §1, §4.1), the patched `UI/Agent` files, portable `UI/Common` extras (`WorkDir`, `ArchiveName`, `StringUtils`, `TextPairs`, `SplitUtils`), `Common/Lang.cpp`, plus `Mac/Core/Platform/*` providing the link-time obligations listed in `02-engine-api.md` §4.3 (`CompareFileNames_ForFolderList`, `SetExtractErrorMessage`, `NWorkDir::CInfo` and the other `ZipRegistry` accessors, `MyLoadString`, one TU including `MyInitGuid.h`). Compiled with the 7zz defines (no `-Weverything -Werror`), `Z7_LZMA_DEC_OPT` on `LzmaDec.c`, `LzmaDecOpt.S` arm64 only. |
| `SevenZipKit` | framework | Objective-C++ (`.mm`) with pure Objective-C public headers | The bridge. Swift sees only the headers in `Mac/Core/include/`. No C++ types leak. |
| `7-Zip` | app | Swift, AppKit | Everything the user sees. Non-sandboxed (it is a file manager). Also implements the 7zG command grammar and the URL-scheme command channel. |
| `FinderSync` | appex `com.apple.FinderSync` | Swift | Context menu and toolbar menu in Finder. Sandboxed; forwards commands to the app via the URL scheme. |
| `SevenZipKitTests` | XCTest | Swift/ObjC++ | Bridge unit tests against fixture archives in `Mac/Tests/Fixtures/`. |
| `7-ZipUITests` | XCUITest | Swift | Smoke tests of the main window and key dialogs. |

Build settings shared by all targets: `MACOSX_DEPLOYMENT_TARGET 14.0`, `SWIFT_VERSION 5.9`, `CODE_SIGN_STYLE Manual`, `CODE_SIGN_IDENTITY "-"`, empty `DEVELOPMENT_TEAM` (overridable from the command line for Developer ID), `OTHER_LDFLAGS -lc++` on targets linking `SevenZipCore`. Follow every gotcha in `04-toolchain.md`.

## Upstream patches

Only the minimal `#ifdef _WIN32` / `__APPLE__` guards documented in `02-engine-api.md` §4.2 (Agent.h, Agent.cpp, AgentOut.cpp, ArchiveFolderOut.cpp, UpdateCallbackAgent.cpp, ArchiveFolderOpen.cpp, SplitUtils.*, Windows/ResourceString.h). Every patch is listed in `Mac/docs/upstream-patches.md` with a one-line reason. Nothing else in `C/`, `CPP/`, `Asm/` changes.

## SevenZipKit bridge (Objective-C API consumed by Swift)

Naming: prefix `SZ`. Errors are `NSError` in domain `SZErrorDomain` carrying the HRESULT and the engine message. Every blocking engine call is exposed twice: a synchronous method (documented "call off the main thread") and no completion-handler variant; Swift wraps them in its own async layer. Callbacks are delegate protocols, invoked on the engine's worker thread; the app marshals to main.

Core objects:

- `SZCodecs` (singleton): formats (name, extensions, flags: update-capable, multi-file, encryption, etc.), `SZCodecs.load()` at startup, lookup by extension/signature.
- `SZFolder`: wraps one `IFolderFolder` plus its optional interfaces (`IFolderOperations`, `IFolderGetItemName`, `IFolderCalcItemFullSize`, `IFolderWasChanged`, `IFolderSetFlatMode`, `IArchiveFolder`, `IFolderArchiveUpdate`, `IFolderArcProps`, `IFolderProperties`, `IFolderClone`, `IFolderCompare`). Methods: `bindToPath`, `bindToFolder(index)`, `parent`, `items` (count, property by `PROPID`, all columns declared by the folder), `isArchive`, `arcProps`, `createFolder`, `createFile`, `rename`, `delete`, `setComment`, `copyTo/copyFrom` (with `SZOperationDelegate`), `extract` (for archive folders, all `NExtract` path/overwrite modes), `flatMode`, `wasChanged`.
- `SZRootFolder`: the Computer/Volumes/home/Documents virtual root (Windows `RootFolder` + `FSDrives`), listing mounted volumes from `/Volumes` with kpidType/size/free space.
- `SZFileSystemFolder`: the macOS replacement for `FSFolder`/`FSFolderCopy`, implemented in C++ against the portable `NWindows::NFile` layer: listing with all FM columns, FSEvents-based change notification, copy/move with progress and overwrite callbacks, trash via `NSFileManager.trashItem`, calc-size, flat mode, opening archives inside via `SZCodecs`.
- `SZArchiveOpener`: open an archive file (with `SZPasswordDelegate`, volumes, format hint) into an `SZFolder`; also `reopen`.
- `SZExtractor`: the `ExtractGUI` equivalent over `UI/Common/Extract.cpp`: extract many archives to a directory with `SZExtractOptions` (path mode, overwrite mode, password, elimination of duplicate root, `-spe`, `-snl`, etc.) reporting through `SZProgressDelegate`.
- `SZUpdater`: the `UpdateGUI` equivalent over `UI/Common/Update.cpp`: add/update/delete with `SZUpdateOptions` (every Compress dialog option, `-m` parameters, volumes, SFX stub path, delete-after, email temp dir), reporting through `SZProgressDelegate`.
- `SZHasher`: `HashCalc` over files and folders for every hash method, results as ordered lines identical to 7zG's hash dialog.
- `SZBenchmark`: `Bench` with dictionary size, thread count, iterations, live per-pass results.
- `SZLang`: loader for `Lang/*.txt` with the positional rules from `01-fm-feature-inventory.md` §7 and the built-in English table generated from `en.ttt`. `SZLang.string(id)` and `string(id, fallback)`. Language switch reloads.
- `SZSettings`: the C++ `ZipRegistry` accessors backed by `CFPreferences` in the app's domain, keys named after the Windows registry values (`01b-fm-dialogs-settings.md` §5), so the engine-side defaults and the Swift settings UI read the same values.
- `SZTempFiles` / `SZWorkDir`: work-dir policy (system temp, current, specified, only-for-removable), temp folders `7zO*/7zE*`.
- `SZProgressDelegate`: `setTotal`, `setCompleted`, `setRatioInfo`, `setCurrentFile(path, isDir)`, `setNumFilesProcessed`, `askOverwrite` (returns `SZOverwriteAnswer`), `askPassword`, `showMessage`, `setOperationResult(kind, path)`, `checkBreak` (pause blocks here, cancel returns `E_ABORT`). Pause is implemented by blocking the worker in `checkBreak` on a condition variable, exactly like `CProgressSync`.

Threading: one serial `DispatchQueue` per panel for folder operations; one per long operation (extract/update/hash/bench/copy). The engine's COM refcounts are not atomic, so an `SZFolder` is owned by one queue only. UI code never blocks the main thread on engine calls.

## App structure (`Mac/App/`)

```
App/            AppDelegate, MainMenu (built in code, every IDM item with its Windows ID in a comment, actions on the responder chain), CommandLine (7zG grammar: a x e t h b + switches), URLCommands (sevenzip:// scheme), DocumentOpening (CFBundleDocumentTypes), Services (NSServices handlers)
MainWindow/     MainWindowController (toolbar: Add Extract Test Copy Move Delete Info; 1 or 2 panels in an NSSplitView; status bar), window/panel state persistence
Panel/          PanelViewController (path combobox with history, NSTableView details view, NSCollectionView for large/small icons and list modes, sort, selection, keyboard map from §3, folder history, favorites, drag and drop incl. NSFilePromiseProvider, clipboard, timers, item open with temp folder and watcher)
Dialogs/        one file per dialog: Compress, Extract, Progress, Overwrite, Password, CopyMove, Properties, Comment, Split, Combine, Link, HashResults, Benchmark, Messages, About, Options (tabs: System, Plugins, Folders, Editor, Settings, Language, Menu), Browse (NSOpenPanel wrapper), ListView, Combo, Edit
Support/        Lang (Swift facade over SZLang), Settings (UserDefaults keys), Icons (NSWorkspace icons for extensions), Formatting (sizes, dates matching FM), TempFiles
```

Menu items whose action selector has no implementation yet are auto-disabled by AppKit; implementation agents add `@objc` actions in their own files (Swift extensions) instead of editing shared files, so parallel work does not conflict.

## Finder integration (`Mac/FinderSync/`, app-side `Integration/`)

- Finder Sync extension monitors `/`, `/Volumes`, `~/Library/CloudStorage`; builds the exact 7-Zip menu (`03-shell-integration-inventory.md` §1, §6) for the selection; toolbar item with the same menu; sends `sevenzip://` URLs with the command and file list (a temp list file for long selections) to the app.
- App handles URL commands and argv identically through `CommandLine`, showing only the dialogs 7zG would (Compress/Extract dialog when `-ad`, progress otherwise, hash results, test statistics).
- `NSServices` in the app Info.plist provide the same commands without the extension enabled.
- `CFBundleDocumentTypes` + UTI declarations for all 39 associated extensions; Options > System sets defaults via `NSWorkspace.setDefaultApplication(at:toOpen:)`.
- "Compress and email" via `NSSharingService.composeEmail`.
- Dragging items out of an archive to Finder via `NSFilePromiseProvider` with lazy extraction.

## Verification

Fixtures: `Mac/Tests/Fixtures/` with small archives in several formats created by the built `7zz` (script `Mac/scripts/make-fixtures.sh`). Unit tests cover the bridge. UI automation uses XCUITest and `osascript`; screenshots go to `Mac/docs/reports/screenshots/`.

## As built (Wave 1 scaffold, branch `mac/scaffold`)

Code against these names; do not read the sources.

### SevenZipKit public API (`Mac/Core/include/`, `import SevenZipKit`)

- `SZTypes.h`: `SZPropID` (all `kpid*`, Swift names `.name .size .mtime .ctime .atime .attrib .crc .isDir .packSize ...`), `SZVarType`, `SZTimestampLevel` (`.day .min .sec .NTFS .NS`), `SZExtractPathMode`, `SZOverwriteMode`, `SZOverwriteAnswer`, `SZOperationResult`, `SZAskMode`.
- `SZError.h`: `SZErrorDomain`, `SZErrorCode` (Swift `SZError.Code.*`: `.engine .cancelled .outOfMemory .notImplemented .invalidArgument .notArchive .passwordRequired .wrongPassword .codecsNotLoaded .fileNotFound .notFolder .unsupported`), userInfo keys `SZErrorHRESULTKey`, `SZErrorEngineMessageKey`; helper class `SZErrors` (`errorWithCode:message:`, `errorWithHRESULT:message:`, `messageForHRESULT:`).
- `SZCodecs`: `loadCodecs()` (throws), `isLoaded`, `unload()`, `formats: [SZFormatInfo]`, `formatCount`, `format(forExtension:)`, `format(forArchiveName:)`, `format(named:)`, `allExtensions`. `SZFormatInfo`: `index name extensions addExtensions mainExtension updateEnabled isHashHandler keepName findSignature supportsAltStreams supportsNtSecurity supportsSymLinks supportsHardLinks useGlobalOffset startOpen backwardOpen preArc pureStartOpen byExtOnlyOpen supportsCTime/ATime/MTime flags timeFlags signatureCount`.
- `SZFolder` (owned by one serial queue): `SZFolder.folder(forPath:passwordDelegate:)` (walks into archives, "" = root), `loadItems()`, `itemCount`, `nameOfItem(at:)`, `prefixOfItem(at:)`, `sizeOfItem(at:)`, `isDirectory(at:)`, `propertyOfItem(at:propID:) -> Any?` (String/NSNumber/Date), `varTypeOfItem(at:propID:)`, `displayStringOfItem(at:propID:timestampLevel:)`, `properties: [SZPropertyInfo]` (`propID varType handlerName localizedName`), `folderProperty(forID:)`, `folderType` ("FSFolder" / "RootFolder" / "FSDrives" / "7-Zip.<type>"), `path`, `fullPath`, `isArchive isFileSystem isRootFolder isReadOnly`, `archive: SZArchive?`, `arcProps: SZArcProps?`, `bindToFolder(at:)`, `bindToFolder(named:)`, `bindToPath(_:passwordDelegate:)`, `bindToParentFolder()` (archive root -> outer folder; root -> root), `supportsFlatMode`, `flatMode`, `supportsChangeNotification`, `wasChanged`, `supportsCompare`, `compareItem(at:with:propID:)`, `SZFolder.compareFileName(_:with:)`, `SZFolder.timestampShowUTC`. `SZArcProps`: `levelCount`, `properties(atLevel:)`, `property(atLevel:propID:)`, `displayString(atLevel:propID:)`, `properties2(atLevel:)`, `property2(atLevel:propID:)`.
- `SZFileSystemFolder: SZFolder`: `folder(withPath:)`, `directoryPath`, `fullPathOfItem(at:)`, `defaultHiddenPropIDs`. Columns Name, Size, Modified, Created (birth time), Accessed, Attributes; FSEvents-backed `wasChanged`; `IFolderOperations` stubbed (E_NOTIMPL) in `Mac/Core/Internal/FSFolderMac.cpp`.
- `SZRootFolder: SZFolder`: `makeRootFolder()` (Computer "/", Volumes, Home, Documents), `makeVolumesFolder()` (FSDrives: Name, Total Size, Free Space, Type, Label, File System, Cluster Size from `statfs`), `rootEntryNames`.
- `SZArchiveOpener`: `openArchive(atPath:formatHint:passwordDelegate:)`, `openArchive(in:itemIndex:formatHint:passwordDelegate:)` (stream via `IInArchiveGetStream`, else temp extraction into a `7zO-*` dir like 7zFM). `SZArchive`: `path type errorMessage outerFolder outerItemIndex isReadOnly tempDirectory arcProps`, `rootFolder()`, `reopen()`, `close()`. `SZPasswordDelegate`: `passwordForArchive(atPath:) -> String?` (engine thread; nil = cancel; no delegate -> `.passwordRequired`).
- `SZLang.shared`: `string(forID:)`, `string(forID:fallback:)`, `translatedString(forID:)` (lang file only), `englishString(forID:)` (en.ttt + PropertyName.rc-only names), `loadLanguage(code:)` ("" system, "-" English), `loadLanguageFile(_:)`, `currentLanguageCode`, `comments`, `availableLanguages: [SZLanguageInfo]` (`code path englishName nativeName stringCount`), `SZLang.langDirectoryPath`, `englishStringCount` (444), `SZLang.systemLanguageCandidates`. Also installs the `MyLoadString` hook for the engine.
- `SZSettings` (CFPreferences, domain `com.yrambler2001.7zip`, same as `UserDefaults.standard`): `string(forKey:)`/`setString(_:forKey:)`, `integer(forKey:defaultValue:)`/`setInteger`, `double`/`setDouble`, `bool(forKey:defaultValue:)`/`setBool`, `boolPair(forKey:)`/`setBoolPair` (nil = undefined), `stringArray`/`setStringArray`, `hasKey`, `removeKey`, `keys(withPrefix:)`, `synchronize`, `applicationID`; key constants `SZSettingsKey*` (`Lang`, `FM.Position`, `FM.Panels.numPanels/currentPanel/splitterPos`, `FM.PanelPath0/1`, `FM.ListMode0/1`, `FM.FlatViewArc0/1`, `FM.FolderHistory`, `FM.FolderShortcuts`, `FM.Toolbars`, ...). `SZWorkDirSettings`: `loadFromSettings()`, `save()`, `mode path forRemovableOnly` (backs `NWorkDir::CInfo`). Engine-side `NExtract/NCompression/NWorkDir/CContextMenuInfo` accessors use keys `Extraction.*`, `Compression.*`, `Compression.Options.<Format>.*`, `Options.*`.
- `SZProgressDelegate` protocol (unused yet): `progressSetTotal:`, `progressSetCompleted:`, `progressSetRatioInfoInSize:outSize:`, `progressSetCurrentFile:isDirectory:`, `progressSetNumFilesProcessed:`, `progressAskOverwriteExisting:...suggestedName:`, `progressAskPasswordForPath:`, `progressShowMessage:`, `progressSetOperationResult:path:isEncrypted:`, `progressCheckBreak`.
- `SZEngineVersionString()`, `SZEngineCopyrightString()`.

Internals: engine headers enter `.mm` files only via `Mac/Core/Internal/SZEngine.h` (renames `BOOL`); `SZBridgeUtils.h` (string/PROPVARIANT/HRESULT conversions, `SZRunCatching` exception ladder); `SZFolder+Internal.h` (raw `IFolderFolder` access, internal initializers). Platform layer in `Mac/Core/Platform/` (part of `SevenZipCore`).

### App layout (`Mac/App/`)

- `AppDelegate.swift` (`main()`, lang + codecs at launch, `[path] [-t<type>]` argv)
- `MainMenu.swift` (every §2 item with IDM comments; `@objc protocol MenuActions` lists every selector: `fileOpen fileOpenInside ... fileExit editSelectAll ... viewTwoPanels ... favoritesSetBookmark favoritesOpenBookmark toolsOptions toolsBenchmark toolsDeleteTempFiles helpContents helpAbout toolbarAddToArchive toolbarExtractArchives toolbarTestArchives`; unimplemented ones are disabled)
- `MainWindow/MainWindowController.swift` (toolbar Add/Extract/Test/Copy/Move/Delete/Info, split view, 1/2 panels, persistence, favorites, toolbar toggles, auto-refresh timer, About)
- `Panel/PanelViewController.swift` (address bar, details table, status bar, navigation, sort, password prompt), `Panel/PanelTableView.swift` (Enter/Backspace/`\` keys), `Panel/PanelRow.swift` (row model + snapshot)
- `Support/Lang.swift`, `Support/Settings.swift`, `Support/Formatting.swift`, `Support/Icons.swift`
- `Mac/FinderSync/FinderSync.swift` (stub appex), `Mac/Tests/SevenZipKitTests/` (17 tests), `Mac/Tests/Fixtures/` (make-fixtures.sh)

Implement menu commands in later waves as `extension MainWindowController` / `extension PanelViewController` in new files.
