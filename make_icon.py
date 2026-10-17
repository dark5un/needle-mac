#!/usr/bin/env python3
"""make_icon.py — render NeedleMac.icns: a rounded-square gradient tile with
a steel needle (eye + point) and a cyan thread loop. Needs Pillow.

    python3 make_icon.py            # -> icon.iconset + NeedleMac.icns
"""
import math
import os
import subprocess
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit("make_icon.py needs Pillow: pip install pillow")

SS = 4                      # supersample factor
S = 1024 * SS               # raster size


def sc(v):
    return v * SS


def lerp3(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def main():
    out_dir = os.path.dirname(os.path.abspath(__file__))
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # --- rounded square with a vertical indigo -> violet gradient ---------
    # draw the gradient clipped to a rounded-rect mask
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    m = sc(72)                      # margin
    rad = sc(196)
    md.rounded_rectangle([m, m, S - m, S - m], radius=rad, fill=255)

    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    top, bot = (58, 60, 140), (124, 58, 190)
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp3(top, bot, y / S) + (255,))
    img.paste(grad, (0, 0), mask)

    # --- thread: one clean cyan ring passing behind the needle ------------
    tcx, tcy, tr = sc(500), sc(620), sc(170)
    d.ellipse([tcx - tr, tcy - tr, tcx + tr, tcy + tr],
              outline=(80, 200, 255, 255), width=sc(30))

    # --- needle: capsule body + triangular point, steel white -------------
    x1, y1, x2, y2 = sc(300), sc(730), sc(700), sc(330)   # eye end -> tip base
    tipx, tipy = sc(760), sc(270)                          # the point
    half = sc(44)
    # body as a thick line with round ends
    d.line([x1, y1, x2, y2], fill=(240, 244, 250, 255), width=half * 2)
    # tip triangle
    ang = math.atan2(tipy - y2, tipx - x2)
    perp = ang + math.pi / 2
    bx1 = x2 + half * math.cos(perp)
    by1 = y2 + half * math.sin(perp)
    bx2 = x2 - half * math.cos(perp)
    by2 = y2 - half * math.sin(perp)
    d.polygon([(bx1, by1), (bx2, by2), (tipx, tipy)], fill=(240, 244, 250, 255))
    # subtle shading: a thin darker seam along the shaft, centered
    d.line([x1, y1, x2, y2], fill=(205, 212, 228, 255), width=sc(8))

    # --- the eye: a hole through the needle near the top end --------------
    ecx, ecy, er = sc(655), sc(375), sc(52)
    # punch: repaint the gradient inside the eye circle
    eye_mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(eye_mask).ellipse([ecx - er, ecy - er, ecx + er, ecy + er], fill=255)
    img.paste(grad, (0, 0), eye_mask)
    # dark rim around the eye
    d.ellipse([ecx - er, ecy - er, ecx + er, ecy + er],
              outline=(40, 44, 70, 255), width=sc(14))

    # --- downsample --------------------------------------------------------
    icon = img.resize((1024, 1024), Image.LANCZOS)
    png = os.path.join(out_dir, "icon.png")
    icon.save(png)
    print("wrote", png)

    # --- iconset -> .icns --------------------------------------------------
    iset = os.path.join(out_dir, "icon.iconset")
    os.makedirs(iset, exist_ok=True)
    for size, name in [(16, "icon_16x16"), (32, "icon_16x16@2x"),
                       (32, "icon_32x32"), (64, "icon_32x32@2x"),
                       (128, "icon_128x128"), (256, "icon_128x128@2x"),
                       (256, "icon_256x256"), (512, "icon_256x256@2x"),
                       (512, "icon_512x512"), (1024, "icon_512x512@2x")]:
        icon.resize((size, size), Image.LANCZOS).save(os.path.join(iset, name + ".png"))
    icns = os.path.join(out_dir, "NeedleMac.icns")
    subprocess.run(["iconutil", "-c", "icns", iset, "-o", icns], check=True)
    print("wrote", icns)


if __name__ == "__main__":
    main()
