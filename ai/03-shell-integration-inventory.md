# 03 — Windows shell integration inventory and macOS/Finder mapping

Scope: everything 7-Zip 26.03 does to integrate with the Windows shell (Explorer context
menu, drag/drop handler, file associations, the `7zG.exe` GUI launcher contract, installer
registrations), documented from source so that the macOS port can reproduce each behaviour
through Finder. All paths are relative to the repository root; `file:line` references point
at the 26.03 sources on the `macos` branch.

Sources read: `CPP/7zip/UI/Explorer/*` (ContextMenu.cpp/.h, ContextMenuFlags.h,
RegistryContextMenu.cpp, DllExportsExplorer.cpp, MyExplorerCommand.h, MyMessages.cpp,
resource*.rc, 7-zip.dll.manifest, makefile), `CPP/7zip/UI/GUI/GUI.cpp`, `UpdateGUI.cpp`,
`ExtractGUI.cpp`, `HashGUI.cpp`, `BenchmarkDialog.cpp` (entry points only),
`CPP/7zip/UI/Common/CompressCall.cpp/.h`, `CompressCall2.cpp`, `ArchiveCommandLine.cpp/.h`,
`ArchiveName.cpp`, `Update.cpp` (e-mail path), `Extract.cpp` (output-dir rules),
`ZipRegistry.cpp` (`CContextMenuInfo`), `OpenArchive.cpp` (`-t` open-type grammar),
`CPP/7zip/UI/FileManager/RegistryAssociations.cpp/.h`, `SystemPage.cpp/.h/.rc`,
`MenuPage.cpp/.h/.rc`, `MenuPage2.rc`, `RegistryUtils.cpp`, `FilePlugins.cpp`,
`PanelDrag.cpp`, `PanelMenu.cpp` (7zFM re-use of the menu class), `FM.cpp` (7zFM argv),
`CPP/7zip/UI/Agent/ArchiveFolderOpen.cpp` (icon table), `CPP/Windows/Shell.cpp`
(data-object readers), `CPP/7zip/Bundles/Format7zF/resource.rc` (7z.dll icons + extension
table), `CPP/7zip/Archive/**` (`REGISTER_ARC*` extension strings), `DOC/7zip.wxs`.

---

## 1. Explorer context menu (`7-zip.dll`)

### 1.1 Hosting and registration

| Item | Value | Source |
|---|---|---|
| Binary | `7-zip.dll` (x64) and `7-zip32.dll` (WOW64 copy on x64 installs) | `CPP/7zip/UI/Explorer/makefile:1`, `DOC/7zip.wxs:196-218` |
| COM CLSID | `{23170F69-40C1-278A-1000-000100020000}`, name "7-Zip Shell Extension", `ThreadingModel=Apartment` | `DllExportsExplorer.cpp:43-53`, `RegistryContextMenu.cpp:20-23`, `:157-192` |
| Exports | `DllCanUnloadNow`, `DllGetClassObject`, `DllRegisterServer`, `DllUnregisterServer` | `Explorer.def:5-9`, `DllExportsExplorer.cpp:164-268` |
| Interfaces | `IContextMenu` + `IShellExtInit` (classic menu, Win7-10 and Win11 "Show more options"), `IExplorerCommand` + `IEnumExplorerCommand` (Win11 modern menu) | `ContextMenu.h:28-70` |
| Handler keys (HKCR) | `*\shellex\ContextMenuHandlers\7-Zip`, `Folder\shellex\ContextMenuHandlers\7-Zip`, `Directory\shellex\ContextMenuHandlers\7-Zip` (context menu); `Directory\shellex\DragDropHandlers\7-Zip`, `Drive\shellex\DragDropHandlers\7-Zip` (right-drag menu). Table `k_shellex_Statuses` = `{ {*, Folder, Directory, -Drive}, {-*, -Folder, Directory, Drive} }` | `RegistryContextMenu.cpp:28-48`, `:204-220`; installer duplicates at `DOC/7zip.wxs:140-168` |
| Approval | `HKLM\Software\Microsoft\Windows\CurrentVersion\Shell Extensions\Approved` value `{CLSID}="7-Zip Shell Extension"` | `RegistryContextMenu.cpp:187-191`, `DOC/7zip.wxs:170-175` |
| Enable/disable UI | 7zFM Options > "7-Zip" page, checkboxes "Integrate 7-Zip to shell context menu" (+ a second one for the other bitness DLL, labelled "(32-bit)"/"(64-bit)") calling `SetContextMenuHandler`/`CheckContextMenuHandler` | `MenuPage2.rc:9-10`, `MenuPage.cpp:132-181`, `:303-317` |
| Manifest | ComCtl32 v6 dependency only | `7-zip.dll.manifest` |
| Resources | Strings `IDS_CONTEXT_*` (2320-2330), `IDS_SELECT_FILES` (3015), bitmap `IDB_MENU_LOGO` (190, `MenuLogo.bmp`), icon `IDI_ICON` = `FM.ico` | `resource.h`, `resource2.rc`, `resource.rc:10` |

Language: all labels go through `LangString()` (`Z7_LANG` is defined for the DLL,
`makefile:3-4`) so the `.txt` language files override the English strings below.

### 1.2 Selection input

`IShellExtInit::Initialize` (`ContextMenu.cpp:201-250`):

* `pidlFolder != NULL` only for the **drag-drop handler** case (user right-dragged items onto a
  folder/drive). The folder path is taken from the PIDL, `\\?\` prefix removed, normalised with a
  trailing separator, and `_dropMode = true` (`:212-231`).
* The selection is read from the `IDataObject` as `CF_HDROP` first, falling back to
  `"Shell IDList Array"` (`CFSTR_SHELLIDLIST`) → `_fileNames` (`:238`;
  `CPP/Windows/Shell.cpp:350-363`).
* `"File Attributes Array"` is read into `_attribs.FirstDirIndex` = index of the first selected
  item that is a directory, or -1 (`:240-241`; `Shell.cpp:378-425`). This is how "is a folder
  selected?" is decided without stat'ing every item.
* Explorer ≥ Win7 passes at most 16 items to `Initialize/QueryContextMenu`; when the user
  invokes an item Explorer re-creates the object with the full selection and matches by the
  **displayed string** (comment `:137-162`). Consequences: `needReduce` when
  `_fileNames.Size() >= 16` (`:716-727`), and generated archive names are shown as
  `<base>_` (trailing underscore) so the label is identical in both passes (`:889-904`); the
  real name is recomputed at invoke time (`:1305-1323`, `:1370-1378`).
* Only the first item is stat'ed (`fi0`, `:679-709`); a missing first item throws and no menu is
  produced (`:702-704`). Device paths (`\\.\`) are special-cased (`:686-698`).

### 1.3 Per-user options (`CContextMenuInfo`)

Stored under `HKCU\Software\7-Zip\Options` (`CPP/7zip/UI/Common/ZipRegistry.cpp:23-25`,
`:488`, `:540-599`), edited in 7zFM Options > "7-Zip" page (`MenuPage2.rc`, `MenuPage.cpp`):

| Registry value | Default | UI label (`MenuPage2.rc`) | Effect |
|---|---|---|---|
| `CascadedMenu` (bool) | true | "Cascaded context menu" | Items go inside one "7-Zip" submenu (`ContextMenu.cpp:652-666`, `:1013-1021`); otherwise a separator + flat items are inserted at `indexMenu` (`:667-675`, `:1022-1026`). |
| `MenuIcons` (bool) | false | "Icons in context menu" | Every item gets `MenuLogo.bmp` as `hbmpUnchecked` (`:639-646`, `:378-396`). |
| `ElimDupExtract` (bool) | true | "Eliminate duplication of root folder" | Adds `-spe` to the **Extract to "<x>\"** command only (`:1287`). |
| `WriteZoneIdExtract` (DWORD) | -1 (unset) | "Propagate Zone.Id stream:" combo: `* No`(0) / `Yes`(1) / `For Office files`(2) | Adds `-snz<N>` to every extract command (`:637`, `CompressCall.cpp:266-270`; combo `MenuPage.cpp:196-229`, `:337-342`). |
| `ContextMenu` (DWORD bitmask) | all bits set (`0xFFFFFFFF`) | "Context menu items:" check-list | `NContextMenuFlags` bits, see 1.4. The e-mail items are on by default (comment says they could be disabled, `ZipRegistry.cpp:575-583`). |

Check-list rows, in order (`MenuPage.cpp:49-71`, labels built at `:237-280`):
"Open archive", "Open archive >", "Extract files...", "Extract Here", "Extract to <Folder>",
"Test archive", "Add to archive...", "Add to <Archive>.7z", "Add to <Archive>.zip",
"Compress and email...", "Compress to <Archive>.7z and email",
"Compress to <Archive>.zip and email", "CRC SHA >", "7-Zip > CRC SHA >".

Flag bits (`CPP/7zip/UI/Explorer/ContextMenuFlags.h:8-24`):
`kExtract=1<<0`, `kExtractHere=1<<1`, `kExtractTo=1<<2`, `kTest=1<<4`, `kOpen=1<<5`,
`kOpenAs=1<<6`, `kCompress=1<<8`, `kCompressTo7z=1<<9`, `kCompressEmail=1<<10`,
`kCompressTo7zEmail=1<<11`, `kCompressToZip=1<<12`, `kCompressToZipEmail=1<<13`,
`kCRC_Cascaded=1<<30`, `kCRC=1<<31`.

### 1.4 Menu items — exact order, flags, conditions, verbs, generated command lines

`QueryContextMenu` (`ContextMenu.cpp:585-1176`) is a single pass; the order below is the order
of insertion. `flags` gating: the menu is only built for `CMF_NORMAL`, `CMF_VERBSONLY` or
`CMF_EXPLORE` (`:616-619`). `Shift`+right-click sets `CMF_EXTENDEDVERBS`, which *relaxes* the
extension filter for the extract group (`:797`, `:806`).

Notation: `<dir>` = directory of the first selected item with trailing `\` (`folderPrefix`,
`:707`), or the drop target folder in drop mode (`:831-832`, `:920-923`); `<spec>` = folder
name from 1.6; `<name>` = archive base name from 1.6; `MAP` = `#7zMap<rand>:<bytes>:7zEvent<rand>`
(1.5). Every generated command additionally gets ` -slp` when the FM option "Use large memory
pages" is on and the privilege risk level is 0 (`CompressCall.cpp:100-107`). All commands are
run as `<dir of 7-zip.dll>\7zG.exe <params>` with `CreateProcess` (`CompressCall.cpp:74-98`).

