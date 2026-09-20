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
7. **`-scrc` while extracting or testing** is not wired, and the panel's Test button does not pass
   `-thash`. The bridge support exists (`SZExtractOptions.hashMethods` →
   `SZExtractResult.hashResults`); no caller sets it. (`03 §2.6`, `01 §8.6`)
8. **Quarantine is not propagated** to files extracted normally — only to files you open from
   inside an archive. (`01 §9 #23`)
9. **Command mode** never returns exit code 8 (out of memory) and has no exception→message ladder;
   `rn` is refused; wildcards inside `-i!` are not expanded. Exit codes 0, 1, 2, 7 and 255 are
   correct. (`03 §2.2, §2.7`)
10. **`-sfx<module>` is ignored**: a self-extracting archive is always built from the bundled
    `7z.sfx`, and `a -sfx` without `-ad` writes a plain archive. (`01b §4.23`)
11. **Properties has no raw-property block** and no NT security summary: `IArchiveGetRawProps` is
    not bridged. (`01 §3.11`)
12. **Progress has no Dock-tile percentage**, and the messages list uses fixed column widths.
    (`01b §4.17`)
13. **Options ▸ System** shows generic system icons rather than 7-Zip's format icons (which are
    built and shipped, just not used here); a single click does not toggle a row and Return does
    nothing (Space, `+`, `-`, `*` and the buttons do); Apply does not refresh Launch Services.
    (`01b §4.21`)
14. **Options ▸ Language** does not report a language file that fails to load — it is skipped
    silently — and shows only counts, not the list of missing ids. (`01b §4.9`)
15. **Options ▸ 7-Zip** forces the Options window far wider than the screen, because the
    `pluginkit` status line is one unwrapped string; the tab row is pushed out of view on that
    page. (`Mac/docs/reports/screenshots/packaging-31-options-menu-de.png`)
16. **The two-panel splitter position is restored wrong intermittently** — panel 0 collapses to its
    120 pt minimum instead of the stored ratio. (`01 §1.2`, `01b §5.7`)
17. **Copy/Move, Benchmark and Properties draw their bottom button row clipped** by the window
    edge. The buttons are still there and still work; it is a measuring bug in the shared dialog
    builder, present in English as much as in any translation.
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
1. The handlers behind the panel context menu's 7-Zip commands (`01 §2.9`).
2. Bundled HTML help, and the Options Help button (`01 §9 #17`).
3. Quarantine on ordinary extraction, and zone propagation from the outermost archive
   (`01 §9 #23`).
4. `-scrc` on `x` / `t`, and `t -thash` from the panel (`03 §2.6`, `01 §8.6`).
5. Open Outside for items inside an archive; Diff across two panels (`01 §3.8, §3.11`).
6. Drag and drop in the three icon view modes; the dropped-file list for background drops
   (`01 §3.15`).
7. Raw properties (`IArchiveGetRawProps`) in the columns and in Properties (`01 §3.2, §3.11`).
8. Dock-tile progress, and the exception→message mapping for a failed operation
   (`01b §4.17`, `01 §8.7`).
9. File-menu enable and hide rules (`01 §2.1`).
10. Exit code 8 and the 7zG exception ladder; `EnumerateDirItemsAndSort` for `-i!` wildcards
    (`03 §2.2, §2.7`).
11. `-sfx<module>`; the Compress dialog's per-format Browse filter (`01b §4.23`).
12. Options ▸ System format icons, single-click and Return, and the Launch Services refresh;
    Options ▸ Language's id lists and load-error report (`01b §4.21, §4.9`).
13. Write-back of a nested archive into its parent archive (`01 §3.8`).
14. Dropping onto the Dock icon as "Add to archive…" (`03 §6.2`).

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
