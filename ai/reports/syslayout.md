# `syslayout` — the Options ▸ System layout exception

> **Publication note:** this report was written when it lived in `Mac/docs/reports/`. Its screenshots were removed from the repository before publication; a few showcase images live on in `docs/images/`, and the tests now write their screenshots to the git-ignored `Mac/build/screenshots/`. Paths below that point at removed images are kept as a record of what was measured.

Branch `mac/syslayout`, off `macos` at `739abc9`, 2026-10-03. Scope: `options`
(`Mac/App/Dialogs/Options*.swift`) plus its tests in `Mac/Tests/AppTests/OptGapsTests.swift`.
Follow-up of `ai/reports/release.md` §5 ("Options ▸ System screenshot case removed").

## 1. What threw, and why: a real product bug

**Exception:** `NSGenericException`: "The window has been marked as needing another Update
Constraints in Window pass, but it has already had more Update Constraints in Window passes than
there are views in the window."

- **Reproduced:** I restored `testScreenshotSystemPage` unchanged. Run alone, or with its own class,
  it passed. In a full `test.sh -H` run it raised the exception every time, and the runner
  restarted.
- **Why the full run:** the test ran right after `testOptionsPagesFitTheirWindow`, which leaves the
  app in Ukrainian (`uk`) and the shared Options window laid out many times in other languages.
- **The stack:** it ends in `OptionsPageBase.viewDidLayout` → `NSTextField.invalidateIntrinsicContentSize`
  → `setNeedsUpdateConstraints` inside the window's display-cycle layout. The probe's timer drove that
  cycle. Nothing test-specific threw; the test only drew the window.
- **Instrumented:** with one log line per width the page re-told a label, the run showed about 3,900
  passes on a single label, "Асоціювати 7-Zip з:" (IDT_SYSTEM_ASSOCIATE 2201). It alternated
  between two states without end:

  ```
  pmlw 94.5 -> 63.5   frame (-2, 0, 63.5, 48)    three lines
  pmlw 63.5 -> 94.5   frame (-2, 0, 94.5, 32)    two lines
  ```

**Root cause:** two defects combined.

1. **An ambiguous header row.** The row was `NSStackView([associateLabel, NSView(), buttons])`.
   - The spacer `NSView()` has no intrinsic width.
   - The label (a wrapping label, `maximumNumberOfLines = 3`) and the spacer had the same low
     hugging priority.
   - So the solver split the free width between them arbitrarily, and its answer depended on the
     previous solution (the history from earlier tests).
2. **Feedback from width to width.** `OptionsPageBase.viewDidLayout` (from `mac/optgaps`) sets
   every wrapping label's `preferredMaxLayoutWidth` to its current frame width and marks the page
   for layout again.
   - For a label whose width the page decides, that settles in one pass.
   - For a label whose width comes from its own intrinsic size, the new preferred width changes the
     intrinsic size, which changes the frame, and so on. The loop has no bound, so AppKit ends it
     with the exception.

The same loop happens in the real app whenever the solver lands on a narrow width. The full test
run's history merely made that deterministic. A user would see the window hang for a moment, and
AppKit then logs the fault and skips constraint passes.

## 2. Fix (`Mac/App/Dialogs/OptionsSystemPage.swift`, `OptionsWindow.swift`)

- **The header row (the root cause), 01b §4.21:**
  - IDT_SYSTEM_ASSOCIATE is a single-line static on Windows, so here it is a one-line label
    (`maximumNumberOfLines = 1`, truncating tail, tooltip with the full text). That takes it out of
    the wrapping-label set.
  - The longest translation is `pa-in`, about 45 characters, and it fits easily in the roughly
    450 pt left beside the buttons.
  - The row now uses NSStackView gravity areas instead of a spacer view: the label goes in
    `.leading` and the + / − / * group in `.trailing`.
  - The button group hugs at `.defaultHigh`. A stack view hugs at 250 by default, and the first
    attempt let the group stretch to 462 pt, which was ambiguous again. The regression test caught
    this through `hasAmbiguousLayout`.
- **A bound on the feedback (defence in depth, 01b §4.22):**
  - `OptionsPageBase.viewDidLayout` now allows at most `maxLabelPassesPerSize = 3` re-tell passes
    for each page size.
  - A label that the container sizes needs one pass. A second pass covers a neighbour moved by the
    new height.
  - Anything beyond that is the width feeding back into itself. The page stops there instead of
    letting AppKit throw.
  - The counter resets when the page size changes, so resizing the window still re-wraps the notes.
  - `labelWidthUpdates` counts passes for tests.

## 3. Tests (`Mac/Tests/AppTests/OptGapsTests.swift`, app-hosted)

