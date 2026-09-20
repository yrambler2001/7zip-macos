# `vmcheck` — fresh-VM environment verification

**The build and test environment is healthy: the clean build, all 209 unit tests and the whole
XCUITest suite run on this VM with exactly the five failures already recorded in `requests.md`.**
**Two things still need the user in System Settings** — Terminal has no Automation and no Screen
Recording permission, so AppleScript-driven workflows and `screencapture` do not work; the UI tests
and the app itself are unaffected. Details in §5 and the numbered list in §7.

Run on branch `mac/vmcheck` in `~/things/a.noindex/7zip/.worktrees/vmcheck`,
2026-09-20, against `macos` commit `8d022fe`.

---

## 1. Tool versions, as measured

Every command ran with `DEVELOPER_DIR=/Applications/Xcode.app` exported. `xcode-select -s` was
never run.

| Tool | This VM | `04-toolchain.md` §1 expects | Verdict |
|---|---|---|---|
| Machine | Apple Silicon (arm64) | Apple Silicon (arm64) | match |
| macOS | **26.6.2 (25G83)** | 26.4 (25E246) | newer point release, no effect |
| Xcode | **26.6 (17F113)** at `/Applications/Xcode.app` | 26.6 (17F113) | exact match |
| macOS SDK | **26.5** (`-sdk macosx26.5`, the only macOS SDK listed) | 26.5, `MacOSX26.5.sdk` | exact match |
| Apple clang | **21.0.0 (clang-2100.1.1.101)** | 21.0.0 (clang-2100.1.1.101) | exact match |
| Swift | **6.3.3 (swiftlang-6.3.3.1.3)**, swift-driver 1.148.6 | 6.3.3, swift-driver 1.148.6 | exact match |
| XcodeGen | **2.46.0** (`/opt/homebrew/bin/xcodegen`) | 2.45.4 | newer; generates the project in <1 s, no hang |
| GNU Make | 3.81 (Xcode's) | 3.81 | match |
| git | 2.50.1 (Apple Git-155) | 2.50.1 | match |

One deviation from the doc worth recording: `04-toolchain.md` notes the *global* `xcode-select`
selection is `/Applications/Xcode15.app` and "must stay". This VM has **only** Xcode 26.6, and the
global selection is `/Applications/Xcode.app/Contents/Developer`. Nothing was changed; the scripts
set `DEVELOPER_DIR` themselves, so the rule "never run `xcode-select -s`" still holds and now costs
nothing.

## 2. First-launch setup

| Step | Before | Action | After |
|---|---|---|---|
| Xcode licence | already agreed: `/Library/Preferences/com.apple.dt.Xcode` `IDEXcodeVersionForAgreedToGMLicense = 26.6`, and `xcodebuild -version` ran without a licence error | **none needed** | unchanged |
| Xcode first-launch components | `xcodebuild -checkFirstLaunchStatus` exited 0 with no output, i.e. nothing pending | **none needed** (`-runFirstLaunch` not run) | unchanged |
| Developer mode (debug/test authorization) | `DevToolsSecurity -status` → *"Developer mode is currently disabled."* | `sudo DevToolsSecurity -enable` | *"Developer mode is currently enabled."* — this is the one machine change made |
| `_developer` group | the account is already a member (`id -Gn` lists `admin _lpadmin _developer`) | none needed | unchanged |

Developer mode being off is what would otherwise make every `xcodebuild test` run pop an
authentication panel ("… wants to take control of another process"). It is now off the table.

## 3. Build and unit tests

Run from the `vmcheck` worktree after `rm -rf Mac/build` (fresh DerivedData).

| Step | Command | Wall clock | Result |
|---|---|---|---|
| clean build | `Mac/scripts/build.sh` | **34 s** | `** BUILD SUCCEEDED **`, rc 0 |
| unit tests | `Mac/scripts/test.sh` | **42 s** | `209 passed, 0 failed`, rc 0 |

* XcodeGen generated `Mac/7-Zip.xcodeproj` with no hang (the 120 s `alarm` guard in `build.sh` was
  never hit) and XcodeGen 2.46.0 is fine despite the doc pinning 2.45.4.
* **Zero warnings from `Mac/` sources.** `grep -cE '(^|/)Mac/[^ ]*:[0-9]+:[0-9]+: warning'` over
  `Mac/build/build-Debug.log` returns 0. 33 warning lines remain, all from upstream `C/` and `CPP/`,
  which the hard rules tolerate.
* The product is signed as expected: `Identifier=com.yrambler2001.7zip`, `Signature=adhoc`,
  `flags=0x2(adhoc)`, `TeamIdentifier=not set`.
* `Mac/scripts/parity-check.sh` reports the same `334 / 496` as the handoff, so nothing in the tree
  drifted during the move.

For reference, the previous machine's `verify-latest.md` recorded 22 s for the clean build and 36 s
for the unit tests; this VM is about 50 % / 17 % slower, which is ordinary VM overhead and not a
problem.

## 4. UI tests — compared against the recorded baseline

```
Mac/scripts/test.sh --ui        rc 65, wall clock 318 s
  FAIL  7-ZipUITests: 14 passed, 5 failed, 316s
```

**14 of 19, and the five failures are exactly the five in `requests.md`** — no additional failure,
no missing one, so nothing regressed and nothing on this VM interferes.

| # | Test | `requests.md` row | Observed here |
|---|---|---|---|
| 1 | `SmokeTests/testSortByColumnHeaderReordersRows` | test isolation: the app persists the column layout, so the next launch restores Unsorted | `SmokeTests.swift:108` — got the previous run's order instead of name-ascending, message "default order is name ascending" |
| 2 | `PanelTests/testCopyBetweenPanels` | `SevenZipPanel.addressBar` indexes the split group's combo boxes and picks the wrong one once a second panel exists | `PanelTests.swift:137` — `XCTAssertTrue failed` navigating panel 1 |
| 3 | `PanelTests/testListContextMenuContents` | the right-click helper captured the Apple menu instead of the panel's context menu | `PanelTests.swift:219` — the asserted menu really is the Apple menu ("About This Mac", "System Settings…", … "Clear Menu") |
| 4 | `PanelTests/testSelectionCommands` | the select-by-mask field lookup fails silently, so the default `*` mask selects everything | `PanelTests.swift:93` — "status: 4 / 4 object(s) selected" where 2 of 4 was expected |
| 5 | `SmokeTests/testMenuBarStructure` | File > CRC submenu title (`Lang.menuTitle(553, "CRC")`, id 553 unused by the Windows .rc) | `SmokeTests.swift:170` — `XCTAssertTrue failed` |

Per-class: `PanelTests` 10 tests / 3 failures / 195 s; `SmokeTests` 9 tests / 2 failures / 93 s.

The previous machine's `verify-latest.md` recorded 377 s for the UI step; this VM did it in 318 s.

### Harness infrastructure, confirmed working

* **App-launch lock**: `== app lock acquired … == app lock released` around the run, on the shared
  directory `~/things/a.noindex/7zip/.worktrees/.app-lock`. It was also taken and
  released by hand for the manual launch of §6, and no stale lock was left behind.
* **Preferences guard**: `com.yrambler2001.7zip` was exported to `Mac/build/prefs-backup.plist`,
  cleared for the run and imported back at the end — both lines printed.
* **Screenshot export**: `20 screenshot(s) -> Mac/docs/reports/screenshots`, i.e. the
  `xcresulttool export attachments` path and the manifest-renaming Python both work on Xcode 26.6.
  The 20 files are the ones already tracked in git and they show as modified, not added.
* `--target 7-ZipUITests --only SmokeTests/testOpenFixtureArchiveListsEntries` selected and ran that
  single test, so the `--only` flaw recorded in `requests.md` is only the missing-`--target` case.

## 5. Privacy permissions: what is missing and why a script cannot fix it

Measured facts, no guessing:

| Fact | Value |
|---|---|
| System Integrity Protection | **enabled** (`csrutil status`) — so `TCC.db` cannot be read or written even with `sudo`; both `sqlite3` attempts returned `authorization denied`. `tccutil` can only *reset* a permission, never grant one. |
| GUI session | real and on the console: `launchctl managername` = `Aqua`, `kCGSSessionOnConsoleKey = 1`, `kCGSessionLoginDoneKey = 1`, main display 1 at 1796 px wide. So nothing here is a "headless VM" artefact. |
| Controlling (TCC-responsible) process for this session | **`Terminal.app`** — `/System/Applications/Utilities/Terminal.app`, bundle id `com.apple.Terminal`, pid 409. The chain is `Terminal → login → zsh → claude → zsh`, and `responsibility_get_pid_responsible_for_pid` walks every descendant back to pid 409. Every TCC decision is therefore attributed to Terminal, not to `claude`, `osascript` or `python3`. |
| Automation → System Events | **not granted and not yet decided.** `AEDeterminePermissionToAutomateTarget(com.apple.systemevents, ****, ****, askUserIfNeeded=false)` returns **`-1744 errAEEventWouldRequireUserConsent`**. |
| Automation → Finder | same: **`-1744`**. |
| Automation → the built app (`com.yrambler2001.7zip`) | **`-600 procNotFound`** while the app is not running; it has never been decided either, so it will behave like the two above. |
| Accessibility | **not granted**: `AXIsProcessTrusted()` → `false`. |
| Screen Recording | **not granted**: `CGPreflightScreenCaptureAccess()` → `false`. |

### The probe and the exact failure

`osascript -e 'tell application "System Events" to return count of processes'` does **not** return
an error. It **hangs forever**: macOS spawns the consent dialog
(`/System/Library/CoreServices/UserNotificationCenter.app`, observed running as pid 787) and
`osascript` blocks on it until somebody clicks. The run had to be killed (`SIGKILL`, exit 137); a
second probe against Finder hung the same way and was killed too. This is the worst possible
failure mode for an unattended agent — not a fast refusal, an indefinite stall. The status code
above (`-1744`) is the non-blocking way to detect it, and is what a future script should use before
attempting any AppleScript.

`screencapture -x out.png` fails immediately and clearly:

```
could not create image from display
```

with exit 1. That is the Screen Recording denial, not a missing display.

### Consequence for the project

* **UI tests are unaffected.** `Mac/scripts/test.sh --ui` drives the app through XCUITest, whose
  runner gets its privileges from `testmanagerd`, not from TCC. The whole suite ran (§4) without a
  single permission prompt. Only the Developer-mode setting of §2 mattered there.
* **AppleScript-driven agent workflows are blocked** until Automation is granted, and they block by
  hanging rather than failing.
* **`screencapture` is blocked**, so "launch the app and photograph the screen" is not available;
  XCUITest's own `XCUIScreen.main.screenshot()` is, and it is what produced every screenshot in
  `Mac/docs/reports/screenshots/`.

## 6. Launching the app for real

Done by hand, holding the repository app-launch lock (`mkdir` on
`~/things/a.noindex/7zip/.worktrees/.app-lock`, owner file written, released on
exit as `Mac/docs/api/harness.md` §1a prescribes) and with
`SEVENZIP_DEFAULTS_SUITE=7zip-vmcheck`, so the real `com.yrambler2001.7zip` domain was never
touched. The temporary domain was deleted afterwards.

```
open -n Mac/build/Debug/7-Zip.app --args -FM.PanelPath0 <repo>/Mac/Tests/Fixtures/
```

* The process came up: `7464 …/Debug/7-Zip.app/Contents/MacOS/7-Zip -FM.PanelPath0 …/Mac/Tests/Fixtures/`.
* A real main window exists: `CGWindowListCopyWindowInfo` reports `kCGWindowOwnerName = "7-Zip"`,
  `kCGWindowLayer = 0`, bounds **960 x 723 at (418, 112)**. `kCGWindowName` is **absent**, which is
  itself the Screen-Recording denial — macOS withholds window titles from an unauthorised client.
* `screencapture -x` failed again with `could not create image from display`.
* Apple Events to the app: `AEDeterminePermissionToAutomateTarget(com.yrambler2001.7zip)` →
  `-1744`, so `tell application "7-Zip" to quit` would have hung on a consent dialog. The app was
  quit with `pkill -x 7-Zip` instead (it owns the lock, no other worktree's process was touched);
  no `7-Zip` process remained afterwards and the lock was released.

**The screenshot had to be taken the other way.** Since `screencapture` is denied, the two files

* `Mac/docs/reports/screenshots/vmcheck-01-fixture-archive-test7z.png`
* `Mac/docs/reports/screenshots/vmcheck-02-main-window-fixtures.png`

were captured by XCUITest's own `XCUIScreen.main.screenshot()`, which needs no TCC grant, by
re-running `SmokeTests/testOpenFixtureArchiveListsEntries` on its own
(`Mac/scripts/test.sh --target 7-ZipUITests --only …`, 1 passed, 15 s). The first shows the main
window with the fixture `test.7z` open and its three entries listed with the full Details column
set (Name / Size / Packed Size / Modified / Attributes / CRC / Encrypted / Method / Block /
Folders), the toolbar, the address bar and the status line "1 / 3 object(s) selected". The second
shows the file-system panel populated with the ten fixtures. So the requirement — main window up,
populated panel, a fixture archive opened, screenshot on disk — is met; only the capture mechanism
differs, and that is the Screen-Recording grant of §7.


## 7. What needs the user personally

Three items, all TCC grants for **Terminal** (`/System/Applications/Utilities/Terminal.app`). None
of them blocks the build or the test suites; they only unblock AppleScript-driven agent workflows
and full-screen screenshots. Do them in one pass, then **quit and reopen Terminal** — TCC changes
reach a process only when it restarts, and the Claude session lives inside Terminal.

1. **Automation (Apple Events) — required for AppleScript workflows.**
   This one *cannot* be pre-granted from the System Settings list, because
   *System Settings → Privacy & Security → Automation* only shows applications that have already
   asked, and Terminal has never asked (status `-1744`, no decision recorded). So trigger the ask
   and approve it:
   * In Terminal run `osascript -e 'tell application "System Events" to return count of processes'`
   * A dialog appears: **"Terminal wants access to control System Events. Allowing control will
     provide access to documents and data in System Events…"** → click **OK**.
   * Repeat once with `Finder` in place of `System Events`, and once with `"7-Zip"` after the app
     has been launched, to cover the three targets the workflows use.
   * Afterwards, *System Settings → Privacy & Security → Automation → Terminal* will list
     **System Events**, **Finder** and **7-Zip** with switches; leave them on.
   * Do **not** run that command from an unattended agent session: it hangs on the dialog instead of
     failing.

2. **Screen & System Audio Recording — required for `screencapture`.**
   *System Settings → Privacy & Security → Screen & System Audio Recording* → **+** →
   `Macintosh HD ▸ System ▸ Applications ▸ Utilities ▸ Terminal.app` (⇧⌘G and paste
   `/System/Applications/Utilities/Terminal.app`) → switch **Terminal** on.
   Verify afterwards with `screencapture -x /tmp/x.png` — it currently prints
   `could not create image from display`.

3. **Accessibility — required only if a workflow does UI scripting (`keystroke`, `click at`).**
   *System Settings → Privacy & Security → Accessibility* → **+** → the same Terminal.app → switch
   **Terminal** on. `AXIsProcessTrusted()` is `false` today. Skip this one if the workflows only
   send scriptable commands (`quit`, `activate`, `get name of window 1`) and never simulate input.

Nothing else on this machine needs a human. In particular no Developer ID, no Homebrew package, no
`xcode-select` change and no Xcode first-launch install is outstanding.

## 8. Anything broken on this VM versus the previous machine

Nothing in the build or test path. Item by item:

* Build, unit tests, UI tests, the app-launch lock, the preferences backup/restore, the screenshot
  export and `parity-check.sh` all behave exactly as `verify-latest.md` recorded, with the same
  five UI failures and no new one.
* Timings are comparable: build 22 s → 34 s, unit 36 s → 42 s, UI 377 s → 318 s.
* The only genuine regressions against the previous machine are the three TCC grants of §7, which
  are per-machine state and were never in the repository.
* Two harmless environment differences: XcodeGen is 2.46.0 rather than 2.45.4, and there is no
  second Xcode 15.4 installation, so the global `xcode-select` points at Xcode 26.6. Neither
  affects anything, because every script sets `DEVELOPER_DIR` itself.
* `Mac/scripts/verify.sh` will still exit non-zero, for the pre-existing reason: it runs the UI
  suite, and those five failures are still open. Use `Mac/scripts/test.sh` for a green signal.
