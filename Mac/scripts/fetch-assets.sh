#!/usr/bin/env bash
# fetch-assets.sh -- fetch the redistributable 7-Zip assets that the macOS port
# does not build itself (localisation files and Windows SFX stubs).
#
#   1. downloads the official Windows installer 7z<VER>-x64.exe from 7-zip.org
#      (or uses INSTALLER=/path/to/7zNNNN-x64.exe if you already have it),
#   2. verifies its pinned SHA-256,
#   3. extracts it with the console 7zz built from this tree
#      (CPP/7zip/Bundles/Alone2/b/m_arm64/7zz; built on demand with the
#      upstream makefile if missing),
#   4. copies Lang/*.txt + Lang/en.ttt   -> Mac/Resources/Lang/
#             7z.sfx 7zCon.sfx           -> Mac/Resources/SFX/
#             License.txt readme.txt     -> Mac/Resources/SFX/  (license/provenance)
#
# Env overrides: INSTALLER, SEVENZZ, DEVELOPER_DIR (default /Applications/Xcode.app),
#                KEEP_WORK=1 (keep the temp dir), JOBS (make -j, default 8).
set -euo pipefail

VERSION_TAG="2603"                                  # 7-Zip 26.03
INSTALLER_NAME="7z${VERSION_TAG}-x64.exe"
URL="https://7-zip.org/a/${INSTALLER_NAME}"
INSTALLER_SHA256="0859c524b8a63551848f0c246abddcb1d0b7b656b0fbfe879f8d85e61a9e6edd"
SFX_SHA256="9598f3bbca8e95391b8a356aee2e4cab93d9ac26eea47159ec725a55cf3bb32f"
SFXCON_SHA256="c4402ffcbe8e02ec017f958f0d188fe13ea00193623c95dde546f6621a2e4132"
EXPECTED_LANG_TXT=92                                # + en.ttt = 93 files
LANG_SIGNATURE=';!@Lang2@!UTF-8!'

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ALONE2="$ROOT/CPP/7zip/Bundles/Alone2"
SEVENZZ="${SEVENZZ:-$ALONE2/b/m_arm64/7zz}"
LANG_DIR="$ROOT/Mac/Resources/Lang"
SFX_DIR="$ROOT/Mac/Resources/SFX"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/7zip-assets.XXXXXX")"
trap '[ "${KEEP_WORK:-0}" = 1 ] && echo "work dir kept: $WORK" || rm -rf "$WORK"' EXIT

log() { printf '[fetch-assets] %s\n' "$*"; }
die() { printf '[fetch-assets] ERROR: %s\n' "$*" >&2; exit 1; }
sha256() { shasum -a 256 "$1" | awk '{print $1}'; }

# --- 1. installer ---------------------------------------------------------
if [ -n "${INSTALLER:-}" ]; then
  [ -f "$INSTALLER" ] || die "INSTALLER=$INSTALLER does not exist"
  log "using local installer $INSTALLER"
else
  INSTALLER="$WORK/$INSTALLER_NAME"
  log "downloading $URL"
  curl -fsSL --retry 3 --retry-delay 2 -o "$INSTALLER" "$URL"
fi

# --- 2. verify -------------------------------------------------------------
actual="$(sha256 "$INSTALLER")"
[ "$actual" = "$INSTALLER_SHA256" ] || die "SHA-256 mismatch for $INSTALLER
  expected $INSTALLER_SHA256
  actual   $actual"
log "installer SHA-256 OK"

# --- 3. 7zz (build on demand) --------------------------------------------
if [ ! -x "$SEVENZZ" ]; then
  log "7zz not found at $SEVENZZ -- building with the upstream makefile"
  command -v make >/dev/null || die "make not found (install Xcode Command Line Tools)"
  ( cd "$ALONE2" && \
    DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}" \
    MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}" \
    make -j"${JOBS:-8}" -f ../../cmpl_mac_arm64.mak )
  [ -x "$SEVENZZ" ] || die "build finished but $SEVENZZ is missing"
fi
log "using $("$SEVENZZ" i | sed -n 's/^7-Zip (z) \([0-9.]*\).*/7zz \1/p')"

# --- 4. extract ------------------------------------------------------------
EXTRACT="$WORK/extracted"
"$SEVENZZ" x -y -bso0 -bsp0 -o"$EXTRACT" "$INSTALLER" >/dev/null
for f in Lang/en.ttt 7z.sfx 7zCon.sfx License.txt readme.txt; do
  [ -f "$EXTRACT/$f" ] || die "installer did not contain $f"
done
n_txt="$(find "$EXTRACT/Lang" -maxdepth 1 -name '*.txt' | wc -l | tr -d ' ')"
[ "$n_txt" = "$EXPECTED_LANG_TXT" ] || die "expected $EXPECTED_LANG_TXT Lang/*.txt, found $n_txt (update EXPECTED_LANG_TXT if 7-Zip added a language)"
[ "$(sha256 "$EXTRACT/7z.sfx")" = "$SFX_SHA256" ] || die "7z.sfx SHA-256 mismatch"
[ "$(sha256 "$EXTRACT/7zCon.sfx")" = "$SFXCON_SHA256" ] || die "7zCon.sfx SHA-256 mismatch"
# every lang file must start with the CLang signature (after an optional UTF-8 BOM)
for f in "$EXTRACT"/Lang/*.txt "$EXTRACT"/Lang/en.ttt; do
  head -c 32 "$f" | LC_ALL=C sed 's/^\xEF\xBB\xBF//' | grep -q "^${LANG_SIGNATURE}" \
    || die "$(basename "$f") lacks the '$LANG_SIGNATURE' header"
done
log "extracted and verified $((n_txt + 1)) lang files + 2 SFX stubs"

# --- 5. copy ---------------------------------------------------------------
mkdir -p "$LANG_DIR" "$SFX_DIR"
find "$LANG_DIR" -maxdepth 1 \( -name '*.txt' -o -name '*.ttt' \) -delete
cp -f "$EXTRACT"/Lang/*.txt "$EXTRACT"/Lang/en.ttt "$LANG_DIR"/
cp -f "$EXTRACT"/7z.sfx "$EXTRACT"/7zCon.sfx "$EXTRACT"/License.txt "$EXTRACT"/readme.txt "$SFX_DIR"/
chmod 644 "$LANG_DIR"/* "$SFX_DIR"/*
log "Lang: $(ls "$LANG_DIR" | wc -l | tr -d ' ') files -> $LANG_DIR"
log "SFX:  $(ls "$SFX_DIR" | wc -l | tr -d ' ') files -> $SFX_DIR"
log "done"
