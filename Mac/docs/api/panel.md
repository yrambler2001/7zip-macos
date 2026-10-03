# `panel` scope — public API

What the two file panels and the main window expose to the other scopes: how a command scope gets
the selection, how it triggers a refresh, which selectors the panel context menu sends, and the
helpers a later wave can reuse. Sources: `Mac/App/Panel/*`, `Mac/App/MainWindow/*`,
`Mac/App/Commands/PanelCommands.swift`, `Mac/App/Dialogs/{Combo,ListView,CopyMove,Browse,Properties,Comment}Dialog.swift`.

Parity references: `01-fm-feature-inventory.md` §1, §2.1, §2.8, §2.9, §3 (all of it), §9 #2, #12,
#13, #14, #30; `01b-fm-dialogs-settings.md` §4.2, §4.4, §4.5, §4.6, §4.11, §4.18, §5.2, §5.3.

---

## 1. Getting the selection: `ActiveContext` (the frozen contract)

Do not reach into the panel. `MainWindowController` implements `OperationContextProviding` and
registers itself with `ActiveContext.register(_:)` when the window is created and again whenever it
becomes main, so:

```swift
guard let context = ActiveContext.current() else { return }   // main thread
context.folder            // the SZFolder of the focused panel (see the threading rule below)
context.indices           // engine item indices of the operated items ("..", never included)
context.names             // their names, same order
context.paths             // their absolute paths; empty inside an archive
context.folderPath        // the panel's folder path; empty inside an archive
context.displayPath       // what the address bar shows, e.g. "/a/b.7z/dir/"
context.isArchive / .isFileSystem
context.otherPanelPath    // the other panel's path with two panels, else nil
context.window            // present sheets on this
```

The operated items follow 7zFM's rule (`Get_ItemIndices_Operated`): the selected rows, or the
focused row when nothing is selected, never `..`. `PanelOperatedItems.operatedSmart` is the
`Get_ItemIndices_OperSmart` variant (an empty result means "the whole folder") if you need it.

**Threading.** `context.folder` is owned by that panel's serial queue. Never call an engine method
on it from the main thread. Hand it to an off-main operation instead, exactly as
`Mac/docs/api/opsinfra.md` §1 requires. If your work is a folder operation on the *panel's own*
folder, prefer the panel's wrapper, which parks the panel queue for the duration so only one thread
touches the folder:

```swift
// from inside the panel scope; command scopes normally use OperationRunner.run directly
panel.runFolderOperation(options) { folder, runner in try folder.extractItems(...) }
```

A command scope that only needs paths (`context.paths`) does not touch the folder at all — that is
the intended path for `extract`, `compress` and `tools`.

## 2. Triggering a refresh after your operation

```swift
ActiveContext.refresh()      // the focused panel: LoadItems + restore focus/selection by name
ActiveContext.refreshAll()   // both panels (use it when you wrote into the other panel's folder)
```

Both are `RefreshListCtrl_SaveFocused` (01 §3.12): the listing is re-read on the panel queue and the
focus and selection are restored by name, so a new file you created stays visible. Call them on the
main thread after your operation returned. If you created a file whose name you know, the panel-side
equivalent `panel.refreshAfterOperation(selectNames: ["new.7z"])` also focuses and selects it.

Anything a scope changes through `Settings` is picked up on its own: panels observe
`Settings.Group.fm` (the seven `CFmSettings` booleans → `SetListSettings`), the two timestamp keys
of `Settings.Group.view`, and `Settings.Group.language` (re-creates the columns so their names come
from the new lang file). `OptionsPostApply.settingsApplied(languageChanged:)` keeps working.

## 3. The context menu's archive commands

The panel builds the 7-Zip Explorer block of the list context menu (01 §2.9) for non-archive
folders, filtered by `Settings.contextMenuFlags` and `kExtractExcludeExtensions`. The items send
these selectors down the responder chain, so **AppKit disables the ones nobody implements**; a scope
lights its items up simply by implementing the selector on a responder (its own
`NSWindowController` extension, or the app delegate):

