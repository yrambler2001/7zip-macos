# Parity: what a user gets today, compared with the Windows 7-Zip File Manager

Written by the `packaging` scope as the project's final audit, 2026-09-20, against branch
`mac/packaging` (off `macos` at `dea739c`). It is meant to be read by someone deciding whether to
use this app, not by someone defending it.

The specification is `Mac/docs/01-fm-feature-inventory.md` (cited as `01 §n`),
`Mac/docs/01b-fm-dialogs-settings.md` (`01b §n`) and
`Mac/docs/03-shell-integration-inventory.md` (`03 §n`). The per-scope reports in
`Mac/docs/reports/` say how each piece was verified. `Mac/docs/PROGRESS.md` is the item-by-item
checklist; this file is the summary a user needs.

**How this was checked.** A sample of 57 ticked checklist items was re-verified against the
source, biased deliberately towards the expensive and the cross-scope ones — the items most
likely to have been ticked optimistically. Nine were provably untrue and are now unticked, each
with the evidence written next to it in `PROGRESS.md`; eleven more were true but overstated and
carry a correction. The checklist therefore reads **386 of 496** rather than 395. Separately, the
app was launched in **all 93 bundled languages** and screenshotted in five of them; that is
`Mac/docs/reports/packaging.md`.

Two caveats about the whole audit: it is a **source audit plus a driven-app audit**, not a
hands-on review of every feature by a person, and **Finder's own context menu has never been
exercised in Finder** on this machine, because Automation permission was never granted
(`Mac/docs/reports/finder.md` lists 15 manual checks a human still owes).

**Update, 2026-09-20 (`mac/cmdmode`).** Four of the unfinished items below are closed and are
annotated in place; nothing was renumbered and no evidence was deleted. Section F lists them with
what was measured before the fix and what is left. The checklist therefore reads **390 of 496**.

**Update, 2026-10-03 (`mac/opsgaps`).** D items 2, 3, 4 and 8 are closed (B items 6, 8 and 12's
Dock half with them); section H says how. Five checklist boxes were ticked.

**Update, 2026-10-03 (`mac/optgaps`).** D items 11 and 12 are closed, and B items 13, 14, 15, 17 and 23;
section I says how. Three checklist boxes were ticked.

**Update, 2026-10-03 (`mac/panelgaps`).** Items 1, 5 and 6 below are closed and item 9 mostly;
each is annotated in place and section G says how. Four panel-section boxes were ticked; the
checklist now reads **403 of 496** (the other nine came from branches merged since the audit).

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

---

## B. Partial — it works, with a limitation worth knowing

1. **The panel's own right-click menu has a dead 7-Zip section.** Open archive, Extract files…,
   Extract Here, Extract to…, Test archive, Add to archive…, Compress and email… and the two
   "Add to *name*.7z/.zip" items are drawn and then greyed out: the menu items are built with
   selectors that nothing implements, so the responder chain disables every one of them
   (`PanelContextMenu.swift:22-32`; `Mac/docs/reports/screenshots/panel-10-context-menu.png`).
   CRC SHA and the File-menu items on the same menu do work, and so do the same commands from the
   File menu, the toolbar and **Finder's** 7-Zip menu. (`01 §2.9`)
2. **Drag and drop only in the Details view.** The three icon/list view modes are neither a drag
   source nor a drop target. (`01 §3.15`)
3. **Dropping files on the window background** opens Add-to-archive for the panel's *selection*,
   not for what you dropped: the dropped list is computed and discarded. (`01 §3.15`, `03 §4.2`)
4. **Open Outside does nothing for an item inside an archive** — the code path exists but is never
   called. It works normally for files and folders on disk. (`01 §3.8`)
5. **Diff** compares two items selected in one panel; the Windows "focused item of each panel"
   case is not implemented, and the menu item stays enabled even with no Diff tool configured.
   (`01 §3.11`)
6. **No help is bundled.** Help ▸ Contents and the About, Benchmark and temp-browser Help buttons
   open the system help viewer; the Compress and Extract dialogs open 7-zip.org; the Options Help
   button only beeps. Nothing points at a local `FM/index.htm` because there is none.
   (`01 §2.6, §9 #17`)
   **Closed 2026-10-03 (`mac/opsgaps`), see H.1.**
7. ~~**`-scrc` while extracting or testing** is not wired, and the panel's Test button does not pass
   `-thash`. The bridge support exists (`SZExtractOptions.hashMethods` →
   `SZExtractResult.hashResults`); no caller sets it.~~ (`03 §2.6`, `01 §8.6`)
   **Half closed 2026-09-20 (`mac/cmdmode`), see F.2.** `x -scrc<M>` and `t -scrc<M>` now report the
   checksums of the extracted data in the hash list, cross-checked against `7zz t -scrcSHA256`. The
   panel's own Test button still does not pass `-thash`: that file belongs to another scope and the
   recipe is filed in `requests.md`.
8. **Quarantine is not propagated** to files extracted normally — only to files you open from
   inside an archive. (`01 §9 #23`)
   **Closed 2026-10-03 (`mac/opsgaps`), see H.2.**
