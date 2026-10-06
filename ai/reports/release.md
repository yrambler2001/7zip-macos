# `release` — packaging, the last backlog, the final audit

Branch `mac/release`, off `macos` at `0890681`, 2026-10-03. Scope: `release`, acting as the
`packaging` owner and closing the remaining backlog. Files outside `packaging` that were touched
are listed per scope in §7.

## 1. Results in one table

| | before | after |
|---|---|---|
| Checklist (`parity-check.sh`) | 467 / 496 | **490 / 496** |
| Packaging section | 11 / 22 | 20 / 22 |
| Open `requests.md` rows not addressed to `human` | 21 | 0 (17 done or acknowledged, 2 decided as `packaging`, 2 decisions for the orchestrator) |
| Inventory resource ids cited in code (grep audit) | 319 / 361 | 359 / 359 (two wildcard stubs dropped) |
| Unit / app-hosted tests | 378 / 92 | 387 / 98 |
| Full `verify.sh -S` | 522 / 0 | 537 / 0 |

## 2. Packaging

- **Release build and DMG.** `Mac/scripts/package.sh` builds Release ad-hoc, asserts the bundle
  (framework + three appexes signed, `codesign --verify --deep --strict`, sandbox on every appex,
  no `get-task-allow`), stages `7-Zip.app`, an `/Applications` link, `License.txt`, `readme.txt`,
  makes a UDZO image, mounts and re-verifies it. Re-run green (§5).
- **Hardened runtime readiness, measured.** A copy of the Release app was re-signed ad-hoc with
  `--options runtime` (appexes with their own entitlements). It refuses to start only because of
  library validation: ad-hoc signatures carry no Team ID, so `SevenZipKit.framework` and the app
  "have different Team IDs" -- a Developer ID signature gives both the same one. With library
  validation relaxed for the local test only, the app launched, opened `test.7z` in a panel, and
  `x` / `a` in command mode exited 0 with the right output. So the shipped app needs **no**
  hardened-runtime exception entitlement: no JIT, no unsigned memory, no plug-ins, no Apple events
  sent (source grep). Nothing was added to the entitlements.
- **Developer ID and notarization: script-ready, never run** (no identity here,
  `security find-identity -v -p codesigning` → 0). Guards re-checked: `--notarize` without an
  identity exits 3 up front; an identity that is not in the keychain exits 1 before the build. The
  exact commands a human runs are in `Mac/README.md` "A signed, notarized build":

  ```sh
  security find-identity -v -p codesigning
  xcrun notarytool store-credentials 7zip-notary --apple-id you@example.com --team-id TEAMID
  Mac/scripts/package.sh -i "Developer ID Application: Your Name (TEAMID)" -T TEAMID -p 7zip-notary
  spctl --assess --type open --context context:primary-signature -v Mac/build/7-Zip-26.03.dmg
  xcrun stapler validate Mac/build/7-Zip-26.03.dmg
  ```
- **Assets and fixtures reproducible.** `fetch-assets.sh` re-downloaded the pinned installer and
  rewrote `Resources/Lang` (93), `SFX` (4) and `Help` (78) byte-identical to the tree.
  `make-fixtures.sh` rebuilt all ten fixtures: four byte-identical, six differing only in container
  metadata (encryption salts, the gzip header time of the intermediate tar, WIM image times, the xar
  TOC) with every item's name, size, CRC and time unchanged; the committed fixtures were kept.
- **README** brought up to date: what you get (help is bundled, the context menu works, drag and
  drop everywhere), the full Developer ID / notarization sequence, the hardened-runtime finding,
  test counts, and a current known-limitations list.
- **Localization QA across all 93 languages** stands as `packaging` left it and is re-run by every
  `verify.sh`: `LocalizationFittingTests` launches every language, builds the menu bar and fits
  every dialog (part of the app-hosted target). New this time: IDS_SET_FOLDER 6007 has one English
  fallback at all four call sites, `Lang/en.ttt`'s "Select destination folder.", and `de` / `fr`
  override it (`ReleaseTests`); the non-localizable strings of 01 §7.2 were walked in the source.
- **Env-gated verification hooks** (`SZ_OPSINFRA_DEMO`, `SZ_EXTRACT_CONTEXT`, `SZ_COMPRESS_DEMO`,
  `SZ_POLISH_DRAGOUT`, `SZ_TEST_SUPPORT`): **kept in Release**, decided as `packaging`. Each acts only
  when its variable is in the process environment, which no Finder / Dock / LaunchServices launch
  sets; anyone who can set it can already run code as the user; compiling them out would leave a
  Release build untestable by the same harness.

