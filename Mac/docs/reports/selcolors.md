# `selcolors`: selected rows unreadable in Light, and selection drawn as 7zFM draws it

Branch `mac/selcolors`, off `macos` at `47d023c`, 2026-10-03. Scope: `panel` (the list's drawing),
plus tests. The user's report, for the Release build in the Light appearance: "When I select items
in the list, the column details become transparent (white)." The user also asked for the
selection to look like the Windows 7-Zip File Manager.

## 1. Reproduction and root cause

**Repro.** I used Details view, Light appearance, "Full row select" off (the default), and selected
any row while the list had the keyboard focus. The Name cell was white on blue. Size, Modified,
Created and the other columns were **white on the white list**, so they were invisible. With
"Full row select" on, or in Dark, nothing looked wrong: in Dark, white text on the dark list is
readable.

I measured this on the old code with a temporary app-hosted test. It rendered row `b.bin`
selected, with the emphasized style a key window gives, and read the pixels back:

| appearance | FullRow | Name | Size, Modified, Created |
|---|---|---|---|
| Light | off | white on (0,100,225), 5.4:1 | **white on white, 1.0:1** |
| Light | on | white on blue, 5.4:1 | white on blue, 5.4:1 |
| Dark | off | white on blue, 6.3:1 | white on (30,30,30), 16.7:1 |
| Dark | on | white on blue | white on blue |

**Root cause** (`PanelTableView.swift`, `PanelRowView`):

1. With FullRow off, `drawSelection` filled only the name column, to mimic 7zFM. But AppKit still
   gives every cell of a selected row in a key window `backgroundStyle = .emphasized`.
2. Under that style, a text field whose colour is `labelColor` draws white, whatever is behind it.
3. So the columns outside the fill were white on white. The cells' colour was not wrong as such;
   AppKit's "emphasized" background style was applied where no emphasized background was drawn.

The icon modes had a smaller version of the same problem. Their labels were `labelColor`, which is
black, on a full-item fill in `selectedContentBackgroundColor`. That is about 3.4:1 in Light, below
WCAG AA.

## 2. 7zFM 25.01 on Windows, measured

I captured on `ssh windows-host` (Windows 11, 96 dpi, 7-Zip 25.01), using the `wincompare` mechanism:

- **Harness:** `selcolors-data/harness/sel.ps1` (`wrun.sh sel`) drives 7zFM.
- **Configurations:** every combination of FullRow and ShowGrid (`HKCU\Software\7-Zip\FM`).
- **States:** single, multi and focus-only selection; a hovered row; an inactive window (the taskbar
  takes the foreground); an inactive panel (two panels, then Tab); Large Icons, Small Icons and List.
- **Data:** 61 files in `selcolors-data/win/`. Each `.png` is a PrintWindow capture. Each
  `.rects.txt` holds the LVIR_LABEL rect and state of every item. `syscolors.txt` holds the
  GetSysColor values.

I read the colours from the captures with a pixel histogram:

| what | 7zFM | source |
|---|---|---|
| selection fill | **(0,120,212)**, which is COLOR_HIGHLIGHT | every capture, 12 210 px of the full-row row |
| text on the selection | **(255,255,255)**, which is COLOR_HIGHLIGHTTEXT | ClearType fringes aside |
| selected item's icon | blended 50 % with the highlight (ILD_BLEND50): grey 173 becomes (86,146,192) = ½·173 + ½·(0,120,212) | `fr0-g0-details-multi` vs `-focusonly` |
| FullRow **off** | only the **label** is filled: the name's text plus about 2 px each side, after the icon. The other columns keep black on white. | `fr0-g0-details-multi` |
| FullRow **on** | filled from the label (after the icon) to the end of the row | `fr1-g0-details-multi` |
| focus rectangle | dotted, 1 px on and 1 px off, XOR. On white the dots are (0,0,0); on the highlight they are (255,135,43). It goes around the label, or the whole full-row fill. | `*-focusonly`, the `c.txt` row in `*-multi` |
| list without the keyboard focus (inactive panel, inactive window, address bar) | **no selection drawn at all**. Panel.cpp:391 has `LVS_SHOWSELALWAYS` commented out. The status bar still says "2 / 5". | `fr0-g0-details-inactivepanel`, `-inactivewindow` |
| grid lines (ShowGrid) | 1 px (240,240,240) | `fr0-g1-*`, `fr1-g1-*` |
| hover | nothing: hot tracking is only on with "Single-click" (LVS_EX_TRACKSELECT) | `*-hover` |
| icon modes | the icon blended, only the label's text box filled, white text. The focus rectangle goes around the label. | `*-large-*`, `*-small-*`, `*-list-*` |

The list is a plain SysListView32 with no Explorer theme. That is why the highlight is the classic
system colour, and not the light-blue Explorer selection.

## 3. What changed

**`Mac/App/Panel/PanelSelectionStyle.swift` (new).** It holds the measured colours with their
sources. It also holds `blended(_:)`, which is ILD_BLEND50: the icon's opaque pixels are half icon
and half highlight. It draws the dotted focus rectangle.

**`PanelCellView`, also new, is the Details cell.** It **refuses `.emphasized`**: its
`backgroundStyle` setter always stores `.normal`. It takes its colours from the panel's rule
instead:

- `highlightText` when its part of the row is filled;
- otherwise `labelColor`, or `systemRed` for kpidIsDeleted rows.

The name cell swaps to the blended icon.

**The rule** (`PanelViewController.listHasKeyboardFocus`, `cellIsHighlighted(row:isName:)`):

- The fill is drawn when the row is selected, the window is key, and its first responder is this
  panel's list (the table or the icon view). That is the equivalent of `GetFocus()`.
- A drop target row is always filled (LVIS_DROPHILITED).
- The name cell is always covered by the fill; the other cells only with FullRow.

**`PanelRowView`:**

- `drawSelection` fills the label rect, measured from the real name text field, or the full row
  from the label on. It fills nothing while the list is unfocused.
- `drawDraggingDestinationFeedback` uses the same fill.
- The focus rectangle is drawn for the focused row, selected or not, over the fill, in the XOR
  colours.
- The cells are re-coloured when the row's selected, emphasized or drop state changes, and when a
  cell is added.

**Focus tracking:**

- `PanelTableView` re-colours on first-responder changes and on its window's
  `didBecomeKey` / `didResignKey`.
- `PanelCollectionView` re-colours on first-responder changes too.
- A change of `focusedIndex` re-colours, and so does a FullRow change (`applyListSettings`).

**Icon modes (`PanelCollectionItem`):**

- The icon is blended, and the label's text box is filled with white text.
- The focus rectangle goes around the label.
- The item redraws on a selection change, a highlight-state change (drop target) and a focus
  change.

**Grid lines:** `tableView.gridColor` is (240,240,240).

**AlternativeSelection pink** (RGB 255,192,192, 01 §3.6) has a dark variant (120,48,48). In Dark
the text is white, and white on the light pink is 1.4:1.

**Dark mode** has no Windows reference, because 7zFM has no dark theme. I kept the same highlight
and white text: white on (0,120,212) is 4.53:1, which passes WCAG AA, and the selection then looks
the same in both appearances. The grid becomes 12 % white. The focus dots on the list background
use `labelColor`, which is white in Dark.

**Decision final (the user, 2026-10-05, recorded by `mac/feel3`):** the inactive panel keeps the
Windows behaviour below -- no selection drawn -- and is not to be changed.

**One deliberate behaviour change, from parity:** an inactive panel and a window in the
background now show **no** selection, exactly as 7zFM 25.01 does. Before, macOS showed a grey
"unemphasized" selection. The status bar still counts the selection, and it comes back with the
focus. To revert, `PanelRowView.drawsHighlight` and `PanelCollectionItem.drawsHighlight` would
draw an unfocused fill instead of nothing.

Paired captures (Light, 760×140 at 1x) are in `screenshots/wincompare-selection-<state>-win.png`
and `-mac.png`. The states are `details-multi`, `details-multi-fullrow`,
`details-multi-fullrow-grid`, `details-focusonly`, `details-focusonly-fullrow`,
`details-unfocused`, `large-multi` and `list-multi`. What still differs is the font (SF against
Segoe UI), the row height (20 against 19) and the file icons.

## 4. Audit of everything else that draws on a highlight

| place | how it draws | result |
|---|---|---|
| panel Details, every column, single / multi / focus-only, focused / unfocused, FullRow on/off, grid on/off, Light/Dark | `PanelRowView` + `PanelCellView` | **fixed**; `SelColorsTests.testDetailsRowsAreReadableInEveryState` |
| inside an archive (11 columns), flat mode (Path column) | the same cells | **fixed**; `testArchiveAndFlatRowsAreReadable` |
| Large Icons / Small Icons / List | `PanelCollectionItem` | **fixed** (was black on blue, 3.4:1); `testIconModesAreReadable` |
| drag-and-drop target row | `drawDraggingDestinationFeedback` | **fixed** (now LVIS_DROPHILITED style, white text); `testDropTargetRowIsHighlightedAndReadable` |
| AlternativeSelection rows | pink fill | **fixed** for Dark; `testAlternativeSelectionRowsAreReadable` |
| hover | none on Windows, none on the Mac list | same |
| Properties / Folders History (`ListViewDialog`), checksum results (`HashResultsDialog`), Messages | standard view-based `NSTableView`, `labelColor` cells, native emphasized style | readable, Light/Dark, emphasized and not; `testDialogListsAreReadableWhenSelected` |
| Options: Settings, System, Language, Plugins, 7-Zip menu items (checkbox cells) | standard tables | readable, same test (every tab of the Options window) |
| Overwrite dialog, Progress, Temp files | no list with a selection, or a standard one | nothing to fix |
| address bar combo, folder-history dropdown | native `NSComboBox` | native colours, nothing custom |
| flat toolbar hover / pressed | `FMToolbar` (winmatch), dynamic Light/Dark colours, `labelColor` labels | readable, not changed |
| menus with custom views | none in the app (`grep` for `.view =` on menu items) | n/a |

## 5. Tests

**App-hosted, `Mac/Tests/AppTests/SelColorsTests.swift`, 9 cases.**

- **How they measure:** each case renders rows into an **sRGB** bitmap at 2x, from the window's
  frame view so the real background is included. The text's most distinct pixel is measured
  against the cell's dominant colour, and the contrast must be **at least 4.5**.
- **Highlighted cells:** the cases also assert that a highlighted cell is on (0,120,212) with white
  text.
- **The other cells:** an unhighlighted cell must not be on the highlight.
- **The dialog sweep:** marks each table's row views selected directly, so the Language page
  cannot switch the app's language. It also asserts that it really measured text on the accent
  fill.

**Real input, `Mac/Tests/UITests/SelColorsInputTests.swift` (input shard).** It uses two panels:

1. It clicks `a.txt` in the left panel. The name must be filled and every other column at least
   4.5:1 with no fill. This is the user's exact case.
2. It clicks the right panel. The left panel's fill must disappear and the right panel's must
   appear.

It runs in the system appearance. `-AppleInterfaceStyle` in argv does not reach the app, so it
does not override the appearance, and the app has no appearance hook. Dark is covered by the
app-hosted cases. I filed a requests row for a test-support appearance override.

## 6. Results

All runs used `DEVELOPER_DIR=/Applications/Xcode.app`.

| run | result |
|---|---|
| `Mac/scripts/build.sh` | clean, no warnings in `Mac/` |
| `Mac/scripts/test.sh` | 387 passed, 0 failed |
| `Mac/scripts/test.sh -H` | 145 passed, 0 failed, 5 skipped (4 pre-existing; in this branch one case skips by design: `testOnlyTheFocusedListDrawsItsSelection` needs the key window, which a hosted run in the background does not get; the input-shard test covers it) |
| `Mac/scripts/test.sh -u` | see §7 |

## 7. UI suite

`Mac/scripts/test.sh -u`: probe shards 6 + 6 passed; input shard 45 passed, 2 failed, including
`SelColorsInputTests` (passed). The two failures are
`NewWindowUITests.testReopenWithAWindowOpenOpensAnotherWindow` and
`testReopenWithNoVisibleWindowOpensOne`, the same two `winmatch.md` §10 traced to a second 7-Zip
instance: during this run one was running from
`Mac/build/DerivedData/Build/Products/Release/7-Zip.app` in the main checkout (PID 74429, started
22:59, before this run; not started by this agent and left alone). The reopen event does not
produce a window in the shard's app while it runs. Neither test touches the list drawing. Re-run
them once that instance is quit.

## 8. The Windows machine

- **Registry:** `HKCU\Software\7-Zip` was exported before the run. Each configuration deleted the
  key and set only FullRow / ShowGrid. At the end the key was deleted and the backup re-imported:
  the three values `Path`, `Path32` and `Path64`, plus the `FM` key, as before.
- **Windows and processes:** every 7zFM window the script opened was closed by it (`StopFM`), and
  no 7zFM process was left.
- **Cleanup:** the fixture folder, the scheduled task `sz_cmp` and `%TEMP%\szcmp` were deleted.
- **Duration:** about 45 s of windows on screen in all.
- **Not committed:** the registry backup, because it holds the user's own history.

## 9. Files

- `Mac/App/Panel/PanelSelectionStyle.swift` (new)
- `Mac/App/Panel/PanelTableView.swift`
- `Mac/App/Panel/PanelListViews.swift`
- `Mac/App/Panel/PanelViewController.swift`
- `Mac/Tests/AppTests/SelColorsTests.swift` (new)
- `Mac/Tests/UITests/SelColorsInputTests.swift` (new)
- `Mac/docs/reports/selcolors-data/` (harness and Windows captures)
- `Mac/docs/reports/screenshots/wincompare-selection-*`, `selcolors-input-*`
- `Mac/docs/requests.md` (one row)

Nothing outside `Mac/` was touched.
