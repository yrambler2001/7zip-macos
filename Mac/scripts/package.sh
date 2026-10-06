#!/usr/bin/env bash
# package.sh -- build a distributable disk image of 7-Zip.app. Works from any directory.
#
# Produces a read-only compressed (UDZO) .dmg holding the Release app, with both Finder
# extensions and the SevenZipKit framework embedded and signed, plus a symlink to /Applications
# so the user can drag one onto the other. Prints the SHA-256 of the image at the end.
#
# Usage: Mac/scripts/package.sh [options]
#   -i, --identity <NAME>   code signing identity; "-" (the default) is ad-hoc
#   -T, --team <TEAMID>     team identifier, for a Developer ID build
#   -n, --notarize          submit the image to Apple and staple the ticket (needs credentials)
#   -p, --notary-profile <N>  notarytool keychain profile (xcrun notarytool store-credentials)
#       --apple-id <EMAIL>  notarytool Apple ID; needs --team and NOTARY_PASSWORD as well
#   -o, --out <PATH>        image to write (default Mac/build/7-Zip-<version>.dmg)
#   -s, --skip-build        package the Release app already in Mac/build
#   -N, --no-verify         skip the codesign / spctl checks on the finished image
#   -q, --quiet             print only the verdict lines
#   -h, --help              this text
#
# Env (each is the fallback for the matching option):
#   SIGN_IDENTITY, DEVELOPMENT_TEAM, NOTARY_PROFILE, NOTARY_APPLE_ID, NOTARY_PASSWORD
#   DEVELOPER_DIR (default /Applications/Xcode.app)
#
# Signing, and why notarization is guarded
# ----------------------------------------
# Ad-hoc is the default because it is all a machine with no identity can do; `security
# find-identity -v -p codesigning` reports "0 valid identities found" on this one. An ad-hoc
# signature cannot be notarized -- Apple only accepts a Developer ID Application signature with
# the hardened runtime and a secure timestamp -- so --notarize without a real identity is
# refused up front, and without --notarize the notarization step is skipped silently rather
# than failing. What a user sees on first launch of each state is in README.md ("First launch: Gatekeeper").
#
# Exit: 0 success, 1 failure, 2 bad usage, 3 notarization asked for but impossible.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MAC="$ROOT/Mac"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"

IDENTITY="${SIGN_IDENTITY:--}"
TEAM="${DEVELOPMENT_TEAM:-}"
NOTARIZE=0
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_APPLE_ID="${NOTARY_APPLE_ID:-}"
OUT=""
SKIP_BUILD=0
VERIFY=1
QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    -i|--identity) IDENTITY="${2:?--identity needs a value}"; shift ;;
    -T|--team) TEAM="${2:?--team needs a value}"; shift ;;
    -n|--notarize) NOTARIZE=1 ;;
    -p|--notary-profile) NOTARY_PROFILE="${2:?--notary-profile needs a value}"; NOTARIZE=1; shift ;;
    --apple-id) NOTARY_APPLE_ID="${2:?--apple-id needs a value}"; NOTARIZE=1; shift ;;
    -o|--out) OUT="${2:?--out needs a value}"; shift ;;
    -s|--skip-build) SKIP_BUILD=1 ;;
    -N|--no-verify) VERIFY=0 ;;
    -q|--quiet) QUIET=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "package.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

say()  { [ "$QUIET" = 1 ] || echo "$@"; }
step() { [ "$QUIET" = 1 ] || echo "== $*"; }
die()  { echo "package.sh: $*" >&2; exit 1; }

CONFIG=Release
PRODUCTS="$MAC/build/DerivedData/Build/Products/$CONFIG"
APP="$PRODUCTS/7-Zip.app"

# ---------------------------------------------------------------------------
# 0. Decide the signing state before anything is built, so an impossible
#    request fails in a second rather than after a five-minute build.
# ---------------------------------------------------------------------------
ADHOC=1
[ "$IDENTITY" = "-" ] || ADHOC=0

if [ "$ADHOC" = 1 ]; then
  step "signing: ad-hoc (no Developer ID given)"
  if [ "$NOTARIZE" = 1 ]; then
    echo "package.sh: --notarize needs a Developer ID Application identity: Apple does not" >&2
    echo "            notarize an ad-hoc signature. Pass --identity/-i and --team/-T." >&2
    exit 3
  fi
