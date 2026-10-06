# `docicons`: Finder document icons are the original Windows 7-Zip icons

> **Publication note:** all but a few showcase images under `docs/reports/screenshots/` were removed from the repository before publication. Paths below that point into them are kept as a record of what was measured.

Branch `mac/docicons`. Owned: `Mac/scripts/make-icons.{sh,py,swift}`, `Mac/Resources/Icons/doc-*.icns`,
`Mac/Resources/Assets.xcassets/doc-*.imageset`, `Mac/docs/api/icons.md`. One value changed in
`Mac/App/Info.plist` (owned by `finder`, assigned to this scope by the request): the catch-all
document type's icon.

## 1. What changed

**User decision:** the Finder and Desktop icon of every associated archive type is the icon
Windows 7-Zip shows, pixel for pixel. The page-style icons drawn by `make-icons.swift` (white page,
fold, manila band, badge with the format name) are gone.

`make-icons.py` `stage_doc_icons` builds each `doc-<name>.icns` from
`CPP/7zip/Archive/Icons/<name>.ico`. Each format `.ico` holds a 16 px and a 32 px frame (8-bit
paletted with an AND mask; `7z.ico` also has 4-bit copies, and the deepest is used, as on a
true-colour display). For each pixel size the generator takes the frame Windows would draw at that
size and enlarges it by an integer factor, nearest-neighbour:

| `.icns` slot | px | source |
|---|---|---|
| 16 pt @1x | 16 | 16 px frame ×1 |
| 16 pt @2x, 32 pt @1x | 32 | 32 px frame ×1 |
| 32 pt @2x | 64 | 32 px frame ×2 |
| 128 / 256 / 512 pt @1x and @2x | 128 … 1024 | 32 px frame ×4 … ×32 |

16 pt @2x uses the 32 px frame, not the 16 px frame ×2. That is what Windows does: a 32 px slot
(the small icon at 200 % DPI, or a large icon at 100 %) loads the 32 px frame. Nothing is added: no
page, squircle, padding, shadow or label. The AND-mask transparency is carried over pixel for
pixel. The lid of the original art reaches the top-right corner pixel, so the old "corners must be
clear" check now applies to the app icon only.

**Mapping.** It is unchanged and was already right. The 40 extensions of
`Format7zF/resource.rc` STRINGTABLE 100 map to the 27 icons by the `ext:index` pairs, and
`<index> ICON "<name>.ico"` gives the file (`001` → `split.ico`, `lzma` → `lzma.ico`, `z`/`taz` →
`z.ico`, `vhd`/`vhdx` → `vhd.ico`, `wim`/`swm`/`esd` → `wim.ico`, `squashfs`, `cpio`, `fat`,
`ntfs`, `hfs`, `apfs`, `dmg`, …). The generator cross-checks that table against `FileTypes.swift`,
and `FinderCommandTests` checks it against `Info.plist`. The full table is in
`Mac/docs/api/icons.md`.

**Types with no Windows icon.** Windows 7-Zip registers a `DefaultIcon` only for those 40
extensions. `SystemPage.cpp` lists the `GetExtensions()` of `ArchiveFolderOpen.cpp`, which are the
STRINGTABLE 100 pairs only, and `RegistryAssociations.cpp` `AddShellExtensionInfo` writes
`<dll>,<index>`. Any other file a user opens with 7zFM ("Open with ▸ Always") has no DefaultIcon,
so Explorer draws it with the program's own icon, `FM.ico`. The mac port's catch-all
"Archive (7-Zip)" document type (`jar`, `msi`, `vmdk`, `lz`, … 80 extensions) used `doc-7z`, which
Windows never shows for those types. It now uses a new `doc-fm.icns`, which is `FM.ico` built by the
same rule (its 48 px frame divides no macOS size, so 64 px and up come from the 32 px frame).

**No chrome on macOS 26.** With an `.icns` named by `CFBundleTypeIconFile`, macOS 26.6 (25G83)
draws the icon exactly as supplied. `NSWorkspace.icon(forFile:)` returns our pixels unchanged at
every size (§3), with no page or badge frame. The system wraps an icon only when the type has no
icon file, or when `CFBundleTypeIconSystemGenerated` = 1. Setting it to 0 explicitly was tried on
the installed copy and changed nothing, so the key is not added.

**Generator.** The Swift renderer's drawing code and the badge/label/palette tables are deleted.
`make-icons.swift` now only lays out `icons-contact-sheet.png`. `stage_assemble` replaces only
`doc-*.icns`. The first run of the new code deleted the whole directory, including feel3's
`fm-<name>.ico` list icons. That was caught before commit and fixed.

## 2. The check

`make-icons.sh` (verify stage, `verify_icns`) unpacks every shipped `doc-*.icns` with
`iconutil -c iconset` and checks each of its ten slots. The slot must equal some frame of the source
`.ico`, enlarged by an integer factor, nearest-neighbour: the same alpha at every pixel, and the same
RGB wherever a pixel is visible. It must also be the frame Windows draws at that size. Anything
smoothed, redrawn, padded, masked or shadowed fails. A wrong set of `doc-*.icns` files also fails.

- Normal run: `verified 203 PNGs`, `verified 280 .icns slots against their .ico frames`, exit 0.
- Negative test: the old page-style `doc-zip.icns` was put back, and all ten of its slots failed
  with "not an integer nearest-neighbour enlargement of any frame of CPP/7zip/Archive/Icons/zip.ico".
