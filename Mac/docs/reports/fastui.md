# `fastui` — a test suite that is fast because most of it stopped launching the app

Branch `mac/fastui`. Scope: `Mac/Tests/*`, `Mac/scripts/*`, `Mac/project.yml`.

## 1. The problem, measured

The UI suite was correct and unusable. Measured on this branch before any change
(`Mac/scripts/test.sh --ui`, Debug, ad-hoc signed, one run):

| | count | test time | wall clock | per test |
|---|---|---|---|---|
| `SevenZipKitTests` | 311 | 22.4 s | 44 s | 0.07 s |
| `7-ZipUITests` | 54 | 1580.5 s | 1604 s | **29.7 s** |

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

**But the per-test cost is not the relaunch.** That was the premise this scope was given, and the
`resetcmd` scope measured it out of existence: a reset is 0.41–0.55 s and a terminate + launch +
first listing is 3.89 s, so the relaunch was 3.4 s of the 29.7 s per case. The rest is XCUITest
itself — element resolution over the accessibility bus and the runner's wait for the app to be idle
before every query and every event. §3.1 re-attributes the savings on that basis; the conclusion it
leads to is the same one the numbers above already suggest, only more strongly: the work is to stop
asking XCUITest for things that are not interactive.

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
3. **One app per test class instead of one per test**, reset between tests through the contract's
   reset (`Mac/docs/test-support-contract.md`), delivered through `<SZ_STATE_DIR>/reset-request` and
   waiting for the acknowledgement the contract defines; animations off, a state directory and a
   settings plist per class; every fixed sleep in the remaining tests replaced by a condition wait; a
   test timeout so a hang fails fast. Worth 3.4 s of a 19 s test, which §3.1 explains.
4. **Shards that run at once.** The XCUITest cases are split into those that only *read* the app and
   those that *synthesize input*. Each shard is built against an app target with a bundle identifier
   of its own, so several instances coexist; the read-only shards and the two unit targets run
   concurrently and the input shard runs alone.
5. **The hot accessors read one snapshot** instead of resolving every match of an element query over
   the accessibility bus — worth 13 % of the input shard on its own, which is four times what the
   reset is worth (§3.1).
6. **The test-only app copies claim nothing on this machine** (no URL scheme, no document types, no
   Services), and every URL a test sends is aimed. Not an optimisation: the copies broke eleven UI
   tests of another scope before this (§6.7).
7. **The scripts do the obvious thing**: `build-for-testing` once, then
   `test-without-building -xctestrun` per shard, concurrent group first, input shard last, one merged
   summary. `build.sh`, `test.sh` and `verify.sh` behave exactly as before for a caller who passes no
   arguments; everything new is behind `--for-testing`, `--host`, `--shards` and `--jobs`.

## 3. Before and after

### 3.1 Where the 29.7 seconds per test actually went

The premise this scope started from — "almost all of it is quitting and relaunching the app" — is
wrong, and the correction came from the `resetcmd` scope's measurements of the app side:

| | measured |
|---|---|
| `sevenzip://test/reset` end to end | **0.41–0.55 s** |
| terminate + launch + first panel listing | **3.89 s** |
| the app's own launch, out of process | 0.7 s |
| one XCUITest case, before this branch | **29.7 s** |

So the relaunch was 3.4 s of the 29.7, about 11 %. The remaining ~26 s is XCUITest's own cost:
resolving elements over the accessibility bus, and the runner's wait for the app to go idle before
every query and every synthesized event. Which reorders the whole exercise:

1. **moving an assertion out of XCUITest entirely** saves ~29 s of the ~29 s — it is the win;
2. **narrowing what a test asks the accessibility bus for** saves a measurable slice of the rest;
3. **reusing the app** (per-class launch + reset) saves 3.4 s per test — real, but a rounding error
   next to the first two;
4. **sharding** does not make anything faster, it makes the read-only part free by overlapping it.

Everything below is attributed on that basis.

### 3.2 The suite as a whole

Machine: the Apple Silicon VM of `04-toolchain.md` §1, Xcode 26.6, Debug, ad-hoc signed. **Before**
is `Mac/scripts/test.sh` followed by `Mac/scripts/test.sh --ui` on this branch before any change;
**after** is `Mac/scripts/test.sh --shards`.

