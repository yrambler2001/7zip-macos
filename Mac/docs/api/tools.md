# `tools` — hashing, benchmark, split/combine, link, about, help, temp files

What this scope exposes and what other scopes should reuse instead of reinventing. Code
against this file; you do not need to read the sources.

Parity references: `01-fm-feature-inventory.md` §2.1, §2.5, §2.6, §3.11, §3.13, §3.14, §8.6;
`01b-fm-dialogs-settings.md` §4.1, §4.3, §4.10, §4.11, §4.20, §4.26, §4.27;
`02-engine-api.md` §2.3 (`HashCalc.h`, `Bench.h`), §2.5.

---

## 1. Threading in one paragraph

Every `SZHasher` / `SZSplitFile` call and the `SZBenchmark` worker **block**, so they must run
off the main thread — drive them with `OperationRunner` (see `api/opsinfra.md`). They report
through `id<SZProgressDelegate>` on the calling thread and cancel when `progressCheckBreak`
returns `YES`. `SZBenchmark` owns its own 8 MB thread and calls its delegate from it (and from
`Bench()`'s own threads), so a benchmark delegate must marshal to the main thread itself.
An `SZFolder` handed to `SZHasher` must belong to the calling thread (engine refcounts are not
atomic), which is why `hash(itemsIn:…)` is normally given a folder opened inside the same
`OperationRunner.run` block rather than the panel's folder.

---

## 2. `SZHasher` (ObjC, `SevenZipKit`)

```swift
// Every hasher the loaded codecs expose, enumerated through GetHashMethods + CreateHasher.
// 10 in this build: CRC32, CRC64, SHA256, SHA1, BLAKE2sp, MD5, XXH64, SHA384, SHA512, SHA3-256.
SZHasher.availableMethods            // [SZHashMethod] -> .name .menuTitle .digestSize
SZHasher.methodName(forMenuID: 105)  // "SHA256"; 101 -> "*"; nil for a foreign id
SZHasher.isMethodSupported("sha256") // case-insensitive; "*" means "all"

// File-system items. `paths` may be absolute or relative to `basePath`; the reported names
// (and therefore the "data and names" sums) are relative to the containing directory, exactly
// like `7zz h`. `recursive` = !flatMode: with `false` a selected folder is skipped.
let results = try SZHasher.hash(paths: [String], relativeTo: String?,
                                methods: [String], recursive: Bool,
                                progress: SZProgressDelegate?)

// Items inside an archive, without extracting anything (CopyTo in stream mode with an
// IFolderExtractToStreamCallback). `at: nil` takes every item of the folder.
let results = try SZHasher.hash(itemsIn: SZFolder, at: [NSNumber]?,
                                methods: [String], progress: SZProgressDelegate?)

// Checksum files.
SZHasher.checksumFileName(forPaths:relativeToPath:method:)     // "readme.txt.sha256"
try SZHasher.writeChecksumFile(at:forPaths:relativeTo:method:recursive:progress:)
let check = try SZHasher.verifyChecksumFile(at: path, progress: nil)
```

### `SZHashResults`

| Member | Meaning |
|---|---|
| `rows: [SZHashResultRow]` | the ordered `name` / `value` pairs `AddHashBundleRes` builds (§3) |
| `text: String` | the same as `"<name>: <value>"` lines, plus lang 3001 "There are no errors" when there were neither errors nor hashers |
| `clipboardText(forRowsAt: IndexSet)` | what Ctrl+C copies |
| `numFiles numFolders numAlternateStreams filesSize alternateStreamsSize numErrors` | the `CHashBundle` counters |
| `mainName firstFileName` | `CHashBundle::MainName` / `FirstFileName` |
| `methodNames: [String]` | the methods that ran, in engine order |
| `dataDigests dataAndNamesDigests streamsAndNamesDigests` | method → hex for `k_HashCalc_Index_DataSum` / `NamesSum` / `StreamsSum`; for a single file `dataDigests` **is** that file's digest |
| `fileResults: [SZHashFileResult]` | per file, in hashing order: `path size isDirectory isAlternateStream digests` |

`SZChecksumVerification`: `numOK numFailed numMissing numUnsupported messages methodNames text
succeeded`.

### 3. The exact row order (what `HashResultsDialog` renders)

`GUI/HashGUI.cpp:179-231`, all names from the lang file:

1. **Errors** (1070) — only when `numErrors != 0`
2. single file and no folders → **Name** (1004) = `firstFileName`
   otherwise → **Name** = `mainName` (when set), **Folders** (1031) when `> 0`, **Files** (1032)
3. **Size** (1007), rendered as lang 3504 `"{0} bytes"` with the number space-grouped
4. **Alternate Streams** (1075) + **Alternate Streams Size** (1076) when `> 0`
5. per method, in engine order:
   * single file → one row named after the method with the plain hex
   * otherwise → `"<M> checksum for data"` (7502) and `"<M> checksum for data and names"` (7503),
     each the lang string with `CRC` replaced by the method name and the colon removed
   * `"<M> checksum for streams and names"` (7504) when alternate streams were hashed

---

## 4. `SZBenchmark` (ObjC, `SevenZipKit`)

```swift
let bench = SZBenchmark()
bench.dictionarySize = 1 << 25      // -md
bench.numberOfThreads = 10          // -mmt
bench.numberOfPasses = 1            // -mm pass limit
bench.totalMode = false             // `-mm=*`: console-style text instead of results
bench.level = -1
bench.delegate = self               // benchmarkDidUpdate / benchmarkDidFinish(error:)
try bench.start()                   // one Bench() call per pass on its own thread
bench.requestStop()                 // CBenchProgressSync::SendExit
bench.waitUntilFinished()           // Cancel must not close before this returns
```

Snapshot (lock-protected, any thread): `isRunning passesFinished didFinishAllPasses
currentEncode resultingEncode currentDecode resultingDecode totalRating passes
droppedPassIndex frequencyText totalModeText logText`.

`SZBenchmarkResult`: `isDefined speed rating ratingPerUsage usage unpackSize usagePercent
ratingMIPS ratingPerUsageMIPS` plus the ready-made strings `speedString` (`"<n> KB/s"`),
`ratingString` / `ratingPerUsageString` (`"<n>.<mmm> GIPS"`), `usageString` (`"<n>%"`),
`sizeString` (`"<n> MB"` / `"<n> GB"`).

Static information other scopes will want:

| Member | Value |
|---|---|
| `memoryUsage(forThreads:level:dictionary:totalMode:)` | `GetBenchMemoryUsage` |
| `ramSize` / `ramSizeLimit` / `isMemoryUsageOK(_:)` | `NSystem::GetRamSize`, `RAM × 15/16`, `usage + 1 MB ≤ limit` |
| `minimumDictionarySize` `maximumDictionarySize` `minimumDictionaryLog` | 256 KB, 4 GB, 18 |
| `processThreadCount` `systemThreadCount` `hardwareThreadsText` | the affinity numbers and the `"/ <n> …"` static |
| `cpuName` `cpuFeaturesText` `systemInfoLine1` `systemInfoLine2` | `GetCpuName_MultiLine`, `GetOsInfoText + " : " + AddCpuFeatures`, `GetSysInfo` (**both empty on macOS**, upstream fills them only under `_WIN32`) |
| `versionWithCPUText` | `"7-Zip 26.03 (arm64)"` — About and the Compress dialog want this |
| `engineDateText` | `MY_DATE` |
| `engineCopyrightText` | `"Copyright (c) 1999-2026 Igor Pavlov"`. Use this, **not** `SZEngineCopyrightString()`, which is compiled without `USE_COPYRIGHT_CR` and reads `"Igor Pavlov : Public domain : <date>"` |

---

## 5. `SZSplitFile` (ObjC, `SevenZipKit`)

```swift
SZSplitVolumePresets()                       // ["10M", "100M", "1000M", "650M - CD", ...]
SZSplitFile.parseVolumeSizes("650M - CD")    // [NSNumber]? -- nil when the text is invalid
SZSplitFile.numberOfVolumes(forSize:volumeSizes:)
try SZSplitFile.split(at:volumeBasePath:volumeSizes:progress:)   // <base>.001, .002, ...
SZSplitFile.parseFirstVolumeName(_:unchangedPart:)               // "x.001" -> true, "x."
SZSplitFile.volumeNames(forFirstVolume:in:)                      // the consecutive series
SZSplitFile.combinedName(forFirstVolume:)                        // "x.001" -> "x"
try SZSplitFile.combine(_:in:to:progress:)
```

`parseVolumeSizes` is `ParseVolumeSizes` verbatim: `<number>[b|k|m|g|t]`, 1024-based,
case-insensitive, `-` ends parsing, a space-separated list means successive sizes with the last
repeating, overflow fails.

---

## 6. Swift UI this scope owns

| Type | Windows original |
|---|---|
| `HashListDialogView` | `CListViewDialog` / `IDD_LISTVIEW 99` — 1 or 2 columns, `deleteIsAllowed`, `stringsWereChanged`, `focusedItemIndex`, `onActivate`, Cmd+A / Cmd+C / Del, Enter shows the row |
| `HashResultsDialog.show(results:title:parent:)` | `ShowHashResults` (title lang 7501, deletable rows, `SelectFirst = false`) |
| `BenchmarkDialog.run(totalMode:parent:)` | `IDD_BENCH 7600` / `IDD_BENCH_TOTAL 7699` |
| `SplitDialog.run(filePath:path:parent:) -> Result?` | `IDD_SPLIT 7300` |
| `CombineDialog.run(title:prompt:info:path:parent:) -> String?` | the Copy dialog as Combine uses it |
| `LinkDialog.run(currentDirPrefix:filePath:anotherPath:parent:) -> Bool` | `IDD_LINK 7700` |
| `AboutDialog.show(parent:)` | `IDD_ABOUT 2900` |
| `ToolsTempFilesDialog.show(parent:)` | `IDD_BROWSE2 93` |
| `Help.show(topic:)` + `Help.contents/start/benchmark/tempFiles/options/add/extract` | `ShowHelpWindow(topic)` |
| `ToolsAlerts.unsupportedOperation/error/confirm` | `MessageBox_Error_UnsupportOperation`, `MessageBox_Error_LangID`, `MB_YESNOCANCEL` |
| `ToolsPanelAccess.panels(in:)`, `.operatedItems(of:)` | `Get_ItemIndices_OperSmart` |

### What other scopes should reuse

* **`panel`**: `HashListDialogView` is the generic list dialog you need for Properties /
  archive info (`PanelMenu.cpp:183`) and Folders History (`PanelFolderChange.cpp:868`). Lift it
  into `Mac/App/Dialogs/ListViewDialog.swift` (yours) unchanged and delete the copy here; the
  hash dialog will just use it. Please also replace `ToolsPanelAccess.operatedItems(of:)` with a
  real `PanelViewController.operatedItems` (see §8) and drop the Wave 1 placeholder
  `MainWindowController.helpAbout` so the About menu items can point straight at
  `toolsShowAbout`.
* **`compress`**: `SZBenchmark.memoryUsage(forThreads:level:dictionary:totalMode:)`,
  `ramSize`, `ramSizeLimit` and `isMemoryUsageOK(_:)` are the same numbers the Compress
  dialog's memory line and `SetErrorMessage_MemUsage` need. `SZBenchmark.versionWithCPUText`
  is the `MY_VERSION_CPU` string.
* **`extract`**: `-scrc` on extract/test means passing a `CHashBundle` to `Extract()`; when you
  add it, build the results with `SZHashResults` so the same dialog shows them. The stream-mode
  callback in `SZHasher.mm` (`CSZHashStreamCallback`) is the model for `IFolderExtractToStreamCallback`.
* **`finder` / `compress`**: the Explorer `CRC SHA-256 -> <name>.sha256` (C12) and
  `Test archive : Checksum` (C13) commands are `SZHasher.writeChecksumFile` and
  `SZHasher.verifyChecksumFile`; no update flow is needed for them.
* **anyone**: `Help.show(topic:)` for a dialog Help button.

---

## 7. Deliberate differences from Windows

1. **Link types.** macOS has hard links and POSIX symlinks only. `IDR_LINK_TYPE_JUNCTION 7714`
   and `IDR_LINK_TYPE_WSL 7715` are NTFS reparse-point flavours and are absent; the dialog says
   so in a footnote rather than silently dropping them. "File Symbolic Link" and "Directory
   Symbolic Link" both call `symlink(2)` and differ only in the kind check that produces
   "Incorrect link type", which is what the Windows check does too.
2. **The Link dialog completes a directory `from`.** When "Link from" names an existing
   directory (the single-panel case, where `AnotherPath` is the current folder), the target's
   base name is appended instead of failing with "Incorrect link type".
3. **Checksum-file verification is done in the bridge**, not by opening the file as a hash
   archive and testing it. `Codecs_AddHashArcHandler` *is* registered (`Agent.cpp:99`), so the
   archive route stays available for the `extract` scope; `verifyChecksumFile` parses the
   coreutils and BSD-tag forms itself and re-hashes each listed file, which keeps the check
   independent of the extract flow.
4. **`recursive: false`** (flat view) skips selected directories entirely instead of counting
   them as folders with no contents, because a flat listing already contains every file.
5. **`IDT_BENCH_SYS1` / `SYS2` are empty**: upstream `GetSysInfo` is `_WIN32`-only. The Darwin
   version and page size are part of `cpuFeaturesText` instead, and the empty statics are hidden.
6. **The temp-files browser lists `NSTemporaryDirectory()`**, the app's own per-user container,
   and its filter matches `7z` + `E|O|S` + 8 hex characters as on Windows. There is no
   `Open Outside : 7-Zip` *new process*: the item is opened in the current window instead
   (a notification the window controller answers).
7. **Benchmark "Total Rating" appears only after the last pass**, as on Windows; the port has no
   `IDD_BENCH_2 17600` small-screen variant (the window is resizable).

---

## 8. Known gaps

* `ToolsPanelAccess.operatedItems(of:)` reads the panel's selection through its `NSTableView`
  and maps rows by displayed name, because `PanelViewController`'s selection helpers are
  `private` and belong to the `panel` scope. It is correct (names are unique inside a folder)
  but should become a one-line forward once `panel` exposes the operated items.
* `Mac/App/Dialogs/ToolsTempFilesDialog.swift` and `Mac/Core/SZSplitFile.{h,mm}` are new paths
  this scope claims; they are not in the Wave 2 ownership table (which lists only
  `Hash*/Benchmark*/Split*/Combine*/Link*/About*` under `Dialogs/` and `SZHasher`/`SZBenchmark`
  under `Core/`). Both names are `tools`-specific, so merges stay trivial.
* `-mm=*` total mode is implemented (`BenchmarkDialog.run(totalMode: true)`) but no menu item
  reaches it: `IDM_BENCHMARK2 902` exists only in the Windows CE build (01 §2.5).
* Sorting in the temp browser is by header click and Cmd+F3/F5/F6 only; there is no persisted
  sort order (Windows does not persist it either).
* No bundled HTML help ships yet, so `Help.show` falls back to the online documentation. Drop
  the CHM contents into `Mac/Resources/Help/` and the same topic paths resolve locally.

---

## Note — 2026-09-20 (`mac/cleanup`)

* **§8's first gap is closed.** `ToolsPanelAccess.operatedItems(of:)` no longer reads the panel's
  `NSTableView`: it calls `ActiveContext.current()`, the frozen `OperationContext` contract, like
  the `extract` and `compress` command scopes. `ToolsPanelItems.rows: [PanelRow]` is therefore
  gone; it is now `items: [ToolsPanelItems.Item]` with `index` / `name` / `path` / `isDirectory`
  (`names` and `fullPaths` are unchanged). The panel argument is still taken, for `panel.flatMode`
  alone — the contract does not carry it and `CApp::CalculateCrc2` needs it as
  `CDirEnumerator::EnterToDirs = !flatMode`.
* **The `extract` scope's `-scrc` now reuses this scope's rows.** The
  `CHashBundle → SZHashResults` conversion stays in `SZHasher.mm` and is exported through the new
  `Mac/Core/Internal/SZHashBundleBridge.h`:

  ```objc
  SZHashResults *SZHashResultsFromBundle(const CHashBundle &, NSArray<SZHashFileResult *> *,
                                         NSArray<SZHashResultRow *> *leadingRows);
  SZHashResultRow *SZMakeHashResultRow(NSString *name, NSString *value);
  NSString *SZHashSizeValueString(uint64_t size);
  ```

  `leadingRows` is how `ExtractGUI` prepends `Archives:` / `Packed Size`; the CRC command passes
  nil, so §3's row order is unchanged. Anyone else who has a `CHashBundle` should use this rather
  than rebuild the rows.

Verified in the running app: File > CRC > CRC-32 on a file-system selection, on a whole folder and
on an item inside an archive, each matching the console `7zz` value — screenshots
`Mac/docs/reports/screenshots/cleanup-01..03-*.png`, details in `Mac/docs/reports/cleanup.md`.

---

## Note — 2026-10-03 (`mac/opsgaps`)

* **§8's last gap is closed: the help is bundled.** `Mac/Resources/Help/` holds the 78 pages of the
  shipped `7-zip.chm` (unpacked by `Mac/scripts/fetch-assets.sh`, pinned hash) and is copied into
  every app target. `Help` (in `AboutDialog.swift`) now has a constant for every Windows `kHelpTopic`
  (`start`, `contents`, `benchmark`, `tempFiles`, `add`, `addOptions`, `extract`, `optionsSystem`,
  `optionsMenu`, `optionsFolders`, `optionsEditor`, `optionsSettings`, `optionsLanguage`, `plugins`),
  `url(for:)`, `bundledURL(for:in:)` (case-blind, anchor kept, refuses `..`) and `show(topic:)`, which
  opens the page in the default browser. `Help.opener` replaces the launch in tests.
* **`HashListDialogView` is view-based**: each cell is an `NSTableCellView` with a label, so rows are
  visible to accessibility (and XCUITest); `displayedRows` returns what the list shows.