else
  # The identity has to exist in a keychain, or xcodebuild fails deep inside the build.
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -Fq "$IDENTITY"; then
    echo "package.sh: no code signing identity matching '$IDENTITY' in the keychain." >&2
    echo "            security find-identity -v -p codesigning  lists what is available." >&2
    exit 1
  fi
  step "signing: $IDENTITY${TEAM:+  (team $TEAM)}"
  if [ "$NOTARIZE" = 1 ] && [ -z "$NOTARY_PROFILE" ]; then
    [ -n "$NOTARY_APPLE_ID" ] || die "--notarize needs --notary-profile, or --apple-id plus --team and NOTARY_PASSWORD"
    [ -n "$TEAM" ] || die "--apple-id also needs --team <TEAMID>"
    [ -n "${NOTARY_PASSWORD:-}" ] || die "--apple-id also needs NOTARY_PASSWORD (an app-specific password)"
  fi
fi

# ---------------------------------------------------------------------------
# 1. Release build.
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = 1 ]; then
  step "skipping the build (--skip-build)"
  [ -d "$APP" ] || die "no $APP; drop --skip-build"
else
  step "building $CONFIG"
  SIGN_IDENTITY="$IDENTITY" DEVELOPMENT_TEAM="$TEAM" \
    "$MAC/scripts/build.sh" --config "$CONFIG" --quiet \
    || die "the Release build failed; see $MAC/build/build-$CONFIG.log"
fi
[ -d "$APP" ] || die "no app bundle at $APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILDNO="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
VOLNAME="7-Zip $VERSION"
OUT="${OUT:-$MAC/build/7-Zip-$VERSION.dmg}"
mkdir -p "$(dirname "$OUT")"

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/7zip-dmg.XXXXXX")"
RW="$STAGE/rw.dmg"
MNT="$STAGE/mnt"
SRC="$STAGE/src"
STAGE_ENT="$STAGE/entitlements"
cleanup() {
  [ -d "$MNT" ] && hdiutil detach "$MNT" -quiet -force >/dev/null 2>&1 || true
  rm -rf "$STAGE"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 2. The bundle must carry both extensions and the framework, all signed. A
#    missing appex is silent at build time and only shows up as a Finder menu
#    that never appears, so it is asserted here.
# ---------------------------------------------------------------------------
step "checking the bundle"
for part in \
  "Contents/MacOS/7-Zip" \
  "Contents/Frameworks/SevenZipKit.framework" \
  "Contents/PlugIns/FinderSync.appex" \
  "Contents/PlugIns/QuickActionExtract.appex" \
  "Contents/PlugIns/QuickActionCompress.appex" \
  "Contents/Frameworks/SevenZipKit.framework/Resources/Lang/en.ttt" \
  "Contents/Frameworks/SevenZipKit.framework/Resources/Lang/de.txt" \
  "Contents/Resources/SFX/7z.sfx" \
  "Contents/Resources/SFX/7zCon.sfx" \
  "Contents/Resources/AppIcon.icns" \
  "Contents/Resources/doc-7z.icns"
do
  [ -e "$APP/$part" ] || die "the app bundle is missing $part"
done
# The official language files ride in the framework, because the reader lives there. There are
# 93: the English template en.ttt plus 92 translations, each <code>.txt.
LANGDIR="$APP/Contents/Frameworks/SevenZipKit.framework/Resources/Lang"
NLANG="$(ls "$LANGDIR" | grep -cE '\.(txt|ttt)$' || true)"
[ "$NLANG" = 93 ] || die "expected 93 language files in the framework, found $NLANG"
NICNS="$(ls "$APP/Contents/Resources" | grep -c '^doc-.*\.icns$' || true)"
[ "$NICNS" -ge 27 ] || die "expected at least 27 document icons, found $NICNS"
say "   version $VERSION ($BUILDNO), $NLANG language files, $NICNS document icons, $(du -sh "$APP" | cut -f1) on disk"

# Every nested code item has to be signed, and the outer signature has to seal them.
for part in \
  "Contents/Frameworks/SevenZipKit.framework" \
  "Contents/PlugIns/FinderSync.appex" \
  "Contents/PlugIns/QuickActionExtract.appex" \
  "Contents/PlugIns/QuickActionCompress.appex"
do
  codesign -dv "$APP/$part" >/dev/null 2>&1 || die "$part is not signed"
done
codesign --verify --deep --strict "$APP" 2>/dev/null \
  || die "codesign --verify --deep --strict failed on the app; the image would not be installable"
say "   codesign --verify --deep --strict: ok ($(codesign -dv "$APP" 2>&1 | sed -n 's/^Signature=//p'))"

# A sandboxed appex that lost its entitlement never loads, and Xcode has twice stripped it
# silently (api/finder.md section 8), so assert it. `plutil -extract` is no use here: it reads
# the dots in com.apple.security.app-sandbox as a key *path*, so it can never find the key --
# PlistBuddy takes the literal name. Entitlements are only re-signed by a build that actually
# re-links the appex, which is why package.sh always builds rather than trusting Mac/build.
ENT="$STAGE_ENT"
mkdir -p "$ENT"
for ax in FinderSync QuickActionExtract QuickActionCompress; do
  codesign -d --entitlements - --xml "$APP/Contents/PlugIns/$ax.appex" 2>/dev/null >"$ENT/$ax.plist"
  [ -s "$ENT/$ax.plist" ] || die "$ax.appex has no entitlements at all; Finder will refuse to load it"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENT/$ax.plist" 2>/dev/null)" = true ] \
    || die "$ax.appex is not sandboxed; Finder will refuse to load it (api/finder.md section 8)"
  # A distributable build must not ask to be debuggable: the notary service rejects it.
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$ENT/$ax.plist" >/dev/null 2>&1; then
    die "$ax.appex carries com.apple.security.get-task-allow; notarization would be refused (CODE_SIGN_INJECT_BASE_ENTITLEMENTS)"
  fi
