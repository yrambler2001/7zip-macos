# `compress` scope — public API

What other scopes may use from `mac/compress`: the update bridge (`SZUpdater`), the Compress
dialog and its Options sheet, the computation model behind them, and the commands. The
`finder` scope needs section 5 for its context-menu commands; the `panel` scope needs
section 6 for drag-into-an-archive.

Sources: `Mac/Core/include/SZUpdater.h`, `Mac/Core/SZUpdater.mm`,
`Mac/App/Dialogs/CompressModel.swift`, `CompressDialog.swift`, `CompressOptionsSheet.swift`,
`CompressDemo.swift`, `Mac/App/Commands/CompressCommands.swift`.

Parity references: `01b-fm-dialogs-settings.md` sections 4.23 (Add to Archive) and 4.24
(Compress Options); `01-fm-feature-inventory.md` sections 8.1, 8.5, 8.7;
`03-shell-integration-inventory.md` sections 1.6, 2.2-2.5; `02-engine-api.md` section 2.3.

---

## 1. Threading in one paragraph

`SZUpdater`'s methods **block** for the whole operation and must run **off the main thread**;
while they block, the engine calls the `id<SZProgressDelegate>` they were given on that same
worker thread. Drive them with `OperationRunner` (`Mac/docs/api/opsinfra.md` section 5), which
is itself the delegate, owns the Progress dialog, and answers the password question. The
dialog and sheet controllers are main-thread only and run their own modal session.

---

## 2. `SZUpdater` (ObjC, `SevenZipKit`)

`UpdateGUI.cpp` minus the dialog, on top of the engine's own `UpdateArchive()`
(`CPP/7zip/UI/Common/Update.cpp`) — the same function 7zG runs, so behaviour matches the
Windows product instead of being reimplemented.

```swift
// Create or update `options.archivePath` from file-system paths (directories are recursed).
let result = try SZUpdater.update(with: options, sourcePaths: paths, progress: runner)

// Add to an existing archive in place, keeping its format (exact name mode, no volumes).
let result = try SZUpdater.addPaths(paths, toArchiveAt: archivePath, options: nil, progress: runner)

// Delete entries from an archive: the console `d` command (k_ActionSet_Delete).
let result = try SZUpdater.deleteItems(named: ["a.txt", "sub/*"], fromArchiveAt: archivePath,
                                       options: nil, progress: runner)

// The bundled Windows SFX stubs (Mac/Resources/SFX in the app bundle's Resources).
SZUpdater.defaultSFXModulePath                 // .../SFX/7z.sfx, nil when missing
SZUpdater.sfxModulePath(named: "7zCon.sfx")

// CreateArchiveName (UI/Common/ArchiveName.cpp, 03 section 1.6). `baseName` receives the name
// without the `_<N>` collision suffix.
var base: NSString?
let name = SZUpdater.archiveBaseName(forItemPaths: paths, isHash: false, baseName: &base)

SZUpdater.formatSupportsUpdate("7z")           // CArcInfoEx::UpdateEnabled
```

Failures are `NSError` in `SZErrorDomain` with the `SZError.Code` values: `.cancelled` for
`E_ABORT`, `.unsupported` when the handler cannot create archives
("Update operations are not supported for this archive."), `.notImplemented` for volumes +
email, `.fileNotFound` when the SFX stub is missing, `.engine` otherwise.

### 2.1 `SZUpdateOptions`

One-to-one with `CUpdateOptions` plus the dialog's option set. Tri-states are `NSNumber?`
(nil = "not specified, leave the handler default", i.e. `CBoolPair::Def == false`).

