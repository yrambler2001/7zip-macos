# `resetcmd` — test support: the environment switches, `sevenzip://test/reset`, several instances

The app side of `Mac/docs/test-support-contract.md`. Code against this file; `fastui` consumes it.

Sources: `Mac/App/Integration/TestReset.swift` (the coordinator, the animation switch, the request
watcher), `Mac/App/Integration/CommandURL.swift` (`TestResetRequest`, the `test` host),
`Mac/App/Support/Settings.swift` (`TestSupport`, the domain replacement), `Mac/Core/SZSettings.*`
(the state directory and the temporary root, so ObjC++ and Swift cannot disagree),
`Mac/App/MainWindow/MainWindowController.swift` and `Mac/App/Panel/PanelViewController.swift`
(`resetForTest`). Tests: `Mac/Tests/SevenZipKitTests/TestSupportTests.swift` (30, no GUI) and
`Mac/Tests/UITests/ResetCommandTests.swift` (11, the real app).

**The headline numbers.** A reset costs **0.41 s** (no parameters beyond a path) to **0.55 s** (a
`defaults` plist plus a panel-count change) measured from inside XCUITest, against **3.89 s** for
`terminate()` + `XCUIApplication.launch()` + waiting for a panel. `SZ_DISABLE_ANIMATIONS=1` takes
**0.43 s** off every dialog open-and-close cycle. Section 8 has the method and the raw figures.

---

## 1. The switches, and the one rule about them

| Variable | Effect |
|---|---|
| `SZ_TEST_SUPPORT` | `1` turns everything below on. Anything else, or unset, and none of it exists: the `test` URL host is rejected, the main window publishes no accessibility value, the other two variables are ignored, and no test-only code runs. |
| `SZ_DISABLE_ANIMATIONS` | `1` (with test support on) removes window and view animation time — see section 2. |
| `SZ_STATE_DIR` | An absolute directory this instance uses for everything it would otherwise put in a shared place — see section 3. |
| `SEVENZIP_DEFAULTS_SUITE` | Unchanged (`Mac/docs/api/options.md` section 1): a domain name, or an absolute plist path, used as the whole settings domain. |

```swift
TestSupport.isEnabled            // SZ_TEST_SUPPORT == "1"
TestSupport.animationsDisabled   // and SZ_DISABLE_ANIMATIONS == "1"
TestSupport.stateDirectory       // SZ_STATE_DIR, or nil
TestSupport.temporaryDirectory   // <SZ_STATE_DIR>/tmp/, or NSTemporaryDirectory()
TestSupport.stateSubdirectory("x")   // created on demand; nil without a state directory
SZSettings.testSupportEnabled / .stateDirectory / .temporaryDirectory   // the same, in the bridge
```

Only the exact string `"1"` counts, so `SZ_TEST_SUPPORT=0`, `=true` or `=yes` leave the app alone.
Every variable is read with `getenv` on **every** access, never cached and never through
`ProcessInfo.processInfo.environment`, so a unit test may `setenv` mid-process — the rule
`NMacPrefs::ApplicationID()` already followed for the settings suite.

`TestSupport.prepareForLaunch()` runs first in `applicationWillFinishLaunching`, before anything
reads a setting. With a state directory and **no** explicit `SEVENZIP_DEFAULTS_SUITE`, it points the
settings domain at `<SZ_STATE_DIR>/preferences.plist`; an explicit suite always wins, which is how
the harness seeds one plist per test.

**Gating the other two variables on `SZ_TEST_SUPPORT` is a reading of the contract, not an accident.**
The table in the contract introduces `SZ_TEST_SUPPORT` with "the test-only affordances **below**", and
"unset means none of them do", so the rows under it are gated. It also makes the "nothing may change
behaviour when `SZ_TEST_SUPPORT` is unset" rule mechanical rather than a promise. If the orchestrator
would rather have them independent, remove `isEnabled` from `TestSupport.animationsDisabled` and
`SZSettings.stateDirectory` — two lines.

## 2. `SZ_DISABLE_ANIMATIONS` — removing the time, not shortening it

`TestAnimations.installIfNeeded()` runs before the first window exists and registers these in the
**registration** domain of `UserDefaults.standard` (so nothing is persisted, and the settings file a
test seeded is untouched):

