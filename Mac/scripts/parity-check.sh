#!/usr/bin/env bash
# parity-check.sh -- count the parity checkboxes of ai/PROGRESS.md per scope.
# Read-only: it never writes to the file.
#
# Usage: Mac/scripts/parity-check.sh [options]
#   (no options)           one line per scope: done / total / percent, then a TOTAL line
#   -s, --scope <NAME>     only that scope (scaffold, fsfolder, panel, extract, compress,
#                          tools, options, finder, packaging)
#   -l, --list <NAME>      list the unticked items of that scope (with line numbers)
#   -L, --list-all         list the unticked items of every scope
#   -f, --file <PATH>      a different checklist file (default ai/PROGRESS.md)
#   -h, --help             this text
# A scope section is a "## <n>. <scope> — ..." heading; items are "- [ ]" / "- [x]" lines.
set -euo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app}"   # for consistency with the other scripts
FILE="$ROOT/ai/PROGRESS.md"
SCOPE=""
LIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    -s|--scope) SCOPE="${2:?--scope needs a value}"; shift ;;
    -l|--list) LIST="${2:?--list needs a value}"; SCOPE="$LIST"; shift ;;
    -L|--list-all) LIST="*" ;;
    -f|--file) FILE="${2:?--file needs a value}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "parity-check.sh: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
[ -r "$FILE" ] || { echo "parity-check.sh: cannot read $FILE" >&2; exit 2; }

awk -v want="$SCOPE" -v list="$LIST" -v file="$FILE" '
  /^## / {
    scope = ""
    if ($2 ~ /^[0-9]+\.$/) { scope = $3; if (!(scope in seen)) { seen[scope] = 1; order[++n] = scope } }
    next
  }
  /^- \[[ xX]\]/ {
    if (scope == "") next
    total[scope]++
    if ($0 ~ /^- \[[xX]\]/) { done[scope]++ }
    else {
      item = $0; sub(/^- \[[ xX]\] /, "", item)
      if (list == "*" || (list != "" && list == scope)) undone[scope] = undone[scope] NR "\t" item "\n"
    }
    next
  }
  END {
    if (n == 0) { print "no scope sections (## <n>. <scope>) in " file; exit 1 }
    if (want != "" ) {
      found = 0
      for (i = 1; i <= n; i++) if (order[i] == want) found = 1
      if (!found) { printf "no such scope: %s (have:", want; for (i = 1; i <= n; i++) printf " %s", order[i]; print ")"; exit 1 }
    }
    printf "%-12s %6s %6s %6s\n", "scope", "done", "total", "pct"
    td = 0; tt = 0
    for (i = 1; i <= n; i++) {
      s = order[i]
      d = done[s] + 0; t = total[s] + 0
      td += d; tt += t
      if (want == "" || want == s)
        printf "%-12s %6d %6d %5d%%\n", s, d, t, (t ? int(d * 100 / t + 0.5) : 0)
    }
    printf "%-12s %6d %6d %5d%%\n", "TOTAL", td, tt, (tt ? int(td * 100 / tt + 0.5) : 0)
    for (i = 1; i <= n; i++) {
      s = order[i]
      if (s in undone) {
        printf "\n-- %s: %d open item(s) --\n", s, total[s] - done[s]
        printf "%s", undone[s]
      }
    }
  }
' "$FILE"
