# `feel3`: Get Info, combo boxes, scroll bars, the list font, Open archive, the address drop-down, archive icons

Branch `mac/feel3`, off `macos` at `5086123`, 2026-10-05. Scope: the user's eight findings on the
Release build at `5086123`, the two `recheck2` leftovers (hover and slow-click rename in the icon
views, CEditDialog for the hash item info), and two decisions the user sent during the run
(Option+Space for Ctrl+Space; the inactive panel stays as Windows). Files of several scopes (§11).

## 0. Method

**Reference.** `ssh windows-host`: Windows 11, 7-Zip 26.03, 96 dpi; one Windows pixel = one macOS point.
`HKCU\Software\7-Zip` was exported first (a copy in the session scratchpad, not committed), deleted
before each part of the step, re-imported at the end (§12).

**Windows step** (`feel3-data/harness/f3.ps1`, run in the interactive session by the scheduled task
`sz_cmp` with the recheck2 harness, real input through `SendInput`), output in `feel3-data/win/`:

| part | measures | output |
|---|---|---|
| font | Segoe UI at height −12: `GetTextMetrics`, `GetOutlineTextMetrics`, `GetTextExtentPoint32` of 27 strings, a ClearType rendering | `font-segoe.txt/png` |
| icons | 41 files `a.<ext>` (the 40 registered extensions + `a.txt`), the `HKCR` ProgID and `DefaultIcon` of each, 7zFM in Details / Large / Small / List | `icons-assoc.txt`, `icons-*.png/txt` |
| address drop-down | the combo and its ComboLBox (`LB_GETITEMHEIGHT`, rect, `CB_GETCURSEL`), closed, after a click into the text, dropped, the mouse on rows 1 and 4 | `addr-*.png`, `log.txt` |
| combo boxes | Add to Archive: hover, dropped, focused, the edit combo hovered, zip (disabled combos) | `cmb-*.png/txt` |

Pixel values below were read from those captures and from the `dlgfeel` captures with a small
CGImage tool (colour runs, ink bounding boxes), not judged by eye.

**Mac side.** `Mac/Tests/AppTests/Feel3Tests.swift` (13 cases) and `Feel3FontTests.swift` (the font
images), app-hosted.

## 1. Info opens the folder instead of Get Info (finding 1)

**Cause.** `PanelFinderInfo` sent **one** `aevt/odoc` whose direct object was a **list** of
`information window of <file URL>` specifiers. AppleScript never builds that. What it sends for
`tell application "Finder" to open information window of …` was captured with an OSA send proc
(`OSASetSendProc`, so nothing reached Finder and no consent was needed):

| AppleScript | direct object of `odoc` |
|---|---|
| `information window of (POSIX file p as alias)` | `'obj '{want 'prop', form 'prop', seld 'iwnd', from 'obj '{want 'alis', form 'name', seld <HFS path>}}` |
| `information window of item (POSIX file p)` | `'obj '{want 'prop', form 'prop', seld 'iwnd', from 'obj '{want 'cobj', form 'indx', seld <file URL>}}` |
| `information window of (POSIX file p)` | `'obj '{… seld 'iwnd', from <file URL>}` (the shape the port used) |

Always one specifier, one event per `open`. Given a list, Finder treats the direct object as a list
of items to open and resolves each to its item — so a file "opened" its folder, which is what the
user saw. The system log of the user's run confirms the event reached Finder (Finder's
`TCCAccessRequestIndirect` for `com.yrambler2001.7zip` at the click, 19:08:37) and that no
Automation consent was ever requested from `tccd` (no `kTCCServiceAppleEvents` request from 7-Zip in
two days): the old code asked `AEDeterminePermissionToAutomateTarget` with `askUserIfNeeded: false`
and then sent anyway.

**Fix** (`Panel/PanelFinderInfo.swift`):

* one `open` per item (at most 20, `kMaxOpenItems`), the direct object the specifier AppleScript
  compiles for `open information window of item (POSIX file p)` (`FinderInfo.openEvent(for:)`),
  then `activate` Finder;
* `AEDeterminePermissionToAutomateTarget(finder, *, *, askUserIfNeeded: true)` first, on the
  background queue, so the "“7-Zip” wants to control “Finder”" prompt comes up; a refusal
  (−1743/−1744) falls back to the 7-Zip Properties list at once;