9. ~~**Command mode** never returns exit code 8 (out of memory) and has no exception→message ladder;
   `rn` is refused; wildcards inside `-i!` are not expanded. Exit codes 0, 1, 2, 7 and 255 are
   correct.~~ (`03 §2.2, §2.7`)
   **Closed 2026-09-20 (`mac/cmdmode`), see F.1.** All four halves were confirmed true by measurement
   first. `SevenZipFailureLadder` is `WinMain`'s whole catch chain, exit 8 included; `rn` is
   implemented; include and exclude wildcards are expanded by the engine's own
   `EnumerateDirItemsAndSort` / `EnumerateItems`.
10. ~~**`-sfx<module>` is ignored**: a self-extracting archive is always built from the bundled
    `7z.sfx`, and `a -sfx` without `-ad` writes a plain archive.~~ (`01b §4.23`)
    **Closed 2026-09-20 (`mac/cmdmode`), see F.3.** The named module is honoured and validated, and a
    missing module, a bogus module or a non-7z `-t` is an error with nothing written. The Compress
    dialog's own per-format Browse filter is a separate item and is still open.
11. **Properties has no raw-property block** and no NT security summary: `IArchiveGetRawProps` is
    not bridged. (`01 §3.11`)
12. **Progress has no Dock-tile percentage**, and the messages list uses fixed column widths.
    (`01b §4.17`)
    **Dock tile closed 2026-10-03 (`mac/opsgaps`), see H.3**; the column widths are unchanged.
13. **Options ▸ System** shows generic system icons rather than 7-Zip's format icons (which are
    built and shipped, just not used here); a single click does not toggle a row and Return does
    nothing (Space, `+`, `-`, `*` and the buttons do); Apply does not refresh Launch Services.
    (`01b §4.21`)
    **Closed 2026-10-03 (`mac/optgaps`), see I.1.**
14. **Options ▸ Language** does not report a language file that fails to load — it is skipped
    silently — and shows only counts, not the list of missing ids. (`01b §4.9`)
    **Closed 2026-10-03 (`mac/optgaps`), see I.2.**
15. **Options ▸ 7-Zip** forces the Options window far wider than the screen, because the
    `pluginkit` status line is one unwrapped string; the tab row is pushed out of view on that
    page. (`Mac/docs/reports/screenshots/packaging-31-options-menu-de.png`)
    **Closed** (`mac/polish`); and every Options page now fits a 660 pt window in eight languages,
    measured (`mac/optgaps`, I.3).
16. **The two-panel splitter position is restored wrong intermittently** — panel 0 collapses to its
    120 pt minimum instead of the stored ratio. (`01 §1.2`, `01b §5.7`)
17. **Copy/Move, Benchmark and Properties draw their bottom button row clipped** by the window
    edge. The buttons are still there and still work; it is a measuring bug in the shared dialog
    builder, present in English as much as in any translation.
    **Closed** (`mac/polish`, the `DialogKit.install` bottom constraint). Separately, every
    `DialogKit` dialog now centres on its owner window instead of the screen (`mac/optgaps`, I.4).
18. **Opening several archives from Finder**: the first reuses the front window's panel, only the
    rest get windows of their own. (`03 §6.2`)
19. **Only the five `Options.*` values reach the Finder extensions**; `Compression.*` and
    `Extraction.*` do not. (`03 §6.4`)
20. **The toolbar** persists its mask and visibility but renders SF Symbols, so "Large Buttons"
    and "Show Buttons Text" do not reproduce the Windows 48×36 / 24×24 bitmaps. (`01 §1.3`)
21. **The status bar** is one four-part label rather than four sections at fixed widths.
    (`01 §1.2`)
22. **File-menu enable rules** for Split, Combine, Link, Diff and the version-control items are not
    evaluated the way `01 §2.1` specifies. (The version-control items are hidden.)
23. **Right-to-left languages are not mirrored** (AppKit only mirrors an app that declares an RTL
    localization, and this app carries none), and composite one-field strings — the status line,
    the Copy dialog's info block — come out with their segments in reverse order. Nothing is
    clipped or missing. Six of the 92 translations are RTL.
    **Segment order closed 2026-10-03 (`mac/optgaps`), see I.5**; the app is still not mirrored.
24. **A third of the translations are substantially incomplete** — 24 of 92 are missing more than a
    quarter of the strings the app asks for, and those fall back to English. 28 are complete. Full
    table in `Mac/docs/reports/packaging.md`.

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

---

## D. Missing

