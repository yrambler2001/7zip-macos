# `resetcmd` — report

Branch `mac/resetcmd`. Implements `Mac/docs/test-support-contract.md` in the app so the UI suite can
stop relaunching the app for every test. The public surface is `Mac/docs/api/resetcmd.md`; this file
is what was done, what was measured, and what is still wrong.

## 1. The answer to the question that motivated this

| | mean | min | max | n |
|---|---|---|---|---|
| reset, `path0` only | **0.409 s** | 0.142 | 0.585 | 10 |
| reset, `defaults` plist + panel switch + `view` | **0.548 s** | 0.294 | 0.754 | 10 |
| `terminate()` + `XCUIApplication.launch()` + wait for a panel | **3.892 s** | 3.620 | 4.278 | 3 |

Measured from inside XCUITest, which is what a test pays (`ResetCommandTests`
`testMeasureResetAgainstRelaunch`; three suite runs agreed within noise). **A reset replaces a
relaunch at about one seventh to one ninth of the cost, saving ~3.4 s per test.**

`SZ_DISABLE_ANIMATIONS=1` takes **0.43 s** off every dialog open-and-close cycle (1.322 s against
1.756 s over the same constant hash, six cycles each).

One number worth the orchestrator's attention: out of process, **a cold launch of the app itself costs
about 0.7 s** (driver: quit + relaunch + first reset, mean 0.710 s over 4 rounds). The 28.7 s-per-test
baseline is therefore almost entirely XCUITest's launch handshake and the suite's own per-test
overhead, not the app's start-up. Removing the relaunch removes ~3.9 s of it; whatever else makes a
test cost 28.7 s is `fastui`'s to find, and the reset alone will not deliver the whole win.

## 2. What was implemented

**Phase 1, the switches.** `SZ_TEST_SUPPORT` gates everything. `SZ_DISABLE_ANIMATIONS` registers
AppKit's own animation defaults in the registration domain (so nothing is persisted and a seeded
settings file is untouched), turns window tabbing off, sets `animationBehavior = .none` on every
window the app creates — including `DialogKit.window`, which all 21 dialogs go through — and wraps
every split-view and window-frame change in a zero-duration grouping. `SZ_STATE_DIR` redirects the
settings domain, the temp root for `7zO*` / `7zE*` / `7zL-*`, the launch-time purge of stale email
folders, Tools ▸ Delete Temporary Files and `SZTempOpen`'s containment guard, through **one** accessor
in the bridge (`SZSettings.temporaryDirectory`) so ObjC++ and Swift cannot disagree. All 16
`NSTemporaryDirectory()` call sites in the app and the bridge were found by search, not by guessing,
and every one of them now goes through it.

**Phase 2, the reset.** `sevenzip://test/reset` with all seven parameters, rejected outright without
test support. It cancels every live `OperationRunner` and **waits for the worker to actually stop**
before touching a panel; ends every sheet, aborts every modal session as the stack unwinds, and orders
every secondary window out; replaces the settings domain from a plist, switches the language the way
the Options ▸ Language page does, rebuilds the menu bar and the toolbars, and tells every settings
group to re-read; then rebuilds both panels — including a hidden one — with selection, sort order,
view mode and flat mode back to their defaults. Each panel releases its folder chain with
`runOnQueue { folder = nil }`, on the serial queue that owns it, because the engine's COM refcounts
are not atomic; panels are reused rather than recreated, so no queue is ever destroyed under a live
folder. The generation goes to the main window's accessibility value first and to the `ack` file last.

**Phase 3, several instances.** The extension-snapshot file name, the Launch Services stamp key and
the internal pasteboard types now derive from the running bundle identifier; `lsregister -f` is skipped
entirely under test support. There was no lock file, pid file, single-instance guard, distributed
notification or mach service anywhere, so nothing else needed unpicking.

**Phase 4.** 30 unit tests (`TestSupportTests`) and 11 UI tests (`ResetCommandTests`).

## 3. Windows parity

Nothing here is a 7zFM feature, so there is no inventory section to cite. What matters for parity is
that nothing was weakened to make a test easier:

