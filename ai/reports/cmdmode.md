# `cmdmode` — command mode, archive creation switches, and the Dock drop

> **Publication note:** this report was written when it lived in `Mac/docs/reports/`. Its screenshots were removed from the repository before publication; a few showcase images live on in `docs/images/`, and the tests now write their screenshots to the git-ignored `Mac/build/screenshots/`. Paths below that point at removed images are kept as a record of what was measured.

Scope report per `ai/00-orchestration.md` "Agent deliverables". Branch `mac/cmdmode`, worktree
`.worktrees/cmdmode`, created from `macos` at `c6f1a8b`. Date 2026-09-20.

Assignment: close four items of `ai/parity.md` — D item 10 (command mode), D item 4's command
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
| `ai/api/finder.md` | section 12, the dated grammar note |
| `ai/parity.md` | the four items annotated in place plus section F |
| `ai/requests.md` | two rows closed, five filed |
| `ai/PROGRESS.md` | the `cmdmode` ticks |

Nothing outside that list was touched. In particular `Mac/App/Dialogs/*`, `Mac/App/Panel/*`,
`Mac/App/Commands/*`, `Mac/App/Support/*`, `Mac/Core/SZExtractor.*`, `Mac/project.yml` and
`Mac/Tests/UITests/`'s existing files are unchanged; the parallel dialog-layout agent owns those.
`Mac/App/MainMenu.swift` needed no change. No upstream file (`C/`, `CPP/`, `Asm/`, `DOC/`) was
touched.

---

## 4. Verification

### 4.1 Unit tests

`rm -rf Mac/build && Mac/scripts/build.sh && Mac/scripts/test.sh`: **311 of 311 pass** (the 286 of the audit's baseline
plus the 25 new ones in `CommandModeTests`), with the app-launch lock held for the whole run. The
clean build produces **no warning from `Mac/` source**; the one line the log carries,
`SevenZipKit: ld: warning: ignoring duplicate libraries: '-lc++'`, is pre-existing — it is in the
main checkout's build log too and comes from `OTHER_LDFLAGS` in `Mac/project.yml`, which this scope
does not own.

The 25 tests, by what they hold down:

