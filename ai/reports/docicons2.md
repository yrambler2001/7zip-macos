# `docicons2`: small icons are the 16 × 16 frame at every scale

> **Publication note:** this report was written when it lived in `Mac/docs/reports/`. Its screenshots were removed from the repository before publication; a few showcase images live on in `docs/images/`, and the tests now write their screenshots to the git-ignored `Mac/build/screenshots/`. Paths below that point at removed images are kept as a record of what was measured.

Branch `mac/docicons2`, a follow-up to `docicons` (`ai/reports/docicons.md`).

## User decision

The smallest icons must look like Windows' smallest icons and like the panel list (sffont: the
16 px frame, pixel-doubled on Retina). So a 16 pt slot shows the `.ico`'s 16 × 16 frame at every
scale. Before, a 16 pt slot on Retina (32 px) showed the 32 px frame, which Windows draws only for
large icons.

## Changes

- **`make-icons.py`.** In every `doc-*.icns`, the 16 pt @2x slot (`icon_16x16@2x`, `ic11`) is now
  the 16 px frame ×2 (`doc_slot_frame`, `16@2x.png`). 16 pt @1x is still the 16 px frame. 32 pt and
  up are unchanged: the 32 px frame, ×1 … ×32. Since `ic11` and `icon_32x32` are separate slots, the
  32 pt @1x slot keeps the 32 px frame.
- **The check.** `verify_icns` now also requires each slot to equal exactly the frame
  `doc_slot_frame` picks. The `docicons` version of `doc-zip.icns` fails with
  `icon_16x16@2x.png: is the 32 px frame, the 16 pt slot must be the 16 px frame`. A normal run
  checks 280 slots and passes.
- **Options ▸ System** (`OptionsSystemPage.formatIcon`, 01b §4.21). The rows now draw
  `PanelArchiveIcons.icon(named:large: false)`, which is the same `NSImage` the panel list and the
  address bar use. Windows' System page fills its ImageList from `ExtractIconExW` small icons
  (SystemPage.cpp:56-95). `OptGapsTests.testSystemPageShowsTheFormatIcons` asserts that the two are
  identical. The address bar and the panel list already used `PanelArchiveIcons`, so every 16 pt
  rendering in the app is now the 16 px frame.

## Installed, verified

The Release build is in `/Applications/7-Zip.app`. The steps were the same as in `docicons`:

- backed up, copied, `codesign -v --deep` ok, backup removed
- `lsregister -f` on the installed app
- this tree's builds unregistered
- the three appexes re-added: one copy each, from `/Applications`, elected `+`

The installed `.icns` is `cmp`-identical to the committed one, and its `ic11` differs from its
`icon_32x32`.

`NSWorkspace.icon(forFile:)` was rendered pixel for pixel at 16 pt @1x and @2x, 32 pt @1x and @2x,
64, 128 and 256 pt:

- **Types never drawn at 16 pt @2x before** (the catch-all `z01 zipx xpi ods xlsx apk appx r00 udf
  lzma86 ova ar …`): every slot matches the `.icns`, including 16 pt @2x = 16 px frame ×2.
- **The 40 associated types:** the 16 pt @2x slot still comes back as the old image. Finder had drawn
  these, and so had the `docicons` 2x probe. It is IconServices' system cache again
  (`docicons.md` §3). Nothing short of the administrator flush clears it:

  ```sh
  sudo rm -rf /Library/Caches/com.apple.iconservices.store
  killall Dock Finder
  ```

  Then log out and in. All other slots are exact, apart from the five `docicons` stale slots.

Images:

- `screenshots/docicons-sheet.png`: every type × the seven slots, with an `=`/`x` per slot.
- `screenshots/docicons-finder-list.png`: a Finder-like list at 16 pt on Retina. Each row shows the
  icon Finder gets now, then the installed `.icns`. The second column is the 16 px frame doubled.
- `screenshots/docicons2-options-system.png`: Options ▸ System from the hosted tests, showing the 16 px
  frames pixel-doubled, the same as the panel list.

## Verification

- `make-icons.sh` green and reproducible (§ Changes).
- `build.sh` Debug and Release: BUILD SUCCEEDED, no warnings from `Mac/` code.
- `test.sh`: 401 passed.
- `test.sh -H`: 273 passed. The first full run had two failures in classes this branch does not
  touch: `DateColsTests` (a column width) and `SelColorsTests` (a contrast reading). Both passed
  alone and in a second full run.
