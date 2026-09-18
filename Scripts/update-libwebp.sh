#!/usr/bin/env bash
# Re-vendor upstream libwebp into Sources/CWebP at a pinned tag. The C target compiles src/ + sharpyuv/
# verbatim; the public headers are copied to include/webp so SwiftPM can generate the module map.
# After running: update THIRD-PARTY-NOTICES.txt's tag/commit line, rebuild, run the tests, and check
# `swift build` still reports zero assembly files (libwebp has never shipped any; if that changes, the
# from-source target stops being the whole story).
set -euo pipefail
TAG="${1:-v1.6.0}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"
DST="$HERE/Sources/CWebP"
TMP="$(mktemp -d)"
git clone --quiet --depth 1 --branch "$TAG" https://github.com/webmproject/libwebp.git "$TMP/libwebp"
COMMIT="$(git -C "$TMP/libwebp" rev-parse --short HEAD)"
rm -rf "$DST"; mkdir -p "$DST/include/webp"
cp -R "$TMP/libwebp/src" "$DST/src"
cp -R "$TMP/libwebp/sharpyuv" "$DST/sharpyuv"
cp "$TMP/libwebp/src/webp/"*.h "$DST/include/webp/"
find "$DST" \( -name 'Makefile.am' -o -name '*.rc' -o -name '*.in' \) -delete
{ echo "libwebp — vendored as source in Sources/CWebP (encoder + decoder + sharpyuv, $TAG)"
  echo "Source: https://github.com/webmproject/libwebp (tag $TAG, commit $COMMIT)"
  echo "Re-vendored by Scripts/update-libwebp.sh"
  echo
  echo "The BSD-3-Clause licence and the WebM PATENTS grant below cover encoding as well as decoding"
  echo "(\"make, have made, use, offer to sell, sell, import, transfer\"), so shipping the encoder raises no"
  echo "new licence or patent question. Both texts must accompany any binary that links this package."
  echo; echo "=================================================================== COPYING"; cat "$TMP/libwebp/COPYING"
  echo; echo "=================================================================== PATENTS"; cat "$TMP/libwebp/PATENTS"; } > "$HERE/THIRD-PARTY-NOTICES.txt"
rm -rf "$TMP"
echo "libwebp $TAG ($COMMIT) → $DST: $(find "$DST/src" "$DST/sharpyuv" -name '*.c' | wc -l | tr -d ' ') C files, $(find "$DST" -name '*.s' -o -name '*.S' -o -name '*.asm' | wc -l | tr -d ' ') assembly files"
