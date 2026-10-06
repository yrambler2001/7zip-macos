# options scope — progress log

> **Publication note:** all but a few showcase images under `docs/reports/screenshots/` were removed from the repository before publication. Paths below that point into them are kept as a record of what was measured.

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

## Phase 5b (verification in the running app)

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

## Phase 6 — defaults-domain override, docs, final verification

**`SEVENZIP_DEFAULTS_SUITE`** (request from `harness`, `Mac/docs/requests.md`). The CFPreferences
application ID is now resolved by `NMacPrefs::ApplicationID()` on every access
(`Mac/Core/Platform/MacPrefs.cpp`): the variable when it is set and non-empty, otherwise
`com.yrambler2001.7zip`. Because every settings path — `SZSettings`, the Swift `Settings` facade
and the engine-side `ZipRegistry` accessors (`Extraction.*`, `Compression.*`, `Options.*`,
`NWorkDir`) — goes through `NMacPrefs`, one variable isolates the whole process, engine included.
`SZSettings.applicationID` reports the domain in use and `SZSettings.usesOverrideSuite` whether it
is overridden; the two constants are `SZSettingsSuiteEnvironmentVariable` and
`SZSettingsDefaultApplicationID`. The CFString is rebuilt only when the value changes, so a test
can switch domains with `setenv()` mid-process (guarded by a critical section).

Files touched outside the original ownership list: `Mac/Core/SZSettings.mm` and
`Mac/Core/include/SZSettings.h` (granted for this change) plus `Mac/Core/Platform/MacPrefs.{h,cpp}`
— the engine-side accessors read the domain from there, so the request could not be satisfied
without it. The change is additive: without the variable nothing behaves differently.

`Mac/docs/api/options.md` is written: the domain override, the key → property table for every key
of 01b §5.1-5.5, the tri-state / sentinel / log2 encodings, the notification names and groups, the
`FileTypes` shape for the `finder` scope (40 extensions) and how to add a page.

### Verified in the running app (final binary, isolated domain)

Held the shared app lock, launched with `SEVENZIP_DEFAULTS_SUITE=7zip-options`, and:

- walked all seven pages twice (screenshots `options-1..7-*.png`, regenerated from the final
  build) — no exceptions in the log;
- the domain override end to end: everything the app stored landed in `7zip-options`
  (`defaults read 7zip-options` shows `Lang`, `FM.*`), and `com.yrambler2001.7zip` kept its old
  `Lang = -` throughout;
- language: selecting Russian relabelled the window title (`Настройки`), the tab titles
  (`Система 7-Zip Папки Редактор Настройки Язык Plugins`), the menu bar
  (`Файл Правка Вид Избранное Сервис Справка`) and the buttons (`Помощь`, `Отмена`) **live**,
  with no restart (screenshot `options-8-language-ru.png`); OK persisted `Lang = ru`, a relaunch
  came up in Russian and reopened Options on the remembered page, and selecting the built-in
  English entry (`-`) put everything back to English;
- persistence (earlier pass, real domain): `FM.ShowGrid`, `FM.ShowDots`, `FM.Viewer`,
  `Options.CascadedMenu`, `Options.WriteZoneIdExtract`, `Options.ContextMenu = 0xC0003F67`
  (every context-menu item except `kTest 1<<4`), `Options.WorkDirType = 2` + `WorkDirPath` +
  `TempRemovableOnly = 0` all survived quit + relaunch;
- Cancel discards (`FM.ShowRealFileIcons` stayed `0` after a toggle + Cancel) and the window
  reopens on the page it was left on.

`rm -rf Mac/build && Mac/scripts/build.sh && Mac/scripts/test.sh` both exit 0; 29 unit tests pass
(12 in `SettingsTests`), no warnings in `Mac/` code.

### Mapping notes (where macOS deviates, and why)

- **System page** (01b §4.21, 03 §3.4, 01 §9 #3): one per-user column instead of the Windows
  current-user/all-users pair, with a note naming the dropped `IDS_SYSTEM_ALL_USERS 2202` column;
  `NSWorkspace.setDefaultApplication(at:toOpen:)` shows the system's own confirmation and answers
  asynchronously, so Apply refreshes the rows in the completion handler and reports only the first
  error, as `SystemPage::OnApply` does. "Clear" hands the type back to the application that owned
  it when the page was opened, because macOS has no API to remove a default handler.
- **7-Zip page** (01b §4.13, 03 §6.2): the shell-handler checkbox becomes a live Finder Sync
  status read from `pluginkit -m -p com.apple.FinderSync -v`, a button that opens Login Items &
  Extensions and the `pluginkit -e use -i …` command, since only the user can enable an appex. The
  bitness checkbox `2310` is dropped. The zone combo drives `com.apple.quarantine` propagation
  (01 §9 #23) and keeps the Windows lang IDs (`406 = Yes`, `407 = No` — the inventory has them
  swapped).
- **Settings page** (01b §4.19): "Use large memory pages" is shown disabled with the reason
  (01 §9 #16); "Show system menu" is kept and documented as the macOS Finder commands in the panel
  context menu (01 §9 #2).
- **Language page** (01b §4.9): a list instead of a combo, so the English name, the native name
  and the completeness fit side by side; `***` / `+++` locale marks kept; switching applies live
  (Windows applies on OK) and Cancel puts the previous language back.
- **Plugins page**: macOS-only, informational. 26.03 has no plugin chooser (03 §3.4, 01 §6.8) and
  this build links every codec statically (01 §9 #29), so the page lists the 61 loaded handlers.
- `FM.Columns.<FolderTypeID>` is a JSON string rather than a `REG_BINARY` blob (same fields).

### Known gaps / follow-ups

1. The System page uses `NSWorkspace.icon(for:)` for the row icons; converting
   `CPP/7zip/Archive/Icons/*.ico` into bundled assets needs a resource entry (packaging scope).
2. Rows whose extension has no declared UTI (`bzip2`, `tbz`, `tzst`, `001`, `swm`, `esd`, `taz`,
   `tpz`, …) show `—` and are not associable until the `finder` scope adds the imported type
   declarations to `Mac/App/Info.plist`; `SevenZipFileType.utType` picks them up automatically.
3. Help opens no book: each page carries its `.chm` topic and logs it (01 §9 #17).
4. The Language page shows how many lines are missing or extra, not the full ID lists
   (`PROGRESS.md` box left unticked).
5. `FM.AutoRefresh` is persisted although Windows does not persist `AutoRefresh_Mode` (inherited
   from the scaffold; box left unticked).
6. The Language table's own column headers ("English name", "Native name", "Code", "Strings") are
   not localizable — Windows has no such columns, so there are no lang IDs for them.
7. `Mac/Tests/SevenZipKitTests/Settings.swift` and `FileTypes.swift` are **symlinks** to
   `Mac/App/Support/*`: the test target globs its own directory and cannot depend on the app
   target. The `harness` scope replaces them with proper `project.yml` entries after the merge
   (request filed in `Mac/docs/requests.md`). Both files are Foundation-only so they compile
   there; keep them that way.
