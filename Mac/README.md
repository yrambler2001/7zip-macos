# 7-Zip for macOS

A native macOS build of the **7-Zip File Manager**. The archive engine is upstream 7-Zip 26.03,
compiled unchanged from `C/`, `CPP/` and `Asm/` in this repository; the user interface is a new
AppKit application written against it through an Objective-C++ bridge. There is no Windows
emulation layer and no third-party dependency — the whole app is Swift, AppKit and the 7-Zip
engine.

The specification is the Windows 7-Zip File Manager (`7zFM.exe`), item for item: the same menus,
the same dialogs with the same controls, the same keyboard map, the same settings, and the same
93 official language files. `Mac/docs/parity.md` says honestly how far that got.

* **Requires** macOS 14 (Sonoma) or newer, Apple Silicon (arm64).
* **Version** 26.03, bundle id `com.yrambler2001.7zip`.
* **Licence** upstream 7-Zip's (`DOC/License.txt`); the RAR code is under `DOC/unRarLicense.txt`.

---

## What you get

Everything the Windows file manager does with archives, in a Mac window:

* **Browse and edit archives in place** — 7z, ZIP, RAR, TAR, GZip, BZip2, XZ, Zstandard, CAB, ISO,
  DMG, WIM, MSI, RPM, DEB, APFS, VHD and the rest of the 40 registered types. Enter an archive as
  if it were a folder, including archives inside archives.
* **Two panels**, four view modes (large icons, small icons, list, details), sortable columns,
  flat view, folder history, ten Alt-digit favorites, and the 7zFM keyboard map.
* **Extract** with every path mode and overwrite mode, **Add to archive** with the full
  compression cascade (method, dictionary, word size, solid block, threads, memory), encryption
  including encrypted headers, multi-volume archives, and self-extracting archives.
* **Test**, **CRC / checksum** with all eleven hash methods, **Benchmark**, **Split**, **Combine**,
  **Link**, file **Properties** and ZIP **comments**.
* **Finder integration** — a 7-Zip submenu on the right-click menu, two Quick Actions, five
  Services and 40 file associations with their own document icons.
* **93 languages**, the official 7-Zip translations, switchable while the app runs.

* **The 7-Zip help pages**, bundled, opened in your browser from every Help button.

What is partial or deliberately different is listed in **`Mac/docs/parity.md`**; the short
version is under *Known limitations* below.

---

## Install

### From the disk image

```sh
Mac/scripts/package.sh          # writes Mac/build/7-Zip-26.03.dmg and prints its SHA-256
```

Open the image and drag **7-Zip** onto the **Applications** shortcut next to it. The image also
carries the licence and the upstream readme.

### First launch of an unsigned build

This build is **ad-hoc signed**: it has a valid signature, but not one issued by Apple, because
there is no Developer ID on the machine that builds it. What happens on first launch depends on
whether the file was downloaded:

* **Built locally** (or copied over the network with `scp`, `rsync`, AirDrop from your own Mac):
  it just opens. Nothing marked it as quarantined, so Gatekeeper never evaluates it.
* **Downloaded with a browser, or received through Mail or Messages**: macOS attaches a
  `com.apple.quarantine` attribute, Gatekeeper evaluates the app and refuses it — on macOS 15 and
  later with *"7-Zip" Not Opened — Apple could not verify "7-Zip" is free of malware*, and only an
  **Open Anyway** button in **System Settings ▸ Privacy & Security** will let it through. (The old
  right-click ▸ Open trick no longer works on macOS 15+.) So:

  1. Try to open the app once, and dismiss the warning.
  2. Open **System Settings ▸ Privacy & Security**, scroll to the Security section, and click
     **Open Anyway** next to the message about 7-Zip.
  3. Confirm with Touch ID or your password. It opens, and every later launch is silent.

  The command-line equivalent, if you prefer it, is `xattr -dr com.apple.quarantine /Applications/7-Zip.app`.

`spctl --assess` reports `rejected` for this build and that is expected; `codesign --verify --deep
--strict` reports it valid, which is the check that says the bundle is intact.

### A signed, notarized build

With a Developer ID in the keychain:

```sh
Mac/scripts/package.sh --identity "Developer ID Application: Your Name (TEAMID)" \
                       --team TEAMID \
                       --notary-profile my-notary-profile     # implies --notarize
```

That builds with the hardened runtime and a secure timestamp, signs the app, its framework and
all three extensions, signs the disk image, submits it with `xcrun notarytool --wait` and staples
the ticket. Without a Developer ID the notarization step is skipped with a printed note rather
than failing; asking for it anyway exits 3 and says why.

