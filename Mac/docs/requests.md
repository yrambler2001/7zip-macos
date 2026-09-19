# Cross-scope requests

Requests one scope makes of another. The orchestrator assigns each to the owning scope's next
agent. Add a line, never rewrite someone else's.

| From | To | Request | State |
|---|---|---|---|
| `harness` | `options` (`Settings.swift`) and `opsinfra`/bridge owner (`SZSettings.mm`) | Let the app read its preferences domain from the `SEVENZIP_DEFAULTS_SUITE` environment variable so UI tests get a per-run isolated settings domain instead of writing to `com.yrambler2001.7zip`. | **done** (`mac/options`): `NMacPrefs::ApplicationID()` resolves the variable on every access, so `SZSettings`, the Swift `Settings` facade and the engine-side `ZipRegistry` accessors all follow it; `SZSettings.applicationID` / `.usesOverrideSuite` report it. See `Mac/docs/api/options.md`. |
| `harness` | `harness` (itself, next run) | `SevenZipApp.launch()` must terminate an already-running 7-Zip instance first; a sibling agent's running app broke two UI runs. | open |
| `fsfolder` | `panel` | `GetSystemIconIndex` and the delete-confirmation strings were left to the panel scope. | open |
| `options` | `harness` (`project.yml`) | Replace the two symlinks under `Mac/Tests/SevenZipKitTests/` that point at `Support/Settings.swift` and `Support/FileTypes.swift` with proper source entries for the test target. | open |
| `panel` | `harness` (`project.yml`) | `Mac/App/Panel/PanelRow.swift` and `PanelLogic.swift` are symlinked into `Mac/Tests/SevenZipKitTests/` (like `Settings.swift` / `FileTypes.swift`) so the sort comparator, mask matcher, operated-items rule and column model are unit-tested against the app's own source. Please replace all four symlinks with proper source entries for the test target. Also: `Mac/Tests/UITests/PanelTests.swift` is written against the `harness` helpers and needs the `7-ZipUITests` target to run. | open |
| `panel` | `harness` (`SevenZipPanel`) | `panelCount` counts `window.tables`; in the Large Icons / Small Icons / List view modes a panel's list is an `NSCollectionView` laid **over** the table (the table stays in the hierarchy so the count keeps working), so a view-mode test should read the collection view, not the table. | open |
| `options`, `opsinfra`, `harness` | orchestrator | Agents running the app concurrently share the `com.yrambler2001.7zip` preferences domain and overwrite each other's settings; the domain override request above fixes this. | **done**: launch with `SEVENZIP_DEFAULTS_SUITE=7zip-<scope>` (or any name) and the whole process, engine included, uses that domain. |

## Spec corrections found during implementation

These override the inventory documents. Trust this list over the inventory when they disagree.

- The association list has **40** extensions, not 39 (`CPP/7zip/Bundles/Format7zF/resource.rc:38`), correcting `03-shell-integration-inventory.md` section 3.
- The zone-handling combo lang IDs are `406 = Yes`, `407 = No`; `01b-fm-dialogs-settings.md` section 4.13 has them swapped.
- `NWorkDir::CInfo::Load` falls back to the system temp folder only when `WorkDirPath` is **absent**, not when it is present but empty.
- 7zFM has **no "Auto Rename Existing" button**: `NOverwriteAnswer` has no such value and 3425 is
  an Extract-dialog overwrite *mode*. The Overwrite dialog has six buttons.

## Wave status

- Merged into `macos`: `fsfolder`, `opsinfra`, `options`. Each ran a clean build plus test pass.
- `mac/harness` (4 commits, work staged): needs its `verify.sh` run, which waits on the shared
  app lock, then the `PROGRESS.md` section 9.1 tick.
- `mac/tools` in progress.
- Follow-up after the merge: `harness` replaces the two `Mac/Tests/SevenZipKitTests/` symlinks with
  proper `project.yml` source entries. Keep `Settings.swift` and `FileTypes.swift` Foundation-only
  so they stay compilable inside the test target.
