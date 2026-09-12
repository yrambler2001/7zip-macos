#!/usr/bin/env bash
# test.sh -- run the SevenZipKit unit tests (XCTest) with xcodebuild.
# Usage: Mac/scripts/test.sh   (Debug). Env: DEVELOPER_DIR.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC="$ROOT/Mac"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"
mkdir -p "$MAC/build"
LOG="$MAC/build/test.log"

if [ ! -d "$MAC/Tests/Fixtures" ] || [ -z "$(ls -A "$MAC/Tests/Fixtures" 2>/dev/null)" ]; then
  echo "Fixtures missing; run Mac/scripts/make-fixtures.sh" >&2
  exit 2
fi

echo "== xcodegen"
perl -e 'alarm 120; exec @ARGV' xcodegen generate -s "$MAC/project.yml" -q

echo "== xcodebuild test -> $LOG"
set +e
xcodebuild -project "$MAC/7-Zip.xcodeproj" -scheme SevenZipKitTests -configuration Debug \
  -derivedDataPath "$MAC/build/DerivedData" -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES test >"$LOG" 2>&1
RC=$?
set -e
grep -E "Test Case .* (passed|failed)|Executed [0-9]+ tests|error:|\*\* TEST" "$LOG" | grep -v CoreSimulator | tail -60 || true
if [ $RC -ne 0 ]; then
  echo "TESTS FAILED (rc=$RC); full log: $LOG"
  exit $RC
fi
echo "OK: tests passed"