| test | asserts |
|---|---|
| `testExitCodeValues` | `NExitCode::EEnum` including the 8 that had no other reference in the tree |
| `testFailureLadderConstantsMatchTheBridge` | the four constants the Foundation-only ladder mirrors still equal `SZErrorDomain`, `SZErrorHRESULTKey`, `SZPathExceptionUserInfoKey` and the two `SZError.Code` values, and that `SZErrors.errorWithHRESULT:` really maps `E_ABORT` / `E_OUTOFMEMORY` to them |
| `testExitCodeLadder` | every arm of `GUI.cpp:437-494`: out of memory by code, by HRESULT and by POSIX `ENOMEM` → 8 + IDS_MEM_ERROR; the path exception → 7 + its text; `E_ABORT` by code and by HRESULT → 255 + **no** box; another engine error → 2 + `MyFormatMessage`'s text; a string exception → 2 + the string; `Internal Error #17` → `"Error: 17"`; an empty text → `"Unknown error"`; a plain Swift error → 2 |
| `testMemoryErrorMessageComesFromLangID3000` | the ladder's default text is the built-in English of lang id 3000, and the lang table really carries that id, so the app's `Lang.text(3000, …)` resolves rather than falls back |
| `testRenameCommandParsesPairs` | `rn a.7z o1 n1 o2 n2` → two pairs, and nothing in the item censor |
| `testRenameCommandRefusesAnOddNumberOfNames` | `"There is no second file name for rename pair:"` + the offending name |
| `testRenameCommandRefusesAWildcardInTheOldName` | `"Unsupported rename command:"`, and that `-spd` makes the same name literal and accepted |
| `testRenameCommandReadsPairsFromAListFile` | `@listfile` pairs with CRLF and LF, the file recorded in `consumedListFiles`, and an odd count refused |
| `testRenameRewritesTheArchive` | the real rename: two members in, `README.1st` out, `readme.txt` gone, cross-checked with `7zz l -slt` |
| `testRenameBridgeRefusesAnUnsupportedPair` | `isSupported` / `unsupportedDetail`, the bridge refusing an unsupported pair and an empty pair list |
| `testIncludeSwitchModifiersAreRecorded` | `-i!`, `-ir!`, `-xr0!`, `-iw-!`, `-spd`, `-im2!`, `-xm-!` and `-r` each land on the right `SevenZipPathSpec` field, and that a literal selection does **not** trigger a directory walk |
| `testExpandPathSpecsWalksTheRealTreeLikeTheEngine` | against a real four-file tree: non-recursed, `-r`, `-r0`, an exclude entry, `*` at the top level, a literal name that does not exist (→ 7), and both of the engine's walks |
| `testLiteralSpecKeepsAStarInARealFileName` | a file really named `we*rd.txt` survives `SZPathSpec.literal` — the reason `-aiw-!` exists |
| `testArchiveCensorExpandsWildcards` | three archives, `-ai!*.7z` minus `-ax!two.7z` → the other two, sorted |
| `testUpdateWithSpecsKeepsTheRelativePathsTheEngineComputes` | `-ir!*.txt` stores `sub/big.txt` and `sub/deep/inner.txt`, not `big.txt`, and skips `notes.md`; `7zz t` passes on the result |
| `testDeleteWithNoIncludeEntryIsRefused` | an exclude-only censor cannot empty an archive, and an include entry deletes exactly its members |
| `testScrcIsParsedForExtractAndTest` | `-scrcSHA256`, a bare `-scrc`, and two `-scrc` switches on `x` / `t` |
| `testChecksumsWhileExtractingAndTesting` | the digest the command path produces for an extraction equals the one for a test equals `7zz t -scrcSHA256`, and `testSummary` is nil when the hash list runs |
| `testSfxSwitchIsParsedWithAndWithoutAModule` | `-sfx`, `-sfx7zCon.sfx`, and no `-sfx` at all |
| `testSfxModuleResolution` | `formatSupportsSFX` for 7z / 7Z / zip; the default stub; a bare name; an absolute path; a missing module (→ "cannot find specified SFX module"); a text file, a 2-byte `MZ` file and a directory (→ "cannot open SFX module") |
| `testSfxArchiveIsBuiltFromTheNamedModule` | the produced `.exe` starts with `7zCon.sfx` byte for byte, is bigger than the stub, holds `readme.txt`, `7zz l` reads it, and the default stub differs from the named one |
| `testSfxFailsInsteadOfWritingSomethingElse` | `-tzip -sfx` and a missing module both fail with **nothing written** |
| `testDockDropRoutesOneArchiveToOpenAndEverythingElseToCompress` | one archive → open; two archives, a folder, an unknown file, an excluded extension → add to archive; nothing → nothing |
| `testDockDropCompressCommandIsTheFinderMenuCommand` | the verb's argv is `a <sel> -ad -saa -- <dir><name>` and parses back into an `add` command with `showDialog` and `-saa` |
| `testInfoPlistClaimsAnyItemForTheDockDropOnly` | one `public.item` + `public.folder` group, `Viewer` + `None`, no `CFBundleTypeExtensions`, and it is the last entry |

### 4.2 The real argv paths

Command mode was exercised **against the built app**, not only through the bridge: each case runs
`Mac/build/Debug/7-Zip.app/Contents/MacOS/7-Zip <argv>` in its own throwaway preferences domain
(`SEVENZIP_DEFAULTS_SUITE`) and its exit code is compared with the one `03 §2.7` prescribes. 25 cases,
**0 failures**; one case is documented below rather than counted as a pass.

```
== 03 section 2.2 / 2.7: exit codes from the real argv
  ok    a  create an archive                                       exit 0
  ok    t  test it                                                 exit 0
  ok    x  extract it                                              exit 0
  ok    u  update it                                               exit 0
  ok    d  delete a member                                         exit 0
  STUCK t  archive that does not exist                             still on screen after 40 s (expected exit 2)
  ok    a  no items at all                                         exit 7
  ok    unknown switch                                             exit 7
  ok    -i! with nothing after the marker                          exit 7
  ok    -i# map: no shared memory on macOS                         exit 7
  ok    l  unsupported command in the GUI                          exit 2
  ok    i  unsupported command in the GUI                          exit 2
  ok    -t with an unknown format                                  exit 2
== 03 section 2.2: rn
  ok    rn one pair                                                exit 0
  ok    rn odd number of names                                     exit 7
  ok    rn wildcard in the old name                                exit 7
  ok    7zz lists README.1st after rn
== 03 section 2.2: -i / -x wildcards, expanded by the engine
  ok    a -ir!*.txt (recursed wildcard)                            exit 0
  ok    7zz sees sub/big.txt and sub/deep/inner.txt, and no notes.md
  ok    a -i!* -x!*.log (exclude applied)                          exit 0
  ok    noise.log excluded
  ok    a -i! wildcard that matches nothing                        exit 7
  ok    t -ai! wildcard that matches nothing                       exit 7
  ok    t -an -ai!*.7z (archive censor)                            exit 0
  ok    t -an -ai!*.7z -ax!two.7z                                  exit 0
== 01b section 4.23: -sfx<module>
  ok    a -sfx (bundled 7z.sfx)                                    exit 0
  ok    a -sfx7zCon.sfx (named module)                             exit 0
  ok    a -sfx/nonexistent (missing module)                        exit 2
  ok    a -sfx<bogus> (not an executable)                          exit 2
  ok    a -tzip -sfx (format has no kFF_SFX)                       exit 2
  ok    named.exe starts with 7zCon.sfx byte for byte
  ok    7zz lists readme.txt inside named.exe
== 0 failure(s), 1 case(s) left a window on screen
```

