#!/usr/bin/env bash
# make-fixtures.sh -- create the tiny test archives in Mac/Tests/Fixtures with the
# console 7zz built from this tree (or SEVENZZ=/path/to/7zz).
# Fixtures (all built from the same 4-file tree, deterministic content):
#   test.7z            7z, LZMA2, solid
#   test.zip           zip, Deflate
#   test.tar.gz        gzip over tar
#   test.tar.xz        xz over tar
#   secret.7z          7z with encrypted headers (-mhe=on), password "secret"
#   secret.zip         zip with ZipCrypto-encrypted entries, password "secret"
#   nested.zip         zip containing test.7z and test.tar.gz (archive inside archive)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SEVENZZ="${SEVENZZ:-$ROOT/CPP/7zip/Bundles/Alone2/b/m_arm64/7zz}"
if [ ! -x "$SEVENZZ" ]; then
  SEVENZZ="$HOME/things/a.noindex/7zip/CPP/7zip/Bundles/Alone2/b/m_arm64/7zz"
fi
if [ ! -x "$SEVENZZ" ]; then
  echo "7zz not found; build it with: cd CPP/7zip/Bundles/Alone2 && DEVELOPER_DIR=/Applications/Xcode.app make -j8 -f ../../cmpl_mac_arm64.mak" >&2
  exit 1
fi
OUT="$ROOT/Mac/Tests/Fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$OUT" "$WORK/src/sub/deep"
printf 'hello 7-zip\n' > "$WORK/src/readme.txt"
printf '%s\n' "line 1" "line 2" "line 3" > "$WORK/src/notes.md"
head -c 3000 /dev/zero | tr '\0' 'A' > "$WORK/src/sub/big.txt"
printf 'deep file\n' > "$WORK/src/sub/deep/inner.txt"
# fixed timestamps so the archives are reproducible
find "$WORK/src" -exec touch -t 202401021530.00 {} +
rm -f "$OUT"/*.7z "$OUT"/*.zip "$OUT"/*.tar.gz "$OUT"/*.tar.xz "$OUT"/*.tar
cd "$WORK/src"
Z="$SEVENZZ"
$Z a -bd -bso0 -t7z  -mx=5 "$OUT/test.7z"  readme.txt notes.md sub
$Z a -bd -bso0 -tzip -mx=5 "$OUT/test.zip" readme.txt notes.md sub
$Z a -bd -bso0 -ttar "$WORK/test.tar" readme.txt notes.md sub
$Z a -bd -bso0 -tgzip "$OUT/test.tar.gz" "$WORK/test.tar"
$Z a -bd -bso0 -txz   "$OUT/test.tar.xz" "$WORK/test.tar"
$Z a -bd -bso0 -t7z  -psecret -mhe=on "$OUT/secret.7z"  readme.txt notes.md sub
$Z a -bd -bso0 -tzip -psecret         "$OUT/secret.zip" readme.txt notes.md sub
cd "$OUT"
$Z a -bd -bso0 -tzip -mx=0 "$OUT/nested.zip" test.7z test.tar.gz
ls -la "$OUT"
