# `panel` scope report (branch `mac/panel`)

Everything the two file panels do: the four view modes and the columns, sorting, flat view,
navigation and the address bar, the selection commands and the key map, the status bar, the file
operations, the context menus, drag & drop and the clipboard, and the generic dialogs this scope
owns. Parity reference: `01-fm-feature-inventory.md` §1.2-§1.5, §2.1, §2.8, §2.9, §3 (all),
§9 #2, #9, #10, #12, #13, #14, #30; `01b-fm-dialogs-settings.md` §4.2, §4.4, §4.5, §4.6, §4.11,
§4.18, §5.2, §5.3. Public API for the other scopes: `Mac/docs/api/panel.md`.

## 1. What was implemented

| File | Contents |
|---|---|
| `Mac/App/Panel/PanelRow.swift` | `PanelRow` (name, prefix, isDeleted, isPackage, full path, per-PROPID cell text and sort keys) and `PanelSnapshot` — what the panel queue hands the main thread. Foundation only. |
| `Mac/App/Panel/PanelLogic.swift` | `PanelSorting` (`CompareItems2` + `SortItemsWithPropID`), `PanelMask` (`EnhancedMaskTest`, select-by-type rule), `PanelOperatedItems` (`Get_ItemIndices_Operated` / `OperSmart`), `PanelColumn`/`PanelColumnsModel` (`InitColumns` + the `CListViewInfo` layout). Foundation only; symlinked into the unit-test target. |
| `Mac/App/Panel/PanelViewController.swift` | Panel state and views, snapshot apply (`RefreshListCtrl`), the four view modes, columns and their persistence, sorting (with `IFolderCompare` on the panel queue), selection model incl. AlternativeSelection, status bar, settings/language observers, `runFolderOperation` (parks the panel queue while the shared runner owns the folder). |
| `Mac/App/Panel/PanelListViews.swift` | Details table data source/delegate and the `NSCollectionView` behind Large Icons / Small Icons / List. |
| `Mac/App/Panel/PanelTableView.swift` | List key entry point, header view (column menu), row view (AlternativeSelection pink, `kpidIsDeleted` red, FullRow off = name column only). |
| `Mac/App/Panel/PanelKeys.swift` | The key map of 01 §3.7 and every selection command of §3.6. |
| `Mac/App/Panel/PanelNavigation.swift` | `BindToPathAndRefresh`, parent/root/volumes, open item / open inside / nested archives, `kStartExtensions`, `IsVirus_Message`, address drop-down, folders history, favorites, the two-panel helpers, the password prompt. |
| `Mac/App/Panel/PanelOperations.swift` | Delete (Trash + permanent + confirmations 6100-6105), in-place rename, create folder/file, comment, Properties, calc-size, `CopyTo` / `CopyFrom` / `CopyFsItems`. |
| `Mac/App/Panel/PanelContextMenu.swift` | List context menu (7-Zip verbs → sibling scopes, System submenu, File items), column header menu, Quick Look. |
| `Mac/App/Panel/PanelDragDrop.swift` | Drag source (file URLs / `NSFilePromiseProvider`), drop target and effect rules, the Control-drag menu, "Add to archive…" from a window-background drop, clipboard copy/cut/paste. |
| `Mac/App/Panel/PanelFormat.swift`, `PanelIcons.swift` | Column alignment, the Copy dialog's item-info block, the icon rule (`GetSystemIconIndex` replacement) and the address-bar icon. |
| `Mac/App/MainWindow/MainWindowController.swift` | Panel delegate (Tab, F9, Alt+Up/Left/Right, Alt+F1/F2, F5/F6, bookmarks), `ActiveContext.register`, per-panel save incl. `SaveListViewInfo`, toolbar/menu enable rules, the window-background drop target. |
| `Mac/App/Commands/PanelCommands.swift` | `CApp::OnCopy` (F5/F6, Copy To…/Move To…, FS→archive, archive→archive through a `7zE` temp dir) and `OperationContextProviding`. |
| `Mac/App/Dialogs/` | `ComboDialog` (IDD_COMBO 98), `ListViewDialog` + `TextViewerDialog` (IDD_LISTVIEW 99, IDD_EDIT_DLG 94), `CopyMoveDialog` (IDD_COPY 96), `BrowseDialog` (IDD_BROWSE 95), `PropertiesDialog` (IDS_PROPERTIES 6600), `CommentDialog` (IDS_COMMENT 6400). |
| `Mac/Tests/SevenZipKitTests/PanelLogicTests.swift` | 18 unit tests: the sort comparator, mask matching, operated items, the column model and its persistence. |
| `Mac/Tests/UITests/PanelTests.swift` | 10 UI tests written against the `harness` helpers (they run after `mac/harness` is merged; see §5). |

