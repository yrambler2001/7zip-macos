# finderext-registration.sh -- sourced by build.sh and test.sh (appfeel, Mac/docs/reports/appfeel.md §2).
#
# Every 7-Zip.app copy registers its Finder Sync extension under the same identifier, and PlugInKit
# hands Finder one of them -- after an xcodebuild, the fresh build. So building or testing used to
# take Finder's 7-Zip menu away from the installed app, and a worktree build that was later deleted
# left Finder pointing at nothing. Which copy wins cannot be steered by re-adding one (measured,
# reports/appfeel.md §2); removing the others can. These functions remember which copy Finder used
# before the build/test and, if that changed, remove every other registration and re-add that copy.
# Registrations whose bundle no longer exists are always dropped. The election (on/off) is never
# touched.
#
#   finderext_snapshot   before xcodebuild
#   finderext_restore    after it, and from an EXIT trap

FINDEREXT_ID=com.yrambler2001.7zip.FinderSync
FINDEREXT_BEFORE=""

# The appex path of the copy Finder uses (pluginkit -m prints only that one; the path is the last
# tab-separated field).
finderext_active() {
  /usr/bin/pluginkit -m -v -i "$FINDEREXT_ID" 2>/dev/null \
    | awk -F'\t' -v id="$FINDEREXT_ID" 'index($0, id) { print $NF; exit }'
}

finderext_snapshot() {
  FINDEREXT_BEFORE="$(finderext_active || true)"
}

finderext_restore() {
  [ -x /usr/bin/pluginkit ] || return 0
  local path now
  /usr/bin/pluginkit -m -D -A -v -i "$FINDEREXT_ID" 2>/dev/null \
    | awk -F'\t' -v id="$FINDEREXT_ID" 'index($0, id) { print $NF }' \
    | while IFS= read -r path; do
        [ -n "$path" ] && [ ! -e "$path" ] && /usr/bin/pluginkit -r "$path" >/dev/null 2>&1 || true
      done
  [ -n "$FINDEREXT_BEFORE" ] && [ -e "$FINDEREXT_BEFORE" ] || return 0
  now="$(finderext_active || true)"
  if [ "$now" != "$FINDEREXT_BEFORE" ]; then
    /usr/bin/pluginkit -m -D -A -v -i "$FINDEREXT_ID" 2>/dev/null \
      | awk -F'\t' -v id="$FINDEREXT_ID" 'index($0, id) { print $NF }' \
      | while IFS= read -r path; do
          [ -n "$path" ] && [ "$path" != "$FINDEREXT_BEFORE" ] && /usr/bin/pluginkit -r "$path" >/dev/null 2>&1 || true
        done
    /usr/bin/pluginkit -a "$FINDEREXT_BEFORE" >/dev/null 2>&1 || true
    echo "== Finder extension handed back to $FINDEREXT_BEFORE"
  fi
  FINDEREXT_BEFORE=""
}
