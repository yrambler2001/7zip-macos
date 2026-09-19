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