- Reproducible: a second full run rewrote every asset byte for byte. The `.icns` in the installed
  app is `cmp`-identical to the committed one.

## 3. Installed and verified through Launch Services

The Release build is in `/Applications/7-Zip.app` (ad-hoc, `codesign -v --deep` ok). The steps:

1. The user's running copy was asked to quit (`NSRunningApplication.terminate()`, exit within 2 s).
2. The old copy was moved to `~/7-Zip-backup.app`, the new one copied with `ditto` and verified.
3. The backup was unregistered and removed, then `lsregister -f`, and the app was touched.
4. The user's copy was relaunched in the background, because it had been running.

Unregistering the backup also drops PlugInKit's registrations of the extensions under that
bundle id, so all three appexes were re-added with `pluginkit -a`. FinderSync, QuickActionExtract
and QuickActionCompress are each listed once, from `/Applications`, elected `+`. Later, `test.sh -H`
left Finder on this worktree's Debug extension. That was handed back the same way (other copies
removed, this tree's builds unregistered from LS). 125 stale Launch Services registrations of
old 7-Zip builds were dropped as well: other worktrees' DerivedData copies and a `/Volumes/7-Zip
26.03` copy whose DMG is no longer mounted. They are build products, and LS re-registers any of them
that is launched. Default-app choices were not touched (no `LSSetDefaultRoleHandler`).

Verification uses a probe that does what Finder does. It makes a sample file of every type, asks
`NSWorkspace.icon(forFile:)`, renders the image at 16/32/64/128/256 pt (1x and 2x), and
pixel-compares each size with the generated PNG of that pixel size.

- `screenshots/docicons-sheet.png`: every type of the 40, plus six catch-all samples, at 16, 32, 64,
  128 and 256 pt at 1x, with the default app in the label (green = 7-Zip).
- `screenshots/docicons-finder-icons.png`: a Finder-like icon view at 64 pt, Retina.
- `screenshots/docicons-finder-list.png`: a Finder-like list view at 16 pt with Kind, Retina.

Results for the 27 types that open with 7-Zip: every size of 22 types is pixel-identical to the
`.icns`. For 5 types (`7z`, `zip`, `001`, `wim`, `xar`), only the pixel sizes that Finder had already
drawn before the install come back stale: 32 and 64 px (16 pt and 32 pt on Retina), and 16/64 px
at 1x. Those slots show the system's generic archive page or the old page-style 7-Zip art. Larger
sizes are exact. The catch-all samples that open with 7-Zip (`lz`, `msi`, `vmdk`, `qcow2`) show
`FM.ico`, exact at every size.

**The stale slots come from IconServices' system cache** (`/Library/Caches/com.apple.iconservices.store`,
owned by `_iconservices`). Each of the following was tried, and none of them invalidates those
entries:

- `lsregister -f`, `-f -R`, `-u` then `-f`
- touching the bundle and the `.icns` files
- a new `CFBundleVersion`
- renaming the `.icns` resource
- `CFBundleTypeIconSystemGenerated` = 0
- removing every other 7-Zip registration
- restarting `iconservicesagent`

All were done on the installed copy and reverted. Clearing the system cache needs an administrator:

```sh
sudo rm -rf /Library/Caches/com.apple.iconservices.store
killall Dock Finder        # then log out and in (or restart) so iconservicesd rebuilds it
```

## 4. Which of the user's types show the new icons

A type shows the 7-Zip icon in Finder only when 7-Zip is its default app. Measured after install:

- **Open with 7-Zip, so they show the new icons (27 of 40):** `7z zip rar 001 cab lzma bzip2 tpz zst
  tzst taz lzh lha rpm deb arj vhd vhdx wim swm esd fat ntfs hfs xar squashfs apfs`. Five of these
  need the cache flush above for their small Retina sizes.
- **Open with Archive Utility (11):** `xz txz tar cpio bz2 tbz2 tbz gz gzip tgz z`.
- **Open with DiskImageMounter (2):** `iso dmg`.
- **Catch-all:** most of the 80 open with 7-Zip and show `FM.ico`. These belong to other apps:
  - `jar` → JavaLauncher
  - `odt docx doc` → TextEdit
  - `epub` → Books
  - `ipa` → iOS App Installer
  - `img` → DiskImageMounter
  - `pkg` → Installer
  - `xip` → Archive Utility
  - `obj` → Xcode

To make 7-Zip the default for the others (not done here):

1. **7-Zip ▸ Options ▸ System**: tick the types and press OK or Apply.
2. **Finder**: select a file of the type ▸ File ▸ Get Info ▸ "Open with" ▸ 7-Zip ▸ **Change All…**.

## 5. Verification

- `make-icons.sh`: green (§2).
- `Mac/scripts/build.sh` (Debug): BUILD SUCCEEDED, no warnings from `Mac/` code.
- `build.sh Release`: BUILD SUCCEEDED.
- `test.sh`: 401 passed.
- `test.sh -H`: 273 passed. `OptGapsTests` checks that every `doc-<name>.icns` is bundled, and
  `FinderCommandTests` checks the plist icon table.
- The UI suite was not run, because no UI code changed. The Options ▸ System rows load
  `doc-<name>.icns`, so they now show the original 16 px frames.
- Screenshot churn from the test runs was reverted. `icons-contact-sheet.png` is regenerated: it
  shows the new art and `doc-fm`.
