# `mac/navgaps` — the remaining panel, navigation and window gaps

Branch `mac/navgaps`, off `macos` at `76466f1`, 2026-10-03. Input: the "left open" list of
`reports/archgaps.md`, the unchecked PROGRESS items outside `packaging`, and the open
`requests.md` rows. The checklist went from **455 to 467 of 496**. Section K of `parity.md` is the
user-facing summary.

## 1. Opening an archive: progress, Cancel, per-level text (`01 §6.7`, PROGRESS 153, 155)

**Windows.** `CFfpOpen::OpenFileFolderPlugin` (FileFolderPluginOpen.cpp:220-370) opens on a worker
thread under a `CProgressDialog` titled IDS_OPENNING 3303 in WaitMode (shown only after the create
delay). `COpenArchiveCallback` (OpenCallback.cpp:20-60) feeds it from Open_SetTotal /
Open_SetCompleted and answers Open_CheckBreak with the Cancel state. Afterwards `GetFolderError`
composes per level: IDS_CANT_OPEN_AS_TYPE 3017, IDS_IS_OPEN_AS_TYPE 3018, `[type] : Error : ...`,
`Errors: <kpidErrorFlags text>`. Only the **non-open level's** text becomes `ffp.ErrorMessage`:

- `CPanel::OpenAsArc` enters the archive and then shows it (PanelItemOpen.cpp:512).
- `OpenAsArc_Msg` shows a box only for an encrypted S_FALSE (IDS_CANT_OPEN_ENCRYPTED_ARCHIVE 3006)
  or a real HRESULT. A plain "not an archive" is silent: Enter then starts the file externally, and
  Open Inside does nothing.
- `BindToPath` uses OpenAsArc without `_Msg`: a file that is not an archive binds its folder, silently.

The open-level warnings ("There are data after the end of archive") are computed and **not shown**
on entering (the `GetFolderError(_folder, s)` call in OpenAsArc is commented out upstream). They are
in Properties. The port does the same, so a zip with a tail opens without a box.

**Mac.**

- Bridge (`SZArchiveOpener.mm`):
  - `CSZOpenCallbackUI` forwards Open_SetTotal / Open_SetCompleted to an `SZProgressDelegate`, and
    `progressCheckBreak` aborts. The nested-archive copy (`CExtractToTempCallback`) reports
    through the same delegate.
  - New `progress:` variants of `openArchive(atPath:)`, `openArchive(in:)`, `SZFolder.folder(forPath:)`
    and `bindToPath`.
  - `SZGetFolderError` is a port of GetFolderLevels + GetFolderError, read through the agent's
    `IFolderArcProps`.
  - `SZArchive.openErrorMessage` holds the non-open level's text.
  - A failed S_FALSE carries `SZArchiveOpenEncryptedKey` (CFfpOpen::Encrypted = PasswordIsDefined),
    `SZArchiveOpenErrorMessageKey` and `SZArchiveOpenPathKey`. Its description is FM.cpp's text.
- Panel (`PanelArchiveOpen.swift`):
  - `runArchiveOpen` runs the open on an `OperationRunner` worker (WaitMode 500 ms, title "Opening",
    status IDS_OPENNING) while the panel queue waits.
  - `ArchiveOpenFailure` decides the box the way OpenAsArc_Msg does.
  - Used by `openRow` (Enter, Open Inside, `*`, `#`), `navigate(to:)` (only when the path does not
    end in a directory) and the command-line open.
- **A deadlock found and fixed on the way.** Hosting `OperationRunner.run` inside
  `DispatchQueue.main.sync` hung as soon as the open asked for a password. The main queue is
  serial, so the worker's own `main.sync` for the password dialog could never run. The hop is now
  `performOnMainRunLoop` (`CFRunLoopPerformBlock`, common modes). `PanelNestedArchives`'
  write-back had the same latent hang and uses it too (requests.md row to every scope).
- **Difference.** A cancelled `navigate` keeps the old listing. Windows has already bound the root
  by then, so it shows the root.

## 2. Passwords per archive level (`01 §8.7`, `01b §4.16`, PROGRESS 168)

**Windows.** Each `CFolderLink` has `UsePassword` / `Password` from its own `CFfpOpen` (a fresh
one per open, so nested opens are *not* pre-seeded in 26.03). Copy, Test and update operations use
`_parentFolders.Back()`'s password and write back what they asked for (PanelItemOpen.cpp:1566-1658,
PanelCopy.cpp:405-411). The nested write-back uses the parent level's password.

**Mac.**

- `SZArchive.password` is set by the bridge from the open, and by the nested-copy extraction (which
  is also pre-seeded from its level).
- `panel.rememberedPassword` is now the innermost level's (`PanelArchiveLevel`, a lock-protected
  weak reference updated in `folder`'s `didSet`).
