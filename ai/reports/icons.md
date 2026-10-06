# icons scope — report

> **Publication note:** this report was written when it lived in `Mac/docs/reports/`. Its screenshots were removed from the repository before publication; a few showcase images live on in `docs/images/`, and the tests now write their screenshots to the git-ignored `Mac/build/screenshots/`. Paths below that point at removed images are kept as a record of what was measured.

Branch `mac/icons`. Worktree `.worktrees/icons`. Owned: `Mac/Resources/Assets.xcassets/*`,
`Mac/Resources/Icons/*` (new), `Mac/scripts/make-icons.{sh,py,swift}`, `ai/api/icons.md`.
Additive edits: `Mac/project.yml` (one source entry on the `7-Zip` target),
`ai/PROGRESS.md` (one Status row, one new section 10).

## What was implemented

The app's whole visual identity, generated from the upstream Windows icon resources by
`Mac/scripts/make-icons.sh`. Nothing under `Assets.xcassets` or `Resources/Icons` is hand-made,
and nothing under `CPP/` was modified. Full API, naming scheme, mapping table and the
`CFBundleDocumentTypes` shape the `finder` scope needs are in `ai/api/icons.md`.

### 1. The generator

* `Mac/scripts/make-icons.py` — a dependency-free `.ico` decoder plus the catalogue assembler.
  It handles the real Windows icon format rather than the happy path: PNG-compressed frames,
  32- and 24-bit BMP frames, and 8/4/1-bit paletted BMP frames, with the subtleties that matter —
  `biHeight` is twice the visible height because the AND mask follows the XOR bitmap, both are
  bottom-up with *different* row paddings, and a 32bpp frame's alpha channel is only authoritative
  when some byte in it is non-zero (otherwise the AND mask is the transparency). All 30 upstream
  icons turn out to be 8bpp or 4bpp paletted with an AND mask, so `sips` — which cannot open
  `.ico` at all — would have been the wrong tool twice over. PNG reading and writing are also
  in-script (no Pillow on this machine, and none may be installed).
* `Mac/scripts/make-icons.swift` — the renderer (CoreGraphics + CoreText). Every icon is drawn
  from scratch at every pixel size; stroke widths, insets, corner radii, the fold and the type size
  are functions of the size, so nothing is a downscale of one 1024 px bitmap.
* `Mac/scripts/make-icons.sh` — the driver, with `--stage extract|draw|assemble|sheet|verify`
  and `--dump <name>` for an ASCII dump of an upstream icon.

The whole toolchain is `python3` + `swift` + `iconutil`, all present on a stock macOS with Xcode.
`brew list` was checked first: ImageMagick is absent, `rsvg-convert` is present but was
deliberately **not** used so the generator works on a machine that only has Xcode.

Nothing is hand-copied from the inventories. The extension list is read from *both*
`CPP/7zip/Bundles/Format7zF/resource.rc` STRINGTABLE 100 and `Mac/App/Support/FileTypes.swift`,
and the two are compared; a disagreement aborts the run. The index → `.ico` mapping comes from the
`<index> ICON "…"` lines of the same `.rc`. This confirms the `requests.md` spec correction over
`03 §3.1`: the association list holds **40** extensions, not 39, mapped onto **27** icons.

### 2. The app icon (`AppIcon.appiconset`, 10 slots, 7 pixel sizes 16…1024)

The old asset was a straight upscale of a 32×32 Windows icon. The new one is Apple's rounded
square: 824/1024 of the canvas, centred, with the continuous ("squircle") corner drawn as the
superellipse `|x/a|^5 + |y/a|^5 = 1` — which matches Apple's 824 pt body with a 185.4 pt radius to
within 1 pt at the 45° point, so the shape is the real macOS one rather than a plain rounded rect.

It is still unmistakably 7-Zip: the body is a gradient between the two brand blues taken straight
out of the upstream icons (`#0000ff` from `zip.ico` → `#000080` from `7z.ico`), carrying the manila
archive sheet (`#ffff99` with the `#999900` olive border) and the `7z` mark that
`CPP/7zip/UI/FileManager/FM.ico` draws.