done
codesign -d --entitlements - --xml "$APP/Contents/MacOS/7-Zip" 2>/dev/null >"$ENT/app.plist" || true
if [ -s "$ENT/app.plist" ] \
   && /usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$ENT/app.plist" >/dev/null 2>&1; then
  die "the app carries com.apple.security.get-task-allow; notarization would be refused (CODE_SIGN_INJECT_BASE_ENTITLEMENTS)"
fi
say "   all three app extensions are sandboxed, nothing asks for get-task-allow"

# ---------------------------------------------------------------------------
# 3. Stage the image contents.
# ---------------------------------------------------------------------------
step "staging"
mkdir -p "$SRC" "$MNT"
/usr/bin/ditto "$APP" "$SRC/7-Zip.app"          # ditto preserves the signature; cp -R does not
ln -s /Applications "$SRC/Applications"
cp "$APP/Contents/Resources/AppIcon.icns" "$SRC/.VolumeIcon.icns"
# 03 section 5 asks for License.txt, History.txt and the readme beside the app. The source
# distribution has the first two of those under DOC/ (its change log is the *source* history,
# `src-history.txt`; the binary distribution's History.txt is not in this tree), so the two that
# exist are shipped and nothing is invented.
for doc in License.txt readme.txt; do
  [ -f "$ROOT/DOC/$doc" ] && cp "$ROOT/DOC/$doc" "$SRC/$doc"
done
[ -f "$SRC/License.txt" ] || die "DOC/License.txt is missing; the image must carry the licence"

# ---------------------------------------------------------------------------
# 4. Read/write image first, so the volume can be given its custom icon, then
#    convert to a compressed read-only one. hdiutil sizes the image itself
#    with -srcfolder plus a little slack for the HFS+ metadata.
# ---------------------------------------------------------------------------
step "creating the disk image"
rm -f "$OUT"
hdiutil create -quiet -srcfolder "$SRC" -volname "$VOLNAME" -fs HFS+ \
  -format UDRW -size $(( $(du -sm "$SRC" | cut -f1) + 24 ))m "$RW" \
  || die "hdiutil create failed"
hdiutil attach "$RW" -mountpoint "$MNT" -nobrowse -quiet || die "could not mount the staging image"

