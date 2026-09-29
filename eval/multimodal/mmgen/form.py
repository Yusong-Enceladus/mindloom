"""(7) Photos of printed forms, labels and signs: shipping labels, equipment nameplates, shelf price tags,
room signs, opening-hours / parking notices, handwritten repair forms and warehouse bin labels.

Ground truth: `fields` = [{key, label, value}] where key is a stable English name, label is the printed
caption ("" when the sign has none) and value the printed (or handwritten) value; `lines` = every
printed line in reading order. Carriers, makers and shops are invented; phone numbers are masked or
use reserved fictional ranges.
"""

from __future__ import annotations

import random

from PIL import Image, ImageDraw

from . import common as C
from . import fonts, photo
from .whiteboard import hand_line


def _barcode(d, x0, y0, x1, h, rng, ink=(20, 20, 20)):
    x = x0
    while x < x1:
        w = rng.choice([2, 2, 3, 4, 5])
        d.rectangle([x, y0, x + w, y0 + h], fill=ink)
        x += w + rng.choice([2, 3, 4])


class Canvas:
    """Tiny layout helper: draw text and remember it as a GT line."""

    def __init__(self, size, bg, key="hei", bold="hei_bold"):
        self.img = Image.new("RGB", size, bg)
        self.d = ImageDraw.Draw(self.img)
        self.key, self.bold = key, bold
        self.lines: list[str] = []

    def text(self, xy, s, size, fill=(20, 20, 20), bold=False, anchor="la", record=True, key=None):
        k = key or (self.bold if bold else self.key)
        self.d.text(xy, fonts.check(k, s), font=fonts.font(k, size), fill=fill, anchor=anchor)
        if record:
            self.lines.append(s)

    def width(self, s, size, bold=False):
        return self.d.textlength(s, font=fonts.font(self.bold if bold else self.key, size))


# --------------------------------------------------------------------------- label kinds
# each returns (image, fields [(key, label, value)], qa, hard, lang, background kind)

