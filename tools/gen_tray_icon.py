#!/usr/bin/env python3
"""Generate assets/tray/tray_icon.png (22x22 RGBA) without PIL."""
import struct, zlib, os

W = H = 22
px = bytearray(W * H * 4)

def put(x, y):
    if 0 <= x < W and 0 <= y < H:
        i = (y * W + x) * 4
        px[i:i+4] = b"\xff\xff\xff\xff"

def triangle(tip_x, base_x):  # left-pointing triangle
    for x in range(tip_x, base_x + 1):
        half = round(7 * (x - tip_x) / (base_x - tip_x))
        for y in range(11 - half, 11 + half + 1):
            put(x, y)

triangle(2, 10)
triangle(11, 19)

raw = b"".join(b"\x00" + bytes(px[y*W*4:(y+1)*W*4]) for y in range(H))

def chunk(tag, data):
    c = struct.pack(">I", len(data)) + tag + data
    return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

png = (b"\x89PNG\r\n\x1a\n"
       + chunk(b"IHDR", struct.pack(">IIBBBBB", W, H, 8, 6, 0, 0, 0))
       + chunk(b"IDAT", zlib.compress(raw))
       + chunk(b"IEND", b""))

out = os.path.join(os.path.dirname(__file__), "..", "assets", "tray", "tray_icon.png")
os.makedirs(os.path.dirname(out), exist_ok=True)
with open(out, "wb") as f:
    f.write(png)
print("wrote", out)
