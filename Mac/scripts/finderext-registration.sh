# finderext-registration.sh -- sourced by build.sh and test.sh (appfeel, Mac/docs/reports/appfeel.md §2;
# finderfix, Mac/docs/reports/finderfix.md).
#
# Every 7-Zip.app copy registers its Finder Sync extension and its two Quick Actions under the same
# identifiers, and PlugInKit hands Finder one copy of each -- after an xcodebuild, the fresh build.
# So building or testing used to take Finder's 7-Zip menu away from the installed app, and a
# worktree build that was later deleted left Finder pointing at nothing. Which copy wins cannot be
# steered by re-adding one (measured, reports/appfeel.md §2); removing the others can. These
# functions remember which copy Finder used before the build/test and, if that changed, remove
# every other registration and re-add that copy. Registrations whose bundle no longer exists are
# always dropped. The election (on/off) is never touched.
#
# finderfix: the same goes for Launch Services. A build in DerivedData also claims the `sevenzip:`
# scheme and the archive document types, so `open sevenzip://…` could reach it instead of the
# installed app. When the copy Finder used before is outside this tree's build directory (the user's
# installed 7-Zip), the freshly built copies are unregistered from Launch Services afterwards. A
# copy that is launched (run.sh, the UI tests) registers itself again, which is harmless while it
# runs; the next build or test run hands everything back.
#
#   finderext_snapshot   before xcodebuild
#   finderext_restore    after it, and from an EXIT trap

FINDEREXT_IDS="com.yrambler2001.7zip.FinderSync com.yrambler2001.7zip.QuickActionExtract com.yrambler2001.7zip.QuickActionCompress"
FINDEREXT_BEFORE=""
FINDEREXT_LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# The appex path of the copy Finder uses for identifier $1 (pluginkit -m prints only that one; the
# path is the last tab-separated field).
finderext_active() {
  /usr/bin/pluginkit -m -v -i "$1" 2>/dev/null \
    | awk -F'\t' -v id="$1" 'index($0, id) { print $NF; exit }'
}

# Every registered copy of identifier $1, one path per line.
finderext_all() {
  /usr/bin/pluginkit -m -D -A -v -i "$1" 2>/dev/null \
    | awk -F'\t' -v id="$1" 'index($0, id) { print $NF }'
}

finderext_snapshot() {
  [ -x /usr/bin/pluginkit ] || return 0
  local id
  FINDEREXT_BEFORE=""
  for id in $FINDEREXT_IDS; do
    FINDEREXT_BEFORE="$FINDEREXT_BEFORE$id|$(finderext_active "$id" || true)
"
  done
}

finderext_restore() {
  [ -x /usr/bin/pluginkit ] || return 0
  local id before path now handed=""
  for id in $FINDEREXT_IDS; do
    finderext_all "$id" | while IFS= read -r path; do
      [ -n "$path" ] && [ ! -e "$path" ] && /usr/bin/pluginkit -r "$path" >/dev/null 2>&1 || true
    done
    before="$(printf '%s' "$FINDEREXT_BEFORE" | awk -F'|' -v id="$id" '$1 == id { print $2; exit }')"
    [ -n "$before" ] && [ -e "$before" ] || continue
    now="$(finderext_active "$id" || true)"
    if [ "$now" != "$before" ]; then
      finderext_all "$id" | while IFS= read -r path; do
        [ -n "$path" ] && [ "$path" != "$before" ] && /usr/bin/pluginkit -r "$path" >/dev/null 2>&1 || true
      done
      /usr/bin/pluginkit -a "$before" >/dev/null 2>&1 || true
      handed="$before"
    fi
  done
  [ -n "$handed" ] && echo "== Finder extensions handed back to ${handed%/Contents/PlugIns/*}"

  # Launch Services: give the scheme and the document types back to the installed copy.
  before="$(printf '%s' "$FINDEREXT_BEFORE" | awk -F'|' '$1 ~ /FinderSync$/ { print $2; exit }')"
  FINDEREXT_BEFORE=""
  [ -n "$before" ] && [ -e "$before" ] && [ -x "$FINDEREXT_LSREGISTER" ] || return 0
  case "$before" in
    "${MAC:-/nonexistent}"/build/*) return 0 ;;   # the developer uses this tree's own build
  esac
  local app
  for app in "${MAC:-/nonexistent}"/build/DerivedData/Build/Products/*/7-Zip.app; do
    [ -d "$app" ] || continue
    "$FINDEREXT_LSREGISTER" -u "$app" >/dev/null 2>&1 || true
  done
  # Unregistering a bundle also drops its appexes; make sure the installed copy keeps its own.
  for path in "${before%/FinderSync.appex}"/*.appex; do
    [ -d "$path" ] && /usr/bin/pluginkit -a "$path" >/dev/null 2>&1 || true
  done
}
