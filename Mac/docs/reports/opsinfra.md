# opsinfra — operation infrastructure (branch `mac/opsinfra`)

The shared machinery every long-running operation in the app uses: the COM callback adapters,
the `SZFolderOperations` bridge API, the Swift `OperationRunner`, and the Progress / Overwrite
/ Password / Messages / Memory dialogs. **Public API: `Mac/docs/api/opsinfra.md`** — wave-3
scopes (`panel`, `extract`, `compress`, `tools`) code against that file.

## 1. What was implemented

### Bridge (`Mac/Core/`)

* `include/SZProgressDelegate.h` — extended (the 11 original required methods are unchanged):
  `SZProgressStatus` (raw value **is** the 7-Zip lang string ID), `SZMemoryUseAnswer`, and
  optional callbacks `progressSetTotalFiles:`, `progressSetStatus:`,
  `progressSetTitleFileName:`, `progressScanFolders:…`,
  `progressAskPasswordForEncryptionCancelled:`, `progressRequestMemoryUseForPath:…`,
  `progressMoveArchiveFrom:toPath:size:` / `…Completed:total:` / `…Finished`,
  `progressClearCancelState`.
* `Internal/SZCallbackAdapters.{h,mm}` — `CSZCallbackBase` (strong delegate, `CheckBreak()`,
  message/status helpers, password cache) plus three adapters:
  * `CSZExtractCallbackAdapter`: `IProgress`, `IFolderArchiveExtractCallback(2)`,
    `IFolderOperationsExtractCallback`, `ICryptoGetTextPassword`, `ICompressProgressInfo`,
    `IArchiveRequestMemoryUseCallback`, `IArchiveOpenCallback`.
  * `CSZUpdateCallbackAdapter`: `IFolderArchiveUpdateCallback(2)`, `…_MoveArc`,
    `IFolderScanProgress`, `ICryptoGetTextPassword(2)`, `ICompressProgressInfo`,
    `IArchiveOpenCallback`.
  * `CSZProgressAdapter`: bare `IProgress`.
  Every entry point calls `CheckBreak()` first, so cancel returns `E_ABORT` and pause blocks
  inside the delegate. Refcounts are non-atomic (`MyCom.h:380`), so the header documents the
  one-thread ownership rule and the `CMyComPtr2 + Create_if_Empty()` pattern.
* `include/SZFolderOperations.h` + `SZFolderOperations.mm` — category on `SZFolder`:
  `copyItems(at:toPath:)`, `moveItems(at:toPath:)`,
  `copyItems(named:fromFolderPath:moveMode:)` (`CopyFrom`), `deleteItems(at:)`,
  `renameItem(at:to:)`, `createFolder(named:)`, `createFile(named:)`,
  `setComment(_:forItemAt:)`, `calcSize(at:)`,
  `extractItems(at:toPath:pathMode:overwriteMode:testMode:)` → `SZOperationSummary`
  (`filesProcessed`, `errorCount`, `firstFailure`, `passwordWasAsked`), plus the three
  capability properties. `E_NOTIMPL` surfaces as `SZErrorCodeNotImplemented` carrying the
  lang-6008 text.
* `include/SevenZipKit.h` — one additive `#import` (shared file, additive-only edit).

### App (`Mac/App/`)

* `Dialogs/ProgressDialogSupport.swift` — `ProgressSync` (the `CProgressSync` equivalent:
  lock-protected worker/UI hand-off; `checkStop()` returns the cancel flag and sleeps 100 ms
  while paused), `ProgressSnapshot`, `ProgressFormatting`, `MessageListView` (numbered rows,
  Cmd+A / Cmd+C), `DialogKit`.
* `Dialogs/ProgressDialog.swift` — `IDD_PROGRESS 97` with every field, button and label of
  01b §4.17, the `"<Paused> <NN%> <Title> <Background> <fileName>"` title, the embedded
  message list that appears with the first message, and the "keep the window open when
  messages were collected" end state (Cancel → Close, Pause/Background hidden).
* `Dialogs/OverwriteDialog.swift` (`IDD_OVERWRITE 3500`), `Dialogs/PasswordDialog.swift`
  (`IDD_PASSWORD 3800` + the compress-side verify field `3802` and "Encrypt file names"
  `4016` behind `Options`), `Dialogs/MessagesDialog.swift` (`IDD_MESSAGES 6602`),
  `Dialogs/MemoryUseDialog.swift` (`IDD_MEM 7800`).
