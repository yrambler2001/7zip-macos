# `dlgfeel`: every dialog laid out from its Windows template, measured against 7zFM 26.03

Branch `mac/dlgfeel`, off `macos` at `0be1f72`, 2026-10-04. Scope: the user's findings 8, 12-15,
17-23, 25 and 28, then a sweep of every other dialog. The work touches files of several scopes,
all listed in section 9.

## 1. How it was measured, and how the port lays dialogs out now

**Reference.** `ssh windows-host`: Windows 11, 96 dpi, **7-Zip 26.03 (x64)**. The registry key
`HKCU\Software\7-Zip` was exported first, deleted before every step (fresh defaults) and
re-imported at the end (section 10).

**Harness.** `dlgfeel-data/harness/` is the `listfeel` harness. Its `Controls` dump was extended
with three readings:

- the window style (`RESIZABLE` / `FIXED` from WS_THICKFRAME, MIN/MAX boxes);
- the dialog font;
- every control's style.

| step | what it does | output |
|---|---|---|
| `wrun.sh dlg1` | opens and dumps 31 dialog states with PrintWindow captures | `win/dlg-*.txt`, `win/dlg-*.png` |
| `wrun.sh dlg2` | screen captures of the six Options pages (PrintWindow leaves the tab strip blank), their tab rects (TCM_GETITEMRECT), and Benchmark resized by 200 x 100 px | `win/screen-*.png`, `win/options-tabs.txt`, `win/dlg-bench-resized.txt` |

The dialogs in `dlg1` are About, Copy, Move, Create Folder, Create File, Comment, Link, Checksum,
Select, Folders History, Delete Temporary Files, Split, Combine, and all six Options pages. The
step also opens Benchmark (at start, at 9 s and at 18 s), Add to Archive (7z and zip, with the
Options dialog of each), Extract, Progress (during a SHA-512 of a 6 GB file), Password,
Properties inside an archive, and Overwrite.

**The finding behind the new layout.** Every 7zFM dialog is a `.rc` template in dialog units.
The dialog font is MS Shell Dlg 8 pt, whose base units are 6 x 13 at 96 dpi. A control's pixel
rect is therefore MulDiv(x, 6, 4), MulDiv(y, 13, 8) with the size converted the same way. This
was checked against every dump. For example:

- IDD_ABOUT 160 x 160 DLU is a 240 x 260 client;
- IDD_COMPRESS 416 x 336 DLU is 624 x 546;
- "Archive format:" at 8,41 DLU is 12,67 px.

The text itself is drawn in Segoe UI 9 pt: cap height 9, "Compression method:" 98 px.

**The port, accordingly** (new files):

| file | role |
|---|---|
| `Mac/scripts/make-rc-layout.py` | runs both `resource.rc` files through the C preprocessor, like `make-rc-strings.py`, and writes `Mac/App/Support/RcTemplates.swift` with every DIALOG template: 25 dialogs, 316 controls, with their kinds, texts and WS_THICKFRAME |
| `Mac/App/Support/RcLayout.swift` | `RcDialog(idd).rect(id)` gives the Windows pixel rect of a control (one px = one pt); `RcFormView` is a flipped client area; `RcPlace` puts an AppKit control on a rect so its drawing lands where Windows draws (below); `RcResize` holds the pieces of every OnSize |
| `RcLayout.swift`, Windows-drawn pieces | `WinGroupBox`, Windows 11's group box; `WinProgressBar`, msctls_progress32; `WinPopUpButtonCell`, the combo's 4 px text inset |
| `Mac/App/Dialogs/OptionsTabControl.swift` | the property sheet's tab strip |

How `RcPlace` lines AppKit controls up with Windows:

