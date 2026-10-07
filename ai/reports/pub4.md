# pub4 — CI, release workflow, Homebrew tap

Branch `mac/pub4`, in the cleaned clone `7zip-macos` (from `macos` 8393bdf). Nothing was pushed and
no remote was added; publishing is the maintainer's step (docs/releasing.md, "One-time setup").

## 1. What was added

| File | Purpose |
|---|---|
| `.github/workflows/ci.yml` | push to `macos`, PRs into it, manual: jobs **hygiene**, **build**, **unit** (matrix arm64 / x86_64), **app-hosted** (informational) |
| `.github/workflows/release.yml` | tag `v*`: **build** (tag = `v`+PORT_VERSION, unit tests both slices, optional Developer ID signing + notarization, `package.sh`, `.sha256`, release notes) → **release** (`gh release create`, `contents: write` for that job only) → **tap** (only with secret `TAP_TOKEN`); manual run = dry run |
| `.github/actions/setup-toolchain/action.yml` | `DEVELOPER_DIR=/Applications/Xcode_26.6.app` via `GITHUB_ENV` (no `xcode-select`), XcodeGen 2.46.0 from its release, SHA-256 checked |
| `.github/dependabot.yml` | monthly grouped updates of the SHA-pinned actions |
| `Mac/scripts/check-hygiene.sh` | committed screenshots, personal `/Users/<name>` paths (placeholders me/someone/x/you/runner/Shared allowed; upstream dirs excluded), warnings-as-errors still set per port target, `--build-log` scan for `Mac/…: warning:`, `UPSTREAM_VERSION` = `MY_VERSION_NUMBERS`, CHANGELOG section for PORT_VERSION |
| `Mac/scripts/release-notes.sh` | release body: CHANGELOG section (relative links made absolute at the tag), install steps, Open Anyway (left out when notarized), Finder extension note, SHA-256 |
| `Mac/scripts/update-cask.sh` | rewrites `version "<port>,<upstream>"` and `sha256` in the cask; validates its inputs |
| `Mac/scripts/ci-trim-cache.sh` | drops a CI compilation cache over 2 GB |
| `docs/releasing.md` | cutting a release, what each job does, secrets (signing, notarization by API key or Apple ID, `TAP_TOKEN`), upstream merge (26.04 after 1.0.0), pinning, CI details |

Edited: `README.md` (Homebrew install, `brew trust`, Open Anyway after every install/update, link
to releasing.md), `CHANGELOG.md` (1.0.0: CI and release workflow, cask command), `docs/building.md`
(release steps now push a tag), `docs/upstream.md` (step 4 uses `bump-version.sh --upstream`).

## 2. Decisions

- **Runner** `macos-26` (Apple silicon; `macos-26-intel` is the x64 one). Its image has Xcode 26.0.1
  to 26.6 (26.6 default; the local machine has 26.6 too) and Rosetta 2 (`install-rosetta.sh` in
  actions/runner-images), so `test.sh -A x86_64` runs there.
- **Actions pinned by commit SHA**, tag in a comment: checkout v7.0.1 `3d3c42e5…`, cache v6.1.0
  `55cc8345…`, upload-artifact v7.0.1 `043fb46d…`, download-artifact v8.0.1 `3e5f45b2…` (resolved with
  `gh api …/git/ref/tags/…`). Only `actions/*`; the release is made with the preinstalled `gh`, so no
  third-party action holds the write token.
- **Caching.** DerivedData is not cached: Xcode trusts products by mtime, which a checkout resets, and
  a stale product is the unsafe failure mode. Instead Xcode 26 compilation caching
  (`COMPILATION_CACHE_ENABLE_CACHING=YES` via `XCODEBUILD_EXTRA`) with
  `DerivedData*/CompilationCache.noindex` in actions/cache: content-addressed, so a hit is always an
  identical compilation. Measured: universal Release from scratch 110 s; DerivedData deleted, cache
  restored, every source touched: 18 s. Release builds never use it.
- **App-hosted tests** run on hosted runners (they have a GUI session) but as `continue-on-error`:
  window rendering and pixel comparisons depend on the runner's display. UI tests stay local.
- **Build number**: CI uses `github.run_number` (no history needed); releases use the commit count
  (`fetch-depth: 0`), as `version.sh` does locally, so a release and a local build of the same tag
  agree.
