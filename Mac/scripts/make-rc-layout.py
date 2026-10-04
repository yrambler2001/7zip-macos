#!/usr/bin/env python3
"""make-rc-layout.py -- every 7zFM / 7zG dialog template, in dialog units, for the port's dialogs
(dlgfeel).

Windows lays a dialog out from its .rc template: every control has an x, y, width and height in
dialog units (DLUs), and the dialog manager converts them with the dialog font's base units. The
port places its controls from the very same numbers (`RcLayout.swift`), so a control's position
and size come out of the template instead of being guessed again in Swift.

The resource scripts are run through the C preprocessor exactly like make-rc-strings.py (rc.exe
preprocesses them the same way), so every `#define`d size and `#include`d page resolves:

    CPP/7zip/UI/FileManager/resource.rc   7zFM.exe
    CPP/7zip/UI/GUI/resource.rc           7zG.exe  (Add to Archive, Extract, Benchmark ...)

Each `<id> DIALOG x, y, cx, cy STYLE ...` block is tokenised and split into control statements
(LTEXT, RTEXT, CTEXT, PUSHBUTTON, DEFPUSHBUTTON, GROUPBOX, EDITTEXT, COMBOBOX, LISTBOX, ICON,
CONTROL ...). Their numeric fields are C expressions of literals (`(400 + 8 + 8) - 8 - 64`) and
are evaluated with C integer arithmetic. A template that is in both scripts (the shared
Password / Progress / ListView ones) is taken from 7zFM's.

Output: Mac/App/Support/RcTemplates.swift.

    python3 Mac/scripts/make-rc-layout.py [--repo <root>] [--check]
"""

from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import tempfile

SOURCES = ["CPP/7zip/UI/FileManager/resource.rc", "CPP/7zip/UI/GUI/resource.rc"]
OUTPUT = "Mac/App/Support/RcTemplates.swift"

KEYWORDS = {"LTEXT", "RTEXT", "CTEXT", "PUSHBUTTON", "DEFPUSHBUTTON", "GROUPBOX", "CONTROL",
            "EDITTEXT", "COMBOBOX", "LISTBOX", "ICON", "AUTOCHECKBOX", "CHECKBOX",
            "AUTORADIOBUTTON", "RADIOBUTTON", "SCROLLBAR", "PUSHBOX", "STATE3", "AUTO3STATE"}
# Statement keywords whose first field is the text.
TEXT_FIRST = KEYWORDS - {"EDITTEXT", "COMBOBOX", "LISTBOX", "SCROLLBAR"}
CONSTANTS = {"IDOK": 1, "IDCANCEL": 2, "IDABORT": 3, "IDRETRY": 4, "IDIGNORE": 5, "IDYES": 6,
             "IDNO": 7, "IDCLOSE": 8, "IDHELP": 9, "IDTRYAGAIN": 10, "IDCONTINUE": 11}

TOKEN = re.compile(r'L?"(?:[^"]|"")*"|[A-Za-z_][A-Za-z_0-9]*|\d+|[-+*/(),|]|\S')


def unescape(s: str) -> str:
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


def preprocess(repo: str, rc: str, stub: str) -> str:
    env = dict(os.environ)
    env.setdefault("DEVELOPER_DIR", "/Applications/Xcode.app")
    return subprocess.run(["xcrun", "clang", "-E", "-P", "-x", "c", "-I", stub,
                           "-DUNICODE", "-D_UNICODE", os.path.join(repo, rc)],
                          check=True, capture_output=True, text=True, env=env).stdout


