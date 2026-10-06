# `okcancel`: "SOMETIMES the OK and Cancel buttons don't work, while Help and the close button work"

> **Publication note:** this report was written when it lived in `Mac/docs/reports/`. Its screenshots were removed from the repository before publication; a few showcase images live on in `docs/images/`, and the tests now write their screenshots to the git-ignored `Mac/build/screenshots/`. Paths below that point at removed images are kept as a record of what was measured.

Branch `mac/okcancel`, off `macos` at `396900f`, 2026-10-06.

## 1. Root cause in one paragraph

`WinComboHover` (`Support/WinCombo.swift`, feel3) owns the tracking area of every Windows-style
combo box and drop-down: `WinComboBox` (Add to Archive's name and volume fields, Copy / Move,
Extract, Split, Link, Create Folder / File, Select, Combine) and `WinPopUpButtonCell` (every
CBS_DROPDOWNLIST). It was a plain `NSObject` with `@objc func mouseEntered(with:)`. In Swift that
selector is `mouseEnteredWith:`, but AppKit sends a tracking area's owner `mouseEntered:`. So the
first time the pointer crossed a combo of the key dialog, AppKit raised
`-[SevenZipApp.WinComboHover mouseEntered:]: unrecognized selector`.

The exception was raised inside `NSApp.runModal(for:)` and unwound the modal session. AppKit caught
it further out: from a context-menu verb, `NSMenuTrackingSession` caught it and logged "Exception
thrown while attempting to perform a menu item's action". From anywhere else,
`-[NSApplication run]` caught it. Either way the dialog stayed on screen **with no modal session**:

* OK and Cancel call `NSApp.stopModal()`, which stops nothing when there is no session, so they
  looked dead.
* Help only opens a page, so it worked.
* The close box worked because `DialogWindow.performClose` (infohang) also orders the window out.

"Sometimes" is the pointer's path. Whether the pointer crosses a combo before it reaches OK
depends on where the dialog comes up relative to the pointer. From the context menu the dialog
appears under the pointer, so it happens often. The bug is not specific to the context menu.

## 2. Evidence

**Reproduced with real input, Release build.** `OkCancelUITests.testContextMenuCompressDialogsCancelWithTheMouse`
on the old code: right-click → 7-Zip ▸ Add to archive… / Compress and email… → Cancel clicked with
the mouse. The dialog stayed up in **20 of 40** attempts (`round N …: Cancel did not close the
dialog`). The screenshot showed the dialog intact, with nothing covering it.

**Diagnosis.** Temporary logging in `CompressDialogController`, since removed:

```
OKCDBG runModal start   (stack: ... NSMenuTrackingSession _performPostTrackingDismissalActions ...)
OKCDBG 1s later modal=nil
OKCDBG cancelPressed modal=nil self="Add to Archive"  (stack: -[NSApplication run] -> sendEvent ...)
```

`runModal` never returned and was no longer on the stack. `NSApp.modalWindow` was nil while the
dialog was visible. The unified log had the reason:

```
[com.apple.AppKit:Menu] Exception thrown while attempting to perform a menu item's action. It has been
caught ... -[SevenZipApp.WinComboHover mouseEntered:]: unrecognized selector sent to instance
  -[NSTrackingArea _dispatchMouseEntered:] <- -[NSApplication _doModalLoop:peek:] <- runModalForWindow:
  <- CompressDialogController.run <- ... <- NSMenuTrackingSession ... <- NSContextMenuImpl
```

**The other hypotheses in the brief, checked:**

| | hypothesis | finding |
|---|---|---|
| a | a view overlaps OK/Cancel | **no.** `OkCancelTests.testEveryDialogControlReceivesTheClickAimedAtIt` hit-tests every visible, enabled control of 22 dialogs in English, German, Russian, French, Japanese and Arabic (132 dialog runs). It checks the centre and the ¼ / ¾ points of each control, and every click reaches its own control. |
| b | the menu's tracking loop blocks the buttons | Partly right. The dialog does run inside the context menu's tracking session, and that is where the exception was caught. But the buttons were never blocked: their actions ran (`cancelPressed` was logged). |
| c | dead target or wrong responder | no. The action reached the live controller. |
| d | disabled buttons or key-equivalent clash | no. The button was enabled, and the click was dispatched to it. |
| e | a stale session from the previous dialog | no. Each dialog's own session was lost. |

## 3. Fix

1. **The root cause** (`Support/WinCombo.swift`). `WinComboHover` is now an `NSResponder` that
   overrides `mouseEntered(with:)` / `mouseExited(with:)`, so the selectors are correct by
   construction. As a side effect the hover look of the combos, measured in feel3 §2, now works;
   it never did before.
2. **Every dialog survives such a bug** (`Dialogs/ProgressDialogSupport.swift`,
   `Core/SZObjCException.{h,mm}`). `DialogKit.runModal(for:)` replaces `NSApp.runModal(for:)` at
   all 20 dialog sites, including `WinMessageBox`, Browse and the progress window. It runs the
   session inside `SZCatchException`, a 10-line `@try/@catch` in SevenZipKit, because Swift cannot
   catch an NSException. If an exception escapes an event handler, it is logged and recorded in
   `DialogKit.caughtModalExceptions`, and the session **resumes** for the same window. This is what
   `-[NSApplication run]` does for the main loop. If the exception left the window off screen, the
   dialog ends as IDCANCEL. The safety net covers every entry point: context menu, File menu,
   toolbar, Finder or command line.
