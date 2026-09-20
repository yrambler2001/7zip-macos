# `cmdmode` — command mode, archive creation switches, and the Dock drop

Scope report per `Mac/docs/00-orchestration.md` "Agent deliverables". Branch `mac/cmdmode`, worktree
`.worktrees/cmdmode`, created from `macos` at `c6f1a8b`. Date 2026-09-20.

Assignment: close four items of `Mac/docs/parity.md` — D item 10 (command mode), D item 4's command
half (checksums while extracting and testing), D item 11's bridge half (the self-extracting module
switch) and D item 14 (dropping onto the Dock icon) — after **measuring** each one, because a recent
sibling found half of its filed diagnoses wrong once measured.

---

## 1. How the four diagnoses held up

**All four held up exactly as written.** Nothing in this batch was already working, and nothing was
misdiagnosed. What measuring added was detail, and in two places the engine corrected an assumption
of *mine* rather than the audit's (section 6).

| Item | Filed | Measured |
|---|---|---|
| 10, command mode | "never returns exit code 8, no exception→message ladder, `rn` is refused, wildcards inside `-i!` are not expanded" | True on all four counts. `SevenZipExitCode.memoryError` had exactly one reference in the whole tree, an assertion in `FinderCommandTests.swift:329`. `CommandExecutor` had five hand-written `case .failure: return .fatalError` arms and no message mapping at all. `runUpdateGroup` answered `rn` with `showError("Unsupported command")` + exit 2. `SevenZipArguments.resolve` returned `-i!` / `-x!` names verbatim into `includePaths`, and `SZUpdater` fed every one of them to `AddPreItem_NoWildcard`, so a pattern could only ever match a file literally named `*.txt`. |
| 4, `-scrc` on `x`/`t` | "the bridge already supports this; nothing sets them" | True. `grep hashMethods Mac/App` found two hits: the declaration in the grammar and one read in `runHash`. `SZExtractOptions.hashMethods` / `SZExtractResult.hashResults` were fully implemented and unit-tested by `ExtractHashTests`, with no caller. |
| 11, `-sfx<module>` | "always built from the bundled stub because the switch naming a module is ignored; asking for one without `-ad` silently writes a plain archive" | True, and the second half is worse than it sounds. `CommandExecutor.swift:365` was `input.sfxMode = command.sfxModule != nil` — the module string was discarded even in the dialog path — and in the **no-dialog** path `result.sfxMode` was never assigned at all, so `a -sfx out.exe f` wrote a plain 7z *named* `out.exe`. `SZUpdateOptions.sfxModulePath` had no assignment anywhere in the tree. |
| 14, the Dock drop | "currently opens them" | True. `application(_:open:)` → `URLCommands.openDocuments` → `CommandExecutor.openInFileManager`, with no notion of where the request came from. |

---

## 2. What was implemented

### 2.1 The exception ladder and exit code 8 (`03 §2.7`)

`SevenZipFailureLadder` — appended to `Mac/App/Integration/ArgumentGrammar.swift` — is `WinMain`'s
catch chain (`CPP/7zip/UI/GUI/GUI.cpp:437-494`) as a pure classifier, and **every** failure site in
`CommandExecutor` now routes through it, so no code path invents an exit code of its own:

| cause | exit | box |
|---|---|---|
| `CNewException` / `E_OUTOFMEMORY` / POSIX `ENOMEM` | **8** | IDS_MEM_ERROR 3000 |
| `SevenZipArgumentError` (= `CMessagePathException` from the parser) | 7 | message + path, two lines |
| bridge error flagged `SZPathExceptionUserInfoKey` (= `CMessagePathException` from the engine) | 7 | the engine's own text |
| `E_ABORT` / `SZError.Code.cancelled` | 255 | none |
| any other engine error | 2 | `localizedDescription`, i.e. `MyFormatMessage` |
| `"Internal Error #N"` (how the bridge spells `catch (int n)`) | 2 | `"Error: N"`, as `WinMain` spells it |
| no text at all | 2 | `"Unknown error"` |

Why exit 8 is now reachable at all: `CNewException` **is** `std::bad_alloc` on this platform
(`CPP/Common/NewHandler.h:99-102`, since `Z7_REDEFINE_OPERATOR_NEW` is not defined), the bridge's
`SZHandleCurrentException` already caught `std::bad_alloc` and returned `E_OUTOFMEMORY`, and
`SZErrors.errorWithHRESULT:` already mapped that to `SZErrorCodeOutOfMemory`. The only missing piece
was a classifier that looked at it.

