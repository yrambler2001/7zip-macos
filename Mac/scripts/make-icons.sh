#!/bin/sh
# make-icons.sh -- regenerate every icon asset of 7-Zip.app from the upstream Windows resources.
#
# The assets under Mac/Resources/Assets.xcassets and Mac/Resources/Icons are *generated*, never
# hand-edited: run this after touching the generator or the association table and commit the
# result.  See ai/api/icons.md for the naming scheme and the extension -> icon mapping.
#
#   Mac/scripts/make-icons.sh                 extract, draw, assemble, contact sheet, verify
#                                             ("draw" draws nothing: it enlarges .ico frames
#                                             nearest-neighbour by integer factors)
#   Mac/scripts/make-icons.sh --stage draw    one stage only (extract|draw|assemble|sheet|verify)
#   Mac/scripts/make-icons.sh --dump 7z       ASCII-dump one upstream .ico
#
# Inputs  (read-only, never modified):
#   CPP/7zip/Archive/Icons/*.ico              27 per-format icons
#   CPP/7zip/UI/FileManager/FM.ico            the File Manager's own icon (the "7z" mark)
#   CPP/7zip/UI/FileManager/7zipLogo.ico      the About-box wordmark
#   CPP/7zip/Bundles/SFXWin/7z.ico            the SFX stub icon
#   CPP/7zip/Bundles/Format7zF/resource.rc    index -> .ico and the ext:index association string
#   Mac/App/Support/FileTypes.swift           the port's authoritative association table
#
# Outputs:
#   Mac/Resources/Assets.xcassets/AppIcon.appiconset/      10 slots, 7 distinct pixel sizes
#   Mac/Resources/Assets.xcassets/doc-<name>.imageset/      27 image sets (mac 1x/2x)
#   Mac/Resources/Icons/doc-<name>.icns                     27 format .icns + doc-fm.icns, 16..1024;
#                                                           the verify stage fails unless every size
#                                                           is an .ico frame enlarged x1..x32
#   Mac/build/screenshots/icons-contact-sheet.png    every icon at 128pt on a checkerboard
#   Mac/build/icons/                                        scratch: decoded frames, manifest, PNGs
set -eu

REPO=$(cd "$(dirname "$0")/../.." && pwd)
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app}

# `swift` (for make-icons.swift) needs a usable DEVELOPER_DIR; nothing else here does.
if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "make-icons.sh: DEVELOPER_DIR=$DEVELOPER_DIR does not exist" >&2
  exit 1
fi

echo "== make-icons: repo $REPO"
python3 "$REPO/Mac/scripts/make-icons.py" --repo "$REPO" "$@"
