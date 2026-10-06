# `listfeel`: the main window's list, measured against a fresh-default 7zFM 26.03

> **Publication note:** this report was written when it lived in `Mac/docs/reports/`. Its raw capture data (`*-data/`) and its screenshots were removed from the repository before publication; a few showcase images live on in `docs/images/`, and the tests now write their screenshots to the git-ignored `Mac/build/screenshots/`. Paths below that point into removed material are kept as a record of what was measured.

Branch `mac/listfeel`, off `macos` at `8d3064d`, 2026-10-04. Scope: the panel's list, header,
address bar, toolbar button, Properties (`panel`'s files), plus the few lines in other scopes
listed in §12.

## 1. How it was measured

**Reference.** `ssh windows-host`: Windows 11, 1920×1080 at 96 DPI, **7-Zip 26.03**, the version this
port is built from. One Windows pixel maps to one macOS point.

**Fresh default.** Every script deletes `HKCU\Software\7-Zip` before it starts 7zFM. The key was
exported to `%TEMP%\szcmp\reg-backup.reg` first and re-imported at the end (§13).

**Harness.** `listfeel-data/harness/` is the `wincompare` harness (a PowerShell step run in the
interactive session by the scheduled task `sz_cmp`), extended with these readers:

- `ListGeom` reads every rect of the list: `LVM_GETITEMRECT` (bounds, icon, label and select
  bounds), `LVM_GETSUBITEMRECT`, `HDM_GETITEMRECT` and `LVM_GETSTRINGWIDTH`. It also reads the list
  and header fonts (`WM_GETFONT` → `LOGFONT`) and the list styles.
- `SysFonts` reads the system metrics.
- Raw mouse input: `Down`, `MoveTo` and `Up`.

**Steps.**

| step | what it measures | output |
|---|---|---|
| `wrun.sh lf1` | geometry, fonts, header menus, toolbar hover and pressed, the address drop-down, Properties in 7 states | `win1/` |
| `wrun.sh lf2` | the rubber band with real mouse drags (6 starting points, FullRow off and on), captured from the screen while the button is held | `win2/` |
| `wrun.sh lf3` | the Windows halves of the paired captures | `win3/` |

**Pixel tool.** Distances in the captures were read with a small CGImage tool: colour runs along a
row or column, and bounding boxes by colour. They were not judged by eye.

**macOS side.** The app-hosted test `Mac/Tests/AppTests/ListFeelTests.swift` (13 cases) renders the
real panel and measures the same distances. For example, it finds the selection fill by its colour
and the text by its ink.

## 2. The list: geometry, font, columns

| item | Windows 26.03 (px) | macOS before (pt) | macOS now (pt) | source of the Windows value |
|---|---|---|---|---|
| row pitch | **19** | 22 (rowHeight 20 + intercell 2) | **19** | LVIR_BOUNDS height |
| header height | **24** | 28 (AppKit default) | **24** | SysHeader32 window rect |
| icon | x **4**, 16×16, **1** below the row top | x 5, centred | x **4**, top **1** | LVIR_ICON, ink rows 173-188 in row 172-190 |
| label / fill start | x **20** | 23 | **20** | LVIR_LABEL |
| name text origin | label + **2** (ink at +3) | field at 25 | label + 2 (ink at +2.5) | ink x 33 for label 30 |
| other columns' text | **6** from the aligned edge | 3 + 2 | **6** (ink 6 ± 1) | date ink 266 in column 260-360; size ink ends at 254 in 160-260 |
| text vertical | 'b' 5 below the row top, baseline 14 | centred 13 pt | 5 / 14 (± 1) | b.bin ink rows 196-204 in row 191-209 |
| list font | **Segoe UI 9 pt** (height −12, weight 400), tabular digits | SF 13 pt, proportional digits | **Helvetica Neue 11 pt**, tabular digits | WM_GETFONT of the list and the header |
| "a.txt" / "vol.7z.001" / "2024-01-15 11:30" | 22 / 51 / 88 | 26.7 / 61 / 107 | 21.6 / 50.1 / 88.1 | LVM_GETSTRINGWIDTH, ink |
| header text | 6 from the aligned edge | 3 | 6 (ink 6-7) | "Name" ink at 7, "Size" ends at 253 |
| sort arrow in the header | **none** | AppKit triangle and highlighted column | none | no HDF_SORTUP / HDF_SORTDOWN anywhere in FileManager/; capture |
| Name column | **160** | 160 | 160 | GetColumnWidth, LVM_GETCOLUMN |
| time columns | **100** | 120 | **100**, and the date fits | the same |
| raw (hex) columns | **100** | 160-470 | **100** | GetColumnWidth(propID, VT_BSTR) |
| every other column | **100** | 100 | 100 | the same; FS, 7z, zip folders (`win1/*.txt`) |

**Why Helvetica Neue.** macOS has no Segoe UI. The user asked for the closest family and size,
with tabular digits. I measured the candidates against the PC's advance widths:

| font | "a.txt" | "vol.7z.001" | date | tabular digits |
|---|---|---|---|---|
| SF Pro 11 | 23.2 | 52.6 | 92.8 | no |
| SF Pro 11, monospaced digits | 23.2 | 55.8 | 100.9 | yes |
| SF Pro 11, condensed | 19.5 | 42.8 | 72.0 | no |
| Arial 12 | 22.7 | 54.7 | 93.9 | no |
| **Helvetica Neue 11** | **21.6** | **50.1** | **88.1** | **yes** |

Helvetica Neue 11 matches every one of them to within a pixel. That is why a date fits the
100 pt default width exactly as it does on Windows, and why "1 234" and "100 000" right-align
digit for digit. SF with monospaced digits needs 101 pt for the date. That is what cut the dates
with the old 13 pt font even at 120 pt (user finding 10).

**Files.** `PanelMetrics.swift` (new) holds every number in the table. It is used by:

- `PanelViewController.loadView`: row height, gap, header.
- `PanelListViews.swift` `makeListCell`: cell layout.
- `PanelHeaderCell`: header margins.
- `PanelLogic.swift` `defaultWidth`: widths.
- `updateSortIndicator`: no arrows.

The name's text field is now exactly as wide as its text. That is the item's hit area (§6), and it
is what VoiceOver and XCUITest click. During an F2 rename the field spans the column again.

## 3. The selection fill's padding (user finding 2)

| item | Windows (px) | before (pt) | now (pt) |
|---|---|---|---|
| fill of "a.txt" | x 20-50, **30 wide**, the full 19 rows | 23-52, 2 before the text, about 2 after it | x 20-50, **30 wide**, 19 high |
| fill before the text ink | **3** | 2 | 2.5 |
| fill after the text | **6** after the advance (the ink ends at the advance) | about 2 | 6 after the advance (7 after the ink: Helvetica's 't' has 1-2 pt of side bearing) |

The rule is LVIR_LABEL clipped to the text: start at the label, 2 px, the text, 6 px, never past
the column (`PanelMetrics.labelFill`). `PanelRowView` and the rubber band's hit test use it.

## 4. Properties (Info) (user findings 3 and 4)

### 4.1 Outside an archive: Finder's Get Info

`CPanel::Properties` (PanelMenu.cpp:171-180) sends any folder without `IGetFolderArcProps` to
`InvokeSystemCommand("properties")`. That function (PanelMenu.cpp:58-76) acts only for the file
system or the drives list and only when something is operated. It then invokes the shell's
"properties" verb, which opens the Windows property sheet.

`PanelFinderInfo.swift` (new) does the macOS equivalent:

| folder | operated | Windows | macOS now (`FinderInfo.route`) |
|---|---|---|---|
| inside an archive | any | the 7-Zip list | the 7-Zip list |
| file system or volumes | 1 or more | the shell's property sheet | Finder **Get Info**, one window per item, at most 20 |
| file system | none (also `..`) | nothing | nothing (before: the 7-Zip list) |
| root (Computer) | any | nothing | nothing |

**The event.** It is `open` (`aevt/odoc`) of `information window` (`iwnd`) of each file URL, sent
to `com.apple.finder` and followed by `activate`. It is sent from a background queue with
`.waitForReply` and a 120 s timeout, so a consent prompt or a busy Finder never blocks the app.

**The checks.** `AEDeterminePermissionToAutomateTarget` (without asking) runs first. A recorded
refusal (−1743) goes straight to the fallback. Any failure of the send also shows the **7-Zip list
dialog** instead: the user denied Automation, Finder is not running, or the send timed out.

**Info.plist.** `NSAppleEventsUsageDescription` was added to `Mac/App/Info.plist`, which the
`finder` scope owns, and to its test copy `Mac/Tests/AppVariants/Info.plist`.

**Under tests.** Under XCTest, `SEVENZIP_UITEST` or the test-support contract, `FinderInfo.sender`
is a stub that answers "denied". No event is ever sent, and no consent prompt can sit over the
suite.

**What the tests cover.** They cover the routing table and the specifier. They check that a `.shown`
answer opens no 7-Zip window and that `.denied` opens the "Properties" list. They also check that
nothing operated does nothing (`ListFeelTests`, `InfoHangTests`).

**Manual check** (Automation cannot be granted on this VM):

1. Select two files in a folder and press Info.
2. macOS asks once: "7-Zip wants to control Finder". Allow it, and two Finder Get Info windows
   open in front.
3. In System Settings › Privacy & Security › Automation, turn 7-Zip › Finder off. Info now opens
   the 7-Zip Properties list.
4. Inside an archive, Info always opens the 7-Zip list.

### 4.2 Inside an archive: rows and columns

7zFM's rows, from `win1/dlg-prop-7z-{file,folder,multi,multi2,none,subfile}.txt` and
`dlg-prop-zip-file.txt`, against what the port showed before:

| block | 7zFM 26.03 | before | now |
|---|---|---|---|
| one item | every folder property, **`kpidIsDir` included** ("Folder -" in a zip); VT_BOOL false is "-" | IsDir skipped | as 7zFM |
| several items | `"" / "N object(s) selected"`, then Folders (each folder + its NumSubDirs) and Files (NumSubFiles) when ≠ 0, then Size and Packed Size | blank row, then Size, Packed Size, Folders, Files; no count row; folder contents not counted | as 7zFM |
| separators | `------------------------` in the name column (kSeparator), `----------------` between levels | empty rows | as 7zFM |
| folder block | GetFolderProperty(kpidPath) **named "Name"** ("Name sub\\" in a sub-folder, absent at the root), then IFolderProperties (Size, Packed Size, Folders, Files, CRC) | a fixed list (Type, Path, ReadOnly, …) | as 7zFM; new bridge `SZFolder.folderPropertyInfos` |
| archive level | separator, kSpecProps, handler properties (Path, Type, Physical Size, Headers Size, Method, Solid, Blocks) | a "----Path 1----" title row first | as 7zFM |
| end | **two separators**: CAgent answers GetArcProp for the NonOpen level with S_OK | none | as 7zFM |
| trailing "ArcFileName" row | none | present | gone |
| values | AddPropertyString: sizes grouped, times at ns precision, error flags as their message | flags as a number | as 7zFM (`propertiesDialogString(...)`) |

The dialog (`ListViewDialog.swift`) now matches it too:

| item | 7zFM (px) | before (pt) | now (pt) |
|---|---|---|---|
| first column | LVSCW_AUTOSIZE: **80** (the 72 px separator + 8) | 200 | **80** |
| second column | LVSCW_AUTOSIZE: **326** (the path, 314, + 12) | 460, stretched | the widest value + 12, not stretched |
| row pitch | **17** | small row size (about 17-18), alternating colours | **17**, no alternating colours |
| text | 6 from the column's edge, Segoe UI 9 | 2, SF 11 | 6, Helvetica Neue 11 |
| header | 24, empty | AppKit default | 24, empty |

The separator counts as Windows' 72 px when the column is sized. It is then drawn clipped at the
column's edge, because the macOS hyphen is wider.

## 5. Column menu order (user finding 11)

7zFM's header menu lists `_columns`, which is the folder's property order, visible or not, whatever
order the header shows (ShowColumnsContextMenu, PanelItems.cpp:1396-1413). On the file system that
is (`win1/hdrmenu-fs.txt`):

> Name, Size, Modified, Created, Accessed, Metadata Changed, Attributes, Packed Size, iNode, Links,
> Comment, Folders, Files, Link

Before, the port had two differences:

- The menu followed the header order, with the hidden columns last.
- The macOS FS folder declared Mode, User, Group and Link in the middle of the list.

Now `PanelColumnsModel.propertyOrder` keeps the property order, and `menuColumns` feeds the menu.
`FSFolderMac.cpp` lists the Windows columns in the Windows order, then Link, then the macOS-only
Mode, User and Group. Archives use their handler's order, as on Windows (`hdrmenu-7z.txt`).

There is no separate "Columns" dialog in 7zFM 26.03 or in the port; the header menu is the column
chooser.

## 6. Rubber band (user finding 6)

Measured with real drags on 7zFM (`win2/fr*-*.txt` hold the item states during the drag;
`win2/fr*.png` are the screen while the button is held):

| drag starts on | FullRow off (default) | FullRow on |
|---|---|---|
| the icon or the name's text | item (select, drag) | item |
| the blank part of the name column | **rubber band** | item |
| a Size / Modified cell | **rubber band** | item |
| right of the last column | rubber band | rubber band |
| below the rows | rubber band | rubber band |
| what the band selects | rows whose **icon or label text** it touches (a band over Size / Modified selects nothing) | rows whose **full row** it touches |
| how it looks | dotted 1-on / 1-off XOR rectangle (DrawFocusRect) | the same |
| a click on the background | clears the selection | the same |

**Implementation.** `PanelTableView.mouseDown` asks `isOnItem(_:row:)`. The item rect is the icon
plus `labelFill`, or the full row up to the last column with FullRow. Anywhere else,
`trackRubberBand` takes over:

- The selection is cleared unless Cmd or Shift is held.
- After the 4 px drag threshold (SM_CXDRAG / SM_CYDRAG = 4, measured) a dotted rectangle is drawn
  with `PanelSelectionStyle.drawFocusRectangle`.
- The rows the band touches (`rowsHit(by:)`) are selected live. Cmd toggles them against the
  previous selection (Ctrl on Windows); Shift adds them.
- The list autoscrolls.

A mouse-down on the item still goes to AppKit, so item drags, double-click and the context menu are
unchanged. The icon views, which are `NSCollectionView`s, keep AppKit's own band. AlternativeSelection
mode keeps its own click handling.

## 7. Toolbar pressed state (user finding 5)

`win1/tb-hover.png` and `tb-pressed.png` show the Info button with the mouse over it and then with
the button held. Every pixel column of the bitmap and of the label moves by **+1**, and **no row
moves**: the bitmap's rows are 6-23 and the label's 33-41 in both.

The user remembered "1 px down and right". That is the classic, unthemed comctl32 offset. The
Windows 11 theme 7zFM uses moves only right.

The port follows the measurement: `FMToolbarView.pressedOffset = (1, 0)`, applied to the bitmap and
the label while `isHighlighted` is set. `ListFeelTests.testToolbarPressedOffset` checks it from
rendered ink. If the down shift is wanted anyway, it is that one constant.

## 8. Address bar (user findings 26 and 27)

| item | Windows | before | now |
|---|---|---|---|
| focus ring | none | blue AppKit ring | none (`focusRingType = .none`); keyboard focus unchanged |
| drop-down contents | the path's components **by name**, each one indent deeper, then Documents, Computer, the drives (indent 1), Network (`win1/combo-dropped.txt`) | full paths of the components, then Documents, "/", volumes, **and 20 history entries** | names, indented, then Documents, Computer, the volumes (no Network on macOS); no history |
| a pick in the drop-down | navigates at once (CBN_SELENDOK, PanelFolderChange.cpp:803-822), list focused | only replaced the text; Return needed | a mouse pick navigates at once and focuses the list; arrow keys only move, and Return commits the highlighted entry's **path** |
| band height | 24 (ReBar) | about 32 | 24 |

`PanelAddressDropdown.swift` (new) builds the entries, and `addressDropdownPaths` is
ComboBoxPaths. `ListFeelInputTests.testAddressDropdownPickNavigates` clicks an entry with the real
mouse and sees the panel move with no Return (screenshot `listfeel-input-address-dropdown.png`).

## 9. One panel on a fresh start (user finding 24)

With the key deleted, 7zFM 26.03 starts with **one** list (`win1/log.txt`: `fresh lists=1`;
`kNumDefaultPanels = 1`, FM.cpp:127). The port's default is already 1 (`Settings.numPanels`, and
`ListFeelTests.testFreshDefaultIsOnePanel` checks it with the key removed).

The user's own domain `com.yrambler2001.7zip` has `FM.Panels.numPanels = 2`. That is a saved
choice: F9 or View › 2 Panels writes it, as 7zFM writes `Panels`. Run
`defaults delete com.yrambler2001.7zip FM.Panels.numPanels`, or press F9 once, to get one panel back.
No code change was needed.

## 10. Other things noticed and fixed

- **No sort arrow and no highlighted column in the header** (§2).
- **Header text margins:** 6 instead of 3 (`PanelHeaderCell`).
- **Address band height:** 24 (§8).
- **History left out of the address drop-down** (§8).
- **Properties:** the alternating rows and the stretched last column are gone (§4.2).

Things checked and found already matching:

- **Status bar:** 23 px, parts at 220 / 320 / 420 (`win1/fresh-fs.txt`), already the same.
- **Focus rectangle:** the dotted rectangle around the label (selcolors).

## 11. Paired captures

`screenshots/wincompare-listfeel-list-{win,mac}.png` and `-archive-{win,mac}.png` show the list's
top-left 760 × 200 at 1x, with the same files. `listfeel-01-selection.png` and
`listfeel-02-properties.png` are app-hosted renders. `listfeel-input-*.png` come from the input
shard.

The remaining visible differences are three:

- the glyph shapes (Helvetica Neue against Segoe UI, at the same advance widths);
- the file icons (Finder's against the shell's);
- the header's column separators (AppKit draws short ones, Windows full-height).

## 12. Files

**`panel` scope:**

- `Mac/App/Panel/PanelMetrics.swift` (new)
- `PanelAddressDropdown.swift` (new)
- `PanelFinderInfo.swift` (new)
- `PanelTableView.swift`
- `PanelListViews.swift`
- `PanelViewController.swift`
- `PanelLogic.swift`
- `PanelContextMenu.swift`
- `PanelNavigation.swift`
- `PanelOperations.swift`
- `PanelMenuCommands.swift`
- `PanelSelectionStyle.swift`
- `Mac/App/MainWindow/FMToolbar.swift`
- `Mac/App/Dialogs/PropertiesDialog.swift`
- `ListViewDialog.swift`

**Outside it** (all recorded in `requests.md`):

- `Mac/App/Info.plist` (`finder`): one key.
- `Mac/Tests/AppVariants/Info.plist` (`harness`): the same key, kept in step as its test requires.
- `Mac/Core/Internal/FSFolderMac.cpp` (`fsfolder`): `kProps` reordered.
- `Mac/Core/include/SZFolder.h` and `Mac/Core/SZFolder.mm`, additive:
  - `folderPropertyInfos`
  - `propertiesDialogString(forFolderProperty:)`
  - `SZArcProps.propertiesDialogString(atLevel:propID:answered:)` and `propertiesDialogString2`
- `Mac/Core/SZArchiveOpener.mm`: `SZOpenArcErrorFlagsMessage` is no longer `static`, so Properties
  can reuse it.

**Tests:**

- `Mac/Tests/AppTests/ListFeelTests.swift` (new, 13 cases)
- `Mac/Tests/UITests/ListFeelInputTests.swift` (new, 2 cases)
- updated: `PanelLogicTests` (widths, menu order), `SevenZipKitTests.testFileSystemFolder` (FS
  order), `NavGapsBridgeTests` (raw widths 100), `InfoHangTests` (nothing operated opens nothing)

Nothing outside `Mac/` was touched.

## 13. Verification

All runs used `DEVELOPER_DIR=/Applications/Xcode.app`, at the final code.

| run | result |
|---|---|
| `Mac/scripts/build.sh` | clean, no warnings in `Mac/` |
| `Mac/scripts/test.sh` (unit) | 388 passed, 0 failed |
| `Mac/scripts/test.sh -H` (app-hosted) | 158 passed, 0 failed (`ListFeelTests` 13) |
| `Mac/scripts/test.sh -u` (input shard + both probe shards) | 61 passed, 0 failed (`ListFeelInputTests` 2) |

Along the way: the first `-H` run failed `InfoHangTests` (it expected a dialog for Info with nothing
operated on the file system, where 7zFM opens none) and `HostTargetTests` (the variant Info.plist).
Both tests were updated, and four `SelColorsTests` failures were only the knock-on of the dialog
that test left up. Each passes alone and in the full run above.

## 14. The Windows machine

- **Registry:** `HKCU\Software\7-Zip` was exported before the first step; each step deleted it, and
  `lf2` set `FM\FullRow` for its second half. At the end the key was deleted and the backup
  re-imported. It has the same values as before (Path, Path32, Path64, FM with its history,
  columns and positions).
- **Windows:** every 7zFM window was closed by its step (`StopFM`). The item drags were cancelled
  with Esc before the button was released, so nothing was moved.
- **Cleanup:** the task `sz_cmp` and `%TEMP%\szcmp` were deleted. The backup is not committed,
  because it holds the user's history.