The ladder lives in `ArgumentGrammar.swift` rather than a file of its own for a concrete reason: it
has to be unit-testable, and `Mac/project.yml` (owned by `harness`) lists the test target's app
sources file by file, so a new file would not compile into `SevenZipKitTests`. That file is also
compiled into the two sandboxed appex targets, which must not link `SevenZipKit`, so the ladder is
Foundation-only and spells out the four bridge constants it needs;
`CommandModeTests.testFailureLadderConstantsMatchTheBridge` asserts they still agree, the same way
`ContextMenuItemFlags` mirrors `Settings.ContextMenuFlags`.

`SZUpdater.mm` and `SZHasher.mm` additionally substitute the IDS_MEM_ERROR text for
`MyFormatMessage`'s errno text on `E_OUTOFMEMORY`, which is what `HResultToMessage`
(`ProgressDialog2.cpp:1477-1483`) does, so the Progress dialog's own final message says what Windows
says for those two operations. `SZExtractor.mm` and `OperationRunner`'s generic alert belong to other
scopes and are filed in `requests.md`.

### 2.2 `rn` (`03 §2.2`)

`SevenZipArguments.parse` turns an `rn` command's positional strings into `[SevenZipRenamePair]`
instead of item paths, exactly as `AddToCensorFromNonSwitchesStrings` does with its `renamePairs`
argument (`ArchiveCommandLine.cpp:565-625`):

* pairs in order; a `@listfile` among the positional strings contributes pairs of its own and must
  hold an **even** number of names, else `kIncorrectListFile`;
* an odd number of names → `"There is no second file name for rename pair:"` + the name (exit 7);
* a wildcard in an **old** name → `"Unsupported rename command:"` + old + new
  (`CRenamePair::Prepare`, `Update.cpp:288-295`); `-spd` turns wildcard parsing off and the name is
  then literal and accepted.

`SZUpdater.renameItems(pairs:inArchiveAt:itemSpecs:options:progress:)` fills
`CUpdateOptions::RenamePairs` and `RenameMode` and hands the archive to the engine's own
`UpdateArchive`, which walks `arcItems`, matches each censored name against the pairs with
`CRenamePair::GetNewPath` and rewrites the archive. `itemSpecs` is the `-i` / `-x` mask over the
archive's **own** item names; empty means `*`. Upstream dispatches `rn` through `UpdateGUI`, so the
progress window is the Compressing one (`IDS_PROGRESS_COMPRESSING 3301` — there is no "Renaming"
string in the 33xx block) and a failed file is still exit code 1. The bridge re-checks `isSupported`
so a caller that bypasses the parser cannot get an unsupported pair through.

### 2.3 Include and exclude wildcards, expanded by the engine (`03 §2.2`)

The instruction was to reuse the engine's own directory enumeration rather than write a matcher, and
that is what happens — twice, because the engine has two walks and they differ.

`SevenZipPathSpec` (Swift) / `SZPathSpec` (bridge) is one censor entry: the name as written plus the
`r` / `w` / `m` modifiers of the switch it came from, i.e. `CNameOption` + the name
`AddNameToCensor` receives. `SevenZipCommandLine` exposes `includeSpecs`, `excludeSpecs`,
`archiveIncludeSpecs`, `archiveExcludeSpecs` and the two composed lists `itemSpecs` (with the
positional paths under the global `CNameOption`) and `archiveSpecs` (with the archive name, never
recursed, as `nopArc` has it at `ArchiveCommandLine.cpp:1671-1676`).

* `SZUpdater.expandPathSpecs(_:sortedArchiveList:)` builds an `NWildcard::CCensor` with
  `AddPreItem`, runs `AddPathsToCensor(k_RelatPath)` + `ExtendExclude()`, and then either
  `EnumerateDirItemsAndSort` (`true` — the extract group's archive list, the call `GUI.cpp:285-304`
  makes) or `EnumerateItems` (`false` — the item-censor walk `UpdateArchive` and `HashCalc` run).
* The **update, delete and rename** paths do not expand at all: they hand the specs to
  `SZUpdater.update(with:pathSpecs:)` / `deleteItems(specs:)` / `renameItems(…itemSpecs:)` and
  `UpdateArchive` does its own `AddPathsToCensor` + `EnumerateItems` (`Update.cpp:1159-1161`). That
  is what keeps the stored names right: `a arc.7z -ir!src/*.c` stores `sub/x.c`, not `x.c`, because
  the censor prefix is `src/` and the engine computes the relative path. Pre-expanding to full paths
  and re-adding them as literals would have flattened that.
