# Changelog

All notable changes to 7-Zip for macOS are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the port uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) for its own version; the engine version
is upstream 7-Zip's (for example *7-Zip 26.03 for macOS 1.0.0*).

## [Unreleased]

### Added

- **Quick Look preview for archives.** Selecting an archive in Finder (the preview pane, or the
  space bar) shows its type, method, file and folder counts, sizes and compression ratio, and its
  contents as a tree with 7-Zip's Name, Size, Packed Size and Modified columns, icons and font,
  folders first. **Open in 7-Zip** opens it in the app. Every archive type 7-Zip registers is
  covered, compressed tarballs (`.tar.gz`, `.tar.bz2`, `.tar.xz`, `.tar.zst`, …) included.
  The preview never asks for a password (an archive with encrypted file names says so), stops
  after about 2 seconds or 10 000 entries ("…and N more — open in 7-Zip"), and never writes
  anything. Options ▸ macOS ▸ **Quick Look preview for archives** turns it off and on; it is on
  by default and Reset All Settings turns it back on. The document icons Finder shows are
  unchanged.

## [1.1.3] — 2026-10-07

7-Zip 26.04 for macOS 1.1.3: security hardening of the Finder integration.

### Security

- Commands that the Finder extension and the Quick Actions hand to 7-Zip are now authenticated:
  each carries a secret that only 7-Zip and its own extensions can read, created on first launch
  and renewed by Options ▸ macOS ▸ Reset All Settings. Other applications and web pages can no
  longer start 7-Zip commands through the `sevenzip:` / `x-7zip:` link schemes.
- 7-Zip also checks every such command against the commands its Finder menu actually offers:
  extract into the archive's own folder, test, add next to the selected items, compress and email,
  checksums and open. Anything else, including targets inside `~/Library` (other than iCloud Drive
  and cloud storage folders) or system folders and symbolic links that lead there, is refused with
  a message. The Services menu items apply the same target checks. The full command line
  (`7-Zip.app/Contents/MacOS/7-Zip a …`) is unchanged.
- The update check's **Download** button opens only this project's release pages on GitHub.

### Changed

- **Propagate Zone.Id** (Options ▸ 7-Zip) is **Yes** by default, on a fresh install and after
  Reset All Settings: files extracted from a downloaded (quarantined) archive keep the quarantine
  flag, as with Archive Utility. A value you chose is kept; *No* is now stored when you pick it.
- If you choose a Finder or Quick Action command before 7-Zip has ever been opened, 7-Zip opens,
  finishes setting up and asks you to choose the command again.

## [1.1.2] — 2026-10-07

7-Zip 26.04 for macOS 1.1.2.

### Fixed

- Clicking a column header did not sort when **Show ".." item** (Options ▸ Settings) was on. The
  click was saved as the new sort, but the list kept its order, in every folder and inside every
  archive: the ".." row was counted as an item of the folder, so the sort looked stale and was
  dropped. Sorting from the header, View ▸ Arrange By and Ctrl+F3…F7 work with ".." shown.
- A column layout saved by another version, or damaged, is cleaned up when it is read: unknown,
  duplicate or missing columns, a sort on a column the folder does not have, out-of-range widths
  and values of the wrong type no longer lose the layout or affect sorting.

### Added

- **Options ▸ macOS ▸ Reset All Settings…** asks for confirmation, then puts every 7-Zip setting
  back to its default — options, window and panel layout, column layouts and sorts, histories,
  favorites — and restarts the app. Your files, archives and the Finder extension's on/off state
  are not touched.

### Changed

- The theme is **Light** by default, on a fresh install and after Reset All Settings. A theme you
  chose (Light or Dark) is kept. Before 1.1.2 *System* was the default and was not stored, so
  *System* chosen explicitly cannot be told apart from never chosen: pick *System* again in
  Options ▸ macOS if you want it; it is stored from now on.
- The Homebrew cask removes the quarantine flag after installing or upgrading, so a Homebrew
  install opens without *Open Anyway*. The disk image still needs it.

## [1.1.1] — 2026-10-07

7-Zip 26.04 for macOS 1.1.1: fixes for problems reported against 1.0.0.

### Fixed

- Opening an application bundle or another package as a folder (for example a Chrome web-app
  shim in `~/Applications/Chrome Apps.localized/`) showed "E_FAIL Unspecified error". Enter on any
  folder now opens it, as 7-Zip File Manager does; Open Outside (Shift+Return) still launches an
  app. A directory tried as an archive is reported as "not an archive" instead of failing.
- File names with an emoji or any other character outside the Basic Multilingual Plane showed
  as empty rows, both in folders and inside archives.
- A name with a control character, such as the Finder's `Icon\r` file, was drawn higher than
  the other rows. Every row now draws its text on the same baseline whatever characters the name
  holds (emoji, Arabic, Thai, Tibetan, combining marks), and the name column draws nothing for a
  control character, as the Windows list does. Other columns show line breaks as spaces.
