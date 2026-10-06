# `datecols`: whole dates, sizes and headers in SF Pro 12.2; the status bar's time as 7zFM

> **Publication note:** all but a few showcase images under `docs/reports/screenshots/` were removed from the repository before publication. Paths below that point into them are kept as a record of what was measured.

Branch `mac/datecols`. The orchestrator found three defects in sffont's `sffont-main.png`: dates cut
("2024-11-28 21:5…") in Modified and Created at the default width, a status bar time ending in "Z",
and asked for anything else clipped under SF Pro 12.2.

## 1. Why the dates were cut, and why the status bar said "Z"

Both came from one cause. `PanelWindowlessErrorTests` toggles View > Time > UTC through
`MainWindowController.viewTimeUTC` (which sets the engine's `g_Timestamp_Show_UTC`), then restores
only `Settings.timestampShowUTC`. Every list drawn later in the same test process printed UTC, so
sffont's screenshot showed "2024-11-28 21:58Z". That string is 119 pt in the tabular-digit font,
the text field of a 123 pt column is 117 pt, so the "Z" cut it. Without the "Z" the date (111 pt) fit,
which is why sffont's own test passed when it ran on its own.

Fixes:

* `Settings.timestampShowUTC`'s setter now sets `SZFolder.timestampShowUTC` too, so the engine global
  can never differ from the setting (`DateColsTests.testTheUTCSettingDrivesTheEngine`).
  `SFFontTests` also pins View > Time to minutes / local time for its images.
* A time column's default width is no longer a fixed "2024-01-15 11:30". It is the widest date
  that the current View > Time level prints (ConvertUtcFileTimeToString2: day, minutes, seconds, 7 or
  9 fraction digits, plus "Z" with UTC). It is measured the way a list cell's `NSTextField` needs it in
  `listDigitsFont`, plus Windows' 6 px on each side, and is never below 100
  (`PanelMetrics.timeColumnWidth(level:utc:)`):

  | level | local | UTC |
  |---|---|---|
  | day | 100 | 100 |
  | minutes (default) | **123** | 131 |
  | seconds | 142 | 150 |
  | NTFS (7 digits) | 199 | 207 |
  | NS (9 digits) | 215 | 223 |

* When View > Time changes, a time column still at the previous default takes the new one.
  A width the user chose is kept (`PanelViewController.followTimeColumnDefault`).
  A stored layout whose time column is at any level's default, or at the old 100, loads at
  today's default (`PanelColumnsModel.timeWidthDefaults`).

## 2. Sizes and the status bar

* **Size columns.** `Formatting.sizePropIDs` (Size, Packed Size, Total Size, Free Space, ...) start at
  `PanelMetrics.sizeColumnWidth`, which is "9 999 999 999 999" (9.99 TB, 113.5 pt) + 12 = **126**.
  Windows' 100 px holds "99 999 999 999" in Segoe UI 9. A stored size column at the old 100 loads at
  126. Folders, Files and the other numeric columns keep 100: their realistic values ("99 999 999",
  CRC "FFFFFFFF", 56 pt) fit.
* **Status bar time, 7zFM 26.03.** OnRefreshStatusBar (PanelListNotify.cpp:800-822) prints the
  focused item's kpidMTime with `ConvertPropertyToShortString2(dateString2, prop, kpidMTime)`. That
  is the default level 0, which means **seconds**, whatever level the list uses. The time is local
  unless `g_Timestamp_Show_UTC`, and "Z" is added only then (PropVariantConv.cpp:31-41, 129-133). The
  port showed the list's own cell (minutes) instead. Each row now carries `statusTime`, which the
  engine formats at `SZTimestampLevel.sec` on the panel queue (the list cell is reused when the list
  level already is SEC). The status bar now reads "2024-11-28 23:58:00".
* **Status bar parts.** SetParts {220, 320, 420, -1} gave the size parts 98 pt, too narrow for
  "9 999 999 999 999" in SF Pro 12.2 (114.5 pt). The two size parts now follow the font
  (`PanelMetrics.statusSectionEdges` = [220, 341, 462] in SF Pro 12.2, never narrower than
  Windows' 100 per part). Part 0 still ends at 220.

## 3. Also found: every table header drew in 11 pt

`NSTableHeaderCell` ignores its `font`: it draws `stringValue` in the system's 11 pt header font.
The header view also resets `font` to that 11 pt font when the cell is installed. On screen, "Modified"
in the main list's header was 44 pt of ink, not the 50 pt of SF Pro 12.2, so sffont's "header in
the list font" held only for the property. New `Support/WinHeaderCell.swift` gives the title an
attributed string in `titleFont` before it draws. It is the base of `PanelHeaderCell` (main list) and
is installed on the Options lists (`OptionsUI.column`), the temp-files list and the Messages list
(`DialogMetrics.font`). The main header's baseline stays where recheck put it (RecheckTests green).

The other sffont images (Add to Archive, Extract, Options pages 2-6) were looked at and show nothing
else clipped or misaligned.

## 4. Tests

New `Mac/Tests/AppTests/DateColsTests.swift` (7 tests):

* `testEveryDefaultWidthCellShowsTheWidestValueWhole`: covers a fresh file-system list and a 7z
  archive, at all five levels, local and UTC (20 runs). Every visible column must be at its default
  width. Every real cell must be drawn whole. Then each time / size cell is given its widest value
  ("2024-12-31 23:59:59.123456789Z" from a DateFormatter, independent of `widestDate`; "9 999 999 999 999")
  and must be drawn whole. *Drawn whole* means the real cell's text field, rendered, is pixel-identical
  to a copy that clips instead of truncating, and AppKit's `expansionFrame` reports no truncation.
* `testTheCheckSeesATruncatedCell`: the same check fails for a column 1 pt too narrow.
* `testStatusBarShowsTheTimeWithSecondsInLocalTime`: the status bar shows seconds in local time,
  with "Z" only under UTC, and keeps seconds at the day level. The list shows minutes.
* `testStatusBarPartsHoldTheWidestValues`, `testTheUTCSettingDrivesTheEngine`,
  `testTimeColumnsFollowTheLevelButKeepAUserWidth`, `testHeadersDrawInTheListFont` (header ink width).

Updated: `SFFontTests` (time width from the level's widest date, no "Z", View > Time pinned),
`ListFeelTests` (size columns 126), `NavGapsTests` (status edges from `PanelMetrics`).

## 5. Verification

* `Mac/scripts/build.sh`: exit 0, no warnings in `Mac/`.
* `Mac/scripts/test.sh`: 388 passed, 0 failed.
* `Mac/scripts/test.sh -H`: 250 passed, 0 failed (243 + the 7 new ones).
* `Mac/scripts/test.sh -u`: 63 passed, 1 failed (input 51/52, probe1 6/6, probe2 6/6). The one
  failure, `PanelTests.testCopyBetweenPanels` ("right panel: []", an empty accessibility snapshot),
  was a flake: run alone, `PanelTests` failed once more in a different test (`testCreateFolderAndDelete`,
  also an empty listing), then passed 10/10.
* Regenerated and looked at: `screenshots/sffont-main.png` (dates whole, Size 126, status bar
  "2024-11-28 23:58:00", header in SF Pro 12.2) and `screenshots/sffont-options.png` (list header in
  SF Pro 12.2). The fixture's 22:58 file shows 23:58 because the engine, like Windows'
  FileTimeToLocalFileTime, converts with the offset in force now (CEST), not November's.

## 6. Cross-scope edits (for the orchestrator)

`panel`: `PanelMetrics.swift`, `PanelLogic.swift`, `PanelRow.swift`, `PanelViewController.swift`
(`statusSections` is now internal for the tests). `options`: `Support/Settings.swift` (the UTC
setter), `Dialogs/OptionsWindow.swift`. `tools`: `ToolsTempFilesDialog.swift`. `opsinfra`:
`ProgressDialogSupport.swift`. New `Support/WinHeaderCell.swift`. `harness`: the test files in §4.
Nothing outside `Mac/`.

## 7. Known gaps

* Per-folder-type column widths are shared by every panel showing that type (as on Windows), so the
  last panel to save wins. A level change resizes the default-width columns in every open panel.
* Dialog table columns with Windows' fixed widths (Options › System 80 / 152, Hash results, Properties)
  are unchanged; long values there still truncate with an ellipsis, as in sffont.
* A size above 9.99 TB, or a 5-digit year, still cuts at the default width (as Windows' 100 px does
  from 100 GB).
