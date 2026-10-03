# `winmatch`: the five `wincompare` differences, the original icon, a Windows toolbar

Branch `mac/winmatch`, off `macos` at `006d42d`, 2026-10-03. The user's three decisions:

1. fix the five differences `wincompare` filed (`requests.md`) so the Mac matches 7zFM;
2. the app icon is the original `FM.ico`, converted without redrawing;
3. the toolbar looks like 7zFM's: flat buttons, the bitmap with the label under it, no bezel.

The reference is again the real 7zFM **25.01** on `ssh windows-host` (Windows 11, 96 dpi), driven by the
`wincompare` harness. The new scripts are in `winmatch-data/harness/` (`wrun.sh t1` = every
toolbar mask with hover and pressed, the About dialog and the 7zFM.exe icon; `wrun.sh t2` = F1 in
About), and every dump and capture they produced is in `winmatch-data/win/`.

## 1. A folder just opened: focus, no selection (`01 §3.6`, PanelItems.cpp:984-1001)

| | 7zFM 25.01 | macOS before | macOS now |
|---|---|---|---|
| status bar of a fresh folder | `0 / 15 object(s) selected`, part 1 empty | `1 / 15`, part 1 the first item's size | `0 / N`, part 1 empty |
| the first item | focused (dotted rectangle), not selected | focused and selected | focused, dotted rectangle, not selected |
| after Deselect All | nothing operated | the focused row was operated | nothing operated |
| File menu, nothing selected | only Split / Combine / Link grayed (`win/menu-noselection.txt`) | items depended on the fallback row | only Split / Combine / Link grayed |
| F5 with nothing selected | Copy dialog for the whole folder (Get_ItemIndices_OperSmart) | nothing | the whole folder |
| Shift+F5 / Shift+F6 | the focused item, selected or not | the operated items | the focused item |
| Down from an unselected focus | the next item, selected | NSTableView selected row 0 | the next item, selected |

How: `PanelOperatedItems.operated` takes `focusedIsListSelected` and falls back to the focused row
only then, which is the AlternativeSelection cursor (`_listView.IsItemSelected`); `operatedSmart`
is used by Copy / Move. `restoreSelection` no longer selects the focus. `PanelRowView` draws the
list control's dotted focus rectangle around the name cell (the row with FullRow) of a focused,
unselected row while the list has the keyboard focus. `isActionEnabled` / `windowActionIsEnabled`
follow CFileMenu::Load (MyLoadMenu.cpp:635-672): nothing selected grays nothing. F3 / Space on an
unselected focused folder still calculates its size (EditItem uses the focused item).

## 2. The Extract dialog has no archive summary (IDD_EXTRACT 3400)

7zG's dialog has no such control (`wincompare-data/win/dlg-extract.txt`). The summary is gone for
archives on disk and for the 7zG command line (`CommandExecutor`). It stays only for Extract inside
an archive: there 7zFM shows CCopyDialog, whose info text the lines are.

## 3. The progress window: no "Errors: N" line (IDD_PROGRESS 97)

`OnExternalCloseMessage` only re-labels the buttons, so on 7zFM IDT_PROGRESS_STATUS 103 stays empty
and the count is in the Errors row (`wincompare-data/win/dlg-test-broken-final.txt`). The port now
leaves it empty too. Its row labels are now the dialog's own .rc texts (`Files:`,
`Compressed size:`), as LangSetDlgItems_Colon keeps them when no language file is loaded.

## 4. Built-in English is the .rc text, not `en.ttt`

With no language file, 7zFM shows its compiled resources. `en.ttt` is the translators' template and
differs in places, for example:

| ID | .rc (Windows) | en.ttt (port before) |
|---|---|---|
| 4000 | Add to Archive | Add to archive |
| 4008 | &Solid Block size: | Solid block size: |
| 3803 in IDD_EXTRACT / IDD_COMPRESS | Show Password | Show password |

`Mac/scripts/make-rc-strings.py` runs `CPP/7zip/UI/FileManager/resource.rc` and
`CPP/7zip/UI/GUI/resource.rc` through the C preprocessor (rc.exe preprocesses them the same way,
so every `#define`d ID resolves). It collects dialog captions, control texts and STRINGTABLE
entries into `Mac/Core/Internal/SZRcStrings.h`: 403 IDs, plus 149 texts per dialog. `SZLang` looks
an ID up in this order: the language file, then the .rc text, then en.ttt, then the resource-only
names. A language file still wins.

Five IDs carry different texts in different dialogs, so they are only in the per-dialog table. The
code asks for them with their IDD (`Lang.dialogText`, `Lang.dialogTextColon`):

