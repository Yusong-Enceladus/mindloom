"""(4) Whiteboard / notebook / sticky-note photos in handwriting-like faces.

Each character is drawn separately with jittered size, baseline and angle; each line gets its own slant;
then the surface is photographed (perspective, uneven light, glare, blur, noise, JPEG). Crossed-out lines
(`struck`) and ticked items (`checked`) are drawn as strokes and recorded in the ground truth.
"""

from __future__ import annotations

import random

from PIL import Image, ImageDraw, ImageFilter

from . import common as C
from . import fonts, photo

INKS = {"black": (32, 32, 38), "blue": (28, 68, 160), "red": (186, 40, 40), "green": (28, 118, 64)}
FAINT_INKS = {"black": (150, 150, 156), "blue": (130, 160, 206), "red": (214, 150, 150), "green": (140, 190, 150)}


# --------------------------------------------------------------------------- content
# each returns [(text, flags)] with flags from {"title", "struck", "checked"} and qa

def c_weekly(rng, similar):
    a, b = C.SIMILAR_ZH[0] if similar else rng.sample(C.ZH_NAMES, 2)
    d = C.rdate(rng); fee = rng.choice(["0.25%", "0.38%"]); amt = rng.choice([5.8, 6.2, 4.5]); k = rng.choice([3, 5])
    lines = [(f"周会 {d.month}/{d.day}", {"title"}),
             (f"1. 点单上线 → {d.month}/{min(28, d.day + 7)}", set()),
             (f"2. 支付走方案B，费率{fee}", set()),
             (f"3. 预算{amt}万（已确认）", {"checked"}),
             (f"4. 找{a}要样品×{k}", set()),
             (f"5. {b}：发票周五前开", set())]
    qa = [("支付走哪个方案？", "方案B", "exact"), ("预算是多少？", f"{amt}万", "number"),
          ("找谁要样品？", a, "exact"), ("要几件样品？", f"{k}", "number")]
    return lines, qa


def c_todo(rng, similar):
    d = C.rdate(rng); p = rng.choice([128, 135, 142]); q = rng.choice([10, 20])
    lines = [("待办", {"title"}),
             (f"豆子报价 {p}元/公斤", {"struck"}),
             (f"改为 {p - 6}元/公斤，订{q}公斤", set()),
             (f"{d.month}月{d.day}日前付定金", set()),
             ("磨豆机保养", {"checked"}),
             ("周六盘点库存", set())]
    qa = [("现在的豆子价格是多少？", f"{p - 6}元/公斤", "number"), ("订多少公斤？", f"{q}公斤", "number"),
          ("哪条被划掉了？", f"豆子报价 {p}元/公斤", "exact")]
    return lines, qa


def c_plan(rng, similar):
    a, b = C.SIMILAR_ZH[2] if similar else rng.sample(C.ZH_NAMES, 2)
    n = rng.choice([6, 8]); h = rng.choice([2, 3]); k = rng.choice([45, 60])
    lines = [("秋游方案", {"title"}),
             (f"人数：{n}户，约{n * 3}人", set()),
             (f"车程{h}小时，{k}座大巴", set()),
             (f"联系人：{a}", set()),
             (f"备选：{b}负责订餐", set()),
             ("雨天顺延一周", set())]
    qa = [("联系人是谁？", a, "exact"), ("谁负责订餐？", b, "exact"), ("车程多久？", f"{h}小时", "number")]
    return lines, qa


