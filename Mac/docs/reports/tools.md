# `tools` scope report — hashes, Benchmark, Split/Combine, Link, About, Help, temp files

## State notes (appended per phase)

### Phase 1 — hashing bridge (done)

* `Mac/Core/Internal/SZToolsEngine.h` — the extra engine headers this scope needs
  (`HashCalc.h`, `Bench.h`, `Wildcard.h`, `EnumDirItems.h`, `System.h`, `SystemInfo.h`,
  `FileStreams.h`, `CreateCoder.h`, `MethodProps.h`, `Property.h`, `IFileExtractCallback.h`)
  behind the same `BOOL` rename guard `SZEngine.h` uses.
* `Mac/Core/include/SZHasher.h` + `Mac/Core/SZHasher.mm`
  * `SZHasher.availableMethods` enumerates the hashers through `GetHashMethods` +
    `CreateHasher` (10 in this build: CRC32, CRC64, SHA256, SHA1, BLAKE2sp, MD5, XXH64,
    SHA384, SHA512, SHA3-256) — nothing hard-coded except the CRC-submenu wording map.
  * `hash(paths:relativeTo:methods:recursive:progress:)` runs `HashCalc()` over a
    `NWildcard::CCensor` built from the operated items, exactly what `7zz h` does
    (02 §3.5 recommends this over 7zFM's panel-coupled `CThreadCrc`).
  * `hash(itemsIn:at:methods:progress:)` hashes archive members without extracting them:
    `IFolderOperations::CopyTo` with a private `IFolderExtractToStreamCallback`
    (`CSZHashStreamCallback`) that hands the Agent a hashing stream — the `streamMode` +
    `hashMethods` path of `PanelCopy.cpp:239-266`.
  * `SZHashResults` carries the ordered `rows` (`AddHashBundleRes`, 01b §4.27 wording, lang
    IDs 1004/1031/1032/1007/1070/1075/1076 and 7502/7503/7504 with `CRC` replaced and the
    colon removed), the `text` form with lang 3001 "There are no errors",
    `clipboardText(forRowsAt:)`, the three digest groups and the per-file digests.
  * `writeChecksumFile(...)` writes the coreutils `"<hex>  <name>"` lines the hash
    pseudo-format writes for `a -thash`; `verifyChecksumFile(at:progress:)` parses both that
    and the BSD `METHOD (name) = hex` tag form and re-hashes every listed file.
* `Mac/Core/include/SZBenchmark.h` + `Mac/Core/SZBenchmark.mm` — `Bench()` on a dedicated
  thread with `IBenchCallback` / `IBenchPrintCallback` / `IBenchFreqCallback`, the
  `CBenchProgressSync` snapshot behind a mutex, plus the CPU / OS / RAM / version strings.
* `Mac/Core/include/SZSplitFile.h` + `Mac/Core/SZSplitFile.mm` — `ParseVolumeSizes`,
  `GetNumberOfVolumes`, `CVolSeqName`, `CThreadSplit` and `CThreadCombine` on POSIX I/O.
* `Mac/Tests/SevenZipKitTests/HasherTests.swift` — 12 tests, all digests cross-checked
  against `7zz h`. Build and full test suite green (67 tests).

Next: the Swift UI (CRC submenu + results dialog, Benchmark, Split/Combine, Link, About,
Help, temp-files browser).

### Phases 2-4 — the UI (built, not yet driven live)

* `Mac/App/Dialogs/HashResultsDialog.swift` — `HashListDialogView` is the generic
  `CListViewDialog` (IDD_LISTVIEW 99): 1 or 2 columns, Del deletes rows when allowed,
  Cmd+A selects all, Cmd+C copies `"<name>: <value>"` lines, Enter/double-click shows the row
  in an info box for a 2-column list. `HashResultsDialog.show` is `ShowHashResults`: title
  lang 7501 "Checksum information", `DeleteIsAllowed = true`, `SelectFirst = false`.
  **The `panel` scope may lift `HashListDialogView` into its own `ListViewDialog.swift`** for
  Properties / archive info / Folders History; this file then just uses it.
* `Mac/App/Dialogs/BenchmarkDialog.swift` — every control of IDD_BENCH 7600: dictionary combo
  (2·2^n / 3·2^n, 256 KB … 4 GB, initial = largest 2^n from 32 MB down that fits RAM),
  memory-usage line, thread combo (1, 2, 4, 6 … 2× system, initial = process threads rounded
  down to even), pass combo (1, 2, 5, 10 … 10⁷), the Compressing / Decompressing Current and
  Resulting rows (size, CPU usage, speed, rating/usage, rating), Total Rating, elapsed time,
  pass counter, error line, CPU / version / features statics, the log column with the
  `Compr Decompr Total   CPU` table, Restart / Stop / Help / Cancel with the real enable and
  restart semantics, and the 1000 ms tick. Cancel asks the worker to exit and closes only
  after `waitUntilFinished`.
* `Mac/App/Dialogs/SplitDialog.swift`, `CombineDialog.swift` — IDD_SPLIT 7300 with the nine
  volume presets and free-text parsing, and the Combine destination dialog (a local stand-in
  for the `panel` scope's Copy dialog) with the detected-parts info block.
* `Mac/App/Dialogs/LinkDialog.swift` — IDD_LINK 7700 with the three link types macOS has and
  a footnote about Directory Junction / WSL.
* `Mac/App/Dialogs/AboutDialog.swift` — IDD_ABOUT 2900 plus `Help`, the topic opener
  (bundled `Contents/Resources/Help/<topic>`, else the online documentation).
* `Mac/App/Dialogs/ToolsTempFilesDialog.swift` — IDD_BROWSE2 93 temp browser.
* `Mac/App/Commands/ToolsCommands.swift` — the menu commands plus `ToolsPanelAccess`, which
  reads the operated items from the focused panel's public surface.

---

## Final report

### What was implemented

**Bridge (`Mac/Core`)**

| File | Contents |
|---|---|
| `include/SZHasher.h`, `SZHasher.mm` | `SZHasher` (method enumeration, file-system and archive hashing, checksum-file write/verify), `SZHashResults`, `SZHashResultRow`, `SZHashFileResult`, `SZHashMethod`, `SZChecksumVerification` |
| `include/SZBenchmark.h`, `SZBenchmark.mm` | `SZBenchmark` (worker thread over `Bench()`), `SZBenchmarkResult`, `SZBenchmarkPass`, the CPU / OS / RAM / version strings |
| `include/SZSplitFile.h`, `SZSplitFile.mm` | `SZSplitFile` (`ParseVolumeSizes`, `GetNumberOfVolumes`, `CVolSeqName`, split, combine), `SZSplitVolumePresets()` |
| `Internal/SZToolsEngine.h` | the extra engine headers behind the `BOOL` rename guard |
| `include/SevenZipKit.h` | three added `#import`s (additive) |

**App (`Mac/App`)**

`Dialogs/HashResultsDialog.swift` (+ the generic `HashListDialogView`),
`Dialogs/BenchmarkDialog.swift`, `Dialogs/SplitDialog.swift`, `Dialogs/CombineDialog.swift`,
`Dialogs/LinkDialog.swift`, `Dialogs/AboutDialog.swift` (+ `Help`),
`Dialogs/ToolsTempFilesDialog.swift`, `Commands/ToolsCommands.swift`
(+ one added line in `MainMenu.swift`).

### How it maps to Windows

* **File > CRC** (01 §2.1, §3.13): all eleven submenu items with their `IDM_*` ids; the
  file-system path runs `HashCalc()` (what `7zz h` runs), the archive path runs
  `IFolderOperations::CopyTo` in stream mode with a hashing stream, so nothing is extracted.
  Progress title is lang 7500 for the FS path and the method name for a single named method on
  the archive path, exactly as `PanelCopy.cpp:281-289` chooses it.
* **Hash results** (01b §4.27): the generic `CListViewDialog` with the Windows title,
  `DeleteIsAllowed`, `SelectFirst = false`, `Ctrl+C` as `"<name>: <value>"`, and the row order /
  wording of `AddHashBundleRes` (including `"<M> checksum for data and names"` built from lang
  7503 with `CRC` replaced and the colon removed).
* **Benchmark** (01b §4.26): in-process, one `Bench()` per pass, every control of `IDD_BENCH
  7600` including the memory-fit initial dictionary, the memory-usage guard, the log table and
  the Restart / Stop / Help / Cancel semantics; Cancel closes only after the thread ended.
* **Split / Combine** (01 §3.14, 01b §4.20): the nine volume presets, `ParseVolumeSizes`, the
  volume-size and >100-volume checks, `<name>.001…` naming with pre-allocation, first-volume
  detection, the parts info block and the existing-output check.
* **Link** (01b §4.10): the three link types macOS has, the default selection rules, the
  kind checks, the "hide the data of an existing file" refusal and link removal on an empty
  target; Junction and WSL are documented as absent.
* **About / Help** (01b §4.1, 01 §2.6): the real version / date / copyright / info lines, the
  home-page button, and `Help.show(topic:)` for every topic id.
* **Temp files** (01b §4.3): the `7z[EOS]<8 hex>` filter in the temp root, unfiltered
  sub-folders, per-directory counts with the 200/2000 limits and the `+` suffix, all six
  columns, the 6100-6105 confirmations, Refresh / Parent / Close / Help, the keyboard map and
  the context menu; symlinks are neither descended nor opened but can be deleted.

### What was verified

**Unit tests (`Mac/Tests/SevenZipKitTests`, 22 new tests; suite: 75 tests, 0 failures)**

* `HasherTests` (12): all ten methods' digests for a 30-byte fixture against
  `7zz h '-scrc*'`; `"*"` in one run; the multi-file data and data-and-names sums and every
  per-file digest against `7zz h -scrcSHA256`; the single-file row layout; hashing every item
  and one item inside `test.7z`; progress statuses and cancellation (`SZErrorCodeCancelled`);
  checksum-file write (byte-exact coreutils lines) and verify, including a tampered file, a
  missing file and the BSD tag form; the `.sha256` naming rule; the menu-id map.
* `BenchmarkTests` (3): the static information (RAM, limits, thread counts, CPU strings,
  `GetBenchMemoryUsage` monotonicity); a full pass producing non-zero speed / rating / usage /
  size with the right string formats and a log containing the header and the averages; Stop
  ending the worker with no error.
* `SplitCombineTests` (5): `ParseVolumeSizes` (suffixes, `-` terminator, lists, overflow, every
  preset), `GetNumberOfVolumes`, first-volume-name parsing and output naming, a 700 KiB split
  into 4 volumes of the right sizes and a **byte-identical** combine round trip, and a
  two-size volume list (100, then 300 repeating).

**In the running app** (`Mac/docs/reports/screenshots/tools-*.png`, 13 window captures)

* File > CRC > SHA-256 on `readme.txt` → rows `Name / Size / SHA256` with
  `948bc6f0…742c21c8`, identical to `7zz h`; Cmd+A + Cmd+C put
  `"Name: readme.txt\nSize: 12 bytes\nSHA256: …"` on the clipboard; Enter opened the row's info
  box; Del removed a row (5 → 4).
* File > CRC > `*` on one file → all ten methods in one dialog.
* Select All + SHA-256 over the whole folder → `Folders 2 / Files 6 / Size 703 339 bytes` and
  both sums byte-identical to `7zz h -scrcSHA256 big.bin notes.md readme.txt sub test.7z`.
* Inside `test.7z`, Select All + SHA-256 → `Files 4 / Size 3 043` and the same data sum as the
  file-system tree, with nothing written to disk.
* Tools > Benchmark → dictionary 32 MB (memory-fit choice), `2225 MB / 65536 MB`, 10 threads,
  `/ 10` hardware line, `Apple M1 Max 10C10T`, `7-Zip 26.03 (arm64)`, the Darwin+PageSize
  feature line, one pass in 10.3 s (compress 62.807 GIPS / 785 %, decompress 43.980 GIPS,
  total 53.394 GIPS / 755 %), the log with the frequency lines, the
  `Compr Decompr Total   CPU` header, the per-pass line, `-------------` and the averages.
  Restart re-enabled Stop; Stop disabled itself and the worker left; changing the pass combo
  to 2 restarted and the Resulting rows accumulated (320 MB / 3206 MB, `2 /` passes); Cancel
  during a run closed the window only after the thread ended.
* File > Split file… on a 700 000-byte file: `10M` (≥ the file) produced
  "Volume size must be smaller than size of original file"; `200k` produced
  `.001/.002/.003 = 204800` and `.004 = 85600`.
* File > Combine files… on `big.bin.001`: title `Combine Files big.bin.001`, info
  `Files: 4    ( 700 000 bytes )` with the first two parts, `...` and the last one; the result
  was **byte-identical** to the original (`cmp`).
* File > Link…: Hard Link preselected for a plain file; a hard link (link count 2) and, after
  selecting "File Symbolic Link", a real symlink pointing at `readme.txt`.
* Help > About → `7-Zip 26.03 (arm64)`, `2026-09-03`,
  `Copyright (c) 1999-2026 Igor Pavlov`, `7-Zip is free software`, Help / www.7-zip.org / OK.
* Help > Contents → the online documentation (`documentation.help/7-Zip/index.htm`).
* Tools > Delete Temporary Files…: `7zO12345678` and `7zEa1b2c3d4` listed (a
  non-matching directory was not), counts `3 files / 2 folders` with the symlink counted but
  not followed and the single-inner-item name in the sixth column; Enter entered a folder (its
  contents listed unfiltered) and Backspace came back; Parent disabled at the temp root;
  opening the symlink said "link openning was blocked by 7-Zip"; Cmd+A + Delete showed
  "Confirm Multiple File Delete … these 2 items" with the names and deleted both permanently.

### Bugs found and fixed during live verification

1. The Link dialog's radio buttons were created with a `nil` action, so AppKit did not group
   them and "File Symbolic Link" never took effect (a hard link was made instead). They now
   share an action, which is what `WS_GROUP` does on Windows.
2. The About dialog showed only `Igor Pavlov`: `SZEngineCopyrightString()` is compiled without
   `USE_COPYRIGHT_CR`. Added `SZBenchmark.engineCopyrightText` (`MY_COPYRIGHT`).
3. The temp browser had no key handling, so Enter / Backspace / Del / Cmd+A / Cmd+F3-F6 did
   nothing. Added `ToolsTempFilesTableView` with the `CBrowseDialog2` key map.

### Known gaps / follow-ups

* `PROGRESS.md` §6 has three boxes left open on purpose:
  * the `7zG h` **command-line** entry point (`HashCalcGUI`) — that is the CLI / `finder`
    scope's `7zG` grammar, not a File-manager command; the in-process path it shares is done.
  * `x` / `t` with `-scrc` — the `extract` scope owns that flow (request filed).
  * `IDD_BENCH_TOTAL` (`-mm=*`) — implemented and reachable via
    `BenchmarkDialog.run(totalMode: true)`, but no menu item exists because `IDM_BENCHMARK2 902`
    is Windows-CE-only (01 §2.5).
* `ToolsPanelAccess.operatedItems(of:)` reads the panel's selection through its table view;
  it should become a one-line forward once `panel` exposes the operated items (request filed).
* `HashListDialogView` should move to the `panel` scope's `ListViewDialog.swift` (request filed).
* No bundled HTML help ships yet, so `Help.show` uses the online documentation.
* The hash progress dialog only appears for runs longer than the 500 ms `WaitMode` delay, which
  is the Windows behaviour; a slow volume or a large tree shows it with Pause / Background /
  Cancel from `OperationRunner`.
* The temp browser's "Open Outside : 7-Zip" opens the path in the current window instead of a
  new process.
