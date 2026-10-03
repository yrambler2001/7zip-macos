# Parity: what a user gets today, compared with the Windows 7-Zip File Manager

First written by the `packaging` scope as the project's final audit (2026-09-20), refreshed by
**`mac/release` on 2026-10-03** so that every section describes the current branch. It is meant to
be read by someone deciding whether to use this app, not by someone defending it.

The specification is `Mac/docs/01-fm-feature-inventory.md` (cited as `01 §n`),
`Mac/docs/01b-fm-dialogs-settings.md` (`01b §n`) and
`Mac/docs/03-shell-integration-inventory.md` (`03 §n`). The per-scope reports in
`Mac/docs/reports/` say how each piece was verified. `Mac/docs/PROGRESS.md` is the item-by-item
checklist; this file is the summary a user needs.

## Where it stands (2026-10-03)

- **Checklist: 490 of 496.** The six open items are listed in section D with the reason for each:
  two product decisions (a re-launch opening a new window, the panels' first folder), one
  optional helper the locked design replaced, one check only a human can do (Finder's own menu),
  and two packaging bookkeeping items that follow from those.
- **Of the 14 "unfinished" gaps the first audit listed, none is left** (section D).
- **What is still partial** is small and listed in section B: right-to-left mirroring, a third of
  the translations being incomplete upstream, Finder opening a second archive into the front
  window, and a handful of details.
- **What nobody has verified** is in section E: Finder's own context menu, a real drag into Finder,
  a Dock drop, the Help pages in a browser, the Dock-tile progress, and the whole Developer ID /
  notarization path -- each needs a person, a permission or a certificate this machine does not
  have. The list a human should walk is in `Mac/docs/reports/release.md` §6.
- **Tests:** `Mac/scripts/verify.sh` (all targets: unit, app-hosted, three XCUITest shards) is the
  gate; its last result is in `Mac/docs/reports/verify-latest.md`.

**How the first audit was done.** A sample of 57 ticked checklist items was re-verified against the
source, biased towards the expensive and cross-scope ones; nine were untrue and were unticked with
the evidence written next to them in `PROGRESS.md`. The app was launched in all 93 bundled
languages and screenshotted in five (`Mac/docs/reports/packaging.md`). It is a source audit plus a
driven-app audit, not a hands-on review of every feature by a person.

---

## A. Complete — at parity

These behave as the Windows file manager does, to the level the inventory specifies.

**The window and the panels** (`01 §1.1-§1.5`, `01b §5.7`)
Dual panels in a split view with the F9 toggle, a per-panel address bar with its breadcrumb
drop-down and Up button, the window title following the focused panel, and frame, panel count,
paths, view mode and sort order all persisted under the Windows registry value names.

**Listing and browsing** (`01 §3.1-§3.9`)
All four view modes (large icons, small icons, list, details) with the selection preserved across
a switch; the per-folder-type column sets with the Windows default widths, header-click sorting,
header drag reordering and the header check-list menu, with names taken from lang id `1000 + kpid`;
`CompareItems2` reproduced exactly, including `..` first, folders first except in No Sort, and the
five properties that start descending; flat view with its Prefix column; folder history (Alt+F12,
Del removes) and ten Alt-digit favorites with the 100-character path shortening; mask select and
deselect, select by type, all/none/invert, and the AlternativeSelection mode with its pink rows;
the whole keyboard map of `01 §3.7` with the documented Cmd and Space substitutions; binding into
nested archives with `kStartExtensions`, the virus-name confirmation and the `kMaxOpenItems 20`
cap.

**File operations** (`01 §3.10, §3.11`, `01b §4.5`)
Copy and Move (F5/F6) through the real Copy dialog with its info block and path history, including
rename-on-copy and all four directions (disk→disk, archive→disk, disk→archive, and archive→archive
through a `7zE` temp directory); delete, rename in place, create folder, create file, edit the ZIP
comment, calculate size, and Properties with the per-archive-level `kSpecProps`.

**Extract** (`01b §4.25`, `01 §8.3`)
`IDD_EXTRACT 3400` with every control and the exact `NExtract::CInfo` save rules. The extraction
itself is the engine's own `Extract()`, so path modes, `-spe`, the `*`-per-archive substitution,
the open-error texts and the test summary are literally the Windows product's behaviour.

**Add to archive** (`01b §4.23, §4.24`, `01 §8.5`)
`IDD_COMPRESS 4000` with the full Windows cascade — format, level, method, dictionary, word size,
solid block size, threads, memory use — and the Options sheet `14001` with its tri-state timestamp
boxes. `-m` parameters are generated in upstream order. Update modes, path modes, encryption
including encrypted headers, multi-volume sets, self-extracting archives with a byte-identical stub
prefix, delete-after-compress, and compress-and-email all work.

**The other tools** (`01 §3.13, §3.14`, `01b §4.20, §4.26, §4.27, §4.10, §4.1, §4.3`)
CRC/checksum with all eleven hash methods, hashing archive members without extracting them, the
results list with upstream wording, and `.sha256` write and verify; the complete Benchmark dialog
including Current/Resulting rows for both directions, Total Rating, the CPU/OS statics and the log
with its frequency lines; Split, Combine, Link, About and the temporary-files browser.

**Progress, overwrite, password** (`01b §4.12, §4.14-§4.17`, `01 §8.7`)
Progress with pause, background and cancel-with-confirmation, the overwrite prompt with all its
answers, the password prompt, the messages list, the memory-use prompt, and "keep the window open
when there were messages".

**Opening files inside an archive** (`01 §3.9`)
In-memory or `7zO` temp extraction, launching the external application, watching the file, and the
"was modified, update it in the archive?" write-back.

**Options and settings** (`01b §4.7-§4.9, §4.13, §4.19, §4.21, §4.22, §5`)
All six Windows pages plus an informational Plugins page, and the whole `01b §5` settings surface
written under the Windows key names in `UserDefaults`, shared with the engine.

**Localization** (`01 §7.1, §7.2`)
All 93 official language files bundled and readable by the upstream positional parser, every menu,
dialog, column, property, status and message string resolved by 7-Zip lang id, English fallback
for anything a translation omits, and live language switching. Verified by launching the app in
every one of the 93 — see `Mac/docs/reports/packaging.md`.

**Finder integration** (`03 §1, §3, §6`)
A Finder Sync extension that reproduces `QueryContextMenu` item for item — cascaded or flat, with
icons, the `ContextMenu` bit mask, the exclude list with its Shift relaxation, and
`GetSubFolderNameForExtract` / `CreateArchiveName`; two Quick Actions; five Services; 40 file
associations with 27 document icons and their UTIs; and association switching from Options ▸ System.

**The 7zG command grammar** (`03 §2`)
The full `CArcCmdLineParser` switch set, `#map` refusals with the upstream strings, list-file
transport, `-thash`, `-seml`, and command dispatch.

**Since then** (`mac/navgaps`, `mac/release`): the panel's archive open with its "Opening"
progress and per-level passwords, Windows toolbar bitmaps and the four-part status bar, lazy codec
loading, the launch-time temp sweep, the command-line update mode from `-u`, and the About box's
own wordmark. Sections K and L.

---

## B. Partial — it works, with a limitation worth knowing

Current list. The first audit's 24 items are accounted for at the end of this section.

1. **Opening several archives from Finder**: the first reuses the front window's panel, only the
   rest get windows of their own; Windows starts one 7zFM per file. A file opened into a window
   that already shows something keeps that window and reports a failure as a sheet (`03 §6.2`,
   K.3). Decision for the orchestrator (`reports/release.md`).
2. **Right-to-left languages are not mirrored**: AppKit mirrors only an app that declares an RTL
   localization, and this one carries none; composite strings do come out in the right order
   (I.5). Six of the 92 translations are RTL.
3. **A third of the translations are substantially incomplete upstream** — 24 of 92 miss more than
   a quarter of the strings the app asks for, and those fall back to English; 28 are complete.
   Table in `Mac/docs/reports/packaging.md`.
4. **The messages list** of the Progress window uses fixed column widths (`01b §4.17`).
5. **The panels' first folder** when nothing is stored is the home folder, not 7zFM's root
   ("Computer", one Up away) (`01 §1.4`). Deliberate in `mac/panel`; a decision is asked for.
6. **A re-launch of the running app** (Dock, Finder, `open -a`) brings its window to the front, as
   every Mac app does, instead of opening a new window as a new 7zFM process would (`01 §1.1`).
   A second process (`open -n`) does get its own window. Decision asked for.
7. **Cancel during a command-line wildcard scan** (`7zG a … *.txt -r` from the Finder extension or
   a `sevenzip://` URL) takes effect when the engine's directory walk returns: the walk has no
   break check. The window and the Cancel button are there; the app no longer hangs during it.
8. **Drag between two separate 7-Zip processes** (`open -n`) goes through file promises, i.e. a
   temp folder, instead of the source extracting straight into the target; within one process
   (any number of windows) the direct path is used (`01 §3.15`).

**The first audit's B items, by number:** 1-5 closed by `mac/panelgaps` (G.1-G.3; Diff's
no-tool hiding now also in the panel's context menu, `mac/release`); 6 → H.1; 7 → F.2 and H.5;
8 → H.2; 9 → F.1; 10 → F.3 and I.6; 11 → J.1 (NT security stays hidden by design); 12 → H.3
(Dock tile; the column widths are item 4 above); 13, 14 → I.1, I.2; 15, 17 → `mac/polish` and
I.3, I.4; 16 → `mac/polish` (the splitter ratio is authoritative and never derived during
layout); 18 → item 1 above; 19 → **not a gap**: Windows' shell extension itself reads only the
`Options.*` context-menu values (`ContextMenu.cpp:632-640`), which do reach the extensions;
`Compression.*` and `Extraction.*` are read by the app that runs each command (L.3); 20-22 → K.4;
23 → I.5 plus item 2 above; 24 → item 3 above.

---

## C. Deliberately different on macOS

None of these is a gap; each is the Mac equivalent of something Windows-specific, and each was
decided up front (`00-orchestration.md`, `01 §9`, `03 §6`).

| Windows | macOS | Why |
|---|---|---|
| Explorer shell DLL (`IContextMenu`), drop handler, right-drag menu (`03 §1.1, §1.7`) | Finder Sync extension, Services, Quick Actions; Control-drag menu | macOS has no COM shell extensions, and Finder has no right-drag menu |
| `7zG.exe` as a second process (`01 §9 #1`) | one process; `argv[1] ∈ {a,u,d,x,e,t,h,b}` puts the app into command mode with a real exit code | one binary, no helper bundle |
| `#7zMap` shared-memory selection transport (`03 §1.5`) | `-aiw-!<path>` / `-aiw-@<listfile>` and a `sevenzip://` URL | no shared sections between a sandboxed appex and the app |
| Recycle Bin (`01 §9 #9`) | `NSFileManager.trashItem`; Shift+Cmd+Backspace deletes permanently | — |
| Registry `HKCU\Software\7-Zip` (`01b §5`) | `UserDefaults` with the same value names; the column layout as JSON | — |
| `Zone.Identifier` alternate stream, `-snz` (`01 §9 #23`) | `com.apple.quarantine` with the same none/all/office policy | — |
| OLE `IDataObject` / `CF_HDROP` (`01 §3.15`) | `NSDraggingSource` plus `NSFilePromiseProvider` and a private pasteboard type | — |
| `SetPriorityClass(IDLE)` for Background (`01 §9 #16`) | `setpriority(PRIO_DARWIN_BG)` on the worker thread | — |
| Shell "System" submenu and property sheet (`01 §2.8, §9 #10`) | Open With ▸, Show in Finder, Quick Look, Get Info — and the port's own Properties dialog | — |
| NTFS alternate data streams, NT security descriptors (`01 §9 #6, #7`) | hidden; POSIX mode, owner, group and `readlink` target shown instead | no equivalent, and inventing one would mislead |
| Junction and WSL link types (`01b §4.10`) | hard links and symbolic links only | — |
| ProgIDs, `DefaultIcon`, an "All users" column (`03 §3.3, §3.4`) | `CFBundleDocumentTypes` plus imported UTIs and `setDefaultApplication`, current user only | macOS has no HKLM equivalent |
| MAPI `MAPISendMail` (`03 §2.5`) | `NSSharingService.composeEmail`; the temp archive is purged later, not synchronously | no "sent" callback to delete on |
| `CBrowseDialog` / `SHBrowseForFolder` (`01b §4.2`) | `NSOpenPanel` / `NSSavePanel` | — |
| Ctrl accelerators and the Insert key (`01 §3.7`) | Cmd accelerators; Space selects and calculates size; Cmd+[ / Cmd+] added for Back/Forward | Apple keyboards have no Insert key |
| Accelerator text re-appended after translation (`01 §7.2`) | mnemonics and accelerator text stripped; macOS draws key equivalents itself | — |
| Language applied on OK (`01b §4.9`) | applied live as you pick it; Cancel restores | — |
| External `7z.dll` and `Codecs\*.dll` (`01 §6.8`) | the engine is statically linked; the Plugins page is informational | — |
| Drive letters, `\\.\` physical-drive imaging, Network root (`01 §6.2, §6.3, §6.6`) | Computer = mounted volumes plus Documents; imaging and Network dropped | — |
| Win32 controls, dialog units, the `IDD_*_2` small-screen templates (`01 §9 #14, #33`) | AppKit views; always the full menus and full-size dialogs | — |
| `DeleteOldTempFiles` never called (`01 §1.1`, `§9 #11`) | stale `7zO*` / `7zE*` folders swept at launch, conservatively (L.1) | an improvement, documented as such |
| One 7zFM process per window | one process, any number of windows; a re-launch activates it | macOS application model (B 6) |
| Back / Forward | View ▸ Back / Forward (Cmd+[ / Cmd+]) over the panel's folder history | an addition; 7zFM has no navigation stack |
| `FM\NumPanels`, `CurrentPanel`, `SplitterPos`, the `Columns` blob, `Compression\Options\<fmt>` sub-keys | `FM.Panels.*` (the splitter as a ratio), `FM.Columns.<ID>` as JSON, flat `Compression.Options.<Fmt>.<Name>` keys, `MemUse64` | `UserDefaults` value types; recorded as spec corrections in `requests.md` |

---

## D. Missing

**Windows-only by nature — consciously dropped, nothing to build.**
Alternate data streams and their folder and menu item; NT security descriptors; drive letters,
`\\.\` imaging, NetFolder and the "Network" root; the long-path Recycle Bin message; registry
persistence; the COM shell DLL, its Approved-list registration and `IExplorerCommand`; the
16-item context-menu reduction; drop-handler mode; `ITaskbarList3` taskbar progress (mapped to the
Dock tile); large memory pages (`-slp`); HtmlHelp `.chm` (mapped to the bundled HTML pages);
`Benchmark 2`; every `IDD_*_2` small-screen dialog; the 32-bit memory and dictionary caps;
`Set_Wow64` / `OleInitialize`; and the Explorer verb names.

**Unfinished.** All 14 items of the first audit are closed: 1, 5, 6, 9 by `mac/panelgaps` (G);
2, 3, 4, 8 by `mac/opsgaps` (H) with `mac/cmdmode` (F); 7, 13 by `mac/archgaps` (J); 10, 11, 14
by `mac/cmdmode` (F) and `mac/optgaps` (I); 12 by `mac/optgaps` (I).

**The six checklist items still open, and why** (`PROGRESS.md`):

| Item | Why it is open |
|---|---|
| scaffold: every launch opens a new window (`01 §1.1`) | product decision: B 6 |
| scaffold: panel start path falls back to the root (`01 §1.4`) | product decision: B 5 |
| finder: optional `Contents/Helpers/7zG.app` (`03 §6.4`) | by design: the locked decision runs 7zG commands in process |
| finder: Finder context menu verified in Finder (`03 §6.3`) | needs a human (no Automation permission here): `reports/finder.md` |
| packaging: every box ticked or listed as a known gap | follows from the four above, each listed here and in `reports/release.md` |
| packaging: screenshots for every scope; `architecture.md` current | `architecture.md` "As built" refreshed by `mac/release` (orchestrator-owned, so the orchestrator ticks it); `release-*` and `panelgaps-*` screenshots added; `optgaps` has none of its own -- an Options ▸ System screenshot case re-entered AppKit's constraint pass in the hosted test run and was dropped (its pages appear in `options-*` / `packaging-*`) |

---

## E. Verification debts

Honest about what nobody has checked rather than what nobody has built. Each needs a person, a
permission or a certificate; the step-by-step list is `Mac/docs/reports/release.md` §6.

* **Finder's context menu has never been opened in Finder.** The extension builds, signs,
  sandboxes and registers, and its menu model is unit-tested item for item, but the machine has no
  Automation permission. `Mac/docs/reports/finder.md` lists 15 numbered checks.
* **A real drag from a panel into Finder** (file promises written by Finder) and **a drop onto the
  Dock icon**: both are unit- and app-hosted-tested up to the AppKit boundary; XCUITest cannot drag
  to another app or to the Dock.
* **Help in a browser and the Dock-tile progress** are verified through in-process hooks
  (`Help.opener`, `ProgressDockTile`), not by looking at the browser or the Dock.
* **Only ad-hoc signing has ever been exercised.** There is no Developer ID on this machine
  (`security find-identity -v -p codesigning` → "0 valid identities found"), so the Developer ID
  and notarization paths of `Mac/scripts/package.sh` are written and guarded but never run end to
  end. The exact commands are in `Mac/README.md` and `reports/release.md`.
* **Cleared on 2026-10-03:** `fetch-assets.sh` and `make-fixtures.sh` were re-run (assets
  byte-identical; fixtures identical in content), `architecture.md`'s "As built" is current, and
  the control-id comment audit finds all 359 symbols.

---


## History of updates

**Update, 2026-09-20 (`mac/cmdmode`).** Four of the unfinished items below are closed and are
annotated in place; nothing was renumbered and no evidence was deleted. Section F lists them with
what was measured before the fix and what is left. The checklist therefore reads **390 of 496**.

**Update, 2026-10-03 (`mac/opsgaps`).** D items 2, 3, 4 and 8 are closed (B items 6, 8 and 12's
Dock half with them); section H says how. Five checklist boxes were ticked.

**Update, 2026-10-03 (`mac/optgaps`).** D items 11 and 12 are closed, and B items 13, 14, 15, 17 and 23;
section I says how. Three checklist boxes were ticked.

**Update, 2026-10-03 (`mac/archgaps`).** D items 7 and 13 are closed (B item 11's raw half with
them), and two crashes / blank listings found on the way are fixed; section J says how.

**Update, 2026-10-03 (`mac/panelgaps`).** Items 1, 5 and 6 below are closed and item 9 mostly;
each is annotated in place and section G says how. Four panel-section boxes were ticked; the
checklist now reads **403 of 496** (the other nine came from branches merged since the audit).

**Update, 2026-10-03 (`mac/navgaps`).** B items 20, 21 and 22 (Ver\*) are closed, and the open
behaviour of a panel now matches 7zFM: the "Opening" progress, the per-level open text, passwords per
archive level, the command-line open's "Error" box; section K says how. The checklist reads
**467 of 496**.

---

## F. Closed after the audit — 2026-09-20, `mac/cmdmode`

Four items of section D, each measured against the source before it was touched. **All four
diagnoses held up exactly as written**; nothing in this batch turned out to be already working or
misdiagnosed. What the measurement added was detail, not correction.

### F.1 — D item 10, command mode (`03 §2.2, §2.7`)

Measured: `SevenZipExitCode.memoryError` had no reference outside one assertion in
`FinderCommandTests`; `CommandExecutor` had five hand-written `case .failure: return .fatalError`
arms and no message mapping; `runUpdateGroup` answered `rn` with "Unsupported command" + exit 2; and
`SevenZipArguments.resolve` returned `-i!` / `-x!` names verbatim, so a pattern reached
`AddPreItem_NoWildcard` and matched nothing.

Done:

* **`SevenZipFailureLadder`** — `WinMain`'s catch chain (`GUI.cpp:437-494`) as a pure classifier, and
  every failure site in `CommandExecutor` now routes through it. Exit 8 is reachable because
  `CNewException` **is** `std::bad_alloc` here (`Common/NewHandler.h:99-102`) and the bridge maps it to
  `E_OUTOFMEMORY` → `SZError.Code.outOfMemory`. The bridge's two divergent spellings are normalised
  back: `"Internal Error #N"` → `"Error: N"`, empty → `"Unknown error"`. A `CMessagePathException`,
  which derives from `UString` and would otherwise flatten into exit 2, is flagged by the bridge with
  `SZPathExceptionUserInfoKey` and lands on the exit 7 arm as upstream.
* **`rn`** — old/new pairs from the positional strings and from a `@listfile` among them, with
  upstream's three refusals (odd count, wildcard in an old name, no pair at all), and
  `SZUpdater.renameItems` filling `CUpdateOptions::RenamePairs`.
* **Include and exclude wildcards** — `SZPathSpec` carries one censor entry per resolved name with
  its `r`/`w`/`m` modifiers; `SZUpdater.expandPathSpecs` is the engine's own
  `EnumerateDirItemsAndSort` (archive list) or `EnumerateItems` (item censor); the update, delete and
  rename paths hand the specs straight to `UpdateArchive`, which is what keeps `-ir!src/*.c` storing
  `sub/x.c`. A censor with no wildcard and no exclude entry — every Finder selection, which uses
  `-aiw-!` — takes the literal path and touches no disk, so nothing that worked before changed.

### F.2 — D item 4, checksums while extracting and testing, command half (`03 §2.6`)

Measured: exactly as filed. `command.hashMethods` was read in one place only, `runHash`;
`SZExtractOptions.hashMethods` and `SZExtractResult.hashResults` existed and no caller set them.

Done: `x -scrc<M>` and `t -scrc<M>` set the methods (bare `-scrc` = CRC32, an unsupported method is
exit 2) and show the digests in `HashResultsDialog` instead of the test summary, which is
`ExtractGUI.cpp:129-152`. Cross-checked against `7zz t -scrcSHA256`. **The panel's Test button still
does not pass `-thash`** — that file is another scope's, and the recipe is filed in `requests.md`.

### F.3 — D item 11, the self-extracting module switch, bridge half (`01b §4.23`)

Measured: exactly as filed. `-sfx<module>` reached `SevenZipCommandLine.sfxModule` and was then used
only as a Bool (`input.sfxMode = command.sfxModule != nil`) for the dialog; in the no-dialog branch
`result.sfxMode` was never set at all, so `a -sfx x.exe f` wrote a plain 7z with an `.exe` name.

Done: `SZUpdater.resolvedSFXModulePath` is `Update.cpp:1167-1191` plus a stub sanity check (regular
file, ≥ 1 KiB, `MZ` or a Mach-O / universal magic); `formatSupportsSFX` is `kFF_SFX`, i.e. 7z only;
`CommandExecutor` resolves and validates before any dialog and sets `sfxMode` with or without `-ad`.
A missing module, a bogus module and a non-7z `-t` are all errors with **nothing written** — verified
by running the built app and checking that no output file exists. A named module is honoured byte for
byte (`7zCon.sfx` is the prefix of the produced `.exe`, and `7zz l` reads the payload). The Compress
dialog's per-format Browse filter is a different item and is still open.

### F.4 — D item 14, dropping onto the Dock icon (`03 §6.2`, `03 §1.7`)

Measured: exactly as filed. `application(_:open:)` sent every file URL to
`URLCommands.openDocuments` → `CommandExecutor.openInFileManager`.

Done: the request's **source** is classified first. macOS gives no callback for "dropped on the Dock
icon", so `DockDropDetector` resolves the current Apple event's address attribute to a pid and then a
bundle identifier; `com.apple.dock` means a Dock drop, and anything else — a missing attribute
included — stays an ordinary open. `DockDropRouter` then opens a single recognised archive (Block A's
own condition plus `SZCodecs.format(forArchiveName:)`, so a dropped `notes.txt` is not opened into an
empty panel) and runs `FinderMenuModel`'s `SevenZipCompress` verb for everything else, which is
literally the argv Finder's own menu builds. `Mac/App/Info.plist` claims `public.item` +
`public.folder` with `CFBundleTypeRole: Viewer` and `LSHandlerRank: None`, because the Dock accepts a
drop only for types the app claims and rank `None` keeps the claim out of "Open With".

**Verification debt.** No test on this machine can perform a real Dock drop: Automation permission is
not granted, XCUITest cannot drag to the Dock, and `LSHandlerRank: None` granting the drop is
documented behaviour that has not been observed here. The routing, the argv, the sender detection and
the plist are unit-tested; a human still owes one check — drag two files onto the Dock icon and
confirm the Compress dialog opens, then drag one `.7z` and confirm it opens in a panel.

**And a second one, measured this time: command mode is not reachable from XCUITest at all.**
`XCUIApplication.launch()` with a command word fails after ~69 s either with "has not loaded
accessibility" (the command finished and the process exited before the runner could attach) or the
same way because the app is inside `NSApp.runModal` while still handling
`applicationDidFinishLaunching` and therefore never becomes idle. Both were observed in a real run.
Exit codes are verified by running the built binary from a shell instead — 25 cases in
`Mac/docs/reports/cmdmode.md` section 4.2 — and the two dialogs command mode may show are
screenshotted through the file manager, where the same code builds them.

---

## G. Closed by `mac/panelgaps` — 2026-10-03

Report: `Mac/docs/reports/panelgaps.md`. Tests: `Mac/Tests/AppTests/PanelGapsTests.swift` (app-hosted).

### G.1 — D item 1, the context menu's 7-Zip verbs (`01 §2.8-§2.9`)

Before: every verb was drawn grayed, because `PanelContextCommands` had no implementer.
Now `MainWindowController` implements all of them (`Mac/App/Commands/PanelContextActions.swift`) by
calling the File-menu / toolbar commands (`ExtractCommands`, `CompressCommands`), Open archive binds
the panel, and the CRC submenu also has C12 `SHA-256 -> x.sha256` and C13 `Test archive : Checksum`
(the Finder command lines, run through `CommandExecutor`) — which is also the panel half of D item 4's
`t -thash`. Shown-or-not follows ContextMenu.cpp: needExtract, Shift = extended verbs,
`Extract to "*/"` for several archives, the "Compress to … and email" twins. Left: the panel menu
still has its own builder instead of `FinderMenuModel`.

### G.2 — D item 5, Open Outside in an archive and Diff across panels (`01 §3.8, §3.11`)

Open Outside (and Enter on a non-archive member) extracts the item to a `7zO` folder and opens it,
through `ItemOpenCommands.openOutside(context:)`. IDM_DIFF with one item selected in each panel is
`CApp::DiffFiles`: the other panel's selected item, else the same relative path there; a non-FS panel
is 6008.

### G.3 — D item 6, drag and drop in the icon modes, and the background drop (`01 §3.15`)

Large Icons / Small Icons / List drag out (file URLs, archive promises) and accept drops (folder item
or the panel's folder) through the Details view's own code. A drop on the window background now
compresses the dropped files instead of the selection (`AreThereNamesFromTemp` kept).

### G.4 — D item 9, File-menu rules (`01 §2.1`)

Split / Combine only for one FS file, Link only for one item, Diff hidden without a Diff tool and
disabled in a hash folder, on top of the panel's existing read-only / hash rules. Not done: Ver*
(7vc) items, the small-screen "drop disabled items" variant.

---

## H. Closed by `mac/opsgaps` — 2026-10-03

Report: `Mac/docs/reports/opsgaps.md`. Tests: `Mac/Tests/AppTests/OpsGapsTests.swift` (app-hosted) and
`Mac/Tests/SevenZipKitTests/QuarantineExtractTests.swift`.

### H.1 — D item 2, bundled help (`01 §2.6, §9 #17`)

`fetch-assets.sh` now also verifies `7-zip.chm` inside the pinned installer (its own SHA-256) and
unpacks its 78 `.htm` / `.css` pages into `Mac/Resources/Help/`, which is committed and copied into
the bundle as a folder. `Help.show(topic:)` opens the page for any Windows `kHelpTopic` (case-blind,
as HtmlHelp is) in the default browser, anchor kept. Every Help button now uses it: Options (each
page's own topic — it used to beep), Extract, Compress, Compress Options, Benchmark, About, the temp
browser, and Help ▸ Contents. A browser rather than an Apple Help Book: no `.help` bundle, no
`hiutil` index, no Help Viewer registration cache to go stale for ad-hoc signed and renamed copies.

### H.2 — D item 3, quarantine on extraction (`01 §9 #23`)

The engine already had the whole Windows mechanism behind `#ifdef _WIN32`; a guarded upstream patch
(`Mac/docs/upstream-patches.md`) enables it on `__APPLE__` with the zone bytes read from and written
to `com.apple.quarantine`. So `-snz`, the Options setting (None / All / Office files only, upstream's
own extension list), Finder's extract verbs, the File-menu Extract commands, F5 out of an archive
(`CPanel::CopyTo` reads the setting) and Extract inside an archive all propagate it; drag-out and
temp-open keep their own rules, as on Windows.

### H.3 — B item 12 / D item 8, Dock-tile progress (`01b §4.17`)

`ProgressDockTile` draws the icon with a bar for every operation that shows a Progress dialog,
combined across several, yellow when all are paused and red once errors were shown (TBPFLAG), and
removes it on finish, failure or cancel. The runner also no longer returns from an externally
cancelled run before its worker has stopped.

### H.4 — D item 8, the failure text (`01 §8.7`)

`OperationRunner` shows `CProgressThreadVirt::Process`' text: lang 3000 for out-of-memory, "Error #N"
and "Error" for the two catch arms, silence for `E_ABORT`; `SZExtractor` gives E_OUTOFMEMORY the same
3000 text. Per-item texts (CRC failed, data error, unsupported method, unexpected end, wrong
password, cannot open as archive) were already the lang-file strings.

### H.5 — D item 4, `t -thash` from the Test button (`03 §2.6`)

When every operated item is a checksum file, Test runs the same `t -thash` command line as the
context menu's C13 and Finder. No `-scrc` control was added to the panel's Test: 7zFM has none.

---

## I. Closed by `mac/optgaps` — 2026-10-03

Report: `Mac/docs/reports/optgaps.md`. Tests: `Mac/Tests/AppTests/OptGapsTests.swift` (app-hosted).

### I.1 — D item 12 / B 13, Options ▸ System (`01b §4.21`)

The rows draw 7-Zip's own document icons (`doc-<name>.icns`). A plain click on the state column
toggles that row (NM_CLICK) and Return toggles the selection (NM_RETURN). After Apply has been
answered the bundle is re-registered with Launch Services (the SHCNE_ASSOCCHANGED step). Columns are
sized to their content.

### I.2 — D item 12 / B 14, Options ▸ Language (`01b §4.9`)

`SZLang` now computes LangPage.cpp's merge walk per file: comments, the missing and the extra ids as
`<id> : <text>`. IDT_LANG_INFO shows them as Windows does (50 per list) in a scrolling text view, and a
file that does not load is named in one "Error in Lang file" box.

### I.3 — the Options window's width (`01b §4.22`)

Wrapping labels asked for their one-line width (up to 1018 pt). They are capped and re-measured at
their real width; the widest page now needs 576 pt in a 660 × 580 window, in English, German, Russian,
Japanese, Arabic, Hebrew, French and Ukrainian.

### I.4 — dialog placement

`NSApp.runModal(for:)` re-centres a window on the screen when it shows it, which undid the placement
of every dialog except Copy / Move / Create Folder. `DialogWindow.center()` now centres on the owner:
the parent, else the key or main window; the screen only when no window is up.

### I.5 — B 23, right-to-left composite strings

The status line's parts and the Copy dialog's "label: value" lines are bidi-isolated in a
left-to-right label, so Arabic and Hebrew keep their order. The app is still not mirrored.

### I.6 — D item 11, the Compress Browse filter (`01b §4.23`)

One filter per listed format (without `k_DontSave_Exts`), the "Archive:" aggregate and All Files, or
only `exe` in SFX mode, as a "Save as type" pop-up; the chosen format's extension is appended and the
format combo follows. A `-sfx<module>` now travels through the dialog's input and result.

---

## J. Closed by `mac/archgaps` — 2026-10-03

Details, measurements and the test names are in `Mac/docs/reports/archgaps.md`.

### J.1 — D item 7 / B item 11, raw properties (`01 §3.2, §3.11`)

`SZFolder` bridges `IArchiveGetRawProps`: the raw properties follow the folder's own columns (as
`CPanel::InitColumns` appends them), render as `PanelListNotify.cpp` does (reparse data decoded,
`data:<n>` beyond 64 bytes, upper-case hex only for a CRC / checksum of at most 8 bytes), sort as
`CompareItems2` does (empty first, then the handler's raw order), and appear in Properties with the
`PanelMenu.cpp` form (256-byte limit). WIM shows SHA-1 and reparse data, XAR its checksum, the
file-system image handlers their raw fields. `kpidNtSecure` is never listed (locked decision).
Two defects surfaced while testing it and are fixed: every **tree-handler archive (WIM, XAR, HFS,
APFS, NTFS, Ext, FAT) listed blank names** -- an upstream use-after-free in `CProxyArc2::Load` that
macOS's zero-on-free exposes, patched under `#ifdef __APPLE__` (`upstream-patches.md`) -- and the
**Properties dialog read `CArchiveLink::Arcs[-1]`** for every archive (`GetArcProp2` at level 0)
and crashed on WIM.

### J.2 — D item 13, nested-archive write-back (`01 §3.8`)

Leaving a nested archive that was opened from a `7zO` temp copy -- going up out of its root, binding
another path, opening the drives list, closing the window, quitting -- compares the copy with what
was recorded at open, asks IDS_WANT_UPDATE_MODIFIED_FILE 3009, and on Yes replaces the item in the
parent with `CopyFromFile` under the progress dialog; levels unwind innermost first. A pending edit
of a file inside the nested archive is offered first. No / Cancel discard the copy; a failed,
cancelled or read-only write-back shows IDS_CANNOT_UPDATE_FILE 3010 with the copy's path and keeps
the copy; the parent is rewritten through a temp file and is never touched on failure (byte-for-byte
in the tests). Cancel in that progress dialog now works (`CopyFromFile` had no update callback).
Difference from Windows: binding a path *inside* the same nested archive closes and reopens the
chain (one question) instead of reusing it.

---

## K. Closed by `mac/navgaps` — 2026-10-03

`Mac/docs/reports/navgaps.md` has the detail and the tests.

### K.1 — opening an archive in a panel (`01 §6.7`, PROGRESS 153, 155)

An archive open now runs under 7zFM's "Opening" progress: nothing for 500 ms, then a window named
"Opening <archive>" with the files / bytes the handler reports and Cancel, which stops the open
silently. A failed open says what OpenAsArc_Msg says -- "Cannot open encrypted archive '...'. Wrong
password?" for a wrong password, the error text for a real error, and **nothing** for a file that
simply is not an archive (Enter then starts it, Open Inside does nothing, the address bar shows its
folder). An archive one of whose levels cannot be opened (a split set of a broken 7z) is entered and
the level's text is shown. Warnings of a level that did open are, as in 7zFM, not shown on entering.

### K.2 — passwords per archive level (`01 §8.7`, `01b §4.16`, PROGRESS 168)

Each archive level keeps its own password; an archive never inherits another's. Moving inside the
same archive does not ask again.

### K.3 — the command-line open (`01 §1.1`, PROGRESS 78)

`7-Zip <file>` that cannot open the file shows "Cannot open file '<path>' as archive" plus the
level text and closes the window (the app ends with it, as 7zFM does); a path that does not exist
shows its nearest folder. A file opened from Finder into an already open window shows the box as a
sheet and keeps the window.

### K.4 — B 20, 21, 22: toolbar, status bar, Ver\*

The toolbar draws 7-Zip's own bitmaps, 48x36 with "Large Buttons", 24x24 without, and disappears
when both toolbars are off; the splitter is 4 pt. Each panel's status bar has 7zFM's four parts at
220 / 320 / 420. Ver Edit / Commit / Revert / Diff appear under 7zFM's rule (Diff tool and `FM.7vc`
set, one file selected) and work; "read-only" is the owner's write permission.

### K.5 — smaller items

Masks, the copy-onto-itself checks and name lookups follow the volume's case sensitivity (PROGRESS
140). "Use for removable drives only" in Options > Folders is honoured (a guarded `WorkDir.cpp`
hunk, PROGRESS 169). Temp folders are `7zO<8 hex>` (PROGRESS 69). Auto Refresh starts on in every
launch, as 7zFM never saves it (PROGRESS 642). Raw-property columns (SHA-1, checksums) start wide
enough for their hex.

---

## L. Closed by `mac/release` — 2026-10-03

`Mac/docs/reports/release.md` has the detail; each line names its test.

### L.1 — startup, shutdown and the temp folder (`01 §1.1`)

The window appears before the format table is built (the codecs load on a worker, as 7zFM loads
them "at first use"); quitting first offers every edited temp file back to its archive and only
then saves the window and panel state; and a launch removes `7zO*` / `7zE*` folders an earlier run
left behind -- older than an hour (a day for e-mail folders), never while another 7-Zip process
runs. Windows leaves them for ever (`DeleteOldTempFiles` has no caller): an improvement, not parity.

### L.2 — threading

A password or overwrite question asked from an operation that was started inside a main-queue block
(Open Outside, a drag-out promise, a command URL) could hang the app; it cannot now. A wildcard
command line no longer freezes the app while it scans. A command that works on an archive folder
parks the panels showing that archive, so one engine folder is never used from two threads.
Extract, Test, View / Edit and hashing inside an archive reuse, and remember, the password of the
level they work on.

### L.3 — smaller items

`-u` switches select the Compress dialog's update mode as 7zG does, and the command line's own `-m`
values are kept; "Show real file icons" works (off, the Windows default, file-system items get
their icon by type); Diff is hidden in the panel's context menu without a Diff tool; the About box
shows 7-Zip's own wordmark; one English fallback for IDS_SET_FOLDER; lookup of a format by
signature in the bridge; and every symbolic resource id of the inventories is cited in the code.

