#!/usr/bin/env python3
"""Render the screenshots of a scenario to PNG (Pillow).

Every kind=image item carries an image spec whose image.style picks the layout:
- generic_im (default): image.messages[{sender,time,text}] in a generic instant-messenger style;
- generic_table, generic_terminal, generic_card: tables, terminals and documents/receipts/notices (scale-lab
  layout for specs with image.ocr_text; otherwise the scale-pm table and alert/ticket/SMS/offer card);
- generic_design (a design mock with review notes) and generic_doc (a scanned page), from scale-pm;
- board (dashboard), doc/table (document page), whiteboard and photo (a drawn stand-in scene), from scale-startup.
No real app's branding or colours; every image has a small "合成数据" (synthetic data) mark.
Output: <scenario dir>/assets/<ref or item_id>.png. Deterministic for a given font.

  python3 tools/render_screenshots.py scenarios/dev-week-v1/scenario.json [--out-dir DIR] [--scale 1.0]
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:  # only drawing needs Pillow; asset_path() (used by to_items.py) does not
    Image = ImageDraw = ImageFont = None

# (path, face index for a .ttc: the Simplified Chinese face)
FONT_CANDIDATES = [
    ("/System/Library/Fonts/PingFang.ttc", 0),
    ("/System/Library/PrivateFrameworks/FontServices.framework/Versions/A/Resources/Reserved/PingFangUI.ttc", 0),
    ("/System/Library/Fonts/Hiragino Sans GB.ttc", 0),
    ("/System/Library/Fonts/STHeiti Medium.ttc", 0),
    ("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", 2),
    ("/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc", 2),
    ("/usr/share/fonts/google-noto-cjk/NotoSansCJK-Regular.ttc", 2),
    ("/usr/share/fonts/truetype/noto/NotoSansCJK-Regular.ttc", 2),
    ("/usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf", 0),
]

W = 1080
BG = (244, 245, 248)
HEADER = (255, 255, 255)
OTHER_BUBBLE = (255, 255, 255)
SELF_BUBBLE = (214, 232, 255)
TEXT = (28, 30, 34)
MUTED = (134, 139, 150)
MARK = (205, 70, 60)


def find_font() -> tuple[str, int]:
    if ImageFont is None:
        raise SystemExit("Pillow is required to render screenshots (pip install pillow)")
    env = os.environ.get("EVAL_CJK_FONT")
    if env:
        return env, int(os.environ.get("EVAL_CJK_FONT_INDEX", "0"))
    for path, index in FONT_CANDIDATES:
        if os.path.exists(path):
            try:
                ImageFont.truetype(path, 20, index=index)
                return path, index
            except OSError:
                continue
    raise SystemExit("no CJK font found; set EVAL_CJK_FONT=/path/to/font.ttc (and EVAL_CJK_FONT_INDEX)")


def _avatar_colour(name: str) -> tuple[int, int, int]:
    h = hashlib.md5(name.encode("utf-8")).digest()
    palette = [(94, 129, 172), (163, 112, 88), (104, 150, 116), (150, 110, 170), (190, 140, 70), (90, 150, 160),
               (170, 96, 110), (120, 120, 132)]
    return palette[h[0] % len(palette)]


def _minutes(t):
    """'09:41' -> 581; None for anything else (then the label is always drawn)."""
    try:
        hh, mm = str(t).split(":")[:2]
        return int(hh) * 60 + int(mm)
    except (ValueError, AttributeError):
        return None


def visible_times(messages: list[dict]) -> list[str]:
    """Time label drawn above each message by render_chat ('' = none drawn): like a real IM, a label
    appears only when >= 5 minutes passed since the last one. Keep in sync with render_chat."""
    out, last = [], None
    for msg in messages:
        t = msg.get("time")
        minute = _minutes(t)
        if t and (last is None or minute is None or minute - last >= 5):
            out.append(t)
            last = minute
        else:
            out.append("")
    return out


def _wrap(text: str, font, max_w: int, draw: ImageDraw.ImageDraw) -> list[str]:
    lines = []
    for para in text.split("\n"):
        cur = ""
        for ch in para:
            if draw.textlength(cur + ch, font=font) > max_w and cur:
                lines.append(cur)
                cur = ch
            else:
                cur += ch
        lines.append(cur)
    return lines


def render_chat(spec: dict, out_path: str, scale: float = 1.0) -> tuple[int, int]:
    font_path, index = find_font()
    s = scale
    f_msg = ImageFont.truetype(font_path, int(30 * s), index=index)
    f_name = ImageFont.truetype(font_path, int(22 * s), index=index)
    f_title = ImageFont.truetype(font_path, int(32 * s), index=index)
    f_time = ImageFont.truetype(font_path, int(21 * s), index=index)
    f_mark = ImageFont.truetype(font_path, int(19 * s), index=index)
    width = int(W * s)
    img = Image.new("RGB", (width, int(4000 * s)), BG)
    d = ImageDraw.Draw(img)
    header_h = int(110 * s)
    d.rectangle([0, 0, width, header_h], fill=HEADER)
    d.line([0, header_h, width, header_h], fill=(225, 227, 232), width=max(1, int(2 * s)))
    d.text((width // 2, header_h // 2 + int(6 * s)), spec.get("chat_title", "聊天"), font=f_title, fill=TEXT, anchor="mm")
    cy = header_h // 2 + int(4 * s)
    d.line([(int(46 * s), cy - int(16 * s)), (int(30 * s), cy), (int(46 * s), cy + int(16 * s))],
           fill=TEXT, width=max(2, int(4 * s)), joint="curve")  # back chevron, drawn (not a glyph)
    # Small synthetic-data mark, top right.
    mark = "合成数据"
    mw = d.textlength(mark, font=f_mark) + int(20 * s)
    mx1 = width - int(24 * s)
    mx0 = mx1 - mw
    my0 = header_h // 2 - int(14 * s)
    d.rounded_rectangle([mx0, my0, mx1, my0 + int(34 * s)], int(8 * s), outline=MARK, width=max(1, int(2 * s)))
    d.text(((mx0 + mx1) / 2, my0 + int(17 * s)), mark, font=f_mark, fill=MARK, anchor="mm")

    self_name = spec.get("self_sender", "我")
    y = header_h + int(30 * s)
    last_time = None
    av = int(80 * s)
    lh = int(44 * s)
    max_text_w = int(640 * s)
    for msg in spec["messages"]:
        t = msg.get("time")
        minute = _minutes(t)
        if t and (last_time is None or minute is None or last_time is None or minute - last_time >= 5):
            d.text((width // 2, y + int(14 * s)), t, font=f_time, fill=MUTED, anchor="mm")
            y += int(52 * s)
            last_time = minute
        mine = msg["sender"] == self_name
        lines = _wrap(msg["text"], f_msg, max_text_w, d)
        bw = int(max(d.textlength(line, font=f_msg) for line in lines) + 44 * s)
        bh = int(lh * len(lines) + 26 * s)
        if mine:
            ax = width - int(30 * s) - av
            d.ellipse([ax, y, ax + av, y + av], fill=_avatar_colour(self_name))
            d.text((ax + av // 2, y + av // 2), self_name[:1], font=f_msg, fill="white", anchor="mm")
            bx1 = ax - int(18 * s)
            bx0 = bx1 - bw
            by = y
            d.rounded_rectangle([bx0, by, bx1, by + bh], int(18 * s), fill=SELF_BUBBLE)
            for k, line in enumerate(lines):
                d.text((bx0 + int(22 * s), by + int(12 * s) + k * lh), line, font=f_msg, fill=TEXT)
            y = max(y + av, by + bh) + int(34 * s)
        else:
            ax = int(30 * s)
            d.ellipse([ax, y, ax + av, y + av], fill=_avatar_colour(msg["sender"]))
            d.text((ax + av // 2, y + av // 2), msg["sender"][:1], font=f_msg, fill="white", anchor="mm")
            d.text((ax + av + int(18 * s), y - int(2 * s)), msg["sender"], font=f_name, fill=MUTED)
            bx0 = ax + av + int(18 * s)
            by = y + int(34 * s)
            d.rounded_rectangle([bx0, by, bx0 + bw, by + bh], int(18 * s), fill=OTHER_BUBBLE)
            for k, line in enumerate(lines):
                d.text((bx0 + int(22 * s), by + int(12 * s) + k * lh), line, font=f_msg, fill=TEXT)
            y = max(y + av, by + bh) + int(34 * s)
    # Input bar.
    bar_top = y + int(10 * s)
    d.rectangle([0, bar_top, width, bar_top + int(96 * s)], fill=HEADER)
    d.rounded_rectangle([int(30 * s), bar_top + int(18 * s), width - int(30 * s), bar_top + int(78 * s)],
                        int(14 * s), fill=BG)
    img = img.crop((0, 0, width, bar_top + int(96 * s)))
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    img.save(out_path, format="PNG", optimize=True)
    return img.size


def _canvas(title: str, s: float, bg=BG, header=HEADER, fg=TEXT, height=4000):
    """Blank image with a header bar, a drawn back chevron and the synthetic-data mark."""
    font_path, index = find_font()
    width = int(W * s)
    img = Image.new("RGB", (width, int(height * s)), bg)
    d = ImageDraw.Draw(img)
    header_h = int(110 * s)
    f_title = ImageFont.truetype(font_path, int(30 * s), index=index)
    f_mark = ImageFont.truetype(font_path, int(19 * s), index=index)
    d.rectangle([0, 0, width, header_h], fill=header)
    d.line([0, header_h, width, header_h], fill=(225, 227, 232), width=max(1, int(2 * s)))
    shown = title if d.textlength(title, font=f_title) < width - 320 * s else title[:24] + "…"
    d.text((width // 2, header_h // 2 + int(4 * s)), shown, font=f_title, fill=fg, anchor="mm")
    mark = "合成数据"
    mw = d.textlength(mark, font=f_mark) + int(20 * s)
    mx1 = width - int(24 * s)
    my0 = header_h // 2 - int(14 * s)
    d.rounded_rectangle([mx1 - mw, my0, mx1, my0 + int(34 * s)], int(8 * s), outline=MARK, width=max(1, int(2 * s)))
    d.text((mx1 - mw / 2, my0 + int(17 * s)), mark, font=f_mark, fill=MARK, anchor="mm")
    return img, d, header_h, font_path, index


def _finish(img, bottom: int, out_path: str, s: float):
    img = img.crop((0, 0, img.size[0], max(bottom + int(40 * s), int(400 * s))))
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    img.save(out_path, format="PNG", optimize=True)
    return img.size


def render_table(spec: dict, out_path: str, scale: float = 1.0) -> tuple[int, int]:
    """Generic spreadsheet-like table (no real app's styling)."""
    s = scale
    img, d, top, fp, ix = _canvas(spec.get("title") or "表格", s)
    f_cell = ImageFont.truetype(fp, int(24 * s), index=ix)
    f_head = ImageFont.truetype(fp, int(24 * s), index=ix)
    f_note = ImageFont.truetype(fp, int(21 * s), index=ix)
    cols = [str(c) for c in spec.get("columns") or []]
    rows = [[str(c) for c in r] for r in spec.get("rows") or [] if any(str(c).strip() for c in r)]
    n = max([len(cols)] + [len(r) for r in rows] + [1])
    width = img.size[0]
    margin = int(28 * s)
    avail = width - 2 * margin
    natural = [max([d.textlength(cols[k] if k < len(cols) else "", font=f_head)] +
                   [d.textlength(r[k] if k < len(r) else "", font=f_cell) for r in rows]) + 24 * s for k in range(n)]
    tot = sum(natural) or 1
    widths = [max(60 * s, avail * w / tot) for w in natural]
    scale_w = avail / sum(widths)
    widths = [w * scale_w for w in widths]
    y = top + int(30 * s)
    lh = int(30 * s)

    def row(cells, font, fill, yy):
        wrapped = [_wrap(cells[k] if k < len(cells) else "", font, int(widths[k] - 16 * s), d) for k in range(n)]
        h = max(len(w) for w in wrapped) * lh + int(18 * s)
        x = margin
        d.rectangle([margin, yy, margin + avail, yy + h], fill=fill, outline=(214, 217, 224))
        for k in range(n):
            if k:
                d.line([x, yy, x, yy + h], fill=(214, 217, 224))
            for j, line in enumerate(wrapped[k]):
                d.text((x + 8 * s, yy + 9 * s + j * lh), line, font=font, fill=TEXT)
            x += widths[k]
        return yy + h

    if cols:
        y = row(cols, f_head, (230, 234, 242), y)
    for r in rows:
        y = row(r, f_cell, (255, 255, 255), y)
    if spec.get("note"):
        for line in _wrap(str(spec["note"]), f_note, avail, d):
            y += int(34 * s)
            d.text((margin, y), line, font=f_note, fill=MUTED)
    return _finish(img, y, out_path, s)


def render_terminal(spec: dict, out_path: str, scale: float = 1.0) -> tuple[int, int]:
    """Generic dark terminal window."""
    s = scale
    img, d, top, fp, ix = _canvas(spec.get("title") or "终端", s, bg=(30, 32, 38), header=(52, 55, 63), fg=(230, 232, 236))
    f = ImageFont.truetype(fp, int(23 * s), index=ix)
    width = img.size[0]
    y = top + int(24 * s)
    lh = int(33 * s)
    for raw in spec.get("lines") or []:
        for line in _wrap(str(raw), f, width - int(60 * s), d):
            colour = (240, 120, 110) if any(k in line for k in ("Error", "error", "ERROR", "OOM", "Killed", "failed")) else (208, 214, 222)
            d.text((int(28 * s), y), line, font=f, fill=colour)
            y += lh
    return _finish(img, y, out_path, s)


def render_card(spec: dict, out_path: str, scale: float = 1.0) -> tuple[int, int]:
    """Generic document / receipt / notice card: label-value rows plus an optional body."""
    s = scale
    img, d, top, fp, ix = _canvas(spec.get("title") or "图片", s)
    f_label = ImageFont.truetype(fp, int(24 * s), index=ix)
    f_value = ImageFont.truetype(fp, int(27 * s), index=ix)
    f_body = ImageFont.truetype(fp, int(25 * s), index=ix)
    width = img.size[0]
    margin = int(40 * s)
    lh = int(38 * s)
    fields = [(str(f.get("label", "")), _wrap(str(f.get("value", "")), f_value, width - 2 * margin - int(300 * s), d))
              for f in spec.get("fields") or []]
    body = _wrap(str(spec["body"]), f_body, width - 2 * margin - int(48 * s), d) if spec.get("body") else []
    card_top = top + int(34 * s)
    height = int(24 * s) + sum(max(1, len(v)) * lh + int(14 * s) for _, v in fields)
    if body:
        height += int(28 * s) + len(body) * lh
    card_bottom = card_top + height + int(20 * s)
    d.rounded_rectangle([margin, card_top, width - margin, card_bottom], int(18 * s), fill=(255, 255, 255))
    y = card_top + int(24 * s)
    for label, lines in fields:
        d.text((margin + int(24 * s), y), label, font=f_label, fill=MUTED)
        for j, line in enumerate(lines):
            d.text((margin + int(260 * s), y + j * lh), line, font=f_value, fill=TEXT)
        y += max(1, len(lines)) * lh + int(14 * s)
    if body:
        y += int(10 * s)
        d.line([margin + int(20 * s), y, width - margin - int(20 * s), y], fill=(225, 227, 232))
        y += int(18 * s)
        for line in body:
            d.text((margin + int(24 * s), y), line, font=f_body, fill=TEXT)
            y += lh
    return _finish(img, card_bottom, out_path, s)


# ------------------------------------------------------------------------------------------
# scale-startup styles: dashboards (board), document pages (doc/table), whiteboards and annotated photos.
# ------------------------------------------------------------------------------------------

def _st_fonts(s: float):
    font_path, index = find_font()
    f = lambda n: ImageFont.truetype(font_path, int(n * s), index=index)  # noqa: E731
    return f(40), f(30), f(26), f(21), f(19)


def _mark(d, width, y, s, f_mark):
    mark = "合成数据"
    mw = d.textlength(mark, font=f_mark) + int(20 * s)
    mx1 = width - int(24 * s)
    mx0 = mx1 - mw
    d.rounded_rectangle([mx0, y, mx1, y + int(34 * s)], int(8 * s), outline=MARK, width=max(1, int(2 * s)))
    d.text(((mx0 + mx1) / 2, y + int(17 * s)), mark, font=f_mark, fill=MARK, anchor="mm")


def _st_table(d, x0, y, width, rows, font, s, head_fill=(236, 239, 245)):
    if not rows:
        return y
    ncol = max(len(r) for r in rows)
    widths = [0] * ncol
    for r in rows:
        for i, c in enumerate(r):
            widths[i] = max(widths[i], d.textlength(str(c), font=font) + 36 * s)
    total = sum(widths)
    scale = (width - x0 * 2) / total if total else 1
    widths = [w * scale for w in widths]
    rh = int(58 * s)
    for ri, r in enumerate(rows):
        x = x0
        if ri == 0:
            d.rectangle([x0, y, x0 + sum(widths), y + rh], fill=head_fill)
        for i in range(ncol):
            c = str(r[i]) if i < len(r) else ""
            lines = _wrap(c, font, widths[i] - 24 * s, d)
            for k, line in enumerate(lines[:2]):
                d.text((x + 16 * s, y + 12 * s + k * 26 * s), line, font=font, fill=TEXT)
            x += widths[i]
        d.line([x0, y + rh, x0 + sum(widths), y + rh], fill=(222, 225, 232), width=max(1, int(2 * s)))
        y += rh
    return y


def render_board(spec: dict, out_path: str, scale: float = 1.0) -> tuple[int, int]:
    s = scale
    f_title, f_big, f_body, f_small, f_mark = _st_fonts(s)
    width = int(1280 * s)
    img = Image.new("RGB", (width, int(3000 * s)), (246, 247, 250))
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, width, int(96 * s)], fill=(40, 52, 72))
    d.text((int(36 * s), int(48 * s)), spec.get("title", "看板"), font=f_big, fill="white", anchor="lm")
    _mark(d, width, int(30 * s), s, f_mark)
    y = int(126 * s)
    kpis = spec.get("kpis") or []
    if kpis:
        tw = (width - int(72 * s) - int(24 * s) * (len(kpis) - 1)) / len(kpis)
        for i, (k, v) in enumerate(kpis):
            x = int(36 * s + i * (tw + 24 * s))
            d.rounded_rectangle([x, y, x + tw, y + int(130 * s)], int(14 * s), fill="white", outline=(225, 228, 235))
            d.text((x + 24 * s, y + 22 * s), str(k), font=f_small, fill=MUTED)
            d.text((x + 24 * s, y + 60 * s), str(v), font=f_title, fill=TEXT)
        y += int(160 * s)
    chart = spec.get("chart")
    if chart:
        ch = int(300 * s)
        x0, x1 = int(36 * s), width - int(36 * s)
        d.rounded_rectangle([x0, y, x1, y + ch], int(14 * s), fill="white", outline=(225, 228, 235))
        d.text((x0 + 24 * s, y + 18 * s), chart.get("label", ""), font=f_small, fill=MUTED)
        vals = chart.get("series") or []
        if vals:
            lo, hi = min(vals) - 5, max(vals) + 5
            px0, px1, py0, py1 = x0 + 60 * s, x1 - 40 * s, y + 60 * s, y + ch - 40 * s
            pts = [(px0 + (px1 - px0) * i / max(1, len(vals) - 1), py1 - (py1 - py0) * (v - lo) / (hi - lo)) for i, v in enumerate(vals)]
            d.line(pts, fill=(52, 120, 200), width=max(2, int(4 * s)), joint="curve")
            d.text((x0 + 20 * s, py0), str(max(vals)), font=f_small, fill=MUTED)
            d.text((x0 + 20 * s, py1 - 24 * s), str(min(vals)), font=f_small, fill=MUTED)
        y += ch + int(24 * s)
    rows = spec.get("rows") or []
    if rows:
        top = y
        y = _st_table(d, int(36 * s), y + int(10 * s), width, rows, f_body, s)
        d.rectangle([int(36 * s), top + int(10 * s), width - int(36 * s), y], outline=(225, 228, 235))
        y += int(20 * s)
    if spec.get("note"):
        d.text((int(36 * s), y + 8 * s), spec["note"], font=f_small, fill=MUTED)
        y += int(48 * s)
    img = img.crop((0, 0, width, y + int(30 * s)))
    img.save(out_path, format="PNG", optimize=True)
    return img.size