def shipping_label(rng, v):
    lang = v.get("lang", "zh")
    cv = Canvas((900, 1300), (252, 252, 250), *(("hei", "hei_bold") if lang == "zh" else ("helv", "helv_bold")))
    d = cv.d
    wt = round(rng.uniform(0.4, 9.5), 2)
    no = " ".join(str(rng.randrange(1000, 9999)) for _ in range(3))
    day = C.rdate(rng)
    if lang == "zh":
        names = list(C.SIMILAR_ZH[0]) if v.get("similar") else rng.sample(C.ZH_NAMES, 2)
        rcv, snd = names
        city, dist, road = rng.choice(C.ZH_CITIES), rng.choice(C.ZH_DISTRICTS), rng.choice(C.ZH_ROADS)
        raddr = f"{city}{dist}{road}{rng.randrange(1, 300)}号{rng.randrange(1, 20)}栋{rng.randrange(1, 30)}0{rng.randrange(1, 6)}"
        saddr = f"{rng.choice(C.ZH_CITIES)}{rng.choice(C.ZH_DISTRICTS)}{rng.choice(C.ZH_ROADS)}{rng.randrange(1, 300)}号"
        rphone = f"1{rng.choice([3, 5, 8])}{rng.randrange(0, 10)}****{rng.randrange(1000, 9999)}"
        sphone = f"1{rng.choice([3, 5, 8])}{rng.randrange(0, 10)}****{rng.randrange(1000, 9999)}"
        goods = rng.choice(["咖啡豆样品", "文件", "服装", "电子配件"])
        d.rectangle([0, 0, 900, 130], fill=(30, 30, 30))
        cv.text((40, 65), "示例快运", 56, fill=(255, 255, 255), bold=True, anchor="lm")
        cv.text((860, 65), "标准快递", 34, fill=(255, 255, 255), anchor="rm")
        route = f"{city[:2]}-{dist[:2]} {rng.choice('ABCDEF')}{rng.randrange(10, 99)}"
        cv.text((450, 200), route, 64, bold=True, anchor="mm")
        _barcode(d, 90, 260, 810, 150, rng)
        cv.text((450, 450), f"运单号 {no}", 34, anchor="mm")
        d.line([30, 500, 870, 500], fill=(0, 0, 0), width=3)
        cv.text((40, 530), "收", 44, bold=True)
        cv.text((110, 530), f"{rcv}  {rphone}", 38, bold=True)
        y = 590
        for part in C.wrap(raddr, fonts.font("hei", 34), 740):
            cv.text((110, y), part, 34)
            y += 46
        d.line([30, 720, 870, 720], fill=(0, 0, 0), width=2)
        cv.text((40, 750), "寄", 44, bold=True)
        cv.text((110, 750), f"{snd}  {sphone}", 32)
        cv.text((110, 800), saddr, 30)
        d.line([30, 870, 870, 870], fill=(0, 0, 0), width=2)
        cv.text((40, 900), f"物品：{goods}", 32)
        cv.text((40, 950), f"重量：{wt}kg", 32)
        cv.text((460, 950), "件数：1/1", 32)
        cv.text((40, 1000), f"寄件日期：{day.isoformat()}", 32)
        cv.text((40, 1060), "签收人：", 32)
        fields = [("carrier", "", "示例快运"), ("tracking_no", "运单号", no), ("recipient", "收", rcv), ("recipient_phone", "", rphone),
                  ("recipient_address", "", raddr), ("sender", "寄", snd), ("sender_phone", "", sphone), ("sender_address", "", saddr),
                  ("goods", "物品", goods), ("weight", "重量", f"{wt}kg"), ("pieces", "件数", "1/1"), ("date", "寄件日期", day.isoformat())]
        qa = [("收件人是谁？", rcv, "exact"), ("包裹多重？", f"{wt}kg", "number"), ("运单号是多少？", no, "exact"),
              ("寄件人是谁？", snd, "exact")]
    else:
        names = list(C.SIMILAR_EN[1]) if v.get("similar") else rng.sample(C.EN_NAMES, 2)
        rcv, snd = names
        raddr = f"{rng.randrange(10, 900)} {rng.choice(C.EN_STREETS)}, Apt {rng.randrange(1, 40)}, {rng.choice(C.EN_TOWNS)}"
        saddr = f"{rng.randrange(10, 900)} {rng.choice(C.EN_STREETS)}, {rng.choice(C.EN_TOWNS)}"
        lb = round(wt * 2.2046, 1)
        d.rectangle([0, 0, 900, 130], fill=(30, 30, 30))
        cv.text((40, 65), "SAMPLE EXPRESS", 52, fill=(255, 255, 255), bold=True, anchor="lm")
        cv.text((860, 65), "GROUND", 34, fill=(255, 255, 255), anchor="rm")
        _barcode(d, 90, 200, 810, 150, rng)
        cv.text((450, 400), f"TRACKING # {no}", 34, anchor="mm")
        d.line([30, 450, 870, 450], fill=(0, 0, 0), width=3)
        cv.text((40, 480), "SHIP TO:", 30, bold=True)
        cv.text((40, 530), rcv, 42, bold=True)
        cv.text((40, 590), raddr, 30)
        d.line([30, 660, 870, 660], fill=(0, 0, 0), width=2)
        cv.text((40, 690), "FROM:", 28, bold=True)
        cv.text((40, 735), snd, 32)
        cv.text((40, 780), saddr, 28)
        d.line([30, 840, 870, 840], fill=(0, 0, 0), width=2)
        cv.text((40, 870), f"WEIGHT: {lb} LB", 32)
        cv.text((500, 870), "PKG 1 OF 1", 32)
        cv.text((40, 930), f"SHIP DATE: {day:%m/%d/%Y}", 32)
        fields = [("carrier", "", "SAMPLE EXPRESS"), ("tracking_no", "TRACKING #", no), ("recipient", "SHIP TO", rcv),
                  ("recipient_address", "", raddr), ("sender", "FROM", snd), ("sender_address", "", saddr),
                  ("weight", "WEIGHT", f"{lb} LB"), ("pieces", "PKG", "1 OF 1"), ("date", "SHIP DATE", f"{day:%m/%d/%Y}")]
        qa = [("Who is the recipient?", rcv, "exact"), ("What does the package weigh?", f"{lb} lb", "number"),
              ("What is the tracking number?", no, "exact")]
    hard = ["similar_names"] if v.get("similar") else []
    return cv.img, cv.lines, fields, qa, hard, lang, "cardboard"


