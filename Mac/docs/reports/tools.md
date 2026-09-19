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
