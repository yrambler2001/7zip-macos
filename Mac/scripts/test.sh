#!/usr/bin/env bash
# test.sh -- run the XCTest suites with xcodebuild. Works from any directory.
#
# Usage: Mac/scripts/test.sh [options]
#   (no options)           the SevenZipKit unit tests, as before
#   -u, --ui               the XCUITest shards (input + probe1 + probe2)
#   -H, --host             the app-hosted unit tests (SevenZipAppTests)
#   -a, --all              every test target, one after another
#   -s, --shards           the fast plan: build once with build-for-testing, then run the
#                          read-only targets (unit, app-hosted, probe1, probe2) **concurrently**
#                          and the input shard alone, and merge the results
#   -j, --jobs <N>         how many read-only targets to run at once with --shards (default 4)
#   -t, --target <NAME>    one target: SevenZipKitTests | SevenZipAppTests | 7-ZipUITests |
#                          7-ZipUITestsProbe1 | 7-ZipUITestsProbe2
#   -o, --only <TEST>      one class or case: SmokeTests, SmokeTests/testMenuBarStructure
#                          (the target that declares the class is looked up in Mac/Tests when
#                          --target is not given; an unknown class or test function exits 2, and a
#                          run that executes no test at all exits 4 instead of reading as a pass)
#   -c, --config <CFG>     Debug (default) or Release
#   -k, --keep-prefs       do not clear com.yrambler2001.7zip before an input-shard run
#   -h, --help             this text
#
# Sharding (Mac/docs/api/harness.md). Every XCUITest target is built against an app target with its
# own bundle identifier, so several instances coexist: the **input** shard drives the real app and
# needs the machine to itself (macOS delivers a synthesized click or key to the frontmost
# application), while the **probe** shards and the app-hosted tests only read, and run at the same
# time. Only the input shard therefore takes the repository app-launch lock, and only it touches the
# real preferences domain -- everything else has a settings plist and an SZ_STATE_DIR of its own.
#
# The app-launch lock (<worktrees>/.app-lock, override with SEVENZIP_APP_LOCK) is held while the
# input shard runs: it waits up to 15 minutes, breaks a lock older than 30 minutes, and releases it
# on any exit. The app saves its own settings when it quits, so com.yrambler2001.7zip is exported to
# Mac/build/prefs-backup.plist, cleared (Lang forced to English) and imported back afterwards.
# Screenshot attachments are exported from the result bundles into Mac/docs/reports/screenshots/.
# A test that hangs is failed by XCTest rather than stalling the run (-test-timeouts-enabled).
# Env: DEVELOPER_DIR (default /Applications/Xcode.app), XCODEBUILD_EXTRA.
# Logs: Mac/build/test-<target>.log. Exit: 0 when everything passed, else xcodebuild's code.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC="$ROOT/Mac"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

UNIT_TARGET="SevenZipKitTests"
HOST_TARGET="SevenZipAppTests"
UI_TARGET="7-ZipUITests"
PROBE_TARGETS="7-ZipUITestsProbe1 7-ZipUITestsProbe2"
UI_TARGETS="$UI_TARGET $PROBE_TARGETS"
ALL_SCHEME="7-Zip-AllTests"
APP_DOMAIN="com.yrambler2001.7zip"
CONFIG="Debug"
ONLY=""
TARGETS=""
KEEP_PREFS=0
SHARDED=0
JOBS=4
# A test that hangs must fail fast instead of stalling the whole run; the per-class allowance is
# `SevenZipUITestCase.timeAllowance` and this is the default for anything that does not set one.
TIMEOUT_ARGS=(-test-timeouts-enabled YES
              -default-test-execution-time-allowance 300
              -maximum-test-execution-time-allowance 900)

while [ $# -gt 0 ]; do
  case "$1" in
    -u|--ui) TARGETS="$UI_TARGETS" ;;
    -H|--host) TARGETS="$HOST_TARGET" ;;
    -a|--all) TARGETS="$UNIT_TARGET $HOST_TARGET $UI_TARGETS" ;;
    -s|--shards) SHARDED=1 ;;
    -j|--jobs) JOBS="${2:?--jobs needs a value}"; shift ;;
    -t|--target) TARGETS="${2:?--target needs a value}"; shift ;;
    -o|--only) ONLY="${2:?--only needs a value}"; shift ;;
    -c|--config) CONFIG="${2:?--config needs a value}"; shift ;;
    -k|--keep-prefs) KEEP_PREFS=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "test.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# --only <Class>[/<test>] without --target: find which test target declares that class, instead of