`NSAutomaticWindowAnimationsEnabled = false`, `NSWindowResizeTime = 0.001`,
`NSScrollAnimationEnabled = false`, `NSScrollViewRubberbanding = false`,
`NSDocumentRevisionsWindowTransformAnimation = false`,
`NSToolbarFullScreenAnimationDuration = 0`, `NSBrowserColumnAnimationSpeedMultiplier = 0`,
`QLPanelAnimationDuration = 0`. It also sets `NSWindow.allowsAutomaticWindowTabbing = false`.

That covers the three areas the contract names:

* **dialogs appearing and disappearing** — `NSAutomaticWindowAnimationsEnabled` is the switch AppKit
  itself consults for every window it animates, which is `NSAlert`, the `beginSheetModal` sheets,
  `NSOpenPanel`/`NSSavePanel` and the modal dialogs this app builds. On top of that,
  `TestAnimations.apply(to:)` sets `animationBehavior = .none` and `tabbingMode = .disallowed` on
  every window the app creates itself, so the suppression does not rest on one default: the main
  window, the Options window, and `DialogKit.window(title:resizable:)`, which is the constructor all
  21 dialogs of `01b` go through.
* **window resizing** — `NSWindowResizeTime` is AppKit's seconds-per-150-points figure for
  `setFrame(_:display:animate:)`, which is what `zoom(_:)` uses; `restoreState`'s zoom is additionally
  wrapped in `TestAnimations.withoutAnimation`.
* **the split view** — every divider move, panel insertion and panel removal in
  `MainWindowController` runs inside `TestAnimations.withoutAnimation`, a grouping with
  `duration = 0` and `allowsImplicitAnimation = false`.

```swift
TestAnimations.isDisabled                 // == TestSupport.animationsDisabled
TestAnimations.apply(to: window)          // no-op unless disabled
TestAnimations.withoutAnimation { … }     // zero-duration, implicit animations off
```

Measured (section 8): 1.322 s against 1.756 s for the same dialog open-and-close cycle.

## 3. `SZ_STATE_DIR` — what is redirected, and what is not

| Path | Without a state directory | With one |
|---|---|---|
| settings domain | `com.yrambler2001.7zip` (or the suite) | `<state>/preferences.plist` unless a suite is named |
| temp root for `7zO*` / `7zE*` (temp-open, drag-out, compress-and-email) | `NSTemporaryDirectory()` | `<state>/tmp/`, created on demand |
| `7zL-<uuid>.txt` selection list files | `NSTemporaryDirectory()` | `<state>/tmp/` |
| the launch-time purge of stale `7zE-` folders, and Tools ▸ Delete Temporary Files | the shared temp root | `<state>/tmp/` only |
| `SZTempOpen.temporaryDirectories` / `removeTemporaryDirectory(atPath:)` containment guard | the shared temp root | `<state>/tmp/` |
| the reset request channel (section 5) | — | `<state>/reset-request` |

Everything goes through **one** accessor, `SZSettings.temporaryDirectory`, which is in the bridge
precisely so the ObjC++ side (`SZTempOpen.mm`, `SZArchiveOpener.mm`) and the Swift side use the same
rule. `CommandURL.temporaryRoot` resolves the same rule independently because `CommandURL.swift` is
Foundation-only (it is compiled into the two sandboxed appexes, which may not link `SevenZipKit`); a
unit test asserts the two agree. Without a state directory both return `NSTemporaryDirectory()`
unchanged, so nothing moves for a normal launch.

The redirection matters more than it looks: before it, the launch-time `7zE-` purge and Tools ▸
Delete Temporary Files **enumerated and deleted the other instance's live folders**, because the
prefix and the root were identical for every instance.

**Not redirected, deliberately: the engine's work directory.** `NWorkDir::CInfo` defaults to
`kSystem`, and upstream's `MyGetTempPath` on POSIX is the literal `/tmp/`
(`CPP/Windows/FileDir.cpp:869-876`), so an archive update's temporary file is built in `/tmp/`. It is
left alone for two reasons: the work directory is a **user-visible setting** (Options ▸ Folders, 01b
§4.9) that a test may legitimately assert, and forcing it would make that page lie; and upstream
creates the file with `O_EXCL` and retries with a random postfix on collision
(`CreateTempFile2`), so two instances cannot corrupt each other there. A test that wants the work
directory inside its state directory seeds it, which is one line in the plist:

```swift
"Options.WorkDirType": 2, "Options.WorkDirPath": "<state>/work"
```

## 4. The reset command

