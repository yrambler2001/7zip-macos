# `harness2` — the UI suite green, and honest checklist numbers

**19 of 19 UI tests and 209 of 209 unit tests pass, and `Mac/scripts/verify.sh` is green end to
end for the first time.** None of the five failures was a product bug, as the triage said — but
**three of the five diagnoses were wrong**, and two of those pointed at product code that turned
out to be correct. Every one was confirmed against a dump of what the app really exposes before
anything was changed.

Branch `mac/harness2`, worktree `.worktrees/harness2`, five commits.
Scope: `Mac/scripts/*`, `Mac/Tests/UITests/*`, `Mac/project.yml`, plus the two file exceptions in §6.

---

## 1. The five UI failures, and what each really was

| # | Test | Filed diagnosis | Held up? | What it was |
|---|---|---|---|---|
| 1 | `SmokeTests/testSortByColumnHeaderReordersRows` | the app restores a saved column layout, so the default sort is not name-ascending | **yes** | the key is `FM.Columns.FSFolder`, written on quit into the one shared domain |
| 2 | `PanelTests/testCopyBetweenPanels` | `addressBar` indexes the split group's combo boxes and picks the wrong one with two panels | **no** | the element was right; `Cmd+A` is the app's Edit > Select All, so the field was never cleared |
| 3 | `PanelTests/testListContextMenuContents` | the right-click missed the row and caught the Apple menu | **half** | the right-click hit the row and the menu was correct; `app.menus.firstMatch` *is* the Apple menu |
| 4 | `PanelTests/testSelectionCommands` | the mask field lookup silently misses, so the `*` default selects everything | **yes** | an editable `NSComboBox` has no child text field, so the lookup could never match |
| 5 | `SmokeTests/testMenuBarStructure` | the File > CRC submenu title comes from lang id 553 and may not be "CRC" | **no** | the title is "CRC" and MD5 resolves; the line *above* it, `menuItem(selector: "helpAbout:")`, is what failed |

### 1.1 Test isolation — confirmed, fixed for the whole suite

The app writes its per-folder-type column layout under `FM.Columns.<FolderTypeID>` when it quits
(`Settings.setColumnLayout`, 01b §5.3), and for a file-system folder the type ID is `FSFolder`.
Every test shared the one preferences domain, so whichever test last clicked a column header
decided the next test's "default" order. `PanelLogic.swift:216` is right, as the triage said.

The fix is per-test settings domains, not a targeted `FM.Columns.*` clear — see §2.

### 1.2 Copy between panels — the diagnosis was wrong twice over

`SevenZipPanel.addressBar` was `splitGroup.children(matching: .comboBox).element(boundBy: index)`,
and for panel 1 that resolves to the same element the new code resolves to, so it was never the
cause. The failure message proves it: the typed path landed in panel 1's combo, appended to the
path already there —

```
panel 1 shows '~/~/Library/Containers/…/panel-copy-dst-…010'
```

`navigate(to:)` cleared the field with `Cmd+A`, which is the key equivalent of **Edit > Select All**
(`IDM_SELECT_ALL 600`, `MainMenu.swift:165`). AppKit offers a key equivalent to the menu bar before
the key window's responder chain, so the panel selected all of its *rows* and the field editor
never saw the keystroke. The trailing `Delete` that undoes inline completion then ate a real
character (the destination UUID lost its last digit). `navigate` now selects with `Cmd+Right` then
`Shift+Cmd+Left` — line motions the menu bar does not bind — drops an inline completion only when
the value really is the path plus a suffix, retries up to three times and returns `false` unless
the bar ends up showing exactly the path, so a half-typed path can never look like a navigation
that simply did not happen.

Past that the test failed again at its last line, on its own setup: `makeScratch` gave the source
and the destination the *same three names*, so copying `alpha.txt` raised **Confirm File Replace**
(IDD_OVERWRITE 3400), the app sat modal and the closing `ensurePanelCount(1)` could not open the
View menu. Worse, `right.hasRow("alpha.txt")` had been true *before* the copy ran — the assertion
proved nothing. The destination is created empty now, and the test asserts it starts empty, that
the file exists on disk afterwards, and that nothing is still asking.

I still addressed each panel's elements properly (§2), because the old form is only correct while
the AX order happens to match the panel order.

### 1.3 The list context menu — the right-click was fine

The right-click **did** open the panel's context menu, with all six expected items
(`Open archive`, `Extract files...`, `Add to archive...`, `Rename`, `Delete`, `Properties`).
`app.menus.firstMatch` is the Apple menu because **every menu-bar menu is in `app.menus` too** —
all of them with an *empty* title and a zero frame `(0, 1185, 0, 0)` while closed, so neither the
title nor `firstMatch` distinguishes them. Of 22 menus in `app.menus`, the open context menu was
number 9 and the only one with a real frame.

