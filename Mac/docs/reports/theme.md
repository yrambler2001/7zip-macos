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

| Check | Result |
|---|---|
| `Mac/scripts/build.sh` (Debug) and `build.sh -r` (Release) | exit 0, no warnings in `Mac/` |
| `test.sh` (SevenZipKitTests) | 401 passed |
| `test.sh -H` (SevenZipAppTests) | 273 passed (9 new in `ThemeTests`) |
| `test.sh -u` (input + probe shards) | 61 + 6 + 6 passed |

`ThemeTests` (app-hosted):
- the setting: absent = System = `NSApp.appearance` nil; Light / Dark applied when the key is written, and again after a test reset (keyless notification); an unknown value reads as System;
- the macOS tab: last, after the six Windows pages; Apply (not before) switches the whole app, the Options window included; `FM.Theme` is on disk; reopening shows it;
- grid lines: off by default (zero grid pixels in the list); ticking on the macOS tab ticks the Settings tab and the reverse; Apply redraws the open panel with and then without lines (pixels counted); persisted, both boxes show it on reopen;
- fit: in `-`, de, ru, fr, ja and ar every control is inside the page, nothing scrolls, the label, the check box and the three drop-down titles fit, and the seven tabs fit in one row;
- contrast >= 4.5 under forced Light and Dark: main window list cells (a selected row too), header titles, toolbar labels, address text, the face colour (240 grey in Light, dark in Dark); every Options page, Add to Archive, a message box, a progress window;
- the first-launch decision (installed, ~/Applications, subfolder -> enable; marker or an existing CascadedMenu -> already done; /Volumes, Downloads, Mac/build, App Translocation -> defer; SZ_TEST_SUPPORT, XCTest, the -host / -p1 bundle ids, no appex -> skip; the test host itself -> skip); the run writes once and never re-enables after an untick; a deferred run writes nothing; the PlugInKit commands (`-e use` for all three ids, `-r` of another copy's Quick Action, `-a` of this copy's) checked with the runner replaced, so no real pluginkit call.

`SelColorsTests` now drives Light / Dark through `Settings.theme` (the forced themes) rather than
setting `NSApp.appearance` directly, so its contrast matrix covers the forced themes.

Screenshots (read and checked): `theme-main-light.png`, `theme-main-dark.png`,
`theme-options-dark.png` (the Settings page, unchanged layout), `theme-options-macos-tab-light.png`,
`theme-options-macos-tab-dark.png`, `theme-compress-dark.png`, `theme-msgbox-dark.png`.

**Installed.** The Release build is `/Applications/7-Zip.app` (ad-hoc signed, `codesign -v` ok):
the user's copy was not running, was backed up to `~/7-Zip-backup.app`, replaced, checked, and the
backup removed (and unregistered). The first launch of the installed copy really ran the
first-launch path: `FM.FirstLaunchIntegration = 1` and `Options.CascadedMenu = 1` appeared in
`com.yrambler2001.7zip`, the Finder Sync extension stayed elected `+` from `/Applications`. A cold
`open sevenzip:///run?argv=<a -t7z …>` wrote a valid 7z and the app exited. Afterwards
`pluginkit -m -D -A` lists only `/Applications/7-Zip.app` for FinderSync, QuickActionExtract and
QuickActionCompress (all `+`), and `sevenzip:` resolves only to `/Applications/7-Zip.app`; this
tree's build copies were unregistered from Launch Services.

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
