# Polish report — branch `mac/polish`

Scope: the cross-scope defects nobody owned, plus the first systematic layout sweep of every
window and dialog in the app. Owned paths for this pass: `Mac/App/Panel/*`,
`Mac/App/MainWindow/*`, `Mac/App/Dialogs/*`, `Mac/App/Commands/*`, `Mac/App/Support/*`, new files
under `Mac/Tests/UITests/`. One additive insert in the shared `Mac/App/MainMenu.swift`.

What a later wave needs from this scope — `LayoutAudit`, the drag-out hook and the two changed
signatures — is in `ai/api/polish.md`.

Everything below was measured against the running app before it was changed, and how each filed
diagnosis held up is the first thing each section says. In short: one was **wrong** about the
cause (the Copy dialog), one was **half right** — right that two mechanisms were fighting, wrong
about which one loses and what the damage is (the two-panel collapse), and two were **right**,
one of them understating the effect (the drag-out password does not prompt again, it hangs).

---

## 1. Task 1 — View > 2 Panels collapsed the window

**Filed diagnosis** (`harness` → `panel`): *"`showSecondPanel` does `setPosition(bounds.width * ratio)`
in a `DispatchQueue.main.async`, but `splitView(_:resizeSubviewsWithOldSize:)` recomputes the ratio
from `views[0].frame.width` during the layout pass that the insertion triggers, so the async
`setPosition` is fighting it."* Reported symptom: panel 0 at the 120 pt minimum, panel 1 at 1079 pt,
two times out of three.

**How it held up: half right.** The two really do fight, and the recompute from live frames really
is wrong. But the collapse happens in the *other* order, and it is worse than 120 pt.

Measured with a temporary trace of every `showSecondPanel` / `resizeSubviews` / `setPosition` call
and the subview widths after each, over six launches with `FM.Panels.splitterPos = 0.5` on a
1200 pt window:

| ordering | frequency | what happened |
|---|---|---|
| layout pass first | 5 of 6 | `resizeSubviews` ran with the just-inserted subview still 0 pt wide, so `views[0].frame.width / (oldSize.width - divider)` came out as **1.0008**, and it put the divider at `1080 / 119`. The async block then corrected it to `600 / 599` **30–280 ms later** — a visible flash, and exactly what a test sampling the tree right after the toggle sees. |
| async block first | 1 of 6 | `setPosition(600)` ran before the split view had laid the new subview out. The frames did not add up (1200 + 1 + 0 against a 1200 pt split view) and NSSplitView collapsed **both** panels to `0 / 0`. No further layout pass fixed it: the second panel's table never entered the accessibility tree, `panelCount` stayed 1 and the divider's AX value was 0. |

So the filed "panel 0 at 120" is the transient of the first row observed mid-flight (mirrored:
here it is panel 1 that is 119 pt wide, because `showSecondPanel` inserts the *missing* panel and
in that run it was panel 1; when panel 0 is the one being put back, the same arithmetic gives
`120 / 1079`, which is what was filed).

**Fix** (`Mac/App/MainWindow/MainWindowController.swift`): `splitterRatio` is now authoritative
stored state.

* the divider position is always *derived* from it, never re-derived from live frames;
* `splitView(_:resizeSubviewsWithOldSize:)` applies it, so every layout pass lands on the right
  split and the transient cannot exist;
* only a real divider drag writes it back — `splitViewDidResizeSubviews(_:)` acts only when the
  notification carries `NSSplitViewDividerIndex`, which AppKit sets for a user drag;
* `showSecondPanel` applies it **synchronously**, so there is no ordering to lose, after
  `adjustSubviews()` so `setPosition` sees frames that add up, and then calls
  `layoutSubtreeIfNeeded()` so the new panel lays its own subviews out at the width it has just
  been given;
* `constrainMaxCoordinate` no longer returns a value below `constrainMinCoordinate` on a window
  narrower than 240 pt;
* `saveState` / `switchOnOffOnePanel` persist the stored ratio instead of recomputing it.

**Verified** (`Mac/Tests/UITests/SplitViewTests.swift`, 4 tests):

