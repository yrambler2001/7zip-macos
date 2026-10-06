# Contributing

Thanks for helping. Bug reports, fixes and improvements to the Mac app are welcome.

## Before you start

- **Engine bugs go upstream.** If 7-Zip on Windows or the console `7zz` behaves the same way
  (a format, compression ratio, a crash while parsing an archive), report it to 7-Zip at
  [7-zip.org](https://www.7-zip.org). This repository is about the macOS app.
- **Parity with Windows 7-Zip is the specification.** A change that makes the Mac app behave
  differently from the Windows File Manager needs a reason (a macOS convention, a missing
  platform feature). [docs/parity.md](docs/parity.md) lists the existing differences.
- For a larger change, open an issue first so we can agree on the approach.

## Workflow

1. Fork, branch from `macos` (the default branch). `main` mirrors upstream and takes no PRs.
2. Build and test as in [docs/building.md](docs/building.md) and [docs/testing.md](docs/testing.md).
3. Open a pull request against `macos` and fill in the template.

Working with AI agents is fine, and how this port was made (see [ai/README.md](ai/README.md)); one
agent per branch with a short report is a useful habit but not required. Whoever opens the pull
request is responsible for it: read the diff, run the tests, and keep the agent's commit trailers.

## Rules the code follows

- **Warnings are errors** in `Mac/` code (Swift and Objective-C++). Upstream warnings are tolerated.
- **Swift + AppKit only**: no SwiftUI, no storyboards or xibs, no third-party dependencies.
- **Do not edit `C/`, `CPP/`, `Asm/`, `DOC/`** unless it is unavoidable. A patch must be guarded by
  `#ifdef _WIN32` / `__APPLE__`, leave Windows behaviour unchanged, and be listed in
  [`Mac/docs/upstream-patches.md`](Mac/docs/upstream-patches.md).
- Keep the Windows resource ID in a comment next to each menu item and dialog control
  (`// IDM_FILE_OPEN`), and cite the inventory section (`01 §3.7`, see [ai/](ai/README.md)) when
  implementing Windows behaviour.
- User-visible strings go through `Lang` with their 7-Zip language IDs so the official
  translations keep working.
- New source files under `Mac/App`, `Mac/Core`, `Mac/FinderSync` and `Mac/Tests` are picked up by
  `Mac/project.yml` automatically.

## Tests

- `Mac/scripts/test.sh` (unit) and `Mac/scripts/test.sh -H` (app-hosted) must pass.
- Add a test for a bug fix where you can: unit tests for the bridge, app-hosted tests for windows,
  dialogs and menus.
- UI tests (`Mac/scripts/test.sh -u`) need a local GUI session and permissions; run them when you
  change input handling, and say in the PR if you could not.
- Tests must not leave files in the repository; screenshots go to `Mac/build/screenshots/`.

## Commits

Small, focused commits with a clear message. A `mac(<scope>): ` prefix (`mac(panel): …`) matches
the history but is optional.