The exact command lines, in the order above:

```sh
APP=Mac/build/Debug/7-Zip.app/Contents/MacOS/7-Zip
$APP a  -y  $W/plain.7z $SRC/readme.txt $SRC/notes.md      # 0
$APP t  -y  $W/plain.7z                                     # 0
$APP x  -y  -o$W/out1 $W/plain.7z                           # 0
$APP u  -y  $W/plain.7z $SRC/sub/big.txt                    # 0
$APP d  -y  $W/plain.7z big.txt                             # 0
$APP t  -y  $W/no-such.7z                                   # 2, but see below
$APP a  -y  $W/empty.7z                                     # 7  IDS_SELECT_FILES
$APP x  -y  -zzz $W/plain.7z                                # 7  unknown switch
$APP a  -y  $W/e.7z '-i!'                                   # 7  "Too short switch"
$APP a  -y  $W/e.7z '-i#nope'                               # 7  "Incorrect Map command"
$APP l  -y  $W/plain.7z                                     # 2  "Unsupported command"
$APP i  -y                                                  # 2  "Unsupported command"
$APP t  -y  -tnosuchformat $W/plain.7z                      # 2  IDS_UNSUPPORTED_ARCHIVE_TYPE
$APP rn -y  $W/rn.7z readme.txt README.1st                  # 0
$APP rn -y  $W/rn.7z only-one                               # 7  "There is no second file name..."
$APP rn -y  $W/rn.7z '*.txt' new.txt                        # 7  "Unsupported rename command:"
$APP a  -y  $W/wild.7z "-ir!$SRC/*.txt"                     # 0, stores sub/big.txt + sub/deep/inner.txt
$APP a  -y  $W/excl.7z "-i!$SRC/*" "-x!$SRC/*.log"          # 0, noise.log excluded
$APP a  -y  $W/none.7z "-i!$SRC/*.nothing"                  # 7  nothing matched -> IDS_SELECT_FILES
$APP t  -y  -an "-ai!$W/arcs-none/*.7z"                     # 7  "Cannot find archive"
$APP t  -y  -an "-ai!$W/arcs/*.7z"                          # 0  two archives, one progress window
$APP t  -y  -an "-ai!$W/arcs/*.7z" "-ax!$W/arcs/two.7z"     # 0  one archive
$APP a  -y  -sfx $W/dflt.exe $SRC/readme.txt                # 0  bundled 7z.sfx, no -ad needed
$APP a  -y  -sfx7zCon.sfx $W/named.exe $SRC/readme.txt      # 0  the named module
$APP a  -y  -sfx/nonexistent/none.sfx $W/bad.exe …          # 2  "cannot find specified SFX module"
$APP a  -y  "-sfx$W/bogus.sfx" $W/bogus.exe …               # 2  "cannot open SFX module"
$APP a  -y  -tzip -sfx $W/zip.exe $SRC/readme.txt           # 2  no kFF_SFX for zip
```

`bad.exe`, `bogus.exe` and `zip.exe` were asserted **not to exist** after their runs, which is the
whole point of item 11's "an error rather than a surprise".

**The one STUCK case, and why it is not a bug of this scope.** `t -y <archive that does not exist>`
never exits: the run collects a message ("cannot open file"), and the Progress dialog then stays open
with Cancel relabelled Close — `01b §4.17`'s "keep the window open when there were messages", which
is `CProgressDialog::MessagesDisplayed` and is **not** gated by `g_DisableUserQuestions`, so upstream
7zG behaves the same way. The exit code on the other side of that window is the right one; what an
unattended caller sees is a window. It is pre-existing, it belongs to `opsinfra`'s progress dialog
rather than to the command layer, and changing it would be a deliberate divergence from 7zG, so this
scope left it and recorded it here. The script kills the process after 40 s and reports it rather than
hanging.

**Exit code 8 cannot be provoked this way.** No argv makes the engine fail to allocate, and `-smemx`
is accepted and ignored by this port, so there is no lever. It is unit-tested arm by arm instead, and
it travels the same single code path (`SevenZipFailureLadder`) as the codes above, all of which the
real process does return.