| case | before | after |
|---|---|---|
| toggle View > 2 Panels, 6 launches | 5 × transient `1080/119`, 1 × permanent `0/0` | 6 × `599.5 / 599.5` |
| launch with `numPanels = 2`, `splitterPos = 0.35` | divider 419.5 after a `1080/119` flash | divider 419.5, no flash |
| the same at the 360 × 240 minimum window | 179.5 after a flash | 179.5 |
| drag the divider → quit → relaunch | 359.5 → `0.299833` → 359.5 | unchanged (this part was already correct) |

Screenshots: `polish-11-two-panels-even.png`, `polish-12-two-panels-stored-ratio.png`,
`polish-13-two-panels-minimum-size.png`, `polish-14-two-panels-restored-ratio.png`.

**A defect this scope introduced and the test caught.** The first version of
`applySplitterRatio` had a "last resort" branch that assigned the two arranged subviews' frames by
hand when their widths did not add up after `setPosition`. It looked like cheap insurance; it was
a bug. The panels are constraint-driven, so a raw frame is not propagated into *their* subviews:
the split came out right, but the second panel came up with its address combo 289 pt wide instead
of 538.5 and its header, list and status line crammed into a strip at the top of the panel. It was
stable, not transient, and reproduced twice with identical numbers before it was understood.
`SplitViewTests` is what caught it — the point of asserting the split rather than the panel count.
The branch is gone and `layoutSubtreeIfNeeded()` does the job properly.

**One filed claim that was wrong for a different reason.** The first attempt to reproduce "the
stored ratio is ignored" seeded `FM.Panels.splitterPos` as a plist `real`. It came back as 0.5
every time, which looked like a second product bug. It is not: `SZSettings` stores doubles as
`"%.6f"` **strings** (`SZSettings.mm:84-96`), so a typed `Double` in the seed is invisible to the
app. `SettingsSeed.cleanValues` already seeds it as `"0.500000"`; any test overriding it must do
the same. Nothing to fix, but it is a trap worth knowing.

---

## 2. Task 2 — the clipped Copy dialog

**Filed diagnosis** (`harness` → `panel` / `opsinfra`): *"`DialogKit.install` sizes the window from
`content.fittingSize + 40` after one `layoutSubtreeIfNeeded`, which seems to under-measure the
button row."*

**How it held up: wrong.** The measurement was exactly right (502 × 230 window at `[449, 563]`,
OK and Cancel at y 788–814, window bottom at 793 — 21 pt of overflow, reproduced by
`LayoutAudit` before any change), but the cause is not under-measurement. `fittingSize` is
correct. The bug is a sign error one line up:

```swift
content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: 20)   // was
content.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -20)  // is
```

Auto Layout's `bottom` attribute grows downwards in AppKit as it does in UIKit, so the positive
constant pushed the whole content 20 pt *below* the window and the bottom row was drawn past the
edge. It was not the Copy dialog's bug: **all 19 dialogs** that go through `DialogKit.install` had
it, and the audit now reports every one of them clean.

`install` also now sets `window.contentMinSize` to the fitting size, so a resizable dialog cannot
be dragged smaller than its own controls — that is the "with the window at its smallest" half of
task 5 for every dialog at once.

Before: `polish-00-copy-dialog-clipped-before.png`. After: `polish-22-copy.png`, `polish-23-move.png`.

---

## 3. Task 3 — accessibility identity of the About items

**Filed diagnosis** (`harness` → `tools`/`panel`): *"`ToolsCommands.install()` retargets both
IDM_ABOUT 961 items at `toolsShowAbout:` on `didFinishLaunching`, so the built menu item's
accessibility identifier is `toolsShowAbout:`, not `helpAbout:`."*

**How it held up: right, and measured.** Before the change, `helpAbout:` matched **0** menu items
and `toolsShowAbout:` matched **2** ("About 7-Zip…" in the 7-Zip menu and in Help).

Two changes, either of which fixes it, because the identity should not depend on the other:

* `MainMenu.item(...)` sets an explicit accessibility identifier from the selector the item is
  *declared* with, so no runtime retarget can rename **any** menu item again. Every existing
  `menuItem(selector:)` lookup keeps working, because the identifier is the same string AppKit
  derived before.
* `MainWindowController.helpAbout` now shows the real `IDD_ABOUT 2900` dialog instead of the
  Wave 1 standard-About-panel placeholder, so the retarget is gone altogether. That also closes
  the `tools` → `panel` row asking for exactly this. `ToolsCommands.install()` stays as an empty
  hook so `MainMenu.build()` needs no edit.

Windows resource IDs are unchanged in the comments (`// IDM_ABOUT` at both call sites).