The list menu is the `NSTableView`'s own `menu(for:)` (`PanelTableView.swift:41`, NM_RCLICK,
01 §2.8), so in the accessibility tree it is a **child of the table**. New helpers
`SevenZipPanel.openContextMenu(onRow:)` and `menuItemTitles(of:)` address it from there.
`app.children(matching: .menu)` is *not* an alternative: it is empty, the menu is not a direct
child of the application element.

### 1.4 Select by mask — confirmed

`IDC_COMBO 101` of `IDD_COMBO 98` (01b §4.4) is an editable `NSComboBox`, and its only
accessibility child is the disclosure button: `comboBoxes=1 textFields=0`. So
`dialog.comboBoxes.firstMatch.textFields.firstMatch` could never match, the `if field.exists`
skipped silently, and the default `*` mask selected all four items — exactly 4 of 4 where 2 of 4
was expected. `ComboDialog.run()` focuses the combo and selects its text as 7zFM does
(`ComboDialog.cpp:35-37`), so the test types through that focus and then **reads the mask back**,
which is what makes a miss fail here instead of turning into a wrong selection count.

### 1.5 The menu bar — the product is right, the assertion above it was not

Measured in the built menu:

```
File>CRC = ["CRC-32","CRC-64","XXH64","MD5","SHA-1","SHA-256","SHA-384","SHA-512","SHA3-256","BLAKE2sp","*"]
menuItem(File,CRC,MD5).exists       = true
menuItem(selector: "helpAbout:")    = false
menuItem(selector: "toolsShowAbout:") = true
```

No `.ttt` translates lang id 553, so `Lang.menuTitle(553, "CRC")` falls back to the resource text
and the submenu really is titled `CRC`. The assertion that failed is `SmokeTests.swift:170`, the
line before it: `ToolsCommands.install()` retargets both `IDM_ABOUT 961` items at
`MainWindowController.toolsShowAbout(_:)` on `didFinishLaunching`, and an `NSMenuItem`'s
accessibility identifier is its **current** action. The test now asserts About by menu path plus
either selector, and also asserts the eleven CRC titles so the submenu is covered explicitly.
Filed for `tools`/`panel` in `requests.md`: once the Wave 1 `helpAbout` placeholder is dropped and
`MainMenu.swift` points `IDM_ABOUT` straight at the real dialog, the runtime retarget can go and
the test can assert one selector again. **I did not change the product.**

---

## 2. Harness robustness

### 2.1 Per-test settings domains — the plist-path request, answered without a product change

The open request asked `options` to make `SEVENZIP_DEFAULTS_SUITE` accept a plist path as well as a
domain name, because the sandboxed XCUITest runner cannot write any CFPreferences domain the app
reads. **It already does.** `NMacPrefs::ApplicationID()` hands the variable straight to
CFPreferences, and **CFPreferences accepts an absolute path as an application ID**, then reads and
writes exactly that file. Measured on this machine with a small CoreFoundation probe:

| probe | result |
|---|---|
| `CFPreferencesCopyAppValue(k, "/a/b/seed")` and `".../seed.plist"` | both resolve to `/a/b/seed.plist` |
| a domain path with no file | behaves as an empty domain (`NULL`) |
| a launch argument `-k v` vs the file | the **argument wins**, for any application ID |
| typed `Int` / `Bool` / array in the file | reach the app as themselves |

So `SettingsSeedFile` writes the seed into `TestPaths.artifacts` — inside the runner's own
container, which the runner may write and the unsandboxed app may read — and every `launch()`
hands the app that path. Consequences:

* **Values are typed.** `FM.Panels.numPanels`, `FM.ListMode*`, `FM.Toolbars`, `FM.AutoRefresh`,
  the `Bool` keys and **`Lang`** all work now; the launch-argument channel could express none of
  them (01b §5.2). Verified end to end: a seed of `numPanels = 2` brought the app up with two
  panels and `Lang = "-"` gave English menu titles.
* **Nothing leaks.** The state the app saves on quit goes into a throwaway file, so
  `FM.Columns.FSFolder` cannot reach the next test — which is fix #1.
* **The real domain is untouched.** `test.sh`'s backup/clear/restore is now only a safety net for a
  test that launches without a seed; it is kept because it costs nothing.
* `.keep` reuses the same file, so `relaunch()` is a real persistence assertion against the file
  the app itself wrote.

New seed cases: `.clean`, `.values([String: String])`, `.typed([String: Any])`, `.only([String: Any])`,
`.keep`. `sevenZip.seedFile` exposes the URL and reads the file back; a failing test's file is left
on disk as evidence, a passing test's is deleted. `Mac/docs/api/harness.md` §3 documents it.

