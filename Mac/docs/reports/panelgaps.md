# `panelgaps` — the panel-side gaps users hit first

Branch `mac/panelgaps`, worktree `.worktrees/panelgaps`. Scope: `parity.md` "Unfinished" items 1, 5,
6 and 9, the `packaging` → `panel` Back / Forward row and the small open `requests.md` rows addressed
to `panel`.

## 1. What was implemented

### 1.1 The context menu's 7-Zip block works (parity item 1, 01 §2.8-§2.9)

Every verb was drawn and grayed: `PanelContextCommands` was a protocol nobody implemented.
`Mac/App/Commands/PanelContextActions.swift` (new) implements every selector on
`MainWindowController` and calls the command the File menu / toolbar / Finder already use:

| Verb (lang id) | Handler |
|---|---|
| Open archive (2322), Open archive > `*` `#` `#:e` `7z` `zip` `cab` `rar` | `panel.openSelection(insideOnly: true, formatHint:)` = OpenFocusedItemAsInternal |
| Extract files… (2323) / Extract Here (2326) / Extract to "x/" (2327) / Test archive (2325) | `ExtractCommands.extractWithDialog / extractHere / extractToSubfolder / testArchives` |
| Add to archive… (2324) / Compress and email… (2329) | `CompressCommands.addToArchive(showDialog: true, email:)` |
| Add to "x.7z" / "x.zip" (2328), Compress to "x.7z" / "x.zip" and email (2330, new) | `CompressCommands.compressTo(formatName:email:)` |
| CRC SHA > 11 methods | `fileCalculateHash(_:)` (tools, unchanged) |
| CRC SHA > `SHA-256 -> x.sha256` (C12), `Test archive : Checksum` (C13) — new | the Finder extension's `FinderMenuCommand` argv, run through `CommandExecutor.run(argv:)` |

Shown-or-not rules now follow `CZipContextMenu::QueryContextMenu` (ContextMenu.cpp:741-1001):
Extract / Test only when `needExtract` (no directory and every name outside
`kExtractExcludeExtensions`; Shift = extended verbs skips the name check); `Extract to "*/"` for
several archives (the name was missing before and the item was hidden); `Add to "x.7z"` is left out
when that is the selected file's own name; C13 is left out when a directory is selected. Building
the menu focuses the right-clicked panel (NM_RCLICK), so `ActiveContext` names that panel's items.

### 1.2 Open Outside inside an archive, and Diff across two panels (parity item 5, 01 §3.8, §3.11)

* `fileOpenOutside` inside an archive builds an `OperationContext` for each operated row
  (`PanelViewController.operationContext(rowIndices:)`, new) and calls the extract scope's
  `ItemOpenCommands.openOutside(context:)` (new overload of `openOutside()`): the item is extracted to
  a `7zO` temp folder, opened with the default app and watched for a write-back. `kMaxOpenItems` 20
  applies. Enter on a non-archive file inside an archive now does the same (OpenItemInArchive's
  tryExternal half) instead of showing "not an archive".
* `IDM_DIFF 554`: `MainWindowController.diffRequest()` is `CApp::DiffFiles` (PanelItemOpen.cpp:747-792):
  one item selected in the focused panel and two panels → the other panel's single selected item,
  else the same relative path in its folder (plain name when only the source is flat); either panel
  not a file system → 6008. Two items in one panel keep the existing single-panel path (which, unlike
  Windows, also handles archive members). `fileDiff` in `TempOpenCommands.swift` dispatches.

### 1.3 Drag and drop in Large Icons / Small Icons / List (parity item 6, 01 §3.15)

The table's drag and drop code was split into a widget-independent half
(`dragPasteboardWriter(forRow:)`, `dragSessionWillBegin`, `dragSessionEnded`,
`validateListDrop`, `acceptListDrop`) and the `NSCollectionView` overlay now registers the same
types and source masks and forwards its delegate calls to it. Drag-out is a file URL for file-system
items and the same `NSFilePromiseProvider` (→ `ArchiveDragOut`) for archive members; drop-in on a
folder item targets that folder (`.on`), anywhere else the panel's folder (`.before` stands for the
table's drop row −1); the same-panel refusal, effect rules and Control-drag menu are shared.

### 1.4 A background drop compresses the dropped files (parity item 6, CompressDropFiles)

`compressDroppedFiles` used to stash the drop in `pendingCompressTarget` and send
`toolbarAddToArchive:`, whose implementation reads the **selection**. It now builds an
`OperationContext` from the dropped paths (`dropCompressContext(paths:)`: destination = the first
dropped file's folder, or this panel's folder when a name is under the temp folder —
`AreThereNamesFromTemp`, PanelDrag.cpp:2794) and calls the new
`CompressCommands.addToArchive(context:showDialog:email:)`. `pendingCompressTarget` is no longer
set by anything.

