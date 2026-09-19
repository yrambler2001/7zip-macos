# options scope — progress log

Branch `mac/options`. Worktree `.worktrees/options`. Files owned: `Mac/App/Dialogs/Options*.swift`,
`Mac/App/Support/Settings.swift`, `Mac/App/Support/FileTypes.swift`,
`Mac/App/Commands/OptionsCommands.swift`, plus new tests under `Mac/Tests/SevenZipKitTests/`.

## Phase 1-4 (settings layer, window shell, all pages, file types) — builds

- `Support/Settings.swift`: full typed facade over `SZSettings` for every key of 01b §5.1-5.5
  (root, `FM.*`, `Extraction.*`, `Compression.*`, `Compression.Options.<Format>.*`, `Options.*`),
  tri-state `Bool?` for every `CBoolPair` with a `...Value` companion for the engine's default,
  `-1`/`-2` sentinels and the log2 `BlockSize` preserved, `Notification` per group + one global
  with a key payload. Key → property table in `Mac/docs/api/options.md`.
- `Support/FileTypes.swift`: the association list from `7z.dll` STRINGTABLE 100 (40 entries, not
  39 — see the note in the api doc), icon index, icon file name, format, `<EXT> Archive` title,
  system/imported UTType resolution.
- `Dialogs/OptionsWindow.swift`: `OptionsWindowController` (single window, `NSTabView`, Windows
  page order and lang-file page titles, OK/Cancel/Apply/Help with per-page apply, last page
  remembered), `OptionsPage` protocol + `OptionsPageBase`, `OptionsUI` control factory.
- `Dialogs/OptionsSystemPage.swift` (IDD_SYSTEM 2200), `OptionsMenuPage.swift` (IDD_MENU 2300),
  `OptionsFoldersPage.swift` (2400), `OptionsEditorPage.swift` (2103),
  `OptionsSettingsPage.swift` (2500), `OptionsLanguagePage.swift` (2101), `OptionsPluginsPage.swift`
  (macOS-only informational page).
- `Commands/OptionsCommands.swift`: `MainWindowController.toolsOptions` (IDM_OPTIONS 900, already
  wired in the menu) + the post-apply steps (`SetListSettings` / `RefreshAllPanels` /
  `MyLoadMenu` / `ReloadToolbars` equivalents).

`Mac/scripts/build.sh` succeeds, no warnings in `Mac/` code. No file outside the owned set touched.

Next: unit tests for the settings layer, then verification in the running app with screenshots.

## Phase 5a (unit tests) — 28 tests pass

`Mac/Tests/SevenZipKitTests/SettingsTests.swift` (11 tests): defaults when unset for every group,
`CBoolPair` tri-state round trips (absent / false / true, including the default-true keys), the
`-1` removal sentinel and the `-2` dictionary sentinel, the log2 `BlockSize`, per-format option
enumeration and removal, string-list trimming (100 / 20 / 16 / 10 slots), `FM.Columns.<ID>`,
change notifications (global + per group), the Finder export, the `FileTypes` table, and that a
value written through the facade is visible through `SZSettings` under the Windows-style key.

`Settings.swift` and `FileTypes.swift` are symlinked into `Mac/Tests/SevenZipKitTests/` (the test
target globs that directory and does not depend on the app target), so the tests compile the same
source the app does. Both files are Foundation-only for that reason. The tests write into the real
`com.yrambler2001.7zip` domain and snapshot/restore every key they touch with CFPreferences.

Finding: `NWorkDir::CInfo::Load` falls back to `kSystem` only when `Options.WorkDirPath` is
**absent**; an empty stored string keeps `kSpecified` (`ZipRegistry.cpp:526-533`). 01b section 4.8
says "missing/empty", which is slightly off.

## Phase 5b (verification in the running app) — stopped mid-way (usage limits)

Verified live (screenshots in `Mac/docs/reports/screenshots/options-1..7-*.png`, one per page):

- Tools > Options opens a single window; tabs are **System, 7-Zip, Folders, Editor, Settings,
  Language, Plugins** (Windows order + the macOS-only Plugins page).
- System page lists all 40 types with icon, `<EXT> Archive`, the state column named after the
  user, and the current default application; the per-user note replaces the Windows "All users"
  column. Types macOS has no UTI for (e.g. `bzip2`) show `—` until the `finder` scope adds the
  imported type declarations.
- 7-Zip page: Finder-integration status read from `pluginkit`, the three checkboxes, the zone
  combo (`* No` / `Yes` / `For Office files`) and the 14-row context-menu check-list.
- Settings page: seven CFmSettings checkboxes, the disabled large-pages row with its reason, the
  memory-limit row showing `GB / 64 GB (RAM)`.
- Language page: 94 rows (System default, built-in English, 92 lang files) with English/native
  name, code and `444 / 444 = 100%`. Plugins page lists the 61 loaded handlers.
- Persistence through OK, quit, relaunch: `FM.ShowGrid=1`, `FM.ShowDots=1`, `FM.Viewer=
  /Applications/TextEdit.app`, `Options.CascadedMenu=0`, `Options.WriteZoneIdExtract=1`,
  `Options.ContextMenu=0xC0003F67` (all items except `kTest 1<<4`), `Options.WorkDirType=2` +
  `Options.WorkDirPath=/tmp/7z-work` + `Options.TempRemovableOnly=0`.
- Cancel discards: toggling "Show real file icons" enables Apply, Cancel closes the window and
  `FM.ShowRealFileIcons` stays `0`; reopening restores the control and the last page.
- Live language switch works: selecting a row relabels the menu bar, the window title and the tab
  titles without a restart (observed with Irish and Kabyle).

Bugs found and fixed during verification (all committed): pages were initialised before
`NSTabView` loaded their views (crash), the tab-view delegate overwrote the stored last page while
the tabs were being added, the page root view was constraint-driven so content overflowed, the
Plugins table had no delegate, the zone combo used lang 406/407 swapped (01b §4.13 has them
backwards — upstream `MenuPage.cpp:213-216` is authoritative), the context-menu list needed a real
table, and the Options window was released on close so it could not reopen.

### Half-done / next steps

1. **Language switch screenshot + switch back**: the switch is verified live but the
   `options-8-language-<code>.png` shot and the "select English again, OK, menus back in English"
   pass were not finished. The Options window title is localised, so AppleScript must find the
   window by "the one that has a tab group", not by the title `Options`.
2. `Mac/docs/api/options.md` (key → property table, `FileTypes` shape for the `finder` scope) is
   **not written yet** — this is the main remaining deliverable.
3. `Mac/docs/PROGRESS.md` section 7 boxes are **not ticked** yet.
4. A final clean `rm -rf Mac/build && Mac/scripts/build.sh && Mac/scripts/test.sh` has not been
   run (the incremental build and the 28 tests passed at the previous commit; the four fixes after
   that were each built successfully but not re-tested).
5. Icons: the System page uses `NSWorkspace.icon(for:)`; converting `CPP/7zip/Archive/Icons/*.ico`
   to bundled assets is still open (needs a resource added by the packaging/finder scope).

### Note for the orchestrator

All agents' app instances share the preference domain `com.yrambler2001.7zip`, and XCUITest
launches terminate other instances of the same bundle id. During this verification the `opsinfra`
app repeatedly reset `Options.WorkDirType` / `Options.TempRemovableOnly` to their defaults, and the
`harness` UI-test runner killed running instances. Values were re-checked immediately after each
Apply to work around it.
