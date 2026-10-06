# `icons` — app icon, document icons, and the generator that makes them

Everything under `Mac/Resources/Assets.xcassets` and `Mac/Resources/Icons` is **generated**.
Never hand-edit a PNG, a `Contents.json` or an `.icns` there: change
`Mac/scripts/make-icons.{sh,py,swift}`, re-run the generator and commit the result.

All art derives from the upstream Windows icon resources, which are read-only inputs:

| Input | Used for |
|---|---|
| `CPP/7zip/Archive/Icons/*.ico` (27 files) | one document icon each, the original frames enlarged nearest-neighbour (`docicons`) |
| `CPP/7zip/UI/FileManager/FM.ico` | the app icon itself, frame for frame, and `doc-fm` (the catch-all document type) |
| `CPP/7zip/UI/FileManager/7zipLogo.ico` | the About-box wordmark, shipped unscaled as `AboutLogo.imageset` (IDI_LOGO) |
| `CPP/7zip/Bundles/SFXWin/7z.ico` | the SFX stub icon (decoded and archived) |
| `CPP/7zip/Bundles/Format7zF/resource.rc` | `<index> ICON "<name>.ico"` (0–26) and STRINGTABLE 100, the `ext:index` string |
| `Mac/App/Support/FileTypes.swift` | the port's authoritative extension → icon-index table (`options` scope) |

The generator **cross-checks** `FileTypes.swift` against STRINGTABLE 100 and fails loudly if they
disagree, so the two can never drift. Both currently carry **40** extensions mapped onto **27**
icons (`requests.md` "Spec corrections": the list is 40, not the 39 that `03 §3.1` claims).

## Running it

```sh
export DEVELOPER_DIR=/Applications/Xcode.app      # `swift` needs it; nothing else does
Mac/scripts/make-icons.sh                          # everything: extract, draw, assemble, sheet, verify
Mac/scripts/make-icons.sh --stage draw             # one stage: extract | draw | assemble | sheet | verify
Mac/scripts/make-icons.sh --dump 7z                # ASCII-dump an upstream .ico (how the palette was read)
```

No third-party tool is involved: `python3` decodes the `.ico` files, enlarges their frames and
assembles the catalogue, `iconutil` packs the `.icns`, and `swift` (from Xcode) only renders the
contact sheet. Nothing is drawn. There is
no ImageMagick, Pillow or `rsvg` dependency, and `sips` is not asked to read `.ico` — it cannot.

Stages:

