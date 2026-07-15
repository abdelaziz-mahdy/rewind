#!/usr/bin/env python3
"""Generate the Rewind app icon (macOS AppIcon.appiconset PNGs, Windows
app_icon.ico, and a monochrome Windows tray .ico) with pure per-pixel SDF
rendering. No design tools, no third-party deps -- python3 stdlib only
(struct/zlib/math), same pattern as tools/gen_tray_icon.py.

Design: a dark rounded-square plate (#0E1114 with a subtle radial lift
toward #1E242C near the center) holding a bold two-triangle "rewind" glyph
in accent mint (#3DDC97) with a soft glow. Rendered once at 1024x1024 with
per-pixel signed-distance-field math, then box-filter downscaled (via a
premultiplied-alpha mip chain, so transparent edges don't fringe dark) to
every required size.
"""
import math
import os
import struct
import sys
import zlib

MASTER = 1024

BACKGROUND = (14.0, 17.0, 20.0)   # #0E1114
LIFT = (30.0, 36.0, 44.0)         # #1E242C
ACCENT = (61.0, 220.0, 151.0)     # #3DDC97
RECORD = (255.0, 84.0, 112.0)     # #FF5470
WHITE = (255.0, 255.0, 255.0)


# ---------------------------------------------------------------------------
# Math helpers
# ---------------------------------------------------------------------------

def clamp(x, lo, hi):
    return lo if x < lo else (hi if x > hi else x)


def smoothstep(edge0, edge1, x):
    if edge0 == edge1:
        return 0.0 if x < edge0 else 1.0
    t = clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def lerp_color(c0, c1, t):
    return (c0[0] + (c1[0] - c0[0]) * t,
            c0[1] + (c1[1] - c0[1]) * t,
            c0[2] + (c1[2] - c0[2]) * t)


def sd_round_box(px, py, hx, hy, r):
    qx = abs(px) - (hx - r)
    qy = abs(py) - (hy - r)
    ax = qx if qx > 0.0 else 0.0
    ay = qy if qy > 0.0 else 0.0
    outside = math.hypot(ax, ay)
    inside = min(max(qx, qy), 0.0)
    return outside + inside - r


def sd_polygon(px, py, verts):
    """Exact signed distance to a simple polygon (negative = inside).

    Port of Inigo Quilez's sdPolygon: per-edge closest-point distance plus
    a winding-number sign test, so it works for our (convex) triangles
    without needing a separate point-in-triangle test.
    """
    n = len(verts)
    vx0, vy0 = verts[0]
    d = (px - vx0) ** 2 + (py - vy0) ** 2
    s = 1.0
    j = n - 1
    for i in range(n):
        vix, viy = verts[i]
        vjx, vjy = verts[j]
        ex, ey = vjx - vix, vjy - viy
        wx, wy = px - vix, py - viy
        dot_ee = ex * ex + ey * ey
        t = (wx * ex + wy * ey) / dot_ee if dot_ee > 0.0 else 0.0
        t = clamp(t, 0.0, 1.0)
        bx, by = wx - ex * t, wy - ey * t
        dd = bx * bx + by * by
        if dd < d:
            d = dd
        c1 = py >= viy
        c2 = py < vjy
        c3 = (ex * wy) > (ey * wx)
        if (c1 and c2 and c3) or (not c1 and not c2 and not c3):
            s = -s
        j = i
    return s * math.sqrt(d)


def over(base_rgb, base_a, top_rgb, top_a):
    """Standard "over" alpha compositing (straight, non-premultiplied)."""
    out_a = top_a + base_a * (1.0 - top_a)
    if out_a <= 1e-6:
        return (0.0, 0.0, 0.0), 0.0
    inv = 1.0 - top_a
    out_r = (top_rgb[0] * top_a + base_rgb[0] * base_a * inv) / out_a
    out_g = (top_rgb[1] * top_a + base_rgb[1] * base_a * inv) / out_a
    out_b = (top_rgb[2] * top_a + base_rgb[2] * base_a * inv) / out_a
    return (out_r, out_g, out_b), out_a


