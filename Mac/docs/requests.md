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
| `extract` | `panel` | `PanelViewController` implements `fileOpenOutside(_:)` and disables it unless the folder is a file system, so Open Outside never reaches the archive branch. Call `ItemOpenCommands.openOutside()` (or let the command scope own the selector) so an item inside an archive is extracted to a `7zO` temp folder and opened. | open |
| `extract` | `panel` | Drag-out of archive members: use `ArchiveDragOut.promisedNames(indices:from:)` / `.extract(indices:from:to:...)` / `.removeTemporaryDirectory(_:)` from `Mac/App/Support/TempOpenCommands.swift` (documented in `Mac/docs/api/extract.md` §5) instead of calling the folder directly. | open |
| `extract` | `tools` | Extraction can hash on the fly (`-scrc<method>`, `Extract()`'s `IHashCalc*`). `SZArchiveExtractor` passes NULL; wire it to the hash-results dialog when that exists. | open |

## Spec corrections found during implementation

These override the inventory documents. Trust this list over the inventory when they disagree.

- The association list has **40** extensions, not 39 (`CPP/7zip/Bundles/Format7zF/resource.rc:38`), correcting `03-shell-integration-inventory.md` section 3.
- The zone-handling combo lang IDs are `406 = Yes`, `407 = No`; `01b-fm-dialogs-settings.md` section 4.13 has them swapped.
- `NWorkDir::CInfo::Load` falls back to the system temp folder only when `WorkDirPath` is **absent**, not when it is present but empty.
- 7zFM has **no "Auto Rename Existing" button**: `NOverwriteAnswer` has no such value and 3425 is
  an Extract-dialog overwrite *mode*. The Overwrite dialog has six buttons.
- `AutoRenamePath` (`CPP/7zip/Common/FilePathAutoRename.cpp`) renames to `name_1.ext`, not
  `name (2).ext` as `01-fm-feature-inventory.md` §8.4 says. Both the `kRename` and the
  `kRenameExisting` overwrite modes use it.
- Button lang IDs are positional in `en.ttt`: **406 = Yes, 407 = No, 408 = Close, 409 = Help**
  (401 OK, 402 Cancel, 411 Continue). Using 410/411 for Yes/No gives "" and "Continue".
- The Extract dialog's path-mode and overwrite-mode controls are **combo boxes**
  (`MY_COMBO`, `IDC_EXTRACT_PATH_MODE 102` / `IDC_EXTRACT_OVERWRITE_MODE 103`), not radio
  groups, and `IDD_EXTRACT` has **no** file-count/size summary control.
- The obvious bridge class name `SZExtractor` collides with a private Objective-C class in
  Apple's `StreamingZip.framework` ("implemented in both ... may cause spurious casting
  failures"). The extract scope's class is `SZArchiveExtractor`; keep new `SZ*` class names
  clear of the system frameworks.

## Wave status

- Merged into `macos`: `fsfolder`, `opsinfra`, `options`. Each ran a clean build plus test pass.
- `mac/harness` (4 commits, work staged): needs its `verify.sh` run, which waits on the shared
  app lock, then the `PROGRESS.md` section 9.1 tick.
- `mac/tools` in progress.
- Follow-up after the merge: `harness` replaces the two `Mac/Tests/SevenZipKitTests/` symlinks with
  proper `project.yml` source entries. Keep `Settings.swift` and `FileTypes.swift` Foundation-only
  so they stay compilable inside the test target.