def render_st_doc(spec: dict, out_path: str, scale: float = 1.0) -> tuple[int, int]:
    s = scale
    f_title, f_big, f_body, f_small, f_mark = _st_fonts(s)
    width = int(1080 * s)
    img = Image.new("RGB", (width, int(3000 * s)), (232, 234, 238))
    d = ImageDraw.Draw(img)
    x0, x1 = int(60 * s), width - int(60 * s)
    d.rectangle([x0, int(50 * s), x1, int(2900 * s)], fill="white")
    _mark(d, width, int(8 * s), s, f_mark)
    y = int(100 * s)
    for line in _wrap(spec.get("title", ""), f_big, x1 - x0 - 80 * s, d):
        d.text((x0 + 40 * s, y), line, font=f_big, fill=TEXT)
        y += int(50 * s)
    y += int(20 * s)
    if spec.get("rows"):
        y = _st_table(d, x0 + int(40 * s), y, width - int(80 * s) + int(40 * s), spec["rows"], f_body, s)
        y += int(20 * s)
    for para in spec.get("lines", []):
        for line in _wrap(para, f_body, x1 - x0 - 80 * s, d):
            d.text((x0 + 40 * s, y), line, font=f_body, fill=TEXT)
            y += int(42 * s)
        y += int(12 * s)
    img = img.crop((0, 0, width, y + int(60 * s)))
    d = ImageDraw.Draw(img)
    img.save(out_path, format="PNG", optimize=True)
    return img.size


