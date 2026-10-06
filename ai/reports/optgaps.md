# `optgaps` — the Options / Compress / dialog backlog

Branch `mac/optgaps` (off `macos` at `2800082`). Scope: every open `requests.md` row addressed to
`options`, `compress`, the dialog half of `panel`, and `DialogKit` / `opsinfra`, plus parity.md
D items 11 and 12. Tests: `Mac/Tests/AppTests/OptGapsTests.swift` (13 cases, app-hosted).

## What was done

| Item | Windows reference | What changed |
|---|---|---|
| Options pages wider than the window (`fastui`) | 01b §4.22 | Wrapping labels reported their one-line width (System 941, Editor 1018 pt). `OptionsPageBase.install` caps them at 520 pt and `viewDidLayout` re-tells a narrower label its real width (capped, so the width cannot feed back into the fitting size). Plugins columns narrowed, 7-Zip page list min height 170 -> 120, window 660 x 520 -> 660 x 580. Widest page now 576 pt; tallest 566 pt. |
| System page icons (`icons`) | 01b §4.21, SystemPage.cpp:95 | `doc-<name>.icns` (16/32 px reps) per row. |
| System page single click / Return | SystemPage.cpp:369-396 | `table.action` toggles a row on a plain click in the state column (NM_CLICK, `uKeyFlags == 0`); Return = ChangeState(0) on the selection or all rows. The double-click action is gone (Windows has none: NM_DBLCLK is commented out). |
| System page LaunchServices refresh | SystemPage.cpp:325 | `associationsDidChange()` after the async requests answer: `lsregister -f` + `NSUpdateDynamicServices` (Services only under `SZ_TEST_SUPPORT`). |
| System / Language column widths (`packaging`) | — | `OptionsUI.sizeColumnsToContent`. |
| Language id lists, comments, load errors | LangPage.cpp:108-123, 197-262, 300-358 | `SZLang` does the merge walk per file (`missingLines` / `extraLines` as `<id> : <text>`, `comments`, `failedLanguageFiles`, `languages(inDirectory:failedFiles:)`). IDT_LANG_INFO is a scrolling text view with ShowLangInfo's exact text (50 rows per list, `;` stripped). Failed files: one "Error in Lang file" sheet on page load. The English entry is marked `---`. |
| IDT_LANG 2102 in `ar` | — | covered by the label cap (wraps, does not size the page). |
| Apply button localization | PSBTN_APPLYNOW (comctl32) | Decision: stays English. Windows takes it from the OS language, not the lang file; this app has no `.lproj`. |
| Menu page caption (IDD_MENU 2300) | .rc caption | Decision: stays "7-Zip" (the product name, and what Windows shows too). |
| `reloadLangItems()` on closed windows (`modalfix`) | — | skips windows neither visible nor miniaturized. |
| Bundle-derived prefs domain (`resetcmd`, MacPrefs.cpp) | test-support contract | `NMacPrefs::DefaultApplicationID()`: main bundle id when it is an `APPL`, else `com.yrambler2001.7zip`. No existing assertion changed (xctest is not an APPL). |
| Compress Browse filter (`cmdmode`, parity D 11) | CompressDialog.cpp:876-1016 | `CompressBrowseFilter` + an accessory "Save as type" pop-up. |
| `-sfx<module>` through the dialog (`cmdmode`) | UpdateGUI.cpp:517 | `sfxModulePath` on input and result; `CommandExecutor` fills both (post-dialog override kept). |
| Tools -> compress memory reuse (`tools`) | CompressDialog.cpp GetMemoryUsage_* | Declined: a different formula from the benchmark's; `CompressModel` already ports the right one. |
| ListViewDialog accessibility (`opsgaps`) | 01b §4.11 | view-based cells, as `HashListDialogView`. |
| RTL segment order (`packaging`) | — | `Bidi` isolates (FSI..PDI) each status-line part and each Copy-dialog name / "label: value", in an LTR label. |
| F5 out of a nested archive (`opsgaps`) | PanelCopy.cpp:156-180 | `copyItemsOut` passes the outermost archive as zone source. |
| Dialog placement (`polish`) | DS_CENTER | Cause: `NSApp.runModal(for:)` re-centres on the screen when it orders the window in; only the three dialogs that ordered themselves front first escaped. `DialogKit.window` now makes a `DialogWindow` whose `center()` centres on `DialogKit.owner(for:parent:)` (parent, key, main, the app's main window; screen only with none). Also used by Extract, Progress and Options. |
| Shared temp-dir row (`resetcmd`) | — | verified still in place. |

## Verification

* `Mac/scripts/build.sh`: clean (only the pre-existing `ld: ignoring duplicate libraries: '-lc++'`).
* `Mac/scripts/test.sh`: 348 / 348. `Mac/scripts/test.sh -H`: 70 / 70 (13 new in `OptGapsTests`).
* `testOptionsPagesFitTheirWindow` measures `fittingSize` of all seven pages in `-`, `de`, `ru`, `ja`,
  `ar`, `he`, `fr`, `uk` and fails on any overflow; it found the 7-Zip page's height need after the
  width fix. `testDialogsCentreOnTheirOwnerWindow` failed (854 vs 390) before `DialogWindow` and
  passes after.
* The XCUITest suite was not run (not required for this scope; nothing it drives changed shape).
* Screenshots: the regenerated `fastui-34-options-*.png` show the new Options pages (format icons,
  sized columns). The in-process capture draws some text layers poorly; no new `optgaps-*` shots.

## Files outside `options` ownership

`compress`: `CompressDialog.swift`, `CompressModel.swift`, new `CompressBrowseFilter.swift`.
`panel`: `ListViewDialog.swift`, `CopyMoveDialog.swift`, `PanelFormat.swift`, `PanelOperations.swift`,
`PanelViewController.swift` (status line only). `opsinfra`: `ProgressDialogSupport.swift` (DialogKit),
`ProgressDialog.swift`. `extract`: `ExtractDialog.swift` (one placement block). `finder`:
`CommandExecutor.swift` (two lines). Bridge: `SZLang.{h,mm}`, `SZSettings.{h,mm}`,
`Platform/MacPrefs.{h,cpp}` (unassigned). New shared helper: `Support/Bidi+OptGaps.swift`.

## Known gaps / follow-ups

* No test drives the nested-archive zone source end to end (call-site change on an API `opsgaps`
  tested); a closed main window that is reopened later keeps the toolbar of its old language.
* The Language load-error sheet is not exercised by a test (no bundled file fails); the scan is.
* `TestResetSettleTests`' toolbar stripping can go (filed for `resetcmd`).
