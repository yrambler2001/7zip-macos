# `cleanup` — closing the seams the parallel scopes left

> **Publication note:** all but a few showcase images under `docs/reports/screenshots/` were removed from the repository before publication. Paths below that point into them are kept as a record of what was measured.

Branch `mac/cleanup` (worktree `.worktrees/cleanup`), cut from `macos` at `d06136d`.

Five tasks, all from `Mac/docs/requests.md`: each one was a place where a scope had to work around
something a sibling had not landed yet. Every row is marked done there with a one-line note.

Baseline: clean build, no warnings from `Mac/` code, 209/209 unit tests.
After: clean build, no warnings from `Mac/` code, **223/223 unit tests** (14 new), plus a 4-test
XCUITest verification run.

---

## 1. Tools commands read the frozen contract (`tools` → `panel` request)

`ToolsPanelAccess.operatedItems(of:)` walked the panel's view tree for an `NSTableView`, read its
`selectedRowIndexes`, pulled the *rendered* name out of each row's cell view and mapped it back to
a `PanelRow` by displayed name. That existed only because `mac/tools` was cut before
`OperationContext` was frozen.

It now calls `ActiveContext.current()`, the one implementation of 7zFM's operated-items rule
(`Get_ItemIndices_OperSmart`, `PanelItems.cpp`; 01 §3), exactly as `extract` and `compress` read it.
`ToolsPanelItems.rows: [PanelRow]` became `ToolsPanelItems.items: [Item]` with `index` / `name` /
`path` / `isDirectory`; `folderPath` is `context.displayPath`, `fullPaths` is `context.paths`.

Two details:

* `isDirectory` is resolved from the file system, because `OperationContext` does not carry
  `IsItem_Folder` and the only users (Split, 01 §3.14, and Combine) refuse a non-file-system folder
  first anyway.
* the panel is still read for **one** thing, `panel.flatMode`, which the frozen contract does not
  carry and which `CApp::CalculateCrc2` needs as `CDirEnumerator::EnterToDirs = !flatMode`
  (01 §3.13). Everything else comes from the context.

No behaviour change was intended and none was observed; what is gone is the dependence on the
list's rendering (a scrolled-out row has no cell view, and a display name is not the engine name).

## 2. One lazy-extraction path for dragging out (`panel` ↔ `extract` requests)

`PanelViewController.extractForPromise` ran its own `runFolderOperation` +
`IFolderOperations::CopyTo`. It now calls `ArchiveDragOut.extract(indices:from:to:...)`
(`Mac/docs/api/extract.md` §5), so there is a single lazy-extraction path. That also fixes the path
mode: `ArchiveDragOut` uses `kCurPaths`, which is what `CAgentFolder::CopyTo` uses for a drag
(01 §3.15), so a dragged **directory keeps its subtree** — the old `CopyTo` call did not say so.

Dragging *file-system* items is unchanged (plain file URLs, `pasteboardWriterForRow`).

Threading: `writePromiseTo` is called on the promise queue, so the panel queue is parked from
there — never from the main thread, which `ArchiveDragOut` needs for the Progress dialog — and the
call itself is made on the main thread. That keeps the one-thread-per-folder rule of
`api/opsinfra.md` §1 that `runFolderOperation` used to give for free.

`ArchiveDragOut.promisedNames(indices:from:)` is deliberately *not* called: the promise reports the
row's cached name instead, because reading the folder on the main thread is forbidden
(`api/panel.md` §1). It is the same string, captured on the panel queue when the row was built.

## 3. Reopening a multi-volume set (`compress` → opener request)

`SZArchiveOpener` built its own `IArchiveOpenCallback`. That class implements no
`IArchiveOpenVolumeCallback`, so the Split handler never found `.002` / `.003` and opening
`x.7z.001` failed with `SZErrorCodeNotArchive`, while the console `7zz` opened it. Confirmed before
the fix by the new `MultiVolumeOpenTests`, which failed exactly that way on the checked-in
`multi.7z.001..003` fixture.

`CAgent::Open` now gets the engine's own `COpenCallbackImp`, exactly as 7zFM builds it
(`FileFolderPluginOpen.cpp:317-330`, `02-engine-api.md` §2.5.1):

* `Callback` points at a new `CSZOpenCallbackUI : IOpenCallbackUI`, which answers the password the
  way the old bridge callback did (`Open_CryptoGetTextPassword` → `SZPasswordDelegate`) and tracks
  `PasswordWasAsked` / `Cancelled` for the error mapping;
