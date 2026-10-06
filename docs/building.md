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
Mac/scripts/build.sh               # Debug, ad-hoc signed -> Mac/build/Debug/7-Zip.app
Mac/scripts/build.sh --release     # Release
Mac/scripts/run.sh                 # build, then open the app
Mac/scripts/test.sh                # unit tests (see testing.md for the other suites)
Mac/scripts/verify.sh              # clean build + every suite, summary in Mac/build/verify-latest.md
Mac/scripts/package.sh             # the disk image, Mac/build/7-Zip-26.03.dmg
Mac/scripts/parity-check.sh        # progress of the parity checklist (ai/PROGRESS.md)
```

Everything generated goes to `Mac/build/` (git-ignored), including the Xcode derived data.

## What gets built

`Mac/project.yml` describes the targets; new source files under `Mac/App`, `Mac/Core`,
`Mac/FinderSync` and `Mac/Tests` are picked up without editing it.

- `SevenZipCore` — the upstream engine from `C/`, `CPP/`, `Asm/`, compiled in place as a static
  library.
- `SevenZipKit` — the Objective-C++ bridge framework (`Mac/Core/`).
- `7-Zip` — the AppKit app (`Mac/App/`), with three embedded extensions: `FinderSync` and the two
  Quick Actions (`Mac/QuickAction/`).
- Test targets — see [testing.md](testing.md).

Debug builds are currently arm64 only (`ARCHS` in `Mac/project.yml`); the release pipeline builds
the universal (Apple Silicon + Intel) app.

## Bundled assets

`Mac/Resources/Lang/` (the 93 official translations), `Mac/Resources/SFX/` (the Windows
self-extracting stubs) and `Mac/Resources/Help/` (the help pages from `7-zip.chm`) come unmodified
from the official 7-Zip 26.03 Windows release. `Mac/scripts/fetch-assets.sh` downloads that release
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
spctl --assess --type open --context context:primary-signature -v Mac/build/7-Zip-26.03.dmg
xcrun stapler validate Mac/build/7-Zip-26.03.dmg
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