Block A — **single selected item that is a file (not a folder) and whose extension is not in
`kExtractExcludeExtensions`** (`:741-743`; list `:494-516`: 3gp aac ans ape asc asm asp aspx
avi awk bas bat bmp c cs cls clw cmd cpp csproj css ctl cxx def dep dlg dsp dsw eps f f77 f90
f95 fla flac frm gif h hpp hta htm html hxx ico idl inc ini inl java jpeg jpg js la lnk log mak
manifest wmv mov mp3 mp4 mpe mpeg mpg m4a ofr ogg pac pas pdf php php3 php4 php5 phptml pl pm
png ps py pyo ra rb rc reg rka rm rtf sed sh shn shtml sln sql srt swa tcl tex tiff tta txt vb
vcproj vbs mkv wav webm wma wv xml xsd xsl xslt). Note: there is **no signature sniffing** in
the menu; "looks like an archive" = "extension is not on the exclude list".

| # | Label (English) | Flag | Extra condition | Verb (`GetCommandString`) | Command executed on invoke |
|---|---|---|---|---|---|
| A1 | `Open archive` | `kOpen` | — | `SevenZipOpen` | `7zFM.exe "<file>"` (`:1264-1274`) |
| A2 | `Open archive >` (submenu) | `kOpenAs` | classic `IContextMenu` only (`hMenu != NULL`, `:755`) — omitted in the Win11 `IExplorerCommand` enumeration | popup verb `SevenZip.OpenWithType.`; children `SevenZip.Open.<type>` (`:775-776`) | child: `7zFM.exe "<file>" -t<type>` (`:1268-1272`) |

Children of A2, in order (`kOpenTypes`, `:523-534`, loop `:765-784`): if A1 is present the
first entry (`""` = plain "Open archive") is skipped; then `*`, `#`, `#:e`, `7z`, `zip`,
`cab`, `rar`. Meaning of the type strings (`CPP/7zip/UI/Common/OpenArchive.cpp:3591-3630`,
`:3563-3589`): `*` = try every format by signature ignoring the extension; `#` = open with the
binary "parser" only (find embedded archives; `CanReturnArc=false, CanReturnParser=true`);
`#:e` = parser with `EachPos=true` (report every candidate offset); a format name forces that
handler. 7zFM parses `7zFM.exe "<path>" -t<type>` at `CPP/7zip/UI/FileManager/FM.cpp:646-656`
(`g_MainPath`, `g_ArcFormat`).

Block B — **any non-empty selection** (`:794`). Sub-condition `needExtract` (`:799-824`):
no selected item is a directory (`fi0.IsDir()` or `_attribs.FirstDirIndex != -1`; when reduced
to 16 items only the first 16 attributes count), and — unless `CMF_EXTENDEDVERBS` — **every**
selected file name passes the exclude-list test. Multiple archives are allowed.