| ID | texts by dialog |
|---|---|
| 3801 | "&Enter password:" (Password), "Enter &password:" (Compress) |
| 3803 | "&Show password" (Password), "Show Password" (Extract, Compress) |
| 3903 | "Speed:" (Progress), "Speed" (Benchmark) |
| 4009 | "Number of CPU &threads:" (Compress), "&Number of CPU threads:" (Benchmark) |
| 7302 | "Split to &volumes,  bytes:" (Split, two spaces), "Split to &volumes, bytes:" (Compress) |

1008 and 1032 resolve to their STRINGTABLE text, "Packed Size" and "Files", which is what
LangString loads. The progress window asks with its dialog and gets "Compressed size:" and
"Files:". Menus are unchanged: they already pass their .rc text (`Lang.menuTitle`).

## 5. About: as on Windows, two buttons, with F1 for help

Checked on the PC (`win/about.txt`): IDD_ABOUT shows **OK** and **www.7-zip.org** only, in 25.01
and in the 26.03 `.rc`. Pressing F1 in the dialog opens the help (`CAboutDialog::OnHelp`, start.htm).
`win/about-f1.txt` records the window that came up: an HtmlHelp "HH Parent" window in 7zFM's own
process. The port keeps the two buttons, and the dialog now answers F1 (and the Mac Help key) with
`Help.show(topic: "start.htm")`. So the Help button is not "restored": Windows has none, and the
entry point Windows does have is now there.

## 6. The app icon is FM.ico (user decision 2)

`make-icons.py` writes the app icon straight from `CPP/7zip/UI/FileManager/FM.ico`
(`stage_app_icon`). Nothing is redrawn, and there is no rounded-square mask, margin or shadow. The
ICO has 16, 32 and 48 px frames. Each macOS size takes the nearest frame, the larger on a tie: 16
and 32 at 1:1, and 64 to 1024 from the 48 px frame. The frame is resampled nearest-neighbour, so
every output pixel is an unchanged source pixel. The `verify` stage checks that the app PNGs hold
only FM.ico's colours. The Swift renderer's app-icon code and the superellipse are gone. Re-running
`make-icons.sh` reproduces the committed assets byte for byte; only `AppIcon.appiconset` and the
contact sheet changed.

**Against Windows:** the 32 px slot is pixel-identical (0 differing pixels) to the icon Windows'
shell extracts from `7zFM.exe` 25.01 (`win/icon-7zFM-exe-32.png`). The side-by-side is
`screenshots/wincompare-icon-win-mac.png`: Windows 32 px ×4, Mac 32 px ×4, Mac 128 px, Mac 16 px ×4.

`7zipLogo.ico` already ships unscaled as `AboutLogo` (`mac/release`), which is where Windows uses
it (IDI_LOGO in IDD_ABOUT).

**Document icons were left as they are.** Windows' per-format icons are 32 px `.ico`s that Explorer
shows as such. Their macOS forms are pages drawn with each format's exact badge colour and label.
The user's rule ("identical to the original 7-Zip icon") names the app icon. Applying it to the 27
format icons would replace macOS document icons with 32 px squares, which is a separate decision.
`make-icons.py` already decodes every format icon's frames into `Mac/build/icons/frames/`, so
switching would take one function like `stage_app_icon`.

## 7. The toolbar (user decision 3, 01 §1.3, App.cpp CreateToolbar / AddButton)

macOS 26 draws every `NSToolbarItem` in a rounded glass capsule. The `NSToolbar` is gone. In its
place is `FMToolbarView` (`Mac/App/MainWindow/FMToolbar.swift`), a strip at the top of the window's
content, under the native title bar. CApp::MoveSubWindows puts it there too.

Measured on 7zFM 25.01 (`win/tb-*.txt`, `win/tb-*.png`, pixel colours read from the captures):

| | 7zFM 25.01 | port |
|---|---|---|
| strip | 2 px etched line on top (160 gray, then white), buttons, 4 px below; 52 px high with small buttons and text | the same structure (`2 + button + 4`) |
| separators | none: the archive and standard buttons are back to back | none |
| button size | every button the same: widest label or bitmap + 7 × 6 px; the label is a 16 px line under the bitmap. 42×46 (small, text), 31×30 (small), 55×58 (large, text), 55×42 (large) | the same rule. Text sizes depend on the font, so with SF 11 pt the buttons are 48×46 and 55×58; without text, 31×30 and 55×42 exactly |
| at rest | nothing drawn behind a button | nothing |
| hover | fill (229,243,255), 1 px border (204,232,255), 2 px corners | the same colours and shape (translucent white in dark mode) |
| pressed | fill (204,232,255), border (153,209,255) | the same |
| enabled state | never disabled (TBSTATE_ENABLED, never updated) | never disabled; a command with nothing to do does what 7zFM does (Add: "You must select one or more files", F5: the whole folder) |
| focus | toolbar buttons never take the keyboard focus | `refusesFirstResponder` |
| tooltip | the label (TBSTYLE_TOOLTIPS), also with text on | the same |
| narrow window | TBSTYLE_WRAPABLE wraps onto more rows | wraps |
| bitmaps | IDB_* 48×36 / IDB_*2 24×24, magenta-masked | the same assets, drawn nearest-neighbour so they stay crisp on Retina |