def render_whiteboard(spec: dict, out_path: str, scale: float = 1.0) -> tuple[int, int]:
    s = scale
    font_path, index = find_font()
    f_hand = ImageFont.truetype(font_path, int(40 * s), index=index)
    f_mark = ImageFont.truetype(font_path, int(19 * s), index=index)
    lines = spec.get("lines", [])
    width, height = int(1280 * s), int((180 + 86 * len(lines)) * s)
    img = Image.new("RGB", (width, height), (250, 250, 246))
    d = ImageDraw.Draw(img)
    d.rectangle([int(10 * s), int(10 * s), width - int(10 * s), height - int(10 * s)], outline=(190, 192, 198), width=max(2, int(8 * s)))
    _mark(d, width, int(26 * s), s, f_mark)
    colours = [(30, 60, 140), (170, 40, 40), (20, 110, 60), (30, 30, 30)]
    y = int(90 * s)
    for i, line in enumerate(lines):
        x = int((70 + (i * 37) % 90) * s)
        layer = Image.new("RGBA", (width, int(80 * s)), (0, 0, 0, 0))
        ImageDraw.Draw(layer).text((x, int(10 * s)), line, font=f_hand, fill=colours[i % len(colours)] + (255,))
        layer = layer.rotate(((i * 7) % 5 - 2) * 0.6, resample=Image.BICUBIC, center=(width / 2, 40 * s))
        img.paste(layer, (0, y), layer)
        y += int(86 * s)
    img.save(out_path, format="PNG", optimize=True)
    return img.size


