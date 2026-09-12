# 04 — Toolchain, console build, redistributable assets

Scope: everything the scaffold and packaging agents need to build the macOS port on this
machine without rediscovering it: exact tool versions, the verified `7zz` console build, the
inventory and format of the Windows assets we redistribute (`Lang/`, SFX stubs), a proven
XcodeGen + `xcodebuild` recipe (app + Finder Sync extension + static library with the arm64
assembly), and the licensing constraints. Source snapshot: 7-Zip 26.03, branch `macos`,
repository root `~/things/a.noindex/7zip`. All paths are relative to the
repository root unless stated otherwise. Verified 2026-09-12.

Nothing in this document required editing an upstream file. Every command below was run with
`DEVELOPER_DIR=/Applications/Xcode.app` exported; `xcode-select -s` was never used.

---

## 1. Environment and tool versions

| Tool | Version / location | Notes |
|---|---|---|
| Machine | Apple Silicon (arm64), macOS 26.4 (25E246) | |
| Xcode | **26.6 (17F113)** at `/Applications/Xcode.app` | Selected only via `DEVELOPER_DIR`. The global selection is `/Applications/Xcode15.app` (Xcode 15.4, Apple clang 15) and must stay. |
| macOS SDK | **26.5** (build 25F70), `MacOSX26.5.sdk` | `DefaultDeploymentTarget 26.5`, `MinimumDeploymentTarget 10.13` (13.1 for some variants). `xcodebuild -showsdks` lists only `macosx26.5`. |
| Apple clang | 21.0.0 (clang-2100.1.1.101) | `/usr/bin/clang` shim resolves to Xcode 26.6's toolchain when `DEVELOPER_DIR` is set. |
| Swift | 6.3.3 (swiftlang-6.3.3.1.3), swift-driver 1.148.6 | Both `-swift-version 5` and `6` compile the probe code. |
| XcodeGen | 2.45.4 (`/opt/homebrew/bin/xcodegen`) | Has a hang bug with far-reaching `../` source paths, see §5.4. |
| GNU Make | 3.81 (`/Applications/Xcode.app/Contents/Developer/usr/bin/make`) | Enough for the upstream `*.mak` files. |
| git | 2.50.1 (Apple Git-155) | `git worktree add/remove` verified working. |
| python3 | 3.14.6 | Used for the lang-file validator only. |
| codesign / spctl / pluginkit | present; `spctl --status` = `assessments enabled` | Ad-hoc signing (`codesign -s -`) verified on a trivial binary and on the probe app. |
| hdiutil / pkgbuild / productbuild | present (hdiutil framework 683.100.3) | For packaging. |
| notarytool / stapler | `/Applications/Xcode.app/Contents/Developer/usr/bin/{notarytool,stapler}` | Unusable until a Developer ID exists (see below). |
| create-dmg | **not installed**; `brew install create-dmg` (1.3.0, bottled) is available | `hdiutil` alone is sufficient for a plain DMG. |
| Homebrew | 6.0.22 | |
| Signing identities | `security find-identity -v -p codesigning` → **0 valid identities** | No Apple Development / Developer ID certificate on this machine. Everything is ad-hoc; notarization and Gatekeeper-clean distribution are impossible until a Team ID certificate is installed. |

`DEVELOPER_DIR` semantics, verified: with it exported, `xcode-select -p`, `xcrun`, `xcodebuild`,
`swift` and the `/usr/bin/clang` shim all resolve into Xcode 26.6. Without it, everything falls
back to Xcode 15.4.

Noise you will see from `xcodebuild` under this setup and can ignore:

- `iOSSimulator: [SimServiceContext sharedServiceContextForDeveloperDir:error:] returned nil … "CoreSimulator is out of date"` — the CoreSimulator framework installed system-wide belongs to the globally selected Xcode 15.4. Harmless for macOS builds.
- `appintentsmetadataprocessor … Metadata extraction skipped. No AppIntents.framework dependency found.` — harmless.
- `xcodebuild: WARNING: Using the first of multiple matching destinations` — silence with `-destination 'platform=macOS,arch=arm64'`.

---

## 2. Console build: `7zz` (upstream makefile)

### 2.1 Command and result

```sh
cd CPP/7zip/Bundles/Alone2
DEVELOPER_DIR=/Applications/Xcode.app make -j8 -f ../../cmpl_mac_arm64.mak
```

