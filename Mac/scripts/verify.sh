#!/usr/bin/env bash
# verify.sh -- the one command to run before reporting a scope done: clean build, unit tests,
# app-hosted tests, UI tests, a dated summary in Mac/build/verify-latest.md. Non-zero on
# any failure.
# Works from any directory.
#
# Usage: Mac/scripts/verify.sh [options]
#   -f, --fast             skip the clean step (incremental build)
#   -n, --no-ui            unit tests only (use when no display is available)
#   -S, --shards           run the tests with test.sh --shards: one build-for-testing, the
#                          read-only targets concurrently, the input shard alone
#                          (capital S: -s stays --scope, as it always was)
#   -c, --config <CFG>     Debug (default) or Release
#   -s, --scope <NAME>     name the scope in the summary (default: the git branch)
#   -o, --out <PATH>       summary file (default Mac/build/verify-latest.md)
#   -h, --help             this text
# Unless --no-ui is given it takes the shared app-launch lock (<worktrees>/.app-lock) for the whole
# run, so two agents never drive the app at once; it waits up to 15 minutes, breaks a lock older
# than 30 minutes and releases it on any exit.
# Env: DEVELOPER_DIR (default /Applications/Xcode.app), SEVENZIP_APP_LOCK.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC="$ROOT/Mac"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

FAST=0
NO_UI=0
SHARDS=0
CONFIG="Debug"
SCOPE=""
OUT="$MAC/build/verify-latest.md"
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--fast) FAST=1 ;;
    -n|--no-ui) NO_UI=1 ;;
    -S|--shards) SHARDS=1 ;;
    -c|--config) CONFIG="${2:?--config needs a value}"; shift ;;
    -s|--scope) SCOPE="${2:?--scope needs a value}"; shift ;;
    -o|--out) OUT="${2:?--out needs a value}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "verify.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "$SCOPE" ] || SCOPE="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"

# --- shared app-launch lock (held for the whole run; ai/api/harness.md) -------------------
APP_LOCK="${SEVENZIP_APP_LOCK:-$(
  if [ -d "$ROOT/.worktrees" ]; then echo "$ROOT/.worktrees/.app-lock"
  elif [ "$(basename "$(dirname "$ROOT")")" = ".worktrees" ]; then echo "$(dirname "$ROOT")/.app-lock"
  else echo "${TMPDIR:-/tmp}/7zip-app-lock"; fi)}"
APP_LOCK_HELD=0
lock_owner() { cat "$APP_LOCK/owner" 2>/dev/null || echo "unknown"; }

release_app_lock() {
  if [ "$APP_LOCK_HELD" = 1 ]; then
    APP_LOCK_HELD=0
    rm -rf "$APP_LOCK"
    echo "== app lock released"
  fi
}

acquire_app_lock() {
  if [ -n "${SEVENZIP_APP_LOCK_HELD:-}" ]; then return 0; fi
  local i age
  for i in $(seq 1 180); do                                      # 180 * 5s = 15 min
    if mkdir "$APP_LOCK" 2>/dev/null; then
      echo "$SCOPE (verify.sh, pid $$, $(date '+%Y-%m-%d %H:%M:%S'))" >"$APP_LOCK/owner"
      APP_LOCK_HELD=1
      export SEVENZIP_APP_LOCK_HELD=1                            # test.sh below must not re-take it
      echo "== app lock acquired: $APP_LOCK"
      return 0
    fi
    age=$(( $(date +%s) - $(stat -f %m "$APP_LOCK" 2>/dev/null || date +%s) ))
    if [ "$age" -gt 1800 ]; then
      echo "== app lock $APP_LOCK is $((age / 60)) min old (owner: $(lock_owner)) -- stale, breaking it"
      rm -rf "$APP_LOCK"
      continue
    fi
    if [ "$i" = 1 ]; then echo "== waiting for the app lock $APP_LOCK (owner: $(lock_owner))"; fi
    sleep 5
  done
  echo "verify.sh: app lock $APP_LOCK still held after 15 min (owner: $(lock_owner))." >&2
  echo "           Wait for that run, or remove the directory if it is stale." >&2
  return 3
}

if [ "$NO_UI" = 0 ]; then
  trap release_app_lock EXIT INT TERM
  acquire_app_lock || exit 3
fi

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
  if [ "$SHARDS" = 1 ]; then
    # One build-for-testing, then the read-only targets concurrently and the input shard alone.
    if [ "$NO_UI" = 0 ]; then
      step "all tests (sharded)" "$MAC/scripts/test.sh" --shards --config "$CONFIG"
    else
      step "unit tests" "$MAC/scripts/test.sh" --target SevenZipKitTests --config "$CONFIG"
      step "app-hosted tests" "$MAC/scripts/test.sh" --host --config "$CONFIG"
    fi
  else
    step "unit tests" "$MAC/scripts/test.sh" --target SevenZipKitTests --config "$CONFIG"
    # The app-hosted unit tests run inside the app's own process: no window is driven, but a
    # display is still needed, so they follow the same --no-ui switch as the UI shards.
    if [ "$NO_UI" = 0 ]; then
      step "app-hosted tests" "$MAC/scripts/test.sh" --host --config "$CONFIG"
      step "UI tests" "$MAC/scripts/test.sh" --ui --config "$CONFIG"
    fi
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
  echo "## Parity (ai/PROGRESS.md)"
  echo
  echo '```'
  printf '%s\n' "$PARITY"
  echo '```'
  echo
  echo "Logs: \`Mac/build/build-$CONFIG.log\`, \`Mac/build/test-SevenZipKitTests.log\`,"
  echo "\`Mac/build/test-SevenZipAppTests.log\`, \`Mac/build/test-7-ZipUITests.log\`,"
  echo "\`Mac/build/test-7-ZipUITestsProbe1.log\`, \`Mac/build/test-7-ZipUITestsProbe2.log\`."
  echo "Screenshots: \`Mac/build/screenshots/\`."
} >"$OUT"

echo "== summary -> $OUT"
printf '%s\n' "$RESULTS" | sed '/^$/d'
if [ $RC -ne 0 ]; then
  echo "VERIFY FAILED (rc=$RC)"
  exit $RC
fi
echo "OK: verify passed"
