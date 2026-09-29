"""(5) Receipts (thermal slips) and invoices / sales orders of invented shops, photographed on a desk.

Amounts are computed, not typed: every line amount is qty x unit price rounded to cents, and the
subtotal, discount, tax and total are recomputed from them, so the ground truth is self-consistent.
The layouts are generic; nothing imitates a government tax invoice or a real shop.
"""

from __future__ import annotations

import datetime as dt
import random

from PIL import Image, ImageDraw

from . import common as C
from . import fonts, photo

# name, unit, unit price, weighed (qty has 2-3 decimals)
ZH_ITEMS = {
    "grocery": [("香蕉", "kg", 7.98, True), ("西红柿", "kg", 6.58, True), ("鸡蛋 30枚", "盒", 15.80, False),
                ("纯牛奶 250mL×12", "箱", 59.90, False), ("大米 5kg", "袋", 39.90, False), ("原味酸奶", "杯", 4.50, False),
                ("全麦面包", "个", 8.00, False), ("苹果", "kg", 12.60, True)],
    "coffee": [("拿铁（大杯）", "杯", 28.00, False), ("拿铁（中杯）", "杯", 25.00, False), ("美式（中杯）", "杯", 20.00, False),
               ("手冲 耶加雪菲", "杯", 38.00, False), ("可颂", "个", 16.00, False), ("燕麦奶 加料", "份", 3.00, False)],
    "hardware": [("自攻螺丝 M4×20", "盒", 6.50, False), ("钻头 6mm", "支", 12.00, False), ("布基胶带 48mm", "卷", 5.50, False),
                 ("延长线插座 3m", "个", 39.00, False), ("PVC 水管 20mm", "m", 4.20, True)],
    "stationery": [("A4 复印纸 500张", "包", 26.90, False), ("中性笔 0.5mm", "支", 2.50, False), ("文件夹", "个", 4.80, False),
                   ("便利贴 76×76mm", "本", 3.60, False)],
    "wholesale": [("咖啡豆 云南水洗 1kg", "袋", 126.00, False), ("咖啡豆 云南日晒 1kg", "袋", 118.00, False),
                  ("燕麦奶 1L", "盒", 16.50, False), ("纸杯 12oz（50只）", "条", 22.00, False), ("杯盖 90mm（100只）", "条", 15.00, False)],
}
EN_ITEMS = {
    "coffee": [("Latte (L)", "ea", 5.25, False), ("Latte (M)", "ea", 4.75, False), ("Americano (M)", "ea", 3.95, False),
               ("Croissant", "ea", 3.50, False), ("Oat milk add-on", "ea", 0.60, False)],
    "hardware": [("Wood screws #8 x 1-1/4in", "box", 6.49, False), ("Painter's tape 2in", "roll", 7.99, False),
                 ("Extension cord 10 ft", "ea", 14.99, False), ("Copper wire", "ft", 0.45, True)],
    "grocery": [("Bananas", "lb", 0.69, True), ("Eggs, dozen", "ea", 4.29, False), ("Oat milk 64 oz", "ea", 4.99, False),
                ("Sourdough loaf", "ea", 6.50, False), ("Apples", "lb", 1.89, True)],
    "wholesale": [("Coffee beans, washed, 1 kg", "bag", 21.40, False), ("Coffee beans, natural, 1 kg", "bag", 19.80, False),
                  ("Oat milk 1 L", "carton", 2.35, False), ("Paper cups 12 oz (50)", "sleeve", 3.90, False)],
}
# near-identical names that must stay apart when `similar` is set
SIMILAR_NAMES = [("拿铁（大杯）", "拿铁（中杯）"), ("咖啡豆 云南水洗 1kg", "咖啡豆 云南日晒 1kg"), ("Latte (L)", "Latte (M)"),
                 ("Coffee beans, washed, 1 kg", "Coffee beans, natural, 1 kg")]
ZH_SHOP_KIND = {"青禾便利店": "grocery", "禾木生鲜超市": "grocery", "南巷咖啡": "coffee", "鹿野咖啡": "coffee",
                "橙石五金": "hardware", "北窗文具": "stationery"}
EN_SHOP_KIND = {"Maple & Pine Grocery": "grocery", "Harborlane Coffee Co.": "coffee", "Bluewren Hardware": "hardware"}


