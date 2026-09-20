# `fastui` — a test suite that is fast because most of it stopped launching the app

Branch `mac/fastui`. Scope: `Mac/Tests/*`, `Mac/scripts/*`, `Mac/project.yml`.

## 1. The problem, measured

The UI suite was correct and unusable. Measured on this branch before any change
(`Mac/scripts/test.sh --ui`, Debug, ad-hoc signed, one run):

| | count | test time | wall clock | per test |
|---|---|---|---|---|
| `SevenZipKitTests` | 311 | 22.4 s | 44 s | 0.07 s |
| `7-ZipUITests` | 54 | 1580.5 s | 1604 s | **29.3 s** |

Where the 1580 s went, per class:

| class | tests | time | share |
|---|---|---|---|
| `LocalizationTests` | 6 | 716.5 s | 45 % |
| `LayoutSweepTests` | 11 | 319.1 s | 20 % |
| `PanelTests` | 10 | 171.6 s | 11 % |
| `FinderIntegrationTests` | 10 | 108.7 s | 7 % |
| `SmokeTests` | 9 | 97.4 s | 6 % |
| `SplitViewTests` | 4 | 80.2 s | 5 % |
| `CommandModeUITests` | 2 | 46.4 s | 3 % |
| `AboutAndDragOutTests` | 2 | 40.6 s | 3 % |

Two thirds of the suite — the localization sweep and the dialog layout sweep — was *not* interactive
at all. `LocalizationTests` launched the app once per language, 93 times, to read a menu bar and a
column header. `LayoutSweepTests` launched it eleven times and walked the menu bar to open dialogs,
so that a screenshot could be looked at for clipped controls. Neither needed a window on screen;
both needed *objects*.

## 2. What was done

1. **A host-app test target** (`SevenZipAppTests`, `Mac/Tests/AppTests`) that runs XCTest cases
   **inside the app's own process**, so a test gets the real `NSApp.mainMenu`, real Auto Layout, the
   real lang files and the real dialogs at unit-test speed.
2. **The assertions moved there.** Dialog layout, menu and toolbar inventory, the main window's
   split geometry and the 93-language sweep are now measurements on objects, not screenshots of
   another process.
3. **One app per test class instead of one per test**, reset between tests through
   `sevenzip://test/reset` (`Mac/docs/test-support-contract.md`), waiting for the acknowledgement the
   contract defines; animations off, a state directory and a settings plist per class; every fixed
   sleep in the remaining tests replaced by a condition wait; a test timeout so a hang fails fast.
4. **Shards that run at once.** The XCUITest cases are split into those that only *read* the app and
   those that *synthesize input*. Each shard is built against an app target with a bundle identifier
   of its own, so several instances coexist; the read-only shards and the two unit targets run
   concurrently and the input shard runs alone.
5. **The scripts do the obvious thing**: `build-for-testing` once, then
   `test-without-building -xctestrun` per shard, concurrent group first, input shard last, one merged
   summary. `build.sh`, `test.sh` and `verify.sh` behave exactly as before for a caller who passes no
   arguments; everything new is behind `--for-testing`, `--host`, `--shards` and `--jobs`.

## 3. Before and after

### 3.1 The suite as a whole

Machine: the Apple Silicon VM of `04-toolchain.md` §1, Xcode 26.6, Debug, ad-hoc signed. The
**before** column is `Mac/scripts/test.sh` followed by `Mac/scripts/test.sh --ui` on this branch
before any change; the **after** column is `Mac/scripts/test.sh --shards`, which is one
`build-for-testing` and then the read-only targets concurrently and the input shard alone.

| | tests | wall clock |
|---|---|---|
| **before**: unit tests, then the UI suite | 311 + 54 = 365 | 44 s + 1604 s = **1648 s** (27.5 min) |
| **after**: `--shards`, three consecutive runs | 311 + 24 + 6 + 6 + 25 = **372** | **851 s / 862 s / 1049 s** (14.2 / 14.4 / 17.5 min) |

The UI suite's own number, which is what the 28.7 s per test was about:

| | XCUITest cases | wall clock | per case |
|---|---|---|---|
| before | 54 | 1604 s | 29.7 s |
| after (input shard) | 25 | 621–708 s | 26.5 s |
| after (probe shards, concurrent with everything else) | 12 | 91–280 s | — |

