# Harness report — branch `mac/harness`

> **Publication note:** this report was written when it lived in `Mac/docs/reports/`. Its screenshots were removed from the repository before publication; a few showcase images live on in `docs/images/`, and the tests now write their screenshots to the git-ignored `Mac/build/screenshots/`. Paths below that point at removed images are kept as a record of what was measured.

Scope: the verification infrastructure every later wave uses — the `7-ZipUITests` XCUITest target,
a reusable Swift helper library in `Mac/Tests/UITests/`, and the scripts in `Mac/scripts/`
(`build.sh`, `test.sh`, `verify.sh`, `parity-check.sh`). Owned paths: `Mac/scripts/*`,
`Mac/Tests/UITests/*`, `Mac/project.yml`. Nothing else was touched.

API and usage examples: `ai/api/harness.md`.

---

## 1. The UI test target (`7-ZipUITests`)

Added to `Mac/project.yml`:

```yaml
  7-ZipUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: Tests/UITests
        excludes: ["Info.plist"]
      - path: Tests/Fixtures        # type: folder, buildPhase: resources
    dependencies:
      - target: 7-Zip               # the app under test
    settings:
      base:
        PRODUCT_NAME: 7-ZipUITests
        PRODUCT_MODULE_NAME: SevenZipUITests
        PRODUCT_BUNDLE_IDENTIFIER: com.yrambler2001.7zip.UITests
        INFOPLIST_FILE: Tests/UITests/Info.plist
        TEST_TARGET_NAME: 7-Zip     # makes XCUIApplication() find the app with no bundle id
        SWIFT_TREAT_WARNINGS_AS_ERRORS: YES
        LD_RUNPATH_SEARCH_PATHS: [..., "@executable_path/../Frameworks", "@loader_path/../Frameworks"]
```

plus the scheme wiring: the target is in the `7-Zip` scheme's `test.targets` (next to
`SevenZipKitTests`) and has its own `7-ZipUITests` scheme, so both
`xcodebuild -scheme 7-Zip test` and `-scheme 7-ZipUITests test` work. Signing is the project-wide
ad-hoc setup (`CODE_SIGN_STYLE Manual`, `CODE_SIGN_IDENTITY -`); no per-target signing settings
were needed.

**The app is launchable and fully driveable under XCUITest as it is.** No test hook, entitlement,
`Info.plist` key or accessibility identifier had to be added; no TCC/automation prompt appeared;
being non-sandboxed and embedding the `FinderSync.appex` changes nothing (the appex is not loaded
by the app process). What was necessary, in `04-toolchain.md` style:

1. **`TEST_TARGET_NAME` must name the app target.** With it, `XCUIApplication()` launches the built
   `Mac/build/DerivedData/Build/Products/Debug/7-Zip.app`. Do *not* use
   `XCUIApplication(bundleIdentifier: "com.yrambler2001.7zip")` in a test: that goes through
   LaunchServices and can start a *different* copy (every worktree build registers one).
2. **The generated runner is `7-ZipUITests-Runner.app`** (a copy of Xcode's `XCTRunner.app` with
   the `.xctest` bundle inside). It is **app-sandboxed** and Xcode 26.6 signs it with its own
   entitlements: `com.apple.security.app-sandbox = true`,
   `temporary-exception.files.absolute-path.read-only = ["/", "/"]`. Setting
   `CODE_SIGN_ENTITLEMENTS` on the UI test target does **not** change them (verified: the runner
   keeps `app-sandbox = true`), so the sandbox is a fact to design around, not to switch off.
   Consequences, all measured:
   * `NSHomeDirectory()` inside a test is
     `~/Library/Containers/com.yrambler2001.7zip.UITests.xctrunner/Data` — use
     `TestPaths.realHome` (getpwuid) for the user's home directory.
   * Writing anywhere in the worktree fails with EPERM (`NSCocoaErrorDomain 513`), so a test
     cannot save a PNG into `Mac/build/screenshots`. Screenshots are `XCTAttachment`s and
     `Mac/scripts/test.sh` exports them from the result bundle (see §4).
   * CFPreferences reads and writes for `com.yrambler2001.7zip` are redirected into the runner's
     container: `snapshot()` returns 0 keys and a write is invisible to the app. Seeding settings
     therefore goes through **launch arguments**, and the developer's real settings can never be
     damaged by test code.