# guessing from the name. Guessing sent every UI class but *Smoke*/*UI* to the unit target, where
# -only-testing matched nothing, xcodebuild still exited 0 and the run read as a pass.
declare_target_of_class() {
  local cls="$1" dir target dir_target
  for dir_target in "Tests/UITests:$UI_TARGET" \
                    "Tests/UIProbe1:7-ZipUITestsProbe1" \
                    "Tests/UIProbe2:7-ZipUITestsProbe2" \
                    "Tests/AppTests:$HOST_TARGET" \
                    "Tests/SevenZipKitTests:$UNIT_TARGET"; do
    dir="$MAC/${dir_target%%:*}"
    target="${dir_target##*:}"
    [ -d "$dir" ] || continue
    if grep -rqE "class[[:space:]]+${cls}[[:space:]]*(:|\{)" "$dir" 2>/dev/null; then
      echo "$target"
      return 0
    fi
  done
  return 1
}

if [ -z "$TARGETS" ]; then
  if [ -z "$ONLY" ]; then
    if [ "$SHARDED" = 1 ]; then
      TARGETS="$UNIT_TARGET $HOST_TARGET $UI_TARGETS"
    else
      TARGETS="$UNIT_TARGET"
    fi
  else
    ONLY_CLASS="${ONLY%%/*}"
    if ! TARGETS="$(declare_target_of_class "$ONLY_CLASS")"; then
      echo "test.sh: --only '$ONLY' names no test class under Mac/Tests; nothing would run." >&2
      echo "         Check the spelling, or pass --target explicitly." >&2
      exit 2
    fi
  fi
fi

# A --only filter that names a class in a target must also name an existing test case there.
if [ -n "$ONLY" ]; then
  case "$ONLY" in
    */*)
      ONLY_CASE="${ONLY##*/}"
      if ! grep -rqE "func[[:space:]]+${ONLY_CASE}[[:space:]]*\(" "$MAC/Tests" 2>/dev/null; then
        echo "test.sh: --only '$ONLY' names no test function; nothing would run." >&2
        exit 2
      fi
      ;;
  esac
fi

mkdir -p "$MAC/build"
if [ ! -d "$MAC/Tests/Fixtures" ] || [ -z "$(ls -A "$MAC/Tests/Fixtures" 2>/dev/null)" ]; then
  echo "Fixtures missing; run Mac/scripts/make-fixtures.sh" >&2
  exit 2
fi

# The app-hosted tests run inside a real 7-Zip process, so they need a settings domain of their own
# for exactly the reason every UI test does: the app reads and writes it. One plist, English strings.
HOST_DEFAULTS="$MAC/build/hostapp-defaults.plist"
cat >"$HOST_DEFAULTS" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Lang</key>
	<string>-</string>
	<key>FM.Panels.numPanels</key>
	<integer>1</integer>
</dict>
</plist>
PLIST

# --- shared app-launch lock + preferences safety net (the input shard owns the app) ------------
# Only the input shard drives the shipping bundle id, so only it has to queue behind another agent:
# Mac/docs/api/harness.md "App-launch lock".
APP_LOCK="${SEVENZIP_APP_LOCK:-$(
  if [ -d "$ROOT/.worktrees" ]; then echo "$ROOT/.worktrees/.app-lock"
  elif [ "$(basename "$(dirname "$ROOT")")" = ".worktrees" ]; then echo "$(dirname "$ROOT")/.app-lock"
  else echo "${TMPDIR:-/tmp}/7zip-app-lock"; fi)}"
APP_LOCK_HELD=0
LOCK_SCOPE="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
PREFS_BACKUP="$MAC/build/prefs-backup.plist"
PREFS_SAVED=0

lock_owner() { cat "$APP_LOCK/owner" 2>/dev/null || echo "unknown"; }

acquire_app_lock() {
  if [ -n "${SEVENZIP_APP_LOCK_HELD:-}" ]; then return 0; fi     # already held by verify.sh
  local i age
  for i in $(seq 1 180); do                                      # 180 * 5s = 15 min
    if mkdir "$APP_LOCK" 2>/dev/null; then
      echo "$LOCK_SCOPE (pid $$, $(date '+%Y-%m-%d %H:%M:%S'))" >"$APP_LOCK/owner"
      APP_LOCK_HELD=1
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
  echo "test.sh: app lock $APP_LOCK still held after 15 min (owner: $(lock_owner))." >&2
  echo "         Wait for that run, or remove the directory if it is stale." >&2
  return 3
}

