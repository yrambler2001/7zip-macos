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