* `CommandExecutor.expand(...)` is called only when `SevenZipCommandLine.needsCensorWalk(specs)` —
  an include entry with `*`/`?`, or any exclude entry. Every Finder selection writes one
  `-aiw-!<path>` per item, so the common path answers false, takes the literal names and touches no
  disk. Nothing that worked before this change behaves differently.

**One behaviour change worth naming.** A *positional* path now inherits the global
`CNameOption`, so `a arc.7z 'we*rd.txt'` treats the name as a pattern, where the port previously took
it literally. That is what upstream does (`AddNameToCensor` with `nop.WildcardMatching` true unless
`-spd`), and `-spd` or the `-iw-!` form both opt out, so the selection transport is unaffected.

### 2.4 `-scrc` on `x` and `t` (`03 §2.6`)

`runExtractGroup` sets `SZExtractOptions.hashMethods` from `command.hashMethods` (a bare `-scrc`
contributes an empty name, which is CRC32, exactly as `CHashBundle::SetMethods` reads it; an
unsupported method is exit 2, which is upstream's `ThrowException_if_Error(hb.SetMethods(...))`), and
on success shows `SZExtractResult.hashResults` in `HashResultsDialog` **instead of** the test summary
box — the `if (HashBundle) … else if (Options->TestMode)` of `ExtractGUI.cpp:129-152`. It applies to
`x` as much as to `t`, which is what `ExtractGUI.cpp:81-98` does.

Like upstream's `ShowHashResults`, that list is **not** suppressed by `-y`: `g_DisableUserQuestions`
gates only the error boxes, so an unattended `t -scrc` run shows the results window, exactly as 7zG
does. That is deliberate parity, and it is why the argv exercise in section 4 leaves `-scrc` to the
XCUITest that can click the box away.

The panel's own Test button needs the same treatment and lives in
`Mac/App/Commands/ExtractCommands.swift`, which this scope does not own; it is filed in
`requests.md` with the exact call sites and the `t -thash` half as well.

### 2.5 `-sfx<module>` (`01b §4.23`)

* `SZUpdater.resolvedSFXModulePath(_:)` is `Update.cpp:1167-1191`: nil or `""` is the bundled
  `7z.sfx` (`kDefaultSfxModule`, `UpdateGUI.cpp:31`, `:561-565`), a bare name with no separator is
  looked up in the bundle's `Resources/SFX` first (the equivalent of
  `NDLL::GetModuleDirPrefix()`) and then relative to the current directory, anything else is used as
  given. The file must exist (`"cannot find specified SFX module"`) and must look like a stub — a
  regular file of at least 1 KiB whose first four bytes are `MZ` (the PE stubs 7-Zip ships; both
  bundled ones are `PE32 executable … for MS Windows`) or a Mach-O / universal magic, else
  `"cannot open SFX module"`, which is `Update.cpp:754-755`'s own message.
* `SZUpdater.formatSupportsSFX(_:)` is the `kFF_SFX` bit of the Compress dialog's format table
  (`01b §4.23`, `CompressDialog.cpp:236-248` and the rows at `:364`): 7z only.
* `CommandExecutor` resolves and validates **before** any dialog, and sets `sfxMode` whether or not
  `-ad` was given, because `UpdateGUI.cpp:561-565` fills the default module either way. As upstream
  (`UpdateGUI.cpp:517`, `if (di.SFXMode) options.SfxMode = true;`) the Compress dialog can turn SFX
  **on** but cannot turn a command-line `-sfx` off.

So the two surprises are gone: `a -sfx out.exe f` produces a real self-extracting archive, and a
missing module, a bogus module or a non-7z `-t` is an error **with nothing written** — checked by
running the built app and asserting the output file does not exist.

### 2.6 The Dock drop (`03 §1.7`, `§6.2`)

**How the two gestures are told apart, and why that way.** macOS has no `NSApplicationDelegate`
callback for "dropped on the Dock icon": a Dock drop, a Finder double-click, "Open With", `open -a`
and `NSWorkspace.open` all arrive as the same `kAEOpenDocuments` (`'aevt'/'odoc'`). Three options
were on the table:

1. *Decide from the selection alone* — treat any multi-item or non-archive open as a compress. This
   was rejected: it would break "Open With ▸ 7-Zip" on a text file and the documented multi-archive
   open from Finder (`parity.md` B18), and it would guess about a gesture it cannot see.
