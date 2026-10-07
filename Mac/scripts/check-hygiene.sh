#!/usr/bin/env bash
# check-hygiene.sh -- repository hygiene checks that CI runs on every push and pull request (pub4).
# They need no build and take a few seconds. Works from any directory.
#
# Usage: Mac/scripts/check-hygiene.sh [--build-log <FILE>]...
#   --build-log <FILE>   also fail if that xcodebuild log has a warning in the port's own code
#                        (Mac/...: warning:). Warnings are errors there already, so this only
#                        catches a target whose *_TREAT_WARNINGS_AS_ERRORS was lost. Repeatable.
#   -h, --help           this text
#
# Checks:
#   1. no tracked file under a screenshots/ directory (tests write to Mac/build/screenshots/)
#   2. no personal absolute path: /Users/<name> other than the placeholders the tests and docs use
#      (Shared, me, someone, x, you, runner), outside upstream's sources
#   3. warnings-as-errors: every target in Mac/project.yml that compiles the port's Swift code
#      sets SWIFT_TREAT_WARNINGS_AS_ERRORS: YES, SevenZipKit sets GCC_TREAT_WARNINGS_AS_ERRORS: YES
#   4. Mac/VERSION is complete, and UPSTREAM_VERSION equals MY_VERSION in C/7zVersion.h
#   5. CHANGELOG.md has a section for PORT_VERSION
# Relative Markdown links and the generated icons have their own scripts (check-links.sh,
# make-icons.sh); CI runs those next to this one.
# Exit: 0 clean, 1 a check failed, 2 bad usage.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
LOGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --build-log) LOGS+=("${2:?--build-log needs a file}"); shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "check-hygiene.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

FAIL=0
bad() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }
ok()  { echo "ok:   $*"; }

# 1. Screenshots.
SHOTS="$(git ls-files | grep -iE '(^|/)screenshots/' || true)"
if [ -n "$SHOTS" ]; then
  bad "screenshots are committed (they belong in Mac/build/screenshots/, git-ignored):"
  printf '%s\n' "$SHOTS" | sed 's/^/        /'
else
  ok "no committed screenshots"
fi

# 2. Personal paths. Upstream's own sources are not ours to police.
# shellcheck disable=SC2016  # a literal $USER placeholder is allowed
ALLOWED='^(Shared|me|someone|x|you|runner|USER|<[^>]*>|\$USER|\$\{USER\}|…|\.\.\.)$'
PATHS="$(git grep -nIoE '/Users/[^/[:space:]"'\''`)<>,;:]+' -- . ':!C/' ':!CPP/' ':!Asm/' ':!DOC/' \
  | awk -F: -v allowed="$ALLOWED" '{ hit = $0; sub(/^[^:]*:[^:]*:/, "", hit); name = hit; sub(/^\/Users\//, "", name);
                                     if (name !~ allowed) print }' || true)"
if [ -n "$PATHS" ]; then
  bad "personal absolute paths (use a placeholder such as /Users/me):"
  printf '%s\n' "$PATHS" | sed 's/^/        /'
else
  ok "no personal /Users paths"
fi

# 3. Warnings as errors. Each target block in project.yml is the text between two lines that are
# indented by exactly two spaces under `targets:`.
WAE="$(awk '
  /^targets:/ { in_t = 1; next }
  /^[^ ]/     { in_t = 0 }
  in_t && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { t = $1; sub(/:$/, "", t); next }
  in_t && /SWIFT_TREAT_WARNINGS_AS_ERRORS:[[:space:]]*YES/ { print t ":swift" }
  in_t && /GCC_TREAT_WARNINGS_AS_ERRORS:[[:space:]]*YES/   { print t ":gcc" }
' Mac/project.yml)"
WAE_FAIL=$FAIL
for need in 7-Zip:swift FinderSync:swift QuickActionExtract:swift QuickActionCompress:swift \
            SevenZipKitTests:swift SevenZipAppTests:swift SevenZipKit:gcc; do
  printf '%s\n' "$WAE" | grep -qx "$need" || bad "Mac/project.yml: target ${need%%:*} lost ${need##*:} warnings-as-errors"
done
for log in ${LOGS[@]+"${LOGS[@]}"}; do
  [ -f "$log" ] || { bad "no build log $log"; continue; }
  W="$(grep -E '(^|/)Mac/[^ ]*:[0-9]+:[0-9]+: warning:' "$log" | sort -u || true)"
  if [ -n "$W" ]; then bad "warnings in Mac/ code in $log:"; printf '%s\n' "$W" | sed 's/^/        /'
  else ok "no Mac/ warnings in $(basename "$log")"; fi
done
[ "$FAIL" = "$WAE_FAIL" ] && ok "warnings are errors in every port target"

# 4. Version.
# shellcheck source=version.sh
. Mac/scripts/version.sh
MY_VERSION="$(sed -n 's/^#define MY_VERSION_NUMBERS "\([^"]*\)".*/\1/p' C/7zVersion.h | head -1)"
if [ -z "$PORT_VERSION" ] || [ -z "$UPSTREAM_VERSION" ]; then
  bad "Mac/VERSION lacks PORT_VERSION or UPSTREAM_VERSION"
elif ! printf '%s' "$PORT_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  bad "PORT_VERSION '$PORT_VERSION' is not X.Y.Z"
elif [ "$UPSTREAM_VERSION" != "$MY_VERSION" ]; then
  bad "UPSTREAM_VERSION $UPSTREAM_VERSION != MY_VERSION_NUMBERS $MY_VERSION in C/7zVersion.h"
else
  ok "version $VERSION_NAME"
fi

# 5. Changelog.
if grep -qF "## [$PORT_VERSION]" CHANGELOG.md; then
  ok "CHANGELOG.md has a [$PORT_VERSION] section"
else
  bad "CHANGELOG.md has no '## [$PORT_VERSION]' section (Mac/scripts/bump-version.sh adds one)"
fi

[ "$FAIL" = 0 ] || { echo "$FAIL hygiene check(s) failed"; exit 1; }
echo "OK: repository hygiene"