Additive edits outside the scope's own files: `Mac/App/MainMenu.swift` (Edit > Copy/Cut/Paste with
the standard selectors, View > Back/Forward, two `MenuActions` entries), `Mac/docs/PROGRESS.md`
(own section), `Mac/docs/requests.md` (new rows only).

## 2. Mapping to the Windows behaviour

* **View modes** (§3.1): `SetListViewMode` 0-3, persisted per panel in `ListMode`, items and
  selection preserved across a switch. Details is an `NSTableView` with the folder's columns; the
  other three are an `NSCollectionView` (32 px icons / 16 px icons / `LVS_LIST` columns) laid over
  the table, so the table stays in the accessibility tree.
* **Columns** (§3.2, 01b §5.3): built from `GetPropertyInfo` with `kpidIsDir` skipped and
  `kpidName` first, merged with the persisted layout per folder type ID (`FSFolder`, `FSDrives`,
  `RootFolder`, `7-Zip.<type>`): order, visibility, width, sort ID and direction. Default widths
  160 / 100, default hidden set = `GetColumnVisible`, alignment per `GetColumnAlign`, names from
  lang `1000 + kpid`. Header click sorts, header drag reorders, both are saved on folder change and
  on exit; the header context menu toggles a column and grays Name.
* **Sorting** (§3.3): `..` first, directories before files except in No Sort, up to three rounds
  (`_sortID` → `kpidName` → `kpidPrefix`), `CompareFileNames_ForFolderList` for the path-like
  properties, `IFolderCompare` when the folder implements it (run on the panel queue), index as the
  final tie-break, and the five properties that start descending.
* **Flat view** (§3.4): independent disk/arc flags, `FlatViewArc<N>` persisted, `SetFlatMode` after
  every bind, the Prefix column appears, prefix is the third sort key.
* **History and favorites** (§3.5): `FolderHistory` (unique, newest first, 100) fed by every
  successful bind, the Folders History list dialog with Del, ten bookmark slots, `CopyHistory` (20)
  feeding the Copy dialog.
* **Selection** (§3.6): select/deselect by mask through the Combo dialog, select by type, select
  all/none/invert excluding `..`, `KillSelection` after copy and drag, the AlternativeSelection
  vector with its pink rows, and the operated-items rule everywhere.
* **Key map** (§3.7): the whole table, with Ctrl mapped to Command, the F-keys unchanged and
  Cmd+W closing the window. The exceptions are listed in §4.
* **Navigation** (§3.8, §3.9): `BindToPathAndRefresh` with a wildcard last component becoming the
  selection mask, parent/root/volumes, nested archives, `kStartExtensions`, the virus-name
  confirmation, `kMaxOpenItems`, Alt+Up / Alt+Left / Alt+Right, the breadcrumb drop-down, and the
  window title following the focused panel.
* **Copy / Move** (§3.10): source and destination panels, the preconditions, the destination
  proposal, the Copy dialog with its info block and history, rename-on-copy, `CreateComplexDir`,
  FS→FS and Arc→FS through `CopyTo`, FS→Arc through `CopyFrom`, Arc→Arc through a `7zE` temp dir,
  and the refresh/kill-selection/history on completion.
* **Item operations** (§3.11): delete (Trash without a question for file-system folders, the
  6100-6105 confirmations otherwise), in-place rename, create folder/file, the comment editor,
  the Properties list, and F3 / Space calculating a folder's size.
* **Context menus** (§2.8, §2.9): the 7-Zip verbs first (filtered by the `ContextMenu` mask and
  `kExtractExcludeExtensions`), the System submenu when `ShowSystemMenu` is on, then the File menu
  without Exit; the header menu for the columns.
