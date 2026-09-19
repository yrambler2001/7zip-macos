#!/usr/bin/env bash
# verify.sh -- the one command to run before reporting a scope done: clean build, unit tests,
# UI tests, a dated summary in Mac/docs/reports/verify-latest.md. Non-zero on any failure.
# Works from any directory.
#
# Usage: Mac/scripts/verify.sh [options]
#   -f, --fast             skip the clean step (incremental build)
#   -n, --no-ui            unit tests only (use when no display is available)
#   -c, --config <CFG>     Debug (default) or Release
#   -s, --scope <NAME>     name the scope in the summary (default: the git branch)
#   -o, --out <PATH>       summary file (default Mac/docs/reports/verify-latest.md)
#   -h, --help             this text
# Env: DEVELOPER_DIR (default /Applications/Xcode.app).
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC="$ROOT/Mac"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

FAST=0
NO_UI=0
CONFIG="Debug"
SCOPE=""
OUT="$MAC/docs/reports/verify-latest.md"
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--fast) FAST=1 ;;
    -n|--no-ui) NO_UI=1 ;;
    -c|--config) CONFIG="${2:?--config needs a value}"; shift ;;
    -s|--scope) SCOPE="${2:?--scope needs a value}"; shift ;;
    -o|--out) OUT="${2:?--out needs a value}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "verify.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$SCOPE" ] || SCOPE="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

mkdir -p "$MAC/build" "$(dirname "$OUT")"
STAMP="$(date '+%Y-%m-%d %H:%M:%S %z')"
RESULTS=""      # "<status>\t<step>\t<seconds>\t<detail>" per line
RC=0

step() {                      # step <name> <command...>
  local name="$1"; shift
  local started elapsed rc=0 out
  echo "== $name"
  started=$(date +%s)
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  printf '%s\n' "$out" | tail -25
  if [ $rc -eq 0 ]; then
    RESULTS="$RESULTS
| ok | $name | ${elapsed}s | $(printf '%s' "$out" | grep -E '^(OK|   total)' | tail -1 | tr '|' '/') |"
  else
    RC=$rc
    RESULTS="$RESULTS
| **FAIL** | $name | ${elapsed}s | rc=$rc: $(printf '%s' "$out" | grep -E 'error:|FAILED|failed' | head -1 | tr '|' '/' | cut -c1-160) |"
  fi
  return 0
}

if [ "$FAST" = 1 ]; then
  step "build ($CONFIG)" "$MAC/scripts/build.sh" --config "$CONFIG"
else
  step "clean build ($CONFIG)" "$MAC/scripts/build.sh" --config "$CONFIG" --clean-all
fi

if [ $RC -eq 0 ]; then
  step "unit tests" "$MAC/scripts/test.sh" --target SevenZipKitTests --config "$CONFIG"
  if [ "$NO_UI" = 0 ]; then
    step "UI tests" "$MAC/scripts/test.sh" --ui --config "$CONFIG"
  fi
else
  RESULTS="$RESULTS
| skipped | tests | 0s | the build failed |"
fi

PARITY="$("$MAC/scripts/parity-check.sh" 2>/dev/null || echo '(parity-check failed)')"

{
  echo "# Verification run — $STAMP"
  echo
  echo "* scope / branch: \`$SCOPE\`  (commit \`$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo '?')\`)"
  echo "* configuration: $CONFIG$([ "$FAST" = 1 ] && echo ' (incremental)' || echo ' (clean)')"
  echo "* command: \`Mac/scripts/verify.sh\`  → exit $RC"
  echo "* toolchain: \`DEVELOPER_DIR=$DEVELOPER_DIR\`, $(xcodebuild -version 2>/dev/null | head -1)"
  echo
  echo "| result | step | time | detail |"
  echo "|---|---|---|---|"
  printf '%s\n' "$RESULTS" | sed '/^$/d'
  echo
  echo "## Parity (Mac/docs/PROGRESS.md)"
  echo
  echo '```'
  printf '%s\n' "$PARITY"
  echo '```'
  echo
  echo "Logs: \`Mac/build/build-$CONFIG.log\`, \`Mac/build/test-SevenZipKitTests.log\`, \`Mac/build/test-7-ZipUITests.log\`."
  echo "Screenshots: \`Mac/docs/reports/screenshots/\`."
} >"$OUT"

echo "== summary -> $OUT"
printf '%s\n' "$RESULTS" | sed '/^$/d'
if [ $RC -ne 0 ]; then
  echo "VERIFY FAILED (rc=$RC)"
  exit $RC
fi
echo "OK: verify passed"