| Item | Value |
|---|---|
| Output | `CPP/7zip/Bundles/Alone2/b/m_arm64/7zz` (2,988,992 bytes, Mach-O thin arm64, unsigned, `Identifier=7zz` when queried) |
| Objects | `CPP/7zip/Bundles/Alone2/b/m_arm64/*.o` (~330 translation units) |
| Time (clean, `-j8`) | **real 12.74 s**, user 41.24 s, sys 10.94 s |
| Time (clean rebuild into another `O=` dir, same flags) | real 7.65 s (warm caches) |
| Exit code | 0 |
| Warnings / errors | **none**. Note the makefile compiles with `-Werror -Wall -Wextra -Weverything -Wfatal-errors -Wno-poison-system-directories`, so any diagnostic from Apple clang 21 would have failed the build. The only clang-21-specific accommodation is already upstream: `Asm/arm64/7zAsm.S` emits `#pragma GCC diagnostic ignored "-Wc++-compat"` for `__clang_major__ >= 20` because its `.macro and/or/xor` names collide with C++ alternative tokens. |

Compiler command shape (from the log; C++ files):

```
clang++ -arch arm64 -O2 -c -Werror -Wall -Wextra -Weverything -Wfatal-errors -Wno-poison-system-directories \
  -DNDEBUG -D_REENTRANT -D_FILE_OFFSET_BITS=64 -D_LARGEFILE_SOURCE -fPIC -std=c++11 -o b/m_arm64/X.o ../../UI/Console/X.cpp
```

C files are the same without `-std=c++11` (default gnu17). The only assembly file on arm64 is
`Asm/arm64/LzmaDecOpt.S` (includes `Asm/arm64/7zAsm.S`), compiled with the plain C flags:
`clang -arch arm64 -O2 -c … -o b/m_arm64/LzmaDecOpt.o ../../../../Asm/arm64/LzmaDecOpt.S`
(`ASM_FLAGS` in `CPP/7zip/7zip_gcc.mak` is never defined, so nothing extra). `C/LzmaDec.c` is
compiled with `-DZ7_LZMA_DEC_OPT` so that it calls the assembly `LzmaDec_DecodeReal_3`. The
CRC/SHA/AES `*Opt` files are C with intrinsics on arm64 (the `.asm` MASM sources under
`Asm/x86` are x86-only). `-DZ7_7ZIP_ASM` (`CONSOLE_ASM_FLAGS`) only adds the `ASM` tag to `7zz i`.

Link: `clang++ -o b/m_arm64/7zz -arch arm64 -DNDEBUG <all .o> -lpthread -ldl`.

### 2.2 Two things the makefile does not set (and how to fix without editing it)

1. **No deployment target.** The binary carries `LC_BUILD_VERSION minos 26.0` because no
   `-mmacosx-version-min` is passed and clang defaults to the host OS. Fix by environment,
   verified: `MACOSX_DEPLOYMENT_TARGET=14.0 make …` produces `minos 14.0` with zero warnings
   (`Mac/scripts/fetch-assets.sh` already does this for its on-demand build).
2. **SDK is the Command Line Tools one.** The bare `clang` shim uses Xcode 26.6's *compiler* but
   defaults its sysroot to `/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk` (SDK 26.4), so
   the binary records `sdk 26.4` while `xcrun --show-sdk-version` says 26.5. Harmless for `7zz`;
   if it matters, export `SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"` (not tested). The Xcode
   project is unaffected: `xcodebuild` passes `-isysroot …/MacOSX26.5.sdk` explicitly.

### 2.3 Runtime verification

```
$ b/m_arm64/7zz i
7-Zip (z) 26.03 (arm64) : Copyright (c) 1999-2026 Igor Pavlov : 2026-09-03
 64-bit arm_v:8.5-A locale=UTF-8 Threads:10 OPEN_MAX:1048576, ASM
Formats: 62 entries (7z, APFS, APM, Ar, Arj, Base64, … zip, zstd)   Codecs / Hashers listed.

$ b/m_arm64/7zz b -mmt1        (single thread, ~24 s wall)
Dict   Compressing KiB/s  Rating   |  Decompressing KiB/s  Rating
22:       6302      6131   |     84856      7245
25:       4889      5583   |     79423      7069
Avr:      5433      5686   |     82085      7154        Tot: 6420 MIPS
```

### 2.4 Git hygiene

