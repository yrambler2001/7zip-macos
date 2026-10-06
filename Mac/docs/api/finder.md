# `finder` — shell integration: the command layer, Finder Sync, Quick Actions, Services, document types

What this scope exposes and what the other scopes may reuse. Code against this file; you do not
need to read the sources.

Parity references: `03-shell-integration-inventory.md` sections 1 (the Explorer context menu), 2
(the `7zG.exe` contract), 3 (file associations), 6 (the macOS mapping) and 7 (the current state of
the extension points); `01-fm-feature-inventory.md` section 9 #1, #22, #23, #32;
`Mac/docs/api/icons.md` (the document icons), `Mac/docs/api/options.md` (the `Options.*` settings).

---

## 1. One executor, four routes

Everything funnels into **`CommandExecutor.run(argv:temporaryFiles:parentWindow:)`**, which is
`Main2` (`CPP/7zip/UI/GUI/GUI.cpp:137-402`) plus `WinMain`'s exception mapping (`:408-494`). It
returns a `SevenZipExitCode` and must be called on the main thread.

| Route | Entry point | Who uses it |
|---|---|---|
| real `argv` | `SevenZipCommandLineEntry.runLaunchCommandIfNeeded()` | a terminal, `open --args`, `NSWorkspace.OpenConfiguration.arguments` |
| `sevenzip://` URL | `URLCommands.handle(_:)` | the Finder Sync extension, the two Quick Actions, AppleScript, `open` |
| `NSServices` | `ServicesProvider` (`NSApp.servicesProvider`) | Finder's Services submenu, any app's Services menu |
| document open | `URLCommands.openDocuments(_:)` | double-click, Open With, a drop on the Dock icon |

```swift
// Anything a scope wants to run as if 7zG had been launched with it:
let code = CommandExecutor.run(argv: ["x", "-o/tmp/out/", "-y", "-an", "-aiw-!/tmp/a.7z"])

// The 7zFM shape is recognised too (the first token is a path, not a command word):
CommandExecutor.openInFileManager(paths: ["/tmp/a.7z"], formatHint: "7z")
```

`FinderIntegration.install()` is called once from `MainMenu.build()` (the one additive line this
scope adds to a shared file). It registers the Services provider, runs a launch command line, does
the one-time Launch Services registration and keeps the extensions' settings snapshot up to date.

### 1.1 Exit codes

`SevenZipExitCode` is `NExitCode::EEnum` (`ExitCode.h:10-21`): `.success` 0, `.warning` 1
(failed files), `.fatalError` 2, `.userError` 7 (command-line syntax), `.memoryError` 8,
`.userBreak` 255 (`E_ABORT`, silent). In `argv` mode the process really exits with that code.

### 1.2 Which dialog appears