- `copyItemsOut` and `copyItemsIn` store an asked password on the level. The write-back uses
  `archive.outerFolder?.archive?.password`.
- The port re-opens a chain where 7zFM reuses its links. The levels being left therefore lend their
  passwords to the re-opened levels: `reusablePassword` while asking, and a copy after the bind.
  Moving inside an encrypted archive asks once, as on Windows.

## 3. The command-line open (`01 §1.1`, `§9 #32`, PROGRESS 78)

For an **existing file**, `MainWindowController.openStartupPath(_:formatHint:closesWindowOnFailure:)`
uses `panel.openLaunchArchive`. This is needOpenArc, FM.cpp:975-1014.

- On failure it shows FM.cpp's box: 3005 or 3006 with the full path, then the level text.
- A window made for this path closes: the argv launch, where the app ends with its only window as
  7zFM does, and the extra windows of `openInFileManager`.
- A window that was already showing something keeps it, and the box is a sheet.
- Cancel closes without a box (`return -1` on E_ABORT).
- A path that does not exist binds its nearest existing folder (BindToPath's walk up).

## 4. Case sensitivity per volume (`01 §9 #24`, PROGRESS 140)

`SZFolder.volumeIsCaseSensitive(atPath:)` (`pathconf _PC_CASE_SENSITIVE`, nearest existing ancestor)
feeds:

- `PanelSnapshot.isCaseSensitive`, which drives the select masks (Select / Deselect / the address
  bar's wildcard);
- `indexOfItemNamed`, which has no case-insensitive fallback on a case-sensitive volume;
- the FS copy engine's "onto itself" checks (`FSFolderMac.cpp`, `ComparePathsOnVolume`);
- the new panel-level "Cannot copy files onto itself" check of `CApp::OnCopy` (App.cpp:663-668).

Archives keep the engine's rule (`g_CaseSensitive` is false on macOS). Sorting stays case-insensitive
and numeric, as the inventory asks.

## 5. Window chrome (PROGRESS 81, 83, 94, 108; parity B 20-22)

- **Toolbar.** The 14 upstream bitmaps (`Add.bmp` ... `Info2.bmp`, IDB_ADD 100 ... IDB_INFO2 156)
  were converted to PNG with the RGB(255,0,255) mask made transparent (`ImageList.AddMasked`). They
  are `toolbar-<name>-large|small` in the asset catalog. "Large Buttons" switches 48x36 / 24x24,
  "Show Buttons Text" the labels. The toolbar is hidden while both logical toolbars are off.
- **Splitter.** `PanelSplitView` is 4 pt (kSplitterWidth). kPanelSizeMin 120 was already in place.
  **Difference:** the ratio is stored as a Double, not a 16-bit value.
- **Status bar.** Four parts with right edges 220 / 320 / 420 / rest and a divider before parts
  1-3. A part that starts past a narrow panel's edge is hidden instead of hanging outside the window
  (the layout audit caught that).
- **Ver Edit / Commit / Revert / Diff** (IDM_VER_EDIT 580 ... IDM_VER_DIFF 583,
  `Commands/PanelVerCtrl.swift`) port `CApp::VerCtrl` and the `CFileMenu::Load` rule:
  - the `FM.7vc` store, `ConvertPath_to_Ctrl`, and `_7vc/<name>/NNN` history;
  - Commit's timestamp rounding (hour / minute / 2 s / 1 s);
  - Revert's Overwrite question (no extra buttons, No by default).

  "Read-only" is the owner's write bit.
- **Raw-property columns** (archgaps' XAR screenshot). The values were cut to their first dozen
  digits, so they now start wide enough for their usual value:
  - SHA-1 / checksum: 300 pt;
  - SHA-256: 470 pt;
  - reparse data: 200 pt;
  - others: 160 pt.

  Ordinary columns keep 7zFM's 100. On a 1200 pt window the XAR checksum column still begins to
  the right of the visible area, because XAR lists many columns before it. That is the column
  order upstream gives it.

## 6. Smaller items

- **Work dir "for removable drives only"** (PROGRESS 169, 01b §4.8). Both callers, the agent's
  `CWorkDirTempFile` and `SZUpdater`, go through upstream `GetWorkDir`, whose drive-type test is
  `_WIN32`-only, so it could not be done in the bridge alone. A guarded `#elif defined(__APPLE__)`
  hunk in `CPP/7zip/UI/Common/WorkDir.cpp` calls `MacPath_IsOnRemovableVolume`
  (`Mac/Core/Platform/MacVolume.cpp`: removable media, or ejectable and not internal). It is recorded
  in `upstream-patches.md` / `.diff`. With the Windows default (flag on, system temp), an update of
  an archive on an internal disk now writes its temp file next to the archive, as 7zFM does.
- **Temp folders** (PROGRESS 69). `SZTempOpen.createTemporaryDirectory(prefix:)` makes
  `<prefix><8 hex>` with mode 0700, retried on a clash (CTempDir::Create), instead of `mkdtemp`'s
  `-XXXXXX`. The e-mail folder stays `7zE-<uuid>` on purpose (requests.md).
- **Auto Refresh** (PROGRESS 642). It starts on in every launch, because CApp never saves it. The
  windows of one process still share it.

## 7. Declined or left open, and why

| Line | Item | Why |
|---|---|---|
| 186 | startup sweep of stale `7zO*` / `7zE*` | Not Windows behaviour, and unsafe here. After a failed write-back the modified copy is the *only* copy of the user's edit, and the 3010 box tells them its path (`keepTempDirectory`). A sweep would delete it. Another running instance's folders share the default temp root too. |
| 185 | exit waits for every watcher | Recorded as deliberately different (parity C). macOS watches files, not editor processes, and pending edits are asked about at quit (`TempOpenManager`). |
| 53 | codecs initialised lazily | The engine is linked statically, and `loadCodecs()` is a table fill with no file access. Moving it after the window would race the panel queues' own on-demand loads for nothing measurable. |
| 60 | encryption / SFX flags on `SZCodecs` | The Compress dialog's `g_Formats` table (`CompressModel`) is where 7-Zip keeps them. Duplicating them on `SZFormatInfo` would add a second source of truth and no feature. |
| 61 | `IFolderProperties`, `IFolderClone`, `IFolderArchiveUpdate` | 7zFM never calls the first two on its own folders, and the third is reached through `IFolderOperations`, which is bridged. |
| 432 | private pasteboard for 7-Zip to 7-Zip drops | The in-process drag session already names the source panel (`mac/archgaps`), which is the same thing in one process. |
| 498, 512, 638, 669, 677, 697, 698 | compress / tools / options / finder items | Outside this scope's code, and either verification debts (697/698 need Finder) or recorded as different (512: 7zFM's Extract dialog has no `-scrc`). Not touched. |
| 79, 80, 100, 110 | startup / shutdown order, menu localisation, start path | Already recorded as different in parity C. |

## 8. Verification

- `Mac/scripts/build.sh`: clean, no warnings in `Mac/`.
- `Mac/scripts/test.sh`: **378 passed**, 0 failed (was 363). `NavGapsBridgeTests` adds 15 tests:
  - the non-open text for a zip with a text prefix and for `-tgzip.tar` on a gzip of junk;
  - a split set of a broken 7z that opens with its 7z level's text;
  - no text for clean and tail-only archives;
  - a wrong password flagged encrypted, and the open password stored on the archive;
  - the nested copy using its level's password;
  - progress reaching the delegate, and cancel for the open and for the nested copy;
  - `7zO<8 hex>` names;
  - volume case and the case-aware lookup;
  - raw-column widths;
  - the removable test.
- `Mac/scripts/test.sh -H`: **91 passed**, 0 failed (was 78). `NavGapsTests` adds 13 app-hosted
  tests:
  - entering the broken split set shows the level text as a sheet;
  - Open Inside on a non-archive is silent;
  - a wrong password gives 3006, with the "Opening secret.7z" progress verified up behind the
    password dialog;
  - Cancel in the password dialog is silent;
  - the password stays per level and is not re-asked when binding inside the archive;
  - the address bar binds the folder of a non-archive;
  - the failed launch open shows the box and closes its window, and a reused window keeps its
    folder;
  - a launch with `-t7z` enters the archive, and a missing path binds the nearest folder;
  - four status parts;
  - toolbar bitmaps, sizes, hiding, and the 4 pt splitter;
  - a full Ver Edit / Commit / Edit / Revert cycle.

  `ArchGapsTests`' password test was rewritten for per-level passwords.
- The XCUITest shards were not run. Screenshots `navgaps-01..03` come from the app-hosted tests. The
  cached-display capture they use does not draw the status bar or the toolbar, so they show the
  panel only.

## 9. Files touched outside this scope's natural area

- **Upstream:** `CPP/7zip/UI/Common/WorkDir.cpp` (one guarded hunk, recorded).
- **Unowned:** `Mac/App/AppDelegate.swift` (one argument).
- **extract:** `Mac/Core/Internal/SZTempOpen.mm`, `Mac/Core/include/SZExtractor.h` (a comment).
- **finder:** `Mac/App/Integration/CommandExecutor.swift` (one argument).
- **fsfolder / bridge:** `Mac/Core/Internal/FSFolderMac.cpp`, `Mac/Core/SZFolder.mm` and `.h`,
  `Mac/Core/SZArchiveOpener.mm` and `.h`, the new `Mac/Core/Platform/MacVolume.cpp`.
- **Resources:** 14 `toolbar-*.imageset` in `Mac/Resources/Assets.xcassets`.