def glyph_coverage(dist, glow_sigma, glow_intensity, hard_feather=1.2):
    """Combine a crisp shape edge with a soft outer glow into one alpha,
    since both layers share the same color -- avoids a second `over` call.
    """
    hard = 1.0 - smoothstep(-hard_feather, hard_feather, dist)
    outside = dist if dist > 0.0 else 0.0
    glow = glow_intensity * math.exp(-(outside * outside) / (2.0 * glow_sigma * glow_sigma))
    return clamp(hard + glow * (1.0 - hard), 0.0, 1.0)


# ---------------------------------------------------------------------------
# Master renderers
# ---------------------------------------------------------------------------

def render_app_icon_master():
    """1024x1024 RGBA8 app-icon plate + glyph + recording dot."""
    s = MASTER
    cx = cy = s / 2.0
    margin = 32.0
    half = s / 2.0 - margin          # 480
    corner_r = 214.0

    # All glyph/dot geometry below is defined in the same *center-relative*
    # coordinate space as the `px, py` used in the render loop (px = x -
    # cx, py = y - cy) -- NOT absolute canvas coordinates. Mixing the two
    # would silently miscompare every SDF test.
    half_h = 240.0
    tri_w = 300.0
    gap = 40.0
    total_w = 2 * tri_w + gap
    left_x = -total_w / 2.0
    tri1_base_x = left_x + tri_w
    tri2_tip_x = tri1_base_x + gap
    tri2_base_x = tri2_tip_x + tri_w
    tri1 = [(left_x, 0.0), (tri1_base_x, -half_h), (tri1_base_x, half_h)]
    tri2 = [(tri2_tip_x, 0.0), (tri2_base_x, -half_h), (tri2_base_x, half_h)]

    glyph_glow_sigma, glyph_glow_intensity = 46.0, 0.55

    dot_cx, dot_cy, dot_r = half - 140.0, -(half - 140.0), 58.0
    dot_glow_sigma, dot_glow_intensity = 26.0, 0.5

    buf = bytearray(s * s * 4)
    for y in range(s):
        py = (y + 0.5) - cy
        row_off = y * s * 4
        for x in range(s):
            px = (x + 0.5) - cx
            idx = row_off + x * 4

            dplate = sd_round_box(px, py, half, half, corner_r)
            if dplate > 3.0:
                # Fully transparent outside the rounded plate -- skip the
                # glyph/dot math for this pixel entirely.
                idx4 = idx + 4
                buf[idx:idx4] = b"\x00\x00\x00\x00"
                continue
            plate_a = 1.0 - smoothstep(-1.5, 1.5, dplate)

            dist_c = math.hypot(px, py)
            t = clamp(dist_c / half, 0.0, 1.0)
            col = lerp_color(LIFT, BACKGROUND, t)
            a = plate_a

            dglyph = min(sd_polygon(px, py, tri1), sd_polygon(px, py, tri2))
            glyph_a = glyph_coverage(dglyph, glyph_glow_sigma, glyph_glow_intensity)
            col, a = over(col, a, ACCENT, glyph_a * plate_a)

            # (The red "recording" dot was removed — as an app-icon badge it
            #  just read as an unread-notification mark, not a feature.)

            buf[idx] = int(round(clamp(col[0], 0.0, 255.0)))
            buf[idx + 1] = int(round(clamp(col[1], 0.0, 255.0)))
            buf[idx + 2] = int(round(clamp(col[2], 0.0, 255.0)))
            buf[idx + 3] = int(round(clamp(a, 0.0, 1.0) * 255.0))
        if y % 128 == 0:
            print(f"  app icon: row {y}/{s}", file=sys.stderr)
    return buf