### 2.2 Addressing one panel

AppKit flattens each panel's container view away: both panels' Up button, folder icon, address
combo, list scroll view and status label are **siblings** inside the window's `SplitGroup`, with
the `NSSplitView` divider (an AX element of type `.splitter`) between them. There is no per-panel
container to address, so `SevenZipPanel` derives the per-type index from one snapshot of the split
group, sorted left to right and cut at the divider. `addressBar`, `upButton` and `statusText` now
always belong to the panel asked for whatever order accessibility reports and wherever the divider
sits. `table` is deliberately left as the cheap `window.tables.element(boundBy:)`: it is the
hottest accessor in the driver and the tables really are in panel order.

### 2.3 `test.sh --only` no longer reports an empty run as a pass

The old code guessed the target from the test name, so everything but `*Smoke*`/`*UI*` went to the
unit target, where `-only-testing` matched nothing, `xcodebuild` exited 0 and the run read as
green. Now:

* the target is the one whose source directory **declares the class** (`Mac/Tests/UITests` or
  `Mac/Tests/SevenZipKitTests`);
* a `--only` naming a class or a test function that does not exist exits **2** before anything is
  built;
* a run that executed no test at all — no pass, no failure, no skip — exits **4**.

Measured: `--only NoSuchClass` → 2, `--only PanelTests/testNoSuchFunction` → 2,
`--only PanelTests/testCopyBetweenPanels` → resolves to `7-ZipUITests` and runs it.

---

## 3. The flaky volume test

`FSFolderTests/testCrossVolumeCopyMoveAndVolumeRefresh` asserted
`volumes.itemCount == volumeCountBefore (+ 1)`, so any disk image another agent mounted or detached
while it ran broke it — which happened twice during the parallel waves. Both totals are gone; it
now polls the volumes listing for **its own** volume name appearing and disappearing again, which
is what the test is actually about. The `wasChanged` assertions (a mount and an unmount must be
reported) are kept, because those are real `IFolderWasChanged` behaviour.

---

## 4. The scaffold checklist, audited

`Mac/docs/PROGRESS.md` §1 was 0 of 57 only because the checklist was written after the scaffold was
built. Every item was checked against the tree — code, build settings or a test, never the file
name alone. **28 are now ticked**; the other 29 are each partly built and stay open, with a note in
`PROGRESS.md` naming the recurring reasons. Totals moved 334/496 → **362/496 (73 %)**.

What the audit could **not** confirm, and why:

* Anything that only shows at runtime: the splitter thickness of 4 (the code uses
  `dividerStyle = .thin`), the status bar's `{220, 320, 420, rest}` section edges (the numbers are
  nowhere in the tree — the port uses one label with four joined parts), whether the toolbar is
  hidden when the `Toolbars` mask is 0 (it is always installed).
* Items whose wording names something renamed during development: `Support/TempFiles` is
  `Support/TempOpen.swift`, `SZTempFiles`/`SZWorkDir` are `SZTempOpen`/`SZWorkDirSettings`. The
  behaviour is there; the names are not, so they stay open rather than being quietly ticked.
