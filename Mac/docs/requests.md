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
| `compress` | `extract` / `SZArchiveOpener` owner | `SZFolder.folder(forPath:)` / `SZArchiveOpener.openArchive(atPath:)` cannot open a multi-volume set: opening `x.7z.001` fails with `SZErrorCodeNotArchive` because no `IArchiveOpenVolumeCallback` (`COpenCallbackImp`) is supplied. The console `7zz` opens the same file fine. `UpdaterOptionsTests.testSplitVolumes` works around it by concatenating the volumes. | open |
| `compress` | `harness` (`project.yml`) | Add `Resources/SFX` to the **SevenZipKit** framework's resources (it is an app-target resource today), so `SZUpdater.defaultSFXModulePath` finds `7z.sfx` from the unit-test bundle without the `SEVENZIP_SFX_DIR` override. | open |

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
- `AddMemSize` (CompressDialog.cpp:2717) switches to GB only at **>= 2 GB** (`size >= 1 << 31`), so the memory-use combo shows `1024 MB`, not `1 GB`, and its top 64-bit item is `2 << 43` = `16384 MB`, not `3 << 43`; `01b-fm-dialogs-settings.md` section 4.23 says `3 << 43`.
- `AddMemUsage` (CompressDialog.cpp:3072) uses MB up to **and including** 16 GB, so the memory line reads `16384 MB / … / 16384 MB` on a 16 GB machine.
- The static `CCodecs::Load()` (`LoadCodecs.cpp:808-...`) never copied `CArcInfo::TimeFlags`, so `Get_TimePrecFlags()` / `Get_DefaultTimePrec()` were 0 in this build and the Compress Options timestamp-precision combo was empty. Patched under `#ifdef __APPLE__` (`Mac/docs/upstream-patches.md`). Windows uses the 7z.dll path, which reads the same value from `NHandlerPropID::kTimeFlags`.