"Show Buttons Text", "Large Buttons" and the two toolbar toggles rebuild the strip, as
ReloadToolbars does. A language switch re-labels it (`OptionsPostApply.reloadLangItems`, which now
walks `MainWindows.controllers` instead of NSToolbars). For accessibility the strip has the role
"toolbar" and its buttons are `NSButton`s titled with the label, so `SevenZipApp.toolbarButton`
(XCUITest) finds them as before. The window title bar buttons and the dialogs' push buttons stay
native (user decision).

Paired captures are in `screenshots/`, `wincompare-toolbar-<state>-win.png` against `-mac.png`. The
states are `default`, `default-hover`, `default-pressed`, `large-text`, `large-text-hover`,
`large-text-pressed`, `small-notext`, `large-notext`, `archive-only` and `standard-only`. Both
halves are 420 px wide at 1x. The Mac half is written by
`WinMatchTests.testToolbarIsAFlatWindowsStrip` in the light appearance. The remaining visible
difference is the font: SF is wider than Segoe UI 9 pt, so a button with text is 6 pt wider.

## 8. Files touched, by owning scope

| change | files | owner |
|---|---|---|
| operated items, focus without selection, focus rectangle, arrows, menu rules, F3 size | `Panel/PanelLogic.swift`, `PanelViewController.swift`, `PanelTableView.swift`, `PanelKeys.swift`, `PanelMenuCommands.swift`, `PanelOperations.swift`, `Commands/PanelCommands.swift` | panel |
| toolbar strip | `MainWindow/FMToolbar.swift` (new), `MainWindow/MainWindowController.swift` | panel |
| toolbar re-label on a language switch | `Commands/OptionsCommands.swift` | options |
| Extract summary | `Commands/ExtractCommands.swift`, `Dialogs/ExtractDialog.swift` | extract |
| Extract summary in command mode | `Integration/CommandExecutor.swift` | finder |
| progress status line and labels | `Dialogs/ProgressDialog.swift` | opsinfra |
| .rc English | `Core/SZLang.mm`, `Core/include/SZLang.h`, `Core/Internal/SZRcStrings.h` (generated), `scripts/make-rc-strings.py` (new), `Support/Lang+WinMatch.swift` (new) | bridge / harness / shared extension |
| per-dialog texts | `Dialogs/PasswordDialog.swift` (opsinfra), `CompressDialog.swift` (compress), `ExtractDialog.swift` (extract), `BenchmarkDialog.swift`, `SplitDialog.swift` (tools), `ProgressDialog.swift` (opsinfra) | as listed |
| About F1 | `Dialogs/AboutDialog.swift` | tools |
| app icon | `scripts/make-icons.{py,swift}`, `Resources/Assets.xcassets/AppIcon.appiconset`, `docs/api/icons.md` | icons |

Nothing outside `Mac/` was touched.

Tests: `Mac/Tests/AppTests/WinMatchTests.swift` has 8 cases, one or more per change above. Tests
that asserted the old behaviour were updated: `PanelLogicTests.testOperatedItemsRule` (the
fallback rule), `MenuAndToolbarTests.testToolbarButtons`,
`NavGapsTests.testToolbarBitmapsAndVisibility`,
`NewWindowTests.testToolbarToggleInOneWindowLeavesTheOtherAlone`,
`OptGapsTests.testReloadLangItemsSkipsClosedWindows` (the strip instead of an NSToolbar),
`WinCompareDumpTests` (dumps the strip's buttons with their rects), and
`PanelGapsTests.testScreenshotLargeIcons`. That last one now waits for the icon view's layout: no
selection change forces it any more. `DialogLayoutTests` no longer gives the Extract dialog summary
lines.

## 9. Verification

See section 10 for the runs. Screenshots of the app itself: `screenshots/winmatch-fresh-folder.png`
(dark appearance, focus rectangle on `sub`, nothing selected), `winmatch-toolbar-window.png`,
`winmatch-extract-no-summary.png` and `winmatch-compress-rc-english.png`.

## 10. Results

(filled in below by the final runs)

## 11. The Windows machine

`HKCU\Software\7-Zip` was exported to `%TEMP%\szcmp\reg-backup.reg` before the first run (copied
here too), and every script deleted the key before starting 7zFM. At the end the key was re-imported
from the backup; it has the same three keys as before, with no `Toolbars` value, as before. The
scheduled task `sz_cmp` and the folder `%TEMP%\szcmp` were deleted. Every 7zFM window the scripts
opened was closed by them (`StopFM`), and the HtmlHelp window F1 opened was closed with it. No file
was deleted or moved on the PC.
