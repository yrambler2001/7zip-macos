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
#   -T, --for-testing      build-for-testing the 7-Zip-AllTests scheme, so every test target and
#                          every app copy is compiled once and the shards can then be run with
#                          `test.sh --shards` (or xcodebuild test-without-building) without a rebuild
#   -q, --quiet            print only the verdict line
#   -h, --help             this text
# Env: DEVELOPER_DIR (default /Applications/Xcode.app), XCODEBUILD_EXTRA (extra args),
#      SIGN_IDENTITY (default "-" = ad-hoc; a Developer ID name also turns the hardened runtime on),
#      DEVELOPMENT_TEAM (team identifier, only meaningful with a real SIGN_IDENTITY).
# Exit: 0 on success, xcodebuild's code on failure (2 on bad usage).
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC="$ROOT/Mac"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

CONFIG=""
FOR_TESTING=0
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
    -T|--for-testing) FOR_TESTING=1 ;;
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

# One target instead of the scheme. Xcode 26's xcodebuild refuses -target together with
# -derivedDataPath ("The flag -scheme, -testProductsPath, or -xctestrun is required when
# specifying -derivedDataPath"), which made `build.sh -t <NAME>` fail for every target, so a
# single-target build points SYMROOT/OBJROOT at the same DerivedData tree by hand instead.
DD="$MAC/build/DerivedData"
SCHEME_ARGS=(-scheme 7-Zip -derivedDataPath "$DD")
if [ "$FOR_TESTING" = 1 ]; then SCHEME_ARGS=(-scheme 7-Zip-AllTests -derivedDataPath "$DD"); fi
if [ -n "$TARGET" ]; then
  SCHEME_ARGS=(-target "$TARGET"
    "SYMROOT=$DD/Build/Products"
    "OBJROOT=$DD/Build/Intermediates.noindex"
    "SHARED_PRECOMPS_DIR=$DD/Build/Intermediates.noindex/PrecompiledHeaders")
fi

if [ "$CLEAN" = 1 ]; then
  say "== xcodebuild clean ($CONFIG)"
  xcodebuild -project "$MAC/7-Zip.xcodeproj" "${SCHEME_ARGS[@]}" -configuration "$CONFIG" \
    clean >"$MAC/build/clean-$CONFIG.log" 2>&1 \
    || { echo "CLEAN FAILED; log: $MAC/build/clean-$CONFIG.log"; exit 1; }
fi

# Signing (packaging scope). Ad-hoc by default, which is all a machine with no identity can do
# ("0 valid identities found" here). For a distributable build pass a Developer ID:
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" DEVELOPMENT_TEAM=TEAMID build.sh -r
# A real identity also switches the hardened runtime on and asks for a secure timestamp, both of
# which notarization requires; ad-hoc keeps it off because an ad-hoc signature cannot be notarized.
SIGN_IDENTITY="${SIGN_IDENTITY:-${CODESIGN_IDENTITY:--}}"
SIGN_ARGS=(CODE_SIGNING_ALLOWED=YES CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$SIGN_IDENTITY")
if [ "$SIGN_IDENTITY" = "-" ]; then
  SIGN_ARGS+=(ENABLE_HARDENED_RUNTIME=NO "DEVELOPMENT_TEAM=")
  say "== signing: ad-hoc"
else
  SIGN_ARGS+=(ENABLE_HARDENED_RUNTIME=YES "OTHER_CODE_SIGN_FLAGS=--timestamp --options=runtime")
  [ -n "${DEVELOPMENT_TEAM:-}" ] && SIGN_ARGS+=("DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
  say "== signing: $SIGN_IDENTITY (hardened runtime on)"
fi

ACTION=build
if [ "$FOR_TESTING" = 1 ]; then ACTION=build-for-testing; fi
say "== xcodebuild $ACTION ($CONFIG) -> $LOG"
# The build registers its FinderSync.appex, which would take Finder's 7-Zip menu away from the
# copy the user runs; hand it back afterwards (finderext-registration.sh, reports/appfeel.md).
# shellcheck source=finderext-registration.sh
. "$MAC/scripts/finderext-registration.sh"
finderext_snapshot
set +e
xcodebuild -project "$MAC/7-Zip.xcodeproj" "${SCHEME_ARGS[@]}" -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  "${SIGN_ARGS[@]}" ${XCODEBUILD_EXTRA:-} "$ACTION" >"$LOG" 2>&1
RC=$?
set -e
finderext_restore
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
if [ "$FOR_TESTING" = 1 ]; then
  PLAN="$(ls -t "$DD/Build/Products"/*.xctestrun 2>/dev/null | head -1)"
  echo "OK: $MAC/build/$CONFIG/7-Zip.app -> $APP"
  echo "    test plan: ${PLAN:-none produced}"
else
  echo "OK: $MAC/build/$CONFIG/7-Zip.app -> $APP"
fi
