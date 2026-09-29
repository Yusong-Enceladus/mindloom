"""Camera / scanner degradations applied after a clean render (Pillow + numpy, deterministic per rng).

Nothing here changes which text is on the page; it only changes how hard it is to read. The ground
truth is always written from the clean render's inputs.
"""

from __future__ import annotations

import io
import math
import random

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

from . import fonts

MARK_TEXT = "合成数据"
MARK_RED = (205, 70, 60)


# --------------------------------------------------------------------------- geometry

def _perspective_coeffs(out_pts, in_pts):
    """Coefficients for Image.transform(PERSPECTIVE): maps output (x, y) to input coordinates."""
    rows, rhs = [], []
    for (x, y), (u, v) in zip(out_pts, in_pts):
        rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y])
        rows.append([0, 0, 0, x, y, 1, -v * x, -v * y])
        rhs += [u, v]
    return np.linalg.solve(np.array(rows, float), np.array(rhs, float)).tolist()


def jitter_quad(w: int, h: int, cw: int, ch: int, rng: random.Random, fill: float = 0.82,
                tilt: float = 0.06, rot_deg: float = 4.0) -> list[tuple[float, float]]:
    """A plausible photographed quad for a w x h page inside a cw x ch frame (TL, TR, BR, BL)."""
    scale = min(cw * fill / w, ch * fill / h)
    sw, sh = w * scale, h * scale
    cx = cw / 2 + rng.uniform(-0.04, 0.04) * cw
    cy = ch / 2 + rng.uniform(-0.04, 0.04) * ch
    base = [(-sw / 2, -sh / 2), (sw / 2, -sh / 2), (sw / 2, sh / 2), (-sw / 2, sh / 2)]
    a = math.radians(rng.uniform(-rot_deg, rot_deg))
    ca, sa = math.cos(a), math.sin(a)
    # keystone: the far edge (top or left) is shorter
    k_top = rng.uniform(-tilt, tilt)
    k_left = rng.uniform(-tilt, tilt) * 0.6
    out = []
    for i, (x, y) in enumerate(base):
        if i in (0, 1):
            x *= 1 - k_top
        else:
            x *= 1 + k_top
        if i in (0, 3):
            y *= 1 - k_left
        else:
            y *= 1 + k_left
        x += rng.uniform(-0.012, 0.012) * sw
        y += rng.uniform(-0.012, 0.012) * sh
        out.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
    # keep the whole page inside the frame (with a margin): nothing on it may be cut off
    margin = 0.03 * min(cw, ch)
    xs, ys = [p[0] for p in out], [p[1] for p in out]
    s = min(1.0, (cw - 2 * margin) / (max(xs) - min(xs)), (ch - 2 * margin) / (max(ys) - min(ys)))
    mx, my = (max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2
    out = [(mx + (x - mx) * s, my + (y - my) * s) for x, y in out]
    xs, ys = [p[0] for p in out], [p[1] for p in out]
    dx = max(0.0, margin - min(xs)) - max(0.0, max(xs) - (cw - margin))
    dy = max(0.0, margin - min(ys)) - max(0.0, max(ys) - (ch - margin))
    return [(x + dx, y + dy) for x, y in out]


def place(doc: Image.Image, canvas: Image.Image, quad) -> Image.Image:
    """Warp doc (RGB or RGBA) onto canvas so its corners land on quad (TL, TR, BR, BL)."""
    w, h = doc.size
    src = [(0, 0), (w, 0), (w, h), (0, h)]
    coeffs = _perspective_coeffs(quad, src)
    rgba = doc.convert("RGBA")
    warped = rgba.transform(canvas.size, Image.PERSPECTIVE, coeffs, Image.BICUBIC)
    out = canvas.convert("RGBA")
    out.alpha_composite(warped)
    return out.convert("RGB")


def drop_shadow(canvas: Image.Image, quad, rng: random.Random, strength: float = 0.35) -> Image.Image:
    """Soft shadow under a placed page (drawn before place())."""
    sh = Image.new("L", canvas.size, 0)
    dx, dy = rng.uniform(4, 14), rng.uniform(6, 18)
    ImageDraw.Draw(sh).polygon([(x + dx, y + dy) for x, y in quad], fill=int(255 * strength))
    sh = sh.filter(ImageFilter.GaussianBlur(12))
    arr = np.asarray(canvas, np.float32) * (1 - np.asarray(sh, np.float32)[..., None] / 255.0)
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))