release_app_lock() {
  if [ "$APP_LOCK_HELD" = 1 ]; then
    APP_LOCK_HELD=0
    rm -rf "$APP_LOCK"
    echo "== app lock released"
  fi
}

save_prefs() {
  [ "$KEEP_PREFS" = 0 ] || return 0
  [ "$PREFS_SAVED" = 0 ] || return 0
  local other
  other="$(pgrep -f '7-Zip\.app/Contents/MacOS/7-Zip' | head -1 || true)"
  if [ -n "$other" ]; then
    echo "== warning: 7-Zip is already running (pid $other) although the lock is held;"
    echo "            the UI tests will terminate it and $APP_DOMAIN is left untouched"
    return 0
  fi
  defaults export "$APP_DOMAIN" "$PREFS_BACKUP" 2>/dev/null && PREFS_SAVED=1 || true
  defaults delete "$APP_DOMAIN" >/dev/null 2>&1 || true
  defaults write "$APP_DOMAIN" Lang -string -      # English resource strings for the assertions
  echo "== preferences of $APP_DOMAIN backed up to $PREFS_BACKUP and cleared"
}

restore_prefs() {
  [ "$PREFS_SAVED" = 1 ] || return 0
  PREFS_SAVED=0
  defaults import "$APP_DOMAIN" "$PREFS_BACKUP" 2>/dev/null || true
  echo "== preferences of $APP_DOMAIN restored from $PREFS_BACKUP"
}

# macOS registers an app bundle with Launch Services the moment it is launched, so running the
# app-hosted target or a probe shard registers that copy. The copies claim no URL scheme, no document
# type and no Service any more (Mac/Tests/AppVariants/Info.plist), so a registration is harmless --
# but it still puts a "7-Zip-Probe1" in Finder's Open With list, so they are unregistered on the way
# out. Before that plist change, a registered probe *did* own the sevenzip:// scheme and answered
# another scope's unaimed NSWorkspace.open, failing eleven of their tests.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

unregister_test_apps() {
  local products="$MAC/build/DerivedData/Build/Products/$CONFIG" app
  [ -x "$LSREGISTER" ] || return 0
  for app in 7-Zip-Host.app 7-Zip-Probe1.app 7-Zip-Probe2.app; do
    [ -d "$products/$app" ] || continue
    "$LSREGISTER" -u "$products/$app" >/dev/null 2>&1 || true
  done
}

cleanup() { restore_prefs; release_app_lock; unregister_test_apps; }
trap cleanup EXIT INT TERM

needs_input_shard() { printf '%s\n' $TARGETS | grep -qx "$UI_TARGET"; }

echo "== xcodegen"
# macOS has no timeout(1); XcodeGen can hang on bad source paths (04-toolchain.md 5.4).
perl -e 'alarm 120; exec @ARGV' xcodegen generate -s "$MAC/project.yml" -q

SUMMARY=""
FAILED=0          # xcodebuild's exit code of the first failing target (contract: propagated)
TOTAL_PASS=0
TOTAL_FAIL=0

# Copy the screenshot attachments of a result bundle into Mac/docs/reports/screenshots.
export_screenshots() {
  # Declared one at a time: `local a=$1 b=$(f "$a")` is evaluated with `a` still unset under
  # `set -u` in bash 3.2, which is what "line 240: bundle: unbound variable" was.
  local bundle="$1"
  local n=0
  local tmp
  tmp="$MAC/build/attachments-$(basename "$bundle" .xcresult)"
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
  echo "   $n screenshot(s) from $(basename "$bundle") -> $MAC/docs/reports/screenshots"
}

# The build settings every test run needs. `TEST_RUNNER_<NAME>` reaches the process that hosts the
# tests -- the XCTRunner for a UI shard, the app itself for the app-hosted target -- as `<NAME>`, and
# `build-for-testing` bakes them into the .xctestrun, so the shards inherit them without a rebuild.
COMMON_SETTINGS=(
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
  "TEST_RUNNER_SEVENZIP_REPO_ROOT=$ROOT"
  "TEST_RUNNER_SEVENZIP_SCREENSHOT_DIR=$MAC/docs/reports/screenshots"
  "TEST_RUNNER_SEVENZIP_DEFAULTS_SUITE=$HOST_DEFAULTS"
)