* **Drag & drop and clipboard** (§3.15, §3.16): file URLs for file-system items, one
  `NSFilePromiseProvider` per archive item with extraction deferred to the drop, the target rules
  (folder row → sub-folder, `..` and the source's own folder refused), the effect rules
  (Option = copy, Command = move, otherwise move inside a volume), the confirmation before copying
  into an archive, drops from Finder, the Control-drag menu, and Copy/Cut/Paste.
* **Refresh and layout** (§1.4, §1.5, §3.12, §3.17): `RefreshListCtrl_SaveFocused`, the
  one-second `IFolderWasChanged` poll with archives excluded and the timer suspended during
  operations, `directoryWasRemoved` navigating up, F9 with the second panel created lazily, the
  splitter ratio, and the per-panel save on exit.

## 3. Verified in the running app

Driven with `osascript` (System Events, targeted by unix id so no sibling agent's instance was
touched) plus synthesized mouse events for the right-click and the drag, launched with
`SEVENZIP_DEFAULTS_SUITE=7zip-panel`, under the shared app lock. Screenshots in
`Mac/docs/reports/screenshots/panel-*.png`.

| What | Result |
|---|---|
| Details view, columns, status bar | `Name, Size, Modified, Created, Comment, Folders, Files`; sizes right-aligned with space separators (`2 000`), `..` first, directory Size empty; status `1 / 5 object(s) selected    0    0    2026-09-19 23:48` (`panel-01-details.png`) |
| Sort by Size (header click) | first click descending (`sub, beta.txt, test.zip, alpha.txt, gamma.md`), second ascending; View > Unsorted gives the native order with folders mixed in; View > Name restores name ascending (`panel-02-sort-size-ascending.png`) |
| Column layout persistence | `FM.Columns.FSFolder` written as the JSON `CListViewInfo` with sortID 4 and the hidden flags |
| Column header menu | one checked item per visible column, the ten hidden ones unchecked; toggling Attributes adds the column and persists it (`panel-06-column-menu.png`) |
| Large Icons / Small Icons / List / Details | all four render and keep the selection; `FM.ListMode0` persisted (`panel-03..05`) |
| Select… mask `*.txt` | adds the two .txt files to the selection: `3 / 5 … 2 010` (`panel-07-select-dialog.png`) |
| Select All / Invert / Deselect All | `5 / 5 … 2 893` → `1 / 5` (nothing selected falls back to the focused row) |
| Create Folder / Create File | Combo dialogs, new item focused and selected, files on disk (`panel-08-create-folder.png`) |
| Rename in place | F2 edit in the name cell, renamed on Enter, row re-focused (`panel-09-rename-in-place.png`) |
| Delete to the Trash | no confirmation for a file-system folder, item gone from the listing and present in `~/.Trash` |
| Delete inside an archive | confirmation "Confirm File Delete / Are you sure you want to delete 'readme.txt'?" then the zip is rewritten without it (`panel-20-delete-confirm.png`) |
| Properties | every item property, then the folder block (`Type FSFolder`, `Path`) (`panel-11-properties.png`) |
| Two panels | F9 / View > 2 Panels, both panels with their own address bar and status bar (`panel-12-two-panels.png`) |
| Copy To… between panels | dialog pre-filled with the other panel's path, info block `alpha.txt / Files: 1 / Size: 10`, file copied, destination refreshed, `FM.CopyHistory` written (`panel-13-copy-dialog.png`) |
| Archive navigation | Enter opens `test.zip`, the zip handler's 18 columns appear, sub-folder and Backspace back out with the archive re-focused (`panel-14-inside-archive.png`) |
| Flat view inside the archive | `sub, deep, big.txt, inner.txt, notes.md, readme.txt`, `FM.FlatViewArc0 = 1` (`panel-15-flat-view.png`) |
| Comment dialog | title "Comment", label "Comment:" (`panel-16-comment.png`) |
| List context menu | 7-Zip verbs (grayed: their scopes are not on this branch), then Open/Open Inside/Open Outside/View/Edit, Rename/Copy To/Move To/Delete, Split/Combine (grayed), Properties/Comment (`panel-17-context-menu.png`) |
| Folders History | list dialog with the visited folders (`panel-18-folders-history.png`) |
| Address drop-down | current path first, then every ancestor indented per level, Documents, Computer, the four mounted volumes indented by one, then the history (`panel-19-address-dropdown.png`) |
| Drag between panels | dragging `beta.txt` to the other panel moved it (same volume ⇒ move), both listings refreshed |
| Clipboard | Cmd+C puts the name on the pasteboard and the file URL with it; Cmd+V in the other panel copies the file |
| AlternativeSelection mode | single-selection list with the internal vector: Space toggles and moves down, the "my-selected" rows are painted RGB(255,192,192) and the status bar counts them (`panel-21-alternative-selection.png`) |

Three bugs were found this way and fixed: the icon views rendered nothing (`NSCollectionView`
reuse raised an uncatchable ObjC exception and the document view was never resized), the menu
actions appeared dead while another agent's app was frontmost (a test-harness artefact, not a
bug), and the generic list dialog used lang 3003 as a column title, which showed
"Cannot create folder '{0}'" above the Properties values.