| # | Label | Flag | Condition | Verb | Command executed on invoke |
|---|---|---|---|---|---|
| B1 | `Extract files...` | `kExtract` | `needExtract` | `SevenZipExtract` | `7zG x -o"<dir><spec>\" [-snzN] -ad [-slp] -an -aiMAP` (dialog pre-filled with `<dir><spec>\`) |
| B2 | `Extract Here` | `kExtractHere` | `needExtract` | `SevenZipExtractHere` | `7zG x -o"<dir>" [-snzN] [-slp] -an -aiMAP` |
| B3 | `Extract to "<spec>\"` | `kExtractTo` | `needExtract` | `SevenZipExtractTo` | `7zG x -o"<dir><spec>\" [-spe] [-snzN] [-slp] -an -aiMAP` (`-spe` iff `ElimDupExtract`) |
| B4 | `Test archive` | `kTest` | `needExtract` | `SevenZipTest` | `7zG t [-slp] -an -aiMAP` |
| B5 | `Add to archive...` | `kCompress` | — | `SevenZipCompress` | `7zG a -iMAP -ad [-slp] -saa -- "<dir><name>"` |
| B6 | `Compress and email...` | `kCompressEmail` | not drop mode (`:931`) | `SevenZipCompressEmail` | `7zG a -iMAP -seml. -ad [-slp] -saa -- "<name>"` (no directory: archive is created in a temp dir, see 2.5) |
| B7 | `Add to "<name>.7z"` | `kCompressTo7z` | `<name>.7z` ≠ first item's own name (`:941-942`) | `SevenZipCompressTo7z` | `7zG a -iMAP -t7z [-slp] -sae -- "<dir><name>.7z"` |
| B8 | `Compress to "<name>.7z" and email` | `kCompressTo7zEmail` | not drop mode | `SevenZipCompressTo7zEmail` | `7zG a -iMAP -t7z -seml. [-slp] -sae -- "<name>.7z"` |
| B9 | `Add to "<name>.zip"` | `kCompressToZip` | `<name>.zip` ≠ first item's own name (`:974-975`) | `SevenZipCompressToZip` | `7zG a -iMAP -tzip [-slp] -sae -- "<dir><name>.zip"` |
| B10 | `Compress to "<name>.zip" and email` | `kCompressToZipEmail` | not drop mode | `SevenZipCompressToZipEmail` | `7zG a -iMAP -tzip -seml. [-slp] -sae -- "<name>.zip"` |

If `CascadedMenu` is on, A1..B10 live in a submenu titled **"7-Zip"** (popup verb `SevenZip`,
`:1013-1021`, `MyAddSubMenu` `:399-427`). Otherwise they are preceded by a separator and
inserted flat at `indexMenu` (`:667-675`).

Block C — **`CRC SHA >` submenu** (`:1030-1142`), shown for any selection (files, folders,
mixed) whenever `kCRC | kCRC_Cascaded` is set; placed **inside the 7-Zip submenu** iff
`CascadedMenu && kCRC_Cascaded`, else at top level right after the 7-Zip entry / flat items
(`:1047-1069`). Popup verb `SevenZip.Checksum`. Children (`g_HashCommands`, `:294-309`),
verbs and commands:

| # | Label | Internal id | Verb | Command |
|---|---|---|---|---|
| C1 | `CRC-32` | `kHash_CRC32` | `SevenZip.Checksum.Calc.CRC32` | `7zG h -scrcCRC32 [-slp] -iMAP` |
| C2 | `CRC-64` | `kHash_CRC64` | `…Calc.CRC64` | `7zG h -scrcCRC64 … -iMAP` |
| C3 | `XXH64` | `kHash_XXH64` | `…Calc.XXH64` | `7zG h -scrcXXH64 …` |
| C4 | `MD5` | `kHash_MD5` | `…Calc.MD5` | `7zG h -scrcMD5 …` |
| C5 | `SHA-1` | `kHash_SHA1` | `…Calc.SHA1` | `7zG h -scrcSHA1 …` |
| C6 | `SHA-256` | `kHash_SHA256` | `…Calc.SHA256` | `7zG h -scrcSHA256 …` |
| C7 | `SHA-384` | `kHash_SHA384` | `…Calc.SHA384` | `7zG h -scrcSHA384 …` |
| C8 | `SHA-512` | `kHash_SHA512` | `…Calc.SHA512` | `7zG h -scrcSHA512 …` |
| C9 | `SHA3-256` | `kHash_SHA3_256` | `…Calc.SHA3-256` | `7zG h -scrcSHA3-256 …` |
| C10 | `BLAKE2sp` | `kHash_BLAKE2SP` | `…Calc.BLAKE2sp` | `7zG h -scrcBLAKE2sp …` |
| C11 | `*` | `kHash_All` | `…Calc.*` | `7zG h -scrc* …` (all hashers) |
| — | separator (`:1088-1094`) | | | |
| C12 | `SHA-256 -> <hname>.sha256` | `kHash_Generate_SHA256` | `SevenZip.Checksum.Generate.SHA256` | `7zG a -iMAP -thash [-slp] -sae -- "<dir><hname>.sha256"` (`CalcChecksum` → `CompressFiles` with type `hash`, `CompressCall.cpp:299-312`) |
| C13 | `Test archive : Checksum` | `kHash_TestArc` | `SevenZip.Checksum.Test.Hash` | `7zG t -thash [-slp] -an -aiMAP` (`TestArchives(...,hashMode=true)`, `:278-289`) |

`<hname>` is `CreateArchiveName(..., isHash=true)` (keeps the file extension; uniqueness
checked against `.sha256`, `:1101-1116`, `ArchiveName.cpp:27-29`).

Invoke-side error handling (`InvokeCommandCommon`, `:1256-1396`): extract/test with a folder
in the selection → message box `IDS_SELECT_FILES` "You must select one or more files"
(`:1280-1284`); any exception → message box "Error" (`:1391-1394`); process-launch failure →
`ErrorMessageHRESULT` with the 7zG path (`CompressCall.cpp:83-89`). All message boxes are
suppressed by `g_DisableUserQuestions` (`MyMessages.cpp:16-20`).

`GetCommandString` (`:1420-1465`) returns the verb for both `GCS_VERB` and `GCS_HELPTEXT`, so
the items are scriptable by verb name (`InvokeCommand(lpVerb="SevenZipExtractHere")`).

### 1.5 Passing the file list: the `#map` mechanism

Explorer command lines are limited to ~32 K chars, so the selection is never put on the
command line. `CreateMap` (`CompressCall.cpp:121-184`) creates a named shared-memory section
`7zMap<uint32>` (UTF-16, first `wchar_t` = 0 as a format marker, then NUL-terminated names)
and a named manual-reset event `7zEvent<uint32>`; the switch text becomes
`-i#7zMapNNN:<bytes>:7zEventNNN` (files) or `-an -ai#…` (archives) (`:43-44`, `:158-166`).
The parent waits for either process exit or the event (`Call7zGui`, `:91-96`). 7zG parses `#`
in `AddSwitchWildcardsToCensor` → `ParseMapWithPaths` (`ArchiveCommandLine.cpp:829-840`,
`:651-703`) and sets the event in the `CEventSetEnd` destructor (`:636-647`) so the parent can
release the mapping while 7zG keeps running. Error strings: "Incorrect Map command",
"Unsupported Map data size", "Cannot open mapping", "MapViewOfFile error", "Unsupported Map
data", "Map data error". Alternatives already supported by the parser: `-i@listfile`
(`kFileListID '@'`, `:250`, `:831`) and `-i!name` (`kImmediateNameID '!'`, `:246`, `:829`).
Wildcard interpretation of the passed names is on (`ISWITCH_NO_WILDCARD_POSTFIX` is empty; a
`w-` postfix would disable it, `CompressCall.cpp:36-38`).

### 1.6 Naming rules

**Extract-to folder** (`GetSubFolderNameForExtract`, `ContextMenu.cpp:447-470`), single
selection only; multi-selection uses the literal `*` (`:834-837`) which 7zG replaces by each
archive's default name because `OutDirMode` defaults to `k_ReplaceAsterisk`
(`CPP/7zip/UI/Common/Extract.h:53`, `Extract.cpp:56-77`):

1. No dot in the name → `name~` (e.g. `README` → `README~`).
2. Strip the last extension; trim trailing spaces.
3. If the remainder has another extension and either (`ext == 001` and inner ext ∈ {7z, bz2,
   gz, rar, zip}) or (`ext == rar` and inner ext ∈ {part001, part01, part1}) → strip the inner
   extension too (`foo.7z.001` → `foo`, `foo.part1.rar` → `foo`). `foo.tar.gz` → `foo.tar`.
4. `Get_Correct_FsFile_Name` (illegal chars → `_`, empty → `_`,
   `CPP/7zip/UI/Common/ExtractingFilePath.cpp:23-45`, `:182-194`).
5. Display: `ReduceString` truncates the label to 64 chars with ` ... ` in the middle and
   escapes `&` (`:472-492`).

**Eliminate duplication of root folder** (`-spe`, `Extract.cpp:83-97`): when the archive has a
single root folder whose name equals the last path component of `-o`, extraction happens to the
parent, so `foo.zip` containing `foo/…` yields `<dir>\foo\…` and not `<dir>\foo\foo\…`. The
same checkbox exists in the Extract dialog (`IDX_EXTRACT_ELIM_DUP`, `ExtractDialog.cpp:182`).

**Archive name** (`CreateArchiveName`, `CPP/7zip/UI/Common/ArchiveName.cpp:32-176`):
single item → its name; for a *file* the extension is removed only when the name contains
exactly one dot (`a.txt` → `a`, `a.tar.gz` → `a.tar.gz`); folders keep their name; several
items → name of their common parent folder (drive root → drive letter), fallback `"Archive"`;
then `Get_Correct_FsFile_Name`. If the selection already contains `<name>.7z/.zip/.tar/.wim`
(hash mode: `.sha256`), the name becomes `<name>_<N>` with the smallest free N ≥ 2
(`:105-175`). In the ≥16-item Explorer case the label shows `<base>_` (1.2).

### 1.7 Drop-handler mode (right-drag onto a folder/drive)

Because the CLSID is also registered under `Directory\…\DragDropHandlers` and
`Drive\…\DragDropHandlers`, Explorer instantiates the same class with `pidlFolder` = target
folder when items are right-dragged. Differences (`_dropMode`): the extract commands use the
**target** folder as `<dir>` (`:831-832`), the compress commands create the archive in the
target folder (`:920-923`, `:946-949`, `:979-982`), and the three e-mail items are hidden
(`:931`, `:960`, `:993`).

### 1.8 Windows 11 modern menu (`IExplorerCommand`)

`GetTitle` on the root calls `LoadItems(psiItemArray)` which reads
`SIGDN_FILESYSPATH` for every item (`:1535-1562`), runs `QueryContextMenu(hMenu=NULL, ids
0..999, CMF_NORMAL)` and converts `_commandMap` into a tree of child `CZipContextMenu`
objects: root "7-Zip" (`ECF_HASSUBCOMMANDS`), the CRC root and Open root become nested
enumerators (`:1565-1628`, `:1729-1780`). `GetIcon` returns the path of `7-zip.dll`
(`:1664-1676`). `Invoke` reloads the full selection and calls `InvokeCommandCommon`
(`:1711-1726`). The "Open archive >" submenu is skipped in this mode (1.4, A2).

### 1.9 7zFM re-uses the same class in-process

`CPP/7zip/UI/FileManager/PanelMenu.cpp:805-828` instantiates `CZipContextMenu` directly,
fills `_fileNames`/`_attribs.FirstDirIndex`, calls `Init_For_7zFM()` and
`QueryContextMenu(menu, 0, kSevenZipStartMenuID, kSystemStartMenuID-1, CMF_EXPLORE
[|CMF_EXTENDEDVERBS])`. 7zFM is built with `Z7_EXTERNAL_CODECS` and links
`CompressCall.cpp` (`FileManager/makefile:3`, `:71`), so from 7zFM these commands also spawn
`7zG.exe`. `CompressCall2.cpp` (`#ifndef Z7_EXTERNAL_CODECS`, `:5`) is the in-process
variant used by single-binary bundles: it calls `UpdateGUI`/`ExtractGUI`/`HashCalcGUI`
directly with the same parameters (`:90-153`, `:156-247`, `:249-301`).

---

## 2. `7zG.exe` command interpretation

### 2.1 Process contract

* `WinMain` (`CPP/7zip/UI/GUI/GUI.cpp:408-494`): `InitCommonControls`, `OleInitialize`
  (taskbar progress), `LoadLangOneTime`, `My_SetDefaultDllDirectories`, then `Main2` inside a
  try/catch that maps exceptions to message boxes + exit codes (2.7).
* `Main2` (`:137-402`): `SplitCommandLine(GetCommandLineW())`, drops argv[0]; no arguments →
  message box "Specify command", exit 0 (`:146-150`). `CArcCmdLineParser::Parse1` then
  `g_DisableUserQuestions = options.YesToAll` (`-y` silences every error box) then `Parse2`.
* Codecs: `CREATE_CODECS_OBJECT`, `codecs->Load()`, `Codecs_AddHashArcHandler` (adds the
  pseudo-format "Hash" so `-thash` works, `CPP/7zip/UI/Common/HashCalc.cpp:2216-2231`).
  With `Z7_EXTERNAL_CODECS` a codec-load error string is shown (`:166-178`), and "7-Zip
  cannot find the code that works with archives." / "7-Zip cannot load module: <path>" is
  thrown when no formats are available (`:115`, `:182-196`).
* `-t<type>` is validated by `ParseOpenTypes` → `IDS_UNSUPPORTED_ARCHIVE_TYPE`, exit 2
  (`:198-203`); `-stx<type>` excluded types likewise (`:205-217`).

### 2.2 Commands and switches accepted

Commands (`ArchiveCommandLine.cpp:432-454`): single letter from `"audtexlbih"` → `a` add,
`u` update, `d` delete, `t` test, `e` extract (no paths), `x` extract full paths, `l` list,
`b` benchmark, `i` info, `h` hash; plus `rn` rename. 7zG dispatches only `b`, the extract
group (`t`,`x`,`e`), the update group (`a`,`u`,`d`,`rn`) and `h`; `l` and `i` throw
"Unsupported command" (`GUI.cpp:227-400`).

Switch table (`kSwitchForms`, `ArchiveCommandLine.cpp:278-367`; the parser is shared with
`7z.exe`, so console-only switches are accepted and ignored by 7zG):

| Switch | Parsed as | Relevance to the shell integration |
|---|---|---|
| `-?`, `-h`, `--help` | HelpMode | unused by 7zG |
| `-ba`, `-bd`, `-bt`, `-bb[N]`, `-bso/-bse/-bsp{0,1,2}` | console output control (`:1064-1107`) | accepted, no effect in the GUI |
| `-y` | YesToAll: suppresses message boxes, sets overwrite mode to "overwrite all" (`:1751-1755`) | not generated by the menu |
| `-ad` | `ShowDialog` (`:1571`) | **generated** for "Extract files..." / "Add to archive..." / "Compress and email..." |
| `-ao{a,s,u,t}` | overwrite mode, forced (`:1745-1750`) | not generated |
| `-t<type>` / `-stx<type>` | archive type / excluded types | `-t7z`, `-tzip`, `-thash` generated |
| `-m<prop>` | method properties | none generated (dialog fills them) |
| `-o<dir>` | output dir, separators normalised, trailing `\` added (`:1728-1735`) | **generated** |
| `-w[dir]` | working dir (`:978-985`) | not generated (dialog reads `NWorkDir` settings, `UpdateGUI.cpp:529-539`) |
| `-i…`, `-x…`, `-ai…`, `-ax…` | include/exclude with `r[-|0]`, `w[-]`, `m[-|2]` modifiers and `!`/`@`/`#` sources (`:707-850`) | `-i#`, `-ai#` **generated** |
| `-an` | no archive name argument (`:1530`) | **generated** with `-ai` |
| `-u…`, `-v<size>`, `-r[-|0]` | update rules, volumes, recursion | not generated |
| `-stm<hex>`, `-sfx[module]` | affinity, SFX | not generated |
| `-seml[.][addr]` | e-mail mode; leading `.` = delete after send (`:1798-1808`) | `-seml.` **generated** |
| `-scrc[method]` | hash methods (multi) (`:1431-1432`) | **generated** for `h`; also honoured for `x/t` (hash bundle, `GUI.cpp:275-283`) |
| `-shd<dir>`, `-smemx<size>` | hash dir, extract memory limit | not generated |
| `-si[name]`, `-so` | stdin/stdout | rejected combos (`:1816-1828`) |
| `-slp[…]` | large pages (`:1123-1253`) | **generated** conditionally |
| `-scs`, `-scc`, `-slt`, `-slf`, `-slsl`, `-slmu` | charsets / listing | list-only |
| `-ssp`, `-ssw`, `-sse`, `-ssc[-]` | preserve atime, share-for-write, stop-after-open-error, case sensitivity | not generated |
| `-sa{s,e,a}` | archive name mode smart/exact/add (`:223-235`, `:1543-1544`) | `-saa` / `-sae` **generated** |
| `-spm`, `-spd`, `-spe[-]`, `-spf[2]`, `-spo{d,c,r}` | slash-mark, disable wildcards, eliminate-dup, full paths, out-dir mode (`:1462-1466`, `:1736-1743`) | `-spe` **generated** |
| `-snh`, `-snld`, `-snl`, `-sni`, `-snoi`, `-snon`, `-snz[0-2]`, `-sns`, `-snr`, `-snc`, `-snt` | NT options (`:1580-1661`) | `-snz<N>` **generated** |
| `-sdel`, `-stl` | delete after compress, set archive mtime (`:1813-1814`) | dialog options |
| `-p[pwd]` | password (`:1565-1569`) | dialog |
| `--` | stop switch parsing (`kStopSwitchParsing`, `CompressCall.cpp:46`) | **generated** before the archive path |

`-sa` semantics (`CPP/7zip/UI/Common/Update.cpp:115-145`, `UpdateGUI.cpp:527`): `-saa`
(`k_ArcNameMode_Add`) appends the format's extension to whatever the user typed; `-sae`
(`Exact`) uses the path verbatim; default `-sas` (`Smart`) strips a matching extension and
re-adds it. Context menu: `-saa` for dialog items (user may retype the name), `-sae` for the
fixed `.7z/.zip/.sha256` names.

### 2.3 Dispatch (`GUI.cpp:227-402`)

* `b` → `Benchmark(props, iterations)` (`:227-243`) → `CBenchmarkDialog`
  (`BenchmarkDialog.cpp`); FM's Tools > Benchmark launches `7zG b [-mm=*] [-slp]`
  (`CompressCall.cpp:332-343`).
* `t`/`x`/`e` → `EnumerateDirItemsAndSort(options.arcCensor)` produces the sorted archive list
  (`:285-304`); `ecs->MultiArcMode = count > 1` (`:306`); `ExtractGUI(...)` (`:308-319`).
  Non-OK result with a message already shown → exit 2; `E_ABORT` → 255; `!ecs->IsOK()` → 2.
* `a`/`u`/`d`/`rn` → `InitFormatIndex`/`SetArcPath` (else `IDS_UPDATE_NOT_SUPPORTED`, exit 2),
  `UpdateGUI(...)` (`:329-375`); failed files → exit 1 (`kWarning`).
* `h` → `HashCalcGUI(censor, HashOptions)` (`:376-396`).

### 2.4 Which dialogs appear

* **Extract** (`ExtractGUI.cpp:167-297`): if not test mode: `outputDir` = `-o` or the current
  directory; with `-ad` → `CExtractDialog` (fields: path, overwrite mode, path mode, "Eliminate
  duplication of root folder", NT security, password; single archive path shown when exactly
  one archive, `:203-248`); Cancel → `E_ABORT`. Then `CThreadExtracting` progress dialog
  titled `IDS_PROGRESS_EXTRACTING` / `IDS_PROGRESS_TESTING` (`:274`). Test mode ends with an
  OK box listing Archives / Packed Size / Folders / Files / Size / alt-streams / "There are no
  errors" (`:137-158`); with `-scrc` the results go to the hash list dialog instead
  (`:94-98`, `:131-136`). Multiple archives share one progress window (`MultiArcMode`).
* **Compress** (`UpdateGUI.cpp:543-605`): with `-ad` → `ShowDialog` (`:315-541`) builds
  `CCompressDialog`: format list = formats with `UpdateEnabled`, minus `KeepName` formats
  (gzip/bzip2/xz/zstd/lzma…) unless exactly one file is selected, minus hash formats unless
  forced by `-t`, `swfc` only for `.swf` (`:398-414`); archive path shown without extension
  (`:422`); update mode from the action set; `-m` `tm/tc/ta` props pre-parsed (`:88-105`);
  password from `-p`. On OK the dialog rewrites all options (level `x`, method `0`/`m`, dict
  `0d`/`d`/`mem`, `fb`/`o`, `em`, `he`, `s`, `mt`, `memuse`, `tm/tc/ta`, `tp`; SFX → `.exe`;
  volumes; working dir per `NWorkDir` settings, `:205-281`, `:460-539`). Without `-ad` the
  archive path is derived by `UpdateArchive` (`needSetPath`). Progress title
  `IDS_PROGRESS_COMPRESSING`, or `IDS_CHECKSUM_CALCULATING` when the target format is the
  hash handler (`:579-586`).
* **Hash** (`HashGUI.cpp:283-307`): progress thread; on completion (unless `E_ABORT`)
  `ShowHashResults` → `CListViewDialog` with 2 columns, title `IDS_CHECKSUM_INFORMATION`,
  rows deletable (`:310-327`, `:337-341`). Rows (`AddHashBundleRes`, `:179-230`): errors,
  `Name` (single file) or `Name`/`Folders`/`Files`, `Size`, alt-stream counts, then per hasher
  either `<Hasher>` = value (single file) or `"<Hasher> for data:"`, `"<Hasher> for data and
  names:"`, and streams variants (strings `IDS_CHECKSUM_CRC_DATA*` with "CRC" replaced by the
  hasher name).
* **Benchmark**: `CBenchmarkDialog` (`BenchmarkDialog.cpp:256-353`, `:449-639`).

### 2.5 `-seml` e-mail (MAPI)

`UpdateOptions.EMailMode/EMailAddress/EMailRemoveAfter` (`ArchiveCommandLine.cpp:1798-1808`).
In `UpdateArchive` (`CPP/7zip/UI/Common/Update.cpp`): e-mail + stdout is rejected
(`:1134-1135`), volumes are rejected in e-mail mode (`:1164`); with `EMailRemoveAfter` the
archive is created inside a fresh `%TEMP%\7zE*.tmp` directory that is deleted on return
(`:49`, `:1445-1453`) — this is why the context menu passes no directory for e-mail items.
After the archive is written (`:1704-1849`): `LoadLibrary("Mapi32.dll")` (error "cannot load
Mapi32.dll"), `MAPISendMailW` (fallback ANSI `MAPISendMail`, error "7-Zip cannot find
MAPISendMail function"), one `MapiFileDesc` per created archive, optional `MAPI_TO` recipient,
flag `MAPI_DIALOG` → the default mail client opens a compose window synchronously; 7zG waits,
then deletes the temp dir.

### 2.6 `-scrc` hashing

`h -scrc<M> -i#map` → `HashCalcGUI` (2.4). `x/t … -scrc<M>` → hashes are computed on the
extracted data and shown in the same list dialog (`ExtractGUI.cpp:81-98`, `:129-136`).
`-thash` selects the pseudo-format registered by `Codecs_AddHashArcHandler` (flags
`kKeepName|kStartOpen|kByExtOnlyOpen|kHashHandler`, extensions `sha256 sha512 sha384 sha224
sha512-224 sha512-256 sha3-* sha1 sha2 sha3 sha …`, `HashCalc.cpp:2225-2250`): `a -thash`
writes a checksum file, `t -thash` verifies a checksum file against the files it lists.

### 2.7 Errors and exit codes

`CPP/7zip/UI/Common/ExitCode.h:10-21`: `0` success, `1` warning (some files failed,
`GUI.cpp:369-374`), `2` fatal, `7` user error (command-line syntax, `CMessagePathException`),
`8` memory, `255` user break (`E_ABORT`, silent). Mapping in `WinMain` (`GUI.cpp:447-493`):
`CNewException` → `IDS_MEM_ERROR` box + 8; `CMessagePathException` → box with message + path +
7; `CSystemException(E_ABORT)` → 255 with no box; other `CSystemException` →
`HResultToMessage` box + 2 (`E_OUTOFMEMORY` → 8); string exceptions → box + 2; `int` →
"Error: N" + 2; anything else → "Unknown error" + 2. All boxes: caption "7-Zip",
`MB_ICONERROR`, suppressed by `-y`.

---

## 3. File associations

### 3.1 The extension list and icon indices

The association list is **not** derived from the format registrations; it is the string
resource `100` of `7z.dll` (`CPP/7zip/Bundles/Format7zF/resource.rc:36-39`), parsed by
`CCodecIcons::LoadIcons` (`CPP/7zip/UI/Agent/ArchiveFolderOpen.cpp:14-45`, `ext:index` pairs)
and exposed through `IFolderManager::GetExtensions`/`GetIconPath`
(`ArchiveFolderOpen.cpp:164-215`; icon path = `7z.dll` for external-codec builds or the
executable itself for internal builds). `CExtDatabase::Read` (`FilePlugins.cpp:19-78`) turns
it into the list shown on the System page. Exactly 39 extensions in 26.03:

| Ext | Icon | Ext | Icon | Ext | Icon | Ext | Icon |
|---|---|---|---|---|---|---|---|
| 7z | 0 (7z.ico) | tar | 13 (tar.ico) | zst | 26 (zst.ico) | vhd | 20 (vhd.ico) |
| zip | 1 (zip.ico) | cpio | 12 (cpio.ico) | tzst | 26 | vhdx | 20 |
| rar | 3 (rar.ico) | bz2 | 2 (bz2.ico) | z | 5 (z.ico) | wim | 15 (wim.ico) |
| 001 | 9 (split.ico) | bzip2 | 2 | taz | 5 | swm | 15 |
| cab | 7 (cab.ico) | tbz2 | 2 | lzh | 6 (lzh.ico) | esd | 15 |
| iso | 8 (iso.ico) | tbz | 2 | lha | 6 | fat | 21 (fat.ico) |
| xz | 23 (xz.ico) | gz | 14 (gz.ico) | rpm | 10 (rpm.ico) | ntfs | 22 (ntfs.ico) |
| txz | 23 | gzip | 14 | deb | 11 (deb.ico) | dmg | 17 (dmg.ico) |
| lzma | 16 (lzma.ico) | tgz | 14 | arj | 4 (arj.ico) | hfs | 18 (hfs.ico) |
| | | tpz | 14 | | | xar | 19 (xar.ico) |
| | | | | | | squashfs | 24 (squashfs.ico) |
| | | | | | | apfs | 25 (apfs.ico) |

Icon resources 0–26 map to `CPP/7zip/Archive/Icons/*.ico` (`resource.rc:6-32`). Not in the
list (so never offered for association) although openable: `lz`, `tlz`, `zipx`, `jar`, `pkg`,
`xip`, `msi`, `chm`, `nsis`, `exe`, etc.

### 3.2 Formats 7-Zip can open (for "Open With" / document types)

From `REGISTER_ARC*` in `CPP/7zip/Archive/**` (name → extensions; `+` marks writable):
7z+ (`7z`), zip+ (`zip z01 zipx jar xpi odt ods docx xlsx epub ipa apk appx`), Rar/Rar5
(`rar r00`), Split (`001`), Cab (`cab`), Iso (`iso img`), Udf (`udf iso img`), xz+ (`xz txz`),
lzma/lzma86 (`lzma`, `lzma86`), tar+ (`tar ova`), Cpio (`cpio`), bzip2+ (`bz2 bzip2 tbz2 tbz`),
gzip+ (`gz gzip tgz tpz apk`), zstd+ (`zst tzst`), Z (`z taz`), Lzh (`lzh lha`), Rpm (`rpm`),
Ar (`ar a deb udeb lib`), Arj (`arj`), VHD (`vhd`), VHDX (`vhdx avhdx`), wim+ (`wim swm esd
ppkg`), FAT (`fat img`), NTFS (`ntfs img`), Dmg (`dmg`), HFS (`hfs hfsx`), Xar (`xar pkg xip`),
SquashFS (`squashfs`), APFS (`apfs img`), Chm (`chm chi chq chw`), Hxs (`hxs hxi hxr hxq hxw
lit`), Compound (`msi msp msm doc xls ppt aaf`), Nsis (`nsis`), PE (`exe dll sys`), COFF
(`obj`), TE (`te`), ELF (`elf`), MachO (`macho`), Mub (`mub`), MBR (`mbr`), GPT (`gpt mbr`),
APM (`apm`), LP (`lpimg img`), AVB (`avb img`), Sparse (`simg img`), Ext (`ext ext2 ext3 ext4
img`), QCOW (`qcow qcow2 qcow2c`), VDI (`vdi`), VMDK (`vmdk`), LVM (`lvm`), CramFS (`cramfs`),
FLV (`flv`), SWF/SWFc (`swf`), MsLZ (`mslz`), IHex (`ihex`), Base64 (`b64`), UEFIc (`scap`),
UEFIf (`uefif`), Ppmd (`pmd`), plus the "Hash" pseudo-format (3.1/2.6).

### 3.3 Registry shape written by "Associate 7-Zip with"

`NRegistryAssoc::AddShellExtensionInfo(hkey, ext, title, cmd, iconPath, iconIndex)`
(`RegistryAssociations.cpp:105-165`), rooted at `HKEY_CURRENT_USER\Software\Classes` or
`HKEY_LOCAL_MACHINE\Software\Classes` (`:34-45`):

```
[<root>\.<ext>]                       @ = "7-Zip.<ext>"      (or "7-Zip.*" when iconIndex < 0)
[<root>\7-Zip.<ext>]                  @ = "<EXT> Archive"    (SystemPage.cpp:304-305)
[<root>\7-Zip.<ext>\DefaultIcon]      @ = "<path\7z.dll>,<iconIndex>"
[<root>\7-Zip.<ext>\shell]            @ = ""
[<root>\7-Zip.<ext>\shell\open]       @ = ""
[<root>\7-Zip.<ext>\shell\open\command] @ = "\"<dir>\7zFM.exe\" \"%1\""   (SystemPage.cpp:269-275)
```

`DeleteShellExtensionInfo` removes `.<ext>` and `7-Zip.<ext>` recursively (`:93-103`).
`CShellExtInfo::ReadFromRegistry` reads the current ProgID and parses `DefaultIcon`
`path,index` (`:47-86`); `IsIt7Zip` = ProgID starts with `7-Zip.` (`:88-91`). After applying,
`SHChangeNotify(SHCNE_ASSOCCHANGED)` (`SystemPage.cpp:324-326`).

### 3.4 The Options > System page

`SystemPage.rc:7-16`: static "Associate 7-Zip with:", two `+` push-buttons
(`IDB_SYSTEM_CURRENT`, `IDB_SYSTEM_ALL`), and a report list view with columns **File type** |
**<Windows user name>** (HKCU; fallback "Current User") | **All users** (HKLM)
(`SystemPage.cpp:174-222`; `NUM_EXT_GROUPS = 2`, `SystemPage.h:76-80`). Each row carries the
format icon (extracted from `7z.dll` via `ExtractIconExW`, `:56-84`). Cell text per state
(`SystemPage.h:13-53`, `SystemPage.cpp:41-53`): empty = no association, `7-Zip` = this
install, `[7-Zip]` = a 7-Zip ProgID pointing at a different icon path (another install),
otherwise the foreign ProgID name. Interaction: click a cell to toggle it (`:375-396`);
`+` buttons / Enter toggle the selection or all rows (`:345-360`, `:419-432`); keyboard
Space (current user), `+ - / *` (all users), Ctrl+A / numpad-* select all (`:435-472`).
Toggle logic (`:100-153`): cycles Clear → 7-Zip → Clear; rows owned by another program go to
"Other" (kept) unless the whole group is being set. Apply (`:278-336`) writes/deletes per
row and group, shows a system error box on failure. "Plugin selection": `CExtPlugins.Plugins`
only ever contains the built-in `CArchiveFolderManager` — plugin enumeration is commented out
(`FilePlugins.cpp:21-41`), so there is no plugin chooser in 26.03. Help topic
`FM/options.htm#system` (`:39`).

---

## 4. Drag and drop (`CPP/7zip/UI/FileManager/PanelDrag.cpp`)

### 4.1 Dragging out of 7zFM into Explorer (source side)

`CPanel::OnDrag` (`:1500-1802`):

1. Right-button drags are only allowed from file-system folders (`:1516-1519`).
2. FS folder as source → `dirPrefix` = real path, `UsePreGlobal=false` (`:1550-1555`).
3. Archive as source → create `%TEMP%\7zE<rand>.tmp` (`kTempDirPrefix "7zE"`, `:76`,
   `CTempDir`, `:1558-1563`), `IsTempFiles=true`, `UsePreGlobal=true`, and
   `m_hGlobal_HDROP_Pre` = `[tempdir]` (`:1564-1571`).
4. `m_hGlobal_HDROP_Final` = `tempdir\Get_Correct_FsFile_Name(item)` for every selected item
   (`:1582-1616`) — the names of files that **do not exist yet**.
5. `DoDragDrop(dataObject, dropSource, DROPEFFECT_MOVE|DROPEFFECT_COPY)` (`:1688-1690`).
6. On `DRAGDROP_S_DROP`, if a 7-Zip target sent back a destination (`DestDirPrefix_FromTarget`)
   or asked the source to do the work, the panel extracts/copies directly to it via `CopyTo`
   (`:1728-1770`); errors go to a messages dialog / error box; selection is cleared on success
   (`:1786-1801`). The temp dir is deleted when `tempDirectory` goes out of scope, so targets
   that keep running after `DoDragDrop` returns lose the files (comment `:1663-1665`).

`CDataObject` (`:475-660`, `:842-1215`) offers `CF_HDROP` (two variants: "Pre" = temp dir only,
"Final" = the real item list, because some apps reject non-existent paths, `:459-471`) plus
private formats registered with `RegisterClipboardFormat`: `7-Zip::SetTargetFolder`,
`7-Zip::SetTransfer`, `7-Zip::GetTransfer` (`:78-82`, `:595-597`) and the standard
`Performed DropEffect`, `Logical Performed DropEffect`, `DropDescription`, `TargetCLSID`…
(`:599-605`). **Delayed extraction**: `GetData(CF_HDROP)` first runs
`CopyFromPanelTo_Folder()` when `NeedCall_Copy` is set (`:1092-1093`, `:630-658`), i.e. the
archive is extracted to the temp folder only on the first `GetData` after the drop is
confirmed. `CDropSource::QueryContinueDrag` (`:1245-1370`) does the switch: once the button is
released and the target's last effect is not `NONE`, it flips `UsePreGlobal=false` (real
names), and for temp-file drags either sets `DoNotProcessInTarget` (target is 7-Zip and told
us the folder → the source extracts straight there) or `NeedCall_Copy=true` (target is
Explorer → the next `GetData` extracts into the temp dir, Explorer then copies/moves from it)
(`:1334-1367`). The `GetTransfer` structure sent to the target carries flags such as
`TempFiles`, `WaitFinish`, `NamesAreParent`, `NeedExtractOpToFs`, `Left/RightButton`
(`:162-190`, `:1114-1149`). Explorer's move vs copy result handling and why 7-Zip never
deletes originals itself are documented at `:1694-1722`.

### 4.2 Accepting drops from Explorer (target side)

`CApp::CreateDragTarget` creates one `CDropTarget` for the app window (`:2983-2988`;
`SrcPanelIndex`/`TargetPanelIndex` bookkeeping `:2990-3006`). `DragEnter` reads the paths
(`CF_HDROP` or ID list, `:2383-2387`, `:2404`), positions the cursor on a panel/sub-folder
(`PositionCursor`, `:1927-2007`), sends the target folder and transfer info back to the source
(`SendToSource_*`, `:2222-2380`) and computes the effect (`GetEffect`, `:2148-2184`).
`Drop` (`:2505-2768`): right-button → popup menu `Drag_OnContextMenu` (`:2904-2979`) with
`Copy`/`Move` (to FS folder), `Copy to <Archive>` (into an open archive), `Add to archive`
(create new), `Cancel` (`NDragMenu`, `:340-355`); left-button → app window = `k_AddToArc`,
panel = copy/move into FS folder or `k_Copy_ToArc` into the open archive after a Yes/No box
(`IDS_WANT_TO_COPY_FILES`, `:2611-2626`). `CPanel::CompressDropFiles` (`:2817-2900`):
`createNewArchive` → `CompressFiles(folder, CreateArchiveName(files), "", addExtension=true,
files, email=false, showDialog=true, waitFinish)` i.e. `7zG a -i#map -ad -saa -- "<dir>\<name>"`
(the "Add to archive" dialog); if the sources live in `%TEMP%` the archive goes to
`ROOT_FS_FOLDER` instead (`:2841-2846`); waiting is negotiated through the transfer flags
(`:2855-2867`). Otherwise `CopyFsItems` / `CopyFromNoAsk` (`:2877-2899`). The target always
reports `CFSTR_PERFORMEDDROPEFFECT = DROPEFFECT_COPY` (never MOVE) so Explorer never deletes
the originals (`:2708-2731`, `:2748-2763`).

Related temp-dir users: F5/F6 copy between two non-FS panels goes through a `7zE` temp dir
(`App.cpp:40`, `:769-776`); opening an archived item in an external app uses `7zO`
(`PanelItemOpen.cpp:48`, `:1507-1508`, stale `7zO*.tmp` cleanup `:1823`).

---

## 5. Installer-level integration (`DOC/7zip.wxs`, WiX MSI)

* Files (`:188-252`): `7zFM.exe` (Start Menu shortcut "7-Zip File Manager" in
  `Programs\7-Zip`, `:189-191`, `:356-358`), `7-zip.dll` (+ `7-zip32.dll` on x64) with the
  `CLSID\{…}\InprocServer32` registrations, `7zG.exe`, `7z.dll`, `7z.exe`, `7z.sfx`,
  `7zCon.sfx`, `descript.ion`, `History.txt`, `License.txt`, `readme.txt`, `7-zip.chm`
  (Start Menu shortcut "7-Zip Help", `:248-252`), `Lang\*.txt` as a separate feature
  "Localization files" (`:254-350`, `:389-392`).
* Registry (`:129-186`): `HKCU\Software\7-Zip` `Path` and `Path32|64` = install dir;
  same under `HKLM` when privileged; `HKCR *|Directory|Folder\shellex\ContextMenuHandlers\7-Zip`,
  `HKCR Directory|Drive\shellex\DragDropHandlers\7-Zip` = CLSID; `HKLM …\Shell
  Extensions\Approved` (privileged); `HKLM …\App Paths\7zFM.exe` default + `Path`
  (privileged). `INSTALLDIR` is discovered from those `Path` values (`:109-114`).
* Upgrade: `UpgradeCode 23170F69-40C1-270<cpu>-0000-000004000000`, major upgrade from 4.38
  (`:9`, `:100-103`), `RemoveExistingProducts` after `InstallValidate` (`:398-400`),
  `ALLUSERS=2` (`:116`), `MSIRMSHUTDOWN=2` (`:107`).
* **Not** done by the MSI: no `SendTo` shortcut, no `PATH` environment change, no file
  associations (those are per-user via 7zFM Options > System), no custom uninstall actions —
  uninstall is plain MSI component removal (shellex keys are removed as components; the
  `SetContextMenuHandler(false)` code path deliberately leaves `shellex` keys alone because
  they are shared between bitnesses, `RegistryContextMenu.cpp:203-204`).

---

## 6. macOS mapping proposal

### 6.1 Mechanism evaluation

| Mechanism | What it gives | Constraints |
|---|---|---|
| **Finder Sync extension** (`NSExtensionPointIdentifier = com.apple.FinderSync`, `FIFinderSync` subclass) | Contextual menu items (with submenus) for selected items in monitored folders, sidebar/background menus, a toolbar button with its own menu, badges. `FIFinderSyncController.default().selectedItemURLs()` / `targetedURL()` give the selection. | Must be sandboxed; runs in `FinderSyncExtensionHost`; menu only for items inside `directoryURLs`; must be enabled by the user (System Settings > General > Login Items & Extensions > **File Providers** on 15.2+, or `pluginkit -e use -i <id>`); Apple: "not intended as a general tool for modifying the Finder's user interface"; no API to read file contents or spawn processes. |
| **Action extension shown as Finder Quick Action** (`com.apple.ui-services` extension point; `NSExtensionServiceAllowsFinderPreviewItem = YES`, `NSExtensionServiceFinderPreviewIconName`, `NSExtensionServiceFinderPreviewLabel`, `NSExtensionActivationRule` with `NSExtensionActivationSupportsFileWithMaxCount`) | Entries in Finder's **Quick Actions** submenu of the contextual menu, the Preview pane and Touch Bar; receives `NSExtensionItem` attachments (`NSItemProvider` file URLs). | One flat entry per appex (no submenu; a "7-Zip: Extract Here" / "7-Zip: Add to archive…" pair is realistic, one appex each); sandboxed; user toggles under Login Items & Extensions > **Finder** ("Actions"); appears only after Launch Services registered the app (first launch). Works independently of Finder Sync. |
| **`NSServices` in Info.plist** (`NSMessage`, `NSPortName`, `NSSendFileTypes` = UTIs, `NSRequiredContext`, `NSKeyEquivalent`) | Items in Finder contextual menu > **Services** (and app menu > Services), optional global keyboard shortcut. Delivered to the running host app via `NSApp.servicesProvider` (`handle(pasteboard:userData:error:)`) — the host reads the URLs from the pasteboard, so **no sandbox hop**. | Buried in a submenu; user can toggle in System Settings > Keyboard > Shortcuts > Services; needs the app to have been launched / `pbs -update`. |
| **`CFBundleDocumentTypes` + `UTImportedTypeDeclarations`/`UTExportedTypeDeclarations`** | Double-click / Open With / drag-onto-Dock-icon → `application(_:open:)`; icons per type (`CFBundleTypeIconFile`). | Use existing system UTIs where they exist (`org.7-zip.7-zip-archive`, `public.zip-archive`, `com.rarlab.rar-archive`, `public.tar-archive`, `org.gnu.gnu-zip-archive`, `public.bzip2-archive`, `org.tukaani.xz-archive`, `public.cpio-archive`, `public.iso-image`, `com.apple.disk-image`, `com.microsoft.cab`, `public.deb-archive`? — verify with `mdls`/`UTType(filenameExtension:)`); import the rest (`org.7-zip.arj-archive`, `…lzh`, `…lzma`, `…zstd`, `…wim`, `…001-split`, `…vhd`, `…squashfs`, `…apfs`, `…xar` etc.) with `UTTypeTagSpecification.public.filename-extension`. |
| **`NSWorkspace.shared.setDefaultApplication(at:toOpen:)`** (12.0+) / `urlForApplication(toOpen: UTType)` | Implements the "Associate 7-Zip with" page per UTType; no user prompt for file types. | Per-user only (no "All users" column); Launch Services caches — call `LSRegisterURL` after install. |
| **Extension → app command passing** | (a) `NSWorkspace.shared.openApplication(at: helperURL, configuration:)` with `OpenConfiguration.arguments` and `createsNewApplicationInstance = true` → a fresh helper process gets a real `argv` (exact 7zG model); (b) custom URL scheme (`x-7zip://…`) via `NSWorkspace.open(URL)` → single running app instance receives it in `application(_:open:)`; (c) `NSXPCConnection` to a `launchd` Mach service or an XPC service bundled in the extension; (d) Apple Event `odoc` via `open(urls, withApplicationAt:)` carries file access grants to a sandboxed target but no command word. | (a) and (b) are callable from a sandboxed extension; (c) needs a Mach-lookup entitlement/app group; for an ad-hoc local build without a Team ID avoid app groups (macOS 15+ validates group prefixes). |
| **`NSSharingService(named: .composeEmail)`** `.perform(withItems: [archiveURL])` | Opens Mail compose with the archive attached — the analogue of `MAPISendMail(MAPI_DIALOG)`. | Asynchronous: there is no "mail sent" callback, so `-seml.` (delete after send) cannot be honoured exactly; keep the archive in the app's temp dir and purge on next launch. |
| **`NSFilePromiseProvider`** (+ `NSFilePromiseProviderDelegate`) | Drag items out of the app to Finder; Finder tells you the destination directory and you write the files there on demand — the same "delayed extraction" 7zFM implements with the temp-dir/`GetData` trick, but without a temp copy. | One provider per dragged item, `fileType` must be a UTI; cannot express "move" (extract-to-Finder is always a copy, which matches 7-Zip's behaviour of never deleting originals). |
| **Dropping into the app** | Register `.fileURL` on the outline/table view; `NSDraggingInfo.draggingPasteboard` gives URLs. | No right-button drag on macOS: map the Windows popup (`Copy`/`Move`/`Copy to archive`/`Add to archive`) to modifier keys (⌥ = copy, ⌘ = move) or a sheet; drop on the window background = "Add to archive…". |
| **Apple Events / AppleScript / Shortcuts** | Optional: `AppleScript` `open` handler already comes with document types; a Shortcuts App Intent would replace Quick Actions on 13+. | Nice-to-have, not required for parity. |

### 6.2 Per-item mapping

| Windows item | macOS mechanism (recommended) | Notes |
|---|---|---|
| "7-Zip" cascaded submenu / flat mode | Finder Sync `menu(for: .contextualMenuForItems)` returning an `NSMenu` whose single item "7-Zip" has a submenu (cascaded) or whose items are added directly (flat) — user option kept in `UserDefaults` shared with the app (App Group) or duplicated into the extension's own defaults via the URL scheme handshake. | Finder ignores key equivalents in extension menus; `NSMenuItem.image` is best-effort. |
| Open archive / Open archive > (`*`, `#`, `#:e`, 7z, zip, cab, rar) | `openApplication(at: 7-Zip.app, configuration: [urls] + arguments ["-t<type>"])`; the app's `application(_:open:)` and argv both funnel into the same "open with format" entry point. | Keep the same open-type grammar (`OpenArchive.cpp:3563-3630`). |
| Extract files… / Extract Here / Extract to "<x>/" / Test archive | Extension computes `<dir>`, `<spec>` (port `GetSubFolderNameForExtract` and `CreateArchiveName` verbatim — they are pure string code) and launches the helper with `x -o"<dir><spec>/" [-spe] -ad -an -ai@<listfile>` etc. | `-snz` → propagate `com.apple.quarantine` xattr from the archive to extracted files (the macOS analogue of Zone.Id; Archive Utility does this). |
| Add to archive… / Add to "<name>.7z" / ".zip" | Helper with `a -i@<listfile> [-t7z|-tzip] [-ad] (-saa|-sae) -- "<dir><name>"`. | `Get_Correct_FsFile_Name` must use the POSIX rules already in `ExtractingFilePath.cpp` (`/` and NUL only). |
| Compress and email… / Compress to "<name>.7z|.zip" and email | Helper with `-seml.` → after `UpdateArchive` returns, call `NSSharingService(named: .composeEmail)?.perform(withItems:)` on the main thread instead of MAPI. | Archive is created in `NSTemporaryDirectory()/7zE-<uuid>/`; deleted by a janitor on next launch. |
| CRC SHA > (CRC-32 … BLAKE2sp, `*`, SHA-256 -> file.sha256, Test archive : Checksum) | Same submenu inside the Finder Sync menu; helper `h -scrc<M> -i@list`, `a -thash -sae -- "<dir><hname>.sha256"`, `t -thash -an -ai@list`; results in an `NSTableView` sheet mirroring `CListViewDialog` (2 columns, deletable rows, copyable). | |
| Drop-handler mode (right-drag onto a folder) | No Finder equivalent. Closest: dragging onto the 7-Zip Dock icon → `application(_:open:)` shows "Add to archive…"; Quick Action "Compress with 7-Zip". | Document as intentionally dropped. |
| Icons in context menu | `NSMenuItem.image` (16 pt template of the app icon). | |
| Eliminate duplication of root folder | Port `Extract.cpp:83-97` unchanged; expose the toggle in Settings and in the Extract sheet. | |
| Propagate Zone.Id | Quarantine-xattr propagation switch `-snz{0,1,2}`; "For Office files" → apply only to `com.microsoft.*`/`org.openxmlformats.*` UTIs. | |
| 16-item reduction / `<base>_` labels | Not needed: `selectedItemURLs()` is complete. | |
| Options > System (Associate) | Settings pane listing the 39 extensions with the format icon (`Archive/Icons/*.ico` converted to `.icns`/PNG), one "This user" column; toggling calls `NSWorkspace.setDefaultApplication(at:toOpen: UTType)`; current handler shown via `urlForApplication(toOpen:)` and `LSCopyDefaultRoleHandlerForContentType` display name. | No HKLM/"All users" column. Provide `defaults`-style CLI parity via `open -a`? Optional. |
| Options > 7-Zip (menu page) | Settings pane: "Enable Finder integration" (opens `x-apple.systempreferences:com.apple.LoginItems-Settings.extension` and, for CLI users, prints the `pluginkit -e use -i` line), Cascaded, Icons, ElimDup, Quarantine combo, item check-list persisted to shared defaults. | The extension must re-read the flags on every `menu(for:)`; it cannot be told "settings changed" by Finder. |
| Dragging out of 7zFM into Explorer | `NSFilePromiseProvider` per selected item; delegate extracts the item into the URL Finder supplies (use `CopyTo`-equivalent code path). For drags into another 7-Zip window, add a private pasteboard type carrying archive path + item indices so the target can call the in-process extractor directly (replaces `7-Zip::GetTransfer`). | `NSPasteboard.PasteboardType.fileURL` promises are what Finder expects; also add `.fileURL` for FS-folder sources. |
| Dropping Explorer items into 7zFM | `registerForDraggedTypes([.fileURL])`; `draggingUpdated` decides copy vs "add to archive" by target (panel background of an FS folder = copy/move; open archive = "Copy to archive" with confirmation; window title bar/toolbar = "Add to archive…"). | |
| `7zFM.exe "%1"` association command | `CFBundleDocumentTypes` → `application(_:open:)`; multiple files opened together should behave like Windows (one 7zFM per archive). | |
| Start Menu shortcuts, App Paths, Help `.chm` | Dock/Launchpad by virtue of the `.app`; help as an HTML bundle opened with `NSHelpManager` or a "7-Zip Help" web view; `HKCU\Software\7-Zip\Path` → not needed (`Bundle.main.bundleURL`). | |
| `7zG.exe` | A **helper app** `7-Zip.app/Contents/Helpers/7zG.app` (or the main executable in "7zG mode", see 6.4) that accepts the identical argv grammar. | |

### 6.3 Recommendation

1. **Finder Sync extension** (`7-Zip.app/Contents/PlugIns/FinderIntegration.appex`) for the
   full 7-Zip submenu on every selection, plus its toolbar button whose menu offers the same
   items for the current window's selection (the toolbar menu is available even outside
   monitored folders). Monitor `URL(fileURLWithPath: "/")` so `contextualMenuForItems` fires
   everywhere; implement `beginObservingDirectory`/`endObservingDirectory` and
   `requestBadgeIdentifier` as no-ops and never call `setBadgeImage` (badging under `/` would
   otherwise be evaluated for every visible item). Known limits of the `/` trick: items on
   File Provider domains (iCloud Drive, Dropbox/OneDrive on 12.1+) and some network volumes
   are not under `/` from Finder's point of view, so the menu does not appear there — add
   `/Volumes` and `~/Library/CloudStorage` to `directoryURLs`; when several extensions monitor
   overlapping folders Finder appends all of their menu items but shows at most one badge per
   item, so never badge; other Finder Sync products (Dropbox, Keka, Nextcloud) keep working,
   but document the overlap in the settings UI.
2. **Quick Actions (`com.apple.ui-services`) + `NSServices`** as the fallback that needs no
   Finder Sync enabling: two appexes ("Extract with 7-Zip" for archive UTIs, "Compress with
   7-Zip" for `public.item`) and matching `NSServices` entries ("7-Zip: Extract Here",
   "7-Zip: Add to archive…", "7-Zip: Checksum…"). Services hand the URLs straight to the
   running app, so they also serve as the path for users who refuse all extensions.
3. **Document types + Associate page** with `setDefaultApplication(at:toOpen:)`.
4. **`NSFilePromiseProvider`** for outgoing drags; `.fileURL` drops for incoming.
5. **`NSSharingService.composeEmail`** for the three e-mail items.

### 6.4 "7zG mode" (headless command runner)

* Entry point: `argv[1]` ∈ {`a`,`u`,`d`,`rn`,`x`,`e`,`t`,`h`,`b`} (`g_Commands`,
  `ArchiveCommandLine.cpp:432-454`) switches the process into 7zG mode: no document windows,
  only the Compress/Extract/Hash dialogs and the progress window, exit codes per
  `ExitCode.h`. Everything in `GUI.cpp:137-402` ports as-is (`CArcCmdLineParser` is already
  cross-platform — `MY_IS_TERMINAL` and `GetModuleDirPrefix` have non-Windows branches,
  `ArchiveCommandLine.cpp:104-106`, `:1875-1913`).
* Two ways to run it: (a) a nested helper bundle `Contents/Helpers/7zG.app`
  (`LSUIElement = YES`, `LSMultipleInstancesProhibited = NO`) launched by the extension with
  `NSWorkspace.OpenConfiguration.arguments` + `createsNewApplicationInstance = true` — one
  process per command, exactly like Windows, and the extension can `await` the launch error;
  (b) the main app receiving the same argv through the URL scheme
  `x-7zip:///run?argv=<base64 JSON array>` and dispatching onto a command queue with one
  progress window per command. Implement (a) as primary, (b) for Services/AppleScript.
* File list transport: `-i#7zMap…` depends on Win32 named sections; replace with
  `-i@<listfile>` written as UTF-8 (`-scsUTF-8`) into the caller's own temp dir
  (`NSTemporaryDirectory()` of the extension container is readable by an unsandboxed helper),
  or with positional paths after `--` plus `-spd` (disable wildcard parsing) — macOS `ARG_MAX`
  is 1 MiB, so the Windows 32 K limit does not apply. Delete the listfile in the helper's
  `CEventSetEnd` equivalent.
* Switch handling in the port: honour `-ad`, `-o`, `-spe`, `-saa/-sae`, `-t`, `-seml`,
  `-scrc`, `-y`, `-p`, `-m`, `-w`, `-x`, `-sse`, `-ssw`; ignore `-slp`, `-stm`, `-snz`
  (re-purpose as quarantine propagation), `-sni`, `-snoi/-snon` (or map to
  `com.apple.security.files…` ownership flags). Emit the identical error strings so the
  existing language files keep working.
* Sandbox/signing for local ad-hoc use: the extension **must** carry
  `com.apple.security.app-sandbox = true` (unsandboxed appexes are refused); the host and
  helper can stay unsandboxed (they then read any path, subject to TCC prompts for Desktop /
  Documents / Downloads / removable and network volumes — add
  `NSDesktopFolderUsageDescription`, `NSDocumentsFolderUsageDescription`,
  `NSDownloadsFolderUsageDescription`, `NSRemovableVolumesUsageDescription`,
  `NSNetworkVolumesUsageDescription`). Sign with `codesign --force --deep --sign - 7-Zip.app`
  (ad-hoc), matching `CFBundleIdentifier` prefixes (`org.7-zip.7-Zip`,
  `org.7-zip.7-Zip.FinderIntegration`), `NSExtensionPrincipalClass` = the `FIFinderSync`
  subclass, no App Group (a group not prefixed by a Team ID is rejected on 15+; use the
  URL-scheme/argv handshake and `UserDefaults(suiteName:)` inside the extension container
  written by the extension itself after the app pushes settings through `x-7zip:///settings`).
  Register/enable: `pluginkit -a /Applications/7-Zip.app/Contents/PlugIns/FinderIntegration.appex`,
  `pluginkit -e use -i org.7-zip.7-Zip.FinderIntegration`, verify with
  `pluginkit -m -p com.apple.FinderSync -v` (a `!` prefix means blocked/unloadable; a `+`
  means enabled); GUI path: System Settings > General > Login Items & Extensions > File
  Providers (15.2+; the Finder-Sync list was missing in 15.0/15.1 and only `pluginkit`
  worked), Quick Actions under the same pane's **Finder** entry, Services under Keyboard >
  Keyboard Shortcuts > Services. If Finder does not spawn `FinderSyncExtensionHost`, reset the
  Launch Services database (`lsregister -kill -r -domain local -domain user`) or test on a
  clean VM; MDM profiles that deny public extension points silently block the extension.
* If the host is ever sandboxed (App Store), the extension cannot mint security-scoped
  bookmarks for arbitrary selections; route the selection through
  `NSWorkspace.open(urls, withApplicationAt:)` (Launch Services grants the target access to
  those URLs) and pass the command word through the URL scheme in parallel.

---

## 7. Current status of the Finder extension points (researched September 2026)

* **Finder Sync is not deprecated but is de-emphasised.** Apple's own guide states "The best
  Finder Sync extensions support apps that sync the contents of a local folder with a remote
  data source. Finder Sync is not intended as a general tool for modifying the Finder's user
  interface", lists the capabilities (badges, contextual menus for items inside monitored
  folders, a toolbar button, sidebar menu), the `folderURLs`/`directoryURLs` registration and
  the four `FIMenuKind`s, and recommends XPC/shared defaults for talking to the containing app
  ([Apple, App Extension Programming Guide — Finder Sync](https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/Finder.html)).