3. **Only the first argument may be a path.** `AppDelegate` treats `argv[1]` as the startup path
   when it does not start with `-`, so `SevenZipApp.launch(path:)` puts it first and the seed
   arguments after it.
4. `xcodebuild ... test` builds and *registers* the app; the FinderSync appex of every build shows
   up in `pluginkit`. Unchanged from `04-toolchain.md` §5.4 #3.
5. Runtime noise that is harmless: `IDELaunchParametersSnapshot: … DebuggerVersionStore.StoreError`,
   the usual CoreSimulator and `appintentsmetadataprocessor` lines.

### Accessibility map (how the helpers address the app)

| Thing | Query |
|---|---|
| main window | `app.windows.element(boundBy: 0)`, `title` = focused panel path or `7-Zip` |
| panel i | direct children of `window.splitGroups[0]`, left to right: `Button` "Up One Level", `ComboBox` (address bar, `value` = path), `ScrollView > Table`, `StaticText` (status bar) |
| panel table | `window.tables.element(boundBy: i)` — index order is left to right |
| row | `TableRow > Cell > StaticText`, cell text in `value`; the leftmost cell is Name. **Every** row is in the tree, also the scrolled-out ones, but only visible rows are `isHittable` |
| column header | `Button` with the column title *inside* the `Table` |
| toolbar button | `Button` with `title` Add / Extract / Test / Copy / Move / Delete / Info inside `window.toolbars[0]` |
| menu item | `MenuBar > MenuBarItem > Menu > MenuItem` (nested for submenus). **The AX identifier of a menu item is its selector** (`viewTwoPanels:`, `helpAbout:`), which is language independent |
| alert / dialog | `Sheet` whose first `StaticText` is the message text (NSAlert has no window title) |

### Settings determinism (launch arguments, measured)

`SettingsSeed` turns into `-<preference key> <value>` launch arguments, which land in
NSUserDefaults' argument domain and win over everything stored.

* Works: keys the app reads as `string(forKey:)`, `bool(forKey:)`, `double(forKey:)` —
  `FM.PanelPath0/1`, `FM.Position`, `FM.ShowDots`, `FM.ShowGrid`, `FM.Maximized`,
  `FM.FlatViewArc0/1`, `FM.Panels.splitterPos`.
* An argument value is a **string**, so keys the app reads as `object(forKey:) as? Int/Bool` or as
  `stringArray` (`FM.Panels.numPanels`, `FM.ListMode0/1`, `FM.Toolbars`, `FM.TimestampLevel`,
  `FM.AutoRefresh`, `FM.FolderHistory`, `FM.FolderShortcuts`) fall back to the app's built-in
  default — which is exactly what a "clean" launch wants. To get *two* panels, toggle the menu:
  `sevenZip.ensurePanelCount(2)`.
* A value containing `{}` is parsed as an old-style plist and then dropped: pass a window frame as
  `"100 100 1200 800"` (`NSRectFromString` accepts it), never `"{{100, 100}, {1200, 800}}"`.
* `Lang` is read through `SZSettings`/CFPreferences (`Lang.loadFromSettings`), so an argument
  cannot seed it. `Mac/scripts/test.sh` writes `Lang = "-"` (English) into the real domain for the
  duration of a UI run, after backing the domain up.

---

## 2. Helper library (`Mac/Tests/UITests/`)

