# 7zFM dialogs and settings inventory (sections 4-5, split from 01-fm-feature-inventory.md)

## 4. Dialogs

Common resource conventions (`7zip/GuiCommon.rc`): dialog units with margin `m = 8`, button size `bxs = 64` × `bys = 16`, browse button `bxsDots = 20`; `MY_MODAL_DIALOG_STYLE = DS_MODALFRAME | WS_POPUP | WS_VISIBLE | WS_CAPTION | WS_SYSMENU`, `MY_MODAL_RESIZE_DIALOG_STYLE` adds `WS_THICKFRAME` and `DS_CENTER`; `MY_FONT` = MS Shell Dlg 8; macros `OK_CANCEL` (DEFPUSHBUTTON `IDOK` "OK" + `IDCANCEL` "Cancel" at bottom-right), `CONTINUE_CANCEL` (`IDCONTINUE` 11 "&Continue" + Cancel); `MY_COMBO` = `CBS_DROPDOWNLIST|WS_VSCROLL|WS_TABSTOP`, `MY_COMBO_WITH_EDIT` = `CBS_DROPDOWN|…`, `MY_CHECKBOX` = `BS_AUTOCHECKBOX|WS_TABSTOP`, `MY_TEXT_NOPREFIX` = `8, SS_NOPREFIX`. Every dialog with a `*_2` variant (`IDD_*_2 = IDD_* + 10000`) is the small-screen/CE layout — same control IDs, identical logic.

Common dialog behaviour (`Windows/Control/Dialog.cpp`, `Dialog.h`): `CModalDialog::Create(resID, parent)` → `DialogBoxParam`; `OnInit` → `LangSetWindowText`/`LangSetDlgItems` (localize); `OnButtonClicked` maps `IDOK → OnOK`, `IDCANCEL → OnCancel`, `IDCLOSE → OnClose`, `IDCONTINUE → OnContinue`, `IDHELP → OnHelp`; `NormalizeSize()`/`NormalizePosition()` shrink and center a dialog that would not fit the work area; `IsDialogSizeOK(x, y)` tells the caller to use the `_2` template on small screens. All button texts are localized through `kLangPairs` (§7).

### 4.1 About — `AboutDialog.cpp/.rc` (`IDD_ABOUT 2900`)

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Logo | `IDI_LOGO` (icon) | ICON | static |
| Version | `IDT_ABOUT_VERSION 101` | LTEXT `"7-Zip " MY_VERSION_CPU` (e.g. `7-Zip 26.03 (x64)`) | set from `MY_VERSION_CPU` at init |
| Date | `IDT_ABOUT_DATE 102` | LTEXT `MY_DATE` | static |
| Copyright | (no ID / `IDT_ABOUT_COPYRIGHT`) | LTEXT `MY_COPYRIGHT_CR` | static |
| Info | `IDT_ABOUT_INFO 2901` | LTEXT "7-Zip is free software" (localizable) | static |
| Home page | `IDB_ABOUT_HOMEPAGE 110` | PUSHBUTTON `"www.7-zip.org"` | `ShellExecute("https://www.7-zip.org/")` (`kHomePageURL`) |
| OK | `IDOK` | DEFPUSHBUTTON | close |

`OnHelp` → `ShowHelpWindow("start.htm")`.

### 4.2 Browse for folder / file — `BrowseDialog.cpp/.rc` (`IDD_BROWSE 95`)

7-Zip's own folder/file picker, used by `MyBrowseForFolder(hwnd, title, initialPath, result)` and `MyBrowseForFile(...)` (`BrowseDialog.h`). Selection rule (`BrowseDialog.cpp` `MyBrowseForFolder`): if the initial path is a "super" (`\\?\`) or device path, or its length ≥ `MAX_PATH`, or `SHBrowseForFolder` is unavailable, the custom dialog is used; otherwise the system dialog (`SHBrowseForFolder` for folders, `GetOpenFileName` via `CommonDlg_BrowseForFile` `Windows/CommonDialog.h:38` for files; filters are `(Description, Masks)` pairs). Both return `bool` and the chosen path.

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Folder label | `IDT_BROWSE_FOLDER 101` | LTEXT (current folder) | updated on navigation |
| Parent | `IDB_BROWSE_PARENT 110` | PUSHBUTTON `"<--"` | go to parent (`OpenParentFolder`); Backspace does the same |
| New folder | `IDB_BROWSE_CREATE_DIR 112` | PUSHBUTTON `"+"` | creates `"New Folder"` (`IDS_CREATE_FOLDER_DEFAULT_NAME`) via `Dlg_CreateFolder`, F7 does the same |
| List | `IDL_BROWSE 100` | LISTVIEW report, columns `Name`, `Modified` (`IDS_PROP_MTIME`), `Size` (`IDS_PROP_SIZE`), sorted like the panel (`CompareItems`), system icons | double-click/Enter enters a folder (or selects a file in file mode); Ctrl+R reloads; `..` row |
| Path | `IDE_BROWSE_PATH 102` | EDITTEXT (editable) | typed path is used on OK; folder mode: OK returns the current folder or the typed path |
| Filter | `IDC_BROWSE_FILTER 103` | COMBOBOX | file mode only: filter strings; hidden in folder mode |
| OK / Cancel | `IDOK` / `IDCANCEL` | | |

Properties: `FolderMode`, `ShowAllFiles`, `FilterIndex`, `Filters`, `Title`, `DirPrefix`, `FilePath` (`BrowseDialog.h`). Root (`Computer`) level shows drives (`CFSDrives`-like enumeration with `IDS_COMPUTER`).

### 4.3 Temp files browser — `BrowseDialog2.cpp/.rc` (`IDD_BROWSE2 93`, caption "7-Zip: Browse Temp Files")

