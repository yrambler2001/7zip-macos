# theme — Options ▸ macOS (Theme, Show grid lines) and first-launch Finder integration

Branch `mac/theme`. Two user requests, both macOS additions with no 7zFM counterpart, plus one
panel bug the grid checkbox exposed.

## 1. Options ▸ macOS (a seventh tab, after Language)

The user's change of plan: the six Windows pages keep their layout untouched; the new settings live
on their own tab, titled **macOS**, last in the row (`Dialogs/OptionsMacPage.swift`, pageID 0 so the
title is the fallback). It is laid out like every other page: a DLU template on the 316 × 296 DLU
page (`RcDialog(template:)`), placed with `RcPlace` in the dialog font, fixed size, nothing scrolls.

| Control (template DLUs) | What |
|---|---|
| LTEXT "Theme:" 8,10 76×8 + CBS_DROPDOWNLIST 88,8 120 wide | System (default) / Light / Dark. The label + combo row in the IDD_COMPRESS "Archive format:" style (label 2 DLU under the combo's top). |
| checkbox 8,30 300×10 "Show grid lines" | LVS_EX_GRIDLINES. |

**Theme.** `FM.Theme` = `system` (stored as no key) / `light` / `dark`, `Support/AppTheme.swift`.
It sets `NSApp.appearance` (nil / `.aqua` / `.darkAqua`), so it covers every window of the process:
file-manager windows, dialogs, message boxes, progress, the 7zG-mode dialogs. Applied in
`applicationWillFinishLaunching` before the first window, and whenever the key is written (the
page's Apply / OK) or the whole domain is replaced (a test reset). Translation: lang IDs 9900
("Theme:"), 9901-9903 ("System" / "Light" / "Dark"), outside every official block, so a Lang file
can add them; "System" falls back to 2200 (IDD_SYSTEM's caption, "System"), which all 90+ official
translations carry. English fallbacks are the requested texts.

**Show grid lines.** Windows' own "Show grid lines" exists (IDX_SETTINGS_SHOW_GRID 2505 on the
Settings page, `FM.ShowGrid`), so it stays as the Windows control and the macOS tab's checkbox is
bound to the same setting, with the same caption (lang 2505). While the sheet is open the two
mirror each other (`OptionsGridLines.toggled`); either page's Apply writes the value, and
`OptionsPostApply` refreshes every open panel. Default **off**, as a fresh Windows install
(`Key_Get_BoolPair`-less bool, absent = false): the panel already drew no grid by default
(`gridStyleMask = []`), measured in the test (zero grid pixels).

**Bug found and fixed (panel).** Toggling the grid did not redraw the rows already on screen:
`NSTableRowView` keeps its own copy of the grid style (`_gridStyleMask`, set when the table adds the
row view) and draws the lines from it, and the panel reuses row views. Turning the grid off left the
old lines; turning it on again left none. `applyListSettings` now reloads the rows when the style
changes, and `tableView(_:rowViewForRow:)` reuses row views only within one grid state
(`panelRow` / `panelRow.grid`).

## 2. Dark and Light in every custom-drawn component

Every custom colour was already a light/dark pair (`WinChrome.dynamic` and its relatives): list
selection (`PanelSelectionStyle`), flat toolbar (`FMToolbarColors`), address band and its pop-up
(`WinChrome`, `PanelAddressPopup`), WinCombo / pop-ups (`WinCombo`), header cells
(`PanelHeaderCell`), status bar, message box (`WinMessageBoxContentView`), group boxes
(`DialogMetrics.groupLine`), tabs (`OptionsTabControl`), the progress bar (`WinProgressBar`). The
Windows grey COLOR_BTNFACE (240) maps to `windowBackgroundColor` in Dark (≈ 30-36 grey), the white
COLOR_WINDOW to `textBackgroundColor`. Nothing is cached in a layer or an image, so a theme switch
redraws in place. What was missing was the switch itself, and a test that drives the forced
themes.

## 3. First launch: Finder integration on, once

`Integration/FirstLaunchIntegration.swift`, called from `FinderIntegration.install`'s
did-finish-launching block (right after `claimAtLaunchIfNeeded`, before the settings push):

- **Enable** = `FinderExtensionControl.setEnabled(true)` (claims this copy's FinderSync.appex,
  elects use), then for both Quick Actions remove other copies' registrations, `-a` this copy's
  appex, `-e use`; plus `Options.CascadedMenu = true` (already its default; written so the
  extension snapshot carries it). Off the main thread, never a message box: if PlugInKit refuses,
  the Options checkbox reads the real state, which stays truthful.
- **Once**: the marker `FM.FirstLaunchIntegration` is written when it runs, whatever PlugInKit
  answers. Also written (and nothing else done) when `Options.CascadedMenu` already exists — the
  user has been through Options ▸ 7-Zip before. Unticking either box later is never undone.
- **Never** for a test instance: `SZ_TEST_SUPPORT`, an XCTest bundle loaded, or a bundle id other
  than `com.yrambler2001.7zip` (the `-host`, `-p1`, `-p2` copies); never for a copy without
  FinderSync.appex.
- **Only from an installed location** (decision): the bundle (symlinks resolved) inside
  `/Applications/` or `~/Applications/`, subfolders included, and not App Translocation. Anything
  else — a mounted disk image (`/Volumes/…`), Downloads, `Mac/build`, DerivedData — **defers**:
  nothing is written, and the first launch of the installed copy does it.

## 4. Verification

(filled in below)

## 5. Known gaps / follow-ups

- The Theme label and its three options have no translations yet (the 9900 block is new); every
  language shows the English, except "System" (lang 2200).
- Dark mode has no Windows reference; the dark colours are the AppKit ones playing the same role,
  as before this scope.

## 6. Files

New: `Mac/App/Support/AppTheme.swift`, `Mac/App/Dialogs/OptionsMacPage.swift`,
`Mac/App/Integration/FirstLaunchIntegration.swift`, `Mac/Tests/AppTests/ThemeTests.swift`.
Edited (recorded in `requests.md`): `AppDelegate.swift` (one call), `OptionsWindow.swift` (page
list), `OptionsSettingsPage.swift` (grid mirror only), `URLCommands.swift` (one call),
`PanelViewController.swift` / `PanelListViews.swift` (grid redraw), `DlgFeelTests.swift`,
`SelColorsTests.swift`, `Mac/docs/api/options.md`.