def pick_items(rng, pool, k, similar):
    items = rng.sample(pool, min(k, len(pool)))
    if similar:  # both sizes of the same drink / near-identical names on one slip
        names = {n for pr in SIMILAR_NAMES for n in pr}
        pair = [it for it in pool if it[0] in names][:2]
        assert len(pair) == 2, "no similar pair in this pool"
        items = [it for it in items if it not in pair][: k - 2] + pair
        rng.shuffle(items)
    out = []
    for name, unit, price, weighed in items:
        if weighed:
            qty = round(rng.uniform(0.3, 2.6), 3 if unit == "kg" else 2)
        else:
            qty = rng.choice([1, 1, 1, 2, 2, 3, 4])
        amount = round(qty * price + 1e-9, 2)
        out.append({"name": name, "qty": qty, "unit": unit, "unit_price": price, "amount": amount, "weighed": weighed})
    return out


def qty_text(it):
    if it["weighed"]:
        return f"{it['qty']:.3f}{it['unit']}" if it["unit"] == "kg" else f"{it['qty']:.2f}{it['unit']}"
    return str(it["qty"])


# --------------------------------------------------------------------------- thermal receipt

def render_receipt(r: dict, lang: str, rng: random.Random, faint: bool) -> Image.Image:
    W = 620
    key, bkey = ("hei", "hei_bold") if lang == "zh" else ("mono", "mono_bold")
    f = fonts.font(key, 24)
    fb = fonts.font(bkey, 34)
    img = Image.new("RGB", (W, 2400), (250, 250, 246))
    d = ImageDraw.Draw(img)
    ink = (60, 60, 64) if not faint else (150, 150, 152)
    y = 40

    def center(text, font, k):
        nonlocal y
        d.text((W / 2, y), fonts.check(k, text), font=font, fill=ink, anchor="mt")
        y += int(font.size * 1.45)

    def left_right(lt, rt, k=key, font=f):
        nonlocal y
        d.text((30, y), fonts.check(k, lt), font=font, fill=ink)
        if rt:
            d.text((W - 30, y), fonts.check(k, rt), font=font, fill=ink, anchor="ra")
        y += int(font.size * 1.5)

    def rule():
        nonlocal y
        for x in range(30, W - 30, 14):
            d.line([(x, y + 8), (x + 7, y + 8)], fill=ink, width=2)
        y += 24

    center(r["merchant"], fb, bkey)
    for ln in r["header_lines"]:
        center(ln, f, key)
    rule()
    for lt, rt in r["meta_lines"]:
        left_right(lt, rt)
    rule()
    cols = [30, 300, 474, W - 30]  # name (left), qty (left), unit price (right edge), amount (right edge)
    hdr = ("品名", "数量", "单价", "金额") if lang == "zh" else ("Item", "Qty", "Price", "Amount")
    d.text((cols[0], y), fonts.check(key, hdr[0]), font=f, fill=ink)
    d.text((cols[1], y), fonts.check(key, hdr[1]), font=f, fill=ink)
    d.text((cols[2], y), fonts.check(key, hdr[2]), font=f, fill=ink, anchor="ra")
    d.text((cols[3], y), fonts.check(key, hdr[3]), font=f, fill=ink, anchor="ra")
    y += 38
    for it in r["items"]:
        name = it["name"]
        if d.textlength(name, font=f) > cols[1] - cols[0] - 10:  # long name on its own line
            d.text((cols[0], y), fonts.check(key, name), font=f, fill=ink)
            y += 34
            name = ""
        d.text((cols[0], y), fonts.check(key, name), font=f, fill=ink)
        d.text((cols[1], y), fonts.check(key, qty_text(it)), font=f, fill=ink)
        d.text((cols[2], y), fonts.check(key, f"{it['unit_price']:.2f}"), font=f, fill=ink, anchor="ra")
        d.text((cols[3], y), fonts.check(key, f"{it['amount']:.2f}"), font=f, fill=ink, anchor="ra")
        y += 38
    rule()
    for lt, rt in r["total_lines"]:
        big = lt.startswith(("实付", "Total"))
        left_right(lt, rt, bkey if big else key, fonts.font(bkey, 30) if big else f)
    rule()
    for ln in r["footer_lines"]:
        center(ln, f, key)
    # barcode (random bars, not an encoding of anything)
    y += 10
    x = 90
    while x < W - 90:
        wbar = rng.choice([2, 2, 3, 4, 6])
        d.rectangle([x, y, x + wbar, y + 70], fill=ink)
        x += wbar + rng.choice([2, 3, 4, 5])
    y += 90
    return img.crop((0, 0, W, y + 30))