### 4.3 UI suite

**Command mode itself is not reachable from XCUITest, and that was measured.**
`XCUIApplication.launch()` with a command word fails after ~69 s, two different ways, both observed
in a real run:

* a command that finishes by itself (`t -y <archive>`) exits before the runner can attach —
  *"Application 'com.yrambler2001.7zip' has not loaded accessibility"*;
* a command that shows a dialog (`a … -ad`, or an error box) sits in `NSApp.runModal` while still
  handling `applicationDidFinishLaunching`, so the app never becomes idle and `launch()` gives up
  with the same message.

That is why the exit codes are checked from a shell (4.2) and why the two dialogs command mode may
show are screenshotted through the **file manager**, where the same code builds them:

| screenshot | what it is |
|---|---|
| `Mac/build/screenshots/cmdmode-01-add-to-archive-dialog.png` | IDD_COMPRESS 4000 "Add to archive" — the dialog `-ad` opens, and `-ad` is exactly what a Dock drop passes (`a <selection> -ad -saa -- <dir><name>`) |
| `Mac/build/screenshots/cmdmode-02-checksum-information.png` | IDS_CHECKSUM_INFORMATION 7501 "Checksum information" with its `CRC32 checksum for data` / `... for data and names` rows — what `h` shows and what `x -scrc` / `t -scrc` now show **instead of** the test summary box |

`Mac/scripts/test.sh --ui` on the same clean tree: **37 of 37 pass** (the audit's 35 plus these two), 1143 s, and 51 screenshot attachments exported.

Two things the screenshots incidentally show, both another scope's and both already filed:
the Compress dialog is wider than the screen with its bottom button row clipped (`parity.md` B17),
and the checksum list is placed partly above the top of the screen. The Compress test therefore
closes the dialog with Escape rather than by clicking Cancel, so it does not fail for the wrong
reason while that is being fixed.

One thing the earlier UI attempt taught, kept as a comment in the test file: the window title is the
**lang string**, not the source's fallback — id 4000 is "Add to archive", while the call site reads
`Lang.text(4000, "Add to Archive")`.

### 4.4 Cross-checks against the console tool

`CPP/7zip/Bundles/Alone2/b/m_arm64/7zz` (7-Zip 26.03, arm64, built from this tree) is the reference
in five places:

1. **A produced archive** — `7zz l -slt` on the archive `a -ir!<dir>/*.txt` wrote lists
   `sub/big.txt` and `sub/deep/inner.txt` and **not** `notes.md`, which is the whole claim about
   handing censor specs to `UpdateArchive` rather than pre-expanded paths.
   (`CommandModeTests.testUpdateWithSpecsKeepsTheRelativePathsTheEngineComputes` asserts the same
   thing through the bridge and then runs `7zz t` on the result.)
2. **A checksum** — `7zz t -scrcSHA256 <archive>` prints the same SHA-256 "for data" digest the
   bridge reports for `x -scrcSHA256` and for `t -scrcSHA256`
   (`CommandModeTests.testChecksumsWhileExtractingAndTesting`), and the two commands agree with each
   other.
3. **The rename** — `7zz l -slt` after `rn readme.txt README.1st` lists `README.1st`, lists
   `notes.md` and no longer lists `readme.txt`.
4. **The self-extracting archive** — the first 194 048 bytes of the produced `named.exe` are
   `Mac/Resources/SFX/7zCon.sfx` byte for byte (`cmp`), the produced file is larger than the stub, and
   `7zz l named.exe` reads `readme.txt` out of the payload behind it. The unit test additionally
   asserts that the default stub's first 4 KiB differ from `7zCon.sfx`'s, so "the **named** module was
   used" is a real assertion and not a tautology.
5. **The exclude** — `7zz l` on the archive `a -i!<dir>/* -x!<dir>/*.log` wrote does not list
   `noise.log`.

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
7. **A failing command can leave its Progress window open.** `t -y <archive that does not exist>`
   collects a message, and the Progress dialog then stays up with Cancel relabelled Close — `01b
   §4.17`'s "keep the window open when there were messages", which is not gated by
   `g_DisableUserQuestions` upstream either. The exit code behind that window is right; an
   unattended caller still sees a window. It is `opsinfra`'s dialog, it is faithful to 7zG, and
   changing it would be a deliberate divergence, so it is recorded rather than fixed.
8. **Command mode cannot be driven by XCUITest**, measured (section 4.3). Anything about it that
   needs a running process is verified from a shell instead; anything visual is screenshotted
   through the file manager, where the same code builds the same dialogs.
9. **`-spm` is still accepted and ignored**, so the global mark mode cannot be set from the command
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
