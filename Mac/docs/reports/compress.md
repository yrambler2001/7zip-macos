# `compress` scope — progress log and report

Branch `mac/compress`. Checklist: `Mac/docs/PROGRESS.md` section 5. Spec:
`Mac/docs/01b-fm-dialogs-settings.md` sections 4.23, 4.24; `01-fm-feature-inventory.md`
section 8.5; `02-engine-api.md` section 2.3.

State notes are appended per phase so the work can be resumed after a context compaction.

## Phase 0 — orientation (done)

Read the orchestration contract, `requests.md`, the frozen `OperationContext`, the
`opsinfra` / `options` / `fsfolder` API docs, `01b` sections 4.23/4.24 and the engine
headers that matter (`UI/Common/Update.h`, `UpdateCallback.h`, `SetProperties.h`,
`UpdateAction.h`, `ZipRegistry.h`, `WorkDir.h`, `Wildcard.h`) plus the Windows sources
being ported (`GUI/UpdateGUI.cpp`, `GUI/UpdateCallbackGUI*.cpp`, `Common/CompressCall2.cpp`).

Design decisions taken:

- `SZUpdater` drives the engine's `UpdateArchive()` (`UI/Common/Update.cpp`) exactly like
  `UpdateGUI.cpp` does, so behaviour matches 7zG instead of being reimplemented.
- The `-m` property list is built in Swift (`CompressOptions` → `[SZUpdateProperty]`) in the
  order `01b` section 4.23 "Parameter generation" documents; the bridge passes it through
  unchanged to `CUpdateOptions::MethodMode::Properties`.
- The censor is `AddPreItem_NoWildcard(path)` per source path (7zG's `-i#map` list with
  `ISWITCH_NO_WILDCARD_POSTFIX`); `UpdateArchive` itself calls `AddPathsToCensor(PathMode)`.
- The work-directory policy is applied inside the bridge from `NWorkDir::CInfo::Load()`
  (same preferences domain as the Swift `Settings` facade) unless a working directory is
  passed explicitly.

## Phase 1 — update bridge (done)

`Mac/Core/include/SZUpdater.h` + `Mac/Core/SZUpdater.mm`, added to the umbrella header
(`SevenZipKit.h`, alphabetical, additive). Builds clean; `Mac/scripts/test.sh` green
(71 tests, 4 new).

- `SZUpdateProperty` (one `-m` pair = `CProperty`), `SZUpdateOptions` (one-to-one with
  `CUpdateOptions` + the dialog's option set), `SZUpdateResult` (`CFinishArchiveStat` plus the
  callback counters, the failed-file list and the `-sdel` list).
- `+[SZUpdater updateWithOptions:sourcePaths:progress:error:]` is `UpdateGUI` minus the dialog.
  `+addPaths:toArchiveAtPath:…` updates an existing archive in place (format from its name,
  exact name mode, no volumes), `+deleteItemsNamed:fromArchiveAtPath:…` is the console `d`.
- `CSZUpdateUICallback` (in the .mm, anonymous namespace) implements `IUpdateCallbackUI2` +
  `IOpenCallbackUI` and forwards to `id<SZProgressDelegate>`, mirroring
  `CUpdateCallbackGUI`/`CUpdateCallbackGUI2` call for call, including the
  `NUpdateNotifyOp` -> lang-ID status mapping (3320-3327), `DeletingAfterArchiving` ->
  `Removing` (3305), `MoveArc_*`, `ScanError`/`OpenFileError`/`ReadingFileError` ->
  `FailedFiles`, `ReportExtractResult` -> `SetExtractErrorMessage`, and
  `CryptoGetTextPassword2` -> `progressAskPasswordForEncryptionCancelled:`.
- SFX: `+defaultSFXModulePath` finds `7z.sfx` in the app bundle's `Resources/SFX`, with a
  `SEVENZIP_SFX_DIR` override so the unit tests (no app bundle) find the stubs.
  `BaseExtension` is forced to `"exe"` because `Update.cpp`'s own `kSFXExtension` is `""`
  off Windows.
- Work dir: `NWorkDir::CInfo::Load()` + `GetWorkDir` + `CreateComplexDir` when
  `workingDirectory` is nil, exactly like `UpdateGUI.cpp:527-539`.
- `+archiveBaseNameForItemPaths:isHash:baseName:` wraps the engine's own
  `CreateArchiveName` (03 section 1.6), so the `_2` collision rule is upstream's.

Next: the rest of the bridge tests (encryption, volumes, SFX bytes, delete-after, cancel,
in-place update, entry deletion, timestamps), then the Compress dialog.

## Phase 1b — bridge verification (done)

`Mac/Tests/SevenZipKitTests/UpdaterTests.swift`: 35 tests, all green (102 in the suite).
Every archive is verified twice — re-opened through `SZFolder` and tested with the console
`7zz` built from this tree (`CPP/7zip/Bundles/Alone2/b/m_arm64/7zz`), skipped automatically
when it is absent.

