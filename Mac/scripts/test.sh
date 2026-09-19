#!/usr/bin/env bash
# test.sh -- run the XCTest suites with xcodebuild. Works from any directory.
#
# Usage: Mac/scripts/test.sh [options]
#   (no options)           the SevenZipKit unit tests, as before
#   -u, --ui               the 7-ZipUITests XCUITest suite instead
#   -a, --all              unit tests and UI tests
#   -t, --target <NAME>    one target: SevenZipKitTests | 7-ZipUITests
#   -o, --only <TEST>      one class or case: SmokeTests, SmokeTests/testMenuBarStructure
#                          (implies the target that owns it when --target is not given)
#   -c, --config <CFG>     Debug (default) or Release
#   -k, --keep-prefs       do not clear com.yrambler2001.7zip before a UI run
#   -h, --help             this text
#
# UI runs: the app saves its own settings when it quits, so the preferences domain
# com.yrambler2001.7zip is exported to Mac/build/prefs-backup.plist, cleared (Lang forced to
# English), and imported back when the run ends -- the developer's settings survive. Screenshot
# attachments are exported from the result bundle into Mac/docs/reports/screenshots/.
# Env: DEVELOPER_DIR (default /Applications/Xcode.app), XCODEBUILD_EXTRA.
# Logs: Mac/build/test-<target>.log. Exit: 0 when everything passed, else xcodebuild's code.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC="$ROOT/Mac"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

UNIT_TARGET="SevenZipKitTests"
UI_TARGET="7-ZipUITests"
APP_DOMAIN="com.yrambler2001.7zip"
CONFIG="Debug"
ONLY=""
TARGETS=""
KEEP_PREFS=0
while [ $# -gt 0 ]; do
  case "$1" in
    -u|--ui) TARGETS="$UI_TARGET" ;;
    -a|--all) TARGETS="$UNIT_TARGET $UI_TARGET" ;;
    -t|--target) TARGETS="${2:?--target needs a value}"; shift ;;
    -o|--only) ONLY="${2:?--only needs a value}"; shift ;;
    -c|--config) CONFIG="${2:?--config needs a value}"; shift ;;
    -k|--keep-prefs) KEEP_PREFS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "test.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
# --only <UITest class> without --target picks the UI target
if [ -z "$TARGETS" ]; then
  case "$ONLY" in
    ""|SevenZipKitTests*) TARGETS="$UNIT_TARGET" ;;
    *Smoke*|*UI*) TARGETS="$UI_TARGET" ;;
    *) TARGETS="$UNIT_TARGET" ;;
  esac
fi

mkdir -p "$MAC/build"
if [ ! -d "$MAC/Tests/Fixtures" ] || [ -z "$(ls -A "$MAC/Tests/Fixtures" 2>/dev/null)" ]; then
  echo "Fixtures missing; run Mac/scripts/make-fixtures.sh" >&2
  exit 2
fi

# --- preferences safety net (UI runs launch the real app, which saves its state) -------------
PREFS_BACKUP="$MAC/build/prefs-backup.plist"
PREFS_SAVED=0
restore_prefs() {
  [ "$PREFS_SAVED" = 1 ] || return 0
  defaults import "$APP_DOMAIN" "$PREFS_BACKUP" 2>/dev/null || true
  echo "== preferences of $APP_DOMAIN restored from $PREFS_BACKUP"
}
if [ "$KEEP_PREFS" = 0 ] && printf '%s\n' $TARGETS | grep -q "$UI_TARGET"; then
  defaults export "$APP_DOMAIN" "$PREFS_BACKUP" 2>/dev/null && PREFS_SAVED=1 || true
  trap restore_prefs EXIT INT TERM
  defaults delete "$APP_DOMAIN" >/dev/null 2>&1 || true
  defaults write "$APP_DOMAIN" Lang -string -        # English resource strings for the assertions
  echo "== preferences of $APP_DOMAIN backed up to $PREFS_BACKUP and cleared"
fi

echo "== xcodegen"
# macOS has no timeout(1); XcodeGen can hang on bad source paths (04-toolchain.md 5.4).
perl -e 'alarm 120; exec @ARGV' xcodegen generate -s "$MAC/project.yml" -q

