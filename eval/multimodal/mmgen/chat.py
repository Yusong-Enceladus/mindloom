"""(1) Chat screenshots in a generic messenger UI (no real app's layout, colours or branding).

Ground truth per message: sender (right-hand bubbles are the user: sender "我"/"Me", is_self true),
time (the label actually drawn above the message, "" when none), text (voice / image / file bubbles
use the screenshot-read placeholders "[语音 N秒]", "[图片]", "[文件 name]"), kind.
In one-to-one chats the other side's name is not drawn above bubbles; its gt sender is the chat title
and `sender_shown` is false (a reader may also answer "对方").
"""

from __future__ import annotations

import datetime as dt
import random

from PIL import Image, ImageDraw

from . import common as C
from . import fonts, photo

W = 1080

THEMES = {
    "light": dict(bg=(237, 237, 240), header=(247, 247, 249), other=(255, 255, 255), self=(206, 229, 255),
                  text=(25, 25, 28), name=(128, 132, 140), time=(150, 152, 158), line=(222, 223, 228),
                  bar=(247, 247, 249), field=(255, 255, 255)),
    "mint": dict(bg=(236, 241, 239), header=(246, 248, 247), other=(255, 255, 255), self=(206, 236, 221),
                 text=(28, 30, 30), name=(122, 132, 128), time=(146, 152, 150), line=(220, 226, 223),
                 bar=(246, 248, 247), field=(255, 255, 255)),
    "dark": dict(bg=(17, 17, 19), header=(28, 28, 31), other=(46, 46, 50), self=(38, 70, 118),
                 text=(232, 232, 236), name=(140, 140, 150), time=(118, 118, 126), line=(40, 40, 44),
                 bar=(28, 28, 31), field=(46, 46, 50)),
    # low contrast: faint text on nearly equal backgrounds
    "lowc_light": dict(bg=(246, 246, 246), header=(250, 250, 250), other=(253, 253, 253), self=(238, 242, 248),
                       text=(158, 158, 163), name=(186, 186, 190), time=(190, 190, 194), line=(236, 236, 236),
                       bar=(250, 250, 250), field=(255, 255, 255)),
    "lowc_dark": dict(bg=(30, 30, 32), header=(36, 36, 39), other=(42, 42, 45), self=(46, 54, 66),
                      text=(112, 114, 120), name=(92, 94, 100), time=(90, 92, 98), line=(44, 44, 47),
                      bar=(36, 36, 39), field=(42, 42, 45)),
}


# --------------------------------------------------------------------------- conversations
# Each returns (title_or_None, is_group, [(role, payload)], [(q, a, match)]); role "me" = the user.
# payload: str, or ("voice", seconds) / ("image",) / ("file", name, size)

def conv_beans(rng, n):
    p0 = rng.choice([118, 120, 125]); p1 = p0 + rng.choice([6, 8, 10]); p2 = p1 - rng.choice([3, 4, 5])
    q = rng.choice([20, 25, 30]); q2 = rng.choice([5, 8, 10]); w = rng.choice(C.WEEKDAYS_ZH[:5])
    msgs = [("A", f"云南那家豆子报价发你了，每公斤{p1}元，起订{q}公斤"),
            ("me", f"上次不是{p0}吗？涨了？"),
            ("A", f"说是新产季，水洗的涨了{p1 - p0}元"),
            ("B", f"我问了另一家，日晒的{p2}元/公斤，含运费"),
            ("me", f"那两家各要{q2}公斤试试，{w}前定下来"),
            ("A", f"好，我跟他说{w}发货")]
    qa = [("云南那家水洗豆子现在每公斤多少钱？", f"{p1}元", "number"),
          (f"{n['B']}问到的日晒豆子多少钱一公斤？", f"{p2}元", "number"),
          ("我决定每家先要多少公斤？", f"{q2}公斤", "number")]
    return "小店进货群", True, msgs, qa


def conv_launch(rng, n):
    t = rng.choice(["20:00", "21:30", "22:00"]); d = C.rdate(rng); amt = rng.choice([4.5, 5, 5.8, 6.2])
    msgs = [("A", f"测试版今晚{t}打包，明早发群里"),
            ("B", "支付那块还没过审，先上点单吧"),
            ("me", f"同意，支付推迟到{d.month}月{d.day}日"),
            ("A", f"预算那边要改成{amt:g}万吗？"),
            ("me", f"对，按{amt:g}万走，下周一我发确认邮件"),
            ("C", "收到")]
    qa = [("支付功能推迟到哪天？", f"{d.month}月{d.day}日", "exact"),
          ("预算改成多少？", f"{amt:g}万", "number"),
          ("测试版几点打包？", t, "exact")]
    return "点单小程序项目", True, msgs, qa