**Verified**: `AboutAndDragOutTests.testAboutItemsHaveAStableAccessibilityIdentity` — `helpAbout:`
matches 2 items, `toolsShowAbout:` matches 0, and the item opens the real dialog.

---

## 4. Task 4 — password for the drag-out

**Filed diagnosis** (`cleanup` → `extract`): *"`ArchiveDragOut.extract(indices:from:to:...)` has no
`password:` parameter, so a drag-out from an encrypted archive the panel already unlocked asks for
the password again."*

**How it held up: right about the cause, understated about the effect.** `ArchiveDragOut.extract`
takes `password: String? = nil` now and puts it in the runner options (`PasswordIsDefined`), and
`PanelViewController.extractForPromise` passes the `rememberedPassword` the panel was given when
it opened the chain (`CFolderLink`, `PanelNavigation.passwordForArchive`).

No bridge change was needed. The password reaches the engine through the `OperationRunner` acting
as the password delegate, so `Mac/Core/SZExtractor.mm` and its header are untouched — the one
bridge change the brief allowed for was not necessary.

**Verified as a negative control.** `AboutAndDragOutTests.testDragOutOfAnUnlockedArchiveDoesNotAsk…`
unlocks `secret.7z`, drags `readme.txt` out and asserts the 12 bytes land with no second prompt.
With `password: nil` put back, the test fails — and the app does not merely prompt: it stops
answering, because the promise path has already parked the panel queue and hopped to the main
thread (`PanelDragDrop.swift:287-311`) by the time the prompt would have to run. So the filed
"asks again" is really "hangs".

XCUITest cannot drag between applications, so the test drives the **real** promise path through a
new environment-gated hook in the shape the other scopes already use:
`SZ_POLISH_DRAGOUT=<dir>` adds "Drag Out (verify)" to the Tools menu, and choosing it builds the
`NSFilePromiseProvider` with the panel's own `tableView(_:pasteboardWriterForRow:)` and runs the
promise delegate on `PanelViewController.promiseQueue`, exactly as a drop into Finder does
(`Mac/App/Panel/PanelDragOutVerification.swift`). Screenshot: `polish-15-drag-out-encrypted.png`.

---

## 5. Task 5 — the layout sweep

`Mac/Tests/UITests/LayoutAudit.swift` takes one accessibility snapshot of a window and reports
four classes of finding:

| finding | meaning | test verdict |
|---|---|---|
| `CLIPPED` | an element's frame leaves its window's frame | fail |
| `OVERLAP` | two sibling controls cover each other | fail |
| `OVERSIZE` | the window is larger than the screen, so part of it cannot be reached | fail |
| `TIGHT` | a label or title needs more width than its frame gives it | warning — look at the screenshot |

`TIGHT` is deliberately a warning. It measures the text with the system font at the system size,
which is wrong for a small-font note, an `NSBox` title or a toolbar item whose AX frame is the
icon rather than the label, so it over-reports; every `TIGHT` row below was checked on the
screenshot by eye and the verdict says what was really there. A scroll view is treated as a
clipping boundary: a panel's list is legitimately wider than the panel whenever the columns add
up to more, and that is what the scroll bar is for.

