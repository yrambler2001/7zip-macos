# `infohang`: "I clicked Info, closed it and the app became unresponsive"

> **Publication note:** all but a few showcase images under `docs/reports/screenshots/` were removed from the repository before publication. Paths below that point into them are kept as a record of what was measured.

Branch `mac/infohang`, off `macos` at `2c403fe`, 2026-10-03.

## 1. Root cause in one paragraph

Every dialog in the port is a `DialogKit.window` (`DialogWindow`, 20 dialogs) run with
`NSApp.runModal(for:)`, and each one ends its modal session only from its own buttons
(`NSApp.stopModal()` in OK / Cancel / Escape / Return). The windows have a title-bar close button
(`.closable`). Clicking it **closed the window and left the modal session running**. With a modal
session open for a window that is no longer on screen, AppKit refuses every click on the main
window and the panel's menu commands. Nothing is drawn as busy and there is no beach ball, but the
app takes no more input until it is force-quit. On macOS the red button is the natural way to
close the Properties list, so that is almost certainly what the user did. The flat toolbar
(`FMToolbar.swift`) is not involved: File ▸ Properties and every other dialog behave the same.

## 2. Reproduction matrix (before the fix, `macos` 2c403fe)

App-hosted (`InfoHangTests`, inside the real app process). Properties was opened through the toolbar
Info button's action. "stuck" means the modal session was still running 2 s after the close.

| item \ close | OK | Cancel | Esc | Return | close button | Cmd+W |
|---|---|---|---|---|---|---|
| file `a.txt` | ok | ok | ok | opens the item viewer (by design) | **stuck, window gone** | nothing happens |
| folder `sub` | ok | ok | ok | viewer | **stuck** | nothing |
| archive on disk `test.7z` | ok | ok | ok | viewer | **stuck** | nothing |
| two items | ok | ok | ok | viewer | **stuck** | nothing |
| nothing selected | ok | ok | ok | viewer | **stuck** | nothing |
| `..` (ShowDots) | ok | ok | ok | viewer | **stuck** | nothing |
| item inside `test.7z` | ok | ok | ok | viewer | **stuck** | nothing |
| archive root, nothing selected | ok | ok | ok | viewer | **stuck** | nothing |
| `..` inside the archive | ok | ok | ok | viewer | **stuck** | nothing |
| File ▸ Properties path | | | | | **stuck** | nothing |

Return on a Properties row is OnEnter → ShowItemInfo (ListViewDialog.cpp:247-256, NumColumns > 1).
It opens the item viewer (IDD_EDIT_DLG 94) over the list, as 7zFM does. The viewer's close button
wedged the same way. Cmd+W is File ▸ Exit (IDCLOSE), which targets the main window and is disabled
during a modal session, so it did nothing. That is not a hang, but on Windows Alt+F4 closes the
dialog.

Toolbar audit, same harness (`testEveryToolbarDialogEndsItsSessionWhenClosed`, before the fix):

| button | dialog | close button | Cmd+W |
|---|---|---|---|
| Add | Add to Archive (IDD_COMPRESS) | **stuck** | nothing |
| Extract | Extract (IDD_EXTRACT) | **stuck** | nothing |
| Copy / Move | Copy / Move (IDD_COPY) | **stuck** | nothing |
| Test | progress, then the result alert | progress has `windowShouldClose` (Cancel); alert has no close box | – |
| Delete | none on disk (Trash, FOF_ALLOWUNDO); inside an archive an `NSAlert` with no close box; Esc = No/Cancel | – | – |

With real clicks (XCUITest `InfoHangUITests`, Debug, before the fix): toolbar Info clicked with the
mouse, then the close button. The Properties window disappeared, and the next click on a row was
refused (`close button: a click on a row was refused`). OK and Escape passed. With the fix the
same test passes in **Debug and in Release** (`test.sh -t 7-ZipUITests -c Release`).

## 3. The sample

One `sample <pid> 3` of the Debug app, taken while it was wedged after the close button (the
XCUITest above, 2026-10-03 22:15). Main thread, 1815 of 1815 samples:

```
-[NSApplication run]
 _dispatch_main_queue_drain
  closure #1 in closure #2 in PanelViewController.showProperties()   PanelOperations.swift:253
   static PropertiesDialog.show(lines:parent:)                       PropertiesDialog.swift:171
    static ListViewDialog.run(_:parent:)                             ListViewDialog.swift:38
     -[NSApplication runModalForWindow:]
      -[NSApplication _doModalLoop:peek:]
       -[NSApplication nextEventMatchingMask:untilDate:inMode:dequeue:]
        (1649) NSMenuBarTrackingSession _handleMonitorEvent: ...   <- the test's menu click, refused
```

The main thread is not blocked. It sits idle in the **modal loop of the Properties window**, which
is closed. There is no deadlock, no `main.sync` and no toolbar tracking loop on the stack.

## 4. Fix (owner `opsinfra`: `Mac/App/Dialogs/ProgressDialogSupport.swift`, `DialogWindow`)

One place covers all 20 dialogs:

* `performClose(_:)` (the close button and anything else that asks a window to close): if the
  window is the modal window, it is **IDCANCEL**, as on Windows, where a dialog's close box sends
  WM_CLOSE and DefDlgProc turns that into WM_COMMAND IDCANCEL. A delegate's `windowShouldClose`
  still decides first (Progress and Benchmark already route it to their own Cancel). Next comes the
  dialog's own Escape button (`keyEquivalent == "\u{1b}"`), so its cancel path runs unchanged.
  Without one (the item viewer, About), `stopModal(withCode: .cancel)` runs, which is
  CModalDialog::OnCancel → EndDialog(IDCANCEL).
* `performKeyEquivalent`: Cmd+W in a modal dialog calls `performClose`, the Alt+F4 equivalent.
* `close()` safety net: if a modal window is closed by any other route and its session is still its
  own on the next run-loop pass, with the window off screen, the session is ended. A modal session
  for an invisible window is always a wedge. Every `runModal` caller ignores the response code and
  reads its own result flags, so a duplicate stop is harmless.

No other file changed in `Mac/App`.

## 5. Tests

* `Mac/Tests/AppTests/InfoHangTests.swift` (app-hosted, 4 cases): the matrix above (9 picks × 5
  close ways via the toolbar action); File ▸ Properties with the close button and Cmd+W; Return →
  viewer → viewer close button → back to Properties → Properties close button, every session ended;
  every toolbar dialog closed with the close button and Cmd+W, with nothing written, copied, moved
  or deleted. All of them fail on the old code and pass now.
* `Mac/Tests/UITests/InfoHangUITests.swift` (input shard, owner `harness`): real mouse click on the
  flat toolbar Info, closed with OK / Escape / close button / Cmd+W, then Edit ▸ Select All must
  read "3 / 3" and a click on a row "1 / 3". Screenshots: `screenshots/infohang-properties-open.png`,
  `infohang-responsive-after-close.png`.

## 6. Results (export DEVELOPER_DIR=/Applications/Xcode.app, final code)

| run | result |
|---|---|
| `Mac/scripts/build.sh` | clean, no warnings in `Mac/` |
| `Mac/scripts/test.sh` | 387 passed |
| `Mac/scripts/test.sh -H` | 137 passed (incl. `InfoHangTests` 4) |
| `InfoHangUITests`, Debug and Release | passed |
| `Mac/scripts/test.sh -u` | 58 passed: input 46 (incl. `InfoHangUITests`), probe 6 + 6 |

The app-hosted target cannot be built in Release (`@testable import SevenZipAppHost` needs a
testable build). Release coverage is therefore the XCUITest against the Release app.

## 7. UI suite

`Mac/scripts/test.sh -u` at the final code: 46 + 6 + 6 passed, 0 failed, 668 s. The two
`NewWindowUITests` reopen cases that `winmatch` saw fail because of a foreign 7-Zip instance pass here.

## 8. Not changed / follow-ups

* `NSAlert`s (delete confirmation, test result, errors) have no close box and are unaffected.
* `OptionsWindow` is not modal and has its own `windowShouldClose`. `BrowseDialog` is an
  `NSOpenPanel`, which ends its own session.
* The toolbar strip's `NSButton` tracking was checked and is innocent: the modal session starts from
  a `DispatchQueue.main.async` after the panel queue built the lines, outside the button's tracking
  loop.