Exactly as `03 section 2.4`: the **Extract** dialog only with `-ad`, the **Compress** dialog only
with `-ad`, the test summary box after a clean `t`, the hash results list after `h`, the Benchmark
window for `b`. Everything else runs under the Progress dialog (`OperationRunner`, `waitMode` off,
so 7zG's always-visible progress window is reproduced). Several archives share one progress window
and `-o` may contain `*`, which the engine replaces per archive (`OutDirMode = k_ReplaceAsterisk`).

---

## 2. `SevenZipArguments` — the 7zG grammar (Foundation only)

`Mac/App/Integration/ArgumentGrammar.swift`. `CArcCmdLineParser` and
`NCommandLineParser::CParser`, ported with their error strings so the official `Lang/*.txt` files
keep working.

```swift
let command = try SevenZipArguments.parse(["x", "-o/tmp/", "-spe", "-an", "-aiw-!/tmp/a.7z"])
command.command                 // .extractFull  (SevenZipCommandType, "audtexlbih" + "rn")
command.outputDirectory         // "/tmp/"       (-o, one trailing separator)
command.eliminateDuplicateRoot  // true          (-spe / -spe- / absent = nil)
command.resolvedArchivePaths    // the -ai sources (+ the archive name unless -an)
command.resolvedItemPaths       // the -i sources + the positional paths
command.consumedListFiles       // the -i@/-ai@ files the receiver deletes
command.ignoredSwitches         // ["-slp", "-bso", ...] accepted for parity, no effect
```

`SevenZipArgumentError(message:line:)` carries the upstream text and the offending token; its
`description` is the two-line box `CMessagePathException` produces, and the executor turns it into
exit code 7.

Every switch of `03 section 2.2` is accepted. Honoured: `-ad -ao{a,s,u,t} -t -stx -m -o -w -i -x
-ai -ax -an -u -v -r -sfx -seml[.][addr] -scrc -shd -smemx -si -so -sa{s,e,a} -spd -spe[-] -spf[2]
-spo{d,c,r} -snh -snl -sns -snz[0-2] -sdel -stl -ssp -ssw -sse -sni -p -y --`. Accepted and
ignored: `-? -h --help -ba -bd -bt -bb -bso -bse -bsp -slp -stm -scs -scc -slt -slf -slsl -slmu
-snoi -snon -snr -snc -snt -snld -spm -ssc`.

**The three include sources** (`03 section 1.5`): `-i!<name>` immediate, `-i@<listfile>` (UTF-8,
BOMs skipped, CR/LF/CRLF separated, `Trim()`, one pair of quotes stripped, empties dropped), and
`-i#<map>`, the Win32 shared-memory section, which cannot exist here and is rejected with the
original strings — `"Incorrect Map command"`, `"Unsupported Map data size"`, `"Cannot open
mapping"`. `SevenZipArguments.mapError(_:)` is the shape validator on its own.

---

## 3. `ArchiveNaming` — the pure naming code (Foundation only)

`Mac/App/Integration/ArchiveNaming.swift`, ported verbatim from the Explorer handler so the
sandboxed extension can compute labels and target paths without the engine. Cross-checked against
the engine in `FinderCommandTests`.

```swift
ArchiveNaming.subfolderNameForExtract("foo.7z.001")      // "foo"    GetSubFolderNameForExtract
ArchiveNaming.correctFileSystemName("a/b")               // "a_b"    Get_Correct_FsFile_Name
ArchiveNaming.createArchiveName(paths: p, isHash: false) // CreateArchiveName, with the _<N> rule
ArchiveNaming.reduceString(label)                        // 64 chars with " ... " in the middle
ArchiveNaming.needsExtract(name: "notes.txt")            // false: kExtractExcludeExtensions (113)
ArchiveNaming.openTypes                                  // ["", "*", "#", "#:e", "7z", …]
```

---

## 4. `FinderMenuModel` — `QueryContextMenu` as a value tree (Foundation only)

`Mac/App/Integration/FinderMenuModel.swift`. One pass, the same insertion order and conditions as
`ContextMenu.cpp:585-1176`. The extension turns the tree into an `NSMenu`; the tests assert the
tree, so the whole item set is covered without Finder.

```swift
let selection = FinderSelection(urls: FIFinderSyncController.default().selectedItemURLs() ?? [])
let settings  = IntegrationSettings.current(extensionBundleID: SevenZipBundle.finderSync)
let nodes     = FinderMenuModel.build(selection: selection, settings: settings,
                                     extendedVerbs: NSEvent.modifierFlags.contains(.shift))

// Pick one command by its Windows verb (what the Services and Quick Actions do):
let command = FinderMenuModel.command(verb: "SevenZipExtractHere", selection: selection)
let built   = command!.argv(for: selection.paths)   // (argv, temporaryFiles)
```

`FinderSelection` needs no file access: Finder hands out directory URLs with a trailing slash, so
`URL.hasDirectoryPath` **is** `fi0.IsDir()` / `_attribs.FirstDirIndex`. `dropPath` models the
right-drag drop handler (`03 section 1.7`), which no Finder mechanism reaches but which the model
supports for the Dock-drop path and for the tests.

### 4.1 The items, with the command each generates

`<dir>` = the first item's folder (or the drop target), `<spec>` = `GetSubFolderNameForExtract` or
`*` for a multi-selection, `<name>` = `CreateArchiveName`, `SEL` = the selection switches of §5.

| Verb | Label (lang ID) | Condition | argv |
|---|---|---|---|
| `SevenZipOpen` | Open archive (2322) | one file, extension not excluded, `kOpen` | `<file>` |
| `SevenZip.Open.<type>` | `*` `#` `#:e` `7z` `zip` `cab` `rar` | + `kOpenAs` | `<file> -t<type>` |
| `SevenZipExtract` | Extract files… (2323) | `needExtract`, `kExtract` | `x -o<dir><spec>/ [-snzN] -ad` + SEL |
| `SevenZipExtractHere` | Extract Here (2326) | `needExtract`, `kExtractHere` | `x -o<dir> [-snzN]` + SEL |
| `SevenZipExtractTo` | Extract to "<spec>/" (2327) | `needExtract`, `kExtractTo` | `x -o<dir><spec>/ [-spe] [-snzN]` + SEL |
| `SevenZipTest` | Test archive (2325) | `needExtract`, `kTest` | `t` + SEL |
| `SevenZipCompress` | Add to archive… (2324) | `kCompress` | `a` + SEL + `-ad -saa -- <dir><name>` |
| `SevenZipCompressEmail` | Compress and email… (2329) | not drop mode, `kCompressEmail` | `a` + SEL + `-seml. -ad -saa -- <name>` |
| `SevenZipCompressTo7z` | Add to "<name>.7z" (2328) | name ≠ first item's, `kCompressTo7z` | `a` + SEL + `-t7z -sae -- <dir><name>.7z` |
| `SevenZipCompressTo7zEmail` | Compress to "<name>.7z" and email (2330) | not drop mode | `a` + SEL + `-t7z -seml. -sae -- <name>.7z` |
| `SevenZipCompressToZip` | Add to "<name>.zip" (2328) | name ≠ first item's | `a` + SEL + `-tzip -sae -- <dir><name>.zip` |
| `SevenZipCompressToZipEmail` | Compress to "<name>.zip" and email (2330) | not drop mode | `a` + SEL + `-tzip -seml. -sae -- <name>.zip` |
| `SevenZip.Checksum.Calc.<M>` | CRC-32 … BLAKE2sp, `*` | any selection, `kCRC`\|`kCRC_Cascaded` | `h -scrc<M>` + SEL |
| `SevenZip.Checksum.Generate.SHA256` | SHA-256 -> `<hname>.sha256` | same | `a` + SEL + `-thash -sae -- <dir><hname>.sha256` |
| `SevenZip.Checksum.Test.Hash` | Test archive : Checksum | same | `t -thash` + SEL |

Nesting: cascaded mode puts A1…B10 in one **7-Zip** submenu and `CRC SHA` inside it when
`kCRC_Cascaded` is set, else beside it; flat mode inserts a separator and the items inline
(`ContextMenu.cpp:667-675`, `:1013-1069`).

---

## 5. `CommandURL` — the selection transport and the URL scheme (Foundation only)

`Mac/App/Integration/CommandURL.swift`, the replacement for the `#7zMap` shared-memory section.

```swift
// Switches that carry a selection. Short selections stay inline; long ones get a list file.
let sel = CommandURL.selectionArguments(paths: paths, kind: .archives)   // or .items
sel.arguments        // ["-an", "-aiw-!/a.7z", …]   or   ["-an", "-aiw-@/…/7zL-<uuid>.txt"]
sel.temporaryFiles   // the list file, to be named in the URL so the receiver deletes it

let url = CommandURL.url(argv: argv, temporaryFiles: sel.temporaryFiles)
switch try CommandURL.parse(url) {
case .run(let argv, let temporaryFiles): …
case .settings(let show): …
}
```

* Threshold: more than **16 paths** (`k_Explorer_NumReducedItems`) or more than **2048 bytes**.
* The `w-` postfix (`-aiw-!`, `-iw-@`) switches wildcard matching **off** so a real file name
  containing `*`, `?` or `[` — all legal on macOS — is not read as a pattern. Upstream leaves
  `ISWITCH_NO_WILDCARD_POSTFIX` empty only because Windows forbids those characters.
* The list file is UTF-8, one path per line, named `7zL-<uuid>.txt`, and written into the
  **sender's own** temp directory (inside the extension's container, which the unsandboxed app can
  read). `CommandURL.removeTemporaryFiles(_:)` deletes only files matching that name, so a
  hand-written `-i@list` is never destroyed. The executor deletes both the files named in the URL
  and the ones the parser consumed.
