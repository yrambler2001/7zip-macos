# `mac/archgaps` — archive-engine gaps

Branch `mac/archgaps`, off `macos` at `9c42fb3`, 2026-10-03. This report covers parity.md
"Unfinished" items 7 (raw properties) and 13 (nested-archive write-back), an audit of every
unchecked box in the PROGRESS.md `scaffold`, `fsfolder`, `extract` and `tools` sections, and the
small gaps the audit found. Section J of `parity.md` is the user-facing summary.

## 1. Raw properties (`IArchiveGetRawProps`): `01 §3.2, §3.11`

**Windows.** `CPanel::InitColumns` (PanelItems.cpp:177-199) appends one column per raw property
after the folder's own columns. `SetItemText` (PanelListNotify.cpp:265-349) renders each cell:

- reparse data is decoded;
- more than 64 bytes shows as `data:<n>`;
- otherwise the cell is hex, upper case only for a CRC or checksum of at most 8 bytes.

`CompareItems2` (PanelSort.cpp:99-132) sorts the column: empty values first, then the folder's raw
comparison. `CPanel::Properties` (PanelMenu.cpp:212-246) lists the same values with a 256-byte limit.

**Mac.** `SZFolder` (Mac/Core/SZFolder.mm) QIs `IArchiveGetRawProps`, and `properties` ends with the
raw properties (`SZPropertyInfo.isRawProperty`, `varType == .empty`). `kpidNtSecure` is never
listed (locked decision, `01 §9 #7`), and a raw property whose id the folder already lists is
skipped. For raw columns:

- `displayStringOfItem` returns the list form;
- `compareItem` implements `CompareItems2`;
- `rawPropertyOfItem` returns the bytes;
- `rawPropertyString(at:propID:forPropertiesDialog:)` returns the dialog form.

Because the bridge does all of this, the panel's column, cell and sort code needed no change.
`PanelProperties.build` uses the dialog form for raw lines. Results:

- WIM shows SHA-1 and reparse data.
- XAR shows its checksum.
- The HFS, APFS, NTFS, Ext and FAT image handlers get their raw fields the same way.

7z has none: its handler reports 0 raw properties. A 7z archive therefore cannot serve as a
fixture; WIM and XAR do.

### Two defects found on the way, both fixed

1. **Every tree-handler archive listed blank names.** WIM, XAR, HFS, APFS, NTFS, Ext and FAT go
   through `CProxyArc2`. In `CProxyArc2::Load` (CPP/7zip/UI/Agent/AgentProxy.cpp), the
   `CPropVariant` that receives `kpidName` is declared inside an `else` block. The name is
   copied by `AllocStringAndCopy` *after* that block has freed the BSTR. Windows leaves freed
   bytes in place; macOS zeroes freed small blocks, so each name became `NameLen` NULs. The fix
   hoists the declaration under `#ifdef __APPLE__` and is recorded in
   `upstream-patches.md`/`.diff`. Test: `RawPropertiesTests.testTreeHandlerItemNamesAreReadable`.
2. **The Properties dialog crashed on WIM and read out of bounds on every archive.** It called
   `SZArcProps.properties2(atLevel: 0)`, and `CAgent::GetArcNumProps2` reads `Arcs[level - 1]`.
   - The bridge now answers empty / nil outside `1 ..< levelCount`.
   - `PanelProperties.build` walks the levels as PanelMenu.cpp:345-410 does: innermost first,
     the "2" block only between two levels, and the failed-to-open level after a double separator.
   - Found by `ArchGapsTests` as a host crash in `CObjectVector<CArc>::operator[]`.
   - Test: `RawPropertiesTests.testArcProps2OnlyBetweenLevels`.

**Verification.** `RawPropertiesTests` has 9 unit tests:

- the column list and its order;
- `kpidNtSecure` hidden;
- SHA-1 checked against `shasum` for files at the root, in sub-folders and in flat view;
- the directory row empty;
- sort order;
- the XAR checksum;
- no raw columns for 7z, zip, tar.gz or the file system;
- the formatter's limits and letter case.

`ArchGapsTests.testRawPropertiesAreColumnsAndPropertiesLines` checks the panel's SHA-1 column and
cells, the Properties line (after "Size"), sorting by the raw column, and the XAR checksum cell.
Screenshot `archgaps-01-xar-checksum-column.png` shows the XAR listing with readable names; the
checksum column is off to the right of the 1200 pt window.

## 2. Nested-archive write-back: `01 §3.8`, parity D 13

**Windows.** `CloseOneLevel` calls `OpenParentArchiveFolder` (PanelItemOpen.cpp:598). If the
nested archive's temp copy changed size or time (`WasChanged_from_FolderLink`):

