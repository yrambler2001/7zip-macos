# `panel` scope report (branch `mac/panel`)

State notes are appended per phase, so a compacted context can be resumed from here.
Final summary and gap list at the end.

## Phase note 1 — views, columns, sorting, selection, navigation, operations, drag & drop (built)

**What exists** (all new files under `Mac/App/Panel/` unless stated):

| File | Contents |
|---|---|
| `PanelRow.swift` | `PanelRow` (row model incl. prefix, isDeleted, isPackage, fullPath, per-PROPID cells and sort keys) and `PanelSnapshot` (what the queue hands the main thread). Foundation only. |
| `PanelLogic.swift` | `PanelSorting` (CompareItems2 + SortItemsWithPropID), `PanelMask` (EnhancedMaskTest), `PanelOperatedItems` (operated / OperSmart), `PanelColumn` / `PanelColumnsModel` (InitColumns + CListViewInfo persistence). Foundation only; symlinked into the unit-test target. |
| `PanelViewController.swift` | Panel state, view construction, snapshot apply, four view modes, columns, status bar, settings observers, `runFolderOperation` (parks the panel queue while the shared runner owns the folder). |
| `PanelListViews.swift` | Details table data source/delegate and the `NSCollectionView` for Large Icons / Small Icons / List. |
| `PanelTableView.swift` | List key entry point, header view (column menu), row view (AlternativeSelection pink, kpidIsDeleted red, FullRow off). |
| `PanelKeys.swift` | The full key map of 01 §3.7 and every selection command of 01 §3.6. |
| `PanelNavigation.swift` | BindToPath/BindToPathAndRefresh, parent/root/volumes, open item / open inside / nested archives, kStartExtensions, IsVirus_Message, address drop-down, folders history, favorites, two-panel helpers, password prompt. |
| `PanelOperations.swift` | Delete (Trash + permanent + the 6100-6105 confirmations), in-place rename, create folder/file, comment, properties, calc-size, CopyTo / CopyFrom / CopyFsItems. |
| `PanelContextMenu.swift` | List context menu (7-Zip verbs, System submenu, File items), column header menu, Quick Look. |
| `PanelDragDrop.swift` | Drag source (file URLs / `NSFilePromiseProvider`), drop target, effect rules, clipboard copy/cut/paste. |
| `PanelFormat.swift`, `PanelIcons.swift` | Column alignment, Copy-dialog info block, icon rule (`GetSystemIconIndex` replacement), address-bar icon. |
| `MainWindow/MainWindowController.swift` | Extended: panel delegate (Tab, F9, Alt+Up/Left/Right, Alt+F1/F2, F5/F6, bookmarks), `ActiveContext.register`, per-panel save incl. `SaveListViewInfo`, toolbar/menu enable rules. |
| `Commands/PanelCommands.swift` | `CApp::OnCopy` (F5/F6, Copy To…/Move To…, archive→archive through a 7zE temp dir) and `OperationContextProviding`. |
| `Dialogs/ComboDialog.swift`, `ListViewDialog.swift` (+ `TextViewerDialog`), `CopyMoveDialog.swift`, `BrowseDialog.swift`, `PropertiesDialog.swift`, `CommentDialog.swift` | The generic dialogs this scope owns (IDD_COMBO 98, IDD_LISTVIEW 99, IDD_EDIT_DLG 94, IDD_COPY 96, IDD_BROWSE 95, IDS_PROPERTIES 6600, IDS_COMMENT 6400). |

**Builds:** `Mac/scripts/build.sh` clean (no warnings in `Mac/` code).
**Tests:** `Mac/scripts/test.sh` — 19 new `PanelLogicTests` pass; 84/85 overall. The one failure,
`FSFolderTests.testVolumesRoot` (fsfolder scope), is environment flake: it enumerates the mounted
volumes and one of this machine's test volumes (FAT/NTFS/ExFAT images) answered `errno=5` after a
20 s stall. Re-running that test alone passes.

**Next step:** UI tests, then verification in the running app under the shared app lock, then
`Mac/docs/api/panel.md` and the PROGRESS ticks.