The whole path for a person who has the Apple Developer account, in order:

```sh
# 1. Once: a "Developer ID Application" certificate in the login keychain (Xcode ▸ Settings ▸
#    Accounts ▸ Manage Certificates ▸ +), then check that codesign sees it:
security find-identity -v -p codesigning
# 2. Once: an app-specific password (appleid.apple.com ▸ Sign-In and Security), stored for notarytool:
xcrun notarytool store-credentials 7zip-notary --apple-id you@example.com --team-id TEAMID
# 3. Every release:
Mac/scripts/package.sh -i "Developer ID Application: Your Name (TEAMID)" -T TEAMID -p 7zip-notary
# 4. Check what a downloaded copy will see:
spctl --assess --type open --context context:primary-signature -v Mac/build/7-Zip-26.03.dmg
xcrun stapler validate Mac/build/7-Zip-26.03.dmg
```

The app needs **no** hardened-runtime exception: it uses no JIT, loads no plug-ins and sends no
Apple events. That was checked by running an ad-hoc copy with `--options runtime` (only library
validation had to be relaxed for that local test, because ad-hoc signatures carry no Team ID; a
Developer ID signature gives the app and its framework the same one). The extensions keep their
sandbox entitlement and nothing asks for `get-task-allow`; `package.sh` asserts both.

---

## Build and run from source

```sh
export DEVELOPER_DIR=/Applications/Xcode.app     # every script does this itself too
Mac/scripts/build.sh                             # Debug, ad-hoc signed -> Mac/build/Debug/7-Zip.app
Mac/scripts/build.sh --release                   # Release
Mac/scripts/run.sh                               # build, then open the app
Mac/scripts/test.sh                              # the unit tests (~390)
Mac/scripts/test.sh -H                           # the app-hosted tests (~100)
Mac/scripts/test.sh --all                        # unit tests + the XCUITest suite
Mac/scripts/verify.sh                            # clean build + every suite + a written report
Mac/scripts/package.sh                           # the disk image
Mac/scripts/parity-check.sh                      # how much of the checklist is done
```

Every script takes `--help`, works from any directory and exits non-zero on failure.

You need **Xcode 26** at `/Applications/Xcode.app` and **XcodeGen** (`brew install xcodegen`) —
`Mac/7-Zip.xcodeproj` is generated from `Mac/project.yml` and is not in git. Nothing else: no
package manager, no vendored library. `Mac/docs/HANDOFF.md` has the full list of what a fresh
machine needs, including `sudo DevToolsSecurity -enable` before the UI tests can drive the app.

---

## The Finder extension

The app ships three extensions inside its bundle. macOS does not turn an extension on by itself,
so after the first launch:

**System Settings ▸ General ▸ Login Items & Extensions**

* under **File Providers**, switch on **7-Zip** — this is the Finder Sync extension, which puts
  the whole **7-Zip** submenu on Finder's right-click menu and a 7-Zip button on the Finder
  toolbar;
* under **Finder**, switch on **Extract with 7-Zip** and **Compress with 7-Zip** — the two Quick
  Actions, which appear in Finder's Quick Actions strip and in the right-click ▸ Quick Actions
  submenu.

The five **7-Zip: …** Services need no extension at all; they live under
**System Settings ▸ Keyboard ▸ Keyboard Shortcuts ▸ Services** and appear in the Services menu of
every app.

The same from the command line:

```sh
APP=/Applications/7-Zip.app
pluginkit -a "$APP/Contents/PlugIns/FinderSync.appex"
pluginkit -a "$APP/Contents/PlugIns/QuickActionExtract.appex"
pluginkit -a "$APP/Contents/PlugIns/QuickActionCompress.appex"
pluginkit -e use -i com.yrambler2001.7zip.FinderSync
pluginkit -e use -i com.yrambler2001.7zip.QuickActionExtract
pluginkit -e use -i com.yrambler2001.7zip.QuickActionCompress
pluginkit -m -p com.apple.FinderSync -v        # "+" enabled, "-" disabled, "!" blocked
```

The app's **Options ▸ 7-Zip** page shows the current `pluginkit` state, the command to enable it,
and which of the eleven menu entries to show. If Finder never shows the menu, reset Launch
Services with `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -kill -r -domain local -domain user`
and log out and in again; a managed Mac whose MDM profile denies public extension points blocks
it silently.

**What the 7-Zip menu offers** (the same eleven commands as the Windows shell extension): Open
archive, Open archive ▸ (as a specific format), Extract files…, Extract Here, Extract to
*"name/"*, Test archive, Add to archive…, Compress and email…, Add to *"name.7z"*, Add to
*"name.zip"*, and CRC SHA ▸ with the ten hash methods, `*`, `SHA-256 → file.sha256` and
Checksum : Test.