* Genuinely missing, and worth a follow-up: the `QuickAction` target does not exist (1.1#1);
  `SZCodecs.loadCodecs()` runs **before** the window is created, so the window does not appear
  before the format table is built (1.2#3, 01 §1.1, §9 #29); `IFolderProperties` and `IFolderClone`
  are not exposed on `SZFolder` (1.3#4); every launch opens exactly one window and there is no
  `application(_:open:)`, so "every launch opens a new window" (1.4#3, 01 §1.1) is not met; the
  temp-dir names are `7zO-XXXXXX` from `mkdtemp`, not `7zO<8 hex>` (1.3#12); `Lang` only consults
  `preferredLanguages[0]` (1.3#10); `make-fixtures.sh` does not generate `multi.7z.001-003`
  (1.3#14); and `SZProgressDelegate`'s pause is a 0.1 s polling sleep rather than a condition
  variable (1.3#6).

The two symlinks under `Mac/Tests/SevenZipKitTests/` that pointed at `App/Support/Settings.swift`
and `FileTypes.swift` are gone; both files are sources of the `SevenZipKitTests` target in
`Mac/project.yml`. Both stay Foundation-only, which is what lets them compile outside the app
target. `PanelRow.swift` and `PanelLogic.swift` (and `CompressModel.swift`) are still symlinks —
the `panel` request covers them and the pattern to copy is now in `project.yml`, but removing files
in another scope's directory while that scope has open work invites a conflict.

---

## 5. Verification

Everything ran with `DEVELOPER_DIR=/Applications/Xcode.app`; `xcode-select -s` was never run, and
every UI run took the shared app lock.

`Mac/scripts/verify.sh` (clean build + unit + UI), commit `da57e12`, **exit 0**:

| Step | Time | Result |
|---|---|---|
| clean build (Debug) | 36 s | `** BUILD SUCCEEDED **`; **0 warnings from `Mac/` sources** (33 remain, all upstream `C/`+`CPP/`, which the hard rules tolerate) |
| unit tests | 51 s | **209 passed, 0 failed** |
| UI tests | 278 s | **19 passed, 0 failed** — the first green UI run |
| `parity-check.sh` | — | TOTAL **362 / 496 (73 %)**, up from 334 / 496; `scaffold` **28 / 57** |

Per scope after the audit: `scaffold` 28/57, `fsfolder` 24/58, `panel` 106/108, `extract` 52/57,
`compress` 50/52, `tools` 37/40, `options` 44/46, `finder` 0/36, `packaging` 1/22, `icons` 20/20.

`Mac/docs/reports/verify-latest.md` records the run. The eight stale
`*-failure-*.png` screenshots from earlier red runs are deleted — every test passes, so nothing
regenerates them and leaving them in the report directory would be misleading.

The diagnoses were established with a throwaway `ProbeTests` class that dumped the two-panel
accessibility tree, the open context menu, the whole menu bar with every item's identifier, the Select
dialog and the Copy dialog into the runner's container; it was removed before the first commit.
Screenshots are the usual XCUITest attachments exported into `Mac/docs/reports/screenshots/`
(`screencapture` is still denied on this machine, and no `osascript` was run).

---

## 6. Files touched outside this scope's ownership

* `Mac/Tests/SevenZipKitTests/FSFolderTests.swift` — the volume-total fix, by the orchestrator's
  explicit instruction and for that fix only.
* `Mac/Tests/SevenZipKitTests/Settings.swift` and `FileTypes.swift` — the two symlinks deleted, as
  the `options` request asked.
* `Mac/docs/PROGRESS.md` §1 (`scaffold`), by instruction. No other scope's section was touched.

Nothing under `C/`, `CPP/`, `Asm/`, `DOC/` and nothing in `Mac/App` or `Mac/Core` was changed.

---

## 7. Follow-ups filed in `requests.md`

1. `tools` / `panel` — the About items' accessibility identifier is `toolsShowAbout:` because of
   the runtime retarget; dropping the Wave 1 placeholder removes the need for it.
2. `panel` (`MainWindowController`) — **View > 2 Panels intermittently collapses panel 0 to the
   `kPanelSizeMin` 120 pt minimum** instead of the stored ratio. Measured three times on the same
   seed (`FM.Panels.splitterPos = 0.5`, 1200 pt window): twice the divider came up at 120 with
   panel 0's address combo 59 pt wide, once correctly at 600. `showSecondPanel` sets the
   position in a `DispatchQueue.main.async` while `splitView(_:resizeSubviewsWithOldSize:)`
   recomputes the ratio from `views[0].frame.width` during the layout pass the insertion triggers.
   Nothing is unusable, but the restored splitter position is wrong (01 §1.2, 01b §5.7).
3. `panel` / `opsinfra` — the Copy/Move dialog is ~30 pt too short: with a 502x230 window its OK
   and Cancel buttons sit at y 788-814 while the window ends at 793, so they are drawn clipped
   (visible in `screenshots/panel-07-copy-dialog.png`). They are still in the accessibility tree
   and clickable. `DialogKit.install` sizes from `content.fittingSize + 40`.
4. orchestrator — the app-launch lock does **not** protect a UI run from a sibling agent's *unit*
   run: two concurrent `xcodebuild test` sessions share `testmanagerd`, and the UI one then dies
   with `Failed to initialize for UI testing: Timed out while enabling automation mode.` Hit once
   here, with `mac/cleanup` running `SevenZipKitTests` at the same time; the retry after it
   finished passed. Either the lock covers every `xcodebuild test`, or agents queue unit runs too.

`Mac/docs/HANDOFF.md` needs two corrections the orchestrator owns: item 4 of "What is left"
("Accepting a plist path too would let UI tests seed settings per test") is done and needed no
product change, and "`SEVENZIP_DEFAULTS_SUITE=<name>` … Always set it when driving the app in a
test" should say that the value may also be an absolute path to a plist, which is what the UI
tests now use. I did not edit that file — it is not in this scope's ownership.

Still open and not mine to close: `compress` asked for `Resources/SFX` to be added to the
**SevenZipKit** framework's resources in `project.yml`. It is a `harness`-owned file, but it
changes what the unit-test bundle loads and was outside this assignment, so it is untouched.
