# `extract` scope — progress notes

Branch `mac/extract`, worktree `.worktrees/extract`. Deliverables per
`Mac/docs/00-orchestration.md`; checklist is `Mac/docs/PROGRESS.md` section 4.

## Phase 1 — extraction bridge (done)

**Exists**

- `Mac/Core/include/SZExtractor.h` / `Mac/Core/SZExtractor.mm`: `SZExtractOptions`,
  `SZExtractStatistics`, `SZExtractResult`, `SZExtractor`. The implementation calls the
  engine's own `Extract()` (`CPP/7zip/UI/Common/Extract.cpp`) — the function 7zG runs — so path
  modes, overwrite modes, `-spe` duplicate-root elimination, `*` substitution in the output
  directory, multi-volume accounting and every error text are the Windows product's, not a
  reimplementation.
- The two callbacks `Extract()` needs: the shared `CSZExtractCallbackAdapter` (opsinfra) as the
  COM `IFolderArchiveExtractCallback`, plus `CSZExtractUICallback` (in `SZExtractor.mm`) as the
  non-COM `IExtractCallbackUI` + `IOpenCallbackUI` pair. They share password, delegate and error
  counters, which on Windows is one object (`CExtractCallbackImp`).
- `OpenResult_GUI` ported verbatim (multi-level open-error text, `k_ErrorFlagsIds` table).
- Test statistics summary (`SZExtractResult.testSummary`) formatted exactly like
  `GUI/ExtractGUI.cpp:137-158`, ready for `OperationRunner.Options.okMessage`.
- `SZExtractor.subfolderName(forArchiveNamed:)` = `GetSubFolderNameForExtract`
  (Explorer/ContextMenu.cpp:448, Windows-only code, reimplemented).
- `SZExtractProgressTap` records every message so a caller without a delegate (tests, Finder)
  still gets diagnostics; it mirrors the wrapped delegate's `respondsToSelector:` so the
  adapters' optional-callback probing keeps working.
- `Mac/Tests/Fixtures/multi.7z.001..003`: new 3-volume 7z fixture (random.bin 30000 B + vol.txt).

**Builds** `Mac/scripts/build.sh` → BUILD SUCCEEDED, no warnings in `Mac/`.

**Verified** `Mac/scripts/test.sh` → 92 tests, 0 failures (25 new in
`Mac/Tests/SevenZipKitTests/ExtractorTests.swift`): every fixture format, all four path modes,
all five overwrite modes (including the `.ask` answers and Cancel → `E_ABORT`), password
up-front / through the delegate / wrong / cancelled, multi-volume (also with every volume
passed), cancellation mid-run, test of a good archive with the summary text, of a
CRC-corrupted archive and of a non-archive, the sub-folder-name rules, `createOutputDirectory`.

**Spec correction found:** the engine's `AutoRenamePath`
(`CPP/7zip/Common/FilePathAutoRename.cpp`) produces `readme_1.txt`, not `name (2).ext` as
01 §8.4 claims. Logged in `Mac/docs/requests.md`.

**Next** Phase 2: the Extract dialog (`Mac/App/Dialogs/ExtractDialog.swift`).

## Phase 2 — Extract dialog (done)

`Mac/App/Dialogs/ExtractDialog.swift`: `IDD_EXTRACT 3400`, faithful to
`GUI/ExtractDialog.cpp` (01b §4.25). Caption = translated `IDD_EXTRACT` text + `" : <ArcPath>"`
for exactly one archive. Controls, each with its Windows ID in a comment and its label from the
lang table (the `kLangIDs` list):

- `IDC_EXTRACT_PATH 100` editable `NSComboBox` with the `Extraction.PathHistory` list (max 16)
  and `IDB_EXTRACT_SET_PATH 101` "..." → `NSOpenPanel` titled `IDS_EXTRACT_SET_FOLDER 3402`.
- `IDX_EXTRACT_NAME_ENABLE 131` (no text) + `IDE_EXTRACT_NAME 130`, driven by
  `SplitPathToParts_Smart` (ported), toggling shows/hides the edit, appended again at OK.