def c_formula(rng, similar):
    area = rng.choice([24, 26, 30]); loss = rng.choice([5, 8]); per = rng.choice([1.44, 1.2])
    need = round(area * (1 + loss / 100), 1)
    boxes = int(-(-need // per))
    lines = [("客厅瓷砖", {"title"}), (f"面积 {area}㎡", set()), (f"损耗 {loss}%", set()),
             (f"需要 {need}㎡", set()), (f"每箱 {per}㎡ → {boxes}箱", set())]
    qa = [("客厅面积多少？", f"{area}㎡", "number"), ("一共要几箱？", f"{boxes}箱", "number")]
    return lines, qa


def c_en_standup(rng, similar):
    a, b = C.SIMILAR_EN[0] if similar else rng.sample(C.EN_NAMES, 2)
    d = C.rdate(rng); ms = rng.choice([180, 240, 320])
    lines = [("Standup", {"title"}),
             (f"Checkout p95 = {ms} ms", set()),
             (f"{a}: fix retry bug", set()),
             (f"{b}: release notes", {"checked"}),
             ("Ship payments", {"struck"}),
             (f"Payments moved to {C.MONTHS_EN[d.month - 1]} {d.day}", set())]
    qa = [("What is checkout p95?", f"{ms} ms", "number"), ("Who fixes the retry bug?", a, "exact"),
          ("When are payments moved to?", f"{C.MONTHS_EN[d.month - 1]} {d.day}", "exact")]
    return lines, qa


def c_en_shopping(rng, similar):
    lb = rng.choice([2, 3]); oz = rng.choice([12, 16])
    lines = [("Groceries", {"title"}), (f"Coffee beans {lb} lb", set()), ("Oat milk x4", {"checked"}),
             (f"Honey {oz} oz", set()), ("Paper cups (100)", set()), ("Lemons", {"struck"})]
    qa = [("How many pounds of coffee beans?", f"{lb} lb", "number"), ("How much honey?", f"{oz} oz", "number")]
    return lines, qa


def c_sticky(rng, similar):
    """Sticky notes: groups of lines, one note each."""
    a, b = C.SIMILAR_ZH[4] if similar else rng.sample(C.ZH_NAMES, 2)
    d = C.rdate(rng); amt = rng.choice([860, 1280, 2150])
    notes = [[("交房租", set()), (f"{d.month}/{d.day}", set())],
             [(f"报销{amt}元", set()), ("找财务", set())],
             [(f"{a} 周三面试", set())],
             [(f"{b} 借的书", set()), ("月底还", set())]]
    qa = [("报销多少钱？", f"{amt}元", "number"), ("谁周三面试？", a, "exact"), ("房租哪天交？", f"{d.month}/{d.day}", "exact")]
    return notes, qa


CONTENT = {"weekly": (c_weekly, "zh"), "todo": (c_todo, "zh"), "plan": (c_plan, "zh"), "formula": (c_formula, "zh"),
           "en_standup": (c_en_standup, "en"), "en_shopping": (c_en_shopping, "en"), "sticky": (c_sticky, "zh")}


# --------------------------------------------------------------------------- handwriting

def hand_line(text: str, fkey: str, size: int, ink, rng: random.Random, messy: float = 1.0) -> Image.Image:
    """One line of text, character by character with jitter, on a transparent layer."""
    fonts.check(fkey, text)
    h = int(size * 1.9)
    layer = Image.new("RGBA", (int(size * 1.25 * len(text) + size * 2), h), (0, 0, 0, 0))
    x = size * 0.3
    base = h * 0.62
    drift = 0.0
    for ch in text:
        if ch == " ":
            x += size * rng.uniform(0.28, 0.4)
            continue
        cs = max(8, int(size * rng.uniform(1 - 0.07 * messy, 1 + 0.07 * messy)))
        f = fonts.font(fkey, cs)
        tile = Image.new("RGBA", (cs * 2, cs * 2), (0, 0, 0, 0))
        ImageDraw.Draw(tile).text((cs * 0.5, cs * 1.35), ch, font=f, fill=ink + (255,), anchor="ls")
        tile = tile.rotate(rng.uniform(-5, 5) * messy, resample=Image.BICUBIC)
        drift += rng.uniform(-0.6, 0.6) * messy
        drift = max(-size * 0.08, min(size * 0.08, drift))
        y = base - cs * 1.35 + drift + rng.uniform(-1.2, 1.2) * messy
        layer.alpha_composite(tile, (int(x - cs * 0.5), int(y)))
        adv = f.getlength(ch)
        x += adv * rng.uniform(0.96, 1.1 if messy > 0.5 else 1.04)
    layer = layer.crop((0, 0, int(x + size * 0.4), h))
    return layer.rotate(rng.uniform(-1.6, 1.6) * messy, resample=Image.BICUBIC, expand=True)


def marker_stroke(d: ImageDraw.ImageDraw, pts, ink, width, rng):
    jit = [(x + rng.uniform(-1.5, 1.5), y + rng.uniform(-1.5, 1.5)) for x, y in pts]
    d.line(jit, fill=ink, width=width, joint="curve")


def draw_board(lines, surface: str, fkey: str, inks, rng: random.Random, size: int, messy: float):
    """Returns the surface image with the text drawn, the flat GT lines, and whether it is a board."""
    W, H = (1800, 1200) if surface in ("whiteboard", "blackboard") else (1240, 1640)
    if surface == "whiteboard":
        board = photo.texture((W, H), (238, 240, 238), rng, grain=2, blotch=10)
        # faint ghosting of an earlier, erased drawing
        gd = ImageDraw.Draw(board)
        for _ in range(4):  # kept to the empty right-hand side, so it never reads as a strike-through
            x0, y0 = rng.randrange(int(W * 0.62), W - 100), rng.randrange(H)
            gd.line([(x0, y0), (x0 + rng.randrange(-300, 300), y0 + rng.randrange(-100, 100))], fill=(222, 224, 224), width=10)
        x0, y0, lh = 140, 120, int(size * 1.9)
    elif surface == "blackboard":
        board = photo.texture((W, H), (40, 62, 52), rng, grain=4, blotch=16)
        x0, y0, lh = 140, 120, int(size * 1.9)
    else:  # notebook paper
        board = photo.texture((W, H), (247, 243, 230), rng, grain=2, blotch=6)
        bd = ImageDraw.Draw(board)
        lh = int(size * 1.7)
        for yy in range(170, H - 60, lh):
            bd.line([(0, yy), (W, yy)], fill=(176, 196, 222), width=2)
        bd.line([(150, 0), (150, H)], fill=(222, 150, 150), width=2)
        x0, y0 = 190, 170 - int(size * 1.35)
    d = ImageDraw.Draw(board)
    out_lines = []
    y = y0
    for i, (text, flags) in enumerate(lines):
        ink = inks["title"] if "title" in flags else inks["body"]
        s = int(size * (1.25 if "title" in flags else 1.0))
        ln = hand_line(text, fkey, s, ink, rng, messy)
        x = x0 + (0 if "title" in flags else int(size * 0.4)) + rng.randrange(-8, 9)
        if "checked" in flags:
            cx, cy = x - int(size * 0.2), y + ln.size[1] * 0.55
            marker_stroke(d, [(cx - size * 0.55, cy), (cx - size * 0.3, cy + size * 0.3), (cx + size * 0.1, cy - size * 0.35)],
                          inks["mark"], max(3, size // 9), rng)
            x += int(size * 0.3)
        board.paste(ln, (x, int(y)), ln)
        if "struck" in flags:
            sy = y + ln.size[1] * 0.55
            marker_stroke(d, [(x + size * 0.2, sy + rng.uniform(-3, 3)), (x + ln.size[0] - size * 0.3, sy + rng.uniform(-6, 6))],
                          inks["body"], max(3, size // 10), rng)
        out_lines.append({"text": text, "struck": "struck" in flags, "checked": "checked" in flags,
                          "is_title": "title" in flags})
        y += lh if surface == "notebook" else int(ln.size[1] * 1.08)
    if surface in ("whiteboard", "blackboard"):
        fr = Image.new("RGB", (W + 60, H + 60), (168, 170, 174))
        fr.paste(board, (30, 30))
        board = fr
    return board, out_lines


def draw_sticky(notes, fkey, rng: random.Random, size: int, messy: float):
    W, H = 1800, 1200
    wall = photo.texture((W, H), (236, 238, 236), rng, grain=2, blotch=10)
    colors = [(252, 236, 120), (250, 190, 200), (170, 220, 245), (200, 236, 170)]
    out, cols = [], 2 if len(notes) <= 4 else 3
    note_w, note_h = 640, 420
    for i, note in enumerate(notes):
        r, c = divmod(i, cols)
        pad = Image.new("RGBA", (note_w, note_h), colors[i % len(colors)] + (255,))
        pd = ImageDraw.Draw(pad)
        pd.rectangle([0, 0, note_w, 50], fill=tuple(max(0, v - 18) for v in colors[i % len(colors)]) + (255,))
        y = 90
        lines = []
        for text, flags in note:
            ln = hand_line(text, fkey, size, INKS["black"], rng, messy)
            if ln.size[0] > note_w - 50:
                raise ValueError(f"sticky note line too wide: {text!r}")
            pad.alpha_composite(ln, (40, y))
            y += int(ln.size[1] * 1.05)
            lines.append({"text": text, "struck": False, "checked": False, "is_title": False})
        pad = pad.rotate(rng.uniform(-4, 4), resample=Image.BICUBIC, expand=True)
        x = 160 + c * (note_w + 160) + rng.randrange(-20, 20)
        yy = 110 + r * (note_h + 120) + rng.randrange(-20, 20)
        shadow = Image.new("RGBA", pad.size, (0, 0, 0, 0))
        shadow.paste((0, 0, 0, 60), mask=pad.split()[3])
        wall = wall.convert("RGBA")
        wall.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(6)), (x + 8, yy + 10))
        wall.alpha_composite(pad, (x, yy))
        out.append({"lines": lines})
    return wall.convert("RGB"), out


# symbols some handwriting faces lack, with what a person would write instead
_SUBST = [("㎡", ["m²", "m2"]), ("→", ["->"]), ("×", ["x"]), ("：", [":"]), ("（", ["("]), ("）", [")"]), ("，", [","])]


def fit_glyphs(text: str, fkey: str) -> str:
    for sym, alts in _SUBST:
        if sym in text and not fonts.has_glyphs(fkey, sym):
            for alt in alts:
                if fonts.has_glyphs(fkey, alt):
                    text = text.replace(sym, alt)
                    break
    return text


def build(idx: int, v: dict, rng: random.Random) -> dict:
    fn, lang = CONTENT[v["content"]]
    content, qa = fn(rng, v.get("similar", False))
    fkey = v["font"]
    # the ground truth is what is written: substitute symbols the face cannot draw, in lines and answers
    if v["content"] == "sticky":
        content = [[(fit_glyphs(t, fkey), f) for t, f in note] for note in content]
    else:
        content = [(fit_glyphs(t, fkey), f) for t, f in content]
    qa = [(q, fit_glyphs(a, fkey), m) for q, a, m in qa]
    surface = v.get("surface", "whiteboard")
    size = v.get("size", 64)
    messy = v.get("messy", 1.0)
    faint = v.get("faint", False)
    hard = ["handwriting"]
    if v["content"] == "sticky":
        img, notes = draw_sticky(content, fkey, rng, size, messy)
        lines = [ln for n in notes for ln in n["lines"]]
        gt = {"surface": "sticky_notes", "notes": notes, "lines": lines}
        surface = "sticky_notes"
    else:
        ink_set = FAINT_INKS if faint else INKS
        if surface == "blackboard":
            inks = {"title": (236, 236, 228), "body": (226, 228, 220) if not faint else (120, 138, 128), "mark": (240, 220, 120)}
        else:
            body = rng.choice(["black", "blue"])
            inks = {"title": ink_set["red" if surface == "whiteboard" else body], "body": ink_set[body],
                    "mark": ink_set["green"]}
        board, lines = draw_board(content, surface, fkey, inks, rng, size, messy)
        img = board.convert("RGB")
        gt = {"surface": surface, "lines": lines}
    # photograph it
    cw, ch = (1600, 1200) if img.size[0] >= img.size[1] else (1200, 1600)
    bg = photo.background((cw, ch), rng.choice(["wall", "desk_grey", "wood"]) if surface == "notebook" else "wall", rng)
    fill = 0.62 if v.get("far") else 0.9
    quad = photo.jitter_quad(img.size[0], img.size[1], cw, ch, rng, fill=fill, tilt=v.get("tilt", 0.07), rot_deg=4)
    if surface == "notebook":
        bg = photo.drop_shadow(bg, quad, rng)
    shot = photo.place(img, bg, quad)
    shot = photo.lighting(shot, rng, strength=0.22, vignette=0.2)
    if v.get("glare", surface in ("whiteboard",)):
        shot = photo.glare(shot, rng, strength=0.5 if surface == "whiteboard" else 0.3)
        hard.append("glare")
    if v.get("shadow"):
        shot = photo.cast_shadow(shot, rng)
    shot = photo.blur(shot, v.get("blur", 0.8))
    shot = photo.noise(shot, rng, sigma=5)
    if v.get("far"):
        shot = photo.resize_long(shot, 1100)
        hard.append("small_text")
    shot = photo.add_mark(shot, corner="br")
    if faint:
        hard.append("low_contrast")
    if fkey == "hand_xing":
        hard.append("cursive")
    if v.get("similar"):
        hard.append("similar_names")
    if any(ln["struck"] for ln in gt["lines"]):
        hard.append("struck_items")
    texts = [ln["text"] for ln in gt["lines"]]
    if C.has_units(texts):
        hard.append("units")
    hard.append("perspective")
    return {"image": shot, "ext": "jpg", "quality": 80, "lang": lang if lang == "en" else C.mixed_lang(" ".join(texts)),
            "hard": sorted(set(hard), key=hard.index),
            "render": {"surface": surface, "font": fkey, "size": size, "messy": messy, "faint": faint},
            "gt": gt, "text_lines": texts,
            "qa": [{"q": q, "a": a, "match": m} for q, a, m in qa], "topic": v["content"]}
