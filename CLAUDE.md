# 7-Zip — native macOS port

This repository is upstream 7-Zip 26.03 (`C/`, `CPP/`, `Asm/`, `DOC/`) plus a native macOS
port under `Mac/`. Work happens on branch `macos` and on `mac/<scope>` worktree branches.

**Read `Mac/docs/00-orchestration.md` and `Mac/docs/requests.md` before doing anything**, and `Mac/docs/HANDOFF.md` if you are starting on a new machine. It is the contract: goal,
locked decisions, repository layout, branching, file ownership, and the deliverables every
agent owes. `Mac/docs/architecture.md` describes the design and, in its "As built" section,
the real bridge API and app layout to code against.

## Hard rules

- `export DEVELOPER_DIR=/Applications/Xcode.app` for every build/test command. Never run
  `xcode-select -s` (the global selection must stay on Xcode 15.4).
- Do not edit `C/`, `CPP/`, `Asm/`, `DOC/` except for a patch that is unavoidable; it must be
  guarded by `#ifdef _WIN32` / `__APPLE__` and recorded in `Mac/docs/upstream-patches.md`.
- Only edit files your scope owns (ownership table in `00-orchestration.md`). Additive-only
  edits are allowed in the few shared files listed there.
- Warnings are errors in `Mac/` code (`SWIFT_TREAT_WARNINGS_AS_ERRORS`,
  `GCC_TREAT_WARNINGS_AS_ERRORS`). Upstream warnings are tolerated.
- No third-party dependencies. Swift + AppKit only, no SwiftUI, no storyboards/xibs.
- Parity with Windows 7zFM is the specification. Cite the inventory section
  (e.g. `01 §3.7`, `01b §4.19`) in code comments and reports, and keep the Windows resource
  ID in a comment next to each menu item and dialog control.

## Build, run, test

```sh
export DEVELOPER_DIR=/Applications/Xcode.app
Mac/scripts/build.sh     # xcodegen + xcodebuild Debug, ad-hoc signed, output in Mac/build
Mac/scripts/run.sh       # build then open Mac/build/Debug/7-Zip.app
Mac/scripts/test.sh      # unit tests
```

`Mac/project.yml` globs whole directories, so new source files under `Mac/App`, `Mac/Core`,
`Mac/FinderSync` and `Mac/Tests` are picked up without editing it.

## Commits

One scope per branch, commit early and often, message prefix `mac(<scope>): `. End every commit
message with the `Co-Authored-By` and `Claude-Session` attribution lines your own session gives
you, not the ones from an earlier session.

Never merge, rebase, or switch branches; the orchestrator integrates.
