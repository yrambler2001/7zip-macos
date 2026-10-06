# `recheck`: a systematic pixel-and-behaviour recheck against fresh-default 7zFM 26.03

> **Publication note:** the raw capture data under `docs/reports/*-data/` and all but a few showcase images under `docs/reports/screenshots/` were removed from the repository before publication (raw capture data removed before publication). Paths below that point into them are kept as a record of what was measured.

Branch `mac/recheck`, off `macos` at `fe6ee5f`, 2026-10-04. Scope: everything a user sees or does in
the main window, the dialogs and the operations, measured on the reference PC and on the Mac and
fixed where they differ (files of several scopes, listed in §9).

## 1. Method

**Reference.** `ssh windows-host`: Windows 11, 1920×1080 at 96 dpi, **7-Zip 26.03**, `HKCU\Software\7-Zip`
exported first, deleted before every step (fresh defaults), re-imported at the end (§10). One Windows
pixel = one macOS point.

**Windows harness** (`recheck-data/harness/`, the dlgfeel harness plus `GetGUIThreadInfo` for the
keyboard focus, `GetCursorInfo`, wheel and key injection). Steps, run with `wrun.sh <step>`:

| step | what it measures | output (`recheck-data/win/`) |
|---|---|---|
| `rc1` | fresh main window: every child rect, system colours, screen capture; Tab / Shift+Tab focus chain with one and two panels; Home / Insert / Space / Num * / End / Shift+Up / type-to-select / Ctrl+Space / Ctrl+Up / Ctrl+A; one wheel notch in a 121-item folder; the tooltip of a truncated name; the menus with accelerators | `fresh*`, `two*`, `many.txt`, `menu-main.txt`, `syscolors.txt`, `rc1-log.txt` |
| `rc2` | progress window over time (title, elapsed, remaining, speed, processed every 50 ms), Pause, Background, Cancel (ask box); the list after Create Folder, Copy, Shift+Delete; slow-click and F2 rename; right-click on toolbar, status bar, address field | `rc2-log.txt`, `progress-*.png`, `ask-cancel.*`, `ctx-*.txt` |
| `rc3` | every dialog: initial focus and its selected text, default button (DM_GETDEFID), the Tab order until it cycles, whether Esc closes it | `keys.txt` |
| `rc4` | Single-click hover and ShowDots | `log.txt`, `dots.txt` |

**Mac side.** `Mac/Tests/AppTests/RecheckProbeTests.swift` and `RecheckDialogKeysProbe.swift` render
the real main window with its frame at 1x and replay the same key sequences, wheel notch and dialog
walks (they run only when `Mac/build/recheck/PROBE` exists; the fixture folder is
`Mac/build/recheck/cmp`, made by `wincompare-data/harness/make-cmp.sh`). Pixels were compared with a
raw-byte CGImage tool (colour runs along a row / column, ink bounding boxes), never by eye.
`RecheckTests.swift` (12 cases) keeps every fix.

## 2. Main window: chrome, toolbar, address bar, header, status bar

