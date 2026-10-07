#!/usr/bin/env bash
# showcase.sh -- render reference screenshots of the app into Mac/build/screenshots/. Works from any directory.
# The README images in docs/images/ are full-window screenshots taken by hand with the macOS screenshot
# tool (main window sized 870x500 pt); this script no longer overwrites them.
#
# Usage: Mac/scripts/showcase.sh [--no-ui]
#   --no-ui     only the in-process images (skip the context-menu shot, which needs XCUITest)
#   -h, --help  this text
#
# 1. ShowcaseScreenshotTests (app-hosted) builds the neutral demo folder /Users/Shared/7-Zip Demo/
#    and renders the main window, Add to Archive, Extract and Options in Light and Dark at 2x.
# 2. ShowcaseUITests (XCUITest, input shard: needs the GUI session and automation mode) opens the
#    panel's context menu in that folder.
# 3. The results stay in Mac/build/screenshots/showcase-*.png (git-ignored).
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

ls "$SHOTS"/showcase-*.png 2>/dev/null || echo "showcase.sh: no showcase images were produced" >&2