1. ask IDS_WANT_UPDATE_MODIFIED_FILE 3009 (Yes / No / Cancel);
2. on Yes, call `OnOpenItemChanged` → `CopyFromFile` into the parent under progress;
3. on failure, show IDS_CANNOT_UPDATE_FILE 3010 with the copy's path and return before
   `DeleteDirAndFile`, so the copy survives.

Several levels unwind innermost first.

**Mac.**

- **Bridge** (`SZArchiveOpener.mm`). An archive opened from a 7zO copy records the copy's path,
  size and mtime. It exposes `tempFilePath`, `tempFileWasChanged`, `refreshTempFileAttributes()`,
  `keepTempDirectory()` and `writeBackIntoOuterFolder(progress:)`. The write-back:
  - refuses a read-only parent;
  - finds the item again by name if the parent's listing moved;
  - calls `CopyFromFile`, then re-records the copy and reloads the parent.
- **App** (`Mac/App/Panel/PanelNestedArchives.swift`). `leaveNestedArchives(from:to:)` closes every
  level of the old chain that the new folder is not inside. It runs on the panel queue from:
  - `navigate(to:)`, before the new chain is opened, so the reopened chain sees the updated parent;
  - `goUp()`;
  - `openDrivesFolder()`.

  `closeNestedArchivesForShutdown()` runs from `windowWillClose` and from `willTerminate` (Cmd+Q),
  once. The question and the progress dialog go to the main thread while the queue waits, so only
  one thread touches the folders. Before a level is checked,
  `TempOpenManager.finishSessions(inside:)` offers any pending edit of a file inside it, so that
  edit travels up with the write-back.
- **Failure and cancel.**
  - The parent is rewritten through a temp file and moved over the original, so it is never
    damaged; the tests compare it byte for byte.
  - The modified copy is kept (`keepTempDirectory`), and 3010 shows its path.
  - No and Cancel discard the copy, as in Windows.
- **Cancel did not work at all before.** `SZTempOpen.updateItem` passed `CopyFromFile` a bare
  `IProgress`, so `CommonUpdateOperation` found no `IFolderArchiveUpdateCallback`: no progress, no
  Cancel, no re-open password. This affected every Edit write-back too. It now gets
  `CSZUpdateCallbackAdapter`, as Windows passes `CUpdateCallback100Imp`.
- **Difference from Windows.** Binding a path inside the *same* nested archive closes and reopens
  the chain (asking once) instead of reusing the open links. `resetForTest` drops the chain without
  a question.

**Verification.**

- `NestedWriteBackTests`, 6 unit tests:
  - copy tracking;
  - an edit written back, checked by extracting readme.txt from the parent on disk, with a second
    round;
  - a cancelled write-back: parent unchanged byte for byte, copy kept after close;
  - a read-only parent: refused, parent unchanged, copy kept;
  - an unchanged nested archive cleaning up on close;
  - `-t` format hints.
- `ArchGapsTests`, app-hosted. Alerts are answered by a modal-mode timer, with no synthesized input:
  - going up writes back (one 3009 question naming test.7z, parent reloaded in place);
  - binding another path writes back first, and re-entering sees the new 29-byte readme.txt;
  - an unchanged archive asks nothing;
  - No leaves the parent unchanged;
  - a failed write-back to a read-only parent shows 3010 with the copy's path and keeps both.

## 3. Audit of the unchecked PROGRESS boxes, and the small gaps fixed

