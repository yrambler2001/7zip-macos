# opsinfra — operation infrastructure (branch `mac/opsinfra`)

Shared machinery every long-running operation uses: the COM callback adapters, the
`SZFolderOperations` API, the Swift `OperationRunner`, and the Progress / Overwrite /
Password / Messages / Memory dialogs. Public API: `Mac/docs/api/opsinfra.md`.

## State log

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