* `Support/OperationRunner.swift` — `OperationRunner.run(_:work:completion:)`: worker thread,
  `WaitMode` (no dialog under 500 ms without messages), 200 ms tick, progress dialog
  ownership, modal question dialogs, cancel / pause / background, final error and OK message
  boxes, `collectedMessages`, `password` / `passwordWasAsked` / `encryptFileNames`.
* `Commands/OpsInfraDemo.swift` — verification harness behind `SZ_OPSINFRA_DEMO`
  (`extract` / `errors` / `dialogs`), reached from one additive line in `MainMenu.build()`.

### Tests

`Mac/Tests/SevenZipKitTests/FolderOperationsTests.swift` — 15 new tests (the pre-existing
file was not touched).

## 2. Mapping to the Windows behaviour

| macOS piece | Windows original |
|---|---|
| `CSZExtractCallbackAdapter` | `CExtractCallbackImp` (`FileManager/ExtractCallback.cpp`), 01 §8.4 |
| `AskWrite` port | `ExtractCallback.cpp:710-800` (`AutoRenamePath`, delete-then-write), 01 §8.4 |
| `RequestMemoryUse` port | `ExtractCallback.cpp:1012-1120` + `CMemDialog`, 01b §4.12 |
| `CSZUpdateCallbackAdapter` | `CUpdateCallback100Imp` / `CUpdateCallbackGUI2`, 01 §8.5, 02 §2.5.3 |
| `SZFolderOperations` | `IFolderOperations` + `IArchiveFolder::Extract`, 02 §2.1/§2.2, 01 §3.10/§3.11/§8.1 |
| `ProgressSync` | `CProgressSync` (`ProgressDialog2.h:32-103`), 01 §8.7, 02 §2.5.4 |
| `OperationRunner` | `CProgressThreadVirt` + `CProgressDialog` (`ProgressDialog2.cpp:1412-1475`), 01b §4.17 |
| `ProgressDialog` | `IDD_PROGRESS 97` (`ProgressDialog2a.rc`), 01b §4.17 |
| `OverwriteDialog` / `PasswordDialog` / `MessagesDialog` / `MemoryUseDialog` | `IDD_OVERWRITE 3500` / `IDD_PASSWORD 3800` / `IDD_MESSAGES 6602` / `IDD_MEM 7800`, 01b §4.15/§4.16/§4.14/§4.12 |

Deliberate macOS mappings:

* **Background** (`IDB_PROGRESS_BACKGROUND 444`) changes the *process* priority as on Windows
  (`SetPriorityClass(IDLE_PRIORITY_CLASS)`), using the Darwin background band
  (`setpriority(PRIO_DARWIN_PROCESS, 0, PRIO_DARWIN_BG)`), not a UI change.
* The Overwrite dialog shows one icon per file; Windows has two icon statics and only fills
  the second when the type icon differs from the file icon.
* `Lang` IDs are used for every label; button mnemonics are stripped by `Lang.text`.

## 3. What was verified and how

* `Mac/scripts/test.sh`: **32/32 tests pass** (15 new). The new tests drive real fixture
  archives through `SZFolderOperations`: callback order for a `test.7z` extraction (status and
  title before data, `SetTotal` before the first `SetCompleted`, monotonic completion, current
  file before its result, `SetRatioInfo` seen, 6 results = 4 files + 2 directories, files on
  disk with the right sizes), selected-item extraction with `.noPaths`, test mode writing
  nothing, cancel → `SZError.Code.cancelled`, password delegate unlocking `secret.zip` and
  `secret.7z` (encrypted headers), a wrong password producing per-item failures flagged
  encrypted and named, password-Cancel → cancelled, `.ask` overwrite asked once for "No to
  All", `calcSize` = 3043 / 3010 / 12 on the fixture tree and 350 on a real directory
  (BindToFolder fallback), the file-system folder's clear `notImplemented` error, the refusal
  of move-out-of-archive, and copy-out through `IFolderOperations::CopyTo`.