def nameplate(rng, v):
    cv = Canvas((1100, 700), (196, 198, 200), "hei", "hei_bold")
    cv.img = photo.texture((1100, 700), (190, 192, 196), rng, grain=3, blotch=8, streak=5.0)
    cv.d = ImageDraw.Draw(cv.img)
    ink = (52, 54, 58) if not v.get("faint") else (128, 130, 134)
    d = cv.d
    d.rounded_rectangle([12, 12, 1088, 688], 24, outline=ink, width=4)
    for x, y in ((40, 40), (1060, 40), (40, 660), (1060, 660)):
        d.ellipse([x - 12, y - 12, x + 12, y + 12], outline=ink, width=3)
    kind = rng.choice(["储水式电热水器", "商用咖啡机", "双门冷藏柜"])
    spec = {"储水式电热水器": ("DSZF-60A", "2200W", "60L", "IPX4"), "商用咖啡机": ("EC-2G-10", "3000W", "10L", "IPX1"),
            "双门冷藏柜": ("LC-980F", "420W", "980L", "IPX4")}[kind]
    model, power, cap, ip = spec
    serial = f"{rng.choice('ABCDEFGH')}{rng.randrange(10, 99)}{rng.randrange(100000, 999999)}"
    ym = f"{rng.choice([2025, 2026])}年{rng.randrange(1, 13)}月"
    maker = rng.choice(["云岭电器有限公司", "青槐厨房设备有限公司"])
    cv.text((550, 80), kind, 50, fill=ink, bold=True, anchor="mm")
    rows = [("型号", model), ("额定电压", "220V~"), ("额定频率", "50Hz"), ("额定功率", power), ("额定容量", cap),
            ("防水等级", ip), ("出厂编号", serial), ("生产日期", ym)]
    y = 150
    for i, (k, val) in enumerate(rows):
        x = 80 if i % 2 == 0 else 580
        cv.text((x, y), f"{k}：{val}", 34, fill=ink)
        if i % 2 == 1:
            y += 70
    cv.text((550, 640), maker, 32, fill=ink, anchor="mm")
    fields = [("product", "", kind), ("model", "型号", model), ("voltage", "额定电压", "220V~"), ("frequency", "额定频率", "50Hz"),
              ("power", "额定功率", power), ("capacity", "额定容量", cap), ("ip_rating", "防水等级", ip),
              ("serial_no", "出厂编号", serial), ("manufacture_date", "生产日期", ym), ("manufacturer", "", maker)]
    qa = [("额定功率是多少？", power, "number"), ("型号是什么？", model, "exact"), ("出厂编号是多少？", serial, "exact"),
          ("额定容量是多少？", cap, "number")]
    hard = ["low_contrast"] if v.get("faint") else []
    return cv.img, cv.lines, fields, qa, hard + ["units"], "zh", "desk_grey"