`sevenzip://test/reset?<query>`, or `x-7zip://test/reset?<query>`. Parsed by the same
`CommandURL.parse` as every other command; the `test` host throws
`SevenZipArgumentError("Unsupported URL command")` unless test support is on, which is the same
answer a shipped app gives any unknown command.

| Parameter | Effect |
|---|---|
| `defaults` | Absolute path to a plist. **Replaces** the settings domain's contents with it — every key not in the file is removed, not merged — and reloads everything that reads settings, including the language. |
| `lang` | Language code to load, exactly as the Options ▸ Language page would (`"-"` = built-in English, `""` = system language, else a `Lang/*.txt` stem). |
| `panels` | `1` or `2`. |
| `path0`, `path1` | The directory each panel shows. Absent means the settings domain's `FM.PanelPath<N>`, and failing that the home directory — the same rule as a cold start. |
| `view` | Default view mode for both panels: `0`…`3`, or `large` / `small` / `list` / `details`. |
| `ack` | Absolute path the app writes when the reset is complete. |

```swift
var request = TestResetRequest()
request.panelCount = 2
request.panelPaths = [0: fixtures, 1: "/usr"]
request.ackPath = ack
let url = request.url          // sevenzip://test/reset?panels=2&path0=…&path1=…&ack=…
```

The reset, in order, and this order is the contract:

1. **Stop everything.** Menu tracking is cancelled; every live `OperationRunner` is cancelled the way
   the Cancel button does minus the confirmation, so the worker's next `progressCheckBreak` returns
   `E_ABORT`; every sheet is ended, every `NSSavePanel` cancelled, the innermost modal session
   aborted, and every secondary window ordered out. AppKit's own infrastructure windows (tool tips,
   menu shadows, the status bar) are left alone.
2. **Wait until it really has stopped.** A 20 ms timer in `.common` mode re-aborts each modal session
   the unwinding stack exposes, and only continues once `OperationRunner.hasActiveOperation` is false,
   `NSApp.modalWindow` is nil and no secondary window is visible. A timer, not a main-queue block,
   because a main-queue block is not delivered reliably while `NSApp.runModal` is on the stack —
   `OperationRunner` uses a timer for the same reason. After 15 s it logs and carries on: a reset that
   never finished would be worse than one that finished with a warning, because the test would hang on
   the acknowledgement instead of failing with a message in the log.
3. **Reload the settings.** `defaults` replaces the domain, `lang` writes `Lang` the way the Options
   page does, then `Lang.loadFromSettings()`, `SZFolder.timestampShowUTC`,
   `Settings.notifyAllGroups()` (every group, because after a wholesale replacement no observer can
   know which keys moved) and `OptionsPostApply.reloadLangItems()` (`MyLoadMenu(true)` +
   `ReloadToolbars`).
4. **Rebuild the panels.** The window's own state comes back from the settings domain (toolbars,
   auto-refresh, splitter ratio, focused panel 0); the panel count becomes `panels`; then **every**
   panel — including one that is currently hidden, so nothing survives in it — is rebuilt:

```swift
window.resetForTest(request) { /* all panels bound */ }
panel.resetForTest(to: path, viewMode: mode) { ok in … }
```

   Selection, the focus row, the selection anchor, the rename state, the drag state, the remembered
   password and both navigation stacks are dropped; flat mode goes back to `FM.FlatViewArc<N>` for
   archives and off for the file system; the view mode becomes `view` (or `FM.ListMode<N>`); and the
   cached column model is forgotten so the **sort order** is rebuilt from
   `FM.Columns.<FolderTypeID>` as the domain now stands.

   **The folder chain is released on the queue that owns it.** `SZFolder` wraps engine COM objects
   whose reference counts are plain `++`/`--` (`Z7_COM_USE_ATOMIC` is not defined,
   `Mac/docs/api/opsinfra.md` §4), so the last release has to happen on the panel's serial queue and
   nowhere else. `resetForTest` therefore does `runOnQueue { self.folder = nil }` and lets `navigate`
   enqueue behind it on the same queue. Step 2 is what makes this safe: a cancelled operation's
   worker has already returned, so it cannot still be holding the folder when the panel drops it.
   Panels are **reused**, never recreated, so no panel's queue is ever destroyed under a live folder.

5. **Signal**, in this order: the generation is incremented, published as the main window's
   accessibility value, and only then written to the `ack` file.

### One deliberate leniency