def render_tray_master(size=256):
    """size x size RGBA8: white two-triangle glyph, transparent background.
    Monochrome-friendly (no glow/gradient) so it stays crisp at 16-32px.
    """
    s = float(size)
    scale = s / 22.0  # matches the proportions of tools/gen_tray_icon.py
    cy = s / 2.0

    def tri(tip_x, base_x):
        half_h = 7.0 * scale
        return [(tip_x, cy), (base_x, cy - half_h), (base_x, cy + half_h)]

    tri1 = tri(2.0 * scale, 10.0 * scale)
    tri2 = tri(11.0 * scale, 19.0 * scale)

    buf = bytearray(size * size * 4)
    for y in range(size):
        py = y + 0.5
        row_off = y * size * 4
        for x in range(size):
            px = x + 0.5
            idx = row_off + x * 4
            dglyph = min(sd_polygon(px, py, tri1), sd_polygon(px, py, tri2))
            a = 1.0 - smoothstep(-1.0, 1.0, dglyph)
            if a <= 0.0:
                continue
            av = int(round(clamp(a, 0.0, 1.0) * 255.0))
            buf[idx] = 255
            buf[idx + 1] = 255
            buf[idx + 2] = 255
            buf[idx + 3] = av
    return buf


# ---------------------------------------------------------------------------
# Downscaling (premultiplied-alpha box filter)
# ---------------------------------------------------------------------------

def fast_half(src, w, h):
    """Exact 2x2 box-filter downscale (premultiplied-alpha averaged, so
    transparent neighbours don't drag color toward black at edges)."""
    nw, nh = w // 2, h // 2
    dst = bytearray(nw * nh * 4)
    for y in range(nh):
        srow0 = (2 * y) * w * 4
        srow1 = (2 * y + 1) * w * 4
        drow = y * nw * 4
        for x in range(nw):
            i00 = srow0 + (2 * x) * 4
            i01 = srow0 + (2 * x + 1) * 4
            i10 = srow1 + (2 * x) * 4
            i11 = srow1 + (2 * x + 1) * 4
            a00, a01, a10, a11 = src[i00 + 3], src[i01 + 3], src[i10 + 3], src[i11 + 3]
            asum = a00 + a01 + a10 + a11
            if asum > 0:
                r = (src[i00] * a00 + src[i01] * a01 + src[i10] * a10 + src[i11] * a11) / asum
                g = (src[i00 + 1] * a00 + src[i01 + 1] * a01 + src[i10 + 1] * a10 + src[i11 + 1] * a11) / asum
                b = (src[i00 + 2] * a00 + src[i01 + 2] * a01 + src[i10 + 2] * a10 + src[i11 + 2] * a11) / asum
            else:
                r = g = b = 0.0
            di = drow + x * 4
            dst[di] = int(round(r))
            dst[di + 1] = int(round(g))
            dst[di + 2] = int(round(b))
            dst[di + 3] = int(round(asum / 4.0))
    return dst, nw, nh


