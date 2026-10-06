# 7zFM dialogs and settings inventory (sections 4-5, split from 01-fm-feature-inventory.md)

Verified against source by a second pass on 2026-09-12.

## 4. Dialogs

Common resource conventions (`7zip/GuiCommon.rc`): dialog units with margin `m = 8`, button size `bxs = 64` × `bys = 16`, browse button `bxsDots = 20`; button columns `bx1 = xs - m - bxs`, `bx2 = bx1 - m - bxs`, `bx3`, rows `by1 = ys - m - bys`, `by2`; `MY_MODAL_DIALOG_STYLE = DS_MODALFRAME | DS_CENTER | WS_POPUP | WS_CAPTION | WS_SYSMENU`, `MY_MODAL_RESIZE_DIALOG_STYLE` adds `WS_MINIMIZEBOX | WS_MAXIMIZEBOX | WS_SIZEBOX | WS_THICKFRAME`; `MY_PAGE_STYLE = WS_CHILD | WS_DISABLED | WS_CAPTION` (property-sheet pages, `OPTIONS_PAGE_XC_SIZE 300` × `OPTIONS_PAGE_YC_SIZE 280`); `MY_FONT` = MS Shell Dlg 8; macros `OK_CANCEL` (DEFPUSHBUTTON `IDOK` "OK" at `bx2` + PUSHBUTTON `IDCANCEL` "Cancel" at `bx1`, bottom-right), `CONTINUE_CANCEL` (DEFPUSHBUTTON `IDCONTINUE` 11 "Continue" + Cancel), `MY_BUTTON__CLOSE` (DEFPUSHBUTTON `IDCLOSE` "&Close" at `bx1`); `MY_COMBO` = `CBS_DROPDOWNLIST|WS_VSCROLL|WS_TABSTOP`, `MY_COMBO_SORTED` = `MY_COMBO|CBS_SORT`, `MY_COMBO_WITH_EDIT` = `CBS_DROPDOWN|CBS_AUTOHSCROLL|WS_VSCROLL|WS_TABSTOP`, `MY_CHECKBOX` = `"Button", BS_AUTOCHECKBOX|WS_TABSTOP` (`MY_CONTROL_CHECKBOX(text,id,x,y,xsize)` height 10, `_2LINES` adds `BS_MULTILINE` height 16, `MY_CONTROL_CHECKBOX_COLON` = a 18-du-wide ":" checkbox), `MY_AUTORADIOBUTTON` (+`_GROUP` adds `WS_GROUP`), `MY_TEXT_NOPREFIX` = `8, SS_NOPREFIX`, `MY_CONTROL_EDIT_WITH_SPIN(idEdit, idSpin, text, x, y, xSize)` = centered `ES_NUMBER` edit + `msctls_updown32` buddy spinner (`UDS_SETBUDDYINT|UDS_ALIGNRIGHT|UDS_AUTOBUDDY|UDS_ARROWKEYS|UDS_NOTHOUSANDS`). Every dialog with a `*_2` variant (`IDD_*_2 = IDD_* + 10000`: `IDD_EDIT_2 12103`, `IDD_FOLDERS_2 12400`, `IDD_LANG_2 12101`, `IDD_MENU_2 12300`, `IDD_OVERWRITE_2 13500`, `IDD_PROGRESS_2 10097`, `IDD_SETTINGS_2 12500`, `IDD_SYSTEM_2`, `IDD_COMPRESS_2`, `IDD_EXTRACT_2`, …) is the small-screen/CE layout — same control IDs, identical logic.

Common dialog behaviour (`Windows/Control/Dialog.cpp`, `Dialog.h`): `CModalDialog::Create(resID, parent)` → `DialogBoxParam`; `OnInit` → `LangSetWindowText`/`LangSetDlgItems` (localize); `OnButtonClicked` maps `IDOK → OnOK`, `IDCANCEL → OnCancel`, `IDCLOSE → OnClose`, `IDCONTINUE → OnContinue`, `IDHELP → OnHelp`; `NormalizeSize()`/`NormalizePosition()` shrink and center a dialog that would not fit the work area; `IsDialogSizeOK(x, y)` tells the caller to use the `_2` template on small screens. All button texts are localized through `kLangPairs` (§7).

### 4.1 About — `AboutDialog.cpp/.rc` (`IDD_ABOUT 2900`)

Caption "About 7-Zip", 144 × 144 du, `MY_MODAL_DIALOG_STYLE` (not resizable).

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Logo | `IDI_LOGO 100` (icon resource `7zipLogo.ico`), control id `-1` | ICON 32 × 32, `SS_REALSIZEIMAGE` | static |
| Version | `IDT_ABOUT_VERSION 101` | LTEXT, empty in .rc | `SetItemText("7-Zip " MY_VERSION_CPU)` at `OnInit` (`AboutDialog.cpp:48`), e.g. `7-Zip 26.03 (x64)` |
| Date | `IDT_ABOUT_DATE 102` | LTEXT, empty in .rc | `SetItemText(MY_DATE)` (`:49`) |
| Copyright | control id `-1` | LTEXT `MY_COPYRIGHT` (static in .rc) | static |
| Info | `IDT_ABOUT_INFO 2901` | LTEXT "7-Zip is free software" | the only item in `kLangIDs` (localized) |
| Home page | `IDB_ABOUT_HOMEPAGE 110` | PUSHBUTTON `"www.7-zip.org"` at `bx2` | `ShellExecute(NULL, NULL, "https://www.7-zip.org/", …, SW_SHOWNORMAL)` (`kHomePageURL`, `:65-77`) |
| OK | `IDOK` | DEFPUSHBUTTON at `bx1` | close |

`OnInit` (`:32-53`): with `Z7_EXTERNAL_CODECS`, if `g_CodecsObj->GetCodecsErrorMessage()` is non-empty it is shown first as an error MessageBox; then `NormalizePosition()`. `OnHelp` → `ShowHelpWindow("start.htm")` (`kHelpTopic`).

### 4.2 Browse for folder / file — `BrowseDialog.cpp/.rc` (`IDD_BROWSE 95`)

7-Zip's own folder/file picker (`CBrowseDialog`, compiled only with `USE_MY_BROWSE_DIALOG`), caption "7-Zip: Browse", `MY_MODAL_RESIZE_DIALOG_STYLE`. Entry points (`BrowseDialog.h`): `MyBrowseForFolder(hwnd, title, initialPath, result)` and `CBrowseInfo::BrowseForFile(filters)` (`CBrowseInfo : CCommonDialogInfo`, filters are `CBrowseFilterInfo {Masks, Description}`). Selection rule: folders (`BrowseDialog.cpp:873-900`) — the system `NShell::BrowseForFolder` (`SHBrowseForFolder`) is used unless the initial path is a super (`\\?\`)/device path or its length ≥ `MAX_PATH`, in which case the custom dialog is used; files (`:926-990`) — `CommonDlg_BrowseForFile` (`GetOpenFileName`/`GetSaveFileName`, `Windows/CommonDialog.h`) is tried first and the custom dialog is used only when it fails with `FNERR_INVALIDFILENAME` on a path ≥ `MAX_PATH`; other errors show a MessageBox. Both return `bool` and the chosen path.

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Parent | `IDB_BROWSE_PARENT 110` | PUSHBUTTON `"<--"` (24 × 16 at top-left) | `OpenParentFolder()` (`:749`); Backspace does the same (`OnKeyDown :456`) |
| New folder | `IDB_BROWSE_CREATE_DIR 112` | PUSHBUTTON `"+"` | `OnCreateDir()` (`:787-815`): `Dlg_CreateFolder` (Combo dialog pre-filled with `IDS_CREATE_FOLDER_DEFAULT_NAME`), `CorrectFsPath`, `CreateComplexDir`, then reload and select; F7 does the same |
| Folder label | `IDT_BROWSE_FOLDER 101` | LTEXT (current `DirPrefix`) | `SetItemText` in `Reload` (`:644`) |
| List | `IDL_BROWSE 100` | `SysListView32` report, columns `Name` (`IDS_PROP_NAME`), `Modified` (`IDS_PROP_MTIME`), `Size` (`IDS_PROP_SIZE`, right-aligned), sortable by header click (`CompareItems`), small system icons (`Shell_Get_SysImageList_smallIcons`) | Enter/double-click on a folder enters it, on a file (file mode) finishes with OK (`OnItemEnter :820`); Ctrl+R reloads; `..` row (`kParentIndex = -1`); selection changes update the path edit (`SetPathEditText :760`); honours FM `SingleClick` (`LVS_EX_ONECLICKACTIVATE`) and `ShowDots` settings (`:173-177`) |
| Path | `IDE_BROWSE_PATH 102` | EDITTEXT `ES_AUTOHSCROLL`, initial text = selected name (folder mode: with trailing separator) | `FinishOnOK` (`:851-869`): `GetFullPath(DirPrefix, text)`; invalid → `ERROR_INVALID_NAME` MessageBox; folder mode normalizes to a dir prefix; `FilterIndex` = combo selection; `End(IDOK)` |
| Filter | `IDC_BROWSE_FILTER 103` | COMBOBOX `MY_COMBO` filled with `Filters[i].Description` | selection change → `Reload()`; with ≤ 1 filter: hidden in folder mode, disabled in file mode (`:199-205`) |
| OK / Cancel | `IDOK` / `IDCANCEL` | plain PUSHBUTTONs (no default button) | |

Properties (`BrowseDialog.cpp:136-142`): `SaveMode`, `FolderMode`, `FilterIndex` (in/out), `Filters`, `FilePath` (in/out), `DirPrefix`, `Title` (sets the caption when non-empty). `OnInit` (`:240-275`) computes `_topDirPrefix` (drive root → can go up to the drives list on Windows) and walks up parents until a `Reload` succeeds. Errors from enumeration are shown via `MessageBox_HResError` (`:75`).

### 4.3 Temp files browser — `BrowseDialog2.cpp/.rc` (`IDD_BROWSE2 93`, caption "7-Zip: Browse Temp Files")

Opened by Tools → "Delete Temporary Files..." (`IDM_TEMP_DIR 910`, `MyLoadMenu.cpp:931` → `MyBrowseForTempFolder(g_HWND)`, `BrowseDialog2.cpp:1853-1873`): the window title is the menu text with `...` stripped (fallback "Delete Temporary Files"), `TempFolderPath` = `MyGetTempPath()`. Inside the exact temp folder (`IsExactTempFolder`, `:264`) only entries named `7z` + `E`|`O`|`S` (case-insensitive: E = drag&drop/copy/e-mail, O = open, S = SFX setup) + exactly 8 hex chars are listed (`:1546-1558`); subfolders are listed unfiltered. The Parent button is disabled while in the exact temp folder (`:1603`). Resizable (`MY_MODAL_RESIZE_DIALOG_STYLE`).

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Delete | `IDS_BUTTON_DELETE 7205` (string id reused as control id; localized via `kLangIDs`) | PUSHBUTTON "Delete" (top-left) | `OnDelete` (`:896-975`): confirm with `IDS_CONFIRM_FOLDER_DELETE`/`IDS_WANT_TO_DELETE_FOLDER`, `IDS_CONFIRM_FILE_DELETE`/`IDS_WANT_TO_DELETE_FILE` or `IDS_CONFIRM_ITEMS_DELETE`/`IDS_WANT_TO_DELETE_ITEMS` (+ first 10 names), `MB_YESNOCANCEL`; then `RemoveDirWithSubItems` / `DeleteFileAlways` (permanent, no Recycle Bin); Del key and Ctrl+A (select all) supported |
| Refresh | `IDM_VIEW_REFRESH` (menu id reused as control id, localized) | PUSHBUTTON "Refresh" | `Reload_WithErrorMessage()`; Ctrl+R too |
| Parent | `IDB_BROWSE2_PARENT 110` | PUSHBUTTON `"<--"` | `OpenParentFolder()`; Backspace too |
| Folder | `IDT_BROWSE2_FOLDER 101` | EDITTEXT `ES_READONLY\|ES_AUTOHSCROLL` showing `DirPrefix` | |
| List | `IDL_BROWSE2 100` | `SysListView32` report; columns `Name`, `Modified`, `Size` (`99999 MB+` width), `Files`, `Folders` (`IDS_PROP_FILES`/`IDS_PROP_FOLDERS`), second `Name` column = name of the single root item inside a temp dir (`_columnIndex_fileNameInDir`, `:1734`) | per-dir counts computed by `CBrowseEnumerator` with `k_EnumerateDirsLimit = 200` / `k_EnumerateFilesLimit = 2000` (`:85-86`); interrupted counts show a `+` suffix; Ctrl+F3/F5/F6 sort by name/mtime/size (`:660-672`); Enter opens folder / file (Shift+Enter → Explorer, Alt+Enter → properties, `:1803-1835`) |
| Filter | `IDC_BROWSE2_FILTER 103` | COMBOBOX `MY_COMBO` with the single fixed string `"7-Zip temp files (7z*)"` (`:349`) | |
| Close / Help | `IDCLOSE` (PUSHBUTTON, `WS_GROUP`) / `IDHELP` | not DEFPUSHBUTTON — Enter is used for item activation (`.rc:18`) | Help → `ShowHelpWindow("fm/temp.htm")` (`:979`); Esc → `IDCANCEL` |

Context menu (`:1200-1235`): `Delete\tDelete`, `Open Outside\tShift+Enter` (`IDM_OPEN_OUTSIDE`, Explorer/`ShellExecuteEx`), `Open Outside : 7-Zip` (new 7zFM at that path), `Properties\tAlt+Enter` (`IDS_PROPERTIES`, `Show_FileProps_Window` `:881`: name/size/mtime/attributes/files/folders in a MessageBox). Items with reparse points (junctions/symlinks) are neither descended during counting (`:150`) nor opened (`k_Message_Link_operation_was_Blocked` "link openning was blocked by 7-Zip", `:63`, `:1274`, `:1824`); they can still be deleted as a whole.

### 4.4 Combo (single-value input) — `ComboDialog.cpp/.rc` (`IDD_COMBO 98`)

Caption "Combo" in the .rc, replaced by `Title` at `OnInit`; 240 × 64 du, `MY_MODAL_RESIZE_DIALOG_STYLE` (`OnSize` keeps OK/Cancel bottom-right and stretches the combo, `ComboDialog.cpp:42-58`).

| Control | ID | Type | Behaviour |
|---|---|---|---|
| Static | `IDT_COMBO 100` | LTEXT, text = `Static` member | |
| Combo | `IDC_COMBO 101` | `MY_COMBO_WITH_EDIT`, edit text = `Value`, list = `Strings` (`:35-37`); the `Sorted` member is unused (commented out) | `OnOK` reads the edit text into `Value` (`:60-64`) |
| OK / Cancel | `OK_CANCEL` | | |

Used by (`grep CComboDialog`): `PanelSelect.cpp` (Select/Deselect by mask), `PanelOperations.cpp` (Create Folder / Create File / Comment), `BrowseDialog.cpp` `Dlg_CreateFolder` (`:1121-1132`, `Value` pre-set to `IDS_CREATE_FOLDER_DEFAULT_NAME` "New Folder").

### 4.5 Copy / Move destination — `CopyDialog.cpp/.rc` (`IDD_COPY 96`)

Caption "Copy" in the .rc, replaced by `Title`; 320 × 144 du, resizable (`OnSize` `CopyDialog.cpp:38-71` stretches the combo and info text). `NormalizeSize(true)`.

| Control | ID | Type | Behaviour |
|---|---|---|---|
| Label | `IDT_COPY 100` | LTEXT, text = `Static` (`IDS_COPY_TO 6002` "Copy to:" / `IDS_MOVE_TO 6003` "Move to:" / `IDS_COMBINE_TO 7401` "&Combine to:") | |
| Path | `IDC_COPY 101` | `MY_COMBO_WITH_EDIT`, list = `Strings` (CopyHistory), text = `Value` (`:30-32`) | `OnOK` → `Value` (`:99-103`) |
| Browse | `IDB_COPY_SET_PATH 102` | PUSHBUTTON `"..."` (`bxsDots` wide, `WS_GROUP`) | `MyBrowseForFolder(LangString(IDS_SET_FOLDER 6007), current text)` (`:84-97`); `IDS_SET_FOLDER` has no STRINGTABLE entry in any `.rc` (only `CopyDialogRes.h:8`), so the title is empty unless the lang file provides it; result is normalized to a dir prefix and set as the text |
| Info | `IDT_COPY_INFO 103` | LTEXT `SS_NOPREFIX \| SS_LEFTNOWORDWRAP`, text = `Info` | `kCopyDialog_NumInfoLines = 11` (`CopyDialog.h:11`); `App.cpp:532` lists at most `11 - 6 = 5` item names before the summary |
| OK / Cancel | `OK_CANCEL` | | |

### 4.6 Text viewer — `EditDialog.cpp/.rc` (`IDD_EDIT_DLG 94`)

Caption "Edit" in the .rc, replaced by `Title`; 320 × 240 du, resizable (`OnSize` `EditDialog.cpp:28-57`). Single read-only multiline `EDITTEXT IDE_EDIT 100` (`ES_MULTILINE | ES_READONLY | WS_VSCROLL | WS_HSCROLL | ES_WANTRETURN`) + `MY_BUTTON__CLOSE` (`IDCLOSE` "&Close", DEFPUSHBUTTON). Members `Title`, `Text`. Only caller: `CListViewDialog` (`ListViewDialog.cpp:207`, Enter on a row: 1 column → `Text` = the row; 2 columns → `Title` = name, `Text` = value).

