# `modalfix` — the window-less app-modal alert, and a reset that never acknowledged

Branch `mac/modalfix`, worktree `.worktrees/modalfix`. Scope: the two app-side halves left open by
`Mac/docs/reports/fastui.md` §6.10. The test half of that defect was fixed on `mac/fastui`; this is
the app.

**In one line.** A panel closed at runtime kept reloading and reported its failures with an app-modal
`NSAlert` owned by no window; and a reset that could not finish wrote nothing at all, so a test could
only report a timeout. Both are fixed, both are covered by tests that fail on the old code, and the
sharded plan is unchanged in wall clock.

---

## 1. Reproducing it first

Neither half was taken on trust. Both were reproduced in the app's own process (`SevenZipAppTests`,
the app-hosted target — these cases run *inside* a real 7-Zip process, so "by hand in the app" and
"in a test" are the same thing here), against the code as it stood on `macos`.

**The panel half**, the exact user sequence: two panels, panel 1 on a scratch folder, close panel 1
(F9 / `IDM_VIEW_TWO_PANELS 732`), delete the folder, let the app reload its panels.

```
MODALFIX | closed panel, folder deleted, all panels reloaded
        | window: _NSAlertPanel | app-modal: true | sheet of: nothing
```

An `NSAlert` panel, app-modal, with no sheet parent — raised by a panel the user cannot see, about a
folder the user is not looking at. Nothing in the window hierarchy owns it, so nothing in the window
hierarchy can dismiss it; an automated session cannot aim a click at it at all, the reset cannot
settle past it, and every accessibility query afterwards takes about six seconds.

**The reset half.** `fastui` §6.10 guessed at two possible causes (that `transientWindows()` might not
match the alert, and that the carry-on after `settleTimeout` might not run inside `_doModalLoop`).
Measured here, **both guesses are wrong**: the alert *is* matched — it is a visible `NSPanel` — and the
settle ticker *does* fire inside a nested modal session, because AppKit puts `NSModalPanelRunLoopMode`
in the common modes. The real shape is step 4:

```
ZZREPRO | ack arrived: false | generation 0 -> 0 | isResetting: true
  error: no reset acknowledgement within 25 s (generation was 0, is now 0)
```

Step 4 hands every panel a completion block and waits for all of them. A block that never arrives —
a panel queue parked behind a long engine call, or a main queue starved because an app-modal session
owns the main thread — meant `finish` was never reached: no generation bump, no acknowledgement, for
ever. The reproduction parks a panel's serial queue, and the failure message it produces is the one
`fastui` reported verbatim.

One more hazard was found in the same area and is fixed although it did not fire on this macOS:
`closeTransientUI` called `NSApp.abortModal()`, which Apple documents as **raising**
`NSAbortModalException`. Both of its callers run inside a `CFRunLoopTimer` callback, and an exception
that unwinds out of a timer callback leaves that timer marked as firing — the settle ticker and the
request watcher would both die and the process would be unresettable for the rest of its life. On
Darwin 25.6 the call did not raise in a direct experiment, but the documented behaviour is a loaded
gun and it is now `stopModal(withCode:)`, which never raises.

## 2. The panel half, and why this fix and not another

Three fixes were on the table (`fastui` §6.10 and the brief). The chosen one is **(b) the errors
belong on the main window** *plus* **(a) a panel with no window does not refresh** — and explicitly
**not (c) tear the closed panel down**.

* **Not (c).** 7zFM's `SwitchOnOffOnePanel` *hides* the non-focused panel; the `CPanel` lives on and
  is reused with its folder, its path and its columns (01 §1.2, §3.1). The port matches that — the
  comment in `switchOnOffOnePanel` says "it is kept alive and reused later" — and the frozen
  test-support contract depends on it: step 4 of `sevenzip://test/reset` rebuilds "**every** panel —
  including one that is currently hidden, so nothing survives in it". Destroying the panel would
  break parity *and* a frozen contract to work around a presentation bug.

* **(b), because the code asked the wrong question.** `showError(message:)` branched on
  `view.window`. But "this *view* has no window" is not "this *app* has no window". In 7zFM the hidden
  panel still has a valid `HWND`, so `MessageBoxW(_panelHWND, …)` always had an owner window; on macOS
  a view taken out of the split view has none, while the panel still belongs to the main window. So
  the panel now asks its delegate: `PanelViewController.hostWindow` is `view.window` when it has one
  and `MainWindowController.window` otherwise, and the alert is a **sheet** — which a parent window
  can dismiss and which the reset's step 1 can end, neither of which is true of an app-modal alert.

