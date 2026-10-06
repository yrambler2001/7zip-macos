# 7-Zip for macOS (unofficial port) — rules for AI agents

This repository is upstream 7-Zip 26.03 (`C/`, `CPP/`, `Asm/`, `DOC/`) plus a native macOS port
under `Mac/`. The default branch is `macos`; `main` mirrors upstream `ip7z/7zip` and is never
changed here.

Where to read:

- `docs/` — contributor docs: `building.md`, `architecture.md`, `testing.md`, `upstream.md`,
  `parity.md`. Start there.
- `ai/` — how the port was built with Claude Code: the orchestration contract
  (`ai/00-orchestration.md`), cross-scope requests and spec corrections (`ai/requests.md`), the
  parity specification (`ai/01-fm-feature-inventory.md`, `ai/01b-fm-dialogs-settings.md`,
  `ai/03-shell-integration-inventory.md`), the engine and toolchain notes (`ai/02-engine-api.md`,
  `ai/04-toolchain.md`), the per-scope public APIs (`ai/api/`) and reports (`ai/reports/`).
  `ai/README.md` explains the folder; `ai/HANDOFF.md` lists what a fresh machine needs.

## Hard rules

- `export DEVELOPER_DIR=/Applications/Xcode.app` for every build/test command. Never run
  `xcode-select -s`.
- An `osascript` call that drives another app can raise a consent dialog that an unattended agent
  hangs on instead of failing. Drive the app through XCUITest, and take screenshots as XCUITest
  attachments or in-process renders (app-hosted tests), not with `screencapture`.
- Do not edit `C/`, `CPP/`, `Asm/`, `DOC/` except for a patch that is unavoidable; it must be
  guarded by `#ifdef _WIN32` / `__APPLE__` and recorded in `Mac/docs/upstream-patches.md`.
- Warnings are errors in `Mac/` code (`SWIFT_TREAT_WARNINGS_AS_ERRORS`,
  `GCC_TREAT_WARNINGS_AS_ERRORS`). Upstream warnings are tolerated.
- No third-party dependencies. Swift + AppKit only, no SwiftUI, no storyboards/xibs.
- Parity with Windows 7zFM is the specification. Cite the inventory section
  (e.g. `01 §3.7`, `01b §4.19`) in code comments and reports, and keep the Windows resource
  ID in a comment next to each menu item and dialog control.
- Tests write screenshots to `Mac/build/screenshots/` (git-ignored). Images for the docs live in
  `docs/images/` and are retaken with `Mac/scripts/showcase.sh`.

## Build, run, test

```sh
export DEVELOPER_DIR=/Applications/Xcode.app
Mac/scripts/build.sh     # xcodegen + xcodebuild Debug, ad-hoc signed, output in Mac/build
Mac/scripts/run.sh       # build then open Mac/build/Debug/7-Zip.app
Mac/scripts/test.sh      # unit tests; -H app-hosted, -u XCUITest (local GUI session only)
```

`Mac/project.yml` globs whole directories, so new source files under `Mac/App`, `Mac/Core`,
`Mac/FinderSync` and `Mac/Tests` are picked up without editing it.

## Commits

One scope per branch (`mac/<scope>`, usually in a worktree under `.worktrees/`), commit early and
often, message prefix `mac(<scope>): `. End every commit message with the `Co-Authored-By` and
`Claude-Session` attribution lines your own session gives you, not the ones from an earlier session.

Never merge, rebase, or switch branches; the orchestrator (or the maintainer) integrates.