`git status` after the build shows `?? CPP/7zip/Bundles/Alone2/b/` (426 untracked object files).
`Mac/.gitignore` cannot cover it (gitignore patterns cannot climb directories). The
orchestration document claims `*/b/` is ignored, but nothing implements that yet. Suggested
entries for a **root** `.gitignore` (not created; orchestrator's call):

```
# 7-Zip upstream makefile output (O=b/m_<arch> under every CPP/7zip/Bundles/*, UI/*, Compress/* etc.)
CPP/7zip/**/b/
# generic safety nets
*.o
.DS_Store
```

`CPP/7zip/**/b/` is the precise one; the upstream makefiles always put objects in `b/<variant>/`
relative to the makefile directory (`O=b/m_$(PLATFORM)` in `CPP/7zip/var_mac_arm64.mak`).

---

## 3. Redistributable asset inventory

### 3.1 Source: the official Windows installer

| Item | Value |
|---|---|
| URL | `https://7-zip.org/a/7z2603-x64.exe` |
| Size | 1,661,239 bytes |
| SHA-256 | `0859c524b8a63551848f0c246abddcb1d0b7b656b0fbfe879f8d85e61a9e6edd` (pinned in `Mac/scripts/fetch-assets.sh`) |
| Container | 7z SFX: `Type = 7z`, `Offset = 45568`, `Method = LZMA:5m BCJ2`, solid, 2 blocks, 107 files / 5,917,936 bytes. `7zz l` / `7zz x` open it directly (no NSIS/PE tricks needed). |

Full installer contents (descriptions from its `descript.ion`):

| File | Size | Type | Kept? |
|---|---|---|---|
| `Lang/*.txt` (92) + `Lang/en.ttt` | 1,136 KiB total | UTF-8 text | **yes → `Mac/Resources/Lang/`** |
| `7z.sfx` | 215,552 | PE32 GUI executable, i386 — "7-Zip GUI SFX" | **yes → `Mac/Resources/SFX/`** (SHA-256 `9598f3bbca8e95391b8a356aee2e4cab93d9ac26eea47159ec725a55cf3bb32f`) |
| `7zCon.sfx` | 194,048 | PE32 console executable, i386 — "7-Zip Console SFX" | **yes → `Mac/Resources/SFX/`** (SHA-256 `c4402ffcbe8e02ec017f958f0d188fe13ea00193623c95dde546f6621a2e4132`) |
| `License.txt` | 6,031 | ASCII, CRLF — "7-Zip License" | **yes → `Mac/Resources/SFX/`** (binary redistribution must reproduce it, see §6) |
| `readme.txt` | 1,711 | ASCII, CRLF — "7-Zip Overview" (states "7-Zip 26.03", lists the SFX modules and the LGPL) | **yes → `Mac/Resources/SFX/`** (provenance) |
| `History.txt` | 12,009 | changelog ("26.03 2026-09-03 …") | no (not a license/readme; changelog lives upstream in `DOC/`) |
| `descript.ion` | 366 | 4DOS-style file descriptions | no |
| `7-zip.chm` | 127,448 | HTML Help user manual | no (Windows-only container; could be extracted for a Help book later — `7zz` can unpack CHM) |
| `7z.dll`, `7z.exe`, `7zFM.exe`, `7zG.exe`, `7-zip.dll`, `7-zip32.dll`, `Uninstall.exe` | — | Windows PE binaries | no |

The SFX stubs are Windows executables; on macOS they are only useful as the prefix for
`7zz a -sfx7z.sfx …` / `-sfx7zCon.sfx` to create Windows self-extracting archives (the same use
7zFM offers). `7zz l Mac/Resources/SFX/7z.sfx` opens them as `Type = PE` (14 sections) if anyone
needs to inspect them.

### 3.2 What is now in the tree

```
Mac/Resources/Lang/   93 files (92 × <code>.txt + en.ttt), 1,136 KiB
Mac/Resources/SFX/    7z.sfx  7zCon.sfx  License.txt  readme.txt      (416 KiB)
Mac/scripts/fetch-assets.sh   reproduces all of the above from scratch
```

Language codes present (92 translations): af an ar ast az ba be bg bn br ca co cs cy da de el
eo es et eu ext fa fi fr fur fy ga gl gu he hi hr hu hy id io is it ja ka kaa kab kk ko ku-ckb ku
ky lij lt lv mk mn mng mng2 mr ms nb ne nl nn pa-in pl ps pt-br pt ro ru sa si sk sl sq sr-spc
sr-spl sv sw ta tg th tk tr tt ug uk uz-cyrl uz va vi yo zh-cn zh-tw.

Version line inside `Lang/en.ttt` (second line, first comment):
`; 24.04 : 2024-04-05 : Igor Pavlov` — the English template's string set was last changed in
7-Zip 24.04; 26.03 ships the same 444 strings (IDs 0…7822). Translations carry their own
credit lines in the same slot (e.g. `ru.txt`: `; 24.04 : 2024-04-05 : Igor Pavlov`,
`zh-cn.txt`: `;  2.30 : 2002-09-07 : Modern Tiger, kaZek, Hutu Li` followed by later versions,
`ja.txt`: `;       :            : Komuro`).

### 3.3 `Mac/scripts/fetch-assets.sh`

Executable; verified twice (fresh download: 1.9 s; with `INSTALLER=<local file>`). Steps:
download (or reuse `INSTALLER=`), verify the pinned SHA-256, locate `7zz` at
`CPP/7zip/Bundles/Alone2/b/m_arm64/7zz` or build it with the upstream makefile
(`DEVELOPER_DIR`, `MACOSX_DEPLOYMENT_TARGET=14.0`, `make -j$JOBS`), extract everything to a temp
dir, check the expected file set (92 `Lang/*.txt` + `en.ttt`, both SFX hashes, every lang file
starts with `;!@Lang2@!UTF-8!` after an optional BOM), then replace `Mac/Resources/Lang/*.txt|*.ttt`
and copy the four SFX-dir files. Env: `INSTALLER`, `SEVENZZ`, `DEVELOPER_DIR`, `KEEP_WORK=1`,
`JOBS`. When 7-Zip adds a language, bump `EXPECTED_LANG_TXT`; on a version bump change
`VERSION_TAG` and the three hashes.

---

## 4. Lang file format (exact, from `CPP/Common/Lang.cpp`)

The files are **not** `key = value`. They are a positional list of strings addressed by
implicit integer IDs. The authoritative parser is `CLang::Open` / `CLang::OpenFromString` in
`CPP/Common/Lang.cpp` (170 lines). A parser written from the rules below was run over all 93
files: all parse, each yields 444 strings for `en.ttt`.

### 4.1 File level

1. Read the whole file (upstream rejects files > 1 MiB). Truncate at the first NUL byte.
   **Delete every `0x0D` byte** (so CRLF and LF files are identical; `ja.txt` is CRLF).
2. Decode as strict UTF-8. Drop one leading U+FEFF if present (84 files have a BOM, 9 do not:
   ar da is ro sw tk tr yo zh-cn).
3. The text must begin with the exact signature line `;!@Lang2@!UTF-8!` followed by `\n`.
   Anything else → the file is rejected.
4. The remainder is processed line by line, split on `\n`. A trailing `\n` terminates the last
   line; it does not create an extra empty line.

### 4.2 Line level (state: `id`, an integer initialised to −1024)

Unescape the line first: `\n` → newline, `\t` → tab, `\\` → backslash; a backslash followed by
any other character keeps both characters; a backslash at end of line/file → file rejected.
Then classify the unescaped line:

| Line kind | Rule | Effect |
|---|---|---|
| **Blank** | empty, or only spaces/tabs | `id += 1` (the ID is consumed but no string is stored — "untranslated") |
| **Comment** | first character is `;` | right-trimmed and kept in `Comments` unless it is a bare `;`; **`id += 1`** (comments also consume an ID) |
| **ID line** | the *entire* line is ASCII decimal digits (no sign, no whitespace, no trailing text) | `id = value`; must satisfy `value <= 2^30` and `value >= id` (non-decreasing), else file rejected |
| **String** | anything else | if `id < 0` → file rejected; store `(id, text)`; `id += 1`. Text is stored verbatim (leading/trailing whitespace preserved, no trimming). |

Consequences: IDs are strictly increasing in file order (lookup is a binary search over
`_ids`); a numeric line equal to the current `id` is a no-op; "holes" are expressed either by
blank lines or by jumping to a larger number. In practice every shipped file has all its
comment lines in the header (before the first ID line); mid-body comments are legal but unused.

### 4.3 Post-conditions used by the app

- String ID 0 must be exactly `7-Zip` (`CLang::Open(fileName, "7-Zip")`), otherwise the file is
  rejected. ID 1 = language name in English, ID 2 = native name (used by the language menu).
- Lookup `Get(id)` returns `NULL` when the ID is absent → callers fall back to the built-in
  English resource string. Coverage across the shipped translations ranges from 57 % (`ta.txt`)
  to 100 % (`va`, `zh-cn`, `zh-tw`); 44 files contain exactly one obsolete ID that `en.ttt` no
  longer has (harmless: never looked up).
- The strings are Windows UI strings: `&` marks the mnemonic (`&File`); `{0}`, `{1}` are
  positional placeholders substituted by the caller; `\n` line breaks inside dialog text.
  Menu/dialog IDs match the Windows resource IDs, e.g. `4xx` = `400 + <IDOK…IDCONTINUE>` for
  standard buttons, `5xx`/`6xx`/`7xx` = 7zFM menu items, `1003…` = property names,
  `7820…` = latest additions.

### 4.4 Three examples (all from `Mac/Resources/Lang/en.ttt`)

Example 1 — header, ID 0..2, then the standard-button block with holes:

```
;!@Lang2@!UTF-8!                 <- signature (after an optional BOM)
; 24.04 : 2024-04-05 : Igor Pavlov   <- comment (kept), id -1024 -> -1023
;                                 <- bare ';' comments ×10: id -> -1013
0                                 <- id = 0
7-Zip                             <- (0, "7-Zip")        id -> 1
English                           <- (1, "English")      id -> 2
English                           <- (2, "English")      id -> 3
401                               <- id = 401
OK                                <- (401, "OK")
Cancel                            <- (402, "Cancel")
                                  <- blank: 403 consumed, no string
                                  <- blank: 404
                                  <- blank: 405
&Yes                              <- (406, "&Yes")
&No                               <- (407, "&No")
&Close                            <- (408, "&Close")
Help                              <- (409, "Help")
                                  <- blank: 410
&Continue                         <- (411, "&Continue")
```

Example 2 — a menu block; IDs increment per line until the next numeric line:

```
500
&File                             <- 500
&Edit                             <- 501
&View                             <- 502
F&avorites                        <- 503
&Tools                            <- 504
&Help                             <- 505
540
&Open                             <- 540
Open &Inside                      <- 541
```

Example 3 — escapes and placeholders (file line 262 sits in the 3000-block, ID 3009):

```
File '{0}' was modified.\nDo you want to update it in the archive?
```

is stored as the single string `File '{0}' was modified.⏎Do you want to update it in the
archive?` (the two-character `\n` becomes a real newline). Every shipped file uses `\n`;
none uses `\t` or `\\`.

Reference implementation used for validation (Python, 40 lines):
`/private/tmp/…/scratchpad/langcheck.py` — not committed; the rules above are complete.

---

## 5. XcodeGen + xcodebuild recipe (verified end to end)

A throwaway project was generated and built in the scratchpad with the **same relative layout
as the real one** (`<root>/Mac/project.yml`, sources under `<root>/Asm` and `<root>/C` reached via
`../`). Targets: Swift AppKit app (`com.yrambler2001.7zip`, deployment 14.0), Finder Sync
extension (`com.yrambler2001.7zip.FinderSync`), static library containing one C++ file, upstream
`C/LzmaDec.c` and the arm64 assembly `Asm/arm64/LzmaDecOpt.S`. Results:

| Check | Result |
|---|---|
| `xcodegen generate` | 0.03 s |
| `xcodebuild … -configuration Debug CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build` | BUILD SUCCEEDED; clean ≈ 14 s, incremental 2.4 s; 0 warnings from our sources |
| `-configuration Release` | BUILD SUCCEEDED, 10.8 s clean |
| `.S` assembled by Xcode | yes: `clang -x assembler-with-cpp -target arm64-apple-macos14.0 -isysroot MacOSX26.5.sdk …`; `nm libProbeCore.a` shows `T _LzmaDec_DecodeReal_3` (from the `.S`) and `U _LzmaDec_DecodeReal_3` (from `LzmaDec.c` built with `Z7_LZMA_DEC_OPT`) — the C/asm contract links |
| Signing | app and appex `Signature=adhoc`, `TeamIdentifier=not set`, `flags=0x2(adhoc)`; entitlements embedded |
| `LSMinimumSystemVersion` / `minos` | 14.0 on app and appex, `sdk 26.5` |
| App launch | `open ProbeApp.app` → process running; `osascript -e 'tell application "ProbeApp" to quit'` → quits cleanly |
| `pluginkit -m -v -i com.yrambler2001.7zip.FinderSync` | listed (with path + UUID); `pluginkit -e use -i …` → Finder immediately spawned `…/ProbeFinderSync.appex/Contents/MacOS/ProbeFinderSync` |
| `spctl --assess --type execute ProbeApp.app` | `rejected` (expected for ad-hoc; local launch is unaffected because there is no quarantine attribute) |

### 5.1 `project.yml` (verbatim, final working version)

```yaml
name: ToolchainProbe
options:
  bundleIdPrefix: com.yrambler2001
  deploymentTarget:
    macOS: "14.0"
  createIntermediateGroups: true
  generateEmptyDirectories: true
settings:
  base:
    MACOSX_DEPLOYMENT_TARGET: "14.0"
    SWIFT_VERSION: "6.0"
    CODE_SIGN_STYLE: Manual
    CODE_SIGN_IDENTITY: "-"
    DEVELOPMENT_TEAM: ""
    PROVISIONING_PROFILE_SPECIFIER: ""
    ENABLE_HARDENED_RUNTIME: NO
    ARCHS: arm64
    ONLY_ACTIVE_ARCH: YES
    CLANG_CXX_LANGUAGE_STANDARD: c++11
targets:
  ProbeCore:
    type: library.static
    platform: macOS
    sources:
      - path: Core
      - path: ../Asm/arm64/LzmaDecOpt.S
      - path: ../C/LzmaDec.c
    settings:
      base:
        GCC_PREPROCESSOR_DEFINITIONS: ["$(inherited)", "Z7_LZMA_DEC_OPT=1", "NDEBUG=1", "_REENTRANT=1"]
        HEADER_SEARCH_PATHS: ["../C"]
        PUBLIC_HEADERS_FOLDER_PATH: include
  ProbeApp:
    type: application
    platform: macOS
    sources:
      - path: App
    dependencies:
      - target: ProbeCore
      - target: ProbeFinderSync
        embed: true
    entitlements:
      path: App/ProbeApp.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.files.user-selected.read-write: true
    info:
      path: App/Info.plist
      properties:
        CFBundleDisplayName: ProbeApp
        NSPrincipalClass: NSApplication
        LSMinimumSystemVersion: "$(MACOSX_DEPLOYMENT_TARGET)"
        NSHumanReadableCopyright: "probe"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.yrambler2001.7zip
        SWIFT_OBJC_BRIDGING_HEADER: App/Bridging.h
        OTHER_LDFLAGS: ["$(inherited)", "-lc++"]
        HEADER_SEARCH_PATHS: ["$(SRCROOT)/Core"]
  ProbeFinderSync:
    type: app-extension
    platform: macOS
    sources:
      - path: FinderSync
    entitlements:
      path: FinderSync/ProbeFinderSync.entitlements
      properties:
        com.apple.security.app-sandbox: true
        com.apple.security.files.user-selected.read-only: true
    info:
      path: FinderSync/Info.plist
      properties:
        CFBundleDisplayName: ProbeFinderSync
        NSExtension:
          NSExtensionPointIdentifier: com.apple.FinderSync
          NSExtensionPrincipalClass: "$(PRODUCT_MODULE_NAME).FinderSync"
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.yrambler2001.7zip.FinderSync
schemes:
  ProbeApp:
    build:
      targets:
        ProbeApp: all
    run:
      config: Debug
```

XcodeGen writes `App/Info.plist`, `FinderSync/Info.plist` and both `.entitlements` files from
the `info:`/`entitlements:` blocks (they are generated files; keep them out of git or accept
churn). The generated Info.plists contain `CFBundleExecutable=$(EXECUTABLE_NAME)`,
`CFBundleIdentifier=$(PRODUCT_BUNDLE_IDENTIFIER)`, `CFBundlePackageType` `APPL` / `XPC!`,
`CFBundleShortVersionString 1.0`, `CFBundleVersion 1`, plus the properties given.

### 5.2 Sources (verbatim)

`App/AppDelegate.swift`
```swift
import Cocoa
import os

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "ProbeApp"
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        let p = probe_core_lzma_asm_entry()
        let s = String(cString: probe_core_cxx_string())
        Logger(subsystem: "com.yrambler2001.7zip", category: "probe").info("ProbeApp launched; asm entry=\(String(describing: p)) cxx=\(s, privacy: .public)")
        print("ProbeApp launched; asm entry=\(String(describing: p)) cxx=\(s)")
    }
}
```

`App/Bridging.h`
```c
#include "ProbeCore.h"
```

`Core/ProbeCore.h`
```c
#ifndef PROBE_CORE_H
#define PROBE_CORE_H
#ifdef __cplusplus
extern "C" {
#endif
const void *probe_core_lzma_asm_entry(void);
const char *probe_core_cxx_string(void);
#ifdef __cplusplus
}
#endif
#endif
```

`Core/ProbeCore.cpp`
```cpp
#include "ProbeCore.h"
#include <string>
extern "C" void LzmaDec_DecodeReal_3(void);
static std::string g_s = std::string("cxx-ok-") + std::to_string(7);
const void *probe_core_lzma_asm_entry(void) { return (const void *)&LzmaDec_DecodeReal_3; }
const char *probe_core_cxx_string(void) { return g_s.c_str(); }
```

`FinderSync/FinderSync.swift`
```swift
import Cocoa
import FinderSync

final class FinderSync: FIFinderSync {
    override init() {
        super.init()
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: NSHomeDirectory())]
    }
    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let menu = NSMenu(title: "")
        menu.addItem(withTitle: "ProbeFinderSync item", action: #selector(probeAction(_:)), keyEquivalent: "")
        return menu
    }
    @objc func probeAction(_ sender: AnyObject?) {
        NSLog("ProbeFinderSync: %@", FIFinderSyncController.default().selectedItemURLs() ?? [])
    }
}
```

### 5.3 Commands

```sh
export DEVELOPER_DIR=/Applications/Xcode.app
xcodegen -s Mac/project.yml                     # or: (cd Mac && xcodegen generate)
xcodebuild -project Mac/7-Zip.xcodeproj -scheme <AppScheme> -configuration Debug \
  -derivedDataPath Mac/build/DerivedData -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build
APP=Mac/build/DerivedData/Build/Products/Debug/<App>.app
open "$APP"                                     # launch
osascript -e 'tell application "<AppName>" to quit'   # or: pkill -x <AppName>
pluginkit -m -v -i com.yrambler2001.7zip.FinderSync   # registered by the build itself
pluginkit -e use -i com.yrambler2001.7zip.FinderSync  # enable -> Finder loads the appex
pluginkit -e ignore -i com.yrambler2001.7zip.FinderSync ; pluginkit -r "$APP/Contents/PlugIns/<Ext>.appex"   # disable / unregister
```

`pluginkit -m -v` output format: `<flag> <bundle id>(<version>)\t<UUID>\t<date>\t<path>` where the
flag column is `+` = enabled ("use"), `-` = disabled ("ignore"), blank = default/unset.

### 5.4 Gotchas (each one was hit or verified)

1. **XcodeGen hangs (100 % CPU, never returns) on source paths that climb far out of the spec
   directory** — an absolute path (`/Users/…/Asm/arm64/LzmaDecOpt.S`) or a 7-level
   `../../../../../../../Users/…` path with `createIntermediateGroups: true` hung for > 10 min.
   One level (`../Asm/…`, `../C/…`, the real layout) generates in 0.03 s, as do a symlink inside
   the project dir and `createIntermediateGroups: false`. Never use absolute paths in
   `project.yml`; keep the spec at `Mac/project.yml` and reference `../Asm`, `../C`, `../CPP`.
   Wrap `xcodegen` in a timeout in scripts (`perl -e 'alarm 120; exec @ARGV' xcodegen …`;
   macOS has no `timeout(1)`).
2. **Ad-hoc signing needs `CODE_SIGN_STYLE: Manual`, `CODE_SIGN_IDENTITY: "-"`,
   `DEVELOPMENT_TEAM: ""`, `PROVISIONING_PROFILE_SPECIFIER: ""`** in the spec; on the command
   line `CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES`. With these, both the app and the
   embedded `.appex` are signed ad-hoc with their entitlements embedded (Debug adds
   `com.apple.security.get-task-allow`; Release does not). `ENABLE_HARDENED_RUNTIME: NO` for
   local dev; turn it on (plus timestamp) only when a Developer ID exists.
3. **Finder Sync extension requirements**: `type: app-extension`, Info.plist
   `NSExtension.NSExtensionPointIdentifier = com.apple.FinderSync`,
   `NSExtensionPrincipalClass = $(PRODUCT_MODULE_NAME).FinderSync` (Swift class name is
   module-qualified), a subclass of `FIFinderSync` that sets
   `FIFinderSyncController.default().directoryURLs` in `init`, entitlements
   `com.apple.security.app-sandbox = true` (mandatory for extensions) plus
   `com.apple.security.files.user-selected.read-only`, and the extension's bundle id prefixed by
   the host app's (`com.yrambler2001.7zip.FinderSync`). Embed via
   `dependencies: - target: <ext>  embed: true` (XcodeGen puts it in `Contents/PlugIns/`).
   `xcodebuild` registers the built `.appex` with LaunchServices, so `pluginkit -m -i <id>`
   lists it before the app is ever opened; every build in a *different* DerivedData/config
   registers another copy — clean stale ones with `pluginkit -r <path>` or the wrong copy may be
   the one Finder loads. Keka's `com.aone.keka.KekaFinderIntegration` is also installed on this
   machine; Finder Sync extensions from different apps coexist.
4. **C++ inside a static library needs `-lc++` on the app target** (`OTHER_LDFLAGS`), otherwise the
   Swift app fails to link with `Undefined symbols: std::__1::basic_string…`. Xcode only
   auto-links libc++ when the linking target itself has C++ sources. (An Objective-C++ `.mm`
   file in the app or in the `SevenZipKit` framework target would also do it.)
5. **`NSLog` with a non-`CVarArg` argument does not compile under Xcode 26.6**: `NSLog("%p", ptr)`
   with an `UnsafeRawPointer` fails with `'NSLog' is unavailable: Variadic function is
   unavailable` (String, Array, Int, NSString arguments are fine). Use `os.Logger`.
   `Logger(...).info` messages are not persisted by `log show`; use `log stream` while the app
   runs or `.notice`/`.error` levels.
6. **Xcode 26 Debug builds split the app into `<App>.debug.dylib` + `__preview.dylib`**; the main
   Mach-O is a stub, so `otool -L <App>` shows nothing interesting — inspect
   `<App>.debug.dylib`. Release builds are a single executable (libc++ and Swift libs linked
   there). Both configurations code-sign fine. `ENABLE_DEBUG_DYLIB: NO` should disable it (not
   tested).
7. **The arm64 assembly needs no flags**: Xcode compiles `.S` as `-x assembler-with-cpp` with the
   target's `GCC_PREPROCESSOR_DEFINITIONS`/`HEADER_SEARCH_PATHS`; `LzmaDecOpt.S` finds
   `7zAsm.S` next to itself. Do **not** add `7zAsm.S` as a source (it is include-only). Define
   `Z7_LZMA_DEC_OPT=1` on the target that compiles `C/LzmaDec.c`, otherwise the C fallback is
   used and the `.S` object is dead weight. `LzmaDecOpt.S` has **no** `__aarch64__` guard: a
   universal (`ARCHS = arm64 x86_64`) build must exclude it for x86_64
   (`EXCLUDED_SOURCE_FILE_NAMES[arch=x86_64] = LzmaDecOpt.S`) and not define
   `Z7_LZMA_DEC_OPT` there (the x86 assembly is MASM `.asm`, unusable by Xcode). The probe pins
   `ARCHS: arm64`.
8. **Match the upstream compile environment** for the engine target: `-D_FILE_OFFSET_BITS=64
   -D_LARGEFILE_SOURCE -D_REENTRANT -DNDEBUG -fPIC`, `-O2`, `-std=c++11`
   (`CLANG_CXX_LANGUAGE_STANDARD: c++11`; Xcode's default is gnu++20 and was not tested against
   the engine), no `-Werror -Weverything` (Xcode's default warning set is much smaller and the
   code is known clean under the stricter set anyway). `MACOSX_DEPLOYMENT_TARGET: "14.0"` both in
   `options.deploymentTarget` and `settings` so `LSMinimumSystemVersion` and `minos` agree.
9. **`SWIFT_VERSION` must be set explicitly** (XcodeGen does not default it). `6.0` compiled the
   AppKit delegate and the `FIFinderSync` subclass without concurrency diagnostics; the
   orchestration conventions say Swift 5.9+, so `5.0` is equally fine.
10. `xcodebuild` emits `ld: warning: Could not parse or use implicit file …/SwiftUICore.tbd:
    cannot link directly with 'SwiftUICore' because product being built is not an allowed
    client of it` on some links (seen once, on the failing link of a pure-AppKit app). Benign.
11. `spctl --assess` rejects ad-hoc bundles; that only matters once the app leaves this machine
    (a downloaded copy gets a quarantine attribute and Gatekeeper blocks it). Distribution
    requires Developer ID + notarization (`notarytool`, `stapler` are present; no certificate is).

---

## 6. Licensing notes for redistributing `Lang/` and `SFX/`

Source of truth: `Mac/Resources/SFX/License.txt` (identical to `DOC/License.txt` in this tree),
7-Zip Copyright (C) 1999-2026 Igor Pavlov.

- **7-Zip as a whole**: GNU LGPL v2.1 or later. `7z.dll` (and therefore the archive engine we
  compile in place, including `CPP/7zip/Compress/Rar*` and `CPP/7zip/Archive/Rar/`) is LGPL with
  the **unRAR license restriction**: the RAR decompression code may not be used to develop a RAR
  (WinRAR) compatible archiver. Parts are BSD 3-clause (LZFSE-related) and BSD 2-clause (Zstd
  decoder). `License.txt` says: *"Redistributions in binary form must reproduce related license
  information from this file."* → the macOS bundle must ship `License.txt` (e.g. as
  `Resources/License.txt` and in the About dialog), exactly as the Windows installer does.
