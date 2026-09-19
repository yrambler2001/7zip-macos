# Handoff: moving this port to another machine

State of branch `macos` at the time of writing. Update the status lines as work lands.

## What the machine needs

| Requirement | Why |
|---|---|
| Apple Silicon macOS 14 or newer | The engine builds arm64 with `Asm/arm64/LzmaDecOpt.S`; the app targets macOS 14. |
| Xcode 26.x installed at `/Applications/Xcode.app` | Every build runs with `DEVELOPER_DIR=/Applications/Xcode.app`. If Xcode lives elsewhere, change that one variable in `Mac/scripts/*.sh`. Do not rely on `xcode-select`. |
| `xcodegen` (Homebrew) | `Mac/project.yml` generates `Mac/7-Zip.xcodeproj`, which is git-ignored. |
| Python 3, `sips`, `iconutil` | The icon generator. Part of macOS plus Xcode. |
| Nothing else | No third-party libraries or package managers are used by the app itself. |

No code signing identity is required: everything builds ad-hoc signed. A Developer ID only matters for distribution, via the `DEVELOPMENT_TEAM` and `CODE_SIGN_IDENTITY` build settings.

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
- `Mac/docs/PROGRESS.md` — the 476-item checklist, per scope.
- `Mac/docs/reports/*.md` — what each scope did, verified, and left undone.

## Scope status

Merged into `macos`, each with a clean build and passing tests: `scaffold`, `fsfolder`, `opsinfra`,
`options`, `harness`, `tools`, `extract`.

In flight at handoff, on their own branches with worktrees under `.worktrees/`: `panel`, `compress`,
`icons`. Merge with `git merge mac/<scope>` and expect conflicts only in `Mac/App/MainMenu.swift`
(additive lines from several scopes) and `Mac/docs/requests.md` (union the rows, do not pick a side).

Not started: `finder` (Finder Sync extension, Services and Quick Actions, document types and UTIs,
the `sevenzip://` URL commands, and the 7zG argument grammar) and `packaging` (DMG, signing,
README, localization QA across all 93 languages, final parity audit).

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
