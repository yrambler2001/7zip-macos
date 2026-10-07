# Changelog

All notable changes to 7-Zip for macOS are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the port uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) for its own version; the engine version
is upstream 7-Zip's (for example *7-Zip 26.03 for macOS 1.0.0*).

## [1.0.0] — unreleased

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
  unit tests on Apple silicon and under Rosetta, app-hosted tests), and a release workflow that turns
  a `v<version>` tag into a tested GitHub Release with the disk image and its SHA-256, ready to sign
  and notarize once a Developer ID exists, and updates the Homebrew cask
  ([docs/releasing.md](docs/releasing.md)).

### Changed in upstream sources

- A small set of guarded patches to the engine sources so the file-manager layer builds and
  behaves correctly on macOS; Windows behaviour is unchanged. See
  [Mac/docs/upstream-patches.md](Mac/docs/upstream-patches.md).

[1.0.0]: https://github.com/yrambler2001/7zip-macos/releases/tag/v1.0.0
