# Handoff: moving this port to another machine

State of branch `macos` plus `mac/release` (2026-10-03). Update the status lines as work lands.

## What the machine needs

| Requirement | Why |
|---|---|
| Apple Silicon macOS 14 or newer | The engine builds arm64 with `Asm/arm64/LzmaDecOpt.S`; the app targets macOS 14. |
| Xcode 26.x installed at `/Applications/Xcode.app` | Every build runs with `DEVELOPER_DIR=/Applications/Xcode.app`. If Xcode lives elsewhere, change that one variable in `Mac/scripts/*.sh`. Do not rely on `xcode-select`. |
| `xcodegen` (Homebrew) | `Mac/project.yml` generates `Mac/7-Zip.xcodeproj`, which is git-ignored. |
| Python 3, `sips`, `iconutil` | The icon generator. Part of macOS plus Xcode. |
| Developer mode enabled (`sudo DevToolsSecurity -enable`) | Found off on the fresh VM. Without it every `xcodebuild test` run can raise an authorization panel before the XCUITest runner may drive the app. Check with `DevToolsSecurity -status`; the account also has to be in the `_developer` group, which an admin account already is. |
| Automation + Screen Recording granted to the **terminal application** that runs the agent (here `/System/Applications/Utilities/Terminal.app`) | Only for AppleScript-driven workflows and `screencapture`; the build, the unit tests and `test.sh --ui` need neither. Both were missing on the fresh VM. An unapproved AppleScript **hangs on the consent dialog** instead of failing, so probe first with `AEDeterminePermissionToAutomateTarget(…, askUserIfNeeded=false)` — `-1744` means "would prompt". Only a human can grant these; `TCC.db` is SIP-protected and `tccutil` can only reset. Exact click paths in `ai/reports/vmcheck.md` §7. |
| Nothing else | No third-party libraries or package managers are used by the app itself. |

No code signing identity is required: everything builds ad-hoc signed. A Developer ID only matters for distribution, via the `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` build settings.

A fresh VM was verified end to end on 2026-09-20 (Xcode 26.6 / SDK 26.5 / Swift 6.3.3 / macOS 26.6.2): clean build 34 s, 209 unit tests green, UI suite 14 of 19 with exactly the five known failures. Full findings in `ai/reports/vmcheck.md`. (Those numbers are from that day; the current ones are below.)

## First commands on the new machine

```sh
git checkout macos
export DEVELOPER_DIR=/Applications/Xcode.app
Mac/scripts/verify.sh -S       # clean build + unit, app-hosted and UI tests, writes ai/reports/verify-latest.md
Mac/scripts/parity-check.sh    # per-scope checklist progress
Mac/scripts/run.sh             # launch the app
```

If the bundled assets are missing (`Mac/Resources/Lang`, `Mac/Resources/SFX`), regenerate them with
`Mac/scripts/fetch-assets.sh`; it re-downloads the official 7-Zip release against pinned hashes.
Test fixtures come from `Mac/scripts/make-fixtures.sh`, which needs the console `7zz`
(`cd CPP/7zip/Bundles/Alone2 && DEVELOPER_DIR=/Applications/Xcode.app make -j8 -f ../../cmpl_mac_arm64.mak`).

## Where to read what