**Windows-only by nature — consciously dropped, nothing to build.**
Alternate data streams and their folder and menu item; NT security descriptors; drive letters,
`\\.\` imaging, NetFolder and the "Network" root; the long-path Recycle Bin message; registry
persistence; the COM shell DLL, its Approved-list registration and `IExplorerCommand`; the
16-item context-menu reduction; drop-handler mode; `ITaskbarList3` taskbar progress; large memory
pages (`-slp`); HtmlHelp `.chm`; `Benchmark 2`; every `IDD_*_2` small-screen dialog; the 32-bit
memory and dictionary caps; `Set_Wow64` / `OleInitialize`; and the Explorer verb names.

**Unfinished — real gaps, roughly in the order they would be missed.**
1. ~~The handlers behind the panel context menu's 7-Zip commands (`01 §2.9`).~~ **Done 2026-10-03 (G.1).**
2. ~~Bundled HTML help, and the Options Help button (`01 §9 #17`).~~ **Done 2026-10-03 (H.1).**
3. ~~Quarantine on ordinary extraction, and zone propagation from the outermost archive
   (`01 §9 #23`).~~ **Done 2026-10-03 (H.2)**; an explicit outermost-archive source for the panel's
   copy is filed for `panel`.
4. ~~`-scrc` on `x` / `t`~~ (**done 2026-09-20, F.2**), and `t -thash` from the panel
   (`03 §2.6`, `01 §8.6`) — **the panel half is done 2026-10-03**: the context menu's C13 (G.1) and
   now the toolbar / File-menu Test, which runs `t -thash` for checksum files (H.5).
5. ~~Open Outside for items inside an archive; Diff across two panels (`01 §3.8, §3.11`).~~ **Done 2026-10-03 (G.2).**
6. ~~Drag and drop in the three icon view modes; the dropped-file list for background drops
   (`01 §3.15`).~~ **Done 2026-10-03 (G.3).**
7. Raw properties (`IArchiveGetRawProps`) in the columns and in Properties (`01 §3.2, §3.11`).
8. Dock-tile progress, and the exception→message mapping for a failed operation
   (`01b §4.17`, `01 §8.7`) — **the command-mode half is done 2026-09-20 (F.1)**: every failure a
   command can hit is classified by `SevenZipFailureLadder`, and `SZUpdater` / `SZHasher` now give
   `E_OUTOFMEMORY` the IDS_MEM_ERROR text `HResultToMessage` gives it, so the Progress dialog's own
   final message matches Windows for those two. `SZExtractor` and `OperationRunner`'s generic alert
   are filed in `requests.md`. **Both halves done 2026-10-03 (H.3, H.4).**
9. File-menu enable and hide rules (`01 §2.1`) — **done 2026-10-03 (G.4)** except the Ver* (7vc) items and the small-screen variant.
10. ~~Exit code 8 and the 7zG exception ladder; `EnumerateDirItemsAndSort` for `-i!` wildcards~~
    (`03 §2.2, §2.7`) — **done 2026-09-20 (F.1)**.
11. ~~`-sfx<module>`~~ (**done 2026-09-20, F.3**); ~~the Compress dialog's per-format Browse filter
    (`01b §4.23`)~~ — **done 2026-10-03 (I.6)**.
12. ~~Options ▸ System format icons, single-click and Return, and the Launch Services refresh;
    Options ▸ Language's id lists and load-error report (`01b §4.21, §4.9`).~~ **Done 2026-10-03 (I.1, I.2).**
13. Write-back of a nested archive into its parent archive (`01 §3.8`).
14. ~~Dropping onto the Dock icon as "Add to archive…"~~ (`03 §6.2`) — **done 2026-09-20 (F.4)**,
    with one verification debt: no test on this machine can perform a real Dock drop.

---

## E. Verification debts

Honest about what nobody has checked rather than what nobody has built.

* **Finder's context menu has never been opened in Finder.** The extension builds, signs,
  sandboxes and registers, and its menu model is unit-tested item for item, but the machine has no
  Automation permission, so no test could drive Finder. `Mac/docs/reports/finder.md` lists 15
  numbered checks for a human.
* **Only ad-hoc signing has ever been exercised.** There is no Developer ID on this machine
  (`security find-identity -v -p codesigning` → "0 valid identities found"), so the Developer ID
  and notarization paths of `Mac/scripts/package.sh` are written and guarded but never run end to
  end. Their failure modes are guarded to refuse early rather than fail late.
* **`fetch-assets.sh` and `make-fixtures.sh` were not re-run** by this audit; the bundled
  `Lang/` and `SFX/` assets and the test fixtures are the ones already in the tree.
* **`architecture.md`'s "As built" section is stale** — it still describes the Wave 1 app (it calls
  `SZProgressDelegate` unused, `FinderSync.swift` a stub, and counts 17 tests). It is not
  `packaging`-owned, so it was left alone and recorded here.
* **Control-ID comments are incomplete.** Every `IDM_*` and `IDD_*` from the inventories appears in
  the source as a comment, but roughly 43 control ids (`IDX_SETTINGS_SHOW_DOTS`,
  `IDT_PROGRESS_ELAPSED`, the `IDG_BENCH_*` group, `IDC_LANG_LANG`, `IDB_LINK_LINK` and others)
  are cited by their numeric lang id instead of their symbolic name, so the grep audit of
  `PROGRESS.md §9.4` cannot pass yet.
* **Tests.** 286 of 286 unit tests pass in Debug and in Release; the XCUITest suite passes,
  including the six new localization tests. What the UI suite covers is breadth, not depth: it
  asserts that things are present and populated, not that every operation produces the right bytes
  — that is what the unit tests do.

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
