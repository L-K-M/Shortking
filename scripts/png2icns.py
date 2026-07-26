#!/usr/bin/env python3
"""Build an .icns from a square 1024x1024 master PNG, no macOS tools needed.

This is the cross-platform fallback used by scripts/make-icns.sh when
iconutil/sips are unavailable (e.g. Linux CI). It downscales the master with
Lanczos and packs the standard icon-family chunks, PNG-encoded — the same
layout iconutil produces from a .iconset.

Usage: scripts/png2icns.py <master.png> <out.icns>
Requires: Pillow (pip install pillow)
"""
import io
import struct
import sys

from PIL import Image

# (OSType, pixel size) — the full set iconutil emits for a modern app icon.
ICON_TYPES = [
    (b"icp4", 16),
    (b"icp5", 32),
    (b"ic11", 32),    # 16pt @2x
    (b"ic12", 64),    # 32pt @2x
    (b"ic07", 128),
    (b"ic13", 256),   # 128pt @2x
    (b"ic08", 256),
    (b"ic14", 512),   # 256pt @2x
    (b"ic09", 512),
    (b"ic10", 1024),  # 512pt @2x
]


def main(src: str, dst: str) -> None:
    master = Image.open(src).convert("RGBA")
    if master.size != (1024, 1024):
        sys.exit(f"error: master must be 1024x1024, got {master.size}")

    chunks = b""
    for ostype, px in ICON_TYPES:
        img = master if px == 1024 else master.resize((px, px), Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, format="PNG")
        data = buf.getvalue()
        chunks += ostype + struct.pack(">I", len(data) + 8) + data

    with open(dst, "wb") as f:
        f.write(b"icns" + struct.pack(">I", len(chunks) + 8) + chunks)
    print(f"wrote {dst} ({(len(chunks) + 8) / 1024:.0f} KiB)")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__.strip())
    main(sys.argv[1], sys.argv[2])
