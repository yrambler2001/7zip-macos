#!/usr/bin/env bash
# release-notes.sh -- print the GitHub Release body for a version (pub4; used by release.yml).
#
# Usage: Mac/scripts/release-notes.sh [--version X.Y.Z] [--sha256 <HASH>] [--notarized]
#   --version    the port version (default PORT_VERSION from Mac/VERSION)
#   --sha256     the disk image's SHA-256 (default: computed from Mac/build/<DMG_NAME> if present)
#   --notarized  the image is Developer ID signed and notarized: leave out the Open Anyway steps
#
# The body is the version's section of CHANGELOG.md (its "## [X.Y.Z]" heading and the link
# definitions at the bottom left out, relative links made absolute at the tag), then how to install, then the image's SHA-256. The first
# lines matter: the app's update check shows the first six non-blank lines of the body
# (Mac/App/Support/UpdateCheck.swift), so the changelog comes first.
# Exit: 0, 1 when CHANGELOG.md has no section for the version, 2 bad usage.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=version.sh
. "$ROOT/Mac/scripts/version.sh"
VERSION="$PORT_VERSION"
SHA=""
NOTARIZED=0
while [ $# -gt 0 ]; do
  case "$1" in
    --version) VERSION="${2:?--version needs a value}"; shift ;;
    --sha256) SHA="${2:?--sha256 needs a value}"; shift ;;
    --notarized) NOTARIZED=1 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "release-notes.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
  shift
done
DMG="7-Zip-$UPSTREAM_VERSION-macOS-$VERSION.dmg"
if [ -z "$SHA" ] && [ -f "$ROOT/Mac/build/$DMG" ]; then
  SHA="$(shasum -a 256 "$ROOT/Mac/build/$DMG" | cut -d' ' -f1)"
fi

SECTION="$(awk -v v="$VERSION" '
  BEGIN { head = "## [" v "]" }
  index($0, head) == 1 { on = 1; next }
  on && /^## \[/ { exit }
  on && /^\[[^]]+\]: / { next }
  on { print }
' "$ROOT/CHANGELOG.md")"
# Trim leading and trailing blank lines.
SECTION="$(printf '%s\n' "$SECTION" | awk 'NF { found = 1 } found' | awk '{ a[NR] = $0 } NF { last = NR } END { for (i = 1; i <= last; i++) print a[i] }')"
# Relative links point into the repository at the release tag, since a release body has no base.
SECTION="$(printf '%s\n' "$SECTION" \
  | sed -E "s#\]\(([^):#][^):]*)\)#](https://github.com/yrambler2001/7zip-macos/blob/v$VERSION/\1)#g")"
if [ -z "$SECTION" ]; then
  echo "release-notes.sh: CHANGELOG.md has no '## [$VERSION]' section" >&2
  exit 1
fi

printf '%s\n\n' "$SECTION"
cat <<MD
## Install

Requires macOS 14 (Sonoma) or newer; one universal app for Apple silicon and Intel.

- **Disk image:** download \`$DMG\` below, open it and drag **7-Zip** onto **Applications**.
- **Homebrew:** \`brew install --cask yrambler2001/tap/7zip-macos\` (or \`brew upgrade --cask 7zip-macos\`).
MD
if [ "$NOTARIZED" = 1 ]; then
  cat <<'MD'

This build is signed with a Developer ID and notarized by Apple: it opens without a warning.
MD
else
  cat <<'MD'

**Gatekeeper:** this build is ad-hoc signed, not notarized. The Homebrew cask removes the quarantine
flag after installing, so a Homebrew install opens directly. From the disk image macOS blocks the
first launch after every install and every update: open 7-Zip once and dismiss the warning, then
click **Open Anyway** in **System Settings ▸ Privacy & Security** and confirm. Details:
[First launch: Gatekeeper](https://github.com/yrambler2001/7zip-macos#first-launch-gatekeeper).
MD
fi
cat <<'MD'

To get the Finder menu, switch the extension on once: **Options ▸ 7-Zip ▸ Integrate 7-Zip to shell
context menu**, or **System Settings ▸ General ▸ Login Items & Extensions**.
MD
if [ -n "$SHA" ]; then
  # shellcheck disable=SC2016  # the backticks are Markdown
  printf '\n## SHA-256\n\n```\n%s  %s\n```\n' "$SHA" "$DMG"
fi