* `Init2(dirPrefix, fileName)` sets the folder prefix `COpenCallbackImp::GetStream`
  (`ArchiveOpenCallback.cpp:284-367`) looks in for sibling volumes;
* an archive opened **from a stream** inside another archive gets `SetSubArchiveName` instead, so
  no volume lookup happens there — upstream's `if (inStream)` branch.

`COpenCallbackImp` outlives the open stage for a multi-volume set and keeps a *raw* pointer to the
`IOpenCallbackUI`, so `SZArchive` owns the UI object and clears `Callback` before releasing it.

`archive.type` for `multi.7z.001` is `"7z"`, not `"Split"`: `CAgent::Open` reports the innermost
handler (`CArchiveLink::Arcs.Back()`). `arcProps.levelCount >= 2` is what shows the Split level, and
`rootFolder()` lists the 7z contents directly.

## 4. Hashes while extracting or testing — `-scrc` (`tools` ↔ `extract` requests)

`Extract()` was called with `IHashCalc = NULL`, so 03 §2.6 did nothing.

* `SZExtractOptions.hashMethods` (**empty by default**, so nothing changes for an existing caller)
  builds the same `CHashBundle` `GUI.cpp:275-281` builds and hands it to `Extract()`;
  `CArchiveExtractCallback::SetHashMethods` then wraps every output stream in a
  `COutStreamWithHash`, on extract and on test alike.
* `SZExtractResult.hashResults` is the `SZHashResults` that `HashResultsDialog` already renders,
  with the two rows `ExtractGUI.cpp:129-136` puts in front of `AddHashBundleRes`
  (`IDS_ARCHIVES_COLON 3907` = `NumArchives`, `IDS_PROP_PACKED_SIZE 1008` = `PackSize`), and only
  for a clean run, which is when Windows shows the dialog.
* With hashing on, `testSummary` is nil: the hash list *replaces* the statistics box, which is the
  `if (HashBundle) … else if (Options->TestMode) …` of `ExtractGUI.cpp:131-152`.
* `MainName` / `FirstFileName` stay empty as upstream leaves them, so the rows are
  Files / Size / the per-method sums, never a bare `"<Method>"` row.

The `CHashBundle → SZHashResults` conversion stays where the `tools` scope wrote it
(`SZHasher.mm`) and is shared through the new `Mac/Core/Internal/SZHashBundleBridge.h` with a
`leadingRows` parameter. The CRC command's rows are byte-for-byte unchanged.

**Not wired to a UI call site, on purpose.** 7zFM's Extract dialog has no `-scrc` control: it is a
7zG / command-line option (03 §2.6). The call site to add is the command-line front end
(`Mac/App/CommandLine*.swift`, `finder`) or `ExtractCommands.swift` (`extract`) — both siblings'
files, so it is a row in `requests.md` instead.

## 5. The flaky fixture-order assumption

A sibling is fixing `FSFolderTests/testCrossVolumeCopyMoveAndVolumeRefresh`, so that file was left
alone. Swept the rest: the only other offender was
`SevenZipKitTests/testRootFolder`, which compared the item count of two independent `FSDrives`
enumerations (`SZRootFolder.makeVolumesFolder().itemCount == volumes.itemCount`) and read
`totalSize` / `fileSystem` at index 0. Both are now pinned to the volume mounted at `/`, found by
binding each row — so another agent attaching or detaching a RAM disk between the two calls cannot
fail it. No other assertion in the unit suite depends on directory order or on the number of
mounted volumes (`contentsOfDirectory` is either sorted or compared against 0 / 1 entries).

---

## What was verified and how

**Unit tests — 223/223** after a clean `rm -rf Mac/build && Mac/scripts/build.sh &&
Mac/scripts/test.sh`. 14 are new:

| File | Covers |
|---|---|
| `DragOutPromiseTests` (2) | the promise round trip: the provider advertises the promised name on the pasteboard before anything exists, the promised bytes appear in the directory the receiver chose, a dragged folder keeps `sub/deep/inner.txt`, a member dragged out of a sub-folder lands flat |
| `MultiVolumeOpenTests` (6) | the `multi.7z.001..003` fixture through `SZArchiveOpener` and through `SZFolder.folder(forPath:)`, both members extracted whole, a set written by `7zz a -v40k`, a set written by `SZUpdater`, and one volume on its own which must **not** list as a whole archive |
| `ExtractHashTests` (6) | `-scrc` off by default; the digests cross-checked against `7zz x -scrcSHA256` and `7zz t -scrcSHA256`; the exact row order; `"*"` = every hasher; an unknown method fails instead of silently skipping |

