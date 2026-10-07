# Testing

Three kinds of tests, all run through `Mac/scripts/test.sh` (which builds first):

| Command | Target | What | Where it runs |
|---|---|---|---|
| `Mac/scripts/test.sh` | `SevenZipKitTests` (`Mac/Tests/SevenZipKitTests/`) | unit tests of the bridge against the fixture archives in `Mac/Tests/Fixtures/` | anywhere, including CI |
| `Mac/scripts/test.sh -H` | `SevenZipAppTests` (`Mac/Tests/AppTests/`) | app-hosted tests: XCTest inside the running app, with real windows, dialogs, menus and all 93 languages, but no synthesized input | **local only**: a logged-in GUI session ([why not on GitHub](#why-the-app-hosted-tests-do-not-run-on-github)) |
| `Mac/scripts/test.sh -u` | `7-ZipUITests`, `7-ZipUITestsProbe1/2` (`Mac/Tests/UITests/`, `UIProbe1/2/`) | XCUITest: real clicks and keys against a launched app | **local only**: a GUI session you are not using, with permissions granted (below) |

Other useful forms:

```sh
Mac/scripts/test.sh -o ExtractorTests                    # one class (its target is looked up)
Mac/scripts/test.sh -o ExtractorTests/testExtractEveryFormat   # one test
Mac/scripts/test.sh --all                                # every target, one after another
Mac/scripts/verify.sh                                    # clean build + every suite + summary
```

Logs go to `Mac/build/test-<target>.log`, result bundles to `Mac/build/results-<target>.xcresult`.

## The Intel slice (Rosetta)

The release is universal. `-A x86_64` runs any suite on the x86_64 slice under Rosetta 2 (install it
once: `softwareupdate --install-rosetta --agree-to-license`), built into
`Mac/build/DerivedData-x86_64` so the native build stays:

```sh
Mac/scripts/test.sh -A x86_64          # unit tests on x86_64
Mac/scripts/test.sh -A x86_64 -H       # app-hosted tests on x86_64
```

## No network

No test reaches the network. The update check (`UpdateCheckTests`) runs against a stubbed
`UpdateFetching`, and the app never starts a check of its own in a test process (`SZ_TEST_SUPPORT`,
an XCTest host, or any copy of the app with a test bundle identifier).

## UI tests need permissions

XCUITest drives the app through the accessibility system, so it needs the machine:

- Developer mode: `sudo DevToolsSecurity -enable` (check with `DevToolsSecurity -status`).
- If every UI run stops at an authorization prompt or times out before the first test, enable
  automation mode once: `sudo automationmodetool enable-automationmode-without-authentication`.
- Leave the keyboard and mouse alone while the input shard runs: macOS delivers synthesized input to
  the frontmost app.

They are not suitable for a hosted CI runner. The app-hosted tests cover most of the UI without
synthesized input; the XCUITest suite checks what only real input can show.

## Why the app-hosted tests do not run on GitHub

CI ([`ci.yml`](../.github/workflows/ci.yml)) runs only `SevenZipKitTests`, on both slices. The
app-hosted suite ran there as an informational job in the first public CI run (run 37554507307)
and was removed after it, because on a hosted `macos-26` runner it measures the runner, not the
app, and a job that is red on every push teaches people to ignore red:

- The runner's display is 1024 x 768 at 1x. Windows the tests size to 1200 x 800 or more are
  clamped to the screen, so the layout, column-width and pixel-colour assertions (`DateColsTests`,
  `MainWindowLayoutTests`, `SelColorsTests`, `Feel3Tests`, `RecheckTests`) see a different window.
- Settings the tests write into the host's throwaway domain (`Mac/build/hostapp-defaults.plist`)
  did not read back in that session: `FM.Panels.numPanels = 2` produced one-panel windows, and the
  toolbar mask, splitter position, panel paths and column layouts came back at the seeded values.
  Two tests then indexed the missing second panel and crashed the host (`ArchGapsTests`,
  `PanelGapsTests`), XCTest relaunched it twice, and 15 tests failed on the stale settings or the
  clamped window (`NewWindowTests`, `NavGapsTests`, `WinMatchTests`, `Recheck2Tests`, ...). All of
  them pass locally.
- None of that can be fixed or verified without a GUI session to debug in, and skipping the 15 on
  `CI=true` would leave a job that proves little while looking like coverage.

So the suite is local, like the XCUITest shards: run `Mac/scripts/test.sh -H` (or
`Mac/scripts/verify.sh`) before a pull request that touches `Mac/App/`, and before every release.

## Time zones

The fixture archives' timestamps are one instant, 2024-01-02 14:30:00 UTC
(`Mac/scripts/make-fixtures.sh` sets `TZ=UTC`), and the unit tests read them in UTC, so they pass
in any time zone. They once compared the local wall-clock hour with the 15:30 of a fixture made in
CET, which passed on the machine that made the fixtures and failed on the UTC CI runner. To check
a change against that class of bug, run the suite in another zone; `TEST_RUNNER_<NAME>` reaches the
test process as `<NAME>`:

```sh
TZ=America/Los_Angeles TEST_RUNNER_TZ=America/Los_Angeles Mac/scripts/test.sh
```

## Screenshots

Tests write their screenshots to `Mac/build/screenshots/` (git-ignored); the UI tests attach them to
the result bundle and `test.sh` exports them there. Nothing a test writes ends up in git.

The images in [`docs/images/`](images/) are full-window screenshots taken by hand with the macOS
screenshot tool (window capture, main window sized 870x500 pt). `Mac/scripts/showcase.sh` renders
reference shots of the same windows into `Mac/build/screenshots/` (opt-in tests
`ShowcaseScreenshotTests` and `ShowcaseUITests`, in the neutral folder `/Users/Shared/7-Zip Demo/`).
Look at every image before committing it: no user name or machine detail may be visible.

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
