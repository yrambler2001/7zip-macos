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
