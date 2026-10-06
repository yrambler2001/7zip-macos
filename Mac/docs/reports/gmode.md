# gmode — Finder commands run like 7zG, not inside the File Manager

Branch `mac/gmode` (from `macos` 3177dd5). Parity references: `03-shell-integration-inventory.md`
§1.5 and §2 (the shell runs **7zG.exe**), §6.4 (the macOS transport), `01 §1.1` (7zFM's own launch).

## 1. The report

In Finder, right-click ▸ 7-Zip ▸ **Add to archive…**, then press Cancel or OK in the Compress
dialog: the **7-Zip File Manager window opened**. On Windows the shell menu starts 7zG.exe, a
separate process with no file-manager window. Its dialog appears alone, then its progress window,
and the process exits when the command ends. 7zFM never appears.

## 2. Cause, measured

Launch-order probes were written to a file from the app's delegate methods. Then a cold
`open -a <Debug app> sevenzip:///…` was run several times:

| Run | Order seen |
|---|---|
| error URL, first launch | `willFinishLaunching` → `application(_:open:)` with **finished = 0**, event `GURL` → (box up; `didFinishLaunching` only after it closes) |
| Add-to-archive URL, 3 launches | `didFinishLaunching` with **no current Apple event** → `GURL` 30 ms later |
| `open -a` (plain launch) | `didFinishLaunching` with event **`oapp`** |
| `open -a … file.txt` | `odoc` before `didFinishLaunching` (its window exists by then) |

So there were two bugs, and which one you got depended on timing:

1. **The URL arrives before `didFinishLaunching`.** The command's modal dialog ran inside the
   Apple-event handler, which held up the launch. After OK or Cancel, `didFinishLaunching` ran and
   created the default File Manager window. This is the reported symptom.
2. **The URL arrives after `didFinishLaunching`.** The default window opened at once, and the dialog
   then came up over it (`parentWindow: NSApp.mainWindow`). The app never quit.

The other routes had the same gaps:
- Services and Dock drops passed `NSApp.mainWindow`.
- A 7zG argv created a window and then ordered it out.
- Every dialog without an owner was centred on the key, main or a 7-Zip window (`DialogKit.owner`),
  so with the File Manager open each command dialog sat on top of it.
- A warm hand-off with `activates = true` raised the File Manager's main window above Finder. Seen
  in `CGWindowListCopyWindowInfo`: before the URL, Finder "c" was above the 7-Zip window; during the
  command, the 7-Zip window was above it.

## 3. The fix

`Mac/App/Integration/GMode.swift` (new) is "7zG mode": the state of the shell commands that are
running and how the app behaves around them.

| Where | What |
|---|---|
| `GMode.submit` | Used by `application(_:open:)` for command URLs and Dock drops. Before `didFinishLaunching` the command is **queued**, and the launch is marked as made for a command. The queue runs from the main run loop once launching is done, outside the Apple-event handler. |
| `AppDelegate.didFinishLaunching` | `needsLaunchWindow(..., forCommand:)`: **no default window** for a command launch or a 7zG argv. If the launch has no `oapp` event (URL or Service launches), the default window waits `GMode.launchWindowGrace` (1.5 s). If a command arrives in that time, the window is cancelled. |
| `GMode.run` | Wraps each shell command: URL `run` / `error` / malformed URLs, Dock-drop "Add to archive", Services, and the 7zG argv. Afterwards it refreshes every panel (`refreshAllPanels`, as 7zFM re-reads a changed folder). A command-only launch then **quits** if nothing is left: no command running or queued, no File Manager window, nothing on screen. Otherwise, if the app was not active before the command, the previously active app (Finder) gets the focus back, as Windows activates Explorer when 7zG's window closes. |
| `DialogKit.owner` / `center` (`ProgressDialogSupport.swift`) | While a shell command runs, a File Manager window never owns a dialog, even when one is passed explicitly. An ownerless dialog is centred on the **work area** (`visibleFrame`, title bar included), as Windows' DS_CENTER places 7zG's dialogs (§4). Message boxes keep their screen-centred placement (recheck2). |
| `DialogKit.runModal` → `GMode.prepareModal` | The command's window is made key and main, and only then is the app activated. Activation brings the main and key windows forward, so the dialog comes forward and takes the focus while the File Manager windows stay where they are. |
| `ExtensionHandoff` | `activates = !isRunning(app)`. A running app is not activated by Launch Services, which would raise its main File Manager window; it activates itself in `prepareModal`. A cold launch still activates. |
| `applicationShouldHandleReopen` | While a command runs, a Dock click brings the dialog forward and never opens a File Manager window. |
| `URLCommands.isShellCommand` | Command, error and malformed URLs are 7zG commands. `settings` and the `test` host are not. |
| `CommandLineEntry` | The 7zG argv now runs through `GMode.run`. No window is created any more, so none has to be hidden. |

Unchanged on purpose:
- **Open archive** (the `7zFM.exe <path>` argv) still opens exactly one File Manager window, and the
  app stays.
- A plain document open (double-click, Open With) still opens its window at once.
- The in-panel uses of `CommandExecutor.run` (Test of checksum files, the panel's context verbs) are
  not shell routes and keep the File Manager window as their owner.

## 4. Placement, checked against 7zG

No new VM run was needed. The `wincompare` captures of 7zG's own dialogs, started from 7zFM's
Add / Extract (which launch 7zG on Windows) on the 1920 x 1080 reference with a 48 px taskbar
(work area 1920 x 1032), were enough:

| Dialog | Frame | Centre |
|---|---|---|
| Add to Archive | 645,228 630x575 | (960, 515.5) |
| Extract | 693,352 534x328 | (960, 516) |

Both are centred on the work area. 7zFM sat at (78,78) at the time, so 7zG ignores it. The port now
does the same. Measured with `CGWindowList` on this Mac (1708 x 1151, work area y 30…1061):
- Cold Add to Archive: 686x578 at (511,256), centre (854, 545).
- Cold progress window: centre (854, 545).

## 5. Verification

**By hand, Debug build, `CGWindowList` sampled every 0.5 s** (no Automation needed):

| Case | Observed |
|---|---|
| cold `a -ad …` URL | only the "Add to Archive" window (level 8, app active), no File Manager window |
| cold `a -t7z -mx=9 big.bin` (no dialog) | only "61% Compressing big.7z", then "99%"; the process **exited** at once; `big.7z` written |
| cold `x -y -o… big.7z` | no window at all, exited, files extracted |
| cold Open archive URL | exactly one File Manager window, app keeps running |
| warm, Finder window in front, URL delivered without activation (`open -g`, as the extension now does) | dialog on top, app active, the 7-Zip File Manager window stays **below** Finder's window |
| warm, URL delivered with activation (old hand-off) | File Manager window raised above Finder: the reason for the `ExtensionHandoff` change |

**App-hosted** (`GModeTests`, 9 cases, through `application(_:open:)` as AppKit calls it):
- The warm Add-to-archive dialog is not a sheet, has no parent, and is centred on the work area.
  No File Manager window can own it. File Manager window order and count are unchanged. Reopen
  during the command opens nothing. Cancel writes nothing, and the app does not quit.
- The error report box has no owner and is centred on the screen.
- Open archive opens exactly one window showing the archive, and does not quit even for a command
  launch.
- A no-dialog `a` URL writes the archive, and the panel showing that folder lists it.
- A deferred launch window is cancelled by a command.
- `needsLaunchWindow(forCommand:)`, the `oapp` classification, the quit decision (8 cases), and
  which URLs are shell commands.

**UI** (`GModeUITests`, input shard, URL delivered by `NSWorkspace.open(_:withApplicationAt:)`, as the
extension does):
- cold Add → Cancel → app exits, and no File Manager window ever appears;
- cold Add → OK → archive written, app exits;
- cold error box → OK → app exits;
- cold Open archive → exactly one window;
- warm with two windows → dialog not a sheet, window frames and order unchanged, OK writes the
  archive, the panel lists it, and the app keeps running.

| Command | Result |
|---|---|
| `Mac/scripts/build.sh` | exit 0, 0 warnings |
| `Mac/scripts/test.sh` | 401 passed, 0 failed |
| `Mac/scripts/test.sh -H` | 264 passed, 0 failed (an earlier full run had one timing failure, `Feel3Tests.testIconViewsSlowClickRenameAndHover`, which passed alone and in the next full run) |
| `Mac/scripts/test.sh -u` | **Automation mode was available this time.** Probe1: 6/6 and Probe2: 6/6. Input shard: every class green except `NewWindowUITests` (3 failures, see below). `GModeUITests` is 5/5 when run on its own (`-o GModeUITests`, after the selector fix below). |

`GModeUITests` failed in the first full run for two test-side reasons, both now fixed:
- The app's dialogs are AXDialog, so XCUI lists them under `dialogs`, not `windows`.
- `XCUIApplication(bundleIdentifier:)` attached to the installed `/Applications/7-Zip.app`, which has
  the same identifier. The test now uses `XCUIApplication(url:)` with the shard's bundle.

**`NewWindowUITests` (3 reopen cases) is an environment failure, not a regression.**
`NSWorkspace.openApplication(at: <shard app>)` started **`/Applications/7-Zip.app`** (pid seen in
`ps`; it then showed three windows on the user's home folder). The reopen therefore never reached
the shard's instance. Since `mac/finderfix`, `finderext-registration.sh` `lsregister -u`s every
build in this tree after a build or test run, so Launch Services resolves the bundle identifier to
the installed copy. The reopen path's only change here is the `GMode.isActive` guard, which is false
outside a shell command. **For the orchestrator:** either keep the shard app registered while
`test.sh -u` runs, or quit `/Applications/7-Zip.app` first.

**Machine note:** a macOS privacy prompt, *"7-Zip" would like to access files in your Desktop
folder*, has been on screen since the first Debug-build launch. It belongs to the worktree Debug
build, whose panel listed the home folder. It overlays every screenshot taken meanwhile (so the UI
screenshots were not kept), and only the user can answer it.

## 6. What to check by hand (after the install below)

1. Quit 7-Zip if it is running. In Finder, right-click a file ▸ **7-Zip ▸ Add to archive…**. Only the
   "Add to Archive" dialog appears, in the middle of the screen. Press **Cancel**: the dialog goes
   away, no File Manager window appears, and 7-Zip leaves the Dock.
2. Repeat and press **OK**. A progress window may flash, the archive appears next to the file, and
   7-Zip quits. No File Manager window.
3. Right-click an archive ▸ **7-Zip ▸ Extract Here** (no dialog). The files appear and 7-Zip quits.
4. Open 7-Zip (File Manager) on some folder and put a Finder window in front of it. Right-click a
   file in Finder ▸ **7-Zip ▸ Add to archive…**. The dialog appears on its own, centred on the
   screen and not attached to the File Manager window. The File Manager window does not jump in
   front of Finder. Press OK: the archive is created, Finder is active again, the File Manager is
   still open where it was, and if it shows that folder it lists the new archive.
5. Right-click an archive ▸ **7-Zip ▸ Open archive**. One File Manager window with the archive opens
   and stays.
6. **Quick Actions ▸ Compress with 7-Zip** and **Extract with 7-Zip**, and **Services ▸ 7-Zip: …**
   behave like 1–3.
7. If anything opens a File Manager window, run
   `log stream --predicate 'subsystem == "com.yrambler2001.7zip"'` and repeat. The `GMode` category
   says whether the launch was recognised as a command launch ("launch is for a command …") and
   when it quits.

## 7. Known gaps and follow-ups

- **Services launched cold**: AppKit delivers the request after `didFinishLaunching`. The 1.5 s grace
  covers it only when that launch carries no `oapp` event. A cold Service launch was not measured
  (no way to trigger one without Automation). If it does carry `oapp`, the File Manager window
  appears and the app stays running after the service: the old behaviour, no worse.
- **A Dock drop** activates the app through the Dock, so a running app's File Manager window comes
  forward with it. That is the Dock's own activation and outside the app's control.
- `GMode.launchWindowGrace`: a URL that takes longer than 1.5 s after `didFinishLaunching` gets the
  old behaviour (a window, no quit). Measured delay: about 30 ms.
- Cross-scope edits: `AppDelegate.swift` (orchestrator), `ProgressDialogSupport.swift` (opsinfra),
  `ExtensionHandoff.swift`, `URLCommands.swift`, `ServicesProvider.swift`,
  `AppDelegate+Integration.swift`, `CommandLineEntry.swift` (finder). All are small and commented
  with `gmode` / `GMode`.

## 8. Machine state left behind

- `/Applications/7-Zip.app` is this branch's Release build (ad-hoc signed). It was checked after the
  install:
  - a cold `open sevenzip:///run?argv=[a -t7z …]` wrote the archive and the app exited within 0.5 s,
    with no window;
  - a cold `a -ad …` showed only "Add to Archive" at (511,256).

  The previous copy was kept at `~/7-Zip-backup.app` until then, and has now been removed.
- The three extensions are registered only from `/Applications`. `sevenzip:` resolves only to
  `/Applications/7-Zip.app`; the main tree's Debug and Release builds were unregistered again.
