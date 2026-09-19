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

## Spec corrections found during implementation

These override the inventory documents. Trust this list over the inventory when they disagree.

- The association list has **40** extensions, not 39 (`CPP/7zip/Bundles/Format7zF/resource.rc:38`), correcting `03-shell-integration-inventory.md` section 3.
- The zone-handling combo lang IDs are `406 = Yes`, `407 = No`; `01b-fm-dialogs-settings.md` section 4.13 has them swapped.
- `NWorkDir::CInfo::Load` falls back to the system temp folder only when `WorkDirPath` is **absent**, not when it is present but empty.
