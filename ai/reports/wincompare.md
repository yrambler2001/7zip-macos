# `wincompare`: the macOS port against the real 7-Zip File Manager, side by side

> **Publication note:** this report was written when it lived in `Mac/docs/reports/`. Its raw capture data (`*-data/`) and its screenshots were removed from the repository before publication; a few showcase images live on in `docs/images/`, and the tests now write their screenshots to the git-ignored `Mac/build/screenshots/`. Paths below that point into removed material are kept as a record of what was measured.

Branch `mac/wincompare`, off `macos` at `73afb22`, 2026-10-03. Scope: comparison plus fixes in
whatever scope owned the defect (listed in §9).

## 1. What was compared, and how

**Reference.** `ssh windows-host`, Windows 11, 1920×1080 at 96 DPI, CET/CEST like this Mac. Installed
7-Zip is **25.01 (x64, 2025-08-03)**, not 26.03, which this repository ports. Where the two
versions behave differently, the 26.03 source decides, and the row says "version difference".

**Identical fixtures.** One folder `cmp/` was built on the Mac with the console `7zz`, tarred,
copied to the PC, and every file there was given the same times (2024-01-15 10:30:00 local).
The archives are byte-identical on both sides.

| item | content |
|---|---|
| `a.txt` 1 234 B, `b.bin` 100 000 B, `empty.txt` 0 B, `notes.md` 20 B, `sub/{c.txt,d.log}` | plain files |
| `arc.7z` (LZMA2 solid), `arc.zip`, `arc.tar` | archives of the files above |
| `enc.7z` (`-pPass -mhe=on`), `encz.zip` (ZipCrypto, `Pass`) | encrypted |
| `broken.7z` (first 300 bytes of `arc.7z`), `fake.zip` (text) | broken and fake |
| `vol.7z.001-003` | a split 7z of `b.bin` |

**Windows half.** PowerShell run in the interactive session through a scheduled task. It drives
7zFM with `WM_COMMAND <IDM_*>`, reads menus with `GetMenuItemInfo` after a synthetic
`WM_INITMENUPOPUP` (so the File menu is rebuilt as on a click), and reads every control with a
child-window walk. The list view, header, status bar and toolbar are read with their own messages
through a buffer in 7zFM's process, because their UI Automation proxies do not load in
PowerShell 5.1. Combo boxes are read with `CB_GETLBTEXT`, and the Compress lists come from
`CB_SETCURSEL` + `CBN_SELCHANGE` on 7zG's own combos. Windows are captured with `PrintWindow`.
The scripts are in `wincompare-data/harness/` (`wrun.sh <step>` runs one), and every dump is in
`wincompare-data/win/`.

**macOS half.** `Mac/Tests/AppTests/WinCompareDumpTests.swift` (app-hosted) drives the same
commands through the responder chain over the same folder, and writes the same dumps to
`Mac/build/wincompare/out`. Menus are dumped with real validation. Dialogs come up through the
real command, not a direct `run`. The Compress walk pretends to be the PC: 8 threads and
21 240 692 736 bytes of RAM, through `CompressModel.hardwareOverride`. The test runs only when
`Mac/build/wincompare/cmp` exists, so normal runs skip it. To rebuild that folder, run
`wincompare-data/harness/make-cmp.sh <dir>` and copy `<dir>/cmp` there.

**Count.** 1 311 captured items were compared:

- 897 menu rows over 8 menu states;
- 268 context-menu rows over 6 targets;
- 64 dialog captures;
- 25 main-window states, which cover columns, rows, sorting, view modes and two panels;
- 57 Compress states (7 formats × every level and method), with 9 lists and 2 figures each;
- plus the behaviour and error-text cases of §7.

**Verdicts.** **same**; **deliberate**, a macOS convention under a locked decision
(`00-orchestration.md`, `parity.md` §C); **version**, where 25.01 differs from the 26.03 source and
the port follows 26.03; **Windows artifact**, where the PC's behaviour comes from its own setup;
**BUG → fixed**; **filed**, a difference left for another scope (§10).

Paired screenshots are `screenshots/wincompare-<area>-win.png` / `-mac.png`.

## 2. Main window (01 §1, §3)

