#!/usr/bin/env python3
"""Inspect a raw f32 grid dump (--dump-grid).

Prints the Tier-B tolerance metrics from SPEC-1 section 7.2 and, with --png,
writes a greyscale preview so you can eyeball whether the simulation actually
produced a Physarum network rather than noise or a dead grid.
"""

from __future__ import annotations

import argparse
import math
import pathlib
import struct
import sys


def load(path: pathlib.Path, width: int, height: int) -> list[float]:
    raw = path.read_bytes()
    want = width * height * 4
    if len(raw) != want:
        sys.exit(f"error: {path} is {len(raw)} bytes, expected {want} for {width}x{height}")
    return list(struct.unpack(f"<{width * height}f", raw))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dump", type=pathlib.Path)
    ap.add_argument("--width", type=int, required=True)
    ap.add_argument("--height", type=int, required=True)
    ap.add_argument("--png", type=pathlib.Path, help="write a greyscale PNG preview")
    ap.add_argument("--display-max", type=float, default=100.0)
    a = ap.parse_args()

    g = load(a.dump, a.width, a.height)
    n = len(g)
    total = math.fsum(g)
    mean = total / n
    var = math.fsum((v - mean) ** 2 for v in g) / n
    above1 = sum(1 for v in g if v > 1.0) / n

    print(f"cells        {n}")
    print(f"sum          {total:.6e}")
    print(f"mean         {mean:.6f}")
    print(f"stddev       {math.sqrt(var):.6f}")
    print(f"min / max    {min(g):.4f} / {max(g):.4f}")
    print(f"frac > 1.0   {above1:.6f}")
    if not math.isfinite(total):
        print("WARNING: non-finite values in grid")

    if a.png:
        write_png(a.png, g, a.width, a.height, a.display_max)
        print(f"wrote {a.png}")
    return 0


def write_png(path: pathlib.Path, g, w: int, h: int, dmax: float) -> None:
    """Minimal greyscale PNG writer -- no third-party dependency."""
    import binascii
    import zlib

    scale = 255.0 / dmax
    rows = bytearray()
    for y in range(h):
        rows.append(0)  # filter type 0
        base = y * w
        rows.extend(min(255, max(0, int(g[base + x] * scale))) for x in range(w))

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data +
                struct.pack(">I", binascii.crc32(tag + data) & 0xFFFFFFFF))

    png = (b"\x89PNG\r\n\x1a\n"
           + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 0, 0, 0, 0))
           + chunk(b"IDAT", zlib.compress(bytes(rows), 6))
           + chunk(b"IEND", b""))
    path.write_bytes(png)


if __name__ == "__main__":
    sys.exit(main())