2. *Treat a Dock drop like an open, as most apps do* — rejected, because the assignment is to
   implement the Windows behaviour and Windows registers 7-Zip as an Explorer **drop handler**, so
   dragging a selection onto it offers the compress items (`03 §1.7`, `ContextMenu.cpp`'s
   `_dropMode`).
3. *Read the Apple event's sender* — chosen. The event carries `keyOriginalAddressAttr` /
   `keyAddressAttr`; `DockDropDetector` coerces it to `typeKernelProcessID`, resolves the pid with
   `NSRunningApplication`, and compares the bundle identifier against `com.apple.dock`. Anything
   else — **including a missing or unresolvable attribute** — stays an ordinary open, which is the
   conservative direction: opening what the user asked to open is never destructive, while
   compressing it unasked would be.

**What each drop does.** `DockDropRouter.action(paths:directoryFlags:isRecognisedArchive:)`:

* **one single archive → open it.** The Dock is a legitimate way to open an archive without Finder,
  and the event is indistinguishable from a double-click, so it must still work. "Archive" is Block
  A's own condition (`ContextMenu.cpp:740-786`: one item, not a directory, `needsExtract` — its
  extension is not in `kExtractExcludeExtensions`) **plus** the engine recognising the extension
  (`SZCodecs.format(forArchiveName:)`). The extra clause matters: `needsExtract` is true for a name
  with no extension at all, so without it a dropped `Makefile` or `image.png` would open an empty
  panel instead of being compressed.
* **everything else → "Add to archive…".** Several items, a folder, or one non-archive file. The
  argv is literally `FinderMenuModel.command(verb: "SevenZipCompress", …)`, i.e.
  `a <selection> -ad -saa -- <dir><name>`, so the Dock and Finder's own 7-Zip menu cannot drift. If
  the user has switched that context-menu item off, the drop falls back to opening rather than doing
  nothing silently.

**The enabling half.** The Dock highlights the icon only for types the app claims, and the compress
gesture must accept anything, so `Mac/App/Info.plist` gains one last `CFBundleDocumentTypes` group
claiming `public.item` + `public.folder` with `CFBundleTypeRole = Viewer` and
`LSHandlerRank = None` — the documented "can open it, must never be its default handler" pair. It
claims no `CFBundleTypeExtensions`, so it never competes with the 39 association groups above it, and
a unit test asserts all of that. `CFBundleTypeRole = Shell` would also grant the drop but means
"provides runtime services for other processes", which this is not.

---

## 3. Files

Owned by this scope, all modified or added by it:

| File | Change |
|---|---|
| `Mac/App/Integration/ArgumentGrammar.swift` | `SevenZipPathSpec`, `SevenZipRenamePair`, `SevenZipRecursedType`, `SevenZipMarkMode`, the four spec lists + `itemSpecs` / `archiveSpecs` / `needsCensorWalk`, `rn` pair parsing, the `r`/`w`/`m` modifiers recorded instead of only consumed, and `SevenZipFailure` + `SevenZipFailureLadder` |
| `Mac/App/Integration/CommandExecutor.swift` | the ladder at every failure site, censor expansion, `-scrc` on `x`/`t`, the hash list replacing the test summary, `-sfx<module>`, `renameItems`, `deleteItems(specs:)` |
| `Mac/App/Integration/FinderMenuModel.swift` | `DocumentOpenSource`, `DockDropAction`, `DockDropRouter` (appended; nothing above it touched) |
| `Mac/App/Integration/URLCommands.swift` | `openDocuments(_:formatHint:source:)` and the Add-to-archive path |
| `Mac/App/Integration/AppDelegate+Integration.swift` | `DockDropDetector` and the source-aware `application(_:open:)` / `openFiles:` |
| `Mac/App/Info.plist` | the `public.item` + `public.folder` drop group |
| `Mac/Core/include/SZUpdater.h`, `Mac/Core/SZUpdater.mm` | `SZPathSpec`, `SZRenamePair`, `SZPathExceptionUserInfoKey`, `expandPathSpecs(_:sortedArchiveList:)`, `update(with:pathSpecs:)`, `renameItems(...)`, `deleteItems(specs:)`, `resolvedSFXModulePath(_:)`, `formatSupportsSFX(_:)`, the IDS_MEM_ERROR substitution, and `SZRunCatchingPathException` |
| `Mac/Core/SZHasher.mm` | the same IDS_MEM_ERROR substitution at its two error sites |
| `Mac/Tests/SevenZipKitTests/CommandModeTests.swift` | new, 24 tests |
| `Mac/Tests/UITests/CommandModeUITests.swift` | new, 4 XCUITests |
| `Mac/docs/api/finder.md` | section 12, the dated grammar note |
| `Mac/docs/parity.md` | the four items annotated in place plus section F |
| `Mac/docs/requests.md` | two rows closed, five filed |
| `Mac/docs/PROGRESS.md` | the `cmdmode` ticks |

