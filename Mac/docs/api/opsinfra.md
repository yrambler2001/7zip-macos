# `opsinfra` — public API (operation infrastructure)

Everything a scope needs to run a long engine operation with the 7zFM progress machinery:
the Objective-C operation surface (`SZFolderOperations`, `SZProgressDelegate`), the Swift
`OperationRunner`, and the five shared dialogs. Code against this file; you do not need to
read the sources.

Parity references: `01-fm-feature-inventory.md` §8.1-8.7, `01b-fm-dialogs-settings.md`
§4.12, §4.14-§4.17, `02-engine-api.md` §2.1, §2.2, §2.5.

---

## 1. Threading in one paragraph

Every bridge call listed in §2 **blocks the calling thread** for the whole operation and must
run **off the main thread**, on the queue that owns the `SZFolder` (engine COM refcounts are
not atomic — never touch one folder from two threads). While it blocks, the engine calls your
`id<SZProgressDelegate>` **on that same worker thread**, many times per second and sometimes
from several engine threads at once, so a delegate must be thread-safe and must not touch
AppKit directly. `OperationRunner` (§5) is the ready-made delegate: it stores everything in a
lock-protected snapshot, refreshes the UI from a 200 ms main-thread tick, and blocks the
worker while a question dialog runs modally on the main thread. Cancellation and pause are
both surfaced through **one** delegate method, `progressCheckBreak`: returning `YES` makes the
current call return `E_ABORT` (the operation then fails with `SZError.Code.cancelled`), and
blocking inside it is what "Pause" means (`CProgressSync::CheckStop`, 100 ms loop).

---

## 2. `SZFolderOperations` (ObjC, `SevenZipKit`)

A category on `SZFolder`; import `SevenZipKit`. All methods are synchronous, take an optional
`id<SZProgressDelegate>`, and report failures as `NSError` (Swift `throws`) in `SZErrorDomain`
with the codes from `SZError.Code` (`.cancelled` for `E_ABORT`, `.notImplemented` for an
operation the folder does not provide, `.wrongPassword`, `.engine`, …).

### Capabilities (cheap, no engine work)

| Swift | Meaning |
|---|---|
| `folder.supportsOperations` | folder implements `IFolderOperations` (copy/move/delete/rename/create/comment) |
| `folder.supportsArchiveExtract` | folder implements `IArchiveFolder` (extract / test its items) |
| `folder.supportsCalcItemFullSize` | folder computes recursive sizes itself (otherwise `calcSize` walks the tree) |

### Operations

```swift
// Copy / move the selected items out of this folder into a directory.
try folder.copyItems(at: [NSNumber], toPath: String, progress: SZProgressDelegate?)
try folder.moveItems(at: [NSNumber], toPath: String, progress: SZProgressDelegate?)

// CopyFrom: bring files *into* this folder (add to an archive folder / paste into a dir).
// `itemNames` are relative to `folderPath`.
try folder.copyItems(named: [String], fromFolderPath: String, moveMode: Bool,
                     progress: SZProgressDelegate?)

try folder.deleteItems(at: [NSNumber], progress: SZProgressDelegate?)
try folder.renameItem(at: Int, to: String, progress: SZProgressDelegate?)
try folder.createFolder(named: String, progress: SZProgressDelegate?)
try folder.createFile(named: String, progress: SZProgressDelegate?)
try folder.setComment(String, forItemAt: Int, progress: SZProgressDelegate?)   // kpidComment

// Recursive size of the items (nil never returned on success; throws on error/cancel).
let total: NSNumber = try folder.calcSize(at: [NSNumber], progress: SZProgressDelegate?)

// IArchiveFolder::Extract -- panel copy-out, drag-out and Test inside an archive.
// `at: nil` (or an empty array) takes every item of the folder.
let summary: SZOperationSummary =
    try folder.extractItems(at: [NSNumber]?, toPath: String,
                            pathMode: SZExtractPathMode,       // .fullPaths .curPaths .noPaths .absPaths .noPathsAlt
                            overwriteMode: SZOverwriteMode,    // .ask .overwrite .skip .rename .renameExisting
                            testMode: Bool,
                            progress: SZProgressDelegate?)
```

Notes that matter:

* The destination path may be given with or without a trailing `/`; the bridge normalises it.
* `moveItems` inside an archive fails with `.notImplemented` — that is 7zFM's behaviour
  (`CAgentFolder::CopyTo` refuses `moveMode`); copy out, then delete.
* The **file-system** folder declares `IFolderOperations`; its methods are implemented by the
  `fsfolder` scope. Anything still missing surfaces as `.notImplemented` with the lang-6008
  text "The operation is not supported for this folder. (FSFolder: CopyTo)".