- **`Lang/*.txt`, `Lang/en.ttt`**: "All other files: the GNU LGPL" — the translations are LGPL
  files authored by Igor Pavlov (`en.ttt`) and volunteer translators credited in each file's
  header comments. Redistributing them unmodified with the license text is fine; keep the
  credit comment lines intact (the app can show them in the language dialog like 7zFM does).
- **`7z.sfx`, `7zCon.sfx`**: prebuilt LGPL binaries built by Igor Pavlov from
  `CPP/7zip/Bundles/SFXWin` and `SFXCon` (sources are in this tree). We redistribute them
  unmodified; LGPL §4/§6 obligations are met by shipping the license and the corresponding
  source being this repository. They contain no RAR code (the SFX stubs only decode 7z).
- The unRAR restriction does not affect the assets themselves but applies to the app binary
  that links the RAR decoder; state it in the About/licence screen.
- No other third-party licences are introduced by the assets. `7-zip.chm` was deliberately not
  copied; if a help book is built from it later, it is also LGPL.

---

## 7. Summary of deliverables from this task

| Path | What |
|---|---|
| `CPP/7zip/Bundles/Alone2/b/m_arm64/7zz` | console build, arm64, 26.03, ASM enabled (untracked; needs the root `.gitignore` entry from §2.4) |
| `Mac/Resources/Lang/` | 93 official localisation files |
| `Mac/Resources/SFX/` | `7z.sfx`, `7zCon.sfx`, `License.txt`, `readme.txt` |
| `Mac/scripts/fetch-assets.sh` | reproducible fetch/verify/extract/copy |
| `Mac/docs/04-toolchain.md` | this document |

Throwaway artefacts (scratchpad only, not in the repo): the probe project under
`…/scratchpad/sim/Mac/` (spec, sources, `DerivedData`, `build*.log`), `…/scratchpad/langcheck.py`,
`…/scratchpad/b/m_arm64_min14/7zz` (the `MACOSX_DEPLOYMENT_TARGET=14.0` proof build).