def curl(img: Image.Image, rng: random.Random, amp: float = 4.0, strips: int = 40) -> Image.Image:
    """Gentle bend along the length of a slip (receipts): each horizontal band is shifted sideways along a
    slow sine. Rows stay rows (a band is never shifted up or down), so columns stay aligned."""
    w, h = img.size
    pad = int(amp * 2 + 4)
    src = Image.new("RGBA", (w + 2 * pad, h), (0, 0, 0, 0))
    src.paste(img.convert("RGBA"), (pad, 0))
    phase = rng.uniform(0, math.pi)
    freq = rng.uniform(1.5, 3.0)
    mesh = []
    for i in range(strips):
        y0, y1 = h * i // strips, h * (i + 1) // strips
        d0 = amp * math.sin(phase + freq * y0 / h)
        d1 = amp * math.sin(phase + freq * y1 / h)
        # output box -> source quad (UL, LL, LR, UR)
        mesh.append(((0, y0, w + 2 * pad, y1),
                     (d0, y0, d1, y1, w + 2 * pad + d1, y1, w + 2 * pad + d0, y0)))
    return src.transform(src.size, Image.MESH, mesh, Image.BICUBIC)


def rotate_scan(img: Image.Image, deg: float, fill=(236, 236, 232)) -> Image.Image:
    return img.rotate(deg, resample=Image.BICUBIC, expand=True, fillcolor=fill)


# --------------------------------------------------------------------------- surfaces

def texture(size, base, rng: random.Random, grain: float = 6.0, blotch: float = 14.0,
            streak: float = 0.0) -> Image.Image:
    """Low-frequency blotches + fine grain (+ optional horizontal streaks for wood/brushed metal)."""
    w, h = size
    nprng = np.random.default_rng(rng.randrange(1 << 30))
    small = nprng.normal(0, 1, (max(2, h // 64), max(2, w // 64)))
    low = np.asarray(Image.fromarray(((small - small.min()) / (np.ptp(small) + 1e-6) * 255).astype(np.uint8))
                     .resize((w, h), Image.BICUBIC), np.float32) / 255.0 - 0.5
    arr = np.ones((h, w, 3), np.float32) * np.array(base, np.float32)
    arr += low[..., None] * blotch
    arr += nprng.normal(0, grain, (h, w, 1))
    if streak:
        arr += nprng.normal(0, streak, (h, 1, 1))  # one offset per row: horizontal streaks
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))


BACKGROUNDS = {
    "wood": ((150, 112, 78), 4.0),
    "desk_grey": ((126, 128, 132), 3.0),
    "desk_white": ((214, 212, 206), 2.0),
    "fabric_blue": ((70, 86, 110), 1.0),
    "wall": ((198, 194, 184), 0.0),
    "cardboard": ((176, 142, 100), 2.0),
}


def background(size, kind: str, rng: random.Random) -> Image.Image:
    base, streak = BACKGROUNDS[kind]
    return texture(size, base, rng, grain=5.0, blotch=26.0, streak=streak)


# --------------------------------------------------------------------------- light & sensor

def lighting(img: Image.Image, rng: random.Random, strength: float = 0.25, vignette: float = 0.18) -> Image.Image:
    w, h = img.size
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    ang = rng.uniform(0, 2 * math.pi)
    lin = ((xx / w - 0.5) * math.cos(ang) + (yy / h - 0.5) * math.sin(ang))
    r = np.sqrt(((xx / w) - 0.5) ** 2 + ((yy / h) - 0.5) ** 2) / 0.7071
    field = 1.0 - strength * (lin + 0.5) * 0.9 - vignette * r ** 2
    arr = np.asarray(img, np.float32) * field[..., None]
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))


def glare(img: Image.Image, rng: random.Random, strength: float = 0.45, radius: float = 0.18) -> Image.Image:
    w, h = img.size
    cx, cy = rng.uniform(0.2, 0.8) * w, rng.uniform(0.15, 0.6) * h
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    rx, ry = radius * w, radius * h * rng.uniform(0.5, 1.0)
    blob = np.exp(-(((xx - cx) / rx) ** 2 + ((yy - cy) / ry) ** 2))
    arr = np.asarray(img, np.float32)
    arr = arr + (255 - arr) * (strength * blob)[..., None]
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))