# Count the outcome of one log and fold it into the totals.
tally() {
  local target="$1" log="$2" rc="$3" elapsed="$4" passed failed skipped
  passed=$(grep -c "Test Case .* passed" "$log" || true)
  failed=$(grep -c "Test Case .* failed" "$log" || true)
  skipped=$(grep -c "Test Case .* skipped" "$log" || true)
  TOTAL_PASS=$((TOTAL_PASS + passed))
  TOTAL_FAIL=$((TOTAL_FAIL + failed))
  # A run that executed nothing is never a pass: an -only-testing filter that matches no test in
  # this target makes xcodebuild succeed with an empty run, which used to read as green.
  if [ "$rc" -eq 0 ] && [ "$((passed + failed + skipped))" -eq 0 ]; then
    rc=4
    echo "test.sh: $target executed no test at all${ONLY:+ (--only '$ONLY')}; treating that as a failure." >&2
  fi
  if [ "$rc" -ne 0 ]; then
    if [ "$FAILED" -eq 0 ]; then FAILED=$rc; fi
    SUMMARY="$SUMMARY
  FAIL  $target: $passed passed, $failed failed, ${elapsed}s (rc=$rc, log: $log)"
    echo "TESTS FAILED in $target (rc=$rc); full log: $log"
    grep -E "error:|XCTAssert|failed -" "$log" | grep -v CoreSimulator | head -10 || true
  else
    SUMMARY="$SUMMARY
  ok    $target: $passed passed, ${elapsed}s"
  fi
}

# XCUITest's automation mode is intermittent on some machines (requests.md, uiverify ->
# orchestrator): a run can die before its first test with "Timed out while enabling automation
# mode" and pass unchanged minutes later. Returns 0 (= retry) only for that failure, only when no
# test case started, and only after the first attempt; it waits 15 s first.
automation_mode_flake() {
  local rc="$1" log="$2" attempt="$3"
  [ "$rc" -ne 0 ] && [ "$attempt" -eq 1 ] || return 1
  grep -q "Timed out while enabling automation mode" "$log" || return 1
  grep -q "Test Case '.*' started" "$log" && return 1
  echo "   automation mode timed out before any test ran; retrying once in 15 s ($log)"
  sleep 15
  return 0
}

# --- the classic path: one xcodebuild per target, built as it goes ------------------------------
run_target() {
  local target="$1" log="$MAC/build/test-$1.log" rc=0 started elapsed
  local bundle="$MAC/build/results-$1.xcresult"
  local only_args=()
  if [ -n "$ONLY" ]; then only_args=(-only-testing:"$target/$ONLY"); fi
  echo "== xcodebuild test $target ($CONFIG) -> $log"
  rm -rf "$bundle"
  started=$(date +%s)
  set +e
  # shellcheck disable=SC2046
  local attempt
  for attempt in 1 2; do
    xcodebuild -project "$MAC/7-Zip.xcodeproj" -scheme "$target" -configuration "$CONFIG" \
      -derivedDataPath "$MAC/build/DerivedData" -destination 'platform=macOS,arch=arm64' \
      -resultBundlePath "$bundle" "${TIMEOUT_ARGS[@]}" "${COMMON_SETTINGS[@]}" \
      ${only_args[@]+"${only_args[@]}"} ${XCODEBUILD_EXTRA:-} test >"$log" 2>&1
    rc=$?
    automation_mode_flake "$rc" "$log" "$attempt" || break
    rm -rf "$bundle"
  done
  set -e
  elapsed=$(( $(date +%s) - started ))
  grep -E "Test Case .* (passed|failed)|Executed [0-9]+ tests|error:|\*\* TEST" "$log" \
    | grep -v CoreSimulator | tail -60 || true
  export_screenshots "$bundle"
  tally "$target" "$log" "$rc" "$elapsed"
}

# --- the sharded path: build once, run the shards from the .xctestrun ---------------------------
XCTESTRUN=""

build_for_testing() {
  local log="$MAC/build/build-for-testing.log" rc=0
  echo "== xcodebuild build-for-testing $ALL_SCHEME ($CONFIG) -> $log"
  set +e
  # shellcheck disable=SC2046
  xcodebuild -project "$MAC/7-Zip.xcodeproj" -scheme "$ALL_SCHEME" -configuration "$CONFIG" \
    -derivedDataPath "$MAC/build/DerivedData" -destination 'platform=macOS,arch=arm64' \
    "${COMMON_SETTINGS[@]}" ${XCODEBUILD_EXTRA:-} build-for-testing >"$log" 2>&1
  rc=$?
  set -e
  if [ $rc -ne 0 ]; then
    echo "BUILD-FOR-TESTING FAILED (rc=$rc); log: $log" >&2
    grep -E ": error:|\*\* BUILD" "$log" | head -10 >&2 || true
    return $rc
  fi
  XCTESTRUN="$(ls -t "$MAC/build/DerivedData/Build/Products"/*.xctestrun 2>/dev/null | head -1)"
  if [ -z "$XCTESTRUN" ]; then
    echo "test.sh: build-for-testing produced no .xctestrun" >&2
    return 1
  fi
  echo "   test plan: $XCTESTRUN"
}

