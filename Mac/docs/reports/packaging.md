# `packaging` — build configuration, the disk image, localization QA, the final parity audit

Branch `mac/packaging`, off `macos` at `dea739c`. Five pieces of work: cleaning up the build
configuration, making Release real, producing a distributable disk image, running the localization
QA across all 93 bundled languages (which nobody had done), and auditing the parity checklist
honestly. The user-facing summary is `Mac/README.md`; the parity verdict is `Mac/docs/parity.md`.

---

## 1. Build configuration

### 1.1 One mechanism for the app sources the unit tests compile

Eight files under `Mac/Tests/SevenZipKitTests/` were symlinks into `Mac/App/`
(`PanelRow.swift`, `PanelLogic.swift`, `CompressModel.swift` and the five `App/Integration/`
files), while two others — `Settings.swift` and `FileTypes.swift` — had already been converted to
`sources:` entries on the test target. Two mechanisms for the same thing, and keeping both forms
for one file would compile it twice into the test bundle (`requests.md`: `options` → `harness`,
`panel` → `harness`, `finder` → `packaging`).

All eight symlinks are gone and all ten files are now `sources:` entries. Verified by converting
the generated `project.pbxproj` to JSON and counting the Sources build phase of every target:
`SevenZipKitTests` has **26 sources, no duplicates**, and each of the ten app files appears exactly
once. No other target has a duplicate either. 286 of 286 unit tests pass afterwards.

### 1.2 Release was never a working configuration

Everything up to now had been built Debug. Three things were wrong:

* **The bridge was unoptimized in Release.** `SevenZipKit` set `GCC_OPTIMIZATION_LEVEL: 0` in its
  *base* settings, so a Release build shipped `-O0` Objective-C++ while Swift got `-O -wholemodule`
  and the engine got `-O2`. It is now per-configuration: Debug 0, Release 2.
* **Every Release binary asked to be debuggable.** All four Mach-Os carried
  `com.apple.security.get-task-allow`, which Xcode injects unless
  `CODE_SIGN_INJECT_BASE_ENTITLEMENTS` is NO. Apple's notary service **rejects** a submission whose
  executables carry it, so a Developer ID build would have failed at the last step. Release now
  sets that to NO. Verified after a clean Release build: the app has no entitlements at all, and
  the three appexes still carry `com.apple.security.app-sandbox` and the shared-preference
  exception — which matters, because `api/finder.md` section 8 records that Xcode has twice
  stripped the sandbox entitlement silently and an unsandboxed appex never loads.