Small sizes are separate compositions, which is the whole reason for rendering per size:

| Pixel size | Composition |
|---|---|
| 16 | squircle + `7` in manila — two glyphs at 16 px run together into a blur |
| 32 | squircle + `7z` in manila |
| 64…1024 | squircle + manila sheet + `7z` in navy, with a contact shadow |

### 3. The document icons (27 sets covering all 40 extensions)

The standard macOS page — 704 × 900 in a 1024 canvas, centred, top-right corner folded by
190/1024, three rule lines at 128 px and up — with the 7-Zip artwork at its foot: a manila band
over a badge band in the format's **exact** upstream badge colour, carrying the format label in
white. The label is dropped below 64 px, where no type size is legible, so the two coloured bands
carry the identity there; that is how Apple's own document icons behave.

Upstream squeezes the format name into a 12 × 8 box in a 2 px-stroke pixel font, so it truncates to
two glyphs (`AP` for apfs, `Sq` for squashfs, `01` for split, `bZ` for bz2). macOS has the room, so
the full name is set — that is the "presentation adapted" part. `split.ico` keeps the label `001`,
the extension it actually serves.

Extensions that share a Windows icon share one macOS icon: 27 icons for 40 extensions, no
duplicated assets. Both delivery forms are produced:

* `Mac/Resources/Icons/doc-<name>.icns` — the full ten-slot 16…1024 pyramid, copied **flat** into
  `Contents/Resources` (a group in `project.yml`, deliberately not `type: folder`) so
  `CFBundleTypeIconFile` and `NSImage` resolve them by bare name.
* `doc-<name>.imageset` in the asset catalogue (mac 1× = 256 px, 2× = 512 px) for in-app use. This
  answers the `options` scope's note in `requests.md` that the Options ▸ System rows show system
  icons because the real format icons were never bundled: they can now use
  `NSImage(named: "doc-<name>")`, or load the `.icns` when they want the native 16/32 px reps.

## Mapping to Windows behaviour

* `03 §3.1` / `resource.rc:6-32,36-39` — the index → `.ico` table and the `ext:index` association
  string are the generator's input; the full 40-row mapping table is in `ai/api/icons.md`.
* `03 §3.3` — Windows writes `DefaultIcon = "<7z.dll>,<index>"`. macOS has no per-ProgID icon
  registry, so the equivalent is one `CFBundleDocumentTypes` entry per extension with
  `CFBundleTypeIconFile = doc-<name>`; the exact plist shape is documented for `finder`.
* `01b §4.21` / `03 §3.4` — the Options ▸ System list draws each row's format icon with
  `ExtractIconExW` from `7z.dll`. The `doc-<name>` image sets are that icon, converted.
* `01 §9 #15` — the "system image lists / `IDB_*` bitmaps" row of the Not-applicable table maps
  Windows icon resources onto bundled assets; this is that conversion for the icon resources.

## What was verified, and how

1. **Decoder correctness** — every frame of all 30 upstream `.ico` files decodes
   (`Mac/build/icons/frames/`); `sips -g hasAlpha` on the extracted frames reports `yes`, and the
   ASCII dumps (`make-icons.sh --dump 7z`) match the palette the renderer was given.
2. **Table agreement** — the run prints `tables agree: 40 extensions -> 27 icons`; the
   cross-check is a hard failure, so a future drift in `FileTypes.swift` breaks the generator
   rather than silently mis-icon-ing a type.
3. **Automatic verification of every emitted PNG** — the `verify` stage re-reads all 196 PNGs
   (1 app icon + 27 document icons × 7 sizes) and asserts the exact pixel size, a live alpha
   channel (at least one fully transparent and one fully opaque pixel), more than three distinct
   opaque colours at 64 px and up, and four clear corners. Output: `verified 196 PNGs`, no
   failures.
4. **Contact sheet, looked at** — `Mac/build/screenshots/icons-contact-sheet.png`: all 28
   icons at 128 pt in a 7-wide grid on a checkerboard, each labelled with its asset name and the
   extensions it serves. Checked by eye: none blank, none stretched, the checkerboard shows
   through every transparent margin (so no icon lost its alpha), and every label is the right one.