| item | Windows 26.03 (measured) | Mac before | Mac after | status |
|---|---|---|---|---|
| window background (toolbar strip, splitter, status bar) | COLOR_BTNFACE **(240,240,240)** | AppKit windowBackgroundColor = **white** on macOS 26 | (240,240,240), dark mode unchanged | **fixed** |
| dialog background | (240,240,240) | white | (240,240,240) (DialogKit windows, Options) | **fixed** |
| default window frame (no saved position) | CW_USEDEFAULT: **1440×753** at a top-left cascade slot (78,78) of a 1920×1032 work area | 960×640 content, centred | ¾ of the visible frame wide, 753/1032 of it high, at the first cascade slot (26 pt in from the top-left) | **fixed** |
| toolbar strip | 52 px: (160) line, white line, 240 | same structure on white | same, on 240 | **fixed** |
| toolbar text buttons | 42×46, label Segoe UI 9 **black**, "Add" ink rows 31–39 | 45×46, SF 11, labelColor (85 %), ink 30–37 | **42×46**, Helvetica Neue 11, black, ink 32–39 | **fixed** |
| address band | 24 px, **white** ReBar band, no active-panel marking | accent-tinted band with a 2 px blue bar under the active panel | white, no marking; the band border (180)/(244,247,252) at x 31/32 and (220) bottom line under the Up button | **fixed** |
| Up button | flat 23×22 at 2,1, folder + green arrow bitmap, grey when disabled at the root | AppKit textured rounded button with an SF "arrow.up" symbol | flat 23×22 at 2,1, toolbar hover / pressed colours, a drawn folder + green arrow (not the comctl32 bitmap itself), greyed at the root | **fixed** (icon is a look-alike) |
| address combo | ComboBoxEx at x 33, 24 px, 1 px (141) border, white, 16 px icon 3 px in, text 24 px in, thin chevron | separate blue folder image, AppKit combo with a rounded chevron button and a focus-tinted bezel | one combo at x 33: (141) border, the icon inside at +3,+4, text at +24, a 1 px chevron; NSComboBox behaviour unchanged | **fixed** |
| list frame | themed WS_EX_CLIENTEDGE: 1 px (130,135,144) + 1 px white, header at +2,+2 | none (an NSBox separator line above and below) | the same 2 px edge | **fixed** |
| header dividers | 1 px **(229)** at an item's right edge − 1, **full 24 px** | AppKit's short divider (rows 4–19) | full height (229) | **fixed** |
| header text | black, "Name" ink rows 7–15 | grey, rows 3–10 | black, rows 8–15 | **fixed** |
| list text colour | COLOR_WINDOWTEXT (0,0,0); deleted items RGB(255,0,0) | labelColor (≈38,38,38); systemRed | black; (255,0,0) | **fixed** |
| two-panel splitter | 4 px of BTNFACE, nothing drawn | 4 pt with a separator line in the middle | 4 pt of (240) | **fixed** |
| status bar | 23 px: (215) top line, BTNFACE, Segoe UI 9 black, text ink 2 px into a part, (215) dividers at x 219/319/419 on rows 2–21 | 2 px grey line, white, SF 11, text 8 px in, NSBox dividers rows 4–19 | 1 px (215) line, (240), Helvetica Neue 11 black, text 2 px in on the Windows baseline, dividers at x 219… rows 2–21 | **fixed** |
| menus: items, order, accelerators | `menu-main.txt` | identical items; Ctrl→Cmd; Diff hidden without a tool (validation) | — | same / deliberate (as wincompare §3) |
| Edit menu system items (AutoFill, Start Dictation, Emoji & Symbols) | none | added by AppKit | — | **left** (see §8) |
| tooltip of a truncated name | **none** (no LVS_EX_LABELTIP / INFOTIP; 3 s hover) | none | — | same |
| right-click on toolbar / status bar | no menu | no menu | — | same |
| right-click in the address field | the Edit control's menu | the text field's menu | — | deliberate (native text menu) |

Paired captures: `screenshots/wincompare-recheck-main-win.png` / `-mac.png` (the top-left 420×110 and
the status bar, §11).

## 3. Keyboard and mouse in the list

| key / action | Windows (rc1-log.txt) | Mac before | Mac after | status |
|---|---|---|---|---|
| Home | focus **and select** item 0 | NSTableView scrolled only, nothing selected | focus + select | **fixed** |
| End | focus + select the last item | scrolled only | focus + select | **fixed** |
| Page Up / Page Down | to the first / last visible row, then a page | scrolled only | as Windows (Details) | **fixed** |
| Shift+Up / Down | from the **focused** item, focus moves to the new item | NSTableView extended from its own end, focus stayed | anchor…target, focus on the target | **fixed** |
| Num * (invert), Select All, masks | the **focus stays** (item 0) | the focus jumped to the last selected row | focus kept | **fixed** |
| Insert | nothing outside AlternativeSelection | nothing | — | same |
| type-to-select ("n", "a", pause, "en") | notes.md, stays, enc.7z | the same | — | same |
| Tab, one panel | stays in the list | stays | — | same |
| Shift+Tab, one panel | **stays in the list** | went to the address field | stays | **fixed** |
| Tab / Shift+Tab, two panels | toggles between the two lists only | the same for Tab | Shift+Tab too | **fixed** |
| wheel, one notch | **3 rows** (SPI_GETWHEELSCROLLLINES = 3; top index 0→3→6) | 1 row (19 pt) | 3 rows (57 pt) for line-based wheel events; trackpads unchanged | **fixed** |
| Ctrl+Space (toggle focused) | toggles | Cmd+Space is Spotlight's | — | **left** (key conflict, §8) |
| Ctrl+Up / Ctrl+Down (move focus only) | moves the focus without selecting | Cmd+Up / Cmd+Down are Up One Level / Open | — | deliberate (Mac menu keys) |
| Ctrl+A | selects all | Cmd+A | — | same (Ctrl→Cmd) |
| slow second click on a selected name | no edit started (measured once) | no edit | — | same (unconfirmed, §8) |
| F2 | edit with the whole name selected ("sub" 0–3) | the same | — | same |

## 4. After an operation