* URL shapes: `sevenzip:///run?argv=<base64url JSON array>[&tmp=<base64url JSON array>]` and
  `sevenzip:///settings[?show=1]`. `x-7zip` is registered as well, because `03 section 6.4` spells
  the scheme that way.

---

## 6. `IntegrationSettings` — the five `Options.*` values inside a sandbox

`Mac/App/Integration/IntegrationSettings.swift`. `CContextMenuInfo` (`03 section 1.3`) with the
documented defaults: `cascadedMenu` **true**, `menuIcons` false, `eliminateDuplicateRoot` **true**,
`writeZoneIdExtract` -1, `flags` = every item.

```swift
IntegrationSettings.current(extensionBundleID: SevenZipBundle.finderSync)
IntegrationSettings.loadFromPreferences()          // the app's own domain
FinderSettingsBridge.push()                        // app -> every extension container
FinderSettingsBridge.snapshot()                    // what push() writes, from `Settings`
```

Two ways in, tried in order:

1. the **snapshot** the app writes into each extension's container
   (`~/Library/Containers/<appex id>/Data/Library/Preferences/com.yrambler2001.7zip.integration.plist`).
   The app is unsandboxed, so it can write there; the extension can always read its own container.
   This is the path that works in an ad-hoc build, and it also carries the resolved lang texts (see
   §9 "Menu labels").