* The cancel path is the real one. `cancelActiveOperations()` does exactly what
  `progressDialogDidConfirmCancel` does (`sync.setStopped(true)` → `E_ABORT` at the next
  `progressCheckBreak`, `CProgressSync::CheckStop`), minus the Yes/No/Cancel confirmation (lang 448)
  that a test cannot answer. No new cancellation mechanism exists.
* The settings reload is `OptionsDialog.cpp:31-50` as `OptionsPostApply` already implements it:
  `MyLoadMenu(true)`, `ReloadToolbars`, `SetListSettings` + `RefreshAllPanels`.
* A panel rebuild is `BindToPathAndRefresh` (`PanelFolderChange.cpp:315`) through the existing
  `navigate(to:)`, and the defaults it returns to are the documented ones: `FM.ListMode<N>`,
  `FM.FlatViewArc<N>`, `FM.Columns.<FolderTypeID>` for the sort order, and 7zFM's
  focused-but-unselected first row (01 §3.6, panel api §7 point 6).
* With `SZ_TEST_SUPPORT` unset the app is byte-for-byte the app it was: every accessor returns the
  old value, no timer is armed, the window publishes no accessibility value, and the `test` host is
  refused with the same string an unknown command gets.

## 4. What was verified, and how

* **`Mac/scripts/build.sh` after `rm -rf Mac/build`** — succeeds, no warnings from `Mac/` code.
* **`Mac/scripts/test.sh`** — 341 unit tests pass (311 before, 30 new).
* **`Mac/scripts/test.sh --ui`** — see §7; the 11 new UI tests pass.
* **An out-of-process driver** (scratchpad, not committed; `NSWorkspace.openApplication` with the
  environment, `NSWorkspace.open(_:withApplicationAt:)` for the URL, ack-file polling) proved the
  contract's own `sevenzip://` route works when the sender can aim it: cold launch + first reset
  0.464 s, 20 resets mean 0.439 s, generations `1…21` with no gaps.
* **Two copies with different bundle identifiers** — `com.yrambler2001.7zip` and
  `com.yrambler2001.7zip.alt` (an ad-hoc re-signed `ditto` copy), launched at the same time with
  different `SZ_STATE_DIR` values, three interleaved rounds of resets each: both counted `1, 2, 3`
  independently; each wrote its own `preferences.plist` with its own `FM.PanelPath0` (`/usr/` vs `/`)
  and `FM.Panels.numPanels` (1 vs 2); each had its own `tmp`; and the user's real preferences domain
  was untouched (22 keys before, 22 after).
* **Cancelling a real running operation** — `ResetCommandTests.testResetCancelsARunningOperation`
  starts `h -scrcSHA256 /Applications` through the command channel, waits for the progress dialog, and
  resets: the ack arrives (generation +1), the dialog is gone, nothing else is left open, the panel is
  rebuilt at the fixtures path, and a second reset still works.

No screenshots: everything asserted here is structural (accessibility values, window and dialog
counts, table contents, file contents), and this scope changes no pixels. `screencapture` is denied on
this machine anyway.

## 5. Where this diverges from the frozen contract

Four places, all deliberate, all in `api/resetcmd.md` in full:

1. **A second delivery channel.** With a state directory the app also watches
   `<SZ_STATE_DIR>/reset-request` for the same URL. `NSWorkspace.open(URL)` cannot be aimed: measured
   on this machine, with `fastui`'s three probe bundles registered, Launch Services named a *probe* as
   the `sevenzip` handler and every reset a UI test sent went there — nine tests timed out at once.
   `open(_:withApplicationAt:)` can aim but a sandboxed XCUITest runner cannot resolve the bundle URL
   to aim with. The file channel also gets through a modal session, which an Apple event does not, and
   that is what makes "cancel a running operation" testable at all. The `sevenzip://` route is
   untouched and still works. **This is the one thing `fastui` must know about**, because the contract
   as written cannot be honoured from a sandboxed runner while several bundles exist.
2. **An unusable parameter value is logged and ignored, not refused.** `panels=3`, `view=huge`, a
   relative `ack`, an unknown name: the reset still runs and still writes the acknowledgement, and the
   reasons go to `NSLog` and to `TestResetRequest.warnings`. A refusal would show up in a test as a
   timeout with no explanation.