Nothing outside that list was touched. In particular `Mac/App/Dialogs/*`, `Mac/App/Panel/*`,
`Mac/App/Commands/*`, `Mac/App/Support/*`, `Mac/Core/SZExtractor.*`, `Mac/project.yml` and
`Mac/Tests/UITests/`'s existing files are unchanged; the parallel dialog-layout agent owns those.
`Mac/App/MainMenu.swift` needed no change. No upstream file (`C/`, `CPP/`, `Asm/`, `DOC/`) was
touched.

---

## 4. Verification

### 4.1 Unit tests

<!--UNIT-->

### 4.2 The real argv paths

<!--ARGV-->

### 4.3 UI suite

<!--UI-->

### 4.4 Cross-checks against the console tool

<!--XCHECK-->

---

## 5. Known gaps and follow-ups

1. **The panel's Test button** still cannot ask for a digest, and `t -thash` (Windows' C13 verb,
   "Test archive : Checksum") is reachable only from Finder's menu, not from the panel. Both live in
   `Mac/App/Commands/ExtractCommands.swift`; filed for the `extract` scope in `requests.md` with the
   call sites.
2. **`SZExtractor.mm` and `OperationRunner`** still show `MyFormatMessage`'s errno text for
   `E_OUTOFMEMORY` instead of IDS_MEM_ERROR. The *exit code* is right either way; only the text
   differs. Filed for `extract` and `opsinfra`.
3. **The Compress dialog has no field for an SFX module**, so `CommandExecutor` re-applies
   `-sfx<module>` after the dialog returns rather than the dialog carrying it. Filed for `compress`,
   together with the per-format Browse filter that `parity.md` D item 11 still lists.
4. **Exit code 8 cannot be provoked from a command line.** It is unit-tested arm by arm and the code
   path is the same one every other failure takes, but no argv makes the engine actually fail to
   allocate. `-smemx` is parsed and ignored by this port, so it cannot be used to force it either.
5. **`-scrc` shows its results window even with `-y`**, because upstream's `ShowHashResults` is not
   gated by `g_DisableUserQuestions`. Faithful, and mildly hostile to automation; changing it would
   be a deliberate divergence and is not one this scope took.
6. **A real Dock drop has never been performed.** See section 4 and `parity.md` F.4; one human check
   is filed in `requests.md`.
7. **`-spm` is still accepted and ignored**, so the global mark mode cannot be set from the command
   line even though the per-switch `m` modifier is now honoured end to end. It only affects whether a
   trailing separator forces "directories only", and no shell command generates it.

---

## 6. Where measurement corrected me

Two expectations of mine about the engine's own walk were wrong, and the tests caught them before the
code shipped. Both are recorded in the tests as comments, because they are the kind of thing the next
agent would otherwise assume too:

1. **A matched directory is walked whole even without `-r`.** `expandPathSpecs` of `<dir>/*` returns
   `readme.txt notes.md sub/big.txt sub/deep/inner.txt`, not `readme.txt notes.md sub` — `7z a arc *`
   behaves the same way. And both walks report **files only**; a directory they descended into never
   appears in the result.
2. **A censor path that matches nothing is exit 7, not 2, in the archive-list walk.**
   `EnumerateDirItemsAndSort` throws `CMessagePathException("Cannot find archive")`
   (`EnumDirItems.cpp:1496-1500`), and `WinMain` puts `CMessagePathException` on the `kUserError`
   arm. `CMessagePathException` derives from `UString`, so the bridge's generic handler flattened it
   into `E_FAIL` and the ladder would have called it exit 2. `SZUpdater.mm` now catches it first and
   flags the `NSError` with `SZPathExceptionUserInfoKey`, which the ladder reads.
   `EnumerateItems` — the item-censor walk — has no such rule, so `a arc -i!*.nothing` is not an
   engine exception; it stops at the port's own "You must select one or more files" guard, exit 7 by
   a different route.
