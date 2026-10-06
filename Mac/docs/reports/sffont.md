# `sffont`: SF Pro 12.2 for the whole UI, and pixel-sharp archive icons

> **Publication note:** all but a few showcase images under `docs/reports/screenshots/` were removed from the repository before publication. Paths below that point into them are kept as a record of what was measured.

Branch `mac/sffont`. The user's two decisions after `feel3` §4 and §8 (requests row `feel3` → user):

1. **Font:** SF Pro, the system font, at 12.2 pt ("sf-pro-byheight") as the default for the whole
   7-Zip UI: list, header, status bar, address bar and its drop-down, toolbar labels, every dialog
   and every control in it, Options, message boxes, progress, Properties, hash results, benchmark,
   About. `FM.ListFont` stays as the override.
2. **Archive icons:** the low-resolution frames of the original `.ico` files, pixel-sharp: the 16 px
   frame at 16 pt (Details / Small Icons / List / address bar and drop-down), the 32 px frame at
   32 pt (Large Icons), enlarged by whole pixels on Retina, never smoothed.

## 1. The font, measured

| | Segoe UI 9 (Windows) | Helvetica Neue 11 (old default) | **SF Pro 12.2** |
|---|---|---|---|
| "A..Z" + "a..z" | 347 px | 332.9 pt (0.96) | **381.5 pt (1.10)** |
| "2024-01-15 11:30" | 88 px | 88.1 pt | 101.6 pt; **110.6 pt with tabular digits** |
| ascender / descender | 12 / 3 | 10.5 / 2.3 | 11.8 / 2.6 |
| line height (NSLayoutManager) | 15 px (tmHeight) | 12 pt | **15 pt** |

`ListFontChoice.defaultFontName/defaultSize` are now `system` / 12.2
(`Panel/PanelListFont.swift`); the old default is the candidate `helvetica-neue-11`
(`defaults write com.yrambler2001.7zip FM.ListFont helvetica-neue-11`). Everything that took
`PanelMetrics.listFont` / `DialogMetrics.font` follows (list cells, header, status bar, path combo,
address drop-down, toolbar labels `FMToolbarView.labelFont`, every `RcPlace`-placed control, the
Options tabs, `WinMessageBox`, the icon views' labels). `SFFontTests.testEveryDialogControlUsesTheUIFont`
walks 22 dialogs and the six Options pages and finds every text control in SF Pro 12.2 (bold where
Windows is bold); the one exception it found, the message box's text view, now carries the font it
draws with.

**Tabular digits where columns must line up** (`ListFontChoice.withTabularDigits`,
`NSFont.monospacedDigitSystemFont` for the system face): every Details column except the name
(`PanelMetrics.listDigitsFont`), and every right-aligned dialog static (RTEXT: the progress
window's and benchmark's values). Names and labels stay proportional SF Pro.

**Rows stay 19 px.** SF Pro 12.2's line is 15 pt (11.8 + 2.6 = 14.4 of glyphs): 2 pt clear above and
below in the 19 px row, nothing clipped (`SFFontTests.testRowsHoldTheFontsLine` checks every cell's
text field against the row). Header (24) and toolbar label line (16) also hold it. Toolbar text
buttons are 48 x 46 instead of Windows' 42 x 46 (their width follows the widest label, "Extract").

**Time columns.** `PanelColumnsModel.defaultWidth`: a `fileTime` column starts at
`PanelMetrics.timeColumnWidth` = the full date in the tabular font + Windows' 6 px each side
= 111 + 12 = **123 pt** (Windows: 88 + 12 = 100), never below 100. A column layout saved earlier
with the old 100 px default is widened to 123 on load (any other stored width is kept).
`SFFontTests.testTimeColumnsShowTheFullDateAtTheDefaultWidth` checks no date cell is cut;
`sffont-main.png` shows it.

## 2. Dialogs: DLU grid widened, text grows into free room

Windows sizes a dialog from its font's base units. SF Pro 12.2 is 1.10x Segoe UI 9 over the
alphabet, so **`DLU.scaleX` = 1.10** (computed from `DialogMetrics.font` against Segoe UI's measured
347 px, rounded to 1 %, never below 1): every template x and width is stretched by it, heights are
Windows' own (SF's 15 pt line = Segoe's 15 px). Proportions stay Windows'; e.g. Add to Archive is
686 x 546 (Windows 624 x 546), About 264 x 260, Options 541 x 550 (its tab control, page and the
four buttons are now derived from the 316 DLU page, `OptionsWindow.swift`). With
`FM.ListFont helvetica-neue-11` the scale is 1 and every pixel is dlgfeel's again.

Vertical: a one-line static's frame is one line of the font high (15) and its top moves so the
first baseline stays 11 px below the rect's top, as on Windows (`RcPlace.labelTop` = -1 for SF Pro,
+1 for Helvetica Neue, computed). Message boxes (`WinMessageBoxLayout`): lines 15 pt, wrap width,
buttons and pitch stretched by `scaleX`, text measured as it is (the 1.035 Segoe correction only
applies when the font is narrower than Segoe).

**Text longer than its rect** (a long translation, which often clips on Windows too):
`RcFormView.growTextIntoFreeSpace()` lets a label, check box, radio button, push button or
drop-down take the free room beside it -- rightwards for left-aligned text, leftwards for RTEXT --
never past a sibling on its line, the group box it sits in, or the 4 DLU edge. If that is not
enough, a one-line static takes a second line when the room below is free, and as a last resort
the control's font steps down 0.2 pt at a time to a 10 pt floor. The pass runs when the form is
sized (after OnSize re-places controls), put in a window, and before a draw whenever a control's
text, visibility or frame changed since the last pass; it undoes its previous changes first, so a
language switch on the Options pages starts clean.