3. **`SZ_DISABLE_ANIMATIONS` and `SZ_STATE_DIR` are gated on `SZ_TEST_SUPPORT=1`**, reading the
   contract's "the test-only affordances below". Two lines to ungate if that is wrong.
4. **The engine's work directory is not redirected** by `SZ_STATE_DIR`. It is a user-visible setting
   (Options ▸ Folders), upstream's `kSystem` resolves to `/tmp/` on POSIX, and upstream creates the
   file with `O_EXCL` + a random retry, so two instances cannot corrupt each other. A test that wants
   it inside its state directory seeds `Options.WorkDirType` / `Options.WorkDirPath`.

Also worth stating plainly: the **settings-domain default is still the hard-coded
`com.yrambler2001.7zip`** when neither `SEVENZIP_DEFAULTS_SUITE` nor `SZ_STATE_DIR` is set, even for a
differently-identified build. `NMacPrefs::kAppID` (`Mac/Core/Platform/MacPrefs.cpp`) is outside this
scope's ownership and two existing unit tests assert that constant, so the isolation comes from the
state directory instead. Filed in `requests.md`.

## 6. Findings other scopes will want

1. **`CFPreferencesCopyKeyList` is stale for a plist-path domain** — live for a bundle-id-shaped
   domain, frozen at its first call for an absolute path, which is what `SEVENZIP_DEFAULTS_SUITE` is in
   every UI test. Values read back fine; only the key list lies. `Settings.allDomainKeys()` unions the
   file's own keys, which is what makes `defaults=` really clear what the app wrote since launch.
2. **A `CFRunLoopTimer` is not re-entrant.** A blocking command run straight from the request
   watcher's callback wedged the watcher for the command's duration, so the reset meant to cancel that
   command could not be delivered. Anything that polls on a timer and then calls something blocking has
   this bug.
3. **XCUITest exposes the progress and results dialogs as `.dialog`, not `.window`.**
   `app.windows.count` stays 1 while a progress dialog is up. A test watching `app.windows` will never
   see one.
4. **`XCUIApplication.launch()` attaches to a running instance** with the *earlier* test's
   environment. The symptoms are "Failed to activate application … (current state: Running
   Background)" and a generation that does not start at 0.
5. **`NSRunningApplication.isTerminated` never flips without a run loop**, so a script must use
   `kill(pid, 0)`.
6. `CommandExecutor` runs its censor walk on the main thread before the progress dialog exists. It did
   not bite here, but while that walk runs the app is unresettable and unobservable, and for a wildcard
   over a large tree it would be a visible hang. Not this scope's to fix; noted for `cmdmode`.

## 7. Gates

```
rm -rf Mac/build && Mac/scripts/build.sh      -> BUILD SUCCEEDED, no Mac/ warnings
Mac/scripts/test.sh                           -> 341 passed, 0 failed
Mac/scripts/test.sh --ui                      -> see the run recorded below
```

The app-launch lock (`harness` api §1a) was held for every launch, every driver run and every UI run.

## 8. Known gaps and follow-ups

* The `sevenzip://` URL route cannot be aimed at one instance; the request file is the answer and
  `fastui` should use it. If the orchestrator wants the URL route to be the only one, the app would
  have to refuse commands that Launch Services misrouted, which it cannot detect.
* `SZ_STATE_DIR` does not move the engine work directory (§5.4) or the per-user system registrations
  that only one copy can win: the `sevenzip` / `x-7zip` scheme, the five `NSServices` entries (one
  `NSPortName`), the document associations Options ▸ System writes, and the `pluginkit` state of the
  three appexes.
* `MacPrefs.cpp`'s default domain should derive from the running bundle identifier; filed.
* A reset cannot be delivered while the main thread is blocked outside a run loop (§6.6).
* `ResetCommandTests.swift` lives in `Mac/Tests/UITests/`, which `fastui` owns. It is a clean add on
  one path and depends on nothing in the harness (bare `XCTestCase`, its own `XCUIApplication`), so a
  rewrite of `SevenZipUITestCase` cannot break it — but the orchestrator should place it deliberately
  at merge time.
