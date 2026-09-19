# Cross-scope requests

Requests one scope makes of another. The orchestrator assigns each to the owning scope's next
agent. Add a line, never rewrite someone else's.

| From | To | Request | State |
|---|---|---|---|
| `harness` | `options` (`Settings.swift`) and `opsinfra`/bridge owner (`SZSettings.mm`) | Let the app read its preferences domain from the `SEVENZIP_DEFAULTS_SUITE` environment variable so UI tests get a per-run isolated settings domain instead of writing to `com.yrambler2001.7zip`. | **done** (`mac/options`): `NMacPrefs::ApplicationID()` resolves the variable on every access, so `SZSettings`, the Swift `Settings` facade and the engine-side `ZipRegistry` accessors all follow it; `SZSettings.applicationID` / `.usesOverrideSuite` report it. See `Mac/docs/api/options.md`. |
| `harness` | `harness` (itself, next run) | `SevenZipApp.launch()` must terminate an already-running 7-Zip instance first; a sibling agent's running app broke two UI runs. | open |
| `fsfolder` | `panel` | `GetSystemIconIndex` and the delete-confirmation strings were left to the panel scope. | open |
| `options` | `harness` (`project.yml`) | Replace the two symlinks under `Mac/Tests/SevenZipKitTests/` that point at `Support/Settings.swift` and `Support/FileTypes.swift` with proper source entries for the test target. | open |
| `options`, `opsinfra`, `harness` | orchestrator | Agents running the app concurrently share the `com.yrambler2001.7zip` preferences domain and overwrite each other's settings; the domain override request above fixes this. | **done**: launch with `SEVENZIP_DEFAULTS_SUITE=7zip-<scope>` (or any name) and the whole process, engine included, uses that domain. |
| `harness` | `options` (settings owner) | `SEVENZIP_DEFAULTS_SUITE` takes a domain name, which only allows per-run seeding from the scripts, because the sandboxed XCUITest runner cannot write any CFPreferences domain the app reads. Accepting a **plist path** as well would allow per-test seeding. | open |
| `harness` | `options` (`Settings.swift`) and `opsinfra`/bridge owner (`SZSettings.mm`) | Let the app read its preferences domain from the `SEVENZIP_DEFAULTS_SUITE` environment variable so UI tests get a per-run isolated settings domain instead of writing to `com.yrambler2001.7zip`. | open |
| `options`, `opsinfra`, `harness` | orchestrator | Agents running the app concurrently share the `com.yrambler2001.7zip` preferences domain and overwrite each other's settings; the domain override request above fixes this. | open |
| `tools` | `panel` | Expose the operated items on `PanelViewController` (`Get_ItemIndices_OperSmart`): the selection helpers are `private`, so `ToolsPanelAccess.operatedItems(of:)` reads the list through the panel's `NSTableView` and maps rows by displayed name. | open |
| `tools` | `panel` | Lift `HashListDialogView` (in `Mac/App/Dialogs/HashResultsDialog.swift`) into `Dialogs/ListViewDialog.swift`: it is the generic `CListViewDialog` (IDD_LISTVIEW 99) that Properties / archive info and Folders History need. | open |
| `tools` | `panel` | Drop the Wave 1 placeholder `MainWindowController.helpAbout` (the standard macOS About panel) so the IDM_ABOUT items can point straight at the real `IDD_ABOUT 2900` dialog; `ToolsCommands.install()` currently retargets them at runtime. | open |
| `tools` | `compress` | Reuse `SZBenchmark.memoryUsage(forThreads:level:dictionary:totalMode:)`, `ramSize`, `ramSizeLimit`, `isMemoryUsageOK(_:)` and `versionWithCPUText` for the Compress dialog's memory line and `SetErrorMessage_MemUsage`. | open |
| `tools` | `extract` | `-scrc` on extract/test: build the digests into `SZHashResults` and show them with `HashResultsDialog`; `CSZHashStreamCallback` in `SZHasher.mm` is the `IFolderExtractToStreamCallback` model. | open |
| `tools` | `finder` | The Explorer commands `CRC SHA-256 -> <name>.sha256` (03 §1.4 C12) and `Test archive : Checksum` (C13) are `SZHasher.writeChecksumFile` / `SZHasher.verifyChecksumFile`; no update flow is needed. | open |
| `tools` | orchestrator | New `tools`-owned paths not in the Wave 2 ownership table: `Mac/Core/SZSplitFile.{h,mm}`, `Mac/Core/Internal/SZToolsEngine.h`, `Mac/App/Dialogs/ToolsTempFilesDialog.swift`. | open |
| `extract` | `panel` | `PanelViewController` implements `fileOpenOutside(_:)` and disables it unless the folder is a file system, so Open Outside never reaches the archive branch. Call `ItemOpenCommands.openOutside()` (or let the command scope own the selector) so an item inside an archive is extracted to a `7zO` temp folder and opened. | open |
| `extract` | `panel` | Drag-out of archive members: use `ArchiveDragOut.promisedNames(indices:from:)` / `.extract(indices:from:to:...)` / `.removeTemporaryDirectory(_:)` from `Mac/App/Support/TempOpenCommands.swift` (documented in `Mac/docs/api/extract.md` §5) instead of calling the folder directly. | open |
| `extract` | `tools` | Extraction can hash on the fly (`-scrc<method>`, `Extract()`'s `IHashCalc*`). `SZArchiveExtractor` passes NULL; wire it to the hash-results dialog when that exists. | open |

## Spec corrections found during implementation

These override the inventory documents. Trust this list over the inventory when they disagree.

- The association list has **40** extensions, not 39 (`CPP/7zip/Bundles/Format7zF/resource.rc:38`), correcting `03-shell-integration-inventory.md` section 3.
- The zone-handling combo lang IDs are `406 = Yes`, `407 = No`; `01b-fm-dialogs-settings.md` section 4.13 has them swapped.
- `NWorkDir::CInfo::Load` falls back to the system temp folder only when `WorkDirPath` is **absent**, not when it is present but empty.
- 7zFM has **no "Auto Rename Existing" button**: `NOverwriteAnswer` has no such value and 3425 is
- `SZEngineCopyrightString()` is built without `USE_COPYRIGHT_CR`, so it reads
- Button lang IDs (the run that starts at 401 in `Lang/*.txt`): 401 OK, 402 Cancel,
- `NWindows::NSystem::CProcessAffinity` has **no**
- `GetSysInfo(s1, s2)` (`Windows/SystemInfo.cpp:490`) returns two **empty** strings on
- `AutoRenamePath` (`CPP/7zip/Common/FilePathAutoRename.cpp`) renames to `name_1.ext`, not
- Button lang IDs are positional in `en.ttt`: **406 = Yes, 407 = No, 408 = Close, 409 = Help**
- The Extract dialog's path-mode and overwrite-mode controls are **combo boxes**
- The obvious bridge class name `SZExtractor` collides with a private Objective-C class in

## Wave status

- Merged into `macos`: `fsfolder`, `opsinfra`, `options`. Each ran a clean build plus test pass.
- `mac/harness` merged: UI suite 9/9 green, `verify.sh` green end to end, the app-launch lock is wired into `test.sh --ui` and `verify.sh`.
- In progress: `mac/tools`, `mac/panel`, `mac/extract`, `mac/compress`.
- Follow-up after the merge: `harness` replaces the two `Mac/Tests/SevenZipKitTests/` symlinks with
- `mac/tools` merged: hashing, Benchmark, Split, Combine, Link, About, Help, temp browser. Its
- Retroactive tick needed: the `scaffold` section of `PROGRESS.md` is 0/57 because the checklist
- `mac/harness` (4 commits, work staged): needs its `verify.sh` run, which waits on the shared
- `mac/tools` in progress.
