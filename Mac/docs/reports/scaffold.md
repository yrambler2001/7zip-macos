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

## State after Phase 2 (SevenZipKit bridge)

- Framework `SevenZipKit` builds; public headers in `Mac/Core/include/` (umbrella `SevenZipKit.h`);
  implementations `Mac/Core/*.mm`; C++ folders `Mac/Core/Internal/{FSFolderMac,RootFolderMac,FSEventsWatcher}.cpp`;
  `Internal/SZEngine.h` is the only place engine headers enter ObjC++ (BOOL macro-renamed).
- Classes: SZCodecs/SZFormatInfo, SZErrors (+SZErrorDomain/SZErrorCode), SZFolder/SZPropertyInfo/SZArcProps,
  SZFileSystemFolder, SZRootFolder, SZArchive/SZArchiveOpener/SZPasswordDelegate, SZLang/SZLanguageInfo,
  SZSettings/SZWorkDirSettings, SZProgressDelegate (protocol only), SZTypes.h enums.
- Nested archives: item stream when the handler has IInArchiveGetStream, else temp extraction (7zO-* dir).
- Fixtures in `Mac/Tests/Fixtures` (make-fixtures.sh); `Mac/scripts/test.sh` -> 17 tests pass.
- Next: Phase 3 — app shell in `Mac/App/` (AppDelegate, MainMenu, MainWindowController, PanelViewController,
  Support/{Lang,Settings,Formatting}.swift), `Mac/FinderSync/` stub, Info.plists, app icon, screenshots.