def price_tag(rng, v):
    lang = v.get("lang", "zh")
    cv = Canvas((1000, 560), (255, 255, 255), *(("hei", "hei_bold") if lang == "zh" else ("helv", "helv_bold")))
    d = cv.d
    d.rectangle([0, 0, 1000, 90], fill=(210, 40, 40) if v.get("promo") else (40, 90, 160))
    if lang == "zh":
        name, spec, unit_div, unit_lab = rng.choice([("有机纯牛奶", "250mL×12", 3.0, "L"), ("云南小粒咖啡豆", "500g", 5.0, "100g"),
                                                     ("燕麦饼干", "380g", 3.8, "100g"), ("橄榄油", "750mL", 0.75, "L")])
        price = rng.choice([29.9, 39.9, 59.9, 68.0, 88.0])
        promo = round(price * rng.choice([0.8, 0.85, 0.9]), 1) if v.get("promo") else None
        eff = promo or price
        unit_price = round(eff / unit_div, 2)
        origin = rng.choice(["云南", "内蒙古", "山东", "进口"])
        cv.text((40, 45), "促销" if promo else "商品价签", 40, fill=(255, 255, 255), bold=True, anchor="lm")
        cv.text((40, 130), name, 54, bold=True)
        cv.text((40, 215), f"规格：{spec}", 32)
        cv.text((40, 265), f"产地：{origin}", 32)
        cv.text((40, 315), f"单位价格：¥{unit_price:.2f}/{unit_lab}", 30)
        if promo:
            cv.text((620, 150), f"原价 ¥{price:.2f}", 34, fill=(120, 120, 120))
            w = cv.width(f"原价 ¥{price:.2f}", 34)
            d.line([620, 170, 620 + w, 170], fill=(120, 120, 120), width=3)
            cv.text((960, 300), f"¥{promo:.2f}", 110, fill=(210, 40, 40), bold=True, anchor="rm")
        else:
            cv.text((960, 250), f"¥{price:.2f}", 110, bold=True, anchor="rm")
        _barcode(d, 40, 400, 420, 90, rng)
        code = "69" + "".join(str(rng.randrange(10)) for _ in range(11))
        cv.text((40, 500), code, 26)
        fields = [("product", "", name), ("spec", "规格", spec), ("origin", "产地", origin), ("unit_price", "单位价格", f"¥{unit_price:.2f}/{unit_lab}")]
        if promo:
            fields += [("original_price", "原价", f"¥{price:.2f}"), ("price", "", f"¥{promo:.2f}")]
        else:
            fields += [("price", "", f"¥{price:.2f}")]
        fields.append(("barcode", "", code))
        qa = [("现在卖多少钱？", f"¥{eff:.2f}", "number"), ("规格是多少？", spec, "exact"),
              ("单位价格是多少？", f"¥{unit_price:.2f}/{unit_lab}", "number")]
        if promo:
            qa.append(("原价是多少？", f"¥{price:.2f}", "number"))
    else:
        name, spec, unit_div, unit_lab = rng.choice([("Whole bean coffee", "12 oz", 12, "oz"), ("Oat milk", "64 fl oz", 64, "fl oz"),
                                                     ("Olive oil", "25.3 fl oz", 25.3, "fl oz")])
        price = rng.choice([7.99, 9.49, 12.99, 14.99])
        promo = round(price - rng.choice([1.0, 1.5, 2.0]), 2) if v.get("promo") else None
        eff = promo or price
        unit_price = round(eff / unit_div * 100, 1)
        cv.text((40, 45), "SALE" if promo else "PRICE", 40, fill=(255, 255, 255), bold=True, anchor="lm")
        cv.text((40, 130), name, 54, bold=True)
        cv.text((40, 215), f"Size: {spec}", 32)
        cv.text((40, 265), f"Unit price: {unit_price}¢ per {unit_lab}", 30)
        if promo:
            cv.text((620, 150), f"Reg. ${price:.2f}", 34, fill=(120, 120, 120))
            w = cv.width(f"Reg. ${price:.2f}", 34)
            d.line([620, 170, 620 + w, 170], fill=(120, 120, 120), width=3)
            cv.text((960, 300), f"${promo:.2f}", 110, fill=(210, 40, 40), bold=True, anchor="rm")
        else:
            cv.text((960, 250), f"${price:.2f}", 110, bold=True, anchor="rm")
        _barcode(d, 40, 400, 420, 90, rng)
        fields = [("product", "", name), ("spec", "Size", spec), ("unit_price", "Unit price", f"{unit_price}¢ per {unit_lab}")]
        fields += ([("original_price", "Reg.", f"${price:.2f}"), ("price", "", f"${promo:.2f}")] if promo
                   else [("price", "", f"${price:.2f}")])
        qa = [("What is the current price?", f"${eff:.2f}", "number"), ("What size is it?", spec, "exact")]
        if promo:
            qa.append(("What was the regular price?", f"${price:.2f}", "number"))
    hard = ["two_prices"] if v.get("promo") else []
    return cv.img, cv.lines, fields, qa, hard + ["units"], lang, "desk_white"


