# `harness` — UI test helpers and verification scripts

What a later wave needs to write a UI test for its scope, and the commands to run before
reporting. Sources: `Mac/Tests/UITests/*` (target `7-ZipUITests`), `Mac/scripts/*`. Findings behind
the design (sandboxed test runner, accessibility map, launch-argument limits) are in
`Mac/docs/reports/harness.md`.

## 1. Commands

```sh
export DEVELOPER_DIR=/Applications/Xcode.app        # every script also does this itself
Mac/scripts/build.sh                 # Debug, ad-hoc signed  (unchanged default)
Mac/scripts/build.sh --release       # or: build.sh Release
Mac/scripts/build.sh --clean         # xcodebuild clean first;  --clean-all wipes Mac/build
Mac/scripts/build.sh -t SevenZipKit  # one target
Mac/scripts/run.sh                   # build + open the app     (unchanged)
Mac/scripts/test.sh                  # unit tests               (unchanged default)
Mac/scripts/test.sh --ui             # UI tests only
Mac/scripts/test.sh --all            # unit + UI
Mac/scripts/test.sh --only SmokeTests/testMenuBarStructure     # one class or one case
Mac/scripts/verify.sh                # clean build + unit + UI + Mac/docs/reports/verify-latest.md
Mac/scripts/verify.sh --fast         # same without the clean build
Mac/scripts/verify.sh --no-ui        # unit tests only
Mac/scripts/parity-check.sh          # ticked/total per scope from Mac/docs/PROGRESS.md
Mac/scripts/parity-check.sh --list panel      # the open items of one scope
```

Every script takes `--help`, works from any directory, exports `DEVELOPER_DIR` itself and exits
non-zero on failure. `build.sh` prints the first real compiler error with context instead of the
whole log; the full logs stay in `Mac/build/*.log`.

A UI run needs the real app, so `test.sh`/`verify.sh` **back up `com.yrambler2001.7zip` to
`Mac/build/prefs-backup.plist`, clear it, force `Lang = "-"` (English) and import the backup back
when the run ends** (`--keep-prefs` opts out). Do not use the app by hand while UI tests run.
Screenshot attachments are exported from the result bundle into `Mac/docs/reports/screenshots/`.

## 1a. App-launch lock (read this before running UI tests)

Every worktree builds the same bundle id, and `XCUIApplication.launch()` attaches to an instance
that is already running instead of replacing it. Two agents driving the app at the same time fail
each other's tests with "Lost connection to the application" and scramble the shared preferences
domain. So there is **one lock for the whole repository**:

```
~/things/a.noindex/7zip/.worktrees/.app-lock      # a directory; $SEVENZIP_APP_LOCK overrides
```

`Mac/scripts/test.sh --ui` (or `--all`) and `Mac/scripts/verify.sh` take it for you and release it
on every exit path, including a failure or Ctrl-C:

* acquire: `mkdir` in a loop, 180 tries five seconds apart (15 minutes), then the scope name and
  pid go into `$LOCK/owner`;
* a lock whose directory is **older than 30 minutes** is reported and broken, so a killed run never
  blocks the repository;
* the scripts print `== app lock acquired`, `== waiting for the app lock … (owner: …)` and
  `== app lock released`; if the wait times out they exit 3 and name the owner;
* `verify.sh` holds it for its whole run and exports `SEVENZIP_APP_LOCK_HELD=1`, so the `test.sh`
  calls inside it do not deadlock on their own lock.

If you drive the app **without** these scripts (`run.sh`, `osascript`, a manual launch), take the
lock yourself:

```sh
LOCK=~/things/a.noindex/7zip/.worktrees/.app-lock
for i in $(seq 1 180); do mkdir "$LOCK" 2>/dev/null && break || sleep 5; done
echo "<scope>" > "$LOCK/owner"
trap 'rm -rf "$LOCK"' EXIT INT TERM
# ... launch, drive, screenshot the app ...
rm -rf "$LOCK"
```

## 2. Writing a UI test