def receipt_content(rng: random.Random, lang: str, similar: bool) -> dict:
    if lang == "zh":
        merchant = rng.choice(list(ZH_SHOP_KIND))
        kind = ZH_SHOP_KIND[merchant]
        if similar:
            merchant, kind = rng.choice(["南巷咖啡", "鹿野咖啡"]), "coffee"
        items = pick_items(rng, ZH_ITEMS[kind], rng.randrange(3, 7), similar)
    else:
        merchant = rng.choice(list(EN_SHOP_KIND))
        kind = EN_SHOP_KIND[merchant]
        if similar:
            merchant, kind = "Harborlane Coffee Co.", "coffee"
        items = pick_items(rng, EN_ITEMS[kind], rng.randrange(3, 6), similar)
    day = C.rdate(rng)
    t = dt.time(rng.randrange(8, 21), rng.randrange(60))
    subtotal = round(sum(it["amount"] for it in items), 2)
    r = {"merchant": merchant, "items": items, "date": day.isoformat(), "time": f"{t.hour:02d}:{t.minute:02d}",
         "currency": "CNY" if lang == "zh" else "USD", "subtotal": subtotal, "discount": 0.0, "tax": 0.0}
    if lang == "zh":
        disc = rng.choice([0, 0, 2, 5, 10]) if subtotal > 30 else 0
        total = round(subtotal - disc, 2)
        no = f"{day:%Y%m%d}{rng.randrange(1000, 9999)}"
        pay = rng.choice(["扫码支付", "现金", "会员卡", "银行卡"])
        r.update(discount=float(disc), total=total, receipt_no=no, payment_method=pay)
        city, dist, road = rng.choice(C.ZH_CITIES), rng.choice(C.ZH_DISTRICTS), rng.choice(C.ZH_ROADS)
        r["header_lines"] = [f"{city}{dist}{road}{rng.randrange(1, 200)}号", f"电话：0000-{rng.randrange(1000, 9999)}"]
        r["meta_lines"] = [(f"单号：{no}", f"收银员：{rng.randrange(1, 20):02d}"), (f"日期：{day.isoformat()} {r['time']}", "")]
        r["total_lines"] = [(f"合计件数：{len(items)}", ""), ("小计", f"{subtotal:.2f}")]
        if disc:
            r["total_lines"].append(("优惠", f"-{disc:.2f}"))
        r["total_lines"] += [("实付", f"¥{total:.2f}"), (f"支付方式：{pay}", "")]
        r["footer_lines"] = ["谢谢惠顾，欢迎再次光临", "请妥善保管小票，7日内凭票退换"]
        r["date_text"] = f"{day.isoformat()} {r['time']}"
    else:
        rate = rng.choice([6.25, 7.5, 8.25])
        tax = round(subtotal * rate / 100 + 1e-9, 2)
        total = round(subtotal + tax, 2)
        no = f"{rng.randrange(1000, 9999)}"
        pay = rng.choice(["Card", "Cash", "Mobile pay"])
        r.update(tax=tax, tax_rate=rate, total=total, receipt_no=no, payment_method=pay)
        h12 = t.hour % 12 or 12
        tt = f"{h12}:{t.minute:02d} {'AM' if t.hour < 12 else 'PM'}"
        r["header_lines"] = [f"{rng.randrange(10, 400)} {rng.choice(C.EN_STREETS)}, {rng.choice(C.EN_TOWNS)}",
                             f"Tel (555) 01{rng.randrange(0, 10)}-{rng.randrange(1000, 9999)}"]
        r["meta_lines"] = [(f"Order #{no}", f"Cashier {rng.randrange(1, 20):02d}"), (f"{day:%m/%d/%Y} {tt}", "")]
        r["total_lines"] = [("Subtotal", f"{subtotal:.2f}"), (f"Tax {rate}%", f"{tax:.2f}"), ("Total", f"${total:.2f}"),
                            (f"Paid: {pay}", "")]
        r["footer_lines"] = ["Thank you!", "Returns within 14 days with receipt"]
        r["date_text"] = f"{day:%m/%d/%Y} {tt}"
    return r