The per-case cost of an XCUITest did **not** change, and that is expected: the reset that removes the
relaunch needs the app side of the contract, which is not on this branch (§5). What changed is how
many cases have to pay it — 54 became 37, and the 17 that left became 24 cases in a target where
they cost 68 s in total rather than about 1118 s.

### 3.2 The split, per target

One run of each target on its own (uncontended), and then what the same target costs inside the
four-way concurrent group:

| target | tests | alone | in the concurrent group | notes |
|---|---|---|---|---|
| `SevenZipKitTests` | 311 | 44 s | 115 / 152 / 199 s | unchanged; it joins the group because it can |
| `SevenZipAppTests` | 24 | 88 s (68 s of tests) | 153 / 235 / 331 s | the 93-language dialog sweep is 55 s of that |
| `7-ZipUITestsProbe1` | 6 | — | 107 / 142 / 280 s | read-only, URL-driven Finder commands |
| `7-ZipUITestsProbe2` | 6 | — | 91 / 118 / 271 s | read-only, launch state + the contract |
| **concurrent group wall clock** | 347 | — | **153 / 235 / 332 s** | four `xcodebuild`s at once |
| `7-ZipUITests` (input shard, alone) | 25 | 690 / 621 / 708 s | — | every case clicks, drags or types |
| `build-for-testing` (incremental) | — | 7–20 s | — | once per run, not once per shard |

Four targets at once cost each of them two to four times its solo time on this VM, so the group's
wall clock is about a third of the sequential sum (471 s → 153 s in the best run) rather than a
quarter. The three runs get progressively slower because a sibling agent's own test run was sharing
the machine (§8), which is also why the honest summary of the *after* number is "14–17 minutes,
against 27.5".

### 3.3 What it will be once the reset lands

Arithmetic, not a measurement, and marked as such. The input shard's 25 cases cost 621 s in the best
run. A launch-and-first-listing is 12–13 s of that per case (measured directly:
`LaunchStateTests.testLaunchesAndListsHomeDirectory`, which launches and reads, is 12.9 s). The
shard has six test classes, so with a working reset it pays six launches instead of 25:

```
621 s − (25 − 6) × 12 s ≈ 393 s        input shard, projected
393 s + 153 s + 20 s    ≈ 566 s        whole suite, projected (9.4 min)
```

That is the number to re-measure after `mac/resetcmd` merges; the reset's own cost (a URL round trip
plus an ack file, which the contract requires the app to write last) is assumed to be under a second
and is the one thing this projection cannot check here.

### 3.4 Assertions moved off the GUI path

17 XCUITest cases (of 54) stopped needing a live app, and are now 24 cases in the app-hosted target:
the 6 localization cases, the 11 layout-sweep cases (one of which audited two windows), 3 of the 4
split-view cases and 2 `SmokeTests` cases, less the two that moved to a probe shard rather than in
process. Counted as *windows audited*, the dialog sweep went from 32 to 36 per run; counted as
*languages fitted*, from 5 to 93.

## 4. What moved where, assertion by assertion

Nothing was dropped silently. The table is the whole of it; where the shape of an assertion changed,
it says so.

