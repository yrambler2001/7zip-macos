#!/usr/bin/env bash
# run.sh -- build (Debug) and open the app. Arguments are passed to open(1).
#
# Every worktree builds the same bundle id, so while you drive the app by hand take the shared
# app-launch lock yourself, or a UI test run will terminate your instance and you will overwrite
# each other's settings (recipe: Mac/docs/api/harness.md "App-launch lock"):
#   LOCK=<repo>/.worktrees/.app-lock
#   for i in $(seq 1 180); do mkdir "$LOCK" 2>/dev/null && break || sleep 5; done
#   echo "<scope>" >"$LOCK/owner";  trap 'rm -rf "$LOCK"' EXIT INT TERM
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"$ROOT/Mac/scripts/build.sh" Debug
open "$ROOT/Mac/build/DerivedData/Build/Products/Debug/7-Zip.app" "$@"