A parameter the app cannot use — `panels=3`, `view=huge`, a relative `ack`, an unknown name — is
**recorded in `TestResetRequest.warnings`, logged by the app with `NSLog`, and ignored**; the reset
still runs and still writes the acknowledgement. Refusing the whole command would show up in a test
as a timeout with no explanation, which is the worst failure mode a harness can have. A malformed
*URL* (not a malformed parameter) is still refused outright.

## 5. How a test knows the reset finished — and how it reaches the right app

Both signals of the contract, both required:

```swift
window.value as? String        // "0" before the first reset, then "1", "2", … (test support only)
String(contentsOf: ackURL)     // the same number, written last of all, atomically
```

The accessibility value is set **before** the ack file is written, so a test that sees the file can
trust the value. The ack file's parent directory is created if needed and the write is atomic, so a
poller never reads half a number.

### The delivery channel, and why there are two

`NSWorkspace.open(URL)` hands a `sevenzip://` URL to whichever bundle Launch Services considers the
scheme's handler. **Measured on this machine:** with the `fastui` scope's `7-Zip-Probe1.app`,
`7-Zip-Probe2.app` and `7-Zip-Host.app` registered, `urlForApplication(toOpen:)` named a *probe*, and
every reset a UI test sent went there instead of to the app under test — nine tests timed out at once.
`NSWorkspace.open(_:withApplicationAt:)` can aim, and does (the out-of-process driver of
`Mac/docs/reports/resetcmd.md` uses it and works), but a **sandboxed** XCUITest runner cannot reliably
resolve a bundle URL outside its container to aim with.

So, when a state directory is set, the app also **watches `<SZ_STATE_DIR>/reset-request`** and treats
its contents as the URL:

```swift
// from a UI test: aimed, and it works while the app is inside a modal session
try Data(url.absoluteString.utf8)
    .write(to: stateDirectory.appendingPathComponent("reset-request"), options: .atomic)
```

* The state directory belongs to exactly one instance, so a request left there cannot reach another.
* The watcher is a `Timer` in `.common` mode, so a reset arrives **while `NSApp.runModal` is on the
  stack** — which is precisely the case "cancel or finish any running operation" has to cover. An
  Apple event would not.
* The file is removed before it is acted on, so a slow command cannot be started twice.
* Any `sevenzip://` URL works, not only a reset, which is what lets a test start a real long operation
  to cancel (`sevenzip:///run?argv=…`).

This is an **addition**, not a change of shape: the file holds the same URL, parsed by the same
parser, and the `sevenzip://` route is untouched.

**One trap worth knowing, because it cost an afternoon.** A `CFRunLoopTimer` is **not re-entrant**:
while its callback is on the stack the run loop will not fire that timer again, however long the
callback takes and whatever mode the nested loop spins in. Running a *blocking* command straight from
the watcher's callback therefore wedged the watcher for the whole command and made the reset that was
supposed to cancel that command undeliverable. The watcher now handles a `test`-host URL inline (a
reset never blocks: it arms its own timer and returns) and dispatches anything else with
`DispatchQueue.main.async`.

## 6. Several instances at once

| What | Now derived from |
|---|---|
| settings domain | `SEVENZIP_DEFAULTS_SUITE`, else `<SZ_STATE_DIR>/preferences.plist`, else the default domain |
| temp root, list files, temp-folder purge | `SZ_STATE_DIR` (section 3) |
| the extension settings snapshot's file name | the **running app's** bundle identifier (`SevenZipBundle.runningAppIdentifier`), so two copies write `…/<their id>.integration.plist` instead of one shared file. An appex derives the app's id by dropping the last component of its own, and falls back to the shipped name, so an extension configured by the original build keeps working. |
| the Launch Services registration stamp | the bundle identifier: the default id keeps `FM.LaunchServicesStamp`, anything else gets `FM.LaunchServicesStamp.<id>`. Two copies at different paths used to ping-pong, each re-running `lsregister` on every launch. |
| the internal pasteboard types (`…panel-items`, `…cut`) | the running bundle identifier, so one instance's Cut is not honoured as internal by another |
| `lsregister -f` at launch | **skipped entirely under `SZ_TEST_SUPPORT`**: a throwaway build must not become the system's 7-Zip handler, and it costs a subprocess per launch |

There is no lock file, pid file, single-instance guard, distributed notification or mach service
anywhere in the app, so nothing else had to be unpicked.

