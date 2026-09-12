#!/usr/bin/env bash
# build.sh -- generate the Xcode project with XcodeGen and build the app (Debug,
# ad-hoc signed) into Mac/build/. Usage: Mac/scripts/build.sh [Debug|Release]
# Env: DEVELOPER_DIR (default /Applications/Xcode.app), XCODEBUILD_EXTRA (extra args).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC="$ROOT/Mac"
CONFIG="${1:-Debug}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

mkdir -p "$MAC/build"
LOG="$MAC/build/build-$CONFIG.log"

echo "== xcodegen"
# macOS has no timeout(1); XcodeGen can hang on bad source paths (04-toolchain.md 5.4).
perl -e 'alarm 120; exec @ARGV' xcodegen generate -s "$MAC/project.yml" -q

echo "== xcodebuild ($CONFIG) -> $LOG"
set +e
xcodebuild -project "$MAC/7-Zip.xcodeproj" -scheme 7-Zip -configuration "$CONFIG" \
  -derivedDataPath "$MAC/build/DerivedData" -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES ${XCODEBUILD_EXTRA:-} build >"$LOG" 2>&1
RC=$?
set -e
# Show our own diagnostics (anything under Mac/) and the verdict.
grep -E '(^|/)Mac/[^ ]*:[0-9]+:[0-9]+: (warning|error)|error:|\*\* BUILD' "$LOG" | grep -v 'CoreSimulator\|appintentsmetadataprocessor' | tail -40 || true
if [ $RC -ne 0 ]; then
  echo "BUILD FAILED (rc=$RC); full log: $LOG"
  exit $RC
fi
APP="$MAC/build/DerivedData/Build/Products/$CONFIG/7-Zip.app"
mkdir -p "$MAC/build/$CONFIG"
ln -sfn "$APP" "$MAC/build/$CONFIG/7-Zip.app"
echo "OK: $MAC/build/$CONFIG/7-Zip.app -> $APP"
