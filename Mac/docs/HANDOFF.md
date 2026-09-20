# Handoff: moving this port to another machine

State of branch `macos` at the time of writing. Update the status lines as work lands.

## What the machine needs

| Requirement | Why |
|---|---|
| Apple Silicon macOS 14 or newer | The engine builds arm64 with `Asm/arm64/LzmaDecOpt.S`; the app targets macOS 14. |
| Xcode 26.x installed at `/Applications/Xcode.app` | Every build runs with `DEVELOPER_DIR=/Applications/Xcode.app`. If Xcode lives elsewhere, change that one variable in `Mac/scripts/*.sh`. Do not rely on `xcode-select`. |
| `xcodegen` (Homebrew) | `Mac/project.yml` generates `Mac/7-Zip.xcodeproj`, which is git-ignored. |
| Python 3, `sips`, `iconutil` | The icon generator. Part of macOS plus Xcode. |
| Developer mode enabled (`sudo DevToolsSecurity -enable`) | Found off on the fresh VM. Without it every `xcodebuild test` run can raise an authorization panel before the XCUITest runner may drive the app. Check with `DevToolsSecurity -status`; the account also has to be in the `_developer` group, which an admin account already is. |
| Automation + Screen Recording granted to the **terminal application** that runs the agent (here `/System/Applications/Utilities/Terminal.app`) | Only for AppleScript-driven workflows and `screencapture`; the build, the unit tests and `test.sh --ui` need neither. Both were missing on the fresh VM. An unapproved AppleScript **hangs on the consent dialog** instead of failing, so probe first with `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded=false)` — `-1744` means "would prompt". Only a human can grant these; `TCC.db` is SIP-protected and `tccutil` can only reset. Exact click paths in `Mac/docs/reports/vmcheck.md` §7. |
| Nothing else | No third-party libraries or package managers are used by the app itself. |

No code signing identity is required: everything builds ad-hoc signed. A Developer ID only matters for distribution, via the `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` build settings.

A fresh VM was verified end to end on 2026-09-20 (Xcode 26.6 / SDK 26.5 / Swift 6.3.3 / macOS 26.6.2): clean build 34 s, 209 unit tests green, UI suite 14 of 19 with exactly the five known failures. Full findings in `Mac/docs/reports/vmcheck.md`.

## First commands on the new machine

```sh
git checkout macos
export DEVELOPER_DIR=/Applications/Xcode.app
Mac/scripts/verify.sh          # clean build + unit tests + UI tests, writes Mac/docs/reports/verify-latest.md
Mac/scripts/parity-check.sh    # per-scope checklist progress
Mac/scripts/run.sh             # launch the app
```

If the bundled assets are missing (`Mac/Resources/Lang`, `Mac/Resources/SFX`), regenerate them with
`Mac/scripts/fetch-assets.sh`; it re-downloads the official 7-Zip release against pinned hashes.
Test fixtures come from `Mac/scripts/make-fixtures.sh`, which needs the console `7zz`
(`cd CPP/7zip/Bundles/Alone2 && DEVELOPER_DIR=/Applications/Xcode.app make -j8 -f ../../cmpl_mac_arm64.mak`).

## Where to read what

- `Mac/docs/00-orchestration.md` — the contract: decisions, layout, branching, file ownership, the frozen `OperationContext`.
- `Mac/docs/requests.md` — open cross-scope requests and, importantly, spec corrections that override the inventories.
- `Mac/docs/01-fm-feature-inventory.md`, `01b-fm-dialogs-settings.md` — the parity specification, both second-pass verified against source.
- `Mac/docs/02-engine-api.md` — the engine source set, callback protocols, upstream patches.
- `Mac/docs/03-shell-integration-inventory.md` — Windows shell integration and the macOS mechanisms chosen to replace it. This is the specification for the unfinished `finder` scope.
- `Mac/docs/04-toolchain.md` — build recipe and toolchain gotchas.
- `Mac/docs/api/*.md` — the public API each finished scope exposes. Read these instead of the sources.
- `Mac/docs/PROGRESS.md` — the 496-item checklist, per scope.
- `Mac/docs/reports/*.md` — what each scope did, verified, and left undone.

