# `newwindow`: starting 7-Zip again opens a new window; a Finder open always gets its own

Branch `mac/newwindow`, off `macos` at `22a1d9e`, 2026-10-03. Implements the two user decisions that
answer `reports/release.md` "Decisions for the orchestrator" 1 and 3.

## 1. What the user decided, and what Windows does

| Decision | Windows 7zFM | Here |
|---|---|---|
| Opening 7-Zip again while it runs opens a new File Manager window | every `7zFM.exe` launch is a process with one window; there is no single-instance restriction (`01 §1.1` "Single instance") | the reopen Apple event opens a window, whether windows are open or not; File ▸ New Window does the same |
| An archive opened from Finder always gets its own window | `7zFM.exe "%1"` per file, one process each (`03 §6.2`, `01 §9 #32`) | every file in `application(_:open:)` gets a new window, the first one included |

## 2. Every "open again" path

| Path | What reaches the app | Result |
|---|---|---|
| Dock icon click while running | reopen event (`kAEReopenApplication`) → `applicationShouldHandleReopen` | new window, `false` returned so AppKit does not also un-minimize one |
| Dock click with **no visible window** (all minimized) | same, `hasVisibleWindows == false` | new window; the minimized ones stay minimized |
| Dock click with **no window at all** | cannot happen while running: closing the last window quits the app, as closing 7zFM ends its process (`applicationShouldTerminateAfterLastWindowClosed`), so the click is a cold launch, which opens the launch window | one window |
| Finder double-click of 7-Zip.app, `open -a 7-Zip` | reopen event | new window |
| `open -a 7-Zip --args <path>` on a running app | reopen event; Launch Services drops the arguments | new window at the saved paths (the path cannot be honoured: macOS never delivers it). `open -n -a 7-Zip --args <path>` starts a second process that does honour it, as before |
| Cold launch with arguments (`7-Zip <path> [-t<type>]`) | argv | one window, panel 0 at the path (unchanged, `FM.cpp:639-702`) |
| File ▸ New Window, **Option+Cmd+N** | menu action `fileNewWindow:` (macOS addition, no Windows resource ID, marked so in `MainMenu.swift`) | new window |
| Finder double-click / Open With / `open file.7z` on a running app | open-documents event → `application(_:open:)` | one new window per file; the open windows keep what they show |
| The same as a **cold launch** | open-documents event, delivered **before** `applicationDidFinishLaunching` | only the documents' windows; no empty default window next to them |
| A 7zFM argv in a `sevenzip:///run` URL, Open Outside : 7-Zip, a Dock drop routed to "open" | `CommandExecutor.openInFileManager` | one new window per path |
| 7zG command mode (`7-Zip x …`) | reopen event while the command runs | ignored (AppKit default): that process exits when the command ends and would take the window with it (`03 §6.4`) |

The cold-launch ordering was measured, not assumed: with a marker written from both callbacks,
`open -a 7-Zip.app test.7z` delivered `application(_:open:)` 0.19 s **before**
`applicationDidFinishLaunching`, which then found one window and created none. (XCUITest's own
`XCUIApplication.open(_:)` is different: it launches the app and hands it the file afterwards, 4 runs
in 5 *after* `applicationDidFinishLaunching` -- a launch followed by a Finder open, so there the
launch window stays and the archive gets a second one. The UI test asserts exactly that, see §4.)

## 3. Shortcut: Option+Cmd+N, not Cmd+N

The request said Cmd+N. Cmd+N is already **Create File** (`IDM_CREATE_FILE 556`, Windows Ctrl+N),
under the port's fixed Ctrl → Cmd mapping (`MainMenu.swift` header; Comment keeps Cmd+Z over Undo
for the same reason). Parity with 7zFM is the specification (`CLAUDE.md`), so Create File keeps
Cmd+N and New Window takes **Option+Cmd+N**, which nothing else uses. **Decision for the user:** if
Cmd+N should be New Window after all, it is one line each for the two items in `MainMenu.fileMenu()`,
and Create File would move to Ctrl+N (the literal Windows chord) or lose its shortcut; the tests
that pin the two chords are `NewWindowTests.testNewWindowMenuItemOpensACascadedWindow` and
`NewWindowUITests.testNewWindowShortcutAndMenuItem`.

New Window is the first item of File, followed by a separator, as in every Mac app; 7zFM's File
menu starts with Open.

## 4. Saved state: each window starts like a fresh 7zFM; the last one closed wins

- **Start.** Every window is a `MainWindowController()`, whose `restoreState()` reads the settings a
  fresh 7zFM process reads from the registry (`CWindowInfo::Read`, `CApp::Create`): frame, maximized,
  panel count, focused panel, splitter ratio, both panel paths, list modes, toolbars. A new window
  is cascaded off the frontmost one (`cascadeTopLeft`) because the saved frame is shared and it would
  otherwise sit exactly on top.