| | tests | wall clock |
|---|---|---|
| **before** | 311 unit + 54 UI = 365 | 44 s + 1604 s = **1648 s** (27.5 min) |
| **after** | 311 unit + 25 app-hosted + 12 probe + 25 input = **373** | **674 s / 680 s / 701 s** (11.2–11.7 min), three consecutive runs, all green |

**2.4 times faster with eight more tests**, and the UI part of it is 37 XCUITest cases where there
were 54.

The honest split of the ~1000 s saved:

| change | saving | how it was measured |
|---|---|---|
| 17 XCUITest cases became 25 app-hosted cases | **≈ 1050 s** | those 17 cost 1118 s (`LocalizationTests` 716.5 s, `LayoutSweepTests` 319.1 s, 3 of 4 `SplitViewTests` ~60 s, 2 `SmokeTests` ~22 s); the 25 that replaced them cost 68 s of test time |
| the 12 read-only XCUITest cases moved into shards that run beside everything else | **≈ 160 s off the wall clock** | they cost 90 s + 51 s on their own, and the concurrent group's wall clock is set by the app-hosted target, not by them |
| snapshot-based list reads instead of resolving every element-query match | **73 s over 25 cases, 13 %** | the same input shard, same machine, same tests: 547 s → 474 s |
| per-class app reuse + reset | **0 s so far, ~64 s once merged** | the app side is in `macos` but not on this branch; 19 of the 25 cases would reset instead of relaunch, at 0.5 s against 3.89 s |

### 3.3 The split, per target

| target | tests | on its own | in the four-way concurrent group |
|---|---|---|---|
| `SevenZipKitTests` | 311 | 44 s | 115 / 152 / 199 s |
| `SevenZipAppTests` | 25 | 98 s (68 s of tests) | 153 / 235 / 331 s |
| `7-ZipUITestsProbe1` | 6 | 90 s | 107 / 142 / 280 s |
| `7-ZipUITestsProbe2` | 6 | 51 s | 91 / 118 / 271 s |
| **concurrent group wall clock** | 348 | — | **181 / 189 s** uncontended, 153–332 s while another agent's suite ran |
| `7-ZipUITests` (input shard, alone) | 25 | **474–507 s** (547 s before the query work, 621–708 s before both) | — |
| `build-for-testing`, incremental | — | 7–20 s | — |

Four `xcodebuild`s at once cost each of them two to four times its solo time on this VM, so the
group's wall clock is about a third of the sequential sum rather than a quarter. The spread in the
group column is contention with a sibling agent's own test run (§8), not variance in the tests.

### 3.4 Per XCUITest case

| | cases | wall clock | per case |
|---|---|---|---|
| before | 54 | 1604 s | 29.7 s |
| after, input shard | 25 | 474–507 s | **19.0–20.3 s** |
| after, probe shards | 12 | 141–220 s (concurrent with the rest) | 11.8–18.3 s |

The 29.7 → 19.0 s is the snapshot reads plus the six fewer `FinderIntegrationTests` launches; the
remaining 19 s per case is XCUITest's own overhead, and the reset will take about 3.4 s off it.

### 3.5 Assertions moved off the GUI path

17 XCUITest cases stopped needing a live app and are now 25 app-hosted cases. Counted as *windows
audited*, the dialog sweep went from 32 to 36 per run; counted as *languages fitted*, from 5 to 93.

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

`Mac/Tests/UIProbe1/FinderCommandInspectionTests.swift` — **all six cases**, for the same reason one
step removed. A read-only shard may not click, so it drives its instance through
`<SZ_STATE_DIR>/reset-request` (`Mac/docs/api/resetcmd.md` §5); the watcher that reads that file is in
`macos` and not on this branch, and the unaimed `NSWorkspace.open` that would otherwise stand in for
it is exactly what broke another scope's tests (§6.7), so it is refused here (`aimedOnly`). Each case
is wrapped in the same non-strict `XCTExpectFailure` and fails in ~11 s at the delivery assertion
rather than timing out. After the merge all six are ordinary passing tests and the wrappers can go —
that is the first thing to do on the merged branch.

**Nine cases in total wait for the merge**, and none of them is deleted or weakened: three contract
cases and these six.

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

Unplanned evidence, twice. The first full `--shards` run happened while the sibling `resetcmd` agent
was driving `com.yrambler2001.7zip` from its own worktree; later, `7-ZipUITestsProbe1` (6 cases, 90 s)
and `7-ZipUITestsProbe2` (6 cases, 51 s) both ran green *while* that agent's full UI suite was
running. Different bundle identifiers, different settings plists, different `SZ_STATE_DIR`. Only the
input shard has to queue for the lock.

