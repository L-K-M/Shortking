#!/usr/bin/env bash
# Regenerates Resources/AppIcon.icns from the 1024x1024 master Resources/AppIcon.png.
#
# The .icns is checked in so `make app` never needs image tooling; run this only
# when the icon artwork changes. (Resources/AppIcon.svg is the vector source —
# re-render it to AppIcon.png first if that's what changed.)
#
# On macOS this uses sips + iconutil, the canonical pipeline. Elsewhere it falls
# back to scripts/png2icns.py, which needs python3 + Pillow.
#
# Usage: scripts/make-icns.sh
set -euo pipefail

cd "$(dirname "$0")/.."

MASTER="Resources/AppIcon.png"
OUT="Resources/AppIcon.icns"

[ -f "$MASTER" ] || { echo "!! missing $MASTER" >&2; exit 1; }

if command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
  TMPDIR_ICONSET="$(mktemp -d)"
  trap 'rm -rf "$TMPDIR_ICONSET"' EXIT
  ICONSET="$TMPDIR_ICONSET/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for px in 16 32 128 256 512; do
    sips -z "$px" "$px" "$MASTER" --out "$ICONSET/icon_${px}x${px}.png" >/dev/null
    px2=$((px * 2))
    sips -z "$px2" "$px2" "$MASTER" --out "$ICONSET/icon_${px}x${px}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$OUT"
  echo "wrote $OUT (iconutil)"
else
  python3 scripts/png2icns.py "$MASTER" "$OUT"
fi