- **Close.** `windowWillClose` saves the window's state, as WM_CLOSE runs `g_App.Save()` +
  `SaveWindowInfo` (FM.cpp:1028-1047). So the window closed last is what the next launch or the next
  new window reads, as the 7zFM process that exits last wins. A window saves once: `isClosed` stops
  a second save, and a closed window leaves `MainWindows.controllers`.
- **Quit.** `applicationWillTerminate` used to save only the launch window -- even after it had been
  closed, which would have overwritten a later close with stale state. Now
  `MainWindows.saveAllForTermination()` saves every *open* window from the back to the front, so the
  frontmost window's state is what survives (the same result as closing them one by one from the
  back). The nested-archive write-back on Quit skips closed windows too.
- **No shared mutable state between windows** beyond the settings: each controller has its own
  panels, splitter ratio, toolbar mask copy and refresh timer. `ActiveContext` follows the main
  window (`windowDidBecomeMain`), unchanged.

## 5. Code

| File | Change |
|---|---|
| `Mac/App/MainWindow/MainWindows.swift` (new) | the window list: `open()` (create, register, show, cascade), `primary`, `frontToBack`, `didClose`, `saveAllForTermination()` |
| `Mac/App/AppDelegate.swift` (orchestrator-owned) | `mainWindowController` is now `MainWindows.primary` (the oldest open window, so it is never a closed one); `applicationShouldHandleReopen`; `fileNewWindow:` / `openNewWindow()`; no default window when a cold launch was for documents (`needsLaunchWindow`); Quit saves every open window |
| `Mac/App/MainWindow/MainWindowController.swift` (panel) | `isReleasedWhenClosed = false` (the controller owns its window; AppKit's extra release on close would free it under a controller that is now released after close); `isClosed`; `closeDiscardingState()`; `windowWillClose` reports to `MainWindows` |
| `Mac/App/Integration/CommandExecutor.swift` (finder) | `openInFileManager` opens a new window for **every** path; the never-emptied `extraWindowControllers` list is gone |
| `Mac/App/Integration/TestReset.swift` (finder / resetcmd) | the reset closes a second file-manager window (instead of only ordering it out, which left it alive and saving on Quit), **without saving**: in a UI test the settings domain is the seed file the test has just rewritten, and the close's save overwrote it -- found by the first UI run, where a window opened after a reset showed the previous test's folder |
| `Mac/App/MainMenu.swift` (shared, additive) | File ▸ New Window and `MenuActions.fileNewWindow(_:)` |

## 6. Tests

App-hosted, `Mac/Tests/AppTests/NewWindowTests.swift` (9 cases): reopen with windows open → one more
window each time, returning false, at the saved path; reopen with none visible → a visible window;
the New Window item (first in File, Option+Cmd+N, Create File still Cmd+N) opens a cascaded window;
a new window starts from the saved panel count, focused panel and both paths; the window closed last
wins and a closed window never saves again; Quit saves back to front; an archive from Finder opens
in a new window and leaves the open window alone, a second archive in a third; two files in one
event give two windows; the cold-launch decision.

XCUITest, `Mac/Tests/UITests/NewWindowUITests.swift` (input shard, 5 cases), through real input and
real Launch Services events (no Automation consent involved: Launch Services sends the events, the
test drives no other app):

| test | input path |
|---|---|
| `testReopenWithAWindowOpenOpensAnotherWindow` | `NSWorkspace.openApplication(at:)` aimed at this shard's bundle = the reopen event of a Dock click; twice → 3 windows, both new ones at the saved folder |
| `testReopenWithNoVisibleWindowOpensOne` | Window ▸ Minimize, then the reopen event → a visible new window, the Window menu lists two |
| `testNewWindowShortcutAndMenuItem` | the Option+Cmd+N keystroke, then a click on File ▸ New Window |
| `testArchiveFromFinderGetsItsOwnWindow` | `NSWorkspace.open(_:withApplicationAt:)` = Finder's open-documents event; the first window keeps its folder |
| `testArchiveOpenedIntoAFreshProcessGetsItsOwnWindow` | `XCUIApplication.open(_:)` on a terminated app: exactly one window shows the archive |

Screenshots: `newwindow-01` … `05` (UI), `newwindow-10`, `11` (hosted).

## 7. Verification

RESULTS

## 8. Known gaps and follow-ups

- **A real Finder double-click on a cold app cannot be observed from XCUITest**: an instance that
  Launch Services started is "not running" to `XCUIApplication`, and the runner is not itself
  trusted for the accessibility API. The ordering it depends on was measured with `open -a` (§2);
  the decision function is unit-tested.
- **`open -a 7-Zip --args <path>` on a running app** cannot honour the path (Launch Services sends
  a bare reopen). `open -n` does.
- The Cmd+N question of §3 is the user's to answer.
- `Mac/docs/architecture.md` "As built" (orchestrator-owned, not edited) still says the app has one
  `mainWindowController`; it should mention `MainWindows`.