| Menu item (lang ID) | Selector | Owner |
|---|---|---|
| Open archive (2322) | `sevenZipOpenArchive(_:)` | `panel` handles it itself if unimplemented is fine — it is the same as Enter |
| Open archive > `*` `#` `#:e` `7z` … | `sevenZipOpenArchiveAs(_:)` | `panel` / `extract` |
| Extract files… (2323) | `sevenZipExtractFiles(_:)` | `extract` |
| Extract Here (2326) | `sevenZipExtractHere(_:)` | `extract` |
| Extract to "name/" (2327) | `sevenZipExtractTo(_:)` | `extract` |
| Test archive (2325) | `sevenZipTestArchive(_:)` | `extract` |
| Add to archive… (2324) | `sevenZipCompress(_:)` | `compress` |
| Compress and email… (2329) | `sevenZipCompressEmail(_:)` | `compress` |
| Add to "name.7z" / ".zip" (2328) | `sevenZipCompressTo7z(_:)` / `sevenZipCompressToZip(_:)` | `compress` |
| CRC SHA > (11 methods) | `fileCalculateHash(_:)` with `tag` = `IDM_CRC32 102` … `IDM_HASH_ALL 101` | `tools` |
| Split / Combine / Link / Diff | `fileSplit(_:)`, `fileCombine(_:)`, `fileLink(_:)`, `fileDiff(_:)` | `tools` |
| Copy To… / Move To… | `fileCopyTo(_:)` / `fileMoveTo(_:)` | `panel` (implemented) |

The protocol that declares them is `PanelContextCommands` in
`Mac/App/Panel/PanelContextMenu.swift` (`@objc`, so `#selector` works without an implementation).
Each item carries a `PanelContextTarget` in `representedObject`:

```swift
final class PanelContextTarget: NSObject {
    let paths: [String]        // absolute paths of the operated items
    let folderPath: String     // the panel's folder ("destination" for Extract Here / Add to)
    let names: [String]        // their names
    let formatHint: String?    // "Open archive >" type: "*", "#", "#:e", "7z", "zip", "cab", "rar"
    let archiveName: String?   // "Add to \"<name>.7z\"" proposes this file name
}
```

Read it with `(sender as? NSMenuItem)?.representedObject as? PanelContextTarget`, and fall back to
`ActiveContext.current()` when it is nil (the File menu and the toolbar send the same selectors
without a target).

**Dropping files on the window background** is 7zFM's "Add to archive…" (`CompressDropFiles`,
01 §3.15). The panel collects the names, stores a `PanelContextTarget` in
`panel.pendingCompressTarget` (temp-folder names redirect the destination to the panel's folder, as
upstream) and then sends `toolbarAddToArchive(_:)`. A `compress` implementation should read
`pendingCompressTarget` first and clear it. While nothing implements the selector the drop reports
"operation not supported" (lang 6008).

## 4. Panel and window API worth knowing

```swift
// MainWindowController
window.panels                     // [PanelViewController], 1 or 2
window.focusedPanel               // the panel commands apply to (LastFocusedPanel)
window.otherPanel(of: panel)      // nil with one panel
window.performCopyOrMove(move:copyToSame:)   // CApp::OnCopy, the F5 / F6 flow
window.switchOnOffOnePanel()      // F9 / IDM_VIEW_TWO_PANELS
window.setFocusedPanel(_:)

// PanelViewController
panel.navigate(to:formatHint:fallbackToRoot:select:focusListOnSuccess:completion:)  // BindToPathAndRefresh
panel.goUp() / goRoot() / openDrivesFolder() / goBack() / goForward()
panel.currentPath                 // _currentFolderPrefix (address bar text)
panel.pathToPersist               // what PanelPath<N> stores
panel.snapshot                    // PanelSnapshot: folderType, isArchive, isFileSystem,
                                  // isReadOnly, chainIsReadOnly, isHashFolder, archivePath, rows …
panel.rows                        // [PanelRow] as displayed (sorted, with the ".." row)
panel.operatedRowIndices() / operatedEngineIndices()
panel.setListViewMode(_:)         // 0 large, 1 small, 2 list, 3 details
panel.setFlatMode(_:) / panel.flatMode
panel.sort(by: SZPropID)
panel.selectAll(_:) / invertSelection() / selectSpec(_:) / selectByType(_:) / killSelection()
panel.reload(keepScroll:) / refreshAfterOperation(selectNames:focusRow:)
panel.copyItemsOut(rowIndices:to:move:)      // IFolderOperations::CopyTo
panel.copyItemsIn(paths:move:)               // IFolderOperations::CopyFrom
panel.copyFileSystemItems(paths:toDirectory:move:)   // CopyFsItems
panel.showProperties() / changeComment() / createFolder() / createFile()
panel.deleteItems(toTrash:) / renameFocusedItem() / calcFocusedItemSize()
panel.rememberedPassword          // CFolderLink's password for the open archive chain
panel.currentFolderForContext()   // the SZFolder (queue-owned; see §1)
```

