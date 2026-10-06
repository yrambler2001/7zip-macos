# `polish` — layout auditing, the drag-out hook, and two changed signatures

What a later wave needs from this scope. Report and measurements: `ai/reports/polish.md`.

## 1. `LayoutAudit` — measure a window instead of trusting that it opened

`Mac/Tests/UITests/LayoutAudit.swift`, UI test target. One accessibility snapshot per window, so
it costs a single query.

```swift
LayoutAudit.report(window, name: "Copy")   // [String] -- every finding, warnings included
LayoutAudit.defects(window, name: "Copy")  // only the ones a test must fail on
LayoutAudit.isHardDefect(finding)          // the same filter, for a custom collector
LayoutAudit.size(window)                   // "502x230", for a report table
```

| finding | meaning | hard? |
|---|---|---|
| `CLIPPED <path>: <frame> leaves <window frame>` | an element is drawn past its window's edge | yes |
| `OVERLAP <a> <frame> and <b> <frame>` | two sibling controls cover each other | yes |
| `OVERSIZE <name>: <frame> does not fit the screen (WxH)` | the window is larger than `NSScreen.main.visibleFrame`, so part of it cannot be reached | yes |
| `ERROR <name>: ...` | no snapshot / an empty window frame | yes |
| `TIGHT <path>: "text" needs N pt, has M pt` | the text does not fit its frame, so AppKit truncates it | **no** |

`TIGHT` is a *warning on purpose*. It measures the string with the system font at the system size,
which is wrong for a small-font note, an `NSBox` title or a toolbar item (whose accessibility frame
is the icon, not the icon plus label), so it over-reports. Treat it as "look at the screenshot".

A scroll view, a menu and the menu bar are clipping boundaries: the walk checks their own frame and
does not descend. A panel's list is legitimately wider than the panel whenever its columns add up
to more, which is what the horizontal scroller is for.

**Add your dialog to the sweep** rather than writing a geometry test of your own:
`Mac/Tests/UITests/LayoutSweepTests.swift` has `sweepMenuDialog([menu path], title:name:shot:)`
for anything a menu opens, and `sweep(window, name, shot:)` for anything else. Both print a
`SWEEP | name | size | verdict` line, attach a screenshot of *that window* and collect the hard
defects, which `finish(_:)` asserts at the end of the test.

Screenshot a dialog with `capture(element, name)`, not `SevenZipApp.screenshot`: the latter shoots
the app's first window, which clips every dialog whose frame falls outside the main window.

## 2. `PanelDragOutVerification` — driving a drag to Finder from a test

`Mac/App/Panel/PanelDragOutVerification.swift`, gated exactly like the other scopes' hooks.

```sh
SZ_POLISH_DRAGOUT=<directory>    # adds "Drag Out (verify)" to the Tools menu
```

Choosing the item runs the **real** promise path for the focused row: the provider comes from the
panel's own `tableView(_:pasteboardWriterForRow:)` and the delegate runs on
`PanelViewController.promiseQueue`, as a drop into Finder does. When it finishes it writes
`drag-out-done.txt` into the directory containing `ok` or the error, so a test can wait for the
operation instead of racing a file that is still being written.

XCUITest cannot drag between applications, which is why this exists. Point it at a directory under
`TestPaths.artifacts`: the sandboxed runner can read it and the unsandboxed app can write it.

## 3. Changed signatures

```swift
// Mac/App/Support/TempOpenCommands.swift -- new last parameter, defaulted, source compatible
ArchiveDragOut.extract(indices:from:to:archiveDisplayPath:parentWindow:overwriteMode:
                       password: String? = nil) -> (directory: String, paths: [String])?
```

Pass the password the caller already holds for the archive chain (7zFM remembers it per
`CFolderLink`) and the extraction will not prompt again. Leaving it nil keeps the old behaviour,
which for an encrypted archive means the promise path stops answering rather than prompting — the
panel queue is already parked by then.

```swift
// Mac/App/MainMenu.swift -- MainMenu.item(...) now sets an explicit accessibility identifier
it.setAccessibilityIdentifier(NSStringFromSelector(action))
```

Every menu item built through `item(...)` reports the selector it was **declared** with, not the
one currently installed on it. `sevenZip.menuItem(selector:)` therefore keeps working after any
runtime retarget. If you retarget a menu item, its accessibility identity no longer follows — set
it yourself if you want it to.

`ToolsCommands.install()` is an empty hook now: `MainWindowController.helpAbout` opens the real
`IDD_ABOUT 2900` dialog, so nothing retargets IDM_ABOUT 961 any more.

## 4. `DialogKit.install` (`Mac/App/Dialogs/ProgressDialogSupport.swift`)

Unchanged signature, two behaviour changes every dialog inherits:

* the content is inset by `DialogKit.margin` (20 pt) on **all four** sides. It used to be pushed
  20 pt below the window, so every dialog's bottom row was drawn past the edge.
* `window.contentMinSize` is set to the fitting size, so a resizable dialog cannot be shrunk into
  its own controls. If your dialog is meant to shrink further, set `contentMinSize` again after
  calling `install`.

A label that must not widen its dialog needs more than `lineBreakMode`: give it
`usesSingleLineMode`, `maximumNumberOfLines = 1` and
`setContentCompressionResistancePriority(.defaultLow, for: .horizontal)`. One label without them
grew the Options window to 2191 pt, past the edge of the screen.
