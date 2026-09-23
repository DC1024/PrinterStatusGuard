#!/usr/bin/env python3
# 生成 PrinterStatusGuard 自定义图标 app.ico（多尺寸 16/32/48/64/128/256）
import sys, traceback
try:
    from PIL import Image, ImageDraw

    S = 1024  # 超采样尺寸
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    def vgrad(draw, box, c1, c2):
        x0, y0, x1, y1 = box
        for y in range(int(y0), int(y1)):
            t = (y - y0) / max(1, (y1 - y0))
            r = int(c1[0] + (c2[0] - c1[0]) * t)
            g = int(c1[1] + (c2[1] - c1[1]) * t)
            b = int(c1[2] + (c2[2] - c1[2]) * t)
            draw.line([(x0, y), (x1, y)], fill=(r, g, b, 255))

    def rr(draw, box, r, fill, outline=None, ow=0):
        draw.rounded_rectangle(box, radius=r, fill=fill, outline=outline, width=ow)

    bg = (40, 120, 200)
    bg2 = (12, 90, 170)
    vgrad(d, (0, 0, S, S), bg, bg2)
    mask = Image.new("L", (S, S), 0)
    md = ImageDraw.Draw(mask)
    rr(md, (0, 0, S, S), int(S * 0.18), 255)
    img.putalpha(mask)

    white = (255, 255, 255, 255)
    W = S
    def cx(f): return int(W * f)

    rr(d, (cx(0.31), cx(0.20), cx(0.69), cx(0.34)), cx(0.03), white)
    rr(d, (cx(0.22), cx(0.33), cx(0.78), cx(0.63)), cx(0.04), white)
    rr(d, (cx(0.36), cx(0.36), cx(0.64), cx(0.41)), cx(0.015), (40, 110, 180, 255))
    r = cx(0.035)
    d.ellipse((cx(0.30), cx(0.54), cx(0.30) + r, cx(0.54) + r), fill=(40, 110, 180, 255))
    d.ellipse((cx(0.40), cx(0.54), cx(0.40) + r, cx(0.54) + r), fill=(40, 110, 180, 255))
    rr(d, (cx(0.36), cx(0.60), cx(0.64), cx(0.80)), cx(0.02), white)
    d.line([(cx(0.36), cx(0.70)), (cx(0.64), cx(0.70))], fill=(180, 200, 225, 255), width=max(1, int(S * 0.004)))

    bx, by, br = cx(0.74), cx(0.74), cx(0.17)
    d.ellipse((bx - br, by - br, bx + br, by + br), fill=(46, 158, 79, 255))
    ck = (255, 255, 255, 255)
    lw = max(6, int(S * 0.022))
    d.line([(bx - br * 0.45, by + br * 0.02), (bx - br * 0.10, by + br * 0.38)], fill=ck, width=lw)
    d.line([(bx - br * 0.10, by + br * 0.38), (bx + br * 0.45, by - br * 0.34)], fill=ck, width=lw)

    import os
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "app.ico")
    sizes = [(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    # 用 1024 母版直接 save：PIL 会按 sizes 自行降采样，保证每个尺寸都真实嵌入
    img.save(out, sizes=sizes)
    print("SAVED " + out + " OK")
except Exception:
    traceback.print_exc()
    sys.stdout.flush()
    sys.stderr.flush()