| item | Windows 25.01 | macOS | verdict |
|---|---|---|---|
| window title | the folder path | the folder path | same |
| toolbar | Add, Extract, Test, Copy, Move, Delete, Info; text under the icons | the same seven, same order, text on | same |
| address bar | Up button, icon, editable combo with the path | Up button, icon, editable combo | same |
| FS columns | Name 160 L, Size 100 R, Modified 100 L, Created 100 L, Comment 100 L, Folders 100 R, Files 100 R | identical names, alignment and order and the same widths | same |
| date columns at their default width | `2024-01-15 11:30` fits in 100 px of 9 pt Segoe UI | cut to `2024-01-15 1...`: the list font needs 107 pt (screenshot `main-folder`) | **BUG → fixed**: time columns start at 120 pt |
| 7z columns | 11: … Attributes R, CRC R, **Encrypted R**, Method L, Block R, Folders, Files | the same 11, Encrypted **centred** | **BUG → fixed** (VT_BOOL is LVCFMT_RIGHT) |
| zip / tar / split columns | 18 / 19 / 11 columns | the same, in the same order | same |
| size format | `1 234`, `101 156` | the same | same |
| date format | `2024-01-15 11:30` for a 10:30 CET file, because Windows applies today's CEST offset | the same `11:30`; the engine's `FileTimeToLocalFileTime` copies that rule | same |
| attributes | `A -rw-r--r--`, `D drwxr-xr-x` | the same | same |
| rows inside arc.7z | sub 2 710 / 0, a.txt 1 234 / 100 930, LZMA2:17, CRCs | identical cell for cell | same |
| status bar | 4 parts at 220 / 320 / 420 px, "N / M object(s) selected" | the same parts and text, bidi-isolated | same |
| a folder just opened | first item focused, **not** selected: "0 / 15 object(s) selected" | first item focused and selected: "1 / 15", part 1 its size | filed (operated-item fallback, `requests.md`) |
| sort Name / Type / Size, Size twice | as shown | identical row order | same |
| sort Date (all dates equal) | keeps the previous order | reverse name order | **version** (26.03 adds the name round, PanelSort.cpp:193-219; 25.01 had a stable sort with no tie-break) |
| sort Size, equal sizes | vol.7z.001 before .002 | .002 before .001 | **version** (same reason) |
| Unsorted | NTFS enumeration order | APFS enumeration order | Windows artifact (file system) |
| flat view | Prefix `sub\` | `sub/` | deliberate (path separator) |
| view modes: large, small, list, details | four modes | four modes, selection kept | same |
| two panels (F9) | side by side, same columns | the same | same |
| select by mask `*.7z` | arc.7z, broken.7z, enc.7z, "3 / 15" | the same | same |
| Up from an archive | back in cmp, arc.7z focused and selected | the same | same |

## 3. Menus (01 §2)

Menu dumps: `win/menu-*.txt` against `out/menu-*.txt`, states noselection, a.txt, arc.7z, sub, two
files, inside arc.7z with and without an item, and two panels.

| item | Windows 25.01 | macOS | verdict |
|---|---|---|---|
| top level | File Edit View Favorites Tools Help | app menu, File … Help, plus Window | deliberate (macOS menu bar) |
| File: 7-Zip commands | a **"7-Zip" submenu at the top** whenever FS items are operated (CreateFileMenu, programMenu = true), with the full verb set | a fixed "7-Zip" submenu at the **bottom** with only 4 verbs | **BUG → fixed**: now built per opening, at the top, from the context menu's builder |
| File: Open … Link | 27 items, accelerators as in the .rc | the same items and order | same |
| accelerators | Enter, Ctrl+PgDn, Shift+Enter, F2-F7, Del, Alt+Enter, Ctrl+Z, Ctrl+N, Alt+F4 | Cmd+Down, Cmd+PgDn, Shift+Return, F2-F7, Cmd+Backspace, Opt+Return, Cmd+Z, Cmd+N, Cmd+W | deliberate (Ctrl→Cmd, `parity.md` §C) |
| File: New Window | — | first item | deliberate (`newwindow`) |
| File: Alternate streams, Ver* | present (Ver* hidden without Diff) | hidden | deliberate (NTFS streams hidden) |
| Split / Combine / Link enabled | only for one FS file (Link: one item) | the same rules | same |
| Edit | 7 items, column break | the same 7, then Copy / Cut / Paste and the system's AutoFill / Dictation / Emoji | deliberate (macOS clipboard items, Mac-added) |
| View: modes, arrange, flat, 2 panels, toolbars, refresh | as .rc, radio checks on Details and Name | the same | same |
| View: Time submenu | **local** time ("2026-10-03 18:09") | **UTC** ("16:09") | **BUG → fixed** (follows g_Timestamp_Show_UTC) |
| View: Back / Forward | — | Cmd+[ / Cmd+] | deliberate (addition) |
| Favorites | "Add folder to Favorites as" + 10 slots, empty slots enabled | the same, empty slots grayed | deliberate (menu validation) |
| Tools, Help | Options, Benchmark, Delete Temporary Files; Contents F1, About | the same (Options also Cmd+,) | same |

## 4. The list's context menu (01 §2.8-2.9)

| item | Windows 25.01 | macOS | verdict |
|---|---|---|---|
| structure | "7-Zip" ▸ (cascaded, CRC SHA inside) then directly the File items | the 7-Zip verbs inline, then a separator, then a shortened File part | **BUG → fixed**: cascaded per Options › CascadedMenu (default on), CRC SHA inside per kCRC_Cascaded, no separator |
| File part | Open, Open Inside, Open Inside \*, Open Inside #, Open Outside, View, Edit, Rename … Properties, Comment, CRC ▸, Create Folder, Create File, Link..., Alternate streams | lacked Open Inside \* / #, CRC ▸ and two separators, and showed "Link" | **BUG → fixed**: the same builder as the File menu (`MainMenu.addFileCommands`) |
| verbs for arc.7z | Open archive, Open archive ▸ (7 types), Extract files..., Extract Here, Extract to "arc\\", Test archive, Add to archive..., Compress and email..., Add to / Compress to … and email ×2, CRC SHA ▸ (11 hashes, SHA-256 → file, Test : Checksum) | the same list | same |
| `Add to "arc_2.7z"` for arc.7z | offered, with a `_2` name | `Add to "arc.7z"` is left out | **version** (26.03 drops it when it is the selected file's own name, ContextMenu.cpp:941-942) |
| inside an archive | File part only | File part only | same |
| shell items (System ▸) | off by default | off by default; macOS verbs when on | deliberate |

## 5. Dialogs (01b §4)

Dumps `win/dlg-<name>.txt` against `out/dlg-<name>.txt`.

| dialog | Windows 25.01 | macOS | verdict |
|---|---|---|---|
| Copy / Move (IDD_COPY) | "Copy to:", path combo, "...", info `Files: 1    ( 1 234 bytes )` + blank line + folder + `  a.txt` | the same controls; info was `a.txt / Files: 1 / Size: 1 234` | **BUG → fixed** (GetItemsInfoString line for line) |
| Copy from an archive | info names the archive folder `…\cmp\arc.7z\` | `…/cmp/arc.7z/` | same |
| Create Folder / Create File | combo dialog, "New Folder" / "New File" | the same | same |
| Create Folder on an existing name | "Error Creating Folder", "Cannot create a file when that file already exists." | the same caption, `errno=17 : File exists` | deliberate (OS error text) |
| Rename | in-place edit in the list | in-place edit | same |
| Properties of an FS item | Explorer's property sheet | the port's own list (Name, Size, times, Mode, User, Group, iNode …) | deliberate (`parity.md` §C, shell sheet) |
| Properties inside arc.7z | item block, then the archive block (Path, Type, Physical Size, Headers Size, Method, Solid, Blocks); sizes `1 234`, `101 156`, Modified `2024-01-15 11:30:00.0000000` | the same rows; sizes `1234`, Modified at the list's minute level | **BUG → fixed** (AddPropertyString: IsSizeProp → ConvertSizeToString, other values at ns precision) |
| Comment | `a.txt : Comment`, one-line combo, "&Comment:" | a multi-line "Comment" window | **BUG → fixed** (CComboDialog, IDS_COMMENT 6400 / IDS_COMMENT2 6401) |
| Checksum information | rows Name / Size / CRC32 …; Size as `1234 bytes : 1 KiB` | `1 234 bytes` | **BUG → fixed** (HashGUI links OverwriteDialog.cpp's AddSizeValue) |
| hash of two files / a folder | "SHA256 checksum for data", "… and names", digests with `-0000000N` | identical digests and labels | same |
| Split | "Split File b.bin", 9 volume presets | "Split File" plus a file-name label, the same presets | **BUG → fixed** (CSplitDialog::OnInit appends the name to the caption) |
| Combine | "Combine Files vol.7z.001", `Files: 3    ( 100 114 bytes )` | the same | same |
| Link | Hard, File Symbolic, Directory Symbolic, Directory Junction, WSL | the first three and a note | deliberate (`parity.md` §C) |
| Select / Deselect | combo "Mask:" `*` | the same | same |
| Folders History | list of visited paths | the same | same |
| Delete Temporary Files | columns Name, Modified, Size **R**, Files **R**, Folders **R**, **Name-2**; `1996 KB` | all left, last column "Name", `2043904` | **BUG → fixed** (BrowseDialog2.cpp:369-397, Browse_ConvertSizeToString) |
| About | OK, www.7-zip.org | Help, www.7-zip.org, OK | **BUG → fixed** (IDD_ABOUT has no Help button) |
| Options pages | System, 7-Zip, Folders, Editor, Settings, Language | the same six, then Plugins | deliberate (`parity.md` §C) |
| Options › 7-Zip | shell integration, Cascaded, Icons, Elim dup, Zone.Id, items | the same, with the Finder status line | deliberate |
| Options › Settings | 8 checkboxes, RAM limit `4 GB / 20 GB` | the same, large pages disabled, `1 GB / 8 GB` here | same (RAM-dependent), large pages deliberate |
| Options › Language | combo + info | table with English / native name, code, coverage | deliberate (documented in OptionsLanguagePage.swift; live switching is §C) |
| Extract (7zG) | Extract to, name box, Path mode, Overwrite mode, **Eliminate duplication unchecked**, Password, Restore file security | the same, **checked**, no security box, plus a summary of the archives | **BUG → fixed** (CBoolPair default false); security box deliberate; summary filed |
| Add to Archive (7zG) | every control, `2464 MB / 16206 MB / 20 GB` | every control, the same lists (§6) | same; caption case from en.ttt (§8) |
| Compress › Options | NTFS group (hidden for a.txt), Type, Time group | the same | same |
| Overwrite | folder line, name line, `1234 bytes : 1 KiB`, `Modified: 2024-01-15 11:30:00`; Yes, Yes to All, Auto Rename, No, No to All, Cancel | one quoted reduced path, `1 234 bytes (1 K)`, the date in the season's offset | **BUG → fixed** (SetFileInfoControl + AddSizeValue; current offset) |
| Password | "&Enter password:", Show password, OK, Cancel | the same, plus the archive name above | same |
| Confirm delete in an archive | Yes / No / Cancel | Yes / No | **BUG → fixed** (MB_YESNOCANCEL) |
| Delete on disk | no question, to the Recycle Bin (shell setting) | no question, to the Trash | same |
| Test result | MessageBox **"Testing"**: Archives, Packed Size `101156 bytes : 98 KiB`, Folders, Files, Size, "There are no errors" | the same text under "7-Zip" | **BUG → fixed** (OkMessage.Title = Title) |
| Test of broken.7z | progress window, "Files:" label, messages: path, "Cannot open the file as [7z] archive", "Unexpected end of data" | the same three messages; "Files" without the colon; an extra "Errors: 3" status line | messages same; colon **BUG → fixed** (LangSetDlgItems_Colon); status line filed |
| Benchmark | dictionary, threads, Compressing / Decompressing / Total | the same layout | same (figures are machine-dependent) |

## 6. Compress dialog lists (01b §4.2, IDD_COMPRESS)

`win/compress-matrix.txt` against `out/compress-matrix.txt`: for each of 7z, bzip2, gzip, tar,
wim, xz and zip, the default state, every level and every method at Normal. Each state records the
method, dictionary, word, solid, threads, memory-use lists, the memory figures and encryption.

- **Every list item, every default (`*` entry) and every memory figure is identical.** That covers
  all 57 states, including `2464 MB / 16206 MB / 20 GB / 34 MB` at 7z Normal and `11581 MB` at
  Ultra. The Mac ran with the PC's hardware.
- **BUG → fixed:** a one-method format (bzip2, gzip, xz) left its method combo enabled. Both
  25.01 and 26.03 gray it (EnableMultiCombo, CompressDialog.h:228).
- **version:** tar and wim have one level. 26.03 grays that combo (EnableMultiCombo(LEVEL)) and
  25.01 does not. The port follows 26.03.
- **Windows artifact:** for a format without threads, 7zG keeps the previous `/ 8` next to the
  empty threads combo, because SetNumThreads2 returns before updating it. The port blanks it.

## 7. Behaviours and error texts (01 §3.7, §8)

| case | Windows 25.01 | macOS | verdict |
|---|---|---|---|
| Enter on a folder / archive | enters it | enters it | same |
| Enter on broken.7z or fake.zip | S_FALSE, so the file is started through its association. On the PC that is 7zFM, which says `Cannot open file '…\broken.7z' as archive` / path / `Cannot open the file as [7z] archive` / `Errors: Unexpected end of data` | started through its association. The port's own launch-time box gives the identical four lines (fake.zip: `[zip]`, `Errors: Is not archive`) | same |
| enc.7z, wrong password | Enter password → `Cannot open encrypted archive '…\enc.7z'. Wrong password?` | the same text | same |
| enc.7z, Cancel | silent | silent | same |
| encz.zip lists without a password | yes, Encrypted `+` | yes | same |
| Backspace / Up | parent folder, the archive stays focused | the same (Backspace in the list; Cmd+Up in the menu) | same / deliberate key |
| Grey + / Grey - | Select / Deselect dialogs | the same on the keypad | same |
| Alt+F7-like (Ctrl→Cmd) | Ctrl+F3..F7 sort, Ctrl+1..4 views, Ctrl+R refresh | Cmd+F3..F7, Cmd+1..4, Cmd+R | deliberate (§C) |

## 8. Systematic differences that are not bugs

- **English text comes from `Lang/en.ttt`, not from the .rc.** With no language file, Windows
  shows the .rc strings ("Add to Archive", "&Solid Block size:", "Show Password"). The port's
  built-in English is the official `en.ttt` ("Add to archive", "Solid block size:"), so a few
  captions differ in case. Changing that is a localization decision, not a parity bug (filed).
- **Alert vs MessageBox.** Windows' caption is the bold first line of an `NSAlert` on macOS.
- **Window geometry.** AppKit metrics and Auto Layout differ from dialog units, and a few
  dialogs carry macOS notes (Options pages). Control order and content were compared, not pixels.

## 9. Fixes, and whose files they touched

| fix | files | owning scope |
|---|---|---|
| Context menu: cascaded "7-Zip" submenu, CRC SHA placement, no separator, shared File part | `Mac/App/Panel/PanelContextMenu.swift` | panel |
| File menu: dynamic 7-Zip submenu at the top (FileMenuDelegate), shared builder `addFileCommands` | `Mac/App/MainMenu.swift` (shared) | orchestrator / shared |
| View › Time shows local time; current offset for formatted dates | `Mac/App/MainMenu.swift` | shared |
| Encrypted and other VT_BOOL columns right-aligned | `Mac/App/Panel/PanelFormat.swift` | panel |
| Time columns 120 pt by default so a date is not cut | `Mac/App/Panel/PanelLogic.swift` | panel |
| Copy/Move info text = GetItemsInfoString | `Mac/App/Panel/PanelFormat.swift`, `Mac/App/Commands/PanelCommands.swift` | panel |
| Item comment through the combo dialog | `Mac/App/Panel/PanelOperations.swift` | panel |
| Properties: grouped sizes, ns-precision times | `Mac/App/Dialogs/PropertiesDialog.swift` | panel |
| Split caption with the file name, no extra label | `Mac/App/Dialogs/SplitDialog.swift` | tools |
| "Files:" / "Packed Size:" with their colons | `Mac/App/Dialogs/ProgressDialog.swift` | opsinfra |
| Yes / No / Cancel when deleting inside an archive | `Mac/App/Panel/PanelOperations.swift` | panel |
| `Formatting.sizeValue` (AddSizeValue) | `Mac/App/Support/Formatting+WinCompare.swift` (new) | shared, extension file |
| Overwrite file block | `Mac/App/Dialogs/OverwriteDialog.swift` | opsinfra |
| Checksum Size row | `Mac/Core/SZHasher.mm` | tools |
| Delete Temporary Files columns and sizes | `Mac/App/Dialogs/ToolsTempFilesDialog.swift` | tools |
| About without Help | `Mac/App/Dialogs/AboutDialog.swift` | tools |
| Extract: Eliminate duplication defaults off | `Mac/App/Support/Settings.swift`, `Mac/App/Dialogs/ExtractDialog.swift` | options, extract |
| Test result titled "Testing" | `Mac/App/Commands/ExtractCommands.swift` | extract |
| Method combo grayed for one method; `CompressModel.hardwareOverride` test hook | `Mac/App/Dialogs/CompressDialog.swift`, `CompressModel.swift` | compress |

Tests: `Mac/Tests/AppTests/WinCompareTests.swift`, 15 cases covering the fixes. Also changed:
`SettingsTests` (ElimDup default), `HasherTests` (size text), `PanelGapsTests` and
`GapsInputTests` (the cascaded menu).

## 10. Filed (requests.md)

- `wincompare → extract`: the Extract dialog's archive summary has no IDD_EXTRACT counterpart.
- `wincompare → opsinfra`: the progress window's extra "Errors: N" status line.
- `wincompare → orchestrator`: English from `en.ttt` against the .rc strings (§8).
- `wincompare → tools`: the About topic lost its only entry point with the Help button (F1 on
  Windows).
- `wincompare → panel`: the operated-item fallback to an unselected focused row (§2).

## 11. Verification

These ran at the final code, `export DEVELOPER_DIR=/Applications/Xcode.app`.

| run | result |
|---|---|
| `Mac/scripts/build.sh` | clean, no warnings in `Mac/` |
| `Mac/scripts/test.sh` (unit) | 387 passed, 0 failed |
| `Mac/scripts/test.sh -H` (app-hosted) | 129 passed, 0 failed (includes `WinCompareTests` 15 and `WinCompareDumpTests` 4) |
| `Mac/scripts/test.sh -u`, probe shards | 6 + 6 passed |
| `Mac/scripts/test.sh -u`, input shard | 43 of 45 passed |

**The two input-shard failures:**

- **`PanelTests.testListContextMenuContents`.** It expected "Open archive" at the top level of the
  context menu. The test now opens the cascaded "7-Zip" submenu, and it passes when run alone
  (`-o PanelTests/testListContextMenuContents`). `GapsInputTests` got the same change and passed
  in the shard.
- **`ResetCommandTests.testSelectionIsResetToTheFreshlyBoundDefault`.** It fails with "Not
  hittable" on the `test.zip` row. The run's screen recording shows why: a macOS **"Force Quit
  Applications — Your system has run out of application memory"** window sits over the lower part
  of the 7-Zip window, where that row is. It is still on screen, and this agent cannot close it
  (no Automation permission; `CLAUDE.md`). The test passed on `macos` before this branch and
  touches no code this branch changed, so this is environmental. Re-run it once the window is
  closed.

**Where the memory pressure came from.** One cause is this branch's first dialog run. "Enter" on
`broken.7z` starts the file through its association, which launched Archive Utility; it was
killed afterwards. The dump test now uses the command-line open instead.

**Automation mode.** The first `test.sh -u` attempt failed before any test with "Timed out while
enabling automation mode", the known intermittent failure of `uiverify.md` §6. The retry ran.

## 12. The Windows machine

The registry key `HKCU\Software\7-Zip` was exported before the first run and re-imported at the
end; the scheduled task `sz_cmp` and the `%TEMP%\szcmp` folder were deleted. Two fixture files
went to the Recycle Bin during the first dialog run; only those two entries were removed from it.
Every 7zFM / 7zG window the scripts opened was closed by them. The Mac half did the same with two
scratch copies of `a.txt` / `b.bin` that its first dialog run moved to the Trash. Both were
removed from `~/.Trash`, and the dump test no longer sends Delete on disk.