| case | Windows (rc2-log.txt) | Mac before | Mac after | status |
|---|---|---|---|---|
| Create Folder dialog | focus in the edit, "New Folder" selected 0–10 | the same | — | same |
| after Create Folder | the new folder focused and selected, list focused | the same | — | same |
| after Delete / Shift+Delete | the item now at that place is **focused, not selected** ("0 / 15") | focused **and selected** | focused only | **fixed** |
| after Copy (F5) | the source item stays focused | the same | — | same |

## 5. Progress window (IDD_PROGRESS)

| item | Windows | Mac before | Mac after | status |
|---|---|---|---|---|
| title | "N% Checksum calculating...", paused "Paused N% …", background "**N% Background** Checksum calculating..." | background as "N% Checksum calculating... Background" | Windows order | **fixed** |
| main window title during the run | "N% Checksum calculating... 7-Zip" (AddToTitle + MainTitle), restored when the dialog ends | unchanged (the path) | the same prefix + title + "7-Zip"; restored at the end | **fixed** |
| update cadence | elapsed, remaining, speed, files, processed and the title's percent change **once per elapsed second**; total and bar every 200 ms tick | every tick (5×/s) | per second, as UpdateStatInfo | **fixed** |
| sizes | ConvertSizeToString: "67584 KB", "340 MB", "5722 MB" | grouped bytes ("6 000 000 000") | ConvertSizeToString | **fixed** |
| files | "0", " / 1" (ungrouped, with the leading space) | grouped, "/ 1" | as Windows | **fixed** |
| Pause / Continue, Background / Foreground labels | &Pause ↔ &Continue, &Background ↔ &Foreground | the same | — | same |
| Cancel | pauses, asks "Are you sure you want to cancel?" Yes / No / Cancel, captioned with the operation title (no percent) | asked with the window's current title ("Paused 70% …") | the operation title | **fixed** |
| layout | dlgfeel §3 | — | — | same (dlgfeel) |

## 6. Dialogs: focus, default button, Tab order, Esc

Windows numbers in `recheck-data/win/keys.txt`, Mac in `Mac/build/recheck/out/dialog-keys.txt`
(RecheckDialogKeysProbe).

| dialog | Windows | Mac before | Mac after | status |
|---|---|---|---|---|
| all `.rc` dialogs: Tab order | the template's control order over WS_TABSTOP controls; a radio group is one stop | AppKit's geometric key-view loop (e.g. Copy: "..." before the path, which sits 4 px higher) | template order (`RcFormView.applyTemplateTabOrder`), radio runs one stop, lists and the resource-fork box at their place | **fixed** |
| Copy / Move / Combine / Create Folder / File / Select / Comment | path / name edit focused, all text selected; OK default; Esc closes | the same | — | same |
| Split | the **path** combo focused, selected | the volume-size combo | the path | **fixed** |
| Link | "Link from" focused; default **Link** | the same | — | same |
| Password | the edit focused; Tab: Show password, OK, Cancel | the same | — | same |
| Add to Archive / Extract | archive name / path focused and selected; 26 / 13 Tab stops in the order of keys.txt | geometric order | the Windows order (plus "Exclude Mac resource forks" after "Delete files after compression") | **fixed** |
| About | OK focused; **Esc closes** | Esc did nothing (no Cancel button) | Esc closes (DialogWindow.cancelOperation) | **fixed** |
| Overwrite, Confirm delete | Yes focused and default; Esc = Cancel | Yes default; Esc = Cancel | — | same (buttons take focus only with Full Keyboard Access) |
| Folders History, Checksum, Properties | the list focused, OK default | the same | — | same |
| Delete Temporary Files, Benchmark, Options | Close / Restart / "+" button focused | the list / nothing / the list | — | deliberate (a push button takes the focus only with Full Keyboard Access on macOS) |

## 7. Options

The pages' looks were rebuilt by dlgfeel. Here only their visible effects were spot-checked:
ShowDots shows ".." (row 0, list-selected but not counted: "0 / 15"), FullRow / ShowGrid as selcolors
measured. **Single-click hover (LVS_EX_TRACKSELECT) could not be measured**: synthetic cursor moves
did not make the list hot-track (`rc4`, hot item −1 throughout), so the Mac's behaviour (no hover
selection) is unverified.

## 8. Left for the next agent, by priority (with the measurements)

1. **Message boxes are NSAlerts.** Windows' MessageBox: a caption window centred on its owner, white
   upper area with the 32 px icon and the text, a (240) band with right-aligned 7zFM-size buttons;
   the Mac shows macOS alerts (sheets, app icon, bold first line). 32 `NSAlert()` sites in 21 files;
   UI tests address them as sheets, so a `WinMessageBox` replacement must keep them findable.