SUMMARY=""
FAILED=0          # xcodebuild's exit code of the first failing target (contract: propagated)
TOTAL_PASS=0
TOTAL_FAIL=0

# Copy the screenshot attachments of a result bundle into Mac/docs/reports/screenshots.
export_screenshots() {
  local bundle="$1" tmp="$MAC/build/attachments" n=0
  [ -d "$bundle" ] || return 0
  rm -rf "$tmp"; mkdir -p "$tmp" "$MAC/docs/reports/screenshots"
  xcrun xcresulttool export attachments --path "$bundle" --output-path "$tmp" >/dev/null 2>&1 || return 0
  [ -f "$tmp/manifest.json" ] || return 0
  # manifest.json: [{ attachments: [{ exportedFileName, suggestedHumanReadableName }] }]
  # suggestedHumanReadableName is "<attachment name>_<n>_<UUID>.png"; keep the attachment name.
  n=$(python3 - "$tmp" "$MAC/docs/reports/screenshots" <<'PY'
import json, os, re, shutil, sys
src, dst = sys.argv[1], sys.argv[2]
count = 0
with open(os.path.join(src, "manifest.json")) as fh:
    for test in json.load(fh):
        for att in test.get("attachments", []):
            exported = att.get("exportedFileName")
            name = att.get("suggestedHumanReadableName") or exported or ""
            if not exported or not os.path.exists(os.path.join(src, exported)):
                continue
            name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(\.\w+)$", r"\1", name)
            if not name.lower().endswith(".png"):
                continue
            shutil.copyfile(os.path.join(src, exported), os.path.join(dst, name))
            count += 1
print(count)
PY
)
  echo "   $n screenshot(s) -> $MAC/docs/reports/screenshots"
}

run_target() {
  local target="$1" log="$MAC/build/test-$1.log" rc=0 started elapsed passed failed
  local bundle="$MAC/build/results-$1.xcresult"
  local only_args=()
  if [ -n "$ONLY" ]; then only_args=(-only-testing:"$target/$ONLY"); fi
  echo "== xcodebuild test $target ($CONFIG) -> $log"
  rm -rf "$bundle"
  started=$(date +%s)
  set +e
  xcodebuild -project "$MAC/7-Zip.xcodeproj" -scheme "$target" -configuration "$CONFIG" \
    -derivedDataPath "$MAC/build/DerivedData" -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$bundle" \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES \
    TEST_RUNNER_SEVENZIP_REPO_ROOT="$ROOT" \
    TEST_RUNNER_SEVENZIP_SCREENSHOT_DIR="$MAC/docs/reports/screenshots" \
    ${only_args[@]+"${only_args[@]}"} ${XCODEBUILD_EXTRA:-} test >"$log" 2>&1
  rc=$?
  set -e
  elapsed=$(( $(date +%s) - started ))
  grep -E "Test Case .* (passed|failed)|Executed [0-9]+ tests|error:|\*\* TEST" "$log" \
    | grep -v CoreSimulator | tail -60 || true
  passed=$(grep -c "Test Case .* passed" "$log" || true)
  failed=$(grep -c "Test Case .* failed" "$log" || true)
  TOTAL_PASS=$((TOTAL_PASS + passed))
  TOTAL_FAIL=$((TOTAL_FAIL + failed))
  if [ "$target" = "$UI_TARGET" ]; then export_screenshots "$bundle"; fi
  if [ "$rc" -ne 0 ]; then
    if [ "$FAILED" -eq 0 ]; then FAILED=$rc; fi
    SUMMARY="$SUMMARY
  FAIL  $target: $passed passed, $failed failed, ${elapsed}s (rc=$rc, log: $log)"
    echo "TESTS FAILED (rc=$rc); full log: $log"
    grep -E "error:|XCTAssert|failed -" "$log" | grep -v CoreSimulator | head -10 || true
  else
    SUMMARY="$SUMMARY
  ok    $target: $passed passed, ${elapsed}s"
  fi
}

for t in $TARGETS; do run_target "$t"; done

echo "== summary$SUMMARY"
echo "   total: $TOTAL_PASS passed, $TOTAL_FAIL failed"
if [ "$FAILED" -ne 0 ]; then
  exit "$FAILED"
fi
echo "OK: tests passed"