```swift
import XCTest

final class ExtractDialogTests: SevenZipUITestCase {

    override var screenshotPrefix: String { "extract" }     // -> screenshots/extract-*.png

    func testExtractDialogOpens() {
        // clean settings + panel 0 in Mac/Tests/Fixtures
        launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures]))
        let panel = sevenZip.panel(0)
        XCTAssertTrue(panel.waitForRow(named: "test.7z"))
        panel.select("test.7z")
        XCTAssertTrue(sevenZip.selectMenuItem("File", "Extract..."))
        guard let dialog = sevenZip.waitForDialog(title: "Extract") else {
            return XCTFail("no Extract dialog")
        }
        screenshot("01-extract-dialog")                      // PNG + attachment
        XCTAssertTrue(sevenZip.dismissDialog(dialog, button: "Cancel"))
    }
}
```

`SevenZipUITestCase` gives `sevenZip` (the driver), `app` (the raw `XCUIApplication`),
`launch(...)`, `screenshot(_:)`, `screenshotPrefix`; it screenshots a failing test, kills the app
in `tearDown` and restores the preferences domain when the runner is not sandboxed.

## 3. `SettingsSeed` — deterministic settings

Settings are passed as launch arguments (they beat anything stored and never modify it).

```swift
launch()                                                   // .clean
launch(seed: .clean)                                       // 1 panel, home dir, 1200x800 window
launch(seed: .values([SettingsDomain.Key.panelPath0: TestPaths.fixtures,
                      SettingsDomain.Key.showDots: "1"]))  // clean + overrides
launch(seed: .keep)                                        // whatever is stored (persistence tests)
launch(path: TestPaths.fixture("test.7z"), formatHint: "7z")   // 7zFM.exe [path] [-t<type>] argv
launch(arguments: ["-FM.ShowGrid", "1"], environment: ["MY_VAR": "1"])
```

Keys: `SettingsDomain.Key.{lang, position, maximized, numPanels, currentPanel, splitterPos,
panelPath0, panelPath1, listMode0, listMode1, flatView0, flatView1, folderHistory,
folderShortcuts, showDots, showGrid, fullRow, toolbars, autoRefresh, timestampLevel,
timestampShowUTC}` (the Windows registry value names).

Two limits to know (details in the report): an argument value is a **string**, so keys the app
reads as an `Int`/`Bool` object or as an array (`numPanels`, `listMode*`, `toolbars`,
`timestampLevel`, `autoRefresh`, `folderHistory`, `folderShortcuts`) end up at the app's built-in
default — use `sevenZip.ensurePanelCount(2)` for two panels — and `Lang` cannot be seeded from a
test at all (the scripts do it).

**When `SEVENZIP_DEFAULTS_SUITE` lands** (a sibling scope is adding it: the app reads its
preferences from the domain that environment variable names), switching over is a small, local
change — nothing in your tests moves. `SettingsSeed.launchArguments` is the only producer of the
seed and `SevenZipApp.launch(seed:)` its only consumer, so it means: pass
`launchEnvironment["SEVENZIP_DEFAULTS_SUITE"] = "com.yrambler2001.7zip.uitest.<run>"`, fill that
domain with `SettingsDomain(applicationID: …).replace(with:)` — typed values, so `numPanels`,
`toolbars` and `Lang` finally work — and drop the `-key value` arguments. Two details:

* the app's real domain is then untouched, so the `test.sh` preferences backup/restore and the
  `Lang` write are no longer needed (keep them until the hook is on the branch);