def evaluate(tokens: list[str]) -> int:
    """A C integer expression of literals and the IDOK-style constants."""
    pos = 0

    def peek():
        return tokens[pos] if pos < len(tokens) else None

    def take():
        nonlocal pos
        pos += 1
        return tokens[pos - 1]

    def primary() -> int:
        t = take()
        if t == "(":
            v = expr()
            take()
            return v
        if t == "-":
            return -primary()
        if t == "+":
            return primary()
        if t.isdigit():
            return int(t)
        if t in CONSTANTS:
            return CONSTANTS[t]
        raise ValueError(f"not a number: {t!r} in {' '.join(tokens)}")

    def term() -> int:
        v = primary()
        while peek() in ("*", "/"):
            op = take()
            r = primary()
            v = v * r if op == "*" else int(v / r)
        return v

    def expr() -> int:
        v = term()
        while peek() in ("+", "-"):
            op = take()
            r = term()
            v = v + r if op == "+" else v - r
        return v

    value = expr()
    if pos != len(tokens):
        raise ValueError("trailing tokens in " + " ".join(tokens))
    return value


def split_fields(tokens: list[str]) -> list[list[str]]:
    fields, cur, depth = [], [], 0
    for t in tokens:
        if t == "(":
            depth += 1
        elif t == ")":
            depth -= 1
        if t == "," and depth == 0:
            fields.append(cur)
            cur = []
        else:
            cur.append(t)
    fields.append(cur)
    return fields


def kind_of(keyword: str, cls: str, style: list[str]) -> str:
    s = set(style)
    if keyword == "LTEXT":
        return "ltext"
    if keyword == "RTEXT":
        return "rtext"
    if keyword == "CTEXT":
        return "ctext"
    if keyword == "DEFPUSHBUTTON":
        return "defPush"
    if keyword == "PUSHBUTTON":
        return "push"
    if keyword == "GROUPBOX":
        return "group"
    if keyword == "EDITTEXT":
        return "edit"
    if keyword == "COMBOBOX":
        return "comboList" if "CBS_DROPDOWNLIST" in s else "comboEdit"
    if keyword == "LISTBOX":
        return "listBox"
    if keyword == "ICON":
        return "icon"
    if keyword in ("AUTOCHECKBOX", "CHECKBOX", "STATE3", "AUTO3STATE"):
        return "check"
    if keyword in ("AUTORADIOBUTTON", "RADIOBUTTON"):
        return "radio"
    c = cls.lower()
    if c == "button":
        if s & {"BS_AUTOCHECKBOX", "BS_CHECKBOX", "BS_AUTO3STATE", "BS_3STATE"}:
            return "check"
        if s & {"BS_AUTORADIOBUTTON", "BS_RADIOBUTTON"}:
            return "radio"
        if "BS_GROUPBOX" in s:
            return "group"
        if "BS_DEFPUSHBUTTON" in s:
            return "defPush"
        return "push"
    if c == "syslistview32":
        return "listView"
    if c == "msctls_updown32":
        return "upDown"
    if c == "msctls_progress32":
        return "progress"
    if c == "static":
        return "ltext"
    if c == "edit":
        return "edit"
    return "other"