* **`build.sh -t <target>` could never work.** Xcode 26's `xcodebuild` refuses `-target` together
  with `-derivedDataPath` ("The flag -scheme, -testProductsPath, or -xctestrun is required when
  specifying -derivedDataPath"), so every single-target build exited 64 — a documented flag
  (`api/harness.md` section 1) that was dead. A one-target build now points `SYMROOT`/`OBJROOT` at
  the same DerivedData tree by hand, and the products land where the scheme build puts them.

`build.sh` also learned to sign: `SIGN_IDENTITY` (default `-`) and `DEVELOPMENT_TEAM`, with the
hardened runtime and `--timestamp` switched on automatically for a real identity, because
notarization requires both.

**Result:** Release builds with no warnings from `Mac/` code and **286 of 286 unit tests pass
against the Release configuration**, as they do against Debug.

---

## 2. The disk image — `Mac/scripts/package.sh`

Maps to `03 §5` (the distribution layout) and `00-orchestration.md` "Signing".

```
Mac/scripts/package.sh                                  # ad-hoc, the default
Mac/scripts/package.sh -i "Developer ID Application: Name (TEAM)" -T TEAM -p my-profile
```

What it does, in order: check the signing request is possible → Release build → assert the bundle →
stage → create a read/write image, set the volume icon, convert to UDZO → sign the image if there
is an identity → notarize and staple if asked → mount the finished image and verify it → print the
SHA-256.

**The bundle assertions** are the ones that otherwise fail silently: the framework and all three
appexes present and signed, `codesign --verify --deep --strict` clean, exactly 93 language files
and at least 27 document icons, both SFX stubs, every appex still sandboxed, and nothing carrying
`get-task-allow`. The sandbox check uses `PlistBuddy`, not `plutil -extract`, which reads the dots
in `com.apple.security.app-sandbox` as a key *path* and therefore can never match — that mistake
cost a false "not sandboxed" failure before it was spotted.

**The image**: UDZO, 4.4 MB, volume name `7-Zip 26.03`, the app icon as the volume icon, holding
`7-Zip.app`, a symlink to `/Applications`, and `License.txt` and `readme.txt` from `DOC/`. There is
no `History.txt` in this source tree — its change log is `DOC/src-history.txt`, the *source*
history — so nothing was invented in its place. The Finder **window layout** (icon positions,
window size, a background picture) is deliberately **not** set: it lives in a `.DS_Store` that only
Finder writes, and driving Finder needs Automation permission this machine does not have (an
`osascript` that drives another app hangs on the consent dialog rather than failing, `CLAUDE.md`).
The volume name and the volume icon are the parts of the look that need no automation, and both
are set.

**Notarization is guarded both ways.** Without `--notarize` the step prints
`notarization: skipped` and the script carries on. With `--notarize` but no Developer ID it exits
**3** with an explanation, before the build, rather than failing inside Apple's service — Apple
does not notarize an ad-hoc signature. A Developer ID that is not in the keychain is also caught
before the build.

### Verified end to end (ad-hoc)

`hdiutil verify` passes; the image mounts as `7-Zip 26.03` (HFS+, custom volume icon bit set);
`ditto` copies the app out to a temporary directory; the copy passes
`codesign --verify --deep --strict` ("valid on disk", "satisfies its Designated Requirement",
`Signature=adhoc`, `TeamIdentifier=not set`); the app **launches from that copy and stays up** with
`SevenZipKit` loaded; `spctl --assess` says `rejected`; the mount and the temporary directory are
cleaned up. `sha256 a739da98035a8cb7b0e734f0328da7378507672a6b5cb60fddb39619297e2b46`.

### What a user sees on first launch, measured

`spctl --assess` rejects this build whether or not the file is quarantined — an ad-hoc signature
is never *accepted* by Gatekeeper's assessment. But Gatekeeper only **blocks** a quarantined item,
so:

* **Built locally, or copied with `scp`/`rsync`/AirDrop:** nothing sets `com.apple.quarantine`, so
  the app just opens. Measured: no quarantine attribute on the copy taken out of the image, and it
  launched.
* **Downloaded with a browser, or received by Mail or Messages:** macOS attaches
  `com.apple.quarantine` (measured by setting it by hand:
  `0083;<hex time>;Safari;`), and on macOS 15+ the user gets *"7-Zip" Not Opened — Apple could not
  verify "7-Zip" is free of malware*. The right-click ▸ Open bypass no longer exists there. The way
  through is **System Settings ▸ Privacy & Security ▸ Open Anyway**, confirmed with Touch ID, once.
  `xattr -dr com.apple.quarantine /Applications/7-Zip.app` is the equivalent, and after it the app
  launches (measured).

With a Developer ID **and** notarization, `spctl --assess` returns `accepted` and there is no
prompt at all. That path is written and guarded but has **never been run**: there is no signing
identity on this machine.

---

## 3. Localization QA across all 93 languages

Two halves: drive the app in every language, and audit the files themselves without the app.
The UI half is `Mac/Tests/UITests/LocalizationTests.swift` (the one new UI test file this scope
added), six test cases, all passing.

### 3.1 Every language comes up — 93 of 93

`testLanguagesComeUp1of5` … `5of5` seed `Lang` into a per-test settings plist
(`api/harness.md` section 3), launch the app, and measure. One `LANGSWEEP|…` line per language goes
to the test log. The result is **completely uniform**:

| measurement | value, for all 93 |
|---|---|
| window appears | yes |
| top-level menus | 9 (Apple, 7-Zip, File, Edit, View, Favorites, Tools, Window, Help) |
| menus with a blank title | 0 |
| File menu items | 29 |
| panel rows (the 10 fixtures) | 10 |
| panel columns, none with a blank header | 7 |
| window title / status line | both non-empty |
| problems | 0 |

So **no language file makes the app fail to start, and none leaves a label blank.** That is the
English fallback doing its job: `SZLang.mm:110-119` tries the selected language, then `en.ttt`,
then the 16 compiled-in `kResourceOnlyStrings`, then the Swift literal. A file that fails to parse
at all is rejected whole (`CLang::Open`) and the UI is simply English.

The one defect the sweep found is measured rather than inferred: a count of menu items titled
exactly `"7-Zip"` inside the View menu is **2 for every one of the 92 translations and 0 for
built-in English**. Those two are View ▸ Back and View ▸ Forward, built with `lang: 0`
(`MainMenu.swift:227-228`), and lang id 0 **is** the product name — `CLang::Open` refuses any file
whose id 0 is not `"7-Zip"`. Filed in `requests.md` for the menu's owner; not asserted in the test,
because failing on a known product bug would turn the suite red.

### 3.2 Layout, in five representative languages — 22 screenshots

`testRepresentativeLanguagesLayout` opens the main window and several dialogs in `ar` (RTL),
`he` (a second RTL), `de` (German compounds — the longest strings in the set), `ja` (CJK) and
`ru` (Cyrillic), and attaches a full-screen screenshot of each.
`Mac/docs/reports/screenshots/packaging-1x-main-*`, `-2x-options-settings-*`,
`-24-options-language-ar`, `-3x-options-<page>-de` (all seven Options pages in German),
`-4x-copy/properties/benchmark-*`. They are cropped to the app region and scaled to 1600 px wide.

**The headline: no clipped or truncated label was found that is caused by a translation.** Two
table columns *are* too narrow for their content (finding 4 below), but what they cut is English
text in an English-labelled column, in every language including built-in English.
German — the worst case, with strings up to 120 characters — fits everywhere: the seven Options
pages, the toolbar (`Hinzufügen / Entpacken / Überprüfen / Kopieren / Verschieben / Löschen /
Eigenschaften`), the column headers, the Benchmark grid and the status line all lay out cleanly.
Japanese keeps upstream's `ファイル(F)` mnemonic parentheses, which is what Windows shows. Arabic
and Hebrew render correctly, just not mirrored.

What the screenshots *did* find (all filed in `requests.md`, none of them a "this language is
broken" problem):

| # | What | Language-specific? | Screenshot |
|---|---|---|---|
| 1 | Copy/Move, Benchmark and Properties draw their bottom button row clipped by the window edge | **No** — identical in built-in English (`tools-benchmark.png`), so `DialogKit.install` under-measures for every dialog built that way | `packaging-41-copy-de`, `-44-benchmark-de`, `-42-properties-de`, `-43-properties-ja` |
| 2 | The **Apply** button is never localized (German shows `Hilfe / Apply / Abbrechen / OK`) | No — it has no 7-Zip lang id at all | `packaging-21-options-settings-de` |
| 3 | Options ▸ 7-Zip forces the window past the screen edge (the unwrapped `pluginkit` status line), pushing the tab row out of view | No — the string is fixed English | `packaging-31-options-menu-de` |
| 4 | Two table columns are narrower than their content: Options ▸ Language's "Strings" (every row reads `444 /...`) and Options ▸ System's `Default app...` header with its `Archive U...` / `DiskImag...` cells | No — the cut strings are English in both cases, in an English-labelled column | `packaging-24-options-language-ar`, `packaging-30-options-system-de` |
| 5 | `ar.txt` has the wrong row at lang id 2102: a 78-character translator credit where `Language:` belongs | **Yes**, one language, and it is an upstream data defect, not a port bug | `packaging-24-options-language-ar` |
| 6 | RTL: composite one-field strings reverse their segment order (status line, Copy dialog's info block) | **Yes**, the 6 RTL languages. Nothing missing or clipped, only mirrored | `packaging-10-main-ar`, `-40-copy-ar` |
| 7 | Options ▸ Menu tab caption always English — `IDD_MENU 2300` is an id **no** bundled file defines | Affects all 92 | `packaging-24-options-language-ar` (tab reads `7-Zip`) |

### 3.3 The files themselves, audited without the app

The app asks for **453 distinct lang ids**. `en.ttt` defines 444; 423 of the 453 are both asked for
and present in `en.ttt`, and that intersection is the denominator below. The parser was
reimplemented from `CPP/Common/Lang.cpp` (positional: a digits-only line *sets* the cursor, a blank
or comment line *increments* it, anything else defines the current id) and run over all 93 files.

All 93 parse; all are valid UTF-8 (none is UTF-16); 84 carry a BOM and 9 do not
(`ar da is ro sw tk tr yo zh-cn`), which the parser tolerates either way; `ja.txt` is the only file
with CRLF, which the parser strips; no file is near the 1 MiB cap (largest: `mng2.txt`, 21 KB);
and **no id anywhere maps to an empty string** — structurally impossible, because a blank line
skips the id instead of defining it.

**29 ids are asked for that no language file defines**, so they can only ever be English. Sixteen
of them are deliberate (`SZLang.mm:33-55` carries the `PropertyName.rc` strings as
`kResourceOnlyStrings`), four are property ids upstream also shows numerically, seven are macOS
additions, and one — **2300, the Options ▸ Menu tab caption** — is the only one that is arguably
wrong.

**Fallback verified by reading the code path, not by assuming it:** an id missing from the
selected language falls to `en.ttt` then to the resource-only strings then to the Swift literal
(`SZLang.mm:113-118, :130`); an id present but empty cannot occur; a malformed file is rejected
whole and the UI is English (`Lang.cpp:156-164`, `SZLang.mm:175-180`); a missing file or a `Lang`
value of `""`, `"-"` or anything containing `/` unloads and gives English (`SZLang.mm:169-174`,
`:206-222`); even a missing `en.ttt` degrades to the compiled-in literals. The only two APIs that
can return `""` — `stringForID:` without a fallback and `englishStringForID:` — have no callers
outside the unit tests.

#### Complete: 28 of the 92 translations (0 ids missing)

`ar az bg ca co cs de el es fr hu id it ja ko lt nl pl pt pt-br ro ru sk tr uk va zh-cn zh-tw`
(plus `en.ttt` itself). There is no "nearly complete" tier — the next group jumps straight to 14
missing.

#### Nearly complete: 14–31 ids missing (93–97 %)

| missing | languages |
|---|---|
| 14 | `fa fi gl sl sv` |
| 27 | `da eu he hr is kab si sw tk uz uz-cyrl yo` |
| 31 | `hy tg tt` |

#### Substantially incomplete: more than a quarter of the requested ids missing (24 of 92)

| missing / 423 | coverage | languages |
|---|---|---|
| 109 | 74 % | `fur` Friulian, `ku-ckb` Kurdish-Sorani, `ug` Uyghur |
| 126 | 70 % | `fy` Frisian, `pa-in` Punjabi, `ps` Pashto |
| 139 | 67 % | `bn` Bangla |
| 140 | 67 % | `nb` Norwegian Bokmål, `nn` Norwegian Nynorsk |
| 161 | 62 % | `cy` Welsh, `eo` Esperanto, `ku` Kurdish, `ne` Nepali, `sq` Albanian |
| 162 | 62 % | `mr` Marathi |
| 169 | 60 % | `mn` Mongolian, `ms` Malay |
| 173 | 59 % | `ast` Asturian, `io` Ido, `lv` Latvian, `mk` Macedonian |
| 174 | 59 % | `br` Breton |
| 175 | 59 % | `af` Afrikaans |
| 185 | 56 % | `ta` Tamil |

A middle tier of 20 more sits at 100 missing (76 %): `an ba be et ext ga gu hi ka kaa kk ky lij
mng sa sr-spc sr-spl th vi` and `mng2` at 101. So on a looser cut — more than 50 ids missing — 44
of the 92 qualify. Every one of them still runs; they simply show more English.

Two worth calling out by name: **`nb`** is the file a Norwegian-locale Mac resolves to by default
(`SZLang.mm:293-294` maps both `no` and `nb` to it), so "Auto" gives a Norwegian user a 67 %
translation; and **`mng2`** (Mongolian MenkCode) is 6,302 Private Use Area codepoints, which render
as tofu without that specific font installed — including its own row in the Language list.

#### Languages with layout problems

**None.** Across the five languages screenshotted, and across the 93 measured for populated menus,
columns, status line and window title, no translation clipped, truncated or blanked a label. The
Arabic 2102 row (finding 5) is wrong *text*, not broken layout, and the RTL segment reversal
(finding 6) affects order, not legibility. The layout defects that do exist — findings 1, 3 and 4 —
are present in English too.

---

## 4. The final parity audit

A sample of **57 ticked checklist items** was re-verified against the source, deliberately biased
towards expensive features, cross-scope claims, and anything a scope report or a `requests.md` row
hinted was deferred. **Nine were provably untrue and are now unticked**, each with its evidence
written next to it in `PROGRESS.md`; **eleven more were true but overstated** and carry a
correction. `Mac/scripts/parity-check.sh` therefore went 395 → 386, and back to **396 of 496 (80 %)**
once this scope's own items were ticked.

Unticked, with the proof in each case:

| line | claim | why it is not true |
|---|---|---|
| 306, 307 | the 7-Zip Explorer commands in the panel's own context menu | the items are built with selectors **nothing implements** (`PanelContextMenu.swift:22-32`; `grep -rn 'func sevenZip' Mac/App` finds only the protocol), so the responder chain disables all of them. Visible in `panel-10-context-menu.png` |
| 313 | drop on the window background = Add to archive | the dropped list is assigned to `pendingCompressTarget` (`PanelDragDrop.swift:358`) and **never read**; `CompressCommands` takes the panel *selection* |
| 402 | Open Outside for a folder inside an archive | `TempOpenCommands.openOutside()` has **no callers**; `PanelNavigation.swift:183-189` returns unless the folder is a file system |
| 489 | `x` / `t` with `-scrc` show the hash | `command.hashMethods` is read only in `runHash` (`CommandExecutor.swift:499`) |
| 528 | Help ▸ Contents opens the bundled HTML help | **nothing is bundled** — no `Mac/Resources/Help`, no `.htm` anywhere, no help resource in `project.yml` |
| 602 | `Compression.*` / `Extraction.*` readable by the extension | only the five `Options.*` values travel (`URLCommands.swift:74-87`) |
| 635 | the 7zG dialog selection rules | update mode from the action set, `-m tm/tc/ta` pre-parsing and `-scrc` are all absent |
| 636 | exit code 8 and the exception mapping | `SevenZipExitCode.memoryError` has no reference outside a unit test; no `HResultToMessage` ladder |

Corrected in place rather than unticked (the feature is real, the claim overstated): raw
properties in the columns and Properties (`IArchiveGetRawProps` is not bridged); drag and drop is
Details-view only; `FM.AutoRefresh` **is** persisted, contradicting its own line; Diff needs two
items in one panel; `-sfx<module>` is ignored; the progress message list has fixed columns; the
Options ▸ System page uses system icons and has no single-click or Return; Apply does not refresh
Launch Services; a failing language file is skipped silently; "all writes serialised" has no
implementation; and the association list is 40 rows, not 39.

One item was verified **true** and ticked: `upstream-patches.md` matches the real diff —
`git diff --stat main -- C CPP Asm DOC` touches exactly ten files and the document describes
exactly those ten.

The user-facing result is `Mac/docs/parity.md`: complete / partial / deliberately different /
missing, with the inventory section behind each line.

---

## 5. `Mac/README.md`

For someone handed the repository: what the app is, what it does, how to build and run it, how to
install the disk image and get past the first-launch warning, how to turn the Finder extension and
the Quick Actions on and what the eleven commands are, which permission prompts macOS raises and
why (and why the app is not sandboxed while the extensions are), how to switch language, the known
limitations, and where every document lives.

---

## Final verification

`Mac/scripts/verify.sh` on this branch, clean, with no `--fast` and no `--no-ui`:

| step | time | result |
|---|---|---|
| clean build (Debug) | 39 s | ok, no warnings from `Mac/` code |
| unit tests | 41 s | **286 of 286 passed** |
| UI tests | 1095 s | **35 of 35 passed** |

`OK: verify passed` (`Mac/docs/reports/verify-latest.md`). The UI suite was 29 tests and is now 35:
the six added here are the five language-sweep chunks and the layout/screenshot test. They cost
roughly nine minutes of the eighteen — 93 app launches and 25 more — which is the price of the
localization QA running on every verification instead of rotting. `--no-ui` still skips them.

Release was verified separately, because `verify.sh` is a Debug gate: clean Release build with no
warnings from `Mac/` code, and `Mac/scripts/test.sh --config Release` green at **286 of 286**.

## Known gaps and follow-ups

1. **The Developer ID and notarization paths have never been run.** No identity exists here
   (`security find-identity -v -p codesigning` → "0 valid identities found"). Both are written,
   both refuse early rather than late, neither has been exercised against Apple's service.
2. **No `.DS_Store` window layout on the disk image.** It needs Finder automation, which this
   machine cannot grant. The volume name and volume icon are set; icon positions and a background
   picture are not.
3. **`fetch-assets.sh` and `make-fixtures.sh` were not re-run**, so their "reproducibly pulls"
   checklist item stays unticked rather than being ticked on inspection.
4. **No bundled help.** The largest single remaining gap in the whole port (`01 §9 #17`).
5. **43 control ids are cited numerically** rather than by symbolic name, so the grep audit of
   `PROGRESS.md §9.4` cannot pass yet.
6. **`architecture.md`'s "As built" section is stale** (still Wave 1). Orchestrator-owned, so it was
   left alone and recorded in `parity.md` section E.
7. **`IDS_SET_FOLDER 6007` has two different English fallbacks** across its four call sites
   ("Specify a folder:" in Link/Split/Combine, "Specify a location for output folder" in
   Copy/Move). Invisible once a language defines 6007.
8. **Finder's own context menu has still never been opened in Finder** — the 15 manual checks in
   `Mac/docs/reports/finder.md` remain owed by a human.
9. Seven layout and localization findings filed in `requests.md` for the scopes that own the code:
   the `lang: 0` Back/Forward titles, the untranslated Apply button, the Options ▸ 7-Zip window
   width, the shared dialog button-row clipping, the `ar.txt` 2102 row, RTL segment order, the
   Options ▸ Menu caption, and the narrow "Strings" column.

## Files this scope touched

Owned: `Mac/scripts/package.sh` (new), `Mac/scripts/build.sh`, `Mac/README.md` (new),
`Mac/project.yml`, and the signing-related build settings in it.
Added by permission of the task: `Mac/Tests/UITests/LocalizationTests.swift` (the one new UI test
file), `Mac/docs/parity.md` (new), this report, and `Mac/docs/reports/screenshots/packaging-*.png`.
Shared, additive only: `Mac/docs/PROGRESS.md` (the packaging section ticked, plus the audit's
unticks and notes, which the task assigned to this scope) and `Mac/docs/requests.md` (eight rows
appended). Deleted: the eight symlinks under `Mac/Tests/SevenZipKitTests/`.
Nothing under `Mac/App`, `Mac/Core`, `Mac/FinderSync`, `Mac/QuickAction` or `C`/`CPP`/`Asm`/`DOC`
was modified.
