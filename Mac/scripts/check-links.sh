#!/usr/bin/env bash
# check-links.sh -- check that every relative link in the repository's Markdown files resolves:
# [text](path), [text](path#anchor), ![alt](image) and reference definitions [id]: path.
# The target file (or directory) must exist; an #anchor into a Markdown file must match one of its
# headings (GitHub's slug rules). http(s)/mailto links are not fetched. Works from any directory.
#
# Usage: Mac/scripts/check-links.sh [file.md ...]   (default: every tracked *.md)
# Exit: 0 when every link resolves, 1 otherwise (each broken link is printed as file:line: target).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
if [ $# -eq 0 ]; then
  set -- $(git ls-files '*.md')
fi

python3 - "$@" <<'PY'
import os, re, sys

link_re = re.compile(r'!?\[(?:[^\]\[]|\[[^\]]*\])*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)')
ref_re = re.compile(r'^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+".*")?\s*$')
fence_re = re.compile(r'^\s*(```|~~~)')

def slug(heading):
    h = heading.strip().lower()
    h = re.sub(r'<[^>]+>', '', h)
    h = re.sub(r'[^\w\- ]', '', h)
    return h.replace(' ', '-')

anchors_cache = {}
def anchors(path):
    if path not in anchors_cache:
        found, seen, fence = set(), {}, False
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                if fence_re.match(line):
                    fence = not fence
                    continue
                m = None if fence else re.match(r'^#{1,6}\s+(.*?)\s*#*\s*$', line)
                if m:
                    s = slug(m.group(1))
                    n = seen.get(s, 0)
                    seen[s] = n + 1
                    found.add(s if n == 0 else f"{s}-{n}")
        anchors_cache[path] = found
    return anchors_cache[path]

bad = 0
checked = 0
for md in sys.argv[1:]:
    base = os.path.dirname(md)
    fence = False
    with open(md, encoding='utf-8', errors='replace') as f:
        for no, line in enumerate(f, 1):
            if fence_re.match(line):
                fence = not fence
                continue
            if fence:
                continue
            # drop inline code spans so `[x](y)` examples are not links
            text = re.sub(r'`[^`]*`', '', line)
            targets = [m.group(1) for m in link_re.finditer(text)]
            m = ref_re.match(text)
            if m:
                targets.append(m.group(1))
            for t in targets:
                if re.match(r'^[a-z][a-z0-9+.-]*:', t, re.I):
                    continue                    # http:, https:, mailto: ...
                checked += 1
                path, _, anchor = t.partition('#')
                target = md if path == '' else os.path.normpath(os.path.join(base, path))
                if not os.path.exists(target):
                    print(f"{md}:{no}: missing {t}")
                    bad += 1
                    continue
                if anchor and target.endswith('.md') and anchor.lower() not in anchors(target):
                    print(f"{md}:{no}: no heading for #{anchor} in {target}")
                    bad += 1
print(f"check-links: {checked} relative link(s) in {len(sys.argv) - 1} file(s), {bad} broken")
sys.exit(1 if bad else 0)
PY
