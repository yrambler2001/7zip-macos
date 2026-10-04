# `appfeel`: Dock click vs. a second launch, and the "Integrate 7-Zip to shell context menu" box

Branch `mac/appfeel`, off `macos` at `43d66bc`, 2026-10-04. User requests 7 and 16, plus the stale
"sends no Apple events" sentence in the README.

## 1. Dock click shows the open windows; any other launch opens a new one (request 7)

### What the system sends

A Dock click on the running app and a second launch from Finder / Spotlight / Launchpad / `open -a`
all arrive as the **same** reopen Apple event (`kAEReopenApplication`, `'aevt'/'rapp'`, with one
parameter `'aapd':1` in every case seen). The only difference is the **sender**: Launch Services
sends the event from the process that asked for the launch. Measured on this machine (macOS 26,
Darwin 25.6), first with a throwaway probe app that logged `keySenderPIDAttr` /
`keyOriginalAddressAttr` of every reopen, then with the real app's Debug log line
(`7-Zip reopen: sender pid … -> …`):

| Gesture | Sender reported | How it was produced here | Result |
|---|---|---|---|
| Dock icon click | `com.apple.dock` (`/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock`) | a **real click on the Dock tile** from XCUITest (`dock.descendants(matching: .dockItem)`) | shows the open windows |
| Double-click of 7-Zip.app in a Finder window | `com.apple.finder` | a **real double-click in a Finder window** from XCUITest | new window |
| `open -a 7-Zip` / `open 7-Zip.app` | `/usr/bin/open`, **already exited** when the event is handled (no bundle id, no path) | shell | new window |
| `NSWorkspace.openApplication` from another app | that app (e.g. the UI-test runner) | XCUITest, a Swift helper | new window |
| Spotlight | expected `com.apple.Spotlight` | **not verified** (cannot drive Spotlight here) | new window (any non-Dock sender) |
| Launchpad, macOS 14-15 | the Dock process (Launchpad is drawn by the Dock) | not verified (macOS 26 has no Launchpad) | **shows the open windows**, indistinguishable from a Dock click |

### The rule (`Mac/App/Integration/ReopenSender.swift`, `AppDelegate.applicationShouldHandleReopen`)

- Sender's bundle id is `com.apple.dock` (or its pid is a running Dock, or its executable is the
  Dock's) → **Dock click**: a visible file-manager window is made key (activation brings the app's
  windows forward); with none visible the most recently used minimized one is deminiaturized; with
  no file-manager window at all one is opened.
- Any other identifiable sender, **including one that has already exited** (the Dock never exits,
  `open` always does) → **launch**: `openNewWindow()`, as before (`reports/newwindow.md`).
- No sender at all (no current Apple event, pid 0, the app itself) → treated like the Dock: never a
  surprise window.
- 7zG command mode: unchanged (AppKit default).
- `applicationShouldHandleReopen` returns false in both cases: the app does the work itself.

Windows has no Dock; 7zFM's "every launch is a process with one window" (`01 §1.1`) is kept for
every launch, and the Dock click follows the macOS convention, as the user asked. `parity.md` §B.6
and the "One 7zFM process per window" row say so.

### Manual steps for the user (a check nobody needs to automate further, but worth a minute)

1. Start 7-Zip. Click its **Dock icon**: no new window; the window comes forward.
2. Minimize the window (Cmd+M), click the Dock icon: the same window comes back, Window menu lists one.
3. With 7-Zip running, double-click **7-Zip.app** in /Applications (or Spotlight "7-Zip", Return):
   a **second** window opens.
4. Optional, on a Debug build: `log stream --predicate 'process == "7-Zip"' | grep reopen` prints
   the sender of each event (Release builds do not log).
5. macOS 14/15 only: Launchpad behaves like the Dock (shows windows). Use File ▸ New Window
   (Option-Cmd-N) for a new one.

## 2. "Integrate 7-Zip to shell context menu" (request 16)

### Why it was grey

The user's Release build (`Mac/build/DerivedData/Build/Products/Release`, built 2026-10-03 21:13)
predates `mac/dlgfeel`; its `OptionsMenuPage` did `integrateCheckbox.isEnabled = false`
unconditionally — the box was only a status display and the click went to a separate "Open Login
Items" button. dlgfeel removed that button and re-enabled the box, but the box still only opened
System Settings, and its tick meant "some copy with this identifier is `+`", not "this copy".

### What `pluginkit -m` says, in plain words

