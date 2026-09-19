# Harness report — branch `mac/harness`

Scope: the verification infrastructure every later wave uses — the `7-ZipUITests` XCUITest target,
a reusable Swift helper library in `Mac/Tests/UITests/`, and the scripts in `Mac/scripts/`
(`build.sh`, `test.sh`, `verify.sh`, `parity-check.sh`). Owned paths: `Mac/scripts/*`,
`Mac/Tests/UITests/*`, `Mac/project.yml`. Nothing else was touched.

API and usage examples: `Mac/docs/api/harness.md`.

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
     cannot save a PNG into `Mac/docs/reports/screenshots`. Screenshots are `XCTAttachment`s and
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

Eight tests, only over what the scaffold already does: launch + home listing, navigating into a
directory, opening `test.7z` and listing its entries, "Up One Level" out of a folder inside the
archive and out of the archive, the `View > 2 Panels` toggle and its persistence across a
relaunch, sorting by the Size column header (descending first, second click ascending, expected
order computed from the fixture files), the menu bar inventory (top-level menus and item titles
per menu, plus selector-addressed items) and the seven toolbar buttons.

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
| `test.sh` | `--ui`, `--all`, `--target`, `--only <Class[/case]>` (maps to `-only-testing:`), `--config`, `--keep-prefs`, `--help`; a compact `ok/FAIL <target>: N passed, Ms` summary plus a total line; `-resultBundlePath Mac/build/results-<target>.xcresult`; screenshot attachments exported into `Mac/docs/reports/screenshots/`; preferences backup/clear/restore around a UI run; a test case that failed while xcodebuild returned 0 still fails the script |
| `verify.sh` | new: clean build → unit tests → UI tests → `Mac/docs/reports/verify-latest.md` (date, branch, commit, toolchain, a result table with timings, the parity summary, log and screenshot paths); `--fast`, `--no-ui`, `--config`, `--scope`, `--out`; exits non-zero on any failure |
| `parity-check.sh` | new: awk over `Mac/docs/PROGRESS.md`, `done/total/pct` per scope plus a `TOTAL` line, `--scope`, `--list <scope>` (open items with line numbers), `--list-all`, `--file`; read-only |

### Shared-machine hazards (worth knowing before running UI tests)

* The preferences domain `com.yrambler2001.7zip` is **shared by every worktree's build**, and
  `XCUIApplication.launch()` terminates any running instance of that bundle id. A UI run therefore
  disturbs another agent that is using the app, and vice versa. `test.sh` detects a running
  instance, prints a warning and then leaves the domain untouched instead of clearing it.
* Two UI runs in parallel fight over the app and over `Mac/build/test-7-ZipUITests.log`; the
  runners lose their connection to the app ("Lost connection to the application") and the log ends
  up with interleaved NUL bytes. Run one at a time.

---

## Known gaps / requests

**Request to the scope that owns the settings** (`Mac/App/Support/Settings.swift` — `options`; and
`Mac/Core/SZSettings.mm` — bridge): let the app take its preferences domain from the environment,
e.g. `SEVENZIP_DEFAULTS_SUITE=<name>` → `UserDefaults(suiteName:)` in `Settings` and the same
application id in `SZSettings`. That single hook would give UI tests a private domain per run:
no interference with a parallel worktree, seeding of the keys an argument cannot type (`numPanels`,
`listMode*`, `toolbars`, `timestampLevel`, `autoRefresh`, and the string arrays), and a seedable
`Lang` (today `Mac/scripts/test.sh` writes `Lang = "-"` into the real domain instead, and
`testMenuBarStructure` skips itself when the app is not running English strings). No other test
hook is needed: everything else is reachable through accessibility.

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

---

## State note — 2026-09-19 (stopped on the coordinator's request, usage limits)

**Done and verified**

* `7-ZipUITests` target, schemes, `Info.plist`: builds; `xcodebuild -scheme 7-ZipUITests test` runs.
  The app is launchable and driveable under XCUITest with no test hook (§1).
* Helper library (`SevenZipUITestCase`, `SevenZipApp`, `SevenZipPanel`, `SettingsSeed`,
  `SettingsDomain`, `TestPaths`) — compiles warnings-clean, documented in `Mac/docs/api/harness.md`.
* Smoke tests: **one full green run of all 8 tests** (`Executed 8 tests, with 0 failures`,
  `** TEST SUCCEEDED **`, 220 s) with the six screenshots exported to
  `Mac/docs/reports/screenshots/harness-01-home.png` … `harness-06-two-panels-restored.png`.
* `parity-check.sh`: output cross-checked against a manual `grep` (476 items, 0 ticked; packaging
  22). `build.sh`/`test.sh` with no arguments behave as before (`--help`, syntax and the unit-test
  default were exercised; `test.sh --ui` ran the suite end to end).

**Half-done**

* A ninth test, `testPasswordPromptOpensEncryptedArchive` (opens `secret.7z`, types the password
  into the modal `Enter password` alert), is written but has **never been run**.
* The last two UI runs were disturbed by a sibling agent's 7-Zip instance: three tests failed with
  "Lost connection to the application (pid …)" / "Application … is not running" because
  `XCUIApplication.launch()` attaches to an already running instance of the same bundle id.
* `verify.sh` was written and syntax-checked but **never executed end to end**, so
  `Mac/docs/reports/verify-latest.md` does not exist yet.
* `Mac/docs/PROGRESS.md` is untouched — the one box to tick is line 646 in §9.1 (`build.sh` +
  `run.sh` + `test.sh` runs unit + UI tests), and only that one.

**Next steps, in order**

1. In `SevenZipApp.launch()`, terminate a running instance before launching
   (`if isRunning { app.terminate() }` before `app.launch()`), which fixes the failures above.
2. `Mac/scripts/test.sh --ui` once, with no other 7-Zip instance running, and confirm 9/9 green.
3. `Mac/scripts/verify.sh` end to end; check `Mac/docs/reports/verify-latest.md`.
4. Tick PROGRESS.md §9.1 line 646; commit.
