# 7-Zip File Manager (7zFM) — Complete Feature Inventory for the macOS Port

Source snapshot: 7-Zip 26.03, branch `macos`, repository root `~/things/a.noindex/7zip`.
All paths below are relative to `CPP/` unless stated otherwise. `file:line` references point at
the Windows sources that define the behaviour; IDs are the resource / command IDs used by the
Windows build (they double as localization keys, see §7, so they must be preserved verbatim).

Sources inventoried: `7zip/UI/FileManager/*` (all .cpp/.h/.rc), `7zip/UI/GUI/*` (.cpp/.rc/*Res.h),
`7zip/GuiCommon.rc`, `7zip/UI/Common/*.h` (ZipRegistry, ExtractMode, UpdateAction, LoadCodecs,
PropIDUtils, WorkDir, CompressCall), `7zip/UI/Agent/*` (Agent, AgentOut, ArchiveFolder,
ArchiveFolderOut, ArchiveFolderOpen), `7zip/UI/Explorer/ContextMenu.*`, `Windows/Control/*`,
`Common/Lang.*`, `Windows/PropVariantConv.h`, `7zip/PropID.h`.

Conventions used in this document:

* **IDM_*** = menu command IDs (`FileManager/resource.h`), **IDS_*** = string IDs, **IDD_*** = dialog IDs,
  **IDC_/IDE_/IDB_/IDX_/IDT_/IDG_/IDL_*** = control IDs (combo / edit / button / checkbox / static text / group / list).
* "FS" = real file-system folder (`IsFSFolder()`), "Arc" = archive folder opened through the Agent (`IsArcFolder()`),
  "Hash folder" = archive whose handler is a hash-list handler (`IsHashFolder()`, `kpidIsHash`).
* `Panel.cpp:834-853` defines the folder-type predicates:
  `IsRootFolder()` type `"RootFolder"`, `IsFSFolder()` `"FSFolder"`, `IsFSDrivesFolder()` `"FSDrives"`,
  `IsAltStreamsFolder()` `"AltStreamsFolder"`, `IsArcFolder()` = type starts with `"7-Zip"`,
  `IsHashFolder()` = folder property `kpidIsHash` is `true`. `IsFolderTypeEqTo` compares
  `GetFolderTypeID()` (`Panel.cpp:818`, folder prop `kpidType`).
* "Operated items" = selected items if any are selected, else the focused item
  (`PanelItems.cpp:984 Get_ItemIndices_Operated`; `..` is never operated).
  "OperSmart" (`PanelItems.cpp:1015`) = operated items, but if only the focused item is used and it is
  not selected, nothing is selected at all → returns the focused item only.

---

## 1. Main window

### 1.1 Process, window class, startup

| Item | Value | Source |
|---|---|---|
| Executable | `7zFM.exe` (GUI subsystem), links `7z.dll` codecs via `LoadGlobalCodecs()` | `FM.cpp:577 WinMain2`, `FM.mak` |
| Window class | `"7-Zip::FM"` (`kWindowClass`) | `FM.cpp` (WinMain2, RegisterClass) |
| Window title (initial) | `"7-Zip"` | `FM.cpp` |
| Window title (running) | current folder path of the focused panel; `"7-Zip"` when path empty; two-panel mode shows the focused panel's path | `App.cpp:963 CApp::RefreshTitle`, `App.cpp:974 RefreshTitlePanel` |
| Single instance | none — every launch opens a new window | — |
| Command line | `7zFM.exe [path] [-t<arcType>]`. `path` = folder/archive to open in panel 0; `-t` forces an archive type for opening (`arcFormat` passed to `CPanel::BindToPath`). Parsing at `FM.cpp:639-702` (uses `GetCommands` `FM.cpp:428`). | `FM.cpp:639-702` |
| Startup actions | `LoadLangOneTime()` (§7), `SetMemoryLock()` for large pages (`FM.cpp:508`) if `ReadLockMemoryEnable()`, `Set_SymLink_Supported()` (`FM.cpp:527`), `Set_Wow64()` (`FM.cpp:461`), `OleInitialize`, `InitCommonControls`, `DeleteOldTempFiles()` (`PanelItemOpen.cpp:1815`, removes stale `7zE*`/`7zO*`/`7zS*` temp dirs older than the current session), read `CWindowInfo` (`ViewSettings.cpp:169`) to restore size/position/maximized/panels/splitter. | `FM.cpp:577-783` |
| Accelerator table | `IDR_ACCELERATOR1` (72): `F1 → IDM_HELP_CONTENTS`, `Alt+F12 → IDM_FOLDERS_HISTORY`. All other shortcuts are handled by the panel key handler (§3.7) or as menu-item text only. | `FileManager/resource.rc` |
| Icon | `IDI_ICON` (`FM.ico`) | `resource.rc` |
| Shutdown | `WM_CLOSE`/`WM_DESTROY`: `g_App.Save()` (`App.cpp:382`), `SaveWindowInfo` (`FM.cpp:849`), `g_App.ReleaseApp()` (`App.cpp:405`), `FreeGlobalCodecs()`. `CExitEventLauncher` (`PanelItemOpen.cpp:1104`) signals watcher threads that still monitor externally-opened temp files; they get `kExitTimeout` to finish. | `FM.cpp:890 WndProc` |

### 1.2 Layout (top to bottom)

`CApp::MoveSubWindows` (`FM.cpp:1176-1223`) lays out:

1. **Toolbar ReBar** (`_rebar`, `App.cpp:144 CreateToolbar`, only when at least one toolbar is visible) — full width, height from `RB_GETBARHEIGHT`.
2. **Panel area** — one or two `CPanel` windows side by side. Splitter width `kSplitterWidth = 4`, minimum panel width `kPanelSizeMin = 120`. The splitter position is stored as a ratio (`g_Splitter` position with denominator `1 << 16`) so it survives resizes; dragging happens in `WM_LBUTTONDOWN`/`WM_MOUSEMOVE`/`WM_LBUTTONUP` of `WndProc` (`FM.cpp:890+`, cursor `IDC_SIZEWE`). `xSizes[2]` are handed to `CApp::Create`.
3. Each panel owns its own status bar (there is no main-window status bar).

Each **panel** (`CPanel::OnCreate` `Panel.cpp:383-597`, `ChangeWindowSize` `Panel.cpp:605`) consists of, top to bottom:

| Sub-window | Details | Source |
|---|---|---|
| Panel ReBar | hosts the header toolbar band and the address combo band | `Panel.cpp:383+` |
| Header toolbar | single button `kParentFolderID = 100` ("Up one level", image `IDI_PARENT`/`VIEW_PARENTFOLDER` from the system `IDB_VIEW_SMALL_COLOR` bitmap); click → `OpenParentFolder()` | `Panel.cpp:383+`, `Panel.cpp:727 OnCommand` |
| Address bar | `CComboBoxEx` (`_headerComboBox`) with edit control subclassed by `CMyComboBoxEdit` (`Panel.cpp:276`), image list of system icons; dropdown list built on `CBN_DROPDOWN` (§3.9) | `Panel.cpp:257, 276`, `PanelFolderChange.cpp:627` |
| List view | `CMyListView` (`Panel.cpp:161`), styles `WS_CHILD|WS_VISIBLE|WS_TABSTOP|LVS_SHAREIMAGELISTS|LVS_SHOWSELALWAYS|LVS_EDITLABELS` plus one of `kStyles[] = {LVS_ICON, LVS_SMALLICON, LVS_LIST, LVS_REPORT}` selected by `_listViewMode` (default 3 = report). Extended styles: `LVS_EX_HEADERDRAGDROP`, plus `LVS_EX_FULLROWSELECT`/`LVS_EX_GRIDLINES`/`LVS_EX_ONECLICKACTIVATE|LVS_EX_TRACKSELECT`/`LVS_SINGLESEL` as set by `CApp::SetListSettings` (`App.cpp:73-115`) from settings ShowFullRow / ShowGrid / SingleClick / AlternativeSelection (§5). System small and large image lists attached (`SysIconUtils`). | `Panel.cpp:383+`, `Panel.cpp:871 SetListViewMode` |
| Status bar | `CStatusBar`, 4 parts with right edges `{220, 320, 420, -1}`; see §3.12 for content | `Panel.cpp:383+`, `PanelListNotify.cpp:759 Refresh_StatusBar` |

Both panels get `SetTimer(kTimerID, kTimerElapse = 1000 ms)`; on `WM_TIMER` `CPanel::OnTimer` (`PanelItems.cpp:1458`) asks the folder `IFolderWasChanged::WasChanged()` and reloads if changed (only while `_processTimer` is true and auto-refresh is on; `CDisableTimerProcessing` suspends it during operations).

### 1.3 Toolbars

`App.cpp:144-282`. Two toolbars live in one ReBar band each:

| Toolbar | Buttons (command ID → label string ID → bitmap large/small) | Source |
|---|---|---|
| Archive toolbar (`g_ArchiveButtons`) | `kMenuCmdID_Toolbar_Add 1070` → `IDS_ADD 7200` "Add" → `IDB_ADD 100`/`IDB_ADD2 150`; `kMenuCmdID_Toolbar_Extract 1071` → `IDS_EXTRACT 7201` → `IDB_EXTRACT 101`/`151`; `kMenuCmdID_Toolbar_Test 1072` → `IDS_TEST 7202` → `IDB_TEST 102`/`152` | `App.cpp` (`g_ArchiveButtons`) |
| Standard toolbar (`g_StandardButtons`) | `IDM_COPY_TO 546` → `IDS_BUTTON_COPY 7203` → `IDB_COPY 103`/`153`; `IDM_MOVE_TO 547` → `IDS_BUTTON_MOVE 7204` → `IDB_MOVE 104`/`154`; `IDM_DELETE 548` → `IDS_BUTTON_DELETE 7205` → `IDB_DELETE 105`/`155`; `IDM_PROPERTIES 551` → `IDS_BUTTON_INFO 7206` → `IDB_INFO 106`/`156` | `App.cpp` (`g_StandardButtons`) |

Bitmaps: large = 48×36 (`IDB_*`), small = 24×24 (`IDB_*2`). Toolbar flags (persisted as `Toolbars` mask, §5.2):
bit0 `ShowButtonsLables`, bit1 `LargeButtons`, bit2 `ShowStandardToolbar`, bit3 `ShowArchiveToolbar`;
bit31 set means "never saved → defaults" = labels shown unless the screen is small (`IsSmallScreen`), small buttons, both toolbars visible (`App.cpp:284 CApp::Create` → `ReadToolbar`).
Toolbar clicks: `kMenuCmdID_Toolbar_Add/Extract/Test` are routed by `OnMenuCommand` (`MyLoadMenu.cpp:805`) to `CPanel::AddToArchive / ExtractArchives / TestArchives`; the standard toolbar IDs are ordinary menu IDs. `CApp::ReloadToolbars` (`App.cpp:255`) rebuilds after Options/lang changes; `SaveToolbarChanges` (`App.cpp:276`) persists the mask.

### 1.4 Panels, focus, two-panel mode

* `kNumDefaultPanels = 1`; `CApp::Create` (`App.cpp:284-358`) creates `NumPanels` panels (1 or 2) from `CWindowInfo` or default. Each panel's start path: command-line path for panel 0 if given, else `ReadPanelPath(i)` (`ViewSettings.cpp:265`), else empty (= Root folder). If the stored path cannot be bound the panel falls back to the root folder (`BindToPathAndRefresh` `PanelFolderChange.cpp:315`).
* Per-panel list mode from `CListMode` (`ViewSettings.cpp:237`, packed byte per panel, default 3), flat-view flag from `ReadFlatView(panelIndex)` (`RegistryUtils.cpp:182`).
* `CApp::SwitchOnOffOnePanel` (`App.cpp:360-380`): F9 / `IDM_VIEW_TWO_PANELS` toggles between 1 and 2 panels. When opening the second panel it is created with the current panel's path (`CreateOnePanel` `App.cpp:117`); when closing, the non-focused panel is released.
* Focus: `CApp::SetFocusedPanel` (`PanelDrag.cpp:2990`), `GetFocusedPanelIndex` (`App.cpp:914`), `CPanelCallbackImp::PanelWasFocused` (`App.cpp:63`) refreshes the title. `Tab` switches panels (`CPanelCallbackImp::OnTab` `App.cpp:42`, only in two-panel mode). `Alt+F1`/`Alt+F2` focus the address bar of panel 0/1 (`SetFocusToPath` `App.cpp:49`).
* Custom messages posted to the panel window: `kShiftSelectMessage` (`WM_USER+1`, group selection after Shift+arrow), `kReLoadMessage` (`+2`, reload after rename), `kSetFocusToListView` (`+3`), `kOpenItemChanged` (`+4`, watcher thread reports edited temp file), `kRefresh_StatusBar` (`+5`) — dispatched in `CPanel::OnMessage` (`Panel.cpp:120-159`).

### 1.5 Window persistence

`CWindowInfo` (`ViewSettings.cpp:141 Save`, `169 Read`): rectangle (`left,top,right,bottom`), `maximized`, `numPanels`, `currentPanel`, `splitterPos`. Saved on close (`FM.cpp:849 SaveWindowInfo`) and restored on start; if the stored rectangle is off-screen it is ignored (`FM.cpp:577+`, `IsWindowVisible`-style check via `GetWindowPlacement`). Details of the stored bytes in §5.2.

---

## 2. Menu bar

Menu resource `IDM_MENU` (71, `MENUEX`) in `FileManager/resource.rc`; loaded and localized by `MyLoadMenu()` (`MyLoadMenu.cpp:323-383`), which also copies the popup menus so the File menu can be rebuilt per context (`CopyMenu`, `MyLoadMenu.cpp:299`). `OnMenuActivating` (`MyLoadMenu.cpp:385-563`) refreshes dynamic state each time a top-level menu opens; `OnMenuCommand` (`MyLoadMenu.cpp:805-964`) dispatches. Every top-level popup has a string ID that is also its lang ID (`IDM_FILE 500`, `IDM_EDIT 501`, `IDM_VIEW 502`, `IDM_FAVORITES 503`, `IDM_TOOLS 504`, `IDM_HELP 505`).

The "&" mnemonics and "\t" accelerator texts are part of the menu strings (and of the lang-file lines). Accelerator texts are informational — the actual key handling is in `PanelKey.cpp` (§3.7) except F1 and Alt+F12.

### 2.1 File menu (`IDM_FILE 500`)

Rebuilt for the current panel by `CFileMenu::Load` (`MyLoadMenu.cpp:588-734`) each time it opens (`CPanel::CreateFileMenu` `PanelMenu.cpp:787, 921`); the same builder produces the "File" part of the list-view context menu (`§2.8`). Enabled/hidden rules (evaluated in `Load`):

* `isFsFolder = IsFSFolder()`, `isArc = IsArcFolder()`, `isHash = IsHashFolder()`, `readOnly = IsThereReadOnlyFolder()` (`PanelMenu.cpp:868`: any folder in the chain reports `kpidReadOnly`).
* `numItems` = number of operated items, `isFsFile` = exactly one operated item that is a regular FS file (used for Split/Combine/VerCtrl/Link).
* `allAreFiles`, `isAltStreamsSupported` (folder implements `IFolderAltStreams` and the item supports it).

| Order | Text (resource) | ID | Accelerator | Enabled / visible condition | Handler |
|---|---|---|---|---|---|
| 1 | `&Open\tEnter` | `IDM_OPEN 540` | Enter (list activate) | disabled in hash folder | `ExecuteFileCommand` `MyLoadMenu.cpp:736` → `CPanel::OpenSelectedItems(true)` `PanelItems.cpp:1096` |
| 2 | `Open &Inside\tCtrl+PgDn` | `IDM_OPEN_INSIDE 541` | Ctrl+PgDn | disabled in hash folder | `OpenFocusedItemAsInternal(NULL)` `PanelItems.cpp:1084` |
| 3 | `Open Inside *` | `IDM_OPEN_INSIDE_ONE 590` | — | disabled in hash folder | `OpenFocusedItemAsInternal(L"*")` (open with first matching handler, no parser) |
| 4 | `Open Inside #` | `IDM_OPEN_INSIDE_PARSER 591` | — | disabled in hash folder | `OpenFocusedItemAsInternal(L"#")` (raw parser: scan for embedded archives) |
| 5 | `Open O&utside\tShift+Enter` | `IDM_OPEN_OUTSIDE 542` | Shift+Enter | disabled in hash folder | `OpenSelectedItems(false)` (external app / shell) |
| 6 | `&View\tF3` | `IDM_FILE_VIEW 543` | F3 | disabled in hash folder | `EditItem(false)` `PanelItems.cpp:1043` |
| 7 | `&Edit\tF4` | `IDM_FILE_EDIT 544` | F4 | disabled in hash folder | `EditItem(true)` |
| — | separator | | | | |
| 8 | `Rena&me\tF2` | `IDM_RENAME 545` | F2 | disabled if `readOnly` | `RenameFile()` `PanelOperations.cpp:478` (starts list label edit) |
| 9 | `&Copy To...\tF5` | `IDM_COPY_TO 546` | F5 | disabled in hash folder | `CPanelCallbackImp::OnCopy(false,false)` → `CApp::OnCopy` `App.cpp:565` |
| 10 | `&Move To...\tF6` | `IDM_MOVE_TO 547` | F6 | disabled if `readOnly` or hash folder | `CApp::OnCopy(true,false)` |
| 11 | `&Delete\tDel` | `IDM_DELETE 548` | Del (Shift+Del = permanent) | disabled if `readOnly` | `DeleteItems(!IsKeyDown(VK_SHIFT))` `PanelOperations.cpp:112` |
| — | separator | | | | |
| 12 | `S&plit file...` | `IDM_SPLIT 549` | — | enabled only if `isFsFile` (single FS file) | `CApp::Split()` `PanelSplitFile.cpp:235` |
| 13 | `Com&bine files...` | `IDM_COMBINE 550` | — | enabled only if `isFsFile` | `CApp::Combine()` `PanelSplitFile.cpp:419` |
| — | separator | | | | |
| 14 | `P&roperties\tAlt+Enter` | `IDM_PROPERTIES 551` | Alt+Enter | always | `Properties()` `PanelMenu.cpp:172` |
| 15 | `Comme&nt...\tCtrl+Z` | `IDM_COMMENT 552` | Ctrl+Z | disabled if `readOnly` or hash | `ChangeComment()` `PanelOperations.cpp:487` |
| 16 | popup `CRC SHA` (`IDM_CRC 553`) | | | always enabled; items compute hashes of the operated items (§3.13) | `CApp::CalculateCrc(name)` `PanelCrc.cpp:413` |
| 16a | `CRC-32` | `IDM_CRC32 102` | | | `CalculateCrc("CRC32")` |
| 16b | `CRC-64` | `IDM_CRC64 103` | | | `"CRC64"` |
| 16c | `XXH64` | `IDM_XXH64 120` | | | `"XXH64"` |
| 16d | `MD5` | `IDM_MD5 122` | | | `"MD5"` |
| 16e | `SHA-1` | `IDM_SHA1 104` | | | `"SHA1"` |
| 16f | `SHA-256` | `IDM_SHA256 105` | | | `"SHA256"` |
| 16g | `SHA-384` | `IDM_SHA384 106` | | | `"SHA384"` |
| 16h | `SHA-512` | `IDM_SHA512 107` | | | `"SHA512"` |
| 16i | `SHA3-256` | `IDM_SHA3_256 108` | | | `"SHA3-256"` |
| 16j | `BLAKE2sp` | `IDM_BLAKE2SP 121` | | | `"BLAKE2sp"` |
| 16k | `*` | `IDM_HASH_ALL 101` | | | `CalculateCrc("*")` (all methods) |
| 17 | `Diff` | `IDM_DIFF 554` | — | hidden if no Diff tool configured (`ReadRegDiff` empty); disabled in hash folder | `CApp::DiffFiles()` `PanelItemOpen.cpp:747` |
| — | separator | | | | |
| 18 | `Create Folder\tF7` | `IDM_CREATE_FOLDER 555` | F7 | disabled if `readOnly` or hash | `CreateFolder()` `PanelOperations.cpp:363` |
| 19 | `Create File\tCtrl+N` | `IDM_CREATE_FILE 556` | Ctrl+N (also Shift+F4) | disabled if `readOnly` or hash | `CreateFile()` `PanelOperations.cpp:426` |
| — | separator | | | | |
| 20 | `Link...` | `IDM_LINK 558` | — | disabled unless FS folder with exactly one operated item; hidden under CE | `CApp::Link()` (`LinkDialog.cpp`) |
| 21 | `Alternate Streams` | `IDM_ALT_STREAMS 559` | — | disabled unless `isAltStreamsSupported`; hidden under CE | `OpenAltStreams()` `PanelFolderChange.cpp:1082` |
| 22-25 | `Ver Edit (&1)`, `Ver Commit`, `Ver Revert`, `Ver Diff (&0)` | `IDM_VER_EDIT 580`, `IDM_VER_COMMIT 581`, `IDM_VER_REVERT 582`, `IDM_VER_DIFF 583` | — | shown only when registry `7vc` path is set (`ReadReg_VerCtrlPath`) and `isFsFile` with size < 2 GB; read-only file → only "Ver Edit"; writable file → Commit/Revert/Diff | `CApp::VerCtrl(id)` `VerCtrl.cpp:141` |
| — | separator | | | | |
| 26 | `E&xit\tAlt+F4` | `IDCLOSE 8` | Alt+F4 | hidden in the context-menu variant | `SendMessage(WM_CLOSE)` |

Notes:
* In the context-menu variant (`CFileMenu::Load` with `programMenu=false`) `IDCLOSE` is removed and the items are inserted at `startPos`.
* Hash-folder rule (`isHash`): disables Open/Open Inside*/Open Outside/View/Edit/Copy To/Move To/Comment/Create Folder/Create File/Link/Diff (`MyLoadMenu.cpp:588+`).

### 2.2 Edit menu (`IDM_EDIT 501`)

| Text | ID | Key | Handler |
|---|---|---|---|
| `Select &All\tShift+[Grey +]` | `IDM_SELECT_ALL 600` | Shift+Num+ / Ctrl+A | `SelectAll(true)` `PanelSelect.cpp:206` |
| `Deselect All\tShift+[Grey -]` | `IDM_DESELECT_ALL 601` | Shift+Num- | `SelectAll(false)` |
| `&Invert Selection\t[Grey *]` | `IDM_INVERT_SELECTION 602` | Num* | `InvertSelection()` `PanelSelect.cpp:213` |
| `Select...\t[Grey +]` | `IDM_SELECT 603` | Num+ | `SelectSpec(true)` `PanelSelect.cpp:154` |
| `Deselect...\t[Grey -]` | `IDM_DESELECT 604` | Num- | `SelectSpec(false)` |
| (MENUBARBREAK) | | | |
| `Select by Type\tAlt+[Grey +]` | `IDM_SELECT_BY_TYPE 605` | Alt+Num+ | `SelectByType(true)` `PanelSelect.cpp:169` |
| `Deselect by Type\tAlt+[Grey -]` | `IDM_DESELECT_BY_TYPE 606` | Alt+Num- | `SelectByType(false)` |

All always enabled. Dispatched in `OnMenuCommand` (`MyLoadMenu.cpp:805+`).

### 2.3 View menu (`IDM_VIEW 502`)

Radio/check state is refreshed in `OnMenuActivating` (`MyLoadMenu.cpp:420-436`).

| Text | ID | Key | State | Handler |
|---|---|---|---|---|
| `Lar&ge Icons\tCtrl+1` | `IDM_VIEW_LARGE_ICONS 700` | Ctrl+1 | radio, checked when `_listViewMode == 0` | `SetListViewMode(0)` `Panel.cpp:871` |
| `S&mall Icons\tCtrl+2` | `IDM_VIEW_SMALL_ICONS 701` | Ctrl+2 | radio (mode 1) | `SetListViewMode(1)` |
| `&List\tCtrl+3` | `IDM_VIEW_LIST 702` | Ctrl+3 | radio (mode 2) | `SetListViewMode(2)` |
| `&Details\tCtrl+4` | `IDM_VIEW_DETAILS 703` | Ctrl+4 | radio (mode 3, **default**) | `SetListViewMode(3)` |
| separator | | | | |
| `Arrange by Name\tCtrl+F3` | `IDM_VIEW_ARANGE_BY_NAME 710` | Ctrl+F3 | radio, checked when `_sortID == kpidName` | `SortItemsWithPropID(kpidName)` `PanelSort.cpp:256` |
| `Arrange by Type\tCtrl+F4` | `IDM_VIEW_ARANGE_BY_TYPE 711` | Ctrl+F4 | radio (`kpidExtension`) | `SortItemsWithPropID(kpidExtension)` |
| `Arrange by Date\tCtrl+F5` | `IDM_VIEW_ARANGE_BY_DATE 712` | Ctrl+F5 | radio (`kpidMTime`) | `SortItemsWithPropID(kpidMTime)` |
| `Arrange by Size\tCtrl+F6` | `IDM_VIEW_ARANGE_BY_SIZE 713` | Ctrl+F6 | radio (`kpidSize`) | `SortItemsWithPropID(kpidSize)` |
| `No Sort\tCtrl+F7` | `IDM_VIEW_ARANGE_NO_SORT 730` | Ctrl+F7 | radio (`kpidNoProperty`) | `SortItemsWithPropID(kpidNoProperty)` (archive order) |
| separator | | | | |
| `Flat View` | `IDM_VIEW_FLAT_VIEW 731` | — | check: `GetFlatMode()` | `ChangeFlatMode()` `Panel.cpp:894` |
| `&2 Panels\tF9` | `IDM_VIEW_TWO_PANELS 732` | F9 | check: `NumPanels == 2` | `SwitchOnOffOnePanel()` `App.cpp:360` |
| popup `2017` (`IDM_VIEW_TIME_POPUP 760`) | | | popup label is replaced at open time by the current time formatted at the panel's timestamp level; items are `IDM_VIEW_TIME + k` (761+k) for the 5 levels DAY(-3)/MIN(-1)/SEC(0)/NTFS(7)/NS(9) each showing the current date/time at that precision, radio-checked on `_timestampLevel`; last item `IDM_VIEW_TIME_UTC 799` "UTC" check = `g_Timestamp_Show_UTC` | `MyLoadMenu.cpp:385+ (Is_MenuItem_TimePopup 133)`; handler sets `_timestampLevel` / toggles UTC and redraws |
| popup `Toolbars` (`IDM_VIEW_TOOLBARS 733`) | | | | |
| ↳ `Archive Toolbar` | `IDM_VIEW_ARCHIVE_TOOLBAR 750` | | check `ShowArchiveToolbar` | toggle + `ReloadToolbars` + `SaveToolbarChanges` |
| ↳ `Standard Toolbar` | `IDM_VIEW_STANDARD_TOOLBAR 751` | | check `ShowStandardToolbar` | same |
| ↳ separator | | | | |
| ↳ `Large Buttons` | `IDM_VIEW_TOOLBARS_LARGE_BUTTONS 752` | | check `LargeButtons` | same |
| ↳ `Show Buttons Text` | `IDM_VIEW_TOOLBARS_SHOW_BUTTONS_TEXT 753` | | check `ShowButtonsLables` | same |
| `Open Root Folder\t\\` | `IDM_OPEN_ROOT_FOLDER 734` | `\` or `/` typed in list | — | `OpenRootFolder()` `PanelFolderChange.cpp:1025` |
| `Up One Level\tBackspace` | `IDM_OPEN_PARENT_FOLDER 735` | Backspace | — | `OpenParentFolder()` `PanelFolderChange.cpp:917` |
| `Folders History...\tAlt+F12` | `IDM_FOLDERS_HISTORY 736` | Alt+F12 | — | `FoldersHistory()` `PanelFolderChange.cpp:866` |
| `&Refresh\tCtrl+R` | `IDM_VIEW_REFRESH 737` | Ctrl+R | — | `OnReload(false)` `PanelItems.cpp:1451` |
| `Auto Refresh` | `IDM_VIEW_AUTO_REFRESH 738` | — | check `g_App.Get_AutoRefresh_Mode()` (default on) | `g_App.Change_AutoRefresh_Mode()` (`MyLoadMenu.cpp:890`) |

### 2.4 Favorites menu (`IDM_FAVORITES 503`)

Built dynamically in `OnMenuActivating` (`MyLoadMenu.cpp:385+`):

| Text | ID | Key | Handler |
|---|---|---|---|
| popup `Add folder to Favorites as` (`IDM_ADD_TO_FAVORITES 800`) with 10 items `Bookmark i` (`IDS_BOOKMARK 801` + " " + i, i = 0..9), accelerator `Alt+Shift+<i>` | `kSetBookmarkMenuID (810) + i` | Alt+Shift+0..9 | `CPanel::SetBookmark(i)` `PanelFolderChange.cpp:335` → `SaveFastFolders` |
| separator | | | |
| 10 items: bookmark path (truncated to 100 chars, `"-"` if empty), accelerator `Alt+<i>` | `kOpenBookmarkMenuID (830) + i` | Alt+0..9 / RightCtrl+0..9 | `CPanel::OpenBookmark(i)` `PanelFolderChange.cpp:340` → `BindToPathAndRefresh` |

Bookmarks list = `CFolderHistory` of exactly 10 strings (`ReadFastFolders` / `SaveFastFolders`, §5.2). `SetBookmark` stores the current folder's full path (`GetFsPath()`/`_currentFolderPrefix`).

### 2.5 Tools menu (`IDM_TOOLS 504`)

| Text | ID | Handler |
|---|---|---|
| `&Options...` | `IDM_OPTIONS 900` | `OptionsDialog(hwnd, g_hInstance)` `OptionsDialog.cpp:32` (§4.21) |
| separator | | |
| `&Benchmark` | `IDM_BENCHMARK 901` | `MyBenchmark(false)` `MyLoadMenu.cpp:798` → `Benchmark(totalMode=false)` in `CompressCall.cpp` → spawns `7zG.exe b` |
| `Benchmark2` | `IDM_BENCHMARK2 902` | shown only if the Diff path is set (developer switch); `MyBenchmark(true)` → `7zG b -mm=*` "total" mode (§4.25) |
| separator | | |
| `Delete Temporary Files...` | `IDM_TEMP_DIR 910` | `CBrowseDialog2` (§4.3) opened on the system temp folder |

### 2.6 Help menu (`IDM_HELP 505`)

| Text | ID | Key | Handler |
|---|---|---|---|
| `&Contents...\tF1` | `IDM_HELP_CONTENTS 960` | F1 | `ShowHelpWindow(kHelpTopic = "start.htm")` (HtmlHelp on `7-zip.chm`) |
| separator | | | |
| `&About 7-Zip...` | `IDM_ABOUT 961` | — | `CAboutDialog` (§4.1) |

### 2.7 Command dispatch summary

`OnMenuCommand(HWND, id)` (`MyLoadMenu.cpp:805-964`):
* `IDCLOSE` → `WM_CLOSE`; `IDM_VIEW_*` (modes, sorts, flat, panels, toolbars, time levels, root/parent/history/refresh/auto-refresh); `IDM_SELECT*`/`IDM_INVERT_SELECTION`/`IDM_*_BY_TYPE`; `IDM_OPTIONS`; `IDM_BENCHMARK(2)`; `IDM_TEMP_DIR`; `IDM_HELP_CONTENTS`; `IDM_ABOUT`; `kMenuCmdID_Toolbar_Add/Extract/Test`; bookmark IDs; `IDM_VER_*` → `CApp::VerCtrl`.
* Everything else → `ExecuteFileCommand(id)` (`MyLoadMenu.cpp:736-796`) which maps the File-menu IDs listed in §2.1 (and `IDM_CRC*`/`IDM_HASH_ALL` → `CalculateCrc`).
* `FM.cpp:877 ExecuteCommand` handles `WM_COMMAND` from accelerators/toolbars and forwards to `OnMenuCommand`.

### 2.8 Context menus

**List-view item context menu** — `CPanel::OnContextMenu(HANDLE, x, y)` (`PanelMenu.cpp:1083-1160`):
* Invoked by right-click (`NM_RCLICK`, `PanelItems.cpp:1385 OnRightClick`) on items, or by the keyboard (`WM_CONTEXTMENU` with `x,y == -1` → positioned at the focused item's rectangle).
* Right-click on the header (`x,y` inside header) → column context menu (below).
* Menu composition (`PanelMenu.cpp:1083+`):
  1. If the panel is an FS folder (not root/drives/network) and `ShowSystemMenu` is off, the **shell context menu** of the operated items is *not* inlined; instead `CreateSevenZipMenu` (`PanelMenu.cpp:792`) inserts the 7-Zip Explorer commands (`CZipContextMenu::QueryContextMenu`, IDs from `kSevenZipStartMenuID = 1100`, see §2.9), then `CreateFileMenu` (`PanelMenu.cpp:921`) appends the File-menu items from §2.1 (without Exit).
  2. If `ShowSystemMenu` (Settings page) is on and the folder is FS, `CreateSystemMenu` (`PanelMenu.cpp:688`) queries the shell `IContextMenu` for the items' PIDLs (`CreateShellContextMenu` `PanelMenu.cpp:504`) with `CMF_EXPLORE | (Shift ? CMF_EXTENDEDVERBS : 0)` and inserts it as a `System` submenu (`IDS_SYSTEM 7103`) whose IDs start at `kSystemStartMenuID = 1500`.
  3. Selected ID ≥ 1500 → `InvokePluginCommand(id, systemContextMenu, ...)` (`PanelMenu.cpp:999`) invokes the shell verb (`CMINVOKECOMMANDINFO` with the item's folder as working dir); 1100..1499 → 7-Zip context command (`CZipContextMenu::InvokeCommand`); otherwise → `ExecuteFileCommand`.
* Before modifying operations `CheckBeforeUpdate(resourceID)` (`PanelMenu.cpp:882`) refuses with `IDS_OPERATION_IS_NOT_SUPPORTED 6008` if a read-only folder is in the chain, and `IDS_MESSAGE_UNSUPPORTED_OPERATION_FOR_LONG_PATH_FOLDER 3013` for super-long paths.

**Column header context menu** — `ShowColumnsContextMenu(x, y)` (`PanelItems.cpp:1396-1449`): one check item per available column (`_columns` property list, label = property name), the first (Name) column is grayed/always on; toggling sets `IsVisible` and re-inits columns; result persisted via `SaveListViewInfo` (§5.3).

**Address-bar drop-down** — see §3.9.

**Drag-and-drop right-button menu** — see §3.15 (`NDragMenu`).

**Temp-files browser (Browse2) context menu** — see §4.3.

### 2.9 7-Zip Explorer commands as seen in the FM context menu (`Explorer/ContextMenu.cpp`)

`CZipContextMenu::Init_For_7zFM()` then `QueryContextMenu` (IDs `kSevenZipStartMenuID 1100 + n`). Commands (`enum_CommandInternalID`, `ContextMenu.h:74-101`) and their labels/behaviour when invoked from 7zFM:

| Command | Label (IDS in `Explorer/resource.h`) | Shown when | Action |
|---|---|---|---|
| `kOpen` | "Open archive" | single item, extension not in `kExtractExcludeExtensions` and looks like archive | opens in 7zFM (same process → `BindToPath`) |
| `kOpen` sub-menu ("Open archive >") | `*`, `#`, `#:e`, `7z`, `zip`, `cab`, `rar`, … | single file | opens with the specified type / parser |
| `kExtract` | "Extract files..." | any archive-ish selection | `7zG x -o<dir> -spe -ad -snz…` via `ExtractArchives` (§8) |
| `kExtractHere` | "Extract Here" | | `ExtractArchives` with outFolder = archive dir, no dialog |
| `kExtractTo` | `Extract to "<name>\"` | | out folder `GetSubFolderNameForExtract(arcPath)` (archive base name; for `.tar.gz`-like double extensions the inner name), no dialog |
| `kTest` | "Test archive" | | `TestArchives` |
| `kCompress` | "Add to archive..." | | `CompressFiles(..., showDialog=true)` |
| `kCompressEmail` | "Compress and email..." | | same + `-seml` |
| `kCompressTo7z` / `kCompressToZip` (+Email) | `Add to "<name>.7z"` / `"<name>.zip"` | | `CompressFiles(archiveName, type, showDialog=false)` |
| `kHash_*` sub-menu "CRC SHA >" | CRC-32, CRC-64, XXH64, MD5, SHA-1, SHA-256, SHA-384, SHA-512, SHA3-256, BLAKE2sp, `*`, `SHA-256 -> file.sha256`, `Checksum : Test` | | `CalcChecksum` → `7zG h -scrc<name>` (§8.6); "-> file" generates a hash file; "Test" verifies a hash-list file |

Which commands appear is filtered by the `ContextMenu` flags mask (§5.5, `NContextMenuFlags`) and by the item selection. `kExtractExcludeExtensions` (`ContextMenu.cpp:494-517`) lists extensions that are never offered Open/Extract/Test: `3gp aac ans ape asc asm asp aspx avi awk bas bat bmp c cs cls clw cmd cpp csproj css ctl cxx def dep dlg dsp dsw eps f f77 f90 f95 fla flac frm gif h hpp hta htm html hxx ico idl inc ini inl java jpeg jpg js la lnk log mak manifest wmv mov mp3 mp4 mpe mpeg mpg m4a ofr ogg pac pas pdf php php3 php4 php5 phptml pl pm png ps py pyo ra rb rc reg rka rm rtf sed sh shn shtml sln sql srt swa tcl tex tiff tta txt vb vcproj vbs mkv wav webm wma wv xml xsd xsl xslt`. `kOpenTypes` (`:524`) for the "Open >" sub-menu: `""`, `*`, `#`, `#:e`, `7z`, `zip`, `cab`, `rar` (the empty one is the plain "Open archive").

---

## 3. Panel behaviours

### 3.1 View modes

`CPanel::SetListViewMode(index)` (`Panel.cpp:871-892`): index 0..3 → `LVS_ICON / LVS_SMALLICON / LVS_LIST / LVS_REPORT`; stored in `_listViewMode` (default 3) and persisted per panel in `ListMode` (§5.2). Changing the style keeps items and selection. Only report mode shows columns; other modes show the item name with the small (list/small icons) or large (icons) system icon.

### 3.2 Columns

`CPanel::InitColumns()` (`PanelItems.cpp:96-312`) builds `_columns` from:
1. `IFolderFolder::GetNumberOfProperties / GetPropertyInfo` of the current folder (skipping `kpidIsDir`), in the folder's order (`ItemProperty_Compare_NameFirst` `PanelItems.cpp:90` moves `kpidName` first).
2. Raw properties (`IArchiveGetRawProps`) if the folder exposes them (`IFolderProperties` / archive raw props such as `kpidNtSecure`, `kpidNtReparse`).
3. Persisted column info `CListViewInfo::Read(GetFolderTypeID())` (`ViewSettings.cpp:80`): order, visibility, width, sort ID and direction per **folder type ID** (`"FSFolder"`, `"FSDrives"`, `"RootFolder"`, `"NetFolder"`, `"AltStreamsFolder"`, `"7-Zip.<ArcType>"`).

Defaults (`GetColumnVisible` `PanelItems.cpp:25-51`): for FS folders the columns `kpidATime`, `kpidChangeTime`, `kpidAttrib`, `kpidPackSize`, `kpidINode`, `kpidLinks`, `kpidNtReparse` are hidden; everything else visible. Widths: `kpidName` 160 px, others 100 px (`PanelItems.cpp:96+`). Alignment (`GetColumnAlign` `PanelItems.cpp:53-88`): strings left, numbers/sizes right, times left, booleans center (`VT_BOOL`), `kpidPath/kpidName` left.

Default sort: `_sortID` from persisted info if present, else `kpidName` ascending for FS / AltStreams / Arc folders and `kpidNoProperty` (0, natural order) for the others (`PanelItems.cpp:96+`).

Column header click → `OnColumnClick` (`PanelSort.cpp:281`) → `SortItemsWithPropID` (`PanelSort.cpp:256`); header drag reorders (`LVS_EX_HEADERDRAGDROP`); widths and order are saved by `SaveListViewInfo` (`PanelItems.cpp:1322`) on folder change and exit.

#### Columns per folder type (PROPIDs from `7zip/PropID.h`, names from `PropertyName.rc` = `1000 + kpid`)

| Folder type | Properties exposed (`GetPropertyInfo` table) | Source |
|---|---|---|
| RootFolder | `kpidName` (4) only | `RootFolder.cpp` `kProps` |
| FSDrives | `kpidName`, `kpidTotalSize` (56), `kpidFreeSpace` (57), `kpidType` (20), `kpidVolumeName` (59), `kpidFileSystem` (24), `kpidClusterSize` (58) | `FSDrives.cpp` `kProps` |
| FSFolder | `kpidName` 4, `kpidSize` 7, `kpidMTime` 12, `kpidCTime` 10, `kpidATime` 11, `kpidChangeTime` 98, `kpidAttrib` 9, `kpidPackSize` 8, `kpidINode` 91, `kpidLinks` 37, `kpidComment` 28, `kpidNumSubDirs` 31, `kpidNumSubFiles` 32, and `kpidPrefix` 30 (flat mode only); raw prop `kpidNtReparse` 89 | `FSFolder.cpp` `kProps` / `GetPropertyInfo` |
| AltStreamsFolder | `kpidName`, `kpidSize`, `kpidPackSize` | `AltStreamsFolder.cpp` |
| NetFolder | `kpidName`, `kpidLocalName` 60, `kpidComment`, `kpidProvider` 61 | `NetFolder.cpp` |
| Archive (`7-Zip.<type>`) | the archive handler's item properties with `kpidPath` renamed to `kpidName` (`CAgent::GetPropertyInfo` `Agent.cpp:1881-1890`), plus `kpidNumSubDirs`, `kpidNumSubFiles` (for folders) and `kpidPrefix` (flat mode) added by `CAgentFolder` (`Agent.cpp` `GetNumberOfProperties/GetPropertyInfo`), plus raw properties (`kpidNtSecure` 86, `kpidNtReparse` 89, …) if the handler implements `IArchiveGetRawProps` | `Agent.cpp` |

Other PROPIDs used by the FM as *item* values (not columns): `kpidIsDir` 6, `kpidIsAltStream` 78, `kpidIsDeleted` 84, `kpidOutName` 94 (name to use when copying out of FSDrives / hash folders), `kpidReadOnly` 93 (folder-level), `kpidType` 20 (folder-level), `kpidIsHash` 97 (folder-level), `kpidPath` 3, `kpidErrorType`/`kpidError`/`kpidErrorFlags`/`kpidWarning`/`kpidWarningFlags`/`kpidOffset`/`kpidPhySize`/`kpidTailSize` (archive levels, §3.11), `kpidTotalSize`/`kpidFreeSpace`/`kpidClusterSize`/`kpidVolumeName`/`kpidFileSystem` (drives).

### 3.3 Sorting

`PanelSort.cpp`:
* `CompareFileNames_ForFolderList(s1, s2)` (`PanelSort.cpp:14-51`): case-insensitive, numeric-aware ("file2" < "file10"), digit runs compared by value then by length; ties broken by `MyStringCompareNoCase`.
* `CompareItems2` (`PanelSort.cpp:98-177`) — full comparison used by `ListView_SortItems`:
  1. `..` (index `kParentIndex = -1`) always first.
  2. Directories before files (unless sorting by `kpidNoProperty`).
  3. Up to 3 rounds: the active `_sortID` property, then `kpidName`, then `kpidPrefix` (flat mode) — `SetSortRawStatus` (`PanelSort.cpp:83`) decides whether the sort column is a raw property. Property comparison: strings via `CompareFileNames_ForFolderList` for `kpidName`/`kpidExtension`/`kpidPath`, `kpidNtReparse` compares the decoded reparse target path, numbers/times by value, booleans by value; `IFolderCompare::CompareItems` is used when the folder implements it (archives do, `Agent.cpp` `CompareItems`, which handles alt streams and `kpidPrefix`).
  4. Final tie-break by item index.
  5. Direction: `_ascending` flag; `SortItemsWithPropID(propID)` (`PanelSort.cpp:256-279`): clicking/choosing the same property toggles `_ascending`; choosing a new one sets ascending = true except for `kpidSize`, `kpidPackSize`, `kpidCTime`, `kpidATime`, `kpidMTime` which start descending.
* `kpidNoProperty` (No Sort) = archive/native order (`Ctrl+F7`).
* Sort ID and direction persisted per folder type (§5.3).

### 3.4 Flat view

`ChangeFlatMode()` (`Panel.cpp:894-903`) toggles `_flatModeForArc` (archive folders) or `_flatModeForDisk` (FS folders) — two independent flags; `GetFlatMode()` returns the one for the current folder type. Effects:
* `IFolderSetFlatMode::SetFlatMode(true)` is called on the folder after every bind (`SetNewFolder` `PanelFolderChange.cpp:46`); FSFolder then enumerates recursively (`FSFolder.cpp` `LoadItems` flat branch, adds `kpidPrefix`), archive folders list all files of the subtree (`CAgentFolder::LoadItems` → `_items` with `kpidPrefix`).
* Folder rows are still listed in flat mode for archives (`_loadAltStreams`, "IncludeFolderSubItemsInFlatMode" handling in `GetRealIndices`), but `Delete` in flat mode does not delete sub-items of folders (`AgentOut.cpp:492-535`).
* The `Prefix` column becomes visible; sorting falls back to prefix as the third key.
* Only the FS flag is persisted: `SaveFlatView(panelIndex, flat)` → `FlatViewArc<N>` (`RegistryUtils.cpp:180`) — note the name says "Arc" but `CApp::Create`/`Save` store `_flatModeForArc` (`App.cpp:284-404`).
* `CalculateCrc2` uses `EnterToDirs = !GetFlatMode()` (`PanelCrc.cpp:338`).

### 3.5 Folder history and favorites

* `CFolderHistory` (`App.cpp:992-1006`): unique strings, newest first, max 100 (`kMaxFolderHistory`), persisted as `FolderHistory` (§5.2). Every successful `BindToPathAndRefresh` / `OpenFolder` adds the resulting path (`CPanel::LoadFullPath` `PanelFolderChange.cpp:356` + `_appState->FolderHistory.AddString`).
* `FoldersHistory()` (`PanelFolderChange.cpp:866-892`): `CListViewDialog` titled `IDS_FOLDERS_HISTORY 6601`, one column, `DeleteIsAllowed = true` (Del removes an entry), `SelectFirst = true`, OK/Enter → `BindToPathAndRefresh(selected)`; the list is normalized (`Normalize`, drop empties) and saved back.
* Favorites: 10 slots (`SaveFastFolders`/`ReadFastFolders`, value `FolderShortcuts`, §5.2); `SetBookmark(i)` stores `_currentFolderPrefix` (full path incl. archive path); `OpenBookmark(i)` → `BindToPathAndRefresh`.
* Copy-dialog path history: `CopyHistory` (`ReadCopyHistory`/`SaveCopyHistory` `ViewSettings.cpp:302-305`, newest first via `AddUniqueStringToHeadOfList` `:307`, trimmed in `CApp::OnCopy` `App.cpp:750-757`) — see §3.10.

### 3.6 Selection

`PanelSelect.cpp`:

| Command | Behaviour | Source |
|---|---|---|
| `SelectSpec(select)` (Num+ / Num-) | `CComboDialog` titled `IDS_SELECT 6402` / `IDS_DESELECT 6403`, static `IDS_SELECT_MASK 6404` ("Mask:"), default mask `*`; every item whose name matches the wildcard (`DoesWildcardMatchName`, case-insensitive) gets selected/deselected; `..` excluded | `PanelSelect.cpp:154-167` |
| `SelectByType(select)` (Alt+Num+ / Alt+Num-) | uses the focused item: if it is a folder → all folders; if its name has no extension → all files without extension; else all files with the same extension (`*.ext`); applies `select` | `PanelSelect.cpp:169-204` |
| `SelectAll(select)` (Shift+Num+ / Shift+Num-, Ctrl+A) | selects/deselects all items except `..` | `PanelSelect.cpp:206` |
| `InvertSelection()` (Num*) | toggles every item except `..`; in "mySelectMode" (AlternativeSelection) uses the internal selection array | `PanelSelect.cpp:213-241` |
| `KillSelection()` | clears selection (called after drag/drop, copy) | `PanelSelect.cpp:243` |
| `OnInsert()` (Insert in AlternativeSelection mode) | toggles selection of the focused item and moves focus down one row | `PanelSelect.cpp:77-108` |
| `OnArrowWithShift()` / `OnUpWithShift` / `OnDownWithShift` | in AlternativeSelection mode Shift+Up/Down toggles the item then moves; in normal mode posts `kShiftSelectMessage` so that after the list moved the range between anchor and focus is selected (`OnShiftSelectMessage` `PanelSelect.cpp:14`) | `PanelSelect.cpp:43-133` |
| `OnLeftClick` | in AlternativeSelection (`_mySelectMode`, `LVS_SINGLESEL`) Ctrl+click toggles, Shift+click selects a range from `_prevFocusedItem`; `UpdateSelection` (`PanelSelect.cpp:135`) syncs the internal `_selectedStatusVector` with the list | `PanelSelect.cpp:265+` |

Item selection state is kept in `_selectedStatusVector` (parallel to `_listView` items) when `_mySelectMode` is on; otherwise the list-view state is authoritative. Custom draw paints "my-selected" rows with background `RGB(255,192,192)` and items whose `kpidIsDeleted` is true in red text (`OnCustomDraw` `PanelListNotify.cpp:698-757`).

### 3.7 Keyboard map — `CPanel::OnKeyDown` (`PanelKey.cpp:39-357`)

`LVN_KEYDOWN` handler; `ctrl/alt/shift/leftCtrl/rightCtrl` states are read with `IsKeyDown`. The table lists every case in order of the switch (`kVKeyPropIDPairs` at `PanelKey.cpp:15-28` maps `VK_F3..VK_F7` to `kpidName, kpidExtension, kpidMTime, kpidSize, kpidNoProperty`).

| Key | Modifiers | Action | Source |
|---|---|---|---|
| Tab | — | `_panelCallback->OnTab()` → switch focused panel (only 2-panel mode) | `PanelKey.cpp:39+` |
| `0`..`9` | RightCtrl or Alt (+Shift) | Shift → `SetBookmark(digit)`; else `OpenBookmark(digit)` | |
| F1 | Alt | focus address bar of panel 0 (`SetFocusToPath(0)`) | |
| F2 | Alt | focus address bar of panel 1 | |
| F9 | — | `SwitchOnOffOnePanel` (via `OnMenuCommand(IDM_VIEW_TWO_PANELS)`) | |
| F3..F7 | Ctrl | `SortItemsWithPropID(kpidName / kpidExtension / kpidMTime / kpidSize / kpidNoProperty)` | `FindVKeyPropIDPair` `PanelKey.cpp:30` |
| Shift (key down) | — | remembers `_selectMark` anchor for later group selection | |
| F2 | — | `RenameFile()` | |
| F3 | — | `EditItem(false)` (View) | |
| F4 | — / Shift | `EditItem(true)` (Edit); Shift+F4 → `CreateFile()` | |
| F5 | — / Shift | `OnCopy(move=false, copyToSame=Shift)` (Shift+F5 = copy into the same folder → rename prompt) | |
| F6 | — / Shift | `OnCopy(move=true, copyToSame=Shift)` | |
| F7 | — | `CreateFolder()` | |
| Delete | — / Shift | `DeleteItems(toRecycleBin = !Shift)` | |
| Insert | Ctrl / Shift / plain | Ctrl+Ins → `EditCopy()`; Shift+Ins → `EditPaste()`; plain Insert in AlternativeSelection mode → `OnInsert()` | |
| Down / Up | Shift | `OnArrowWithShift()` (group select) | |
| Down / Up | Alt (Up only) | Alt+Up → `OnSetSameFolder()` (§3.8) | |
| Right / Left | Alt | `OnSetSubFolder()` (§3.8); Shift+arrows → `OnArrowWithShift` | |
| PgDn | Ctrl | `OpenFocusedItemAsInternal()` (also handled in `CMyListView::OnMessage` `Panel.cpp:161+`) | |
| PgUp | Ctrl | `OpenParentFolder()` | |
| Num + (`VK_ADD`) | Alt / Shift / — | Alt → `SelectByType(true)`; Shift → `SelectAll(true)`; plain → `SelectSpec(true)` | |
| Num - (`VK_SUBTRACT`) | Alt / Shift / — | `SelectByType(false)` / `SelectAll(false)` / `SelectSpec(false)` | |
| Num * (`VK_MULTIPLY`) | — | `InvertSelection()` | |
| Backspace | — | `OpenParentFolder()` | |
| `\` or `/` (`WM_CHAR` in list) | — | `OpenDrivesFolder()` (`CMyListView::OnMessage` `Panel.cpp:161+`) | |
| A | Ctrl | `SelectAll(true)` | |
| X / C / V | Ctrl | `EditCut()` / `EditCopy()` / `EditPaste()` (§3.16) | |
| N | Ctrl | `CreateFile()` | |
| R | Ctrl | `OnReload()` (refresh) | |
| W | Ctrl | close the current panel (`SwitchOnOffOnePanel` when 2 panels) | |
| Z | Ctrl | `ChangeComment()` | |
| 1 / 2 / 3 / 4 | Ctrl | `SetListViewMode(0..3)` | |
| F12 | Alt | `FoldersHistory()` (also via accelerator) | |
| Enter | (list `NM_RETURN`/`LVN_ITEMACTIVATE`) | `OnNotifyActivateItems` (`PanelListNotify.cpp:538`): Alt → `Properties()`; Shift → `OpenSelectedItems(false)` (outside); else `OpenSelectedItems(true)` | |
| Esc in address edit | | restores the current path text (`OnNotifyComboBoxEndEdit` `PanelFolderChange.cpp:532`) | |
| Enter in address edit | | `OnNotifyComboBoxEnter` → `BindToPathAndRefresh(text)`; on failure shows the error and keeps the old folder (`PanelFolderChange.cpp:522`) | |
| Tab in address edit | | focus list (`CMyComboBoxEdit::OnMessage` `Panel.cpp:276`) | |
| F9 / Ctrl+W / Alt+F1/F2 in address edit | | same as in list | `Panel.cpp:276+` |

Mouse: single click / double click per `SingleClick` setting (`LVS_EX_ONECLICKACTIVATE`); Alt+double-click → Properties; Shift+double-click → open outside (same `OnNotifyActivateItems` path). Right-click → context menu (§2.8). Left-drag on items → `OnDrag(isRightButton=false)` (`LVN_BEGINDRAG`), right-drag → `OnDrag(true)` (`LVN_BEGINRDRAG`) (§3.15).

### 3.8 Navigation

| Operation | Behaviour | Source |
|---|---|---|
| `BindToPath(fullPath, arcFormat, openRes)` | Central path resolver (`PanelFolderChange.cpp:76-313`). Steps: (1) if the panel already has an open archive chain whose prefix matches, reuse it; (2) `CloseOpenFolders()`; (3) empty path → Root folder; (4) `\\.\` / `\\?\` device/super prefixes → RootFolder `BindToFolder(name)`; (5) alt-stream syntax `path:` → `OpenAltStreams`-like bind (`base:` prefix); (6) otherwise reduce the path to the longest existing FS prefix (`Reduce_Path_To_RealFileSystemPath` style loop): if the remainder is empty → FS folder; if a *file* is reached, open it as an archive (`OpenAsArc_Name` `PanelItemOpen.cpp:566`, honouring `arcFormat`, wildcard `*`/`#` forms) and continue binding the remaining sub-path inside the archive, level by level (nested archives supported); (7) wildcard in last component → the parent folder is opened and the component is used as the focus/selection mask (`DoesNameContainWildcard_SkipRoot` `PanelFolderChange.cpp:71`). Fills `COpenResult` (`ArchiveIsOpened`, `Encrypted`, `ErrorMessage`). | `PanelFolderChange.cpp:76` |
| `BindToPathAndRefresh(path)` | `BindToPath` + `RefreshListCtrl` + error message box (`MessageBox_Error`) on failure | `PanelFolderChange.cpp:315` |
| `OpenParentFolder()` | `PanelFolderChange.cpp:917-997`: if inside an archive at its root → `CloseOneLevel()`; else `IFolderFolder::BindToParentFolder`; on the Root folder nothing happens. Remembers the child's name so it becomes focused+selected in the parent (`_focusedName`/`SetFocusedSelectedItem`). Also `OpenParentArchiveFolder` (`PanelItemOpen.cpp:598`) when the parent is itself an archive opened from a temp file: if the nested archive was modified it is written back into the parent archive (`CopyFromFile` with `kOpenItemChanged` semantics) and the temp file removed. | |
| `CloseOneLevel()` | `PanelFolderChange.cpp:999-1014`: pops the last `CFolderLink` from `_parentFolders`, restores its folder/`_currentFolderPrefix`, deletes the temp file if it was virtual (`CFolderLink::IsVirtual`, `VirtualPath`), and re-packs a modified nested archive into the parent archive via `OpenParentArchiveFolder`. | |
| `CloseOpenFolders()` | `PanelFolderChange.cpp:1016`: `CloseOneLevel` until the chain is empty (used before any full re-bind). | |
| `OpenRootFolder()` | `PanelFolderChange.cpp:1025`: binds `CRootFolder` (Computer/Documents/Network + devices). | |
| `OpenDrivesFolder()` | `PanelFolderChange.cpp:1043`: binds `CFSDrives` (volume mode false). | |
| `OpenFolder(index)` | `PanelFolderChange.cpp:1058-1080`: `BindToFolder(index)` for items that are folders; keeps `_currentFolderPrefix`; adds to history; on archive folders this is a virtual bind (no extraction). | |
| `OpenAltStreams()` | `PanelFolderChange.cpp:1082`: for the focused item calls `IFolderAltStreams::BindToAltStreams(index)` (or for the folder itself) and shows the `path:` folder. | |
| `OpenItem(index, tryInternal, tryExternal, type)` | `PanelItemOpen.cpp:973-1030`: folders → `OpenFolder`; files in FS: if `tryInternal` and the name isn't in `kStartExtensions` try `OpenAsArc_Index` (`PanelItemOpen.cpp:580`) — success binds the archive as a new level; failure (or `tryExternal`) → shell open (`StartApplication`/`ShellExecute` `PanelItemOpen.cpp:817`), after `IsVirus_Message` check. Files inside archives → `OpenItemInArchive` (§3.9). | |
| `OpenFocusedItemAsInternal(type)` | `PanelItems.cpp:1084`: `OpenItem(focused, true, false, type)`. `type = "*"` (any handler, no sub-parsing) or `"#"` (parser) or `NULL`. | |
| `OpenSelectedItems(tryInternal)` | `PanelItems.cpp:1096-1136`: operated items; if a single folder is focused it is entered; opening more than `kMaxOpenItems = 20` files at once is refused with `IDS_TOO_MANY_ITEMS 3016`; each file → `OpenItem(i, tryInternal, true)`. | |
| `OnSetSameFolder(src)` (Alt+Up) | `App.cpp:858-865`: the other panel binds to the same folder path as the source panel. | |
| `OnSetSubFolder(src)` (Alt+Left/Right) | `App.cpp:867-912`: the other panel binds to the focused sub-folder (or the archive) of the source panel — sub-folder path = `GetItemFullPath(focused)`; archives are opened. | |
| Address combo dropdown | §3.9 | |

### 3.9 Address bar, breadcrumb dropdown, opening items inside archives (temp files)

**Address bar** (`CComboBoxEx`): shows `_currentFolderPrefix` (full path incl. archive path such as `C:\a.7z\dir\`) with the folder's system icon (`LoadFullPathAndShow` `PanelFolderChange.cpp:406-520`: root → Computer icon; drives → drive icon; archive → the archive file's icon; alt-stream folder → base file icon; icon lookups via `GetRealIconIndex_for_DirPath` `:373`). `CBN_DROPDOWN` (`OnComboBoxCommand` `PanelFolderChange.cpp:627-837`) rebuilds the list:
1. For an FS/archive path: one entry per path component from the full path down (`AddComboBoxItem` `:592`, indentation increases per level, icons from the FS for real folders, archive icon inside archives), the current path first.
2. Then fixed entries: `IDS_DOCUMENTS 7102` (user documents folder), `IDS_COMPUTER 7100` (drives; each drive listed indented by 1 with its drive icon), `IDS_NETWORK 7101`.
3. Selecting an entry (`CBN_SELENDOK`) → `BindToPathAndRefresh(path)`; the edit box supports typing any path (`CBEN_ENDEDIT`).

**Opening a file that is inside an archive** — `CPanel::OpenItemInArchive(index, tryInternal, tryExternal, editMode, type)` (`PanelItemOpen.cpp:1484-1803`):
1. If `tryInternal` and the archive handler supports `IInArchiveGetStream`, try opening the item *as an archive directly from the stream* (`OpenAsArc_Msg` `PanelItemOpen.cpp:528`, no extraction, virtual `CFolderLink` with `IsVirtual = true`).
2. Otherwise extract the item (and, for a folder, its subtree) to a fresh temp directory `<Temp>\7zO<8 hex>\` (`kTempDirPrefix = "7zO"`, `CTempDir`). If the item is small — size ≤ `RAM >> max(numLevels+1, 8)` and ≤ 4 MiB threshold — extraction goes to memory first (`CVirtFileSystem` in `ExtractCallback.cpp`, flushed to disk afterwards); a Zone.Identifier alt stream is written when `WriteZone` policy says so (`ReadZoneFile`/`WriteZoneFile` `:1334/1352`, mode `kAll` for opened items).
3. If the archive is read-only (`kpidReadOnly`) and `editMode`, the user is warned that changes will not be saved (message built from `IDS_CANNOT_UPDATE_FILE 3010`-style strings).
4. Start the item: `editMode` → `StartEditApplication` (`PanelItemOpen.cpp:719`, Viewer/Editor from settings, fallback `notepad.exe`); else `StartApplication` (shell open) after `IsVirus_Message` check (`:867`: names with 5+ consecutive spaces, RLO/ RTL override characters, or executable extension after trailing dots/spaces → `IDS_VIRUS 3012` confirmation).
5. A watcher thread (`MyThreadFunction`, `PanelItemOpen.cpp` ~1110-1330) waits for the launched process; because many apps hand off to an existing process, it uses `CreateToolhelp32Snapshot` (`GetSnapshot` `:256`) to find child processes / same-image processes started within ~2 s and waits for all of them. When they exit (or on `CExitEventLauncher` exit) it compares the temp file's size and mtime with the stored `CTempFileInfo`; if changed it posts `kOpenItemChanged` → `OnOpenItemChanged` (`:1037/1063`): asks `IDS_WANT_UPDATE_MODIFIED_FILE 3009` ("File was modified. Do you want to update it in the archive?"), on Yes → `IFolderOperations::CopyFromFile(index, tempPath)` (`CThreadCopyFrom` `:1032`, with progress) which re-packs the archive (§6.7), then reloads. On failure `IDS_CANNOT_UPDATE_FILE 3010`. Finally the temp dir is deleted (if the file was not modified or after the update) — `DeleteOldTempFiles` sweeps leftovers on the next start.
6. `CTempFileInfo` fields: `ItemIndex`, `ItemName`, `FolderPath`, `FilePath`, `RelPath`, `FileInfo` (size/mtime), `NeedDelete` (`Panel.h`).

**`kStartExtensions`** (`PanelItemOpen.cpp:633-660`; `DoItemAlwaysStart` `:665` — these are always opened externally by Enter, never tried as archives): `exe bat ps1 com lnk chm msi doc dot xls ppt pps wps wpt wks xlr wdb vsd pub docx docm dotx dotm xlsx xlsm xltx xltm xlsb xps xlam pptx pptm potx potm ppam ppsx ppsm vsdx xsn mpp msg dwf flv swf epub odt ods wb3 pdf ps txt xml xsd xsl xslt hxk hxc htm html xhtml xht mht mhtml htw asp aspx css cgi jsp shtml h hpp hxx c cpp cxx m mm go swift awk sed hta js json php php3 php4 php5 phptml pl pm py pyo rb tcl ts vbs asm mak clw csproj vcproj sln dsp dsw`. **`kExeExtensions`** (`:629`) = `exe bat ps1 com lnk` — used by `IsVirus_Message` (a name whose real extension is one of these but is hidden behind many spaces / RLO / trailing dots triggers the `IDS_VIRUS 3012` warning).

### 3.10 Copy / Move (F5 / F6) — `CApp::OnCopy(move, copyToSame, srcPanelIndex)` (`App.cpp:565-856`)

1. Source panel = `srcPanelIndex`; dest panel = the other panel in two-panel mode, else the same panel. Operated items via `Get_ItemIndices_Operated`; nothing → return. `..` excluded.
2. Precondition checks: source folder must support `IFolderOperations` (else `IDS_OPERATION_IS_NOT_SUPPORTED`); moving from a read-only folder is refused (`CheckBeforeUpdate`).
3. Destination proposal: if two panels and dest is FS → dest panel's FS path; if dest panel is an archive → its archive path (copy *into* archive); if `copyToSame` → the source folder itself. When neither panel is an FS folder (e.g. archive → archive), the operation goes through a temp dir `<Temp>\7zE<hex>\` (`kTempDirPrefix "7zE"`, "extract then add").
4. **Copy dialog** (§4.5): title `IDS_COPY 6000` / `IDS_MOVE 6001`, static `IDS_COPY_TO 6002` / `IDS_MOVE_TO 6003`, info text = `GetItemsInfoString(indices)` (`App.cpp:500-547`: up to `kCopyDialog_NumInfoLines = 11` lines: item names, then `Folders: N`, `Files: N`, `Size: N` sums computed from `kpidSize`/`kpidNumSubDirs`/`kpidNumSubFiles`), combo pre-filled with the proposal + `CopyHistory` (max 20 entries, `App.cpp:754-757`). The dialog is always shown for F5/F6 (also for `copyToSame`); only drag-and-drop uses the no-dialog paths (`CopyFromNoAsk`, `CopyFsItems`).
5. Result path handling (`App.cpp:565+`): trims; if the typed path is relative, it is resolved against the source FS folder; `Reduce_Path_To_RealFileSystemPath` (`App.cpp:420`) walks up until an existing FS folder is found; if the remainder names a non-existent single component and only one item is copied, it is treated as the *new file name* (rename-on-copy); non-existent multi-component → `CreateComplexDir`. `IsCorrectFsName`/`IsFsPath` (`App.cpp:549/557`) validate. Same folder & same name → error (`"Cannot copy file onto itself"` from FSFolderCopy).
6. Execution: FS→FS or Arc→FS: `srcPanel.CopyTo(options, indices, messages)` (`PanelCopy.cpp:182-338`, `CCopyToOptions{folder, moveMode, includeAltStreams=true, replaceAltStreamChars=false, showErrorMessages, streamMode/testMode=false, NeedRegistryZone, ZoneIdMode}`) — runs `CPanelCopyThread` (`PanelCopy.cpp:63-145`) under a progress dialog titled `IDS_COPYING 6004` / `IDS_MOVING 6005`; FS→Arc: `destPanel.CopyFrom(move, folderPrefix, names, showErrors, messages)` (`PanelCopy.cpp:375-450`, `IFolderOperations::CopyFrom` with `CUpdateCallback100Imp`, progress title from the update callback); Arc→Arc: `CopyTo` into the temp dir then `CopyFrom` from it, temp dir removed after.
7. After completion: `srcPanel.RefreshListCtrl`, `destPanel.RefreshListCtrl_SaveFocused`, the copy path is pushed to `CopyHistory`, messages (non-fatal errors collected in `CProgressSync.Messages`) shown in `CMessagesDialog` (§4.15), selection killed on success; on move the source items disappear (move = copy + delete for archives via `moveMode` flag; FS uses `MoveFileEx`).
8. Zone identifier (Mark-of-the-Web): `Get_ZoneId_Stream_from_ParentFolders` (`PanelCopy.cpp:156`) reads `:Zone.Identifier` from the outermost archive file; `CContextMenuInfo.WriteZone` (§5.5) decides whether extracted files get it (`IFolderSetZoneIdMode/File`).

### 3.11 Item operations

| Operation | Behaviour | Source |
|---|---|---|
| Delete (`DeleteItems(toRecycleBin)`) | `PanelOperations.cpp:112-262`. Needs `IFolderOperations` (`MessageBox_Error_UnsupportOperation` otherwise); `CheckBeforeUpdate(IDS_ERROR_DELETING 6107)`. FS folder & recycle bin: `SHFileOperation(FO_DELETE, FOF_ALLOWUNDO)` with the item full paths (double-null list); paths ≥ `MAX_PATH` cannot go to the recycle bin → `IDS_ERROR_LONG_PATH_TO_RECYCLE 6108`. Otherwise: confirmation `MessageBoxW` with title `IDS_CONFIRM_FILE_DELETE 6100` / `IDS_CONFIRM_FOLDER_DELETE 6101` / `IDS_CONFIRM_ITEMS_DELETE 6102` and text `IDS_WANT_TO_DELETE_FILE 6103` `"Are you sure you want to delete '{0}'?"` / `IDS_WANT_TO_DELETE_FOLDER 6104` / `IDS_WANT_TO_DELETE_ITEMS 6105` `"...these {0} items?"`; then `CThreadFolderOperations` (`PanelOperations.cpp:55-101`) runs `IFolderOperations::Delete(indices, n, progress)` under a progress dialog titled `IDS_DELETING 6106`; errors → `MessageBoxErrorForUpdate(hr, IDS_ERROR_DELETING)` (`:103`). Focus is restored to the item after the deleted range. | |
| Rename (`RenameFile`, F2) | `PanelOperations.cpp:478`: starts in-place label editing (`_listView.EditLabel(focused)`). `OnBeginLabelEdit` (`PanelListNotify.cpp:549+`) rejects `..` and read-only folders; `OnEndLabelEdit`: empty/unchanged → ignore; FS: `IsCorrectFsName` (`:274`, rejects only a last path component equal to `.` or `..`) and `CorrectFsPath` (`:284`, resolves the typed name against the folder so `sub\name` moves into a sub-folder); calls `IFolderOperations::Rename(index, newName, progress)` under progress `IDS_RENAMING 6006`; error → `IDS_ERROR_RENAMING 6009`; posts `kReLoadMessage` to refresh and re-focus the renamed item by name. | |
| Create Folder (F7) | `PanelOperations.cpp:363-424`: `Dlg_CreateFolder` (`CComboDialog`, title `IDS_CREATE_FOLDER 6300`, label `IDS_CREATE_FOLDER_NAME 6302`, default `IDS_CREATE_FOLDER_DEFAULT_NAME 6304` = "New Folder"); FS: `CorrectFsPath` allows `a\b\c` (complex dir); `IFolderOperations::CreateFolder(name, progress)`; error → `IDS_CREATE_FOLDER_ERROR 6306`; the new folder gets focused+selected. | |
| Create File (Ctrl+N / Shift+F4) | `PanelOperations.cpp:426-476`: `CComboDialog` (`IDS_CREATE_FILE 6301`, `IDS_CREATE_FILE_NAME 6303`, default `IDS_CREATE_FILE_DEFAULT_NAME 6305` = "New File"); `IFolderOperations::CreateFile` (FS: `CREATE_NEW`, fails if exists; archives: `E_NOTIMPL`); error → `IDS_CREATE_FILE_ERROR 6307`. | |
| Comment (Ctrl+Z) | `PanelOperations.cpp:487+`: `CComboDialog` (`IDS_COMMENT 6400`, label `IDS_COMMENT2 6401`), pre-filled with the item's `kpidComment`; `IFolderOperations::SetProperty(index, kpidComment, VT_BSTR, progress)`. FS: writes `descript.ion` in the folder (`FSFolder.cpp` `SetProperty`, `TextPairs`); archives: only zip supports it (`ArchiveFolderOut.cpp:445-457`). | |
| Properties (Alt+Enter) | `PanelMenu.cpp:172-423`. Non-archive FS items → shell `properties` verb (`InvokeSystemCommand("properties")` `:57`). Otherwise a `CListViewDialog` (2 columns, title `IDS_PROPERTIES 6600`) listing: for the focused item every property from `GetPropertyInfo` (`AddPropertyString` `:110`, values formatted with `ConvertPropertyToString2` at the panel timestamp level; sizes via `ConvertSizeToString`), raw props (`kpidNtSecure` → `ConvertNtSecureToString`; other raw props hex-dumped; > 256 bytes → `data:<N>`), then for multi-selection sums (`Size`, `Packed Size`, `Folders`, `Files`), then a separator and the **folder** properties (`GetFolderProperty` for all folder props), then for archives one block per archive level (`IFolderArcProps::GetArcNumLevels/GetArcProp`) with `kSpecProps = {kpidPath, kpidType, kpidErrorType, kpidError, kpidErrorFlags, kpidWarning, kpidWarningFlags, kpidOffset, kpidPhySize, kpidTailSize}` followed by all handler archive properties, and finally the "non-open" level errors (`GetOpenArcErrorMessage`). | |
| Split / Combine | §3.14 | |
| Link | §4.13 | |
| CRC/hash | §3.13 | |
| Diff | `CApp::DiffFiles()` (`PanelItemOpen.cpp:747-815`): needs a Diff tool path (Options → Editor page); with 2 selected items in one panel diffs them; with 2 panels diffs the focused item of each; items inside archives are first extracted to temp (`OpenItemInArchive` with `tryExternal=false`, path captured); runs `<diff> "path1" "path2"`; error `IDS_CANNOT_START_EDITOR 3011` style message if it cannot start. | |
| View / Edit (F3/F4) | `EditItem(useEditor)` (`PanelItems.cpp:1043-1082`): F3 on a *folder* → `IFolderCalcItemFullSize::CalcItemFullSize(index)` (computes size/files/folders and refreshes the row instead of opening); on a file in FS → `StartEditApplication` with the Viewer (F3) or Editor (F4); inside an archive → `OpenItemInArchive(..., editMode = useEditor)`. | |
| Open Outside / Open folder external | `OpenFolderExternal(index)` (`PanelItemOpen.cpp:835`): FS folder → `ShellExecute open`; inside archive → extract to temp then open the temp dir. | |
| Version control (`IDM_VER_*`) | `CApp::VerCtrl(id)` (`VerCtrl.cpp:141+`): base dir from registry `7vc`; repository path = `<7vc>\<drive letter>_<path with ':'→'_'>\` (`ConvertPath_to_Ctrl`), versions stored as `_7vc\<file>\NNN` (3-digit counter, `ParseNumberString` `:82`); **Edit** copies the current version into the store and clears the read-only attribute; **Commit** stores the modified file as a new version, sets read-only, rounds the timestamp to seconds; **Revert** asks with `COverwriteDialog` (no extra buttons, default No) and restores the last stored version; **Diff** runs the Diff tool on current vs. last version. Only for single FS files < 2 GB. | |

### 3.12 Status bar and list text (`PanelListNotify.cpp`)

`Refresh_StatusBar()` (`PanelListNotify.cpp:759-820`, also posted via `kRefresh_StatusBar`):

| Part | Content |
|---|---|
| 0 | `IDS_N_SELECTED_ITEMS 3002` = `"{0} object(s) selected"` with `{0}` = `"<selected> / <total>"` where `total` excludes `..`; when nothing is selected the focused item counts as 0 |
| 1 | total `kpidSize` of the selected items (`ConvertSizeToString` — thousands separated by spaces, e.g. `1 234 567`), empty if nothing selected |
| 2 | size of the focused item |
| 3 | `kpidMTime` of the focused item formatted at `_timestampLevel` |

`SetItemText(LVITEMW&)` (`PanelListNotify.cpp:152-522`) renders cell text lazily (`LVS_OWNERDATA`-style callback `LVN_GETDISPINFO`):
* Name cell: item name; names containing the RLO char (U+202E) get it replaced by `_`; 4 or more consecutive spaces are collapsed to `"... "`; a trailing space is shown as U+009C/U+2423 (`␣`) so it stays visible; `..` for the parent row. Icons: `IFolderGetSystemIconIndex::GetSystemIconIndex(index)` if the folder implements it (FS/drives always; archives only when `ShowRealFileIcons` is on or the folder is not "slow"), else `g_Ext_to_Icon_Map` cache keyed by extension/attrib (folder icon for dirs).
* Size cells (`IsSizeProp`: `kpidSize kpidPackSize kpidTotalSize kpidFreeSpace kpidClusterSize kpidPhySize kpidHeadersSize kpidTailSize kpidEmbeddedStubSize kpidUnpackSize kpidVirtualSize …` `:96`): number with space thousands separators (`ConvertSizeToString` `:38`).
* Times: `ConvertPropertyToShortString2(prop, propID, level = _timestampLevel)` — levels DAY(-3)/MIN(-1, default)/SEC(0)/NTFS(7 digits)/NS(9); UTC vs local by `g_Timestamp_Show_UTC` (`PropVariantConv.h:10-17`).
* Booleans: `+` / empty. `kpidAttrib`: string like `DRHSA…` via `ConvertPropertyToString2`. Raw props: `kpidNtReparse` → decoded reparse target, `kpidNtSecure` → SDDL-like summary, others hex.
* `OnItemChanged` (`:524`) → status bar refresh; `LVN_ITEMACTIVATE`/`NM_RETURN`/`NM_DBLCLK` → `OnNotifyActivateItems` (`:538`); `LVN_BEGINDRAG/BEGINRDRAG` → `OnDrag`; `LVN_COLUMNCLICK` → sort; `LVN_KEYDOWN` → `OnKeyDown`; `LVN_BEGINLABELEDIT/ENDLABELEDIT` → rename; `NM_CUSTOMDRAW` → `OnCustomDraw`; `NM_RCLICK` → context menu; `NM_CLICK` → `OnLeftClick` (`OnNotifyList` `:549-696`).

`RefreshListCtrl(state)` (`PanelItems.cpp:467-960`): `LoadItems()` on the folder, builds the list (adds `..` when `_showDots && !IsRootFolder()`), restores focus/selection by names (`CSelectedState` `:378`), sets `_flatMode`, re-inits columns when the folder type changed, updates the address bar, then `Refresh_StatusBar`. `RefreshListCtrl_SaveFocused(onTimer)` (`:426`) is the variant used after operations/timer.

### 3.13 Hash (CRC) calculation — `PanelCrc.cpp`

`CApp::CalculateCrc(methodName)` (`PanelCrc.cpp:413`) → `CalculateCrc2` (`:338-411`):
* Inside an archive: `CopyTo` with `streamMode = true` and `hashMethods = {methodName}` (or all if `"*"`) — the Agent extracts to a hashing stream (`IFolderExtractToStreamCallback`), results collected in `CHashBundle`.
* FS folder: `CThreadCrc` (`:194-336`) — first `CDirEnumerator` (`:47`, `EnterToDirs = !flat`, follows the operated items recursively, counting files/bytes with progress status `"Scanning"`), then hashes each file in 32 KiB reads, updating progress every 2 MiB and showing the current file path; errors are collected (`AddErrorMessage` `:177`) and shown in the progress dialog's message list; title `IDS_CHECKSUM_CALCULATING` (GUI res).
* Results: `ShowHashResults(hb, hwnd)` (`GUI/HashGUI.cpp`) — `CListViewDialog` with 2 columns (`Name`/`Value`): `Files`, `Folders`, `Size`, `AltStreams`, `AltStreams size`, `Errors`, then for each method `<Method> for data:`, `<Method> for data and names:`, `<Method> for streams and names:` and for a single file the plain `<Method>: <hex>`; Ctrl+C copies `name: value` lines.

### 3.14 Split / Combine — `PanelSplitFile.cpp`, `SplitUtils.cpp`

**Split** (`CApp::Split()` `PanelSplitFile.cpp:235-353`): requires exactly one FS file (`IDS_SELECT_ONE_FILE 3014`). `CSplitDialog` (§4.20) pre-filled with the current folder as destination and volume presets from `AddVolumeItems` (`SplitUtils.cpp:75`: `"10M"`, `"100M"`, `"1000M"`, `"650M - CD"`, `"700M - CD"`, `"4092M - FAT"`, `"4480M - DVD"`, `"8128M - DVD DL"`, `"23040M - BD"`). `ParseVolumeSizes` (`SplitUtils.cpp:9-73`): numbers with suffix `b/k/m/g/t` (case-insensitive, 1024-based), `-` terminates parsing (so the display suffix after `-` is ignored), space-separated list = successive sizes with the last repeated. Checks: a volume size ≥ file size → `IDS_SPLIT_VOL_MUST_BE_SMALLER 7306`; more than 100 volumes → confirmation `IDS_SPLIT_CONFIRM_TITLE 7304` / `IDS_SPLIT_CONFIRM_MESSAGE 7305` (`"Specified volume size: {0} bytes. Are you sure…"`). Output names `<name>.001`, `.002`, … (`CVolSeqName` `:63`, minimum 3 digits, grows to 4+ when needed). `CThreadSplit` (`:141-233`) copies with a 1 MiB buffer, pre-allocates volumes, runs under a progress dialog titled `IDS_SPLITTING 7303`; an I/O error aborts the thread (already written volumes are left on disk) and is reported through the progress dialog's error list.(`CApp::Split()` `PanelSplitFile.cpp:235-353`): requires exactly one FS file (`IDS_SELECT_ONE_FILE 3014`). `CSplitDialog` (§4.20) pre-filled with the current folder as destination and volume presets from `AddVolumeItems` (`SplitUtils.cpp:75`: `"10M"`, `"100M"`, `"1000M"`, `"650M - CD"`, `"700M - CD"`, `"4092M - FAT"`, `"4480M - DVD"`, `"8128M - DVD DL"`, `"23040M - BD"`). `ParseVolumeSizes` (`SplitUtils.cpp:9-73`): numbers with suffix `b/k/m/g/t` (case-insensitive, 1024-based), `-` terminates parsing (so the display suffix after `-` is ignored), space-separated list = successive sizes with the last repeated. Checks: a volume size ≥ file size → `IDS_SPLIT_VOL_MUST_BE_SMALLER 7306`; more than 100 volumes → confirmation `IDS_SPLIT_CONFIRM_TITLE 7304` / `IDS_SPLIT_CONFIRM_MESSAGE 7305` (`"Specified volume size: {0} bytes. Are you sure…"`). Output names `<name>.001`, `.002`, … (`CVolSeqName` `:63`, minimum 3 digits, grows to 4+ when needed). `CThreadSplit` (`:141-233`) copies with a 1 MiB buffer, pre-allocates volumes, runs under a progress dialog titled `IDS_SPLITTING 7303`; an I/O error aborts the thread (already written volumes are left on disk) and is reported through the progress dialog's error list.

**Combine** (`CApp::Combine()` `:419+`): requires one FS file whose name parses as a volume `…001` (`CVolSeqName::ParseName`, digits only after the last dot and equal to `001`), else `IDS_COMBINE_CANT_DETECT_SPLIT_FILE 7404`; needs at least a second part `…002` else `IDS_COMBINE_CANT_FIND_MORE_THAN_ONE_PART 7405`; output name = file name without the numeric extension (trailing dots trimmed; if empty → `"file"`); destination chosen with `CCopyDialog` titled `IDS_COMBINE 7400` / `IDS_COMBINE_TO 7401` (info line = detected first part `AddInfoFileName` `:413`); existing output file → `IDS_FILE_EXIST 3008` overwrite question; `CThreadCombine` (`:355-411`) concatenates consecutive volumes until a gap, progress titled `IDS_COMBINING 7402`.

### 3.15 Drag & drop — `PanelDrag.cpp`

Source side — `CPanel::OnDrag(nmListView, isRightButton)` (`PanelDrag.cpp:1500-1802`):
* Requires `IFolderOperations` on the folder; right-button drag is allowed only from FS folders (`isRightButton && !IsFSFolder()` → return). Operated items collected; `..` excluded.
* Builds `CDataObject` (`:874 SetData2`) offering: `CF_HDROP` (file list), `"7-Zip::SetTargetFolder"` (target tells the source its destination path, `k_Format_7zip_SetTargetFolder`), `"7-Zip::SetTransfer"` / `"7-Zip::GetTransfer"` (`CDataObject_TransferBase` `:219`, exchanges `k_SourceFlags_*`/`k_TargetFlags_*` such as *DoNotProcessInTarget*, *NeedCall_Copy*, *UsePreGlobal*, *RightButton*, *TempFolder*, *NamesAreParent* …). For FS sources the HDROP contains the real paths; for archive sources the HDROP initially points to *names that will exist* in a new temp dir `<Temp>\7zE<hex>\` (`kTempDirPrefix = "7zE"`), and the files are actually extracted when the target calls `GetData` for the final HDROP (`CopyFromPanelTo_Folder` `:630` → `CopyTo` with `UsePreGlobal=false`) — i.e. extraction is deferred until drop.
* `CDropSource::QueryContinueDrag`: Esc → cancel; button release → drop; for right-button drags the right button controls the drop. `GiveFeedback` → default cursors.
* `DoDragDrop` with `effectsOK = DROPEFFECT_MOVE | DROPEFFECT_COPY` (`DROPEFFECT_LINK` never offered). After it returns: if the target set a folder path and `MustBeProcessedBySource` (target could not process) → `CopyTo(dest, moveMode = effect == MOVE)` performed by the source panel; messages shown in `CMessagesDialog`; `KillSelection()`; the temp dir is deleted if it was created and the target did not take ownership (`k_TargetFlags_*`).

Target side — `CDropTarget` (`:1834-2760`, registered with `RegisterDragDrop` for each panel list view by `CApp::CreateDragTarget` `:2983`):
* `DragEnter/DragOver` → `PositionCursor(pt)` (`:1927`): hit-tests the list; a folder item under the cursor is highlighted (`LVIS_DROPHILITED`) and becomes the target sub-folder; otherwise the panel's current folder is the target. Dropping onto the source panel's own folder (same panel, no sub-folder) is refused (`_isAppTarget`/same-panel check), as is dropping onto `..`.
* `GetEffect(keyState)`: Ctrl → COPY; Shift → MOVE; Alt or Ctrl+Shift → LINK → not supported → `DROPEFFECT_NONE`; no modifier → MOVE when source and target are on the same drive (`IsItSameDrive` `:2066`, first char of paths / same volume) else COPY. Effect forced to COPY when the target is an archive.
* `Drop(dataObject, keyState, pt, effect)` (`:2400+`): loads names from HDROP (`LoadNames_From_DataObject` `:2383`); right-button drop shows menu `NDragMenu` = {`Copy`, `Move`, `Copy To "<archive>"` (when target is an archive), `Add to archive...`, separator, `Cancel`} (`IDS_COPY 6000`/`IDS_MOVE 6001` + `kMenuCmdID_*`), left-button uses the computed effect. If the target is an FS folder: files are copied/moved by the *target* panel via `CopyFsItems` → `CopyFileSystemItems` (`FSFolderCopy.cpp`, with progress) unless the source is 7zFM itself in which case the source is told the target path (`SendToSource_TargetPath_enable` `:2222`) and does the copy (so archive extraction and progress run in the source). If the target is an archive: confirmation `IDS_CONFIRM_FILE_COPY 6010` / `IDS_WANT_TO_COPY_FILES 6011` `"Are you sure you want to copy files to archive"` then `CopyFromNoAsk(moveMode, filePaths)` (`PanelCopy.cpp:452`) → `IFolderOperations::CopyFrom` (Agent re-pack, §6.7). "Add to archive..." → `CompressDropFiles(names, folderPrefix, ...)` (`:2817-2981`): if the source names live in a `7zE`/`7zO` temp folder (`AreThereNamesFromTemp` `:2794`), the destination is redirected to the target panel folder (or root FS) to avoid archiving into temp; then `CompressFiles(destPath, arcName=CreateArchiveName(names), type="", names, email=false, showDialog=true, waitFinish=false)` (§8.1).
* External drops from Explorer into an FM panel are supported through the same `CDropTarget` (HDROP only) and go through `CopyFsItems`/`CopyFromNoAsk`. Drops *to* Explorer are supported through the deferred HDROP (Explorer pulls the files from the `7zE` temp folder; the folder stays until `DeleteOldTempFiles` on next start or the exit hook).

### 3.16 Clipboard — `PanelMenu.cpp:427-489`

* `EditCopy()` (Ctrl+C / Ctrl+Ins): puts the operated items' *names* (or full paths for FS: `GetItemFullPath`) on the clipboard as `CF_UNICODETEXT`, lines joined with `"\r\n"` (`ClipboardSetText`). No `CF_HDROP` is placed — pasting into Explorer is not supported.
* `EditCut()` and `EditPaste()` are no-ops (bodies commented out; `PanelMenu.cpp:427, 455`).
* `CListViewDialog` copy (§4.14) and progress-dialog message copy (§4.17) also use the text clipboard.

### 3.17 Timer / auto refresh

`OnTimer()` (`PanelItems.cpp:1458`): if `_processTimer` and the folder implements `IFolderWasChanged` and `WasChanged()` returns true → `OnReload(true)` → `RefreshListCtrl_SaveFocused(onTimer = true)` (keeps focus/selection by name, does not scroll). FSFolder implements `WasChanged` via `FindFirstChangeNotification` on the folder (`FSFolder.cpp` `CFSFolder::WasChanged`); archive folders don't implement it, so archives are not auto-refreshed. `IDM_VIEW_AUTO_REFRESH` toggles `CApp::AutoRefresh_Mode` (`App.h:62`, default `true`, not persisted; `Change_AutoRefresh_Mode` `App.h:235`, checked in `OnTimer` `PanelItems.cpp:1462`). `CDisableTimerProcessing`/`CDisableNotify` (`Panel.h`) RAII guards suspend the timer and list notifications during long operations.

---

## 4. Dialogs

> Moved to `01b-fm-dialogs-settings.md` section 4.

## 5. Settings persistence

> Moved to `01b-fm-dialogs-settings.md` section 5.

## 6. Folder plugins

### 6.1 Interfaces — `FileManager/IFolder.h`

All are COM-style (`IUnknown`-derived, GUID `{23170F69-40C1-278A-0000-0008xx0000}` with `xx` = the number below; `Z7_IFACE_CONSTR_FOLDER(name, id)` `IFolder.h:11-16`). A macOS port can implement them as plain C++ abstract classes with the same method set; the FM only ever calls them through `QueryInterface`.

| Interface (id) | Methods | Implemented by |
|---|---|---|
| `IFolderFolder` (0x00) `:29-40` | `LoadItems()`, `GetNumberOfItems(UInt32*)`, `GetProperty(itemIndex, propID, PROPVARIANT*)`, `BindToFolder(UInt32 index, IFolderFolder**)`, `BindToFolder(const wchar_t *name, IFolderFolder**)`, `BindToParentFolder(IFolderFolder**)`, `GetNumberOfProperties(UInt32*)`, `GetPropertyInfo(index, BSTR *name, PROPID*, VARTYPE*)`, `GetFolderProperty(propID, PROPVARIANT*)` | all folders |
| `IFolderAltStreams` (0x17) `:47-52` | `BindToAltStreams(UInt32 index, IFolderFolder**)`, `BindToAltStreams(const wchar_t *name, …)`, `AreAltStreamsSupported(index, Int32*)` | FSFolder, CAgentFolder (when `_proxy2`) |
| `IFolderWasChanged` (0x04) `:54-56` | `WasChanged(Int32*)` | FSFolder (change notification), FSDrives |
| `IFolderOperationsExtractCallback` (0x0B, derives `IProgress`) `:60-73` | `AskWrite(srcPath, srcIsFolder, srcTime, srcSize, destPath, BSTR *destPathResult, Int32 *writeAnswer)`, `ShowMessage(message)`, `SetCurrentFilePath(filePath)`, `SetNumFiles(numFiles)` (+ `IProgress::SetTotal/SetCompleted`) | `CExtractCallbackImp` (FM) |
| `IFolderOperations` (0x13) `:76-89` | `CreateFolder(name, IProgress*)`, `CreateFile(name, IProgress*)`, `Rename(index, newName, IProgress*)`, `Delete(indices, numItems, IProgress*)`, `CopyTo(Int32 moveMode, indices, numItems, Int32 includeAltStreams, Int32 replaceAltStreamCharsMode, const wchar_t *path, IFolderOperationsExtractCallback*)`, `CopyFrom(Int32 moveMode, fromFolderPath, const wchar_t *const *itemsPaths, numItems, IProgress*)`, `SetProperty(index, propID, const PROPVARIANT*, IProgress*)`, `CopyFromFile(index, fullFilePath, IProgress*)` | FSFolder, FSDrives (CopyTo only in volume mode), AltStreamsFolder, CAgentFolder |
| (`IFolderOperationsDeleteToRecycleBin`, commented out `:94`) | `DeleteToRecycleBin` — not used; FM calls `SHFileOperation` directly | — |
| `IFolderGetSystemIconIndex` (0x07) `:98-100` | `GetSystemIconIndex(index, Int32*)` | FSFolder, FSDrives, RootFolder, NetFolder, CAgentFolder (extension-based) |
| `IFolderGetItemFullSize` (0x08) `:102-104` | `GetItemFullSize(index, PROPVARIANT*, IProgress*)` | FSFolder (unused by FM) |
| `IFolderCalcItemFullSize` (0x14) `:106-108` | `CalcItemFullSize(index, IProgress*)` — computes and caches size/NumSubDirs/NumSubFiles for a folder item | FSFolder (F3 on a folder) |
| `IFolderClone` (0x09) `:110-112` | `Clone(IFolderFolder**)` | FSFolder (used by the drag data object and copy threads) |
| `IFolderSetFlatMode` (0x0A) `:114-116` | `SetFlatMode(Int32)` | FSFolder, CAgentFolder |
| `IFolderSetShowNtfsStreamsMode` (0xFA) `:119-121` | `SetShowNtfsStreamsMode(Int32)` (declared, `Change_ShowNtfsStrems_Mode` `Panel.cpp:905` exists but has no menu item) | — |
| `IFolderProperties` (0x0E) `:124-128` | `GetNumberOfFolderProperties`, `GetFolderPropertyInfo(index, BSTR*, PROPID*, VARTYPE*)` | CAgentFolder |
| `IFolderArcProps` (0x10) `:130-139` | `GetArcNumLevels`, `GetArcProp(level, propID, …)`, `GetArcNumProps(level, …)`, `GetArcPropInfo(level, index, …)`, `GetArcProp2(level, propID, …)` (properties of the sub-file that *contains* level `level`), `GetArcNumProps2`, `GetArcPropInfo2` | `CAgent` (`Agent.cpp:1892-2002`) |
| `IGetFolderArcProps` (0x11) `:141-143` | `GetFolderArcProps(IFolderArcProps**)` | CAgentFolder → its CAgent |
| `IFolderCompare` (0x15) `:145-147` | `CompareItems(UInt32 index1, UInt32 index2, PROPID propID, Int32 propIsRaw)` → `Int32` | CAgentFolder (sorting inside archives) |
| `IFolderGetItemName` (0x16) `:149-154` | `GetItemName(index, const wchar_t **name, unsigned *len)`, `GetItemPrefix(index, …)`, `GetItemSize(index)` → `UInt64` | CAgentFolder (fast path for `GetItemName`/sorting without PROPVARIANT) |
| `IFolderManager` (9, 5) `:157-166` | `OpenFolderFile(IInStream*, filePath, arcFormat, IFolderFolder**, IProgress*)`, `GetExtensions(BSTR*)`, `GetIconPath(ext, BSTR *iconPath, Int32 *iconIndex)` | `CArchiveFolderManager` (`Agent/ArchiveFolderOpen.cpp`) |

Agent-side interfaces (`Agent/Agent.h`, `7zip/UI/Common/IFileExtractCallback.h`/`Agent.h`): `IArchiveFolder` (`Extract(indices, numItems, includeAltStreams, replaceAltStreamCharsMode, pathMode, overwriteMode, path, testMode, IFolderArchiveExtractCallback*)`), `IInFolderArchive` (`Open(IInStream*, filePath, arcFormat, BSTR *archiveType, IArchiveOpenCallback*)`, `ReOpen`, `Close`, `GetNumberOfProperties`, `GetPropertyInfo`, `BindToRootFolder`, `Extract(pathMode, overwriteMode, path, testMode, IFolderArchiveExtractCallback*)`), `IOutFolderArchive` (`SetFolder`, `SetFiles`, `DeleteItems`, `DoOperation`, `DoOperation2`), `IFolderArchiveUpdateCallback` (`CompressOperation(name)`, `DeleteOperation(name)`, `OperationResult(Int32)`, `UpdateErrorMessage(message)`, `SetNumFiles(numFiles)`), `IFolderArchiveUpdateCallback2` (`OpenFileError(path, hr)`, `ReadingFileError(path, hr)`, `ReportExtractResult(opRes, isEncrypted, name)`, `ReportUpdateOperation(op, name, isDir)`), `IFolderArchiveUpdateCallback_MoveArc` (`MoveArc_Start(srcTempPath, destFinalPath, totalSize, updateMode)`, `MoveArc_Progress(total, current)`, `MoveArc_Finish()`, `Before_ArcReopen()`), `IFolderScanProgress` (`ScanError(path, hr)`, `ScanProgress(numFolders, numFiles, totalSize, path, isDir)`), `IFolderSetZoneIdMode` (`SetZoneIdMode(NZoneIdMode)`), `IFolderSetZoneIdFile` (`SetZoneIdFile(data, size)`), `IArchiveFolderInternal` (`GetAgentFolder(CAgentFolder**)`), `IFolderExtractToStreamCallback` (hash/stream mode: `UseExtractToStream`, `GetStream7(name, isDir, ISequentialOutStream**, askExtractMode, IGetProp*)`, `PrepareOperation7`, `SetOperationResult8`).

### 6.2 RootFolder — `RootFolder.cpp`

* Type ID `"RootFolder"`; items: `IDS_COMPUTER 7100` (index 0 → `CFSDrives`), `IDS_DOCUMENTS 7102` (→ FS folder of `CSIDL_PERSONAL`), `IDS_NETWORK 7101` (→ `CNetFolder`), and `\\.\` (volumes → `CFSDrives(volumeMode=true)`) — under CE only Computer and the root FS. Property table: `kpidName` only. Icons: shell icons for the special folders (`GetIconIndexForCSIDL`).
* `BindToFolder(name)` (`RootFolder.cpp` `BindToFolder(const wchar_t*)`): resolves any typed path — `\\.\`/`\\?\` prefixes → drives/volumes/super paths, `<path>:` (ends with colon, alt-stream syntax) → `CAltStreamsFolder`, network `\\server\share` → FS or Net folder, `Computer\`/`Network\`/`Documents\` names → the corresponding item, otherwise `CFSFolder::Init(path)`.
* `BindToParentFolder` → none (root). `GetFolderProperty(kpidPath)` = `""`, `kpidType` = `"RootFolder"`.

### 6.3 FSDrives — `FSDrives.cpp`

* Type ID `"FSDrives"`; `_volumeMode` (from `\\.\`) lists `PhysicalDrive0…15` and volume GUID paths instead of letters; `kpidIsDir = !_volumeMode` (`:225`).
* Properties (`kProps` `:107`): `kpidName`, `kpidTotalSize`, `kpidFreeSpace`, `kpidType` (string from `kDriveTypes[] = {"Unknown","No Root Dir","Removable","Fixed","Remote","CD-ROM","RAM disk"}` `:119-127`), `kpidVolumeName`, `kpidFileSystem`, `kpidClusterSize` (`GetDiskFreeSpace`/`GetVolumeInformation`, only queried for non-removable drives to avoid spinning up media). Folder prop `kpidPath` = `""` or `\\.\` in volume mode (`:306-309`).
* `BindToFolder(index/name)` → `CFSFolder` at `X:\` (or `\\.\X:` in volume mode); `BindToParentFolder` → RootFolder.
* `IFolderOperations::CopyTo` (`:386+`): only in volume mode — copies a raw device/volume to an image file (`kpidOutName` = `<drive>.<fs>` e.g. `c.ntfs`, `:227`); other operations `E_NOTIMPL`. `GetSystemIconIndex` = drive icon. `WasChanged` polls the drive mask.

### 6.4 FSFolder — `FSFolder.cpp`

* Type ID `"FSFolder"`; `Init(path)` normalizes to a `\`-terminated prefix, checks the directory exists (`_findChangeNotification` created with `FILE_NOTIFY_CHANGE_FILE_NAME|DIR_NAME|ATTRIBUTES|SIZE|LAST_WRITE` for `WasChanged` `:954`).
* `LoadItems`: `NFind::CEnumerator` over `prefix\*`; `_flatMode` recurses into sub-dirs (`kpidPrefix` = relative dir); loads `descript.ion` comments (`CTextPairs`, `TextPairs.cpp`) lazily for `kpidComment`; `_commentsAreLoaded`.
* Properties (`kProps`): `kpidName, kpidSize, kpidMTime, kpidCTime, kpidATime, kpidChangeTime, kpidAttrib, kpidPackSize (allocation size, lazily via GetCompressedFileSize), kpidINode, kpidLinks (NumberOfLinks; via GetFileInformationByHandle, lazy), kpidComment, kpidNumSubDirs, kpidNumSubFiles (only after CalcItemFullSize), kpidPrefix (flat)`; `GetProperty(kpidIsDir)`, `kpidIsAltStream = false`; raw prop `kpidNtReparse` (reparse data buffer for reparse-point items, `GetReparseData`). Folder props: `kpidType "FSFolder"`, `kpidPath` = prefix.
* `BindToFolder(index)` → new `CFSFolder` for the sub-dir (with `_parentFolder` = this); `BindToFolder(name)` → same for a named sub-path; `BindToParentFolder` → parent prefix or, at a drive root, `CFSDrives`/RootFolder (network roots → NetFolder).
* `IFolderAltStreams`: `BindToAltStreams(index)` → `CAltStreamsFolder` for `<file>:`; `AreAltStreamsSupported` = file system is NTFS-like (`IsSupported_NtfsStreams`).
* `IFolderOperations`:
  * `CreateFolder(name)` → `CreateComplexDir`; `CreateFile(name)` → `CreateFile(CREATE_NEW)` (fails `ERROR_FILE_EXISTS`); `Rename(index, newName)` → `MoveFile(prefix+old, prefix+new)`; `Delete(indices)` → recursive `RemoveDirWithSubItems` / `DeleteFileAlways` (clears read-only), progress `SetTotal(numItems)`, aborts on the first error with `GetLastError` HRESULT; `SetProperty(index, kpidComment, string)` → rewrites `descript.ion`; `CopyFromFile` → `E_NOTIMPL` (`FSFolderCopy.cpp:866`; FS items are edited in place); `CopyFrom(move, fromFolder, names)` → `CopyFileSystemItems` (see below).
  * `CopyTo(moveMode, indices, …, path, callback)` — `FSFolderCopy.cpp`: for each item, `CCopyState` (`:228+`) copies files with `CopyFileExW` (progress callback → `IProgress::SetCompleted`; user stop → `PROGRESS_CANCEL` → `E_ABORT`) or moves with `MoveFileWithProgressW` (`MOVEFILE_COPY_ALLOWED`); falls back to manual read/write (`MyCopyFile` `:35`, buffered read/write loop) for alt-stream destinations (`IsAltStreamsDest`) and for old systems; before writing each file it calls `callback->AskWrite(src, isDir, srcTime, srcSize, dest, &destResult, &answer)` — the FM answers via `COverwriteDialog` (§4.15) / current overwrite mode and may rewrite `destResult` (auto-rename); directories are recreated recursively (`CopyFolder`), attributes/times preserved (`SetFileAttrib` after copy `:96`), read-only sources allowed. Error messages: `"Cannot copy file onto itself"` / `"Cannot move file onto itself"` (`:461-462`), `"Cannot copy folder onto itself"` / `"…move folder…"` (`:579-580`), `k_CannotCopyDirToAltStream` `"Cannot copy folder as alternate stream"` (`:32`); other errors as `HRESULT_FROM_WIN32(GetLastError())` with the path (`SendMessageError`). `moveMode` on the same volume uses rename; across volumes copy+delete.
  * `CopyFileSystemItems(itemsPaths, moveMode, callback)` (`FSFolderCopy.cpp`, exported for drag-and-drop): same engine for a list of absolute source paths into `destDirPrefix`.
* `GetSystemIconIndex` → `Shell_GetFileInfo_SysIconIndex_for_Path` (`SysIconUtils.cpp`, cached by extension for files, real icon for exe/lnk/ico, folders by attribute).
* `CalcItemFullSize` → recursive enumeration, stores `Size/NumSubDirs/NumSubFiles` on the item (`_fileInfos[i].FolderStat`), progress via `IProgress`.
* `Clone` → new `CFSFolder` with the same path.

### 6.5 AltStreamsFolder — `AltStreamsFolder.cpp` (Windows only, `FM.mak:78`)

* Type ID `"AltStreamsFolder"`; `Init("<file>:")`; `LoadItems` enumerates `FindFirstStreamW` on the base file; properties `kpidName` (stream name without `:$DATA`), `kpidSize`, `kpidPackSize`; folder props `kpidPath` = `"<file>:"`, `kpidType`.
* `BindToParentFolder` → FSFolder of the base file's directory; `BindToFolder` → none (streams are files).
* `IFolderOperations`: `CreateFile(name)` → `CreateFile("<file>:<name>")`; `Rename` via `NtSetInformationFile(FileRenameInformation)` on the stream handle (`ntdll`, dynamically loaded); `Delete` → `DeleteFile("<file>:<stream>")`; `CopyTo` → `CopyFileSystemItems`-like stream copy through `CFSFolder` engine with `IsAltStreamsDest`; `CopyFrom` → copies files into streams (`k_CannotCopyDirToAltStream` for directories); `CreateFolder`/`SetProperty` → `E_NOTIMPL`.

### 6.6 NetFolder — `NetFolder.cpp` (Windows only)

* Type ID `"NetFolder"`; `Init(NETRESOURCE*)` (root = network neighborhood); `LoadItems` via `WNetOpenEnum/WNetEnumResource` (`Windows/Net.cpp`); properties `kpidName` (`RemoteName`/`Comment` display), `kpidLocalName`, `kpidComment`, `kpidProvider`; `kpidIsDir` = container or share.
* `BindToFolder(index)`: containers → nested `CNetFolder`; shares/disks → `CFSFolder(remoteName + '\')`; `BindToParentFolder` → parent NETRESOURCE or RootFolder. `GetSystemIconIndex` → `GetIconIndexForCSIDL(CSIDL_NETWORK)` / server/share icons. No operations.

### 6.7 Archive folders — `Agent/*.cpp` via `FileFolderPluginOpen.cpp`

**Opening** (`CFfpOpen::OpenFileFolderPlugin(inStream, path, arcFormat, parentWindow)` `FileFolderPluginOpen.cpp:243-395`):
1. Creates `CArchiveFolderManager` (`ArchiveFolderOpen.cpp`) and a `COpenArchiveCallback` (`OpenCallback.cpp`, `IArchiveOpenCallback` + `IArchiveOpenVolumeCallback` + `ICryptoGetTextPassword`) whose `PasswordIsDefined/Password` are pre-set from the parent chain (`Encrypted` in/out flag).
2. Runs `IFolderManager::OpenFolderFile(inStream, path, arcFormat, &folder, progress)` on a worker thread under a progress dialog titled `IDS_OPENNING` ("Opening...") with `WaitMode = true` (dialog only appears if opening takes > 500 ms); `Open_SetTotal/SetCompleted` show bytes/files for multi-volume/solid scanning; password prompts use `CPasswordDialog` (`OpenCallback.cpp:63`, marks `PasswordWasAsked`).
3. `CAgent::Open` (`Agent.cpp:1627-1710`): `ParseOpenTypes(arcFormat)` (supports `*`, `#`, `#:e`, `type:subtype`, nesting like `7z:tar`), `CArchiveLink::Open` (tries handlers by signature/extension, opens nested archives automatically for "parser"/`-t#` requests; `NonOpen_ErrorInfo` records the failing level), sets `ArchiveType = GetTypeOfArc(arc)` and `_isHashHandler` when the handler is a hash-list handler.
4. Result handling (`:361-381`): `S_FALSE` (not an archive) and errors produce `ErrorMessage` composed by `GetFolderError` (`:173-241`): per level `IDS_CANT_OPEN_AS_TYPE` "Cannot open the file as {0} archive" / `IDS_IS_OPEN_AS_TYPE` "The file is open as {0} archive" / `IDS_IS_OPEN_WITH_OFFSET` + the level's `kpidError`, `kpidErrorFlags` (`GetOpenArcErrorMessage` `ExtractCallback.cpp:474`: `IDS_EXTRACT_MSG_IS_NOT_ARC`, `…HEADERS_ERROR`, `…UNAVAILABLE_DATA`, `…UEXPECTED_END`, `…DATA_AFTER_END`, `IDS_OPEN_MSG_UNSUPPORTED_FEATURE`, `…UNAVAILABLE_START`, `…UNCONFIRMED_START`, …), warnings. The panel shows `open_Errors` in a message box but still enters the archive when a folder was returned with warnings (`COpenResult.ErrorMessage` / `ArchiveIsOpened`).

**CAgentFolder** (`Agent.cpp` `CAgentFolder`, one per directory level; `_proxy` = `CProxyArc` flat tree, `_proxy2` = `CProxyArc2` for tree/raw-prop handlers with alt streams):
* Type ID `"7-Zip." + ArchiveType` (`GetFolderProperty(kpidType)`), `kpidPath` = archive path + inner path, `kpidReadOnly` = `_proxy->Are_Changed_LongPaths || (file attrib READONLY) || !CanUpdate()` (`CanUpdate` `Agent.cpp:1611-1625`: not a device file, exactly one archive level, no tail data), `kpidIsHash`, folder props `kpidSize`, `kpidPackSize`, `kpidNumSubDirs`, `kpidNumSubFiles`, `kpidCRC` (aggregated).
* Item properties: handler properties (`kpidPath` → `kpidName`), `kpidIsDir` from the proxy tree (a directory exists if any item path has it as prefix, even without an explicit dir entry — `IsLeaf()` distinguishes real dir items), `kpidNumSubDirs/NumSubFiles` for dirs, `kpidPrefix` in flat mode, `kpidIsAltStream` (proxy2). `GetRealIndex(index)` maps list index → archive item index (`-1` for implicit folders); `GetRealIndices(indices, includeAltStreams, includeFolderSubItemsInFlatMode)` expands folders to all contained items.
* `BindToFolder(index/name)` → child `CAgentFolder` (no I/O); `BindToParentFolder` → parent level; `IFolderAltStreams::BindToAltStreams` → alt-stream sub-folder (`_isAltStreamFolder`).
* `IFolderCompare::CompareItems`, `IFolderGetItemName`, `IFolderSetFlatMode`, `IFolderProperties`, `IGetFolderArcProps`, `IFolderSetZoneIdMode/File` (`ArchiveFolder.cpp:19-29`).
* **Extract / CopyTo** (`ArchiveFolder.cpp:32-57`, `CAgentFolder::Extract` `Agent.cpp` ~`:1450-1588`): `moveMode` → `E_NOTIMPL`; path mode `kCurPaths` (relative to this folder) or, in flat mode, `kNoPaths`/`kNoPathsAlt`; overwrite `kAsk` (callback decides); creates `CArchiveExtractCallback` (`7zip/UI/Common/ArchiveExtractCallback.cpp`) with `CExtractNtOptions{NtSecurity, SymLinks, HardLinks, AltStreams, ReplaceColonForAltStream, WriteToAltStreamIfColon, PreAllocateOutFile, PreserveATime, ZoneMode/ZoneBuf}` from the FM options, `PrepareHardLinks`, then `IInArchive::Extract(realIndices, testMode, callback)`; hash handlers return `E_NOTIMPL` for real extraction (only test/stream mode). The FM's `IFolderOperationsExtractCallback` is wrapped by QI to `IFolderArchiveExtractCallback` (`CExtractCallbackImp` implements both).
* **Update operations** (`ArchiveFolderOut.cpp`): every modifying call goes through `CommonUpdateOperation(op, moveMode, newItemName, actionSet, indices, numItems, progress)` (`:93-374`):
  1. `E_NOTIMPL` if `!CanUpdate()` or (move from hash handler). `SetFolder(this)` computes `_updatePathPrefix` (inner dir, `AgentOut.cpp:23-52`).
  2. `CWorkDirTempFile::CreateTempFile(archivePath)` in the work dir (§4.8) — the *whole archive is rewritten* to a temp file (`tempFile.OutStream`); if the archive has a stub/SFX prefix (`arc.ArcStreamOffset != 0`) the prefix bytes are copied first and a `CTailOutStream` writes after them.
  3. Dispatch: `AGENT_OP_Delete` → `CAgent::DeleteItems` (`AgentOut.cpp:492-535`: keeps every archive item not in `realIndices` as `SetAs_NoChangeArcItem`, reports `DeleteOperation(path)` per removed item); `AGENT_OP_CreateFolder` → `CreateFolder` (`:537-589`: appends one dir item `prefix + name` with current UTC time; refuses if a sub-dir with that name exists → `ERROR_ALREADY_EXISTS` `ArchiveFolderOut.cpp:417-426`; alt-stream folders → `E_NOTIMPL`); `AGENT_OP_Rename` → `RenameItem` (`:592-658`: renames the item and, for a folder, every item prefixed by its path; `NewNames`, `IsMainRenameItem`); `AGENT_OP_Comment` → `CommentItem` (`:661-704`, zip only — `SetProperty` checks `ArchiveType == "zip"` `ArchiveFolderOut.cpp:451`); `AGENT_OP_CopyFromFile` → `UpdateOneFile` (`:708-763`: replaces the data of exactly one item with a disk file, `KeepOriginalItemNames`); `AGENT_OP_Uni` (`CopyFrom`) → `DoOperation2` → `DoOperation` (`:254-471`: enumerates disk items (`CDirItems::EnumerateItems2`, scan progress to `IFolderScanProgress`), enumerates archive items (`EnumerateArchiveItems(2)`), `GetUpdatePairInfoList` + `UpdateProduce` with `k_ActionSet_Add`, `IOutArchive::UpdateItems` with `CArchiveUpdateCallback` → `CUpdateCallbackAgent` → `IFolderArchiveUpdateCallback(2)`; `ISetProperties` from `CAgent::SetProperties` if any were set; on `moveMode` returns `processedPaths`).
  4. `_agent->Close()`, then the temp file replaces the original: `tempFile.MoveToOriginal(deleteOriginal = true, progress)` — reported to the UI through `IFolderArchiveUpdateCallback_MoveArc` (`MoveArc_Start/Progress/Finish`, status line `"NN% : X MiB / Y MiB : Moving : <temp> → <dest>"` `UpdateCallbackGUI2.cpp:64-92`); a user cancel during the move is ignored so the archive is not left half-written (`C_CopyFileProgress_to_FolderCallback_MoveArc` `:68-90`), and `Before_ArcReopen()` clears the stop flag (`UpdateCallback100.cpp:132`).
  5. `moveMode` (Move To into archive): deletes the processed source files and now-empty source dirs (`Delete_EmptyFolder_And_EmptySubFolders` `:31-64`).
  6. `_agent->ReOpen(openCallback)` re-reads the new archive; the folder object re-binds to the same inner path (`pathParts` saved in step 1, `:270-358`), so the panel keeps its position. Exceptions (`UString`) are turned into `UpdateErrorMessage("Error: …")` + `E_FAIL`.
* `CreateFile` → `E_NOTIMPL` (`:440`); `CopyTo` with move → `E_NOTIMPL`; hash handlers: read-only except test.
* `KeepModeForNextOpen()` remembers open types so nested archives reopen with the same handler.

### 6.8 FilePlugins — `FilePlugins.cpp`

`CExtDatabase::Read()` fills `ExtBigItems`/`ExtItems` from `IFolderManager::GetExtensions` (all handler extensions) and `GetIconPath(ext)` (icon file + index inside `7z.dll`); used by SystemPage (association list + icons) and by `PanelItems` for archive-type icons when real icons are off.

---

## 7. Localization

### 7.1 Files and loading

* Lang files live in `<exeDir>\Lang\<id>.txt` (`GetLangDirPrefix()` `LangUtils.cpp:33-36`), UTF-8, format (`Common/Lang.cpp:20-120`): optional BOM, first line **exactly** `;!@Lang2@!UTF-8!` (`kLangSignature`), then lines; `\r` stripped (`:144-153`); a line that is a bare number sets the *next* ID (must be ≥ current, ≤ 2^30); an empty/whitespace line skips one ID; `;` lines are comments (collected in `Comments`, shown on the Language page); every other line is the text for the current ID (then ID++). Escapes: `\n`, `\t`, `\\`; other `\x` kept literally. Line 0 must equal `"7-Zip"` (validated by `CLang::Open(fileName, "7-Zip")` `:122-165`); line 1 = English language name, line 2 = native name (used by LangPage). Max file size 1 MiB. Lookup `CLang::Get(id)` binary-searches the sorted ID vector (`:167-173`).
* Selection (`ReloadLang` `LangUtils.cpp:308-336`): registry `Lang` empty → `OpenDefaultLang()` (`:279-306`): computes candidate short names from the system UI `LANGID` (`Lang_GetShortNames_for_DefaultLang` `:242`, table `kLangs` mapping primary/sub language IDs to `en`, `de`, `fr`, `pt-br`, `zh-cn`, … via `FindShortNames` `:183`), tries `<sub-lang name>.txt` then `<primary>.txt`; value `"-"` → no lang file (built-in English resources); otherwise `Lang\<value>.txt` (`.txt` appended if missing; a value containing a path separator is ignored). `LoadLangOneTime()` (`:40`) runs at startup; `ReloadLang()` after the Language page applies.
* Fallback: every `LangString(id)` (`:137-159`) returns the lang text if present, else the resource string (`MyLoadString`); `LangString_OnlyFromLangFile` (`:161`) returns empty when absent (used where a different default is wanted).

### 7.2 ID namespaces (what the lang file keys are)

Lang IDs are the **same numbers as the Win32 resource IDs**; the mapping rules:

| Range / rule | Meaning | Applied by |
|---|---|---|
| Menu item IDs (`IDM_*`, 500-961; popup titles 500-505) | menu text incl. `&` and `\t` accelerator | `MyLoadMenu.cpp:73 FindLangItem`, `MyChangeMenu :140` (also copies accelerator text from the resource if the translation lacks `\t`) |
| Dialog IDs (`IDD_*`) | dialog caption | `LangSetWindowText(hwnd, IDD_x)` |
| Control IDs ≥ 1000 (`IDT_/IDX_/IDG_/IDR_/IDB_*`) | control text; the low-numbered per-dialog IDs (100-199) are **not** localized | `LangSetDlgItems(hwnd, ids, n)` `:75`; `LangSetDlgItems_Colon` `:97` (appends `:`), `_RemoveColon` `:113` |
| 401 OK, 402 Cancel, 406 Yes, 407 No, 408 Close, 409 Help, 411 Continue | standard buttons (`kLangPairs` `:63-72`) | `LangSetDlgItems` automatically for `IDOK…IDCONTINUE` |
| 1000 + kpid (1003-1104) | property names (`PropertyName.rc`) | `GetNameOfProperty` |
| 3000-3999 | FM messages, progress (`3900-3906`), extract (`34xx`), password (`38xx`) | `LangString` |
| 4000-4099 | Compress dialog | |
| 6000-6603 | FM operation strings (copy/delete/create/comment/select/properties/messages) | |
| 7100-7405 | root items, toolbar buttons, split/combine | |
| 7600-7610 | benchmark; 7700-7715 link; 7800-7821 memory dialog | |
| `IDS_*` in GUI (`resource2.h`/`resource3.h`): 2100 options, 2200 system, 2300 menu, 2400 folders, 2500 settings, 2900 about, 3000-3999, 4000+, 7300 split, `IDS_CHECKSUM_*`, `IDS_MEM_*`, `IDS_PROGRESS_*` (`3320-3327` update ops `ADD/UPDATE/ANALYZE/REPLICATE/REPACK/SKIPPING/DELETE/HEADER`) | | |

Reference English file: `Lang/en.ttt` (repo `DOC`/`Lang`), `k_NumLangLines_EN = 443` lines. Everything not in this table (hard-coded ASCII such as `"7-Zip"`, method names, unit suffixes `KB/MB`, drive type names, `kDriveTypes`, benchmark labels like "Rating", format names, `k_CannotCopy…` messages) is **not** localizable in the Windows build either.

### 7.3 Localizable surface checklist for the port

Menus (all items + popups), toolbar labels, dialog captions/controls listed in §4, property names (§4.18), status/ progress strings, message-box texts (`IDS_*` listed throughout this document with `{0}` placeholders substituted by `MyFormatNew`), the About dialog info line, Folders History / Properties / Checksum dialog titles, the "System" submenu title, bookmark label `IDS_BOOKMARK`.

---

## 8. Extract / Update / Test flows from the FM

### 8.1 How 7zFM invokes the GUI code paths — `7zip/UI/Common/CompressCall.cpp`

7zFM never runs Add/Extract-to-folder/Test-archives/Hash/Benchmark in-process; it spawns **`7zG.exe`** (`k7zGui`, `:34`, located next to `7zFM.exe`) and passes the item list through a **named file mapping + event** (`CreateMap` `:120-186`):
* Mapping name `7zMap<rand32>`, event `7zEvent<rand32>` (retry on `ERROR_ALREADY_EXISTS`); mapping content = one leading `wchar_t 0` (marks UTF-16) followed by NUL-terminated UTF-16 strings; the parameter passed is `-i#<map>:<sizeBytes>:<event>` (`kIncludeSwitch " -i"` + `#…`, `ISWITCH_NO_WILDCARD_POSTFIX`), or `-an -ai#…` for archive lists (`kArcIncludeSwitches`). 7zG (`ArchiveCommandLine.cpp` `#` include syntax) opens the mapping, reads the names, and signals the event; the FM then waits until either the child process exits or the event is signalled (`Call7zGui` `:74-98`: `CProcess::Create` + `WaitForMultipleObjects(process, event)`), or for the whole process when `waitFinish`, before releasing the mapping.
* Switches (`:40-46`): `-ad` show dialog (`kShowDialogSwitch`), `-seml.` email (`kEmailSwitch`), `-t<type>` (`kArchiveTypeSwitch`), `--` (`kStopSwitchParsing`), `-slp` large pages if enabled (`AddLagePagesSwitch` `:100-107`), `-an` no archive name, `-saa`/`-sae` (archive-name mode: `a`ll extensions / `e`xact — `:220-222`), `-o"<dir>"` output, `-spe` eliminate duplicate root (`:265`), `-snz` write Zone.Id (`:268`), `-scrc<method>` (`:317`), `-mm=*` (`:337`).

| Function (`CompressCall.cpp`) | Command line | Called from |
|---|---|---|
| `CompressFiles(arcPathPrefix, arcName, arcType, addExtension, names, email, showDialog, waitFinish)` `:188-236` | `7zG a -i#map[ -t<type>][ -seml.][ -ad][ -slp][ -an][ -saa|-sae] -- "<arcPathPrefix><arcName>"` | `CPanel::AddToArchive` (`Panel.cpp:922-958`: dest prefix = current FS folder, name = `CreateArchiveName(paths)` of the operated items, `showDialog = true`), drag-drop "Add to archive", `CZipContextMenu` |
| `ExtractArchives(arcPaths, outFolder, showDialog, elimDup, writeZone)` `:238-280` | `7zG x -an -ai#map -o"<outFolder>"[ -spe][ -snz][ -ad][ -slp]` | `CPanel::ExtractArchives` (`Panel.cpp:1008-1039`: FS folder only; out folder = `<arcDir>\<GetSubFolderNameForExtract2(arcName)>\` for one archive or `<arcDir>\*\` for several — `*` is replaced by each archive's name by 7zG; `elimDup` = `ci.ElimDup`, `writeZone` = `ci.WriteZone`), context menu Extract/Extract Here/Extract to |
| `TestArchives(arcPaths, hashMode)` `:276-290` | `7zG t -an -ai#map[ -thash][ -slp]` (`hashMode` adds `-thash` so `.sha256`-style files are tested as hash archives) | `CPanel::TestArchives` (`Panel.cpp:1103-1177`) when in an FS folder |
| `CalcChecksum(paths, methodName, arcPathPrefix, arcFileName)` `:302-328` | `7zG h -i#map -scrc<method>[ -o...]` (`arcFileName` non-empty → generate a hash file `"<prefix><arcFileName>"`) | context menu CRC SHA items with `-> file` / `Checksum : Test` (FM menu items compute in-process instead, §3.13) |
| `Benchmark(totalMode)` `:330-340` | `7zG b[ -mm=*][ -slp]` | Tools → Benchmark |

Inside an archive folder the FM does *not* spawn 7zG: `ExtractArchives` becomes `OnCopy` (copy to a folder via the Agent, `Panel.cpp:1008+`), `TestArchives` becomes `CopyTo` with `testMode = true` (`CThreadTest` `Panel.cpp:1064`, summary message with `IDS_PROP_FILES`, `IDS_PROP_SIZE`, `IDS_PROP_PACKED_SIZE`, … + `IDS_MESSAGE_NO_ERRORS`), `AddToArchive` refuses with `MessageBox_Error_UnsupportOperation` unless the panel is an FS folder (`Panel.cpp:922+`), so "Add" never runs on items inside archives (drag them to an FS folder first).

### 8.2 7zG entry — `GUI/GUI.cpp` (`WinMain` → `Main2` `:130-330`)

Parses the 7-Zip command line (`CArcCmdLineParser`, same syntax as `7z.exe`), loads codecs (`Codecs_AddHashArcHandler`), then: `b` → `Benchmark(...)` (`BenchmarkDialog.cpp`); extract group (`x`, `e`, `t`) → `CExtractCallbackImp` + `ExtractGUI(codecs, formats, excluded, paths, censor, options, showDialog, messageWasDisplayed, callback, hwnd)`; update group (`a`, `u`, `d`, `rn`) → `CUpdateCallbackGUI` + `UpdateGUI(...)`; `h` → `HashCalcGUI`. Exit codes `NExitCode::kSuccess/kWarning/kFatalError/kUserError`; errors shown with `ErrorMessage`/`ShowSysErrorMessage` (`:99-128`); `IDS_UNSUPPORTED_ARCHIVE_TYPE`, `IDS_MEM_ERROR`, `IDS_CANT_OPEN_ARCHIVE`, `IDS_UPDATE_NOT_SUPPORTED` "Update operations are not supported for this archive." (`Extract.rc`).

### 8.3 Extract flow — `GUI/ExtractGUI.cpp`

1. If `showDialog`: `CExtractDialog` (§4.25) with `DirPath` = `options.OutputDir` (already `<arcDir>\<subfolder>` from `-o`), `ArcPath`, `ElimDup`, `Password` (if `-p`), `NtSecurity`; cancel → `E_ABORT`. `SplitDest` handling: the sub-folder name is appended when the checkbox is on (`:195-236`).
2. `CreateComplexDir(outputDir)`; failure → `IDS_CANNOT_CREATE_FOLDER` "Cannot create folder '{0}'" message box (`:255-270`).
3. `CThreadExtracting` (`:61-160`) runs `Extract(...)` (`7zip/UI/Common/Extract.cpp`) under `CProgressDialog` titled `IDS_PROGRESS_EXTRACTING` "Extracting" / `IDS_PROGRESS_TESTING` "Testing" (`:274`), `ShowCompressionInfo = false`, `MainTitle = "7-Zip"`; `CExtractCallbackImp` receives all callbacks. For each archive: `BeforeOpen` (`ExtractCallback.cpp:415`, sets `Sync.Set_TitleFileName`), open errors via `OpenResult` (`:621`, `OpenResult_GUI` `:549-619` builds the multi-line message: `IDS_CANT_OPEN_ARCHIVE` "Cannot open file '{0}' as archive", `IDS_CANT_OPEN_ENCRYPTED_ARCHIVE` "…Wrong password?", per-level type/error/flags, and adds it to the progress error list), `ThereAreNoFiles` (`:638`, no-op in the GUI), `ExtractResult` (`:653`: non-`S_OK` → `Add_ArchiveName_Error` + `HResultToMessage`).
4. Test mode summary (`:120-160`): message `IDS_ARCHIVES_COLON` "Archives:" N, `IDS_PROP_PACKED_SIZE`, `IDS_PROP_FOLDERS`, `IDS_PROP_FILES`, `IDS_PROP_SIZE`, `IDS_PROP_NUM_ALT_STREAMS`, `IDS_PROP_ALT_STREAMS_SIZE`, then `IDS_MESSAGE_NO_ERRORS` "There are no errors" — shown as `FinalMessage.OkMessage` (info box after the progress closes) when no errors; with errors the progress dialog stays open with the message list.

### 8.4 `CExtractCallbackImp` — `FileManager/ExtractCallback.cpp/.h` (shared by 7zG extract/test and by the FM's Copy/Test/Hash from archives)

Implements `IFolderArchiveExtractCallback` (`AskOverwrite`, `PrepareOperation`, `MessageError`, `SetOperationResult`), `IFolderArchiveExtractCallback2` (`ReportExtractResult`), `IExtractCallbackUI` (`BeforeOpen`, `OpenResult`, `ThereAreNoFiles`, `ExtractResult`, `SetPassword`), `IOpenCallbackUI` (`Open_CheckBreak`, `Open_SetTotal`, `Open_SetCompleted`, `Open_Finished`, `Open_CryptoGetTextPassword`, `Open_GetPasswordIfAny`, `Open_WasPasswordAsked`, `Open_Clear_PasswordWasAsked_Flag` `:97-171`), `IFolderOperationsExtractCallback` (`AskWrite`, `ShowMessage`, `SetCurrentFilePath`, `SetNumFiles`), `IFolderExtractToStreamCallback` (hash/stream mode → `CVirtFileSystem`/hashers), `ICompressProgressInfo` (`SetRatioInfo`), `IArchiveRequestMemoryUseCallback` (`RequestMemoryUse` → `CMemDialog` §4.12; `Read_LimitGB` registry limit; remembers the answer), `ICryptoGetTextPassword`/`2`, `IProgress` (`SetTotal`/`SetCompleted` → `CProgressSync`).

Key behaviours:
* `AskOverwrite(existName, existTime, existSize, newName, newTime, newSize, &answer)`: `OverwriteMode` `kAsk` → `COverwriteDialog` (§4.15; `ShowExtraButtons` unless single item); answers: `IDYES → kYes`, `IDNO → kNo`, `IDB_YES_TO_ALL → kYesToAll` (switches `OverwriteMode = kOverwrite`), `IDB_NO_TO_ALL → kNoToAll` (`kSkip`), `IDB_AUTO_RENAME → kAutoRename` (`kRename`), `IDCANCEL → E_ABORT`. Modes `kOverwrite/kSkip/kRename/kRenameExisting` answer without UI. Progress is paused while the dialog is up (`ProgressDialog->WaitCreating()`, `Sync.CheckStop` after).
* `AskWrite` (FS copy path, `:700-800`): same overwrite modes applied to `CFSFolder` copies; `kRename` → `AutoRenamePath(dest)` (`name (2).ext`…); `kRenameExisting` → renames the existing file; `kOverwrite` → deletes/replaces; asks with the same dialog in `kAsk`. Answers `writeAnswer = BoolToInt(...)`, `destPathResult` may be changed.
* `PrepareOperation(name, isFolder, askExtractMode, position)`: sets the status line to `IDS_PROGRESS_EXTRACTING` / `IDS_PROGRESS_TESTING` / `IDS_PROGRESS_SKIPPING` ("Skipping") and the file path (`_currentArchivePath` prefix + name).
* `SetOperationResult(opRes, encrypted)` / `ReportExtractResult`: `kOK` → nothing; others → `SetExtractErrorMessage(opRes, encrypted, name, s)` (`:277-413`): `IDS_EXTRACT_MSG_UNSUPPORTED_METHOD` "Unsupported compression method", `…DATA_ERROR` "Data error", `…CRC_ERROR` "CRC failed", `…UNAVAILABLE_DATA`, `…UEXPECTED_END`, `…DATA_AFTER_END`, `…IS_NOT_ARC`, `…HEADERS_ERROR`, `…WRONG_PSW_CLAIM` "Wrong password"; when `encrypted` the guess `IDS_EXTRACT_MSG_WRONG_PSW_GUESS` "Wrong password?" is appended (legacy full sentences `IDS_EXTRACT_MESSAGE_*` `"Data error in '{0}'. File is broken"` etc. are also in `Extract.rc`); `NumArchiveErrors++`; message → `Sync.AddError_Message` (progress list) and `NumFileErrorsInCurrent`.
* `MessageError(message, path)` (`:259`) → `AddError_Message_Name`; `ShowMessage` → list; `SetCurrentFilePath2` (`:426`) computes archive-relative display path.
* Password: `CryptoGetTextPassword` (`:676+`, `SetPassword`): if `!PasswordIsDefined` → `CPasswordDialog` (parent = progress dialog, `WaitCreating`), Cancel → `E_ABORT`; the password is then cached for the whole run (`PasswordIsDefined = true`) and `Open_GetPasswordIfAny` hands it to nested opens; `PasswordWasAsked` lets the FM know it must remember it on the `CFolderLink`.
* `CVirtFileSystem` (`:840-1200`): in-memory extraction target used by "open item in archive" for small files — collects `CVirtFile{Name, Data, IsDir, Attrib, times, ZoneBuf}` up to `MaxTotalAllocSize`, then `FlushToDisk(closeLast)` (`:1175`) writes them under `DirPrefix`, writing `:Zone.Identifier` per `ZoneMode` (`WriteZoneFile_To_FS`), preserving attributes/times, and reports errors via `MessageError`.

### 8.5 Update (Add) flow — `GUI/UpdateGUI.cpp`, callbacks `UpdateCallbackGUI(2).cpp`

1. `UpdateGUI(codecs, formats, cmdArcPath, options, showDialog, messageWasDisplayed, callback, hwnd)` (`:544-600`): if `showDialog` → `ShowDialog(...)` (`:220-540`) fills `NCompressDialog::CInfo` (`ArcPath` = archive name without extension when `-ad`, `Level` from registry (`Level` default 5), `FormatIndex` from `-t` or registry `Archiver`, `Password`, `EncryptHeaders`, `SolidBlockSize`, `NumThreads`, `PathMode`, `OpenShareForWrite`, `DeleteAfterCompressing`, `UpdateMode` from the action set (`FindActionSet`), time/NTFS options from `CFormatOptions`) and shows `CCompressDialog` (§4.23); cancel → `E_ABORT`. Result: `options.ArchivePath.ParseFromPath(di.ArcPath, k_ArcNameMode_Smart)`, `options.MethodMode.Properties` = `SetOutProperties` + parsed user parameters (`ParseAndAddPropertires` `:176`, `IsThereMethodOverride` `:154`), `options.SfxMode/SfxModule` (`kDefaultSfxModule = "7z.sfx"` `:31`, from the module dir `:561-565`), `options.VolumesSizes` (splitting to volumes with `-ad` on an existing archive → `"Splitting to volumes is not supported"` `:480` when updating), `options.EMailMode/EMailRemoveAfter/EMailAddress`, `options.WorkingDir = GetWorkDir(workDirInfo, archivePath)` (`:529-540`), `options.PathMode`, `options.DeleteAfterCompressing`, NT options (`SymLinks/HardLinks/AltStreams/NtSecurity/PreserveATime`), time options.
2. `CThreadUpdating` (`:38-60`) runs `UpdateArchive(codecs, formats, cmdArcPath, censor, options, errorInfo, openCallback, updateCallback, needSetPath)` (`7zip/UI/Common/Update.cpp`) under `CProgressDialog` titled `IDS_PROGRESS_COMPRESSING` "Compressing" (`:579`; for hash "archives" `IDS_CHECKSUM_CALCULATING` `:585`) with `ShowCompressionInfo = true` (shows Packed size / Ratio rows).
3. `CUpdateCallbackGUI` (`UpdateCallbackGUI.cpp`): `StartScanning` → status `IDS_SCANNING` "Scanning"; `ScanError` → `AddError_Code_Name` + `FailedFiles`; `FinishScanning` → totals; `StartArchive(name)` → status `IDS_PROGRESS_COMPRESSING`, `Set_TitleFileName`; `SetNumItems/SetTotal/SetCompleted/SetRatioInfo` → progress; `GetStream(name, isDir, isAnti, mode)`/`ReportUpdateOperation(op, name, isDir)` → status text from `k_UpdNotifyLangs` (`UpdateCallbackGUI2.cpp:17-27`: `IDS_PROGRESS_ADD` "Add", `…UPDATE` "Update", `…ANALYZE` "Analyze", `…REPLICATE` "Replicate", `…REPACK` "Repack", `…SKIPPING` "Skipping", `…DELETE` "Delete", `…HEADER` "Header"); `OpenFileError`/`ReadingFileError` → error list (`S_FALSE` = skip file, continue); `SetOperationResult` → files counter; `ReportExtractResult` (re-packing existing items) → `SetExtractErrorMessage`; `CryptoGetTextPassword2` → `ShowAskPasswordDialog` when `AskPassword` (`-p` without value) else the dialog password; `DeletingAfterArchiving(path, isDir)` → status `IDS_PROGRESS_REMOVE` "Removing"; `WriteSfx` → status `"WriteSfx"`; `MoveArc_*` → status `"NN% : … : Moving : temp → dest"` (`_lang_Moving = IDS_MOVING`); `OpenResult` for updating an existing archive → `OpenResult_GUI` message (`IDS_UPDATE_NOT_SUPPORTED` when the handler can't update).
4. Email mode (`-seml`): after the archive is written, `SendMailAttachment` (`Update.cpp`, MAPI `MAPISendMail`) attaches it; `EMailRemoveAfter` deletes the temp archive afterwards.

### 8.6 Test and Hash

* `7zG t` = extract flow with `TestMode` (no files written; `IDS_PROGRESS_TESTING` title; summary in §8.3).
* `7zG h -scrc<m>` → `HashCalcGUI(paths, options)` (`HashGUI.cpp:280-345`): `CThreadHashCalc` runs `HashCalc(...)` (`7zip/UI/Common/HashCalc.cpp`) with `CHashCallbackGUI` (`:60-260`: `StartScanning` → `IDS_SCANNING`, `SetNumFiles`, `SetTotal`, `SetCompleted`, `OpenFileError`, `BeforeFirstFile`, `GetStream`, `SetOperationResult`, `AfterLastFile` → `ShowHashResults` list dialog), progress title `IDS_CHECKSUM_CALCULATING`; `-scrc` may be repeated; `*` = all methods. `Checksum : Test` = opening the `.sha256` file as a hash "archive" and testing (`Codecs_AddHashArcHandler`).
* In-process FM hashing (§3.13) uses the same `CHashBundle`/`ShowHashResults`.

### 8.7 Error reporting, pause/background/priority, password prompting — summary

* All long operations run on a worker thread with a `CProgressDialog`/`CProgressSync` pair (§4.17). Non-fatal errors accumulate in the dialog's message list (max lines unbounded; the dialog stays open at the end); fatal `HRESULT`s become `FinalMessage.ErrorMessage` shown as a `MessageBox` after the thread ends (`CProgressThreadVirt::Process` `ProgressDialog2.cpp:1432-1475`: catches `UString`, `AString`, `char*`, `CSystemException` → `HResultToMessage`, `...` → `"Unknown error"`). `E_ABORT` is silent.
* Pause/Continue: `CProgressSync::CheckStop()` (`:100-110`) is polled by every callback (`SetCompleted`, `CheckBreak`, `Open_SetCompleted`); while `_paused` it sleeps 100 ms in a loop; `_stopped` → returns `E_ABORT`. Background: `IDLE_PRIORITY_CLASS` for the process (`OnPriorityButton`), reverted when clicking Foreground. Cancel: pause → confirm → stop.
* Password prompting: `CPasswordDialog` is always created with the progress dialog as parent after `WaitCreating()` so it appears on top; for FM in-process operations the panel window is the parent (`FileFolderPluginOpen.cpp`). The FM remembers the password per archive chain (`CFolderLink`) and pre-seeds `PasswordIsDefined` for nested opens, re-opens after update (`ReOpen` with `openCallback` from `updateCallback100` QI `IArchiveOpenCallback`), and for Copy/Test (`CPanelCopyThread` sets `ExtractCallbackSpec->PasswordIsDefined = UsePassword`).
* 7zG exit is reported via the process exit code only; 7zFM refreshes its panels through the 1 s timer / `IFolderWasChanged` after 7zG writes files.

---

## 9. Windows-only items and suggested macOS behaviour

| # | Windows-specific feature (source) | Suggested macOS behaviour |
|---|---|---|
| 1 | Separate `7zG.exe` process + named file mapping/event IPC for Add/Extract/Test/Hash/Benchmark (`CompressCall.cpp`) | Run the same GUI code paths **in-process** on background threads (the callbacks are already thread-safe via `CProgressSync`); keep the `CompressFiles/ExtractArchives/TestArchives/CalcChecksum/Benchmark` API surface as internal functions. Optionally keep a `7zG`-style helper for the Finder extension. |
| 2 | Shell context-menu DLL (`Explorer/*`, `MenuPage`, `RegistryContextMenu`), `CreateShellContextMenu`/`IShellFolder` System submenu, `ShowSystemMenu` option | Finder Sync / Action extension providing the same `NContextMenuFlags` items; in-app context menu = File menu + "Open With…"/"Show in Finder"/"Quick Look"/"Get Info" instead of the shell `System` submenu. Keep the `ContextMenu` flag mask in `UserDefaults`. |
| 3 | File associations via `HKCU/HKLM\Software\Classes` (`SystemPage`, `RegistryAssociations.cpp`) | `Info.plist` `CFBundleDocumentTypes` + `UTImportedTypeDeclarations` for all handler extensions; the System page becomes "set 7-Zip as default app" via `LSSetDefaultRoleHandlerForContentType` / `NSWorkspace.setDefaultApplication(at:toOpen:)` (per UTI, current user only — drop the "all users" column). |
| 4 | Registry persistence (§5) | `UserDefaults` per §5.7; window frame via `NSWindow.setFrameAutosaveName`. |
| 5 | Drive letters, `CFSDrives` (`Computer` with `A:`…`Z:`, drive types, volume images `\\.\PhysicalDriveN`), `\\.\`/`\\?\` prefixes, `RootFolder` items Computer/Documents/Network | Root folder = "Computer" listing mounted volumes from `/Volumes` (`FileManager.mountedVolumeURLs`) with capacity/free space/`kpidFileSystem` from `URLResourceValues`; "Documents" → `~/Documents`; drop "Network" and physical-drive imaging (or expose `/dev/diskN` read-only behind an opt-in). Type names map to `Removable/Fixed/Remote/CD-ROM` from volume resource keys. |
| 6 | NTFS alternate data streams (`AltStreamsFolder`, `IFolderAltStreams`, `kpidIsAltStream`, `:Zone.Identifier`, `-sns`), "Alternate Streams" menu item | Map to extended attributes: an "Extended Attributes" folder listing `listxattr` entries of a file (names/sizes; copy in/out via `getxattr/setxattr`); Zone.Identifier ↔ `com.apple.quarantine` (write when `WriteZone` policy says so). Archive alt streams (`NoPathsAlt`, `file:stream`) still extract as xattrs where the handler supports it. |
| 7 | NT security descriptors (`kpidNtSecure`, `-sni`, "Store/Restore file security", `ConvertNtSecureToString`) | Hide the options; show raw `kpidNtSecure` in Properties as hex/summary only. POSIX mode/owner (`kpidPosixAttrib`, `kpidUser/Group/UserId/GroupId`) become the relevant columns. |
| 8 | Link dialog: hard links, file/dir symlinks, junctions, WSL links (`LinkDialog`, `CreateHardLink/CreateSymbolicLink/SetReparseData`), `kpidNtReparse` column | Offer Hard Link (`link(2)`) and Symbolic Link (`symlink(2)`) only; show symlink targets via `readlink` in a "Link" column. |
| 9 | Recycle bin via `SHFileOperation(FOF_ALLOWUNDO)` (`DeleteItems`), long-path limitation message | `NSFileManager.trashItem(at:resultingItemURL:)` for Del; Shift+Del/Cmd+Backspace+Option = permanent delete with the same confirmation strings. |
| 10 | Shell property sheet (`InvokeSystemCommand("properties")`), `ShellExecute` open/edit, `notepad.exe` fallback, Viewer/Editor/Diff `.exe` paths | Properties for FS items → the same `CListViewDialog` used for archives (or `NSWorkspace.activateFileViewerSelecting` + "Get Info"); open with `NSWorkspace.open`; Viewer/Editor/Diff settings accept app bundles or command lines (`open -a`), default viewer = Quick Look (`QLPreviewPanel`), default editor = TextEdit. |
| 11 | Watching externally opened temp files with `WaitForSingleObject` on the child process + `CreateToolhelp32Snapshot` heuristics (`PanelItemOpen.cpp` `MyThreadFunction`) | Use `NSWorkspace.open(…configuration:)` completion + `NSRunningApplication` termination observation, **plus** an FSEvents/`DispatchSource` (`.write/.rename`) watcher on the temp file; prompt `IDS_WANT_UPDATE_MODIFIED_FILE` on change or on app quit, then `CopyFromFile`. Keep `7zO`/`7zE` temp-dir naming so `DeleteOldTempFiles` and the temp browser work unchanged. |
| 12 | OLE drag & drop (`IDataObject/IDropSource/IDropTarget`, `CF_HDROP`, private formats `7-Zip::SetTargetFolder/SetTransfer/GetTransfer`, right-button drag menu) | `NSDraggingSource`/`NSDraggingDestination` with `NSFilePromiseProvider` for archive items (deferred extraction to the promised destination, same `7zE` temp dir when the receiver is not 7-Zip); `NSPasteboard` file URLs for FS items; internal pasteboard type `org.7-zip.transfer` for panel-to-panel drops; modifier mapping: Option = copy, Cmd = move, default = move on same volume else copy (mirrors `GetEffect`). Right-button drag menu → drop menu shown on drag with Control held, or skip. |
| 13 | Clipboard `CF_UNICODETEXT` names only (`EditCopy`), `EditCut/EditPaste` no-ops | Copy names as text **and** file URLs (`NSPasteboard.writeObjects`) for FS items; leave Cut/Paste unimplemented or implement Paste = `CopyFromNoAsk` of pasteboard file URLs. |
| 14 | Toolbar/ReBar/ComboBoxEx/ListView/StatusBar/PropertySheet Win32 controls, dialog units | `NSToolbar` (Add/Extract/Test/Copy/Move/Delete/Info with the same command IDs), `NSPathControl`/editable `NSComboBox` address bar, `NSTableView` (report) / `NSCollectionView` (icons/list) with `NSOutlineView` not needed; `NSTabViewController` for Options; status bar as a bottom `NSTextField` row with 4 sections. |
| 15 | System image lists / `SHGetFileInfo` icons (`SysIconUtils.cpp`), `IDB_*` toolbar bitmaps | `NSWorkspace.icon(forFile:)` / `icon(for: UTType)` with a per-extension cache (same `g_Ext_to_Icon_Map` semantics), SF Symbols or the original bitmaps for toolbar. |
| 16 | Taskbar progress (`ITaskbarList3`), `SetPriorityClass(IDLE)` for Background, `SeLockMemoryPrivilege` large pages (`-slp`, `LargePages` setting) | Dock icon progress (`NSDockTile` badge/progress view); Background = lower the worker thread QoS (`.background`); remove the large-pages option. |
| 17 | `HtmlHelp` topics (`7-zip.chm`: `start.htm`, `fm/*.htm`, `fm/plugins/7-zip/add.htm`, `extract.htm`, `benchmark.htm`, `temp.htm`) | Apple Help Book or open the bundled HTML in the default browser with the same topic paths. |
| 18 | Lang files in `<exe>\Lang\*.txt`, registry `Lang`, system `LANGID` matching (`kLangs` table) | Ship `Lang/*.txt` in the bundle `Resources/Lang`, keep the `;!@Lang2@!UTF-8!` format and numeric IDs (so existing translations work), pick the default from `Locale.preferredLanguages` mapped to the same short names; optionally overlay `.strings` for AppKit-only UI. |
| 19 | `descript.ion` file comments (`FSFolder SetProperty(kpidComment)`, `TextPairs`) | Use Finder comments (`kMDItemFinderComment` via `NSMetadataItem`/AppleScript is awkward) — simplest: keep `descript.ion` semantics for parity, or map to the `com.apple.metadata:kMDItemFinderComment` xattr. |
| 20 | `FindFirstChangeNotification` folder watching (`IFolderWasChanged`) | `DispatchSource.makeFileSystemObjectSource` on the directory fd or FSEvents; keep the 1 s poll loop calling `WasChanged`. |
| 21 | Version control items (`7vc` registry, `VerCtrl.cpp`, read-only attribute toggling) | Optional; if kept, use `~/Library/Application Support/7-Zip/7vc` and `chflags uchg`/permission bits for the read-only marker. |
| 22 | Email (`-seml`, MAPI `MAPISendMail`) | `NSSharingService(named: .composeEmail)` with the archive as attachment. |
| 23 | Zone.Identifier propagation (`WriteZoneIdExtract`, `-snz`, `IFolderSetZoneIdMode`) | `com.apple.quarantine` xattr on extracted files when the archive itself is quarantined (mode `kAll`) or only for Office documents (`kOffice`). |
| 24 | Case-insensitive path comparisons, `\` separators, `X:` roots, `MAX_PATH`/`\\?\` super paths, 8.3 handling | `/` separators, case-sensitivity per volume (`URLResourceKey.volumeSupportsCaseSensitiveNamesKey`), no super-path logic; `IsCorrectFsName` stays (`.`/`..` only). Keep `CompareFileNames_ForFolderList` numeric-aware, case-insensitive sort (Finder-like). |
| 25 | `CBrowseDialog` fallback for long/super paths and `SHBrowseForFolder`/`GetOpenFileName` | Always `NSOpenPanel`/`NSSavePanel` (with `canCreateDirectories`); the custom Browse dialog is unnecessary except inside archives (not used there anyway). |
| 26 | Console-style Benchmark dialog `IDD_BENCH_TOTAL` writing to a read-only edit | Same, with a monospaced `NSTextView`. |
| 27 | `IsVirus_Message` (RLO / many spaces / hidden `.exe`) | Keep the check (RLO and space padding are platform-independent); extend `kExeExtensions` with `app`, `command`, `sh`, `pkg`, `dmg` for the hidden-extension warning. |
| 28 | Per-process single-threaded UI with modal `DialogBoxParam` loops, `PostMessage(kReLoadMessage)` etc. | `DispatchQueue.main.async` equivalents for the `kShiftSelectMessage`/`kReLoadMessage`/`kSetFocusToListView`/`kOpenItemChanged`/`kRefresh_StatusBar` deferred actions; sheets instead of modal dialogs where the operation has a clear parent window (progress dialog remains a separate window because it can outlive/pause the panel). |

---
*End of inventory.*