| File | What it gives later waves |
|---|---|
| `SevenZipUITestCase.swift` | base `XCTestCase`: `sevenZip`, `launch(...)`, `screenshot(...)`, `screenshotPrefix`, failure screenshot, app kill and (unsandboxed only) settings restore in `tearDown` |
| `SevenZipApp.swift` | `launch/relaunch/quit/terminate`, `window`, `panelCount`, `panel(i)`, `ensurePanelCount`, `toolbar(Button/Titles)`, `menuBar`, `topLevelMenuTitles`, `menuItem(path…)`, `menuItem(selector:)`, `itemTitles(in:)`, `selectMenuItem(path…)`, `isMenuItemEnabled`, `waitForDialog(title:)`, `texts(of:)`, `dismissDialog(_:button:)`, `waitForNoDialog`, `screenshot`, `dumpTree` |
| `SevenZipApp.swift` (`SevenZipPanel`) | `table`, `addressBar`, `upButton`, `statusText`, `path`, `status`, `rowCount`, `columnTitles`, `names`, `row(named:)`, `nameCell(named:)`, `hasRow`, `waitForRow`, `waitForPath`, `cellText(row:column:)`, `select`, `open`, `goUp`, `clickColumnHeader`, `navigate(to:)`, `focusList` |
| `SettingsDomain.swift` | `SettingsSeed` (`.clean` / `.values` / `.keep`) → launch arguments; `SettingsDomain.Key.*` (the registry-style key names); `snapshot/clear/write/replace/restore/value` for unsandboxed callers |
| `TestPaths.swift` | `repoRoot`, `fixtures`, `fixture(_:)`, `screenshots`, `artifacts`, `realHome`, `isSandboxed` |

---

## 3. Smoke tests (`SmokeTests.swift`)

Nine tests, only over what the scaffold already does: launch + home listing, navigating into a
directory, opening `test.7z` and listing its entries, "Up One Level" out of a folder inside the
archive and out of the archive, the `View > 2 Panels` toggle and its persistence across a
relaunch, sorting by the Size column header (descending first, second click ascending, expected
order computed from the fixture files), the `Enter password` prompt on `secret.7z` followed by the
listing, the menu bar inventory (top-level menus and item titles per menu, plus selector-addressed
items) and the seven toolbar buttons. Each test launches its own app instance and asserts nothing
that is not implemented; the whole suite is ~140 s.

---

## 4. Scripts

`build.sh`, `run.sh` and `test.sh` keep their old contract: the same names, the same behaviour and
exit codes with no arguments, the same output paths (`Mac/build/DerivedData`,
`Mac/build/<Config>/7-Zip.app`, `Mac/build/*.log`), everything new is behind a flag. All scripts
have `set -euo pipefail`, resolve the repository from `BASH_SOURCE` so they work from any
directory, export `DEVELOPER_DIR` themselves and print their usage on `--help` (usage text is the
header comment, so it cannot drift). `bash` on this machine is 3.2, so no `${arr[@]}` on an empty
array and no associative arrays.

| Script | Added |
|---|---|
| `build.sh` | `--config/-c`, `--release/-r` (the positional `Debug|Release` still works), `--clean/-k` (xcodebuild clean), `--clean-all/-K` (delete `Mac/build`), `--target/-t`, `--quiet/-q`, `--help`. On failure it prints the **first real compiler/linker error with 12 lines of context** (`print_first_error`, CoreSimulator noise filtered) instead of 40 grep hits |
| `test.sh` | `--ui`, `--all`, `--target`, `--only <Class[/case]>` (maps to `-only-testing:`), `--config`, `--keep-prefs`, `--help`; a compact `ok/FAIL <target>: N passed, Ms` summary plus a total line; `-resultBundlePath Mac/build/results-<target>.xcresult`; screenshot attachments exported into `Mac/build/screenshots/`; preferences backup/clear/restore around a UI run; a test case that failed while xcodebuild returned 0 still fails the script |
| `verify.sh` | new: clean build → unit tests → UI tests → `ai/reports/verify-latest.md` (date, branch, commit, toolchain, a result table with timings, the parity summary, log and screenshot paths); `--fast`, `--no-ui`, `--config`, `--scope`, `--out`; exits non-zero on any failure |
| `parity-check.sh` | new: awk over `ai/PROGRESS.md`, `done/total/pct` per scope plus a `TOTAL` line, `--scope`, `--list <scope>` (open items with line numbers), `--list-all`, `--file`; read-only |

### Shared-machine hazards, and the app-launch lock

