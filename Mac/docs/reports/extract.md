# `extract` scope — progress notes

> **Publication note:** all but a few showcase images under `docs/reports/screenshots/` were removed from the repository before publication. Paths below that point into them are kept as a record of what was measured.

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

## Phase 4 — open / view / edit / diff, the temp watcher and the drag-out hook (done)

**Bridge** `Mac/Core/Internal/SZTempOpen.h` + `.mm`, public API in `Mac/Core/include/SZExtractor.h`:

- `CSZVirtFileSystem` = `CVirtFileSystem` (ExtractCallback.cpp:840-1200): an
  `IFolderArchiveExtractCallback` that also answers `IFolderExtractToStreamCallback`, so
  `CArchiveExtractCallback` writes into memory (`CDynBufSeqOutStream`) instead of into files;
  `FlushToDisk()` then writes the items under the temp prefix, restoring mtime and attributes and
  applying the quarantine attribute.
- `SZTempFile` = `CTempFileInfo`: directory, file, relative path, item index, size + mtime and
  `wasModified` / `refreshRecordedAttributes`, which is the watcher's comparison.
- `SZTempOpen`: `7zO` / `7zE` prefixes, `createTemporaryDirectory(prefix:)` (mkdtemp),
  `inMemoryLimit(archiveLevelCount:)` = `RAM >> max(levels + 1, 8)` else 4 MiB,
  `extractItem(at:of:archiveFilePath:archiveLevelCount:zoneMode:progress:)` (memory first for a
  small file, disk for anything bigger and for folders, with a fall-back to disk when the memory
  path fails), `updateItem(at:of:fromFilePath:progress:)` = `IFolderOperations::CopyFromFile`,
  `temporaryDirectories()` / `removeTemporaryDirectory(atPath:)` (refuses anything that is not a
  `7zO*`/`7zE*` folder inside the temp directory), `applyQuarantine(fromArchiveAt:to:mode:)`.

**App** `Mac/App/Support/TempOpen.swift` and `TempOpenCommands.swift`:

- `ExternalTool`: `SplitCmdLineSmart` for the `FM.Viewer` / `FM.Editor` / `FM.Diff` settings,
  which may be an `.app` bundle, an executable, an application name or a command line; empty
  falls back to Quick Look (`qlmanage -p`) for View and TextEdit for Edit (01 §9 #10).
- `SuspiciousName`: `IsVirus_Message` (RLO, 5+ spaces, an executable extension hidden behind
  trailing dots/spaces, `kExeExtensions` + `app command sh pkg dmg`) and the `IDS_VIRUS 3012`
  confirmation.
- `TempOpenSession`: the watcher. A `DispatchSource` (`.write .rename .delete .extend`) on the
  temp file **and** `NSWorkspace.didTerminateApplicationNotification` for the launched app
  (01 §9 #11). On a change it asks `IDS_WANT_UPDATE_MODIFIED_FILE 3009` and runs `CopyFromFile`
  under the Progress dialog, reports `IDS_CANNOT_UPDATE_FILE 3010` on failure, then removes the
  temp folder. A read-only archive is refused with the same 3010 text (step 3 of
  `OpenItemInArchive`). `TempOpenManager` keeps the sessions and drains them on
  `NSApplication.willTerminateNotification` (01 §1.1 "Shutdown").
- `ItemOpenCommands`: View (F3, `IDM_FILE_VIEW 543`), Edit (F4, `IDM_FILE_EDIT 544`), Open
  Outside (`IDM_OPEN_OUTSIDE 542`) and Diff (`IDM_DIFF 554`), for both a file-system item and an
  item inside an archive; a folder inside an archive is extracted and revealed in Finder
  (`OpenFolderExternal`).
- `ArchiveDragOut`: the lazy-extraction hook for the `panel` scope —
  `extract(indices:from:to:archiveDisplayPath:parentWindow:overwriteMode:)` writes the items into
  the destination Finder supplies or into a fresh `7zE` folder and returns the paths,
  `promisedNames(indices:from:)` for the promise provider, `removeTemporaryDirectory(_:)` for the
  clean-up. Documented in `Mac/docs/api/extract.md`.

**Difference from Windows, documented:** small files are held in memory exactly as Windows does,
but the "give up and go to disk" decision is made *before* the run from the item's own size
(`PanelItemOpen.cpp:1613-1615` does the same), whereas `CVirtFileSystem` can also bail out
mid-run; when the in-memory attempt does fail here, the code simply repeats it straight to disk.

**Verified** `Mac/scripts/test.sh` → 100 tests, 0 failures. `TempOpenTests.swift` (8 tests)
covers the memory path, the disk path for a folder item, an encrypted archive, the full
modify-and-write-back round trip with a re-opened archive, `CopyFromFile` refusal on a
file-system folder, the temp-folder prefixes and the guarded removal, the RAM formula, and
quarantine propagation in all three zone modes.

**Next** Phase 5: verification in the running app.

## Phase 5 — verification in the running app (done)

Launched from this worktree with `SEVENZIP_DEFAULTS_SUITE=7zip-extract` and a scope-local
stand-in for the panel's context provider (`ExtractVerificationContext`, installed only when
`SZ_EXTRACT_CONTEXT` is set — the `panel` scope has not registered the real
`OperationContextProviding` yet). Driven with `osascript` System Events; screenshots in
`Mac/docs/reports/screenshots/`:

| Screenshot | What it shows |
|---|---|
| `extract-01-menu.png` | File > 7-Zip with Extract files… / Extract Here / `Extract to "test/"` / Test archive; the `{0}` of `IDS_CONTEXT_EXTRACT_TO 2327` is filled from the selection |
| `extract-02-dialog.png` | the Extract dialog: caption `Extract : <archive>`, path combo + browse, sub-folder box with `test/`, both mode combos, Eliminate duplication, the password group, the item summary, Help / Cancel / OK |
| `extract-03-test-summary.png` | the test statistics box: `Archives: 1 / Packed Size: 296 bytes / Folders: 2 / Files: 4 / Size: 3043 bytes : 2 KiB` + `There are no errors` |
| `extract-04-update-prompt.png` | `File 'readme.txt' was modified. Do you want to update it in the archive?` with Yes / No |
| `extract-05-dialog-in-archive.png` | the same dialog opened from inside an archive: caption = the archive file recovered from the display path, destination proposed as the archive's own folder |
| `extract-06-test-in-archive.png` | Test inside an archive: `Files: 6 / There are no errors` |

Exercised end to end, each verified by inspecting the file system afterwards:

- **Extract files…** → `<arcDir>/test/` with `notes.md readme.txt sub/big.txt sub/deep/inner.txt`,
  then `refreshAfterOperation`.
- **Extract Here** → the same four files directly in `<arcDir>/`, no dialog.
- **Extract to "…"** with two archives selected → `<arcDir>/*/` substituted per archive.
- **Test archive** on a file-system folder and inside an archive → both summaries.
- **Extract from inside an archive** (two items, one of them a folder) → the subtree landed in the
  archive's own directory.
- **Edit (F4) on an item inside an archive** → extracted to `/var/folders/…/T/7zO-XXXXXX/`,
  opened in TextEdit, the file changed from a shell, the `DispatchSource` watcher fired, the
  prompt appeared, Yes repacked the zip (verified with the console `7zz`: `readme.txt` is now the
  edited text at the new size).
- Both mode combos read back through the accessibility API with every Windows entry
  (`Ask before overwrite, Overwrite without prompt, Skip existing files, Auto rename,
  Auto rename existing files`).

**Fixed during verification**

1. The Objective-C class `SZExtractor` collides with a private class of Apple's
   `StreamingZip.framework` ("may cause spurious casting failures and mysterious crashes");
   renamed to `SZArchiveExtractor`, header file name unchanged. Logged in `requests.md`.
2. `ActiveContext.provider` is `weak`, so a provider nobody else retains disappears at once —
   the verification stand-in now keeps a static reference. Worth knowing for the panel scope.
3. Wrong button lang IDs: 410/411 are "" and "Continue"; Yes/No/Help are **406/407/409**.
   Logged in `requests.md`.
4. The Extract dialog collapsed into itself: an `NSBox` whose content view opts out of
   autoresizing is not constrained by the box, and `DialogKit.install`'s `fittingSize` sizing
   then produced a window too small. The dialog now pins the box content explicitly and uses a
   fixed size, which is also what `IDD_EXTRACT` (336 x 168 du, non-resizable) is.

**Shared app lock.** Acquired at 23:54 with the documented `mkdir` loop. While it was held, the
`panel` and then the `compress` scope overwrote `.app-lock/owner` with their own name and ran
their apps anyway; the panel harness also terminated my instance twice mid-run (that is the open
`harness` request in `requests.md`). Because another scope currently claims the lock, this agent
did **not** `rm -rf` it — deleting it would drop their claim. Orchestrator: the lock protocol
needs `mkdir` to be honoured, not just `owner` rewritten.

## Phase 6 — deliverables

- **API document**: `Mac/docs/api/extract.md` — `SZArchiveExtractor`, `SZTempOpen` / `SZTempFile`,
  the Extract dialog, the commands, the **`ArchiveDragOut` lazy-extraction hook for the `panel`
  scope** (section 5) and the **test-summary shape** (section 1).
- **PROGRESS.md**: 29 items ticked in section 4 (`extract`) only.
- **Cross-scope requests** added to `Mac/docs/requests.md`: Open Outside inside an archive
  (`panel`), the drag-out hook (`panel`), `-scrc` hashing during extraction (`tools`), plus four
  spec corrections (auto-rename naming, the Yes/No/Help lang IDs, combos vs radio groups and the
  absent summary control in `IDD_EXTRACT`, and the `SZExtractor` class-name collision).

### Files owned and touched

| Path | |
|---|---|
| `Mac/Core/include/SZExtractor.h` | new — `SZExtractOptions`, `SZExtractStatistics`, `SZExtractResult`, `SZArchiveExtractor`, `SZTempFile`, `SZTempOpen` |
| `Mac/Core/SZExtractor.mm` | new — the `Extract()` driver, `CSZExtractUICallback`, `OpenResult_GUI`, the test summary |
| `Mac/Core/Internal/SZTempOpen.h` / `.mm` | new — `CSZVirtFileSystem`, quarantine, the temp helpers, `CopyFromFile` |
| `Mac/App/Dialogs/ExtractDialog.swift` | new — `IDD_EXTRACT 3400` |
| `Mac/App/Commands/ExtractCommands.swift` | new — the four commands, `ExtractMenuTitles`, `ExtractVerificationContext` |
| `Mac/App/Support/TempOpen.swift`, `TempOpenCommands.swift` | new — tools, watcher, View/Edit/Open Outside/Diff, `ArchiveDragOut` |
| `Mac/Tests/SevenZipKitTests/ExtractorTests.swift`, `TempOpenTests.swift` | new — 33 tests |
| `Mac/Tests/Fixtures/multi.7z.001..003` | new 3-volume fixture |

Additive-only edits in shared files: `Mac/Core/include/SevenZipKit.h` (one `#import`),
`Mac/App/MainMenu.swift` (the File > 7-Zip submenu, two `MenuActions` selectors, one line calling
the verification hook), `Mac/docs/PROGRESS.md` (section 4 only), `Mac/docs/requests.md` (appended
rows and corrections).

### Known gaps

1. `-scrc<method>` hashing during extraction is not wired (`Extract()` gets `IHashCalc = NULL`);
   it belongs with the `tools` hash dialog. Request filed.
2. `-thash` (testing a `.sha256` hash list as an archive) is not passed by the Test command.
3. Quarantine on a plain extraction: `zoneIDMode` reaches the engine but
   `ReadZoneFile_Of_BaseFile` is `#if defined(_WIN32)`, so nothing is written. The temp-open path
   does it itself; `SZTempOpen.applyQuarantine(fromArchiveAt:to:mode:)` can post-process an
   extraction when the panel scope wants it. PROGRESS §4.3 item left unticked.
4. Diff across two panels needs the other panel's focused item, which the frozen
   `OperationContext` does not expose; only "two items selected in one panel" works.
5. Open Outside inside an archive is unreachable from the menu while `PanelViewController` claims
   and disables the selector. Request filed; `ItemOpenCommands.openOutside()` does the work.
6. The Progress dialog's Dock-tile mirror and the `CProgressThreadVirt::Process` exception→text
   mapping are `opsinfra` items and stay unticked.
7. `7zO` / `7zE` folders survive a crash (`kill -9`), exactly like Windows, which never sweeps.
   `SZTempOpen.temporaryDirectories()` is there for Tools > Delete Temporary Files and for an
   optional startup sweep.