def room_sign(rng, v):
    lang = v.get("lang", "zh")
    cv = Canvas((1100, 620), (46, 52, 64), *(("hei", "hei_bold") if lang == "zh" else ("helv", "helv_bold")))
    lowc = v.get("faint")
    fg = (230, 232, 236) if not lowc else (92, 100, 114)
    sub = (170, 178, 190) if not lowc else (78, 86, 98)
    room = rng.choice(["B-302", "A-1105", "C-208", "4B"])
    cap = rng.choice([6, 8, 12, 20])
    ext = rng.randrange(8000, 8999)
    if lang == "zh":
        cv.text((70, 70), "会议室", 40, fill=sub)
        cv.text((70, 130), room, 130, fill=fg, bold=True)
        cv.text((70, 330), f"容纳 {cap} 人", 44, fill=fg)
        cv.text((70, 400), "设备：投屏 · 电话会议 · 白板", 36, fill=sub)
        cv.text((70, 470), f"预约请联系行政部 分机 {ext}", 34, fill=sub)
        fields = [("room", "会议室", room), ("capacity", "容纳", f"{cap} 人"), ("equipment", "设备", "投屏 · 电话会议 · 白板"),
                  ("contact_ext", "分机", str(ext))]
        qa = [("会议室编号是什么？", room, "exact"), ("能容纳几人？", f"{cap} 人", "number"), ("预约分机号是多少？", str(ext), "exact")]
    else:
        cv.text((70, 70), "MEETING ROOM", 40, fill=sub)
        cv.text((70, 130), room, 130, fill=fg, bold=True)
        cv.text((70, 330), f"Capacity {cap}", 44, fill=fg)
        cv.text((70, 400), "Display · Video call · Whiteboard", 36, fill=sub)
        cv.text((70, 470), f"Book via Facilities, ext. {ext}", 34, fill=sub)
        fields = [("room", "", room), ("capacity", "Capacity", str(cap)), ("equipment", "", "Display · Video call · Whiteboard"),
                  ("contact_ext", "ext.", str(ext))]
        qa = [("Which room is this?", room, "exact"), ("What is the capacity?", str(cap), "number"),
              ("Which extension books it?", str(ext), "exact")]
    return cv.img, cv.lines, fields, qa, (["low_contrast"] if lowc else []), lang, "wall"


def hours_sign(rng, v):
    lang = v.get("lang", "zh")
    cv = Canvas((900, 1100), (250, 248, 240), *(("hei", "hei_bold") if lang == "zh" else ("helv", "helv_bold")))
    d = cv.d
    d.rectangle([20, 20, 880, 1080], outline=(40, 40, 40), width=6)
    shop = rng.choice(C.ZH_SHOPS if lang == "zh" else C.EN_SHOPS)
    o1, c1 = rng.choice(["07:30", "08:00", "09:00"]), rng.choice(["20:00", "21:00", "21:30"])
    o2, c2 = rng.choice(["09:00", "10:00"]), rng.choice(["18:00", "19:00"])
    park_h, fee = rng.choice([1, 2]), rng.choice([5, 8, 10])
    if lang == "zh":
        cv.text((450, 110), shop, 56, bold=True, anchor="mm")
        cv.text((450, 220), "营业时间", 48, bold=True, anchor="mm")
        cv.text((450, 320), f"周一至周五 {o1}至{c1}", 44, anchor="mm")
        cv.text((450, 400), f"周六、周日 {o2}至{c2}", 44, anchor="mm")
        cv.text((450, 480), "法定节假日另行通知", 34, anchor="mm", fill=(90, 90, 90))
        d.line([80, 560, 820, 560], fill=(40, 40, 40), width=3)
        cv.text((450, 640), "顾客临时停车", 44, bold=True, anchor="mm")
        cv.text((450, 730), f"限时 {park_h} 小时", 44, anchor="mm")
        cv.text((450, 810), f"超时收费 {fee}元/小时", 44, anchor="mm")
        cv.text((450, 920), "消费满 50 元可免费停车 1 小时", 32, anchor="mm", fill=(90, 90, 90))
        fields = [("shop", "", shop), ("weekday_hours", "周一至周五", f"{o1}至{c1}"), ("weekend_hours", "周六、周日", f"{o2}至{c2}"),
                  ("parking_limit", "限时", f"{park_h} 小时"), ("parking_fee", "超时收费", f"{fee}元/小时")]
        qa = [("周六几点开门？", o2, "exact"), ("工作日几点关门？", c1, "exact"), ("超时停车怎么收费？", f"{fee}元/小时", "number"),
              ("临时停车限时多久？", f"{park_h} 小时", "number")]
    else:
        def ampm(t):
            h, m = map(int, t.split(":"))
            return f"{h % 12 or 12}:{m:02d} {'AM' if h < 12 else 'PM'}"
        cv.text((450, 110), shop, 48, bold=True, anchor="mm")
        cv.text((450, 220), "STORE HOURS", 48, bold=True, anchor="mm")
        cv.text((450, 320), f"Mon to Fri {ampm(o1)} to {ampm(c1)}", 38, anchor="mm")
        cv.text((450, 400), f"Sat and Sun {ampm(o2)} to {ampm(c2)}", 38, anchor="mm")
        d.line([80, 480, 820, 480], fill=(40, 40, 40), width=3)
        cv.text((450, 560), "CUSTOMER PARKING", 44, bold=True, anchor="mm")
        cv.text((450, 650), f"{park_h} hour limit", 42, anchor="mm")
        cv.text((450, 730), f"${fee} per hour after limit", 42, anchor="mm")
        fields = [("shop", "", shop), ("weekday_hours", "Mon to Fri", f"{ampm(o1)} to {ampm(c1)}"),
                  ("weekend_hours", "Sat and Sun", f"{ampm(o2)} to {ampm(c2)}"),
                  ("parking_limit", "", f"{park_h} hour limit"), ("parking_fee", "", f"${fee} per hour")]
        qa = [("When does the store open on Saturday?", ampm(o2), "exact"), ("What is the parking fee after the limit?", f"${fee} per hour", "number")]
    return cv.img, cv.lines, fields, qa, ["units"], lang, "wall"