### 1.5 View > Back / Forward in a translation (requests.md, `packaging` → `panel`)

`MainMenu.noLangID` (`UInt32.max`) is a sentinel `item(...)` does not look up; the two macOS-only
items use it instead of lang id 0, which is the product name "7-Zip" in every translation.

### 1.6 File-menu rules that live on the window (parity item 9, 01 §2.1)

`MainWindowController.fileMenuRule(_:)`: Split / Combine only for `isOneFsFile`; Link only for exactly
one item and not in a hash folder; Diff disabled in a hash folder and **hidden** when no Diff tool is
configured (`ReadRegDiff` empty); the CRC items always enabled. The panel-side rules (read-only and
hash-folder rules for Open*/View/Edit/Rename/Delete/Comment/Create*) were already in
`PanelMenuCommands.isActionEnabled`. Not done: the Ver* items (7vc) stay hidden, and small-screen
"drop disabled items" is not reproduced.

### 1.7 Small rows

* `fastui` → `panel`: the address-bar icon is now a 16 pt copy, not a 19 pt image scaled into a
  16 pt slot.
* `fsfolder` → `panel` (GetSystemIconIndex / delete strings) was already done on `mac/panel`; the
  stale "open" row is marked done.

## 2. Verification

* `Mac/scripts/build.sh` clean (warnings are errors in `Mac/`).
* `Mac/Tests/AppTests/PanelGapsTests.swift` (new, app-hosted, 13 cases, ~20 s): every 7-Zip verb has
  a handler and is enabled; needExtract (text file, folder, two archives); Extract to, Extract Here
  and Add to "x.7z" really produce files; Open archive binds the panel; C12 writes a `.sha256` with
  the right digest; the right-clicked panel becomes the focused one; Open Outside's archive context;
  Diff across two panels runs a stub diff tool with the right two paths, falls back to the relative
  path, refuses an archive; icon-mode drag-out (URL and promise) and drop-in (folder item and
  background) for all three modes with a stub `NSDraggingInfo`; the background drop's Add to Archive
  dialog proposes the dropped file's name (probed with `ModalProbe`); Back / Forward in German; the
  Split / Combine / Link / Diff rules.
* Totals on the final commit: `test.sh` 342 / 342 (SevenZipKitTests), `test.sh -H` 46 / 46
  (SevenZipAppTests, 13 of them new).
* **A test-hygiene finding.** The first full `-H` run failed
  `PanelWindowlessErrorTests.testAClosedPanelReportsItsErrorOnTheWindowThatOwnsIt` (passes alone).
  Cause, bisected: a closing `MainWindowController` saves `PanelPath0/1`; these tests pointed panels
  at scratch folders and then deleted them, so the next class's new window restored a dead path, put
  up a bind-error sheet, and that sheet queued the test's own sheet behind it. `PanelGapsTests` now
  restores the two keys. The same trap is open to any app-hosted test that does this (noted in
  `api/panel.md`).
* No XCUITest was added: every behaviour here is reachable in process, and the input path (a real
  mouse drag) is AppKit's own.

## 3. Known gaps and follow-ups

* Open Outside of an archive member is covered up to the context it hands `ItemOpenCommands`; the
  test does not launch an external application. The extract scope's temp-open itself is covered by
  its own tests.
* `ListViewDialog` rows: the request (`finder` → `tools`/`panel`) is about `HashListDialogView` in the
  tools-owned `HashResultsDialog.swift`; lifting it into `ListViewDialog` (`tools` → `panel`) is a
  larger change and was left open.
* Right-to-left composite strings (`packaging` → `panel`) left open.
* The panel's context menu still has its own builder rather than sharing `FinderMenuModel`; the
  verbs and rules now match it, C12 / C13 reuse its `FinderMenuCommand`.

## 4. Files touched outside panel ownership

* `Mac/App/Commands/CompressCommands.swift` — `addToArchive(context:showDialog:email:forcedFormatName:)`
  overload; the existing entry point calls it.
* `Mac/App/Support/TempOpenCommands.swift` — `openOutside(context:)` and `diff(paths:parent:)`
  overloads; `fileDiff` dispatches the two-panel case.
* `Mac/App/MainMenu.swift` (shared) — `noLangID` and its one-line use in `item(...)`, the two
  Back / Forward lines.
* `Mac/Tests/AppTests/PanelGapsTests.swift` — new test file.
