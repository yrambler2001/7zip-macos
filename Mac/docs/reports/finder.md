# `finder` — shell integration: what was built, how it maps to Windows, what was verified

Branch `mac/finder`, worktree `.worktrees/finder`, off `macos` at `d06136d`.
Scope: `03-shell-integration-inventory.md` in full — the Explorer context menu, the `7zG.exe`
command contract, the file associations, the drag-and-drop mapping — reproduced with the macOS
mechanisms of that document's section 6. Public API: `Mac/docs/api/finder.md`.

**Summary.** The 7zG argument grammar, the `sevenzip://` transport, the Finder Sync extension, two
Quick Actions, five Services and 40 document types are implemented and build clean.
`Mac/scripts/test.sh` is **272 passed / 0 failed** (63 of them new) and the new
`FinderIntegrationTests` UI class drives the app through the exact URLs the Finder menu sends.
Both extension kinds register and enable with `pluginkit` and report `+`. What a human still has to
look at is Finder's own contextual menu — §8 lists those checks.

---

## 1. What was implemented

### 1.1 The command layer (`03 §2`) — one executor, four routes

`Mac/App/Integration/CommandExecutor.swift` is `Main2` (`GUI.cpp:137-402`) plus `WinMain`'s
exception mapping (`:408-494`). Four routes reach it and nothing else runs a command:

| Route | File | Notes |
|---|---|---|
| real `argv` | `Mac/App/CommandLineEntry.swift` | `argv[1] ∈ {a,u,d,rn,x,e,t,h,b,l,i}` → command mode |
| `sevenzip://` | `Mac/App/Integration/URLCommands.swift` | what the extensions send |
| `NSServices` | `Mac/App/Integration/ServicesProvider.swift` | no extension needed |
| document open | `URLCommands.openDocuments` via `AppDelegate+` extension | double-click, Open With, Dock drop |

* **Grammar** (`Mac/App/Integration/ArgumentGrammar.swift`): `NCommandLineParser::CParser` and
  `CArcCmdLineParser`, including the longest-prefix switch match, the five parser error strings,
  the full `kSwitchForms` table, the `r`/`w`/`m` include modifiers and the three include sources.
  Generated switches become typed fields; the ones 7zG accepts and ignores (`-slp`, `-stm`, the
  `-b*` console block, `-scs`, `-sni`, `-snoi/-snon`, …) land in `ignoredSwitches`.
* **`#map` is refused with the upstream strings** — "Incorrect Map command", "Unsupported Map data
  size", "Cannot open mapping" — so the official lang files keep working (`03 §1.5`).
* **Dialogs** follow `03 §2.4` exactly: Extract only with `-ad`, Compress only with `-ad`, the test
  summary box, the hash results list, the Benchmark window; everything else under the Progress
  dialog with `waitMode` off, which is 7zG's always-visible progress window.