```
+    com.yrambler2001.7zip.FinderSync(26.03)   5A9DAFA2-…   2026-10-03 23:39:09 +0000   /…/Release/7-Zip.app/Contents/PlugIns/FinderSync.appex
```

"The Finder extension `com.yrambler2001.7zip.FinderSync`, version 26.03, is switched **on** (`+`;
`-` = switched off, `!` = forced on by a developer tool, `=` = replaced by another copy, blank =
never chosen, which for Finder extensions means off). It was registered at 23:39, and the copy
Finder actually runs is the one inside that Release 7-Zip.app." The on/off choice belongs to the
identifier; the path is which *copy* serves it.

### Several copies

Every 7-Zip.app with an embedded appex registers it under the same identifier. On this machine
`pluginkit -m -D -A -v -i com.yrambler2001.7zip.FinderSync` listed four: the main tree's Release
and Debug builds, this worktree's Debug build and a leftover copy in another agent's scratch
folder. Measured: **building the Debug app registers it and Finder then gets the fresh build**, so a
mere `build.sh` used to take Finder's menu away from the installed app. Which copy wins cannot be
steered from outside: re-adding a copy (`pluginkit -a` of a known path is a no-op), a newer
registration date, `lsregister -f` of its app and touching the bundle all left the fresh build in
charge (a first guess, "the copy added last wins", was disproved by exactly this). What works, at
once, is **removing the other copies' registrations** (`pluginkit -r <path>`): the only copy left is
the one Finder runs. A removed copy registers itself again when it is launched or rebuilt. A deleted
copy drops out of the list by itself; `pluginkit -r` of a path PlugInKit never knew exits 1. The test copies (`7-Zip-Host`,
`-Probe1/2`) embed no appex, so they never registered one.

### What was built

- `Mac/App/Integration/FinderExtensionControl.swift`: parses `pluginkit -m -v` lines; the state
  for *this* copy (`notEmbedded`, `notRegistered`, `enabled`, `disabled`,
  `otherCopy(path, enabled)`; paths compared after `realpath`, so the `Mac/build/Debug` symlink is
  the same copy); `setEnabled(on)` = remove every other copy's registration (`-r`), add this copy
  (`-a`), elect `use`, or elect `ignore`; then wait up to 3 s for the state to follow.
  `claimAtLaunchIfNeeded()`: every launch of a real copy (never a test instance, `SZ_TEST_SUPPORT`)
  does the same claim in the background when Finder is using another copy, so **the copy the user
  runs wins**. The election is never changed at launch. Verified on this machine: launching this
  branch's Debug build took the extension from the Release copy within 5 s; launching the old
  (pre-appfeel) Release build did not take it back -- the claim is new code, so the user's
  installed copy needs a rebuild/DMG from this branch to behave this way.
- Options ▸ 7-Zip (`OptionsMenuPage.swift`), as `MenuPage.cpp` does it: ticked only when Finder
  uses this copy's extension and it is on (`CheckContextMenuHandler(path)`); **disabled** when this
  copy has no appex (`EnableItem(false)` when 7-zip.dll is missing, :170-174); a click only marks
  the page changed; **Apply/OK switches** (`SetContextMenuHandler`, :299-316) and re-reads the
  state into the box. If the switch did not take (MDM, a future macOS), a "7-Zip" error box says so
  and `FIFinderSyncController.showExtensionManagementInterface()` opens the System Settings pane.
- **Consent:** `pluginkit -e use|ignore` needed none on macOS 26 (rc 0; Finder started/stopped
  the extension process immediately). macOS 14/15 were not available to test; the fallback above
  covers a system that refuses.
- `Mac/scripts/finderext-registration.sh`, sourced by `build.sh` (around xcodebuild) and `test.sh`
  (EXIT trap): remember which copy Finder used before; if the build/test changed it, remove the
  other registrations and re-add that copy; drop registrations whose bundle is gone. Verified:
  `build.sh` printed "Finder extension handed back to …/Release/7-Zip.app/…" and Release stayed the
  only, active copy. So builds and test runs leave the user's copy in charge.
- Machine cleanup done by hand: the scratch-folder copy, the main tree's Debug copy and this
  worktree's Debug copy were unregistered; the user's Release copy
  (`Mac/build/DerivedData/Build/Products/Release/7-Zip.app`) is the only registered one, elected `+`.

## 3. README and docs