* **macOS 15.0/15.1 removed the Finder Sync toggle from System Settings**; only `pluginkit`
  worked, and Apple's visible direction was File Provider, which "does not allow all the same
  functionality" ([Michael Tsai, Oct 2024](https://mjtsai.com/blog/2024/10/03/finder-sync-extensions-removed-from-system-settings-in-sequoia/);
  [Apple Developer Forums thread 756711](https://forums.developer.apple.com/forums/thread/756711?page=2);
  [FinderSyncer](https://github.com/wflixu/FinderSyncer)). **macOS 15.2 restored it** under
  General > Login Items & Extensions > **File Providers**, separate from the **Finder** entry
  that controls Quick Actions ([AppTyrant, May 2025](https://apptyrant.com/2025/05/09/how-to-enable-finder-extensions-on-macos-sequoia-15-2-and-newer/)).
* **Extension points on Sequoia**: `com.apple.ui-services` ("managed by the Finder, controlled
  in Actions settings"), `com.apple.FinderSync` (File Providers pane; example "Keka Finder
  Integration"), `com.apple.fileprovider-nonui` (not exposed)
  ([Eclectic Light, Apr 2025](https://eclecticlight.co/2025/04/23/an-overview-of-app-extensions-and-plugins-in-macos-sequoia/)).
* **macOS 26 (Tahoe)**: Finder Sync extensions still load on 26.x. A report that they "do not
  work on 26.1 ARM" was diagnosed by Apple DTS as MDM profiles denying all public extension
  points, not an OS regression; DTS nevertheless recommends Replicated File Provider for sync
  products ([Apple Developer Forums thread 806607, Nov–Dec 2025](https://developer.apple.com/forums/thread/806607)).
  A 26.3.1 load failure (`!` in `pluginkit`, `FinderSyncExtensionHost` not starting) was
  attributed by DTS to a corrupted Launch Services cache on the dev machine, with the advice to
  test on a clean VM ([thread 819937, Mar 2026](https://developer.apple.com/forums/thread/819937)).
  Take-away: keep Finder Sync as the primary integration but ship the Services/Quick Action
  fallback and a diagnostics page (`pluginkit -m -p com.apple.FinderSync -v` output).
* **Quick Actions**: the `NSExtensionServiceAllowsFinderPreviewItem`,
  `NSExtensionServiceFinderPreviewLabel`, `NSExtensionServiceFinderPreviewIconName`,
  `NSExtensionServiceAllowsTouchBarItem`, `NSExtensionServiceTouchBarLabel/IconName` keys
  inside `NSExtensionAttributes` make an Action extension appear in Finder's Quick Actions,
  Preview pane and Touch Bar; the keys were introduced with 10.14 and are still only partially
  documented ([Indie Stack, Sep 2018](https://indiestack.com/2018/09/finder-quick-actions/);
  [Apple, NSExtension Info.plist keys](https://developer.apple.com/documentation/bundleresources/information-property-list/nsextension)).
* **Sandbox reality**: a Finder Sync extension must be sandboxed or the system refuses to run
  it; `pluginkit -a <appex>` registers and `pluginkit -e use -i <id>` enables it
  ([theevilbit, Finder Sync plugins](https://theevilbit.github.io/beyond/beyond_0026/)).
  Security-scoped bookmarks do not transfer between an unsandboxed app and its sandboxed
  extension, and the extension cannot obtain access to arbitrary user-chosen folders by itself
  ([Apple Developer Forums, sandbox/bookmark threads](https://developer.apple.com/forums/thread/722054),
  [thread 120336](https://developer.apple.com/forums/thread/120336)) — hence the
  "pass URLs to the host/helper" design in 6.4.