* Running app, driven with `osascript` (System Events, **PID-targeted** so sibling agents'
  `7-Zip.app` instances are never touched), screenshots in
  `Mac/docs/reports/screenshots/opsinfra-*.png`:
  * `opsinfra-progress.png` — all fields, Background / Pause / Cancel.
  * `opsinfra-progress-paused.png` — title "Paused 8% Extracting test.7z", button "Continue",
    percent frozen while paused; Continue resumes (8% → 11%).
  * `opsinfra-progress-background.png` — title "13% Extracting Background test.7z", button
    "Foreground"; the demo logs the Darwin band going `0 → 1 → 0`.
  * `opsinfra-cancel-confirm.png` — the Yes / No / Cancel question (lang 448) after the
    automatic pause; **No** keeps the operation running (19% → 23%), **Yes** aborts
    (`checkBreak -> cancelling`, the run ends with `cancelled` and the window closes).
  * `opsinfra-progress-messages.png` — after a run with messages: Errors row, numbered message
    list, the window stays open and the button reads "Close".
  * `opsinfra-overwrite.png`, `opsinfra-password.png`, `opsinfra-password-compress.png`,
    `opsinfra-messages.png`, `opsinfra-memory.png` — the four question dialogs; the demo log
    confirms the answers (Auto Rename returned `readme (2).txt`, the password dialog returned
    the typed text, Memory returned allow with limit 6).
* Clean verification from an empty `Mac/build`: `rm -rf Mac/build && Mac/scripts/build.sh &&
  Mac/scripts/test.sh` — both exit 0 (`** BUILD SUCCEEDED **`, `Executed 32 tests, with 0 failures`), no warnings in `Mac/` code.

Two real bugs were found by the live verification and fixed:

1. the worker-finished notification posted with `DispatchQueue.main.async` is **not delivered
   while `NSApp.runModal` is running**, so the dialog never closed after a cancel; the 200 ms
   tick now notices `sync.isFinished` (the `CheckNeedClose` equivalent, `ProgressDialog2.cpp:1296`);
2. dialogs were sized from the host view's stale fitting size, which cut the Overwrite dialog's
   second button row; they are now sized from the content's fitting size after an explicit
   layout pass.

## 4. Findings and deviations

* **7zFM has no "Auto Rename Existing" button.** `NOverwriteAnswer` (`IFileExtractCallback.h:22-34`)
  has six values and lang `3425` (`IDS_EXTRACT_OVERWRITE_RENAME_EXISTING`) is an *Extract-dialog
  overwrite mode*, not a button of `IDD_OVERWRITE`. The dialog therefore has the six real
  buttons (Yes / Yes to All / Auto Rename / No / No to All / Cancel). Also recorded in
  `Mac/docs/requests.md`.
* `AskWrite` does not special-case `kRenameExisting`; neither does the Windows original — the
  existing-file rename happens inside `CArchiveExtractCallback`, not in the folder-copy path.
* `IArchiveFolder::Extract` never calls `SetNumFiles`, so a "Files: n / total" total is only
  reported when the selection contains no directories (otherwise the counter would exceed the
  total, as it counts every written entry).
* `SZOperationSummary.filesProcessed` counts archive directories too, because the engine
  reports a result for them (6 for the 4-file fixture).

## 5. Known gaps / follow-ups