* the **sandboxed test runner cannot write any CFPreferences domain the app can see** (the sandbox
  redirects every domain into the runner's container, measured), so the per-run domain has to be
  filled by `test.sh`/`verify.sh` before the run, or the hook has to accept a *plist path* instead
  of a domain name — a path inside the runner's container, which the test can write and the
  non-sandboxed app can read. Per-test seeding only works with the second variant; that is
  recorded in `Mac/docs/requests.md`.

## 4. `SevenZipApp` (the driver)

```swift
// lifecycle
launch(seed:path:formatHint:arguments:environment:timeout:) -> XCUIElement   // the window
relaunch()                       // graceful quit + launch(seed: .keep): asserts persistence
quit() -> Bool                   // "7-Zip > Quit 7-Zip", waits for exit (state is saved)
terminate()                      // SIGKILL, no state saved
isRunning

// window and panels
window, windowTitle              // title = focused panel path, "7-Zip" when empty
panelCount                       // 1 or 2
panel(0), panel(1)               // left, right
panelsAreOrderedLeftToRight
ensurePanelCount(_:)             // toggles View > 2 Panels until it matches

// toolbar (App.cpp g_ArchiveButtons / g_StandardButtons)
toolbar, toolbarButton("Extract"), toolbarButtonTitles

// menu bar (MainMenu.swift)
menuBar, topLevelMenuTitles, menuBarItem("View")
menuItem("View", "2 Panels"), menuItem("File", "CRC", "MD5")
menuItem(selector: "viewTwoPanels:")        // language independent (AX id == selector)
itemTitles(in: "File"), isMenuItemEnabled("File", "Open")
selectMenuItem("View", "2 Panels") -> Bool  // opens the menus and clicks
closeOpenMenus()

// dialogs (NSAlert sheets have no title: the message text is matched)
waitForDialog(title:timeout:) -> XCUIElement?
texts(of: dialog) -> [String]               // message text, informative text, ...
dismissDialog(dialog, button: "OK") -> Bool
waitForNoDialog()

// artifacts
screenshot("01-home", prefix: "extract", test: self) -> URL?
dumpTree("after-open")                      // whole accessibility tree -> a text file
```

## 5. `SevenZipPanel` (one CPanel)

```swift
let p = sevenZip.panel(0)
p.table, p.addressBar, p.upButton, p.statusText        // raw elements
p.path                       // address bar text ("" = root folder)
p.status                     // "1 / 7 object(s) selected    838    ..."
p.rowCount, p.columnTitles   // ["Name", "Size", "Modified", "Created"]
p.names                      // Name column top to bottom (short listings; see below)
p.row(named: "test.7z")      // TableRow element
p.nameCell(named: "test.7z") // the StaticText to click
p.hasRow(named:), p.waitForRow(named:timeout:), p.waitForPath(_:timeout:)
p.cellText(row: "test.7z", column: 1)
p.select("test.7z")          // click (scrolls into view first)
p.open("test.7z")            // double click: enter a folder / open an archive
p.goUp()                     // "Up One Level"
p.clickColumnHeader("Size")  // sort; size and time columns start descending
p.navigate(to: TestPaths.fixtures)   // type into the address bar + Return
p.focusList()                // so Enter / Backspace / "\" reach the list
```

`names` costs one accessibility query per row, and every row of a folder is in the tree even when
scrolled out of sight — use it for short listings and `row(named:)` / `waitForRow` for big ones.

## 6. `TestPaths`

```swift
TestPaths.repoRoot        // worktree root, or nil
TestPaths.fixtures        // Mac/Tests/Fixtures (also copied into the test bundle)
TestPaths.fixture("test.7z")
TestPaths.screenshots     // Mac/docs/reports/screenshots (test.sh exports attachments there)
TestPaths.artifacts       // a directory this process may always write to
TestPaths.realHome        // the user's home; NSHomeDirectory() is the runner's sandbox container
TestPaths.isSandboxed
```

Fixtures (from `Mac/scripts/make-fixtures.sh`): `test.7z`, `test.zip`, `test.tar.gz`,
`test.tar.xz`, `secret.7z` and `secret.zip` (password `secret`), `nested.zip`. Each holds
`readme.txt` (12 B), `notes.md` (21 B), `sub/big.txt` (3000 B), `sub/deep/inner.txt` (10 B).

## 7. Conventions for later waves

* Subclass `SevenZipUITestCase`, set `screenshotPrefix` to your scope, name screenshots
  `NN-what` so they end up as `Mac/docs/reports/screenshots/<scope>-NN-what.png`.
* One behaviour per test, always `launch(...)` in the test (not in `setUp`), and no dependency on
  test order.
* Never assert a behaviour that is not implemented yet — add it when the scope lands.
* Prefer `menuItem(selector:)` over a title when a title may be localized.
* Run `Mac/scripts/verify.sh` before reporting; it writes `Mac/docs/reports/verify-latest.md`.
* Never drive the app outside the scripts without taking the app-launch lock (§1a), and never run
  two UI runs at once — expect to queue behind another agent.
* Read values through the snapshot-based accessors (`names`, `columnTitles`, `itemTitles`,
  `toolbarButtonTitles`) or add new ones the same way; resolving many elements one at a time is slow
  and has crashed the test runner.
* If a test needs something the app does not expose to accessibility, ask the owning scope for it
  in your report and add a line to `Mac/docs/requests.md`, instead of touching their files
  (`00-orchestration.md` ownership table).
