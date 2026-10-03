#!/usr/bin/env python3
"""make-rc-strings.py -- the English text of 7zFM / 7zG's own Windows resources, for the port's
built-in English (winmatch).

With no language file, 7zFM shows the strings compiled into its .rc resources: dialog captions,
dialog control texts and STRINGTABLE entries. `Lang/en.ttt` is the *translators'* template and
differs from them in places ("Add to archive" vs the .rc's "Add to Archive", "Solid block size:"
vs "&Solid Block size:", "Show password" vs "Show Password"). SZLang therefore looks a lang ID up
in this table before en.ttt, as Windows' LangString falls back to the resource.

The resource scripts are run through the C preprocessor (the .rc files are preprocessed by rc.exe
the same way), so every `#define`d ID and every `#include` resolves exactly as on Windows:

    CPP/7zip/UI/FileManager/resource.rc   7zFM.exe (all FM dialogs, PropertyName.rc, Extract.rc ...)
    CPP/7zip/UI/GUI/resource.rc           7zG.exe  (Extract, Compress, Benchmark ...)

Collected per lang ID:
  * `<id> DIALOG ... CAPTION "<text>"`         -- a dialog's caption is LangSetWindowText(IDD)
  * control statements `KEYWORD "<text>", <id>` -- LangSetDlgItems: control ID == lang ID
  * `STRINGTABLE` entries                       -- MyLoadString
MENU resources are not collected: the port's menus pass their .rc text explicitly
(`Lang.menuTitle(id, resourceText)`).

Control IDs below 400 are not lang IDs (IDOK, list views, "..." buttons; LangSetDlgItems never
names one), and string-table IDs below 100 are the language names; both are skipped. Two tables
come out: per dialog (what that dialog's control shows), and per ID -- the STRINGTABLE text, which
is what LangString(id) loads, else the text every dialog agrees on. An ID whose dialogs disagree
(3803 "&Show password" in IDD_PASSWORD, "Show Password" in IDD_EXTRACT / IDD_COMPRESS) is in the
per-dialog table only, and the code asks for it with its dialog (`Lang.dialogText`).

Output: Mac/Core/Internal/SZRcStrings.h, a sorted C array included by Mac/Core/SZLang.mm.

    python3 Mac/scripts/make-rc-strings.py [--repo <root>] [--check]
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile

SOURCES = ["CPP/7zip/UI/FileManager/resource.rc", "CPP/7zip/UI/GUI/resource.rc"]
OUTPUT = "Mac/Core/Internal/SZRcStrings.h"

CONTROL_KEYWORDS = ("LTEXT", "RTEXT", "CTEXT", "PUSHBUTTON", "DEFPUSHBUTTON", "GROUPBOX", "CONTROL",
                    "AUTOCHECKBOX", "CHECKBOX", "AUTORADIOBUTTON", "RADIOBUTTON", "STATE3",
                    "AUTO3STATE", "PUSHBOX")
STR = r'"((?:[^"]|"")*)"'
RE_DIALOG = re.compile(r'^\s*(\d+)\s+DIALOG(?:EX)?\b')
RE_CAPTION = re.compile(r'^\s*CAPTION\s+' + STR)
RE_CONTROL = re.compile(r'^\s*(' + "|".join(CONTROL_KEYWORDS) + r')\s+' + STR + r'\s*,\s*(-?\d+)\s*,')
RE_STRING = re.compile(r'^\s*(\d+)\s*,?\s*' + STR + r'\s*$')


def unescape(s: str) -> str:
    """rc.exe string literal: "" is a quote; \\t, \\n, \\\\ as in C."""
    s = s.replace('""', '"')
    out, i = [], 0
    while i < len(s):
        c = s[i]
        if c == "\\" and i + 1 < len(s):
            n = s[i + 1]
            out.append({"t": "\t", "n": "\n", "\\": "\\", "r": "\r", '"': '"'}.get(n, "\\" + n))
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def preprocess(repo: str, rc: str, stub: str) -> list[str]:
    env = dict(os.environ)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app")
    out = subprocess.run(["xcrun", "clang", "-E", "-P", "-x", "c", "-I", stub,
                          "-DUNICODE", "-D_UNICODE", os.path.join(repo, rc)],
                         check=True, capture_output=True, text=True, env=env).stdout
    return out.splitlines()


def collect(lines: list[str], source: str, strings: dict, dialogs: dict) -> None:
    """strings: id -> text (STRINGTABLE, first wins); dialogs: (dialog, id) -> text."""
    in_strings = False
    dialog = None
    for line in lines:
        s = line.strip()
        if s.startswith("STRINGTABLE"):
            in_strings = True
            dialog = None
            continue
        m = RE_DIALOG.match(line)
        if m:
            dialog = int(m.group(1))
            in_strings = False
            continue
        if in_strings:
            if s in ("END", "}"):
                in_strings = False
                continue
            m = RE_STRING.match(line)
            if m and int(m.group(1)) >= 100:
                strings.setdefault(int(m.group(1)), (unescape(m.group(2)), f"{source} STRINGTABLE"))
            continue
        if dialog is not None:
            m = RE_CAPTION.match(line)
            if m:
                dialogs.setdefault((dialog, dialog), (unescape(m.group(1)), f"{source} DIALOG {dialog} CAPTION"))
                continue
            m = RE_CONTROL.match(line)
            if m and int(m.group(3)) >= 400 and m.group(2) != "":
                dialogs.setdefault((dialog, int(m.group(3))),
                                   (unescape(m.group(2)), f"{source} DIALOG {dialog} {m.group(1)}"))


def merge(strings: dict, dialogs: dict) -> tuple[dict, list[str]]:
    """The context-free table: a STRINGTABLE entry (what LangString loads), else the one text
    every dialog agrees on. An ID whose dialogs disagree is left to the dialog table only."""
    table = dict(strings)
    by_id: dict[int, set] = {}
    for (dialog, i), (text, _) in dialogs.items():
        by_id.setdefault(i, set()).add(text)
    ambiguous = []
    for (dialog, i), (text, where) in sorted(dialogs.items()):
        if i in table:
            continue
        if len(by_id[i]) == 1:
            table[i] = (text, where)
        elif i not in ambiguous:
            ambiguous.append(i)
    notes = [f"{i}: " + " | ".join(sorted(repr(t) for t in by_id[i])) + " -> per dialog only" for i in ambiguous]
    return table, notes


def c_literal(text: str) -> str:
    out = []
    for c in text:
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "\t":
            out.append("\\t")
        elif c == "\n":
            out.append("\\n")
        elif c == "\r":
            out.append("\\r")
        elif ord(c) < 0x20 or ord(c) > 0x7E:
            out.append("\\x%04x\"L\"" % ord(c))
        else:
            out.append(c)
    return 'L"' + "".join(out) + '"'


def render(table: dict, dialogs: dict) -> str:
    rows = [f"  {{ {i}, {c_literal(table[i][0])} }},  // {table[i][1]}" for i in sorted(table)]
    drows = [f"  {{ {d}, {i}, {c_literal(dialogs[(d, i)][0])} }},  // {dialogs[(d, i)][1]}"
             for (d, i) in sorted(dialogs)]
    return ("// SZRcStrings.h -- GENERATED by Mac/scripts/make-rc-strings.py from\n"
            "// " + " and ".join(SOURCES) + ". Do not edit.\n"
            "// The English text 7zFM / 7zG show with no language file, by lang ID, both sorted.\n"
            "// kSZRcStrings: STRINGTABLE entries, else a dialog text all dialogs agree on.\n"
            "// kSZRcDialogStrings: every dialog caption (dialog == id) and control text per dialog.\n"
            "static const SZRcString kSZRcStrings[] =\n{\n" + "\n".join(rows) + "\n};\n\n"
            "static const SZRcDialogString kSZRcDialogStrings[] =\n{\n" + "\n".join(drows) + "\n};\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
    ap.add_argument("--check", action="store_true", help="fail when the committed file is stale")
    args = ap.parse_args()

    strings: dict[int, tuple[str, str]] = {}
    dialogs: dict[tuple[int, int], tuple[str, str]] = {}
    with tempfile.TemporaryDirectory() as stub:
        for name in ("windows.h", "CommCtrl.h", "winnt.h", "WinUser.h"):
            open(os.path.join(stub, name), "w").close()
        for rc in SOURCES:
            collect(preprocess(args.repo, rc, stub), os.path.basename(os.path.dirname(rc)), strings, dialogs)
    table, notes = merge(strings, dialogs)

    text = render(table, dialogs)
    path = os.path.join(args.repo, OUTPUT)
    print(f"make-rc-strings: {len(table)} IDs, {len(dialogs)} dialog texts")
    for n in notes:
        print("  " + n)
    if args.check:
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if current != text:
            print(f"{OUTPUT} is stale; run Mac/scripts/make-rc-strings.py", file=sys.stderr)
            return 1
        return 0
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("wrote " + OUTPUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