* **(a), because 7zFM does not do the work either.** A hidden panel has nothing to draw and nowhere
  to put a message. `reload(keepScroll:)` now defers when the panel has no window and
  `showSecondPanel()` replays it through `panelDidBecomeVisible()`, so the View menu's timestamp
  items, an Options apply, a language switch and `ActiveContext.refreshAll()` still reach a hidden
  panel — when it comes back, which is the only moment the result means anything. 7zFM's per-panel
  timer belongs to the panel on screen, and its auto-refresh on a vanished folder shows an empty
  listing rather than a message box (01 §3.11, §3.12).

Both halves matter. (b) alone would move the alert to the main window, where the user would be asked
about a folder they closed; (a) alone would leave the ownerless branch loaded for the next caller to
find. Together, a closed panel is silent and a panel that *does* have something to say has somewhere
to say it.

**The rule is now written down once**, in `Mac/App/Dialogs/ErrorAlert.swift`, and it is the thing to
reuse rather than the two-line `NSAlert` dance:

```swift
ErrorAlert.present(ErrorAlert.make(message: text), on: window)   // sheet; logs when there is no window
ErrorAlert.run(ErrorAlert.make(message: text), on: window)       // sheet, synchronous; app-modal only with no window
```

An app-modal alert is honest only when the app has **no** window at all — the 7zG case, a process
opened to run one command line, which is what upstream's `MessageBoxW(NULL, …)` does.

## 3. The same class elsewhere

Every `view.window` branch and every `NSAlert` presentation in `Mac/App` was read.

| Site | Finding | Action |
|---|---|---|
| `Panel/PanelViewController.swift` `showError` | the defect | fixed |
| `Dialogs/OptionsSystemPage.swift:315` | same branch, same `runModal()` fallback — and **reachable**: `NSWorkspace.setDefaultApplication` answers asynchronously and the user can close the Options window while the requests are in flight | fixed (`ErrorAlert.present` on the page's window, else the app's main window) |
| `Integration/CommandExecutor.swift` `showError` / `showInfo` | worse than a branch: they *accept* a `parent: NSWindow?` and **ignore** it, so every message from a URL or command-line command was app-modal with no owner even when the app had a window — the same wedge, on the same channel the reset arrives by | fixed (`ErrorAlert.run(on: parent)`; a sheet when there is a parent, still synchronous, so no caller changes) |
| `Dialogs/OptionsFoldersPage.swift:107`, `OptionsEditorPage.swift:101` | branch on `view.window` but `guard … else { return }` — they skip the browse panel rather than raising an ownerless one | correct as is |
| `Panel/PanelOperations.swift:78` `confirmDelete`, `PanelNavigation.swift:279` `confirmSuspiciousName`, `PanelDragDrop.swift:279` `confirmCopyToArchive` | app-modal `runModal()` with no owner, but **by design** and never from an invisible panel: each is a synchronous yes/no answer raised by a gesture on the focused, visible panel, and 7zFM asks them with `MessageBoxW` too (01 §2.8, IDS_CONFIRM_*) | left alone, deliberately — converting them to modally-run sheets is a visible change to 21 UI-test lookups for no defect |
| `Commands/ExtractCommands.swift:344`, `CompressCommands.swift:319`, `ToolsCommands.swift:107`, `Support/TempOpen*.swift`, `Support/OperationRunner.swift` | branch on an explicitly passed `parent`, where nil really does mean "no window" | correct as is; not this scope's files either |

**Timers and observers still running on an invisible panel**, the other half of the sweep:

* `MainWindowController.refreshTimer` (1 s, `IFolderWasChanged` polling) already iterated
  `visiblePanels` only — so the `fastui` diagnosis "with its auto-refresh still running" is not quite
  right about the timer. `refreshIfChanged()` now carries the guard itself, so the rule holds for any
  caller rather than for one call site.
* The three `NotificationCenter` observers a panel registers (`Settings.Group.fm` → `applyListSettings`
  → `reload`, `.view` → `reload`, `.language` → `reload`) **were** the live route to a hidden panel,
  and they are what step 3 of a reset fires. This is where the wedge actually came from. Deferred now.