def render_photo(spec: dict, out_path: str, scale: float = 1.0) -> tuple[int, int]:
    """A stylised stand-in for a phone photo: a drawn scene with the user's annotation labels on top."""
    s = scale
    font_path, index = find_font()
    f_lab = ImageFont.truetype(font_path, int(36 * s), index=index)
    f_mark = ImageFont.truetype(font_path, int(19 * s), index=index)
    width, height = int(1080 * s), int(1080 * s)
    img = Image.new("RGB", (width, height), (70, 74, 80))
    d = ImageDraw.Draw(img)
    seed = int(hashlib.md5(spec.get("title", "").encode("utf-8")).hexdigest()[:6], 16)
    for i in range(height):
        c = 60 + int(50 * i / height)
        d.line([(0, i), (width, i)], fill=(c, c + 4, c + 10))
    for k in range(7):
        x = (seed >> k) % int(700 * s) + int(40 * s)
        y = (seed >> (k + 3)) % int(500 * s) + int(200 * s)
        w, h = int((120 + k * 30) * s), int((80 + (k % 3) * 60) * s)
        shade = 90 + (k * 23) % 90
        d.rounded_rectangle([x, y, x + w, y + h], int(10 * s), fill=(shade, shade + 6, shade + 12), outline=(200, 205, 210))
    _mark(d, width, int(24 * s), s, f_mark)
    lines = spec.get("lines", [])
    y = height - int((60 + 64 * len(lines)) * s)
    d.rounded_rectangle([int(40 * s), y - int(20 * s), width - int(40 * s), height - int(40 * s)], int(16 * s), fill=(255, 238, 120))
    for line in lines:
        d.text((int(70 * s), y), line, font=f_lab, fill=(40, 36, 20))
        y += int(64 * s)
    img.save(out_path, format="PNG", optimize=True)
    return img.size


