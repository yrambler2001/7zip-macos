#!/usr/bin/env bash
# update-cask.sh -- point the Homebrew cask at a release (pub4; used by release.yml).
#
# Usage: Mac/scripts/update-cask.sh <Casks/7zip-macos.rb> <PORT_VERSION> <UPSTREAM_VERSION> <SHA256>
#
# The cask's version is "<port>,<upstream>" (for example "1.0.0,26.03"): the release tag carries
# the port version and the disk image's name carries both, so the url is built from
# version.csv.first and version.csv.second. This rewrites the `version` and `sha256` lines and
# nothing else, and fails if either line is not found exactly once.
# Exit: 0 changed or already current, 1 failure, 2 bad usage.
set -euo pipefail
[ $# -eq 4 ] || { sed -n '3,4p' "${BASH_SOURCE[0]}" | sed 's/^# //' >&2; exit 2; }
CASK="$1" PORT="$2" UPSTREAM="$3" SHA="$4"
[ -f "$CASK" ] || { echo "update-cask.sh: no $CASK" >&2; exit 1; }
printf '%s' "$PORT" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "update-cask.sh: bad port version '$PORT'" >&2; exit 2; }
printf '%s' "$UPSTREAM" | grep -qE '^[0-9]+\.[0-9]+$' || { echo "update-cask.sh: bad upstream version '$UPSTREAM'" >&2; exit 2; }
printf '%s' "$SHA" | grep -qE '^[0-9a-f]{64}$' || { echo "update-cask.sh: bad sha256 '$SHA'" >&2; exit 2; }
for key in version sha256; do
  n="$(grep -cE "^  $key \"[^\"]*\"$" "$CASK" || true)"
  [ "$n" = 1 ] || { echo "update-cask.sh: expected one '  $key \"...\"' line in $CASK, found $n" >&2; exit 1; }
done
TMP="$(mktemp)"
sed -E -e "s/^  version \"[^\"]*\"$/  version \"$PORT,$UPSTREAM\"/" \
       -e "s/^  sha256 \"[^\"]*\"$/  sha256 \"$SHA\"/" "$CASK" >"$TMP"
if cmp -s "$TMP" "$CASK"; then
  rm -f "$TMP"; echo "update-cask.sh: $CASK already at $PORT,$UPSTREAM"
else
  cat "$TMP" >"$CASK"; rm -f "$TMP"; echo "update-cask.sh: $CASK -> $PORT,$UPSTREAM ($SHA)"
fi