2. `CFPreferencesCopyAppValue` on `SevenZipBundle.preferencesDomain`, which follows
   `SEVENZIP_DEFAULTS_SUITE` exactly as `NMacPrefs::ApplicationID()` does. Inside the sandbox this
   needs `com.apple.security.temporary-exception.shared-preference.read-only`, which the appex
   declares and which does survive the ad-hoc signature (verified on a clean build — see §8).

The app pushes on launch, on `Settings.Group.contextMenu` and on a language change; the extension
re-reads on **every** `menu(for:)`, because Finder never tells an extension that settings changed.

`ContextMenuItemFlags` duplicates `Settings.ContextMenuFlags`'s bits for code that must not link
the bridge; a test asserts the two agree.

---

## 7. What the extensions are, and how to turn them on

| Bundle | Extension point | Turned on in | Enables |
|---|---|---|---|
| `com.yrambler2001.7zip.FinderSync` | `com.apple.FinderSync` | System Settings ▸ General ▸ Login Items & Extensions ▸ **File Providers** (15.2+) | the whole 7-Zip submenu and the Finder toolbar button |
| `com.yrambler2001.7zip.QuickActionExtract` | `com.apple.ui-services` | … ▸ **Finder** | "Extract with 7-Zip" (= `Extract to "<name>/"`) |
| `com.yrambler2001.7zip.QuickActionCompress` | `com.apple.ui-services` | … ▸ **Finder** | "Compress with 7-Zip" (= `Add to archive…`) |
| the app itself | `NSServices` | System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ **Services** | the five "7-Zip: …" items, with no extension enabled |

```sh
APP=/Applications/7-Zip.app          # or Mac/build/Debug/7-Zip.app
pluginkit -a "$APP/Contents/PlugIns/FinderSync.appex"
pluginkit -a "$APP/Contents/PlugIns/QuickActionExtract.appex"
pluginkit -a "$APP/Contents/PlugIns/QuickActionCompress.appex"
pluginkit -e use -i com.yrambler2001.7zip.FinderSync
pluginkit -e use -i com.yrambler2001.7zip.QuickActionExtract
pluginkit -e use -i com.yrambler2001.7zip.QuickActionCompress
pluginkit -m -p com.apple.FinderSync -v        # `+` enabled, `-` disabled, `!` blocked
pluginkit -m -p com.apple.ui-services -v | grep 7zip
```

If Finder never spawns `FinderSyncExtensionHost`, reset Launch Services
(`lsregister -kill -r -domain local -domain user`) or test on a clean VM; an MDM profile that
denies public extension points blocks the extension silently (`03 section 7`). The Options ▸ 7-Zip
page (`options` scope) already shows the `pluginkit` state and the enabling command.

`LaunchServicesRegistration.registerIfNeeded()` runs `lsregister -f <bundle>` plus
`NSUpdateDynamicServices()` once per bundle path and version, so the document types, the URL scheme
and the Services appear after a build without a manual step. `LaunchServicesRegistration.register()`
forces it.

---

## 8. Signing and sandboxing

* Both appex kinds are sandboxed (`com.apple.security.app-sandbox`). An unsandboxed appex is
  refused by the system.
* **`ENABLE_APP_SANDBOX: YES` is required in `project.yml`.** Xcode 15+ drives that one entitlement
  from the build setting and *strips* the key from `CODE_SIGN_ENTITLEMENTS` when the setting is NO,
  which silently produced an unsandboxed, non-loading appex.
* **XcodeGen owns the two entitlements files.** They are listed under `entitlements.properties`, so
  `Mac/FinderSync/FinderSync.entitlements` and `Mac/QuickAction/QuickAction.entitlements` are
  generated artefacts — edit `project.yml`, not the plists. (With only a `path:` and no
  `properties:`, XcodeGen overwrites them with an empty dict on every run.)
* `com.apple.security.temporary-exception.shared-preference.read-only` **does** survive the ad-hoc
  signature. Verify entitlements only after `rm -rf Mac/build`: an incremental build does not
  re-sign the appex, so `codesign -d --entitlements` keeps reporting the previous set.
* No App Group: macOS 15+ rejects a group identifier that is not prefixed by a Team ID, and this
  build has no Team ID.
* The host app stays unsandboxed and declares `NSDesktopFolderUsageDescription`,
  `NSDocumentsFolderUsageDescription`, `NSDownloadsFolderUsageDescription`,
  `NSRemovableVolumesUsageDescription` and `NSNetworkVolumesUsageDescription`.

---

## 9. Document types and associations

`Mac/App/Info.plist` declares:

* **38 `CFBundleDocumentTypes` groups** covering all **40** association extensions
  (`requests.md`: 40, not the 39 of `03 section 3.1`), one per UTI, each with
  `CFBundleTypeIconFile = doc-<icon>` from `Mac/docs/api/icons.md`, `CFBundleTypeRole = Editor` and
  `LSHandlerRank = Alternate` (`Owner` for `7z`, the one type macOS itself names
  `org.7-zip.7-zip-archive`). 17 extensions reuse a declared system UTI
  (`public.zip-archive`, `com.microsoft.cab`, `public.iso-image`, `org.tukaani.xz-archive`,
  `org.tukaani.tar-xz-archive`, `public.tar-archive`, `public.cpio-archive`,
  `public.bzip2-archive`, `public.tar-bzip2-archive`, `org.gnu.gnu-zip-archive`,
  `org.gnu.gnu-zip-tar-archive`, `public.z-archive`, `com.apple.disk-image-udif`,
  `com.apple.xar-archive`, `org.7-zip.7-zip-archive`); the other **23** get a
  `UTImportedTypeDeclarations` entry `org.7-zip.<ext>-archive` conforming to
  `public.data, public.archive`.
* **one alternate-role viewer entry** with the 78 further extensions of the `REGISTER_ARC*` table
  (`03 section 3.2`: `jar xpi docx apk img qcow2 vmdk vdi msi chm exe …`) so "Open With" offers
  7-Zip for them without claiming them.
* `CFBundleURLTypes` for `sevenzip` and `x-7zip`.
* `NSServices` with the five `7-Zip: …` items.

A unit test asserts that every `FileTypes.all` extension has a document type with the right icon and
a UTI, and that every 7-Zip-owned UTI has a matching imported declaration.

**Does the Options ▸ System page's default-application switching take effect against these
declarations?** Yes. That page (`options` scope) calls
`NSWorkspace.setDefaultApplication(at:toOpen:)` with `SevenZipFileType.utType`, which is
`systemUTType ?? UTType(importedTypeIdentifier)`. Before this scope's plist existed,
`UTType("org.7-zip.rar-archive")` was undeclared and `utType` was `nil` for 23 of the 40 rows, so
those rows were shown as not associable. With the imported declarations in place and Launch
Services refreshed, `UTType(filenameExtension:)` resolves them (measured: after the build,
`rar`, `lzma`, `zst`, `wim`, … all report a declared, non-`dyn.` identifier), so all 40 rows are
now toggleable and `urlForApplication(toOpen:)` reports the current handler. Two caveats to keep in
the report: the page needs the app to have been registered once
(`LaunchServicesRegistration.registerIfNeeded()` does that on first launch), and macOS has no
"All users" scope, so the Windows HKLM column stays absent.

**Menu labels.** The Finder Sync extension cannot read the `Lang/*.txt` files: the reader lives in
`SevenZipKit`, which a sandboxed appex must not link. The app therefore resolves the eleven menu
lang IDs itself and ships them in the settings snapshot (`IntegrationSettings.localizedTitles`,
`IntegrationSettings.menuLangIDs`); the extension's `localize(_:_:)` uses them and falls back to the
English resource text. A language change re-pushes the snapshot.

---

## 10. Deliberate differences from Windows

1. **No drop handler.** `Directory|Drive\shellex\DragDropHandlers` has no Finder equivalent
   (`03 section 1.7`). `FinderSelection.dropPath` and the `_dropMode` rules are implemented, so
   dropping on the Dock icon can use them, but Finder never offers a right-drag menu.
2. **`-y` silences boxes from the first token.** `Main2` sets `g_DisableUserQuestions` only after
   `Parse1`, so upstream still opens a box for a switch-syntax error; the port honours `-y`
   immediately, which is what the switch says and what an unattended run needs.
3. **`&` is not doubled** in menu labels: `GetQuotedReducedString` escapes it for the Win32 menu,
   macOS menus have no `&` mnemonic. `ReduceString`'s 64-character limit is kept.