* Nothing else: `PanelDragOutVerification`'s observer is a one-shot, env-gated, app-level hook, and
  `Mac/App` has no other per-panel timer.

## 4. The reset half

Two changes, in `Mac/App/Integration/TestReset.swift`. `Mac/docs/api/resetcmd.md` has the dated note.

1. **Settle past a modal session rather than waiting for it.** `stopModalSession()` replaces
   `NSApp.abortModal()`: `stopModal(withCode: .abort)` plus a posted `applicationDefined` event to
   wake the loop, which never raises. The settle ticker retries every 20 ms, so nested sessions unwind
   one layer per tick, and the ticker is now armed **before** anything that can unwind, so even a stray
   exception leaves the reset with a heartbeat. `closeTransientUI` also sets `animationBehavior = .none`
   before ordering a window out: ordering a window out again while AppKit is animating the first call
   over-releases its `_NSWindowTransformAnimation` (`EXC_BAD_ACCESS` in `objc_release` under
   `CA::Transaction::commit`, measured once), and a reset has nothing to animate.

2. **The acknowledgement is unconditional, and it carries a diagnosis.** `settleTimeout` (still 15 s)
   now applies twice — to step 2, and to steps 3–4 together — and whichever expires, step 5 runs:
   generation bumped, accessibility value published, ack written. Beside the ack goes a note
   (`<ack>.stall`, or `<SZ_STATE_DIR>/reset-stall`) naming the step and what was still up:

   ```
   7: step 2 (wait until it really has stopped) timed out after 15 s: 1 window(s) would not go: StubbornWindow
   7: step 4 (rebuild the panels) did not finish within 15 s: an operation is still running
   ```

   A reset that settled **removes** the note, so a stale diagnosis can never be read as this reset's.
   `runID` makes `finish` run exactly once per reset, so a rebuild that calls back after the watchdog
   has acknowledged cannot finish the *next* reset by accident. The ack file's contents are unchanged
   (the generation as decimal text), so the frozen contract has not moved: a harness that ignores the
   note behaves exactly as before.

   This is the point of the whole change and it is worth stating plainly: **a diagnostic that says
   which step stalled is worth more than a clean-looking timeout.** The old code's silence turned a
   panel-queue stall into "the test timed out", which names nothing.

Two smaller ones fell out of it. `resetForTest` binds with `navigate(…, reportErrors: false)`, because
step 1 has just closed every dialog and an error sheet raised by step 4 would survive the reset and
greet the next test. And `MainWindowController.windowWillClose` detaches its toolbar: `NSToolbar`'s
`removeItem(at:)` indexes the *displayed* items while `toolbar.items` holds every item, so a toolbar
on a closed window makes `OptionsPostApply.reloadLangItems()` — which step 3 calls — throw
`NSInternalInconsistencyException`. Measured: the exception unwound out of the settle ticker, step 4
never ran, and the next reset queued behind the abandoned one. The watchdog acknowledged anyway, which
is exactly what it is for; the throw should still not happen, and the other half of it (walking windows
it should skip) is filed for `options`.

## 5. What was verified, and how

Seven new cases, all in `SevenZipAppTests` so they cost seconds rather than an app launch each.

| Case | Asserts | On the old code |
|---|---|---|
| `PanelWindowlessErrorTests.testAClosedPanelWhoseFolderVanishedOpensNoOwnerlessModalAlert` | the user sequence opens no app-modal session | **fails**, 3/3 |
| `…testAClosedPanelReportsItsErrorOnTheWindowThatOwnsIt` | a closed panel's error is a sheet of the owning window | fails (no `hostWindow`) |
| `…testReopeningAPanelAppliesTheReloadItDeferred` | deferring is not dropping | fails (no deferral) |
| `TestResetSettleTests.testTheResetSettlesPastAnOwnerlessAppModalAlert` | a reset delivered *into* a modal session ends it and acknowledges **without** stalling | — |
| `…testAStalledPanelRebuildStillAcknowledges` | a rebuild that never returns still acknowledges, naming step 4 | **fails**: "generation was 0, is now 0" |
| `…testAStalledSettleStillAcknowledgesAndSaysWhatStalled` | a settle that cannot succeed still acknowledges, naming step 2 | — |
| `…testACleanResetRemovesAnEarlierStallNote` | a clean reset removes a stale note | — |