def repair_form(rng, v):
    """Printed form, values handwritten."""
    cv = Canvas((1240, 1000), (253, 253, 250), "song", "hei_bold")
    d = cv.d
    names = list(C.SIMILAR_ZH[4]) if v.get("similar") else rng.sample(C.ZH_NAMES, 2)
    who, contact = names
    room = f"{rng.randrange(1, 12)}-{rng.randrange(2, 30)}0{rng.randrange(1, 5)}"
    phone = f"1{rng.choice([3, 5, 8])}{rng.randrange(0, 10)}-{rng.randrange(0, 10)}{rng.randrange(0, 10)}**-{rng.randrange(1000, 9999)}"
    issue = rng.choice(["厨房水龙头漏水", "卫生间灯不亮", "空调不制冷", "门锁卡住"])
    day = C.rdate(rng)
    slot = rng.choice(["上午9点至11点", "下午2点至4点", "晚上7点以后"])
    cv.text((620, 70), "物业报修单", 52, bold=True, anchor="mm")
    cv.text((1180, 130), f"编号：BX{day:%m%d}{rng.randrange(10, 99)}", 26, anchor="ra")
    labels = [("报修人", who), ("房号", room), ("联系电话", phone), ("故障描述", issue), ("期望上门时间", f"{day.month}月{day.day}日 {slot}"),
              ("紧急联系人", contact)]
    y = 170
    for lab, val in labels:
        d.rectangle([60, y, 1180, y + 110], outline=(40, 40, 40), width=2)
        d.line([330, y, 330, y + 110], fill=(40, 40, 40), width=2)
        cv.text((195, y + 55), lab, 34, anchor="mm")
        hl = hand_line(val, v.get("hand_font", "hand_pen"), 44, (28, 50, 140), rng, 1.0)
        if hl.size[0] > 820:
            raise ValueError(f"handwritten value too wide: {val!r}")
        cv.img.paste(hl, (360, int(y + 55 - hl.size[1] / 2)), hl)
        cv.lines.append(val)
        y += 110
    cv.text((60, y + 40), "说明：本单一式两联，维修完成后请住户签字确认。", 28)
    fields = [("reporter", "报修人", who), ("room", "房号", room), ("phone", "联系电话", phone), ("issue", "故障描述", issue),
              ("visit_time", "期望上门时间", f"{day.month}月{day.day}日 {slot}"), ("emergency_contact", "紧急联系人", contact)]
    qa = [("报修人是谁？", who, "exact"), ("房号是多少？", room, "exact"), ("什么故障？", issue, "exact"),
          ("紧急联系人是谁？", contact, "exact")]
    hard = ["handwriting"] + (["similar_names"] if v.get("similar") else [])
    return cv.img, cv.lines, fields, qa, hard, "zh", rng.choice(["wood", "desk_grey"])


