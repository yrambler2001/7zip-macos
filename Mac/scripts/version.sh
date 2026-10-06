#!/usr/bin/env bash
# version.sh -- the port's version, read from Mac/VERSION (pub3). Source it or run it.
#
# Usage: Mac/scripts/version.sh [port|upstream|build|name|dmg|xcconfig]
#   port       1.0.0                         (PORT_VERSION)
#   upstream   26.03                         (UPSTREAM_VERSION)
#   build      the build number: $BUILD_NUMBER, else the commit count of HEAD, else 1
#   name       7-Zip 26.03 for macOS 1.0.0   (the user-visible name, the DMG volume name)
#   dmg        7-Zip-26.03-macOS-1.0.0.dmg   (the disk image's file name)
#   xcconfig   write Mac/build/BuildNumber.xcconfig (CURRENT_PROJECT_VERSION = <build>)
#   (none)     all of the above as KEY=value lines
#
# When sourced it defines PORT_VERSION, UPSTREAM_VERSION, BUILD_NUMBER, VERSION_NAME, DMG_NAME and
# the function write_build_number_xcconfig.

_sz_version_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
_sz_version_read() {
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p" "$_sz_version_root/Mac/VERSION" | head -1
}
PORT_VERSION="$(_sz_version_read PORT_VERSION)"
UPSTREAM_VERSION="$(_sz_version_read UPSTREAM_VERSION)"
if [ -z "${BUILD_NUMBER:-}" ]; then
  BUILD_NUMBER="$(git -C "$_sz_version_root" rev-list --count HEAD 2>/dev/null || echo 1)"
fi
VERSION_NAME="7-Zip $UPSTREAM_VERSION for macOS $PORT_VERSION"
DMG_NAME="7-Zip-$UPSTREAM_VERSION-macOS-$PORT_VERSION.dmg"

# Xcode reads the build number from here (Mac/Version.xcconfig: #include? "build/BuildNumber.xcconfig").
# Rewritten only when it changes, so an unchanged number does not touch every Info.plist.
write_build_number_xcconfig() {
  local f="$_sz_version_root/Mac/build/BuildNumber.xcconfig"
  local line="CURRENT_PROJECT_VERSION = $BUILD_NUMBER"
  mkdir -p "$(dirname "$f")"
  [ -f "$f" ] && [ "$(cat "$f")" = "$line" ] && return 0
  echo "$line" >"$f"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  [ -n "$PORT_VERSION" ] && [ -n "$UPSTREAM_VERSION" ] || { echo "version.sh: Mac/VERSION is incomplete" >&2; exit 1; }
  case "${1:-}" in
    port) echo "$PORT_VERSION" ;;
    upstream) echo "$UPSTREAM_VERSION" ;;
    build) echo "$BUILD_NUMBER" ;;
    name) echo "$VERSION_NAME" ;;
    dmg) echo "$DMG_NAME" ;;
    xcconfig) write_build_number_xcconfig ;;
    "") printf 'PORT_VERSION=%s\nUPSTREAM_VERSION=%s\nBUILD_NUMBER=%s\nVERSION_NAME=%s\nDMG_NAME=%s\n' \
          "$PORT_VERSION" "$UPSTREAM_VERSION" "$BUILD_NUMBER" "$VERSION_NAME" "$DMG_NAME" ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}" ;;
    *) echo "version.sh: unknown argument '$1'" >&2; exit 2 ;;
  esac
fi
