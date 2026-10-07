#!/usr/bin/env bash
# bump-version.sh -- raise the port's version in Mac/VERSION and open its CHANGELOG section (pub3).
#
# Usage: Mac/scripts/bump-version.sh <major|minor|patch|X.Y.Z> [--upstream <NN.NN>] [--dry-run]
#   major | minor | patch   1.2.3 -> 2.0.0 | 1.3.0 | 1.2.4
#   X.Y.Z                   that version (must be newer than the current one)
#   --upstream <NN.NN>      also set UPSTREAM_VERSION (after merging a new 7-Zip release; it must
#                           equal MY_VERSION in C/7zVersion.h, which VersionTests asserts)
#   -n, --dry-run           print what would change, change nothing
#   -h, --help              this text
#
# What it does: rewrites PORT_VERSION (and UPSTREAM_VERSION) in Mac/VERSION, and adds a section
#   ## [X.Y.Z] — unreleased
# with empty Added / Changed / Fixed lists above the newest section of CHANGELOG.md, plus its link
# at the bottom. The build number (CFBundleVersion) is not stored: it is the commit count of HEAD
# or $BUILD_NUMBER at build time (Mac/scripts/version.sh). Nothing is committed or tagged; the
# release tag is v<X.Y.Z>.
# Exit: 0 done, 1 failure, 2 bad usage.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VERSION_FILE="$ROOT/Mac/VERSION"
CHANGELOG="$ROOT/CHANGELOG.md"

WHAT=""
NEW_UPSTREAM=""
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --upstream) NEW_UPSTREAM="${2:?--upstream needs a value}"; shift ;;
    -n|--dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "bump-version.sh: unknown option '$1'" >&2; usage >&2; exit 2 ;;
    *) [ -z "$WHAT" ] || { echo "bump-version.sh: one version argument only" >&2; exit 2; }; WHAT="$1" ;;
  esac
  shift
done
[ -n "$WHAT" ] || { usage >&2; exit 2; }

# shellcheck source=version.sh
. "$ROOT/Mac/scripts/version.sh"
CURRENT="$PORT_VERSION"
[[ "$CURRENT" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "bump-version.sh: PORT_VERSION '$CURRENT' is not X.Y.Z" >&2; exit 1; }
MA="${BASH_REMATCH[1]}"; MI="${BASH_REMATCH[2]}"; PA="${BASH_REMATCH[3]}"

case "$WHAT" in
  major) NEW="$((MA + 1)).0.0" ;;
  minor) NEW="$MA.$((MI + 1)).0" ;;
  patch) NEW="$MA.$MI.$((PA + 1))" ;;
  *)
    [[ "$WHAT" =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || { echo "bump-version.sh: '$WHAT' is not major, minor, patch or X.Y.Z" >&2; exit 2; }
    NEW="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"
    # Strictly newer, compared numerically (1.10.0 > 1.9.0).
    if [ "$(printf '%s\n%s\n' "$CURRENT" "$NEW" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" != "$NEW" ] || [ "$NEW" = "$CURRENT" ]; then
      echo "bump-version.sh: $NEW is not newer than $CURRENT" >&2; exit 1
    fi
    ;;
esac
if [ -n "$NEW_UPSTREAM" ]; then
  [[ "$NEW_UPSTREAM" =~ ^[0-9]+\.[0-9]+$ ]] || { echo "bump-version.sh: --upstream '$NEW_UPSTREAM' is not NN.NN" >&2; exit 2; }
fi
UPSTREAM="${NEW_UPSTREAM:-$UPSTREAM_VERSION}"

echo "PORT_VERSION      $CURRENT -> $NEW"
[ "$UPSTREAM" = "$UPSTREAM_VERSION" ] || echo "UPSTREAM_VERSION  $UPSTREAM_VERSION -> $UPSTREAM"
echo "name              7-Zip $UPSTREAM for macOS $NEW   (tag v$NEW, 7-Zip-$UPSTREAM-macOS-$NEW.dmg)"
if grep -q "^## \[$NEW\]" "$CHANGELOG"; then
  echo "CHANGELOG.md      already has a [$NEW] section"
  ADD_SECTION=0
else
  echo "CHANGELOG.md      new section [$NEW]"
  ADD_SECTION=1
fi
[ "$DRY" = 1 ] && { echo "(dry run: nothing changed)"; exit 0; }

# Mac/VERSION: only the two value lines change; the comments stay.
TMP="$(mktemp)"
sed -e "s/^\([[:space:]]*PORT_VERSION[[:space:]]*=[[:space:]]*\).*/\1$NEW/" \
    -e "s/^\([[:space:]]*UPSTREAM_VERSION[[:space:]]*=[[:space:]]*\).*/\1$UPSTREAM/" "$VERSION_FILE" >"$TMP"
mv "$TMP" "$VERSION_FILE"

if [ "$ADD_SECTION" = 1 ]; then
  python3 - "$CHANGELOG" "$NEW" "$UPSTREAM" <<'PY'
import re, sys
path, new, upstream = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
section = (f"## [{new}] — unreleased\n\n"
           f"7-Zip {upstream} for macOS {new}.\n\n"
           "### Added\n\n-\n\n### Changed\n\n-\n\n### Fixed\n\n-\n\n")
m = re.search(r"^## \[", text, re.M)
text = text[:m.start()] + section + text[m.start():] if m else text.rstrip("\n") + "\n\n" + section
link = f"[{new}]: https://github.com/yrambler2001/7zip-macos/releases/tag/v{new}\n"
m = re.search(r"^\[[^\]]+\]: ", text, re.M)
text = text[:m.start()] + link + text[m.start():] if m else text.rstrip("\n") + "\n\n" + link
open(path, "w", encoding="utf-8").write(text)
PY
fi
echo "OK: Mac/VERSION and CHANGELOG.md updated; fill in the changelog, commit, then tag v$NEW"