* **Exit codes** are `NExitCode::EEnum`; in command mode the process really `exit()`s with them.
* **Dispatch** goes to `SZArchiveExtractor` (the engine's own `Extract()`), `SZUpdater`
  (`UpdateArchive()`), `SZHasher` (`HashCalc`) and the `extract` / `compress` / `tools` dialogs.
  Nothing about extraction, updating or hashing is reimplemented.
* `a -thash` / `t -thash` are `SZHasher.writeChecksumFile` / `verifyChecksumFile`, which is what
  `requests.md` (`tools` → `finder`) asked for.

### 1.2 The transport (`03 §1.5`, `§6.4`)

`Mac/App/Integration/CommandURL.swift` replaces the Win32 `#7zMap` shared-memory section:

* short selections → one `-aiw-!<path>` / `-iw-!<path>` per item (the `kImmediateNameID` source the
  parser already supports), with `w-` so a real name containing `*`, `?` or `[` — all legal on
  macOS — is not read as a wildcard;
* more than 16 paths or more than 2048 bytes → a UTF-8 list file `7zL-<uuid>.txt` in the sender's
  own temp directory (inside the extension container, readable by the unsandboxed app) referenced
  as `-aiw-@<path>`; the receiver deletes it, which is the `CEventSetEnd` equivalent, and only
  files matching that name are ever deleted;
* URLs: `sevenzip:///run?argv=<base64url JSON>[&tmp=…]` and `sevenzip:///settings[?show=1]`;
  `x-7zip` is registered too because `03 §6.4` spells it that way.

### 1.3 Document types and associations (`03 §3`, `api/icons.md`)

`Mac/App/Info.plist` (generated once from `FileTypes.all` + the measured system UTIs, guarded by a
unit test):

* 38 `CFBundleDocumentTypes` groups covering all **40** association extensions, each naming its
  `doc-<icon>.icns`; `CFBundleTypeRole = Editor`, `LSHandlerRank = Alternate` (`Owner` only for
  `7z`) so nothing is hijacked by installing;
* 17 extensions reuse a declared system UTI, the other 23 get a `UTImportedTypeDeclarations` entry
  `org.7-zip.<ext>-archive` (conforming to `public.data, public.archive`) with the same icon;
* one alternate-role viewer entry with the 78 further `REGISTER_ARC*` extensions so "Open With"
  lists 7-Zip for `jar xpi docx apk img qcow2 vmdk msi chm exe …`;
* `CFBundleURLTypes`, `NSServices` (five items) and the five folder/volume usage descriptions.

### 1.4 The Finder Sync extension (`03 §1`, `§6.3`)

`Mac/FinderSync/FinderSync.swift` monitors `/`, `/Volumes` and `~/Library/CloudStorage`, implements
`beginObservingDirectory` / `endObservingDirectory` / `requestBadgeIdentifier` as no-ops and never
badges. `menu(for:)` builds the tree from `Mac/App/Integration/FinderMenuModel.swift`, which is
`CZipContextMenu::QueryContextMenu` ported one to one: the same insertion order, the same
conditions, the same generated command lines, the cascaded/flat modes, the CRC SHA placement rule,
the `Options.ContextMenu` bit mask, the exclude-extension filter with the Shift relaxation, and the
`GetSubFolderNameForExtract` / `CreateArchiveName` naming. Invoking sends the command to the app
with `NSWorkspace.open`; the extension reads no file and spawns no process.

### 1.5 Quick Actions and Services (`03 §6.1`, `§6.3`)

Two `com.apple.ui-services` appexes (`Mac/QuickAction/`), because one appex is one flat Quick
Action entry: **Extract with 7-Zip** (= the context menu's `Extract to "<name>/"`, `-spe` from the
same setting) restricted by an activation predicate to `public.archive`, and **Compress with
7-Zip** (= `Add to archive…`) for any file. Five `NSServices` — Extract files…, Extract Here, Test
archive, Add to archive…, Checksum… — handed to the running app with no sandbox hop, so they work
with every extension switched off. All of them pick their command out of the same
`FinderMenuModel` by its Windows verb, so labels, naming and switches cannot drift.

### 1.6 Settings hand-off (`03 §1.3`, `§6.4`)

A sandboxed appex cannot read the app's preferences domain. The app (unsandboxed) writes a snapshot
of the five `Options.*` values into each extension's container
(`FinderSettingsBridge.push()`), on launch, on a context-menu settings change and on a language
change; the extension reads it on **every** `menu(for:)`, because Finder never announces a settings
change. `com.apple.security.temporary-exception.shared-preference.read-only` is the second path and it
does survive the ad-hoc signature (§4), so the extension can also read
`com.yrambler2001.7zip` directly if no snapshot has been written yet. The snapshot also carries the
eleven resolved menu lang strings, because the `Lang/*.txt` reader lives in `SevenZipKit`, which the
appex must not link.

---

## 2. Mapping to the Windows behaviour

| Windows (`03`) | macOS | Status |
|---|---|---|
| `7-zip.dll` `IContextMenu` / `IExplorerCommand` (§1.1, §1.8) | Finder Sync extension, same item tree | done |
| `CContextMenuInfo` (§1.3) | `IntegrationSettings`, same keys and defaults | done |
| Menu items A1…B10, C1…C13 (§1.4) | `FinderMenuModel`, same verbs and command lines | done |
| `#7zMap` selection transport (§1.5) | `-i!` / `-i@` + `sevenzip://` (§1.2 above) | done |
| `GetSubFolderNameForExtract`, `CreateArchiveName`, `ReduceString` (§1.6) | `ArchiveNaming`, cross-checked against the engine | done |
| Drop handler, right-drag menu (§1.7) | no Finder equivalent | **dropped, documented** |
| 16-item reduction, `<base>_` labels (§1.2) | not needed: `selectedItemURLs()` is complete | dropped |
| `7zG.exe` argv, dialogs, exit codes (§2) | command mode in the app, same grammar | done |
| `-seml` MAPI (§2.5) | `NSSharingService.composeEmail` + `7zE-<uuid>` temp dir, purged next run | done, async |
| `7z.dll` association list, ProgIDs, `DefaultIcon` (§3) | `CFBundleDocumentTypes` + imported UTIs + `doc-*.icns` | done |
| Options ▸ System "All users" column (§3.4) | no HKLM equivalent on macOS | dropped |
| `7zFM.exe "%1"` (§3.3) | `application(_:open:)`, one window per archive | done |

---

## 3. Does the Options ▸ System page's association switching work against these declarations?

**Yes, and the plist is what made 23 of the 40 rows usable.** That page (`options` scope) calls
`NSWorkspace.setDefaultApplication(at:toOpen:)` with `SevenZipFileType.utType`, which is
`systemUTType ?? UTType(importedTypeIdentifier)`. Before this scope existed,
`UTType("org.7-zip.rar-archive")` was undeclared, so `utType` was `nil` for `rar`, `001`, `lzma`,
`bzip2`, `tpz`, `zst`, `tzst`, `taz`, `lzh`, `lha`, `rpm`, `deb`, `arj`, `vhd`, `vhdx`, `wim`,
`swm`, `esd`, `fat`, `ntfs`, `hfs`, `squashfs`, `apfs` and the page showed those rows as not
associable. Measured after this build was registered: `UTType(filenameExtension:)` returns a
declared, non-`dyn.` identifier for **all 40**, so every row is now toggleable and
`urlForApplication(toOpen:)` reports the current handler.

Two caveats worth keeping: Launch Services must have seen the bundle once
(`LaunchServicesRegistration.registerIfNeeded()` runs `lsregister -f` plus
`NSUpdateDynamicServices()` on first launch per bundle path and version), and macOS has no
"All users" scope, so the Windows HKLM column stays absent. One side effect to be aware of: the
unit test that used to derive "which extensions need an imported type" from `systemUTType` now
cannot, because after registration 7-Zip's *own* types answer that query — the test checks the
plist against itself instead.

---

## 4. Two build-system traps found (worth knowing for the whole project)

1. **`ENABLE_APP_SANDBOX` overrides the entitlements file.** Xcode 15+ drives
   `com.apple.security.app-sandbox` from that build setting and *strips* the key from
   `CODE_SIGN_ENTITLEMENTS` when it is `NO` (the default). The appexes were therefore signed
   unsandboxed — which the system refuses to load — while the entitlements file looked correct.
   `ENABLE_APP_SANDBOX: YES` is now set on all three appex targets.
2. **XcodeGen owns an `entitlements:` file.** With `entitlements: { path: … }` and no
   `properties:`, XcodeGen rewrites that file with an empty `<dict/>` on every run, silently
   discarding hand-written contents (this is what the Wave 1 `FinderSync.entitlements` was). The
   keys now live under `entitlements.properties` in `project.yml`; the two `.entitlements` files
   are generated artefacts.
3. **An incremental build re-signs nothing.** While chasing (1) and (2) the appex kept its old
   signature, so `codesign -d --entitlements` reported an entitlement set that no longer matched
   the file and sent the investigation down a wrong path ("ad-hoc signing strips
   `temporary-exception.*`"). On the final **clean** build all three appexes carry
   `com.apple.security.app-sandbox`, `com.apple.security.get-task-allow` **and**
   `com.apple.security.temporary-exception.shared-preference.read-only` — verified. Lesson: verify
   an entitlement change only after `rm -rf Mac/build`.

---

## 5. What was verified, and how

### 5.1 Build and unit tests

```
Mac/scripts/build.sh     ** BUILD SUCCEEDED **, 0 warnings from Mac/ sources
Mac/scripts/test.sh      272 passed, 0 failed   (209 before + 63 new)
```

`Mac/Tests/SevenZipKitTests/FinderCommandTests.swift` — 63 cases over the five shared files, which
are symlinked into the test target so the app, both appex kinds and the tests compile the same
source:

* every command word (`a u d t e x l b i h rn`), the group predicates, the default path mode, and
  the two commands 7zG refuses;
* every generated switch (`-o -ad -spe[-] -snz[0-2] -sa{s,e,a} -ao{a,s,u,t} -seml[.][addr] -scrc
  -t -m -p -y -spf[2] -spo -x!td/tf -sn{l,h,s}[-] -sdel -stl -ssp -ssw -sse -spd -sni --`) and the
  accepted-and-ignored list;
* the five parser error messages, and the archive-name rules (`-an`, "Cannot find archive name",
  "Archive name cannot by empty");
* the three include sources, including a real list file with a BOM, CRLF, quotes and blanks, the
  missing-list-file message, and the three `#map` refusals;
* the naming rules **cross-checked against the engine**: `subfolderNameForExtract` against
  `SZArchiveExtractor.subfolderName` for 15 names, `correctFileSystemName` against
  `SZArchiveExtractor.correctFileName`, and `createArchiveName` against
  `SZUpdater.archiveBaseName` for six selections, plus the `_<N>` collision rules and the isHash
  variant;
* the inline/list-file threshold both ways, the round trip back through the parser, the deletion of
  the generated list file and the refusal to delete a foreign one;
* the URL round trip, the alternate scheme, non-ASCII and spaces, and the rejected URLs;
* the menu tree: the exact 13-item cascaded list for one archive, the flat mode's leading
  separator, the CRC placement rule, the folder and excluded-extension cases with and without
  Shift, the multi-selection `*` sub-folder and parent-folder archive name, the flag mask, the
  drop-mode hiding of the e-mail items, and the `Add to "<name>.7z"` hide rule;
* **the generated command line of all 15 distinct menu commands**, compared character by character
  with what `CompressCall.cpp` builds, and every one of them parsed back by the grammar;
* the `Info.plist` declarations: all 40 extensions with the right `doc-*` icon and a UTI, the 23
  imported types with icon, tag and conformance, the URL schemes, the five Services, the usage
  descriptions, the two Quick Action plists and the Finder Sync sandbox entitlement.

### 5.2 The real argv route (transcript)

With the repository app-launch lock held and `SEVENZIP_DEFAULTS_SUITE=7zip-finder`, the built
binary was run with real command lines:

```
x  -o<tmp>/out/    -y -an -aiw-!Fixtures/test.7z      exit 0, 4 files (sub/deep/inner.txt included)
x  -o<tmp>/multi/*/ -y -an -aiw-!test.7z -aiw-!test.zip exit 0, one folder per archive name
e  -o<tmp>/nopaths/ -y -an -aiw-!test.7z              exit 0, 4 files, paths dropped
a  -iw-!a.txt -iw-!b.txt -t7z -sae -y -- <tmp>/made.7z exit 0, 172-byte archive
a  -iw-!a.txt -thash -sae -y -- <tmp>/a.txt.sha256    exit 0, "5891b5b5…be03  a.txt"
a  -iw-@<list of 30 files> -t7z -sae -y -- many.7z    exit 0, list file deleted afterwards
l  -y test.7z                                          exit 2  ("Unsupported command")
x  -zzz -y -an -aiw-!test.7z                           exit 7  ("Unknown switch:")
```

Eliminate-duplicate-root, on an archive whose single root folder is `dup`:

```
x -o<tmp>/plain/dup/       → plain/dup/dup/inner.txt     (nested, as Windows without -spe)
x -o<tmp>/elim/dup/ -spe   → elim/dup/inner.txt          (root eliminated)
```

### 5.3 The URL route (transcript)

With the app already running, `open sevenzip:///run?argv=…` (which is literally what
`NSWorkspace.open` in the extension does):

* Extract Here → the four files appeared, the app stayed alive;
* `Extract to "<name>/"` with `-spe` → the expected tree;
* quick add with a 25-file selection through a list file → archive written, **list file deleted**;
* the open-archive form (`argv = ["<path>"]`) → handled, app alive;
* `sevenzip:///settings` → the snapshot was rewritten in the extension container;
* `open -a 7-Zip <archive>` (the document-open path) → handled, app alive.

### 5.4 The settings hand-off

Launching the app wrote
`~/Library/Containers/com.yrambler2001.7zip.{FinderSync,QuickActionExtract,QuickActionCompress}/Data/Library/Preferences/com.yrambler2001.7zip.integration.plist`
with `Options.CascadedMenu=true`, `Options.ElimDupExtract=true`, `Options.MenuIcons=false`,
`Options.WriteZoneIdExtract=-1`, `Options.ContextMenu=-1` — the documented defaults.

### 5.5 Extension registration

```
pluginkit -a  …/7-Zip.app/Contents/PlugIns/{FinderSync,QuickActionExtract,QuickActionCompress}.appex
pluginkit -e use -i com.yrambler2001.7zip.{FinderSync,QuickActionExtract,QuickActionCompress}

pluginkit -m -p com.apple.FinderSync -v
+    com.yrambler2001.7zip.FinderSync(26.03)  D381F566-…  …/PlugIns/FinderSync.appex
 (1 plug-in)

pluginkit -m -p com.apple.ui-services -v | grep 7zip
+    com.yrambler2001.7zip.QuickActionCompress(26.03)  7B2DDF98-…
+    com.yrambler2001.7zip.QuickActionExtract(26.03)   E022FE98-…
```

All three carry `+` (enabled) and none carries `!` (blocked). Their sandbox containers exist, which
only happens after the system has actually started the extension process. `codesign -d --entitlements` on each appex of the clean build reports
`com.apple.security.app-sandbox`, `get-task-allow` and
`temporary-exception.shared-preference.read-only`.

### 5.6 Association handlers, measured

After the build was registered, `UTType(filenameExtension:)` returns a declared, non-`dyn.`
identifier for **all 40** extensions (17 system types, 23 `org.7-zip.<ext>-archive`), and
`NSWorkspace.urlForApplication(toOpen:)` reports `7-Zip.app` as the handler for the 23 types
nothing else claims (`rar`, `arj`, `lzh`, `wim`, `apfs`, `squashfs`, …) while leaving
`public.zip-archive` with Archive Utility and `com.apple.disk-image-udif` with DiskImageMounter,
which is the intended `LSHandlerRank = Alternate` behaviour.

### 5.7 UI tests

`Mac/Tests/UITests/FinderIntegrationTests.swift` (new, 10 cases) launches the app through the
harness and then sends exactly the URLs the Finder menu items build, asserting what the app does:
the Extract dialog for `-ad`, the Compress dialog for `a -ad`, the checksum results list for
`h -scrcSHA256`, the `IDS_SELECT_FILES 3015` refusal when a folder is in an extract selection, the
"Unsupported command" and "Unknown switch:" boxes, a silent Extract Here that just produces files,
the open-archive form listing the archive in panel 0 (with and without `-t7z`), and command mode
from a real `argv` showing only the command's dialog and no file-manager window. Screenshots are
attached as `Mac/docs/reports/screenshots/finder-*.png` (ten files). Result: **10 passed,
0 failed**.

---

## 6. Deliberate differences from Windows

1. **No drop handler.** `Directory|Drive\shellex\DragDropHandlers` has no Finder equivalent. The
   `_dropMode` rules (drop target as `<dir>`, e-mail items hidden) are implemented in the model for
   the Dock-drop path and the tests, but Finder never offers a right-drag menu.
2. **`-y` silences boxes from the first token.** Upstream sets `g_DisableUserQuestions` only after
   `Parse1`, so a switch-syntax error still opens a box there.
3. **No `&` doubling** in menu labels (macOS menus have no `&` mnemonic); `ReduceString`'s
   64-character limit is kept.
4. **One process.** No `7zG.app` helper: `argv[1] ∈ {a,u,d,rn,x,e,t,h,b}` puts the main app into
   command mode (window ordered out, real exit code). A URL command runs inside the running file
   manager, which is why the extension uses `NSWorkspace.open(URL)` rather than
   `openApplication(arguments:)` — one instance, no duplicate window.
5. **`rn` is refused** ("Unsupported command"): it needs old/new pairs, which no shell command
   generates.
6. **Two Quick Action appexes**, because one appex is one flat entry in that extension point.
7. **Menu labels come from a snapshot**, not from the lang file directly (§1.6).

---

## 7. Known gaps and follow-ups

* **`-scrc` on `x` / `t` (hash while extracting, `03 §2.6`) is parsed but not yet acted on.** The
  grammar side is complete — `SevenZipCommandLine.hashMethods` is filled for every command — but
  the bridge properties that would carry it, `SZExtractOptions.hashMethods` and
  `SZExtractResult.hashResults`, exist on `macos` (added by `mac/cleanup`) and **not** on
  `mac/finder`, which was branched from `d06136d`. Code against them would not compile here and the
  rules forbid merging, so the work is written up as an exact three-line recipe in `requests.md`
  for the next `finder` agent to apply after the merge. Nothing else in the grammar is blocked by
  it.
* No `Contents/Helpers/7zG.app` (`03 §6.4` variant (a)); command mode covers the same argv
  contract. Listed as still-open in `PROGRESS.md`.
* Dropping on the Dock icon **opens** the archive instead of offering "Add to archive…"
  (`03 §6.2`); still-open in `PROGRESS.md`.
* `-snz` reaches the engine but `ReadZoneFile_Of_BaseFile` is `_WIN32`-only, so a plain extraction
  still writes no `com.apple.quarantine`; `SZTempOpen.applyQuarantine` is the helper that would
  post-process it (`extract` scope's gap).
* A failed hand-off (`NSWorkspace.open` returning false) is silent: a Finder Sync appex has no
  reliable way to show an alert.
* The Quick Actions use `NSActionTemplate` as their preview icon; a bundled asset would look better.
* The README's enabling instructions belong to the `packaging` scope; `Mac/docs/api/finder.md` §7
  has the full text to copy.

---

## 8. Manual checks for the user

None of these can be automated here: Terminal has no Automation permission on this machine, an
`osascript` that drives Finder *hangs* on the consent dialog rather than failing, and
`screencapture` is denied (`Mac/docs/reports/vmcheck.md` §5, §7). Everything below needs a human in
front of Finder. The app and both extensions are already registered and enabled, so step 1 only
confirms it.

1. **Confirm the extensions are on.** Open *System Settings ▸ General ▸ Login Items & Extensions*.
   Under **File Providers** there must be a "7-Zip Finder Extension" switch, on; under **Finder**
   there must be "Extract with 7-Zip" and "Compress with 7-Zip", on. If a switch is missing, run
   `pluginkit -m -p com.apple.FinderSync -v` — a `+` means enabled, a `!` means blocked (an MDM
   profile denying public extension points is the usual cause).
2. **Cascaded context menu.** In Finder, select `Mac/Tests/Fixtures/test.7z`, right-click, and check
   that a **7-Zip** submenu appears with exactly these items, in this order: Open archive,
   Open archive ▸ (`*`, `#`, `#:e`, `7z`, `zip`, `cab`, `rar`), Extract files…, Extract Here,
   `Extract to "test/"`, Test archive, Add to archive…, Compress and email…, `Add to "test_2.7z"`,
   `Compress to "test_2.7z" and email`, `Add to "test_2.zip"`,
   `Compress to "test_2.zip" and email`, and **CRC SHA ▸** with CRC-32, CRC-64, XXH64, MD5, SHA-1,
   SHA-256, SHA-384, SHA-512, SHA3-256, BLAKE2sp, `*`, a separator,
   `SHA-256 -> test.7z.sha256`, `Test archive : Checksum`.
3. **Flat mode.** In 7-Zip ▸ Settings ▸ 7-Zip, turn *Cascaded context menu* off, click OK, then
   right-click the same file again: the items must now sit **inline** after a separator, with
   **CRC SHA** at the top level next to them, and no "7-Zip" parent item. Turn it back on.
   *(Please take a screenshot of the menu in both modes — this is the one piece of evidence the
   automated run cannot produce.)*
4. **Icons in the menu.** Turn *Icons in context menu* on in the same page and re-open the menu:
   every 7-Zip item should carry the app icon at 16 pt.
5. **The item check-list.** Untick a few entries in *Context menu items* (for example everything but
   "Extract Here") and re-open the menu: only the ticked items may appear. Re-tick them afterwards.
6. **Folder selection.** Right-click a *folder*: the extract group (Extract files…, Extract Here,
   Extract to, Test archive) and Open archive must be **absent**; Add to archive…, the two quick
   Add items and CRC SHA must be present.
7. **Shift relaxation.** Right-click a `.txt` file: no extract items. Hold **Shift** while
   right-clicking the same file: Extract files… / Extract Here / Extract to / Test archive appear
   (Open archive still does not — Windows does not relax block A either).
8. **Run one command each.** From the menu, run *Extract Here* on `test.7z` (four files appear next
   to it), *Extract files…* (the Extract dialog opens pre-filled with `…/test/`), *Add to
   archive…* (the Compress dialog opens with `test_2.7z`), and *CRC SHA ▸ SHA-256* (the checksum
   list opens).
9. **Many files.** Select more than 16 files, right-click, and run *CRC SHA ▸ CRC-32*: the selection
   travels through a temporary list file; the results list must show every file, and
   `ls ~/Library/Containers/com.yrambler2001.7zip.FinderSync/Data/tmp` must be empty afterwards
   (the app deletes the list file).
10. **Toolbar button.** In a Finder window, add the 7-Zip toolbar item (View ▸ Customize Toolbar…)
    and click it with something selected: the same menu must appear.
11. **Quick Actions.** Select an archive and use *Quick Actions ▸ Extract with 7-Zip* from the
    contextual menu or the Preview pane; then select any file and use *Compress with 7-Zip*.
12. **Services.** With a file selected in Finder, open *Services* in the contextual menu (or the
    7-Zip ▸ Services menu) and check the five "7-Zip: …" entries are listed and work. If they are
    missing, they are switched on per item in *System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸
    Services*.
13. **Icons and Open With.** In Finder, look at `Mac/Tests/Fixtures/`: `test.7z`, `test.zip`,
    `test.tar.gz` and `test.tar.xz` should show the 7-Zip document icons (blue page with the format
    band). Right-click one ▸ *Open With* must list 7-Zip. Double-clicking a `.7z` should open it in
    7-Zip if 7-Zip is the chosen handler.
14. **The Associate page.** Open 7-Zip ▸ Settings ▸ System: all 40 rows must be toggleable (none
    greyed out as "no type"), and ticking `rar` then re-opening the page must show 7-Zip as the
    handler.
15. **Mail.** Run *Compress and email…* on a small file: the Compress dialog appears, and after OK
    the default mail client opens a new message with the archive attached. (The archive is left in
    `/tmp/7zE-<uuid>/` and purged on the next compress-and-email; macOS gives no "sent" callback.)

To undo the registration afterwards:
`pluginkit -r <path to each .appex>` (or simply delete the build directory and run
`lsregister -kill -r -domain local -domain user`).