* `extractItems` reports a *file total* only when no directory is selected (the Agent's
  `Extract` has no `SetNumFiles`, and a directory's contents are counted as they are written).
* Overwrite handling: pass `.ask` to get the Overwrite dialog through the delegate; the
  "…to All" answers switch the mode for the rest of the call, exactly like `CExtractCallbackImp`.

### `SZOperationSummary`

```swift
summary.filesProcessed   // UInt64: items whose result arrived (7zFM's "Files" counter;
                         //         archive directories count too)
summary.errorCount       // Int: messages + per-item failures collected
summary.firstFailure     // SZOperationResult: .OK when nothing failed
summary.passwordWasAsked // Bool: remember the password on your folder chain (CFolderLink)
```

---

## 3. `SZProgressDelegate` (ObjC protocol, `SevenZipKit`)

Implement it yourself only if you need something `OperationRunner` does not do. All methods
run on the worker thread.

**Required**

| Method (Swift) | Engine source |
|---|---|
| `progressSetTotal(_: UInt64)` | `IProgress::SetTotal` |
| `progressSetCompleted(_: UInt64)` | `IProgress::SetCompleted` (may arrive from several threads) |
| `progressSetRatioInfo(inSize:outSize:)` | `ICompressProgressInfo::SetRatioInfo` |
| `progressSetCurrentFile(_:isDirectory:)` | `PrepareOperation` / `SetCurrentFilePath` |
| `progressSetNumFilesProcessed(_: UInt64)` | running item count (incremented per result) |
| `progressAskOverwriteExisting(_:existTime:existSize:newName:newTime:newSize:suggestedName:) -> SZOverwriteAnswer` | `AskOverwrite`; write a name into `suggestedName` for `.autoRename` |
| `progressAskPassword(forPath:) -> String?` | `ICryptoGetTextPassword`; `nil` = Cancel → `E_ABORT` |
| `progressShowMessage(_: String)` | `MessageError` / `ShowMessage` |
| `progressSetOperationResult(_:path:isEncrypted:)` | per-item result (`path` = the item just processed) |
| `progressCheckBreak() -> Bool` | `YES` = cancel; **block here to pause** |

**Optional** (the adapters check `respondsToSelector:`)

| Method (Swift) | Engine source |
|---|---|
| `progressSetTotalFiles(_: UInt64)` | `SetNumFiles` — the *total* |
| `progressSetStatus(_: SZProgressStatus)` | status line; `rawValue` **is** the lang string ID |
| `progressSetTitleFileName(_: String)` | `Set_TitleFileName` (window title / password prompt) |
| `progressScanFolders(_:files:totalSize:path:isDirectory:)` | `IFolderScanProgress::ScanProgress` |
| `progressAskPassword(forEncryptionCancelled:) -> String?` | `ICryptoGetTextPassword2`; `nil` + `cancelled = false` means "no password" |
| `progressRequestMemoryUse(forPath:requiredSize:allowedSize:testMode:allowSkipArchive:) -> SZMemoryUseAnswer` | `IArchiveRequestMemoryUseCallback` (`allowedSize` is in/out) |
| `progressMoveArchive(from:toPath:size:)`, `progressMoveArchiveCompleted(_:total:)`, `progressMoveArchiveFinished()` | `IFolderArchiveUpdateCallback_MoveArc` |
| `progressClearCancelState()` | `Before_ArcReopen` — clear your cancel flag so the re-open works |

`SZProgressStatus` values (raw value = lang ID): `.extracting` 3300, `.compressing` 3301,
`.testing` 3302, `.opening` 3303, `.scanning` 3304, `.removing` 3305, `.add` 3320,
`.update` 3321, `.analyze` 3322, `.replicate` 3323, `.repack` 3324, `.skipping` 3325,
`.delete` 3326, `.header` 3327, `.copying` 6004, `.moving` 6005, `.renaming` 6006,
`.deleting` 6106, `.checksum` 7500, `.none` 0.
`SZMemoryUseAnswer`: `.allow`, `.skipArchive`, `.stop` (→ `E_ABORT`).

---

## 4. C++ callback adapters (`Mac/Core/Internal/SZCallbackAdapters.h`)

Only `.mm` files inside `Mac/Core/` can use these; they turn an `id<SZProgressDelegate>` into
the COM callbacks the engine wants. `SZFolderOperations` uses them; `SZExtractor`,
`SZUpdater` and `SZHasher` (extract / compress / tools scopes) should too instead of writing
their own.

| Class | Implements | Use for |
|---|---|---|
| `CSZExtractCallbackAdapter` | `IProgress`, `IFolderArchiveExtractCallback(2)`, `IFolderOperationsExtractCallback`, `ICryptoGetTextPassword`, `ICompressProgressInfo`, `IArchiveRequestMemoryUseCallback`, `IArchiveOpenCallback` | `IArchiveFolder::Extract`, `IInFolderArchive::Extract`, `IFolderOperations::CopyTo`, `UI/Common/Extract.cpp` |
| `CSZUpdateCallbackAdapter` | `IFolderArchiveUpdateCallback(2)`, `…_MoveArc`, `IFolderScanProgress`, `ICryptoGetTextPassword`, `ICryptoGetTextPassword2`, `ICompressProgressInfo`, `IArchiveOpenCallback` | `IFolderOperations::CopyFrom/Delete/Rename/CreateFolder/SetProperty`, `IOutFolderArchive::DoOperation` |
| `CSZProgressAdapter` | `IProgress` | anything that only takes an `IProgress` |

Fields worth knowing: `Delegate` (strong), `ArchivePath` (shown in the password prompt),
`OverwriteMode`, `TestMode`, `NumFilesProcessed`, `NumErrors`, `FirstBadOpRes`,
`Password`/`PasswordIsDefined`/`PasswordWasAsked`, `SuggestedName`, `CurrentFilePath`,
`AskPasswordForEncryption`; `AsProgress()` returns an unambiguous `IProgress*`.

**Ownership rule.** `CMyUnknownImp` refcounts are plain `++`/`--` (`Z7_COM_USE_ATOMIC` is not
defined), so an adapter belongs to exactly **one thread**: create it with
`CMyComPtr2<iface, cls> cb; cb.Create_if_Empty();` on the worker thread that runs the
operation, pass `cb.Interface()` to the engine, and let the local `CMyComPtr2` release it
there. Never store one in an Objective-C object that could outlive the call or be released
from another thread. Every entry point calls `CheckBreak()` first, so cancel/pause work
everywhere for free.

---

## 5. `OperationRunner` (Swift, app target)

One call does everything 7zFM's `CProgressThreadVirt` + `CProgressDialog` + `CProgressSync`
trio does.

```swift
struct OperationRunner.Options {
    var title: String                       // operation name in the title ("Extracting")
    var mainTitle: String = "7-Zip"         // message-box title
    var initialStatus: SZProgressStatus = .none
    var showCompressionInfo = false         // Compressed size / Compression ratio rows
    var parentWindow: NSWindow?             // dialogs are centred over it
    var waitMode = true                     // no dialog at all if done < 500 ms without messages
    var okMessage: String?                  // info box after a clean run (test summary)
    var titleFileName: String = ""          // archive shown in the title and password prompt
    var asksPasswordForEncryption = false   // compress side (ICryptoGetTextPassword2)
    var showsEncryptFileNames = false       // its "Encrypt file names" checkbox
    var password: String?                   // pre-seeded (CFolderLink remembers it)
    init(title: String)
}

@discardableResult
static func OperationRunner.run<T>(_ options: Options,
                                   work: @escaping (OperationRunner) throws -> T,
                                   completion: ((Result<T, Error>) -> Void)? = nil) -> Result<T, Error>
```

* **Call `run` on the main thread.** It starts `work` on a dedicated 8 MB thread, shows the
  Progress dialog, runs a modal session, and **returns after the dialog has closed**, with the
  result (`completion` is called with the same value just before it returns). Treat it like
  `NSAlert.runModal()`.
* `work` receives the runner, which **is** the `SZProgressDelegate` — pass it straight to
  `SZFolderOperations` (or to `SZExtractor`/`SZUpdater`). Whatever `work` returns becomes the
  success value; whatever it throws becomes the failure.
* A cancelled run fails with `SZError.Code.cancelled` and shows no message box (`E_ABORT` is
  silent). Other failures raise a critical alert with `error.localizedDescription`. `okMessage`
  is shown only when the run produced no messages.
* If messages were collected, the dialog stays open at the end (Cancel becomes Close), exactly
  like `MessagesDisplayed`; read them afterwards with `runner.collectedMessages` and re-show
  them with `MessagesDialog.show(messages:)`.
* Useful properties after the run: `password`, `passwordWasAsked`, `encryptFileNames`,
  `cancelWasPressed`, `collectedMessages`.
* Buttons: **Pause** parks the worker inside `progressCheckBreak` (100 ms loop) and retitles
  the window "Paused …"; **Background** switches the *process* to the Darwin background band
  (the macOS stand-in for `IDLE_PRIORITY_CLASS`) and adds "Background" to the title; **Cancel**
  auto-pauses, asks Yes/No/Cancel (lang 448), and only on Yes stops the worker.
* Questions are answered for you: `askOverwrite` → `OverwriteDialog`, `askPassword` →
  `PasswordDialog` (asked once per run, then cached), `requestMemoryUse` → `MemoryUseDialog`.
  The worker blocks while the dialog is up.

### Example — extract selected items with progress, overwrite and password handling

```swift
var options = OperationRunner.Options(title: Lang.text(3300, "Extracting"))
options.initialStatus = .extracting
options.titleFileName = folder.fullPath
options.parentWindow = view.window
options.password = rememberedPassword          // optional

let result = OperationRunner.run(options) { runner -> SZOperationSummary in
    // off the main thread; `folder` must not be used elsewhere while this runs
    try folder.extractItems(at: selectedIndexes, toPath: destination,
                            pathMode: .fullPaths, overwriteMode: .ask,
                            testMode: false, progress: runner)
}

switch result {
case .success(let summary):
    if summary.passwordWasAsked { rememberedPassword = runnerPassword }   // runner.password
    refreshPanel()
case .failure(let error as NSError) where error.code == SZError.Code.cancelled.rawValue:
    break                                       // user cancelled; nothing to report
case .failure:
    break                                       // the runner already showed the alert
}
```

---

## 6. Dialogs (Swift, app target, `Mac/App/Dialogs/`)

All are main-thread only and run their own modal session (nesting inside the progress modal is
fine). Use them directly when you need the dialog without an operation.

```swift
// IDD_PROGRESS 97 -- normally owned by OperationRunner; drive it with ProgressSnapshot ticks.
ProgressDialog(title:mainTitle:showCompressionInfo:)   // .window, .update(_:), .operationDidFinish(hasMessages:)
                                                        // delegate: ProgressDialogDelegate

// IDD_OVERWRITE 3500 -> .yes .yesToAll .no .noToAll .autoRename .cancel (+ suggested name)
let answer: OverwriteDialog.Result = OverwriteDialog.run(
    oldFile: .init(path:size:time:isFileSystemFile:),
    newFile: .init(path:size:time:isFileSystemFile:),
    showExtraButtons: true, defaultIsNo: false, parent: window)

// IDD_PASSWORD 3800; nil = Cancel
let password: String? = PasswordDialog.askPassword(forPath: path, parent: window)
var o = PasswordDialog.Options()            // compress side
o.subject = "archive.7z"; o.requiresVerification = true; o.showsEncryptFileNames = true
let r: PasswordDialog.Result? = PasswordDialog.run(o, parent: window)   // .password .showPassword .encryptFileNames

// IDD_MESSAGES 6602 (no-op when `messages` is empty)
MessagesDialog.show(messages: [String], parent: window)

// IDD_MEM 7800; nil = Cancel (answer k_Stop)
let mem: MemoryUseDialog.Result? = MemoryUseDialog.run(options, parent: window)  // .answer .limitGB .remember .saveLimit
```

Reusable helpers in `ProgressDialogSupport.swift`: `ProgressSync` (the lock-protected
worker/UI hand-off, `checkStop()`, `snapshot(background:)`), `ProgressSnapshot`,
`ProgressFormatting` (`time`, `remaining`, `speed`, `ratio`, `percent`, `twoLinePath`,
`reduce`), `MessageListView` (numbered list with Cmd+A / Cmd+C), `DialogKit` (`label`,
`value`, `button`, `checkbox`, `radio`, `window(title:resizable:)`, `install(_:in:parent:minimumWidth:)`).

`PasswordDialog` reads and writes `Extraction.ShowPassword`; `MemoryUseDialog` writes
`Extraction.MemLimit` when the user ticks "Change allowed limit for next operations".

---

## 7. Known gaps for the scopes that build on this

* The Dock-tile progress mirror (`ITaskbarList3` equivalent) is not implemented.
* `CVirtFileSystem` (in-memory extraction for "open item inside archive") and the
  `IOpenCallbackUI` chain belong to the `extract` scope; the adapters already implement
  `IArchiveOpenCallback` so an open callback can be QI'd from the same object.
* 7zFM has **no "Auto Rename Existing" button**: `NOverwriteAnswer` has no such value and
  lang 3425 is an *Extract-dialog overwrite mode*. `OverwriteDialog` has the six real buttons.
* The Overwrite dialog shows one icon per file (Windows has two statics and only shows the
  second when the type icon differs); `NSWorkspace` gives a single composed icon.