# --------------------------------------------------------------------------- invoice / sales order

def render_invoice(r: dict, lang: str) -> Image.Image:
    W, H = 1240, 1754
    key, bkey = ("song", "hei_bold") if lang == "zh" else ("times", "helv_bold")
    img = Image.new("RGB", (W, H), (252, 252, 250))
    d = ImageDraw.Draw(img)
    ink = (34, 34, 40)
    f, fb, ft = fonts.font(key, 28), fonts.font(bkey, 30), fonts.font(bkey, 56)
    d.text((W / 2, 120), fonts.check(bkey, r["doc_title"]), font=ft, fill=ink, anchor="mm")
    d.text((W / 2, 190), fonts.check(key, r["merchant"]), font=fonts.font(key, 32), fill=ink, anchor="mm")
    y = 260
    for lt, rt in r["meta_lines"]:
        d.text((100, y), fonts.check(key, lt), font=f, fill=ink)
        if rt:
            d.text((W - 100, y), fonts.check(key, rt), font=f, fill=ink, anchor="ra")
        y += 46
    y += 20
    cols = r["columns"]
    xs = [100, 180, 560, 690, 800, 950, W - 100]
    d.rectangle([xs[0], y, xs[-1], y + 56], outline=ink, width=2, fill=(236, 238, 242))
    for i, c in enumerate(cols):
        d.text(((xs[i] + xs[i + 1]) / 2, y + 28), fonts.check(bkey, c), font=fonts.font(bkey, 26), fill=ink, anchor="mm")
    y += 56
    for n, it in enumerate(r["items"], 1):
        cells = [str(n), it["name"], qty_text(it) if it["weighed"] else str(it["qty"]), it["unit"],
                 f"{it['unit_price']:,.2f}", f"{it['amount']:,.2f}"]
        d.rectangle([xs[0], y, xs[-1], y + 56], outline=ink, width=1)
        for i, c in enumerate(cells):
            fonts.check(key, c)
            if i in (4, 5):
                d.text((xs[i + 1] - 14, y + 28), c, font=f, fill=ink, anchor="rm")
            elif i == 1:
                d.text((xs[i] + 14, y + 28), c, font=f, fill=ink, anchor="lm")
            else:
                d.text(((xs[i] + xs[i + 1]) / 2, y + 28), c, font=f, fill=ink, anchor="mm")
        y += 56
    for x in xs[1:-1]:
        d.line([(x, y - 56 * (len(r["items"]) + 1)), (x, y)], fill=ink, width=1)
    y += 30
    for lt, rt in r["total_lines"]:
        d.text((xs[-1] - 300, y), fonts.check(key, lt), font=fb if lt.startswith(("合计", "Total")) else f, fill=ink, anchor="ra")
        d.text((xs[-1], y), fonts.check(key, rt), font=fb if lt.startswith(("合计", "Total")) else f, fill=ink, anchor="ra")
        y += 48
    y += 20
    for ln in r["footer_lines"]:
        for part in C.wrap(ln, f, W - 200, d):
            d.text((100, y), fonts.check(key, part), font=f, fill=ink)
            y += 44
    # a stamp-like ring with the word 已收款 / PAID (generic, no organisation name)
    if r.get("paid_stamp"):
        cx, cy = W - 300, y + 90
        col = (200, 60, 60)
        d.ellipse([cx - 110, cy - 110, cx + 110, cy + 110], outline=col, width=6)
        d.text((cx, cy), fonts.check(bkey, r["paid_stamp"]), font=fonts.font(bkey, 44), fill=col, anchor="mm")
    return img


