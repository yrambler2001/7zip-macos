#!/usr/bin/env bash
# run.sh -- build (Debug) and open the app.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
"$ROOT/Mac/scripts/build.sh" Debug
open "$ROOT/Mac/build/DerivedData/Build/Products/Debug/7-Zip.app" "$@"
