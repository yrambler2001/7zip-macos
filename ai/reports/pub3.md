# pub3 — universal app, versioning, update check

Branch `mac/pub3`, in the cleaned clone `7zip-macos` (from `macos` 7edb08f). The user's four
decisions for the first public release: a universal app, one source of truth for the version,
an update check against GitHub Releases, and the docs. Also, at the user's request, the copyright
holder is "Yurii Synyshyn (yrambler2001)" everywhere the port's copyright is shown.

## 1. Universal app (Apple Silicon + Intel)

- `Mac/project.yml`: `ARCHS = arm64 x86_64` for every target. Debug keeps `ONLY_ACTIVE_ARCH = YES`
  (the destination's slice), Release sets it to `NO` (both slices).
- The engine follows upstream's own clang makefiles. arm64 matches `cmpl_mac_arm64.mak` (`USE_ASM=1`):
  `Asm/arm64/LzmaDecOpt.S`, with `Z7_LZMA_DEC_OPT` for `C/LzmaDec.c`. x86_64 matches
  `cmpl_mac_x64.mak` / `var_mac_x64.mak` (`USE_ASM=`): no assembler at all, every `*Opt.c` as C,
  `LzmaDec.c` without `Z7_LZMA_DEC_OPT` (`7zip_gcc.mak:1266-1345`). The MASM `Asm/x86/*.asm` files
  are not touched.
  - Xcode cannot make a per-file flag depend on the architecture. The per-file
    `-DZ7_LZMA_DEC_OPT` therefore became a target-wide `$(SZ_LZMA_DEC_OPT_DEFS)`, set only by
    `SZ_LZMA_DEC_OPT_DEFS[arch=arm64]`. `LzmaDec.c` is the only file that tests the define.
    `EXCLUDED_SOURCE_FILE_NAMES[arch=x86_64] = LzmaDecOpt.S` was already in place.
  - `SevenZipCore` builds with `CLANG_ENABLE_MODULES = NO`. With modules on, the x86_64 slice failed
    in `C/AesOpt.c`: `<wmmintrin.h>` is a submodule of `_Builtin_intrinsics` that does not make
    `__m128i` from `<emmintrin.h>` visible. Upstream compiles with plain textual includes.
  - Checked with `nm`: the arm64 slice of `libSevenZipCore.a` defines and calls
    `_LzmaDec_DecodeReal_3` (the assembler). The x86_64 slice has the C `_LzmaDec_DecodeReal2`.
- No upstream file changed; no patch was needed.
- `build.sh -a/--arch` and `test.sh -A/--arch` choose the destination architecture (default
  `uname -m`). A non-host architecture builds into `Mac/build/DerivedData-<arch>`.

`lipo -info` of the Release bundle (`Mac/scripts/build.sh --release`):

```
Contents/MacOS/7-Zip                                                   x86_64 arm64
Contents/Frameworks/SevenZipKit.framework/Versions/A/SevenZipKit       x86_64 arm64
Contents/PlugIns/FinderSync.appex/Contents/MacOS/FinderSync            x86_64 arm64
Contents/PlugIns/QuickActionExtract.appex/Contents/MacOS/QuickActionExtract    x86_64 arm64
Contents/PlugIns/QuickActionCompress.appex/Contents/MacOS/QuickActionCompress  x86_64 arm64
```

`package.sh` now refuses a bundle in which any Mach-O lacks a slice.

**Rosetta.** Rosetta 2 was not installed on this VM; `softwareupdate --install-rosetta
--agree-to-license` installed it. `Mac/scripts/test.sh -A x86_64` ran SevenZipKitTests on the
x86_64 slice: **398 passed, 0 failed, 5 skipped**, identical to the native run. The same 5 tests skip
in both runs: they compare against the console `7zz`, which is not built in this clone.
`VersionTests/testRunningSlice` confirms that the slice under test is x86_64 (the engine reports
`x64`). No test behaves differently on x86_64.

## 2. Versioning

- **`Mac/VERSION`** is the only place the numbers live (`PORT_VERSION = 1.0.0`,
  `UPSTREAM_VERSION = 26.03`). It is written in xcconfig syntax so that Xcode can include it as it is.
- **`Mac/Version.xcconfig`** is the project-level config file of both configurations
  (`configFiles` in `project.yml`). It sets `MARKETING_VERSION = $(PORT_VERSION)` and
  `CURRENT_PROJECT_VERSION = 1`, then does an optional `#include? "build/BuildNumber.xcconfig"`.
- Every `Info.plist` (app, framework, three extensions, test bundles and test app copies) says
  `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)`. Nothing is hard-coded twice.
- **Build number** = `$BUILD_NUMBER` (CI) or else `git rev-list --count HEAD` (320 at the time of
  writing). `build.sh` and `test.sh` write it to `Mac/build/BuildNumber.xcconfig`, and only when it
  changes, so an unchanged number does not touch the plists.
- `Mac/scripts/version.sh` prints or exports `PORT_VERSION`, `UPSTREAM_VERSION`, `BUILD_NUMBER`,
  `VERSION_NAME` ("7-Zip 26.03 for macOS 1.0.0") and `DMG_NAME` ("7-Zip-26.03-macOS-1.0.0.dmg").
- `Mac/scripts/bump-version.sh <major|minor|patch|X.Y.Z> [--upstream NN.NN] [--dry-run]` rewrites
  `Mac/VERSION`. It also adds a `## [X.Y.Z] — unreleased` section (Added / Changed / Fixed) above
  the newest one in `CHANGELOG.md`, with its tag link. It refuses a version that is not newer
  (compared numerically: 1.10.0 > 1.9.0). It was exercised on `patch --upstream 26.04` and then
  reverted.
- Where the user sees the version:
  - the About box. IDT_ABOUT_VERSION 101 now reads "7-Zip 26.03 for macOS 1.0.0 (arm64)" (or
    "(x64)" on Intel), and "macOS version by yrambler2001" stays;
  - the DMG file name `7-Zip-26.03-macOS-1.0.0.dmg` and its volume name "7-Zip 26.03 for macOS 1.0.0";
  - the output of `package.sh`;
  - the update check's boxes.

  The main window and the help pages show no version on Windows, so they show none here either.
- `VersionTests`, a unit test that also runs under Rosetta, checks three things:
  - `UPSTREAM_VERSION` equals the engine's `MY_VERSION`;
  - the framework's `CFBundleShortVersionString` equals `PORT_VERSION`;
  - `CFBundleVersion` is a number.

## 3. Update check (`Mac/App/Support/UpdateCheck.swift`)

**At startup.** `AppDelegate.applicationDidFinishLaunching` calls
`UpdateCheck.scheduleStartupCheck()`. The check runs 3 s later, after `GMode.launchWindowGrace`, so
a launch made for a Finder command is known as one by then. It runs only if all of these hold:

- the setting `FM.CheckUpdates` is on (the default);
- the process is not a test process: `SZ_TEST_SUPPORT`, an XCTest host, or a copy of the app whose
  bundle id is not `com.yrambler2001.7zip`;
- there is no 7zG-mode context (`GMode.launchedForCommand`, `GMode.isActive`, a 7zG argv);
- a File Manager window exists;
- the last check (`FM.UpdateLastCheck`) is at least 24 h old. A last-check time in the future also
  counts, so a clock that was set back does not block the check for ever.

The request goes out asynchronously and is silent on any error. If the result arrives while a
command or a modal window is up, it is dropped and the last-check time is cleared, so the next
launch asks again.

**The request.** `GET https://api.github.com/repos/yrambler2001/7zip-macos/releases/latest` over
an ephemeral `URLSession` with a 15 s timeout. It carries `Accept: application/vnd.github+json` and
`User-Agent: 7-Zip-for-macOS/<port>`, nothing else. Any HTTP status other than 200 is an error.
Drafts and pre-releases are ignored, and so is a tag that is not a version or is a pre-release
version. `tag_name` is compared as semver after the `v` is stripped (`SemVer` follows semver.org
§11: numeric parts, pre-release identifiers, build metadata ignored).

**A newer release.** A `WinMessageBox` owned by the main window, with the information icon:

- the text "A new version is available: 7-Zip <upstream> for macOS <new> (you have <current>).";
- `<upstream>` comes from the release name or body ("7-Zip 26.04 for macOS …") when it is there,
  otherwise the running engine's version;
- below that, the release name (unless it repeats the headline) and the first 6 non-blank lines of
  `body`, with Markdown heading marks stripped and each line cut at 120 characters;
- the buttons **Download** (opens `html_url`), **Later** (also Esc and the close box) and
  **Skip This Version** (`FM.UpdateSkippedVersion`; that version is not offered at startup again).

**Help ▸ Check for Updates…** is a macOS addition with no Windows resource ID, placed above About.
Its action `helpCheckForUpdates:` is on `AppDelegate`, so it works with no window open. It always
checks, ignoring the 24 h limit and the skipped version, and reports every outcome:

- a newer release: the same box;
- otherwise "You have the latest version (7-Zip 26.03 for macOS 1.0.0).";
- on an error: "Could not check for updates." followed by the reason, with the error icon.

**Options ▸ macOS.** A checkbox "Check for updates at startup" (template control 9930 at
8,46 300×10 DLU) is bound to `FM.CheckUpdates`. Apply and OK write it.

**WinMessageBox.** The box gained `Buttons.custom([titles], escape:)`. It answers `.button1` to
`.button3`, and each button is as wide as its title needs (at least 75 px), keeping MessageBox's
8 px gap and 15 px right margin. The four MB_* sets are unchanged.

**New lang IDs.** They sit outside every official block, after the theme's 9900-9903:

| ID | English |
|---|---|
| 9950 | Check for updates at startup |
| 9951 | Check for &Updates... |
| 9952 | A new version is available: {0} (you have {1}). |
| 9953 | Download |
| 9954 | Later |
| 9955 | Skip This Version |
| 9956 | You have the latest version ({0}). |
| 9957 | Could not check for updates. |

**Privacy.** The README documents it: the app contacts api.github.com once a day at startup, and the
check is turned off in Options ▸ macOS. Nothing is downloaded or installed.

**Tests** (`Mac/Tests/AppTests/UpdateCheckTests.swift`, 15 tests). Every network call goes to
`StubUpdateFetcher`, and setUp installs a failing stub so that a forgotten stub fails instead of
reaching GitHub. The tests cover:

- semver parsing and ordering: `1.10.0 > 1.9.0` and semver.org's whole pre-release chain;
- the JSON fixture: a trimmed real `releases/latest` answer, plus null `name`/`body`, a 404 document
  and HTML;
- the notes excerpt;
- `evaluate`: newer, equal, older, draft, pre-release, a non-version tag, an error;
- the startup decision: setting off, test support, 7zG mode, no window, 23 h / 24 h, a future time;
- the skipped version, at startup and from the menu;
- that a test process never starts a check;
- the request's headers and URL;
- the port version and the About text;
- the Help menu item;
- the Options checkbox and that it persists;
- the newer-release box end to end: text, icon, buttons, owner, Esc = Later; Skip records,
  Download opens, Later does nothing; a skipped version stays silent at startup;
- the up-to-date and error boxes, which are silent at startup;
- the custom button geometry.

A screenshot of the box is written to `Mac/build/screenshots/pub3-update-available.png`, which is
not committed.

## 4. Verification

| Run | Result |
|---|---|
| `build.sh -k` (Debug, clean) | succeeded, no warnings in `Mac/` |
| `build.sh --release` (universal) | succeeded; `lipo` above |
| `test.sh` (SevenZipKitTests, arm64) | 398 passed, 0 failed |
| `test.sh -A x86_64` (Rosetta) | 398 passed, 0 failed — same as native |
| `test.sh -H` (app-hosted, 287 incl. 15 new) | 287 passed, 0 failed |
| `test.sh -u` (XCUITest shards) | 73 passed, 0 failed (input 61, probe1 6, probe2 6) |
| `package.sh` | `Mac/build/7-Zip-26.03-macOS-1.0.0.dmg`, 7.0 MB, volume "7-Zip 26.03 for macOS 1.0.0", every Mach-O universal |

### 4.1 UI tests and the disk image

The XCUITest shards passed with nothing changed for them; the startup check never runs in their
app copies (test support, test bundle IDs).

`package.sh` checks the bundle before it builds the image, and the finished image is version
1.0.0 (build 321), ad-hoc signed. `codesign --verify --deep --strict` passes. `spctl` rejects it,
as it does every ad-hoc build. The image was not installed into /Applications.

The first packaging run caught a bug in the new universal check: the `case` pattern could not match
`x86_64 arm64`, because both words need the space between them. It now tests each slice on its own.

## 5. Copyright holder

The copyright holder is now "Yurii Synyshyn (yrambler2001)" in `LICENSE`, `NOTICE`, the README's
License section and `NSHumanReadableCopyright` of the app, the framework, the three extensions and
the test app copies. That value now reads "7-Zip Copyright (c) 1999-2026 Igor Pavlov. macOS port
© 2026 Yurii Synyshyn (yrambler2001)." Igor Pavlov's copyright is kept wherever it was shown, and
the About box keeps "macOS version by yrambler2001".

## 6. Files

**New:**

- `Mac/VERSION`, `Mac/Version.xcconfig`
- `Mac/scripts/version.sh`, `Mac/scripts/bump-version.sh`
- `Mac/App/Support/PortVersion.swift`, `Mac/App/Support/UpdateCheck.swift`
- `Mac/Tests/AppTests/UpdateCheckTests.swift`, `Mac/Tests/SevenZipKitTests/VersionTests.swift`
- this report

**Edited** (cross-scope edits recorded in `requests.md`):

- `Mac/project.yml`
- `Mac/scripts/build.sh`, `test.sh`, `package.sh`
- every `Info.plist` under `Mac/`
- `AppDelegate.swift` (one call), `MainMenu.swift` (one item)
- `Dialogs/AboutDialog.swift`, `Dialogs/OptionsMacPage.swift`, `Dialogs/WinMessageBox.swift`
- `README.md`, `CHANGELOG.md`, `LICENSE`, `NOTICE`
- `docs/building.md`, `docs/testing.md`
- `ai/api/options.md`, `ai/reports/theme.md`
