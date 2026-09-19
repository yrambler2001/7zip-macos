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