def parse(text: str, source: str, templates: dict) -> None:
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        m = re.match(r'^\s*(\d+)\s+DIALOG(?:EX)?\s+(.*)$', lines[i])
        if not m:
            i += 1
            continue
        did = int(m.group(1))
        header = m.group(2)
        caption = ""
        body: list[str] = []
        i += 1
        while i < len(lines) and lines[i].strip() not in ("BEGIN", "{"):
            cm = re.match(r'^\s*CAPTION\s+"((?:[^"]|"")*)"', lines[i])
            if cm:
                caption = unescape(cm.group(1))
            else:
                header += " " + lines[i]
            i += 1
        i += 1
        depth = 1
        while i < len(lines):
            s = lines[i].strip()
            if s in ("END", "}"):
                depth -= 1
                if depth == 0:
                    break
            body.append(lines[i])
            i += 1
        i += 1
        hdr = header.split("STYLE")[0]
        hfields = split_fields(TOKEN.findall(hdr))
        w = evaluate(hfields[2])
        h = evaluate(hfields[3])
        style_tokens = set(TOKEN.findall(header.split("STYLE")[1])) if "STYLE" in header else set()
        resizable = "WS_THICKFRAME" in style_tokens or "WS_SIZEBOX" in style_tokens
        controls = []
        tokens = TOKEN.findall(" ".join(body))
        stmts, cur = [], None
        for t in tokens:
            if t in KEYWORDS:
                if cur:
                    stmts.append(cur)
                cur = [t]
            elif cur is not None:
                cur.append(t)
        if cur:
            stmts.append(cur)
        for st in stmts:
            kw = st[0]
            fields = split_fields(st[1:])
            text_value = ""
            if kw in TEXT_FIRST:
                first = fields.pop(0)
                if first and first[0].startswith(("\"", "L\"")):
                    text_value = unescape(first[0][first[0].index('"') + 1:-1])
                elif first:
                    text_value = " ".join(first)          # ICON IDI_LOGO
            cid = evaluate(fields[0])
            cls, style = "", []
            if kw == "CONTROL":
                c = fields[1][0]
                cls = c[c.index('"') + 1:-1]
                style = [t for t in fields[2] if re.match(r"[A-Z_]", t)]
                x, y, cw, ch = (evaluate(f) for f in fields[3:7])
            else:
                x, y, cw, ch = (evaluate(f) for f in fields[1:5])
                if len(fields) > 5:
                    style = [t for t in fields[5] if re.match(r"[A-Z_]", t)]
            controls.append((cid, kind_of(kw, cls, style), x, y, cw, ch, text_value,
                             "ES_PASSWORD" in style, "ES_MULTILINE" in style))
        templates.setdefault(did, (did, caption, w, h, resizable, controls, source))


def swift_string(s: str) -> str:
    out = []
    for c in s:
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append("\\t")
        elif c == "\r":
            out.append("\\r")
        else:
            out.append(c)
    return '"' + "".join(out) + '"'


def render(templates: dict) -> str:
    out = ["// RcTemplates.swift -- GENERATED by Mac/scripts/make-rc-layout.py from",
           "// " + " and ".join(SOURCES) + ". Do not edit.",
           "// Every dialog template of 7zFM / 7zG in dialog units, as rc.exe compiles it (dlgfeel).",
           "// RcLayout.swift converts them with the dialog font's base units (6 x 13 at 96 dpi).",
           "",
           "// swiftlint:disable all",
           "extension RcTemplates {",
           "    static let all: [Int: RcTemplate] = ["]
    for did in sorted(templates):
        _, caption, w, h, resizable, controls, source = templates[did]
        out.append(f"        // {source}")
        out.append(f"        {did}: RcTemplate(id: {did}, caption: {swift_string(caption)}, "
                   f"width: {w}, height: {h}, resizable: {'true' if resizable else 'false'}, controls: [")
        for (cid, kind, x, y, cw, ch, text, pw, ml) in controls:
            extra = (", password: true" if pw else "") + (", multiline: true" if ml else "")
            out.append(f"            RcControl(id: {cid}, kind: .{kind}, x: {x}, y: {y}, width: {cw}, "
                       f"height: {ch}, text: {swift_string(text)}{extra}),")
        out.append("        ]),")
    out.append("    ]")
    out.append("}")
    return "\n".join(out) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
    ap.add_argument("--check", action="store_true", help="fail when the committed file is stale")
    args = ap.parse_args()
    templates: dict = {}
    with tempfile.TemporaryDirectory() as stub:
        for name in ("windows.h", "CommCtrl.h", "winnt.h", "WinUser.h"):
            open(os.path.join(stub, name), "w").close()
        for rc in SOURCES:
            parse(preprocess(args.repo, rc, stub), os.path.basename(os.path.dirname(rc)), templates)
    text = render(templates)
    path = os.path.join(args.repo, OUTPUT)
    print(f"make-rc-layout: {len(templates)} dialog templates, "
          f"{sum(len(t[5]) for t in templates.values())} controls")
    if args.check:
        current = open(path, encoding="utf-8").read() if os.path.exists(path) else ""
        if current != text:
            print(f"{OUTPUT} is stale; run Mac/scripts/make-rc-layout.py", file=sys.stderr)
            return 1
        return 0
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)
    print("wrote " + OUTPUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
