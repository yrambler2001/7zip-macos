# `recheck2`: Windows message boxes, the Up button, the Edit menu, hover and slow-click rename

Branch `mac/recheck2`, off `macos` at `ec7d4dc`, 2026-10-04. Scope: the items 1, 2, 4, 5 and 6 of
`recheck.md` §8 (item 3, Ctrl+Space, waits for the user's choice and is not touched). Files of several
scopes, listed in §8.

## 1. Method

**Reference.** `ssh windows-host`: Windows 11, 1920×1080 at 96 dpi, 7-Zip 26.03. `HKCU\Software\7-Zip`
exported first (a copy in the session scratchpad, not committed), deleted before every step, re-imported
at the end (§9). One Windows pixel = one macOS point.

**Windows harness** (`recheck2-data/harness/`: recheck's `lib.ps1`, `wrun.sh`, `go.cmd` plus two steps),
run in the interactive session by the scheduled task `sz_cmp`:

| step | what it measures | output (`recheck2-data/win/`) |
|---|---|---|
| `mb` | `MessageBoxW` through WinForms with visual styles on (the comctl32 v6 context 7zFM has; without it Windows draws the Windows 7 icons and classic buttons), owned by a form at (200,150) 1000×700, for every flag set 7zFM uses and for short, long, unbreakable, multi-line and wide texts, a long caption, no owner: every child rect, font and text extent, `DM_GETDEFID`, the focused control, the close box's state (`SC_CLOSE` in the system menu), a `PrintWindow` capture, then Esc and `WM_CLOSE` and what `MessageBoxW` returned. Then 7zFM's own delete confirmation inside an archive | `mb-*.txt/png`, `fm-delete.txt/png`, `mb-log.txt` |
| `hc` | Single-click hover and the slow second click with **real input** (`SendInput`, absolute coordinates), sampling the list's own state (`LVM_GETHOTITEM`, selection, focus, `LVM_GETEDITCONTROL`, the cursor shape) at fixed times and capturing the row | `log.txt`, `sc1-*.png`, `sc0-*.png`, `slow-*.png` |

recheck's `rc4` had moved the pointer with `SetCursorPos` and zero-delta `mouse_event`s, which never
made the list hot; `SendInput` with `MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_MOVE` does.

**Mac side.** `Mac/Tests/AppTests/Recheck2Tests.swift` (15 cases, app-hosted): the box geometry
against the measured cases, its keys, close box, owner, no-owner path, closed-from-outside path and
asynchronous path, 1x captures, the Edit menu, the slow click (and File > Delete during its edit), the
hover and the Up icon.

## 2. Message boxes (recheck.md §8 item 1)

### 2.1 What Windows does (measured)

| item | Windows 26.03 / Windows 11 | Mac before | Mac after |
|---|---|---|---|
| window | a separate `#32770` window with the caption 7zFM passes | NSAlert, mostly a **sheet**, bold first line, app icon | `WinMessageBoxWindow`, a separate titled window (native title bar: the user's exception) |
| placement | **centred on the screen** of the owner, title bar included: 7zFM at (78,78) 1440×753, the delete box centred at (963,540) on 1920×1080; the same place with no owner | centred / sheet | centred on the owner's screen (`screen.frame`) |
| areas | white message area, a **(243,243,243)** band 42 px high (not 240) | — | the same; dark appearance: AppKit's background colours |
| icon | 32×32 at (21,23): Windows 11 flat icons — orange-red disc with a white X (MB_ICONSTOP), blue disc with "?" / "i", yellow triangle with "!" | app icon | drawn look-alikes (the bitmaps are Windows artwork), colours from the captures |
| text | Segoe UI 9 pt, black; at x 62 (11 without an icon), y 23, or centred on a 34 px icon block when shorter (y 33 for one line, 26 for two); lines 13 px apart, static height `13n + 2`; wrapped at ≈ 324 px, a word longer than that broken between characters (`SS_EDITCONTROL`); `"\n"` ends a line | AppKit text | Helvetica Neue 11 (the dialogs' Segoe stand-in) on the Windows baselines; widths scaled by 1.035 (Segoe is 3.5 % wider on 7zFM's messages) so the box has the Windows size and breaks where Windows breaks |
| buttons | 75×23, right-aligned 15 px from the edge, 83 px apart, 9 px under the band's top (10 when the icon is taller than the text); Windows order Yes / No / Cancel, OK / Cancel | AppKit order and size | the same rects, native push buttons (the user's exception) |
| width | max(62 + text + 30, 27 + buttons + 15, caption + 54): one OK = 117, three buttons = 284 | — | the same formula |
| default button | the first (`DM_GETDEFID` 6 / 1) | first | first (Return) |
| Esc | MB_YESNOCANCEL / MB_OKCANCEL → IDCANCEL; **MB_OK → IDOK** (the lone OK is id 2 inside, answers 1); **MB_YESNO → nothing** | Cancel or nothing | the same |
| close box | the same answer as Esc; **disabled for MB_YESNO** (`SC_CLOSE` absent) | sheet: none | the same; Cmd+W too |
| access keys | "&Yes" / "&No": Y / N | — | Y / N (from lang 406 / 407) |
| Ctrl+C | copies caption, text and buttons between dashed lines | — | Cmd+C, the same text |

Paired 1x captures of the client area: `screenshots/wincompare-recheck2-msgbox-{delete,error,askcancel,info}-{win,mac}.png`.
The geometry test asserts the measured heights, text origins, icon rect, band and button rects
exactly and the widths within 3 % (the font difference); `delete` comes out 316 wide against 318.

### 2.2 One box for the whole app

`Mac/App/Dialogs/WinMessageBox.swift`: `WinMessageBox.run(text, caption:, buttons:, icon:, owner:)`
is `MessageBoxW` (returns IDOK / IDCANCEL / IDYES / IDNO); `WinMessageBox.show(...)` puts the same box up
from the main run loop after the caller returned (what used to be a non-blocking sheet). It is modal to
the app (`NSApp.runModal(for:)`) and is always owned by a visible window when the app has one
(`DialogKit.owner`: the window asked for, else the key / main / a 7-Zip window). With no window at all
it is centred on the main screen and is still an ordinary titled window that its buttons, Esc, the close
box, Cmd+W, `close()` from outside and the test reset all end — never the ownerless NSAlert that wedged
the app (`modalfix.md`), and the close box never leaves a session running (`infohang.md`).
`ErrorAlert.present` keeps modalfix's rule: a report with **no** window goes to the log, and `show`
drops a report whose window closed before it came up (a panel of a closed window finishing a reload).

All the `NSAlert` sites (32 in 21 files, recheck.md §8) are gone (`grep NSAlert Mac/App` finds only comments). Each now
passes what 7zFM passes (source line in the code):

| site | caption | buttons, icon |
|---|---|---|
| delete confirmation (`PanelOperations.confirmDelete`) | 6100 / 6101 / 6102 | YESNOCANCEL, question (folder text now 6104's ".. and all its contents?") |
| 3009 write-back (`PanelNestedArchives`, `TempOpen`) | 7-Zip | YESNOCANCEL, question (TempOpen had Yes/No) |
| 3010 cannot update, cannot start editor, open-inside errors, panel errors | 7-Zip | OK, stop |
| copy into an archive by drop / paste (`PanelDragDrop`) | 6010 | YESNOCANCEL, question; text now "Copy to:" / "Move to:", the folder, 6011 + " ?" (PanelDrag.cpp:2611-2625) |
| progress Cancel (`ProgressDialog`) | the operation title | YESNOCANCEL, **no icon** |
| operation error / OK message (`OperationRunner`) | the operation's main title | OK, stop / OK, none |
| split-volume question (`CompressDialog`), 7307, No Update Engines, Benchmark, Link, Split, About, Options errors | 7-Zip | as the .cpp |
| temp-files delete / properties (`ToolsTempFilesDialog`) | 7303.. / 6600 "Properties" | YESNOCANCEL question / OK |
| lang file errors (`OptionsLanguagePage`) | "Error in Lang file" | OK, stop |
| command line / URL messages (`CommandExecutor`) | 7-Zip | OK, stop / OK |

Two behaviours changed to match 7zFM, found while migrating:

* **IDS_VIRUS 3012** (`SuspiciousName.confirm`, extract scope): the Mac asked "… Do you want to open
  it?" Yes/No. 7zFM 26.03 does not ask: `IsVirus_Message` shows the 3012 text, the cleaned-up name and
  the name with `MessageBox_Error` and does not open the file (PanelItemOpen.cpp:944-967). The Mac now
  does the same.
* `HashResultsDialog`'s item info is a `CEditDialog` on Windows; it is now a plain OK box captioned with
  the row's name (closer than an NSAlert, still not the edit dialog — §10).

### 2.3 Tests that addressed sheets

`AppHostTestCase` now records every box (`recordedBoxes`, `boxText(ownedBy:)`) and answers a report
nobody waits for (`show`) at once with its Esc answer, so a stray report cannot wedge the suite; a
question (`run`) is left to the test's answerer and its caller's stack is printed. `NavGapsTests` and
`PanelWindowlessErrorTests` read the box owned by the window instead of the sheet on it (the rule they
guard is unchanged: owned by the panel's window, never by nothing); `TestResetSettleTests` keeps its
raw-NSAlert worst case. The XCUITest driver finds the box as before: it is a window whose title is
the caption, subrole `AXDialog`, whose static text value is the message and whose buttons are titled.

## 3. The Up button (recheck.md §8 item 2)

7zFM's Up button is `VIEW_PARENTFOLDER` from comctl32's `IDB_VIEW_SMALL_COLOR` (Panel.cpp:447,
490-491: `TB_ADDBITMAP` with `HINST_COMMCTRL`) — **Windows artwork, not in the 7-Zip sources** (no
.bmp in `CPP/7zip/UI/FileManager/` has it). So it stays a drawn look-alike, redrawn closer to the
16×16 capture (`recheck-data/win/fresh-screen.png` x 14..29, y 108..123): an open yellow folder (the
back with its tab, the front flap slanting up to the right, the darker (214,168,0) lower edge) and a
green arrow with a dark outline, its head on row 4 from x 5 to 13, the tip at x 7.5, the stem leaning
down to the left into the folder. `PanelAddressBar.swift` `PanelUpButton.drawIcon`;
`Recheck2Tests.testUpButtonIconIsTheFolderWithTheGreenArrow`; paired 16×16 captures
`screenshots/wincompare-recheck2-upicon-{win,mac}.png`.

## 4. Edit menu (recheck.md §8 item 4)

`Support/EditMenuCleanup.swift`, adopted by the Edit menu as it is built (one additive line in
`MainMenu.swift`): registers `NSDisabledDictationMenuItem` and `NSDisabledCharacterPaletteMenuItem`
before the menu bar exists, and — AutoFill has no such switch — removes every item AppKit adds to the
Edit menu (by action `startDictation:` / `orderFrontCharacterPalette:`, an AutoFill title or action,
and a trailing separator) as it is added and before the menu opens. The test adds the three items the
way AppKit does and checks they are taken out; the Edit menu AppKit left was 7zFM's 8 items + Copy /
Cut / Paste.

## 5. Single-click hover and the slow second click (recheck.md §8 items 5, 6)

### 5.1 Measured (`recheck2-data/win/log.txt`; double-click time 550 ms, hover time 400 ms)

| case | Windows 26.03 |
|---|---|
| SingleClick on, pointer rests on an item's icon or label | hot at once (`LVM_GETHOTITEM`), **hand cursor**, nothing drawn (no hot colour, no underline — `LVS_EX_UNDERLINEHOT` is commented out of App.cpp:88-92); after **400 ms** the item becomes the selected and focused one (selection replaced) |
| moving on to the next item | hot at once, selected after 400 ms |
| over the Size cell (FullRow off), the background, outside | not hot, arrow, nothing selected |
| SingleClick on, one click on a folder | opens it |
| SingleClick off, hover | hot index changes, nothing visible, arrow cursor |
| click on the label of the item that is already the only selected and focused one | **the label edit starts after the double-click time** (none at +550 ms, the edit at +650 ms), its text selected |
| first click on an unselected item, second 700 ms later | the first selects; the second starts the edit ~550 ms later |
| double-click on the selected item | opens it, no edit |
| second click on the icon, on the Size cell | no edit (the Size cell click deselects) |
| click on one of two selected items | the selection becomes that item, no edit |
| the window inactive, click on the selected item | the edit still starts |

recheck's "no edit (measured once)" was the synthetic-input artefact.

### 5.2 Mac (`Panel/PanelTableView.swift`, Details view)

* **Slow click** (SingleClick off): a mouse-down without modifiers on the label (`labelHitRect`, the
  Name cell's text fill) of the row that was the only selected and focused one, released in place,
  schedules `renameFocusedItem()` (the F2 path) after `NSEvent.doubleClickInterval`; a second click, a
  key, a drag or another click cancels it. Not in AlternativeSelection.
* **Hover** (SingleClick on): a tracking area; over an item's icon or label (`isOnItem`, the whole row
  with FullRow) the cursor is the pointing hand and a 0.4 s timer (SPI_GETMOUSEHOVERTIME; macOS has no
  such setting) selects and focuses that row (`setFocus`) if the pointer is still on it and no button
  is down. Elsewhere the arrow, no timer. The single-click activation was already there.

* An operation that changes the folder while a label is edited (File > Delete right after a slow
  click, which the input shard's `PanelTests.testCreateFolderAndDelete` does by clicking its already
  selected new folder) cancels the edit first (`cancelRenameEditing`, LVN_ENDLABELEDIT with no
  text), and the timer renames only the item the click was on. Before that fix the edit outlived the
  delete and the folder stayed.

Tests: `testSlowSecondClickRenamesAfterTheDoubleClickTime` (the rename starts only after the
interval; a double-click, the first click on an unselected item, the icon and a multi-selection do not
start one), `testDeleteWhileRenamingDeletesTheItem`, `testSingleClickHoverSelectsAfterTheHoverTime`.

## 6. Not done

* Ctrl+Space (recheck.md §8 item 3): left for the user's choice, as asked.
* The icon views (Large / Small Icons, List) have neither the hover selection nor the slow-click rename
  (Windows has both in every view mode); rename there is the Rename dialog.
* The Hash item info should be IDD_EDIT-like `CEditDialog`, not a message box.
* The box wraps by the scaled Helvetica Neue widths: a line can hold a word more or less than on
  Windows (e.g. "word word …" fits 11 words a line against Windows' 10).
* Full Keyboard Access decides whether a push button takes the focus, so Tab between the box's
  buttons works only with it on (recheck.md §8 item 8).

## 7. Verification

All runs with `DEVELOPER_DIR=/Applications/Xcode.app`.

| run | result |
|---|---|
| `Mac/scripts/build.sh` | exit 0, no warnings in `Mac/` |
| `Mac/scripts/test.sh` (final) | **388 passed, 0 failed** |
| `Mac/scripts/test.sh -H` (final) | **222 passed, 0 failed** (Recheck2Tests 15) |
| `Mac/scripts/test.sh -u` (final, at `f034cfa`) | **64 passed, 0 failed**: input shard 52, probe1 6, probe2 6 |

Before the test-support change of §2.3 a full `-H` run hung twice: a report that used to be a sheet
nobody looked at is now modal, and a panel of a closed window kept reporting `errno=2` from its reload.
The second was a product fix (§2.2: no window, no box), the first a harness change.

### 7.1 UI suite

The first `-u` run lost the input shard to the known "Timed out while enabling automation mode"
(`uiverify.md`; the retry in `test.sh` timed out too) while both probes passed. The shard alone then
ran 51 / 1: `PanelTests.testCreateFolderAndDelete` clicked its already selected folder, which now
starts the rename (as on Windows), and File > Delete did not delete it — the defect fixed in §5.2. The
final run above is after that fix.

## 8. Files

| change | files | owner |
|---|---|---|
| the message box | `Dialogs/WinMessageBox.swift` (new), `Dialogs/ErrorAlert.swift` | opsinfra (new shared file) |
| call sites | `Commands/{Compress,Extract,Tools}Commands.swift`, `Dialogs/{About,Benchmark,Compress,HashResults,Link,OptionsLanguagePage,OptionsMenuPage,OptionsSettingsPage,OptionsSystemPage,Progress,Split,ToolsTempFiles}*.swift`, `Integration/CommandExecutor.swift`, `MainWindow/MainWindowController.swift`, `Panel/{PanelDragDrop,PanelNestedArchives,PanelOperations,PanelViewController}.swift`, `Support/{OperationRunner,TempOpen,TempOpenCommands}.swift` | tools, compress, extract, options, opsinfra, finder, panel, orchestrator |
| Up icon, hover, slow click | `Panel/PanelAddressBar.swift`, `Panel/PanelTableView.swift` | panel |
| Edit menu | `Support/EditMenuCleanup.swift` (new), one line in `MainMenu.swift` (additive) | shared |
| tests | `Tests/AppTests/Recheck2Tests.swift` (new), `AppHostTestCase.swift`, `NavGapsTests.swift`, `PanelWindowlessErrorTests.swift`, `TestResetSettleTests.swift` | harness |
| measurements | `docs/reports/recheck2-data/` | — |

Nothing outside `Mac/` was touched.

## 9. The Windows machine

`HKCU\Software\7-Zip` exported to `%TEMP%\szcmp\reg-backup.reg` before the first step (copy kept in
the session scratchpad), deleted before each step, and at the end deleted and re-imported (30 lines,
as before). Every 7zFM window and every message box was closed by the steps; no 7z process is left. The
scheduled task `sz_cmp` and `%TEMP%\szcmp` (the fixtures, the scripts' output) were deleted. Nothing was
deleted from the user's files; the only file operations were in `%TEMP%\szcmp\cmp`.

## 10. Left for the next agent

1. Ctrl+Space — the user's choice of key (recheck.md §8 item 3).
2. Hover selection and slow-click rename in the three icon views (§6).
3. `CEditDialog` for the Hash results' item info.
4. Segoe UI's own advance widths, if the remaining one-word wrap differences matter (§6).