The same experiment showed the other half of the lesson: when two runs **do** share a bundle
identifier, they destroy each other. One of my runs broke the sibling's 94-minute-old lock as stale
(its owner pid was gone) while the agent was in fact still driving the app, and four input-shard
cases failed — every one of them a synthesized event that went to the wrong instance. The staleness
rule is right for a killed run and wrong for a lock taken by hand; `api/harness.md` §1a now says so.

### 6.7 An app copy that claims a URL scheme will be handed real URLs

The cost of this one was paid by somebody else, which is why it is written out in full. macOS
registers an app bundle with Launch Services **the moment it is launched**, and
`NSWorkspace.open(URL)` hands a `sevenzip://` URL to whichever registered bundle owns the scheme.
The three test-only copies were built from `Mac/App/Info.plist`, so each of them claimed
`sevenzip://`, the 40 archive document types and the five Services — and once they had been launched
once, `urlForApplication(toOpen:)` named a *probe*. Eleven UI tests of another scope that used an
unaimed `NSWorkspace.open` were answered by a probe, which then took the frontmost menu bar and
failed them. `lsregister -u` on the three bundles fixed all eleven with no other change.

Three things came out of it, and together they mean a copy cannot be chosen even while registered:

* the copies build from `Mac/Tests/AppVariants/Info.plist` — `App/Info.plist` without
  `CFBundleURLTypes`, `CFBundleDocumentTypes`, their `UTImportedTypeDeclarations` and `NSServices`.
  `HostTargetTests.testTheVariantInfoPlistMatchesTheApps` fails if either half drifts, and the host
  app asserts the claims are absent from its *own* running bundle;
* `test.sh` runs `lsregister -u` on the three copies on every exit path;
* every URL a test sends is **aimed**: `SevenZipApp.open` writes it to
  `<SZ_STATE_DIR>/reset-request`, the channel the `resetcmd` scope added for exactly this reason
  (`Mac/docs/api/resetcmd.md` §5), and only falls back to `NSWorkspace`. The unaimed form that caused
  the damage is gone from `Mac/Tests/*` altogether.

### 6.8 A file channel needs a delivery receipt, not a successful write

Switching to the state-directory channel broke the three URL-driven input-shard cases at once: the
app side of the watcher is in `macos` but not on this branch, so the write succeeded, the file sat
there, and the command never ran. A write is not a delivery. The app removes the request *before*
acting on it, so its disappearance is the receipt — `writeRequest` now waits for that, cleans up and
returns false when it does not come, and `open` falls through to the aimed `NSWorkspace` call. Both
branches were measured: 22 passed / 3 failed before, 25 passed after.

### 6.9 Resolving every match of an element query is the expensive part

`nameCell(named:)` resolved **every** static text of the list whose value matched, over the
accessibility bus, one element at a time, to pick the leftmost — and `hasRow` and `waitForRow` went
through it, which made them the hottest accessors in the suite. Reading one snapshot of the table
instead, and resolving elements only when something is actually going to be clicked, took the input
shard from 547 s to 474 s (13 %) with no other change. That is four times what the reset will save.

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

Every run of the suite made during this scope, in order, with every failure accounted for. Nothing
became flaky and stayed flaky: each failure below has a cause and a fix, and the fix is in the branch.

| run | result | wall clock | what failed, and why |
|---|---|---|---|
| baseline `--ui` | 54 / 54 | 1604 s | — |
| `--shards` A | 369 / 372 | 851 s | two input-shard cases (a menu item clicked at an undefined point, `point.x != INFINITY`; a column-header click that landed nowhere) and one unexpected exit of the host app during the 465-dialog language sweep |
| `--shards` B | 372 / 372 | 862 s | — |
| `--shards` C | 372 / 372 | 1049 s | — |
| — | — | — | *two fixes: the reuse lifecycle, and closing each probed window* |
| `SevenZipAppTests` ×3 | 24 / 24 each | 230 / 260 / 303 s | — |
| `Probe1`, `Probe2` | 6 / 6 each | 90 s, 51 s | run *while* another agent's full UI suite was driving the real app |
| input shard | 25 / 25 | 547 s | — |
| input shard, snapshot reads | 22 / 25 | 503 s | three URL-driven cases: the new state-directory channel counted a successful *write* as delivery |
| — | — | — | *fix: the delivery receipt* |
| input shard | 25 / 25 | 474 s | — |
| `--shards` (with the receipt) | 367 / 373 | 687 s | all six probe-shard cases: the copies no longer claim `sevenzip://`, so the unaimed fallback could not reach them |
| — | — | — | *fix: `aimedOnly`, and those six marked expected-to-fail until the watcher merges* |
| `Probe1` | 6 / 6 | 71 s | the six are expected failures; they fail in 11 s each instead of timing out in 34 s |
| **`--shards` final** | **373 / 373** | **701 s** | — |
| **`--shards` final, again** | ****373 / 373**** | | |