* unchanged: the entitlement `com.apple.security.automation.apple-events` (hardened runtime) and
  `NSAppleEventsUsageDescription` are in the built app; ad-hoc Release has no hardened runtime, so
  neither was the cause.

**Verified here:** the event's shape (`Feel3Tests.testGetInfoEventIsOneSpecifierPerItem`). **Not
verifiable here:** Finder's reaction — Automation cannot be granted on this machine without a
person (`vmcheck.md`; a consent prompt would hang an unattended run).

**Manual check** (a person, on the built app):

1. Select one file, press Info (Alt+Enter / the toolbar's Info). macOS asks once "“7-Zip” wants
   access to control “Finder”": OK. Finder's Get Info window for the file opens in front.
2. Select one folder, Info: its Get Info window. Select three items, Info: three Get Info windows.
3. System Settings › Privacy & Security › Automation › 7-Zip › Finder off: Info shows the 7-Zip
   Properties list. Back on: Get Info again.
4. An ad-hoc build gets a new code signature each build, so macOS may ask again after a rebuild;
   `tccutil reset AppleEvents com.yrambler2001.7zip` resets the decision.

## 2. Combo boxes and pop-ups (finding 2)

AppKit's pop-up on macOS 26 is a grey capsule with the title **centred**; its combo box a rounded
field with a blue button. 7zFM's are themed comctl32 combos. Measured (21 px high in every dialog):

| | CBS_DROPDOWNLIST ("select") | CBS_DROPDOWN (edit + list) |
|---|---|---|
| normal | border (210), bottom line (188), fill (253) | border (141), fill (255) |
| hover | border (0,120,212), bottom (0,108,190), fill (229,241,251) | the 19 px button part (252) |
| focused | border (165,191,210), bottom (147,171,188), fill (248,250,253), dotted focus rectangle x+3..right−20, y+3..bottom−3 | border (0,120,212); text selected from x+3, y+3 |
| disabled | border (234), fill (250), text (109), chevron (189) | — |
| text | 4 px in, baseline 15 px down (cap top +6) | the same |
| chevron | an 8 × 4 px "v", (110), centre 9.5 px from the right, top row +8 | the same |

`Support/WinCombo.swift` (new) draws exactly that: `WinPopUpButtonCell` (every dialog pop-up placed
by `RcPlace.popup`, i.e. all of them: Language, Options ▸ 7-Zip's zone combo, Add to Archive,
Extract, Benchmark, Compress Options, Temp files) and `WinComboBox` (every edit combo: Copy / Move,
Extract path, archive name and volumes, Split, Link, Create Folder / File / Select). The menu and the
field editor stay AppKit's. Hover is tracked per control; focus draws the dotted rectangle.

The field editor of an `NSComboBoxCell` is inset once more by the cell for its bezel; measured in
the Copy dialog and moved back (`WinComboBoxCell.bezelShift`), so the selection starts 3 px in and
3 px down as on Windows.

Paired: `wincompare-dlgfeel-{options-5,compress,copy}-{win,mac}.png` (re-rendered by
`DlgFeelSnapshots`; the Mac halves are in `Mac/build/dlgfeel/` and copied when `PAIRED` is set).
Measured after: Language combo text ink x 27 on both, the baseline on the same row; the cap top is
one row lower on the Mac (Helvetica Neue's 8 pt caps against Segoe's 9 px — §4).
`Feel3Tests.testDropDownListDrawsLeftAlignedText`, `testEditComboIsWindowsStyle`.

The address bar's combo is §6/§7.

## 3. Phantom scroll bars (finding 3)

Two causes:

1. **Overlay scrollers.** With "Show scroll bars: Automatically" and a trackpad, AppKit uses the
   overlay style, which *flashes* the scrollers when a view appears and whenever it scrolls —
   the vertical bar the user saw at launch, gone at a touch, then the horizontal one. A Win32 list
   shows a bar only while its content overflows on that axis, and then permanently.
   `Support/WinScrollView.swift` pins the legacy, auto-hiding style (the scroller-style override
   ignores the system's `NSPreferredScrollerStyleDidChangeNotification` reset). Used by both
   panels' Details and icon views and by every dialog list (Properties, Hash results, Temp files,
   Options, Benchmark, progress messages).
2. **The icon views' document view only ever grew** (`max(frame, clip)`), starting from 600 × 400,
   so a small folder kept a vertical bar. It is now sized to the layout's content, at least the
   clip.

In Details a horizontal bar appears when the columns are wider than the panel — as on Windows (two
500 pt panels do not hold 7zFM's 760 px of default columns). `Feel3Tests.testNoScrollBarsWithoutOverflow`
(all four modes, both panels).

## 4. The list font (finding 4) — options for the user

**Measured.** Segoe UI at height −12 (9 pt at 96 dpi): em 12 px, `tmAscent` 12, `tmDescent` 3,
internal leading 3. Rendered by ClearType: **caps 9 px, x-height 6 px** (design 8.4 / 6.0; hinting
rounds the caps up), stems ≈ 1 px (ink coverage of 'N' 1.03 px per row). Advance widths
(`GetTextExtentPoint32`): "a.txt" 22, "vol.7z.001" 51, "2024-01-15 11:30" 88, the 23 list strings
together 1 378 px. Windows draws it at 1x with ClearType; the Mac draws at 2x on Retina with
grayscale antialiasing, which makes the same point size look lighter.

The current default, Helvetica Neue 11, was matched by **width** on three strings (listfeel). Its
caps are 7.9 pt and its x-height 5.7 pt: **1.1 and 0.3 pt shorter than what Windows shows** — the
"smaller" the user sees, while the widths agree.

Two ways to match, for every candidate: **by height** (cap + x-height = 15, Windows' rendered
9 + 6) and **by width** (the 23 strings' summed advances = 1 378).

| candidate | size | cap | x-height | ascent / descent | 'l' width | "a.txt" | "vol.7z.001" | date | 23 strings | tabular digits |
|---|---|---|---|---|---|---|---|---|---|---|
| **Segoe UI 9 pt (Windows)** | 12 px | **9** (8.4) | **6** | 12 / 3 | ≈ 1 | **22** | **51** | **88** | **1 378** | yes |
| Helvetica Neue (current) | 11 | 7.85 | 5.69 | 10.5 / 2.3 | 0.93 | 21.6 | 50.1 | 88.1 | 1 323 (−4.0 %) | yes |
| Helvetica Neue by height | 12.2 | 8.71 | 6.31 | 11.6 / 2.6 | 1.04 | 23.9 | 55.6 | 97.7 | 1 467 (+6.5 %) | yes |
| Helvetica Neue by width | 11.5 | 8.21 | 5.95 | 11.0 / 2.5 | 0.98 | 22.6 | 52.4 | 92.1 | 1 383 (+0.4 %) | yes |
| SF Pro (system, no tracking) by height | 12.2 | 8.60 | 6.42 | 11.8 / 2.6 | 1.04 | 25.3 | 57.4 | 101.6 | 1 533 (+11.2 %) | no |
| SF Pro by width | 10.8 | 7.61 | 5.68 | 10.4 / 2.3 | 0.92 | 22.8 | 51.7 | 91.3 | 1 377 (−0.1 %) | no |
| Arial by height | 12.2 | 8.74 | 6.33 | 11.0 / 2.6 | 1.07 | 23.1 | 55.6 | 95.4 | 1 456 (+5.7 %) | yes |
| Arial by width | 11.6 | 8.31 | 6.02 | 10.5 / 2.5 | 1.02 | 21.9 | 52.9 | 90.7 | 1 385 (+0.5 %) | yes |
| Lucida Grande by height | 12.0 | 8.67 | 6.36 | 11.6 / 2.5 | 1.15 | 26.8 | 61.9 | 112.5 | 1 571 (+14.0 %) | yes |
| Lucida Grande by width | 10.5 | 7.59 | 5.57 | 10.2 / 2.2 | 1.01 | 23.4 | 54.1 | 98.5 | 1 374 (−0.3 %) | yes |

Pros and cons:

* **Helvetica Neue 12.2 (by height)** — Windows' visual size and Segoe-like shapes; dates need
  98 pt and are cut in the 100 pt default column ("2024-01-15 11:…"), names run 6 % longer.
* **Helvetica Neue 11.5 (by width)** — half a point bigger than today, widths still Segoe's;
  caps still 0.8 pt short of Windows.
* **SF Pro 12.2 (by height)** — the native macOS look at Windows' height; 11 % wider, proportional
  digits (sizes do not line up), dates cut.
* **SF Pro 10.8 (by width)** — native look, Segoe's widths; smaller than today in height, digits
  proportional.
* **Arial 12.2 / 11.6** — closest proportions to Segoe after Helvetica Neue, tabular digits; Arial
  looks more like Windows' older Arial UI than Segoe; 12.2 cuts dates.
* **Lucida Grande 12 / 10.5** — the old macOS UI font, very legible at small sizes; 14 % wider by
  height, short by width.

Images, Windows above and the Mac below, the same list (the Windows capture of `listfeel`), at
1x (1 Windows px = 1 Mac pt) and at 2x (Windows' pixels doubled, the Mac at Retina scale):

```
Mac/docs/reports/screenshots/feel3-font-current.png                     -2x.png
Mac/docs/reports/screenshots/feel3-font-helvetica-neue-byheight.png     -byheight-2x.png
Mac/docs/reports/screenshots/feel3-font-helvetica-neue-bywidth.png      -bywidth-2x.png
Mac/docs/reports/screenshots/feel3-font-sf-pro-byheight.png             -byheight-2x.png
Mac/docs/reports/screenshots/feel3-font-sf-pro-bywidth.png              -bywidth-2x.png
Mac/docs/reports/screenshots/feel3-font-arial-byheight.png              -byheight-2x.png
Mac/docs/reports/screenshots/feel3-font-arial-bywidth.png               -bywidth-2x.png
Mac/docs/reports/screenshots/feel3-font-lucida-grande-byheight.png      -byheight-2x.png
Mac/docs/reports/screenshots/feel3-font-lucida-grande-bywidth.png       -bywidth-2x.png
```

**The setting.** `defaults write com.yrambler2001.7zip FM.ListFont <key>` (next launch), key one of
`helvetica-neue-byheight`, `helvetica-neue-bywidth`, `sf-pro-byheight`, `sf-pro-bywidth`,
`arial-byheight`, `arial-bywidth`, `lucida-grande-byheight`, `lucida-grande-bywidth`, or any
`<PostScript name>:<size>` (`system:12`, `Arial:12.5`); `defaults delete … FM.ListFont` returns to
Helvetica Neue 11, which stays the default. It sets `PanelMetrics.listFont`, i.e. the list, header,
status bar, address bar, toolbar labels and (through `DialogMetrics.font`) the dialogs. Row height,
columns and margins stay Windows' (19 / 24 / 100 px …). `Panel/PanelListFont.swift`;
`Feel3Tests.testListFontSetting`; the images come from `Feel3FontTests`. Segoe UI itself cannot be
bundled (Microsoft's font licence).

## 5. Context menu ▸ 7-Zip ▸ Open archive (finding 5)

`CZipContextMenu::InvokeCommand` kOpen (ContextMenu.cpp:1264-1275) runs
`MyCreateProcess(Get7zFmPath(), "\"<first item>\" [-t<type>]")`: a **new 7zFM** process. Every
other verb of that menu runs 7zG (Extract, Add, Test, CRC) or works in place, and the File menu's
Open (540, Enter) and Open Inside (541) bind the same panel. So only kOpen and its "Open archive ▸
<type>" sub-menu change: they now open the first operated item in a new File Manager window with the
type hint, exactly as Finder / `7zFM <path>` does (`CommandExecutor.openInFileManager`,
newwindow.md); the invoking panel stays where it was. `Commands/PanelContextActions.swift`;
`Feel3Tests.testContextOpenArchiveOpensANewWindow`, `PanelGapsTests.testOpenArchiveVerbOpensANewWindow`.

## 6. The address drop-down (finding 6)

Measured (`addr-dropped.png`, `addr-hover4.png`): the list is the combo's width, right under it, a
1 px (0,120,215) border, white, **18 px rows** (`LB_GETITEMHEIGHT` 18; NSComboBox's were ~17 and
text-only), each row a 16 px **icon** at 4 + **10 px per level** from the list's edge, 1 px below the
row's top, the name 20 px after the icon's left edge with its baseline 14 px down; nothing selected
on opening (`CB_GETCURSEL` −1); **the row under the mouse highlighted** (0,120,215) from 2 px inside
either edge, white text, the icon blended 50 % (ILD_SELECTED), a dotted focus rectangle; the
highlight follows the mouse (`CB_GETCURSEL` 1, then 4).

NSComboBox's own list can do none of that, so the arrow now opens `Panel/PanelAddressPopup.swift`:
a borderless child panel with those metrics, icons from `AddressDropdown.icon(for:)` (the volume
for "/", the real folder icons, 7-Zip's icon for an archive component, a folder inside an archive,
Documents, Computer, the volumes), the list font, legacy scroll bar past 30 rows. A click picks
(binds at once and focuses the list, CBN_SELENDOK), Up / Down move the highlight and Return picks it,
Esc, a click elsewhere or the window losing key closes it; Option+Down (Alt+Down) opens it from the
edit. Each row is an accessibility element named after its entry (`address-dropdown-<i>`).

`Feel3Tests.testAddressDropdownRowsIconsAndPick`; `ListFeelInputTests.testAddressDropdownPickNavigates`
clicks the arrow and an entry with the real mouse. Paired: `wincompare-feel3-addrlist-{win,mac}.png`.

## 7. The address text shifts right when clicked (finding 7)

The same bezel inset as §2: the cell gave the field editor `textRect` both through
`drawingRect(forBounds:)` and again through its `edit`/`select` overrides, and NSComboBoxCell adds
its own inset, so the edited path sat **4 pt right** of the drawn one (measured: ink at x 24 drawn,
28 edited). The overrides are gone and the editor's rect is moved back by the measured inset
(`AddressComboCell.editorShift`). `Feel3Tests.testAddressTextDoesNotMoveWhenEdited` (x and y equal
before and after the click).

## 8. Archive icons (finding 8)

7zFM asks the shell for an icon by extension (ShowRealFileIcons off), and the shell answers with
the `DefaultIcon` 7-Zip registers, `7z.dll,<index>` — frame `<index>` of
`CPP/7zip/Archive/Icons/*.ico`. `icons-assoc.txt`: on the PC all 40 extensions are registered to
`7-Zip.<ext>` with their icon. (12 of them — bz2, cpio, gz, iso, tar, tbz2, tgz, txz, tzst, xar,
xz, zst — still showed a plain document there, because Windows 11's own per-user defaults override
the ProgID; that is a property of that PC, not of 7-Zip.)

`Panel/PanelArchiveIcons.swift` shows the same frames: the 27 upstream `.ico` files are bundled
unchanged as `Mac/Resources/Icons/fm-<name>.ico`, the extension → icon mapping is
`FileTypes.all` (string resource 100); 16 pt in Details / Small Icons / List (the 16 px frame, the
32 px frame on Retina), 32 pt in Large Icons (the 32 px frame), for file-system and archive items and
the address bar's archive icon; other extensions keep the system icon. The Large Icons grid is now
Windows' 75 × 75 icon spacing and the icon views' labels use the list font.
`Feel3Tests.testArchiveIconsPerExtension`. Paired: `wincompare-feel3-icons-{details,large}-{win,mac}.png`.

## 9. recheck2 leftovers and the user's two decisions

* **Hover selection and slow-click rename in Large Icons, Small Icons and List**
  (`PanelCollectionView`): the Details rules of recheck2 §5 — a click on the label of the only
  selected, focused item starts the rename after the double-click time (a drag or a second click
  cancels it), and the rename is **in place** in the item's label (was the Rename dialog); with
  Single-click on, the hand cursor over an item and selection after 0.4 s.
  `Feel3Tests.testIconViewsSlowClickRenameAndHover` (all three modes).
* **Hash results' item info** is IDD_EDIT_DLG (`TextViewerDialog`, the CEditDialog port): the name
  as the title and the value as the text, or the row's text with no title in a one-column list
  (ListViewDialog.cpp:207-215).
* **Ctrl+Space** (toggle the focused item's selection, focus stays) is **Option+Space**; Ctrl+Space
  works too when macOS lets it through (matched by key code, since Option+Space types U+00A0).
  `Panel/PanelKeys.swift`; `Feel3Tests.testOptionSpaceTogglesTheFocusedItem`; `parity.md` §C.
* **Inactive panel selection**: unchanged, Windows' (nothing drawn); recorded as final in
  `selcolors.md`.

## 10. Verification

All with `DEVELOPER_DIR=/Applications/Xcode.app`.

| run | result |
|---|---|
| `Mac/scripts/build.sh` | exit 0, no warnings in `Mac/` |
| `Mac/scripts/test.sh` | 388 passed, 0 failed |
| `Mac/scripts/test.sh -H` | 235 passed, 0 failed after the two expectation updates (`PanelGapsTests` Open archive → new window, `RecheckTests` tab chain names `WinComboBox`) |
| `Mac/scripts/test.sh -u` | probe1 6 / 0, probe2 6 / 0; input shard 52 / 0 on its re-run (§10.1) |

### 10.1 UI suite

The first `-u` run lost the input shard to the known "Timed out while enabling automation mode"
(`uiverify.md`) before any test ran, while both probe shards passed (6 + 6). The input shard alone
(`test.sh -t 7-ZipUITests`) then passed **52 / 0**, including `ListFeelInputTests.testAddressDropdownPickNavigates`
with the new drop-down (real mouse on the arrow and on an entry).

## 11. Files

| change | files | owner |
|---|---|---|
| Get Info | `Panel/PanelFinderInfo.swift` | panel |
| combos | `Support/WinCombo.swift` (new), `Support/RcLayout.swift` (`WinPopUpButtonCell`), `Dialogs/{ComboDialog,CopyMoveDialog,CompressDialog,ExtractDialog,LinkDialog,SplitDialog}.swift` (`WinComboBox`) | shared / dlgfeel, panel, compress, extract, tools |
| scroll bars | `Support/WinScrollView.swift` (new); `Panel/PanelViewController.swift`, `PanelListViews.swift`; `Dialogs/{ListViewDialog,HashResultsDialog,ToolsTempFilesDialog,OptionsWindow,ProgressDialogSupport,BenchmarkDialog}.swift` | panel, tools, options, opsinfra |
| font | `Panel/PanelListFont.swift` (new), `Panel/PanelMetrics.swift` | panel |
| Open archive | `Commands/PanelContextActions.swift` | panel |
| address bar | `Panel/PanelAddressPopup.swift` (new), `PanelAddressBar.swift`, `PanelAddressDropdown.swift`, `PanelNavigation.swift`, `PanelListViews.swift`, `PanelViewController.swift` | panel |
| archive icons | `Panel/PanelArchiveIcons.swift` (new), `PanelIcons.swift`; `Mac/Resources/Icons/fm-*.ico` (27 upstream files, new) | panel, icons |
| icon views | `Panel/PanelListViews.swift`, `PanelOperations.swift`, `PanelMenuCommands.swift` | panel |
| hash item info | `Dialogs/HashResultsDialog.swift` | tools |
| Option+Space | `Panel/PanelKeys.swift` | panel |
| tests | `Tests/AppTests/Feel3Tests.swift`, `Feel3FontTests.swift` (new); `PanelGapsTests.swift`, `RecheckTests.swift`, `UITests/ListFeelInputTests.swift` | harness |
| docs | `docs/parity.md` (one row), `docs/reports/selcolors.md` (decision note), `docs/requests.md` | — |
| measurements | `docs/reports/feel3-data/` | — |

Nothing outside `Mac/` was touched.

## 12. The Windows machine

`HKCU\Software\7-Zip` exported to `%TEMP%\szcmp\reg-backup.reg` before the step (copy in the session
scratchpad), deleted before each part, and at the end deleted and re-imported (`FM\Panels` read back
as before). Every 7zFM window and the Add to Archive dialog were closed by the step; no 7zFM / 7zG
process was left. The scheduled task `sz_cmp` and `%TEMP%\szcmp` (fixtures, scripts, output) were
deleted. Only `%TEMP%\szcmp` was written to.

## 13. Left open

* The user's font choice (§4); the default is unchanged until then.
* Finder Get Info needs the manual check of §1 (Automation cannot be granted unattended here).
* The dropped list of a *dialog* pop-up is still AppKit's menu (it opens over the box, not under
  it); the closed box is Windows'.
* The Large Icons label does not wrap to two lines as LVS_ICON does for long names.
