# Testing

Three kinds of tests, all run through `Mac/scripts/test.sh` (which builds first):

| Command | Target | What | Where it runs |
|---|---|---|---|
| `Mac/scripts/test.sh` | `SevenZipKitTests` (`Mac/Tests/SevenZipKitTests/`) | unit tests of the bridge against the fixture archives in `Mac/Tests/Fixtures/` | anywhere, including CI |
| `Mac/scripts/test.sh -H` | `SevenZipAppTests` (`Mac/Tests/AppTests/`) | app-hosted tests: XCTest inside the running app, with real windows, dialogs, menus and all 93 languages, but no synthesized input | a logged-in GUI session |
| `Mac/scripts/test.sh -u` | `7-ZipUITests`, `7-ZipUITestsProbe1/2` (`Mac/Tests/UITests/`, `UIProbe1/2/`) | XCUITest: real clicks and keys against a launched app | **local only**: a GUI session you are not using, with permissions granted (below) |

Other useful forms:

```sh
Mac/scripts/test.sh -o ExtractorTests                    # one class (its target is looked up)
Mac/scripts/test.sh -o ExtractorTests/testExtractEveryFormat   # one test
Mac/scripts/test.sh --all                                # every target, one after another
Mac/scripts/verify.sh                                    # clean build + every suite + summary
```

Logs go to `Mac/build/test-<target>.log`, result bundles to `Mac/build/results-<target>.xcresult`.

## UI tests need permissions

XCUITest drives the app through the accessibility system, so it needs the machine:

- Developer mode: `sudo DevToolsSecurity -enable` (check with `DevToolsSecurity -status`).
- If every UI run stops at an authorization prompt or times out before the first test, enable
  automation mode once: `sudo automationmodetool enable-automationmode-without-authentication`.
- Leave the keyboard and mouse alone while the input shard runs: macOS delivers synthesized input to
  the frontmost app.

They are not suitable for a hosted CI runner. The app-hosted tests cover most of the UI without
synthesized input; the XCUITest suite checks what only real input can show.

## Screenshots

Tests write their screenshots to `Mac/build/screenshots/` (git-ignored); the UI tests attach them to
the result bundle and `test.sh` exports them there. Nothing a test writes ends up in git.

The images in [`docs/images/`](images/) are retaken with `Mac/scripts/showcase.sh`: it builds a
neutral demo folder in `/Users/Shared/7-Zip Demo/`, renders the windows (opt-in tests
`ShowcaseScreenshotTests` and `ShowcaseUITests`) and copies the results into `docs/images/`. Look
at every image before committing it: no user name or machine detail may be visible.

## Reference-data tests

A few app-hosted tests compare the Mac app with captures of the Windows 7-Zip File Manager (the
`WinCompare*`, `ListFeel*`, `DlgFeel*`, `Feel3Font*` families). The Windows captures are not in the
repository; a test that needs one skips itself when it is missing. To regenerate, for example,
`Feel3FontTests/testFontComparisonImages`: capture 7zFM 26.03's Details list (760 × 200 px at
96 dpi, the fixture of the test's `makeFixture()`) on Windows, save it as
`Mac/build/screenshots/wincompare-listfeel-list-win.png` and run that test. How the captures were
made originally is in [`ai/reports/wincompare.md`](../ai/reports/wincompare.md) and
[`ai/reports/listfeel.md`](../ai/reports/listfeel.md).

## Several runs at once

`SEVENZIP_DEFAULTS_SUITE` gives a run its own preferences domain, and the app-launch lock
(`.worktrees/.app-lock`, override with `SEVENZIP_APP_LOCK`) serializes the runs that launch the
app; the scripts take it themselves. Details in [`ai/test-support-contract.md`](../ai/test-support-contract.md)
and [`ai/api/harness.md`](../ai/api/harness.md).