- **Static.** Text at the rect's left edge and its baseline 11 px down.
- **Check box.** The box at the rect's left edge, centred.
- **Combo box.** 21 px tall.
- **Edit field.** The rect, less AppKit's 1 px shadow.
- **Push button.** Native (the user's exception), 1 px inside the rect, as Windows 11 draws it.

**Calibration.** IDD_COMPRESS's controls were rendered on their Windows rects and their ink was
measured against the Windows capture (`DlgFeelCalibration`). The group frame's top, left, right
and bottom lines are on the same pixels (y 136, x 336, x 611, y 232). The drop-down is at the
same rect (168,63 132x21) and the button at 13..106. Check-box text baselines agree (y 164), and
label baselines agree after a 2 px shift.

**Statics behave like SS_LEFT.** The text breaks at word boundaries, and a one-line static shows
the words that fit, never an ellipsis.

**Font.** Helvetica Neue 11, the font `listfeel` matched to Segoe UI 9 for the list
(`DialogMetrics.font` = `PanelMetrics.listFont`).

**Resizable dialogs.** They port their OnSize and start at the template size.

## 2. The user's findings

| # | finding | Windows 26.03 (measured) | macOS before | macOS now |
|---|---|---|---|---|
| 8 | About | 240 x 260 px, fixed. Logo 12,13; version / date / copyright at y 88 / 109 / 130; info at 151; buttons 96 x 26 at y 221 | 420 x 162 pt, text column beside the logo, bold version | 240 x 260 on the template. **"macOS version by yrambler2001"** at y 151, the copyright line's 21 px pitch under it; the info moves down one line |
| 12 | System: the per-user note | none | a three-sentence note | removed |
| 13 | System: columns | Type 80 px left, `<user>` 152 px **centred** (header and cells), All users 152 px; one "+" over each state column | Type, Description, user, Default application; "+", "−" and "*" buttons; alternating rows | Type 80 (format icon + extension) and `<user>` 152 centred: the NUM_EXT_GROUPS == 1 build of SystemPage.cpp, because macOS has no all-users associations. One "+" (IDB_SYSTEM_CURRENT 101) over the user column. Rows 17 px, 24 px header, no alternating colours. Keys Space / + / − / * / Return unchanged |
| 14 | Options resizable | fixed: 494 x 550 client | resizable, 660 x 580 | fixed at 494 x 550 |
| 15 | Options page size | page 474 x 481 at 10,29; tab control 6,7 482x507; buttons 75 x 23 at y 520; the 7-Zip page's 14 items in 450 x 299, no scroll bar | pages sized by Auto Layout; the item list scrolled | each page is the template's 474 x 481 at 10,29. The 7-Zip list is 450 x 299 with 17 px rows: 14 x 17 = 238, no scroll bar. Tested in English, German, Russian, French, Japanese and Ukrainian (`testOptionsPagesDoNotScrollInSeveralLanguages`) |
| 15 | tab strip | Windows 11 tabs from x 8 (rects in section 3.1) | AppKit's centred segmented tabs | `OptionsTabControl`: tabs from x 8, unselected (245) fill with a (234) frame, the selected tab 2 px larger and open into the page, caption baseline 14 px down, page (250) with a 2 px shadow. The page area stays a tabless NSTabView. Ctrl+Tab, Ctrl+Shift+Tab, Ctrl+PgDn and Ctrl+PgUp switch pages |
| 17 | Folders: the note | none | "Current means… Stored as Options.WorkDirType…" | removed; the controls are on the IDD_FOLDERS rects |
| 18 | Editor | label, then a 408 px field and "..." (30 x 26), three times: y 42 / 62, 94 / 114, 146 / 166 | three label-above-field groups in a stack, placeholders, a long note | exactly the template; no placeholders, no note. Behaviour unchanged: a bundle, an executable, or a command line with the path appended |
| 19 | "Use large memory pages" | a checkbox at 22,227 | a disabled checkbox with a note | removed. The controls under it keep their places, as a hidden control leaves its place on Windows |
| 20 | "Show system menu" note | checkbox text "Show system &menu" | the checkbox plus a macOS note | the checkbox with the Windows caption, no note; the setting keeps its macOS meaning |
| 21 | Language | one CBS_DROPDOWNLIST 240 px wide at 22,62 with "English : English  ---", "<English> : <native>" + "  ***" / "  +++", sorted, English first; the info static under it; the choice applies on OK / Apply | a five-column table, a "System default" row, live switching | the Windows drop-down list and info static, in the same order and with the same marks. Picking an entry only shows its info and enables Apply; Apply / OK store `Lang` and switch the language (OnApply → SaveRegLang + ReloadLang). Cancel leaves everything as it was |
| 22 | Plugins page | none | a macOS-only page | removed (`OptionsPluginsPage.swift` deleted) |
| 23 | Benchmark | 732 x 429; group boxes Compressing / Decompressing / Total Rating; RTEXT values; WS_THICKFRAME, and a resize moves nothing but the log static (`dlg-bench-resized.txt`: every control at the same rect after +200 x +100); 10 passes selected | 900 x 490, a grid whose columns moved with the values, bold group labels, no boxes, a scrolling text view for the log | IDD_BENCH on the template: three `WinGroupBox`es and right-aligned values that never move. Resizing only stretches the log (OnSize). Passes default to 10 (k_NumBenchIterations_Default). The window stays resizable, which is what 7zFM 26.03 measures (style 0x94CF08C4, WS_THICKFRAME); only the log grows |
| 25 | Add to Archive | 624 x 546, fixed, every control on the IDD_COMPRESS rects (`dlg-compress.txt`) | 986 x 484, two auto-laid-out columns, NSBox groups | 624 x 546 on the template, with Windows group boxes. The drop-downs have Windows' text insets ("100 ns : Windows" no longer reads "100 ns : Wind…") |
| 25 | the Options dialog's time controls | IDD_COMPRESS_OPTIONS 384 x 403, a modal dialog with a caption. NTFS group (hidden for 7z / zip); "Type: 7z"; Time group with "**:**" IDX_COMPRESS_PREC_SET + "Timestamp precision:" + combo (246,182 114x21); ":" + Store modification / creation / last access time; ":" + Set archive time; "Do not change source files last access time". Hidden items leave their places | a sheet that collapsed hidden rows | the template with every time control, shown and enabled exactly as SetPrec / SetTimeMAC decide. A modal dialog over Add to Archive, not a sheet |
| 28 | Exclude Mac resource forks | — | — | see section 4 |

## 3. The sweep: Windows px against Mac pt

Client areas. "before" is the port at `0be1f72`, rendered by `DlgFeelSnapshots` at 1x.

| dialog | template | Windows 26.03 | resizable on Windows | Mac before | Mac now |
|---|---|---|---|---|---|
| About | IDD_ABOUT 2900 | 240 x 260 | no | 420 x 162 | **240 x 260**, fixed |
| Options | property sheet | 494 x 550 | no | 660 x 580, resizable | **494 x 550**, fixed |
| Add to Archive | IDD_COMPRESS 4000 | 624 x 546 | no | 986 x 484 | **624 x 546**, fixed |
| Compress Options | IDD_COMPRESS_OPTIONS 14001 | 384 x 403 | no | 420 x 308, a sheet | **384 x 403**, fixed, a dialog |
| Extract | IDD_EXTRACT 3400 | 528 x 299 | no | 560 x 328 | **528 x 299**, fixed |
| Overwrite | IDD_OVERWRITE 3500 | 534 x 351 | no | 520 x 312 | **534 x 351**, fixed |
| Password | IDD_PASSWORD 3800 | 324 x 143 | no | 573 x 190 | **324 x 143**, fixed |
| Memory usage | IDD_MEM 7800 | 504 x 351 (template) | no | 642 x 308 | **504 x 351**, fixed |
| Copy / Move / Combine | IDD_COPY 96 | 504 x 260 | yes | 502 x 144 / 666 x 142 | **504 x 260**, OnSize |
| Create Folder / File, Select, Comment | IDD_COMBO 98 | 384 x 130 | yes | 360 x 120 (Comment: a 460 x 216 multi-line editor) | **384 x 130**, OnSize; Comment is the Combo dialog, as on Windows |
| Split | IDD_SPLIT 7300 | 456 x 182 | yes | 480 x 176 | **456 x 182**, OnSize |
| Link | IDD_LINK 7700 | 456 x 374 | yes | 540 x 318 | **456 x 374**, OnSize |
| Properties, Folders History, Checksum | IDD_LISTVIEW 99 | 744 x 546 | yes | 720 x 474 / 720 x 334 | **744 x 546**, OnSize |
| Progress | IDD_PROGRESS 97 | 564 x 332 | yes | 560 x ~300 | **564 x 332**, OnSize |
| Messages | IDD_MESSAGES 6602 | 684 x 286 (template) | yes | 640 x 294 | **684 x 286**, OnSize |
| Delete Temporary Files | IDD_BROWSE2 93 | 699 x 559 | yes | 900 x 452 | **699 x 559**, OnSize |
| Benchmark | IDD_BENCH 7600 | 732 x 429 | yes (only the log grows) | 900 x 490 | **732 x 429**, OnSize |
| text viewer | IDD_EDIT_DLG 94 | 504 x 416 (template) | yes | 480 x 320+ | **504 x 416**, OnSize |

Controls, positions and look changed in the sweep (beyond sizes):

**Extract**

- The controls are on the IDD_EXTRACT rects, with the Password group box.
- "Restore file security" keeps its place, hidden (no NT security on macOS).
- **Extract inside an archive is now the Copy dialog**, because 7zFM's
  `CPanel::ExtractArchives` calls `OnCopy` there. The port used to show the Extract dialog with
  summary lines, a documented deviation.

**Copy / Move / Combine**

- One `CopyMoveDialog` with the IDT_COPY_INFO static: 11 lines, never wrapped, clipped at the
  right (SS_LEFTNOWORDWRAP).
- Combine is that dialog with IDS_COMBINE's caption and label, as on Windows.

**Link**

- All five link types are shown. "Directory Junction" and "WSL" are disabled.
- The note about NTFS reparse points is gone.

**Checksum results**

- The plain IDD_LISTVIEW with OK and Cancel, like 7zG's ShowHashResults.
- The extra Copy button is gone; Ctrl+C still copies.

**Password**

- One field and "Show password", on both sides, because 7zG's CryptoGetTextPassword2 shows the
  same CPasswordDialog.
- The compress-side verify field, "Encrypt file names" and the subject line are gone.

**Progress**

- CProgressDialog::OnSize is ported: label / value columns of 135 + 108 px, the second column
  at 309, buttons 120 x 26 that shrink when narrow, the message list in its own place.
- The window no longer grows when messages arrive.
- `WinProgressBar` draws the Windows 11 bar: a (200) frame, a (235) track and a (0,138,17) fill.

**Overwrite**

- The IDD_OVERWRITE rects, with 32 px icons at 12,72 and 12,185.
- Yes to All / No to All / Auto Rename leave their places empty when hidden.

**Delete Temporary Files**

- The IDD_BROWSE2 rects and OnSize.
- Column widths 186 / 111 / 67 / 72 / 72 / 132, from LVSCW_AUTOSIZE over 7zFM's sample row.
- Small file icons, 17 px rows, a read-only edit for the folder.

**Messages and the progress message list**

- 17 px rows, a 24 px header, no alternating colours, a line border.

**Text viewer**

- The dialog font instead of a monospaced one.

### 3.1 Options tab strip (TCM_GETITEMRECT)

The tabs are System 2..48, 7-Zip 48..90, Folders 90..136, Editor 136..178, Settings 178..228
and Language 228..288, on y 2..20 of the control at 6,7. The caption sits 6-7 px in from each
side. The port sizes a tab as max(42, caption + 13): 46 / 42 / 46 / 42 / 50 / 60 in English.

## 4. "Exclude Mac resource forks" (finding 28)

**The control**

- A checkbox in the **Options group box** of Add to Archive, under "Delete files after
  compression".
- The group grows by one 16 DLU row, and the Encryption group moves down by the same 26 px. It
  still ends 16 DLU above the button row.
- It has no lang ID (no language file has the text).

**State**

- **Unchecked by default.**
- Remembered as `Compression.ExcludeMacResourceForks` (bool), like `Compression.ShowPassword`.

**What it does when checked.** `CompressMacMetadata` (CompressModel.swift) adds three recursive,
wildcard excludes to the update's censor: `._*`, `.DS_Store` and `__MACOSX`. That is exactly
`-xr!._* -xr!.DS_Store -xr!__MACOSX`, so the engine's own matcher drops:

- the AppleDouble files that carry a resource fork and extended attributes on a volume that
  cannot hold them;
- Finder's folder files;
- Archive Utility's metadata folder.

It also turns `storeAltStreams` off. The engine stores no resource-fork or xattr stream on macOS
in any case, so with or without the box no `com.apple.*` attribute data reaches the archive.

**Unchecked.** Behaviour is unchanged.

**Command line.** The same switches already work: `7-Zip x … -xr!._* -xr!.DS_Store -xr!__MACOSX`
for `a`, or the `-ad` dialog with the box. A new switch was not added. The 7z switch grammar is
upstream's, and the three excludes say the same thing.

**Paths.** The panel / Finder path (`CompressCommands.run`) and the command line with `-ad`
(`CommandExecutor`) both apply it.

**Tested** (`DlgFeelTests.testExcludeMacResourceForksKeepsMacMetadataOutOfTheArchive`). The
fixture folder holds `a.txt` with a `com.apple.ResourceFork` and a `com.apple.metadata:…`
attribute, plus `._a.txt`, `.DS_Store`, `sub/.DS_Store`, `sub/._b.txt` and `__MACOSX/._a.txt`.
The two archives were listed:

- **unchecked**: `folder, folder/.DS_Store, folder/._a.txt, folder/__MACOSX, folder/__MACOSX/._a.txt, folder/a.txt, folder/sub, folder/sub/.DS_Store, folder/sub/._b.txt, folder/sub/b.txt`;
- **checked**: `folder, folder/a.txt, folder/sub, folder/sub/b.txt`;
- neither has an alternate-stream entry.

## 5. Behaviour fixes found on the way

**Language** applies on OK, not on selection (finding 21).

**Benchmark** passes default to 10.

**Extract inside an archive** uses the Copy dialog (section 3).

**Compress Options** is a modal window, not a sheet.

**Password** is single-field on the compress side.

**Remaining differences, by design or by AppKit:**

- Native push buttons and the window title bar (the user's exceptions).
- Native check boxes, radio buttons, edit fields and combo boxes, on the Windows rects. AppKit's
  check-box text starts 3 px further right (the box is 14 px against 13).
- Helvetica Neue instead of Segoe UI: the same baselines, about 4 % wider ink.
- macOS overlay scroll bars.
- AppKit's lighter window background (white against (243)).

## 6. Paired captures

`screenshots/wincompare-dlgfeel-<name>-win.png` is the Windows client area. The matching
`-mac.png` is the Mac content view at 1x in the light appearance, written by
`DlgFeelSnapshots` when `Mac/build/dlgfeel/PAIRED` exists.

The 24 pairs:

| group | pairs |
|---|---|
| general | about |
| Options | options-0 … options-5 |
| path and name dialogs | copy, createfolder, comment-file, split, combine, link |
| lists | hash-crc32, history, tempfiles |
| Benchmark | bench-start (against Windows at 18 s) |
| extract and compress | extract, compress, compress-options, compress-options-zip |
| operation dialogs | overwrite, password, progress |

The Mac halves render inactive controls (the test host is not the active app), so check boxes
and drop-downs look dimmed there.

## 7. Tests

**`Mac/Tests/AppTests/DlgFeelTests.swift`** (new, 17 cases):

- the client size and resizability of 16 dialogs against the table above;
- the Compress Options dialog (size, not a sheet, the precision set box and combo);
- About with the credit line on the copyright pitch;
- Options: six pages, no banned note text, no placeholders;
- the System page's columns;
- the Editor page's layout;
- the Language page's single drop-down list;
- the Options pages without scrolling, and the 7-Zip list's 14 items without a scroll bar, in
  six languages;
- Benchmark: group boxes, RTEXT values, and columns that do not move on resize;
- Add to Archive: two group boxes, and the new box unchecked and inside the Options group;
- the resource-fork exclusion end to end, and its persistence;
- Extract and Link group boxes;
- Link's five link types;
- Checksum results with OK and Cancel only;
- Copy's OnSize.

**`DlgFeelSnapshots.swift`** (new) writes the Mac renders. `DlgFeelCalibration` is the control
calibration.

**Updated:**

- `DialogLayoutTests` and `OpsGapsTests`: six Options pages.
- `OptGapsTests`:
  - the System columns and the Language drop-down replace the column-fit test;
  - the syslayout header-row regression is removed, because that Auto Layout row no longer
    exists;
  - the Copy info is now one static.
- `SelColorsTests`: centred cell text is measured where it is drawn.
- `WindowAudit`: overlap is judged on a label's text rect (frames reach 2 pt past the text, so
  statics that touch on Windows touched here); a text field's field-editor internals are not
  walked.

## 8. Verification

All runs used `DEVELOPER_DIR=/Applications/Xcode.app`, at the final code.

| run | result |
|---|---|
| `Mac/scripts/build.sh` | clean, no warnings in `Mac/`; the app is signed with `com.apple.security.automation.apple-events` |
| `Mac/scripts/test.sh` (unit) | 388 passed, 0 failed |
| `Mac/scripts/test.sh -H` (app-hosted) | 184 passed, 0 failed (`DlgFeelTests` 17) |
| `Mac/scripts/test.sh -u` (input + probes) | 49 + 6 + 6 passed, 0 failed |
| `make-rc-layout.py --check` | `RcTemplates.swift` is current |

## 9. Files

**New:**

- `Mac/scripts/make-rc-layout.py`
- `Mac/App/Support/RcTemplates.swift` (generated)
- `Mac/App/Support/RcLayout.swift`
- `Mac/App/Dialogs/OptionsTabControl.swift`
- `Mac/Resources/App.entitlements`
- `Mac/Tests/AppTests/DlgFeelTests.swift`
- `Mac/Tests/AppTests/DlgFeelSnapshots.swift`
- `Mac/docs/reports/dlgfeel-data/`
- 24 `-win` and 24 `-mac` paired captures

**Changed, by owning scope:**

| scope | files |
|---|---|
| options | `OptionsWindow.swift`, `OptionsSystemPage.swift`, `OptionsMenuPage.swift`, `OptionsFoldersPage.swift`, `OptionsEditorPage.swift`, `OptionsSettingsPage.swift`, `OptionsLanguagePage.swift`; `OptionsPluginsPage.swift` deleted; `Settings.swift` (one new key) |
| tools | `AboutDialog.swift`, `BenchmarkDialog.swift`, `SplitDialog.swift`, `CombineDialog.swift`, `LinkDialog.swift`, `HashResultsDialog.swift`, `ToolsTempFilesDialog.swift` |
| compress | `CompressDialog.swift`, `CompressOptionsSheet.swift`, `CompressModel.swift`, `Commands/CompressCommands.swift` |
| extract | `ExtractDialog.swift`, `Commands/ExtractCommands.swift` |
| panel | `CopyMoveDialog.swift`, `ComboDialog.swift`, `CommentDialog.swift`, `ListViewDialog.swift` |
| opsinfra | `PasswordDialog.swift`, `OverwriteDialog.swift`, `ProgressDialog.swift`, `ProgressDialogSupport.swift`, `MessagesDialog.swift`, `MemoryUseDialog.swift`, `Support/OperationRunner.swift` |
| finder | `Integration/CommandExecutor.swift` (the -ad excludes) |
| harness | `Mac/project.yml` (`CODE_SIGN_ENTITLEMENTS` of the app target); tests above |

**Packaging note** (requests.md, listfeel → packaging). `com.apple.security.automation.apple-events`
is now in `Mac/Resources/App.entitlements`, the app target's `CODE_SIGN_ENTITLEMENTS`. A Developer
ID build with the hardened runtime (`package.sh -i …`) therefore carries it. The ad-hoc builds
carry it too, which is harmless. `Mac/README.md`'s "sends no Apple events" sentence predates
`listfeel` and is left to the packaging scope.

Nothing outside `Mac/` was touched.

## 10. The Windows machine

**Registry.** `HKCU\Software\7-Zip` was exported to `%TEMP%\szcmp\reg-backup.reg` (copied to the
session scratchpad, not committed), deleted for each step, and re-imported at the end. It has the
same values as before: Path, Path32, Path64 and the FM key.

**Processes.** Every 7zFM / 7zG process was closed or killed by the steps and at cleanup. The
SHA-512 run on the 6 GB `big.bin` was cancelled by closing 7zFM, and the file was deleted with
the fixture folder.

**Cleanup.** The scheduled task `sz_cmp` and `%TEMP%\szcmp` were deleted.
