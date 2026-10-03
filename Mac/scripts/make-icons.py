#!/usr/bin/env python3
"""Regenerate every 7-Zip.app icon asset from the upstream Windows icon resources.

This is the *extraction and assembly* half of the icon pipeline; the *drawing* half is
``Mac/scripts/make-icons.swift`` (CoreGraphics, so the art is a real vector render at every
pixel size instead of one big bitmap scaled down).  ``Mac/scripts/make-icons.sh`` runs both.

What this script does, in order:

1. Parses the authoritative upstream tables so nothing is hand-copied:
   * ``CPP/7zip/Bundles/Format7zF/resource.rc``  -- ``<index> ICON "<name>.ico"`` (0..26) and
     STRINGTABLE 100, the ``ext:index`` association string (40 pairs in 26.03).
   * ``Mac/App/Support/FileTypes.swift``         -- the `options` scope's merged table, which is
     the authoritative extension -> icon-index list for the port.
   Both are cross-checked; a mismatch is a hard error.
2. Decodes every frame of every upstream ``.ico`` (see :func:`ico_frames` /
   :func:`decode_bmp_frame` for the format handling: PNG-compressed frames, 32/24-bit BMP frames
   with or without a real alpha channel, and 8/4/1-bit paletted BMP frames whose transparency
   lives in the trailing 1-bit AND mask).  Frames are written out as RGBA PNGs by a small
   built-in PNG writer -- ``sips`` cannot read ``.ico`` at all, and nothing here may depend on a
   package that is not part of a stock macOS + Xcode install.
3. Derives the palette that the macOS art is drawn with: the shared "archive body" colours and
   each format's exact badge colour, read straight out of the decoded 32x32 frames.
4. Writes ``icons-manifest.json`` for the Swift renderer, runs it (document icons), writes the
   app icon straight from ``FM.ico``'s frames (:func:`stage_app_icon`: nearest frame per size,
   nearest-neighbour, nothing redrawn), then assembles
   ``AppIcon.appiconset``, the ``doc-<name>.imageset``s, and the ``doc-<name>.icns`` files
   (via ``iconutil``), and finally verifies every emitted PNG really carries alpha and is not
   blank or a solid rectangle.

Usage::

    python3 Mac/scripts/make-icons.py --repo <repo root> [--work <dir>] [--stage all|extract|draw|assemble|verify]
    python3 Mac/scripts/make-icons.py --repo . --dump 7z      # ASCII dump of one upstream icon
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import zlib
from collections import Counter

# --------------------------------------------------------------------------------------------
# Geometry / naming constants shared with make-icons.swift and Mac/docs/api/icons.md
# --------------------------------------------------------------------------------------------

# Pixel sizes an AppIcon.appiconset / .iconset needs on macOS (16pt..512pt @1x and @2x).
PIXEL_SIZES = [16, 32, 64, 128, 256, 512, 1024]

# (point size, scale, pixel size) rows of a macOS app icon set.  Every slot gets its own file
# even where two slots are the same pixel size: actool de-duplicates identical *filenames* and
# then emits an AppIcon.icns missing the collapsed slots, which costs the 512pt art.
APPICON_ROWS = [
    (16, 1, 16), (16, 2, 32),
    (32, 1, 32), (32, 2, 64),
    (128, 1, 128), (128, 2, 256),
    (256, 1, 256), (256, 2, 512),
    (512, 1, 512), (512, 2, 1024),
]

# iconutil's fixed filenames inside a .iconset directory.
ICONSET_ROWS = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

# The two pixel sizes each doc-<name>.imageset carries (mac idiom, 1x and 2x).  The .icns files
# hold the full 16..1024 pyramid; the image sets exist for in-app use (Options > System rows,
# sheets) where NSImage scales one representation.
IMAGESET_ROWS = [(1, 256), (2, 512)]

# The label each format badge carries.  Upstream draws the format name in a 2px-stroke pixel
# font inside a 12x8 box, so it truncates to two glyphs ("AP" for apfs, "Sq" for squashfs,
# "01" for split).  macOS has room, so the label is the full format name; index 9 keeps the
# upstream "001" rather than the file name "split" because that is the extension it serves.
BADGE_LABELS = {
    0: "7Z", 1: "ZIP", 2: "BZ2", 3: "RAR", 4: "ARJ", 5: "Z", 6: "LZH", 7: "CAB", 8: "ISO",
    9: "001", 10: "RPM", 11: "DEB", 12: "CPIO", 13: "TAR", 14: "GZ", 15: "WIM", 16: "LZMA",
    17: "DMG", 18: "HFS", 19: "XAR", 20: "VHD", 21: "FAT", 22: "NTFS", 23: "XZ",
    24: "SQUASHFS", 25: "APFS", 26: "ZST",
}

# The shared "archive body" colours every one of the 27 upstream format icons paints the yellow
# sheet with (verified identical across all 27 by --dump).  Everything *else* in an icon is that
# format's badge colour, which is how :func:`badge_colour` finds it.
BODY_PALETTE = {
    "fill":    (0xFF, 0xFF, 0x99),  # manila sheet
    "speckle": (0xFF, 0xCC, 0x99),  # 1px dither speckles over the sheet
    "edge":    (0xCC, 0xCC, 0x66),  # sheet highlight / lid edge
    "border":  (0x99, 0x99, 0x00),  # sheet outline
    "shadow":  (0x33, 0x33, 0x00),  # drop shadow
    "white":   (0xFF, 0xFF, 0xFF),  # badge inner plate
    "black":   (0x0C, 0x0C, 0x0C),  # 3px anti-alias crumb on the lid
    "paper":   (0xFF, 0xFB, 0xF0),  # 1px anti-alias crumb on the lid
}


# --------------------------------------------------------------------------------------------
# Minimal PNG writer (no Pillow on this machine, and none may be installed)
# --------------------------------------------------------------------------------------------

def write_png(path: str, width: int, height: int, rgba: bytes) -> None:
    """Write 8-bit RGBA `rgba` (top-down, width*height*4 bytes) as a non-interlaced PNG."""
    assert len(rgba) == width * height * 4, (len(rgba), width, height)
    stride = width * 4
    # Filter type 0 (None) per scanline keeps the writer trivial; zlib still compresses the
    # flat colour fields of these icons down to a few kB.
    raw = b"".join(b"\x00" + rgba[y * stride:(y + 1) * stride] for y in range(height))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)  # 8bpc, colour type 6 = RGBA
    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", ihdr))
        fh.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        fh.write(chunk(b"IEND", b""))


def read_png_rgba(path: str) -> tuple[int, int, bytes]:
    """Read a non-interlaced 8-bit PNG back to (w, h, RGBA).  Used only by --verify.

    Handles colour types 6 (RGBA), 2 (RGB) and 0 (grey) with all five filter types, which covers
    everything CoreGraphics and this writer emit.
    """
    data = open(path, "rb").read()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path}: not a PNG")
    pos, idat, w = 8, [], 0
    h = bitdepth = colour = interlace = 0
    while pos < len(data):
        (length,) = struct.unpack_from(">I", data, pos)
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            w, h, bitdepth, colour, _comp, _filt, interlace = struct.unpack(">IIBBBBB", body)
        elif tag == b"IDAT":
            idat.append(body)
        elif tag == b"IEND":
            break
        pos += 12 + length
    if bitdepth != 8 or interlace != 0:
        raise ValueError(f"{path}: unsupported bitdepth={bitdepth} interlace={interlace}")
    nch = {0: 1, 2: 3, 6: 4}.get(colour)
    if nch is None:
        raise ValueError(f"{path}: unsupported colour type {colour}")
    raw = zlib.decompress(b"".join(idat))
    stride = w * nch
    out = bytearray(w * h * 4)
    prev = bytearray(stride)
    p = 0
    for y in range(h):
        ftype = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        for i in range(stride):
            a = line[i - nch] if i >= nch else 0
            b = prev[i]
            c = prev[i - nch] if i >= nch else 0
            if ftype == 1:
                line[i] = (line[i] + a) & 0xFF
            elif ftype == 2:
                line[i] = (line[i] + b) & 0xFF
            elif ftype == 3:
                line[i] = (line[i] + ((a + b) >> 1)) & 0xFF
            elif ftype == 4:
                pa, pb, pc = abs(b - c), abs(a - c), abs(a + b - 2 * c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 0xFF
        for x in range(w):
            o = (y * w + x) * 4
            if nch == 4:
                out[o:o + 4] = line[x * 4:x * 4 + 4]
            elif nch == 3:
                out[o:o + 3] = line[x * 3:x * 3 + 3]
                out[o + 3] = 255
            else:
                g = line[x]
                out[o:o + 4] = bytes((g, g, g, 255))
        prev = line
    return w, h, bytes(out)


# --------------------------------------------------------------------------------------------
# Windows .ico decoding
# --------------------------------------------------------------------------------------------

class Frame:
    """One decoded .ico image: RGBA pixels, top-down."""

    def __init__(self, width: int, height: int, rgba: bytes, encoding: str, bpp: int):
        self.width, self.height, self.rgba = width, height, rgba
        self.encoding, self.bpp = encoding, bpp

    def pixel(self, x: int, y: int) -> tuple[int, int, int, int]:
        o = (y * self.width + x) * 4
        return tuple(self.rgba[o:o + 4])  # type: ignore[return-value]

    def __repr__(self) -> str:
        return f"<Frame {self.width}x{self.height} {self.encoding}{self.bpp}>"


def ico_frames(path: str) -> list[Frame]:
    """Decode every image in a Windows .ico.

    Layout: ICONDIR {reserved u16, type u16 (1 = icon), count u16} followed by `count`
    ICONDIRENTRY {w u8, h u8, colourCount u8, reserved u8, planes u16, bitCount u16,
    bytesInRes u32, imageOffset u32}.  A width/height byte of 0 means 256.  The directory's
    `bitCount` is advisory (7-Zip's icons leave it 0), so the real depth comes from the payload.
    """
    data = open(path, "rb").read()
    reserved, kind, count = struct.unpack_from("<HHH", data, 0)
    if reserved != 0 or kind not in (1, 2):
        raise ValueError(f"{path}: not an .ico (reserved={reserved} type={kind})")
    frames = []
    for i in range(count):
        w, h, _ncol, _rsv, _planes, _bpp, nbytes, offset = struct.unpack_from("<BBBBHHII", data, 6 + 16 * i)
        w, h = (w or 256), (h or 256)
        blob = data[offset:offset + nbytes]
        if blob[:8] == b"\x89PNG\r\n\x1a\n":
            # Vista+ icons may store a whole PNG per frame.  None of 7-Zip 26.03's icons do,
            # but handle it so the converter is correct rather than merely sufficient.
            pw, ph, rgba = read_png_rgba_bytes(blob)
            frames.append(Frame(pw, ph, rgba, "PNG", 32))
        else:
            frames.append(decode_bmp_frame(blob, path))
    return frames


def read_png_rgba_bytes(blob: bytes) -> tuple[int, int, bytes]:
    tmp = os.path.join(os.environ.get("TMPDIR", "/tmp"), "ico-frame-%d.png" % os.getpid())
    with open(tmp, "wb") as fh:
        fh.write(blob)
    try:
        return read_png_rgba(tmp)
    finally:
        os.unlink(tmp)


def decode_bmp_frame(blob: bytes, path: str) -> Frame:
    """Decode a BMP-encoded .ico frame ("DIB": BITMAPINFOHEADER + palette + XOR rows + AND mask).

    Notes that matter for correctness:
      * `biHeight` is *twice* the visible height: the XOR (colour) bitmap is followed by the AND
        (transparency) mask.  A frame with no mask at all would have biHeight == height.
      * Both bitmaps are stored bottom-up with rows padded to a 4-byte boundary, and the two use
        different paddings because the mask is always 1bpp.
      * For 32bpp frames the alpha channel is authoritative *if any alpha byte is non-zero*;
        plenty of real-world icons ship 32bpp frames with an all-zero alpha channel, where the
        AND mask is the only transparency information.  All of 7-Zip's frames are 8bpp or 4bpp
        paletted, so the AND mask is what carries their transparency.
    """
    (hsize, bw, bh, _planes, bpp, comp, _imgsize,
     _xppm, _yppm, nclr, _nimp) = struct.unpack_from("<IiiHHIIiiII", blob, 0)
    if hsize < 40:
        raise ValueError(f"{path}: BITMAPCOREHEADER frames are not supported (hsize={hsize})")
    if comp != 0:
        raise ValueError(f"{path}: compressed DIB frame (biCompression={comp})")
    # An .ico DIB stores XOR rows then the AND mask, so biHeight is twice the visible height.
    # An odd biHeight can only mean "no mask" (a .cur/.ico variant), so take it at face value.
    height = bh // 2 if bh % 2 == 0 else bh
    has_mask = bh == height * 2

    ncolors = nclr if nclr else (1 << bpp if bpp <= 8 else 0)
    pal_off = hsize
    palette = []
    for i in range(ncolors):
        b, g, r, _a = blob[pal_off + 4 * i: pal_off + 4 * i + 4]
        palette.append((r, g, b))

    xor_off = pal_off + 4 * ncolors
    xor_stride = ((bw * bpp + 31) // 32) * 4
    mask_off = xor_off + xor_stride * height
    mask_stride = ((bw + 31) // 32) * 4

    # For 32bpp, decide once whether the embedded alpha channel is real.
    alpha_is_real = False
    if bpp == 32:
        alpha_is_real = any(blob[xor_off + 4 * i + 3] for i in range(bw * height))

    rgba = bytearray(bw * height * 4)
    for y in range(height):
        src_y = height - 1 - y                      # rows are bottom-up
        ro = xor_off + xor_stride * src_y
        mo = mask_off + mask_stride * src_y
        for x in range(bw):
            alpha = 255
            if bpp == 32:
                b, g, r, a = blob[ro + 4 * x: ro + 4 * x + 4]
                if alpha_is_real:
                    alpha = a
            elif bpp == 24:
                b, g, r = blob[ro + 3 * x: ro + 3 * x + 3]
            elif bpp == 8:
                r, g, b = palette[blob[ro + x]]
            elif bpp == 4:
                byte = blob[ro + (x >> 1)]
                r, g, b = palette[(byte >> 4) if (x & 1) == 0 else (byte & 0x0F)]
            elif bpp == 1:
                bit = (blob[ro + (x >> 3)] >> (7 - (x & 7))) & 1
                r, g, b = palette[bit]
            else:
                raise ValueError(f"{path}: unsupported {bpp}bpp frame")
            if has_mask and not (bpp == 32 and alpha_is_real):
                # AND mask: 1 = transparent (the XOR colour is ANDed with the screen).
                if (blob[mo + (x >> 3)] >> (7 - (x & 7))) & 1:
                    alpha = 0
            o = (y * bw + x) * 4
            rgba[o:o + 4] = bytes((r, g, b, alpha))
    return Frame(bw, height, bytes(rgba), "BMP", bpp)


def best_frame(frames: list[Frame]) -> Frame:
    """Pick the frame to derive colours from: biggest, and deepest at equal size."""
    return max(frames, key=lambda f: (f.width * f.height, f.bpp))


def badge_colour(frame: Frame) -> tuple[int, int, int]:
    """The format's badge colour: the most common colour that is not part of the shared body."""
    body = set(BODY_PALETTE.values())
    counts: Counter = Counter()
    for y in range(frame.height):
        for x in range(frame.width):
            r, g, b, a = frame.pixel(x, y)
            if a and (r, g, b) not in body:
                counts[(r, g, b)] += 1
    if not counts:
        raise ValueError("no badge colour found")
    return counts.most_common(1)[0][0]


# --------------------------------------------------------------------------------------------
# Upstream tables
# --------------------------------------------------------------------------------------------

def parse_resource_rc(repo: str) -> tuple[dict[int, str], list[tuple[str, int]]]:
    """(index -> icon file stem, [(ext, index)]) from CPP/7zip/Bundles/Format7zF/resource.rc."""
    text = open(os.path.join(repo, "CPP/7zip/Bundles/Format7zF/resource.rc")).read()
    icons = {int(i): os.path.splitext(os.path.basename(p))[0]
             for i, p in re.findall(r'^\s*(\d+)\s+ICON\s+"([^"]+)"', text, re.M)}
    m = re.search(r'^\s*100\s+"([^"]+)"', text, re.M)
    if not m:
        raise ValueError("resource.rc: STRINGTABLE 100 not found")
    pairs = [(e, int(i)) for e, i in (p.split(":") for p in m.group(1).split())]
    return icons, pairs


def parse_file_types(repo: str) -> list[tuple[str, int, str]]:
    """[(ext, iconIndex, format)] from the `options` scope's Mac/App/Support/FileTypes.swift."""
    text = open(os.path.join(repo, "Mac/App/Support/FileTypes.swift")).read()
    rows = re.findall(
        r'SevenZipFileType\(ext:\s*"([^"]+)",\s*iconIndex:\s*(\d+),\s*format:\s*"([^"]+)"\)', text)
    return [(e, int(i), f) for e, i, f in rows]


# --------------------------------------------------------------------------------------------
# Stages
# --------------------------------------------------------------------------------------------

def stage_extract(repo: str, work: str) -> dict:
    """Decode the upstream icons, cross-check the tables, and build the renderer manifest."""
    icons, rc_pairs = parse_resource_rc(repo)
    sw_rows = parse_file_types(repo)

    if [(e, i) for e, i, _ in sw_rows] != rc_pairs:
        raise SystemExit("FileTypes.swift and resource.rc STRINGTABLE 100 disagree:\n"
                         f"  rc   ({len(rc_pairs)}): {rc_pairs}\n"
                         f"  swift({len(sw_rows)}): {[(e, i) for e, i, _ in sw_rows]}")
    print(f"tables agree: {len(rc_pairs)} extensions -> {len(set(i for _, i in rc_pairs))} icons")

    frames_dir = os.path.join(work, "frames")
    os.makedirs(frames_dir, exist_ok=True)

    entries = []
    for index in sorted(icons):
        name = icons[index]
        ico = os.path.join(repo, "CPP/7zip/Archive/Icons", name + ".ico")
        frames = ico_frames(ico)
        out = os.path.join(frames_dir, name)
        os.makedirs(out, exist_ok=True)
        for f in frames:
            write_png(os.path.join(out, f"{f.width}x{f.height}-{f.bpp}bpp.png"),
                      f.width, f.height, f.rgba)
        big = best_frame(frames)
        r, g, b = badge_colour(big)
        exts = [e for e, i, _ in sw_rows if i == index]
        entries.append({
            "index": index,
            "name": name,
            "label": BADGE_LABELS[index],
            "badge": "#%02x%02x%02x" % (r, g, b),
            "extensions": exts,
            "formats": sorted({f for e, i, f in sw_rows if i == index}),
            "source": os.path.relpath(ico, repo),
            "frames": [f"{f.width}x{f.height}/{f.encoding}{f.bpp}" for f in frames],
        })
        print(f"  [{index:2d}] {name:9s} {big.width}x{big.height} {big.encoding}{big.bpp} "
              f"badge={entries[-1]['badge']} label={BADGE_LABELS[index]:8s} exts={','.join(exts)}")

    # The app icon takes its mark from the File Manager's own icon and its colours from 7z.ico.
    fm = ico_frames(os.path.join(repo, "CPP/7zip/UI/FileManager/FM.ico"))
    logo = ico_frames(os.path.join(repo, "CPP/7zip/UI/FileManager/7zipLogo.ico"))
    sfx = ico_frames(os.path.join(repo, "CPP/7zip/Bundles/SFXWin/7z.ico"))
    for label, fs in (("FM", fm), ("7zipLogo", logo), ("SFXWin-7z", sfx)):
        out = os.path.join(frames_dir, label)
        os.makedirs(out, exist_ok=True)
        for f in fs:
            write_png(os.path.join(out, f"{f.width}x{f.height}-{f.bpp}bpp.png"),
                      f.width, f.height, f.rgba)
        print(f"  [--] {label:9s} frames={[f'{f.width}x{f.height}' for f in fs]}")

    # The About box's IDI_LOGO (AboutDialog.rc:10, 21: ICON ... SS_REALSIZEIMAGE) is 7zipLogo.ico
    # at its real size, so the largest frame ships unscaled as AboutLogo.imageset (1x only: a
    # 2x upscale of a 110x63 bitmap would only blur it; AppKit scales the 1x on Retina).
    big = best_frame(logo)
    logo_set = os.path.join(repo, "Mac/Resources/Assets.xcassets/AboutLogo.imageset")
    os.makedirs(logo_set, exist_ok=True)
    write_png(os.path.join(logo_set, "AboutLogo.png"), big.width, big.height, big.rgba)
    write_json(os.path.join(logo_set, "Contents.json"), {
        "images": [{"idiom": "mac", "scale": "1x", "filename": "AboutLogo.png"},
                   {"idiom": "mac", "scale": "2x"}],
        "info": {"version": 1, "author": "xcode"},
    })
    print(f"  [--] AboutLogo {big.width}x{big.height} -> {os.path.relpath(logo_set, repo)}")

    manifest = {
        "note": "generated by Mac/scripts/make-icons.py -- do not edit",
        "pixelSizes": PIXEL_SIZES,
        "body": {k: "#%02x%02x%02x" % v for k, v in BODY_PALETTE.items()},
        "app": {
            # The app icon is FM.ico itself (IDI_ICON in FM.rc), frame by frame: see
            # stage_app_icon.  Nothing about it is drawn.
            "sources": ["CPP/7zip/UI/FileManager/FM.ico"],
            "frames": [f"{f.width}x{f.height}/{f.encoding}{f.bpp}" for f in fm],
        },
        "icons": entries,
    }
    path = os.path.join(work, "icons-manifest.json")
    with open(path, "w") as fh:
        json.dump(manifest, fh, indent=2)
    print(f"wrote {os.path.relpath(path, repo)}")
    return manifest


def stage_draw(repo: str, work: str) -> None:
    """Run the CoreGraphics renderer to produce every PNG at every pixel size."""
    swift = os.path.join(repo, "Mac/scripts/make-icons.swift")
    png_dir = os.path.join(work, "png")
    shutil.rmtree(png_dir, ignore_errors=True)
    os.makedirs(png_dir, exist_ok=True)
    cmd = ["swift", swift, os.path.join(work, "icons-manifest.json"), png_dir]
    print("$ " + " ".join(cmd))
    subprocess.run(cmd, check=True)
    stage_app_icon(repo, work)


def app_icon_frame(frames: list[Frame], px: int) -> Frame:
    """The FM.ico frame nearest to `px` pixels (the larger one on a tie)."""
    return min(frames, key=lambda f: (abs(f.width - px), -f.width))


def scale_nearest(f: Frame, px: int) -> bytes:
    """Nearest-neighbour resample of a square frame to px x px: every output pixel is one source
    pixel, unchanged, so no colour that the .ico does not contain is introduced."""
    out = bytearray(px * px * 4)
    for y in range(px):
        sy = y * f.height // px
        for x in range(px):
            sx = x * f.width // px
            o = (sy * f.width + sx) * 4
            out[(y * px + x) * 4:(y * px + x) * 4 + 4] = f.rgba[o:o + 4]
    return bytes(out)


def stage_app_icon(repo: str, work: str) -> None:
    """The app icon is the original 7zFM icon (winmatch): for each macOS pixel size the nearest
    FM.ico frame (16, 32 or 48 px), resampled nearest-neighbour to fill the whole canvas -- no
    redrawing, no rounded-square mask, no added margin or shadow."""
    fm = ico_frames(os.path.join(repo, "CPP/7zip/UI/FileManager/FM.ico"))
    out_dir = os.path.join(work, "png", "app")
    os.makedirs(out_dir, exist_ok=True)
    used = []
    for px in PIXEL_SIZES:
        f = app_icon_frame(fm, px)
        write_png(os.path.join(out_dir, f"{px}.png"), px, px,
                  f.rgba if f.width == px else scale_nearest(f, px))
        used.append(f"{px}<-{f.width}")
    print("app icon from FM.ico: " + " ".join(used))


def stage_assemble(repo: str, work: str, manifest: dict) -> None:
    """Lay the rendered PNGs out as an asset catalog and as .icns files."""
    png = os.path.join(work, "png")
    catalog = os.path.join(repo, "Mac/Resources/Assets.xcassets")
    icons_dir = os.path.join(repo, "Mac/Resources/Icons")

    # ---- AppIcon.appiconset -------------------------------------------------------------
    appicon = os.path.join(catalog, "AppIcon.appiconset")
    shutil.rmtree(appicon, ignore_errors=True)
    os.makedirs(appicon)
    images = []
    for pt, scale, px in APPICON_ROWS:
        fn = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
        shutil.copyfile(os.path.join(png, "app", f"{px}.png"), os.path.join(appicon, fn))
        images.append({"filename": fn, "idiom": "mac", "scale": f"{scale}x", "size": f"{pt}x{pt}"})
    write_json(os.path.join(appicon, "Contents.json"),
               {"images": images, "info": {"author": "xcode", "version": 1}})
    print(f"AppIcon.appiconset: {len(images)} slots, "
          f"{len(set(px for _, _, px in APPICON_ROWS))} distinct pixel sizes")

    # ---- doc-<name>.imageset ------------------------------------------------------------
    for old in sorted(os.listdir(catalog)):
        if old.startswith("doc-") and old.endswith(".imageset"):
            shutil.rmtree(os.path.join(catalog, old))
    for e in manifest["icons"]:
        name = f"doc-{e['name']}"
        d = os.path.join(catalog, name + ".imageset")
        os.makedirs(d)
        images = []
        for scale, px in IMAGESET_ROWS:
            fn = f"{name}_{px}.png"
            shutil.copyfile(os.path.join(png, "doc", e["name"], f"{px}.png"), os.path.join(d, fn))
            images.append({"filename": fn, "idiom": "mac", "scale": f"{scale}x"})
        write_json(os.path.join(d, "Contents.json"),
                   {"images": images, "info": {"author": "xcode", "version": 1}})
    print(f"image sets: {len(manifest['icons'])} x doc-<name>.imageset")

    # ---- doc-<name>.icns ----------------------------------------------------------------
    shutil.rmtree(icons_dir, ignore_errors=True)
    os.makedirs(icons_dir)
    for e in manifest["icons"]:
        iconset = os.path.join(work, "iconset", f"doc-{e['name']}.iconset")
        shutil.rmtree(iconset, ignore_errors=True)
        os.makedirs(iconset)
        for fn, px in ICONSET_ROWS:
            shutil.copyfile(os.path.join(png, "doc", e["name"], f"{px}.png"),
                            os.path.join(iconset, fn))
        out = os.path.join(icons_dir, f"doc-{e['name']}.icns")
        subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    sizes = sum(os.path.getsize(os.path.join(icons_dir, f)) for f in os.listdir(icons_dir))
    print(f".icns: {len(manifest['icons'])} files in Mac/Resources/Icons ({sizes // 1024} kB)")

    # ---- the mapping table the finder scope needs ----------------------------------------
    rows = []
    for e in manifest["icons"]:
        for ext in e["extensions"]:
            rows.append({"extension": ext, "icon": e["name"], "iconIndex": e["index"],
                         "icns": f"doc-{e['name']}.icns", "imageSet": f"doc-{e['name']}"})
    write_json(os.path.join(work, "extension-map.json"), rows)
    print(f"extension map: {len(rows)} extensions -> {len(manifest['icons'])} icons")


def write_json(path: str, obj) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        json.dump(obj, fh, indent=2)
        fh.write("\n")


def stage_verify(repo: str, work: str, manifest: dict) -> int:
    """Check every emitted PNG: right size, has a real alpha channel, not blank, not a slab."""
    problems = []
    checked = 0
    todo = [(os.path.join(work, "png", "app", f"{px}.png"), px, "app") for px in PIXEL_SIZES]
    for e in manifest["icons"]:
        todo += [(os.path.join(work, "png", "doc", e["name"], f"{px}.png"), px, e["name"])
                 for px in PIXEL_SIZES]
    for path, px, who in todo:
        if not os.path.exists(path):
            problems.append(f"{who} {px}px: missing")
            continue
        w, h, rgba = read_png_rgba(path)
        checked += 1
        if (w, h) != (px, px):
            problems.append(f"{who} {px}px: is {w}x{h}")
        alphas = rgba[3::4]
        transparent = sum(1 for a in alphas if a == 0)
        opaque = sum(1 for a in alphas if a == 255)
        if transparent == 0:
            problems.append(f"{who} {px}px: no transparent pixel -- alpha channel lost")
        if opaque == 0:
            problems.append(f"{who} {px}px: nothing opaque -- blank")
        # Distinct opaque colours: a stretched/blank icon collapses to one or two.
        colours = {rgba[i:i + 3] for i in range(0, len(rgba), 4) if rgba[i + 3] > 200}
        if who == "app":
            # The app icon is FM.ico resampled nearest-neighbour: only the .ico's own colours.
            fm = ico_frames(os.path.join(repo, "CPP/7zip/UI/FileManager/FM.ico"))
            src = {f.rgba[i:i + 3] for f in fm for i in range(0, len(f.rgba), 4) if f.rgba[i + 3] > 200}
            if not colours <= src:
                problems.append(f"app {px}px: colours not in FM.ico: {sorted(colours - src)[:4]}")
        elif px >= 64 and len(colours) < 4:
            problems.append(f"{who} {px}px: only {len(colours)} opaque colours")
        # Corners must be clear: FM.ico's frames and the page both leave them empty.
        for cx, cy in ((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)):
            if rgba[(cy * w + cx) * 4 + 3] > 8:
                problems.append(f"{who} {px}px: corner ({cx},{cy}) is opaque")
                break
    print(f"verified {checked} PNGs")
    for p in problems:
        print("  FAIL " + p)
    return 1 if problems else 0


def stage_contact_sheet(repo: str, work: str) -> None:
    """Ask the renderer for the contact sheet and drop it in the reports directory."""
    out = os.path.join(repo, "Mac/docs/reports/screenshots/icons-contact-sheet.png")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    cmd = ["swift", os.path.join(repo, "Mac/scripts/make-icons.swift"),
           os.path.join(work, "icons-manifest.json"), os.path.join(work, "png"),
           "--contact-sheet", out]
    print("$ " + " ".join(cmd))
    subprocess.run(cmd, check=True)
    print("contact sheet: " + os.path.relpath(out, repo))


# --------------------------------------------------------------------------------------------

def dump(repo: str, name: str) -> None:
    """ASCII-art one upstream icon; how the palette and badge constants above were established."""
    for base in ("CPP/7zip/Archive/Icons/%s.ico" % name,
                 "CPP/7zip/UI/FileManager/%s.ico" % name,
                 "CPP/7zip/Bundles/SFXWin/%s.ico" % name):
        p = os.path.join(repo, base)
        if os.path.exists(p):
            break
    else:
        raise SystemExit(f"no such icon: {name}")
    for f in ico_frames(p):
        print(f"--- {base} {f!r}")
        counts = Counter()
        for y in range(f.height):
            for x in range(f.width):
                r, g, b, a = f.pixel(x, y)
                if a:
                    counts[(r, g, b)] += 1
        keys = [c for c, _ in counts.most_common()]
        syms = "@#%*+=-:.abcdefghijklmnopqrstuvwxyz0123456789"
        sym = {c: syms[i] if i < len(syms) else "?" for i, c in enumerate(keys)}
        for y in range(f.height):
            print("  " + "".join(" " if f.pixel(x, y)[3] == 0 else sym[f.pixel(x, y)[:3]]
                                 for x in range(f.width)))
        for c in keys[:16]:
            print("    %s = #%02x%02x%02x  x%d" % (sym[c], c[0], c[1], c[2], counts[c]))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", default=".", help="repository root")
    ap.add_argument("--work", default=None, help="scratch directory (default Mac/build/icons)")
    ap.add_argument("--stage", default="all",
                    choices=["all", "extract", "draw", "assemble", "verify", "sheet"])
    ap.add_argument("--dump", metavar="NAME", help="ASCII-dump one upstream .ico and exit")
    args = ap.parse_args()

    repo = os.path.abspath(args.repo)
    if args.dump:
        dump(repo, args.dump)
        return 0
    work = os.path.abspath(args.work or os.path.join(repo, "Mac/build/icons"))
    os.makedirs(work, exist_ok=True)

    manifest_path = os.path.join(work, "icons-manifest.json")
    if args.stage in ("all", "extract"):
        manifest = stage_extract(repo, work)
    else:
        manifest = json.load(open(manifest_path))
    if args.stage in ("all", "draw"):
        stage_draw(repo, work)
    if args.stage in ("all", "assemble"):
        stage_assemble(repo, work, manifest)
    if args.stage in ("all", "sheet"):
        stage_contact_sheet(repo, work)
    if args.stage in ("all", "verify"):
        return stage_verify(repo, work, manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