1. **extract** — decodes every frame of every upstream `.ico` into
   `Mac/build/icons/frames/<name>/<w>x<h>-<bpp>bpp.png` (PNG-compressed frames, 32/24-bit BMP
   frames with or without a real alpha channel, and 8/4/1-bit paletted BMP frames whose
   transparency is the trailing 1-bit AND mask — 7-Zip's are all 8bpp + AND mask). Writes
   `Mac/build/icons/icons-manifest.json`: each format icon's index, name, frames, formats and
   extensions.
2. **draw** — draws nothing (the stage name is historical). `stage_doc_icons` writes every
   document icon at every pixel size as an `.ico` frame enlarged by an integer factor,
   nearest-neighbour (see "Document icons" below), and `stage_app_icon` writes the app icon's PNGs
   straight from `FM.ico`.
3. **assemble** — lays the PNGs out as `AppIcon.appiconset`, 27 `doc-<name>.imageset`s, and 28
   `.icns` files (27 formats + `doc-fm`) via `iconutil`. Only `doc-*.icns` in `Mac/Resources/Icons`
   are replaced; the `fm-<name>.ico` copies the file list uses (feel3) are left alone.
4. **sheet** — writes `Mac/build/screenshots/icons-contact-sheet.png`: every icon at 128 pt
   on a checkerboard, with its name and the extensions it serves.
5. **verify** — reads all 203 emitted PNGs back and fails on a wrong pixel size, a lost alpha
   channel, a colour that is not in the source `.ico`, or (app icon) an opaque corner. Then it
   unpacks every shipped `doc-*.icns` with `iconutil -c iconset` and fails unless each of its ten
   slots equals some frame of the source `.ico` enlarged by an integer factor, nearest-neighbour
   (same alpha everywhere, same RGB wherever visible), and unless that frame is the one Windows
   draws at that size. An old page-style `.icns` fails all ten slots (checked).

`Mac/build/icons/` is scratch (git-ignored). Nothing there is shipped.

## What is generated

### App icon — `Mac/Resources/Assets.xcassets/AppIcon.appiconset`

Ten slots, `icon_<pt>x<pt>[@2x].png`, covering 16, 32, 128, 256 and 512 pt at 1× and 2×
(7 distinct pixel sizes, 16 … 1024). Each slot has its own file even where two slots are the same
pixel size: `actool` collapses identical *filenames* and then emits an `AppIcon.icns` missing the
collapsed slots.

The app icon **is** the original 7zFM icon, `CPP/7zip/UI/FileManager/FM.ico` (`winmatch`, user
decision): nothing is redrawn, there is no macOS rounded-square mask, no added margin and no
shadow. `FM.ico` has three frames, 16, 32 and 48 px (4-bit and 8-bit paletted, AND-mask
transparency). Each macOS pixel size takes the nearest frame (the larger on a tie) and resamples it
nearest-neighbour to fill the canvas, so every output pixel is one source pixel unchanged:

| Pixel size | FM.ico frame |
|---|---|
| 16 | 16 (1:1) |
| 32 | 32 (1:1) |
| 64 … 1024 | 48 |

`verify` checks that the app PNGs contain only `FM.ico`'s own colours. The 32 px slot is
pixel-identical to the icon Windows' shell extracts from 7zFM.exe 25.01
(`ai/reports/winmatch.md`).

`Info.plist` needs nothing: `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `Mac/project.yml`
makes `actool` write `CFBundleIconFile` / `CFBundleIconName` and emplace `AppIcon.icns`.

### Document icons — `Mac/Resources/Icons/doc-<name>.icns` (and `doc-<name>.imageset`)

**The original Windows format icons, pixel for pixel** (`docicons`, user decision; report
`ai/reports/docicons.md`). One per upstream format icon, not per extension: 27 icons for 40
extensions. `<name>` is the `.ico` stem, so `001` uses `doc-split`. Plus `doc-fm`, which is
`FM.ico`: the icon of the catch-all "Archive (7-Zip)" document type, because Windows registers a
DefaultIcon only for the 40 STRINGTABLE 100 extensions and Explorer draws any other file opened with
7zFM with the program's own icon.

Every format `.ico` has a 16 px and a 32 px frame (8-bit paletted + AND mask; `7z.ico` also has
4-bit copies, and the deepest is used, as on a true-colour display). Each size takes the frame
Windows picks for that pixel size and enlarges it by an integer factor, nearest-neighbour. Nothing
is added: no page, squircle, padding, shadow or label, and the AND-mask transparency is kept.

| `.icns` slot | pixels | source |
|---|---|---|
| 16 pt @1x | 16 | 16 px frame ×1 |
| 16 pt @2x | 32 | 16 px frame ×2 (`docicons2`: a small icon is the small frame at every scale, as in the panel list) |
| 32 pt @1x | 32 | 32 px frame ×1 |
| 32 pt @2x | 64 | 32 px frame ×2 |
| 128 pt @1x / @2x | 128 / 256 | 32 px frame ×4 / ×8 |
| 256 pt @1x / @2x | 256 / 512 | 32 px frame ×8 / ×16 |
| 512 pt @1x / @2x | 512 / 1024 | 32 px frame ×16 / ×32 |

(`doc-fm` has a 48 px frame too, but 48 divides none of the macOS sizes above 32, so it also
uses the 32 px frame from 64 px up.)

Delivery:

* `doc-<name>.icns` — copied flat into `Contents/Resources`; `CFBundleTypeIconFile` names it
  without the extension. This is what Finder uses. The Options ▸ System rows draw
  `PanelArchiveIcons`' small icon instead (`docicons2`), the same image as the panel list: the
  16 px frame, enlarged by whole pixels on Retina.
* `doc-<name>.imageset` — 1× = 256 px, 2× = 512 px (the 32 px frame ×8 / ×16), for
  `NSImage(named:)`.

`CFBundleTypeIconSystemGenerated` is not set: with an `.icns` named by `CFBundleTypeIconFile`,
macOS 26 (25G83) draws the `.icns` as is, with no page or badge chrome (measured through
`NSWorkspace.icon(forFile:)`; setting the key to 0 changes nothing).

## Extension → icon mapping

Every one of the 40 extensions in `FileTypes.swift` has artwork; **no extension falls back**,
because all 27 upstream icons exist and the association string only ever references 0–26. The
Badge and Label columns describe the upstream `.ico` art (they were inputs to the old drawn icons).
Every other extension 7-Zip can open (the catch-all document type) uses `doc-fm`.

| Ext | Icon index | Image set | `.icns` | Badge | Label |
|---|---|---|---|---|---|
| `7z` | 0 (`7z.ico`) | `doc-7z` | `doc-7z.icns` | `#000080` | 7Z |
| `zip` | 1 (`zip.ico`) | `doc-zip` | `doc-zip.icns` | `#0000ff` | ZIP |
| `bz2` | 2 (`bz2.ico`) | `doc-bz2` | `doc-bz2.icns` | `#0000ff` | BZ2 |
| `bzip2` | 2 (`bz2.ico`) | `doc-bz2` | `doc-bz2.icns` | `#0000ff` | BZ2 |
| `tbz2` | 2 (`bz2.ico`) | `doc-bz2` | `doc-bz2.icns` | `#0000ff` | BZ2 |
| `tbz` | 2 (`bz2.ico`) | `doc-bz2` | `doc-bz2.icns` | `#0000ff` | BZ2 |
| `rar` | 3 (`rar.ico`) | `doc-rar` | `doc-rar.icns` | `#0000ff` | RAR |
| `arj` | 4 (`arj.ico`) | `doc-arj` | `doc-arj.icns` | `#0000ff` | ARJ |
| `z` | 5 (`z.ico`) | `doc-z` | `doc-z.icns` | `#0000ff` | Z |
| `taz` | 5 (`z.ico`) | `doc-z` | `doc-z.icns` | `#0000ff` | Z |
| `lzh` | 6 (`lzh.ico`) | `doc-lzh` | `doc-lzh.icns` | `#0000ff` | LZH |
| `lha` | 6 (`lzh.ico`) | `doc-lzh` | `doc-lzh.icns` | `#0000ff` | LZH |
| `cab` | 7 (`cab.ico`) | `doc-cab` | `doc-cab.icns` | `#0000ff` | CAB |
| `iso` | 8 (`iso.ico`) | `doc-iso` | `doc-iso.icns` | `#0000ff` | ISO |
| `001` | 9 (`split.ico`) | `doc-split` | `doc-split.icns` | `#0000ff` | 001 |
| `rpm` | 10 (`rpm.ico`) | `doc-rpm` | `doc-rpm.icns` | `#0000ff` | RPM |
| `deb` | 11 (`deb.ico`) | `doc-deb` | `doc-deb.icns` | `#0000ff` | DEB |
| `cpio` | 12 (`cpio.ico`) | `doc-cpio` | `doc-cpio.icns` | `#0000ff` | CPIO |
| `tar` | 13 (`tar.ico`) | `doc-tar` | `doc-tar.icns` | `#0000ff` | TAR |
| `gz` | 14 (`gz.ico`) | `doc-gz` | `doc-gz.icns` | `#0000ff` | GZ |
| `gzip` | 14 (`gz.ico`) | `doc-gz` | `doc-gz.icns` | `#0000ff` | GZ |
| `tgz` | 14 (`gz.ico`) | `doc-gz` | `doc-gz.icns` | `#0000ff` | GZ |
| `tpz` | 14 (`gz.ico`) | `doc-gz` | `doc-gz.icns` | `#0000ff` | GZ |
| `wim` | 15 (`wim.ico`) | `doc-wim` | `doc-wim.icns` | `#0000ff` | WIM |
| `swm` | 15 (`wim.ico`) | `doc-wim` | `doc-wim.icns` | `#0000ff` | WIM |
| `esd` | 15 (`wim.ico`) | `doc-wim` | `doc-wim.icns` | `#0000ff` | WIM |
| `lzma` | 16 (`lzma.ico`) | `doc-lzma` | `doc-lzma.icns` | `#0000ff` | LZMA |
| `dmg` | 17 (`dmg.ico`) | `doc-dmg` | `doc-dmg.icns` | `#0000ff` | DMG |
| `hfs` | 18 (`hfs.ico`) | `doc-hfs` | `doc-hfs.icns` | `#0000ff` | HFS |
| `xar` | 19 (`xar.ico`) | `doc-xar` | `doc-xar.icns` | `#0000ff` | XAR |
| `vhd` | 20 (`vhd.ico`) | `doc-vhd` | `doc-vhd.icns` | `#0000ff` | VHD |
| `vhdx` | 20 (`vhd.ico`) | `doc-vhd` | `doc-vhd.icns` | `#0000ff` | VHD |
| `fat` | 21 (`fat.ico`) | `doc-fat` | `doc-fat.icns` | `#0000ff` | FAT |
| `ntfs` | 22 (`ntfs.ico`) | `doc-ntfs` | `doc-ntfs.icns` | `#0000ff` | NTFS |
| `xz` | 23 (`xz.ico`) | `doc-xz` | `doc-xz.icns` | `#0000ff` | XZ |
| `txz` | 23 (`xz.ico`) | `doc-xz` | `doc-xz.icns` | `#0000ff` | XZ |
| `squashfs` | 24 (`squashfs.ico`) | `doc-squashfs` | `doc-squashfs.icns` | `#0000ff` | SQUASHFS |
| `apfs` | 25 (`apfs.ico`) | `doc-apfs` | `doc-apfs.icns` | `#0000ff` | APFS |
| `zst` | 26 (`zst.ico`) | `doc-zst` | `doc-zst.icns` | `#0000ff` | ZST |
| `tzst` | 26 (`zst.ico`) | `doc-zst` | `doc-zst.icns` | `#0000ff` | ZST |

The same table is emitted as JSON at `Mac/build/icons/extension-map.json`
(`{extension, icon, iconIndex, icns, imageSet}` per row) if the `finder` scope would rather
generate its plist entries than copy the table.

## What the `finder` scope must put in `Info.plist`

`Mac/App/Info.plist` is owned by `finder` (`docicons` changed one value: the catch-all's icon is
`doc-fm`). One
`CFBundleDocumentTypes` entry per extension, with `CFBundleTypeIconFile` naming the `.icns`
**without the extension**. Fields other than the icon (`LSItemContentTypes`, `LSHandlerRank`,
`CFBundleTypeRole`) are the `finder` scope's call — the shape below only fixes the icon keys.

```xml
<key>CFBundleDocumentTypes</key>
<array>
  <dict>
    <key>CFBundleTypeName</key>            <string>7Z Archive</string>
    <key>CFBundleTypeExtensions</key>      <array><string>7z</string></array>
    <key>CFBundleTypeIconFile</key>        <string>doc-7z</string>
    <key>CFBundleTypeRole</key>            <string>Editor</string>
    <key>LSHandlerRank</key>               <string>Owner</string>
    <key>LSItemContentTypes</key>          <array><string>org.7-zip.7z-archive</string></array>
  </dict>
  <dict>
    <key>CFBundleTypeName</key>            <string>BZIP2 Archive</string>
    <key>CFBundleTypeExtensions</key>      <array>
      <string>bz2</string><string>bzip2</string><string>tbz2</string><string>tbz</string>
    </array>
    <key>CFBundleTypeIconFile</key>        <string>doc-bz2</string>
    …
  </dict>
  …
</array>
```

Notes for that work:

* `CFBundleTypeName` / `LSItemContentTypes` should come from `SevenZipFileType.localizedDescription`
  and `.utType` in `Mac/App/Support/FileTypes.swift`; the icon name is the only thing this scope
  owns, and it is always `doc-` + the `iconFileName` that struct already computes
  (`FileTypes.iconNames[iconIndex]`).
* Extensions that share an icon (`bz2 bzip2 tbz2 tbz`, `gz gzip tgz tpz`, `wim swm esd`,
  `z taz`, `lzh lha`, `vhd vhdx`, `xz txz`, `zst tzst`) can share **one** document-type entry with
  several `CFBundleTypeExtensions`, or get one entry each — either way they name the same
  `doc-<name>` icon. Do not copy the `.icns` under new names.
* `UTImportedTypeDeclarations` entries take their icon the same way, with
  `UTTypeIconFile` = `doc-<name>` (or `UTTypeIconName` = the image set's name, which also resolves
  because the image sets are compiled into `Assets.car`).
* After changing the plist, re-register so the Finder picks the icons up:
  `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f <path>/7-Zip.app`.

## Project wiring

`Mac/project.yml`, target `7-Zip` (additive change by this scope):

```yaml
      - path: Resources/Assets.xcassets
      - path: Resources/Icons
        buildPhase: resources
```

`Resources/Icons` is a **group**, not `type: folder`, on purpose: the `.icns` files must land flat
in `Contents/Resources` for `CFBundleTypeIconFile` and `NSImage(named:)` to resolve them by bare
name. A folder reference would nest them under `Contents/Resources/Icons/` and neither would work.

## Regenerating after the association table changes

If `options` adds or moves an extension in `FileTypes.swift`, or upstream adds an icon, run
`Mac/scripts/make-icons.sh`. It re-derives everything; the cross-check aborts if
`FileTypes.swift` and `resource.rc` no longer agree. If a *new* icon index appears, add its label
to `BADGE_LABELS` in `Mac/scripts/make-icons.py` first — the script raises a `KeyError` naming the
index otherwise.