- **Signing**: secrets → temporary keychain (default + first in the search list, deleted at the end),
  identity found by `security find-identity`, team from `APPLE_TEAM_ID` or the identity; notarytool
  profile stored from either an App Store Connect API key (`APPLE_API_KEY_P8/_ID/_ISSUER_ID`,
  preferred) or `APPLE_ID`/`APPLE_TEAM_ID`/`APPLE_APP_PASSWORD`; `package.sh -i -T -p` does the rest.
  Without secrets: ad-hoc, a notice in the run. Not exercisable without a certificate.
- **Cask version** `"1.0.0,26.03"`, url from `version.csv.first/second`; livecheck `:github_latest`
  with a block that maps the DMG asset name to `"<port>,<upstream>"`.
- **Tap license** BSD-2-Clause: Homebrew's and homebrew/cask's license, so the cask can move between
  the tap and the official repo; a cask contains no 7-Zip code, so LGPL is not needed.

## 3. Finding: Homebrew 7 tap trust

Homebrew 7.0.8 (local) refuses to load casks from an untrusted third-party tap
(`Homebrew::UntrustedTapError`) unless the command names it in full
(`trust.rb: explicitly_allowed?`). So `brew install --cask yrambler2001/tap/7zip-macos` works, but a
plain `brew upgrade` skips the tap until `brew trust yrambler2001/tap`. README, the tap README, the
cask caveats and releasing.md say so.

## 4. Tap repository (local, no remote)

`/Users/yrambler2001/things/a.noindex/homebrew-tap`, one commit: `Casks/7zip-macos.rb`, `README.md`,
`LICENSE`, `.gitignore`. sha256 = the worktree DMG of this branch (build 326,
`08c7a940…87df`); the release workflow overwrites it. No `xattr` / quarantine stripping; `uninstall
quit:`; `zap` for Application Scripts, Caches, Containers, HTTPStorages, Preferences, Saved
Application State of `com.yrambler2001.7zip*`; `depends_on macos: :sonoma` (brew style rejects
`">= :sonoma"` now: `Homebrew/OSDependsOn`).

Validation (tapped temporarily with `brew tap yrambler2001/tap <path>`, untapped afterwards):
`brew style --cask` no offenses; `brew audit --cask --strict` passed; `brew audit --cask --new
--online` fails only with `GitHub::API::HTTPNotFoundError` (the repository is not public yet). The
livecheck block, fed a `releases/latest` fixture with `7-Zip-26.04-macOS-1.2.0.dmg`, returns
`1.2.0,26.04`. `update-cask.sh` rewrote the placeholder, reported "already at" on a second run, and
refused `1.0` (exit 2).

## 5. Local validation

- `actionlint` 0 errors (includes shellcheck of every `run:`); `yamllint` (default rules,
  line-length 160) clean; `shellcheck` clean on the four new scripts.
- The CI jobs replayed in order on this machine (Xcode 26.6, the pinned XcodeGen binary first on
  `PATH`, `BUILD_NUMBER=1`, compilation caching on, from an empty `Mac/build`):

| Step | Result | Time |
|---|---|---|
| check-hygiene.sh | ok (after fixing the self-match below) | 0 s |
| check-links.sh | 78 links, 0 broken | 0 s |
| make-icons.sh + no diff in Mac/Resources | 280 .icns slots verified, tree unchanged | 87 s |
| build.sh Debug, `ONLY_ACTIVE_ARCH=NO`, `lipo -verify_arch arm64 x86_64` | ok | 79 s |
| package.sh (universal Release, DMG) | ok, every Mach-O universal | 119 s |
| check-hygiene --build-log (Debug, Release, unit) | no `Mac/` warnings | 0 s |
| test.sh -A arm64 | 403 executed, 5 skipped (need `7zz`), 0 failures | 50 s |
| test.sh -A x86_64 (Rosetta) | 403 executed, 5 skipped, 0 failures | 75 s |
| test.sh -H | 297 executed, 10 skipped, 0 failures | 281 s |

  The first replay caught `check-hygiene.sh` flagging its own regex (`/Users/[^…`); the path pattern
  is now `/Users/[A-Za-z0-9._-]+`. A negative test (a `/Users/<real name>` line in README, a target
  without warnings-as-errors, a log with a `Mac/` warning) fails with three findings.
- `release-notes.sh` output checked by eye; `package.sh -q` with the real build number: 21 s warm.
- After all builds `pluginkit` shows `/Applications/7-Zip.app` as the only registered copy of the
  three extensions.

Not verifiable locally: the runs on GitHub's runners themselves, the signing/notarization path (no
certificate), `gh release create`, and the tap push.