3. **A crash the fix exposed** (`WinHeaderCell.swift`, `PanelAddressBar.swift`,
   `RcLayout.swift`). With the hover working, the UI runs crashed twice, in
   `PanelMetrics.listFont` and `-[NSCell font]` (objc_retain on a freed object).
   `-[NSCell copyWithZone:]` copies the instance bitwise and does not retain Swift stored
   references. AppKit copies cells for header drawing, accessibility snapshots and pop-up menus,
   so every freed copy over-released something:
   * `WinHeaderCell.titleFont`, which is the shared list font;
   * `AddressComboCell.icon`;
   * `WinPopUpButtonCell.hover`.

   Each of these cells now overrides `copy(with:)` and calls `CellCopy.adopt`, which gives the copy
   the retain it is owed. This was a latent bug since datecols and feel3. An app-hosted probe
   crashed the test host on the old code.

Windows parity: none of this changes behaviour. IDOK / IDCANCEL / IDHELP keep their 7zFM meaning
(CompressDialog.cpp OnOK / OnCancel, 01 §2.8–§2.9 for the context verbs).

## 4. Tests (all fail on the old code)

App-hosted, `Mac/Tests/AppTests/OkCancelTests.swift`:

| test | what it checks | on the old code |
|---|---|---|
| `testEveryTrackingAreaOwnerAnswersItsSelectors` | Every tracking area in 22 dialogs, the six Options pages and the main window has an owner that answers the selectors its options make AppKit send (177 areas in the dialogs). | fails: `WinComboHover does not answer mouseEntered:` |
| `testComboHoverFollowsTheMouse` | The combo's hover state follows the mouse. | fails |
| `testAnExceptionInsideAModalDialogKeepsItsSession` | An NSException raised inside Create Folder's modal session leaves it the modal window, and its own Cancel then ends `run` with nil. | fails: the exception escapes `ComboDialog.run` |
| `testCellCopiesKeepTheirObjectsAlive` | The icon, hover owner and title font survive copies of the three cells. | crashes the host |
| `testEveryDialogControlReceivesTheClickAimedAtIt` | Hypothesis (a): six languages, 132 dialog runs. | passes (overlap was not the cause) |

XCUITest, input shard, `Mac/Tests/UITests/OkCancelUITests.swift`, Release:

| test | what it does | on the old code |
|---|---|---|
| `testContextMenuCompressDialogsCancelWithTheMouse` | Right-click → 7-Zip ▸ Add to archive… and ▸ Compress and email…, alternating, 20 × 2. The pointer crosses the combos, then Cancel is clicked. | 20 of 40 stuck |
| `testContextMenuAddToArchiveOKWithTheMouse` | Context menu, then OK, 10×. The dialog goes and `alpha.7z` is written. | — |
| `testOtherEntryPointsCancelWithTheMouse` | Toolbar Add, toolbar Extract, and 7-Zip ▸ Extract files…, each 5×. | — |

Screenshot: `screenshots/okcancel-compress-from-context-menu.png`.

## 5. Results (`DEVELOPER_DIR=/Applications/Xcode.app`)

| run | result |
|---|---|
| `Mac/scripts/build.sh` | exit 0, no warnings in `Mac/` |
| `Mac/scripts/test.sh` | 388 passed |
| `Mac/scripts/test.sh -H` | 255 passed, 0 failed (incl. `OkCancelTests` 5) |
| `Mac/scripts/test.sh -u` (Debug) | 67 passed: input 55 (incl. `OkCancelUITests` 3), probe 6 + 6; 1532 s |
| `OkCancelUITests`, Release (`-t 7-ZipUITests -c Release`) | 3 passed; no crash report written after the fix |

The app-hosted target has no Release configuration (`@testable import`), so the Release coverage is
the XCUITest against the Release app.

## 6. Notes and follow-ups

* Leftover "7-Zip quit unexpectedly" boxes, from the crashes in §3.3, sat over the main window and
  took the UI tests' clicks. `OkCancelUITests` answers any such box with Ignore before it starts.
* A second click on a selected name starts the slow-click rename (01 §3.9). A test that re-selects
  the same row before a right-click therefore opens the rename field instead of the menu, so the
  tests select once.
* Files touched outside this scope's own new files:
  * `Support/WinCombo.swift`, `Support/RcLayout.swift`, `Support/WinHeaderCell.swift` (feel3 / dlgfeel / datecols);
  * `Panel/PanelAddressBar.swift` (panel);
  * `Dialogs/ProgressDialogSupport.swift` and `Support/OperationRunner.swift` (opsinfra);
  * the one-line `runModal` change in 17 dialog files (compress, extract, tools, panel, opsinfra);
  * `Core/include/SevenZipKit.h` (additive import) and the new `Core/SZObjCException.{h,mm}`.

  Nothing outside `Mac/`.
