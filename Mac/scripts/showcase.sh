#!/usr/bin/env bash
# showcase.sh -- retake the images in docs/images/ (README, docs/parity.md). Works from any directory.
#
# Usage: Mac/scripts/showcase.sh [--no-ui]
#   --no-ui     only the in-process images (skip the context-menu shot, which needs XCUITest)
#   -h, --help  this text
#
# 1. ShowcaseScreenshotTests (app-hosted) builds the neutral demo folder /Users/Shared/7-Zip Demo/
#    and renders the main window, Add to Archive, Extract and Options in Light and Dark at 2x.
# 2. ShowcaseUITests (XCUITest, input shard: needs the GUI session and automation mode) opens the
#    panel's context menu in that folder.
# 3. The results (Mac/build/screenshots/showcase-*.png) are copied into docs/images/.
# Look at every image before committing it: no user name or machine detail may be visible.
# The document-icon sheets and the font comparison are not retaken here (ai/reports/docicons.md,
# ai/reports/feel3.md).
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHOTS="$ROOT/Mac/build/screenshots"
IMAGES="$ROOT/docs/images"
UI=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-ui) UI=0 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "showcase.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# The flag file turns the opt-in tests on (both test processes can read it; the UI runner is
# sandboxed but may read the worktree).
FLAG="$ROOT/Mac/build/showcase/RUN"
mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"
trap 'rm -f "$FLAG"' EXIT
"$ROOT/Mac/scripts/test.sh" -o ShowcaseScreenshotTests
if [ "$UI" = 1 ]; then
  "$ROOT/Mac/scripts/test.sh" -o ShowcaseUITests
fi

copy() {
  if [ -f "$SHOTS/showcase-$1.png" ]; then
    cp "$SHOTS/showcase-$1.png" "$IMAGES/$2.png"
    echo "docs/images/$2.png"
  else
    echo "showcase.sh: missing $SHOTS/showcase-$1.png" >&2
  fi
}
mkdir -p "$IMAGES"
copy main-light main-light
copy main-dark main-dark
copy add-to-archive-light add-to-archive
copy add-to-archive-dark add-to-archive-dark
copy extract-light extract
copy extract-dark extract-dark
copy options-dark options-dark
copy options-macos-light options-macos-light
copy options-macos-dark options-macos-dark
if [ "$UI" = 1 ]; then copy context-menu context-menu; fi