The panel cases use `ModalProbe`'s trick (`fastui` §6.5): a timer added to `.common` and `.modalPanel`
*before* the trigger fires **inside** the nested `NSApp.runModal` loop, so a wedge is recorded and then
ended with `NSApp.stopModal()` instead of hanging the whole bundle. That is why reproducing an
unkillable modal session did not cost a 300 s timeout.

Screenshot: `Mac/docs/reports/screenshots/modalfix-closed-panel-folder-deleted-no-wedge.png` — the main
window after the sequence that used to wedge it, one panel, listing, no alert over it.

**Results.** Baseline to match: a clean build with no `Mac/` warnings, 342 unit tests, the sharded plan
green.

| Run | Result | Wall clock |
|---|---|---|
| `build.sh` | 0 warnings from `Mac/` code (1 upstream) | — |
| `test.sh` (unit) | **342 passed** | 56 s |
| `test.sh --target SevenZipAppTests` ×3 | **32 passed** each (25 before, +7) | 84 / 81 / 81 s |
| `test.sh --shards` (before the stability fixes) | 421 passed, 0 failed — but the host app crashed and restarted, losing one case | 719 s |
| `test.sh --shards` A | **RESULT_A** | **WALL_A** |
| `test.sh --shards` B | **RESULT_B** | **WALL_B** |

The sharded plan's wall clock is the number the defect's six-second-query penalty would have shown up
in: `fastui` measured 674–701 s for a clean plan and 851–1049 s when the machine was shared, and the
input shard is 520–530 s of it. The runs here sit in that clean band, so the penalty is gone — it was
never in this branch's numbers to begin with, because the test-side fix that stopped provoking it
merged with `mac/fastui`; what this branch removes is the *trap*, not a cost that was still being paid.

### Flakiness found and fixed while running it

Three runs of the app-hosted target in a row flushed out three real problems, all now fixed and all
worth naming because two of them were in the app:

* the toolbar throw above, which the watchdog survived but which cascaded into the next case's
  generation being two higher — the reason `TestResetSettleTests.setUpWithError` now asserts that no
  reset is in flight, so a cascade fails with a sentence instead of an arithmetic mismatch;
* the repeated `orderOut` during a window fade, which segfaulted the host app;
* my own stall fixture: a directly constructed `NSWindow` defaults to `isReleasedWhenClosed = true`, so
  a test that also holds it in a property released it twice. `NSWindowController` clears the flag for
  the app's own windows, which is why nothing else in the suite needed it.

After those, `SevenZipAppTests` is 32/32 on three consecutive runs.

## 6. Parity notes

* 01 §1.2, §3.1 — the closed panel is kept and reused, as `SwitchOnOffOnePanel` does.
* 01 §3.11, §3.12 — auto-refresh and `RefreshListCtrl_SaveFocused`: a vanished folder shows an empty
  listing (or goes up, `recoverFromRemovedDirectory`), it does not open a message box.
* 01 §2.8 — the error message boxes; `IDM_VIEW_TWO_PANELS 732`, `IDM_VIEW_TIME_UTC 799` keep their
  resource IDs in the code and in the tests.
* No upstream file was touched.

## 7. Gaps and follow-ups

* **`OptionsPostApply.reloadLangItems()` walks windows it should skip** — filed for `options` in
  `Mac/docs/requests.md`. The half that belongs to this scope (not leaving a toolbar on a closed
  window) is done; the robust guard belongs in that function.
* **The stall note is written but nothing reads it yet.** `harness` should surface
  `<ack>.stall` in the "no reset acknowledgement" failure message — that is the whole point of
  writing it, and it is the difference between "the reset timed out" and "step 4 did not finish: an
  operation is still running". Filed.
* **Three confirmation alerts are still app-modal with no owner** (`confirmDelete`,
  `confirmSuspiciousName`, `confirmCopyToArchive`). They are 7zFM's `MessageBoxW` answers and are only
  ever raised by a gesture on the visible panel, so they are not the defect; but they are the last
  places in `Mac/App` where the app runs a modal session the reset has to abort, and a later scope that
  wants `ErrorAlert.run` everywhere should convert them together with the UI-test lookups.
* **`Mac/docs/PROGRESS.md` is untouched**, as on `mac/fastui`: its checkboxes are product features and
  this branch implements none.
* **Files touched outside this scope's ownership**: two new test files under `Mac/Tests/AppTests/`
  (additive; the `harness` scope owns that directory, and no existing file there was edited) and the
  one new screenshot. Nothing else.
