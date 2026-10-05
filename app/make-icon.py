#!/usr/bin/env python3
"""Generate the PM3 tools app icon (white text on a black tile).

The stock launcher draws an app icon 1:1 into a 300x300 slot anchored at the
slot's top-left, and clips anything larger -- it does not scale. Every stock icon
is a 300x300 RGBA PNG whose artwork sits inside a 200x200 box inset 50 px from the
canvas edge, so the top margin is what decides how high the artwork sits.

The canvas is therefore 300x300 and the visible black tile is a 4:3 rectangle,
200x150, top-aligned with that stock artwork box.

    ./make-icon.py                    # 300x300 canvas, 200x150 (4:3) tile
    ./make-icon.py --tile 200x200     # square tile instead
"""
import argparse
import os

from PIL import Image, ImageDraw, ImageFont

BOLD = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
REG = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"


def fit(draw, text, path, max_w, start):
    size = start
    while size > 6:
        f = ImageFont.truetype(path, size)
        if draw.textlength(text, font=f) <= max_w:
            return f
        size -= 1
    return ImageFont.truetype(path, 6)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--canvas", default="300x300", help="full image size (stock: 300x300)")
    ap.add_argument("--tile", default="200x150", help="visible black tile inside the canvas")
    ap.add_argument("--radius", type=int, default=16, help="black tile corner radius")
    ap.add_argument("--tile-top", type=int, default=50,
                    help="y of the tile top inside the canvas; stock artwork starts at 50")
    ap.add_argument("--margin", type=float, default=0.08, help="text margin inside the tile")
    ap.add_argument("--title", default="PM3")
    ap.add_argument("--sub", default="tools")
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    CW, CH = (int(v) for v in args.canvas.lower().split("x"))
    TW, TH = (int(v) for v in args.tile.lower().split("x"))
    out = args.out or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                   "assets", "icon.png")

    im = Image.new("RGBA", (CW, CH), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)

    # Anchored, not centred: the launcher draws the canvas 1:1, so the top
    # margin alone decides how high the artwork sits in the card.
    x0, y0 = (CW - TW) // 2, args.tile_top
    d.rounded_rectangle([x0, y0, x0 + TW - 1, y0 + TH - 1], radius=args.radius,
                        fill=(0, 0, 0, 255))

    inner = int(TW * (1 - 2 * args.margin))
    f1 = fit(d, args.title, BOLD, inner, TH)
    f2 = ImageFont.truetype(REG, max(6, int(f1.size * 0.46)))

    b1, b2 = f1.getbbox(args.title), f2.getbbox(args.sub)
    h1, h2 = b1[3] - b1[1], b2[3] - b2[1]
    gap = max(2, int(TH * 0.05))
    top = y0 + (TH - (h1 + gap + h2)) // 2

    cx = CW // 2
    d.text((cx, top), args.title, font=f1, fill=(255, 255, 255, 255), anchor="ma")
    d.text((cx, top + h1 + gap), args.sub, font=f2, fill=(255, 255, 255, 255), anchor="ma")

    im.save(out)
    print("%s  canvas %dx%d  tile %dx%d at y=%d (ratio %.2f)  %s=%dpx  %s=%dpx"
          % (out, CW, CH, TW, TH, args.tile_top, TW / TH, args.title, f1.size, args.sub, f2.size))


if __name__ == "__main__":
    main()
