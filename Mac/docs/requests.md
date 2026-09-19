# Cross-scope requests

Requests one scope makes of another. The orchestrator assigns each to the owning scope's next
agent. Add a line, never rewrite someone else's.

| From | To | Request | State |
|---|---|---|---|
| `harness` | `options` (`Settings.swift`) and `opsinfra`/bridge owner (`SZSettings.mm`) | Let the app read its preferences domain from the `SEVENZIP_DEFAULTS_SUITE` environment variable so UI tests get a per-run isolated settings domain instead of writing to `com.yrambler2001.7zip`. | open |
| `harness` | `harness` (itself, next run) | `SevenZipApp.launch()` must terminate an already-running 7-Zip instance first; a sibling agent's running app broke two UI runs. | open |
| `fsfolder` | `panel` | `GetSystemIconIndex` and the delete-confirmation strings were left to the panel scope. | open |
| `options` | `harness` (`project.yml`) | Replace the two symlinks under `Mac/Tests/SevenZipKitTests/` that point at `Support/Settings.swift` and `Support/FileTypes.swift` with proper source entries for the test target. | open |
| `options`, `opsinfra`, `harness` | orchestrator | Agents running the app concurrently share the `com.yrambler2001.7zip` preferences domain and overwrite each other's settings; the domain override request above fixes this. | open |
| `tools` | `panel` | Expose the operated items on `PanelViewController` (`Get_ItemIndices_OperSmart`): the selection helpers are `private`, so `ToolsPanelAccess.operatedItems(of:)` reads the list through the panel's `NSTableView` and maps rows by displayed name. | open |
| `tools` | `panel` | Lift `HashListDialogView` (in `Mac/App/Dialogs/HashResultsDialog.swift`) into `Dialogs/ListViewDialog.swift`: it is the generic `CListViewDialog` (IDD_LISTVIEW 99) that Properties / archive info and Folders History need. | open |
| `tools` | `panel` | Drop the Wave 1 placeholder `MainWindowController.helpAbout` (the standard macOS About panel) so the IDM_ABOUT items can point straight at the real `IDD_ABOUT 2900` dialog; `ToolsCommands.install()` currently retargets them at runtime. | open |
| `tools` | `compress` | Reuse `SZBenchmark.memoryUsage(forThreads:level:dictionary:totalMode:)`, `ramSize`, `ramSizeLimit`, `isMemoryUsageOK(_:)` and `versionWithCPUText` for the Compress dialog's memory line and `SetErrorMessage_MemUsage`. | open |
| `tools` | `extract` | `-scrc` on extract/test: build the digests into `SZHashResults` and show them with `HashResultsDialog`; `CSZHashStreamCallback` in `SZHasher.mm` is the `IFolderExtractToStreamCallback` model. | open |
| `tools` | `finder` | The Explorer commands `CRC SHA-256 -> <name>.sha256` (03 §1.4 C12) and `Test archive : Checksum` (C13) are `SZHasher.writeChecksumFile` / `SZHasher.verifyChecksumFile`; no update flow is needed. | open |
| `tools` | orchestrator | New `tools`-owned paths not in the Wave 2 ownership table: `Mac/Core/SZSplitFile.{h,mm}`, `Mac/Core/Internal/SZToolsEngine.h`, `Mac/App/Dialogs/ToolsTempFilesDialog.swift`. | open |

## Spec corrections found during implementation

These override the inventory documents. Trust this list over the inventory when they disagree.

- The association list has **40** extensions, not 39 (`CPP/7zip/Bundles/Format7zF/resource.rc:38`), correcting `03-shell-integration-inventory.md` section 3.
- The zone-handling combo lang IDs are `406 = Yes`, `407 = No`; `01b-fm-dialogs-settings.md` section 4.13 has them swapped.
- `NWorkDir::CInfo::Load` falls back to the system temp folder only when `WorkDirPath` is **absent**, not when it is present but empty.
- 7zFM has **no "Auto Rename Existing" button**: `NOverwriteAnswer` has no such value and 3425 is
  an Extract-dialog overwrite *mode*. The Overwrite dialog has six buttons.
- `SZEngineCopyrightString()` is built without `USE_COPYRIGHT_CR`, so it reads
  `"Igor Pavlov : Public domain : <date>"`. The About dialog's static line is `MY_COPYRIGHT`
  with that macro, i.e. `"Copyright (c) 1999-2026 Igor Pavlov"` — use
  `SZBenchmark.engineCopyrightText`.
- Button lang IDs (the run that starts at 401 in `Lang/*.txt`): 401 OK, 402 Cancel,
  **406 Yes, 407 No, 408 Close, 409 Help**, 411 Continue. `01b` cites no IDs for these.
- `NWindows::NSystem::CProcessAffinity` has **no**
  `Get_and_return_NumProcessThreads_and_SysThreads` outside `_WIN32`; the normalisation has to
  be repeated by the caller (`SZBenchmark.mm`).
- `GetSysInfo(s1, s2)` (`Windows/SystemInfo.cpp:490`) returns two **empty** strings on
  non-Windows, so `IDT_BENCH_SYS1 107` / `SYS2 108` have nothing to show; the Darwin version and
  page size arrive through `GetOsInfoText` + `AddCpuFeatures` instead.

## Unfinished at the Wave 2 pause (2026-09-19)

Each branch builds and its features were verified live, but none ran a final clean
build-plus-test, so nothing is merged yet except `fsfolder`.

- `mac/opsinfra` (3 commits): write `Mac/docs/api/opsinfra.md`, tick the shared-dialog boxes
  (they sit in the `extract` section of `PROGRESS.md`), clean verify.
- `mac/options` (3 commits): write `Mac/docs/api/options.md`, tick the `options` section, finish
  the language screenshot and switch-back check, clean verify, replace the two test-target
  symlinks.
- `mac/harness` (4 commits): terminate an already-running app in `SevenZipApp.launch()`, rerun
  the 9 UI tests, run `verify.sh` end to end, tick `PROGRESS.md` section 9.1.
