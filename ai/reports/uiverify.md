# `uiverify`: the full UI suite after panelgaps, opsgaps, optgaps, archgaps and navgaps

Branch `mac/uiverify`, off `macos` at `379345d`, 2026-10-03. Scope: `harness` / `fastui`
(`Mac/Tests/*`, `Mac/scripts/*`, `Mac/project.yml`), plus one product fix in `panel`'s file.

## 1. Results

The final run was `Mac/scripts/verify.sh -S` (clean Debug build, every target, sharded) at commit
`8fb530d`. It exited 0, and `ai/reports/verify-latest.md` holds its summary.

| target | passed | failed | time |
|---|---|---|---|
| `SevenZipKitTests` (unit) | 378 | 0 | 101 s |
| `SevenZipAppTests` (app-hosted, `-H`) | 92 | 0 | 172 s |
| `7-ZipUITestsProbe1` (read-only shard) | 6 | 0 | 84 s |
| `7-ZipUITestsProbe2` (read-only shard) | 6 | 0 | 81 s |
| `7-ZipUITests` (input shard) | 40 | 0 | 499 s |
| **total** | **522** | **0** | **703 s wall clock** (build 40 s) |

The run before it (`verify.sh -S`, commit `a295e09`) gave 519 / 2 in 754 s. The suite that existed
before this branch was entirely green: **none of the 36 existing input-shard cases broke** after the
five scopes changed the menus, toolbar bitmaps, status bar, dialog placement, Options layout,
archive opening and context menu. Both failures were in the four cases this branch added (§3), and
one of them came from a real product defect (§2).

Standalone runs earlier in the day:

- `test.sh`: 378 / 0 in 48 s.
- `test.sh -H`: 22 passed, then the runner hung during
  `LocalizationFittingTests.testEveryLanguageBuildsAPopulatedMenuBar`. The log stops after language
  `tg` with "The test runner hung before establishing connection", and no crash report was written.
  The same case run alone passed in 8 s, and both later `verify.sh` runs passed the whole target
  (91 and 92). I treat it as a one-off flake and have not reproduced it.

## 2. Product bug found and fixed: the icon views were invisible to accessibility

This affects **Large Icons, Small Icons and List** (01 §3.2, the `NSCollectionView` overlay from
`mac/panel` / `mac/panelgaps`). The accessibility tree showed `CollectionView > Other` (one
section) with **no children** while four items were on screen. VoiceOver users and XCUITest
therefore saw an empty list in three of the four view modes.

- **Fix, in `Mac/App/Panel/PanelListViews.swift`:**
  - `PanelCollectionView.accessibilityChildren()` returns the visible item views in item order.
  - Each item's root view (`ItemBackgroundView`) is an accessibility element with role `.cell`,
    labelled with the item's name, and it reports the item's selection.
- **First attempt, kept and recorded:** making the item view an element alone was not enough.
  AppKit's section element still enumerated nothing.
- **Regression test:** `PanelGapsTests.testIconModeItemsAreAccessibilityCells` (app-hosted). It
  checks that in modes 0 to 2 the children are cells whose labels are exactly the panel's rows.
- **Real-input coverage:** `GapsInputTests.testDragOntoAFolderInLargeIcons` (below) only became
  possible with this fix.

## 3. New XCUITest coverage (`Mac/Tests/UITests/GapsInputTests.swift`, input shard)

All four tests pass. Screenshots are `uiverify-01..03`.

| test | real input path | covers |
|---|---|---|
| `testRightClickExtractToExtractsNextToTheArchive` | right-click a row, click `Extract to "arc/"` | panelgaps' 7-Zip verbs (01 §2.9), the menu holds Open archive too, the extracted folder appears and the panel lists it |
| `testDragOntoAFolderInLargeIcons` | mouse drag between two icons in Large Icons | panelgaps' icon-mode drag and drop (01 §3.15), with no dialog left up |
| `testCancelWhileOpeningIsSilent` | double-click `secret.7z`, click Cancel in the password dialog | navgaps' "Opening" progress (IDS_OPENNING 3303) is up behind the password dialog; Cancel is E_ABORT, so no box appears and the panel stays put |
| `testStatusBarSectionsFollowAClickedItem` | click a row | navgaps' four-part status bar: `1 / 4`, selected size, focused size |

How the two first-run failures were fixed:

