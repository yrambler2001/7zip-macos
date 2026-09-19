# `compress` scope — progress log and report

Branch `mac/compress`. Checklist: `Mac/docs/PROGRESS.md` section 5. Spec:
`Mac/docs/01b-fm-dialogs-settings.md` sections 4.23, 4.24; `01-fm-feature-inventory.md`
section 8.5; `02-engine-api.md` section 2.3.

State notes are appended per phase so the work can be resumed after a context compaction.

## Phase 0 — orientation (done)

Read the orchestration contract, `requests.md`, the frozen `OperationContext`, the
`opsinfra` / `options` / `fsfolder` API docs, `01b` sections 4.23/4.24 and the engine
headers that matter (`UI/Common/Update.h`, `UpdateCallback.h`, `SetProperties.h`,
`UpdateAction.h`, `ZipRegistry.h`, `WorkDir.h`, `Wildcard.h`) plus the Windows sources
being ported (`GUI/UpdateGUI.cpp`, `GUI/UpdateCallbackGUI*.cpp`, `Common/CompressCall2.cpp`).

Design decisions taken:

- `SZUpdater` drives the engine's `UpdateArchive()` (`UI/Common/Update.cpp`) exactly like
  `UpdateGUI.cpp` does, so behaviour matches 7zG instead of being reimplemented.
- The `-m` property list is built in Swift (`CompressOptions` → `[SZUpdateProperty]`) in the
  order `01b` section 4.23 "Parameter generation" documents; the bridge passes it through
  unchanged to `CUpdateOptions::MethodMode::Properties`.
- The censor is `AddPreItem_NoWildcard(path)` per source path (7zG's `-i#map` list with
  `ISWITCH_NO_WILDCARD_POSTFIX`); `UpdateArchive` itself calls `AddPathsToCensor(PathMode)`.
- The work-directory policy is applied inside the bridge from `NWorkDir::CInfo::Load()`
  (same preferences domain as the Swift `Settings` facade) unless a working directory is
  passed explicitly.