## Scope status

Everything built so far is merged into `macos`. The per-scope branches are kept for history and
their worktrees have been removed, so the repository moves cleanly.

| Scope | State |
|---|---|
| `scaffold` | merged: Xcode project, engine static library, ObjC++ bridge, app shell, menu bar |
| `fsfolder` | merged: file-system folder, all columns, copy/move/delete/rename/create/calc-size, flat mode, volumes, FSEvents |
| `opsinfra` | merged: callback adapters, operation runner, Progress / Overwrite / Password / Messages / Memory dialogs |
| `options` | merged: all seven Options pages, the settings layer, live language switching, the preferences-domain override |
| `harness` | merged: UI test target, helper library, verify and parity scripts, the app-launch lock |
| `tools` | merged: every hash method with its results dialog, Benchmark, Split, Combine, Link, About, Help, temp browser |
| `extract` | merged: Extract dialog and flow, all path and overwrite modes, Test, open/view/edit with write-back, drag-out hook |
| `compress` | merged: Compress dialog and Options sheet, update flow, SFX, volumes, delete-after, compress-and-email |
| `icons` | merged: app icon and 27 document icons covering all 40 associated extensions, regenerated by script |
| `panel` | merged: all four view modes, sorting, selection, key map, history, favorites, operations, context menu, drag and drop, clipboard, two-panel layout |
| `finder` | **not started**: Finder Sync extension, Services and Quick Actions, document types and UTIs, `sevenzip://` URL commands, the 7zG argument grammar. Specified in `03-shell-integration-inventory.md`. |
| `packaging` | **not started**: DMG, Developer ID signing, README, localization QA across all 93 languages, final parity audit |

Checklist progress is 334 of 496 items. Two figures understate the truth: `scaffold` reads 0 of 57
because the checklist did not exist when it was built, and `fsfolder` reads 41% because half its
items were deliberately assigned to `panel`.

### Test state at handoff

- Unit tests: 209 of 209 pass.
- UI tests: 14 of 19 pass. The five failures are harness problems, not product bugs, each recorded
  as a row in `requests.md`: test isolation for the persisted column layout, the address-bar helper
  indexing the wrong combo box with two panels, the right-click helper missing the row, the
  select-by-mask field lookup failing silently, and a submenu title assertion. Three other failures
  were provably wrong expectations and are already fixed.
- `Mac/scripts/verify.sh` therefore exits non-zero until those five are fixed. Run
  `Mac/scripts/test.sh` for the unit suite, which is green.

## Known follow-ups

Full list in `Mac/docs/requests.md`. The ones that matter most:

1. `ToolsPanelAccess.operatedItems` reads the panel's table directly because the `tools` branch
   predates the frozen `OperationContext`. Migrate it to `ActiveContext.current()`.
2. The `scaffold` section of `PROGRESS.md` reads 0 of 57 only because the checklist did not exist
   when the scaffold was built. An audit pass should tick what it really did.
3. Two symlinks under `Mac/Tests/SevenZipKitTests/` point at `App/Support/Settings.swift` and
   `FileTypes.swift`; replace them with proper source entries in `Mac/project.yml`. Those two files
   must stay Foundation-only so they keep compiling inside the test target.
4. `SEVENZIP_DEFAULTS_SUITE` overrides the preferences domain by name. Accepting a plist path too
   would let UI tests seed settings per test rather than per run.

## Running several agents at once

Two mechanisms exist because parallel agents interfered with each other:

- `SEVENZIP_DEFAULTS_SUITE=<name>` makes the whole process, engine included, use that preferences
  domain instead of `com.yrambler2001.7zip`. Always set it when driving the app in a test.
- The app-launch lock, the directory `.worktrees/.app-lock` (override with `SEVENZIP_APP_LOCK`),
  serializes app launches. `Mac/scripts/test.sh --ui` and `verify.sh` take it automatically.
  Acquire it per launch, not per phase, and never kill a 7-Zip process from another worktree.