`PanelViewController` also conforms to `SZPasswordDelegate`: pass the panel as the password delegate
when you open an archive for it and the user is asked once, then the answer is remembered.

## 5. Reusable dialogs this scope owns

```swift
// IDD_COMBO 98 -- one editable value with history (Select mask, Create Folder/File, Rename)
ComboDialog.run(title:label:value:strings:parent:) -> String?

// IDD_LISTVIEW 99 -- a generic 1- or 2-column list; Del removes rows when deleteIsAllowed
var o = ListViewDialogOptions(); o.title = …; o.strings = …; o.values = …; o.numColumns = 2
let r = ListViewDialog.run(o, parent: window)      // .accepted .focusedItemIndex .strings .stringsWereChanged

// IDD_EDIT_DLG 94 -- the read-only text viewer a list row opens
TextViewerDialog.show(title:text:parent:)

// IDD_COPY 96 -- the Copy / Move destination with its history and the item-info block
CopyMoveDialog.run(move:value:history:info:parent:) -> String?
PanelFormat.itemsInfo(rows:)                        // GetItemsInfoString, ≤ 11 lines

// IDD_BROWSE 95 -- NSOpenPanel / NSSavePanel wrapper (folder result has a trailing "/")
BrowseDialog.forFolder(title:initialPath:parent:) -> String?
BrowseDialog.forFile(title:initialPath:allowedExtensions:save:parent:) -> String?

// IDS_PROPERTIES 6600 and IDS_COMMENT 6400
PropertiesDialog.show(lines:parent:)                // build the lines with PanelProperties.build
CommentDialog.run(value:parent:) -> String?
```

`PanelProperties.build(folder:itemIndices:snapshot:level:)` must run on the panel queue (it reads
the folder); `PropertiesDialog.show` then runs on the main thread.

## 6. Logic helpers (Foundation only, unit-tested)

`Mac/App/Panel/PanelLogic.swift` is symlinked into the test target, so these are safe to reuse from
anywhere, including tests:

```swift
PanelSorting.sorted(rows:sortID:ascending:flatMode:folderCompare:)   // CompareItems2
PanelSorting.nextSort(current:ascending:tapped:)                     // SortItemsWithPropID
PanelMask.matches(mask:name:)                                        // DoesWildcardMatchName
PanelMask.containsWildcard(_:) / maskForSelectByType(name:isDirectory:)
PanelOperatedItems.operated(rows:selected:focused:) / operatedSmart(…)
PanelColumnsModel(properties:folderType:isFileSystem:hiddenByDefault:layout:)  // InitColumns
model.layout()                                                       // Settings.ColumnLayout (CListViewInfo)
```

## 7. Deliberate macOS differences (documented deviations)

1. **Back / Forward** (`Cmd+[` / `Cmd+]`, View menu) are a macOS addition — 7zFM has no navigation
   stack. They are per panel and not persisted; the Windows *folder history* (`FM.FolderHistory`,
   the address drop-down and View > Folders History…) is unchanged.
2. **Insert** does not exist on Apple keyboards: in AlternativeSelection mode **Space** is
   `OnInsert` (toggle the focused item and move down); in the normal mode Space calculates the
   focused folder's size (what F3 does there too). `Ctrl+Ins` / `Shift+Ins` are `Cmd+C` / `Cmd+V`.
3. **Edit > Copy / Cut / Paste** were added to the menu bar (7zFM binds the keys only). Copy puts the
   item *names* as text **and** file URLs for file-system items; Cut marks the clipboard so Paste
   moves; Paste is `CopyFromNoAsk` of the pasteboard's file URLs (01 §3.16, §9 #13).