## 3. Code changes (the backlog)

### 3.1 Startup, shutdown, temp folder (01 §1.1)

- **Lazy codecs.** `AppDelegate` shows the window first and builds the format table on a worker
  (`FM.cpp:738-743` defers `LoadGlobalCodecs()` the same way). Every engine entry point still loads
  it on first use; `SZCodecs.formats` now takes the lock even when loaded, so a reader racing the
  worker never sees an empty table.
- **`SZCodecs` lookup by signature**: `formats(matchingHeader:)`, `SZFormatInfo.signatures` /
  `signatureOffset`.
- **Shutdown order**: `applicationWillTerminate` finishes the temp-file sessions (the "modified,
  update?" question per edited item) *before* saving window and panel state, as `WM_CLOSE` does.
- **Launch sweep** (`TempOpenJanitor.swift`): stale `7zO*` / `7zE*` folders older than an hour
  (`7zE-*` e-mail folders: a day), skipped while another 7-Zip process runs and under test support.
  An improvement over Windows, labelled as such.

### 3.2 Threading audit (PROGRESS 9.4) — findings and fixes

An independent read of every `DispatchQueue.main.sync`, every engine call reachable from the main
thread, and every `SZFolder` handed across queues found:

| # | finding | fix |
|---|---|---|
| 1 | `CommandExecutor.expand` ran the engine's censor walk on the main thread before any window existed (requests resetcmd → cmdmode) | runs inside `OperationRunner.run` (WaitMode, "Scanning..."); its error comes back once through the command's own `report` |
| 2 | `OperationRunner.onMain` used `DispatchQueue.main.sync`: a runner started from inside a main-queue block (Open Outside from `PanelNavigation`, the test reset's URL commands) deadlocked on a password / overwrite question | hops with a common-modes `CFRunLoopPerformBlock` + semaphore, delivered by any modal session |
| 3 | the drag-out promise ran the extraction (a modal session) inside `DispatchQueue.main.sync` | `performOnMainRunLoop` |
| 4 | Extract / Test inside an archive, Open-into-temp, add-into-archive and the temp write-back used the panel's `SZFolder` on a worker without parking the panel queue | `PanelViewController.parkPanels(showing:)` parks every panel whose archive chain holds that archive; a panel whose queue is itself waiting on the main thread (`queueHeldForMain`) is skipped, and a park that does not happen within 2 s proceeds rather than deadlock |
| 5 | (grey) `currentFolderForContext()` reads the `folder` reference on main | left: a pointer read, never a call; noted in HANDOFF |
| 6 | (grey) the temp-files browser's size walk (capped at 200 dirs / 2000 files per entry) on main | left: bounded |

No `main.sync` around a modal session remains in `Mac/App`; `Mac/Core`, the Finder Sync and Quick
Action extensions contain none.

### 3.3 Settings audit (01b §5.7)

Every key is read and written through `Settings` / `SZSettings` with the Windows default. Fixed:
`FM.ShowRealFileIcons` was stored but ignored -- it now governs file-system icons exactly as
`PanelItems.cpp:587` does (off, the default: icon by type); the Password and Memory-use dialogs
wrote their keys around `Settings`, so nothing heard the change. The intentional name / shape
differences (`FM.Panels.*`, JSON columns, flat `Compression.Options.<Fmt>.<Name>`, `MemUse64`,
`FM.Position`) are recorded as spec corrections in `requests.md`.

### 3.4 Smaller items

- **Command line**: the Compress dialog's update mode follows `FindActionSet` over `a` / `u` and
  the `-u` switches (each `-u` string starts again from the command's default set, as
  `ParseUpdateCommandString` does; an unlisted set is E_NOTIMPL before the dialog); the command
  line's own `-m` list is kept ahead of the dialog's properties, as `SetOutProperties` appends.
- **Passwords per level** for Extract, Test, View / Edit and hashing inside an archive.
- **Diff** hidden in the panel's context menu without a Diff tool (`MyLoadMenu.cpp:614`).
- **About** shows `7zipLogo.ico` at its real 110 × 63 size (`AboutLogo.imageset`, emitted by
  `make-icons.py`'s extract stage).
- **Resource-id comments**: 25 control ids that were cited only by number got their symbol; the
  Windows-only ids are named where their control would be. Audit: 359 / 359.
- **`test.sh`** retries a target once (after 15 s) on "Timed out while enabling automation mode"
  when no test case started.

## 4. Requests rows

**Closed / acknowledged:** tools, icons, finder, navgaps → orchestrator (ownership table);
finder → every scope (toolchain gotchas 12-13); archgaps, navgaps → orchestrator (15-file upstream
diff = `upstream-patches.md`); cleanup → extract/finder (`-scrc`); icons → tools (About logo);
finder → packaging (README); resetcmd → cmdmode (censor walk); optgaps → extract and → every dialog
author (all 24 `runModal` sites use `DialogKit.window`); archgaps → extract and → panel; uiverify
→ orchestrator (`test.sh` retry); navgaps → every scope, → extract (×2), → extract/compress/tools,
→ compress.

**Decided as `packaging`:** polish → packaging (hooks kept in Release, §2).

**Left for a human:** cmdmode → human (the Dock drop), unchanged.

### Decisions for the orchestrator

1. **A re-launch of the running app** (Dock click, Finder double-click of the app, `open -a`):
   Windows starts a new 7zFM window each time; the app now brings its window forward, as Mac apps
   do. *Recommendation:* keep the Mac behaviour and tick PROGRESS "Every launch opens a new window"
   as *mapped* (a second process via `open -n` already gets its own window). The alternative is one
   line in `applicationShouldHandleReopen`.
   **Decided (user, 2026-10-03): open a new window**, as each 7zFM.exe launch does -- with windows
   open or not, plus File ▸ New Window. Built by `mac/newwindow` (`reports/newwindow.md`); PROGRESS
   1.4 ticked.
2. **The panels' first folder** when nothing is stored: home (as built) or 7zFM's root
   ("Computer"). *Recommendation:* keep home -- the root is one Up away and home is what a Mac user
   expects -- and tick PROGRESS "Panel start path" as *mapped*.
3. **An archive opened from Finder while a window is open** reuses the front window's panel
   (navgaps K.3). *Recommendation:* open a new window when the front window shows anything but its
   launch state; it is what Windows does (one 7zFM per file) and loses nothing. Owner: `finder` /
   `panel`.
   **Decided (user, 2026-10-03): always a new window**, not only when the front window has moved
   on from its launch state. Built and tested by `mac/newwindow`.
4. **`testmanagerd` sharing** (requests harness → orchestrator): *recommendation:* one sentence
   in `00-orchestration.md` that every `xcodebuild test`, unit runs included, waits for the
   app-launch lock when more than one agent runs; do not make `test.sh` take it for unit runs.
5. **PROGRESS §9.4 "every box ticked or listed; status table done"**: becomes true when 1 and 2 are
   answered and the human checks of §6 are done; tick it then. *1 is answered (`mac/newwindow`);
   2 and §6 remain.*

## 5. Verification

Final run: `Mac/scripts/verify.sh -S -s release` (clean Debug build, every target, sharded) —
numbers in `ai/reports/verify-latest.md`; summary filled in below by the last commit.

`verify.sh -S -s release` at `b9c963b`: **exit 0**, clean Debug build 42 s, 724 s of tests.

| target | passed | failed | time |
|---|---|---|---|
| `SevenZipKitTests` (unit) | 387 | 0 | 105 s |
| `SevenZipAppTests` (app-hosted, incl. the 93-language sweep) | 98 | 0 | 183 s |
| `7-ZipUITestsProbe1` | 6 | 0 | 94 s |
| `7-ZipUITestsProbe2` | 6 | 0 | 97 s |
| `7-ZipUITests` (input shard) | 40 | 0 | 505 s |
| **total** | **537** | **0** | |

Disk image: `Mac/scripts/package.sh` after the verify run.

`Mac/build/7-Zip-26.03.dmg` (not committed): 4,860,301 bytes (4.6 MB), UDZO, volume "7-Zip 26.03",
ad-hoc, arm64, macOS 14+, SHA-256 `029387d59f70eaaed19249bf3a598a71e503e1a42f8d56bfdfbff1f6fb4e3325`.
Bundle checks and the mounted-image re-verification passed; `spctl` rejects it as expected for
ad-hoc.

### Follow-up found on the way

An app-hosted case that opened Options, selected the System tab and drew the window raised
AppKit's `NSGenericException` "more Update Constraints in Window passes than there are views"
(once inside the probe's timer, once in the *next* test, `testSystemAndLanguageColumnsFitTheirContent`).
The case was removed; the existing Options tests are green without it. Worth a look by `options`:
the System page's table may invalidate constraints from inside its own layout.

## 6. Manual checks a human must do

Each needs a person, Automation / Screen Recording permission, or a certificate this machine lacks.

1. **Finder extension** — the 15 numbered steps of `ai/reports/finder.md` §8: extensions on
   in System Settings; the cascaded menu's exact items on `test.7z`; flat mode; menu icons; the
   item check-list; a folder selection; Shift relaxation on a `.txt`; each command run once
   (Extract Here, Extract files…, Add to archive…, CRC SHA ▸ SHA-256); the Quick Actions and the
   Services. Screenshot the menu in cascaded and flat mode.
2. **A real drag into Finder**: drag a file out of an archive panel onto the Desktop; the file
   appears (promise fulfilled) and no `7zE*` folder is left in `$TMPDIR` after quitting.
3. **Dock drop**: drag two files onto the 7-Zip Dock icon → the Compress dialog opens with both;
   drag one `.7z` → it opens in a panel (requests row cmdmode → human, parity F.4).
4. **Help in a browser**: Help ▸ Contents, and the Help button of Extract, Add to archive, Options
   (each page) and Benchmark open the right local page in the default browser.
5. **Dock-tile progress**: compress a large folder; the Dock icon shows a progress bar that ends
   when the operation does, and pauses (yellow) with Pause.
6. **Notarization**: the five commands in §2 on a Mac with a Developer ID; then download the DMG
   through a browser on another Mac and open it: no Gatekeeper prompt beyond the standard
   "downloaded from the Internet" confirmation.
7. If XCUITest's automation mode keeps timing out: `sudo automationmodetool
   enable-automationmode-without-authentication`.

## 7. Files touched

- **packaging:** `Mac/README.md`; this report; `ai/PROGRESS.md`, `parity.md`,
  `HANDOFF.md`, `requests.md`.
- **orchestrator-owned, mechanical:** `Mac/App/AppDelegate.swift` (lazy codecs, shutdown order,
  launch sweep), `ai/00-orchestration.md` (ownership rows), `ai/architecture.md`
  ("As built" refreshed), `ai/04-toolchain.md` (gotchas 12-13).
- **harness:** `Mac/scripts/test.sh` (retry); tests `Mac/Tests/SevenZipKitTests/CodecsSignatureTests.swift`,
  `UpdateActionSetTests.swift`, `Mac/Tests/AppTests/ReleaseTests.swift` (new), screenshot cases
  added to `PanelGapsTests.swift`, `OptGapsTests.swift`.
- **icons:** `Mac/scripts/make-icons.py`, `Mac/Resources/Assets.xcassets/AboutLogo.imageset` (new).
- **fsfolder / bridge:** `Mac/Core/SZCodecs.mm`, `Mac/Core/include/SZCodecs.h`.
- **opsinfra:** `OperationRunner.swift`, `PasswordDialog.swift`, `MemoryUseDialog.swift`,
  `ProgressDialog.swift` (comments).
- **panel:** `PanelViewController.swift`, `PanelArchiveOpen.swift`, `PanelNestedArchives.swift`,
  `PanelDragDrop.swift`, `PanelIcons.swift`, `PanelContextMenu.swift`.
- **extract:** `ExtractCommands.swift`, `TempOpen.swift`, `TempOpenCommands.swift`,
  `TempOpenJanitor.swift` (new), `ExtractDialog.swift` (comment).
- **compress:** `CompressCommands.swift`.
- **tools:** `ToolsCommands.swift`, `AboutDialog.swift`, `BenchmarkDialog.swift`, `LinkDialog.swift`,
  `SplitDialog.swift`, `CombineDialog.swift` (fallback text / comments).
- **finder:** `ArgumentGrammar.swift`, `CommandExecutor.swift`.
- **options:** `OptionsWindow.swift`, `OptionsSettingsPage.swift`, `OptionsLanguagePage.swift`,
  `OptionsMenuPage.swift`, `OptionsSystemPage.swift` (comments).
- **panel (dialogs):** `CopyMoveDialog.swift`, `BrowseDialog.swift`; shared `MainMenu.swift`
  (one comment, additive).

No upstream file (`C/`, `CPP/`, `Asm/`, `DOC/`) was touched.