# Run one target from the prebuilt plan. No build, no project read: safe to run several at once.
run_shard() {
  local target="$1" log="$MAC/build/test-$1.log" rc=0 started elapsed
  local bundle="$MAC/build/results-$1.xcresult"
  local only_args=(-only-testing:"$target")
  if [ -n "$ONLY" ]; then only_args=(-only-testing:"$target/$ONLY"); fi
  rm -rf "$bundle"
  started=$(date +%s)
  set +e
  local attempt
  for attempt in 1 2; do
    xcodebuild test-without-building -xctestrun "$XCTESTRUN" \
      -destination 'platform=macOS,arch=arm64' -resultBundlePath "$bundle" \
      "${TIMEOUT_ARGS[@]}" "${only_args[@]}" >"$log" 2>&1
    rc=$?
    automation_mode_flake "$rc" "$log" "$attempt" || break
    rm -rf "$bundle"
  done
  set -e
  elapsed=$(( $(date +%s) - started ))
  echo "$rc $elapsed" >"$MAC/build/shard-$target.rc"
  return 0
}

sharded_run() {
  build_for_testing || return $?
  local concurrent=() target pids=() started
  for target in $TARGETS; do
    [ "$target" = "$UI_TARGET" ] && continue
    concurrent+=("$target")
  done

  if [ "${#concurrent[@]}" -gt 0 ]; then
    echo "== running ${#concurrent[@]} read-only target(s) concurrently: ${concurrent[*]}"
    started=$(date +%s)
    # Batched rather than `wait -n`, which needs bash 4.3 and macOS ships 3.2.
    local batch=0
    for target in "${concurrent[@]}"; do
      run_shard "$target" &
      pids+=($!)
      batch=$((batch + 1))
      if [ "$batch" -ge "$JOBS" ]; then wait; batch=0; fi
    done
    wait
    echo "   concurrent group: $(( $(date +%s) - started ))s wall clock"
    for target in "${concurrent[@]}"; do
      read -r rc elapsed <"$MAC/build/shard-$target.rc"
      grep -E "Executed [0-9]+ tests|\*\* TEST" "$MAC/build/test-$target.log" | tail -3 || true
      export_screenshots "$MAC/build/results-$target.xcresult"
      tally "$target" "$MAC/build/test-$target.log" "$rc" "$elapsed"
    done
  fi

  if needs_input_shard; then
    echo "== running the input shard alone (it synthesizes keyboard and mouse events)"
    acquire_app_lock || return 3
    save_prefs
    run_shard "$UI_TARGET"
    read -r rc elapsed <"$MAC/build/shard-$UI_TARGET.rc"
    grep -E "Test Case .* (passed|failed)|Executed [0-9]+ tests|\*\* TEST" \
      "$MAC/build/test-$UI_TARGET.log" | grep -v CoreSimulator | tail -40 || true
    export_screenshots "$MAC/build/results-$UI_TARGET.xcresult"
    tally "$UI_TARGET" "$MAC/build/test-$UI_TARGET.log" "$rc" "$elapsed"
    restore_prefs
    release_app_lock
  fi
}

RUN_STARTED=$(date +%s)
if [ "$SHARDED" = 1 ]; then
  sharded_run || FAILED=$?
else
  if needs_input_shard; then
    acquire_app_lock || exit 3
    save_prefs
  fi
  for t in $TARGETS; do run_target "$t"; done
fi
RUN_ELAPSED=$(( $(date +%s) - RUN_STARTED ))

# A failing test case with a zero exit code means the log and xcodebuild disagree: treat as failure.
if [ "$TOTAL_FAIL" -ne 0 ] && [ "$FAILED" -eq 0 ]; then FAILED=1; fi

echo "== summary$SUMMARY"
echo "   total: $TOTAL_PASS passed, $TOTAL_FAIL failed, ${RUN_ELAPSED}s wall clock"
if [ "$FAILED" -ne 0 ]; then
  exit "$FAILED"
fi
echo "OK: tests passed"