| Property | Windows | Notes |
|---|---|---|
| `archivePath` | `ArchivePath` | full path **with** extension |
| `formatName` / `formatIndex` | `-t` / `MethodMode.Type.FormatIndex` | index wins; -1/empty derives it from the path (`FindFormatForArchiveName`) |
| `properties: [SZUpdateProperty]` | `MethodMode.Properties` | the `-m` list, already in emission order |
| `updateMode: SZUpdateMode` | `-u` action set | `.add .update .fresh .sync .delete` |
| `pathMode: SZCompressPathMode` | `-spf` | `.relative .full .absolute` |
| `nameMode: SZArchiveNameMode` | `-saa` / `-sae` | `.smart .exact .add` |
| `sfxMode`, `sfxModulePath` | `-sfx` | `BaseExtension` becomes `"exe"` (the engine's own `kSFXExtension` is `""` off Windows) |
| `volumeSizes: [NSNumber]` | `-v` | empty = one archive |
| `password`, `asksPassword` | `-p` | `asksPassword` = `-p` with no value: the delegate's `progressAskPassword(forEncryptionCancelled:)` is used |
| `deleteAfterCompressing` | `-sdel` | |
| `setArchiveMTime` | `-stl` | |
| `openShareForWrite` | `-ssw` | |
| `stopAfterOpenError` | `-sse` | |
| `preserveATime` | `-ssp` | tri-state |
| `storeSymLinks` / `storeHardLinks` / `storeAltStreams` / `storeNtSecurity` | `-snl` / `-snh` / `-sns` / `-sni` | tri-state; the last two are Windows-only concepts, kept so the settings round-trip |
| `workingDirectory` | `WorkingDir` | nil = the Options > Folders policy (`NWorkDir::CInfo` + `GetWorkDir` + `CreateComplexDir`); `""` = the archive's own folder |
| `emailMode`, `emailRemoveAfter`, `emailAddress` | `-seml` | the bridge only *creates* the archive; sending it is the app's job |

### 2.2 `SZUpdateProperty`

`+propertyWithName:value:` → Swift `SZUpdateProperty(name:value:)`; `switchText` renders
`name=value` (or just `name`) the way `7z -m…` spells it, which is what the tests compare
against the console.

### 2.3 `SZUpdateResult`

`archivePath` (as the engine resolved it — `GetFinalVolPath` for a volume set),
`archiveSize`, `volumeCount`, `isMultiVolume` (`CFinishArchiveStat`), `filesProcessed`,
`scannedFileCount`, `scannedTotalSize`, `errorCount`, `failedPaths`
(`CUpdateCallbackGUI::FailedFiles` — a non-empty list is 7zG's exit code 1 / `kWarning`),
`passwordWasAsked`, `password`, `deletedPaths` (what `-sdel` removed).

### 2.4 What arrives on the delegate

`CSZUpdateUICallback` (inside `SZUpdater.mm`) implements `IUpdateCallbackUI2` and
`IOpenCallbackUI` and mirrors `CUpdateCallbackGUI`/`CUpdateCallbackGUI2` call for call:

* `StartScanning` → status `.scanning` (3304); `ScanProgress`/`FinishScanning` →
  `progressScanFolders(_:files:totalSize:path:isDirectory:)`; `ScanError` → the error list
  **and** `failedPaths`;
* `StartArchive` → status `.compressing` (3301) + `progressSetTitleFileName`;
* `GetStream` / `ReportUpdateOperation` → the `NUpdateNotifyOp` → lang-ID status map
  (`.add` 3320 … `.header` 3327) plus `progressSetCurrentFile`;
* `SetNumItems` → `progressSetTotalFiles`; `SetTotal`/`SetCompleted`/`SetRatioInfo` → the
  usual three;
* `OpenFileError` (returns `S_FALSE`: list and skip) and `ReadingFileError` → the error list
  and `failedPaths`; `ReportExtractResult` → `SetExtractErrorMessage`;
* `CryptoGetTextPassword2` → `progressAskPassword(forEncryptionCancelled:)` (nil +
  `cancelled == false` means "no password"); `Open_CryptoGetTextPassword` →
  `progressAskPassword(forPath:)`;
* `DeletingAfterArchiving` → status `.removing` (3305) + `deletedPaths`;
* `MoveArc_Start/Progress/Finish` → `progressMoveArchive…`;
* `WriteSfx` → the stub as the current file (there is no lang ID for the literal "WriteSfx"
  status Windows shows);
* every entry point polls `progressCheckBreak` first, so Cancel and Pause work everywhere.

---

## 3. `CompressDialogResult` — a prepared option set

`Mac/App/Dialogs/CompressModel.swift`. This is the struct another scope fills in (or takes
from the dialog) and hands to the bridge; it owns the `-m` emission order.

```swift
var r = CompressDialogResult()
r.archivePath = "/tmp/a.7z"
r.formatName = "7z"
r.formatIndex = SZCodecs.format(named: "7z")!.index
r.level = 9
r.method = "LZMA2"                 // "" = the auto item, nothing emitted
r.dictionary = 64 << 20            // nil = auto
r.solidBlockSize = 1 << 24         // nil = not specified; 0 = non-solid; UInt64.max = solid
r.numThreads = 4
r.parameters = "-mhc=off"          // the free "Parameters" text
r.password = "secret"
r.encryptHeadersIsAllowed = true; r.encryptHeaders = true

r.properties                       // [SZUpdateProperty] in the documented order
r.parameterTokens                  // SplitOptionsToStrings
r.hasMethodOverride                // IsThereMethodOverride
let options = r.updateOptions()    // ready for SZUpdater.update(with:sourcePaths:progress:)
```

Emission order (`SetOutProperties` + `ParseAndAddPropertires`, 01b section 4.23 "Parameter
generation"): `x=<level>`; then, unless the Parameters text overrides the method,
`0=`/`m=` method, `0d=`/`d=` (`0mem`/`mem` for PPMd), `0fb=`/`fb=` (`0o`/`o` for PPMd); then
`em=`, `he=on|off`, `s=<bytes>b`, `mt=<N>`, `memuse=<NN>%`|`<bytes>b`, `tm`/`tc`/`ta`,
`tp=<N>`; then the Parameters tokens with a leading `-m` stripped (later duplicates win).

Also public and useful on their own:

| Type | What it is |
|---|---|
| `CompressStaticFormat` | one `g_Formats[]` entry: `name levelsMask methods flags levels`; `.forFormatName(_:)` falls back to entry 0 like `GetStaticFormatIndex` |
| `CompressFormatFlags` | `kFF_Filter/Solid/MultiThread/Encrypt/EncryptFileNames/MemUse/SFX` |
| `CompressMethodID` | `EMethodID` with `kMethodsNames`, `isSupportedBySFX`, `usesOrderMode` |
| `CompressModel` | the live dialog state: the item-list builders (`levelItems` `methodItems` `dictionaryItems` `orderItems` `solidItems` `threadItems` `memUseItems`), the auto values (`autoDictionary` `autoOrder` `autoSolidBlockSize` `autoNumThreads`), `memUseLimitBytes`, `memoryEstimate`, `memoryUsageText`, `encryptionMethodItems` |
| `CompressMemUse` | `NCompression::CMemUse::Parse` + `propertyValue` |
| `CompressVolumes` | `presets` (the Split dialog's nine), `parse(_:)` = `ParseVolumeSizes`, `count(forSize:volumeSizes:)` |
| `CompressTimePrecision` | `win/unix/dos/ns1` + `propVarBase` 16 … `propVarMax` 25, `title(_:secText:nsText:)` = `AddPrec`, `available(timeFlags:defaultPrecision:)`, `defaultPrecision(timeFlags:isGZip:)` |

`CompressModel` is AppKit-free on purpose so it compiles into the test bundle
(`Mac/Tests/SevenZipKitTests/CompressModel.swift` is a symlink, like `Settings.swift`).

---

## 4. The dialogs

```swift
var input = CompressDialogInput()
input.directoryPrefix = "/Users/me/Documents/"   // DirPrefix, shown in the folder line
input.archiveBaseName = "/Users/me/Documents/Archive"   // Info.ArcPath, no extension
input.itemPaths = paths                          // decides `oneFile` -> the KeepName formats
input.forcedFormatName = "7z"                    // -t; also lets hash handlers into the list
input.password = nil                             // -p
input.updateMode = .add                          // -u
input.pathMode = .relative                       // -spf
input.sfxMode = false                            // -sfx
input.parentWindow = window
let result: CompressDialogResult? = CompressDialogController.run(input)   // nil = Cancel
```

`CompressOptionsSheet.run(_:parent:)` is the Options sheet; the dialog drives it, and its
`State` is the exchange struct (`CBool1` / `CBoolBox` on Windows).

The dialog writes, at OK: `Compression.Archiver`, `Compression.ShowPassword`,
`Compression.EncryptHeaders`, `Compression.SymLinks`/`HardLinks`/`AltStreams`/`Security`/
`PreserveATime`, `Compression.ArcHistory` (new path first, max 20) and every touched
`Compression.Options.<Format>.*` group through the `options` scope's `Settings` facade.

---

## 5. Commands (what the `finder` scope calls)

```swift
// `CPanel::AddToArchive`: the dialog over the active panel's selection.
CompressCommands.addToArchive(showDialog: true, email: false, forcedFormatName: nil)

// The Explorer quick commands: <CreateArchiveName>.<ext> in the current folder, no dialog.
CompressCommands.compressTo(formatName: "7z", email: false)
CompressCommands.compressTo(formatName: "zip", email: true)

// Run a prepared option set (e.g. from a saved profile or a URL command).
CompressCommands.run(result, sourcePaths: paths, email: false, context: context)

// Hand a finished archive to the system mail composer (SendMailAttachment's replacement).
CompressCommands.compose(email: archivePath, address: nil)
CompressCommands.makeEmailDirectory()            // a fresh 7zE-<uuid> temp folder
CompressCommands.purgeStaleEmailDirectories()    // EMailRemoveAfter, deferred

// 7zFM's two refusals, reusable: not a file-system folder / nothing selected.
CompressCommands.operatedFileSystemPaths(context)
```

`@objc` entry points on `MainWindowController` (all declared in `MenuActions`, so a menu item
or a toolbar item can target them): `toolbarAddToArchive` (already wired to the toolbar Add
button), `compressToSevenZip`, `compressToZip`, `compressAndEmail`,
`compressToSevenZipAndEmail`, `compressToZipAndEmail`, `compressAddToOpenArchive`.

Every command reads its selection through `ActiveContext.current()` and refreshes with
`ActiveContext.refreshAll()`, so nothing reaches into panel internals.

Email mode builds the archive in `NSTemporaryDirectory()/7zE-<uuid>/` and then calls
`NSSharingService(named: .composeEmail)`. `EMailRemoveAfter` cannot be honoured synchronously
(the mail app still needs the file), so folders older than a day are purged on the next
compress-and-email; email + volumes is refused as on Windows.

---

## 6. Adding to an archive that is already open

```swift
// The panel's drag-into-an-archive and the "add files" command both go through this.
CompressCommands.addFiles(paths, to: context)    // context.isArchive == true
CompressCommands.addFilesToOpenArchive()         // asks with an NSOpenPanel first
```

At the archive **root** this is `SZUpdater.addPaths(_:toArchiveAt:)` — the engine's in-place
update, which re-packs through a temp file and reports `MoveArc_*`. Inside a **sub-folder** it
is the Agent's `IFolderOperations::CopyFrom` through the `opsinfra` API
(`folder.copyItems(named:fromFolderPath:moveMode:progress:)`), which stores the items under
the folder the panel shows — what 7zFM's drag-into-an-archive does (01 section 3.10).

---

## 7. Verification hook

`CompressDemo` (`Mac/App/Dialogs/CompressDemo.swift`), installed from `MainMenu.build()` and
inert unless `SZ_COMPRESS_DEMO` is set: `dialog` opens the Compress dialog over a stand-in
`OperationContext`, `options` also clicks the Options button, `quick` runs the no-dialog
"Compress to <name>.7z". `SZ_COMPRESS_DIR` overrides the source folder. It registers its own
`OperationContextProviding` only while the variable is set, so the `panel` scope's real
provider is untouched.

---

## 8. Known gaps

* The archive **opener** has no `IArchiveOpenVolumeCallback`, so a volume set that this scope
  creates (`x.7z.001`, …) cannot be re-opened through `SZFolder`/`SZArchiveOpener`; the console
  opens it fine. Recorded in `Mac/docs/requests.md` for the `extract` scope.
* External `Codecs\` DLL methods (`SetMethods(userCodecs)`) do not exist on macOS, so
  `CompressModel.externalMethods` is always empty.
* Alternate data streams and Windows file security are hidden in the Options sheet (01 §9
  #6, #7); the settings keys still round-trip.
* The browse panel uses `NSSavePanel` with "allow other file types" instead of one filter per
  format: `NSSavePanel` has no equivalent of a filter combo whose selection changes the
  archive type, so the type is taken from the extension the user types (which is the part of
  `OnButtonSetArchive` that matters).
* `Mac/Resources/SFX` is a resource of the **app** target only, so the unit tests locate the
  stubs through `SEVENZIP_SFX_DIR`. Adding the folder to the `SevenZipKit` framework's
  resources would remove the need.

---

## Note — 2026-09-20 (`mac/cleanup`)

The multi-volume request this scope filed is done. `SZArchiveOpener` hands `CAgent::Open` the
engine's own `COpenCallbackImp` with `Init2(dirPrefix, fileName)`, so
`IArchiveOpenVolumeCallback::GetStream` finds `.002`, `.003`, `.r00`, `.z01` … next to the first
volume. `SZFolder.folder(forPath: "x.7z.001")` and
`SZArchiveOpener.openArchive(atPath:formatHint:passwordDelegate:)` therefore list the whole set;
`archive.type` is the **innermost** handler (`"7z"`, not `"Split"` — `CArchiveLink::Arcs.Back()`),
and `archive.arcProps?.levelCount >= 2` is what shows the Split level.

`UpdaterOptionsTests.testSplitVolumes` can drop its "concatenate the volumes first" workaround; the
new `MultiVolumeOpenTests` opens a `7zz a -v40k` set and an `SZUpdater` set directly. See
`Mac/docs/reports/cleanup.md`.
