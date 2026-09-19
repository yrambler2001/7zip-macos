# `extract` scope — progress notes

Branch `mac/extract`, worktree `.worktrees/extract`. Deliverables per
`Mac/docs/00-orchestration.md`; checklist is `Mac/docs/PROGRESS.md` section 4.

## Phase 1 — extraction bridge (done)

**Exists**

- `Mac/Core/include/SZExtractor.h` / `Mac/Core/SZExtractor.mm`: `SZExtractOptions`,
  `SZExtractStatistics`, `SZExtractResult`, `SZExtractor`. The implementation calls the
  engine's own `Extract()` (`CPP/7zip/UI/Common/Extract.cpp`) — the function 7zG runs — so path
  modes, overwrite modes, `-spe` duplicate-root elimination, `*` substitution in the output
  directory, multi-volume accounting and every error text are the Windows product's, not a
  reimplementation.
- The two callbacks `Extract()` needs: the shared `CSZExtractCallbackAdapter` (opsinfra) as the
  COM `IFolderArchiveExtractCallback`, plus `CSZExtractUICallback` (in `SZExtractor.mm`) as the
  non-COM `IExtractCallbackUI` + `IOpenCallbackUI` pair. They share password, delegate and error
  counters, which on Windows is one object (`CExtractCallbackImp`).
- `OpenResult_GUI` ported verbatim (multi-level open-error text, `k_ErrorFlagsIds` table).
- Test statistics summary (`SZExtractResult.testSummary`) formatted exactly like
  `GUI/ExtractGUI.cpp:137-158`, ready for `OperationRunner.Options.okMessage`.
- `SZExtractor.subfolderName(forArchiveNamed:)` = `GetSubFolderNameForExtract`
  (Explorer/ContextMenu.cpp:448, Windows-only code, reimplemented).
- `SZExtractProgressTap` records every message so a caller without a delegate (tests, Finder)
  still gets diagnostics; it mirrors the wrapped delegate's `respondsToSelector:` so the
  adapters' optional-callback probing keeps working.
- `Mac/Tests/Fixtures/multi.7z.001..003`: new 3-volume 7z fixture (random.bin 30000 B + vol.txt).

**Builds** `Mac/scripts/build.sh` → BUILD SUCCEEDED, no warnings in `Mac/`.

**Verified** `Mac/scripts/test.sh` → 92 tests, 0 failures (25 new in
`Mac/Tests/SevenZipKitTests/ExtractorTests.swift`): every fixture format, all four path modes,
all five overwrite modes (including the `.ask` answers and Cancel → `E_ABORT`), password
up-front / through the delegate / wrong / cancelled, multi-volume (also with every volume
passed), cancellation mid-run, test of a good archive with the summary text, of a
CRC-corrupted archive and of a non-archive, the sub-folder-name rules, `createOutputDirectory`.

**Spec correction found:** the engine's `AutoRenamePath`
(`CPP/7zip/Common/FilePathAutoRename.cpp`) produces `readme_1.txt`, not `name (2).ext` as
01 §8.4 claims. Logged in `Mac/docs/requests.md`.

**Next** Phase 2: the Extract dialog (`Mac/App/Dialogs/ExtractDialog.swift`).