### 4.7 Options › Editor page — `EditPage.cpp/.rc` + `EditPage2.rc` (`IDD_EDIT 2103`, caption "Editor")

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Viewer label | `IDT_EDIT_VIEWER 543` | LTEXT "&View:" (localized via `LangSetDlgItems_Colon`) | |
| Viewer path | `IDE_EDIT_VIEWER 100` | EDITTEXT `ES_AUTOHSCROLL` | `ReadRegEditor(false)` / `SaveRegEditor(false)` (registry `Viewer`, §5.2) |
| Viewer browse | `IDB_EDIT_VIEWER 101` | PUSHBUTTON `"..."` | `Edit_BrowseForFile` (`EditPage.cpp:88-125`): `SplitCmdLineSmart` extracts the program from the current text, `CBrowseInfo::BrowseForFile` with the single filter `*.exe`; the chosen path replaces the whole text (parameters are dropped) |
| Editor label/path/browse | `IDT_EDIT_EDITOR 2104` "&Editor:", `IDE_EDIT_EDITOR 102`, `IDB_EDIT_EDITOR 103` | | `ReadRegEditor(true)` / `SaveRegEditor(true)` (registry `Editor`) |
| Diff label/path/browse | `IDT_EDIT_DIFF 2105` "&Diff:", `IDE_EDIT_DIFF 104`, `IDB_EDIT_DIFF 105` | | `ReadRegDiff` / `SaveRegDiff` (registry `Diff`) |

`EN_CHANGE` (outside `_initMode`) marks the row `WasChanged` and calls `Changed()` (`:142-158`); `OnApply` (`:61-79`) saves only changed rows; `OnNotifyHelp` → `"FM/options.htm#editor"`. Empty viewer/editor → `StartEditApplication` (`PanelItemOpen.cpp:719-735`) falls back to `<WindowsDir>\notepad.exe`. Values may contain arguments: `SplitCmdLineSmart` (`PanelItemOpen.cpp:675`) splits program and parameters, the file path is appended as a quoted parameter (`StartAppWithParams`).

### 4.8 Options › Folders page — `FoldersPage.cpp/.rc` (`IDD_FOLDERS 2400`, "Folders")

Working (temporary) folder for archive updates (`NWorkDir::CInfo`, `7zip/UI/Common/ZipRegistry.h`):

| Control | ID | Type / text | Default | Behaviour |
|---|---|---|---|---|
| Label | `IDT_FOLDERS_WORKING_FOLDER 2401` | LTEXT "&Working folder" (a GROUPBOX in older versions, now commented out in `FoldersPage2.rc`) | | |
| Radio | `IDR_FOLDERS_WORK_SYSTEM 2402` | `MY_CONTROL_AUTORADIOBUTTON_GROUP` "&System temp folder" | **checked** (`NWorkDir::NMode::kSystem = 0`, `CInfo::SetDefault` `ZipRegistry.h:178`) | |
| Radio | `IDR_FOLDERS_WORK_CURRENT 2403` | "&Current" (= folder of the archive) | | `kCurrent = 1` |
| Radio | `IDR_FOLDERS_WORK_SPECIFIED 2404` | "Specified:" | | `kSpecified = 2`; `MyEnableControls` (`FoldersPage.cpp:71-76`) enables the edit + browse only in this mode |
| Path | `IDE_FOLDERS_WORK_PATH 100` | EDITTEXT `ES_AUTOHSCROLL` | empty | `WorkDirPath`; `EN_CHANGE` → `ModifiedEvent` |
| Browse | `IDB_FOLDERS_WORK_PATH 101` | PUSHBUTTON `"..."` | | `MyBrowseForFolder(IDS_FOLDERS_SET_WORK_PATH_TITLE 2406 "Specify a location for temporary archive files.")` (`:148-156`) |
| Checkbox | `IDX_FOLDERS_WORK_FOR_REMOVABLE 2405` | `MY_CONTROL_CHECKBOX` "Use for removable drives only" | **checked** (`SetForRemovableOnlyDefault` → `true`) | |

`OnInit` loads `NWorkDir::CInfo` (`m_WorkDirInfo.Load()`); any change sets `_needSave` and `Changed()`; `OnApply` (`:158-167`) → `GetWorkDir` + `NWorkDir::CInfo::Save()` (§5.5) only when `_needSave`. Help topic `"fm/options.htm#folders"`. `Load()` (`ZipRegistry.cpp:509-530`) falls back to `kSystem` when `WorkDirPath` is missing/empty and the mode was `kSpecified`. Used by `GetWorkDir()` (`7zip/UI/Common/WorkDir.cpp`) when creating `CWorkDirTempFile` for archive updates (§6.7).

### 4.9 Options › Language page — `LangPage.cpp/.rc` (`IDD_LANG 2101`, "Language")

| Control | ID | Type | Behaviour |
|---|---|---|---|
| Label | `IDT_LANG_LANG 2102` | LTEXT "Language:" | |
| Combo | `IDC_LANG_LANG 100` | `MY_COMBO` (160 du wide, not sorted) | first entry = built-in English (`Name = "-"`, `LangPage.cpp:88-99`), then every `*.txt` in `GetLangDirPrefix()` (`:104-118`; files that fail `LangOpen` are reported in one "Error in Lang file" MessageBox `:262-263`), displayed as `<IDS_LANG_ENGLISH (id 1)> : <IDS_LANG_NATIVE (id 2)>` (`NativeLangString` `:49-53`, fallback = file short name); files matching the user default language (`Lang_GetShortNames_for_DefaultLang`, `LangUtils.cpp:242-275`: `GetSystemDefaultLangID`/`GetUserDefaultLangID`) get a `***` (exact sub-language) or `+++` (same primary language, incl. `xx-yy` prefix match) mark (`:127-158`); current selection = entry whose short name equals `g_LangID` (registry `Lang`) |
| Info | `IDT_LANG_INFO 101` | LTEXT `SS_NOPREFIX` multiline | `ShowLangInfo` (`:334-358`) for the selected entry: `<name> : <numLines> / <NumLangLines_EN> = NN%` (`NumLangLines_EN` = line count of `Lang\en.ttt` if present, else `k_NumLangLines_EN = 443` `:19`), the file's comment lines (`CLang::Comments`), then "Missing lines" / "Extra lines" ID lists relative to `en.ttt` (`:176-240`) |

`CBN_SELCHANGE` → `_needSave`, `Changed()`, `ShowLangInfo()` (`:288-297`). `OnApply` (`:267-280`) → `SaveRegLang(name)` when `_needSave`, then `ReloadLang()` and sets the global `LangWasChanged = true`; the Options dialog then reloads the menu and toolbars (`OptionsDialog.cpp` → `MyLoadMenu`, `ReloadToolbars`, `ReloadLangItems` `App.cpp:68`). Help topic `"fm/options.htm#language"`.

### 4.10 Link — `LinkDialog.cpp/.rc` (`IDD_LINK 7700`, "Link"; not built under CE)