- The status bar's first text no longer runs into the window's rounded bottom-left corner: it
  moves in by the corner's reach (8 pt on macOS 26, 4 pt on earlier versions), so it clears the
  frame as 7-Zip File Manager's does. The other parts keep the Windows inset of 2 px.
- View > Arrange By checks Name when the list is sorted by a column that has no item of its own
  (Created, Packed Size, ...), as 7-Zip File Manager does; it used to check nothing.

## [1.1.0] — 2026-10-07

7-Zip 26.04 for macOS 1.1.0: the engine updated to
[7-Zip 26.04](https://github.com/ip7z/7zip/releases/tag/26.04) (2026-10-05).

### Changed

- Updated the engine to 7-Zip 26.04. Upstream's summary is "some bugs and vulnerabilities were
  fixed": the NTFS, VHD and WIM handlers were largely rewritten, and the ISO, NSIS, Zip, APM, Cab,
  DMG, Ext and other readers were hardened against malformed archives. Auxiliary items that a
  handler marks as such are now left out of extraction and of checksum calculation. No format,
  extension, command-line switch, menu item or dialog control was added or removed.
- The bundled assets come from the official 7-Zip 26.04 Windows release (`7z2604-x64.exe`): new
  `7z.sfx` and `7zCon.sfx` self-extracting modules, an updated Slovak translation, and the 26.04
  help pages.

### Fixed

- **CRC SHA** on items inside an archive now counts the folders and includes their names in
  "checksum for data and names", as 7-Zip File Manager 26.04 does, so the sum equals the one for the
  same tree on disk (earlier versions skipped folders). Extracting with checksums
  (`-scrc`) gets the matching fix from the 26.04 engine.

### Changed in upstream sources

- The guarded macOS patches carry over to 26.04 unchanged and are all still needed
  ([Mac/docs/upstream-patches.md](Mac/docs/upstream-patches.md)).

## [1.0.0] — 2026-10-07

First public release: a native macOS port of the 7-Zip File Manager on the 7-Zip 26.03 engine.

### Added

- The 7-Zip File Manager in AppKit: two panels, large icons / small icons / list / details views,
  sortable columns, flat view, folder history, favorites, Back / Forward, and the 7zFM keyboard map.
- Archives browsed and edited like folders, including nested archives with write-back, for every
  format the engine supports.
- Extract, Add to archive (all compression options, AES-256 encryption, multi-volume archives,
  Windows self-extracting archives), Test, checksums with every hash method, Benchmark, Split,
  Combine, Link, Properties and comments.
- Options with the seven Windows pages plus a macOS page (theme: System / Light / Dark, grid lines).
- The 93 official 7-Zip translations, switchable live; the 7-Zip help pages, bundled.
- Finder integration: a Finder Sync extension with the 7-Zip submenu, two Quick Actions, five
  Services, document icons for 40 archive types, the `sevenzip://` URL scheme and the 7zG
  command-line grammar.
- Quarantine propagation on extraction (the macOS counterpart of Zone.Identifier), Dock-tile
  progress, drag and drop with Finder and between panels.
- A universal app (Apple Silicon and Intel): the arm64 slice keeps upstream's ARM64 assembler
  LZMA decoder, the x86_64 slice uses 7-Zip's C code paths, as upstream's clang builds do.
- Distribution as an ad-hoc signed disk image, `7-Zip-26.03-macOS-1.0.0.dmg`, and a Homebrew cask
  (`brew install --cask yrambler2001/tap/7zip-macos`).
- An update check against GitHub Releases: at File Manager startup at most once a day (off in
  Options ▸ macOS ▸ Check for updates at startup) and from Help ▸ Check for Updates…, with
  Download / Later / Skip This Version. Nothing is downloaded or installed automatically.
- Versioning: one source of truth, `Mac/VERSION`; the build number is the commit count;
  `Mac/scripts/bump-version.sh` raises the version and opens a changelog section.
- GitHub Actions: CI on every push and pull request (hygiene checks, universal build and disk image,
  unit tests on Apple silicon and under Rosetta), and a release workflow that turns
  a `v<version>` tag into a tested GitHub Release with the disk image and its SHA-256, ready to sign
  and notarize once a Developer ID exists, and updates the Homebrew cask
  ([docs/releasing.md](docs/releasing.md)).

### Changed in upstream sources

- A small set of guarded patches to the engine sources so the file-manager layer builds and
  behaves correctly on macOS; Windows behaviour is unchanged. See
  [Mac/docs/upstream-patches.md](Mac/docs/upstream-patches.md).

[1.1.3]: https://github.com/yrambler2001/7zip-macos/releases/tag/v1.1.3
[1.1.2]: https://github.com/yrambler2001/7zip-macos/releases/tag/v1.1.2
[1.1.1]: https://github.com/yrambler2001/7zip-macos/releases/tag/v1.1.1
[1.1.0]: https://github.com/yrambler2001/7zip-macos/releases/tag/v1.1.0
[1.0.0]: https://github.com/yrambler2001/7zip-macos/releases/tag/v1.0.0
