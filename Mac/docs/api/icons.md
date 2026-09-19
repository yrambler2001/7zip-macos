# `icons` — app icon, document icons, and the generator that makes them

Everything under `Mac/Resources/Assets.xcassets` and `Mac/Resources/Icons` is **generated**.
Never hand-edit a PNG, a `Contents.json` or an `.icns` there: change
`Mac/scripts/make-icons.{sh,py,swift}`, re-run the generator and commit the result.

All art derives from the upstream Windows icon resources, which are read-only inputs:

| Input | Used for |
|---|---|
| `CPP/7zip/Archive/Icons/*.ico` (27 files) | one document icon each: the exact badge colour and the label the badge spells |
| `CPP/7zip/UI/FileManager/FM.ico` | the app icon's `7z` mark (the File Manager's own Windows icon) |
| `CPP/7zip/UI/FileManager/7zipLogo.ico` | the About-box wordmark (decoded and archived; not drawn into an asset) |
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

No third-party tool is involved: `python3` decodes the `.ico` files and assembles the catalogue,
`swift` (CoreGraphics + CoreText, from Xcode) draws, and `iconutil` packs the `.icns`. There is
no ImageMagick, Pillow or `rsvg` dependency, and `sips` is not asked to read `.ico` — it cannot.

Stages:

1. **extract** — decodes every frame of every upstream `.ico` into
   `Mac/build/icons/frames/<name>/<w>x<h>-<bpp>bpp.png` (PNG-compressed frames, 32/24-bit BMP
   frames with or without a real alpha channel, and 8/4/1-bit paletted BMP frames whose
   transparency is the trailing 1-bit AND mask — 7-Zip's are all 8bpp + AND mask). Writes
   `Mac/build/icons/icons-manifest.json`: the shared body palette, each format's badge colour,
   label and extensions.
2. **draw** — `make-icons.swift` renders every icon at every pixel size from the manifest. The
   art is re-drawn per size (stroke widths, insets, corner radii, fold and type size are all
   functions of the pixel size); nothing is downsampled from one big bitmap.
3. **assemble** — lays the PNGs out as `AppIcon.appiconset`, 27 `doc-<name>.imageset`s, and 27
   `.icns` files via `iconutil`.
4. **sheet** — writes `Mac/docs/reports/screenshots/icons-contact-sheet.png`: every icon at 128 pt
   on a checkerboard, with its name and the extensions it serves.
5. **verify** — reads all 196 emitted PNGs back and fails on a wrong pixel size, a lost alpha
   channel, a blank or single-colour image, or an opaque corner.

`Mac/build/icons/` is scratch (git-ignored). Nothing there is shipped.

## What is generated

### App icon — `Mac/Resources/Assets.xcassets/AppIcon.appiconset`

Ten slots, `icon_<pt>x<pt>[@2x].png`, covering 16, 32, 128, 256 and 512 pt at 1× and 2×
(7 distinct pixel sizes, 16 … 1024). Each slot has its own file even where two slots are the same
pixel size: `actool` collapses identical *filenames* and then emits an `AppIcon.icns` missing the
collapsed slots.

Geometry: Apple's rounded square, 824/1024 = 0.8046875 of the canvas, centred, which leaves the
standard 100/1024 margin. The corner is the continuous ("squircle") one, drawn as the superellipse
`|x/a|^5 + |y/a|^5 = 1` — for Apple's 824 pt body with a 185.4 pt radius the rounded rectangle's
45° point is at 357.7 and the superellipse's at 358.7, a 1 pt difference.

Art: a vertical gradient between 7-Zip's two brand blues (`#0000ff` from `zip.ico` → `#000080`
from `7z.ico`) carrying the manila archive sheet (`#ffff99`, olive `#999900` border) and the `7z`
mark `FM.ico` draws, in the navy. Small sizes are deliberately different compositions, because
the sheet's border and the mark collapse into noise below 64 px:

| Pixel size | Composition |
|---|---|
| 16 | squircle + `7` in manila, no sheet |
| 32 | squircle + `7z` in manila, no sheet |
| 64 … 1024 | squircle + manila sheet + `7z` in navy, with contact shadow |

`Info.plist` needs nothing: `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` in `Mac/project.yml`
makes `actool` write `CFBundleIconFile` / `CFBundleIconName` and emplace `AppIcon.icns`.

### Document icons — `doc-<name>.imageset` and `Mac/Resources/Icons/doc-<name>.icns`

One per upstream **format icon**, not per extension: extensions that share a Windows icon share
one macOS icon, so there are 27 icons for 40 extensions and no duplicated assets. `<name>` is the
upstream `.ico` file's stem, so `001` uses `doc-split` (from `split.ico`).

* `Mac/Resources/Icons/doc-<name>.icns` — the full 16 … 1024 pyramid (all ten `iconutil` slots).
  Copied flat into `Contents/Resources`, so `CFBundleTypeIconFile` and `NSImage(named:)` both
  find it by bare name. This is the one to use for document types.
* `Mac/Resources/Assets.xcassets/doc-<name>.imageset` — `mac` idiom, 1× = 256 px, 2× = 512 px, for
  in-app use through `NSImage(named: "doc-7z")`: the Options ▸ System rows (`01b §4.21`, `03 §3.4`),
  sheets, anything that wants the format icon inside the UI rather than from Launch Services.
  This closes the `options` scope's note that the System page shows system icons because the real
  format icons were never bundled.

Which one `NSImage` gives you, verified against the built bundle:

```swift
NSImage(named: "doc-7z")                      // the image set: 256 px @1x, 512 px @2x
Bundle.main.url(forResource: "doc-7z", withExtension: "icns")
    .flatMap(NSImage.init(contentsOf:))       // the .icns: native 16/32/64/128/256/512/1024 reps
```

`NSImage(named:)` resolves the asset catalogue first, so a 16 pt table row gets a downscale of the
256 px rep. For crisp small sizes in the UI (Options ▸ System rows, panel list icons) load the
`.icns`, which carries a real 16 px and 32 px representation.

Geometry: the macOS page, 704 × 900 in a 1024 canvas (0.6875 × 0.8789), centred horizontally, with
the top-right corner folded by 190/1024. At the foot of the page sit the 7-Zip bands — manila
(`#ffff99`) over the format's exact upstream badge colour — and the badge carries the format label
in white. The label is dropped below 64 px, where no type size is legible, exactly as Apple's own
document icons behave; the bands alone carry the identity there.

Labels are the full format name. Upstream draws the name in a 2 px-stroke pixel font inside a
12 × 8 box, so it truncates to two glyphs (`AP` for apfs, `Sq` for squashfs, `01` for split);
macOS has the room, so the whole name is set. `split.ico`'s label stays **`001`**, the extension it
actually serves.

## Extension → icon mapping

Every one of the 40 extensions in `FileTypes.swift` has artwork; **no extension falls back**,
because all 27 upstream icons exist and the association string only ever references 0–26.

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

`Mac/App/Info.plist` is owned by `finder`; this scope does not touch it. One
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