Opened by Tools → "Delete Temporary Files...". Lists only entries of the temp folder whose names are `7zE`/`7zO`/`7zS` + 8 hex digits (7-Zip's own temp dirs; the "filter" combo has the single entry `"7-Zip temp files (7z*)"`).

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Folder | `IDT_BROWSE2_FOLDER` | read-only EDIT with the temp path | |
| Parent | `IDB_BROWSE_PARENT 110` | button | navigate up (also Backspace) |
| Refresh | (`IDM_VIEW_REFRESH` text) | button | re-enumerate |
| Delete | (`IDS_BUTTON_DELETE 7205` text) | button | asks `IDS_WANT_TO_DELETE_*` and deletes the selected dirs/files recursively (Del key too) |
| Filter | combo | `"7-Zip temp files (7z*)"` | fixed |
| List | report list, columns `Name`, `Modified`, `Size`, `Files`, `Folders`, `Name-2` (real name when display name is decorated) | enumeration computes per-entry size/files/folders counts with limits (`200` dirs / `2000` files scanned per entry before giving up) | |
| Close / Help | `IDCLOSE` / `IDHELP` | | Help → `"fm/temp.htm"` |

Context menu on items: `Delete`, `Open Outside` (Explorer), `Open Outside: 7-Zip` (new 7zFM instance at that path), `Properties`. Reparse points (junctions/symlinks) are refused for deletion to avoid following links.

### 4.4 Combo (single-value input) — `ComboDialog.cpp/.rc` (`IDD_COMBO 98`)

| Control | ID | Type | Behaviour |
|---|---|---|---|
| Static | `IDT_COMBO 100` | LTEXT `Static` (`CComboDialog::Static`) | |
| Combo | `IDC_COMBO 101` | `MY_COMBO_WITH_EDIT`, pre-filled with `Value` and `Strings` | `OnOK` reads the edit text into `Value` |
| OK / Cancel | | | |

Used by: Select/Deselect mask, Create Folder, Create File, Comment (§3.11), `Dlg_CreateFolder`.

### 4.5 Copy / Move destination — `CopyDialog.cpp/.rc` (`IDD_COPY 96`)

| Control | ID | Type | Behaviour |
|---|---|---|---|
| Label | `IDT_COPY` | LTEXT `Static` (`IDS_COPY_TO` / `IDS_MOVE_TO` / `IDS_COMBINE_TO`) | |
| Path | `IDC_COPY` | `MY_COMBO_WITH_EDIT` with `Value` + history `Strings` (CopyHistory) | result in `Value` |
| Browse | `IDB_COPY_SET_PATH` | PUSHBUTTON `"..."` | `MyBrowseForFolder(IDS_SET_FOLDER 6007 "Specify a location for output folder.", current text)` |
| Info | `IDT_COPY_INFO` | LTEXT multiline (`Info` = `GetItemsInfoString`) | up to `kCopyDialog_NumInfoLines = 11` lines |
| OK / Cancel | | | |

### 4.6 Text viewer — `EditDialog.cpp/.rc` (`IDD_EDIT_DLG 94`)

Resizable; single read-only multiline `EDITTEXT IDE_EDIT` (`ES_MULTILINE|ES_READONLY|ES_AUTOVSCROLL|WS_VSCROLL|WS_HSCROLL`) + `IDCLOSE` "Close". `Title` and `Text` members. Used by `CListViewDialog` (Enter on a row shows the full value) and for long messages.

### 4.7 Options › Editor page — `EditPage.cpp/.rc` (`IDD_EDIT 2103`, title `IDS_OPTIONS_EDIT`/"Editor")

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Viewer label | `IDT_EDIT_VIEWER` | "&Viewer:" | |
| Viewer path | `IDE_EDIT_VIEWER 100` | EDITTEXT | `ReadRegEditor(false)` / `SaveRegEditor(false)` (`Viewer`) |
| Viewer browse | `IDB_EDIT_VIEWER 101` | `"..."` | `MyBrowseForFile` with filter `*.exe` (`IDS_OPEN_TYPE_ALL_FILES` + "Executable") |
| Editor label/path/browse | `IDT_EDIT_EDITOR`, `IDE_EDIT_EDITOR 102`, `IDB_EDIT_EDITOR 103` | | registry `Editor` |
| Diff label/path/browse | `IDT_EDIT_DIFF`, `IDE_EDIT_DIFF 104`, `IDB_EDIT_DIFF 105` | | registry `Diff` |

`OnApply` saves the three strings; `OnNotifyHelp` → `"FM/options.htm#editor"`. Empty viewer/editor → the FM falls back to `notepad.exe` (`StartEditApplication`). Paths may contain arguments (`SplitCmdLineSmart` `PanelItemOpen.cpp:675` splits program and parameters; the file path is appended quoted).

### 4.8 Options › Folders page — `FoldersPage.cpp/.rc` (`IDD_FOLDERS 2400`, "Folders")

Working (temporary) folder for archive updates (`NWorkDir::CInfo`, `7zip/UI/Common/ZipRegistry.h`):

| Control | ID | Type / text | Default | Behaviour |
|---|---|---|---|---|
| Group | `IDG_FOLDERS_WORKING_FOLDER` | "&Working folder" | | |
| Radio | `IDR_FOLDERS_WORK_SYSTEM 2402` | "&System temp folder" | **checked** (`NWorkDir::NMode::kSystem = 0`) | |
| Radio | `IDR_FOLDERS_WORK_CURRENT 2403` | "&Current" (= folder of the archive) | | `kCurrent = 1` |
| Radio | `IDR_FOLDERS_WORK_SPECIFIED 2404` | "Specified:" | | `kSpecified = 2`; enables the edit/browse |
| Path | `IDE_FOLDERS_WORK_PATH 100` | EDITTEXT | empty | `WorkDirPath` |
| Browse | `IDB_FOLDERS_WORK_PATH 101` | `"..."` | | `MyBrowseForFolder(IDS_FOLDERS_SET_WORK_PATH_TITLE 2406 "Specify a location for temporary archive files.")` |
| Checkbox | `IDX_FOLDERS_WORK_FOR_REMOVABLE 2405` | "Use for removable drives only" | **checked** (`ForRemovableOnly = true`) | |

`OnApply` → `NWorkDir::CInfo::Save()` (§5.5). Used by `GetWorkDir()` (`7zip/UI/Common/WorkDir.cpp`) when creating `CWorkDirTempFile` for archive updates (§6.7).

### 4.9 Options › Language page — `LangPage.cpp/.rc` (`IDD_LANG 2101`, "Language")

| Control | ID | Type | Behaviour |
|---|---|---|---|
| Label | `IDT_LANG_LANG` | "Language:" | |
| Combo | `IDC_LANG_LANG 100` | `MY_COMBO` | first entry `"English (English)"` (built-in, value `-`), then every `Lang\*.txt` (`GetLangDirPrefix()`), listed as `<native name> (<English name>)` from lang lines 0/1; entries whose language matches the system UI language are marked with `***` (exact) / `+++` (primary language) prefix; current selection from registry `Lang` |
| Info | `IDT_LANG_INFO 101` | multiline static | for the selected file: `"<name> : <lines> / <EN lines> = NN%"` (`k_NumLangLines_EN = 443` reference count from the built-in `en.ttt`), the file's comment lines (`CLang::Comments`), and lists of missing/extra IDs relative to English |

`OnApply` → `SaveRegLang(value)` then `ReloadLang()` (§7); the Options dialog then reloads the menu and toolbars (`OptionsDialog.cpp` → `LangWasChanged` → `MyLoadMenu`, `ReloadToolbars`, `ReloadLangItems` `App.cpp:68`).

### 4.10 Link — `LinkDialog.cpp/.rc` (`IDD_LINK 7700`, "Link"; not built under CE)

Invoked by File → Link... (`CApp::Link()`), requires an FS folder and exactly one operated item (`IDS_SELECT_ONE_FILE`).

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| "Link from (path):" | `IDT_LINK_PATH_FROM` | | |
| From path | `IDC_LINK_PATH_FROM 100` | `MY_COMBO_WITH_EDIT` | pre-filled with `<current folder>\<item name>` (the link to be created) |
| Browse from | `IDB_LINK_PATH_FROM 103` | `"..."` | `MyBrowseForFile`/Folder |
| "Link to (path):" | `IDT_LINK_PATH_TO` | | |
| To path | `IDC_LINK_PATH_TO 101` | `MY_COMBO_WITH_EDIT` | target; pre-filled with the item's full path |
| Browse to | `IDB_LINK_PATH_TO 104` | `"..."` | |
| Current target | `IDT_LINK_PATH_TO_CUR 102` | static | if the item already is a reparse point, shows its decoded target (`NIO::GetReparseData` → `CReparseAttr`) |
| Group | `IDG_LINK_TYPE` | "Link type" | |
| Radio | `IDR_LINK_TYPE_HARD 7711` | "Hard Link" | `CreateHardLink`; default when the item is a file |
| Radio | `IDR_LINK_TYPE_SYM_FILE 7712` | "File Symbolic Link" | `CreateSymbolicLink` |
| Radio | `IDR_LINK_TYPE_SYM_DIR 7713` | "Directory Symbolic Link" | `CreateSymbolicLink(SYMBOLIC_LINK_FLAG_DIRECTORY)`; default for folders |
| Radio | `IDR_LINK_TYPE_JUNCTION 7714` | "Junction" | reparse point `IO_REPARSE_TAG_MOUNT_POINT` via `SetReparseData` |
| Radio | `IDR_LINK_TYPE_WSL 7715` | "WSL Symbolic Link" | `IO_REPARSE_TAG_LX_SYMLINK` |
| Link button | `IDB_LINK_LINK 7701` | DEFPUSHBUTTON "Link" | performs the operation; error → `MessageBox_LastError`; on success the panel is refreshed |
| Cancel | `IDCANCEL` | | |

### 4.11 List view (generic 1- or 2-column list) — `ListViewDialog.cpp/.rc` (`IDD_LISTVIEW 99`, resizable)

| Control | ID | Type | Behaviour |
|---|---|---|---|
| List | `IDL_LISTVIEW` | LISTVIEW report; `NumColumns` = 1 or 2 (`Strings` / `Values`), `LVS_EX_FULLROWSELECT` | |
| OK / Cancel | `IDOK`/`IDCANCEL` | | `OnOK` sets `FocusedItemIndex` (used by Folders History) |

Members: `Title`, `Strings`, `Values`, `NumColumns`, `SelectFirst`, `DeleteIsAllowed`, `StringsWereChanged`, `FocusedItemIndex`.
Keys: Del → deletes the focused row when `DeleteIsAllowed` (sets `StringsWereChanged`); Ctrl+A → select all; Ctrl+C / Ctrl+Ins → copies selected rows to the clipboard as `name: value` (2 columns) or plain lines, joined by `\r\n`; Enter / Alt+Enter → `CEditDialog` showing the focused row's full text. Used by Properties, Folders History, hash results, archive info, `CBrowseDialog2` stats.

### 4.12 Memory usage request — `MemDialog.cpp/.rc` (`IDD_MEM 7800`, caption "Memory usage request" `IDS_MEM_REQUIRES_BIG_MEM`)

Shown by `CExtractCallbackImp::RequestMemoryUse` (`ExtractCallback.cpp`) when a decoder needs more memory than the current limit (`IArchiveRequestMemoryUseCallback`).

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Message | `IDT_MEM_MESSAGE 101` | multiline static | `"<file> requires <N> GB … limit <M> GB"` composed from `IDS_MEM_*` strings + archive/file path |
| Checkbox | `IDX_MEM_SAVE_LIMIT 7801` | "Set new memory usage limit:" | when checked the spin value is written to `MemLimit` (§5.4) |
| Spin edit | `IDE_MEM_SPIN_EDIT 110` + `IDC_MEM_SPIN 111` | UPDOWN, unit GB (`IDT_MEM_GB 112` "GB") | range min 1 .. max(64, RAM−1 GB); initial = requested rounded up |
| Radio | `IDR_MEM_ALLOW 7820` | "Allow the operation" (default) | |
| Radio | `IDR_MEM_SKIP_ARC 7821` | "Skip this archive" | returns `E_ABORT`-like skip for the archive |
| Checkbox | `IDX_MEM_REMEMBER 7802` | "Remember this decision" (for this run) | stores in the callback so the next request uses the same answer |
| Continue / Cancel | `IDCONTINUE` / `IDCANCEL` | | Cancel → `E_ABORT` |

### 4.13 Options › 7-Zip (shell integration) page — `MenuPage.cpp/.rc` (`IDD_MENU 2300`, "7-Zip")

| Control | ID | Type / text | Default | Behaviour |
|---|---|---|---|---|
| Checkbox | `IDX_SYSTEM_INTEGRATE_TO_MENU 2301` | "Integrate 7-Zip to shell context menu" | registered? | writes/removes `7-zip.dll` shell-extension registration for the current user (`CheckContextMenuHandler`/`SetContextMenuHandler` in `RegistryContextMenu.cpp`) |
| Checkbox | `IDX_SYSTEM_INTEGRATE_TO_MENU_2 2310` | "Integrate 7-Zip to shell context menu (32-bit)" | | same for the 32-bit DLL on x64 |
| Checkbox | `IDX_SYSTEM_CASCADED_MENU 2302` | "Cascaded context menu" | **true** | `CContextMenuInfo.Cascaded` |
| Checkbox | `IDX_SYSTEM_ICON_IN_MENU 2304` | "Icons in context menu" | false | `MenuIcons` |
| Checkbox | `IDX_EXTRACT_ELIM_DUP 3430` | "Eliminate duplication of root folder" | **true** | `ElimDup` |
| Label + combo | `IDT_SYSTEM_ZONE 3440`, `IDC_SYSTEM_ZONE 101` | "Propagate Zone.Id stream:" with entries `No` (`IDS_NO`-style builtin, value 0), `Yes` (1), `For Office files` (`IDT_ZONE_FOR_OFFICE 3441`, value 2) | `-1` = not set → behaves as No | `WriteZone` |
| Group + list | `IDT_SYSTEM_CONTEXT_MENU_ITEMS`, `IDL_SYSTEM_OPTIONS 100` | "Context menu items:" check-list (`LVS_EX_CHECKBOXES`) with one row per `kMenuItems` flag: Open archive, Open archive >, Extract files..., Extract Here, Extract to <Folder>, Test archive, Add to archive..., Compress and email..., Add to <Archive>.7z, Compress to <Archive>.7z and email, Add to <Archive>.zip, Compress to <Archive>.zip and email, CRC SHA > | all checked (`NContextMenuFlags::GetDefaultFlags()`) | bitmask `ContextMenu` |

`OnApply` → `CContextMenuInfo::Save()` (§5.5) + shell registration; changes `Changed()` state per control.

### 4.14 Messages — `MessagesDialog.cpp/.rc` (`IDD_MESSAGES 6602`, caption "7-Zip: Diagnostic messages", resizable)

List `IDL_MESSAGE` with columns `#` and `Message` (`IDS_MESSAGE 6603`); `IDCLOSE` "Close". Fed with `Messages` (`UStringVector`). Used after Copy/Drop/Delete etc. when non-fatal messages were collected.

### 4.15 Overwrite confirmation — `OverwriteDialog.cpp/.rc` (`IDD_OVERWRITE 3500`, "Confirm File Replace")

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Header | `IDT_OVERWRITE_HEADER 3501` | "Destination folder already contains processed file." | |
| Question | `IDT_OVERWRITE_QUESTION_BEGIN 3502` | "Would you like to replace the existing file" | |
| Old icon / name / size+time | `IDI_OVERWRITE_OLD_FILE 100` (icon), `IDI_OVERWRITE_OLD_FILE_2 101` (name text), `IDT_OVERWRITE_OLD_FILE_SIZE_TIME 102` | icon from `GetRealIconIndex` of the existing file; name; `IDS_FILE_SIZE 3504` `"{0} bytes"` + time | `OldFileInfo` (`Path`, `Size`, `Time`, `Is_FileSystemFile`) |
| "with this one?" | `IDT_OVERWRITE_QUESTION_END 3503` | | |
| New icon / name / size+time | `IDI_OVERWRITE_NEW_FILE 110`, `IDI_OVERWRITE_NEW_FILE_2 111`, `IDT_OVERWRITE_NEW_FILE_SIZE_TIME 112` | | `NewFileInfo` |
| Yes | `IDYES` | "&Yes" | `IDYES` |
| Yes to All | `IDB_YES_TO_ALL 440` | "Yes to &All" | `IDB_YES_TO_ALL` (hidden when `ShowExtraButtons = false`) |
| Auto Rename | `IDB_AUTO_RENAME 3505` | "A&uto Rename" | `IDB_AUTO_RENAME` (hidden when `ShowExtraButtons = false`) |
| No | `IDNO` | "&No" | |
| No to All | `IDB_NO_TO_ALL 441` | "No to A&ll" | (hidden when `ShowExtraButtons = false`) |
| Cancel | `IDCANCEL` | "&Cancel" | `IDCANCEL` |

`DefaultButton_is_NO` makes "No" the default (used by VerCtrl Revert). Time is formatted with `ConvertUtcFileTimeToString` (local, seconds). Sizes shown only if defined. Mapped by `CExtractCallbackImp::AskOverwrite` (§8.4).

### 4.16 Password — `PasswordDialog.cpp/.rc` (`IDD_PASSWORD 3800`, "Enter password")

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Label | `IDT_PASSWORD_ENTER 3801` | "Enter password:" | |
| Password | `IDE_PASSWORD_PASSWORD 120` | EDITTEXT `ES_PASSWORD` | `Password` member |
| Show | `IDX_PASSWORD_SHOW 3803` | checkbox "Show password" | toggles `SetPasswordChar(0 / '*')`; initial value from `ShowPassword` (`NExtract::Read_ShowPassword()`), saved with `Save_ShowPassword` on OK |
| OK / Cancel | | | Cancel → caller returns `E_ABORT` |

Used by the open callback (`COpenArchiveCallback`, `FileFolderPluginOpen.cpp`), `CExtractCallbackImp::CryptoGetTextPassword` (`ExtractCallback.cpp`), `CUpdateCallbackGUI2::ShowAskPasswordDialog` (`UpdateCallbackGUI2.cpp:52`, parent = progress dialog, waits `WaitCreating`), and `CUpdateCallback100Imp`. The password is remembered per panel folder chain (`CFolderLink::UsePassword/Password`) so nested archives/re-opens don't ask again.

### 4.17 Progress — `ProgressDialog2.cpp/.rc` (`IDD_PROGRESS 97`, resizable) and the SFX-only `ProgressDialog.cpp` (`IDD_PROGRESS` in the SFX build: label + progress bar + Cancel, 100 ms timer)

Layout (`ProgressDialog2.rc`):

| Control | ID | Type / text |
|---|---|---|
| Elapsed label / value | `IDT_PROGRESS_ELAPSED 3900` "Elapsed time:" / `IDT_PROGRESS_ELAPSED_VAL 110` | |
| Remaining | `IDT_PROGRESS_REMAINING 3901` "Remaining time:" / `IDT_PROGRESS_REMAINING_VAL 111` | |
| Files | `IDT_PROGRESS_FILES 1032` ("Files") / `IDT_PROGRESS_FILES_VAL 112` | shows `cur / total` (or just `cur`) |
| Errors | `IDT_PROGRESS_ERRORS 3906` "Errors:" / `IDT_PROGRESS_ERRORS_VAL 113` | shown when > 0 |
| Total size | `IDT_PROGRESS_TOTAL 3902` "Total size:" / `IDT_PROGRESS_TOTAL_VAL 114` | |
| Speed | `IDT_PROGRESS_SPEED 3903` "Speed:" / `IDT_PROGRESS_SPEED_VAL 115` | `<N> KB/s / MB/s` |
| Processed | `IDT_PROGRESS_PROCESSED 3904` "Processed:" / `IDT_PROGRESS_PROCESSED_VAL 116` | |
| Packed size | `IDT_PROGRESS_PACKED 1008` ("Packed Size") / `IDT_PROGRESS_PACKED_VAL 117` | only when ratio info is provided (compression) |
| Ratio | `IDT_PROGRESS_RATIO 3905` "Compression ratio:" / `IDT_PROGRESS_RATIO_VAL 118` | |
| Status | `IDT_PROGRESS_STATUS 103` | e.g. `Compressing`, `Extracting`, `Scanning`, `Testing`, `Add`, `Update`, `Repack`, `Moving` … |
| File name | `IDT_PROGRESS_FILE_NAME 102` | current path (two lines: folder / name, reduced to fit with `ReduceString` `:324`) |
| Progress bar | `IDC_PROGRESS1 100` | `PBM_SETRANGE32` 0..range (range scaled down to fit 32 bits, `SetProgressRange` `:574`) |
| Messages list | `IDL_PROGRESS_MESSAGES 101` | report list of error/warning messages, shown (`EnableErrorsControls` `:332`) once the first message arrives; grows the dialog |
| Background | `IDB_PROGRESS_PRIORITY 444` "&Background" / after click `IDS_PROGRESS_FOREGROUND 445` "&Foreground" | `OnPriorityButton` `:1150`: `SetPriorityClass(IDLE_PRIORITY_CLASS)` for the whole process; title gets `<Background>` suffix |
| Pause | `IDB_PAUSE 446` "&Pause" / `IDS_CONTINUE 411` "&Continue" | `OnPauseButton` `:1130`: `Sync.Set_Paused(true)`; workers block in `CProgressSync::CheckStop` (`:100`, loops with `Sleep(kPauseSleepTime = 100 ms)` while paused); title gets `<Paused>` prefix (`IDS_PROGRESS_PAUSED 447`) |
| Cancel / Close | `IDCANCEL` "Cancel" → after completion text `IDS_CLOSE 408` "&Close" | Cancel while running: pauses, asks `IDS_PROGRESS_ASK_CANCEL 448` "Are you sure you want to cancel?" (Yes/No; No resumes), Yes → `Sync.Set_Stopped(true)` and workers see `E_ABORT` from `CheckStop` |

Behaviour (`CProgressDialog`):
* Created by `CProgressThreadVirt::Create(title, parent)` (`:1412`) which spawns the worker thread (`CProgressThreadVirt::Process` `:1432` calls `ProcessVirt()`, catches exceptions → `FinalMessage.ErrorMessage`) and shows the dialog **modally after a delay**: `kCreateDelay = 500 ms` — if the operation finishes before that no dialog appears (`WaitMode`); `IsModal`/`ShowCompressionInfo` flags.
* Timer `kTimerElapse = 200 ms` (`:33`, `:422`): `OnTimer` → `UpdateStatInfo` (`:695`) copies from `CProgressSync` (critical-section-protected struct: `_stopped`, `_paused`, `_bytesProgressMode`, `_totalBytes`, `_completedBytes`, `_totalFiles`, `_curFiles`, `_inSize/_outSize`, `_titleFileName`, `_status`, `_filePath`, `_isDir`, `Messages`, `FinalMessage.ErrorMessage/OkMessage`), computes elapsed (`GetTimeString` `:602` → `hh:mm:ss`), remaining = elapsed × (total−done)/done, speed, ratio = out/in %. `kMaxRatio`-style guards avoid division by zero.
* Title (`SetTitleText` `:1084`): `"<Paused> NN% <Background> <Title> <fileName>"` — percent is also mirrored into the taskbar button via `ITaskbarList3::SetProgressValue/State` (`SetTaskbarProgressState` `:306`).
* When the worker finishes (`ProcessWasFinished` `:1305` via `kCloseMessage`): if there are messages or a `FinalMessage`, the dialog stays open, Pause/Background hidden, Cancel becomes Close (`CheckNeedClose` `:1296`); error → `MessageBoxW(MB_ICONERROR)` with `FinalMessage.ErrorMessage.Message` (title = dialog title), ok message → info box; otherwise the dialog closes itself. `MessagesDisplayed`, `_wasCreated` flags. `OnExternalCloseMessage` `:991`.
* Messages list: `AddMessage` (`:1173`) splits multi-line text, numbers rows (`AddMessageDirect` `:1159`), `AddError_Message_Name` `:228` formats `"<msg> : <name>"`, `AddError_Code_Name` `:244` uses `HResultToMessage` (`:1477`: Win32 error text, or `"Error #x"`); Ctrl+A/Ctrl+C in the list copies (`CopyToClipboard` `:1369`).
* `CProgressCloser` / `CDisableTimerProcessing` wrappers; result HRESULT of `ProcessVirt` is stored in `Result` and turned into `FinalMessage` if not `S_OK`/`E_ABORT` (`E_ABORT` = silent cancel).

### 4.18 Property names — `PropertyName.rc` / `PropertyNameRes.h`

`IDS_PROP_<X> = 1000 + kpid<X>` for kpid 3..104 (`PropertyNameRes.h:3-104`), e.g. `1003 Path`, `1004 Name`, `1005 Extension`, `1006 Folder`, `1007 Size`, `1008 Packed Size`, `1009 Attributes`, `1010 Created`, `1011 Accessed`, `1012 Modified`, `1013 Solid`, `1014 Commented`, `1015 Encrypted`, `1016 Split Before`, `1017 Split After`, `1018 Dictionary`, `1019 CRC`, `1020 Type`, `1021 Anti`, `1022 Method`, `1023 Host OS`, `1024 File System`, `1025 User`, `1026 Group`, `1027 Block`, `1028 Comment`, `1029 Position`, `1030 Path Prefix`, `1031 Folders`, `1032 Files`, `1033 Version`, `1034 Volume`, `1035 Multivolume`, `1036 Offset`, `1037 Links`, `1038 Blocks`, `1039 Volumes`, `1041 64-bit`, `1042 Big-endian`, `1043 CPU`, `1044 Physical Size`, `1045 Headers Size`, `1046 Checksum`, `1047 Characteristics`, `1048 Virtual Address`, `1049 ID`, `1050 Short Name`, `1051 Creator Application`, `1052 Sector Size`, `1053 Mode`, `1054 Symbolic Link`, `1055 Error`, `1056 Total Size`, `1057 Free Space`, `1058 Cluster Size`, `1059 Label`, `1060 Local Name`, `1061 Provider`, `1062 NT Security`, `1063 Alternate Stream`, `1064 Aux`, `1065 Deleted`, `1066 Tree`, `1067 SHA-1`, `1068 SHA-256`, `1069 Error Type`, `1070 Errors`, `1071 Errors`, `1072 Warnings`, `1073 Warning`, `1074 Streams`, `1075 Alternate Streams`, `1076 Alternate Streams Size`, `1077 Virtual Size`, `1078 Unpack Size`, `1079 Total Physical Size`, `1080 Volume Index`, `1081 SubType`, `1082 Short Comment`, `1083 Code Page`, `1084 Is not archive type`, `1085 Physical Size can't be detected`, `1086 Zeros Tail Is Allowed`, `1087 Tail Size`, `1088 Embedded Stub Size`, `1089 Link`, `1090 Hard Link`, `1091 iNode`, `1092 Stream ID`, `1093 Read-only`, `1094 Out Name`, `1095 Copy Link`, `1096 Archive File Name`, `1097 Is Hash`, `1098 Metadata Changed`, `1099 User ID`, `1100 Group ID`, `1101 Device Major`, `1102 Device Minor`, `1103 Dev Major`, `1104 Dev Minor`. `PropertyName.cpp` `GetNameOfProperty(propID, name)` returns the localized string when `propID < 1000`-range is covered, else the handler-supplied BSTR name.

### 4.19 Options › Settings page — `SettingsPage.cpp/.rc` (`IDD_SETTINGS 2500`, "Settings")

| Control | ID | Text | Default | Persisted as |
|---|---|---|---|---|
| Checkbox | `IDX_SETTINGS_SHOW_DOTS 2501` | "Show \"..\" item" | false | `ShowDots` |
| Checkbox | `IDX_SETTINGS_SHOW_REAL_FILE_ICONS 2502` | "Show real file icons" | false | `ShowRealFileIcons` |
| Checkbox | `IDX_SETTINGS_SHOW_SYSTEM_MENU 2503` | "Show system menu" | false | `ShowSystemMenu` |
| Checkbox | `IDX_SETTINGS_FULL_ROW 2504` | "Full row select" | false | `FullRow` |
| Checkbox | `IDX_SETTINGS_SHOW_GRID 2505` | "Show grid lines" | false | `ShowGrid` |
| Checkbox | `IDX_SETTINGS_SINGLE_CLICK 2506` | "Single-click to open an item" | false | `SingleClick` |
| Checkbox | `IDX_SETTINGS_ALTERNATIVE_SELECTION 2507` | "Alternative selection mode" | false | `AlternativeSelection` |
| Checkbox | `IDX_SETTINGS_LARGE_PAGES 2508` | "Use large memory pages" | false | `LargePages` (HKCU\Software\7-Zip) — needs `SeLockMemoryPrivilege`; disabled if `!IsLargePageSupported()` |
| Label | `IDT_COMPRESS_MEMORY_DE`-style `7816` | "Memory usage limit for extraction:" | | |
| Checkbox + spin | `IDX_SETTINGS_MEM_LIMIT 100`, `IDE_SETTINGS_MEM_SPIN_EDIT 101` + `IDC_SETTINGS_MEM_SPIN 102`, `IDT_SETTINGS_MEM_GB 103` "GB" | | unchecked = no limit | `Extraction\MemLimit` (GB; `NExtract::Read_LimitGB / Save_LimitGB`) |

`OnApply` → `CFmSettings::Save()` (`RegistryUtils.cpp:121`) + `SaveLockMemoryEnable`; the Options dialog then calls `SetListSettings()` and `RefreshAllPanels()`; Help → `"FM/options.htm#settings"`.

### 4.20 Split — `SplitDialog.cpp/.rc` (`IDD_SPLIT 7300`, "Split File")

| Control | ID | Text | Behaviour |
|---|---|---|---|
| Label | `IDT_SPLIT_PATH 7301` | "&Split to:" | |
| Path | `IDC_SPLIT_PATH 100` | `MY_COMBO_WITH_EDIT` (`FolderPath`) | |
| Browse | `IDB_SPLIT_PATH 101` | `"..."` | `MyBrowseForFolder(IDS_SET_FOLDER 6007 "Specify a location for output folder.")` (`SplitDialog.cpp:92`) |
| Label | `IDT_SPLIT_VOLUME 7302` | "Split to &volumes, bytes:" | |
| Volume | `IDC_SPLIT_VOLUME 102` | `MY_COMBO_WITH_EDIT` with presets (§3.14) | `OnOK`: `ParseVolumeSizes` must succeed and yield ≥ 1 size, else `IDS_INCORRECT_VOLUME_SIZE 7307` "Incorrect volume size" and the dialog stays open |
| OK / Cancel | | | |

### 4.21 Options › System page — `SystemPage.cpp/.rc` (`IDD_SYSTEM 2200`, "System")

File association editor.

| Control | ID | Text | Behaviour |
|---|---|---|---|
| Label | `IDT_SYSTEM_ASSOCIATE` | "Associate 7-Zip with:" | |
| Button | `IDB_SYSTEM_CURRENT 101` | `"+"` (current user column) | toggles all rows for HKCU |
| Button | `IDB_SYSTEM_ALL 102` | `"+"` (all users column) | toggles all rows for HKLM (needs admin; errors ignored) |
| List | `IDL_SYSTEM_ASSOCIATE 100` | report list: columns `Extension` (`IDS_PROP_EXTENSION`), current-user marker, all-users marker; one row per extension from `g_CodecsObj` formats (`CExtDatabase`) | click on a marker column, Space, `+`/`-` keys toggle; state values: `kAssocState_None`/`_7Zip`/`_Other` (shows the other app's program-id name) |

`OnApply` (`SystemPage.cpp`): for each changed row writes/removes `HKCU|HKLM\Software\Classes\.<ext>` default value → `7-Zip.<ext>` with `7-Zip.<ext>\DefaultIcon = "<dir>7z.dll,<iconIndex>"` (icon index from `GetIconPath`/`CExtInfoBig`) and `shell\open\command = "<dir>7zFM.exe" "%1"` (`RegistryAssociations.cpp`), then `SHChangeNotify(SHCNE_ASSOCCHANGED)`. Help → `"FM/options.htm#system"`.

### 4.22 Options property sheet — `OptionsDialog.cpp` (`OptionsDialog(hwnd, hInstance)` `:32`)

`MyPropertySheet` (`Windows/Control/PropertyPage.cpp:74`) with pages in this order: `IDD_SYSTEM` (System), `IDD_MENU` (7-Zip), `IDD_FOLDERS` (Folders), `IDD_EDIT` (Editor), `IDD_SETTINGS` (Settings), `IDD_LANG` (Language); title `IDS_OPTIONS 2100` "Options"; page titles are the localized `IDD_*` captions. Each page implements `OnInit`, `OnCommand` (calls `Changed()`), `OnApply`, `OnNotifyHelp`. After the sheet closes: if `LangWasChanged` → `MyLoadMenu(true)` + `g_App.ReloadLangItems()` + `ReloadToolbars()`; then `g_App.SetListSettings()` and `g_App.RefreshAllPanels()`.

### 4.23 Add to Archive (Compress) — `GUI/CompressDialog.cpp/.rc` (`IDD_COMPRESS 4000`, caption "Add to Archive")

Shown by `7zG.exe a -ad …` (§8.1) through `UpdateGUI.cpp` `ShowDialog` (fills `NCompressDialog::CInfo` from the command line / `CUpdateOptions`), never in-process by 7zFM.

#### Controls

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Folder line | `IDT_COMPRESS_ARCHIVE_FOLDER 130` | LTEXT (target folder path, shown when the archive name is relative) | |
| "&Archive:" | `IDT_COMPRESS_ARCHIVE 4001` | LTEXT | |
| Archive name | `IDC_COMPRESS_ARCHIVE 100` | `MY_COMBO_WITH_EDIT`, history `ArcHistory` (`kHistorySize = 20`, `:86`) | on format change the extension is swapped (`SetArchiveName`); "Compress to <name>.7z" pre-fills |
| Browse | `IDB_COMPRESS_SET_ARCHIVE 101` | `"..."` | `MyBrowseForFile` (save mode, filter for the format, title `IDS_COMPRESS_SET_ARCHIVE_BROWSE` "Browse") |
| "Archive &format:" | `IDT_COMPRESS_FORMAT 4003` / `IDC_COMPRESS_FORMAT 104` | `MY_COMBO | CBS_SORT` | formats from `g_Formats` that exist in `g_CodecsObj` with `UpdateEnabled`; default = registry `Archiver` (default `7z`) or forced by the caller |
| "Compression &level:" | `IDT_COMPRESS_LEVEL 4004` / `IDC_COMPRESS_LEVEL 102` | `MY_COMBO` | `IDS_METHOD_STORE` (0) "Store", `IDS_METHOD_FASTEST` (1) "Fastest", `IDS_METHOD_FAST` (3) "Fast", `IDS_METHOD_NORMAL` (5) "Normal", `IDS_METHOD_MAXIMUM` (7) "Maximum", `IDS_METHOD_ULTRA` (9) "Ultra"; only levels allowed by the format's `LevelsMask` |
| "Compression &method:" | `IDT_COMPRESS_METHOD 4005` / `IDC_COMPRESS_METHOD 106` | `MY_COMBO` | per format (table below); hidden/disabled for level 0 |
| "&Dictionary size:" | `IDT_COMPRESS_DICTIONARY 4006` / `IDC_COMPRESS_DICTIONARY 107` | `MY_COMBO` | per method (below); shown as `KB/MB/GB` |
| "&Word size:" | `IDT_COMPRESS_ORDER 4007` / `IDC_COMPRESS_ORDER 108` | `MY_COMBO` | fast bytes / PPMd order |
| "&Solid Block size:" | `IDT_COMPRESS_SOLID 4008` / `IDC_COMPRESS_SOLID 109` | `MY_COMBO` | 7z/xz only |
| "Number of CPU &threads:" | `IDT_COMPRESS_THREADS 4009` / `IDC_COMPRESS_THREADS 110` + `IDT_COMPRESS_HARDWARE_THREADS 112` `"/ <N>"` | `MY_COMBO` + RTEXT | |
| "Memory usage for Compressing:" | `IDT_COMPRESS_MEMORY 4017` / `IDC_COMPRESS_MEM_USE 117` + `IDT_COMPRESS_MEMORY_VALUE 113` | combo + value text | combo built by `SetMemUseCombo` (`:2767`): default item `80%` (`AddMemComboItem(80, true, true)`), then `10%..100%`, then absolute sizes `2^n` and `3·2^(n-1)` from 128 MiB upward (`for i = 54..`), the registry value inserted in place; value text shows the estimated usage `<N> MB` (red-ish warning when above limit) |
| "Memory usage for Decompressing:" | `IDT_COMPRESS_MEMORY_DE 4018` / `IDT_COMPRESS_MEMORY_DE_VALUE 114` | | estimated decompression memory |
| "Split to &volumes, bytes:" | `IDT_SPLIT_TO_VOLUMES 7302` / `IDC_COMPRESS_VOLUME 105` | `MY_COMBO_WITH_EDIT` with the same presets as Split (§3.14) | empty = no volumes |
| "Parameters:" | `IDT_COMPRESS_PARAMETERS 4010` / `IDE_COMPRESS_PARAMETERS 111` | EDITTEXT | free `-m` switches, see parameter generation below |
| Options button | `IDB_COMPRESS_OPTIONS 2100` "Options" + `IDT_COMPRESS_OPTIONS 141` | opens §4.24; the static shows a summary of the options currently set (e.g. `-snl -snh -tm-`) | |
| "&Update mode:" | `IDT_COMPRESS_UPDATE_MODE 4002` / `IDC_COMPRESS_UPDATE_MODE 103` | `MY_COMBO` | `IDS_COMPRESS_UPDATE_MODE_ADD` "Add and replace files" (`k_ActionSet_Add`), `…_UPDATE` "Update and add files", `…_FRESH` "Freshen existing files", `…_SYNC` "Synchronize files" (`g_UpdateMode_Pairs` in `UpdateGUI.cpp`) |
| "Path mode:" | `IDT_COMPRESS_PATH_MODE 3410` / `IDC_COMPRESS_PATH_MODE 116` | `MY_COMBO` | `IDS_PATH_MODE_RELAT` "Relative pathnames" (`kRelative`), `IDS_EXTRACT_PATHS_FULL` "Full pathnames" (`kFull`), `IDS_EXTRACT_PATHS_ABS` "Absolute pathnames" (`kAbsolute`) (`:398-400`) |
| Options group | `IDG_COMPRESS_OPTIONS 4011` "Options" | | |
| SFX | `IDX_COMPRESS_SFX 4012` "Create SF&X archive" | checkbox | 7z only (`Flags & kSFX`), disabled when volumes are used; sets `Info.SFXMode`; the archive extension becomes `.exe`; module `7z.sfx` (`kDefaultSfxModule`) from the program folder |
| Shared | `IDX_COMPRESS_SHARED 4013` "Compress shared files" | checkbox | `OpenShareForWrite` (`-ssw`) |
| Delete | `IDX_COMPRESS_DEL 4019` "Delete files after compression" | checkbox | `DeleteAfterCompressing` (`-sdel`) |
| Encryption group | `IDG_COMPRESS_ENCRYPTION 4014` "Encryption" | | shown for formats with `kEncrypt` (7z, zip) |
| Password | `IDT_PASSWORD_ENTER 3801` "Enter &password:" / `IDE_COMPRESS_PASSWORD1 120`; `IDT_PASSWORD_REENTER 3802` "Reenter password:" / `IDE_COMPRESS_PASSWORD2 121` | `ES_PASSWORD` edits | |
| Show password | `IDX_PASSWORD_SHOW 3803` | checkbox | hides the re-enter field; persisted `Compression\ShowPassword` |
| "&Encryption method:" | `IDT_COMPRESS_ENCRYPTION_METHOD 4015` / `IDC_COMPRESS_ENCRYPTION_METHOD 122` | combo | 7z: `AES-256`; zip: `ZipCrypto` (default), `AES-256`; persisted `EncryptionMethod` per format |
| Encrypt names | `IDX_COMPRESS_ENCRYPT_FILE_NAMES 4016` "Encrypt file &names" | checkbox | 7z only (`kEncryptFileNames`), `-mhe`; persisted `EncryptHeaders` |
| OK / Cancel / Help | `IDOK` / `IDCANCEL` / `IDHELP` | | Help → `kHelpTopic = "fm/plugins/7-zip/add.htm"` (`CompressDialog.cpp:1254`) |

#### Format table (`g_Formats[]`, `CompressDialog.cpp:271+`) — `{Name, LevelsMask, Methods, Flags}`

| Format | Levels | Methods (first = default) | Flags |
|---|---|---|---|
| `""` (unknown/other handler) | 0-9 | — | — |
| `7z` | 0,1,2,3,4,5,6,7,8,9 | LZMA2, LZMA, PPMd, BZip2, Deflate, Deflate64, Copy (+ zstd/… when the handler advertises them) | `kFilter | kSolid | kMultiThread | kEncrypt | kEncryptFileNames | kMemUse | kSFX` |
| `Zip` | 0,1,3,5,7,9 | Deflate, Deflate64, BZip2, LZMA, PPMd (+ zstd) | `kMultiThread | kEncrypt | kMemUse` |
| `GZip` | 1,5,7,9 | Deflate | `kMemUse` |
| `BZip2` | 1,3,5,7,9 | BZip2 | `kMultiThread | kMemUse` |
| `xz` | 1-9 | LZMA2 | `kSolid | kMultiThread | kMemUse` |
| `Tar` | 0 | (GNU / POSIX variants via `-mm`) | — |
| `wim` | 0 | — | — |
| `Hash` (hash-list "archive") | 0 | SHA256, SHA1, … (checksum methods) | — |

Level names: `IDS_METHOD_STORE/FASTEST/FAST/NORMAL/MAXIMUM/ULTRA`. SFX method list restricted to Copy/LZMA/LZMA2/PPMd (`kSFXMethods`).

#### Automatic values (`CompressDialog.cpp` `SetDictionary` ~`:1960-2130`, `SetOrder` ~`:2200+`, `SetSolidBlockSize` `:2379-2500`, `SetNumThreads` ~`:2540-2700`)

* **Dictionary** (`_auto_Dict`, level L): LZMA/LZMA2: L ≤ 4 → `1 << (2L + 16)` (64 KB … 16 MB); L 5..9 → `1 << (L + 20)` (32 MB … 512 MB) but capped by the format (7z ≤ 1.5 GB/1536 MB on 64-bit; 32-bit builds cap at 128 MB–; zip LZMA ≤ 64 MB for old zip readers). PPMd: `1 << (L + 19)` (7z) / zip PPMd `1 << (L + 19)` with 4 MB..; BZip2: 900 KB (L ≥ 5), 500 KB (L 3), 100 KB (L 1); Deflate: 32 KB; Deflate64: 64 KB. Combo items: powers of two (and 3·2^n in the top range) from 64 KB up to the cap; item text `<N> KB/MB/GB`; the auto item is selected by default and there is no explicit "auto" entry — the selected value is only emitted when it differs from `_auto_Dict` (see `Get_Dict_ForDialogLevel`).
* **Word size / order** (`_auto_Order`): LZMA/LZMA2: 32 (L ≤ 6), 64 (L ≥ 7); Deflate/Deflate64: 32 (L ≤ 6), 64 (L 7), 128 (L 9); PPMd (7z): 4 (L 1), 6 (L 3), 16 (L 5), 32 (L 7+); PPMd (zip): `L + 3` clamped 2..16; BZip2 has none. Items: LZMA 5..273 (5,8,12,16,24,32,48,64,96,128,192,256,273), Deflate 3..258, PPMd 2..32.
* **Solid block size** (`_auto_Solid`, 7z/xz): level 0 → non-solid; LZMA2 → `chunk << 6` else `dict << 7`; minimum 16 MB, maximum 4 GB (32-bit) / 16 GB (64-bit); combo items `IDS_COMPRESS_NON_SOLID` "Non-solid", `1 MB … 64 GB` (powers of two from `kMinSize = 1 MB` `:2379`), `IDS_COMPRESS_SOLID` "Solid" (= single block, value `(UInt64)-1`, encoded as `-ms=e`/`on`); the auto value is preselected.
* **Threads** (`_auto_NumThreads`): hardware thread count (`NSystem::GetNumberOfProcessors`) limited per method: LZMA 2, LZMA2 up to 512, BZip2 64, zip 128 (Deflate: one file per thread; zip+LZMA uses 2 sub-threads per file so `numMainZipThreads = threads/2`, `:2918-2929`), xz 512, PPMd/others 1; further reduced so that the estimated memory stays under the memory-usage limit; combo items 1..(max even number up to 2×hardware) plus the hardware count; the "/ N" static shows the hardware count.
* **Memory limit** (`Get_MemUse_Bytes`): percent of `_ramSize_Reduced` (RAM minus a reserve) or absolute; `80%` default.
* **Memory estimation** (`GetMemoryUsage_Threads_Dict_DecompMem` `:2901-3068`): level 0 → 1 MB; filter (BCJ2 etc.) at level ≥ 9 adds `(12 MB)*2 + 5 MB`; LZMA: `dict * 11.5 + 6 MB` per thread-block (`+ (dict * 4 ... )` for `lc/lp` hash tables, ×2 for 2 threads), LZMA2: per block `dict * ...` × number of blocks = threads/2; PPMd: `dict + 50 KB`; BZip2: ~`10 MB × threads`; Deflate: `1 MB × threads`; zip adds `numMainZipThreads` multiples; decompression memory: LZMA/LZMA2 `dict + 2 MB` (+ solid overhead), PPMd `dict`, BZip2 4 MB, Deflate 2 MB. Displayed in `IDT_COMPRESS_MEMORY_VALUE` / `_DE_VALUE`.

#### OnOK validation (`CompressDialog.cpp:1064-1240`)

1. zip: password must be ASCII (`IsAsciiString`, `IDS_PASSWORD_USE_ASCII`); zip+AES: length ≤ 99 (`IDS_PASSWORD_TOO_LONG`).
2. If "Show password" is unchecked the two password fields must match (`IDS_PASSWORD_NOT_MATCH`).
3. Estimated compression memory must not exceed the memory-use limit, else `SetErrorMessage_MemUsage` (`IDS_MEM_OPERATION_BLOCKED` "The operation was blocked by 7-Zip." + `IDS_MEM_REQUIRES_BIG_MEM` + sizes + `IDS_MEM_ERROR`) and the dialog stays open.
4. Archive path: `GetFinalPath_Smart` — relative names are resolved against the dialog's folder (`IDT_COMPRESS_ARCHIVE_FOLDER`), extension appended/corrected per format (except when the base name already ends with an extension in `k_DontSave_Exts = "xpi odt ods docx xlsx"` (`:876`) which are zip containers whose name must be kept); invalid → `k_IncorrectPathMessage`.
5. Volumes: `ParseVolumeSizes` (`IDS_INCORRECT_VOLUME_SIZE`); last size < 100 KB (`100 << 10`) → confirm `IDS_SPLIT_CONFIRM` ("Specified volume size: {0} bytes. Are you sure…"); SFX + volumes is not allowed (SFX box disabled).
6. Saves registry (`CInfo::Save` §5.4 + `CFormatOptions` per format: Method, Level, Dictionary, Order, BlockSize, NumThreads, MemUse, EncryptionMethod, Options = parameters text, time options), adds the archive path to `ArcHistory` (max 20).

#### Parameter string generation (`UpdateGUI.cpp` `SetOutProperties`, shown above in source, and `ParseAndAddPropertires`)

Properties are passed to the handler through `ISetProperties` as name/value pairs in this order:
`x` = level; if a method was chosen (`setMethod` = the user changed method/dict/order or the format is 7z): `0`=method (7z) or `m`=method (others); dictionary `0d`/`d` (or `0mem`/`mem` for PPMd, size with `b` suffix); order `0fb`/`fb` (or `0o`/`o` for PPMd); `em` = encryption method; `he` = encrypt headers (7z); `s` = solid block size; `mt` = threads; `memuse` = `NN%` or bytes; `tm`/`tc`/`ta` = store M/C/A time (bool pairs, only when set); `tp` = time precision. Then the user's **Parameters** text is split on spaces, a leading `-m` is stripped from each token, `name=value` pairs added (and a `mt`, `x`, `0`… token here overrides the generated one; a user-specified method (`0=`/`m=`) disables the generated dict/order). Global options: `-r0` recursion, `-sdel`, `-ssw`, `-snl`/`-snh`/`-sni`/`-sns` (symlinks/hardlinks/security/alt streams from §4.24), `-stl` (`SetArcMTime`), `-slp`, `-sfx<module>` (SFX), `-v<size>` volumes, `-ap`/`-spf` path mode, `-u` update action set (`k_ActionSet_*`), `-ssp` (preserve ATime). Work directory for the temp archive from `NWorkDir` (§4.8).

### 4.24 Compress Options — `GUI/CompressOptionsDialog.rc` (`IDD_COMPRESS_OPTIONS 14001`, caption "Options"; `COptionsDialog` in `CompressDialog.cpp:3350-3700`)

| Control | ID | Text | Behaviour |
|---|---|---|---|
| Group | `IDG_COMPRESS_NTFS 115` | "NTFS" | |
| Checkbox | `IDX_COMPRESS_NT_SYM_LINKS 4040` | "Store symbolic links" | `-snl`; registry `SymLinks` (bool pair: Def/Val) |
| Checkbox | `IDX_COMPRESS_NT_HARD_LINKS 4041` | "Store hard links" | `-snh`; `HardLinks` |
| Checkbox | `IDX_COMPRESS_NT_ALT_STREAMS 4042` | "Store alternate data streams" | `-sns`; `AltStreams` |
| Checkbox | `IDX_COMPRESS_NT_SECUR 4043` | "Store file security" | `-sni`; `Security` |
| Info | `IDT_COMPRESS_TIME_INFO 191` | static describing the format's native precision | |
| Group | `IDG_COMPRESS_TIME 4080` | "Time" | |
| Set-checkbox + label + combo | `IDX_COMPRESS_PREC_SET 201`, `IDT_COMPRESS_TIME_PREC 4081` "Timestamp precision:", `IDC_COMPRESS_TIME_PREC 190` | combo entries built by `AddTimeOption`: `Windows (100 ns)` (`kTimePrec_Win 0`), `Unix (1 sec)` (1), `DOS (2 sec)` (2), `Linux (1 ns)` (3), plus base precisions 0..9 digits when the handler supports them (`IDS_COMPRESS_SEC` "sec" / `IDS_COMPRESS_NS` "ns"); enabled only when the "set" box is checked; default from `Get_DefaultTimePrec()` of the format | `-mtp=N`; registry `TimePrec` |
| Set + checkbox | `IDX_COMPRESS_MTIME_SET 202` / `IDX_COMPRESS_MTIME 4082` "Store modification time" | | `-mtm`; `MTime` |
| Set + checkbox | `IDX_COMPRESS_CTIME_SET 203` / `IDX_COMPRESS_CTIME 4083` "Store creation time" | | `-mtc`; `CTime` |
| Set + checkbox | `IDX_COMPRESS_ATIME_SET 204` / `IDX_COMPRESS_ATIME 4084` "Store last access time" | | `-mta`; `ATime` |
| Set + checkbox | `IDX_COMPRESS_ZTIME_SET 205` / `IDX_COMPRESS_ZTIME 4085` "Set archive time to latest file time" | | `-stl`; `SetArcMTime` |
| Checkbox | `IDX_COMPRESS_PRESERVE_ATIME 4086` | "Do not change source files last access time" | `-ssp`; `PreserveATime` |
| OK / Cancel / Help | | | Help → `kHelpTopic_Options = "fm/plugins/7-zip/add.htm#options"` (`CompressDialog.cpp:1255`) |

"Set" checkboxes implement tri-state (`CBoolPair{Def, Val}`): unchecked "set" = leave the handler default and emit nothing.

### 4.25 Extract — `GUI/ExtractDialog.cpp/.rc` (`IDD_EXTRACT 3400`, caption "Extract")

Shown by `7zG.exe x -ad …`. `CExtractDialog` members: `DirPath`, `ArcPath`, `Password`, `PathMode`, `OverwriteMode`, `ElimDup`, `NtSecurity`, `AltStreams`, `OverwriteMode_Force`, `_info` (`NExtract::CInfo` registry).

| Control | ID | Text | Behaviour |
|---|---|---|---|
| "E&xtract to:" | `IDT_EXTRACT_EXTRACT_TO 3401` | | |
| Path | `IDC_EXTRACT_PATH 100` | `MY_COMBO_WITH_EDIT`, history `PathHistory` (`kHistorySize = 16`, `:91`) | initial = `DirPath` (caller-provided: archive folder + sub-folder name) |
| Browse | `IDB_EXTRACT_SET_PATH 101` | `"..."` | `MyBrowseForFolder(IDS_EXTRACT_SET_FOLDER "Specify a location for extracted files.")` |
| Sub-folder checkbox | `IDX_EXTRACT_NAME_ENABLE 131` | (no text) | when checked the name in the edit is appended to the path (`SplitDest` registry, default **true**) |
| Sub-folder name | `IDE_EXTRACT_NAME 130` | EDITTEXT | default = `GetSubFolderNameForExtract(arcName)`; checkbox unchecked → disabled |
| "Path mode:" | `IDT_EXTRACT_PATH_MODE 3410` / `IDC_EXTRACT_PATH_MODE 102` | `MY_COMBO` | `kPathMode_IDs` (`:33`): `IDS_EXTRACT_PATHS_FULL` "Full pathnames" → `kFullPaths`, `IDS_EXTRACT_PATHS_NO` "No pathnames" → `kNoPaths`, `IDS_EXTRACT_PATHS_ABS` "Absolute pathnames" → `kAbsPaths`; `kCurPaths` (used when extracting a sub-folder from the FM) is displayed as Full (`:172`) and kept unless the user picks something else (`:303`); persisted `ExtractMode` (with `PathMode_Force`) |
| Elim dup | `IDX_EXTRACT_ELIM_DUP 3430` | "Eliminate duplication of root folder" | `ElimDup` (registry default true); when the archive has a single root folder equal to the sub-folder name, that level is dropped |
| "Overwrite mode:" | `IDT_EXTRACT_OVERWRITE_MODE 3420` / `IDC_EXTRACT_OVERWRITE_MODE 103` | `MY_COMBO` | `IDS_EXTRACT_OVERWRITE_ASK` "Ask before overwrite" → `kAsk`, `…_WITHOUT_PROMPT` "Overwrite without prompt" → `kOverwrite`, `…_SKIP_EXISTING` "Skip existing files" → `kSkip`, `…_RENAME` "Auto rename" → `kRename`, `…_RENAME_EXISTING` "Auto rename existing files" → `kRenameExisting` (`NExtract::NOverwriteMode`, `Common/ExtractMode.h:20-29`); persisted `OverwriteMode` (+`OverwriteMode_Force`) |
| Password group | `IDG_PASSWORD 3807` "Password" / `IDE_EXTRACT_PASSWORD 120` / `IDX_PASSWORD_SHOW 3803` | | password pre-filled if the caller already knows it; `ShowPassword` persisted |
| NT security | `IDX_EXTRACT_NT_SECUR 3431` | "Restore file security" | `NtSecurity` (`-sni`), persisted `Security` |
| OK / Cancel / Help | | | `OnOK` `:299-390`: reads modes, password, bool pairs, saves `_info` (`NExtract::CInfo::Save`), adds the path to history (max 16); Help → `"fm/plugins/7-zip/extract.htm"` |

Path modes in the engine (`Common/ExtractMode.h:10-17`): `kFullPaths` (full relative paths), `kCurPaths` (paths relative to the current archive folder — FM "extract this folder"), `kNoPaths` (flatten), `kAbsPaths` (allow absolute/`..` paths), `kNoPathsAlt` (flatten but keep `file:stream` alt-stream names — used by the Agent for alt-stream folders). Zone-ID modes: `kNone`, `kAll`, `kOffice` (`:33-39`).

### 4.26 Benchmark — `GUI/BenchmarkDialog.cpp/.rc` (`IDD_BENCH 7600` resizable; `IDD_BENCH_TOTAL 7699` for `-mm=*` mode)

Runs in `7zG.exe b` (`Benchmark(totalMode)` in `CompressCall.cpp:330-340` → `7zG b [-mm=*] -slp`).

| Control | ID | Text | Behaviour |
|---|---|---|---|
| Restart | `IDB_RESTART 443` | "&Restart" | `RestartBenchmark` (`:922`): stops the worker (`SendExit_Status("Stop for restart ...")`) and starts again with the current combo values |
| Stop | `IDB_STOP 442` | "&Stop" | `OnStopButton` (`:949`) → worker exits at the next pass boundary; button disabled afterwards |
| Help / Cancel | `IDHELP` / `IDCANCEL` | | Help → `"fm/benchmark.htm"`; Cancel stops and closes |
| "&Dictionary size:" | `IDT_BENCH_DICTIONARY 4006` / `IDC_BENCH_DICTIONARY 101` | combo | sizes from `kMinDicSize = 1 << kBenchMinDicLogSize` (= 256 KB, `Bench.h:74` log 18) doubling (and 3·2^n) up to `kMaxDicSize = 1 << (22 + sizeof(size_t)/4*5)` (`:429`, = 4 GB on 64-bit builds), limited by RAM (`IsMemoryUsageOK` `:324`: usage + 1 MB ≤ `RamSize_Limit`); default = the largest size whose usage fits, starting from the standard 32 MB (`:570-582`) |
| Memory usage | `IDT_BENCH_MEMORY 7601` / `IDT_BENCH_MEMORY_VAL 102` | | `<N> MB` from `GetBenchMemoryUsage(numThreads, dict)` (`Bench.cpp`; roughly `dict × 10 × threads/2 + fixed overhead`), printed by `Print_MemUsage` `:732` |
| "&Number of CPU threads:" | `IDT_BENCH_NUM_THREADS 4009` / `IDC_BENCH_NUM_THREADS 103` + `IDT_BENCH_HARDWARE_THREADS 104` `"/ <hw>"` | combo | 1, 2, 4, … even numbers up to 2 × hardware threads; default = hardware threads |
| Column headers | `IDT_BENCH_SIZE 1007` "Size", `IDT_BENCH_USAGE_LABEL 7608` "CPU Usage", `IDT_BENCH_SPEED 3903` "Speed", `IDT_BENCH_RPU_LABEL 7609` "Rating / Usage", `IDT_BENCH_RATING_LABEL 7604` "Rating" | | |
| Compressing group | `IDG_BENCH_COMPRESSING 7602` with rows `IDT_BENCH_CURRENT 7606` "Current" (`IDT_BENCH_COMPRESS_SIZE1 170`, `_USAGE1 114`, `_SPEED1 110`, `_RPU1 116`, `_RATING1 112`) and `IDT_BENCH_RESULTING 7607` "Resulting" (`171`, `115`, `111`, `117`, `113`) | | speed in KB/s, usage in %, rating in MIPS |
| Decompressing group | `IDG_BENCH_DECOMPRESSING 7603`, rows `IDT_BENCH_CURRENT2 7656` / `IDT_BENCH_RESULTING2 7657` with `172/122/118/124/120` and `173/123/119/125/121` | | |
| Error | `IDT_BENCH_ERROR_MESSAGE 161` | | shows a decoding error / "CRC error" if the round trip failed |
| Total rating group | `IDG_BENCH_TOTAL_RATING 7605` with `IDT_BENCH_TOTAL_USAGE_VAL 133`, `IDT_BENCH_TOTAL_RPU_VAL 131`, `IDT_BENCH_TOTAL_RATING_VAL 130` | | averages of compress/decompress |
| CPU / version / features / system | `IDT_BENCH_CPU 106`, `IDT_BENCH_VER 105` ("7-Zip 26.03 (x64)"), `IDT_BENCH_CPU_FEATURE 109`, `IDT_BENCH_SYS1 107`, `IDT_BENCH_SYS2 108` | static | CPU name/frequency, feature flags, OS version, RAM |
| Log | `IDT_BENCH_LOG 160` | multi-line static (right side) | one line per pass: `pass: <n> ... <rating>` |
| "Elapsed time:" / "Passes:" | `IDT_BENCH_ELAPSED 3900` / `IDT_BENCH_ELAPSED_VAL 140`, `IDT_BENCH_PASSES 7610` / `IDT_BENCH_PASSES_VAL 142`, `IDC_BENCH_NUM_PASSES 143` | combo | pass count choices `1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, … 10 000 000` (or unlimited); the benchmark runs until the number of passes is reached, then stops |

Behaviour: worker thread `CThreadBenchmark` runs `Bench()` from `7zip/UI/Common/Bench.cpp` with a `IBenchCallback`/`IBenchPrintCallback` implementation that updates a `CBenchProgressSync` struct; the dialog timer (`kTimerElapse = 1000 ms`, `:40`) copies values into the controls (`:1000-1250`). `kMaxLog…` limits the log. Changing dictionary/threads/passes restarts. Total mode (`IDD_BENCH_TOTAL`): a read-only multi-line edit `IDE_BENCH2_EDIT 100` that receives the console-style benchmark text (`-mm=*` runs all methods) plus elapsed time; Help/Cancel.

### 4.27 Hash results — `GUI/HashGUI.cpp`

`ShowHashResults(hb, hwnd)` (`:330`) → `AddHashBundleRes(pairs, hb)` (`:179-231`): pairs `IDS_PROP_NUM_ERRORS` (if any), `IDS_PROP_NAME` = single file name (when one file), `IDS_PROP_FOLDERS`, `IDS_PROP_FILES`, `IDS_PROP_SIZE`, `IDS_PROP_NUM_ALT_STREAMS`, `IDS_PROP_ALT_STREAMS_SIZE` (when > 0), then per hasher: `<Method>` (if single file, plain hex), `IDS_CHECKSUM_CRC_DATA` "<Method> for data", `IDS_CHECKSUM_CRC_DATA_NAMES` "… for data and names", `IDS_CHECKSUM_CRC_STREAMS_NAMES` "… for streams and names". Displayed in `CListViewDialog` titled `IDS_CHECKSUM_INFORMATION` "Checksum information" with 2 columns (`:310-328`). Progress title `IDS_CHECKSUM_CALCULATING` "Checksum calculating" (`:298`), status `IDS_SCANNING` while enumerating; the `7zG h` path uses `CHashCallbackGUI` (`:60-300`) with `IDS_MESSAGE_NO_ERRORS` appended when the hash-file test found no errors.

---

## 5. Settings persistence (registry → macOS `UserDefaults` mapping)

All keys are under `HKEY_CURRENT_USER\Software\7-Zip` (`kCUBasePath`); some legacy reads also check `HKLM`. Types: `REG_SZ` (string), `REG_DWORD` (`UInt32`), `REG_BINARY` (blob), `REG_MULTI_SZ`-like string lists (stored as one binary blob of `\0`-separated UTF-16 strings — `SaveStringList` `ViewSettings.cpp:275`), bool = `REG_DWORD` 0/1.

### 5.1 `HKCU\Software\7-Zip` (`RegistryUtils.cpp`)

| Value | Type | Default | Reader / writer | Used by |
|---|---|---|---|---|
| `Lang` | string | `""` (= system language) ; `"-"` = English/built-in | `ReadRegLang` / `SaveRegLang` `:58-59` | `ReloadLang` (§7), LangPage |
| `LargePages` | bool | `false` | `ReadLockMemoryEnable` / `SaveLockMemoryEnable` `:170-171` | `SetMemoryLock` at startup, `-slp` switch |

### 5.2 `HKCU\Software\7-Zip\FM` (`RegistryUtils.cpp`, `ViewSettings.cpp`)

| Value | Type | Default | Reader / writer | Used by |
|---|---|---|---|---|
| `Viewer` | string | `""` → notepad | `ReadRegEditor(false)` / `SaveRegEditor(false)` `:61-62` | F3 |
| `Editor` | string | `""` → notepad | `ReadRegEditor(true)` | F4, edit-in-archive |
| `Diff` | string | `""` (hides Diff) | `ReadRegDiff` / `SaveRegDiff` `:64-65` | `IDM_DIFF`, `IDM_BENCHMARK2` visibility |
| `7vc` | string | `""` (hides Ver* items) | `ReadReg_VerCtrlPath` `:67` (read-only, no UI) | VerCtrl |
| `ShowDots` | bool | false | `CFmSettings::Load/Save` `:121-168` | `_showDots` |
| `ShowRealFileIcons` | bool | false | " | icon lookup |
| `FullRow` | bool | false | " | `LVS_EX_FULLROWSELECT` |
| `ShowGrid` | bool | false | " | `LVS_EX_GRIDLINES` |
| `SingleClick` | bool | false | " | `LVS_EX_ONECLICKACTIVATE|TRACKSELECT` |
| `AlternativeSelection` | bool | false | " | `_mySelectMode` / `LVS_SINGLESEL` |
| `ShowSystemMenu` | bool | false | " | context menu System submenu |
| `FlatViewArc<N>` (N = panel index 0/1) | bool | false | `ReadFlatView` / `SaveFlatView` `:180-190` | panel flat mode |
| `ShowDeleted` | bool | false | `Read_ShowDeleted` `:193` (no UI; unused/commented) | — |
| `Position` | binary 20 bytes: `Int32 left, top, right, bottom; UInt32 maximized` | none (system default placement) | `CWindowInfo::Read/Save` `ViewSettings.cpp:141-196` | main window |
| `Panels` | binary 12 bytes: `UInt32 numPanels, currentPanel, splitterPos` | numPanels 1, current 0, splitter = half | same | panels |
| `Toolbars` | UInt32 mask | `0x80000000 | 8 | 4 | 1` (bit31 = "defaults", archive+standard visible, labels on) | `ReadToolbarsMask` / `SaveToolbarsMask` `:213-227` | toolbars |
| `ListMode` | UInt32, one byte per panel (`mode & 0xFF`, `(mode >> 8) & 0xFF`) | `3` (Details) each | `CListMode::Read/Save` `:229-248` | view mode |
| `PanelPath0`, `PanelPath1` | string | `""` | `ReadPanelPath` / `SavePanelPath` `:250-273` | start folders |
| `FolderHistory` | string list (max 100) | empty | `ReadFolderHistory` / `SaveFolderHistory` `:292-295` | Folders History |
| `FolderShortcuts` | string list (exactly 10) | 10 empty strings | `ReadFastFolders` / `SaveFastFolders` `:297-300` | Favorites |
| `CopyHistory` | string list (max 20) | empty | `ReadCopyHistory` / `SaveCopyHistory` `:302-305` | Copy dialog |

### 5.3 `HKCU\Software\7-Zip\FM\Columns\<FolderTypeID>` (`ViewSettings.cpp:56-139`, `CListViewInfo`)

One binary value per folder type ID (e.g. `FSFolder`, `FSDrives`, `RootFolder`, `NetFolder`, `AltStreamsFolder`, `7-Zip.7z`, `7-Zip.zip`, `7-Zip.tar`, …), value name = the folder type ID itself. Layout (little-endian `UInt32`): `version (1)`, `SortID` (PROPID), `Ascending` (0/1), `count`, then `count` × `{PropID, IsVisible, Width}`. Read (`:80`) ignores blobs with a different version/size. Saved by `SaveListViewInfo` (`PanelItems.cpp:1322-1383`) whenever the panel leaves a folder type or exits.

### 5.4 `HKCU\Software\7-Zip\Extraction` and `\Compression` (`7zip/UI/Common/ZipRegistry.cpp`)

| Key / value | Type | Default | Notes |
|---|---|---|---|
| `Extraction\ExtractMode` | UInt32 (`NPathMode`) | `kFullPaths` (0) | `PathMode_Force` in memory only |
| `Extraction\OverwriteMode` | UInt32 (`NOverwriteMode`) | `kAsk` (0) | |
| `Extraction\ShowPassword` | bool | false | shared by Password dialog |
| `Extraction\PathHistory` | string list (max 16) | empty | |
| `Extraction\SplitDest` | bool | **true** | "extract to sub-folder named after archive" |
| `Extraction\ElimDup` | bool | (unset → true) | `CBoolPair` |
| `Extraction\Security` | bool | (unset) | restore NT security |
| `Extraction\MemLimit` | UInt32 GB | (unset = no limit) | `Read_LimitGB` / `Save_LimitGB`; MemDialog / SettingsPage |
| `Compression\ArcHistory` | string list (max 20) | empty | |
| `Compression\Archiver` | string | `"7z"` | last format (`ArcType`) |
| `Compression\Level` | UInt32 | 5 | last global level |
| `Compression\ShowPassword` | bool | false | |
| `Compression\EncryptHeaders` | bool | false | |
| `Compression\Security`, `AltStreams`, `HardLinks`, `SymLinks`, `PreserveATime` | bool pairs (`Def`/`Val`) | unset | NTFS options |
| `Compression\Options\<FormatName>\Method` | string | | e.g. `LZMA2` |
| `…\Options` | string | | the "Parameters" text |
| `…\EncryptionMethod` | string | | `AES-256` / `ZipCrypto` |
| `…\MemUse32` / `MemUse64` | string | | `80%` or bytes (separate values for 32/64-bit builds) |
| `…\Level` | UInt32 | | per format |
| `…\Dictionary` | UInt32/UInt64 | | bytes |
| `…\Order` | UInt32 | | |
| `…\BlockSize` | UInt64 | | solid block |
| `…\NumThreads` | UInt32 | | |
| `…\TimePrec` | UInt32 | | |
| `…\MTime`, `CTime`, `ATime`, `SetArcMTime` | bool pairs | | |

### 5.5 `HKCU\Software\7-Zip\Options` (`ZipRegistry.cpp`, `NWorkDir::CInfo`, `CContextMenuInfo`)

| Value | Type | Default | Used by |
|---|---|---|---|
| `WorkDirType` | UInt32 (`NWorkDir::NMode`: 0 system, 1 current, 2 specified) | 0 | archive update temp file location (`CWorkDirTempFile`) |
| `WorkDirPath` | string | `""` | |
| `TempRemovableOnly` | bool | **true** | use the work dir only when the archive is on a removable drive |
| `CascadedMenu` | bool | true | shell menu |
| `MenuIcons` | bool | false | shell menu |
| `ElimDupExtract` | bool | true | `CContextMenuInfo.ElimDup` |
| `WriteZoneIdExtract` | UInt32 (`-1` unset / 0 no / 1 yes / 2 office) | `-1` | `CContextMenuInfo.WriteZone` |
| `ContextMenu` | UInt32 flags (`Explorer/ContextMenuFlags.h:8-24`: `kExtract 1<<0`, `kExtractHere 1<<1`, `kExtractTo 1<<2`, `kTest 1<<4`, `kOpen 1<<5`, `kOpenAs 1<<6`, `kCompress 1<<8`, `kCompressTo7z 1<<9`, `kCompressEmail 1<<10`, `kCompressTo7zEmail 1<<11`, `kCompressToZip 1<<12`, `kCompressToZipEmail 1<<13`, `kCRC 1<<31`) | all set (`GetDefaultFlags()`) | which shell items appear (MenuPage list, §4.13) |

### 5.6 Shell registration written by the Options pages (Windows only)

* `HKCU|HKLM\Software\Classes\.<ext>` = `7-Zip.<ext>`, `7-Zip.<ext>\DefaultIcon`, `7-Zip.<ext>\shell\open\command` (`RegistryAssociations.cpp`).
* `HKCU\Software\Classes\*\shellex\ContextMenuHandlers\7-Zip`, `Directory\…`, `Folder\…`, `Drive\…`, `CLSID\{23170F69-40C1-278A-1000-000100020000}` (`RegistryContextMenu.cpp`, `MenuPage`).

### 5.7 Suggested `UserDefaults` mapping

Use one domain (`org.7-zip.7zFM` or the bundle ID) and keep the value names: `Lang`, `LargePages` (drop), `FM.Viewer/Editor/Diff`, `FM.ShowDots`…`FM.ShowSystemMenu`, `FM.FlatViewArc0/1`, `FM.Position` (use `NSWindow frameAutosaveName` instead), `FM.Panels` (`numPanels`, `currentPanel`, `splitterRatio`), `FM.Toolbars`, `FM.ListMode0/1`, `FM.PanelPath0/1`, `FM.FolderHistory` (array), `FM.FolderShortcuts` (array of 10), `FM.CopyHistory`, `FM.Columns.<FolderTypeID>` (dictionary: `sortID`, `ascending`, `columns: [{propID, visible, width}]`), `Extraction.*`, `Compression.*`, `Compression.Options.<Format>.*`, `Options.WorkDirType/Path/TempRemovableOnly`, `Options.ElimDupExtract`, `Options.WriteZoneIdExtract` (map to `com.apple.quarantine`), `Options.ContextMenu` (Finder extension items). Everything that is a `CBoolPair` must stay tri-state (absent / false / true).

---