2. **Up button bitmap** is a drawn look-alike of comctl32 VIEW_PARENTFOLDER (pixel rows in
   `rc1` capture, `fresh-screen.png` 14..29 × 108..123); the real bitmap is Windows' artwork.
3. **Ctrl+Space** (toggle the focused item's selection) has no Mac key: Cmd+Space is Spotlight and
   Ctrl+Space the input-source switch. Choose one (e.g. Option+Space) with the user.
4. **Edit menu system items** (AutoFill, Start Dictation, Emoji & Symbols) are injected by AppKit;
   `NSDisabledDictationMenuItem` / `NSDisabledCharacterPaletteMenuItem` defaults remove two of them,
   AutoFill needs its own switch. Earlier reports called them deliberate.
5. **Single-click hover** (§7): measure with a real pointer (or `SendInput` with absolute
   coordinates) and port TRACKSELECT (hover 400 ms = SPI_GETMOUSEHOVERTIME selects) if it shows.
6. **Slow second click rename** measured "no edit" once; re-measure with `SendInput` before deciding.
7. Toolbar / status / header fonts are Helvetica Neue 11 for Segoe UI 9 (same advances, glyph
   shapes differ) — the remaining visible difference in every paired capture, with the file icons.
8. Initial focus on a push button (About, Benchmark, Delete Temporary Files, Overwrite) is impossible
   without Full Keyboard Access; a custom first-responder button would change the system setting's
   meaning.

## 9. Files

| change | files | owner |
|---|---|---|
| chrome colours and geometry | `Support/WinChrome.swift` (new), `Panel/PanelAddressBar.swift` (new), `Panel/PanelViewController.swift`, `MainWindow/FMToolbar.swift`, `MainWindow/MainWindowController.swift`, `Panel/PanelMetrics.swift`, `Panel/PanelSelectionStyle.swift` | panel (+ shared new file) |
| dialog background, Esc, Tab order | `Dialogs/ProgressDialogSupport.swift`, `Support/RcLayout.swift`, `Dialogs/OptionsWindow.swift`, `Dialogs/ListViewDialog.swift`, `Dialogs/ToolsTempFilesDialog.swift`, `Dialogs/CompressDialog.swift`, `Dialogs/SplitDialog.swift` | opsinfra, dlgfeel's shared layout, options, panel, tools, compress |
| progress window | `Dialogs/ProgressDialog.swift`, `Dialogs/ProgressDialogSupport.swift`, `Support/OperationRunner.swift` | opsinfra |
| list keys, wheel, delete focus | `Panel/PanelKeys.swift`, `Panel/PanelTableView.swift`, `Panel/PanelListViews.swift`, `Panel/PanelOperations.swift` | panel |
| tests | `Mac/Tests/AppTests/RecheckTests.swift`, `RecheckProbeTests.swift`, `RecheckDialogKeysProbe.swift` | harness |

Nothing outside `Mac/` was touched.

## 10. The Windows machine

`HKCU\Software\7-Zip` was exported to `%TEMP%\szcmp\reg-backup.reg` before the first step (a copy
kept in the session scratchpad, not committed: it holds the user's history), deleted before each
step, and at the end deleted and re-imported from the backup (same 30 lines as before). Every 7zFM /
7zG window was closed by the steps (`StopFM`); the SHA-512 run was cancelled with its own Yes. The
scheduled task `sz_cmp` and `%TEMP%\szcmp` (fixtures, the 6 GB `big.bin`, the 121-file folder) were
deleted. Nothing was moved to the Recycle Bin: the only deletion was the empty "New Folder" the step
created, with Shift+Delete.

## 11. Verification

All runs with `DEVELOPER_DIR=/Applications/Xcode.app`.

| run | result |
|---|---|
| `Mac/scripts/test.sh -u` (input shard + both probes), after the chrome, progress, keys, dialog and colour commits | **64 passed, 0 failed** (52 + 6 + 6) |
| `Mac/scripts/test.sh -H` during the work | 201 → 206 → 210 passed, 0 failed |
| final `build.sh` | exit 0, no warnings in `Mac/` |
| final `test.sh` (unit) | **388 passed, 0 failed** |
| final `test.sh -H` | **206 passed, 0 failed** (RecheckTests 10; the probes skip without `Mac/build/recheck/PROBE`). One earlier full run failed `RecheckTests.testListKeysMoveLikeTheListControl` and, as a knock-on, `SelColorsTests.testDropTargetRowIsHighlightedAndReadable`: an earlier test had left panel 0 in an icon mode; the test now pins and restores Details |

Paired captures (1x, light): `screenshots/wincompare-recheck-main-top-{win,mac}.png` (760×220 from
the client's top-left), `-statusbar-` (the bottom 56 px), `-splitter-` (two panels around the
splitter).
