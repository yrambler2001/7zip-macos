# testreg — UI tests address their own build, never the installed 7-Zip

Branch `mac/testreg` (from `macos` ec8262f). Scope: the test harness (`Mac/Tests/UIDriver`,
`Mac/scripts/test.sh`, `Mac/scripts/finderext-registration.sh`) plus the UI tests that reached the
wrong copy. No app code changed.

## 1. The problem, measured

`/Applications/7-Zip.app` now owns the Launch Services and PlugInKit registrations: finderfix
unregisters every build after a run. On this machine the UI suite then reached the user's app in
three ways:

| Where | What happened |
|---|---|
| `TestShard.appURL` | The bundle walk stopped one level short. On macOS the test bundle is `<Config>/<T>-Runner.app/Contents/PlugIns/<T>.xctest`, which is four levels below `<Config>`, not three. So the lookup fell back to `urlForApplication(withBundleIdentifier:)`, and that returned **/Applications/7-Zip.app**. Every "aimed" reopen and URL went to the installed app: the 3 `NewWindowUITests` failures in gmode §5. `GModeUITests` used the same URL too, so its earlier pass was probably against the installed copy. |
| `NewWindowUITests` Dock cases | The Dock shows two "7-Zip" tiles: the installed copy's recent-apps tile, then the running build's. The test clicked the first one, which launched `/Applications/7-Zip.app` (started 11:37:32, during `testDockClickRestoresTheMinimizedWindow`). |
| `FinderContextMenuTests` | By design, Finder drives whichever copy's extension is elected. On this machine that is the installed copy. Setup and teardown also `forceTerminate`d **every** `com.yrambler2001.7zip`, the user's running app included. |

Also, `SevenZipApp.open` fell back to an unaimed `NSWorkspace.open(URL)`. `XCUIApplication`
attaches to and terminates processes by bundle identifier, and the input shard's identifier is the
shipping one.

## 2. The fix (tests address their bundle; no registration juggling)

- **`TestShard.appURL`** looks for the bundle on disk only. It checks `SEVENZIP_APP_PATH`, then every
  ancestor of the test bundle, then `__XCODE_BUILT_PRODUCTS_DIR_PATHS`. It no longer falls back to
  Launch Services. nil is a failure.
- **`SevenZipApp.open`** uses only the two aimed channels: the state-dir request file, then
  `NSWorkspace.open(_:withApplicationAt: appURL)`. The `aimedOnly:` parameter is gone because
  every call is aimed now.
- **Guard** `TestShard.assertOnlyTestBuildRuns` (with `foreignInstances()`): a test fails loudly
  if any running 7-Zip is not this shard's build. That means its own bundle id at another path, or
  the shipping id outside this run's products directory. It runs in `SevenZipUITestCase` setUp
  (before the test touches anything), after every `launch`, in tearDown (to name a test that
  *started* one), and in `FinderContextMenuTests`.
- **`GModeUITests`**: if no bundle URL is found, it falls back to `XCUIApplication()` (the target
  app), not to a bundle-id lookup.
- **`FinderContextMenuTests`** only looks at and terminates this build's instances. Each case runs
  only if Finder uses *this build's* copy of the extension it needs. Otherwise it is skipped with
  the owning path in the message. The sandboxed runner can't ask PlugInKit, so `test.sh`
  (`finderext_mark`) writes `Mac/build/finderext-active` before the input shard: the test.sh pid
  (checked alive with `kill(pid, 0)`) and `id|appex` per extension. Finder windows are closed only
  if the test opened them.
- **Dock cases** are skipped when the Dock shows more than one "7-Zip" tile. XCUITest exposes neither
  `AXURL` nor the running indicator, and the sandboxed runner can't read the AX API (measured). One
  workaround was tried: open each tile's Dock menu and look for "Quit". It launched the installed
  app, so it was dropped.
- **`test.sh`**: before the input shard (classic and `--shards`), `require_no_foreign_sevenzip`
  refuses to run (exit 5) next to a 7-Zip that is not this tree's build. It never quits the
  user's app, and the shared preferences domain makes this necessary. Afterwards,
  `check_no_foreign_started` fails the run (exit 6) if one appeared. `quit_test_processes` sends
  TERM only to processes whose executable is under this tree's `Build/Products/`, and it also runs
  from the EXIT/INT/TERM trap. The old `pgrep '7-Zip.app/Contents/MacOS/7-Zip'` warning, which
  matched the installed app, is gone.

## 3. Tried and rejected: electing the build's extensions for the run

`finderext_elect` would make the build's appexes the copies Finder runs, with a crash-safe
hand-back file. Measured results:
1. `pluginkit -a` is a silent no-op while the other copy is registered. You have to remove the
   other copy first, and the app must be LS-registered (`lsregister -f`).
2. Even then, Finder **never loaded** the build's FinderSync (93 s; no launch attempt in the log),
   and the Quick Actions list had not refreshed ("Customize…" only).

It was unreliable, and it changes the user's Finder during a run. It was removed. The
hand-back to the installed copy via `finderext_restore` worked every time.

## 4. Verification (with `/Applications/7-Zip.app` installed)

| Run | Result |
|---|---|
| `test.sh` | 401 passed, 0 failed |
| `test.sh -u` | **71 passed, 0 failed**: input 59 passed + 7 skipped (5 `FinderContextMenuTests`: Finder runs the installed copy; 2 Dock cases: two 7-Zip tiles), Probe1 6/6, Probe2 6/6. The `NewWindowUITests` reopen cases pass. No foreign 7-Zip started. |
| `test.sh -H` | 263 passed, **1 failed**: `GModeTests.testWarmCommandDialogStandsAloneAndLeavesTheWindowsAlone` (`GModeTests.swift:104`: `DialogKit.owner(for: nil, parent: managerWindow)` returned the Compress `DialogWindow` itself, i.e. the key window). It fails alone too. This branch changes no app or AppTests code, and `-H` is unaffected by the harness changes (only the trap's `quit_test_processes` is new), so it belongs to the gmode/app scope: **for the orchestrator**. |

Afterwards: `pluginkit -mAvvv` lists FinderSync, QuickActionExtract and QuickActionCompress only
from `/Applications/7-Zip.app`. `urlForApplication(toOpen: sevenzip://…)` and `x-7zip://` resolve
to `/Applications/7-Zip.app`, and `urlsForApplications` lists only it. No 7-Zip process is running.
A stale Launch Services registration of the **main checkout's** Debug build
(`7zip/Mac/build/.../Debug/7-Zip.app`, outside this tree) was also listed as a candidate, so it was
unregistered with `lsregister -u`.

Machine clean-up during the work: `/Applications/7-Zip.app` was launched twice, by the old reopen tests and by the rejected Dock-menu probe
(pids 38156 and 39132). Both were started by the run and stopped with SIGTERM, so they saved nothing.