- `ai/00-orchestration.md` — the contract: decisions, layout, branching, file ownership, the frozen `OperationContext`.
- `ai/requests.md` — open cross-scope requests and, importantly, spec corrections that override the inventories.
- `ai/01-fm-feature-inventory.md`, `01b-fm-dialogs-settings.md` — the parity specification, both second-pass verified against source.
- `ai/02-engine-api.md` — the engine source set, callback protocols, upstream patches.
- `ai/03-shell-integration-inventory.md` — Windows shell integration and the macOS mechanisms chosen to replace it (the `finder` scope's specification).
- `ai/04-toolchain.md` — build recipe and toolchain gotchas.
- `ai/api/*.md` — the public API each finished scope exposes. Read these instead of the sources.
- `ai/PROGRESS.md` — the 496-item checklist, per scope.
- `ai/parity.md` — what a user gets today: complete, partial, different, missing, unverified.
- `ai/reports/*.md` — what each scope did, verified, and left undone.

## Scope status

Every scope is merged into `macos` except `mac/release`, which is waiting for the orchestrator. The
per-scope branches are kept for history; their worktrees can be removed once merged.

| Scope | State |
|---|---|
| `scaffold` | merged: Xcode project, engine static library, ObjC++ bridge, app shell, menu bar. 55 / 57 -- two product decisions open (below) |
| `fsfolder` | merged: file-system folder, all columns, copy/move/delete/rename/create/calc-size, flat mode, volumes, FSEvents. 58 / 58 |
| `opsinfra` | merged: callback adapters, operation runner, Progress / Overwrite / Password / Messages / Memory dialogs |
| `options` | merged: all seven Options pages, the settings layer, live language switching. 46 / 46 |
| `harness`, `harness2`, `fastui`, `resetcmd`, `modalfix`, `uiverify` | merged: unit, app-hosted and XCUITest targets, sharded runs, `verify.sh`, the app-launch lock, `sevenzip://test/reset` |
| `tools` | merged: every hash method, Benchmark, Split, Combine, Link, About, Help, temp browser. 40 / 40 |
| `extract` | merged: Extract dialog and flow, all modes, Test, open/view/edit with write-back, drag-out. 57 / 57 |
| `compress` | merged: Compress dialog and Options sheet, update flow, SFX, volumes, delete-after, e-mail. 52 / 52 |
| `icons` | merged: app icon, 27 document icons for 40 extensions, the About wordmark. 20 / 20 |
| `panel`, `panelgaps`, `navgaps` | merged: all four view modes, sorting, selection, keys, history, favorites, operations, context menu with the 7-Zip verbs, drag and drop in every mode, archive open with progress, per-level passwords. 108 / 108 |
| `finder`, `cmdmode` | merged: Finder Sync extension, two Quick Actions, five Services, document types and UTIs, `sevenzip://`, the 7zG grammar, Dock drop. 34 / 36 -- the optional 7zG helper (by design) and the human Finder check |
| `packaging` + `release` | `mac/release`: Release build, DMG, hardened-runtime readiness, Developer ID / notarization path (script-ready, never run: no identity here), README, localization QA in all 93 languages, final parity audit. 20 / 22 |
| `opsgaps`, `optgaps`, `archgaps`, `polish`, `cleanup` | merged: help, quarantine, Dock tile, failure texts, Options ▸ System / Language, raw properties, nested write-back, layout fixes |

**Checklist: 490 of 496** (`Mac/scripts/parity-check.sh`). The six open items, each with its reason,
are in `ai/parity.md` section D; four need the orchestrator or a human, not code.

### Test state (2026-10-03, `mac/release`)

- `Mac/scripts/verify.sh -S` (clean Debug build, every target, sharded) is the gate; the latest
  run's numbers are in `ai/reports/verify-latest.md` and `ai/reports/release.md` §5.
- Unit tests (`SevenZipKitTests`): 387. App-hosted (`SevenZipAppTests`): ~100, including the
  93-language sweep. XCUITest: two read-only probe shards and the input shard.
- `test.sh` retries a target once when XCUITest's automation mode times out before any test runs
  (seen intermittently on this machine). If it sticks: `sudo automationmodetool
  enable-automationmode-without-authentication`.

## How to resume

1. Merge `mac/release` into `macos` (it touches docs, `Mac/scripts/test.sh` / `make-icons.py`, and
   small edits across `App/` listed in `reports/release.md` §7).
2. Answer the decisions in `ai/reports/release.md` "Decisions for the orchestrator".
3. Walk the manual checks in `reports/release.md` §6 on a Mac with Automation and Screen Recording
   granted (and, for distribution, a Developer ID): Finder's menu, a drag into Finder, a Dock drop,
   Help in a browser, the Dock-tile progress, then `package.sh -i … -T … -p …` for notarization.
4. Then tick the last boxes (`PROGRESS.md` §9.4) and set every scope to done.

## Known follow-ups

- The decisions above (re-launch opens a new window or not; the panels' first folder; whether a
  file opened from Finder should always get its own window; how agents share `testmanagerd`).
- Right-to-left mirroring would need an RTL localization declared in the bundle
  (`CFBundleLocalizations`) plus a review of every hand-built layout.
- `currentFolderForContext()` reads the panel's `folder` reference on the main thread while the
  panel queue may replace it: a pointer race, never a call, but worth an atomic holder like
  `PanelArchiveLevel`.

## Running several agents at once

Two mechanisms exist because parallel agents interfered with each other:

- `SEVENZIP_DEFAULTS_SUITE=<name>` makes the whole process, engine included, use that preferences
  domain instead of `com.yrambler2001.7zip`. Always set it when driving the app in a test.
- The app-launch lock, the directory `.worktrees/.app-lock` (override with `SEVENZIP_APP_LOCK`),
  serializes app launches. `Mac/scripts/test.sh --ui` and `verify.sh` take it automatically.
  Acquire it per launch, not per phase, and never kill a 7-Zip process from another worktree.
  It does **not** cover unit-test runs, which share `testmanagerd` with a UI run (requests row
  harness → orchestrator).