The console tool used for the cross-checks is
`CPP/7zip/Bundles/Alone2/b/m_arm64/7zz` (`UpdaterTestCase.consoleTool`); those tests skip when it
is not built.

**In the running app** — one XCUITest run under the repository app-lock with
`SEVENZIP_DEFAULTS_SUITE=7zip-cleanup`, 4/4 green. Screenshots in
`Mac/docs/reports/screenshots/`:

| Screenshot | What it shows |
|---|---|
| `cleanup-01-crc-file-system.png` | File > CRC > CRC-32 on `test.7z` selected in a file-system folder → `CRC32  6CECBD15`, the value `7zz h Mac/Tests/Fixtures/test.7z` prints |
| `cleanup-02-crc-folder.png` | the same command on the whole `Fixtures` **folder** → Files 10, Size 34 065 bytes, `CRC32 checksum for data  C852619D-00000003`, the value `7zz h Mac/Tests/Fixtures` prints |
| `cleanup-03-crc-inside-archive.png` | the same command on `readme.txt` **inside** `test.7z` → `CRC32  6FB20739`, the CRC `7zz l -slt` reports for that member |
| `cleanup-04-copy-out-of-archive.png` | the drag-out-adjacent path: Copy To… of the archive folder `sub` |
| `cleanup-05-after-copy-out.png` | after it; the test asserts `sub/deep/inner.txt` exists at the destination, i.e. the subtree survived |

The "data and names" sum for the folder differs from `7zz h <dir>` (`AB5DBEDA` vs `82FD2B4F`)
because 7zFM names a selected folder's files relative to the **parent**, so the names that enter
the sum carry the `Fixtures/` prefix. The "for data" sum, which does not depend on names, matches.

The UI verification was written as a throwaway `Mac/Tests/UITests/CleanupVerifyTests.swift`,
run, and **deleted again** — `Mac/Tests/UITests/*` belongs to `harness` and a sibling is working in
it right now. Only the screenshots are committed. If the harness scope wants these four checks
permanently, the file is reproducible from this report; ask and I will hand it over.

## What a human still has to confirm by hand

1. **A real drag of an archive member to Finder.** Automation permission is not granted on this
   machine, so a drag cannot be scripted and `screencapture` is denied. Open `Mac/Tests/Fixtures`,
   enter `test.7z`, drag `readme.txt` (and separately the folder `sub`) onto the Desktop: the file
   must appear with the right bytes, the folder must arrive with `sub/deep/inner.txt` inside, and
   the archive must be left untouched.
2. **Drag-out of a member of an *encrypted* archive** (`secret.7z`, password `secret`) after the
   panel has already been unlocked: today the Password dialog appears again, because
   `ArchiveDragOut.extract` has no `password:` parameter (the panel used to pass
   `OperationRunner.Options.password = rememberedPassword`). Filed as a request to `extract`; it is
   a prompt, not a failure.
3. **A split archive produced by the Compress dialog, reopened from the panel** by double-clicking
   its `.001` — the unit tests cover the bridge, not the panel navigation.

## Known gaps and follow-ups (all in `Mac/docs/requests.md`)

* `-scrc` has no call site yet: `ExtractCommands.swift` / `CommandLine*.swift` must set
  `hashMethods` and show `hashResults`.
* `ArchiveDragOut.extract` needs a `password:` parameter (item 2 above).
* `SZArchiveOpener` still does not run the open on a worker under a progress window titled
  `IDS_OPENNING` in WaitMode, and does not pre-seed the password from the parent chain, so
  `PROGRESS.md` §2.3 "`SZArchiveOpener` = `CFfpOpen::OpenFileFolderPlugin`" stays unticked even
  though its multi-volume and `PasswordWasAsked` halves are now real.
* Per-file digests are not collected for `-scrc` (`SZHashResults.fileResults` is empty there):
  upstream's extract path has no `IHashCallbackUI`, so there is no hook per file. The sums are the
  Windows output.

## Files touched outside this scope's ownership

* `Mac/Tests/SevenZipKitTests/SevenZipKitTests.swift` — the volume-count assertion of task 5
  (the task asked for it; the file belongs to no scope in the ownership table).
* `Mac/Core/Internal/SZHashBundleBridge.h` — **new** path, shared by `SZHasher.mm` and
  `SZExtractor.mm`, both of which this scope owned for these tasks.
* `Mac/docs/requests.md`, `Mac/docs/PROGRESS.md`, `Mac/docs/api/{extract,tools,panel,compress}.md`
  (appended dated notes only), `Mac/docs/reports/`.
* `Mac/Tests/UITests/CleanupVerifyTests.swift` existed only during the verification run and is not
  on the branch.