- **`testScreenshotSystemPage`:** restored as `mac/release` wrote it. It now shoots English, German,
  Russian and Arabic (RTL), giving `optgaps-01-options-system{,-de,-ru,-ar}.png`.
  - It runs in the same position in the full `-H` run that used to throw.
  - The in-process capture still leaves out the tab strip, the header and the note (the
    `cacheDisplay` limitation already recorded in `optgaps.md`). The header geometry is therefore
    asserted, not judged from the picture.
- **`testSystemPageHeaderLayoutSettles` (the regression test):**
  - **Setup:** for each of `-`, `uk`, `de`, `ru`, `ar`, `he` and `ja`, it opens Options on the
    System page and seeds the label's `preferredMaxLayoutWidth` with 4, 63.5, 94.5, 200 and 0 pt.
    These are the narrow states from the failing run; seeding them reproduces the history
    deterministically.
  - **Assertions after layout and display:**
    - at most 2 width re-tells;
    - no ambiguous layout in the row or its views;
    - the label at its full one-line width;
    - label and buttons inside the row and not overlapping (alignment rects);
    - the button group not stretched.
  - **Before the fix it failed** in English, Ukrainian and German: 40 passes per layout call
    (330 with the 4 pt seed), and in German "7-Zip verknüpfen mit:" wrapped at 113 pt where it
    needs 131 pt.
  - **After the fix it passes in every language.**

## 4. Verification

| run | result |
|---|---|
| `Mac/scripts/test.sh` (unit) | 387 passed, 0 failed |
| `Mac/scripts/test.sh -H` (app-hosted) | 100 passed, 0 failed; no `NSGenericException` in the log (it had 1 before the fix, with a runner restart) |
| `Mac/scripts/verify.sh -S` (all targets, sharded; how `uiverify.md` §1 runs the UI suite) | 538 passed, 1 failed (see §4.1) |
| `Mac/scripts/test.sh -t 7-ZipUITestsProbe2` (re-run of that shard alone) | 6 passed, 0 failed |

Running app, per language: the app-hosted tests are the app itself (`7-Zip-Host`), and they open the
real Options window on the System page in English, Ukrainian, German, Russian, Japanese, Arabic and
Hebrew, with real display passes. No Automation or Screen Recording permission is needed, and this
machine has neither (CLAUDE.md).

### 4.1 Full verification

`verify.sh -S` ran from a clean Debug build in 724 s:

| target | passed | failed |
|---|---|---|
| `SevenZipKitTests` | 387 | 0 |
| `SevenZipAppTests` | 100 | 0 |
| `7-ZipUITestsProbe1` | 6 | 0 |
| `7-ZipUITestsProbe2` | 5 | 1 |
| `7-ZipUITests` (input shard) | 40 | 0 |

**The one failure:** `LaunchStateTests.testLaunchesAndListsHomeDirectory` in Probe2.

- **What happened:** XCUITest reported "Failed to activate application
  'com.yrambler2001.7zip-p2' (current state: Running Background)" after 78 s. That happened at
  launch, while the four read-only shards ran concurrently, before the test touched any UI.
- **Why it is not this change:** the case does not open Options, and nothing in this branch
  touches launch or activation.
- **Re-run:** the shard alone (`test.sh -t 7-ZipUITestsProbe2`) passed 6 / 6 in 43 s.

So every case passed in either the sharded run or the re-run. `verify-latest.md` is not committed
because it records the sharded run's rc=65.

## 5. Files touched

- `Mac/App/Dialogs/OptionsSystemPage.swift`: the header row.
- `Mac/App/Dialogs/OptionsWindow.swift`: the bounded label-width feedback and the test counter.
- `Mac/Tests/AppTests/OptGapsTests.swift`: the restored screenshot case and the regression case.
- `Mac/build/screenshots/optgaps-01-options-system{,-de,-ru,-ar}.png`
- `ai/reports/syslayout.md`

No upstream file was touched, and nothing outside the `options` scope beyond its own test file.
`PROGRESS.md` is unchanged: this restores behaviour that was already ticked.

## 6. Follow-ups

- **Other pages:** one other row puts a wrapping label beside a control: Menu ▸ IDT_SYSTEM_ZONE
  3440 next to its combo (`OptionsMenuPage.swift:118`).
  - That row has no spacer and is not stretched, so the label's frame is its intrinsic width and
    the feedback reaches a fixed point after one pass. It cannot oscillate.
  - Any such row added later is bounded by `maxLabelPassesPerSize` and cannot throw.
- **The `release.md` §5 note** ("Worth a look by `options`") is answered by this report.