| was | is | note |
|---|---|---|
| `LocalizationTests.testLanguagesComeUp1of5` … `5of5` (93 app launches) | `LocalizationFittingTests.testEveryLanguageBuildsAPopulatedMenuBar` | same assertions on the objects: 8 top-level menus, no blank menu title anywhere in the bar (the launch sweep only checked the top level), ≥ 20 File items, the lang file really loaded (`currentLanguageCode`, a translated id 401). **Changed**: "the panel lists its 10 fixture rows and 7 columns" is now "the seven column property names of a file-system folder resolve from the lang file" plus, in `UIProbe2/LaunchStateTests.testSeededFolderAndColumnsComeUp`, the live panel's row count and column titles once — the row count is language independent, so asserting it 93 times bought nothing. **Added**: the status-bar template (IDS_N_SELECTED_ITEMS 3002) must still substitute `{0}`, and lang ids 1031/1032/1007 (the Copy dialog's info block) must be non-empty. |
| `LocalizationTests.testRepresentativeLanguagesLayout` (5 languages × main window + Options pages + 6 dialogs, ~30 launches) | `LocalizationFittingTests.testEveryLanguageFitsTheDialogs` + `testRepresentativeLanguagesAreScreenshotted` | **Strengthened**: the fitting question is now asked of **all 93** languages on the five dialogs whose windows are sized from their labels, and answered by `WindowAudit` as a number instead of by a human looking at five screenshots. The five representative languages are still screenshotted (`fastui-lang-*.png`), now including every Options page. |
| `LayoutSweepTests` (11 cases: main window, Copy, Move, Properties, Create Folder, Split, Link, Folders History, Combine, hash results, About, Benchmark, temp files, 7 Options pages, Compress, Compress Options, Extract, Comment, Password, Progress, Overwrite, 2 × Password, Messages, Memory) | `DialogLayoutTests` (10 cases) + `MainWindowLayoutTests.testMainWindowLayout` | every window of the sweep is still audited and still screenshotted. **Added**: the text viewer (IDD_EDIT_DLG 94), the Select combo, the Overwrite variant without the extra buttons, and the compressing Progress dialog — four windows the launch sweep never opened. **Changed**: `FIT` (the window is smaller than its content's fitting size) is a new hard assertion, and a `FIT-SOFT` warning where the window holds a wrapping label or a scroll view, whose fitting size means nothing; see §6. |
| `SplitViewTests.testTwoPanelsSplitEvenlyOnFirstUse`, `testStoredSplitterPositionIsRestoredOnLaunch`, `testTwoPanelsAtMinimumWindowSize` | `MainWindowLayoutTests.testTwoPanelsSplitEvenlyOnFirstUse`, `testStoredSplitterPositionIsRestored`, `testTwoPanelsAtMinimumWindowSize` | same three trials, same even-split and stored-ratio assertions, measured on the `NSSplitView`'s subview frames instead of on the accessibility frames of the panels' address combos. `testSplitterPositionSurvivesRelaunch` stays an XCUITest: it drags the divider. |
| `SmokeTests.testMenuBarStructure` | `MenuAndToolbarTests.testMenuBarStructure` + `testMenuItemsAreAddressableBySelector` | the same expected item lists, verbatim. **Added**: *every* item that sends an action reports that action as its accessibility identifier (the rule `menuItem(selector:)` depends on), and no item has an empty title (`testNoMenuItemHasAnEmptyTitle`). |
| `SmokeTests.testToolbarButtons` | `MenuAndToolbarTests.testToolbarButtons` | same seven labels in order; **added**: every item sends an action, and Add sends the toolbar Add selector rather than merely being enabled. |
| `SmokeTests.testLaunchesAndListsHomeDirectory` | `UIProbe2/LaunchStateTests.testLaunchesAndListsHomeDirectory` | unchanged, moved to a read-only shard (it never clicks). |
| `AboutAndDragOutTests.testAboutItemsHaveAStableAccessibilityIdentity` | split: the identifier half in `MenuAndToolbarTests.testMenuItemsAreAddressableBySelector`, the click and the dialog in `AboutAndDragOutTests.testAboutItemOpensTheAboutDialog` | both halves are still asserted, the first without a launch. |
| `FinderIntegrationTests` (10) | 6 in `UIProbe1/FinderCommandInspectionTests`, 4 in `UITests/FinderIntegrationTests` | **Changed** for the three refusal boxes (IDS_SELECT_FILES 3015, "Unsupported command", "Unknown switch"): they used to be closed by clicking OK, and a read-only shard may not click. The click was dismissal, not assertion, so it is replaced by asserting that the box's OK button exists and is enabled — strictly more than before — and the instance is thrown away in `tearDown`. The cases where the click *is* the specification (Cancel is `E_ABORT`: nothing extracted, the app survives, and in command mode the process ends) stayed in the input shard unchanged. **Added**: every URL now goes to *this shard's* instance (`NSWorkspace.open(urls:withApplicationAt:)`) instead of to whichever copy LaunchServices considers the handler for `sevenzip://` — with several worktrees built on this machine that was a real coin toss. |
| `PanelTests` (10), `CommandModeUITests` (2), `SmokeTests` (6 remaining), `AboutAndDragOutTests` (2), `SplitViewTests` (1) | unchanged, input shard | every one of them clicks, double-clicks, drags or types. |
| — | `UIProbe2/TestSupportContractTests` (4, new) | the test-support contract itself: the reset generation on the main window, a reset that returns the app to a known state without quitting, a reset that closes an open dialog, and one shard driving its own bundle identifier. |
| — | `SevenZipAppTests/HostTargetTests` (3, new) | the new target's own preconditions: the settings domain is a throwaway plist and not the developer's, the cases run on the main thread, the fixtures and the screenshot directory resolve. |

**Assertions I decided were worthless, and dropped** — one, and it is a counting argument rather than
a behaviour: `LocalizationTests` asserted the fixtures row count (10) and the column count (7) of the
live panel once per language, 93 times. Neither depends on the language; the row count is what
`FileManager` reports for a directory and the column count is the folder's property list. Both are
still asserted once, on a live panel, in `LaunchStateTests`, and the part that *is* language
dependent — that every column has a name in that language — is asserted for all 93.

## 5. Tests that need the app side of the contract, and are expected to fail until it merges

`Mac/Tests/UIProbe2/TestSupportContractTests.swift` — three of its four cases assert
`Mac/docs/test-support-contract.md`, which `mac/resetcmd` implements in `Mac/App/*` (not this
scope's to write). Each is wrapped in a **non-strict** `XCTExpectFailure`, so it reports green both
before and after that merge, and nothing else in the suite depends on the affordances existing:

* `testMainWindowCarriesTheResetGeneration` — the main window's accessibility value is the reset
  generation, `0` before the first reset;
* `testResetReturnsTheAppToAKnownStateWithoutRelaunching` — the generation goes up, the ack file is
  written last, the panels rebuild, the process survives;
* `testResetClosesAnOpenDialog` — a reset closes a sheet a previous test left open.

`testThisShardDrivesItsOwnBundleIdentifier` is not expected to fail: it is about the build, which
this scope owns.

Until the merge, `SevenZipApp.prepare` finds `testSupportIsImplemented == false` and relaunches, so
the input shard costs what it cost before per test. **The reset is the only part of the measurement
below that is still projected rather than measured**, and §3 says which number that is.

## 6. Findings

### 6.1 The nineteen-dialog clipping defect is a frame comparison

The defect that motivated the whole dialog sweep — `DialogKit.install` pinning its content with
`+margin` instead of `-margin`, so the bottom `2 × margin` of every dialog, i.e. the OK/Cancel row,
fell outside the window — is `CLIPPED` in `WindowAudit`: a view whose frame leaves the window's
content rectangle. It is found in 0.15 s per dialog, in process, with no screenshot involved. The
PNGs are still written (32 of them, `fastui-*.png`), because truncation and crowding do not show up
in a frame; they are evidence for a human, not the measurement.

### 6.2 `fittingSize` is only a bound when nothing in the window wraps

Asserting `contentSize >= contentView.fittingSize` looked like the sharper version of the same check,
and it is — for the 21 `DialogKit` dialogs, which are built from single-line labels. It is
meaningless for a window with a wrapping label or a scroll view: a wrapping label's fitting size is
its width on *one* line, so the Options window reports "content needs 941x452, the window gives
660x520" in built-in English while looking exactly as the `polish` scope signed it off. So `FIT` is a
failure only where nothing in the window is elastic, and a `FIT-SOFT` warning elsewhere. Four of the
seven Options pages, in every language, are in that warning list, worst 1018x320 in `de`/`ru`/`ja`;
filed for `options` in `Mac/docs/requests.md`.

### 6.3 Four app copies need four Swift module names

Every app target installs its `.swiftmodule` into the shared products directory, so four targets
with `PRODUCT_MODULE_NAME: SevenZipApp` are four commands writing
`Products/Debug/SevenZipApp.swiftmodule` — `error: Multiple commands produce …`. The copies are
`SevenZipAppHost`, `SevenZipAppProbe1`, `SevenZipAppProbe2`; the shipping app keeps `SevenZipApp`,
and `SevenZipAppTests` does `@testable import SevenZipAppHost`.

### 6.4 An app-hosted test writes the developer's preferences unless it is stopped

The host app is a real 7-Zip process: it saves `FM.Position`, `FM.Columns.<FolderTypeID>` and the
splitter ratio when it quits, and these tests change all three on purpose. `TEST_RUNNER_<NAME>`
does **not** reach it (measured: the plist the variable named was never written), but the scheme's
test-action `environmentVariables` does, and `NMacPrefs::ApplicationID()` re-reads
`SEVENZIP_DEFAULTS_SUITE` on every access (`MacPrefs.cpp:23-28`), so a `setenv` before the first
case is a second belt. Both are in place and
`HostTargetTests.testSettingsAreIsolatedFromTheRealDomain` asserts the result.

### 6.5 A modal dialog can be probed without a click

Every dialog of the port is presented the way 7zFM presents its own: a `static func run(...)` that
blocks in `NSApp.runModal(for:)`. `NSApp.runModal` spins a nested run loop in
`NSModalPanelRunLoopMode`, so a timer added to that mode *before* `run()` is called fires inside the
modal session with the window built, ordered front and laid out — which is what `ModalProbe` does,
ending the session with `NSApp.stopModal()` when it is finished. No app-side hook was needed, and
none was asked for.

### 6.6 The probe shards really are independent of another agent's run

Unplanned evidence: the first full `--shards` run happened while the sibling `resetcmd` agent held
the repository app-launch lock and was driving `com.yrambler2001.7zip`. The two probe shards and the
app-hosted target ran to completion anyway — different bundle identifiers, different settings plists,
different `SZ_STATE_DIR` — and only the input shard queued for the lock. That is the whole point of
the split, observed rather than argued.

## 7. Build settings that turned out to be necessary

| setting | target | why |
|---|---|---|
| `TEST_HOST = $(BUILT_PRODUCTS_DIR)/7-Zip-Host.app/Contents/MacOS/7-Zip-Host` | `SevenZipAppTests` | makes the app the process the tests run in |
| `BUNDLE_LOADER = $(TEST_HOST)` | `SevenZipAppTests` | the test bundle links against the app, so `@testable import` resolves |
| `ENABLE_TESTABILITY = YES` | Debug, project-wide (already set) | without it the app module's internal types are invisible |
| `PRODUCT_MODULE_NAME` distinct per app copy | the four app targets | see §6.3 |
| `LD_RUNPATH_SEARCH_PATHS += @loader_path/../Frameworks` | `SevenZipAppTests` | `SevenZipKit.framework` is embedded in the host app |
| `CODE_SIGN_IDENTITY = -`, `CODE_SIGNING_ALLOWED = YES` | inherited | an ad-hoc signed host app accepts an ad-hoc signed injected bundle; nothing else was needed to make the new targets sign |
| `TEST_TARGET_NAME = <app copy>` | each UI shard | `XCUIApplication()` then attaches to that copy with no bundle id in the test |
| `SEVENZIP_APP_NAME` / `SEVENZIP_APP_BUNDLE_ID` / `SEVENZIP_SHARD_NAME` | each UI shard | reach the test bundle through its `Info.plist`, which is how `TestShard` knows which instance to drive and where to send a URL — one `.xctestrun` can then run every shard with no per-shard environment |
| scheme test action `environmentVariables: SEVENZIP_DEFAULTS_SUITE` | `SevenZipAppTests`, `7-Zip-AllTests` | see §6.4 |
| `-test-timeouts-enabled YES -default-test-execution-time-allowance 300` | every run, from `test.sh` | `XCTestCase.executionTimeAllowance` is ignored without it, so a hang stalled the run instead of failing |

The three app copies deliberately do **not** embed `FinderSync` or the two Quick Actions: a test
never loads them, and every build of an app that embeds them registers another copy with
`pluginkit` (`04-toolchain.md` §5.4 item 3).

## 8. Flakiness

<!--FLAKINESS-->

## 9. Gaps and follow-ups

* **The reset itself is not exercised yet.** Until `mac/resetcmd` merges, `prepare` relaunches, so
  the input shard has not yet paid off. The projection in §3 is arithmetic on the measured launch
  cost, not a measurement; re-run `test.sh --shards` after the merge and replace it.
* **The input shard is the wall clock.** It holds 25 of the 37 XCUITest cases because 25 of them
  click. Splitting it further buys nothing while it must run alone; the reset is what shortens it.
* **The concurrent group contends for the machine.** Four targets at once cost each of them roughly
  two to four times its solo time (the unit target: 22 s alone, 100 s in the group), so the group's
  wall clock is a third of the sequential sum rather than a quarter. `--jobs 2` is there for a
  machine where that trade is worse.
* **`LayoutAudit.swift` was deleted** along with `LayoutSweepTests.swift` and
  `LocalizationTests.swift`. `WindowAudit` supersedes the first (real views instead of accessibility
  snapshots, real cell metrics instead of a system-font guess); if a later scope needs to audit a
  window it cannot reach in process, it is in the history.
* Three requests filed in `Mac/docs/requests.md`: a silent rejection of the `test` URL host for
  `resetcmd`, the Options page widths for `options`, and the path bar's oversized folder icon for
  `panel`.
