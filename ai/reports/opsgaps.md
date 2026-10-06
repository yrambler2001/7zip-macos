# `opsgaps` — operation-level gaps from `parity.md`

> **Publication note:** this report was written when it lived in `Mac/docs/reports/`. Its screenshots were removed from the repository before publication; a few showcase images live on in `docs/images/`, and the tests now write their screenshots to the git-ignored `Mac/build/screenshots/`. Paths below that point at removed images are kept as a record of what was measured.

Branch `mac/opsgaps`, off `macos` at `69f2a88`, 2026-10-03. Closes `parity.md` D items 2, 3, 4 (panel
half) and 8, and the cheap `requests.md` rows addressed to `opsinfra` / `extract` / `tools`.
Summary for users: `parity.md` section H. Specification: `01 §2.6, §8.7, §9 #17, §9 #23`,
`01b §4.17, §4.19`, `03 §2.6`.

## 1. Bundled help (`01 §2.6, §9 #17`) — IDM_HELP_CONTENTS 960 and every IDHELP button

**Source.** Windows ships `7-zip.chm`; its HTML is not in `DOC/` (only `7zip.hhp`). The pinned
installer `7z2603-x64.exe` that `fetch-assets.sh` already verifies contains it, so the script now
also checks `7-zip.chm`'s own SHA-256 (`e0b70a83…22cb`), unpacks it with the tree's `7zz` (7-Zip reads
CHM), checks the expected 78 `.htm`/`.css` files and every `kHelpTopic` target, and copies only those
into `Mac/Resources/Help/` (the `#SYSTEM`, `$WW*` index streams and the `.hhc`/`.hhk` sitemaps mean
nothing to a browser). The pages are committed like `Lang/`, so the build needs no network. Re-running
the script reproduced the committed `Lang/` and `SFX/` byte for byte.

**Bundling.** `Resources/Help` is a `type: folder` resource of the `7-Zip` target and of the
`SevenZipTestApp` template (`Mac/project.yml`, harness-owned; additive, recorded in `requests.md`), so
`Contents/Resources/Help/fm/index.htm` exists in the app and in the test hosts.

**Opening.** `Help.show(topic:)` (in `AboutDialog.swift`) resolves the topic case-blind — half the
Windows sources say `FM/`, the CHM's folder is `fm/`, and HtmlHelp does not care — keeps the anchor
(`fm/options.htm#editor`), refuses `..`, and opens the `file://` URL in the **default browser**
(`urlForApplication(toOpen: https://…)` + `open(_:withApplicationAt:)`, because handing a `.htm` to
`NSWorkspace.open` gives it to whatever owns that type and may drop the fragment). An Apple Help Book
was rejected: it needs a separate `.help` bundle, an `hiutil` index rebuilt on every content change
and Help Viewer's registration cache, which is keyed by bundle identifier and goes stale for ad-hoc
signed and renamed copies such as the three test apps; the CHM pages are HTML 3.2 that any browser
renders. With no bundled page the old online fallback remains.

**Buttons.** Every Windows `kHelpTopic` is a `Help` constant with its source line:

| Where | Windows | Before | Now |
|---|---|---|---|
| Help ▸ Contents (F1) | `kFMHelpTopic "FM/index.htm"` (MyLoadMenu.cpp:38) | online site | bundled |
| Options, each page | `k*Topic` (SystemPage.cpp:39, MenuPage.cpp:41, FoldersPage, EditPage.cpp:28, SettingsPage.cpp:45, LangPage.cpp:28) | `NSLog` + beep | the page's own topic and anchor |
| Extract | `fm/plugins/7-zip/extract.htm` (ExtractDialog.cpp:414) | 7-zip.org | bundled |
| Compress | `fm/plugins/7-zip/add.htm` (CompressDialog.cpp:1254) | 7-zip.org | bundled |
| Compress Options | `…add.htm#options` (CompressDialog.cpp:1255) | 7-zip.org | bundled |
| Benchmark / About / temp browser | `fm/benchmark.htm`, `start.htm`, `fm/temp.htm` | online site | bundled |

The Options anchor `#sevenZip` has no matching `<A name>` in `options.htm` — the same in Windows,
where it also lands at the top of the page.

## 2. Quarantine on ordinary extraction (`01 §9 #23`, `-snz`, Options ▸ 7-Zip "Propagate Zone.Id stream")