# The volume name and the custom-icon bit are the two parts of the window's look that need no
# Finder automation. Icon positions, the window size and a background picture live in a
# .DS_Store that only Finder writes, which needs Automation permission this machine does not
# have -- an osascript that drives Finder here hangs on the consent dialog rather than failing
# (CLAUDE.md, ai/reports/vmcheck.md section 7). Deliberately left out; see
# ai/reports/packaging.md.
SetFile -a C "$MNT" 2>/dev/null || say "   (SetFile unavailable: no custom volume icon)"
hdiutil detach "$MNT" -quiet || die "could not unmount the staging image"
rm -rf "$MNT"

hdiutil convert "$RW" -quiet -format UDZO -imagekey zlib-level=9 -o "$OUT" \
  || die "hdiutil convert failed"
hdiutil internet-enable -no "$OUT" >/dev/null 2>&1 || true

# A Developer ID build signs the image too, so Gatekeeper can evaluate it before it is mounted.
if [ "$ADHOC" = 0 ]; then
  step "signing the image"
  codesign --force --sign "$IDENTITY" --timestamp "$OUT" || die "signing the image failed"
fi

# ---------------------------------------------------------------------------
# 5. Notarization. Skipped unless asked for, and asking for it without an
#    identity was already refused in step 0.
# ---------------------------------------------------------------------------
if [ "$NOTARIZE" = 1 ]; then
  step "notarizing (this waits for Apple, usually a few minutes)"
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait \
      || die "notarytool rejected the submission; xcrun notarytool log <id> has the detail"
  else
    xcrun notarytool submit "$OUT" --apple-id "$NOTARY_APPLE_ID" --team-id "$TEAM" \
      --password "$NOTARY_PASSWORD" --wait \
      || die "notarytool rejected the submission; xcrun notarytool log <id> has the detail"
  fi
  step "stapling the ticket"
  xcrun stapler staple "$OUT" || die "stapler failed"
  xcrun stapler validate "$OUT" || die "the stapled ticket does not validate"
  say "   ticket stapled"
else
  step "notarization: skipped$([ "$ADHOC" = 1 ] && echo " (ad-hoc build; Apple does not notarize one)" || echo " (--notarize not given)")"
fi

# ---------------------------------------------------------------------------
# 6. Verify the finished image the way a user's machine will.
# ---------------------------------------------------------------------------
if [ "$VERIFY" = 1 ]; then
  step "verifying the image"
  hdiutil verify "$OUT" >/dev/null 2>&1 || die "hdiutil verify failed on $OUT"
  mkdir -p "$MNT"
  hdiutil attach "$OUT" -mountpoint "$MNT" -nobrowse -readonly -quiet || die "the finished image will not mount"
  [ -d "$MNT/7-Zip.app" ] || die "no 7-Zip.app on the mounted image"
  [ -L "$MNT/Applications" ] || die "no /Applications symlink on the mounted image"
  [ -f "$MNT/License.txt" ] || die "no License.txt on the mounted image"
  codesign --verify --deep --strict "$MNT/7-Zip.app" 2>/dev/null \
    || die "the app on the image fails codesign --verify --deep --strict"
  SPCTL="$(spctl --assess --type execute -vv "$MNT/7-Zip.app" 2>&1 || true)"
  hdiutil detach "$MNT" -quiet; rm -rf "$MNT"
  say "   mounts, holds 7-Zip.app, the Applications symlink and the licence, signature intact"
  if echo "$SPCTL" | grep -q accepted; then
    say "   spctl --assess: accepted"
  else
    say "   spctl --assess: rejected -- expected for an $([ "$ADHOC" = 1 ] && echo "ad-hoc" || echo "un-notarized") build; Gatekeeper wants a"
    say "                   notarized Developer ID signature. First-launch instructions: README.md"
  fi
fi

# ---------------------------------------------------------------------------
# 7. Verdict.
# ---------------------------------------------------------------------------
SIZE="$(du -h "$OUT" | cut -f1 | tr -d ' ')"
SUM="$(shasum -a 256 "$OUT" | cut -d' ' -f1)"
echo
echo "OK: $OUT"
echo "    volume name   $VOLNAME"
echo "    version       $VERSION ($BUILDNO), arm64, macOS 14.0+"
echo "    size          $SIZE"
echo "    signature     $([ "$ADHOC" = 1 ] && echo "ad-hoc" || echo "$IDENTITY")$([ "$NOTARIZE" = 1 ] && echo ", notarized and stapled" || echo ", not notarized")"
echo "    sha256        $SUM"