- `IDC_EXTRACT_PATH_MODE 102` and `IDC_EXTRACT_OVERWRITE_MODE 103` as pop-up buttons — the
  resource declares `MY_COMBO`, so combos, not radio groups (the task brief said "radio
  groups"; the inventory and the .rc say combo, and requests.md says the spec wins). All three
  path entries (Full / No / Absolute; a caller's `kCurPaths` shows as Full and survives OK) and
  all five overwrite entries (Ask / Overwrite / Skip / Auto rename / Auto rename existing).
- `IDX_EXTRACT_ELIM_DUP 3430` with `CheckButton_TwoBools` semantics (caller's Def, then the
  setting, then the true default).
- `IDX_EXTRACT_NT_SECUR 3431` created but hidden (01 §9 #7); its stored value round-trips.
- `IDG_PASSWORD 3807` box with `IDE_EXTRACT_PASSWORD 120` and `IDX_PASSWORD_SHOW 3803`
  (secure/plain field swap, same trick as `PasswordDialog`).
- OK / Cancel / Help (`fm/plugins/7-zip/extract.htm`).
- Addition, *not* a Windows control: an item-count/size summary block (max 11 names, then
  Folders / Files / Size) modelled on `CCopyDialog`'s `GetItemsInfoString` (App.cpp:500-547),
  because the brief asked for it. `IDD_EXTRACT` has no such control on Windows.

Settings round-trip follows `NExtract::CInfo::Load/Save` exactly: `ExtractMode` is written only
when it differs from the stored value (that is what `PathMode_Force` means),
`OverwriteMode` only when not forced by the caller, `SplitDest` / `ElimDup` / `Security` /
`ShowPassword` only when the user changed them, `PathHistory` = new path first, then the other
entries, case-insensitively unique, max 16.

## Phase 3 — commands (done)

`Mac/App/Commands/ExtractCommands.swift`, all through `ActiveContext.current()` and
`OperationRunner`, refreshing with `ActiveContext.refresh()`:

- `toolbarExtractArchives` (kMenuCmdID_Toolbar_Extract 1071 / kExtract): FS folder → output
  `<arcDir>/<GetSubFolderNameForExtract2(name)>/` for one archive, `<arcDir>/*/` for several,
  Extract dialog, then `SZExtractor`. Inside an archive → the archive folder's own extract path
  (`IArchiveFolder::Extract`, `kCurPaths`), destination proposed from the other panel or the
  archive's own directory.
- `extractHere` (kExtractHere): no dialog, `<arcDir>/`.
- `extractToSubfolder` (kExtractTo): no dialog, sub-folder per archive, `-spe` from
  `Options.ElimDupExtract`.
- `toolbarTestArchives` (kMenuCmdID_Toolbar_Test 1072 / kTest): FS folder → `SZExtractor.test…`
  and the statistics info box when there were no errors; inside an archive → `extractItems`
  with `testMode` and the shorter "Files / There are no errors" message (the Agent has no
  `CDecompressStat`).
- Preconditions match `CPanel::ExtractArchives`: file-system folder (else
  `IDS_OPERATION_IS_NOT_SUPPORTED 6008`), a non-empty selection with no directory in it (else
  `IDS_SELECT_FILES 3015`). `Options.WriteZoneIdExtract` becomes `-snz<N>`.
- `Mac/App/MainMenu.swift` (additive): a File > 7-Zip cascaded submenu with Extract files… /
  Extract Here / Extract to "<name>/" / Test archive, plus two new `MenuActions` selectors;
  `ExtractMenuTitles` (in `ExtractCommands.swift`) is its `NSMenuDelegate` and fills `{0}` in
  `IDS_CONTEXT_EXTRACT_TO 2327` from the selection, as `QueryContextMenu` does on Windows.

**Builds** clean. **Next** Phase 4: temp-file open / view / edit / diff + the watcher and the
lazy-extraction hook for the panel scope.