Measured the hard way: every worktree builds the same bundle id, and `XCUIApplication.launch()`
**attaches to an instance that is already running** instead of replacing it. When another agent had
the app open, three of my tests died with `Lost connection to the application (pid …)` /
`Application com.yrambler2001.7zip is not running`, and two parallel UI runs also scrambled
`Mac/build/test-7-ZipUITests.log` (interleaved NUL bytes). The preferences domain is shared as well,
so a run that clears it disturbs whoever else is using the app.

Two fixes, both in place:

1. `SevenZipApp.launch()` terminates a running instance before launching, so a test always drives
   its own fresh process.
2. **One app-launch lock for the whole repository**: the directory
   `<repo>/.worktrees/.app-lock` (`$SEVENZIP_APP_LOCK` overrides; a non-worktree checkout uses
   `<root>/.worktrees/.app-lock` too, else `$TMPDIR/7zip-app-lock`). `test.sh --ui|--all` and
   `verify.sh` acquire it with `mkdir` in a loop — 180 tries, 5 s apart, 15 minutes total — write
   `<branch> (pid …, <time>)` into `$LOCK/owner`, and release it from a single `trap … EXIT INT
   TERM`, so a failure, an assertion or Ctrl-C never leaves it behind. A lock directory **older
   than 30 minutes** is announced with its owner and broken; a wait that runs out exits 3 and names
   the owner. `verify.sh` holds the lock for its whole run and exports `SEVENZIP_APP_LOCK_HELD=1`,
   which makes the nested `test.sh` calls skip their own acquire (no self-deadlock). Agents that
   drive the app *without* these scripts must take the same lock; the recipe is in
   `ai/api/harness.md` "App-launch lock".
   With the lock held, `test.sh` also backs up, clears and restores the preferences domain, because
   no one else can be using the app then; if it still finds a running instance it warns and leaves
   the domain alone.

---

## 5. Verification

