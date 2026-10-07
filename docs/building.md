# Building 7-Zip for macOS

## Requirements

| What | Notes |
|---|---|
| macOS 14 (Sonoma) or newer | the app's deployment target |
| Xcode 26 at `/Applications/Xcode.app` | every script sets `DEVELOPER_DIR=/Applications/Xcode.app` itself; change that one variable if Xcode lives elsewhere. Do not rely on `xcode-select`. |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) | `Mac/7-Zip.xcodeproj` is generated from `Mac/project.yml` and is not in git |
| Python 3, `sips`, `iconutil` | only for regenerating icons (`Mac/scripts/make-icons.sh`); part of macOS and Xcode |

Nothing else: no package manager, no third-party library. Builds are ad-hoc signed, so no Apple
Developer account is needed.

## Scripts

All scripts live in `Mac/scripts/`, work from any directory, take `--help` and exit non-zero on
failure.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app
Mac/scripts/build.sh               # Debug, host architecture, ad-hoc signed -> Mac/build/Debug/7-Zip.app
Mac/scripts/build.sh --release     # Release, universal (arm64 + x86_64)
Mac/scripts/run.sh                 # build, then open the app
Mac/scripts/test.sh                # unit tests (see testing.md for the other suites)
Mac/scripts/test.sh -A x86_64      # the same tests on the Intel slice, under Rosetta 2
Mac/scripts/verify.sh              # clean build + every suite, summary in Mac/build/verify-latest.md
Mac/scripts/package.sh             # the universal disk image, Mac/build/7-Zip-26.04-macOS-1.1.3.dmg
Mac/scripts/version.sh             # the version: 7-Zip 26.04 for macOS 1.1.3, build number, DMG name
Mac/scripts/bump-version.sh minor  # raise the port version (major|minor|patch|X.Y.Z)
Mac/scripts/parity-check.sh        # progress of the parity checklist (ai/PROGRESS.md)
```

Everything generated goes to `Mac/build/` (git-ignored), including the Xcode derived data.

## What gets built

`Mac/project.yml` describes the targets; new source files under `Mac/App`, `Mac/Core`,
`Mac/FinderSync` and `Mac/Tests` are picked up without editing it.

- `SevenZipCore` — the upstream engine from `C/`, `CPP/`, `Asm/`, compiled in place as a static
  library.
- `SevenZipKit` — the Objective-C++ bridge framework (`Mac/Core/`).
- `7-Zip` — the AppKit app (`Mac/App/`), with four embedded extensions: `FinderSync`, the two
  Quick Actions (`Mac/QuickAction/`) and the Quick Look preview (`Mac/QuickLook/`, which links the
  app's `SevenZipKit` instead of carrying its own).
- Test targets — see [testing.md](testing.md).

## Universal build (Apple Silicon + Intel)

`ARCHS` is `arm64 x86_64` for every target. A **Release** build (`build.sh --release`,
`package.sh`) always builds both slices (`ONLY_ACTIVE_ARCH = NO`); a **Debug** build builds the
destination's architecture only — the host's by default, or the one given with `build.sh -a` /
`test.sh -A`.

The two slices of the engine differ the way upstream's own clang makefiles do:

| Slice | Assembler | As upstream's |
|---|---|---|
| arm64 | `Asm/arm64/LzmaDecOpt.S`, with `Z7_LZMA_DEC_OPT` for `C/LzmaDec.c` | `cmpl_mac_arm64.mak` (`USE_ASM=1`) |
| x86_64 | none: every `*Opt.c` is compiled as C, `LzmaDec.c` without `Z7_LZMA_DEC_OPT` | `cmpl_mac_x64.mak` (`USE_ASM=`) |

Upstream's x86 assembler (`Asm/x86/*.asm`) is MASM syntax and is not assembled. In
`Mac/project.yml` the x86_64 slice excludes `LzmaDecOpt.S` (`EXCLUDED_SOURCE_FILE_NAMES[arch=x86_64]`)
and the define comes from `SZ_LZMA_DEC_OPT_DEFS[arch=arm64]`. The engine target builds with clang
modules off, as upstream's makefiles do (with modules on, `C/AesOpt.c` does not compile for x86_64).
The hardware AES, SHA and CRC paths are chosen at run time on both slices, as upstream does.

Check a build with `lipo -info` (`package.sh` refuses an image with a binary that is not universal):

```sh
find Mac/build/Release/7-Zip.app/ -type f -perm +111 -exec sh -c 'file -b "$1" | grep -q Mach-O && lipo -info "$1"' _ {} \;
```

### Testing the Intel slice under Rosetta

On Apple Silicon the x86_64 slice runs under Rosetta 2. Install it once with
`softwareupdate --install-rosetta --agree-to-license`, then:

```sh
Mac/scripts/test.sh -A x86_64        # unit tests (SevenZipKitTests), x86_64, Mac/build/DerivedData-x86_64
Mac/scripts/test.sh -A x86_64 -H     # the app-hosted tests too
```

`VersionTests/testRunningSlice` asserts that the slice under test is the one asked for.

## Versions

One file holds the version: `Mac/VERSION`.

```
PORT_VERSION = 1.1.3         the port's own semantic version
UPSTREAM_VERSION = 26.04     the 7-Zip engine (must equal MY_VERSION in C/7zVersion.h)
```

- `Mac/Version.xcconfig` includes it for every target: `MARKETING_VERSION = $(PORT_VERSION)` is
  `CFBundleShortVersionString` of the app, the framework and the three extensions (their
  `Info.plist`s say `$(MARKETING_VERSION)`).
- `CFBundleVersion` is the **build number**: `$BUILD_NUMBER` when set (CI), else the commit count of
  `HEAD`. `build.sh` and `test.sh` write it to `Mac/build/BuildNumber.xcconfig`, which the xcconfig
  includes optionally; a build straight from Xcode gets `1`.
- The user-visible name is **7-Zip 26.04 for macOS 1.1.3**: the About box, the update check, the
  disk image `7-Zip-26.04-macOS-1.1.3.dmg` and its volume name. `Mac/scripts/version.sh` prints
  each form.
- Releases are tagged `v<PORT_VERSION>` (`v1.1.3`) at
  <https://github.com/yrambler2001/7zip-macos/releases>; the app's update check compares that tag
  with its own version.

To release a new version:

```sh
Mac/scripts/bump-version.sh patch          # or minor, major, 1.2.0; --upstream 26.05 after an upstream merge
$EDITOR CHANGELOG.md                       # fill in the new section and date it
git commit -am "Version 1.1.3" && git tag -a v1.1.3 -m "7-Zip 26.04 for macOS 1.1.3"
git push origin macos v1.1.3               # the release workflow builds, tests and publishes it
```

[releasing.md](releasing.md) describes the workflow, the Homebrew tap and the signing secrets.
`Mac/scripts/package.sh` makes the same disk image locally.

## Bundled assets

`Mac/Resources/Lang/` (the 93 official translations), `Mac/Resources/SFX/` (the Windows
self-extracting stubs) and `Mac/Resources/Help/` (the help pages from `7-zip.chm`) come unmodified
from the official 7-Zip 26.04 Windows release. `Mac/scripts/fetch-assets.sh` downloads that release
and re-extracts them against pinned SHA-256 hashes. Test fixtures are made by
`Mac/scripts/make-fixtures.sh`, which needs the console `7zz`:

```sh
cd CPP/7zip/Bundles/Alone2 && make -j8 -f ../../cmpl_mac_arm64.mak
```

## Signing and notarization

The default build and the DMG are ad-hoc signed: `codesign --verify --deep --strict` reports them
valid, `spctl --assess` rejects them (no Developer ID), which is why a downloaded copy needs
*Open Anyway* once (see the [README](../README.md#first-launch-gatekeeper)).

With a Developer ID certificate, `package.sh` signs with the hardened runtime and a secure
timestamp, signs the app, its framework, the three extensions and the disk image, notarizes with
`xcrun notarytool --wait` and staples:

```sh
# once: a "Developer ID Application" certificate in the login keychain, then
security find-identity -v -p codesigning
xcrun notarytool store-credentials 7zip-notary --apple-id you@example.com --team-id TEAMID
# every release:
Mac/scripts/package.sh -i "Developer ID Application: Your Name (TEAMID)" -T TEAMID -p 7zip-notary
spctl --assess --type open --context context:primary-signature -v Mac/build/7-Zip-26.04-macOS-1.1.3.dmg
xcrun stapler validate Mac/build/7-Zip-26.04-macOS-1.1.3.dmg
```

The app needs one hardened-runtime entitlement, `com.apple.security.automation.apple-events`
(`Mac/Resources/App.entitlements`): Properties on files outside an archive asks Finder for its Get
Info windows. The extensions keep their sandbox entitlement.

## Troubleshooting

- *"xcodegen: command not found"* — install it with Homebrew; `/opt/homebrew/bin` must be on `PATH`.
- *The Finder menu calls another copy of 7-Zip* — every copy registers the same extension. The
  build and test scripts hand the extension back to the copy that had it before
  (`Mac/scripts/finderext-registration.sh`); `pluginkit -m -D -A -v -i com.yrambler2001.7zip.FinderSync`
  lists all registered copies.
- More toolchain traps are recorded in [`ai/04-toolchain.md`](../ai/04-toolchain.md).
