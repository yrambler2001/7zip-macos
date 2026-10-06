# `extract` scope — public API

What the other scopes may use from `mac/extract`: the extraction bridge (`SZArchiveExtractor`),
the temp-file machinery (`SZTempOpen` / `SZTempFile`), the Extract dialog, the four commands, and
the **lazy-extraction hook the `panel` scope needs for dragging archive members out to Finder**
(section 5).

Sources: `Mac/Core/include/SZExtractor.h`, `Mac/Core/SZExtractor.mm`,
`Mac/Core/Internal/SZTempOpen.*`, `Mac/App/Dialogs/ExtractDialog.swift`,
`Mac/App/Commands/ExtractCommands.swift`, `Mac/App/Support/TempOpen*.swift`.

Parity references: `01-fm-feature-inventory.md` §3.9, §3.11, §3.15, §8.1-8.4;
`01b-fm-dialogs-settings.md` §4.25; `02-engine-api.md` §2.3, §2.5.2;
`03-shell-integration-inventory.md` §1.6.

---

## 1. `SZArchiveExtractor` — extract or test archives

> **Why not `SZExtractor`?** That class name is taken by a private Objective-C class in Apple's
> `StreamingZip.framework`; the runtime reports the duplicate and warns about "spurious casting
> failures and mysterious crashes". The header is still `SZExtractor.h`, as the architecture
> document says; only the class is `SZArchiveExtractor`.

The implementation calls the engine's own driver, `Extract()` in
`CPP/7zip/UI/Common/Extract.cpp` — the function 7zG runs — so path modes, overwrite modes, the
`-spe` duplicate-root elimination, `*` substitution in the output directory, multi-volume
accounting and every error text are the Windows product's, not a reimplementation.

**Blocks for the whole operation; call off the main thread** (drive it with `OperationRunner`,
which is itself the `SZProgressDelegate` — see `api/opsinfra.md`).

```swift
let options = SZExtractOptions()
options.outputDirectory = "/tmp/out/*/"        // "" = the process's current directory
options.outDirMode = .replaceAsterisk          // .direct | .addArchiveName | .replaceAsterisk
options.pathMode = .curPaths                   // .fullPaths .curPaths .noPaths .absPaths .noPathsAlt
options.overwriteMode = .ask                   // .ask .overwrite .skip .rename .renameExisting
options.eliminateDuplicateRoot = true          // NSNumber?; nil = CBoolPair "not defined" (-spe)
options.zoneIDMode = .all                      // -snz: .none .all .office
options.password = "secret"                    // -p; the delegate is not asked while this is set
options.formatHint = "7z"                      // -t<type>, "*" or "#"; nil = detect
options.testMode = false
// also: pathModeForced, overwriteModeForced, excludeDirectoryItems/excludeFileItems (-spd/-spf),
// restoreFileSecurity (-sni, accepted for parity; macOS has no NT security, 01 §9 #7),
// extractSymbolicLinks (-snl, default true) / extractHardLinks (-snh) / extractAlternateStreams,
// preAllocateOutputFile, preserveAccessTime, memoryLimit (UINT64_MAX = none).

let result = try SZArchiveExtractor.extractArchives(at: paths, options: options, progress: runner)
let result = try SZArchiveExtractor.testArchives(at: paths, options: options, progress: runner)
```

`SZExtractResult`:

| Member | Meaning |
|---|---|
| `statistics` | `SZExtractStatistics` = `CDecompressStat`: `archiveCount`, `fileCount`, `folderCount`, `unpackSize`, `packSize`, `alternateStreamCount`, `alternateStreamsUnpackSize` |
| `filesProcessed` | items whose `SetOperationResult` arrived (the progress dialog's "Files") |
| `errorCount` | messages + per-item failures (the "Errors" counter) |
| `archiveErrorCount` | `NumArchiveErrors`: archives that failed to open or to extract |
| `firstFailure` | first non-OK `SZOperationResult` (CRC error, wrong password, …) |
| `passwordWasAsked`, `password` | remember the password on the folder chain (`CFolderLink`) |
| `messages` | every message the run produced, for a caller that passed no delegate |
| `isOK` | `CExtractCallbackImp::IsOK()` — nothing failed |
| `testSummary` | **the test statistics block** (below); nil unless it was a test that finished clean |

Only a *fatal* failure throws (cancellation gives `SZError.Code.cancelled`); per-archive and
per-item errors are reported through the delegate and counted, exactly like 7zG, which still
returns `S_OK`.

### The test-summary shape

`testSummary` is the text `GUI/ExtractGUI.cpp:137-158` builds and 7zG shows as
`FinalMessage.OkMessage` after the progress window closes. Pass it to
`OperationRunner.Options.okMessage`, or show it yourself:

```
Archives: 1
Packed Size: 296 bytes
Folders: 2
Files: 4
Size: 3043 bytes : 2 KiB

There are no errors
```

* the label of every row is the lang string (`IDS_ARCHIVES_COLON 3907`, `IDS_PROP_PACKED_SIZE`
  1008, `IDS_PROP_FOLDERS` 1031, `IDS_PROP_FILES` 1032, `IDS_PROP_SIZE` 1007, and
  `IDS_MESSAGE_NO_ERRORS 3001` on the last line);
* "Folders" appears only when there are directories, and the two alternate-stream rows
  (`IDS_PROP_NUM_ALT_STREAMS` 1075, `IDS_PROP_ALT_STREAMS_SIZE` 1076) only when the count is
  non-zero, preceded by a blank line;
* sizes use `AddSizeValue` (`OverwriteDialog.cpp:68`): `"<digits> bytes"` plus `" : <N> KiB"` /
  `MiB` / `GiB` from 1024 bytes up;
* `nil` when the run had any error — Windows then leaves the progress window open with the
  message list instead of showing a box.

### Helpers

```swift
SZArchiveExtractor.subfolderName(forArchiveNamed: "movie.part01.rar")   // "movie"
SZArchiveExtractor.correctFileName("a/b")                               // Get_Correct_FsFile_Name
try SZArchiveExtractor.createOutputDirectory("/tmp/out/")               // CreateComplexDir + IDS_CANNOT_CREATE_FOLDER 3003
```

`subfolderName(forArchiveNamed:)` is `GetSubFolderNameForExtract` (Explorer/ContextMenu.cpp:448):
the name without its extension, with the inner extension also dropped for `.tar.gz`-style names
and for `.001` / `.part01.rar` volumes, `~` appended when there is no extension at all.

---

## 2. `SZTempOpen` / `SZTempFile` — the temp-folder round trip

`CPanel::OpenItemInArchive` + `CTempFileInfo` + `CVirtFileSystem`, as three calls.

```swift
SZTempOpen.openDirectoryPrefix        // "7zO" -- open / view / edit an item
SZTempOpen.extractDirectoryPrefix     // "7zE" -- drag-out and archive-to-archive copy
let dir = try SZTempOpen.createTemporaryDirectory(prefix: SZTempOpen.extractDirectoryPrefix)
let limit = SZTempOpen.inMemoryLimit(archiveLevelCount: levels)   // RAM >> max(levels+1, 8), else 4 MiB

// BLOCKS; run on the queue that owns `folder`.
let file = try SZTempOpen.extractItem(at: index, of: folder,
                                      archiveFilePath: "/path/to.7z",   // quarantine source
                                      archiveLevelCount: folder.arcProps?.levelCount ?? 1,
                                      zoneMode: .all, progress: runner)

try SZTempOpen.updateItem(at: index, of: folder, fromFilePath: file.filePath, progress: runner)

SZTempOpen.temporaryDirectories()                   // every 7zO*/7zE* folder in the temp dir
SZTempOpen.removeTemporaryDirectory(atPath: dir)    // refuses anything else
SZTempOpen.applyQuarantine(fromArchiveAt: arc, to: path, mode: .office)
```

`SZTempFile` is `CTempFileInfo`: `directoryPath`, `filePath`, `relativePath`, `itemName`,
`itemIndex`, `isDirectory`, `wasHeldInMemory`, `size`, `modificationDate`, plus `wasModified`
(the watcher's size+mtime comparison) and `refreshRecordedAttributes()`.

A small item goes through memory first (`CSZVirtFileSystem`, the `IFolderExtractToStreamCallback`
path), everything bigger and every folder goes straight to disk; if the in-memory attempt fails
the call retries on disk by itself. `updateItem` is `IFolderOperations::CopyFromFile` and answers
`SZError.Code.notImplemented` for a file-system folder, which is what `CFSFolder` does.

---

## 3. The Extract dialog

```swift
var options = ExtractDialog.Options()
options.directoryPath = "/tmp/out/test/"     // DirPath in/out, slash-terminated
options.archivePath = "/tmp/test.7z"         // only for exactly one archive -> caption suffix
options.pathMode = .curPaths
options.overwriteMode = .ask
options.eliminateDuplicateRoot = nil          // Bool?, the caller's CBoolPair
options.restoreFileSecurity = nil
options.summaryLines = ExtractCommands.itemsInfoLines(context)
options.parentWindow = window
guard let answer = ExtractDialog.run(options) else { return }   // nil = Cancel -> E_ABORT
// answer: directoryPath, pathMode, overwriteMode, password, eliminateDuplicateRoot,
//         restoreFileSecurity
```

The dialog reads and writes the `Extraction.*` settings itself, with the
`NExtract::CInfo::Load/Save` rules (see `api/options.md`), and pushes the chosen path to
`Extraction.PathHistory`. Main thread only.

---

## 4. Commands

`Mac/App/Commands/ExtractCommands.swift`, all driven by `ActiveContext.current()` and refreshed
with `ActiveContext.refresh()`:

```swift
ExtractCommands.extractWithDialog()     // kMenuCmdID_Toolbar_Extract 1071 / kExtract
ExtractCommands.extractHere()           // kExtractHere
ExtractCommands.extractToSubfolder()    // kExtractTo (-spe from Options.ElimDupExtract)
ExtractCommands.testArchives()          // kMenuCmdID_Toolbar_Test 1072 / kTest
ItemOpenCommands.open(useEditor: Bool)  // IDM_FILE_VIEW 543 / IDM_FILE_EDIT 544
ItemOpenCommands.openOutside()          // IDM_OPEN_OUTSIDE 542
ItemOpenCommands.diff()                 // IDM_DIFF 554
```

The `@objc` selectors `toolbarExtractArchives(_:)`, `extractHere(_:)`, `extractToSubfolder(_:)`,
`toolbarTestArchives(_:)`, `fileView(_:)`, `fileEdit(_:)` and `fileDiff(_:)` are implemented as
extensions on `MainWindowController`, so the menu and the toolbar reach them through the
responder chain. **The `panel` scope also implements `fileOpenOutside(_:)` on
`PanelViewController` and disables it outside a file-system folder**, so the archive branch of
Open Outside is only reachable by calling `ItemOpenCommands.openOutside()` directly — see the
request added to `ai/requests.md`.

Other useful pieces:

```swift
ExtractCommands.archivePaths(context)        // the ExtractArchives preconditions + error boxes
ExtractCommands.itemsInfoLines(context)      // CApp::GetItemsInfoString (max 11 names + totals)
ExtractCommands.realFileSystemPath(display)  // Reduce_Path_To_RealFileSystemPath
ExtractCommands.normalizeDirectory(path)     // trailing "/"
```

---

## 5. `ArchiveDragOut` — the lazy-extraction hook for the `panel` scope

This is what `panel` needs for `NSFilePromiseProvider` and for a plain drag of archive members
to Finder (01 §3.15, 03 §4.1). Extraction is deferred until the drop, exactly like
`CPanel::OnDrag`'s HDROP, which only names files that *will* exist.

```swift
// 1. While the drag is in flight, report the names Finder should show:
let names = ArchiveDragOut.promisedNames(indices: indices, from: folder)

// 2. At drop time, extract. `to:` is the destination Finder supplied; pass nil to get a fresh
//    7zE<hex> temp folder instead (for receivers that need real paths before the drop
//    completes). Returns nil when the user cancelled; the Progress dialog and the error
//    reporting are handled for you.
guard let (directory, paths) = ArchiveDragOut.extract(indices: indices, from: folder,
                                                      to: destinationPath,       // or nil
                                                      archiveDisplayPath: panel.currentPath,
                                                      parentWindow: view.window,
                                                      overwriteMode: .overwrite) else { return }

// 3. When the receiver is done with a temp folder the hook created:
ArchiveDragOut.removeTemporaryDirectory(directory)
```

Notes for the panel scope:

* `extract` uses `pathMode: .curPaths`, i.e. paths relative to the folder being dragged from,
  which is what `CAgentFolder::CopyTo` does for a drag; a dragged directory keeps its subtree.
* It runs on the `OperationRunner` worker thread, so it must be called on the **main** thread
  (`OperationRunner.run` returns after the dialog closed, like `NSAlert.runModal()`), and the
  `SZFolder` must not be touched elsewhere while it runs.
* `waitMode` is on, so a drag of a few small files shows no dialog at all.
* The `7zE` folder is *not* removed automatically: the source owns it, exactly as on Windows.
  `TempOpenManager` does not track it either — call `removeTemporaryDirectory(_:)`.

---

## 6. Known gaps (see `ai/reports/extract.md` for the full list)

* `-scrc<method>` during extraction (hash-on-the-fly into the hash results dialog) is not wired:
  `Extract()` is called with `IHashCalc = NULL`. It belongs with the `tools` scope's hash dialog.
* `-thash` (testing a `.sha256`-style hash list as an archive) is not passed by the Test command.
* Quarantine on a *plain* extraction is not applied: the engine's `ReadZoneFile_Of_BaseFile` is
  `#if defined(_WIN32)` only, so `zoneIDMode` reaches the engine but has no effect there. The
  temp-open path applies it itself (`SZTempOpen.applyQuarantine`), and the same helper can be
  used to post-process an extraction.
* Diff across two panels needs the *other* panel's focused item, which the frozen
  `OperationContext` does not expose; only "two items selected in one panel" works.

---

## Note — 2026-09-20 (`mac/cleanup`)

Two of §6's gaps are closed; this section is appended rather than rewritten, so the text above
still describes what the `extract` scope shipped.

* **`ArchiveDragOut` is now the only drag-out path.** `PanelViewController.extractForPromise`
  (`Mac/App/Panel/PanelDragDrop.swift`) calls `ArchiveDragOut.extract(indices:from:to:...)`; the
  panel's own `IFolderOperations::CopyTo` call is gone, and with it the wrong path mode (a dragged
  directory now keeps its subtree, because §5's `kCurPaths` is used). `promisedNames` is *not*
  called: the promise reports the row's cached name, since the folder must not be read on the main
  thread (`api/panel.md` §1); it is the same string. The panel queue is parked from the promise
  queue for the duration, which is the ownership rule `runFolderOperation` used to give.
  **Open:** `extract(...)` has no `password:` parameter, so a drag-out of a member of an archive the
  panel already unlocked asks for the password again (`requests.md`).
* **`-scrc<method>` is wired.** `SZExtractOptions.hashMethods` (`NSArray<NSString *>`, **empty =
  off**) hands `Extract()` a `CHashBundle` instead of NULL, and `SZExtractResult.hashResults` is an
  `SZHashResults` ready for `HashResultsDialog.show(results:parent:)`. Its rows are the ones
  `GUI/ExtractGUI.cpp:129-136` builds: `Archives:` = `statistics.archiveCount` and `Packed Size` =
  `statistics.packSize`, then `AddHashBundleRes`. It is nil unless the run finished with `isOK`,
  and when it is non-nil **`testSummary` is nil** — Windows shows the hash list *instead* of the
  test statistics box (`if (HashBundle) … else if (TestMode) …`, `:131-152`). `fileResults` is
  empty there: upstream's extract path has no per-file hash hook.
  No command passes `hashMethods` yet; 7zFM's Extract dialog has no such control, so the call site
  is the command-line front end (`requests.md`).

```swift
let options = SZExtractOptions()
options.hashMethods = ["SHA256"]          // or ["*"]; [] (the default) changes nothing
let result = try SZArchiveExtractor.testArchives(at: paths, options: options, progress: runner)
if let hashes = result.hashResults { HashResultsDialog.show(results: hashes, parent: window) }
```

Covered by `Mac/Tests/SevenZipKitTests/{DragOutPromiseTests,ExtractHashTests}.swift`; the digests
are cross-checked against `7zz x -scrcSHA256` / `7zz t -scrcSHA256`. See
`ai/reports/cleanup.md`.

---

## Note — 2026-10-03 (`mac/opsgaps`)

* **§6's quarantine gap is closed.** `zoneIDMode` now has its Windows effect: the engine's
  `ReadZoneFile_Of_BaseFile` / `WriteZoneFile_To_BaseFile` are enabled on `__APPLE__` and carry
  `com.apple.quarantine` (upstream patch, `Mac/docs/upstream-patches.md`), so `.all` copies the
  archive's attribute onto every extracted file, `.office` onto upstream's `kOfficeExtensions` only,
  and nothing is written for an archive that has none. `SZTempOpen.applyQuarantine` is still what
  temp-open uses. Extract inside an archive (`ExtractCommands.extractFromArchiveFolder`) passes
  `SZFolder.registryZoneMode` through the new `extractItems(...zoneMode:zoneSourcePath:...)`
  (`api/opsinfra.md`, note of the same date).
* **§6's `-thash` gap is closed for the Test command**: `ExtractCommands.testArchives()` hands a
  selection made only of checksum files (`ExtractCommands.areChecksumFiles(_:)`) to
  `CommandExecutor.run(argv: ["t", "-thash", "--", ...])`.
* `SZArchiveExtractor` gives `E_OUTOFMEMORY` without an engine text the IDS_MEM_ERROR 3000 message.
* The Extract dialog's Help button opens the bundled `fm/plugins/7-zip/extract.htm` (`api/tools.md`).