- `Mac/README.md`: the "sends no Apple events" paragraph now names the one entitlement
  (`com.apple.security.automation.apple-events`) and why (Properties → Finder Get Info, macOS asks
  once, fallback to 7-Zip's list); the Finder-extension section explains the checkbox, the
  `pluginkit` line and the several-copies rule; two stale "Known limitations" bullets (re-launch
  brought the window forward; several archives shared the front window) now describe the current
  behaviour.
- `parity.md` §B.6, the process-model row, a new row for IDX_SYSTEM_INTEGRATE_TO_MENU.
- `requests.md`: the `dlgfeel → packaging` README row and the `listfeel → packaging` entitlement
  row are closed; the `listfeel → finder` Info.plist row is marked kept.

## 4. Tests

- `Mac/Tests/AppTests/AppFeelTests.swift` (app-hosted, 13 cases): sender classification (Dock by
  bundle id and by path, Finder, Spotlight, `open`, exited sender, none, self); launcher → one new
  window; Dock → none; no event → none; Dock with everything minimized → restored, not opened;
  `pluginkit` output parsing (four copies, a path with a space, another identifier ignored); state
  per copy incl. symlinks; enable/disable against a fake PlugInKit (deleted copy removed, existing
  copies kept, this copy newest, `use`/`ignore`); an election that does not take; no claim from a
  test instance; the Options box disabled without an appex, unticked for another copy's extension,
  click → page changed → Apply switches both ways. The fake reports the *first* registered copy as
  active, so a claim that merely re-added its own copy (the first, wrong implementation) fails. **The real `pluginkit` is never called with a
  mutating argument by any test**: the runner is replaced for the whole class.
- `NewWindowTests` (hosted): the reopen cases call `handleReopen(from: .launcher(...))`.
- `NewWindowUITests` (input shard), three new cases with real input: **a real Dock-tile click**
  (one window stays one), **a real Dock click on a minimized window** (restored, Window menu lists
  one), **a real double-click on 7-Zip.app in Finder** (a second window). The existing
  `NSWorkspace.openApplication` reopen cases still open windows (sender = the runner).
  Screenshots `newwindow-06`, `-07`, `-08`.

## 5. Verification

| run | result |
|---|---|
| `Mac/scripts/build.sh` (Debug) | exit 0, no warnings in `Mac/`; hands the extension back to the Release copy |
| `Mac/scripts/test.sh` (SevenZipKitTests) | 388 passed, 0 failed |
| `Mac/scripts/test.sh -H` (SevenZipAppTests, incl. 12 `AppFeelTests`), after the final claim fix | 196 passed, 0 failed; Release still the only registered copy afterwards |
| `Mac/scripts/test.sh -u` (input shard + two probes) | 52 + 6 + 6 passed, 0 failed |
| `NewWindowUITests` alone | 8 passed: real Dock click (sender logged `com.apple.dock -> dock`), real Dock click on a minimized window, real Finder double-click (`com.apple.finder -> launcher`), the existing reopen / New Window / archive cases |

The UI suite ran before the last change to `FinderExtensionControl.claim` (remove the other
copies instead of re-adding this one); that code runs only in non-test launches and in the
hosted tests, which were re-run after it. The final DMG is left to the orchestrator.

## 6. Known gaps

- Spotlight's sender is inferred, not observed; it is not the Dock, so it opens a window either way.
- Launchpad on macOS 14/15 = Dock (by construction of the sender rule).
- `pluginkit -e` without consent is verified on macOS 26 only.
- `FIFinderSyncController.showExtensionManagementInterface()` (fallback) was not exercised: the
  primary path never failed here.

## 7. Files touched

New: `Mac/App/Integration/ReopenSender.swift`, `FinderExtensionControl.swift`,
`Mac/Tests/AppTests/AppFeelTests.swift`, `Mac/scripts/finderext-registration.sh`.
Edited outside a single owner (recorded for the orchestrator): `Mac/App/AppDelegate.swift`
(orchestrator: reopen handling), `Mac/App/Dialogs/OptionsMenuPage.swift` (options),
`Mac/App/MainWindow/MainWindows.swift` (panel, comment only), `Mac/App/Integration/URLCommands.swift`
(finder, one call at launch), `Mac/scripts/build.sh`, `test.sh` (harness), `Mac/README.md`
(packaging), `Mac/docs/parity.md`, `Mac/Tests/AppTests/NewWindowTests.swift`,
`Mac/Tests/UITests/NewWindowUITests.swift`. Nothing outside `Mac/`.