**Measured, six languages** (`SFFontTests.testDialogTextFitsItsFramesInSixLanguages`: English,
German, Russian, French, Japanese, Arabic; 22 dialogs + 6 Options pages each): every label's text on
its line (or its wrapped lines in its height), every check box / radio cell, every push button's
title with AppKit's 9 pt bezel margins, every group-box title, every drop-down title beside its
chevron -- **1 692 texts, 0 clipped**. Three drop-down titles remain cut at the 10 pt floor, all
translations that are cut on Windows as well: Add to Archive → Update mode in French ("Ajouter et
remplacer les fichiers", 176 needed / 171) and Compress Options → timestamp precision in Arabic
(twice, 149 / 131). The menu that opens shows them whole. Before the grow pass the same test found
113 clipped texts (mostly "..." and "<--" buttons, German/French/Russian check boxes, Benchmark's
German column headers).

Benchmark's machine-description lines (CPU name, features, uname) are longer on a Mac than on
Windows and have no room to grow: their last visible line now ends in an ellipsis
(`BenchmarkDialog.swift`).

The 93-language sweep (`LocalizationFittingTests`, `WindowAudit`: clipped / overlap / fit) stays
green with the wider dialogs.

## 3. Archive icons

`Panel/PanelArchiveIcons.swift`: the `.ico`'s frame of exactly the point size (16 px for 16 pt,
32 px for 32 pt) is decoded by Core Graphics and enlarged by whole pixels into 1x / 2x / 3x bitmap
representations (each source pixel an exact 2 x 2 / 3 x 3 block), so nothing is interpolated when
AppKit draws it, on any screen. (feel3 showed the 32 px frame at 16 pt on Retina; the extension
text of the 16 px frame is the legible one.) The .ico frames are 8-bit indexed with an 8-bit alpha;
`NSBitmapImageRep.colorAt` cannot read them (it returns nothing), so the decode goes through a CG
bitmap context. Used by the Details / Small Icons / List cells, Large Icons, the address bar and its
drop-down (all through `PanelArchiveIcons.icon`). `SFFontTests.testArchiveIconsAreTheLowResolutionFramesPixelSharp`
checks the 1x bitmap equals the frame, carries its pixels, and the 2x / 3x bitmaps are exact blocks.

## 4. Images for the user

All drawn without font smoothing, as the screen draws them (`Feel3FontTests.drawUnsmoothed`); the
main window's list is drawn part by part and must carry row ink (`fontimg`'s guard).

```
Mac/docs/reports/screenshots/sffont-main.png                 main window, Details, 2x
Mac/docs/reports/screenshots/sffont-compress.png             Add to Archive, 2x
Mac/docs/reports/screenshots/sffont-extract.png              Extract, 2x
Mac/docs/reports/screenshots/sffont-options.png              Options › System, 2x (-2 .. -6: the other pages)
Mac/docs/reports/screenshots/sffont-icons-before.png         feel3's icons, 1x   (-2x.png: Retina)
Mac/docs/reports/screenshots/sffont-icons-after.png          sffont's icons, 1x  (-2x.png: Retina)
```

At 1x the 16 pt icons are the same 16 px frame before and after; the difference is at 2x, where
"before" shows the 32 px frame and "after" the 16 px frame doubled.

## 5. Tests

New: `Mac/Tests/AppTests/SFFontTests.swift` (8 tests: default font, rows, time columns, fonts of
every dialog control, six-language fit, icons, before/after icon images, screenshots).
Updated for the new metrics (expectations derived from the font / `DLU.scaleX`, not new magic
numbers): `DlgFeelTests` (client widths = Windows x `scaleX`), `ListFeelTests` (SF widths, fill
padding, time column width, properties separator), `RecheckTests` (toolbar width from the widest
label), `Recheck2Tests` (message box lines / widths / buttons), `Feel3Tests` (the default is SF Pro,
icon representations), `Feel3FontTests` (the "current" image stays Helvetica Neue 11, what the user
chose from).

## 6. Verification

* `Mac/scripts/build.sh`: exit 0, no warnings in `Mac/`.
* `Mac/scripts/test.sh`: 388 passed, 0 failed.
* `Mac/scripts/test.sh -H`: 243 passed, 0 failed (incl. the 93-language `LocalizationFittingTests`).
* `Mac/scripts/test.sh -u`: 64 passed (52 input + 6 + 6 probe), 0 failed.
* The images in §4 were looked at: dates whole, archive icons present and sharp, no clipped text.

## 7. Cross-scope edits (for the orchestrator)

`panel`: `PanelListFont.swift`, `PanelMetrics.swift`, `PanelListViews.swift`, `PanelLogic.swift`,
`PanelViewController.swift`, `PanelArchiveIcons.swift`. `Support/RcLayout.swift` (dlgfeel's layout
engine: `DLU.scaleX`, `DLU.px`, font-derived label metrics, `growTextIntoFreeSpace`).
`options`: `OptionsWindow.swift` (geometry from the page width). `tools`: `BenchmarkDialog.swift`
(ellipsis on the machine lines). `opsinfra`/recheck2: `WinMessageBox.swift` (font-derived metrics).
`harness`: the test files listed in §5. Nothing outside `Mac/`.

## 8. Known gaps

* Three drop-down titles stay cut at 10 pt (§2); Windows cuts them too.
* Table columns inside dialogs (Options › System's 80 / 152, Hash results, Properties) keep their
  Windows widths; their cells truncate with an ellipsis as before.
* Hand-placed widths that are not in a template (a few column widths) are not stretched by `scaleX`.
* A text control whose font was stepped down keeps it until its dialog is re-laid out.