`Mac/Tests/UITests/LayoutSweepTests.swift` opens every window and dialog, audits it, attaches a
screenshot of **that window** (not of the app's first window, which clipped every dialog centred
outside the main window's frame) and fails on any hard defect.

### Every window inspected

| Window | Windows dialog | Size | Verdict |
|---|---|---|---|
| Main window, 1 panel | — (01 §1.2) | 1200x785 | clean |
| Main window, 2 panels | — (01 §1.2) | 1200x785 | clean |
| Main window at its 360x240 minimum | — | 360x225 | clean (`SplitViewTests`) |
| Copy | IDD_COPY 3200 | 502x230 | **fixed** — OK / Cancel were drawn 21 pt below the window |
| Move | IDD_COPY 3200 | 502x230 | **fixed** — same |
| Compress | IDD_COMPRESS 4000 | 986x516 | clean (2 `NSBox` titles reported TIGHT; they are not truncated) |
| Compress Options sheet | IDD_COMPRESS_OPTIONS 2100 | 420x264 | clean |
| Extract | IDD_EXTRACT 3400 | 560x410 | clean; only the window *title* truncates, as any long title does |
| Progress | IDD_PROGRESS 100 | 560x290 | clean |
| Overwrite | IDD_OVERWRITE 3500 | 520x312 | clean |
| Password, extract side | IDD_PASSWORD 3800 | 340x222 | clean |
| Password, compress side | IDD_PASSWORD 3800 | 340x348 | clean |
| Messages | IDD_MESSAGES 100 | 640x326 | clean |
| Memory usage | IDD_MEMORY_USE 7800 | 480x340 | clean |
| Properties | IDD_LISTVIEW 99 / IDS_PROPERTIES 6600 | 720x506 | clean |
| Comment | IDD_COMMENT 6400 | 460x248 | clean |
| Split | IDD_SPLIT 7300 | 480x230 | clean (the small-font file name is reported TIGHT; it is not truncated) |
| Combine | IDD_COMBINE 7400 | 578x230 | clean |
| Link | IDD_LINK 7700 | 540x350 | **fixed** — the "Link Type" box had collapsed onto its own title, over the third radio |
| Checksum information | IDD_LISTVIEW 99 / IDS_CHECKSUM 7501 | 720x366 | clean |
| Benchmark | IDD_BENCHMARK 7600 | 900x522 | clean (3 small-font header lines reported TIGHT; none is truncated) |
| About | IDD_ABOUT 2900 | 420x194 | clean |
| Options > System | IDD_SYSTEM 2200 | 660x552 | clean |
| Options > 7-Zip | IDD_MENU 2300 | 660x588 | **fixed** — was 2191x574, wider than the screen |
| Options > Folders | IDD_FOLDERS 2400 | 660x588 | clean |
| Options > Editor | IDD_EDIT 2103 | 660x588 | clean |
| Options > Settings | IDD_SETTINGS 2500 | 660x588 | clean |
| Options > Language | IDD_LANG 2101 | 660x588 | clean |
| Options > Plugins | macOS only | 660x588 | clean |
| Folders History | IDD_LISTVIEW 99 / IDS_FOLDERS_HISTORY 6601 | 720x506 | clean |
| Create Folder | the generic combo dialog | 360x152 | clean |
| Temporary files browser | CBrowseDialog2 | 900x484 | clean |
| Browse | IDD_BROWSE 95 | — | not swept: `NSOpenPanel` / `NSSavePanel`, the macOS parity choice of 01b §4.2 |

Sizes are what the accessibility tree reported on a 1796 pt wide screen with the main window at
1200 x 785. "clean" means no `CLIPPED`, `OVERLAP` or `OVERSIZE` finding; where a `TIGHT` warning
was raised the screenshot was checked by eye and the verdict says what was really there. The final
run leaves **15 `TIGHT` warnings and no hard defect** anywhere in the app. The 15 are: four small-font
labels the heuristic mismeasures (Benchmark's three header lines, Split's file name), four
`NSBox` titles (Compress's Options and Encryption, Extract's and Link's), two `NSToolbarItem`-like
accessibility frames (the Up One Level button reports a width of -1), two status lines that really
do truncate at a 600 pt panel width, and two paths that truncate by design (Extract's archive path,
the Options pluginkit line).

### What the sweep found and fixed

1. **All 19 `DialogKit` dialogs were clipped at the bottom** — section 2. One sign error.
2. **The Link dialog's "Link Type" box (IDG_LINK_TYPE 7710) was collapsed onto its own title**,
   overlapping the third radio button. The radio stack was assigned as the box's content view and
   *then* constrained against `typeBox.contentView` — which by that point was the stack itself, so
   every constraint read "leading == own leading + 8", Auto Layout broke them all and the box had
   no height. The stack now goes into a wrapper view; the dialog grew from 540 × 274 to 540 × 350,
   which is the height its contents always needed. This is the only `OVERLAP` the sweep found.
3. **Options > 7-Zip blew the whole Options window out to 2191 pt** — wider than the 1796 pt
   screen, with the tab strip cut off at "Langu…" and OK / Cancel off the right edge. The
   pluginkit diagnostics label had `lineBreakMode = .byTruncatingTail` and a width tied to the
   stack, but `lineBreakMode` only says *how* to truncate: a label still resists compression below
   its full text, and that text is a command line with a bundle id, a version and a path in it.
   It now has `usesSingleLineMode`, `maximumNumberOfLines = 1` and a low horizontal compression
   resistance, and carries the full text in a tool tip. This was found only because the audit
   compares the window against the screen — nothing inside it was "clipped".

### Deliberately different on macOS, left alone

* **Browse (IDD_BROWSE 95)** is `NSOpenPanel` / `NSSavePanel`, the macOS parity choice recorded in
  01b §4.2. It is a system window with its own layout; there is nothing of ours to sweep.
* **The Options window is resizable with a 560 × 420 minimum** instead of a fixed-size property
  sheet, and its pages are an `NSTabView` rather than Windows' tab control. Intentional.
* **Truncation that is correct**: the Extract dialog's title (`Extract : <path>`, truncated by the
  title bar as any macOS window title is) and the Options > 7-Zip pluginkit line. The alternative
  is a dialog whose width depends on a path, which is the defect fixed in point 3 above.
  The Benchmark window's `Darwin : …` kernel line is *also* flagged `TIGHT` and is **not**
  truncated — checked on `polish-32-benchmark.png`; the heuristic measures it with the system font
  and it is drawn in the small one.
* **Toolbar item labels** (`Add`, `Extract`, …) used to be reported `TIGHT` because an
  `NSToolbarItem`'s accessibility frame is the icon, not the icon plus label. Nothing is truncated
  on screen; the audit skips toolbar descendants now.
* **The Options pages' explanatory notes** are `NSTextField(wrappingLabelWithString:)`, so they
  wrap onto a second line rather than truncating. The audit skips labels tall enough for two
  lines now, which is what they are.

---

## 6. What was verified, and how

* `rm -rf Mac/build && Mac/scripts/build.sh` — clean, no warnings from `Mac/` code.
* `Mac/scripts/test.sh` — **223 of 223** unit tests pass (the baseline, unchanged).
* `Mac/scripts/test.sh --ui` — **36 of 36** UI tests pass: the 19 that were green before plus the
  17 this scope adds (11 sweep, 4 split view, 2 About / drag-out).
* Every test invocation, unit runs included, held the repository app lock
  (`.worktrees/.app-lock`). The lock does not otherwise cover a unit run, and two concurrent
  `xcodebuild test` sessions share `testmanagerd` (`requests.md`, `harness` → orchestrator), so a
  sibling's unit run can kill a UI run. A wrapper took the lock, exported
  `SEVENZIP_APP_LOCK_HELD=1` and called `test.sh` inside it.
* Every UI test launches with `SEVENZIP_DEFAULTS_SUITE` pointing at its own per-test plist
  (`harness` api §3), so the developer's settings were never read or written.

## 7. Known gaps and follow-ups

* **Dialog placement is inconsistent.** Measured on a 1796 pt wide screen with the main window at
  `(100, 285) 1200 × 785`: Copy, Move and Create Folder are centred on the main window; every
  other modal dialog is centred on the *screen* although it is passed a parent window. The cause
  was not chased down (it is placement, not layout — every dialog is fully on screen and
  internally correct), but 7zFM centres on the parent and macOS would too. Worth one pass by
  whoever owns `DialogKit` next.
* **`TIGHT` is a heuristic.** It cannot see the control's real font, so it still over-reports
  small-font notes and `NSBox` titles. It now skips a label tall enough for two lines (it wraps,
  it does not truncate) and anything inside a toolbar (whose items report the icon's frame, not
  the icon's plus the label's), which removed most of the noise. A future version could read the
  font through an accessibility attribute.
* **The sweep does not resize dialogs.** `contentMinSize` now makes "the window at its smallest"
  equal to the fitting size for every `DialogKit` dialog, which is why the min-size pass has
  nothing left to find there; the main window is swept at its 360 × 240 minimum by
  `SplitViewTests`. The Options window (560 × 420 minimum, its own sizing) and the Extract dialog
  (fixed 560 pt, its own sizing) are not swept at their minimum.
* **`PanelDragOutVerification` is a test hook in the shipping app**, gated on an environment
  variable exactly like `SZ_OPSINFRA_DEMO`, `SZ_EXTRACT_CONTEXT` and `SZ_COMPRESS_DEMO`. If the
  packaging scope wants these stripped from Release, they should all go together.
* **`Mac/App/Dialogs/OptionsMenuPage.swift` is `options`-scope territory** and its content is
  `finder`-scope work. The change there is three presentational lines plus a tool tip; it touches
  no setting and no integration logic.