4. **No 16-item reduction.** `selectedItemURLs()` is complete, so the `<base>_` label trick and the
   invoke-time recomputation of `ContextMenu.cpp:889-904` are unnecessary (the invoke path still
   re-reads the selection, which is where a long selection's list file is written).
5. **`-seml.` cannot delete synchronously**: the mail composer keeps the file, so the archive is
   built in `NSTemporaryDirectory()/7zE-<uuid>/` and folders older than a day are purged on the next
   compress-and-email (`CompressCommands.purgeStaleEmailDirectories`).
6. **One process.** There is no separate `7zG.app`; `argv[1] ∈ {a,u,d,rn,x,e,t,h,b}` puts the app
   into command mode instead (window ordered out, real exit code). A URL command runs inside the
   already-running file manager, which is why the extension uses `NSWorkspace.open(URL)` rather
   than `openApplication(arguments:)` — one instance, no duplicate window, and the sandbox allows
   both.
7. **`rn` is refused.** The rename command needs old/new pairs, which no shell command generates.
8. **The Quick Actions are two appexes**, because one appex is one flat Quick Action entry; there
   are no submenus in that extension point.

---

## 11. Known gaps

* `-scrc` **on** `x`/`t` (hash while extracting) is not wired here: the executor passes the methods
  to `SZHasher` only for `h`. `mac/cleanup` has since added `SZExtractOptions.hashMethods` and
  `SZExtractResult.hashResults` (see `requests.md`), so this becomes a two-line change once that is
  merged.
* No `Contents/Helpers/7zG.app` helper bundle (`03 section 6.4` variant (a)); command mode inside
  the main app covers the same argv contract.
* `-snz` reaches the engine but the engine's `ReadZoneFile_Of_BaseFile` is `_WIN32`-only, so plain
  extraction does not yet write `com.apple.quarantine`; `SZTempOpen.applyQuarantine` is the helper
  that would post-process it (`extract` scope's gap, `api/extract.md` section 6).
* The Finder Sync menu shows no key equivalents (Finder ignores them) and `NSMenuItem.image` is
  best-effort, as Apple documents.
* The Quick Actions use `NSActionTemplate` for `NSExtensionServiceFinderPreviewIconName`; a bundled
  asset would look better.
* Finder's contextual menu itself cannot be asserted from a test on this machine (no Automation
  permission); the numbered manual checks in `Mac/docs/reports/finder.md` cover it.

---

## 12. Grammar and command-layer changes, 2026-09-20 (`mac/cmdmode`)

Closing items 10, 11, 14 and the command half of item 4 of `Mac/docs/parity.md`. Nothing below
removes or renames anything the sections above document; every addition is new API.

### 12.1 `SevenZipCommandLine` now carries censor **entries**, not just names

`includePaths` / `excludePaths` / `archivePaths` / `archiveExcludePaths` are unchanged. Beside them
there are now four `[SevenZipPathSpec]` lists that keep the `r` / `w` / `m` modifiers of the switch
each name came from (`CNameOption` + `AddNameToCensor`, `ArchiveCommandLine.cpp:459-495, :707-850`):

```swift
struct SevenZipPathSpec {                 // = the bridge's SZPathSpec
    var path: String                      // the name as written, wildcards and all
    var include: Bool                     // false for -x / -ax
    var recursedType: SevenZipRecursedType // .recursed (-r) .wildcardOnlyRecursed (-r0) .nonRecursed
    var wildcardMatching: Bool            // false for the `w-` postfix and for -spd
    var markMode: SevenZipMarkMode         // kMark_FileOrDir / StrictFile / StrictFile_IfWildcard
}

command.includeSpecs / excludeSpecs / archiveIncludeSpecs / archiveExcludeSpecs
command.itemSpecs        // includeSpecs + the positional paths with the global CNameOption + excludeSpecs
command.archiveSpecs     // archiveIncludeSpecs + the archive name (never recursed) + archiveExcludeSpecs
command.defaultRecursedType / .defaultWildcardMatching    // the `nop` of :1485-1491
SevenZipCommandLine.needsCensorWalk(specs)   // a wildcard to expand, or any exclude entry
```

**Wildcards are expanded by the engine, never by us.** `SZUpdater.expandPathSpecs(_:sortedArchiveList:)`
runs `EnumerateDirItemsAndSort` (`sortedArchiveList: true`, the extract group's archive list, which is
the call `GUI.cpp:285-304` makes) or `EnumerateItems` (`false`, the walk `UpdateArchive` and
`HashCalc` do). The update, delete and rename paths hand the specs straight to `UpdateArchive` via
`SZUpdater.update(with:pathSpecs:progress:)` / `deleteItems(specs:…)` / `renameItems(…itemSpecs:…)`,
so `-ir!src/*.c` still stores `sub/x.c` rather than `x.c`. A censor with no wildcard and no exclude
entry — which is every Finder selection, because the transport writes `-aiw-!<path>` — takes the old
literal path and touches no disk.

Two measured differences between the two walks, both upstream's:

* `EnumerateDirItemsAndSort` throws `CMessagePathException("Cannot find archive")` when **nothing**
  matched (`EnumDirItems.cpp:1496-1500`) and "Duplicate archive path:" for a duplicate; `WinMain`
  puts both on the **exit 7** arm. `EnumerateItems` has no such rule.
* Both report files only. A *matched directory* is walked whole even without `-r` (`7z a arc *`
  behaves the same way).

### 12.2 `rn` is implemented (this replaces §10 point 7)

`SevenZipArguments.parse` turns the positional strings of an `rn` command into
`[SevenZipRenamePair]` (`CRenamePair`) instead of item paths, exactly as
`AddToCensorFromNonSwitchesStrings` does with `renamePairs`:

* `rn a.7z old1 new1 old2 new2` — pairs in order;
* a `@listfile` among the positional strings contributes pairs and must hold an **even** number of
  names, else `"Incorrect item in listfile.…"`;
* an odd number of names is `"There is no second file name for rename pair:"` + the name (exit 7);
* a wildcard in an **old** name is `"Unsupported rename command:"` + old, new (`CRenamePair::Prepare`,
  `Update.cpp:288-295`); `-spd` turns wildcard parsing off and the name is then literal;
* the `-i` / `-x` masks stay the mask over the **archive's own** item names; empty means `*`.

`SZUpdater.renameItems(pairs:inArchiveAt:itemSpecs:options:progress:)` fills
`CUpdateOptions::RenamePairs` and `RenameMode` and lets `UpdateArchive` rewrite the archive.
Upstream dispatches `rn` through `UpdateGUI`, so the progress window is the **Compressing** one
(`IDS_PROGRESS_COMPRESSING 3301`; there is no "Renaming" string in the 33xx block) and a failed file
is exit code 1.

### 12.3 The exit-code ladder

`SevenZipFailureLadder` (in `ArgumentGrammar.swift`, Foundation only) is `WinMain`'s catch chain
(`GUI.cpp:437-494`) as a pure function, and **every** failure site in `CommandExecutor` goes through
it:

```swift
SevenZipFailureLadder.classify(error, memoryMessage: Lang.text(3000, …))  // -> SevenZipFailure
SevenZipFailureLadder.exitCode(for: error)                               // when the box is already up
```

| cause | exit | box |
|---|---|---|
| `CNewException` / `E_OUTOFMEMORY` / POSIX `ENOMEM` | **8** | IDS_MEM_ERROR 3000 |
| `SevenZipArgumentError` (`CMessagePathException`) | 7 | message + path |
| bridge error flagged `SZPathExceptionUserInfoKey` | 7 | the engine's text |
| `E_ABORT` / `SZError.Code.cancelled` | 255 | none |
| any other engine error | 2 | `localizedDescription` (= `MyFormatMessage`) |
| `"Internal Error #N"` (the bridge's `catch (int n)`) | 2 | `"Error: N"` |
| no text at all | 2 | `"Unknown error"` |

`CNewException` **is** `std::bad_alloc` on this platform (`Common/NewHandler.h:99-102`), so the
bridge's `SZHandleCurrentException` maps an allocation failure to `E_OUTOFMEMORY` and exit 8 is
reachable. `SZUpdater` and `SZHasher` also substitute IDS_MEM_ERROR for `MyFormatMessage`'s errno
text on `E_OUTOFMEMORY`, which is what `HResultToMessage` does, so the Progress dialog's own final
message says what Windows says too. `SZExtractor` still does not — filed in `requests.md`.

### 12.4 `-scrc` on `x` / `t`

`CommandExecutor.runExtractGroup` sets `SZExtractOptions.hashMethods` from
`command.hashMethods` (a bare `-scrc` = CRC32, an unsupported method = exit 2) and shows
`SZExtractResult.hashResults` in `HashResultsDialog` **instead of** the test summary
(`ExtractGUI.cpp:129-152`). Like upstream's `ShowHashResults`, that list is **not** suppressed by
`-y`: `g_DisableUserQuestions` gates only the error boxes, so an unattended `t -scrc` run shows it,
exactly as 7zG does.

### 12.5 `-sfx<module>`

`SZUpdater.resolvedSFXModulePath(_:)` is `Update.cpp:1167-1191`: nil/empty is the bundled
`7z.sfx` (`kDefaultSfxModule`), a bare name is looked up in the bundle's `Resources/SFX` first
(`NDLL::GetModuleDirPrefix()`'s equivalent) and then relative to the current directory, anything else
is used as given. It must exist ("cannot find specified SFX module") and look like a stub — a regular
file of at least 1 KiB starting with `MZ` or a Mach-O / universal magic ("cannot open SFX module").
`SZUpdater.formatSupportsSFX(_:)` is `kFF_SFX`, i.e. 7z only.

`CommandExecutor` resolves and validates **before** any dialog, and sets `sfxMode` whether or not
`-ad` was given (`UpdateGUI.cpp:561-565` fills the default module either way), so the two surprises
are gone: `a -sfx …` without `-ad` now produces an SFX, and a missing module, a bogus module or a
non-7z `-t` is an error with nothing written instead of a quietly plain archive. As upstream
(`UpdateGUI.cpp:517`, `if (di.SFXMode) options.SfxMode = true;`), the Compress dialog can turn SFX
**on** but cannot turn a command-line `-sfx` off.

### 12.6 Dropping on the Dock icon (this refines §1 "document open" and §10 point 1)

`application(_:open:)` now classifies the request's **source** before acting:

```swift
DockDropDetector.currentSource            // .document or .dockDrop
DockDropRouter.action(paths:directoryFlags:isRecognisedArchive:)  // .open / .addToArchive / .nothing
URLCommands.openDocuments(_:formatHint:source:)
```

macOS has no delegate callback for "dropped on the Dock icon" — Finder, the Dock, `open(1)` and
`NSWorkspace` all cause the same `kAEOpenDocuments`. `DockDropDetector` therefore reads the current
Apple event's `keyOriginalAddressAttr` / `keyAddressAttr`, coerces it to `typeKernelProcessID` and
resolves the pid to a bundle identifier; `com.apple.dock` means a Dock drop. Anything else — a
missing attribute included — is treated as an ordinary open, because opening what the user asked to
open is never destructive while compressing it unasked would be.

The routing rule, and why: **one single archive still opens** (the Dock is a legitimate way to open an
archive without Finder, and the event is indistinguishable from a double-click), where "archive" is
Block A's own condition — one item, not a directory, `needsExtract` (extension not in
`kExtractExcludeExtensions`) — **plus** the engine recognising the extension
(`SZCodecs.format(forArchiveName:)`), so a dropped `notes` or `image.png` is not opened into an empty
panel. **Everything else is "Add to archive…"**: several items, a folder, or one non-archive file.
That is Windows' drop-handler gesture (`03 §1.7`), and the argv is literally
`FinderMenuModel.command(verb: "SevenZipCompress", …)`, so the Dock and Finder's own menu cannot
drift. If the user has switched that context-menu item off, the drop falls back to opening rather
than doing nothing.

`Mac/App/Info.plist` gains one last `CFBundleDocumentTypes` group claiming
`public.item` + `public.folder` with `CFBundleTypeRole: Viewer` and `LSHandlerRank: None`, because the
Dock highlights the icon only for types the app claims and the compress gesture has to accept
anything. Rank `None` keeps it out of "Open With" and out of every default-handler race; it grants
the drop and nothing else.

---

## 13. The extension hand-off, 2026-10-06 (`mac/finderfix`)

What changed between a click in Finder and `URLCommands.handle` (report: `Mac/docs/reports/finderfix.md`).

- **Menu items are numbered.** `FinderMenuBuilder.menu(for:action:image:)` builds the Finder Sync
  `NSMenu`; every command item's `tag` is `FinderMenuModel.menuTag(forIndex:)` in
  `FinderMenuModel.flattenCommands(_:)` order. Finder copies the menu and keeps only title, image,
  tag, action and submenu, so `representedObject`/`target` must never carry anything. On the click,
  `FinderMenuModel.resolveInvocation(tag:title:nodes:)` rebuilds the tree for the current selection
  and returns the command (tag first, the title must agree; a stale tag falls back to a unique
  title; nil otherwise).
- **`ExtensionHandoff.send(_:to:log:completion:)`** (AppKit, compiled into the three appexes) opens
  the URL with `NSWorkspace.open(_:withApplicationAt:)` aimed at `SevenZipBundle.containingAppURL`
  and falls back to `NSWorkspace.open(URL)` only when that fails. Outcome `.aimed` / `.scheme` /
  `.failed`. `aimedOpener` and `schemeOpener` are replaceable for tests.
- **`sevenzip:///error?code=<noitems|command|unavailable>`** (`CommandURL.errorURL(_:)`,
  `CommandURL.Action.extensionFailure`, `CommandURL.ExtensionFailure`): an extension that cannot
  build a command asks the app to show the fixed message for that code in an error box. Unknown codes
  are rejected like any unsupported URL, so a URL cannot make the app show text of its choosing.
- **`QuickActionInput.fileURLs(from:completion:)`** resolves Quick Action attachments: `public.file-url`
  when offered, else `loadInPlaceFileRepresentation` of the content type (in place only, never a
  temporary copy), else `loadItem` of the content type when it returns a file URL.
- **Logging.** Subsystem `com.yrambler2001.7zip`, categories `FinderSync` and `QuickAction` (the hand-off logs under its caller's category)
  and `URL` (the app): `log stream --predicate 'subsystem == "com.yrambler2001.7zip"'`
  shows the menu, the click, the hand-off outcome and the URL the app received. Paths are private.
- **Compress Quick Action** activates on `UTI-CONFORMS-TO "public.item"` (any file or folder).