def general_downscale(src, sw, sh, dw, dh):
    """Fractional-ratio box-filter downscale (area-weighted, premultiplied
    alpha) for target sizes that aren't a clean power-of-two division."""
    dst = bytearray(dw * dh * 4)
    sx_ratio = sw / dw
    sy_ratio = sh / dh
    for dy in range(dh):
        y0 = dy * sy_ratio
        y1 = y0 + sy_ratio
        iy0 = int(math.floor(y0))
        iy1 = min(int(math.ceil(y1)), sh)
        for dx in range(dw):
            x0 = dx * sx_ratio
            x1 = x0 + sx_ratio
            ix0 = int(math.floor(x0))
            ix1 = min(int(math.ceil(x1)), sw)
            rsum = gsum = bsum = asum = wsum = 0.0
            for sy in range(iy0, iy1):
                wy = min(sy + 1, y1) - max(sy, y0)
                if wy <= 0:
                    continue
                roff = sy * sw * 4
                for sx in range(ix0, ix1):
                    wx = min(sx + 1, x1) - max(sx, x0)
                    if wx <= 0:
                        continue
                    w = wx * wy
                    idx = roff + sx * 4
                    av = src[idx + 3]
                    aw = av * w
                    rsum += src[idx] * aw
                    gsum += src[idx + 1] * aw
                    bsum += src[idx + 2] * aw
                    asum += aw
                    wsum += w
            if asum > 1e-9:
                r, g, b = rsum / asum, gsum / asum, bsum / asum
            else:
                r = g = b = 0.0
            aavg = (asum / wsum) if wsum > 0 else 0.0
            di = (dy * dw + dx) * 4
            dst[di] = int(round(clamp(r, 0.0, 255.0)))
            dst[di + 1] = int(round(clamp(g, 0.0, 255.0)))
            dst[di + 2] = int(round(clamp(b, 0.0, 255.0)))
            dst[di + 3] = int(round(clamp(aavg, 0.0, 255.0)))
    return dst


def build_mip_chain(master, size):
    """{size: buf, size/2: buf, ...} down to (and including) 16px, via
    successive exact 2x2 box-filter halvings."""
    mips = {size: master}
    cur, cw, ch = master, size, size
    while cw > 16:
        cur, cw, ch = fast_half(cur, cw, ch)
        mips[cw] = cur
    return mips


# ---------------------------------------------------------------------------
# PNG / ICO encoding
# ---------------------------------------------------------------------------

def png_bytes(w, h, rgba):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        raw.extend(rgba[y * w * 4:(y + 1) * w * 4])

    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))


def write_png(path, w, h, rgba):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png_bytes(w, h, rgba))
    print("wrote", path)


def write_ico(path, sized_images):
    """sized_images: list of (size, rgba) tuples. Each frame is embedded as
    a PNG (supported for any size on Windows Vista+), which keeps this
    encoder simple and dependency-free."""
    n = len(sized_images)
    entries = []
    blobs = []
    offset = 6 + 16 * n
    for size, rgba in sized_images:
        blob = png_bytes(size, size, rgba)
        wb = size if size < 256 else 0
        hb = size if size < 256 else 0
        entries.append(struct.pack("<BBBBHHII", wb, hb, 0, 0, 1, 32, len(blob), offset))
        blobs.append(blob)
        offset += len(blob)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(struct.pack("<HHH", 0, 1, n))
        for e in entries:
            f.write(e)
        for b in blobs:
            f.write(b)
    print("wrote", path)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    root = os.path.join(os.path.dirname(__file__), "..")

    print("rendering 1024x1024 app icon master...", file=sys.stderr)
    app_master = render_app_icon_master()
    app_mips = build_mip_chain(app_master, MASTER)

    macos_dir = os.path.join(root, "macos", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    for size in (16, 32, 64, 128, 256, 512, 1024):
        write_png(os.path.join(macos_dir, f"app_icon_{size}.png"), size, size, app_mips[size])

    win_48 = general_downscale(app_mips[128], 128, 128, 48, 48)
    windows_images = [(sz, app_mips[sz]) for sz in (16, 32, 64, 128, 256)]
    windows_images.insert(2, (48, win_48))  # keep ascending order: 16,32,48,64,128,256
    write_ico(os.path.join(root, "windows", "runner", "resources", "app_icon.ico"), windows_images)

    print("rendering 256x256 tray glyph master...", file=sys.stderr)
    tray_master = render_tray_master(256)
    tray_mips = build_mip_chain(tray_master, 256)
    tray_24 = general_downscale(tray_mips[64], 64, 64, 24, 24)
    tray_images = [(16, tray_mips[16]), (24, tray_24), (32, tray_mips[32])]
    write_ico(os.path.join(root, "assets", "tray", "tray_icon_windows.ico"), tray_images)

    print("done")


if __name__ == "__main__":
    main()