def bin_label(rng, v):
    lang = v.get("lang", "zh")
    cv = Canvas((1000, 600), (255, 255, 255), *(("hei", "hei_bold") if lang == "zh" else ("helv", "helv_bold")))
    d = cv.d
    loc = f"{rng.choice('ABCD')}-{rng.randrange(1, 12):02d}-{rng.randrange(1, 30):02d}"
    sku = f"SKU{rng.randrange(100000, 999999)}"
    qty = rng.choice([12, 24, 36, 48])
    lot = f"{C.rdate(rng):%Y%m%d}"
    exp = C.rdate(rng, start=C.rdate(rng) .replace(year=2027), days=120)
    d.rectangle([0, 0, 1000, 150], fill=(250, 210, 40))
    if lang == "zh":
        item = rng.choice(["燕麦奶 1L", "纸杯 12oz", "咖啡豆 云南日晒 1kg"])
        cv.text((40, 75), f"库位 {loc}", 70, bold=True, anchor="lm")
        cv.text((40, 190), f"品名：{item}", 38)
        cv.text((40, 250), f"编码：{sku}", 34)
        cv.text((40, 310), f"数量：{qty} 件", 34)
        cv.text((520, 310), f"批次：{lot}", 34)
        cv.text((40, 370), f"有效期至：{exp.isoformat()}", 34)
        fields = [("location", "库位", loc), ("item", "品名", item), ("sku", "编码", sku), ("quantity", "数量", f"{qty} 件"),
                  ("lot", "批次", lot), ("expiry", "有效期至", exp.isoformat())]
        qa = [("库位是哪里？", loc, "exact"), ("数量多少？", f"{qty} 件", "number"), ("有效期到哪天？", exp.isoformat(), "date")]
    else:
        item = rng.choice(["Oat milk 1 L", "Paper cups 12 oz", "Coffee beans, natural, 1 kg"])
        cv.text((40, 75), f"BIN {loc}", 70, bold=True, anchor="lm")
        cv.text((40, 190), f"Item: {item}", 38)
        cv.text((40, 250), f"SKU: {sku}", 34)
        cv.text((40, 310), f"Qty: {qty} units", 34)
        cv.text((520, 310), f"Lot: {lot}", 34)
        cv.text((40, 370), f"Best before: {exp:%m/%d/%Y}", 34)
        fields = [("location", "BIN", loc), ("item", "Item", item), ("sku", "SKU", sku), ("quantity", "Qty", f"{qty} units"),
                  ("lot", "Lot", lot), ("expiry", "Best before", f"{exp:%m/%d/%Y}")]
        qa = [("Which bin?", loc, "exact"), ("How many units?", str(qty), "number"), ("Best before?", exp.isoformat(), "date")]
    _barcode(d, 40, 440, 700, 110, rng)
    return cv.img, cv.lines, fields, qa, [], lang, "cardboard"


KINDS = {"shipping_label": shipping_label, "nameplate": nameplate, "price_tag": price_tag, "room_sign": room_sign,
         "hours_sign": hours_sign, "repair_form": repair_form, "bin_label": bin_label}


def build(idx: int, v: dict, rng: random.Random) -> dict:
    img, lines, fields, qa, hard, lang, bgk = KINDS[v["kind"]](rng, v)
    cw, ch = (1600, 1200) if img.size[0] >= img.size[1] else (1200, 1600)
    bg = photo.background((cw, ch), bgk, rng)
    fill = 0.62 if v.get("far") else 0.86
    quad = photo.jitter_quad(img.size[0], img.size[1], cw, ch, rng, fill=fill, tilt=v.get("tilt", 0.08), rot_deg=v.get("rot", 5))
    bg = photo.drop_shadow(bg, quad, rng, strength=0.25)
    shot = photo.place(img, bg, quad)
    shot = photo.lighting(shot, rng, strength=0.25, vignette=0.25)
    if v.get("glare"):
        shot = photo.glare(shot, rng, strength=0.5, radius=0.14)
        hard = hard + ["glare"]
    if v.get("shadow"):
        shot = photo.cast_shadow(shot, rng)
        hard = hard + ["shadow"]
    if v.get("motion"):
        shot = photo.motion_blur(shot, v["motion"])
        hard = hard + ["blur"]
    shot = photo.blur(shot, v.get("blur", 0.7))
    shot = photo.noise(shot, rng, sigma=5)
    if v.get("far"):
        shot = photo.resize_long(shot, 1000)
        hard = hard + ["small_text"]
    shot = photo.add_mark(shot, corner="br")
    hard = hard + ["perspective"]
    if "units" not in hard and C.has_units(lines):
        hard.append("units")
    gt = {"label_kind": v["kind"], "fields": [{"key": k, "label": lab, "value": val} for k, lab, val in fields], "lines": lines}
    return {"image": shot, "ext": "jpg", "quality": 80, "lang": lang, "hard": list(dict.fromkeys(hard)),
            "render": {"kind": v["kind"], "background": bgk}, "gt": gt, "text_lines": lines,
            "qa": [{"q": q, "a": a, "match": m} for q, a, m in qa], "topic": v["kind"]}