Covered: create in 7z / zip / tar / wim / gzip / bzip2 / xz; the tar GNU and POSIX header
methods; all ten 7z levels (Store is the largest, Ultra the smallest); the 7z method list
(LZMA2 LZMA PPMd BZip2 Copy Deflate) and the zip method list (Deflate Deflate64 BZip2 LZMA
PPMd) and zip's 0/1/3/5/7/9 levels; a read-only handler refused with
`SZErrorCodeUnsupported`; solid (`s=…`) vs non-solid (`s=0b`) proven through the console's
`Block =` lines; an encrypted 7z that lists but needs the password to test; `he=on` that
cannot even be listed without one; zip ZipCrypto vs `em=AES256`; a 5-volume split that
rejoins by concatenation and that the console accepts; an SFX whose first
`sizeof(7z.sfx)` bytes are byte-identical to the bundled stub, starts with `MZ` and whose
payload lists and tests; `-sdel` removing the sources, and keeping them when the run fails;
cancellation mid-compression leaving neither an archive nor a temp file; `tc`/`ta`/`tp=0`
making zip store creation/access times and `tm=off` dropping gzip's mtime; `-stl`; `-snl`
on/off; in-place add (with the MoveArc callback firing), entry deletion (`7z d`), Freshen,
Sync and the relative/absolute path modes; and `CreateArchiveName` including the
`<name>_<N>` collision rule.

Known gap recorded in `Mac/docs/requests.md`: the bridge's archive *opener* has no
`IArchiveOpenVolumeCallback`, so `x.7z.001` cannot be opened through `SZFolder`
(the console can). Creating volumes works; only reading a set back through the bridge does not.

## Phase 2 + 3 — dialog, Options sheet and commands (built)

- `Mac/App/Dialogs/CompressModel.swift` — the AppKit-free computation half of
  `CompressDialog.cpp`: `g_Formats` (9 entries with `LevelsMask`, method lists and the seven
  `kFF_*` flags), `CompressMethodID` = `EMethodID` with `kMethodsNames`, the level / method /
  dictionary / word-size / solid / thread / mem-use item builders with their auto rules and
  selection-from-settings logic, `Get_Lzma2_ChunkSize`, `Get_MemUse_Bytes`,
  `GetMemoryUsage_Threads_Dict_DecompMem`, `PrintMemUsage`, `CompressMemUse`
  (`NCompression::CMemUse::Parse`), `CompressVolumes` (`ParseVolumeSizes` + the Split presets +
  `GetNumberOfVolumes`), `CompressTimePrecision` (`AddPrec` / `Get_TimePrecFlags`) and
  `CompressDialogResult`, whose `properties` emits the `-m` list in the exact
  `SetOutProperties` + `ParseAndAddPropertires` order (including `IsThereMethodOverride`).
- `Mac/App/Dialogs/CompressDialog.swift` — IDD_COMPRESS 4000. Every control carries its
  Windows ID in a comment and its label comes from the lang table by ID. The cascade is the
  Windows one: format -> `SaveOptionsInMem` + `FormatChanged` + `SetArchiveName2`;
  level -> `ResetForLevelChange` + method + dependents; method -> dictionary/order/solid/
  threads/memory (+ the hash extension); dictionary -> reset stored block size unless
  Non-solid/Solid, refill solid/threads/memory; order/solid/threads -> memory;
  mem-use -> threads + memory. OnOK does the five validations in order, the volume parse with
  the < 100 KB confirmation, and writes `Archiver`, `ShowPassword`, `EncryptHeaders`,
  `ArcHistory` (20) and every touched per-format option group.
- `Mac/App/Dialogs/CompressOptionsSheet.swift` — IDD_COMPRESS_OPTIONS 14001 with the tri-state
  ":" set-boxes, `SetPrec` / `SetTimeMAC` (tar -> no ctime, atime only for POSIX; zip -> c/a
  only at Windows precision; mtime's set-box hidden for multi-file formats), the always-shown
  `-stl` box and the `-ssp` box. Alt streams and file security are hidden on macOS but still
  round-trip through the settings.
- `Mac/App/Commands/CompressCommands.swift` — `toolbarAddToArchive` (`CPanel::AddToArchive`
  rules: FS panel only, IDS_SELECT_FILES when nothing is selected, `CreateArchiveName`),
  the `CompressTo7z` / `CompressToZip` quick commands and their email variants, compress and
  email through `NSSharingService.composeEmail` with a `7zE-<uuid>` temp folder (stale folders
  purged on the next run since `EMailRemoveAfter` cannot be synchronous), and adding files to
  the archive an open panel is inside (in-place `SZUpdater.addPaths` at the root, the Agent's
  `CopyFrom` in a sub-folder). Everything runs under `OperationRunner` with the
  IDS_PROGRESS_COMPRESSING title and `showCompressionInfo = true`, then `ActiveContext.refreshAll()`.
- `Mac/App/MainMenu.swift`: six selectors appended to `MenuActions` (additive only).

Next: unit tests for the model (item lists, auto values, memory, property order), then the
running-app verification.