def conv_dinner(rng, n):
    w = rng.choice(C.WEEKDAYS_ZH[3:6]); k = rng.choice([6, 8, 9, 11]); t = rng.choice(["18:30", "19:00"])
    p = rng.choice([85, 120, 150])
    msgs = [("A", f"{w}晚上聚餐定在哪？"),
            ("me", f"就学校东门那家，{k}个人"),
            ("A", f"我订了{t}的包间，人均大概{p}元"),
            ("me", "好的，我跟大家说一声"),
            ("A", ("image",)),
            ("A", "这是菜单，你看看要不要加菜")]
    qa = [("聚餐几点开始？", t, "exact"), ("人均大概多少钱？", f"{p}元", "number"),
          ("聚餐一共几个人？", f"{k}个人", "number")]
    return None, False, msgs, qa


def conv_tiles(rng, n):
    boxes = rng.choice([18, 20, 24]); per = rng.choice([1.44, 1.2, 0.96]); area = rng.choice([22, 24, 26])
    loss = rng.choice([5, 8, 10]); need = area * (1 + loss / 100); have = boxes * per
    short = max(1, int(-(-(need - have) // per)))
    w = rng.choice(C.WEEKDAYS_ZH[:6]); t = rng.choice(["8:30", "9:00", "10:00"])
    msgs = [("A", f"瓷砖到了，{boxes}箱，每箱{per:g}㎡"),
            ("B", f"客厅要铺{area}㎡，够吗"),
            ("A", f"按损耗{loss}%算，还差{short}箱"),
            ("me", f"那再补{short}箱，师傅{w}能来吗"),
            ("C", f"{w}上午{t}到"),
            ("me", ("voice", rng.choice([6, 9, 14])))]
    qa = [("到货的瓷砖每箱多少平方米？", f"{per:g}㎡", "number"), ("还要补几箱？", f"{short}箱", "number"),
          ("师傅几点到？", f"{w}上午{t}", "contains")]
    return "新家装修", True, msgs, qa


def conv_school(rng, n):
    d = C.rdate(rng); t = rng.choice(["7:40", "7:50", "8:00"]); p = rng.choice([35, 40, 45])
    msgs = [("A", f"各位家长：{d.month}月{d.day}日秋游，{t}在校门口集合，请带水和午餐"),
            ("B", "需要另外交费吗？"),
            ("A", f"车费每人{p}元，已从班费扣除"),
            ("me", "收到，谢谢老师"),
            ("C", "请问下雨还去吗"),
            ("A", "如遇下雨顺延一周，另行通知")]
    qa = [("秋游是哪天？", f"{d.month}月{d.day}日", "exact"), ("几点集合？", t, "exact"),
          ("车费每人多少？", f"{p}元", "number")]
    return "三年二班家长群", True, msgs, qa


def conv_refund(rng, n):
    code = f"TH{rng.randrange(10**9, 10**10)}"; k = rng.choice([3, 5, 7]); amt = rng.choice([89.9, 129, 256.5])
    msgs = [("A", f"您好，退货单 {code} 已受理"),
            ("me", "大概几天能退款？"),
            ("A", f"仓库签收后{k}个工作日内退款{amt:g}元到原支付账户"),
            ("me", "好的，快递已经寄出了"),
            ("A", ("file", "退货须知.pdf", "86 KB")),
            ("A", "请按须知在包裹内附上退货单号")]
    qa = [("退货单号是多少？", code, "exact"), ("退款金额是多少？", f"{amt:g}元", "number"),
          ("签收后几个工作日内退款？", f"{k}个工作日", "number")]
    return "售后客服小禾", False, msgs, qa


def conv_run(rng, n):
    pace = rng.choice(["5'42\"", "6'05\"", "5'18\""]); km = rng.choice([8.2, 10.5, 12.0]); lng = rng.choice([18, 21, 25])
    t = rng.choice(["6:00", "6:30"])
    msgs = [("A", f"今天配速{pace}，跑了{km:g}km"),
            ("B", "可以啊，比上周快"),
            ("C", f"周六{lng}公里长距离，{t}湖边集合"),
            ("me", "我能跑15公里，后面骑车跟着"),
            ("A", "记得带能量胶"),
            ("B", ("voice", rng.choice([5, 11])))]
    qa = [(f"{n['A']}今天跑了多少公里？", f"{km:g}km", "number"), ("周六长距离跑多少公里？", f"{lng}公里", "number"),
          ("周六几点集合？", t, "exact")]
    return "晨跑小分队", True, msgs, qa


def conv_trip(rng, n):
    d = C.rdate(rng); t = rng.choice(["07:12", "08:05", "13:40"]); p = rng.choice([354.5, 419, 268])
    nights = rng.choice([2, 3]); amt = rng.choice([1260, 1580, 1896]); share = round(amt / 3, 2)
    msgs = [("A", f"高铁票抢到了，{d.month}月{d.day}日 {t} 出发，二等座{p:g}元"),
            ("B", f"酒店我订了两间，{nights}晚，一共{amt}元"),
            ("me", f"那每人{share:g}元，我转你"),
            ("B", "好的"),
            ("C", "我那天得先去趟公司，晚一班到")]
    qa = [("高铁几点出发？", t, "exact"), ("酒店一共多少钱？", f"{amt}元", "number"),
          ("酒店每人分摊多少？", f"{share:g}元", "number")]
    return "国庆出行", True, msgs, qa


def conv_rent(rng, n):
    e = rng.choice([186.4, 212.8, 243.6]); wtr = rng.choice([38.5, 42, 57.3]); g = rng.choice([64, 71.2, 88])
    total = round(e + wtr + g, 2); share = round(total / 3, 2)
    msgs = [("A", f"这个月电费{e:g}元，水费{wtr:g}元，燃气{g:g}元"),
            ("B", f"一共{total:g}元，三个人每人{share:g}元"),
            ("me", "已转"),
            ("A", "收到，下个月轮到我交网费")]
    qa = [("这个月电费多少？", f"{e:g}元", "number"), ("每人分摊多少？", f"{share:g}元", "number")]
    return "合租 502", True, msgs, qa


def conv_samples(rng, n):
    k = rng.choice([3, 5, 6]); code = f"YD{rng.randrange(10**11, 10**12)}"; amt = rng.choice([2380, 4650, 3120.5])
    msgs = [("A", f"样品{k}件已寄出，单号{code}"),
            ("B", f"我这边还没开发票，金额是{amt:g}元对吧？"),
            ("me", f"对，是{amt:g}元，样品我收到后再确认"),
            ("A", "好的"),
            ("B", "收到，今天下午开")]
    qa = [("寄出的样品有几件？", f"{k}件", "number"), ("快递单号是多少？", code, "exact"),
          ("谁说今天下午开发票？", n["B"], "exact"), ("谁寄出了样品？", n["A"], "exact")]
    return "采购对接群", True, msgs, qa


def conv_en_launch(rng, n):
    ver = rng.choice(["2.4.1", "3.0.0-rc2", "1.8.7"]); day = rng.choice(["Thursday", "Friday"]); s = rng.choice([30, 45])
    d = C.rdate(rng)
    msgs = [("A", f"Build {ver} is up on staging, please test by {day}"),
            ("B", f"Checkout still times out after {s} seconds"),
            ("me", f"Let's ship ordering first and move payments to {C.MONTHS_EN[d.month - 1]} {d.day}"),
            ("A", "OK, I'll update the release notes"),
            ("C", "I can pair on the timeout tomorrow morning")]
    qa = [("Which build is on staging?", ver, "exact"), ("After how many seconds does checkout time out?", f"{s} seconds", "number"),
          ("When do payments move to?", f"{C.MONTHS_EN[d.month - 1]} {d.day}", "exact")]
    return "Launch sync", True, msgs, qa


def conv_en_move(rng, n):
    boxes = rng.choice([12, 16, 20]); fee = rng.choice([180, 240, 275]); t = rng.choice(["9 AM", "10 AM"])
    msgs = [("A", f"Movers confirmed for Saturday {t}, {boxes} boxes plus the desk"),
            ("me", f"Great, is the ${fee} quote still valid?"),
            ("A", f"Yes, ${fee} flat, cash or card"),
            ("me", "Perfect. I'll leave the keys with the front desk"),
            ("A", ("image",))]
    qa = [("What time do the movers come?", f"Saturday {t}", "contains"), ("How much is the quote?", f"${fee}", "number"),
          ("How many boxes?", f"{boxes} boxes", "number")]
    return None, False, msgs, qa


def conv_mixed_review(rng, n):
    t = rng.choice(["14:00", "15:30", "16:00"]); gmv = rng.choice([86.4, 112.5, 97.2]); room = rng.choice(["B-302", "A-1105"])
    msgs = [("A", f"明天的 review 改到 {t} 了，room {room}"),
            ("me", "OK，deck 我今晚发你"),
            ("A", f"记得加上 Q3 的 GMV：{gmv:g} 万，同比 +12%"),
            ("me", "好，retention 那页要不要保留？"),
            ("A", "保留，放在 appendix")]
    qa = [("review 改到几点？", t, "exact"), ("在哪个会议室？", room, "exact"), ("Q3 的 GMV 是多少？", f"{gmv:g} 万", "number")]
    return None, False, msgs, qa


def conv_mixed_vendor(rng, n):
    qty = rng.choice([200, 300, 500]); unit = rng.choice([3.8, 4.2, 5.5]); lead = rng.choice([7, 10, 14])
    msgs = [("A", f"MOQ 是 {qty} pcs，单价 ¥{unit:g}/pc"),
            ("B", f"lead time 大概 {lead} 天，含 QC"),
            ("me", f"先下 {qty} pcs，PO 我明天发"),
            ("A", "OK，收到 PO 就排产"),
            ("B", ("file", f"PI_{qty}pcs.pdf", "142 KB"))]
    qa = [("最小起订量是多少？", f"{qty} pcs", "number"), ("单价多少？", f"¥{unit:g}/pc", "number"),
          ("交期多少天？", f"{lead} 天", "number")]
    return "包材供应商对接", True, msgs, qa


CONVERSATIONS = {
    "beans": (conv_beans, "zh"), "launch": (conv_launch, "zh"), "dinner": (conv_dinner, "zh"),
    "tiles": (conv_tiles, "zh"), "school": (conv_school, "zh"), "refund": (conv_refund, "zh"),
    "run": (conv_run, "zh"), "trip": (conv_trip, "zh"), "rent": (conv_rent, "zh"), "samples": (conv_samples, "zh"),
    "en_launch": (conv_en_launch, "en"), "en_move": (conv_en_move, "en"),
    "mixed_review": (conv_mixed_review, "mixed"), "mixed_vendor": (conv_mixed_vendor, "mixed"),
}


# --------------------------------------------------------------------------- time labels

def _label(ts: dt.datetime, style: str, lang: str) -> str:
    h12 = ts.hour % 12 or 12
    if lang == "en":
        base = f"{h12}:{ts.minute:02d} {'AM' if ts.hour < 12 else 'PM'}"
        return {"plain": base, "yesterday": f"Yesterday {base}",
                "date": f"{C.MONTHS_EN[ts.month - 1]} {ts.day}, {base}",
                "weekday": f"{C.WEEKDAYS_EN[ts.weekday()]} {base}", "ampm": base}[style]
    hm = f"{ts.hour:02d}:{ts.minute:02d}"
    return {"plain": hm, "yesterday": f"昨天 {hm}", "date": f"{ts.month}月{ts.day}日 {hm}",
            "weekday": f"{C.WEEKDAYS_ZH[ts.weekday()]} {hm}",
            "ampm": f"{'上午' if ts.hour < 12 else '下午'}{h12}:{ts.minute:02d}"}[style]


# --------------------------------------------------------------------------- drawing

def _status_bar(d, th, s, clock):
    f = fonts.font("helv_bold", 30 * s)
    d.text((int(60 * s), int(40 * s)), clock, font=f, fill=th["text"], anchor="lm")
    x1 = W * s - int(40 * s)
    d.rounded_rectangle([x1 - int(56 * s), int(28 * s), x1, int(52 * s)], int(6 * s), outline=th["text"], width=max(1, int(2 * s)))
    d.rectangle([x1 - int(52 * s), int(32 * s), x1 - int(20 * s), int(48 * s)], fill=th["text"])
    for k in range(4):  # signal bars
        bx = x1 - int(130 * s) + k * int(12 * s)
        d.rectangle([bx, int(50 * s) - k * int(6 * s) - int(6 * s), bx + int(7 * s), int(50 * s)], fill=th["text"])


def _avatar(d, x, y, size, name, s):
    col = C_AVATARS[sum(map(ord, name)) % len(C_AVATARS)]
    d.rounded_rectangle([x, y, x + size, y + size], int(12 * s), fill=col)
    key = "hei" if any("一" <= ch <= "鿿" for ch in name) else "helv_bold"
    glyph = name[-1] if key == "hei" else name[:1]
    d.text((x + size / 2, y + size / 2), fonts.check(key, glyph), font=fonts.font(key, 34 * s), fill="white", anchor="mm")


C_AVATARS = [(94, 129, 172), (163, 112, 88), (104, 150, 116), (150, 110, 170), (190, 140, 70), (90, 150, 160),
             (170, 96, 110), (120, 120, 132)]


def render(spec: dict, theme: str, s: float, status_bar: bool, rng: random.Random) -> Image.Image:
    th = THEMES[theme]
    fkey = spec["font"]
    f_msg = fonts.font(fkey, 32 * s)
    f_name = fonts.font(fkey, 24 * s)
    f_title = fonts.font(spec["font_bold"], 34 * s)
    f_time = fonts.font(fkey, 23 * s)
    width = int(W * s)
    img = Image.new("RGB", (width, int(5200 * s)), th["bg"])
    d = ImageDraw.Draw(img)
    top = 0
    if status_bar:
        d.rectangle([0, 0, width, int(84 * s)], fill=th["header"])
        _status_bar(d, th, s, spec["clock"])
        top = int(84 * s)
    header_h = int(104 * s)
    d.rectangle([0, top, width, top + header_h], fill=th["header"])
    d.line([0, top + header_h, width, top + header_h], fill=th["line"], width=max(1, int(2 * s)))
    title = spec["title"] + (f"({spec['members']})" if spec["is_group"] else "")
    d.text((width // 2, top + header_h // 2), fonts.check(spec["font_bold"], title), font=f_title, fill=th["text"], anchor="mm")
    cy = top + header_h // 2
    d.line([(int(50 * s), cy - int(18 * s)), (int(32 * s), cy), (int(50 * s), cy + int(18 * s))], fill=th["text"],
           width=max(2, int(4 * s)), joint="curve")
    # small synthetic-data mark where a real app would put its "more" button
    f_mark = fonts.font("hei", 21 * s)
    mw = d.textlength(photo.MARK_TEXT, font=f_mark) + int(20 * s)
    mx1 = width - int(26 * s)
    d.rounded_rectangle([mx1 - mw, cy - int(18 * s), mx1, cy + int(18 * s)], int(8 * s), outline=photo.MARK_RED,
                        width=max(1, int(2 * s)))
    d.text((mx1 - mw / 2, cy), photo.MARK_TEXT, font=f_mark, fill=photo.MARK_RED, anchor="mm")

    y = top + header_h + int(28 * s)
    av = int(84 * s)
    lh = int(46 * s)
    max_w = int(660 * s)
    pad_x, pad_y = int(24 * s), int(14 * s)
    for m in spec["messages"]:
        if m["time"]:
            d.text((width // 2, y + int(14 * s)), fonts.check(fkey, m["time"]), font=f_time, fill=th["time"], anchor="mm")
            y += int(56 * s)
        mine = m["is_self"]
        ax = width - int(28 * s) - av if mine else int(28 * s)
        _avatar(d, ax, y, av, spec["self_avatar"] if mine else m["sender"], s)
        by = y
        if not mine and spec["show_names"]:
            d.text((ax + av + int(18 * s), y - int(2 * s)), fonts.check(fkey, m["sender"]), font=f_name, fill=th["name"])
            by = y + int(36 * s)
        kind = m["kind"]
        if kind == "text":
            lines = C.wrap(m["text"], f_msg, max_w, d)
            for ln in lines:
                fonts.check(fkey, ln)
            bw = int(max(d.textlength(ln, font=f_msg) for ln in lines) + 2 * pad_x)
            bh = int(lh * len(lines) + 2 * pad_y)
        elif kind == "voice":
            bw, bh = int((150 + 14 * m["seconds"]) * s), int(lh + 2 * pad_y)
        elif kind == "image":
            bw, bh = int(320 * s), int(240 * s)
        else:  # file
            bw, bh = int(520 * s), int(150 * s)
        bx0 = ax - int(18 * s) - bw if mine else ax + av + int(18 * s)
        bx1 = bx0 + bw
        fill = th["self"] if mine else th["other"]
        if kind == "image":
            d.rounded_rectangle([bx0, by, bx1, by + bh], int(14 * s), fill=(196, 204, 212) if "dark" not in theme else (70, 76, 84))
            d.polygon([(bx0 + int(30 * s), by + bh - int(40 * s)), (bx0 + int(120 * s), by + int(90 * s)),
                       (bx0 + int(200 * s), by + bh - int(40 * s))], fill=(150, 162, 174))
            d.polygon([(bx0 + int(150 * s), by + bh - int(40 * s)), (bx0 + int(220 * s), by + int(120 * s)),
                       (bx0 + int(290 * s), by + bh - int(40 * s))], fill=(130, 144, 158))
            d.ellipse([bx0 + int(230 * s), by + int(36 * s), bx0 + int(270 * s), by + int(76 * s)], fill=(236, 214, 150))
        else:
            d.rounded_rectangle([bx0, by, bx1, by + bh], int(18 * s), fill=fill)
        if kind == "text":
            for k, ln in enumerate(lines):
                d.text((bx0 + pad_x, by + pad_y + k * lh), ln, font=f_msg, fill=th["text"])
        elif kind == "voice":
            cx, cyy = (bx1 - pad_x - int(20 * s), by + bh // 2) if mine else (bx0 + pad_x + int(8 * s), by + bh // 2)
            for r in (8, 16, 24):
                rr = int(r * s)
                start, end = (135, 225) if mine else (-45, 45)
                d.arc([cx - rr, cyy - rr, cx + rr, cyy + rr], start, end, fill=th["text"], width=max(2, int(3 * s)))
            lab = f"{m['seconds']}″"
            fonts.check(fkey, lab)
            if mine:
                d.text((bx0 + pad_x, cyy), lab, font=f_msg, fill=th["text"], anchor="lm")
            else:
                d.text((bx1 - pad_x, cyy), lab, font=f_msg, fill=th["text"], anchor="rm")
        elif kind == "file":
            ix0 = bx1 - pad_x - int(80 * s)
            d.rounded_rectangle([ix0, by + int(30 * s), ix0 + int(80 * s), by + int(120 * s)], int(8 * s), fill=(214, 90, 80))
            d.text((ix0 + int(40 * s), by + int(75 * s)), "PDF", font=fonts.font("helv_bold", 22 * s), fill="white", anchor="mm")
            d.text((bx0 + pad_x, by + int(34 * s)), fonts.check(fkey, m["file_name"]), font=f_msg, fill=th["text"])
            d.text((bx0 + pad_x, by + int(88 * s)), fonts.check(fkey, m["file_size"]), font=f_name, fill=th["name"])
        y = max(y + av, by + bh) + int(30 * s)
    # input bar
    bar_top = y + int(8 * s)
    d.rectangle([0, bar_top, width, bar_top + int(110 * s)], fill=th["bar"])
    d.line([0, bar_top, width, bar_top], fill=th["line"], width=max(1, int(2 * s)))
    d.rounded_rectangle([int(100 * s), bar_top + int(20 * s), width - int(180 * s), bar_top + int(86 * s)], int(12 * s), fill=th["field"])
    d.ellipse([int(28 * s), bar_top + int(26 * s), int(80 * s), bar_top + int(78 * s)], outline=th["name"], width=max(2, int(3 * s)))
    d.ellipse([width - int(150 * s), bar_top + int(26 * s), width - int(98 * s), bar_top + int(78 * s)], outline=th["name"], width=max(2, int(3 * s)))
    d.ellipse([width - int(80 * s), bar_top + int(26 * s), width - int(28 * s), bar_top + int(78 * s)], outline=th["name"], width=max(2, int(3 * s)))
    return img.crop((0, 0, width, bar_top + int(110 * s)))


# --------------------------------------------------------------------------- builder

def build(idx: int, v: dict, rng: random.Random) -> dict:
    fn, lang = CONVERSATIONS[v["conv"]]
    if lang == "en":
        pool, pairs, me = C.EN_NAMES, C.SIMILAR_EN, "Me"
    else:
        pool, pairs, me = C.ZH_NAMES, C.SIMILAR_ZH, "我"
    names = rng.sample(pool, 3)
    if v.get("similar"):
        a, b = pairs[v["similar_pair"] % len(pairs)]
        names[0], names[1] = a, b
    n = {"A": names[0], "B": names[1], "C": names[2]}
    title, is_group, raw, qa = fn(rng, n)
    if not is_group:
        title = title or n["A"]
        n = {"A": title, "B": title, "C": title}
    # timeline: minutes between messages; a label is drawn at the start and after a >= 5 min gap
    start = dt.datetime.combine(C.rdate(rng), dt.time(rng.randrange(8, 22), rng.randrange(60)))
    style = v.get("time_style", "plain")
    ts = start
    messages, last_label_ts = [], None
    for k, (role, payload) in enumerate(raw):
        if k:
            ts += dt.timedelta(minutes=rng.choice([0, 1, 1, 2, 3]) if rng.random() > v.get("gap_p", 0.25)
                               else rng.choice([6, 9, 14, 23, 41]))
        label = ""
        if last_label_ts is None or (ts - last_label_ts) >= dt.timedelta(minutes=5):
            label = _label(ts, style, lang)
            last_label_ts = ts
        mine = role == "me"
        sender = me if mine else n[role]
        m = {"sender": sender, "is_self": mine, "time": label, "kind": "text"}
        if isinstance(payload, str):
            m["text"] = payload
        elif payload[0] == "voice":
            m.update(kind="voice", seconds=payload[1], text=f"[语音 {payload[1]}秒]")
        elif payload[0] == "image":
            m.update(kind="image", text="[图片]")
        else:
            m.update(kind="file", file_name=payload[1], file_size=payload[2], text=f"[文件 {payload[1]}]")
        messages.append(m)

    font_key, bold_key = (("helv", "helv_bold") if lang == "en" else rng.choice([("hei", "hei_bold"), ("heiti", "heiti_med")]))
    spec = {"title": title, "is_group": is_group, "members": rng.choice([4, 6, 8, 12, 23]),
            "show_names": is_group, "messages": messages, "font": font_key, "font_bold": bold_key,
            "self_avatar": "我" if lang != "en" else "Me"}
    after = ts + dt.timedelta(minutes=rng.randrange(1, 30)) if style in ("plain", "ampm") else \
        dt.datetime.combine(start.date() + dt.timedelta(days=rng.randrange(1, 4)), dt.time(rng.randrange(8, 23), rng.randrange(60)))
    spec["clock"] = f"{after.hour}:{after.minute:02d}"
    theme = v.get("theme", "light")
    img = render(spec, theme, 1.0, v.get("status_bar", True), rng)
    hard, render_info = [], {"theme": theme, "fonts": [font_key, bold_key]}
    ext = "png"
    if v.get("small"):
        img = img.resize((int(img.size[0] * v["small"]), int(img.size[1] * v["small"])), Image.LANCZOS)
        ext = "jpg"  # saved at quality 72: a forwarded, recompressed screenshot
        hard.append("small_text")
        render_info["downscale"] = v["small"]
    if theme.startswith("lowc"):
        hard.append("low_contrast")
    if v.get("similar"):
        hard.append("similar_names")
    if style != "plain":
        hard.append("dated_time")
    if any(m["kind"] != "text" for m in messages):
        hard.append("non_text_bubbles")

    gt_messages = [{k: m[k] for k in ("sender", "is_self", "time", "text", "kind")} for m in messages]
    for gm, m in zip(gt_messages, messages):
        if m["kind"] == "voice":
            gm["seconds"] = m["seconds"]
        if m["kind"] == "file":
            gm["file_name"] = m["file_name"]
        if not is_group and not m["is_self"]:
            gm["sender_shown"] = False
    texts = [m["text"] for m in messages if m["kind"] == "text"]
    if C.has_units(texts):
        hard.append("units")
    text_lines = [title] + [f"{m['sender']}：{m['text']}" for m in messages]
    all_text = " ".join(texts)
    return {
        "image": img, "ext": ext, "quality": 72, "lang": lang if lang != "zh" else C.mixed_lang(all_text),
        "hard": hard, "render": render_info,
        "gt": {"chat_title": title, "is_group": is_group, "messages": gt_messages},
        "text_lines": text_lines,
        "qa": [{"q": q, "a": a, "match": mt} for q, a, mt in qa],
        "topic": v["conv"],
    }