def invoice_content(rng: random.Random, lang: str, similar: bool) -> dict:
    day = C.rdate(rng)
    if lang == "zh":
        kind = "wholesale" if similar else rng.choice(["wholesale", "stationery", "hardware"])
        seller = {"wholesale": "穗禾里食品有限公司", "stationery": "拾光文化传媒", "hardware": "云岭电器有限公司"}[kind]
        buyer = rng.choice([c for c in C.ZH_COMPANIES if c != seller])
        items = pick_items(rng, ZH_ITEMS[kind], rng.randrange(3, 6), similar)
        for it in items:  # wholesale quantities
            if not it["weighed"]:
                it["qty"] = it["qty"] * rng.choice([10, 12, 20])
                it["amount"] = round(it["qty"] * it["unit_price"], 2)
        subtotal = round(sum(it["amount"] for it in items), 2)
        no = f"XS-{day:%Y%m%d}-{rng.randrange(100, 999)}"
        doc_title = rng.choice(["销售单", "送货单"])
        r = {"doc_title": doc_title, "merchant": seller, "buyer": buyer, "items": items, "date": day.isoformat(),
             "receipt_no": no, "currency": "CNY", "subtotal": subtotal, "discount": 0.0, "tax": 0.0, "total": subtotal,
             "payment_method": rng.choice(["银行转账", "月结"]), "total_in_words": C.cjk_upper(subtotal)}
        r["meta_lines"] = [(f"客户：{buyer}", f"单号：{no}"), (f"日期：{day.year}年{day.month}月{day.day}日", f"结算方式：{r['payment_method']}")]
        r["columns"] = ["序号", "品名规格", "数量", "单位", "单价（元）", "金额（元）"]
        r["total_lines"] = [("合计金额：", f"¥{subtotal:,.2f}"), ("大写：", r["total_in_words"])]
        r["footer_lines"] = ["备注：货物当面点清，如有质量问题请于 3 日内联系。", f"开单人：{rng.choice(C.ZH_NAMES)}"]
        r["paid_stamp"] = "已收款" if rng.random() < 0.5 else None
        r["date_text"] = f"{day.year}年{day.month}月{day.day}日"
    else:
        kind = "wholesale" if similar else rng.choice(["wholesale", "hardware"])
        seller = "Fernhollow Foods Inc." if kind == "wholesale" else "Tallpine Logistics LLC"
        buyer = rng.choice([c for c in C.EN_COMPANIES if c != seller])
        items = pick_items(rng, EN_ITEMS[kind], rng.randrange(3, 5), similar)
        for it in items:
            if not it["weighed"]:
                it["qty"] = it["qty"] * rng.choice([10, 12, 24])
                it["amount"] = round(it["qty"] * it["unit_price"], 2)
        subtotal = round(sum(it["amount"] for it in items), 2)
        rate = rng.choice([6.25, 8.25])
        tax = round(subtotal * rate / 100 + 1e-9, 2)
        total = round(subtotal + tax, 2)
        no = f"INV-{day:%Y}-{rng.randrange(1000, 9999)}"
        due = day + dt.timedelta(days=30)
        r = {"doc_title": "INVOICE", "merchant": seller, "buyer": buyer, "items": items, "date": day.isoformat(),
             "receipt_no": no, "currency": "USD", "subtotal": subtotal, "discount": 0.0, "tax": tax, "tax_rate": rate,
             "total": total, "payment_method": "Bank transfer", "due_date": due.isoformat()}
        r["meta_lines"] = [(f"Bill to: {buyer}", f"Invoice no.: {no}"),
                           (f"Date: {C.MONTHS_EN[day.month - 1]} {day.day}, {day.year}",
                            f"Due: {C.MONTHS_EN[due.month - 1]} {due.day}, {due.year}")]
        r["columns"] = ["#", "Description", "Qty", "Unit", "Unit price", "Amount"]
        r["total_lines"] = [("Subtotal", f"${subtotal:,.2f}"), (f"Tax ({rate}%)", f"${tax:,.2f}"), ("Total due", f"${total:,.2f}")]
        r["footer_lines"] = ["Payment terms: net 30 days by bank transfer. Please quote the invoice number."]
        r["paid_stamp"] = "PAID" if rng.random() < 0.4 else None
        r["date_text"] = f"{C.MONTHS_EN[day.month - 1]} {day.day}, {day.year}"
    return r