Invoked by File → Link... (`CApp::Link()`, `LinkDialog.cpp:352-402`): requires an FS folder (`MessageBox_Error_UnsupportOperation` otherwise) and exactly one operated item (`IDS_SELECT_ONE_FILE`). Inputs: `CurDirPrefix` = panel FS path, `FilePath` = `<panel path><item prefix><item name>`, `AnotherPath` = the other panel's FS path (or the same panel in single-panel mode). 288 × 214 du, resizable. After `IDOK` the source panel is refreshed only if the `kpidNtReparse` ("Link") column is visible, plus `RefreshTitleAlways()`.

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Label | `IDT_LINK_PATH_FROM 7702` | LTEXT "Link from:" | |
| From path | `IDC_LINK_PATH_FROM 100` | `MY_COMBO_WITH_EDIT` | the link to create. `OnInit` (`:87-179`): if `FilePath` is an existing reparse point → `FilePath`; otherwise → `AnotherPath` (the other panel's folder) |
| Browse from | `IDB_LINK_PATH_FROM 103` | PUSHBUTTON `"..."` (`WS_GROUP`) | `OnButton_SetPath(false)` (`:232-248`): `MyBrowseForFolder(LangString(IDS_SET_FOLDER))`, result normalized to a dir prefix |
| Label | `IDT_LINK_PATH_TO 7703` | LTEXT "Link to:" | |
| To path | `IDC_LINK_PATH_TO 101` | `MY_COMBO_WITH_EDIT` | the target: existing reparse point → its decoded target (`CReparseAttr::GetPath`); otherwise `FilePath` |
| Browse to | `IDB_LINK_PATH_TO 104` | PUSHBUTTON `"..."` | `OnButton_SetPath(true)` (folder browser) |
| Current target | `IDT_LINK_PATH_TO_CUR 102` | LTEXT | for an existing reparse point: `<target>` (+ ` : <PrintName>` when the name pair differs; `ERROR: … : <message>` prefix when `GetReparseData` fails, `:105-136`) |
| Group | `IDG_LINK_TYPE 7710` | GROUPBOX "Link Type" | |
| Radio | `IDR_LINK_TYPE_HARD 7711` | "Hard Link" (`WS_GROUP`) | default for a plain existing file (`:171`); `OnButton_Link` → `NDir::MyCreateHardLink(from, to)` (`:299-305`) |
| Radio | `IDR_LINK_TYPE_SYM_FILE 7712` | "File Symbolic Link" | default when `FilePath` does not exist (`:102`) or the item is a Win32 file symlink |
| Radio | `IDR_LINK_TYPE_SYM_DIR 7713` | "Directory Symbolic Link" | default for a plain folder when `g_SymLink_Supported` (`:164-169`) or an existing dir symlink |
| Radio | `IDR_LINK_TYPE_JUNCTION 7714` | "Directory Junction" | default for a folder when symlinks are unsupported, or an existing mount point (`IsMountPoint`) |
| Radio | `IDR_LINK_TYPE_WSL 7715` | "WSL" | existing `IsSymLink_WSL` reparse point |
| Link | `IDB_LINK_LINK 7701` | DEFPUSHBUTTON "Link" | `OnButton_Link` (`:262-350`): relative `from` gets `CurDirPrefix`; for non-WSL types both existing paths must match the dir/file kind of the chosen type ("Incorrect link type"); hard link → `MyCreateHardLink`; other types: refuse if `from` is an existing non-empty regular file ("WARNING: reparse point will hide the data of existing file"), `FillLinkData(to, isSymLink = type != junction, isWSL)` builds the reparse buffer ("Incorrect link" if empty, "Internal conversion error" if it does not parse back), empty `to` → `NIO::DeleteReparseData(from)`, else `NIO::SetReparseData(from, isDirLink, data)`; errors → `MessageBoxW(MyFormatMessage(GetLastError()), "7-Zip", MB_ICONERROR)`; success → `End(IDOK)` |
| Cancel | `IDCANCEL` | PUSHBUTTON | |

`kLangIDs` localizes the two labels, the group and the five radio buttons.

### 4.11 List view (generic 1- or 2-column list) — `ListViewDialog.cpp/.rc` (`IDD_LISTVIEW 99`, resizable)

Caption "ListView" in the .rc, replaced by `Title`; 480 × 320 du.

| Control | ID | Type | Behaviour |
|---|---|---|---|
| List | `IDL_LISTVIEW 100` | `SysListView32` `LVS_REPORT \| LVS_SHOWSELALWAYS \| LVS_AUTOARRANGE \| LVS_NOCOLUMNHEADER`; `OnInit` (`ListViewDialog.cpp:34-131`) removes `LVS_NOCOLUMNHEADER` when `NumColumns > 1`, adds `LVS_EX_FULLROWSELECT` (+ `LVS_EX_ONECLICKACTIVATE\|LVS_EX_TRACKSELECT` when FM `SingleClick`); columns `Strings` / `Values`, auto-sized | `SelectFirst` → first row focused+selected |
| OK / Cancel | `OK_CANCEL` | | `OnOK` (`:317-321`) stores `FocusedItemIndex` (used by Folders History) |

Members: `Title`, `Strings`, `Values`, `NumColumns` (1 or 2), `SelectFirst`, `DeleteIsAllowed`, `StringsWereChanged`, `FocusedItemIndex`.
Keys (`OnNotify` `:258-315`): Del → `DeleteItems` (only when `DeleteIsAllowed`; removes the selected rows from `Strings` and sets `StringsWereChanged`); Ctrl+A → `SelectAll`; Ctrl+C / Ctrl+Ins → `CopyToClipboard` (`:164-195`): selected rows as `<string>` or `<string>: <value>` (2 columns), each followed by `\r\n`; Enter / double-click (`LVN_ITEMACTIVATE`, `OnEnter` `:247-256`) → `OnOK` for 1-column lists, or `ShowItemInfo` (`:198-215`: `CEditDialog`) when Alt is held or `NumColumns > 1`. Callers: `PanelMenu.cpp:183` (Properties / archive info), `PanelFolderChange.cpp:868` (Folders History), `GUI/HashGUI.cpp:312` (hash results).

### 4.12 Memory usage request — `MemDialog.cpp/.rc` (`IDD_MEM 7800`, caption "Memory usage request" `IDS_MEM_REQUIRES_BIG_MEM`)

Shown by `CExtractCallbackImp::RequestMemoryUse` (`ExtractCallback.cpp:1012-1120`, `IArchiveRequestMemoryUseCallback`) when a decoder needs more memory than the allowed limit. The callback first raises the allowed size to the registry `MemLimit` (`NExtract::Read_LimitGB()`, §5.4) when set and larger than the engine's forced limit; if `requiredSize` fits, it answers `k_Allow` silently. Otherwise (and unless `g_DisableUserQuestions`, or `k_IsReport` mode which only reports) the dialog is created over the progress dialog; a remembered answer (`_remember`/`_skipArc`) skips the dialog. 320 × 200 du, `MY_MODAL_DIALOG_STYLE`.

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Message | `IDT_MEM_MESSAGE 101` | LTEXT `SS_NOPREFIX`, 72 du high | `MemDialog.cpp:82-127`: optional `IDS_MEM_ERROR` "The system cannot allocate the required amount of memory" (when RAM < required) + `IDS_MEM_REQUIRES_BIG_MEM` "The operation requires big amount of memory (RAM)." + `    <N> GB : <IDS_MEM_REQUIRED_MEM_SIZE>` + `    <M> GB : <IDS_MEM_CURRENT_MEM_LIMIT>` (+ `IDS_MEM_RAM_SIZE` line when not allowed) + `File: <path>` + `<Testing\|Extracting>: <ArcPath>` (multi-archive mode) |
| Checkbox | `IDX_MEM_SAVE_LIMIT 7801` | `MY_CHECKBOX` "Change allowed limit for next operations", unchecked | toggles the spin edit (`EnableSpin`, `:178-187`); when checked at Continue the value is validated (`ConvertStringToUInt32`, ≤ 2^30, else `E_INVALIDARG` error box) and returned in `Limit_GB` / `NeedSave` → caller writes `NExtract::Save_LimitGB` (`ExtractCallback.cpp:1075-1076`) |
| Spin edit | `IDE_MEM_SPIN_EDIT 110` + `IDC_MEM_SPIN 111` (`MY_CONTROL_EDIT_WITH_SPIN`), unit label `IDT_MEM_GB 112` | `ES_NUMBER` edit + up-down | range `1 .. valMax` where `valMax = 64` without RAM info, else `min(RAM_GB − 1, 16384)` (`:128-142`); initial value = `Required_GB` (`:143-150`); disabled until the checkbox is ticked; label text `GB` or `GB / <RAM> GB (RAM)` |
| Group | `IDG_MEM_ACTION 7803` | GROUPBOX "Action" | |
| Radio | `IDR_MEM_ACTION_ALLOW 7820` | "&Allow archive unpacking" | default when RAM > required (`is_Allowed`, `:99`, `:155-163`) |
| Radio | `IDR_MEM_ACTION_SKIP_ARC 7821` | "&Skip archive unpacking" | default otherwise; result `SkipArc` → caller answers `k_SkipArc` (`ExtractCallback.cpp:1085-1093`) |
| Checkbox | `IDX_MEM_REMEMBER 7802` | `MY_CHECKBOX` "&Repeat selected action for current operation" | hidden unless `ShowRemember` (multi-archive mode, an item index or a path is known, `:172-173`); result `Remember` → callback stores `_remember`/`_skipArc` for the rest of the operation |
| Continue / Cancel | `CONTINUE_CANCEL` (`IDCONTINUE` DEFPUSHBUTTON, `IDCANCEL`) | | `OnContinue` (`:189-218`) reads the controls and ends with `IDCONTINUE`; anything else → caller answers `k_Stop` and returns `E_ABORT` |

Members (`MemDialog.h`): `Limit_GB`, `Required_GB` (in/out), `TestMode`, `ArcPath`, `FilePath`, `ShowRemember`, `Remember`, `NeedSave`, `SkipArc`. `kLangIDs` localizes the two checkboxes, the group and the radios.

### 4.13 Options › 7-Zip (shell integration) page — `MenuPage.cpp/.rc` (`IDD_MENU 2300`, "7-Zip")

| Control | ID | Type / text | Default | Behaviour |
|---|---|---|---|---|
| Checkbox | `IDX_SYSTEM_INTEGRATE_TO_MENU 2301` | "Integrate 7-Zip to shell context menu" | checked if `7-zip.dll` (next to the exe, `GetModuleDirPrefix`) is registered (`CheckContextMenuHandler`, `RegistryContextMenu.cpp`); disabled if the DLL file is missing (`MenuPage.cpp:131-185`) | `OnApply` (`:299-318`) → `SetContextMenuHandler(newVal, path, wow)`, errors shown as MessageBox; hidden under CE |
| Checkbox | `IDX_SYSTEM_INTEGRATE_TO_MENU_2 2310` | text = first checkbox's text + ` (32-bit)` on x64 builds / ` (64-bit)` on 32-bit builds (`IDS_PROP_BIT64` with `64`→`32` replace, `:111-130`) | same check for `7-zip32.dll` (x64 build, `KEY_WOW64_32KEY`) / `7-zip64.dll` (32-bit build on WOW64, `KEY_WOW64_64KEY`); hidden on 32-bit Windows (`!g_Is_Wow64`) | same |
| Checkbox | `IDX_SYSTEM_CASCADED_MENU 2302` | "Cascaded context menu" | **true** (`CContextMenuInfo::Load` `ZipRegistry.cpp:564`) | `Cascaded` (`CBoolPair`; `.Def` is set only when the user changed it) |
| Checkbox | `IDX_SYSTEM_ICON_IN_MENU 2304` | "Icons in context menu" | false (`:567`) | `MenuIcons` |
| Checkbox | `IDX_EXTRACT_ELIM_DUP 3430` (shared with Extract dialog) | "Eliminate duplication of root folder" | **true** (`:570`) | `ElimDup` (registry `ElimDupExtract` under `Options`) |
| Label + combo | `IDT_SYSTEM_ZONE 3440`, `IDC_SYSTEM_ZONE 101` | LTEXT "Propagate Zone.Id stream:" + `MY_COMBO` (100 du wide) with entries `* No` (lang id 406 `MY_IDNO`, value 0), `Yes` (lang id 407 `MY_IDYES`, 1), `For Office files` (`IDT_ZONE_FOR_OFFICE 3441`, 2) and, when the stored value is ≥ 3, the raw number (`:196-228`) | `WriteZone = -1` (not set) → shown as `* No` | `OnApply`: index ≤ 0 is stored as `-1`, else the value (`:337-342`); registry `WriteZoneIdExtract` |
| Label + list | `IDT_SYSTEM_CONTEXT_MENU_ITEMS 2303`, `IDL_SYSTEM_OPTIONS 100` | LTEXT "Context menu items:" + `SysListView32` report, `LVS_SINGLESEL\|LVS_NOCOLUMNHEADER`, `LVS_EX_CHECKBOXES\|LVS_EX_FULLROWSELECT`; rows from `kMenuItems[]` (`:49-71`, strings from `Explorer/resource2.rc`): `Open archive` (`kOpen 1<<5`), `Open archive >` (`kOpenAs 1<<6`), `Extract files...` (`kExtract 1<<0`), `Extract Here` (`kExtractHere 1<<1`), `Extract to <Folder>` (`kExtractTo 1<<2`), `Test archive` (`kTest 1<<4`), `Add to archive...` (`kCompress 1<<8`), `Add to <Archive>.7z` (`kCompressTo7z 1<<9`), `Add to <Archive>.zip` (`kCompressToZip 1<<12`), `Compress and email...` (`kCompressEmail 1<<10`), `Compress to <Archive>.7z and email` (`kCompressTo7zEmail 1<<11`), `Compress to <Archive>.zip and email` (`kCompressToZipEmail 1<<13`), `CRC SHA >` (`kCRC 1<<31`), `7-Zip > CRC SHA >` (`kCRC_Cascaded 1<<30`) | all checked: `Flags = (UInt32)-1` when the `ContextMenu` value is absent (`:577`) | bitmask saved to `ContextMenu` only when changed (`Flags_Def`) |

Any checkbox/list change sets the matching `_*_Changed` flag and `Changed()` (`:370-436`); `OnApply` (`:299-358`) writes shell registration first, then `CContextMenuInfo::Save()` (§5.5) if any of the five flags changed. Help topic `"fm/options.htm#sevenZip"`.

### 4.14 Messages — `MessagesDialog.cpp/.rc` (`IDD_MESSAGES 6602`, caption "7-Zip: Diagnostic messages", resizable)

440 × 160 du. List `IDL_MESSAGE 100` (`SysListView32` report, `LVS_SHOWSELALWAYS|LVS_NOSORTHEADER`) with an unnamed 30-du index column and `Message` (`IDS_MESSAGE 6603`, 600 du); button `IDOK` "&Close" (DEFPUSHBUTTON, text re-set from `IDS_CLOSE` at init, `MessagesDialog.cpp:35`). Fed with `Messages` (`const UStringVector *`); `AddMessage` splits a message at `\n` into several rows (`:17-28`). Only caller: `PanelDrag.cpp:1788` (messages collected during a drag-and-drop copy). The progress dialog uses its own embedded list of the same shape (`CProgressDialog::UpdateMessagesDialog`, `ProgressDialog2.cpp:1202`, §4.17).

### 4.15 Overwrite confirmation — `OverwriteDialog.cpp/.rc` (`IDD_OVERWRITE 3500`, "Confirm File Replace")

340 × 200 du, `MY_MODAL_DIALOG_STYLE`; icons are 24 × 24 (`iconSize`); the "Auto Rename" button is 104 du wide (`bSizeBig`). Buttons are laid out in two rows (`by2`: Yes / Yes to All / Auto Rename; `by1`: No / No to All / Cancel). No DEFPUSHBUTTON in the .rc.

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Header | `IDT_OVERWRITE_HEADER 3501` | LTEXT "Destination folder already contains processed file." | localized (`kLangIDs`) |
| Question | `IDT_OVERWRITE_QUESTION_BEGIN 3502` | LTEXT "Would you like to replace the existing file" | |
| Old icons + text | `IDI_OVERWRITE_OLD_FILE 100`, `IDI_OVERWRITE_OLD_FILE_2 101` (two stacked ICON statics), `IDT_OVERWRITE_OLD_FILE_SIZE_TIME 102` (LTEXT `SS_NOPREFIX`, 50 du high) | `SetFileInfoControl` (`OverwriteDialog.cpp:90-118`): path (quoted and shortened when > `kCurrentFileNameSizeLimit = 72` chars, `ReduceString :36-47`), size line `IDS_FILE_SIZE 3504 "{0} bytes"` (+ ` (N K/M/G)` approximation for ≥ 1024, `AddSizeValue :68-88`) if `Size_IsDefined`, `IDS_PROP_MTIME` + `ConvertUtcFileTimeToString` if `Time_IsDefined`; icons via `SHGetFileInfo` (`:120-230`): the file's real icon for `Is_FileSystemFile`, the extension's icon otherwise; the second icon is set only when its index differs from the first (`:216-224`) | `OldFileInfo` (`CFileInfo {Path, Size, Time, Size_IsDefined, Time_IsDefined, Is_FileSystemFile}`, `OverwriteDialog.h:13-40`) |
| "with this one?" | `IDT_OVERWRITE_QUESTION_END 3503` | LTEXT | |
| New icons + text | `IDI_OVERWRITE_NEW_FILE 110`, `IDI_OVERWRITE_NEW_FILE_2 111`, `IDT_OVERWRITE_NEW_FILE_SIZE_TIME 112` | same | `NewFileInfo` |
| Yes | `IDYES` | PUSHBUTTON "&Yes" | `End(IDYES)` (`:275-288`) |
| Yes to All | `IDB_YES_TO_ALL 440` | PUSHBUTTON "Yes to &All" | `End(IDB_YES_TO_ALL)`; hidden when `!ShowExtraButtons` (`:248-253`) |
| Auto Rename | `IDB_AUTO_RENAME 3505` | PUSHBUTTON "A&uto Rename" | `End(IDB_AUTO_RENAME)`; hidden when `!ShowExtraButtons` |
| No | `IDNO` | PUSHBUTTON "&No" | `End(IDNO)` |
| No to All | `IDB_NO_TO_ALL 441` | PUSHBUTTON "No to A&ll" | `End(IDB_NO_TO_ALL)`; hidden when `!ShowExtraButtons` |
| Cancel | `IDCANCEL` | PUSHBUTTON "&Cancel" | `IDCANCEL` |

`DefaultButton_is_NO` → `DM_SETDEFID IDNO` + focus on No (`:255-261`). `OnDestroy` releases the four icons. Mapped by `CExtractCallbackImp::AskOverwrite` (§8.4) and by the FM copy/move code.

### 4.16 Password — `PasswordDialog.cpp/.rc` (`IDD_PASSWORD 3800`, "Enter password")

200 × 72 du (140 wide under CE), `MY_MODAL_DIALOG_STYLE`; caption localized via `LangSetWindowText(IDD_PASSWORD)`.

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Label | `IDT_PASSWORD_ENTER 3801` | LTEXT "&Enter password:" | localized (`kLangIDs`) |
| Password | `IDE_PASSWORD_PASSWORD 120` | EDITTEXT `ES_PASSWORD \| ES_AUTOHSCROLL` | `Password` member (in/out; pre-filled at init via `SetTextSpec` `PasswordDialog.cpp:25-29`) |
| Show | `IDX_PASSWORD_SHOW 3803` | `MY_CHECKBOX` "&Show password" | click → `ReadControls` + `SetTextSpec`: `SetPasswordChar(ShowPassword ? 0 : '*')` and re-sets the text (`:43-52`); initial state = `ShowPassword` member |
| OK / Cancel | `OK_CANCEL` | | `OnOK` (`:54-58`) → `ReadControls` (`Password`, `ShowPassword`); Cancel → caller returns `E_ABORT` |

Callers: `CExtractCallbackImp::CryptoGetTextPassword` (`ExtractCallback.cpp:684-704`) and `COpenArchiveCallback` (`OpenCallback.cpp:66-84`) — both set `ShowPassword = NExtract::Read_ShowPassword()`, wait for the progress dialog (`WaitCreating`) and use it as parent, cache `Password`/`PasswordIsDefined` for the rest of the operation and call `NExtract::Save_ShowPassword` only when the checkbox state changed; `CUpdateCallbackGUI2::ShowAskPasswordDialog` (`GUI/UpdateCallbackGUI2.cpp:52-61`) does not read/save `ShowPassword`. In the FM the password is remembered per panel folder chain (`CFolderLink::UsePassword/Password`) so nested archives/re-opens don't ask again.

### 4.17 Progress — `ProgressDialog2.cpp/.rc` (`IDD_PROGRESS 97`, resizable) and the SFX-only `ProgressDialog.cpp` (`IDD_PROGRESS` in the SFX build: label + progress bar + Cancel, 100 ms timer)

Layout (`ProgressDialog2.rc` defines `IDD_PROGRESS`/`IDD_PROGRESS_2` and the string table; the dialog body is in `ProgressDialog2a.rc`, included twice): caption "Progress", `MY_MODAL_RESIZE_DIALOG_STYLE`, 360 du wide (`BIG_DIALOG_SIZE(360, 192)` → `_2` template on small screens), buttons 80 du wide (`bxs` redefined); label column 90 du (`MY_PROGRESS_LABEL_UNITS_START`), value column 72 du (`MY_PROGRESS_VAL_UNITS`, 44 under CE), rows `k = 11` du apart. All value fields are right-aligned `RTEXT` with `MY_TEXT_NOPREFIX`.

| Control | ID | Type / text |
|---|---|---|
| Elapsed | `IDT_PROGRESS_ELAPSED 3900` "Elapsed time:" / `IDT_PROGRESS_ELAPSED_VAL 120` | `GetTimeString` (`ProgressDialog2.cpp:602`) `hh:mm:ss` |
| Remaining | `IDT_PROGRESS_REMAINING 3901` "Remaining time:" / `IDT_PROGRESS_REMAINING_VAL 121` | `elapsed × (total − done) / done` (`MyMultAndDiv`, `:795-800`) |
| Files | `IDT_PROGRESS_FILES 1032` (= `IDS_PROP_FILES` "Files") / `IDT_PROGRESS_FILES_VAL 111` (current) and `IDT_PROGRESS_FILES_TOTAL 112` (` / total`, next row, `:855-866`) | |
| Errors | `IDT_PROGRESS_ERRORS 3906` "Errors:" / `IDT_PROGRESS_ERRORS_VAL 126` | count of messages; label+value shown by `EnableErrorsControls` (`:332`) |
| Total size | `IDT_PROGRESS_TOTAL 3902` "Total size:" / `IDT_PROGRESS_TOTAL_VAL 122` | right column |
| Speed | `IDT_PROGRESS_SPEED 3903` "Speed:" / `IDT_PROGRESS_SPEED_VAL 123` | `<N> B/s`, `<N> KB/s` (≥ 10000 B/s), `<N> MB/s` (≥ 10000 KB/s) (`:806-826`) |
| Processed | `IDT_PROGRESS_PROCESSED 3904` "Processed:" / `IDT_PROGRESS_PROCESSED_VAL 124` | |
| Compressed size | `IDT_PROGRESS_PACKED 1008` (= `IDS_PROP_PACKED_SIZE`, .rc text "Compressed size:") / `IDT_PROGRESS_PACKED_VAL 110` | hidden with Ratio when `!ShowCompressionInfo` (`:408`) |
| Ratio | `IDT_PROGRESS_RATIO 3905` "Compression ratio:" / `IDT_PROGRESS_RATIO_VAL 125` | `out / in %` from `Set_Ratio` (`:176`) |
| Status | `IDT_PROGRESS_STATUS 103` | LTEXT, full width: e.g. `Compressing`, `Extracting`, `Scanning`, `Testing`, `Add`, `Update`, `Repack`, `Moving` … (`Set_Status` `:191`) |
| File name | `IDT_PROGRESS_FILE_NAME 102` | `Static` `SS_NOPREFIX \| SS_LEFTNOWORDWRAP`, 24 du high: current path as two lines (folder / name), each cut with `ReduceString(s, _numReduceSymbols)` (`:324`, `:907-928`) |
| Progress bar | `IDC_PROGRESS1 100` | `msctls_progress32` `PBS_SMOOTH \| WS_BORDER`, 16 du; `SetProgressRange` (`:574`) scales the 64-bit range down to fit, `SetProgressPos` (`:584`) also updates the taskbar |
| Messages list | `IDL_PROGRESS_MESSAGES 101` | `SysListView32` report, `LVS_NOCOLUMNHEADER \| LVS_NOSORTHEADER`, 48 du: numbered error/warning rows; shown by `EnableErrorsControls` once the first message arrives |
| Background | `IDB_PROGRESS_BACKGROUND 444` DEFPUSHBUTTON "&Background" ↔ `IDS_PROGRESS_FOREGROUND 445` "&Foreground" | `OnPriorityButton` (`:1150`): `SetPriorityClass(IDLE_PRIORITY_CLASS / NORMAL_PRIORITY_CLASS)` for the whole process; title gets a `Background` suffix |
| Pause | `IDB_PAUSE 446` "&Pause" ↔ `IDS_CONTINUE 411` "&Continue" | `OnPauseButton` (`:1130`): `Sync.Set_Paused(!paused)`; workers block in `CProgressSync::CheckStop` (`:100`, `Sleep(kPauseSleepTime = 100 ms)` loop while paused); title gets `IDS_PROGRESS_PAUSED 447` "Paused" |
| Cancel / Close | `IDCANCEL` "Cancel" → text `IDS_CLOSE 408` "&Close" after completion | `OnButtonClicked` (`:1234-1294`): while running: auto-pause, `MessageBoxW(IDS_PROGRESS_ASK_CANCEL 448 "Are you sure you want to cancel?", title, MB_YESNOCANCEL)`, Yes → `_cancelWasPressed`, `OnCancel` → `Sync.Set_Stopped(true)` (`:571`) so workers get `E_ABORT` from `CheckStop`; No → resume. After completion (`_waitCloseByCancelButton`): `End(IDCLOSE)` |

Behaviour (`CProgressDialog`):
* Created by `CProgressThreadVirt::Create(title, parent)` (`:1412-1420`) which spawns the worker thread (`CProgressThreadVirt::Process` `:1432-1470` calls `ProcessVirt()`, catches exceptions → `FinalMessage.ErrorMessage.Message`, appends up to 32 `ErrorPaths`) then `CProgressDialog::Create(title, thread, parent)` (`:960-990`): in `WaitMode` it first waits `kCreateDelay = 500 ms` (2500 under CE) for the thread — if it finished without messages no dialog appears; then the modal dialog runs until the worker finishes. If the dialog could not be created, "Progress Error" is shown after the thread ends.
* Timer `kTimerElapse = 200 ms` (500 under CE) (`:33-39`, `:422`): `OnTimer` (`:935`) → `UpdateStatInfo` (`:695`) copies from `CProgressSync` (critical-section-protected: `_stopped`, `_paused`, `_bytesProgressMode`, `_totalBytes`, `_completedBytes`, `_totalFiles`, `_curFiles`, `_inSize/_outSize`, `_titleFileName`, `_status`, `_filePath`, `_isDir`, `Messages`, `FinalMessage`) and refreshes only the fields whose value changed.
* Title (`SetTitleText` `:1084-1127`): `"<Paused> <NN%> <Title> <Background> <fileName>"` (`fileName` = `_titleFileName` cut to `kTitleFileNameSizeLimit`); percent is mirrored into the taskbar button via `ITaskbarList3` (`SetTaskbarProgressState` `:306`, `TBPF_PAUSED` while paused, `TBPF_NOPROGRESS` on close).
* When the worker finishes (`ProcessWasFinished` `:1305` posts `kCloseMessage = WM_APP + 1`; `OnExternalCloseMessage` `:991-1035`): Cancel text → Close, Pause/Background hidden; error message → `MessageBoxW(MB_ICONERROR)` with `FinalMessage.ErrorMessage.Message` (title default "7-Zip"); no messages → optional `OkMessage` info box and the dialog closes itself; otherwise it stays open showing the messages (`MessagesDisplayed`). If the close message arrives while the cancel question is open, it is handled after the question (`_externalCloseMessageWasReceived`). `CheckNeedClose` `:1296`.
* Messages list: `AddMessage` (`:1173`) splits multi-line text, `AddMessageDirect` (`:1159`) numbers rows; `AddError_Message_Name` (`:228`) formats `"<msg> : <name>"`, `AddError_Code_Name` (`:244`) uses `HResultToMessage` (`:1477`: Win32 error text or `"Error #x"`); Ctrl+A / Ctrl+C / Ctrl+Ins in the list → `CopyToClipboard` (`:1369`); `UpdateMessagesDialog` (`:1202`) moves new `Sync.Messages` into the list on each timer tick and auto-sizes the columns.
* `CProgressCloser` / `CDisableTimerProcessing` wrappers; `Result` of `ProcessVirt` becomes `FinalMessage` unless it is `S_OK` or `E_ABORT` (silent cancel).
* SFX build (`ProgressDialog.cpp/.rc`, `IDD_PROGRESS`): 172 × 44 du, only `IDC_PROGRESS1` progress bar + `IDCANCEL` "Cancel"; `kTimerElapse = 100 ms` (`:16`); Cancel asks the same question and calls `Sync.SetStopped(true)` (`:76`).

### 4.18 Property names — `PropertyName.rc` / `PropertyNameRes.h`

`IDS_PROP_<X> = 1000 + kpid<X>` for kpid 3..104 (`PropertyNameRes.h:3-104`), e.g. `1003 Path`, `1004 Name`, `1005 Extension`, `1006 Folder`, `1007 Size`, `1008 Packed Size`, `1009 Attributes`, `1010 Created`, `1011 Accessed`, `1012 Modified`, `1013 Solid`, `1014 Commented`, `1015 Encrypted`, `1016 Split Before`, `1017 Split After`, `1018 Dictionary`, `1019 CRC`, `1020 Type`, `1021 Anti`, `1022 Method`, `1023 Host OS`, `1024 File System`, `1025 User`, `1026 Group`, `1027 Block`, `1028 Comment`, `1029 Position`, `1030 Path Prefix`, `1031 Folders`, `1032 Files`, `1033 Version`, `1034 Volume`, `1035 Multivolume`, `1036 Offset`, `1037 Links`, `1038 Blocks`, `1039 Volumes`, `1041 64-bit`, `1042 Big-endian`, `1043 CPU`, `1044 Physical Size`, `1045 Headers Size`, `1046 Checksum`, `1047 Characteristics`, `1048 Virtual Address`, `1049 ID`, `1050 Short Name`, `1051 Creator Application`, `1052 Sector Size`, `1053 Mode`, `1054 Symbolic Link`, `1055 Error`, `1056 Total Size`, `1057 Free Space`, `1058 Cluster Size`, `1059 Label`, `1060 Local Name`, `1061 Provider`, `1062 NT Security`, `1063 Alternate Stream`, `1064 Aux`, `1065 Deleted`, `1066 Is Tree`, `1067 SHA-1`, `1068 SHA-256`, `1069 Error Type`, `1070 Errors`, `1071 Errors`, `1072 Warnings`, `1073 Warning`, `1074 Streams`, `1075 Alternate Streams`, `1076 Alternate Streams Size`, `1077 Virtual Size`, `1078 Unpack Size`, `1079 Total Physical Size`, `1080 Volume Index`, `1081 SubType`, `1082 Short Comment`, `1083 Code Page`, `1084 Is not archive type`, `1085 Physical Size can't be detected`, `1086 Zeros Tail Is Allowed`, `1087 Tail Size`, `1088 Embedded Stub Size`, `1089 Link`, `1090 Hard Link`, `1091 iNode`, `1092 Stream ID`, `1093 Read-only`, `1094 Out Name`, `1095 Copy Link`, `1096 ArcFileName`, `1097 IsHash`, `1098 Metadata Changed`, `1099 User ID`, `1100 Group ID`, `1101 Device Major`, `1102 Device Minor`, `1103 Dev Major`, `1104 Dev Minor` (101 strings in `PropertyName.rc`; `1040` has no string, `1089` is `IDS_PROP_NT_REPARSE` "Link"). `PropertyName.cpp:10-23` `GetNameOfProperty(propID, name)`: for `propID < 1000` returns `LangString(1000 + propID)` when non-empty, else the handler-supplied name, else the numeric id.

### 4.19 Options › Settings page — `SettingsPage.cpp/.rc` (`IDD_SETTINGS 2500`, "Settings")

Controls in `SettingsPage2.rc` order (all `MY_CONTROL_CHECKBOX`, defaults from `CFmSettings::Load` `RegistryUtils.cpp:136-149`, values under `HKCU\Software\7-Zip\FM`):

| Control | ID | Text | Default | Persisted as |
|---|---|---|---|---|
| Checkbox | `IDX_SETTINGS_SHOW_DOTS 2501` | "Show \"..\" item" | false | `ShowDots` |
| Checkbox | `IDX_SETTINGS_SHOW_REAL_FILE_ICONS 2502` | "Show real file &icons" | false | `ShowRealFileIcons` |
| Checkbox | `IDX_SETTINGS_FULL_ROW 2504` | "&Full row select" | false | `FullRow` |
| Checkbox | `IDX_SETTINGS_SHOW_GRID 2505` | "Show &grid lines" | false | `ShowGrid` |
| Checkbox | `IDX_SETTINGS_SINGLE_CLICK 2506` | "&Single-click to open an item" | false | `SingleClick` |
| Checkbox | `IDX_SETTINGS_ALTERNATIVE_SELECTION 2507` | "&Alternative selection mode" | false | `AlternativeSelection` |
| Checkbox | `IDX_SETTINGS_SHOW_SYSTEM_MENU 2503` | "Show system &menu" | false | `ShowSystemMenu` |
| Checkbox | `IDX_SETTINGS_LARGE_PAGES 2508` | "Use &large memory pages" | false (`ReadLockMemoryEnable`, `HKCU\Software\7-Zip\LargePages`) | disabled if `!IsLargePageSupported()` (`SettingsPage.cpp:143-146`); on apply `NSecurity::EnablePrivilege_LockMemory(enable)` + `SaveLockMemoryEnable` (`:292-300`) |
| Label | `IDT_MEM_USAGE_EXTRACT 7816` | LTEXT "Maximum amount of RAM memory usage allowed to unpack archives:" | | |
| Checkbox + spin | `IDX_SETTINGS_MEM_SET 100` (`MY_CONTROL_CHECKBOX_COLON` ":"), `IDE_SETTINGS_MEM_SPIN_EDIT 101` + `IDC_SETTINGS_MEM_SPIN 102` (`MY_CONTROL_EDIT_WITH_SPIN`), `IDT_SETTINGS_MEM_GB 103` "GB" (becomes `GB / <RAM> GB (RAM)`) | | unchecked (spin disabled) when `NExtract::Read_LimitGB()` is `0`/`-1` (`:229-240`); spin range `1 .. valMax` with the same `valMax` rule as the Mem dialog (64 without RAM info, else `min(RAM_GB − 1, 16384)`, `:217-228`) | `Extraction\MemLimit` (GB): `OnApply` (`:302-321`) writes `-1` when unchecked, else the validated edit value (`ConvertStringToUInt32`, ≤ 2^30, otherwise `E_INVALIDARG` error box and `PSNRET_INVALID`) via `NExtract::Save_LimitGB` |

`OnApply` (`:272-321`): `CFmSettings::Save()` (`RegistryUtils.cpp:121-132`) only if `_wasChanged`, large pages only if `_largePages_wasChanged`, mem limit only if `_memx_wasChanged`; `OnButtonClicked`/`OnCommand` (`:391-430`) set those flags and call `Changed()`. The Options dialog then calls `SetListSettings()` and `RefreshAllPanels()`; Help → `"FM/options.htm#settings"`. `kLangIDs` localizes the eight checkboxes and the label.

### 4.20 Split — `SplitDialog.cpp/.rc` (`IDD_SPLIT 7300`, "Split File")

288 × 96 du, resizable; caption "Split File" replaced by the localized `IDS_SPLIT`-style title set by the caller (`SplitDialog.cpp:26-46`). Members: `FilePath`, `Path` (in/out), `VolumeSizes` (out, `CRecordVector<UInt64>`).

| Control | ID | Text | Behaviour |
|---|---|---|---|
| Label | `IDT_SPLIT_PATH 7301` | LTEXT "&Split to:" | localized (`kLangIDs`) |
| Path | `IDC_SPLIT_PATH 100` | `MY_COMBO_WITH_EDIT`, text = `Path` | `OnOK` → `Path` |
| Browse | `IDB_SPLIT_PATH 101` | PUSHBUTTON `"..."` (`WS_GROUP`) | `OnButtonSetPath` (`:87-100`): `MyBrowseForFolder(LangString(IDS_SET_FOLDER))`, result normalized to a dir prefix |
| Label | `IDT_SPLIT_VOLUME 7302` | LTEXT "Split to &volumes,  bytes:" | |
| Volume | `IDC_SPLIT_VOLUME 102` | `MY_COMBO_WITH_EDIT` (96 du wide) filled by `AddVolumeItems` (`SplitUtils.cpp:60-80`, `k_Sizes[]`): `10M`, `100M`, `1000M`, `650M-CD`, `700M-CD`, `4092M-FAT`, `4480M-DVD`, `8128M-DVDDL`, `23040M-BD`; first entry selected | `OnOK` (`:102-115`): `ParseVolumeSizes` (`SplitUtils.cpp:10-58`: space-separated list of `<number>[b\|k\|m\|g\|t]` with 2^10/20/30/40 multipliers, overflow → false) must succeed with ≥ 1 size, else `MessageBoxW(IDS_INCORRECT_VOLUME_SIZE 7307 "Incorrect volume size", "7-Zip", MB_ICONERROR)` and the dialog stays open |
| OK / Cancel | `OK_CANCEL` | | |

### 4.21 Options › System page — `SystemPage.cpp/.rc` (`IDD_SYSTEM 2200`, "System")

File association editor (`NUM_EXT_GROUPS = 2`: group 0 = current user `HKCU`, group 1 = all users `HKLM`, `GetHKey(g)`).

| Control | ID | Text | Behaviour |
|---|---|---|---|
| Label | `IDT_SYSTEM_ASSOCIATE 2201` | LTEXT "Associate 7-Zip with:" | localized (only `kLangIDs` entry) |
| Button | `IDB_SYSTEM_CURRENT 101` | PUSHBUTTON `"+"` above the current-user column | `ChangeState(0)` on all rows (`SystemPage.cpp:345-359`, `:419-431`) |
| Button | `IDB_SYSTEM_ALL 102` | PUSHBUTTON `"+"` above the all-users column (absent in `IDD_SYSTEM_2`) | `ChangeState(1)` on all rows |
| List | `IDL_SYSTEM_ASSOCIATE 100` | `SysListView32` report, `LVS_SHOWSELALWAYS \| LVS_SHAREIMAGELISTS \| LVS_NOSORTHEADER`; columns `Type` (`IDS_PROP_FILE_TYPE`, 80 du, with the format's icon), `<user name>` (`GetUserNameW`, fallback "Current User", 152 du centered), `All users` (`IDS_SYSTEM_ALL_USERS 2202`) (`:174-222`); one row per extension of `CExtDatabase::Read()` (`_extDB.Exts`, from `g_CodecsObj` formats + plugin icon paths, `:224-260`) | cell click on a marker column (`NM_CLICK`, `:375-395`), Space / `+` / `-` / `*` keys (`:440-470`: Space → group 0, others → group 1; `*` or Ctrl+A selects all) toggle the selected rows via `ChangeState(group, indices)` (`:100-153`): `kExtState_Clear` ⇄ `kExtState_7Zip`, and `kExtState_Other` (another program's ProgID shown) is restored when a row already had one; sets `_needSave` + `Changed()` |

`OnApply` (`:278-337`): for each row whose `State != OldState` per group — `kExtState_7Zip` → `NRegistryAssoc::AddShellExtensionInfo(key, ext, "<EXT> Archive", GetProgramCommand(), plugin.IconPath, plugin.IconIndex)` (`RegistryAssociations.cpp:105-160`: `Software\Classes\.<ext>` default = `7-Zip.<ext>`, `7-Zip.<ext>` default = title, `\DefaultIcon` = `"<iconPath>,<iconIndex>"`, `\shell\open\command` = `"<7zFM.exe>" "%1"`), `kExtState_Clear` → `DeleteShellExtensionInfo(key, ext)` (`:93-103`); the first error code is reported once as a MessageBox (HKLM without admin rights fails); then `SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST)`. `CShellExtInfo::ReadFromRegistry` / `IsIt7Zip` (`:47-91`) detect the current state. Help → `"FM/options.htm#system"`.

### 4.22 Options property sheet — `OptionsDialog.cpp` (`OptionsDialog(hwnd, hInstance)` `:32`)

`NControl::MyPropertySheet(pages, hwndOwner, LangString(IDS_OPTIONS))` (`Windows/Control/PropertyPage.cpp`) with pages in this order (`OptionsDialog.cpp:13-20`): `IDD_SYSTEM` (System), `IDD_MENU` (7-Zip), `IDD_FOLDERS` (Folders), `IDD_EDIT` (Editor), `IDD_SETTINGS` (Settings), `IDD_LANG` (Language) — `BIG_DIALOG_SIZE(200, 200)` / `SIZED_DIALOG` picks the `IDD_*_2` templates on small screens; page titles come only from the lang file (`LangString_OnlyFromLangFile(page.ID)`), falling back to the .rc captions. Each page implements `OnInit`, `OnCommand`/`OnButtonClicked` (call `Changed()`), `OnApply`, `OnNotifyHelp`. After the sheet returns with a non-zero/-1 result (`:31-50`): if `langPage.LangWasChanged` → `MyLoadMenu(true)`, `g_App.ReloadToolbars()`, `g_App.MoveSubWindows()`, `g_App.ReloadLangItems()`; then always `g_App.SetListSettings()` and `g_App.RefreshAllPanels()`.

### 4.23 Add to Archive (Compress) — `GUI/CompressDialog.cpp/.rc` (`IDD_COMPRESS 4000`, caption "Add to Archive")

Shown by `7zG.exe a -ad …` (§8.1) through `UpdateGUI.cpp` `ShowDialog` (`:315-541`, fills `NCompressDialog::CInfo` from `CUpdateOptions`/command-line `-m` properties via `ParseProperties`), never in-process by 7zFM. 400 × 320 du, `MY_MODAL_DIALOG_STYLE` (not resizable); left column 192 du (`gSize`), right column starts at `gSize + 24`. `IDD_COMPRESS_2` (152 × 160, CE) drops the labels, memory rows, path mode, Delete, Reenter password and Help. `NormalizePosition()` at init.

Format list offered (`UpdateGUI.cpp:398-419`): every `CArcInfoEx` with `UpdateEnabled`, excluding `Flags_KeepName` formats (gzip/bzip2/xz/… single-stream) unless exactly one regular file is being added, excluding hash handlers and `swfc` unless forced by `-t`. `dialog.SetMethods(userCodecs)` (`CompressDialog.cpp:405-427`) collects external single-stream codecs (from `Codecs\` DLLs) not already in `g_7zMethods` as extra 7z methods.

RAM (`OnInit` `:437-459`): `_ramSize` = `GetRamSize()` (capped at 1.75 GB on 32-bit builds), `_ramSize_Reduced = max(_ramSize, 64 MB)`, `_ramUsage_Auto = 80 %` of it.

#### Controls

| Control | ID | Type / text | Behaviour |
|---|---|---|---|
| Folder line | `IDT_COMPRESS_ARCHIVE_FOLDER 130` | LTEXT (top row, right of the "Archive:" label) | shows `DirPrefix` (the folder part of the archive path, `SetArcPathFields` `:830-858`); typing/choosing an absolute path moves the folder here (`ArcPath_WasChanged` `:1263`, `k_Message_ArcChanged` posted from the history combo, `:1290-1309`) |
| "&Archive:" | `IDT_COMPRESS_ARCHIVE 4001` | LTEXT | |
| Archive name | `IDC_COMPRESS_ARCHIVE 100` | `MY_COMBO_WITH_EDIT`, list = registry `ArcHistory` (`m_RegistryInfo.ArcPaths`, max `kHistorySize = 20`, `:86`, `:533-534`) | initial text = `Info.ArcPath` (caller's archive path without extension) + `.<main ext>` (`SetArchiveName` `:1477-1517`; for `Flags_KeepName` formats the original file name is kept, for hash handlers the extension is the lower-cased method name, SFX → `.exe`); on format change the previous format's extension is swapped (`SetArchiveName2` `:1450-1475`) |
| Browse | `IDB_COMPRESS_SET_ARCHIVE 101` | PUSHBUTTON `"..."` (`WS_GROUP`) | `OnButtonSetArchive` (`:879-1016`): `CBrowseInfo::BrowseForFile` in `SaveMode` with title `IDS_COMPRESS_SET_ARCHIVE_BROWSE 4070` "Browse", one filter per listed format `<Name> (ext1 ext2 …)` (extensions in `k_DontSave_Exts = "xpi odt ods docx xlsx"` `:876` are omitted from the masks), an "Archive: (all main exts)" filter and `IDS_OPEN_TYPE_ALL_FILES 4071` "All Files (*.*)"; SFX mode offers only `exe`; the chosen filter's main extension is appended when missing and, if it differs from the current format, the format combo is switched (`:1000-1016`) |
| "Archive &format:" | `IDT_COMPRESS_FORMAT 4003` / `IDC_COMPRESS_FORMAT 104` | `MY_COMBO \| CBS_SORT` (item data = index into `codecs->Formats`) | selection = caller-forced `Info.FormatIndex` (`-t`), else registry `ArcType` (`Compression\Archiver`), else the first entry (`:503-522`); change → `SaveOptionsInMem` + `FormatChanged(true)` (`:698-765`: re-fills level/solid/params/memuse/threads combos, enables Solid/Threads/Method/Dictionary/Order/SFX/encryption controls per `g_Formats` flags, loads per-format registry options) + `SetArchiveName2` |
| "Compression &level:" | `IDT_COMPRESS_LEVEL 4004` / `IDC_COMPRESS_LEVEL 102` | `MY_COMBO` | `SetLevel2` (`:1572-1618`): one item per bit of the format's `LevelsMask`, text `"<n> - <name>"` with `g_Levels[]` names `IDS_METHOD_STORE 4050` "Store" (0), `_FASTEST 4051` "Fastest" (1), `_FAST 4052` "Fast" (3), `_NORMAL 4053` "Normal" (5), `_MAXIMUM 4054` "Maximum" (7), `_ULTRA 4055` "Ultra" (9); even levels 2/4/6/8 show only the number; selection = registry `Level` of the format (`-1` → 5, `> 9` → 9), default 5; change → `ResetForLevelChange`, `SetMethod`, `SetSolidBlockSize`, `SetNumThreads`, `SetMemoryUsage` (`:1348-1369`) |
| "Compression &method:" | `IDT_COMPRESS_METHOD 4005` / `IDC_COMPRESS_METHOD 106` | `MY_COMBO` | `SetMethod2` (`:1627-1709`): empty for level 0 (except tar/hash); items from the format's method list (for 7z: `Copy`/`Deflate`/`Deflate64` are skipped (`:1664-1668`), external codecs appended; in SFX mode only `g_7zSfxMethods` = Copy/LZMA/LZMA2/PPMd); the first item is shown as `*  <name>` (`k_Auto_Prefix`) with item data `-1` (= "auto", nothing is emitted); selection = registry `Method` of the format if present, else the auto item; disabled when the format has no methods (`EnableItem(IDC_COMPRESS_METHOD, fi.MethodIDs != NULL)`) |
| "&Dictionary size:" | `IDT_COMPRESS_DICTIONARY 4006` / `IDC_COMPRESS_DICTIONARY 107` | `MY_COMBO` | `SetDictionary2` (`:1859-2153`), see below; first item `*  <auto>` (data `k_Auto_Dict`); registry `Dictionary` (only if the registry `Method` equals the current one) selects the largest item ≤ value; disabled when it has ≤ 1 item (`EnableMultiCombo`) |
| "&Word size:" | `IDT_COMPRESS_ORDER 4007` / `IDC_COMPRESS_ORDER 108` | `MY_COMBO` | `SetOrder2` (`:2213-2362`), see below; `*  <auto>` first; registry `Order` |
| "&Solid Block size:" | `IDT_COMPRESS_SOLID 4008` / `IDC_COMPRESS_SOLID 109` | `MY_COMBO` | `SetSolidBlockSize2` (`:2405-2521`), see below; enabled only for `kFF_Solid` formats (7z, xz) |
| "Number of CPU &threads:" | `IDT_COMPRESS_THREADS 4009` / `IDC_COMPRESS_THREADS 110` + `IDT_COMPRESS_HARDWARE_THREADS 112` | `MY_COMBO` + RTEXT `SS_NOPREFIX` | `SetNumThreads2` (`:2559-2712`), see below; the RTEXT shows `/ <process threads>` (+ ` / <system threads>` when they differ) |
| "Memory usage for Compressing:" | `IDT_COMPRESS_MEMORY 4017` / `IDC_COMPRESS_MEM_USE 117` + `IDT_COMPRESS_MEMORY_VALUE 113` | `MY_COMBO` (52 du) + LTEXT `MY_TEXT_NOPREFIX` | shown only for `kFF_MemUse` formats (`SetMemUseCombo` `:2767-2855`): items `*  80%` (auto, emits nothing), `10%` … `100%`, then absolute sizes `2·2^n` / `3·2^n` from 256 MB, 384 MB, 512 MB, 768 MB, 1 GB … up to `3 << 43` (64-bit) / `3 << 31` (32-bit); the registry `MemUse` value (e.g. `50%` or `512M`) is inserted at its sorted position and selected; value text = `<estimated usage> / <limit> / <RAM>` in MB/GB/TB (`PrintMemUsage` `:3099-3133`, `?` when unknown) |
| "Memory usage for Decompressing:" | `IDT_COMPRESS_MEMORY_DE 4018` / `IDT_COMPRESS_MEMORY_DE_VALUE 114` | LTEXT / RTEXT | estimated decompression memory (same visibility) |
| "Split to &volumes, bytes:" | `IDT_SPLIT_TO_VOLUMES 7302` / `IDC_COMPRESS_VOLUME 105` | `MY_COMBO_WITH_EDIT` filled by `AddVolumeItems` (same presets as §4.20, `:495`) | empty = no volumes; parsed at OK (`ParseVolumeSizes`) into `Info.VolumeSizes` → `options.VolumesSizes` (`UpdateGUI.cpp:476`) |
| "Parameters:" | `IDT_COMPRESS_PARAMETERS 4010` / `IDE_COMPRESS_PARAMETERS 111` | EDITTEXT `ES_AUTOHSCROLL` | free `-m` switches; pre-filled from registry `Options` of the format (`SetParams` `:3244-3254`); see parameter generation below |
| Options button + summary | `IDB_COMPRESS_OPTIONS 2100` PUSHBUTTON "Options" + `IDT_COMPRESS_OPTIONS 141` LTEXT `SS_NOPREFIX` (2 lines) | | opens §4.24 (`COptionsDialog`, `:607-612`); the static (`ShowOptionsString` `:3353-3371`) lists the non-default settings: `tp<N>`, `tm`/`tc`/`ta` (`-` suffix = off, `[tm]` = on by default), `-stl`, and `SL` `HL` `AS` `Sec` for enabled link/stream/security options |
| "&Update mode:" | `IDT_COMPRESS_UPDATE_MODE 4002` / `IDC_COMPRESS_UPDATE_MODE 103` | `MY_COMBO` | `k_UpdateMode_IDs` (`:378-384`): `IDS_COMPRESS_UPDATE_MODE_ADD 4060` "Add and replace files" (`kAdd` → `k_ActionSet_Add`), `_UPDATE 4061` "Update and add files" (`kUpdate`), `_FRESH 4062` "Freshen existing files" (`kFresh`), `_SYNC 4063` "Synchronize files" (`kSync`); mapping `g_UpdateMode_Pairs` (`UpdateGUI.cpp:290-296`); initial = the caller's action set (`-u`), default Add |
| "Path mode:" | `IDT_COMPRESS_PATH_MODE 3410` / `IDC_COMPRESS_PATH_MODE 116` | `MY_COMBO` | `k_PathMode_IDs` (`:396-401`): `IDS_PATH_MODE_RELAT` "Relative pathnames" (`NWildcard::k_RelatPath`), `IDS_EXTRACT_PATHS_FULL` "Full pathnames" (`k_FullPath`), `IDS_EXTRACT_PATHS_ABS` "Absolute pathnames" (`k_AbsPath`); initial = `options.PathMode` (`-spf`) |
| Options group | `IDG_COMPRESS_OPTIONS 4011` GROUPBOX "Options" | | |
| SFX | `IDX_COMPRESS_SFX 4012` `MY_CHECKBOX` "Create SF&X archive" | | enabled only for `kFF_SFX` formats (7z) and when the selected method is SFX-capable (`CheckSFXControlsEnable` `:618-631`); initial = `options.SfxMode` (`-sfx`); toggling swaps the extension to/from `.exe` (`OnButtonSFX` `:781-809`) and re-fills the method list; result `Info.SFXMode` → `options.SfxMode`, `BaseExtension = "exe"`, module `<7zG dir>\7z.sfx` (`kDefaultSfxModule`, `UpdateGUI.cpp:31`, `:561-565`) unless `-sfx<module>` was given. Volumes are **not** disabled with SFX (`CheckVolumeEnable` is commented out) |
| Shared | `IDX_COMPRESS_SHARED 4013` `MY_CHECKBOX` "Compress shared files" | | `OpenShareForWrite` (`-ssw`) |
| Delete | `IDX_COMPRESS_DEL 4019` `MY_CHECKBOX` "Delete files after compression" | | `DeleteAfterCompressing` (`-sdel`) |
| Encryption group | `IDG_COMPRESS_ENCRYPTION 4014` GROUPBOX "Encryption" | | group and all its controls are enabled only for `kFF_Encrypt` formats (7z, zip) (`:747-762`) |
| Password | `IDT_PASSWORD_ENTER 3801` "Enter &password:" / `IDE_COMPRESS_PASSWORD1 120`; `IDT_PASSWORD_REENTER 3802` "Reenter password:" / `IDE_COMPRESS_PASSWORD2 121` | EDITTEXT `ES_PASSWORD \| ES_AUTOHSCROLL` | pre-filled with `Info.Password` (`-p`); result → `callback->Password` |
| Show password | `IDX_PASSWORD_SHOW 3803` `MY_CHECKBOX` "Show Password" | | `UpdatePasswordControl` (`:570-584`): clears the password char and hides the re-enter label/edit; initial from registry `Compression\ShowPassword`, saved at OK |
| "&Encryption method:" | `IDT_COMPRESS_ENCRYPTION_METHOD 4015` / `IDC_COMPRESS_ENCRYPTION_METHOD 122` | `MY_COMBO` | `SetEncryptionMethod` (`:1721-1752`): 7z → `AES-256` only; zip → `ZipCrypto` (default), `AES-256` (selected when registry `EncryptionMethod` starts with `aes`); `GetEncryptionMethodSpec` (`:1810-1821`) returns the name without `-` (`AES256`) only when it is not the default item |
| Encrypt names | `IDX_COMPRESS_ENCRYPT_FILE_NAMES 4016` `MY_CHECKBOX` "Encrypt file &names" | | visible/enabled only for `kFF_EncryptFileNames` (7z); initial from registry `EncryptHeaders`; result `Info.EncryptHeaders` (`he`) |
| OK / Cancel / Help | `IDOK` (DEFPUSHBUTTON, `WS_GROUP`) / `IDCANCEL` / `IDHELP` | | Help → `kHelpTopic = "fm/plugins/7-zip/add.htm"` (`CompressDialog.cpp:1254`) |

`kLangIDs` (`:45-84`) localizes every label, group, checkbox and the Options button. Other combo changes (`OnCommand` `:1313-1439`): Method → `MethodChanged` (dictionary + order refill), solid, threads, memory, and for hash handlers the archive extension; Dictionary → resets the stored block size unless it was Non-solid/Solid, refills solid/threads, memory; Order/Solid/Threads → memory; Mem use → threads (auto value) + memory.

#### Format table (`g_Formats[]`, `CompressDialog.cpp:271-356`) — `{Name, LevelsMask, NumMethods, MethodIDs, Flags}`

Matched by name against the selected `CArcInfoEx` (`GetStaticFormatIndex` `:1551-1558`, falls back to entry 0 for any other update-capable handler). Method names from `kMethodsNames[]` (`:147-162`): `Copy, LZMA, LZMA2, PPMd, BZip2, Deflate, Deflate64, PPMd (zip variant), SHA256, SHA1, CRC32, CRC64, GNU, POSIX`. Flags (`:236-248`): `kFF_Filter 1<<0`, `kFF_Solid 1<<1`, `kFF_MultiThread 1<<2`, `kFF_Encrypt 1<<3`, `kFF_EncryptFileNames 1<<4`, `kFF_MemUse 1<<5`, `kFF_SFX 1<<6` (`kFF_Time_*` bits 10-13 are defined but unused).

| Format | Levels (`LevelsMask`) | Methods (first = auto/default) | Flags |
|---|---|---|---|
| `""` (any other handler) | 0-9 | none (`MethodIDs = NULL`) | `MultiThread \| MemUse` |
| `7z` | 0-9 | `g_7zMethods`: LZMA2, LZMA, PPMd, BZip2, Deflate, Deflate64, Copy — the last three are hidden in the combo (`:1664-1668`); external codec DLL methods appended; SFX mode: `g_7zSfxMethods` = Copy, LZMA, LZMA2, PPMd | `Filter \| Solid \| MultiThread \| Encrypt \| EncryptFileNames \| MemUse \| SFX` |
| `Zip` | 0, 1, 3, 5, 7, 9 | `g_ZipMethods`: Deflate, Deflate64, BZip2, LZMA, PPMd (`kPPMdZip`) | `MultiThread \| Encrypt \| MemUse` |
| `GZip` | 1, 5, 7, 9 | Deflate | `MemUse` |
| `BZip2` | 1, 3, 5, 7, 9 | BZip2 | `MultiThread \| MemUse` |
| `xz` | 1-9 | LZMA2 | `Solid \| MultiThread \| MemUse` |
| `Tar` | 0 | `g_TarMethods`: GNU, POSIX (tar header format) | none |
| `wim` | 0 | none | none |
| `Hash` | none (mask 0) | `g_HashMethods`: SHA256, SHA1 | none |

`zstd` and `Swfc` entries exist only in commented-out code (`:208-221`, `:322-337`) — no zstd in the 26.03 GUI.

#### Automatic values (`CompressDialog.cpp` `SetDictionary2` `:1859-2153`, `SetOrder2` `:2213-2362`, `SetSolidBlockSize2` `:2405-2521`, `SetNumThreads2` `:2559-2712`)

Every combo has an "auto" first item (`*  <value>`, item data `-1`/`k_Auto_Dict`) whose value is computed from level/method; when the auto item is selected the property is **not** emitted (`GetDictSpec`/`GetOrderSpec`/`GetNumThreadsSpec`/`GetBlockSizeSpec` return `-1`) and the engine applies its own defaults. Item texts use `<N> B/KB/MB/GB` (`Combo_AddDict2` `:1825-1840`, `Add_Size` `:2390-2403`). `L` = level (`GetLevel2`, `-1` → 5).

* **Dictionary** (`_auto_Dict`): LZMA/LZMA2: `L ≤ 4` → `1 << (2L + 16)` (64 KB, 256 KB, 1 MB, 4 MB, 16 MB); `L ≤ 8` (64-bit) / `L ≤ 6` (32-bit) → `1 << (L + 20)` (32 MB … 256 MB); above → `1 << 28` = 256 MB on 64-bit / `1 << 26` = 64 MB on 32-bit (`:1941-1946`). Items: 64 KB, 256 KB, 1 MB, 2 MB, 3 MB, 4 MB, 6 MB, 8 MB, 12 MB, 16 MB, 24 MB, 32 MB, 48 MB, 64 MB, … (`2·2^n`, `3·2^n`) up to `kLzmaMaxDictSize = 15 << 28` = 3840 MB on 64-bit (loop stops at `kLzmaMaxDictSize_Up` = 4 GB; 2 GB/3 GB/4 GB entries are clamped to 3840 MB) and up to 64 MB on 32-bit (`:1947-1966`). PPMd (7z): `1 << (L + 19)` (1 MB at L1 … 16 MB at L5 … 256 MB at L9); items 1 MB, 2 MB, 3 MB, … up to 1 GB (64-bit) / 512 MB (32-bit), values ≥ 3840 MB clamped to `4 GB − 1 KB` (`:2067-2104`). PPMd (zip): `1 << (L + 19)`; items 1 MB … 256 MB (`:2105-2124`). Deflate: 32 KB, Deflate64: 64 KB (single auto item, `:2125-2135`). BZip2: 900 KB (`L ≥ 5`), 500 KB (`L ≥ 3`), 100 KB; items 100 KB … 900 KB (`:2136-2158`). Copy: 0. `-mx` levels only influence the auto value. The registry `Dictionary` (`-2` marker = ≥ 4 GB) selects the largest item ≤ value (`SaveOptionsInMem` `:3256-3318`).
* **Word size / order** (`_auto_Order`): LZMA/LZMA2: 32 (`L < 7`), 64 (`L ≥ 7`); items 8, 12, 16, 24, 32, 48, 64, 96, 128, 192, 256, 273 (`:2239-2258`). Deflate/Deflate64: 32 (`L < 7`), 64 (`L 7-8`), 128 (`L 9`); items 8 … 256 then 258 (Deflate) / 257 (Deflate64) (`:2291-2314`). PPMd (7z): 4 (`L < 5`), 6 (`L 5-6`), 16 (`L 7-8`), 32 (`L 9`); items 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 20, 24, 28, 32 (`:2315-2341`). PPMd (zip): `L + 3`; items 2 … 16 (`:2342-2356`). BZip2/Copy/others: empty combo (disabled). `OrderMode` = true for PPMd/PPMdZip (`GetOrderMode` `:2363-2372`) which switches the emitted property names to `mem`/`o`.
* **Solid block size** (`_auto_Solid`, only `kFF_Solid` formats and `L > 0`): 7z: LZMA2 → `Get_Lzma2_ChunkSize(dict) << 6` (chunk = `dict × 4` clamped to 1 MB … 256 MB, rounded up to 1 MB, `:2375-2388`) capped at 16 GB; other methods → `dict << 7` (BZip2 dictionary rounded to a multiple of 100000) capped at 4 GB; minimum 16 MB (`:2452-2479`). xz: `= chunk size` (no min/max). Items: `*  <auto>` (data `-1`), `IDS_COMPRESS_NON_SOLID 4072` "Non-solid" (7z only, `kSolidLog_NoSolid = 0`), `1 MB` … `64 GB` (`2^20 … 2^36`, item data = log2), `IDS_COMPRESS_SOLID 4073` "Solid" (`kSolidLog_FullSolid = 64`) (`:2481-2521`). `OnOK` (`:1160-1168`): `-1` → `SolidIsSpecified = false` (nothing emitted); 0 → `s=0b`; `64` → `SolidBlockSize = (UInt64)-1` (emitted as `s=18446744073709551615b`); else `s=<2^log>b`. Registry `BlockLogSize` selects the item.
* **Threads** (`_auto_NumThreads`): `numCPUs` = process affinity thread count, `numHardwareThreads` = system count (`CProcessAffinity`); per-method maximum `numAlgoThreadsMax` (`:2609-2627`): zip 128 (64-bit) / 32 (32-bit), xz 512, LZMA 2, LZMA2 512, BZip2 64, Copy/PPMd/Deflate/Deflate64/PPMdZip 1, other formats `2 × hardware`; `autoThreads = min(numCPUs, max)` then reduced while the estimated memory exceeds the memory-use limit (zip: one thread at a time; LZMA2: in units of `2` block threads for `L ≥ 5`, `:2634-2680`). Items: `*  <auto>` then `1 … min(2 × hardware, max)` (omitted when the only possibility is 1); registry `NumThreads` (only for the same method) selects an explicit item, otherwise auto (`:2681-2712`). The "/ N" static shows `numCPUs` (`/ numCPUs / numHardwareThreads` when they differ).
* **Memory limit** (`Get_MemUse_Bytes` `:2865-2876`): the combo's registry string (`NN%` of `_ramSize_Reduced`, or absolute `<N>M/G`) parsed by `NCompression::CMemUse`; auto → `_ramUsage_Auto` = 80 % of `_ramSize_Reduced`.
* **Memory estimation** (`GetMemoryUsage_Threads_Dict_DecompMem` `:2901-3070`): `L == 0` → 1 MB (both); `kFF_Filter` formats at `L ≥ 9` add `2 × 12 MB + 5 MB` (BCJ2); zip adds `numMainZipThreads × (sizeof(size_t) << 23)` when more than one main thread (zip+LZMA at `L ≥ 5` uses 2 sub-threads per file). LZMA/LZMA2 (`:2942-3017`): per block `hs × 4 + dict × 4 (+ dict × 4 for L ≥ 5) + 2 MB (+ 6 MB for the 2-thread match finder)` plus the block buffer (`dict + 64 KB (+1 MB)` × 1.5 for single-block LZMA, or the LZMA2 chunk size × (blocks + blocks/8 + 1) pack buffers); decompression = `dict + 2 MB`. PPMd: `dict + 2 MB` (both). Deflate/Deflate64: `4 MB × numMainZipThreads`, decompression 2 MB. BZip2: `10 MB × threads`, decompression 7 MB. PPMdZip: `(dict + 2 MB) × threads`. Unknown dictionary (auto item of an unknown method) → `?`. Displayed by `PrintMemUsage` (`:3099-3133`) as `<usage> / <limit> / <RAM>` in MB (≤ 16 GB), GB (≤ 64 TB) or TB.

#### OnOK validation (`CompressDialog.cpp:1066-1252`)

1. zip only: the password must be ASCII (`IsAsciiString` `:1018`, `IDS_PASSWORD_USE_ASCII 3805` "Use only English letters, numbers and special characters (!, #, $, ...) for password."); zip + AES: length ≤ 99 (`IDS_PASSWORD_TOO_LONG 3806` "Password is too long").
2. If "Show Password" is unchecked the two password fields must match (`IDS_PASSWORD_NOT_MATCH 3804` "Passwords do not match").
3. If the estimated compression memory is known and exceeds `Get_MemUse_Bytes()`: `SetErrorMessage_MemUsage` (`:1047-1064`: `IDS_MEM_OPERATION_BLOCKED 7810` "The operation was blocked by 7-Zip." + `IDS_MEM_REQUIRES_BIG_MEM` + required / limit / RAM sizes in MB) is shown and the dialog stays open.
4. `SaveOptionsInMem()` stores the current combo values into the format's `CFormatOptions`; `GetFinalPath_Smart` (`:811-828`) resolves the archive name against `DirPrefix` (or `StartDirPrefix`); failure → `k_IncorrectPathMessage` "Incorrect archive path". No extension is added here (the name already carries it).
5. `Info.*` are filled (`UpdateMode`, `PathMode`, `Level`, `Dict64`, `Order`, `OrderMode`, `NumThreads`, `MemUsage`, `SolidBlockSize`/`SolidIsSpecified`, `Method`, `EncryptionMethod`, `FormatIndex`, `SFXMode`, `OpenShareForWrite`, `DeleteAfterCompressing`, `EncryptHeaders`, the five `CBoolPair`s via `SET_FINAL_BOOL_PAIRS` — unsupported ones are cleared —, time options from `CFormatOptions`, `Options` = Parameters text).
6. Volumes: non-empty text must pass `ParseVolumeSizes` (`IDS_INCORRECT_VOLUME_SIZE 7307`); a last volume < 100 KB asks `IDS_SPLIT_CONFIRM 7308` "Specified volume size: {0} bytes.\nAre you sure you want to split archive into such volumes?" (`MB_YESNOCANCEL`).
7. Registry: `ArcType` = format name, `ShowPassword`, `EncryptHeaders`, `ArcPaths` = new path + previous history (max 20), per-format options — `NCompression::CInfo::Save()` (§5.4).

#### Parameter generation (`UpdateGUI.cpp` `ShowDialog` `:315-541`, `SetOutProperties` `:205-284`, `ParseAndAddPropertires` `:176-194`)

After `IDOK`, `options.MethodMode.Properties` is rebuilt as `-m` name/value pairs in this order: `x=<level>` (if set); if the Parameters text contains no method override (`IsThereMethodOverride` `:154-174`: a `<digit>=` token for 7z, `m=` otherwise): `0=<Method>` (7z) / `m=<Method>` (others) when a non-auto method is selected, `0d=<dict>b` / `d=<dict>b` (or `0mem`/`mem` for PPMd `OrderMode`), `0fb=<order>` / `fb=<order>` (or `0o`/`o` for PPMd); then `em=<AES256>` (only when not the default method), `he=on|off` (only for formats with `kFF_EncryptFileNames`), `s=<bytes>b` (when `SolidIsSpecified`), `mt=<N>` (when not auto), `memuse=<NN>%` or `memuse=<bytes>b` (when set), `tm`/`tc`/`ta` = `on|off` (only when their `CBoolPair.Def` is set), `tp=<N>` (when set). Then the Parameters text is split on whitespace (`SplitOptionsToStrings` `:141-152`), a leading `-m` is stripped from each token and every `name[=value]` is appended (later duplicates win in the handler). Other dialog results map to `CUpdateOptions`: `DeleteAfterCompressing` (`-sdel`), `SetArcMTime` (`-stl`), `PreserveATime` (`-ssp`, only when `Def`), `VolumesSizes` (`-v`), `ActionSet` from `g_UpdateMode_Pairs` (`-u`), `PathMode` (`-spf`), `OpenShareForWrite` (`-ssw`), `SymLinks`/`HardLinks`/`AltStreams`/`NtSecurity` (`-snl`/`-snh`/`-sns`/`-sni`), `SfxMode` + `ArchivePath.BaseExtension = "exe"` (`-sfx`, module `<7zG dir>\7z.sfx` if none given), `MethodMode.Type.FormatIndex` (`-t`), `Password`; the working directory for the temp archive comes from `NWorkDir::CInfo` (§4.8) unless mode is `kCurrent`. The dialog's `CurrentDirWasChanged` restores the process directory afterwards. The progress title is `IDS_PROGRESS_COMPRESSING` (or `IDS_CHECKSUM_CALCULATING` for hash formats).

### 4.24 Compress Options — `GUI/CompressOptionsDialog.rc` (`IDD_COMPRESS_OPTIONS 14001`, caption "Options"; `COptionsDialog` in `CompressDialog.cpp:3350-3700`)

240 × 232 du, `MY_MODAL_DIALOG_STYLE`; caption localized from `IDB_COMPRESS_OPTIONS` (`:3701`); `kLangIDs_Options` (`:3680-3696`) localizes the four NTFS boxes, the Time group, the precision label and the five time checkboxes. Values are exchanged with the parent `CCompressDialog` (`cd`): `CBool1 {Val, Supported}` for the NTFS/ATime boxes, `CBoolBox {Id, Set_Id, BoolPair, DefaultVal, IsSupported}` for the time boxes.

| Control | ID | Text | Behaviour |
|---|---|---|---|
| Group | `IDG_COMPRESS_NTFS 115` | GROUPBOX "NTFS" | hidden with all four boxes when none is supported (`OnInit` `:3709-3719`) |
| Checkbox | `IDX_COMPRESS_NT_SYM_LINKS 4040` | "Store symbolic links" | shown only if `CArcInfoEx::Flags_SymLinks()`; initial `cd->SymLinks.Val` (command line `-snl` or registry `SymLinks`, combined in `FormatChanged` via `SET_GUI_BOOL`); result → `Info.SymLinks` (`-snl`) |
| Checkbox | `IDX_COMPRESS_NT_HARD_LINKS 4041` | "Store hard links" | `Flags_HardLinks()`; `-snh`; registry `HardLinks` |
| Checkbox | `IDX_COMPRESS_NT_ALT_STREAMS 4042` | "Store alternate data streams" | `Flags_AltStreams()`; `-sns`; registry `AltStreams` |
| Checkbox | `IDX_COMPRESS_NT_SECUR 4043` | "Store file security" | `Flags_NtSecurity()`; `-sni`; registry `NtSecurity` |
| Info | `IDT_COMPRESS_TIME_INFO 191` | LTEXT above the Time group | `Type: <format name>` (+ `:GNU`/`:POSIX` for tar) (`SetPrec` `:3482-3500`) |
| Group | `IDG_COMPRESS_TIME 4080` | GROUPBOX "Time" (112 du) | |
| Set-box + label + combo | `IDX_COMPRESS_PREC_SET 201` (`MY_CONTROL_CHECKBOX_COLON` ":"), `IDT_COMPRESS_TIME_PREC 4081` "Timestamp precision:", `IDC_COMPRESS_TIME_PREC 190` `MY_COMBO` (76 du) | `SetPrec` (`:3482-3582`): one item per bit of `CArcInfoEx::Get_TimePrecFlags()` (+ the default precision): `100 ns : Windows` (`kTimePrec_Win 0`), `1 sec : Unix` (1), `2 sec : DOS` (2), `1 ns : Linux` (3), `1 sec` (`k_PropVar_TimePrec_Base`) and `10^(9-d) ns` for base+1 … base+9 (`AddPrec` `:3455-3480`, units `IDS_COMPRESS_SEC 4090` "sec" / `IDS_COMPRESS_NS 4091` "ns"); default = `Get_DefaultTimePrec()` (gzip forced to Unix); selection = registry/stored `TimePrec` when set (an unknown value ≥ 3 is added as a plain number); combo enabled only when the ":" box is checked and there is more than one item; the ":" box is hidden when nothing can be chosen; unchecking it resets `TimePrec` to `-1` | `tp=<N>`; registry `TimePrec` |
| Set + checkbox | `IDX_COMPRESS_MTIME_SET 202` / `IDX_COMPRESS_MTIME 4082` "Store modification time" | | `SetTimeMAC` (`:3584-3653`): shown if `Flags_MTime()`; default value `Flags_MTime_Default()`; when not explicitly set and the format is not single-file (`Flags_KeepName`), the ":" box is hidden and the checkbox disabled (mtime is always stored); `tm=on\|off` only when set; registry `MTime` |
| Set + checkbox | `IDX_COMPRESS_CTIME_SET 203` / `IDX_COMPRESS_CTIME 4083` "Store creation time" | | shown if `Flags_CTime()`; tar → never; zip → only with Windows (100 ns) precision; default `Flags_CTime_Default()`; `tc=on\|off`; registry `CTime` |
| Set + checkbox | `IDX_COMPRESS_ATIME_SET 204` / `IDX_COMPRESS_ATIME 4084` "Store last access time" | | shown if `Flags_ATime()`; tar → only for POSIX headers; zip → only with Windows precision; default `Flags_ATime_Default()`; `ta=on\|off`; registry `ATime` |
| Set + checkbox | `IDX_COMPRESS_ZTIME_SET 205` / `IDX_COMPRESS_ZTIME 4085` "Set archive time to latest file time" (2-line checkboxes) | | always shown; default false; result `SetArcMTime` → `options.SetArcMTime` (`-stl`); registry `SetArcMTime` |
| Checkbox | `IDX_COMPRESS_PRESERVE_ATIME 4086` | "Do not change source files last access time" (2 lines) | `CBool1`; `-ssp` (`options.PreserveATime` only when `Def`) |
| OK / Cancel / Help | `IDOK` (DEFPUSHBUTTON) / `IDCANCEL` / `IDHELP` | | `OnOK` (`:3797-3816`) copies the boxes back into `cd->SymLinks/HardLinks/AltStreams/NtSecurity/PreserveATime` and the format's `CFormatOptions` (`TimePrec`, `MTime`, `CTime`, `ATime`, `SetArcMTime`); the parent then refreshes `IDT_COMPRESS_OPTIONS`; Help → `kHelpTopic_Options = "fm/plugins/7-zip/add.htm#options"` (`:1255`, `:3818-3821`) |

"Set" (":") checkboxes implement tri-state (`CBoolPair {Def, Val}`): unchecked = leave the handler default (the value box shows `DefaultVal` and is disabled) and emit nothing; a precision change re-evaluates the C/A-time availability for zip (`OnCommand` `:3765-3779`).

### 4.25 Extract — `GUI/ExtractDialog.cpp/.rc` (`IDD_EXTRACT 3400`, caption "Extract")

Shown by `7zG.exe x -ad …` through `ExtractGUI.cpp` (`:203-247`): `DirPath` = full normalized `-o` output dir (or the current directory), `ArcPath` = the archive path when exactly one archive is given, `PathMode`/`OverwriteMode` (+ `_Force` flags from the command line), `ElimDup`, `NtSecurity`, `Password` (if already known). 336 × 168 du, `MY_MODAL_DIALOG_STYLE`; caption = localized `IDD_EXTRACT` text (fallback "Extract") + ` : <ArcPath>` (`ExtractDialog.cpp:141-150`); window icon `IDI_ICON`. The `IDD_EXTRACT_2` (CE, 152 × 128) variant has no sub-folder edit, Elim-dup, NT-security or Help. `CExtractDialog` members (`ExtractDialog.h:76-92`): `DirPath` (in/out), `ArcPath`, `Password` (in/out), `PathMode_Force`, `OverwriteMode_Force`, `PathMode`, `OverwriteMode`, `NtSecurity`, `ElimDup` (`CBoolPair`), `_info` (`NExtract::CInfo`, registry §5.4).

| Control | ID | Text | Behaviour |
|---|---|---|---|
| "E&xtract to:" | `IDT_EXTRACT_EXTRACT_TO 3401` | LTEXT | |
| Path | `IDC_EXTRACT_PATH 100` | `MY_COMBO_WITH_EDIT`, list = registry `PathHistory` (`_info.Paths`, max `kHistorySize = 16`, `:91`) | initial text = `DirPath` (or its parent when the sub-folder box is on, `:186-207`); the first history item is pre-selected when history exists |
| Browse | `IDB_EXTRACT_SET_PATH 101` | PUSHBUTTON `"..."` (`WS_GROUP`) | `OnButtonSetPath` (`:276-288`): `MyBrowseForFolder(IDS_EXTRACT_SET_FOLDER 3402 "Specify a location for extracted files.")`, result normalized to a dir prefix |
| Sub-folder checkbox | `IDX_EXTRACT_NAME_ENABLE 131` | `MY_CHECKBOX` without text | initial = registry `SplitDest` (default **true**); when on, `SplitPathToParts_Smart(DirPath)` puts the parent in the combo and the last component in the name edit (`:195-207`); toggling shows/hides the edit (`:263-264`); at OK the edit text is appended to the combo path (`:375-388`) and a changed state is saved with `Def = true` |
| Sub-folder name | `IDE_EXTRACT_NAME 130` | EDITTEXT `ES_AUTOHSCROLL` | last path component of `DirPath` (the caller already derived it from the archive name: `7zG x -ad` → `<archive name without extension>\`) |
| "Path mode:" | `IDT_EXTRACT_PATH_MODE 3410` / `IDC_EXTRACT_PATH_MODE 102` | `MY_COMBO` | `kPathMode_IDs` (`:33-38`) / `kPathModeButtonsVals` (`:49-57`): `IDS_EXTRACT_PATHS_FULL 3411` "Full pathnames" → `kFullPaths`, `IDS_EXTRACT_PATHS_NO 3412` "No pathnames" → `kNoPaths`, `IDS_EXTRACT_PATHS_ABS 3413` "Absolute pathnames" → `kAbsPaths`; initial = caller's `PathMode` unless the registry value is forced (`PathMode_Force`, `:172-176`); a caller `kCurPaths` is displayed as Full and kept unless the user picks another mode (`:302-305`); saved as `ExtractMode` + `PathMode_Force` when changed, never storing `kAbsPaths` (`:328-337`) |
| Elim dup | `IDX_EXTRACT_ELIM_DUP 3430` | `MY_CHECKBOX` "Eliminate duplication of root folder" | `CheckButton_TwoBools(ElimDup, _info.ElimDup)` (`GetBoolsVal` `:114-119`: caller's `Def` wins, else registry, default true); result → `options.ElimDup`; registry `ElimDup` (Def/Val pair) |
| "Overwrite mode:" | `IDT_EXTRACT_OVERWRITE_MODE 3420` / `IDC_EXTRACT_OVERWRITE_MODE 103` | `MY_COMBO` | `kOverwriteMode_IDs` (`:40-47`) / `kOverwriteButtonsVals` (`:59-69`): `IDS_EXTRACT_OVERWRITE_ASK 3421` "Ask before overwrite" → `kAsk`, `_WITHOUT_PROMPT 3422` "Overwrite without prompt" → `kOverwrite`, `_SKIP_EXISTING 3423` "Skip existing files" → `kSkip`, `_RENAME 3424` "Auto rename" → `kRename`, `_RENAME_EXISTING 3425` "Auto rename existing files" → `kRenameExisting` (`Common/ExtractMode.h:20-29`); initial = caller's unless registry forced (`:177-178`); saved as `OverwriteMode` (+ `OverwriteMode_Force` when it differs from the caller's, `:339-341`) |
| Password group | `IDG_PASSWORD 3807` GROUPBOX "Password" / `IDE_EXTRACT_PASSWORD 120` (`ES_PASSWORD \| ES_AUTOHSCROLL`) / `IDX_PASSWORD_SHOW 3803` `MY_CHECKBOX` "Show Password" | | pre-filled with the caller's password; show box initial from registry `ShowPassword` (`:184`), toggles the password char (`UpdatePasswordControl` `:246-253`), saved with `Def = true` when changed (`:321-326`); result → `extractCallback->Password` |
| NT security | `IDX_EXTRACT_NT_SECUR 3431` | `MY_CHECKBOX` "Restore file security" | `CheckButton_TwoBools(NtSecurity, _info.NtSecurity)`; result → `options.NtOptions.NtSecurity` (`-sni`); registry `Security` pair. (`IDX_EXTRACT_ALT_STREAMS 3432` is commented out) |
| OK / Cancel / Help | `IDOK` (DEFPUSHBUTTON, `WS_GROUP`) / `IDCANCEL` / `IDHELP` | | `OnOK` (`:299-411`): reads modes/password/bool pairs, takes the combo text (or the selected history entry), trims, normalizes, appends the sub-folder name, stores `DirPath`, rebuilds `_info.Paths` = new path + other history entries (max 16) and `_info.Save()`; Help → `kHelpTopic = "fm/plugins/7-zip/extract.htm"` (`:414`) |

`kLangIDs` (`:75-89`) localizes the labels, the two checkboxes, the group and the show-password box. Path modes in the engine (`Common/ExtractMode.h:8-18`): `kFullPaths`, `kCurPaths` (paths relative to the current archive folder — FM "extract this folder"), `kNoPaths`, `kAbsPaths`; overwrite modes (`:20-30`) as above; Zone-ID modes `kNone`, `kAll`, `kOffice` (`:32-40`).

### 4.26 Benchmark — `GUI/BenchmarkDialog.cpp/.rc` (`IDD_BENCH 7600` resizable; `IDD_BENCH_TOTAL 7699` for `-mm=*` mode)

Runs in `7zG.exe b` (`Benchmark(totalMode)` in `Common/CompressCall.cpp:332-343` → `7zG b [-mm=*] [-slp]`, launched from Tools → Benchmark). `IDD_BENCH` is 332 + 140 (log column) × 248 du, `MY_MODAL_RESIZE_DIALOG_STYLE | WS_MINIMIZEBOX` (`SIZED_DIALOG` → `IDD_BENCH_2 17600` on small screens); `IDD_BENCH_TOTAL 7699` is used when `TotalMode` (`-mm=*`) (`BenchmarkDialog.cpp:366`). Timer `kTimerElapse = 1000 ms` (`:40`); RAM limit `RamSize_Limit = RAM × 15/16` (`:565`), `IsMemoryUsageOK(usage) = usage + 1 MB ≤ RamSize_Limit` (`:324-325`).

| Control | ID | Text | Behaviour |
|---|---|---|---|
| Restart | `IDB_RESTART 443` | PUSHBUTTON "&Restart" (top-right) | `RestartBenchmark` (`:922-935`): if the worker runs, sets `NeedRestart` and asks it to exit (`SendExit_Status("Stop for restart ...")`), else `StartBenchmark` (`:857-920`) |
| Stop | `IDB_STOP 442` | PUSHBUTTON "&Stop" | `OnStopButton` (`:949-961`): disables itself (focus → Restart) and asks the worker to exit (`"Stop ..."`) |
| Help / Cancel | `IDHELP` / `IDCANCEL` | PUSHBUTTONs (bottom-right) | Help → `kHelpTopic = "fm/benchmark.htm"` (`:37`); Cancel (`OnCancel` `:965-978`) disables itself, asks the worker to exit (`"Cancel ..."`) and closes when the thread has ended |
| "&Dictionary size:" | `IDT_BENCH_DICTIONARY 4006` (= `IDS_PROP_DICTIONARY_SIZE`) / `IDC_BENCH_DICTIONARY 101` | `MY_COMBO` | items `2·2^n`, `3·2^n` from `kMinDicSize = 1 << 18` = 256 KB (`:426-428`) — 256 KB, 384 KB, 512 KB, 768 KB, 1 MB, … — up to `kMaxDicSize = 1 << (22 + sizeof(size_t)/4·5)` = 4 GB on 64-bit / 64 MB on 32-bit (`:429`, `:585-604`), text in KB/MB/GB; initial = `-md` value or the largest `2^n` from 32 MB (`dicSizeLog = 25`) downwards whose memory usage fits (`:569-582`); change → `RestartBenchmark` (`:1390-1401`) |
| Memory usage | `IDT_BENCH_MEMORY 7601` "Memory usage:" / `IDT_BENCH_MEMORY_VAL 102` | LTEXT | `<N> MB / <RAM> MB` from `GetBenchMemoryUsage(threads, level, dict, totalMode)` (`Common/Bench.cpp`; `OnChangeDictionary` `:742-760`, `Print_MemUsage` `:732-740`); if the usage does not fit, `StartBenchmark` shows `SetErrorMessage_MemUsage` (shared with the Compress dialog) as an error box and does not start |
| "&Number of CPU threads:" | `IDT_BENCH_NUM_THREADS 4009` / `IDC_BENCH_NUM_THREADS 103` + `IDT_BENCH_HARDWARE_THREADS 104` | `MY_COMBO` + LTEXT (2 lines) | items `1, 2, 4, 6, …` up to `2 × system threads` (`:532-548`); initial = `-mmt` value or the process thread count rounded down to even (max 16384); the static shows `/ <process threads>` + affinity info (`GetProcessThreadsInfo`) |
| Column headers | `IDT_BENCH_SIZE 1007` "Size", `IDT_BENCH_USAGE_LABEL 7608` "CPU Usage", `IDT_BENCH_SPEED 3903` "Speed", `IDT_BENCH_RPU_LABEL 7609` "Rating / Usage", `IDT_BENCH_RATING_LABEL 7604` "Rating" | RTEXT | localized with the colon removed (`kLangIDs_RemoveColon`) |
| Compressing group | `IDG_BENCH_COMPRESSING 7602` "Compressing"; rows `IDT_BENCH_CURRENT 7606` "Current" (`IDT_BENCH_COMPRESS_SIZE1 170`, `_USAGE1 114`, `_SPEED1 110`, `_RPU1 116`, `_RATING1 112`) and `IDT_BENCH_RESULTING 7607` "Resulting" (`171`, `115`, `111`, `117`, `113`) | RTEXT values | filled by `PrintBenchRes` (`:1139-1170`) from `CSyncData` (`k_Ids_Enc_1`/`k_Ids_Enc` `:801-814`): size in KB/MB, usage in %, speed in KB/s, ratings in MIPS |
| Decompressing group | `IDG_BENCH_DECOMPRESSING 7603`; rows `IDT_BENCH_CURRENT2 7656` / `IDT_BENCH_RESULTING2 7657` (texts copied from 7606/7607) with `172/122/118/124/120` and `173/123/119/125/121` | | `k_Ids_Dec_1`/`k_Ids_Dec` (`:815-828`) |
| Error | `IDT_BENCH_ERROR_MESSAGE 161` | RTEXT | worker error text (`OnMessage` `:1172-1238`: thread errors, `HResultToMessage`, decoding/CRC errors) |
| Total rating group | `IDG_BENCH_TOTAL_RATING 7605` "Total Rating" with `IDT_BENCH_TOTAL_USAGE_VAL 133`, `IDT_BENCH_TOTAL_RPU_VAL 131`, `IDT_BENCH_TOTAL_RATING_VAL 130` | RTEXT | printed once the run finished (`k_Ids_Tot` `:829-835`, encode + decode results combined) |
| CPU / version / features / system | `IDT_BENCH_CPU 106` (CPU name), `IDT_BENCH_VER 105` (`"7-Zip " MY_VERSION_CPU`), `IDT_BENCH_CPU_FEATURE 109` (OS info + CPU features), `IDT_BENCH_SYS1 107` / `IDT_BENCH_SYS2 108` (`GetSysInfo`) | static | set once in `OnInit` (`:495-514`) |
| Log | `IDT_BENCH_LOG 160` | LTEXT `SS_LEFTNOWORDWRAP \| SS_NOPREFIX` (140 du right column) | frequency lines + `Compr Decompr Total   CPU` header + one line per pass (`AddRatingsLine`, `:1091-1121`) with ` : <pass number>`, `...` when older passes were dropped (`kRatingVector_NumBundlesMax = 20`), then `-------------` and the final averages (`UpdateGui` `:1249-1389`) |
| "Elapsed time:" / "Passes:" | `IDT_BENCH_ELAPSED 3900` / `IDT_BENCH_ELAPSED_VAL 140` (`PrintTime` `:990-1025`), `IDT_BENCH_PASSES 7610` / `IDT_BENCH_PASSES_VAL 142` (`<finished> /`), `IDC_BENCH_NUM_PASSES 143` | `MY_COMBO` | pass-count items `1, 2, 5, 10, 20, 50, … 10000000` (`:609-633`), initial = `-mm` `NumPasses_Limit` (added as an extra item when not in the list); the worker stops after that many passes; change → restart |

Behaviour: `StartBenchmark` (`:857-920`) clears all value fields to `"..."` (`kProcessingString`), checks memory, copies dictionary/threads/passes into `CBenchProgressSync`, starts `_timer` and the `CThreadBenchmark` thread (`Process` `:1600+` runs `Bench()` from `7zip/UI/Common/Bench.cpp` with `CBenchCallback`/`CBenchCallback2`/`CFreqCallback` implementations that fill `Sync`); `OnTimer` (`:1240-1247`) → `UpdateGui`; thread completion posts a message handled in `OnMessage` (`:1172-1238`) which restarts when `NeedRestart` or closes when `ExitWasAsked_in_GUI`. `TotalMode` (`IDD_BENCH_TOTAL`): a read-only fixed-pitch multi-line edit `IDE_BENCH2_EDIT 100` (`:463-479`) receives the console-style text produced by `CBenchCallback2::Print` (all methods, `-mm=*`), `NormalizeSize(true)` on init; the dictionary/threads/passes combos and buttons are the same.

### 4.27 Hash results — `GUI/HashGUI.cpp`

No dialog resource of its own: results are shown in the generic `CListViewDialog` (§4.11). `ShowHashResults(hb, hwnd)` (`HashGUI.cpp:330-335`) → `AddHashBundleRes(pairs, hb)` (`:179-231`) builds name/value pairs: `IDS_PROP_NUM_ERRORS` (only when errors), then either `IDS_PROP_NAME` = the file name (single file, no dirs) or `IDS_PROP_NAME` = `hb.MainName` (when set) + `IDS_PROP_FOLDERS` (when > 0) + `IDS_PROP_FILES`, then `IDS_PROP_SIZE`, and `IDS_PROP_NUM_ALT_STREAMS` + `IDS_PROP_ALT_STREAMS_SIZE` (when > 0); per hasher: for a single file one row `<Method>` = hex digest, otherwise `IDS_CHECKSUM_CRC_DATA` "CRC checksum for data:" and `IDS_CHECKSUM_CRC_DATA_NAMES` "CRC checksum for data and names:" with `CRC` replaced by the method name and the colon removed (`AddHashResString` `:167-177`), plus `IDS_CHECKSUM_CRC_STREAMS_NAMES` "CRC checksum for streams and names:" when alternate streams were hashed. `ShowHashResults(pairs, hwnd)` (`:310-328`): 2-column list, `Title = IDS_CHECKSUM_INFORMATION` "Checksum information", `DeleteIsAllowed = true`, `SelectFirst = false`. The text form `AddHashBundleRes(UString&, hb)` (`:233-254`, `name: value` lines, plus `IDS_MESSAGE_NO_ERRORS` "There are no errors" when there were neither errors nor hashers — i.e. after testing a hash file) is used for message boxes / the FM.

`7zG h` path: `HashCalcGUI` (`:283-308`) runs `CHashCallbackGUI` (`:25-57`, a `CProgressThreadVirt` + `IHashCallbackUI`) in the progress dialog with title `IDS_CHECKSUM_CALCULATING` "Checksum calculating..." (`MainAddTitle`), status `IDS_SCANNING` "Scanning..." while enumerating (`:77-82`), scan/open errors added to the progress message list (`:89-93`, `:139-147`); `AfterLastFile` (`:256-271`) stores the pairs and `ProcessWasFinished_GuiVirt` (`:337-341`) shows the list dialog over the progress window. Strings live in `FileManager/resourceGui.rc:5-20`.

---

## 5. Settings persistence (registry → macOS `UserDefaults` mapping)

All keys are under `HKEY_CURRENT_USER\Software\7-Zip` (`kCUBasePath` in `RegistryUtils.cpp:16`, `kCuPrefix` in `ZipRegistry.cpp:23`; `ViewSettings.cpp:20` names `HKCU\Software\7-Zip\FM` `kCUBasePath`). Nothing is read from `HKLM` (the `SaveLmOption`/`ReadLmOption` helpers are commented out, `RegistryUtils.cpp:100-119`). Types: `REG_SZ` (string), `REG_DWORD` (`UInt32`, bool = 0/1 via `CKey::SetValue(bool)`), `REG_BINARY` (fixed layouts below), string lists = one `REG_BINARY` blob of `\0`-terminated UTF-16 strings (`CKey::SetValue_Strings` / `GetValue_Strings`, `Windows/Registry.cpp:424-470`). "bool pair" = `CBoolPair {Def, Val}`: `Def` is whether the value exists in the registry (`Key_Get_BoolPair`, `ZipRegistry.cpp:76-86`); `Key_Set_BoolPair_Delete_IfNotDef` (`:68-74`) deletes the value when `Def` is false. All `ZipRegistry.cpp` access is serialized by a global critical section (`CS_LOCK`). Benchmark and hash operations have **no** persisted settings (`7zG b`/`h` take everything from the command line).

### 5.1 `HKCU\Software\7-Zip` (`RegistryUtils.cpp`)

| Value | Type | Default | Reader / writer | Used by |
|---|---|---|---|---|
| `Lang` | string | absent/`""` = auto (`OpenDefaultLang()` picks the file matching the system language); `"-"` = built-in English; otherwise a file name without `.txt` (a path with a separator is used as-is) | `ReadRegLang` / `SaveRegLang` (`:58-59`), consumed by `ReloadLang` (`LangUtils.cpp:308-330`) | §4.9, §7 |
| `LargePages` | bool | `false` | `ReadLockMemoryEnable` / `SaveLockMemoryEnable` (`:170-171`) | `FM.cpp:514-518` (`EnablePrivilege_LockMemory` at startup when the risk level is 0), `CompressCall.cpp:102` (adds `-slp` to 7zG command lines), §4.19 |

### 5.2 `HKCU\Software\7-Zip\FM` (`RegistryUtils.cpp`, `ViewSettings.cpp`)

| Value | Type | Default | Reader / writer | Used by |
|---|---|---|---|---|
| `Viewer` | string | `""` → `<WindowsDir>\notepad.exe` | `ReadRegEditor(false)` / `SaveRegEditor(false)` (`RegistryUtils.cpp:61-62`) | F3 |
| `Editor` | string | `""` → notepad | `ReadRegEditor(true)` / `SaveRegEditor(true)` | F4, edit-in-archive |
| `Diff` | string | `""` (hides Diff) | `ReadRegDiff` / `SaveRegDiff` (`:64-65`) | `IDM_DIFF` |
| `7vc` | string | `""` (hides Ver* items) | `ReadReg_VerCtrlPath` (`:67`, read-only, no UI) | VerCtrl |
| `ShowDots` | bool | false | `CFmSettings::Load/Save` (`:121-168`, `SaveOption`/`ReadOption` = `REG_DWORD` 0/1) | `_showDots` |
| `ShowRealFileIcons` | bool | false | " | icon lookup |
| `FullRow` | bool | false | " | `LVS_EX_FULLROWSELECT` |
| `ShowGrid` | bool | false | " | `LVS_EX_GRIDLINES` |
| `SingleClick` | bool | false | " | `LVS_EX_ONECLICKACTIVATE \| TRACKSELECT` (also Browse / ListView dialogs) |
| `AlternativeSelection` | bool | false | " | `_mySelectMode` |
| `ShowSystemMenu` | bool | false | " | context menu System submenu |
| `FlatViewArc<N>` (N = panel index 0/1) | bool | false | `ReadFlatView` / `SaveFlatView` (`:173-190`) | panel flat mode |
| `Position` | binary 20 bytes: `Int32 left, top, right, bottom; UInt32 maximized` (LE) | none (system placement) | `CWindowInfo::Read/Save` (`ViewSettings.cpp:141-196`; blobs of the wrong size are ignored) | main window |
| `Panels` | binary 12 bytes: `UInt32 numPanels, currentPanel, splitterPos` | none (`panelInfoDefined = false` → 1 panel) | same | panels |
| `Toolbars` | UInt32 mask | `kDefaultToolbarMask = (1 << 31) \| 8 \| 4 \| 1` (`:218`; bit 31 = "defaults") | `ReadToolbarsMask` / `SaveToolbarsMask` (`:213-227`) | toolbars |
| `ListMode` | UInt32, one byte per panel (`Panels[i] & 0xFF` at bits `8·i`) | `CListMode::Init()` (Details) | `CListMode::Read/Save` (`:229-248`) | view mode |
| `PanelPath0`, `PanelPath1` | string (`kPanelPathValueName + index`) | absent | `ReadPanelPath` / `SavePanelPath` (`:250-273`) | start folders |
| `FolderHistory` | string list, trimmed to 100 (`CFolderHistory::Normalize`, `App.cpp:992-997`) | empty | `ReadFolderHistory` / `SaveFolderHistory` (`:292-295`, `SaveStringList` `:275`) | Folders History |
| `FolderShortcuts` | string list, index = favorite slot 0-9 (`CFastFolders::SetString` grows the list, `AppState.h:10-24`) | empty | `ReadFastFolders` / `SaveFastFolders` (`:297-300`) | Favorites |
| `CopyHistory` | string list, max 20 (`App.cpp:753-757`, newest first via `AddUniqueStringToHeadOfList` `:307-315`) | empty | `ReadCopyHistory` / `SaveCopyHistory` (`:302-305`) | Copy dialog |

`ShowDeleted` (`kShowDeletedFiles`) and `Underline` exist only as comments (`RegistryUtils.cpp:33`, `:41`, `:191-194`) — not persisted.

### 5.3 `HKCU\Software\7-Zip\FM\Columns\<FolderTypeID>` (`ViewSettings.cpp:52-136`, `CListViewInfo`)

One `REG_BINARY` value per folder type ID (value name = the ID, e.g. `FSFolder`, `FSDrives`, `RootFolder`, `NetFolder`, `AltStreamsFolder`, `7-Zip.7z`, `7-Zip.zip`, …). Layout (little-endian `UInt32`): `version = kListViewVersion 1`, `SortID` (PROPID), `Ascending` (0/1), `count`, then `count` × `{PropID, IsVisible, Width}` (`kListViewHeaderSize = 12`, `kColumnInfoSize = 12`). `Read` (`:80-136`) ignores blobs with another version or an inconsistent size. Saved by `CPanel::SaveListViewInfo` (`PanelItems.cpp:1322`) from `CPanel::InitColumns` (`:98`, before columns are rebuilt for a new folder type) and `CPanel::OnDestroy` (`Panel.cpp:598-602`).

### 5.4 `HKCU\Software\7-Zip\Extraction` and `\Compression` (`7zip/UI/Common/ZipRegistry.cpp`)

`NExtract::CInfo` (`:88-198`): `Load()` (`:140-175`) defaults `PathMode = kCurPaths`, `OverwriteMode = kAsk`, `SplitDest.Val = true`; `Save()` (`:103-122`).

| Key / value | Type | Default | Notes |
|---|---|---|---|
| `Extraction\ExtractMode` | UInt32 (`NPathMode`, accepted ≤ `kAbsPaths`) | absent | written only when `PathMode_Force` (the user changed it, §4.25); present → `PathMode_Force = true` on load |
| `Extraction\OverwriteMode` | UInt32 (`NOverwriteMode`, accepted ≤ `kRenameExisting`) | absent | written only when `OverwriteMode_Force`; present → `OverwriteMode_Force = true` |
| `Extraction\ShowPassword` | bool pair | false | `Read_ShowPassword` (`:177-186`) / `Save_ShowPassword` (`:124-130`) also used by the Password dialog (§4.16) |
| `Extraction\PathHistory` | string list (max 16, `ExtractDialog.cpp:91`) | empty | rewritten on every Save (`RecurseDeleteKey` + `SetValue_Strings`) |
| `Extraction\SplitDest` | bool pair | **true** (`Key_Get_BoolPair_true`) | sub-folder checkbox (§4.25) |
| `Extraction\ElimDup` | bool pair | absent (dialog treats absent as true) | |
| `Extraction\Security` | bool pair | absent | restore NT security |
| `Extraction\MemLimit` | UInt32 GB | absent = `0`/`-1` → no limit | `Read_LimitGB` (`:188-197`) / `Save_LimitGB` (`:132-138`); §4.12, §4.19 |

`NCompression::CInfo` (`:200-375`): `Load()` (`:307-373`) defaults `Level = 5`, `ArcType = "7z"`, `ShowPassword = false`, `EncryptHeaders = false`; `Save()` (`:255-305`) rewrites the whole `Options` subtree.

| Key / value | Type | Default | Notes |
|---|---|---|---|
| `Compression\ArcHistory` | string list (max 20, `CompressDialog.cpp:86`) | empty | |
| `Compression\Archiver` | string | `"7z"` | last format name (`ArcType`) |
| `Compression\Level` | UInt32 | 5 | last global level (written, but the dialog reads the per-format `Level`) |
| `Compression\ShowPassword` | bool | false | |
| `Compression\EncryptHeaders` | bool | false | |
| `Compression\Security`, `AltStreams`, `HardLinks`, `SymLinks`, `PreserveATime` | bool pairs (deleted when not `Def`) | absent | NTFS/link options (§4.24) |
| `Compression\Options\<FormatID>\Method` | string | | non-auto method name, e.g. `LZMA2` |
| `…\Options` | string | | the "Parameters" text |
| `…\EncryptionMethod` | string | | `AES256` for zip when chosen (empty = default) |
| `…\MemUse64` (64-bit builds) / `MemUse32` (32-bit builds) | string | | `NN%` or `<N>M`/`<N>G` (`kMemUse`, `:248-252`) |
| `…\Level` | UInt32 | | per format |
| `…\Dictionary` | UInt32 | | bytes; `-1` = auto, `-2` = ≥ 4 GB (`CompressDialog.cpp:3256-3290`) |
| `…\Order` | UInt32 | | word size / PPMd order; `-1` = auto |
| `…\BlockSize` | UInt32 | | **log2** of the solid block size (`BlockLogSize`): 0 = non-solid, 64 = solid, `-1` = auto |
| `…\NumThreads` | UInt32 | | `-1` = auto |
| `…\TimePrec` | UInt32 | | `-1` = not set |
| `…\MTime`, `ATime`, `CTime`, `SetArcMTime` | bool pairs (deleted when not `Def`) | absent | |

`DictionaryChain` and a global `Compression\MemUse` (`MemLimit_Save/Load`) exist only in commented-out code (`:214`, `:459-487`).

### 5.5 `HKCU\Software\7-Zip\Options` (`ZipRegistry.cpp:488-599`, `NWorkDir::CInfo`, `CContextMenuInfo`)

| Value | Type | Default | Used by |
|---|---|---|---|
| `WorkDirType` | UInt32 (`NWorkDir::NMode`: 0 system, 1 current, 2 specified) | 0 (`SetDefault`, `ZipRegistry.h:176-181`); invalid or `kSpecified` without a path → 0 (`:517-534`) | archive update temp file location (`CWorkDirTempFile`, §4.8) |
| `WorkDirPath` | string | `""` | |
| `TempRemovableOnly` | bool | **true** | use the work dir only when the archive is on a removable drive |
| `CascadedMenu` | bool pair | true (`:564`, `Key_Get_BoolPair_true`) | shell menu |
| `MenuIcons` | bool pair | false | shell menu |
| `ElimDupExtract` | bool pair | true | `CContextMenuInfo.ElimDup` |
| `WriteZoneIdExtract` | UInt32 (`-1` unset / 0 no / 1 yes / 2 office) | `-1` | `CContextMenuInfo.WriteZone` |
| `ContextMenu` | UInt32 flags (`Explorer/ContextMenuFlags.h:8-24`: `kExtract 1<<0`, `kExtractHere 1<<1`, `kExtractTo 1<<2`, `kTest 1<<4`, `kOpen 1<<5`, `kOpenAs 1<<6`, `kCompress 1<<8`, `kCompressTo7z 1<<9`, `kCompressEmail 1<<10`, `kCompressTo7zEmail 1<<11`, `kCompressToZip 1<<12`, `kCompressToZipEmail 1<<13`, `kCRC_Cascaded 1<<30`, `kCRC 1<<31`) | absent → `Flags = (UInt32)-1` (all), `Flags_Def = false` (`:577-584`); written only when `Flags_Def` (`:557-558`) | which shell items appear (MenuPage list, §4.13) |

### 5.6 Shell registration written by the Options pages (Windows only)

* `HKCU|HKLM\Software\Classes\.<ext>` default = `7-Zip.<ext>`; `7-Zip.<ext>` default = `<EXT> Archive`, `\DefaultIcon` = `"<iconPath>,<index>"`, `\shell\open\command` = `"<7zFM.exe>" "%1"` (`RegistryAssociations.cpp:20-27`, `:93-160`; System page §4.21).
* `HKCU\Software\Classes\CLSID\{23170F69-40C1-278A-1000-000100020000}` (`k_Clsid`, "7-Zip Shell Extension", `InprocServer32` = `7-zip.dll` path, `ThreadingModel = Apartment`), `HKCU\Software\Classes\*\shellex\ContextMenuHandlers\7-Zip`, `Folder\…`, `Directory\…` (+ `Directory\shellex\DragDropHandlers\7-Zip`, `Drive\shellex\DragDropHandlers\7-Zip`) and the `Approved` list (`RegistryContextMenu.cpp:22-52`, `:120-190`; 7-Zip page §4.13, WOW64 variants via `KEY_WOW64_32KEY/64KEY`).
* `RegistryPlugins.cpp` reads no registry at all: it enumerates `7-zip.dll` and `Plugins\*.dll` next to the executable and calls their exported `GetPluginProperty` (`:20-128`).

### 5.7 Suggested `UserDefaults` mapping

Use the app's own domain (bundle ID) and keep the Windows value names as key suffixes so `01-fm-feature-inventory.md` stays auditable:

| Registry | `UserDefaults` key | Type | Notes |
|---|---|---|---|
| `Lang` | `Lang` | String | `""`/absent = auto, `"-"` = English, else lang file stem |
| `LargePages` | — | | drop (no macOS equivalent) |
| `FM\Viewer`, `Editor`, `Diff`, `7vc` | `FM.Viewer`, `FM.Editor`, `FM.Diff`, `FM.7vc` | String | command line with optional arguments; empty = default app |
| `FM\ShowDots` … `FM\ShowSystemMenu` | `FM.ShowDots`, `FM.ShowRealFileIcons`, `FM.FullRow`, `FM.ShowGrid`, `FM.SingleClick`, `FM.AlternativeSelection`, `FM.ShowSystemMenu` | Bool | defaults false |
| `FM\FlatViewArc0/1` | `FM.FlatViewArc0`, `FM.FlatViewArc1` | Bool | |
| `FM\Position` | — | | use `NSWindow.setFrameAutosaveName("7zFM")` (+ `FM.Maximized` Bool if zoom must be restored) |
| `FM\Panels` | `FM.NumPanels`, `FM.CurrentPanel`, `FM.SplitterPos` | Int | splitter as absolute pixels like Windows or a 0-1 ratio |
| `FM\Toolbars` | `FM.Toolbars` | Int (bit mask) | keep the bit layout (bit 31 = "defaults") |
| `FM\ListMode` | `FM.ListMode0`, `FM.ListMode1` | Int | 0 icons … 3 details |
| `FM\PanelPath0/1` | `FM.PanelPath0`, `FM.PanelPath1` | String | |
| `FM\FolderHistory`, `CopyHistory`, `FolderShortcuts` | `FM.FolderHistory` (≤ 100), `FM.CopyHistory` (≤ 20), `FM.FolderShortcuts` (10 slots, empty string = unset) | [String] | |
| `FM\Columns\<ID>` | `FM.Columns.<ID>` | Dictionary `{sortID: Int, ascending: Bool, columns: [{propID: Int, visible: Bool, width: Int}]}` | one entry per folder type ID |
| `Extraction\*` | `Extraction.ExtractMode`, `Extraction.OverwriteMode` (Int, absent = not forced), `Extraction.ShowPassword`, `Extraction.SplitDest`, `Extraction.ElimDup`, `Extraction.Security` (Bool, absent = `Def = false`), `Extraction.PathHistory` ([String] ≤ 16), `Extraction.MemLimit` (Int GB, absent = none) | | |
| `Compression\*` | `Compression.ArcHistory` ([String] ≤ 20), `Compression.Archiver` (String), `Compression.Level` (Int), `Compression.ShowPassword`, `Compression.EncryptHeaders` (Bool), `Compression.Security/AltStreams/HardLinks/SymLinks/PreserveATime` (Bool, absent = not set) | | |
| `Compression\Options\<Format>\*` | `Compression.Options.<Format>` | Dictionary `{Method, Options, EncryptionMethod, MemUse: String; Level, Dictionary, Order, BlockSize, NumThreads, TimePrec: Int; MTime, ATime, CTime, SetArcMTime: Bool?}` | keep `-1`/`-2` sentinels and the log2 `BlockSize` so `CompressDialog.cpp` logic can be ported verbatim; one `MemUse` key (macOS is 64-bit only) |
| `Options\WorkDirType/Path/TempRemovableOnly` | `Options.WorkDirType` (Int), `Options.WorkDirPath` (String), `Options.TempRemovableOnly` (Bool, default true) | | |
| `Options\CascadedMenu`, `MenuIcons`, `ElimDupExtract`, `WriteZoneIdExtract`, `ContextMenu` | `Options.CascadedMenu`, `Options.MenuIcons`, `Options.ElimDupExtract` (Bool, defaults true/false/true), `Options.WriteZoneIdExtract` (Int, map 1/2 to `com.apple.quarantine` handling), `Options.ContextMenu` (Int mask, absent = all) | | consumed by the Finder Sync / Quick Action extensions through an app group |

Everything that is a `CBoolPair` on Windows must stay tri-state (absent / false / true), because absent means "use the handler's default" for the `-m` switches and "not forced" for the extraction modes. Settings shared with the extensions (`Options.*`, `Compression.*`, `Extraction.*`) belong in the app-group suite, the rest in the standard suite.

---
