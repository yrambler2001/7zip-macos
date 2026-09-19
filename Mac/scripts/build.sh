#!/usr/bin/env bash
# build.sh -- generate the Xcode project with XcodeGen and build the app, ad-hoc signed,
# into Mac/build/. Works from any directory.
#
# Usage: Mac/scripts/build.sh [Debug|Release] [options]
#   Debug | Release        configuration (positional, default Debug -- unchanged contract)
#   -c, --config <CFG>     same as the positional argument
#   -r, --release          shorthand for --config Release
#   -k, --clean            clean the configuration first (xcodebuild clean)
#   -K, --clean-all        remove Mac/build entirely (fresh DerivedData), then build
#   -t, --target <NAME>    build one target instead of the 7-Zip scheme
#   -q, --quiet            print only the verdict line
#   -h, --help             this text
# Env: DEVELOPER_DIR (default /Applications/Xcode.app), XCODEBUILD_EXTRA (extra args).
# Exit: 0 on success, xcodebuild's code on failure (2 on bad usage).
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC="$ROOT/Mac"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

CONFIG=""
CLEAN=0
CLEAN_ALL=0
TARGET=""
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    Debug|Release) CONFIG="$1" ;;
    -c|--config) CONFIG="${2:?--config needs a value}"; shift ;;
    -r|--release) CONFIG="Release" ;;
    -k|--clean) CLEAN=1 ;;
    -K|--clean-all) CLEAN_ALL=1 ;;
    -t|--target) TARGET="${2:?--target needs a value}"; shift ;;
    -q|--quiet) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "build.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
CONFIG="${CONFIG:-Debug}"

say() { [ "$QUIET" = 1 ] || echo "$@"; }

# Print the first real compiler/linker error with its context instead of the whole log.
# $1 = log file, $2 = how many lines of context (default 12).
print_first_error() {
  local log="$1" ctx="${2:-12}" n
  n="$(grep -nE '(:[0-9]+:[0-9]+: (error|fatal error):)|^(ld|clang|swiftc|xcodebuild): error:|^error:|Undefined symbols|Command .* failed with a nonzero exit code' "$log" \
      | grep -v 'CoreSimulator\|appintentsmetadataprocessor' | head -1 | cut -d: -f1 || true)"
  if [ -n "$n" ]; then
    echo "---- first error ($log:$n) ----"
    sed -n "${n},$((n + ctx))p" "$log"
    echo "---- (full log: $log) ----"
  else
    echo "---- no 'error:' line found; log tail ----"
    tail -20 "$log"
  fi
}

if [ "$CLEAN_ALL" = 1 ]; then
  say "== rm -rf $MAC/build"
  rm -rf "$MAC/build"
fi
mkdir -p "$MAC/build"
LOG="$MAC/build/build-$CONFIG.log"

say "== xcodegen"
# macOS has no timeout(1); XcodeGen can hang on bad source paths (04-toolchain.md 5.4).
perl -e 'alarm 120; exec @ARGV' xcodegen generate -s "$MAC/project.yml" -q

SCHEME_ARGS=(-scheme 7-Zip)
[ -n "$TARGET" ] && SCHEME_ARGS=(-target "$TARGET")

if [ "$CLEAN" = 1 ]; then
  say "== xcodebuild clean ($CONFIG)"
  xcodebuild -project "$MAC/7-Zip.xcodeproj" "${SCHEME_ARGS[@]}" -configuration "$CONFIG" \
    -derivedDataPath "$MAC/build/DerivedData" clean >"$MAC/build/clean-$CONFIG.log" 2>&1 \
    || { echo "CLEAN FAILED; log: $MAC/build/clean-$CONFIG.log"; exit 1; }
fi

say "== xcodebuild ($CONFIG) -> $LOG"
set +e
xcodebuild -project "$MAC/7-Zip.xcodeproj" "${SCHEME_ARGS[@]}" -configuration "$CONFIG" \
  -derivedDataPath "$MAC/build/DerivedData" -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES ${XCODEBUILD_EXTRA:-} build >"$LOG" 2>&1
RC=$?
set -e
# Show our own diagnostics (anything under Mac/) and the verdict.
if [ "$QUIET" = 0 ]; then
  grep -E '(^|/)Mac/[^ ]*:[0-9]+:[0-9]+: (warning|error)|error:|\*\* BUILD' "$LOG" | grep -v 'CoreSimulator\|appintentsmetadataprocessor' | tail -40 || true
fi
if [ $RC -ne 0 ]; then
  echo "BUILD FAILED (rc=$RC); full log: $LOG"
  print_first_error "$LOG"
  exit $RC
fi
APP="$MAC/build/DerivedData/Build/Products/$CONFIG/7-Zip.app"
mkdir -p "$MAC/build/$CONFIG"
ln -sfn "$APP" "$MAC/build/$CONFIG/7-Zip.app"
echo "OK: $MAC/build/$CONFIG/7-Zip.app -> $APP"