Two of those rows are not test flakiness and are worth separating out:

* the **four** input-shard failures in the very first `--shards` attempt (not in the table, because the
  run never completed) were two agents driving `com.yrambler2001.7zip` at once. My run broke a
  94-minute-old lock as stale — its owner pid was gone, but the agent was still using the app.
  Synthesized events went to the wrong instance. The staleness rule is right for a killed run and
  wrong for a lock taken by hand; `api/harness.md` §1a now says so, and that whole class of
  interference is why the probe shards exist;
* the six probe-shard failures and the three URL-driven ones were **my own regressions inside this
  session**, found by re-running, and both are now covered by an assertion rather than by luck (the
  delivery receipt, and `aimedOnly`).

The three runs of the whole plan that shared the machine with a sibling agent's test run took 851 s,
862 s and 1049 s; the three that did not took 701 s, 680 s and 674 s — a 4 % spread. The per-target spread in §3.3
is that contention, not variance in the tests.


## 9. Gaps and follow-ups

* **Nine cases are expected-to-fail until `mac/resetcmd`'s app side is on the branch** (§5): three
  contract cases and the six URL-driven probe cases. First job after the merge: drop the
  `XCTExpectFailure` wrappers, confirm they pass, and re-measure — the reset then replaces 19 of the
  input shard's 25 relaunches, worth about 64 s.
* **The input shard is the wall clock** (492–507 s of the 680–701 s) and 19 s per case is XCUITest
  itself, not the app. The levers left, in the order the measurements suggest: move any remaining
  assertion that is not interactive into `SevenZipAppTests`; narrow the element queries that are left
  (`waitForDialog` polls `app.sheets`, `app.dialogs` and `app.windows` with `containing(...)` six
  times a second, which is the next one worth measuring); and `SZ_DISABLE_ANIMATIONS`, which the
  merged app honours and this branch's app does not, so its effect is still unmeasured here.
* **The concurrent group contends for the machine.** Four targets at once cost each of them two to
  four times its solo time on this VM, so the group's wall clock is a third of the sequential sum
  rather than a quarter. `--jobs 2` is there for a machine where that trade is worse.
* **Two agents on one bundle identifier still destroy each other**, and the 30-minute staleness rule
  will break a lock that was taken by hand and is still in use. The probe shards are immune by
  construction; the input shard is not, and cannot be.
* **`LayoutAudit.swift` was deleted** along with `LayoutSweepTests.swift` and
  `LocalizationTests.swift`. `WindowAudit` supersedes the first (real views instead of accessibility
  snapshots, real cell metrics instead of a system-font guess); if a later scope needs to audit a
  window it cannot reach in process, it is in the history.
* **`Mac/docs/PROGRESS.md` is untouched**: its checkboxes are product behaviours and this scope
  implements none. The `Status` table has no `fastui` row to tick, and adding one is the
  orchestrator's call.
* Three requests filed in `Mac/docs/requests.md`: a silent rejection of the `test` URL host for
  `resetcmd`, the Options page widths for `options`, and the path bar's oversized folder icon for
  `panel`.

## 10. How to run it

```sh
export DEVELOPER_DIR=/Applications/Xcode.app
Mac/scripts/test.sh                  # 311 unit tests, 44 s        (unchanged default)
Mac/scripts/test.sh --host           # 25 app-hosted tests, 98 s
Mac/scripts/test.sh --shards         # everything, 680 s, the way to run it
Mac/scripts/verify.sh -S             # clean build + everything, sharded
```

`Mac/docs/api/harness.md` §0 says which target a new test belongs in, §8 how to audit a window, §10
how to send a URL to the right instance. The measured logs behind every number in §3 are in
`Mac/build/measure/` of the worktree (not committed) and the per-target logs in `Mac/build/test-*.log`.
