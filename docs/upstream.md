# Following upstream 7-Zip

This repository is a fork of [ip7z/7zip](https://github.com/ip7z/7zip), the official 7-Zip source
mirror by Igor Pavlov.

| Branch | Contents |
|---|---|
| `main` | an exact mirror of upstream; never committed to here |
| `macos` | the default branch: upstream plus the port (`Mac/`, `docs/`, `ai/`, the root community files) |

## What the port changes upstream

The port lives in its own directories. Inside upstream's tree (`C/`, `CPP/`, `Asm/`, `DOC/`) it
only adds a handful of guarded hunks — `#ifdef _WIN32` / `#ifndef _WIN32` splits, `__APPLE__`
branches and Windows-typedef fixes — so Windows builds are unaffected. Every one is listed with its
reason in [`Mac/docs/upstream-patches.md`](../Mac/docs/upstream-patches.md), and the exact diff is
[`Mac/docs/upstream-patches.diff`](../Mac/docs/upstream-patches.diff). To see the current state:

```sh
git diff main macos -- C CPP Asm DOC
```

At the root the port replaces upstream's two-line `README.md` with its own and adds `LICENSE`,
`NOTICE` and the community files; upstream's own documentation stays in `DOC/`.

## Merging a new upstream release

```sh
git fetch upstream                       # remote: https://github.com/ip7z/7zip.git
git checkout main && git merge --ff-only upstream/main && git push origin main
git checkout -b mac/upstream-XX.YY macos
git merge main                           # conflicts can only be in the patched files or README.md
```

Then:

1. Resolve conflicts in the patched files by re-applying each hunk from `upstream-patches.md` to the
   new code; keep `README.md` as the port's.
2. Check whether upstream added, removed or renamed engine sources the `SevenZipCore` target lists
   (`Mac/project.yml`; the source set is explained in [`ai/02-engine-api.md`](../ai/02-engine-api.md)).
3. Update the bundled assets for the new release: bump `VERSION_TAG` and the pinned hashes in
   `Mac/scripts/fetch-assets.sh` and run it (Lang files, SFX stubs, help pages).
4. Update the version strings (`Info.plist` files, `package.sh`) and `CHANGELOG.md`.
5. Build and run the unit and app-hosted tests ([testing.md](testing.md)), regenerate
   `Mac/docs/upstream-patches.diff` (`git diff main -- C CPP Asm DOC > Mac/docs/upstream-patches.diff`),
   and open a pull request into `macos`.

Bugs in the archive engine itself (formats, compression, the command-line tools) belong upstream:
report them to 7-Zip at [7-zip.org](https://7-zip.org) or the
[7-Zip SourceForge project](https://sourceforge.net/projects/sevenzip/).