Verified with two copies carrying **different bundle identifiers** (`com.yrambler2001.7zip` and
`com.yrambler2001.7zip.alt`, the second an `ad-hoc`-re-signed copy) running at the same time with
different `SZ_STATE_DIR` values: three interleaved rounds of resets, each instance's generation
counting `1, 2, 3` independently, each instance's own `preferences.plist` holding its own
`FM.PanelPath0` and `FM.Panels.numPanels`, and the user's real preferences domain untouched (22 keys
before, 22 after).

**What cannot be isolated, and is not this scope's to fix.** These are per-user, single-winner system
registrations: the `sevenzip` / `x-7zip` URL scheme, the five `NSServices` entries (one `NSPortName`,
`7-Zip`), the document-type associations that Options ▸ System writes with
`NSWorkspace.setDefaultApplication`, and the `pluginkit` state of the three appexes. Whichever copy
Launch Services prefers wins them. The reset channel of section 5 exists because of the first of
these.

## 7. Notes for whoever writes the tests

Measured while building this, all of it surprising enough to be worth writing down:

1. **`CFPreferencesCopyKeyList` is stale for a plist-path domain.** For a domain named like a bundle
   id it is live. For a domain that is an absolute **plist path** — which is what
   `SEVENZIP_DEFAULTS_SUITE` is in every UI test — it answers from a cache filled by its first call in
   the process and never updates, even after `CFPreferencesAppSynchronize`. Values read back
   correctly; only the key *list* goes stale, and the file on disk is authoritative.
   `Settings.allDomainKeys()` unions both, which is what makes `defaults=` actually clear the keys the
   app wrote since launch. A test that enumerates a seed file's keys should read the file.
2. **The progress and results dialogs are `XCUIElement.ElementType.dialog`, not `.window`.**
   `app.windows.count` stays 1 while a progress dialog is up; `app.dialogs.count` becomes 1.
3. **`XCUIApplication.launch()` attaches to a running instance** instead of replacing it, so a
   leftover from an earlier test is silently reused *with the earlier test's environment*. The symptom
   is "Failed to activate application … (current state: Running Background)" or a generation that
   starts at something other than 0. Terminate first and wait for `.notRunning`.
4. **`NSRunningApplication.isTerminated` never flips without a run loop**, so a command-line driver
   must ask the kernel (`kill(pid, 0)`) instead.
5. A reset cannot be delivered while the main thread is blocked **outside** a run loop. Everything in
   the app that blocks for long does so inside a modal session, where the watcher's timer runs, so
   this has not bitten — but a future main-thread walk would make the app unresettable for its
   duration.

## 8. The measurements

All on this machine, Debug build, `SZ_DISABLE_ANIMATIONS=1`, app already launched.

**From inside XCUITest** — the number that matters, because it is what a test pays
(`testMeasureResetAgainstRelaunch`, three runs of the suite agreeing within noise):

| | n | mean | min | max |
|---|---|---|---|---|
| reset, `path0` only | 10 | **0.409 s** | 0.142 | 0.585 |
| reset, `defaults` plist + panel-count switch + `view` | 10 | **0.548 s** | 0.294 | 0.754 |
| `terminate()` + `launch()` + wait for a panel | 3 | **3.892 s** | 3.620 | 4.278 |

So a reset replaces a relaunch at roughly **one seventh to one ninth** of the cost, saving ~3.4 s per
test. Earlier runs of the same test measured 1.742 s / 6.038 s when the reset was delivered through
`NSWorkspace` rather than the request file; both ratios are about the same, the absolute numbers are
better with the file.

**Animations** (`testAnimationSuppressionRemovesTime`): the same dialog open-and-close cycle, six
times each, hashing the same file so the constant is identical — **1.322 s** with
`SZ_DISABLE_ANIMATIONS=1`, **1.756 s** without. 0.43 s of pure animation per cycle, which is about the
two 0.2 s window fades AppKit would otherwise run.

**Out of process** (the driver, `NSWorkspace.open(_:withApplicationAt:)`, no accessibility overhead):
cold launch + first reset 0.464 s; 20 resets mean 0.439 s; quit + relaunch + first reset mean 0.710 s
over 4 rounds. Worth knowing for what it says about the 28.7 s-per-test baseline: **the app itself
launches in about 0.7 s**, so the other 28 s of a test is XCUITest's launch handshake and the suite's
own overhead, not the app. Removing the relaunch removes ~3.9 s of that; the rest is `fastui`'s to
find.