* Dock-tile progress mirroring (the `ITaskbarList3` equivalent, 01 §9 #16) is not implemented;
  the corresponding progress-bar box stays unticked.
* The progress message list uses fixed column widths instead of re-measuring them on each tick.
* `CVirtFileSystem`, the full `IOpenCallbackUI` chain and quarantine writing stay with the
  `extract` scope; the adapters already expose `IArchiveOpenCallback` for it.
* The exception → message mapping box (`CProgressThreadVirt::Process`, `ErrorPaths`, "a message
  with `S_OK` forces `E_FAIL`") stays unticked: the C++ ladder lives in `SZRunCatching`
  (scaffold) and the Swift side only maps `E_ABORT` to silence plus everything else to an
  alert.
* Open request in `Mac/docs/requests.md`: reading the preferences domain from
  `SEVENZIP_DEFAULTS_SUITE` touches `Mac/Core/SZSettings.mm`, which is outside this scope's
  ownership — left for the bridge owner.

## 6. `Mac/docs/PROGRESS.md` boxes ticked

All 23 ticks are in **section 4 (`extract`)**, because the shared dialogs and the extract-side
callbacks live there; this scope has no section of its own:

* §4.3 (7 boxes): `AskOverwrite`, `AskWrite`, `PrepareOperation`, `SetOperationResult` /
  `ReportExtractResult`, `MessageError` / `ShowMessage` / `SetRatioInfo`, password prompting,
  `RequestMemoryUse`.
* §4.4 (11 of 13): labels/values, status + file name, message list, Background, Pause,
  Cancel/close, creation + WaitMode, 200 ms timer, title, completion, one serial queue per
  operation. Left unticked: the progress bar's Dock-tile mirror and the exception → message
  mapping.
* §4.5 (5 boxes): Overwrite layout, Overwrite buttons, Password, Messages, Memory dialogs.

## Appendix — state log (written as the work progressed)

### Phase 1-2 done — callback adapters + SZFolderOperations

* `Mac/Core/include/SZProgressDelegate.h` — extended: `SZProgressStatus` (raw value = the
  7-Zip lang string ID), `SZMemoryUseAnswer`, and optional callbacks
  (`progressSetTotalFiles:`, `progressSetStatus:`, `progressSetTitleFileName:`,
  `progressScanFolders:...`, `progressAskPasswordForEncryptionCancelled:`,
  `progressRequestMemoryUseForPath:...`, `progressMoveArchive*`, `progressClearCancelState`).
  The 11 original required methods are unchanged.
* `Mac/Core/Internal/SZCallbackAdapters.{h,mm}` — `CSZCallbackBase` (delegate holder,
  `CheckBreak`, message/status helpers, password cache), `CSZExtractCallbackAdapter`
  (IProgress + IFolderArchiveExtractCallback(+2) + IFolderOperationsExtractCallback +
  ICryptoGetTextPassword + ICompressProgressInfo + IArchiveRequestMemoryUseCallback +
  IArchiveOpenCallback), `CSZUpdateCallbackAdapter` (IFolderArchiveUpdateCallback(+2) +
  MoveArc + IFolderScanProgress + ICryptoGetTextPassword(2) + ICompressProgressInfo +
  IArchiveOpenCallback), `CSZProgressAdapter` (bare IProgress).
  `AskWrite` is a port of `CExtractCallbackImp::AskWrite` (ExtractCallback.cpp:710-800) and
  honours the dialog's Auto Rename suggestion; `RequestMemoryUse` ports
  ExtractCallback.cpp:1012-1120. Refcounts are non-atomic: one adapter belongs to one
  thread (documented in the header).
* `Mac/Core/include/SZFolderOperations.h` + `Mac/Core/SZFolderOperations.mm` — category on
  `SZFolder`: copy/move items, `copyItems(named:fromFolderPath:moveMode:)` (CopyFrom),
  delete, rename, createFolder, createFile, setComment, `calcSize`, and
  `extractItems(at:toPath:pathMode:overwriteMode:testMode:)` (IArchiveFolder::Extract)
  returning `SZOperationSummary`. `E_NOTIMPL` (the file-system folder until `fsfolder`
  lands its operations) surfaces as `SZErrorCodeNotImplemented` with lang 6008 text.
* `Mac/Core/include/SevenZipKit.h` — one additive `#import` (allowed shared file).

Builds clean (`Mac/scripts/build.sh`). Next: Phase 3 `OperationRunner.swift`.

### Phase 5a done — bridge unit tests

`Mac/Tests/SevenZipKitTests/FolderOperationsTests.swift` (15 tests, all green together with
the 17 pre-existing ones): callback order for a real `test.7z` extraction (status and title
before data, `SetTotal` before the first `SetCompleted`, monotonic completion, current file
before its result, `SetRatioInfo` seen, 6 results = 4 files + 2 dirs, files on disk with the
right sizes), selected-items extraction with `.noPaths`, test mode writing nothing, cancel →
`SZError.Code.cancelled`, password delegate unlocking `secret.zip` and `secret.7z` (encrypted
headers), wrong password → per-item failures flagged encrypted with the item name, password
Cancel → cancelled, `.ask` overwrite asked once for "No to All", `calcSize` = 3043 / 3010 / 12
for the fixture tree and 350 for a real directory (BindToFolder fallback), file-system
`IFolderOperations` reporting a clear `notImplemented`, archive move refused, copy-out through
`IFolderOperations::CopyTo`.

Adapters now report the current item path with each operation result
(`CExtractCallbackImp::_currentFilePath`).

### Phases 3-4 + UI verification done (WIP stop point)

**Done and verified in the running app** (screenshots in `Mac/docs/reports/screenshots/`):

* `Mac/App/Dialogs/ProgressDialogSupport.swift` — `ProgressSync` (CProgressSync: lock-protected
  worker/UI hand-off, `checkStop()` blocks while paused, 100 ms), `ProgressSnapshot`,
  `ProgressFormatting` (elapsed/remaining/speed/ratio/percent/two-line path/ReduceString),
  `MessageListView` (numbered list, Cmd+A / Cmd+C), `DialogKit` (control + window factories).
* `Mac/App/Dialogs/ProgressDialog.swift` — IDD_PROGRESS 97 with every field of 01b §4.17
  (elapsed 3900/120, remaining 3901/121, files 1032/111 + 112, errors 3906/126, total 3902/122,
  speed 3903/123, processed 3904/124, packed 1008/110, ratio 3905/125, status 103, file name 102,
  bar 100, message list 101), Background 444/445, Pause 446/411, Cancel→Close 402/408, the
  `"<Paused> <NN%> <Title> <Background> <file>"` title, the Yes/No/Cancel cancel question (448)
  with auto-pause, and "keep the window open when messages were collected".
* `OverwriteDialog.swift` (3500: Yes / Yes to All / Auto Rename / No / No to All / Cancel — 7zFM
  has no "Auto Rename Existing" *button*; 3425 is an Extract-dialog *mode*), `PasswordDialog.swift`
  (3800 + compress-side verify 3802 and Encrypt file names 4016 behind `Options`),
  `MessagesDialog.swift` (6602), `MemoryUseDialog.swift` (7800 with spin limit, Action radios,
  Repeat checkbox, Continue/Cancel).
* `Mac/App/Support/OperationRunner.swift` — `OperationRunner.run(_:work:completion:)`: runs the
  blocking bridge call on a dedicated thread, is itself the `SZProgressDelegate`, owns the
  Progress dialog, 200 ms tick, WaitMode (no dialog under 500 ms without messages), cancel
  (auto-pause → Yes/No/Cancel → `E_ABORT`), pause, Background (Darwin process band, verified
  0→1→0), the final error/OK message boxes and the message list.
* `Mac/App/Commands/OpsInfraDemo.swift` + one additive line in `MainMenu.build()`
  (`OpsInfraDemo.installIfRequested()`), modes `extract` / `errors` / `dialogs` behind
  `SZ_OPSINFRA_DEMO`.
* Verified by driving the running app with `osascript` (System Events, PID-targeted so sibling
  agents' apps are untouched): progress fields, Pause freezes the percent and retitles
  "Paused …", Continue resumes, Background retitles + switches the process band, Cancel→No keeps
  running, Cancel→Yes aborts and closes, the errors run keeps the window open with the message
  list and a Close button, and all four question dialogs appear and answer
  (Auto Rename returned `readme (2).txt`, memory returned allow/limit 6).
* Two real bugs found and fixed while verifying: the worker-finished notification is not
  delivered by `DispatchQueue.main.async` inside `NSApp.runModal` (now the 200 ms tick notices
  it, like `CheckNeedClose`), and dialogs were sized from the host view's stale fitting size
  (now from the content's).

**Half-done / next steps**

1. `Mac/docs/api/opsinfra.md` is NOT written yet — the public API is: ObjC
   `SZFolderOperations` (category on `SZFolder`) + `SZOperationSummary` + the extended
   `SZProgressDelegate`; Swift `OperationRunner.Options` / `.run(_:work:completion:)` and the
   five dialogs (`ProgressDialog`, `OverwriteDialog.run(oldFile:newFile:…)`,
   `PasswordDialog.run(_:parent:)` / `.askPassword(forPath:parent:)`,
   `MessagesDialog.show(messages:parent:)`, `MemoryUseDialog.run(_:parent:)`).
2. `Mac/docs/PROGRESS.md` boxes not ticked yet (the shared-dialog items live in the `extract`
   section).
3. Last state: `Mac/scripts/build.sh` SUCCEEDED and `Mac/scripts/test.sh` passed 32/32 at the
   previous commit; the only changes after that test run are dialog sizing, the timer-driven
   finish check, the files-total fix and the demo — all of which built cleanly. A final clean
   `rm -rf Mac/build && build && test` has not been run.
4. Screenshots were re-captured after the sizing fix; `opsinfra-overwrite.png` from the last
   pass shows the full six-button layout (520x312 pt window).