| What | Result |
|---|---|
| `Mac/scripts/test.sh --ui` | **9 tests, 0 failures**, 142 s of testing (154 s wall), `** TEST SUCCEEDED **`; the lock was taken and released, the preferences domain backed up, cleared and restored |
| `Mac/scripts/verify.sh` | **green end to end** (exit 0): clean build 32 s (344 C/C++ + 45 Swift compile tasks — Xcode 26's compilation cache makes a wiped `Mac/build` cheap), unit tests 17 passed / 6 s, UI tests 9 passed / 141 s; it queued ~4 min behind the `options` agent's lock first, then wrote `ai/reports/verify-latest.md` (regenerated on every run) |
| `Mac/scripts/parity-check.sh` | 476 items, `packaging 1/22` after the tick below; cross-checked against `grep -c '^- \['` (476) and a manual awk count of the packaging section (22) |
| `build.sh` / `test.sh` with no arguments | re-run after all the changes: `build.sh` prints `== xcodegen`, `== xcodebuild (Debug) -> …`, `** BUILD SUCCEEDED **`, `OK: …/7-Zip.app -> …`, exit 0; `test.sh` runs only `SevenZipKitTests` (17 passed), prints the same per-case lines and `OK: tests passed`, exit 0, and takes **no** app lock (unit runs do not touch the app) |
| Screenshots | `Mac/build/screenshots/harness-01-home.png`, `-02-fixtures`, `-03-archive`, `-04-two-panels`, `-05-sorted-by-size`, `-06-two-panels-restored`, `-07-password` — all written by the suite through the attachment export |
| `ai/PROGRESS.md` | one box ticked, in §9.1: `build.sh` = xcodegen + xcodebuild Debug ad-hoc, `run.sh` opens the app, `test.sh` runs unit **and** UI tests. Nothing else in `packaging` is mine to tick |

Both of the requests I filed in `ai/requests.md` under `harness` are resolved from my side:
the launch-instance fix is in, and the settings-domain override is now owned by the `options` /
bridge scopes (see the note in §"Known gaps" and in `ai/api/harness.md` §3).

## Known gaps / requests

**Settings-domain override (filed in `ai/requests.md`, being implemented by another scope).**
`SEVENZIP_DEFAULTS_SUITE` — the app reading its preferences domain from the environment
(`UserDefaults(suiteName:)` in `Mac/App/Support/Settings.swift`, the same application id in
`Mac/Core/SZSettings.mm`) — removes the two things launch arguments cannot do: the keys an argument
cannot type (`numPanels`, `listMode*`, `toolbars`, `timestampLevel`, `autoRefresh`, the string
arrays) and `Lang`. It is not on this branch, so nothing here depends on it; switching is a change
in two places only (`SettingsSeed.launchArguments` produces the seed, `SevenZipApp.launch(seed:)`
consumes it) and `ai/api/harness.md` §3 spells out the diff.
One caveat for whoever implements it: **the sandboxed test runner cannot write any CFPreferences
domain the app can read** (every domain is redirected into its container — measured), so with a
domain *name* the per-run domain must be filled by `test.sh`/`verify.sh`; accepting a **plist path**
as well (a file the test writes inside its own container, which the non-sandboxed app then reads)
is what would allow per-*test* seeding. Apart from settings, no test hook is needed: everything is
reachable through accessibility.

**Not covered by the smoke suite (add when the scope lands).** Nothing below is asserted today;
each needs the feature first.

| Scope | Tests to add |
|---|---|
| `fsfolder` | root/Computer and Volumes listing, temp-file open/edit round trip, `descript.ion`, hidden-file and attribute columns |
| `panel` | copy/move/delete/rename/create folder/file, Properties, selection dialogs (`Select...`, by type), flat view, folders history, favorites, the keyboard map, column show/hide and widths, two-panel copy, context menu, drag and drop |
| `extract` | Extract dialog (`waitForDialog(title: "Extract")`), path mode / overwrite / password options, Progress window with pause and cancel, Overwrite and Messages dialogs, Test |
| `compress` | Add to Archive dialog and its format/level/encryption controls, Compress Options, update modes, delete-after |
| `tools` | CRC submenu results in the ListView dialog, Benchmark window, Split/Combine, Link, About |
| `options` | every Options page and its round trip through `UserDefaults`, language switching at runtime, associations |
| `finder` | the Finder Sync menu and Quick Actions (these drive *Finder*, not our app: XCUITest can attach to `com.apple.finder`, or use `osascript`), `sevenzip://` URLs, document types |
| `packaging` | DMG contents, bundled help HTML, first-launch registration |

**Follow-up owed to `options` (after the merge, not before).** `Mac/Tests/SevenZipKitTests/`
contains two symlinks to `Mac/App/Support/Settings.swift` and `Mac/App/Support/FileTypes.swift` so
the unit tests can compile those types. Once `mac/options` is merged, replace them with explicit
source entries on the `SevenZipKitTests` target in `Mac/project.yml`
(`- path: App/Support/Settings.swift`, `- path: App/Support/FileTypes.swift`) and delete the
symlinks. It cannot be done on this branch: the files do not exist here yet, and XcodeGen fails on a
source path that is missing. Recorded in `ai/requests.md` (`options` → `harness`).

**For the orchestrator.** `CLAUDE.md` is not mine to edit; its "Build, run, test" block would be
worth two extra lines: `Mac/scripts/verify.sh` before reporting, and "take
`<repo>/.worktrees/.app-lock` before driving the app by hand" (the recipe is in
`ai/api/harness.md` §1a).

**Other notes.**

* `testToolbarButtons` asserts that the toolbar buttons are still **disabled**; whoever implements
  Add/Extract/Test/Copy/Move/Delete/Info must flip that assertion.
* `names`/`columnTitles`/`itemTitles`/`toolbarButtonTitles` read one accessibility snapshot.
  Resolving menu elements one at a time (the first implementation) crashed the test runner
  mid-suite — keep new helpers snapshot-based.
* A long listing exposes every row to accessibility but only the visible rows are clickable;
  `SevenZipPanel.select/open` scroll the row into view first.
* `Mac/build/prefs-backup.plist` is the last backup a `test.sh --ui` run took; it is git-ignored.
* This branch polluted `com.yrambler2001.7zip` with UI-state keys (`FM.Position`, `FM.ShowDots`,
  `FM.ShowGrid`, `Lang = "-"`) while another agent was using the app in parallel; all of them are
  ordinary UI state the options scope owns and rewrites.