- **The drag test:** this is the product bug in §2.
- **The Opening test:** I had assumed the title starts with "Opening"; it only contains it. The
  match is now `CONTAINS`, which is what the app-hosted test uses.

**Not added, and why:**

- **Help buttons (opsgaps).** The only hook is in process (`HelpTopics.opener`), and
  `OpsGapsTests` already uses it for the menu, Options, Extract and Compress topics. From
  XCUITest a click would launch the user's browser. A file-based hook under `SZ_TEST_SUPPORT`
  would be a product change made only for a test, so I did not add one.
- **The Cancel button on the "Opening" progress window itself.** That window appears only after
  500 ms (WaitMode), and no fixture takes that long to open. The password-dialog Cancel above is the
  real input path into the same abort handling.

## 4. Harness changes

- **`SevenZipApp.reset` reads the stall note** (`<ack>.stall`, else `<SZ_STATE_DIR>/reset-stall`,
  matched by generation; requests row modalfix → harness).
  - A missing ack now quotes the note.
  - An ack whose generation has a note is now a **failure** that names the stalled step. The app
    is then not in the state the test asked for, and `prepare` relaunches.
- **`SevenZipPanel` follows the four-label status bar.**
  - `statusText` is section 0: the leftmost label in the panel's bottom row. The panel's ordinal
    no longer names it.
  - New `statusParts`, with Bidi isolates stripped.
- **`SevenZipPanel` icon-view accessors** (requests row panel → harness): `iconView` (the
  collection view on the panel's side of the divider; it does not exist in Details mode),
  `iconNames`, `iconItem(named:)` and `waitForIcon(named:)`.
- **`TestResetSettleTests`** no longer strips stray toolbars. optgaps made `reloadLangItems` skip
  closed windows (requests row optgaps → resetcmd).

## 5. Requests rows

**Closed:**

- panel → harness: `PanelRow` / `PanelLogic` symlinks. These were already source entries; I checked
  that no symlink is left.
- panel → harness: `SevenZipPanel` collection view.
- harness rows from the wave-3 triage.
- finder → harness: merge hazard, already converted.
- The three resetcmd → fastui rows, all already done by `mac/fastui`. I checked each and cited the
  code.
- modalfix → harness: stall note.
- optgaps → resetcmd: toolbar stripping.

**Acknowledged (kept):** opsgaps' `Resources/Help` and archgaps' `test.wim` / `test.xar` fixtures.

**Declined:** compress → harness, `Resources/SFX` in the framework. That would ship the 416 KB of
stubs twice inside the app, for a unit-test convenience that `SEVENZIP_SFX_DIR` already covers.

**New:** uiverify → orchestrator, on intermittent XCUITest automation mode (§6).

## 6. What could not run, and why

Everything ran in the end. One thing for whoever runs the suite next:

- **What happened:** the first three UI attempts (13:52 to 13:58, one input-shard test and one
  probe-shard test) failed before any test with `Failed to initialize for UI testing: Timed out
  while enabling automation mode.`
  - `automationmodetool` reported "Automation Mode is disabled. This device requires user
    authentication".
  - Restarting `testmanagerd` did not help.
- **What changed:** twenty minutes later, with nothing changed, `verify.sh -S` ran all five shards,
  and so did two more runs. The tool still printed the same text.
- **What it is not:** the Accessibility TCC denial, which reads "Not authorized for performing UI
  testing actions" and did not occur.
- **If it sticks:** a human can run
  `sudo automationmodetool enable-automationmode-without-authentication` once. `test.sh` could also
  retry a shard once on that message (requests row).

## 7. Files touched

- `Mac/Tests/UIDriver/SevenZipApp.swift`
- `Mac/Tests/UIDriver/TestSupport.swift`
- `Mac/Tests/UITests/GapsInputTests.swift` (new)
- `Mac/Tests/AppTests/PanelGapsTests.swift`
- `Mac/Tests/AppTests/TestResetSettleTests.swift`
- `Mac/App/Panel/PanelListViews.swift` (**panel scope**, the accessibility fix)
- `ai/requests.md`
- `ai/reports/verify-latest.md`
- three `uiverify-*.png` screenshots

No upstream files are touched. `PROGRESS.md` is untouched: there are no new product boxes, and the
accessibility fix restores behaviour that the panel scope had already ticked.