def cast_shadow(img: Image.Image, rng: random.Random, strength: float = 0.28) -> Image.Image:
    """A soft shadow band across part of the frame (a phone or hand between lamp and page)."""
    w, h = img.size
    m = Image.new("L", (w, h), 0)
    x0 = rng.uniform(-0.2, 0.6) * w
    pts = [(x0, -10), (x0 + rng.uniform(0.3, 0.6) * w, -10),
           (x0 + rng.uniform(0.1, 0.5) * w, h + 10), (x0 - rng.uniform(0.1, 0.3) * w, h + 10)]
    ImageDraw.Draw(m).polygon(pts, fill=int(255 * strength))
    m = m.filter(ImageFilter.GaussianBlur(max(w, h) / 40))
    arr = np.asarray(img, np.float32) * (1 - np.asarray(m, np.float32)[..., None] / 255.0)
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))


def noise(img: Image.Image, rng: random.Random, sigma: float = 5.0) -> Image.Image:
    nprng = np.random.default_rng(rng.randrange(1 << 30))
    arr = np.asarray(img, np.float32) + nprng.normal(0, sigma, (img.size[1], img.size[0], 1))
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))


def speckle(img: Image.Image, rng: random.Random, density: float = 0.0015) -> Image.Image:
    """Scanner dust: sparse dark and light specks."""
    nprng = np.random.default_rng(rng.randrange(1 << 30))
    arr = np.asarray(img).copy()
    h, w = arr.shape[:2]
    n = int(h * w * density)
    ys, xs = nprng.integers(0, h, n), nprng.integers(0, w, n)
    arr[ys[: n // 2], xs[: n // 2]] = 40
    arr[ys[n // 2:], xs[n // 2:]] = 250
    return Image.fromarray(arr)


def blur(img: Image.Image, radius: float) -> Image.Image:
    return img.filter(ImageFilter.GaussianBlur(radius)) if radius > 0 else img


def motion_blur(img: Image.Image, length: int, horizontal: bool = True) -> Image.Image:
    if length <= 1:
        return img
    arr = np.asarray(img, np.float32)
    acc = np.zeros_like(arr)
    for k in range(length):
        acc += np.roll(arr, k - length // 2, axis=1 if horizontal else 0)
    return Image.fromarray(np.clip(acc / length, 0, 255).astype(np.uint8))


def contrast(img: Image.Image, factor: float, toward: float = 255.0) -> Image.Image:
    """Pull every pixel toward `toward` (factor < 1 = faded print / weak toner)."""
    arr = np.asarray(img, np.float32)
    arr = toward + (arr - toward) * factor
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))


def jpeg(img: Image.Image, quality: int) -> Image.Image:
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=quality)
    buf.seek(0)
    return Image.open(buf).convert("RGB")


def resize_long(img: Image.Image, long_side: int) -> Image.Image:
    w, h = img.size
    s = long_side / max(w, h)
    if s >= 1:
        return img
    return img.resize((max(1, round(w * s)), max(1, round(h * s))), Image.LANCZOS)


# --------------------------------------------------------------------------- synthetic-data mark

def add_mark(img: Image.Image, corner: str = "br", scale: float = 1.0) -> Image.Image:
    """Small "合成数据" box stamped after all degradations, outside the scored content."""
    img = img.copy()
    d = ImageDraw.Draw(img)
    size = max(11, int(min(img.size) * 0.022 * scale))
    f = fonts.font("hei", size)
    fonts.check("hei", MARK_TEXT)
    tw = d.textlength(MARK_TEXT, font=f)
    pad = max(3, size // 3)
    bw, bh = tw + 2 * pad, size + 2 * pad
    m = max(6, size // 2)
    x0 = img.size[0] - bw - m if corner[1] == "r" else m
    y0 = img.size[1] - bh - m if corner[0] == "b" else m
    d.rounded_rectangle([x0, y0, x0 + bw, y0 + bh], radius=pad, fill=(255, 255, 255), outline=MARK_RED,
                        width=max(1, size // 10))
    d.text((x0 + bw / 2, y0 + bh / 2), MARK_TEXT, font=f, fill=MARK_RED, anchor="mm")
    return img