5. **Small sizes, looked at** — 16/32/64/128 px of the app icon and of `doc-7z` / `doc-squashfs`
   rendered 8× with nearest-neighbour on a checkerboard and inspected. This is what drove the
   per-size design: the first draft's 16 px `7z` was mush, hence the `7`-only variant, and the
   64 px sheet was re-proportioned so the mark's optical size barely changes across the 32 → 64
   step where the sheet appears.
6. **The built bundle** — `Mac/scripts/build.sh` on a clean `Mac/build`, then the app registered
   with `lsregister -f` and its icon asked for through `NSWorkspace.icon(forFile:)`, i.e. exactly
   what the Finder and the Dock draw. Rendered at 16/32/64/128/256/512 pt and inspected: correct
   at every size. `assetutil --info` on the built `Assets.car` confirms all ten AppIcon
   renditions, 16 px through 1024 px. (The `AppIcon.icns` `actool` emplaces beside `Assets.car`
   carries only 16/16@2x/128/128@2x — that is `actool`'s legacy fallback and is the same for any
   Xcode-built app; macOS 14 uses `CFBundleIconName` → `Assets.car`.)
7. **Document icons through AppKit** — `doc-7z.icns` and `doc-squashfs.icns` loaded as `NSImage`
   and drawn at every size: reps `1024, 512×2, 256×2, 128, 64, 32×2, 16`, all correct. And
   `Bundle(path:).image(forResource: "doc-7z")` against the built app resolves from `Assets.car`,
   so the in-app name lookup works too.
8. **Asset catalogue compiles clean** — `actool` emits no notices, warnings or errors (checked in
   `Mac/build/build-Debug.log`); the only warnings in the log are the tolerated upstream
   `libtool: … has no symbols` ones. Warnings are errors in `Mac/` code and the build is green.
9. **Clean build** — `rm -rf Mac/build && Mac/scripts/build.sh` → `** BUILD SUCCEEDED **`.

The app was not launched interactively, so the app-launch lock was not taken.

## Known gaps and follow-ups

* **No extension lacks artwork.** All 40 extensions in `FileTypes.swift` resolve to one of the 27
  upstream icons, so no fallback was needed. If a future extension arrived without an icon index
  the generator would raise a `KeyError` naming the index rather than silently substituting one.
* **The plist is not wired.** `Mac/App/Info.plist` belongs to `finder`; this scope only produced
  the assets and documented the exact keys. Until `finder` adds `CFBundleDocumentTypes`, the
  Finder still shows generic icons for `.7z` files — the assets are present and correct, nothing
  points Launch Services at them yet.
* **26 of the 27 badges are the same blue.** Upstream gives only `7z.ico` a distinct colour
  (`#000080`); every other format icon uses `#0000ff`. The label is therefore the only
  differentiator between, say, `.rar` and `.tar`, exactly as on Windows. Tinting each format
  differently was considered and rejected as a departure from upstream.
* **`7zipLogo.ico` is decoded but unused.** It is the 110 × 63 monochrome About-box wordmark; the
  `tools` scope's About dialog (`IDD_ABOUT 2900`) could use
  `Mac/build/icons/frames/7zipLogo/110x63-8bpp.png` if it wants the real wordmark. Say so and this
  scope will ship it as an asset.
* **Image sets carry two sizes.** An `.imageset` only has 1×/2× slots, so the in-app sets are
  256/512 px. UI that needs a crisp 16 px row icon should load the `.icns` (documented in
  `api/icons.md`); the alternative would be 27 more `.appiconset`s, which `actool` would rather
  not see.
* **Retina Dock ≥ 512 pt** is served from `Assets.car`, not from the emplaced `AppIcon.icns`.
  If `packaging` ever needs a standalone full-pyramid `AppIcon.icns` (for a DMG volume icon, say),
  add a stage to `make-icons.py` — the PNGs are already all there in `Mac/build/icons/png/app/`.