def ground_truth_text(spec: dict) -> str:
    """All text drawn in the image, in reading order (excluding the 合成数据 mark)."""
    style = spec.get("style") or "generic_im"
    out = []
    if style == "generic_im":
        out.append(spec.get("chat_title", "聊天"))
        shown = visible_times(spec["messages"])
        for msg, t in zip(spec["messages"], shown):
            if t:
                out.append(t)
            out.append(("" if msg["sender"] == spec.get("self_sender", "我") else msg["sender"] + "：") + msg["text"])
        return "\n".join(out)
    out.append(spec.get("title", ""))
    for k, v in spec.get("kpis") or []:
        out.append(f"{k} {v}")
    if spec.get("chart"):
        out.append(spec["chart"].get("label", ""))
    for r in spec.get("rows") or []:
        out.append(" | ".join(str(c) for c in r))
    out += spec.get("lines", [])
    if spec.get("note"):
        out.append(spec["note"])
    return "\n".join(x for x in out if x)


# ------------------------------------------------------------------------------------------
# scale-pm styles: generic_table / generic_card here draw pm's layout (the scale-lab layouts above are used
# for specs that carry image.ocr_text, which every scale-lab image has), plus generic_design and generic_doc.
# ------------------------------------------------------------------------------------------

def _pm_header(d, width, title, fonts, s):
    header_h = int(110 * s)
    d.rectangle([0, 0, width, header_h], fill=HEADER)
    d.line([0, header_h, width, header_h], fill=(225, 227, 232), width=max(1, int(2 * s)))
    d.text((int(36 * s), header_h // 2), title, font=fonts["title"], fill=TEXT, anchor="lm")
    mark = "合成数据"
    mw = d.textlength(mark, font=fonts["mark"]) + int(20 * s)
    mx1 = width - int(24 * s)
    mx0 = mx1 - mw
    my0 = header_h // 2 - int(14 * s)
    d.rounded_rectangle([mx0, my0, mx1, my0 + int(34 * s)], int(8 * s), outline=MARK, width=max(1, int(2 * s)))
    d.text(((mx0 + mx1) / 2, my0 + int(17 * s)), mark, font=fonts["mark"], fill=MARK, anchor="mm")
    return header_h


def _pm_fonts(s):
    font_path, index = find_font()
    mk = lambda px: ImageFont.truetype(font_path, int(px * s), index=index)  # noqa: E731
    return {"title": mk(32), "mark": mk(19), "text": mk(26), "small": mk(22), "big": mk(30), "cell": mk(24)}


def _pm_canvas(width, s):
    img = Image.new("RGB", (width, int(6000 * s)), BG)
    return img, ImageDraw.Draw(img)


def _pm_finish(img, height, out_path):
    img = img.crop((0, 0, img.width, height))
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    img.save(out_path, format="PNG", optimize=True)
    return img.size


def _pm_para(d, x, y, text, font, max_w, fill=TEXT, lh=None):
    lh = lh or int(font.size * 1.45)
    for line in _wrap(str(text), font, max_w, d):
        d.text((x, y), line, font=font, fill=fill)
        y += lh
    return y


def render_pm_table(spec: dict, out_path: str, scale: float = 1.0):
    s = scale
    cols = [str(c) for c in spec.get("columns", [])]
    rows = [[str(v) for v in r] for r in spec.get("rows", [])]
    n = max(1, len(cols))
    width = int(max(1080, min(1800, 220 * n)) * s)
    img, d = _pm_canvas(width, s)
    f = _pm_fonts(s)
    y = _pm_header(d, width, str(spec.get("title", "看板")), f, s) + int(24 * s)
    if spec.get("subtitle"):
        y = _pm_para(d, int(36 * s), y, spec["subtitle"], f["small"], width - int(72 * s), MUTED) + int(10 * s)
    x0, x1 = int(30 * s), width - int(30 * s)
    cw = (x1 - x0) / n
    def row(vals, yy, bold=False, fill=(255, 255, 255)):
        wrapped = [_wrap(v, f["cell"], int(cw - 24 * s), d) for v in vals] or [[""]]
        h = int(max(len(w) for w in wrapped) * f["cell"].size * 1.4 + 28 * s)
        d.rectangle([x0, yy, x1, yy + h], fill=fill)
        for k, w in enumerate(wrapped):
            ty = yy + int(14 * s)
            for line in w:
                d.text((x0 + k * cw + int(12 * s), ty), line, font=f["cell"], fill=TEXT if not bold else (60, 64, 72))
                ty += int(f["cell"].size * 1.4)
        d.line([x0, yy + h, x1, yy + h], fill=(225, 227, 232), width=max(1, int(2 * s)))
        return yy + h
    y = row(cols, y, True, (234, 237, 243))
    for r in rows:
        y = row((r + [""] * n)[:n], y)
    y += int(20 * s)
    if spec.get("note"):
        y = _pm_para(d, int(36 * s), y, spec["note"], f["small"], width - int(72 * s), MUTED) + int(10 * s)
    return _pm_finish(img, y + int(30 * s), out_path)


def render_pm_card(spec: dict, out_path: str, scale: float = 1.0):
    s = scale
    width = int(1080 * s)
    img, d = _pm_canvas(width, s)
    f = _pm_fonts(s)
    y = _pm_header(d, width, str(spec.get("title", "")), f, s) + int(30 * s)
    x0, x1 = int(36 * s), width - int(36 * s)
    top = y
    y += int(24 * s)
    for fld in spec.get("fields", []):
        if not isinstance(fld, (list, tuple)) or len(fld) < 2:
            continue
        d.text((x0 + int(24 * s), y), str(fld[0]), font=f["small"], fill=MUTED)
        y = _pm_para(d, x0 + int(260 * s), y, fld[1], f["text"], x1 - x0 - int(290 * s)) + int(12 * s)
    if spec.get("body"):
        y += int(8 * s)
        y = _pm_para(d, x0 + int(24 * s), y, spec["body"], f["text"], x1 - x0 - int(48 * s)) + int(8 * s)
    d.rounded_rectangle([x0, top, x1, y + int(16 * s)], int(16 * s), outline=(220, 223, 230), width=max(1, int(2 * s)))
    y += int(40 * s)
    if spec.get("footer"):
        y = _pm_para(d, x0, y, spec["footer"], f["small"], x1 - x0, MUTED)
    return _pm_finish(img, y + int(30 * s), out_path)


def render_design(spec: dict, out_path: str, scale: float = 1.0):
    s = scale
    width = int(1280 * s)
    img, d = _pm_canvas(width, s)
    f = _pm_fonts(s)
    y = _pm_header(d, width, str(spec.get("title", "设计稿")), f, s) + int(30 * s)
    px0, px1 = int(40 * s), int(760 * s)
    top = y
    for b in spec.get("blocks", []):
        if not isinstance(b, dict):
            continue
        by = y
        d.text((px0 + int(20 * s), y + int(14 * s)), str(b.get("label", "")), font=f["small"], fill=MUTED)
        yy = _pm_para(d, px0 + int(20 * s), y + int(50 * s), b.get("text", ""), f["text"], px1 - px0 - int(40 * s))
        d.rounded_rectangle([px0, by, px1, yy + int(14 * s)], int(14 * s), outline=(200, 205, 215), width=max(1, int(2 * s)),
                            fill=None)
        y = yy + int(34 * s)
    ay = top
    for a in spec.get("annotations", []):
        ax0, ax1 = int(800 * s), width - int(30 * s)
        yy = _pm_para(d, ax0 + int(16 * s), ay + int(12 * s), a, f["small"], ax1 - ax0 - int(32 * s), (150, 40, 30))
        d.rounded_rectangle([ax0, ay, ax1, yy + int(10 * s)], int(10 * s), outline=MARK, width=max(1, int(2 * s)))
        d.line([ax0, ay + int(24 * s), px1, ay + int(24 * s)], fill=MARK, width=max(1, int(2 * s)))
        ay = yy + int(30 * s)
    return _pm_finish(img, max(y, ay) + int(30 * s), out_path)


def render_pm_doc(spec: dict, out_path: str, scale: float = 1.0):
    """A scanned-looking page: off-white paper, slight grey, no text layer."""
    s = scale
    width = int(1240 * s)
    img = Image.new("RGB", (width, int(8000 * s)), (238, 236, 230))
    d = ImageDraw.Draw(img)
    f = _pm_fonts(s)
    x0 = int(90 * s)
    y = int(70 * s)
    d.text((width - int(40 * s), int(30 * s)), "合成数据", font=f["mark"], fill=MARK, anchor="rm")
    d.text((width // 2, y), str(spec.get("title", "")), font=f["big"], fill=(40, 40, 40), anchor="mt")
    y += int(80 * s)
    for para in spec.get("paragraphs", []):
        y = _pm_para(d, x0, y, para, f["text"], width - 2 * x0, (45, 45, 45)) + int(14 * s)
    return _pm_finish(img, y + int(60 * s), out_path)


RENDERERS = {"generic_im": render_chat, "generic_terminal": render_terminal,
             "generic_design": render_design, "generic_doc": render_pm_doc,
             "board": render_board, "doc": render_st_doc, "table": render_st_doc,
             "whiteboard": render_whiteboard, "photo": render_photo}


def render(spec: dict, out_path: str, scale: float = 1.0) -> tuple[int, int]:
    """Draw any image spec; the style defaults to the chat renderer."""
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    style = spec.get("style") or "generic_im"
    if style in ("generic_table", "generic_card"):  # two layouts share these names (see above)
        lab = "ocr_text" in spec
        fn = {"generic_table": (render_pm_table, render_table), "generic_card": (render_pm_card, render_card)}[style][lab]
        return fn(spec, out_path, scale)
    if style not in RENDERERS:
        raise ValueError(f"unknown image style {style!r}")
    return RENDERERS[style](spec, out_path, scale)


render_image = render  # scale-startup's name for the dispatcher


def asset_path(scenario_path: str, item: dict, out_dir: str | None = None) -> str:
    base = out_dir or os.path.join(os.path.dirname(os.path.abspath(scenario_path)), "assets")
    return os.path.join(base, f"{item.get('ref') or item['item_id']}.png")


def render_scenario(scenario_path: str, out_dir: str | None = None, scale: float = 1.0) -> list[str]:
    with open(scenario_path, encoding="utf-8") as fh:
        scenario = json.load(fh)
    written = []
    for item in scenario["items"]:
        if item["kind"] != "image":
            continue
        path = asset_path(scenario_path, item, out_dir)
        size = render(item["image"], path, scale)
        written.append(path)
        print(f"{path} {size[0]}x{size[1]}")
    return written


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scenario")
    ap.add_argument("--out-dir")
    ap.add_argument("--scale", type=float, default=1.0)
    args = ap.parse_args(argv)
    font = find_font()
    print(f"font: {font[0]} (index {font[1]})", file=sys.stderr)
    render_scenario(args.scenario, args.out_dir, args.scale)
    return 0


if __name__ == "__main__":
    sys.exit(main())