A code-review pass over the whole scope found eight more, all fixed in the second commit: the
operation runner did not actually park the panel queue before the worker started, Enter on several
items bound a folder with the indices of the listing it had just replaced, a queued `IFolderCompare`
sort could install rows of a folder that was already gone, the AlternativeSelection rows never
repainted, F9 could not bring panel 0 back and the refresh timer polled the hidden panel,
archive→archive move deleted only the focused item, select-by-type on an extension-less name
selected every file, and a failed bind left the pending focus armed.

## 4. Deliberate differences from Windows

1. **Back / Forward** (`Cmd+[` / `Cmd+]`, View menu) are new: 7zFM has no navigation stack. The
   Windows folder history is unchanged.
2. **Insert** does not exist on Apple keyboards: in AlternativeSelection mode **Space** is
   `OnInsert`, otherwise Space calculates the focused folder's size (what F3 does there too).
   `Ctrl+Ins` / `Shift+Ins` are `Cmd+C` / `Cmd+V`.
3. **Edit > Copy / Cut / Paste** were added to the menu bar; Copy puts the item names *and* the
   file URLs on the pasteboard, Cut marks it so Paste moves, Paste is `CopyFromNoAsk` (§9 #13).
4. **Permanent delete** is Shift+Cmd+Backspace (Windows Shift+Del); Cmd+Backspace is the Trash.
5. **The right-button drag menu** is offered on a **Control-drag**.
6. **The System submenu** becomes Open With / Show in Finder / Quick Look / Get Info, and Get Info
   opens this scope's Properties dialog (§9 #2, #10).
7. **Focus vs. selection**: a Cocoa table has no separate focus, so the first non-`..` row is
   selected after a folder change and the status bar reads `1 / N`, which is what 7zFM shows for
   its focused-but-unselected row.
8. **Column widths** are the Windows numbers (160 / 100 points); the system font is larger than
   Windows' 8 pt UI font, so a date column shows a truncated value until it is widened.
9. **The address drop-down** has no per-entry icons (an `NSComboBox` list is plain text); the
   per-level indentation is there.
10. **Raw properties** (`IArchiveGetRawProps`) are not exposed by the bridge, so the Properties
    dialog has no hex dump and no `kpidNtSecure` summary; `fsfolder` api §1 made that choice
    deliberately and shows the link target as a normal column instead.

## 5. Known gaps and follow-ups

* **Zone identifier / quarantine propagation** (PROGRESS §3.8 last box) is not implemented: it
  needs `Get_ZoneId_Stream_from_ParentFolders` and the `WriteZone` policy, which belong to the
  `extract` scope (01 §9 #23).
* **The File-menu enable rules for the `tools` commands** (Split/Combine only for one file-system
  file, Link for exactly one item, Diff hidden without a Diff tool, Ver* with 7vc) are not
  evaluated here: those selectors belong to `tools`, and AppKit disables what nobody implements.
  The panel's own rules (`isFsFolder`, `isHashFolder`, read-only chain, item count, all-are-files)
  are in `PanelViewController.isActionEnabled`.
* **Open Outside / View / Edit inside an archive** need the temp-file open flow of `extract`
  (PROGRESS §2.4, §4.6). The panel forwards the same selector to the next responder, so the
  `extract` implementation is no longer shadowed; on this branch the commands report lang 6008 for
  archive items. Nothing was duplicated here (`Mac/docs/api/extract.md` is not on this branch).
* **Drag-out of archive members** uses this scope's own `NSFilePromiseProvider`; once
  `ArchiveDragOut` (extract api §5) is on the branch, `extractForPromise` should call it instead.
* **Drag & drop is wired for the details table only**; the three icon view modes have no drag
  source or drop target yet.
* **The 7-Zip context verbs and the toolbar Add/Extract/Test** stay disabled until `extract`,
  `compress` and `tools` implement the selectors listed in `Mac/docs/api/panel.md` §3.
* `Mac/Tests/UITests/PanelTests.swift` needs the `7-ZipUITests` target of `mac/harness`; the two
  new symlinks under `Mac/Tests/SevenZipKitTests/` should become proper source entries
  (`Mac/docs/requests.md`).
* The `NSCollectionView` items are created without reuse (see §3): fine for a screenful, worth
  revisiting if a folder with tens of thousands of items is scrolled in icon mode.

## 6. Build, tests, commits

* `Mac/scripts/build.sh` — clean, no warnings in `Mac/` code.
* `Mac/scripts/test.sh` — 85 tests, 0 failures, including the 18 new `PanelLogicTests`.
* Everything committed on `mac/panel` with `mac(panel): ` messages.
