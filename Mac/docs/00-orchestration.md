# macOS 7-Zip File Manager port — orchestration rules

This file is the contract for every agent working on the port. Read it fully before touching anything.

## Goal

A native macOS app, `7-Zip.app` (bundle id `com.yrambler2001.7zip`), with feature parity to the Windows 7-Zip File Manager (7zFM), the 7zG GUI launcher, and the Explorer shell extension, including Finder integration. The C++ archive engine is reused unchanged; only the UI layer is new.

## Locked decisions

| Area | Decision |
|---|---|
| UI | Swift + AppKit. Objective-C++ bridge (`SevenZipKit`) exposes the C++ engine to Swift. |
| Look | Faithful 7zFM layout: same menus, toolbar, dual panels, dialogs, shortcuts. Native AppKit widgets, standard macOS menu bar. |
| Signing | Ad-hoc by default (`CODE_SIGN_IDENTITY=-`). Developer ID via `DEVELOPMENT_TEAM`/`CODE_SIGN_IDENTITY` build settings. |
| Min macOS | 14.0 (Sonoma). |
| Toolchain | Xcode 26.6 at `/Applications/Xcode.app`. Always `export DEVELOPER_DIR=/Applications/Xcode.app`. Never run `xcode-select -s`. |
| Project | XcodeGen (`Mac/project.yml`) generates `Mac/7-Zip.xcodeproj`. The `.xcodeproj` is git-ignored; regenerate with `xcodegen -s Mac/project.yml`. |
| Windows-only | Localization kept (official `Lang/*.txt` in `Mac/Resources/Lang`). Windows SFX stubs kept (`Mac/Resources/SFX`). NTFS alternate streams and Windows security info hidden. |
| Verification | Agents may launch the app, automate it (AppleScript/XCUITest/`osascript`), take screenshots (`screencapture`), and enable the Finder extension (`pluginkit`). |

## Repository layout

```
Mac/
  project.yml            XcodeGen spec (targets: SevenZipCore, SevenZipKit, 7-Zip app, FinderSync ext, Quick Action ext, tests)
  Core/                  ObjC++ bridge (SevenZipKit): .h public headers, .mm implementations
  App/                   Swift AppKit app: windows, panels, dialogs, menus, settings
  FinderSync/            Finder Sync extension (Swift)
  QuickAction/           Action/Service extension for Finder Quick Actions (Swift)
  Resources/             Lang/, SFX/, Assets.xcassets, Info.plist files, entitlements
  scripts/               build.sh, run.sh, test.sh, fetch-assets.sh, package.sh
  Tests/                 XCTest unit tests (SevenZipKit) and UI tests
  docs/                  00-orchestration.md (this), 01-04 inventories, architecture.md, PROGRESS.md, reports/<scope>.md
```

Upstream sources (`C/`, `CPP/`, `Asm/`, `DOC/`) are compiled in place by the `SevenZipCore` target. Edits to upstream files are allowed only when strictly necessary, must be wrapped in `#ifdef __APPLE__` (or `#ifndef _WIN32`) and listed in `Mac/docs/upstream-patches.md`.

## Branching and worktrees

- Integration branch: `macos` (off `main`, which tracks upstream `ip7z/7zip`). Only the orchestrator commits to `macos`.
- Each implementation agent works in its own git worktree at `.worktrees/<scope>/` on branch `mac/<scope>` created from `macos`. The orchestrator creates the worktree and tells the agent its path.
- Agents commit early and often on their own branch. Commit messages: `mac(<scope>): <imperative summary>`.
- Agents never merge, rebase, or touch other branches. The orchestrator merges `mac/<scope>` into `macos` and resolves conflicts.
- Build artifacts (`Mac/build/`, `Mac/7-Zip.xcodeproj`, `*/b/`, DerivedData) are git-ignored.

## Agent deliverables

Every implementation agent must, before finishing:

1. Build cleanly: `Mac/scripts/build.sh` exits 0 with no new warnings in `Mac/` code.
2. Run tests: `Mac/scripts/test.sh` passes.
3. Verify in the running app when UI is involved: launch via `Mac/scripts/run.sh`, exercise the feature, and save screenshots to `Mac/docs/reports/screenshots/<scope>-*.png`.
4. Write `Mac/docs/reports/<scope>.md`: what was implemented, how it maps to the Windows behavior (cite `01-fm-feature-inventory.md` sections), what was verified and how, known gaps, and follow-ups.
5. Update `Mac/docs/PROGRESS.md` checkboxes for the features covered.
6. Commit everything on `mac/<scope>`.
7. Reply to the orchestrator with at most 20 lines: branch name, commit count, what works, what does not, files touched outside `Mac/`.

## Coding conventions

- Swift 5.9+, AppKit, no SwiftUI. Objective-C++ (`.mm`) only inside `Mac/Core/`. Swift never includes C++ headers directly.
- The bridge is asynchronous where the engine blocks: long operations run on a background `DispatchQueue`/`Thread`, progress arrives via delegate callbacks marshalled to the main thread, cancellation via the engine's `IProgress` return codes.
- Strings: engine `UString` is UTF-32 `wchar_t` on macOS; the bridge converts to `NSString`. File paths are `NSString`/`URL`; never `FString` in Swift.
- Settings live in `UserDefaults` under keys that mirror the Windows registry value names (see `01-fm-feature-inventory.md` section 5).
- Localizable UI strings use the 7-Zip lang IDs via `Lang.get(id, fallback)` so the official `Lang/*.txt` files work as-is.
- Every menu item and dialog control keeps its Windows resource ID in code comments (`// IDM_FILE_OPEN`) so parity can be audited.
- No third-party dependencies.

## Build and run

```
export DEVELOPER_DIR=/Applications/Xcode.app
Mac/scripts/build.sh            # xcodegen + xcodebuild Debug, ad-hoc signed
Mac/scripts/run.sh              # builds then opens Mac/build/Debug/7-Zip.app
Mac/scripts/test.sh             # unit + UI tests
```