4. **The right-button drag menu** is offered on a **Control-drag** (macOS drags have no right
   button): Copy / Move / Copy to (archive target) / Add to archive… / Cancel.
5. **The "System" context submenu** replaces the shell verbs with Open With (the applications that
   claim the file), Show in Finder, Quick Look and Get Info, which opens this scope's Properties
   dialog (01 §9 #2, #10).
6. **Focus vs. selection**: a Cocoa table has no focus separate from the selection, so the focused
   row is tracked by the panel and the first row is selected after a folder change. The status bar
   therefore reads `1 / N` in a fresh folder, exactly as 7zFM does with its focused-but-unselected
   row.
7. **View modes** other than Details are an `NSCollectionView` laid over the table (the table stays
   in the hierarchy, so `window.tables.count` keeps counting panels for the UI-test helpers).
   Large Icons uses 32 px icons (the Windows large-icon size), List flows into columns like
   `LVS_LIST`.
8. **Column widths** are the Windows defaults (Name 160, others 100 points). The system font is
   larger than Windows' 8 pt UI font, so a date column shows a truncated value until it is widened;
   the width is then persisted per folder type like any other.
9. **Open Outside / View / Edit inside an archive** needs the temp-file extraction of the `extract`
   scope (PROGRESS §2.4, §4.6). While that is missing, those commands report lang 6008 for archive
   items; file-system items work (Viewer / Editor from Options > Editor, else the default app).

---

## Note — 2026-09-20 (`mac/cleanup`)

`PanelDragDrop.swift` only: dragging an archive member out to Finder is fulfilled through the
`extract` scope's `ArchiveDragOut.extract(indices:from:to:...)` (`api/extract.md` §5) instead of the
panel's own `copyItems` call. Two consequences for this scope:

* the drag now uses `kCurPaths`, so a dragged **directory keeps its subtree**, which is what
  `CAgentFolder::CopyTo` does for a drag (01 §3.15);
* `filePromiseProvider(_:writePromiseTo:)` runs on `PanelViewController.promiseQueue`, parks the
  panel queue from *there* (never from the main thread, which `ArchiveDragOut` needs for the
  Progress dialog) and makes the call on the main thread — the same one-thread-per-folder guarantee
  `runFolderOperation` gives, which still applies to every other panel operation.

Dragging file-system items (plain file URLs) and every drop path are untouched.
`rememberedPassword` is no longer passed for the promise; see the open request in `requests.md`.

---

## Note — 2026-09-21 (`mac/modalfix`)

**A panel's error is a sheet of the window that owns the panel, and a closed panel does not reload
on its own.** Both are behaviour changes other scopes can see.

`PanelViewController.showError(_:)` / `showError(message:)` used to branch on `view.window` and fall
back to `NSAlert.runModal()`. A panel closed with F9 (`IDM_VIEW_TWO_PANELS 732`) is kept alive and
reused — 7zFM hides its non-focused panel rather than destroying the `CPanel`, and step 4 of
`sevenzip://test/reset` rebuilds the hidden one too — but on macOS its view is out of the split view,
so `view.window` is nil. The fallback therefore raised an **app-modal alert owned by no window**,
which wedged the app (`Mac/docs/reports/fastui.md` §6.10, `reports/modalfix.md`).

Two new members, and one new rule:

```swift
panel.isPanelVisible      // the view is installed in a window (false for a panel closed with F9)
panel.hostWindow          // view.window, else the window that owns the panel (the delegate's)
```

* `PanelDelegate` gains `var panelHostWindow: NSWindow? { get }`; `MainWindowController` answers
  with its own `window`. Any future implementer of `PanelDelegate` must provide it.
* **`ErrorAlert`** (`Mac/App/Dialogs/ErrorAlert.swift`) is where every message box in the app should
  now go: `ErrorAlert.present(_:on:)` for a non-blocking sheet, `ErrorAlert.run(_:on:)` for a
  synchronous one (a sheet run in a nested modal loop, the `BrowseDialog` shape). With **no** window
  at all `present` logs and `run` is app-modal — that is the 7zG case, a process with no window.
  Never branch a presentation on whether a *view* has a window again.
* `panel.reload(keepScroll:)` **defers** when `isPanelVisible` is false and
  `MainWindowController.showSecondPanel()` replays it through `panel.panelDidBecomeVisible()`. So
  `ActiveContext.refreshAll()`, the View menu's timestamp items, an Options apply and a language
  switch all still reach a hidden panel — just when it is shown, not while it is invisible. A command
  scope needs no change. `panel.refreshIfChanged()` carries the same guard (the window's 1 s timer
  already only ticked `visiblePanels`).
* `panel.navigate(...)` gains a defaulted `reportErrors: Bool = true`. `false` logs a failed bind
  instead of showing it; `resetForTest` uses it, because a reset must not leave a sheet up after its
  own step 1 has closed everything.

Nothing else about the panel API changed. The three confirmation alerts that are app-modal **by
design** (`confirmDelete`, `confirmSuspiciousName`, `confirmCopyToArchive` — 7zFM's `MessageBoxW`
answers, and always raised by a gesture on the visible panel) were left alone; see `reports/modalfix.md`.

---

## Note — 2026-10-03 (`mac/panelgaps`)

Supersedes parts of §3 and §7.9; the text above still describes what `mac/panel` shipped.

* **§3, the context verbs are implemented.** Every `PanelContextCommands` selector is implemented on
  `MainWindowController` (`Mac/App/Commands/PanelContextActions.swift`) and calls the File-menu /
  toolbar command (`ExtractCommands`, `CompressCommands`); nobody else needs to implement them. New
  selectors: `sevenZipCompressTo7zEmail(_:)`, `sevenZipCompressToZipEmail(_:)` and
  `sevenZipChecksumCommand(_:)` (C12 / C13, `representedObject` is a `PanelChecksumCommand` wrapping
  the Finder extension's `FinderMenuCommand`). Building the menu (`makeItemContextMenu`) focuses the
  panel it belongs to, so `ActiveContext.current()` names that panel's operated items.
* **§3, background drop.** `pendingCompressTarget` is no longer set. `compressDroppedFiles(info:)`
  calls `CompressCommands.addToArchive(context:showDialog:email:)` with
  `panel.dropCompressContext(paths:)` — an `OperationContext` whose `paths` are the dropped files and
  whose `folderPath` is the destination folder.
* **§7.9, Open Outside inside an archive works.** `panel.operationContext(rowIndices:)` builds the
  frozen `OperationContext` for explicit rows; Open Outside (and Enter on a non-archive member) hands
  one per row to `ItemOpenCommands.openOutside(context:)`.
* **Diff.** `MainWindowController.diffRequest()` is the two-panel rule of `CApp::DiffFiles`;
  `fileDiff` uses it before the single-panel `ItemOpenCommands.diff()`.
* **Drag and drop helpers** usable by any list widget: `dragPasteboardWriter(forRow:)`,
  `dragSessionWillBegin(_:rowIndexes:)`, `dragSessionEnded(operation:)`,
  `validateListDrop(info:proposedRow:)`, `acceptListDrop(info:proposedRow:)` (row −1 = the panel's
  folder). The icon-mode `NSCollectionView` uses them.
* **File-menu rules on the window:** `MainWindowController.fileMenuRule(_:)`.
* **Test hygiene for app-hosted tests:** a `MainWindowController` saves `PanelPath0/1` when its window
  closes. A test that points panels at scratch folders and deletes them must restore those two keys,
  or the next class's window greets its test with a bind-error sheet that queues every later sheet
  (it made `PanelWindowlessErrorTests` fail after `PanelGapsTests` until restored).

## Note — 2026-10-03 (`mac/optgaps`)

* `ListViewDialog` (IDD_LISTVIEW 99) is view-based: each cell is an `NSTableCellView` whose label is
  the accessibility value, as in `HashListDialogView`.
* Right-to-left: `Bidi` (`Mac/App/Support/Bidi+OptGaps.swift`) — `isolate`, `join`, `labelValue`,
  `stripped`, `makeLeftToRight`. The status line text and `PanelFormat.itemsInfo` now contain
  U+2068 / U+2069 around each segment; compare with `Bidi.stripped` when asserting exact text
  (`contains` on a whole segment still works).
* `copyItemsOut` passes the outermost archive (`snapshot.archivePath`) as the zone source of a copy
  out of an archive (`Get_ZoneId_Stream_from_ParentFolders`).