**Diagnosis.** Every caller already passed the mode (`ExtractCommands.applyZoneMode`, `-snz` in
`CommandExecutor`, Finder's `-snzN`), but the engine's zone code is `#if defined(_WIN32)`, so it
reached nothing. Post-processing from the bridge would have to guess which files a run wrote (the
engine alone knows each disk path at `CloseFile` time, after the overwrite and rename decisions).

**Fix.** A guarded upstream patch (`Mac/docs/upstream-patches.md`, diff appended to
`upstream-patches.diff`): the five zone guards in `ArchiveExtractCallback.h/.cpp`, `Extract.cpp` and
`Agent.cpp` become `(_WIN32 && !UNDER_CE) || __APPLE__`, and `ReadZoneFile_Of_BaseFile` /
`WriteZoneFile_To_BaseFile` get an `__APPLE__` body over `getxattr`/`setxattr("com.apple.quarantine")`.
Windows compiles exactly what it did. So the Windows policy applies unchanged: **All** = every
extracted file, **Office files only** = upstream's `kOfficeExtensions`, **None** = nothing, and an
archive without the attribute propagates nothing (no invented quarantine).

**Panel paths.** `CPanel::CopyTo` sets `IFolderSetZoneIdMode` / `IFolderSetZoneIdFile` before every
`CopyTo` (PanelCopy.cpp:76-92, :188-198). `SZFolderOperations` now does the same: the plain
`copyItems` / `moveItems` read `Options.WriteZoneIdExtract` (`NeedRegistryZone`), and a
`zoneMode:zoneSourcePath:` variant exists for copy and for `extractItems`. Extract inside an archive
uses it; drag-out and temp-open keep None / their own handling, as `PanelDrag.cpp:2887` and
`PanelItemOpen.cpp` do; test mode never stamps.

**Verified.** `QuarantineExtractTests` (6, SevenZipKitTests): a 7z with `readme.txt`, `report.docx`,
`sub/inner.txt` whose file carries a quarantine value → All marks all three with the identical
value, Office only the `.docx`, None none, an unquarantined archive none; F5-style `copyItems` with
All then None (the policy is reset per call); an explicit `zoneSourcePath` wins.

## 3. Dock-tile progress (`01b §4.17`, ITaskbarList3)

`ProgressDockTile` + `ProgressDockTileView` (`Mac/App/Dialogs/ProgressDockTile.swift`): the app icon
with a rounded bar along the bottom. `OperationRunner` registers when its Progress dialog appears
(fast `waitMode` runs never show one, like Windows), updates on the 200 ms tick, and unregisters on
finish (`OnExternalCloseMessage` → TBPF_NOPROGRESS, even when the dialog stays open for its messages),
failure and cancel. Several operations (nested runs) are combined as bytes done / bytes total; the
colour is TBPF_ERROR red once any has shown messages, TBPF_PAUSED yellow when every one is paused,
else blue. The tile is only redrawn on a whole-percent or state change.

**Found on the way:** `cancelActiveOperations()` (test reset) ended the modal session before the
worker had seen `E_ABORT`, so `run` returned a nil outcome and raised a critical "The operation did
not produce a result" alert — which hung the first version of the Dock test. The runner now spins the
run loop until the worker has finished before returning, as `CProgressDialog` never returns before
its thread does.

**Verified.** `testDockTileCombinesSeveralOperationsAndClears` (two owners, fractions, the three
states, idempotent `end`, `NSApp.dockTile.contentView` back to nil),
`testDockTileFollowsARealOperationAndClearsOnCancel` (a real `OperationRunner.run`, sampled from
inside its modal session, cancelled at ≥ 25 %), and `testDockTileRendering`, which renders the three
colours to `screenshots/opsgaps-dock-tile.png` (`screencapture` is denied on this machine, and the
Dock itself cannot be screenshotted from a test).

## 4. Error → message mapping (`01 §8.7`)

Measured first: the per-item and per-archive texts the GUI shows already come from the lang files —
`CSZCallbackBase::ReportOperationResult` calls upstream's `SetExtractErrorMessage` (3721-3729:
unsupported method, data error, CRC failed, …encrypted variants, unavailable data, unexpected end,
data after end, is not archive, headers error, wrong password), and `SZExtractor` builds the open
errors from 3005 / 3006 / 3017 / 3018 / 3019 (`ExtractorTests.testTestCorruptedArchiveReportsCrcError`,
`testWrongPassword`, `testTestTruncatedArchiveReportsOpenError`). What differed was the *fatal* path:

* `OperationRunner.failureMessage(for:)` = `CProgressThreadVirt::Process` + `HResultToMessage`,
  reusing `SevenZipFailureLadder.classify` (the command half): E_ABORT silent, out-of-memory in any
  spelling → lang 3000, `catch (int)` "Internal Error #N" → "Error #N", `catch (...)` → "Error",
  otherwise the engine text. The runner's critical alert uses it (`requests.md` row, `cmdmode` →
  `opsinfra`).
