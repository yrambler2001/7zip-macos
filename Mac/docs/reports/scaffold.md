# Scaffold report (Wave 1) — work-in-progress state notes

(Compaction-safety log. Final form is written in Phase 4.)

## State after Phase 1 (core library)

- `Mac/project.yml` exists with targets SevenZipCore, SevenZipKit, 7-Zip, FinderSync, SevenZipKitTests
  (only SevenZipCore has been built so far).
- Upstream patches from `02-engine-api.md` §4.2 applied with `git apply` (9 files), recorded in
  `Mac/docs/upstream-patches.md` (+ `upstream-patches.diff`).
- `Mac/Core/Platform/`: `SevenZipCoreMac.cpp` (MyInitGuid once, `CompareFileNames_ForFolderList`,
  `SetExtractErrorMessage`, `NWindows::MyLoadString` -> `g_SZ_LoadStringHook`), `ZipRegistryMac.cpp`
  (all `ZipRegistry.h` accessors over CFPreferences), `MacPrefs.{h,cpp}` (CFPreferences helpers),
  `PlatformHooks.h`.
- Scripts: `Mac/scripts/{build,test,run,make-fixtures}.sh`.
- Builds: `xcodebuild -target SevenZipCore` -> BUILD SUCCEEDED, 0 errors, `libSevenZipCore.a` 32 MB
  (Debug, -O2), `_LzmaDec_DecodeReal_3` present from the arm64 assembly.
- Next: Phase 2 — SevenZipKit bridge (`Mac/Core/include/*.h`, `Mac/Core/*.mm`, `Mac/Core/Internal/*`),
  fixtures via `make-fixtures.sh`, tests in `Mac/Tests/SevenZipKitTests`.
