# Scaffold report (Wave 1) — branch `mac/scaffold`

## What was implemented

- **SevenZipCore** static library: exact 7zz source set minus Console (312 TUs) + patched `UI/Agent`, `WorkDir`, `ArchiveName`, `StringUtils`, `TextPairs`, `SplitUtils`, `PropertyName`, `FormatUtils`, `Common/Lang.cpp`, arm64 `LzmaDecOpt.S` with `Z7_LZMA_DEC_OPT`. Upstream patches: `Mac/docs/upstream-patches.md` (+ `.diff`). Platform layer `Mac/Core/Platform/` (MyInitGuid TU with every interface header, `CompareFileNames_ForFolderList`, `SetExtractErrorMessage`, `MyLoadString` hook, all `ZipRegistry.h` accessors over CFPreferences).
- **SevenZipKit** framework: see `architecture.md` "As built" for the API. Nested archives open from the item stream (tar, xz, images) or through a `7zO-*` temp extraction (zip, 7z, gzip) exactly like 7zFM.
- **7-Zip app**: full 7zFM menu bar (§2, IDM comments, lang titles, Cmd-mapped shortcuts, auto-disabled selectors), toolbar with the seven buttons (SF Symbols; disabled until implemented), 1/2 panels in an `NSSplitView` (F9 / View > 2 Panels), panel = Up button + editable path combo + details table with the folder's columns + status bar (`{0} object(s) selected`, sizes, mtime), double-click/Enter/Backspace/`\` navigation, header-click sorting (7zFM rules: dirs first, size/date start descending), active-panel accent bar, FSEvents auto-refresh (1 s poll), favorites (10 slots), time-precision popup, window/panel/splitter/path persistence under the registry key names, password prompt sheet. App icon from `FM.ico`. FinderSync stub appex.
- **Tests**: `Mac/scripts/test.sh` -> 17 XCTest cases (codecs, 7z/zip/tar.gz/tar.xz/nested/encrypted fixtures, FS folder + FSEvents, root/volumes, lang en + de, settings round trip). Fixtures from `Mac/scripts/make-fixtures.sh`.

## Verification

- `Mac/scripts/build.sh` BUILD SUCCEEDED (Debug, ad-hoc); `Mac/scripts/test.sh` TEST SUCCEEDED.
- Run via `Mac/scripts/run.sh`, driven with System Events: home directory listed; address bar -> `Mac/Tests/Fixtures/`; Enter on `test.7z` lists `sub, notes.md, readme.txt` with 7z columns; Enter on `sub` -> `deep, big.txt`; View > 2 Panels toggles; quit + relaunch restores 2 panels and both paths. Screenshots: `Mac/docs/reports/screenshots/scaffold-01-home.png`, `-02-fixtures.png`, `-03-archive.png`, `-04-two-panels.png`.

## Mapping notes / deviations

- Default start folder is the home directory (7zFM: root folder) — root is one "Up" away.
- Bare-key shortcuts (Enter, Backspace, Del, `\`, keypad) are handled by the table; menu shows Cmd+Down (Open), Cmd+Up (Up One Level), Cmd+Backspace (Delete), Cmd+W (Exit).
- `.tar.gz` opens as the gzip level with one `test.tar` item (as `7zz l` / 7zFM), the tar opens as a nested archive.
- Column "Created" = birth time (engine's kpidCTime on macOS is ctime).

## Known gaps / follow-ups

- Not implemented (menu items disabled): all file operations (copy/move/delete/rename/create/comment/split/combine/link/properties dialog), CRC, view/edit, extract/add/test, options, benchmark, folders history dialog, select dialogs, large/small/list view modes (state only), toolbar large buttons (state only), archive "Open Outside".
- `Mac/docs/PROGRESS.md` does not exist yet (orchestrator to create).
- The final clean-state rebuild (`rm -rf Mac/build`) was not re-run after the last edits (week quota); the incremental build + tests pass.
- UI automation via AppleScript is fragile once the window title changes (window-by-name lookups).