* `SZExtractor.mm`: E_OUTOFMEMORY with no engine text gets lang 3000, as `SZUpdaterError` /
  `SZHasherError` do (`cmdmode` → `extract` row).
* Not applicable: `ErrorPaths` (up to 32 appended paths) has no producer in the port.

`testFailureMessageIsHResultToMessage` covers each arm.

## 5. The panel's Test button and checksum files (`03 §2.6`, parity D item 4)

`ExtractCommands.testArchives()`: when every operated item has an extension of the hash
pseudo-format (`SZCodecs.format(named: "hash").extensions`), it runs
`CommandExecutor.run(argv: ["t", "-thash", "--", …])` — the C13 / Finder command line — instead of the
archive test. Measured with `7zz`: plain `t x.sha256` and `t -thash x.sha256` both verify and both
report `CRC Failed : a.txt` on a mismatch, so this changes the presentation (the checksum verification
box instead of archive statistics), not the verdict. The other half of the request — a hash method
for an ordinary Test — was **deliberately not added**: 7zFM's Test is `::TestArchives(paths)` with no
`-scrc` (Panel.cpp:1176), so there is no Windows control to mirror; `t -scrc` works in command mode.

## 6. Small `requests.md` rows

* **done** `HashListDialogView` accessibility (`finder` → `tools`): view-based cells with a real
  `NSTextField`, accessibility label = text, `displayedRows` for tests.
* **done** the `test` URL host (`fastui` → `resetcmd`): `URLCommands.handle` drops an unparsable
  `sevenzip://test/…` with an `NSLog`, no alert. `CommandURL.parse` is unchanged (its tests still see
  the throw).
* **done** the two `cmdmode` rows of §4.
* **left open**, filed or already filed: `ListViewDialog.swift` (Properties / Folders History) is still
  cell-based (panel); the explicit outermost-archive zone source for F5 (panel); dialog placement
  centring on the screen (`polish` → opsinfra: `DialogKit.install` does centre on its parent, the
  offenders pass `parent: nil` from their own call sites, which belong to other scopes); the About
  logo asset (icons); SFX in the framework resources (harness).

## 7. Verification

| What | Result |
|---|---|
| `Mac/scripts/build.sh` | clean, no new warnings in `Mac/` |
| `Mac/scripts/test.sh` (SevenZipKitTests) | 348 passed, 0 failed |
| `Mac/scripts/test.sh -H` (SevenZipAppTests) | 57 passed, 0 failed |
| new: `QuarantineExtractTests` | 6/6 |
| new: `OpsGapsTests` | 11/11 |

No XCUITest was needed: every new behaviour is reachable in process. Help is asserted without
launching a browser (`Help.opener` captures the URL).

## 8. Files touched outside `opsinfra` ownership

* upstream (guarded, recorded): `CPP/7zip/UI/Common/ArchiveExtractCallback.{h,cpp}`,
  `CPP/7zip/UI/Common/Extract.cpp`, `CPP/7zip/UI/Agent/Agent.cpp`; `Mac/docs/upstream-patches.{md,diff}`
* `extract`: `Mac/Core/SZExtractor.mm`, `Mac/App/Commands/ExtractCommands.swift`, `Mac/App/Dialogs/ExtractDialog.swift`
* `tools`: `Mac/App/Dialogs/AboutDialog.swift` (`Help`), `Mac/App/Dialogs/HashResultsDialog.swift`
* `options`: `Mac/App/Dialogs/OptionsWindow.swift`
* `finder`: `Mac/App/Integration/URLCommands.swift`
* `compress` (one Help call each, not in the allowed list): `Mac/App/Dialogs/CompressDialog.swift`,
  `Mac/App/Dialogs/CompressOptionsSheet.swift`
* `harness`: `Mac/scripts/fetch-assets.sh`, `Mac/project.yml` (additive `Resources/Help`)
* new: `Mac/Resources/Help/**` (78 files), `Mac/Tests/SevenZipKitTests/QuarantineExtractTests.swift`,
  `Mac/Tests/AppTests/OpsGapsTests.swift`
* docs: `parity.md`, `requests.md`, `PROGRESS.md`, `api/{opsinfra,extract,tools}.md`, this report

## 9. Follow-ups

* Human check: open Help ▸ Contents and an Options page's Help in a real session (the default browser
  is never launched by the tests), and watch the Dock icon during a large extraction.
* `panel`: pass the outermost archive as `zoneSourcePath` on F5; make `ListViewDialog` view-based.