def build(idx: int, v: dict, rng: random.Random) -> dict:
    lang = v.get("lang", "zh")
    doc_kind = v.get("kind", "receipt")
    similar = v.get("similar", False)
    faint = v.get("faint", False)
    hard = []
    if doc_kind == "receipt":
        r = receipt_content(rng, lang, similar)
        clean = render_receipt(r, lang, rng, faint)
        if v.get("curl", True):
            clean = photo.curl(clean, rng, amp=rng.uniform(3, 7))
        cw, ch = 1200, 1600
        fill = 0.9 if not v.get("far") else 0.62
    else:
        r = invoice_content(rng, lang, similar)
        clean = render_invoice(r, lang)
        if faint:
            clean = photo.contrast(clean, 0.45)
        cw, ch = 1200, 1600
        fill = 0.92 if not v.get("far") else 0.7
    bg = photo.background((cw, ch), v.get("bg", rng.choice(["wood", "desk_grey", "fabric_blue"])), rng)
    quad = photo.jitter_quad(clean.size[0], clean.size[1], cw, ch, rng, fill=fill, tilt=v.get("tilt", 0.06), rot_deg=5)
    bg = photo.drop_shadow(bg, quad, rng)
    shot = photo.place(clean, bg, quad)
    shot = photo.lighting(shot, rng, strength=0.25, vignette=0.25)
    if v.get("shadow"):
        shot = photo.cast_shadow(shot, rng, strength=0.32)
        hard.append("shadow")
    if v.get("glare"):
        shot = photo.glare(shot, rng, strength=0.4)
        hard.append("glare")
    shot = photo.blur(shot, v.get("blur", 0.7))
    shot = photo.noise(shot, rng, sigma=4)
    if v.get("far"):
        shot = photo.resize_long(shot, 1000)
        hard.append("small_text")
    shot = photo.add_mark(shot, corner="tr")
    if faint:
        hard.append("low_contrast")
    if similar:
        hard.append("similar_items")
    if any(it["weighed"] for it in r["items"]):
        hard.append("units")
    hard.append("perspective")
    items_gt = [{"name": it["name"], "qty": it["qty"], "unit": it["unit"], "unit_price": f"{it['unit_price']:.2f}",
                 "amount": f"{it['amount']:.2f}"} for it in r["items"]]
    gt = {"doc_kind": doc_kind if doc_kind == "receipt" else "invoice", "merchant": r["merchant"],
          "date": r["date"], "date_text": r["date_text"], "time": r.get("time", ""), "doc_no": r["receipt_no"],
          "currency": r["currency"], "items": items_gt, "subtotal": f"{r['subtotal']:.2f}",
          "discount": f"{r['discount']:.2f}", "tax": f"{r['tax']:.2f}", "total": f"{r['total']:.2f}",
          "payment_method": r["payment_method"]}
    for k in ("buyer", "tax_rate", "due_date", "total_in_words"):
        if k in r:
            gt[k] = r[k]
    # self-consistency
    assert abs(sum(float(it["amount"]) for it in items_gt) - r["subtotal"]) < 0.005
    assert abs(r["subtotal"] - r["discount"] + r["tax"] - r["total"]) < 0.005
    text_lines = [r.get("doc_title", "")] if doc_kind != "receipt" else []
    text_lines += [r["merchant"]] + r.get("header_lines", []) + [f"{a} {b}".strip() for a, b in r["meta_lines"]]
    text_lines += [f"{it['name']} {qty_text(it)} {it['unit_price']:.2f} {it['amount']:.2f}" for it in r["items"]]
    text_lines += [f"{a} {b}".strip() for a, b in r["total_lines"]] + r["footer_lines"]
    cur = "元" if lang == "zh" else ""
    sym = "¥" if lang == "zh" else "$"
    if lang == "zh":
        qa = [("这张单据的实付/合计金额是多少？", f"{sym}{r['total']:,.2f}", "number"), ("商家是哪家？", r["merchant"], "exact"),
              ("消费日期是哪天？", r["date"], "date")]
        big = max(r["items"], key=lambda it: it["amount"])
        qa.append((f"{big['name']}的金额是多少？", f"{big['amount']:,.2f}{cur}", "number"))
    else:
        qa = [("What is the total?", f"{sym}{r['total']:,.2f}", "number"), ("Which business issued it?", r["merchant"], "exact"),
              ("What is the date?", r["date"], "date")]
        if r["tax"]:
            qa.append(("How much tax?", f"{sym}{r['tax']:,.2f}", "number"))
    return {"image": shot, "ext": "jpg", "quality": 80, "lang": lang, "hard": hard,
            "render": {"doc_kind": doc_kind, "faint": faint, "curl": doc_kind == "receipt" and v.get("curl", True)},
            "gt": gt, "text_lines": [t for t in text_lines if t],
            "qa": [{"q": q, "a": a, "match": m} for q, a, m in qa], "topic": doc_kind}