A read-only audit of all 70 unchecked lines in §1, §2, §4 and §6, plus line 498 at the end of §5,
found 37 done-but-unticked, 18 partial, 1 missing (optional) and 14 deliberately different. I
ticked 45 boxes: the 37 done, minus §5 line 498 (not this scope's section), plus the items closed
here. The checklist now reads **455 of 496**.

| Line | Item | Evidence |
|---|---|---|
| 43, 45, 71, 75 | project.yml targets, scripts, test target, app files | `project.yml`, `Mac/scripts/*`, `Tests/SevenZipKitTests` |
| 63 | SZProgressDelegate | `SZProgressDelegate.h`; `FolderOperationsTests.testCancelFailsWithCancelledError` |
| 85, 89, 96, 101, 106 | toolbar → focused panel, icons, View menu, menu validation, header | `CompressCommands`/`ExtractCommands` via ActiveContext, `Icons.swift`/`PanelIcons.swift`, `MenuAndToolbarTests.testMenuBarStructure` |
| 109, 111, 113, 114 | refresh timer, root folder, deferred messages, smoke test | `refreshIfChanged`, `SZRootFolder`, `SmokeTests` |
| 136, 139 | system icons, Trash / delete strings | `PanelIcons`, `PanelOperations.swift:18-70`, `FSFolderTests` |
| 154, 156-167 | ParseOpenTypes, CAgentFolder, update operations, KeepModeForNextOpen | upstream Agent compiled and called through the bridge; `FolderOperationsTests`, `TempOpenTests`, `testFormatHint` |
| 157 | archive item properties incl. raw properties | this branch, `RawPropertiesTests` |
| 173-181, 183, 184 | OpenItemInArchive steps 1-5, CTempFileInfo, nested write-back, 7zE dirs | `TempOpenTests`, `NestedWriteBackTests`, `ArchGapsTests` |
| 177 | IsVirus_Message | fixed here: the panel's own weaker copy now calls `SuspiciousName` (one list, one IDS_VIRUS 3012 text; U+202D added) |
| 182 | kStartExtensions | fixed here: applied inside archives too (`DoItemAlwaysStart`, PanelItemOpen.cpp:993/1503) |
| 420, 426 | Open Outside, Open with kMaxOpenItems and `*`/`#` | `PanelGapsTests`, `PanelNavigation.swift` |
| 510, 532 | `7zG h`, Benchmark TotalMode | `CommandExecutor.runHash`, `HasherTests`; `BenchmarkDialog` console view |

**Also fixed, boxes left unticked because the rest of the item is still open:**

- **168, password per chain.** The panel's remembered password was never forgotten, so an
  unrelated later archive silently got the old one. It is now cleared when the panel leaves its last
  archive level. Test: `testRememberedPasswordIsForgottenOutsideArchives`. Still per panel, not per
  level.
- **78, `-t<type>` on the launch line.** It was parsed and discarded. `SZFolder.folder(forPath:formatHint:passwordDelegate:)`
  now hands it to `CAgent::Open` for the first archive on the path; `navigate(to:formatHint:)`
  passes it. Test: `testFolderForPathHonoursTheFormatHint`. Still open: a failed launch open
  falls back to the root instead of showing "Error" and closing the window.
- **432, 7-Zip → 7-Zip drops.** Archive members dropped onto an *archive* panel said
  "unsupported". They now go through a 7zE folder, as F5 does. Test:
  `testDropFromOneArchiveIntoAnother`. The private pasteboard type is still unused; the in-process
  drag session does that job.

**Left open.** Each is filed in `requests.md` or already listed in parity.md B / C:

| Line | Item | State |
|---|---|---|
| 153 | archive open | No "Opening..." progress or cancel; `Open_SetTotal`/`SetCompleted` are no-ops. |
| 155 | open errors | No warnings shown on entering an archive; the per-level open error text exists only on the extract path. |
| 140 | case sensitivity | No per-volume case sensitivity. |
| 169 | work dir | "Removable only" needs an upstream `WorkDir.cpp` patch. |
| 60, 61 | bridge | No encryption / SFX flags in SZCodecs; `IFolderProperties` / `IFolderClone` / `IFolderArchiveUpdate` not bridged. |
| 69 | temp dirs | Named `7zO-XXXXXX`, not `7zO<8 hex>`. |
| 81, 83, 108 | window chrome | Toolbar bitmaps, status-bar sections, splitter (parity B 20 / 21). |
| 94 | File menu | Ver* items. |
| 186 | optional | Startup sweep. Not done: sweeping temp folders at launch could hit another running instance's folders. |

These are recorded as different on macOS (parity C): 77, 79, 80, 100, 110, 185 and 512.

## 4. Test counts

- `Mac/scripts/build.sh`: clean, no warnings in `Mac/`.
- `Mac/scripts/test.sh`: 363 passed, 0 failed.
- `Mac/scripts/test.sh -H`: 78 passed, 0 failed.

The XCUITest shards were not run; nothing UI-driven changed shape.

## 5. Files touched outside this scope's natural area

- **Upstream.** `CPP/7zip/UI/Agent/AgentProxy.cpp`: one `#ifdef __APPLE__` hunk, recorded.
- **extract.** `Mac/App/Support/TempOpen.swift`, `Mac/Core/Internal/SZTempOpen.mm`.
- **panel.** `Mac/App/Panel/PanelNavigation.swift`, `PanelDragDrop.swift`, `PanelViewController.swift`
  (one stored flag), `Mac/App/MainWindow/MainWindowController.swift`,
  `Mac/App/Dialogs/PropertiesDialog.swift`, and the new `PanelNestedArchives.swift`.
- **harness.** `Mac/scripts/make-fixtures.sh` (additive) and two new fixtures.
- **scaffold bridge.** `Mac/Core/SZFolder.mm` and `.h`, `Mac/Core/SZArchiveOpener.mm` and `.h`.