---

## What macOS will ask you for, and why

The app is **not sandboxed** — a file manager that can only see files you have individually
picked is not a file manager. macOS therefore asks for consent the first time it touches a
protected location, and the app declares a reason for each:

| Prompt | When | Why |
|---|---|---|
| **Desktop / Documents / Downloads** folder access | the first time you browse into one | the panel lists and reads files there |
| **Removable volumes** | the first time you open a USB disk or SD card | the same, for a mounted volume |
| **Network volumes** | the first time you open a file server | the same, over a network mount |
| **Files and Folders** (generic) | extracting to, or compressing from, a protected folder | writing the output |

Declining a prompt is safe: the panel shows the folder as empty until you allow it, which you can
do later under **System Settings ▸ Privacy & Security ▸ Files and Folders**.

The two Finder extensions *are* sandboxed, because macOS refuses to load one that is not. They
read only the files you selected in Finder and the app's own settings.

The app asks for nothing else: no network access, no login item, no background agent, no
analytics.

---

## Language

**Options ▸ Language** (⌘, then the Language tab) lists the 92 bundled translations with their
English and native names and how complete each one is, plus *Auto* (follow the system language)
and English. The change takes effect immediately — the menu bar, the toolbar, the columns and
every open dialog re-label themselves; Cancel puts it back.

The files are the official 7-Zip `Lang/*.txt`, bundled unmodified. A string a translation does
not define falls back to English, so a partly translated language is usable rather than blank.
28 of the 92 are complete; 24 of them are missing more than a quarter of the strings the app asks
for, and those show a good deal of English alongside their own language. The full per-language table is in
`Mac/docs/reports/packaging.md`.

---

## Known limitations

The honest list is `Mac/docs/parity.md`. The short version:

* **Opening several archives from Finder at once**: the first one opens in the front window, the
  others in windows of their own (Windows opens one window per archive).
* **Re-launching the app** (Dock, Finder) brings its window forward instead of opening a new one,
  as Mac apps do; `open -n -a 7-Zip` starts a second window.
* **Right-to-left languages are not mirrored** — the text is right, the layout is left-to-right.
* **About a quarter of the translations are incomplete upstream** and fall back to English for
  what they miss.
* **Alternate data streams and NT security descriptors are hidden**, deliberately: they have no
  macOS equivalent. POSIX mode, owner, group and link target are shown instead.
* **The Finder menu, a drag into Finder, a drop on the Dock icon and the Dock-tile progress** are
  tested up to the macOS boundary but have not been looked at by a person on a signed build
  (`Mac/docs/reports/release.md` lists the checks).
* `7z.exe`-style command-line use exists (`7-Zip.app/Contents/MacOS/7-Zip a archive.7z files…`)
  and covers the 7zG grammar, but it is a GUI app in command mode, not a console tool. For
  scripting, build the real console binary:
  `cd CPP/7zip/Bundles/Alone2 && make -f ../../cmpl_mac_arm64.mak`.

---

## Where the documentation lives

| File | What it is |
|---|---|
| `Mac/docs/parity.md` | what a user gets today versus the Windows File Manager: complete, partial, deliberately different, missing |
| `Mac/docs/PROGRESS.md` | the 496-item parity checklist, per scope |
| `Mac/docs/00-orchestration.md` | the project contract: decisions, layout, file ownership |
| `Mac/docs/architecture.md` | how the app and the bridge are put together |
| `Mac/docs/01-fm-feature-inventory.md`, `01b-fm-dialogs-settings.md` | the specification: every 7zFM feature, dialog, control and setting |
| `Mac/docs/02-engine-api.md` | which engine sources are compiled and how the bridge calls them |
| `Mac/docs/03-shell-integration-inventory.md` | the Windows shell extension and the macOS mechanisms that replace it |
| `Mac/docs/04-toolchain.md` | build recipe and toolchain traps |
| `Mac/docs/HANDOFF.md` | what a fresh machine needs, the scope status and how to resume |
| `Mac/docs/reports/release.md` | the last pass: what was closed, the decisions left, the manual checks |
| `Mac/docs/upstream-patches.md` | every change made to upstream C/C++ (15 files, all guarded) |
| `Mac/docs/api/*.md` | the public API each part of the app exposes |
| `Mac/docs/reports/*.md` | what each piece of work did, verified and left undone |
| `Mac/docs/reports/screenshots/` | screenshots taken by the UI tests |
