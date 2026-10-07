# Releasing

Releases are built by GitHub Actions from a tag. Nothing is built or uploaded by hand.

| Workflow | Runs on | Does |
|---|---|---|
| [`ci.yml`](../.github/workflows/ci.yml) | every push to `macos`, every pull request into it | hygiene checks, universal Debug and Release builds and the disk image, unit tests on arm64 and on x86_64 under Rosetta 2 |
| [`release.yml`](../.github/workflows/release.yml) | a pushed tag `v*` | checks the tag against `Mac/VERSION`, runs the unit tests on both slices, builds and packages the universal app, signs and notarizes it if the secrets exist, publishes the GitHub Release, updates the Homebrew cask |

The app-hosted tests (`Mac/scripts/test.sh -H`) and the XCUITest suites (`Mac/scripts/test.sh -u`)
do not run on GitHub: the hosted runner's GUI session is not one they can be trusted on, and the UI
tests need permissions granted by hand ([testing.md](testing.md#why-the-app-hosted-tests-do-not-run-on-github)).
Run both locally before a release.

## Cutting a release

From an up-to-date `macos` with a green CI run:

```sh
export DEVELOPER_DIR=/Applications/Xcode.app
Mac/scripts/bump-version.sh minor          # or patch, major, X.Y.Z; see "Upstream" below for --upstream
$EDITOR CHANGELOG.md                       # fill in the new section, replace "unreleased" with the date
Mac/scripts/verify.sh                      # optional but recommended: every suite, including the UI tests
git commit -am "Version 1.2.0"
git tag -a v1.2.0 -m "7-Zip 26.04 for macOS 1.2.0"
git push origin macos v1.2.0
```

The tag must be `v` + `PORT_VERSION` from `Mac/VERSION`; the release workflow fails at once
otherwise. For the first release, 1.0.0 is already in `Mac/VERSION`: date its CHANGELOG section,
commit, tag `v1.0.0`, push.

What the release workflow then does:

1. **build** (macOS 26, Apple silicon, Xcode 26.6):
   - checks out the tag with full history: the build number (`CFBundleVersion`) is the commit count,
     as in a local build, so it is the same number on every machine;
   - fails unless the tag equals `v<PORT_VERSION>`, `UPSTREAM_VERSION` equals `MY_VERSION` in
     `C/7zVersion.h`, and `CHANGELOG.md` has a `## [<PORT_VERSION>]` section (`check-hygiene.sh`); it
     warns if that section still says *unreleased*;
   - runs `test.sh` (arm64) and `test.sh -A x86_64` (Rosetta);
   - signs with a Developer ID if one is configured (below), otherwise ad-hoc;
   - runs `package.sh`: universal Release, `7-Zip-<upstream>-macOS-<port>.dmg`, checked and mounted;
     notarized and stapled if the notarization secrets exist;
   - writes `<dmg>.sha256` and the release notes (`Mac/scripts/release-notes.sh`).
2. **release**: creates the GitHub Release *7-Zip &lt;upstream&gt; for macOS &lt;port&gt;* on the tag,
   with the image and its `.sha256`. The body is the version's CHANGELOG section, then the install
   steps (with the *Open Anyway* steps while the build is not notarized) and the SHA-256. The app's
   update check shows the release's first lines, so the changelog comes first. Re-running the job
   replaces the assets and the notes of the existing release.
3. **tap**: if the secret `TAP_TOKEN` exists, rewrites `version` and `sha256` (and nothing else, so
   the cask's quarantine step is kept) in
   `Casks/7zip-macos.rb` of [yrambler2001/homebrew-tap](https://github.com/yrambler2001/homebrew-tap)
   (`Mac/scripts/update-cask.sh`) and pushes the commit. Without the secret the job only prints a
   notice; update the cask by hand then (below).

**Dry run.** *Actions ▸ Release ▸ Run workflow* on a branch builds, tests and packages that commit
and uploads the disk image as a workflow artifact, and publishes nothing.

**If a release fails** after the tag is pushed: fix the cause on `macos`, delete the tag
(`git push origin :v1.1.0 && git tag -d v1.1.0`) and the draft or partial release if one was
created, then tag again. A failure in the **tap** job alone can be re-run from the Actions page.

## One-time setup on GitHub

### The repository

- Default branch `macos`; `main` mirrors upstream ([upstream.md](upstream.md)).
- *Settings ▸ Actions ▸ General*: allow GitHub Actions; workflow permissions *Read repository
  contents* (the default). The release job asks for `contents: write` for itself only.
- Optionally protect `macos` with the required checks *Hygiene*, *Build* and *Unit tests (arm64)*,
  *Unit tests (x86_64)*.
- Optionally protect tags `v*` (*Settings ▸ Rules ▸ Rulesets*) so only maintainers can push them.

### The Homebrew tap

1. Create the public repository `yrambler2001/homebrew-tap` (empty, no README) and push the
   prepared tap to it (`Casks/7zip-macos.rb`, `README.md`, `LICENSE`).
2. Create a fine-grained personal access token: *GitHub ▸ Settings ▸ Developer settings ▸ Personal
   access tokens ▸ Fine-grained tokens ▸ Generate new token*.
   - Resource owner: yrambler2001; repository access: *Only select repositories* ▸ `homebrew-tap`.
   - Permissions: *Contents: Read and write* (Metadata: read-only is added automatically). Nothing
     else.
   - Expiration: up to a year; put a reminder in the calendar to renew it.
3. In `yrambler2001/7zip-macos`: *Settings ▸ Secrets and variables ▸ Actions ▸ New repository
   secret*, name `TAP_TOKEN`, value the token.

Updating the cask by hand (no token, or a failed tap job):

```sh
cd homebrew-tap
/path/to/7zip-macos/Mac/scripts/update-cask.sh Casks/7zip-macos.rb 1.1.0 26.04 <sha256 from the release>
git commit -am "7zip-macos 1.1.0 (7-Zip 26.04)" && git push
```

The cask's version is `<port>,<upstream>` (`1.1.0,26.04`), because the image's name carries both.
Homebrew 7 needs a third-party tap to be trusted before it loads it implicitly: users install with
the full name (`brew install --cask yrambler2001/tap/7zip-macos`) and run `brew trust
yrambler2001/tap` once so that `brew upgrade` includes it; the tap's README and the cask's caveats
say so.

### Signing and notarization (later, with an Apple Developer ID)

Until these secrets exist every release is ad-hoc signed, and users of the disk image need *Open
Anyway* after each install and update; the Homebrew cask removes the quarantine flag itself (its
`postflight_steps`, the user's decision for 1.1.2), so Homebrew installs open directly. Once the
secrets exist, the next tag is signed with the hardened runtime, notarized and stapled
automatically; the release notes then leave out the *Open Anyway* steps. Remember to update the
README's "First launch: Gatekeeper" section and the cask's caveats at the same time, and drop the
cask's quarantine step, which a notarized app does not need.

| Secret | Value |
|---|---|
| `MACOS_CERT_P12` | the *Developer ID Application* certificate with its private key, exported from Keychain Access as `.p12`, then `base64 -i cert.p12 \| pbcopy` |
| `MACOS_CERT_PASSWORD` | the password chosen at export |
| `APPLE_TEAM_ID` | the 10-character team ID (*developer.apple.com ▸ Account ▸ Membership*) |

and, for notarization, **either** an App Store Connect API key (preferred: not tied to a person's
Apple ID; *App Store Connect ▸ Users and Access ▸ Integrations ▸ Team Keys*, role *Developer*):

| Secret | Value |
|---|---|
| `APPLE_API_KEY_P8` | the contents of `AuthKey_XXXXXXXXXX.p8` |
| `APPLE_API_KEY_ID` | its key ID |
| `APPLE_API_ISSUER_ID` | the issuer ID shown above the keys |

**or** an Apple ID with an app-specific password (*account.apple.com ▸ Sign-In and Security ▸
App-Specific Passwords*):

| Secret | Value |
|---|---|
| `APPLE_ID` | the Apple ID e-mail |
| `APPLE_APP_PASSWORD` | the app-specific password |

The workflow imports the certificate into a temporary keychain, which it deletes at the end of the
job; nothing persists on the runner. A certificate without notarization secrets gives a signed but
not notarized image (a warning in the run). Locally the same is
`Mac/scripts/package.sh -i "Developer ID Application: …" -T TEAMID -p <notarytool profile>`
([building.md](building.md#signing-and-notarization)).

The signing path cannot be exercised until a certificate exists; do a dry run (*Run workflow*)
after adding the secrets and check the log for `signing: Developer ID Application: …` and
`ticket stapled`.

## Upstream: merging a new 7-Zip release

When upstream publishes, say, 7-Zip 26.04 after port 1.0.0:

1. Merge it as [upstream.md](upstream.md) describes (`main` fast-forwards to upstream, a branch
   from `macos` merges `main`, conflicts only in the patched files).
2. Raise both versions in one go:

   ```sh
   Mac/scripts/bump-version.sh minor --upstream 26.04    # 7-Zip 26.04 for macOS 1.1.0
   ```

   A new engine is a minor release of the port at least; `VersionTests` and `check-hygiene.sh` fail
   until `UPSTREAM_VERSION` equals `MY_VERSION` in `C/7zVersion.h`.
3. Re-fetch the bundled assets for the new release (`Mac/scripts/fetch-assets.sh` with the new tag
   and hashes), regenerate `Mac/docs/upstream-patches.diff`, and note "Updated the engine to 7-Zip
   26.04" under *Changed* in the new CHANGELOG section.
4. Open a pull request into `macos`; when CI is green, merge it and cut the release as above. The
   image is then `7-Zip-26.04-macOS-1.1.0.dmg` and the cask version `1.1.0,26.04`.

## Pinned actions and tools

- Actions are pinned by commit SHA with the tag in a comment (`actions/checkout@<sha>  # v7.0.1`): a
  tag can be moved by whoever controls the action's repository, a SHA cannot. Only GitHub's own
  `actions/*` are used; the release itself is created with the `gh` CLI on the runner, so no
  third-party code sees the write token. Dependabot (`.github/dependabot.yml`) proposes updates
  monthly, SHA and comment together.
- Xcode is pinned to 26.6 and XcodeGen to 2.46.0 (by SHA-256) in
  [`.github/actions/setup-toolchain`](../.github/actions/setup-toolchain/action.yml). When the
  runner image drops that Xcode, the job fails with the list of installed ones; change the default
  there.
- The runner is `macos-26` (Apple silicon). Its image has Rosetta 2, which the x86_64 unit tests use.

## CI details

- **Compilation cache.** CI builds with Xcode's compilation caching
  (`COMPILATION_CACHE_ENABLE_CACHING=YES`) and keeps `CompilationCache.noindex` in the Actions cache.
  Entries are looked up by the hash of each compilation's exact inputs, so a restored cache cannot
  produce a stale object; DerivedData's build products, which Xcode trusts by file time, are not
  cached. `Mac/scripts/ci-trim-cache.sh` drops a cache over 2 GB so it starts afresh; to drop all
  of them, bump `CACHE_VERSION` in `ci.yml`. Releases never use the cache.
- **Hygiene** (`Mac/scripts/check-hygiene.sh`, runnable locally): no committed screenshots, no
  personal `/Users/<name>` paths, warnings-as-errors still set for every port target and no warning
  in the port's code in the build logs, `Mac/VERSION` consistent with the engine, a CHANGELOG section
  for the version. Next to it CI runs `check-links.sh` and `make-icons.sh` (the regenerated icons
  must equal the committed ones).
- **App-hosted tests** are not in CI: on the hosted runner's 1024 x 768 session they failed for
  reasons of the runner, not the app ([testing.md](testing.md#why-the-app-hosted-tests-do-not-run-on-github)).
  Run `Mac/scripts/test.sh -H` locally.
