#!/usr/bin/env python3
"""make_icon.py — render NeedleMac.icns: a quill pen over a papyrus scroll
on a warm parchment-gradient tile. Needs Pillow.

    python3 make_icon.py            # -> icon.png + icon.iconset + NeedleMac.icns
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

    # --- rounded square, warm parchment gradient (sand -> terracotta) -----
    m, rad = sc(72), sc(196)
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle([m, m, S - m, S - m], radius=rad, fill=255)
    grad = Image.new("RGBA", (S, S))
    gd = ImageDraw.Draw(grad)
    top, bot = (245, 222, 179), (226, 168, 122)      # parchment -> warm clay
    for y in range(S):
        gd.line([(0, y), (S, y)], fill=lerp3(top, bot, y / S) + (255,))
    img.paste(grad, (0, 0), mask)

    # --- papyrus scroll: a sheet with rolled ends, slightly tilted --------
    sheet = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    sd = ImageDraw.Draw(sheet)
    cx, cy = sc(490), sc(560)
    w, h = sc(340), sc(400)
    ang = math.radians(8)
    paper = (243, 229, 198, 255)
    edge = (198, 168, 122, 255)

    def rot(dx, dy):
        return (cx + dx * math.cos(ang) - dy * math.sin(ang),
                cy + dx * math.sin(ang) + dy * math.cos(ang))

    corners = [rot(-w / 2, -h / 2), rot(w / 2, -h / 2),
               rot(w / 2, h / 2), rot(-w / 2, h / 2)]
    sd.polygon(corners, fill=paper, outline=edge, width=sc(6))

    # rolled top and bottom: cylinders along the tilted horizontal axis
    def roll(dy):
        p1 = rot(-w / 2 - sc(16), dy)
        p2 = rot(w / 2 + sc(16), dy)
        sd.line([p1, p2], fill=edge, width=sc(104))
        sd.line([p1, p2], fill=(236, 220, 186, 255), width=sc(88))
        for p in (p1, p2):
            r = sc(52)
            sd.ellipse([p[0] - r, p[1] - r, p[0] + r, p[1] + r],
                       fill=(233, 216, 182, 255), outline=edge, width=sc(6))
    roll(-h / 2)
    roll(h / 2)

    # faint writing lines on the sheet: one aligned block
    for i in range(6):
        t = -h / 2 + sc(60) + i * sc(56)
        x1, y1 = rot(-w / 2 + sc(34), t)
        ln = w - sc(68)
        x2 = x1 + ln * math.cos(ang)
        y2 = y1 + ln * math.sin(ang)
        sd.line([x1, y1, x2, y2], fill=(140, 108, 78, 200), width=sc(9))
    img.alpha_composite(sheet)

    # --- quill: shaft lower-left -> feather upper-right -------------------
    q = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    qd = ImageDraw.Draw(q)
    x1, y1 = sc(290), sc(770)          # nib end
    x2, y2 = sc(770), sc(240)          # feather tip
    ang_q = math.atan2(y2 - y1, x2 - x1)
    perp = ang_q + math.pi / 2
    L = math.hypot(x2 - x1, y2 - y1)

    def off(along, side, bulge):
        return (x1 + along * math.cos(ang_q) + side * bulge * math.cos(perp),
                y1 + along * math.sin(ang_q) + side * bulge * math.sin(perp))

    # feather body: a leaf shape along the upper ~70% of the shaft
    start = L * 0.28
    steps = 24
    pts = []
    for i in range(steps + 1):
        t = start + (L - start) * (i / steps)
        bulge = math.sin(math.pi * i / steps) * L * 0.15
        pts.append(off(t, 1, bulge))
    for i in range(steps, -1, -1):
        t = start + (L - start) * (i / steps)
        bulge = math.sin(math.pi * i / steps) * L * 0.09
        pts.append(off(t, -1, bulge))
    qd.polygon(pts, fill=(252, 248, 240, 255), outline=(140, 112, 80, 255))
    # shaft (rachis): one stroke from nib to feather tip, no doubled line
    qd.line([(x1, y1), (x2, y2)], fill=(110, 76, 52, 255), width=sc(14))
    for i in range(3, steps, 2):
        t = start + (L - start) * (i / steps)
        bulge = math.sin(math.pi * i / steps) * L * 0.15
        qd.line([off(t, 0, 0), off(t, 1, bulge * 0.9)],
                fill=(224, 210, 186, 255), width=sc(4))
    # nib: dark triangle with a slit
    tipx, tipy = off(-sc(44), 0, 0)
    qd.polygon([off(0, 1, sc(13)), off(0, -1, sc(13)), (tipx, tipy)],
               fill=(70, 50, 40, 255))
    qd.line([(tipx, tipy), off(sc(24), 0, 0)], fill=(40, 28, 22, 255), width=sc(4))
    img.alpha_composite(q)

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
