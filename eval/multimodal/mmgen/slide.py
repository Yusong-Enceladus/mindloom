"""(3) Slides: a 16:9 page rendered with Pillow (title, bullets with levels, optional KPI panel, footer),
either as a clean export or as a phone photo of the projected slide (keystone, glare, blur, noise).
"""

from __future__ import annotations

import random

from PIL import Image, ImageDraw

from . import common as C
from . import fonts, photo

SW, SH = 1920, 1080

THEMES = {
    "corporate": dict(bg=(255, 255, 255), band=(28, 58, 102), title=(255, 255, 255), text=(40, 44, 52),
                      sub=(96, 102, 112), accent=(224, 128, 58), foot=(130, 136, 146), panel=(242, 245, 250)),
    "minimal": dict(bg=(250, 249, 246), band=None, title=(20, 22, 26), text=(46, 48, 54), sub=(104, 108, 116),
                    accent=(63, 155, 107), foot=(150, 152, 158), panel=(238, 242, 238)),
    "dark": dict(bg=(22, 30, 46), band=None, title=(245, 247, 250), text=(214, 220, 230), sub=(150, 160, 178),
                 accent=(96, 165, 250), foot=(120, 130, 148), panel=(34, 44, 64)),
    "lowc": dict(bg=(243, 244, 246), band=None, title=(150, 154, 162), text=(172, 176, 183), sub=(186, 189, 195),
                 accent=(200, 204, 210), foot=(196, 198, 202), panel=(236, 238, 241)),
}


# --------------------------------------------------------------------------- content
# each returns (title, subtitle, [(level, text)], kpis [(label, value)], qa [(q, a, match)])

def s_weekly(rng):
    wk = rng.randrange(30, 40); rate = rng.choice([98.7, 99.2, 99.6]); d = C.rdate(rng); days = rng.choice([3, 5])
    b = [(0, f"已完成：点单模块联调，接口成功率 {rate}%"),
         (0, f"进行中：支付对接，预计 {d.month}月{d.day}日 提测"),
         (1, "支付沙箱已通，等待正式商户号"),
         (0, f"风险：第三方审核需要 {days} 个工作日"),
         (0, "下周：灰度发布到 2 家门店，收集反馈")]
    qa = [("接口成功率是多少？", f"{rate}%", "number"), ("支付预计哪天提测？", f"{d.month}月{d.day}日", "exact"),
          ("第三方审核需要几个工作日？", f"{days} 个工作日", "number")]
    return f"点单小程序项目周报（第{wk}周）", None, b, [], qa


def s_review(rng):
    rev = rng.choice([186.4, 212.9, 247.3]); yoy = rng.choice([8.6, 12.4, 17.1]); aov = rng.choice([32.8, 36.5, 41.2])
    mem = rng.choice([1240, 1865, 2310]); refund = rng.choice([1.2, 1.8, 2.4])
    b = [(0, f"营收 {rev} 万元，同比 +{yoy}%"), (0, f"客单价 ¥{aov}，较上季度持平"),
         (0, f"新增会员 {mem:,} 人，其中小程序渠道占 62%"), (0, f"退款率降至 {refund}%"),
         (1, "主要来自出餐超时减少"), (0, "Q4 重点：会员复购与新品上市")]
    kpis = [("营收", f"{rev}万"), ("同比", f"+{yoy}%"), ("新增会员", f"{mem:,}")]
    qa = [("Q3 营收是多少？", f"{rev} 万元", "number"), ("新增会员多少人？", f"{mem:,} 人", "number"),
          ("退款率降至多少？", f"{refund}%", "number")]
    return "Q3 经营复盘", "2026 年第三季度", b, kpis, qa


def s_launch(rng):
    d = C.rdate(rng); n = rng.choice([6, 8, 12]); a = rng.choice([18, 22]); bb = a + rng.choice([3, 4]); k = rng.choice([40, 60])
    b = [(0, f"上线日期：{d.month}月{d.day}日（{C.WEEKDAYS_ZH[d.weekday()]}）"), (0, f"首批门店：{n} 家"),
         (0, f"定价：中杯 ¥{a}，大杯 ¥{bb}"), (0, f"物料：海报 {k} 张、菜单贴 {n * 2} 份"),
         (1, "上线前 3 天完成门店培训"), (0, "负责人：运营部 周婷")]
    qa = [("上线日期是哪天？", f"{d.month}月{d.day}日", "exact"), ("首批几家门店？", f"{n} 家", "number"),
          ("大杯定价多少？", f"¥{bb}", "number")]
    return "秋季新品上线计划", None, b, [("首批门店", f"{n}家"), ("中杯", f"¥{a}"), ("大杯", f"¥{bb}")], qa


def s_research(rng):
    n = rng.choice([120, 286, 412]); p1 = rng.choice([58, 63, 71]); p2 = rng.choice([24, 31]); t = rng.choice([4.2, 5.5])
    b = [(0, f"样本：{n} 位近 30 天到店顾客"), (0, f"{p1}% 希望支持提前下单、到店自取"),
         (0, f"{p2}% 认为高峰期等待超过 10 分钟"), (1, f"平均等待 {t} 分钟（工作日午间）"),
         (0, "建议：先上线点单，支付随后接入")]
    qa = [("调研样本多少人？", f"{n} 位", "number"), ("多少比例希望提前下单？", f"{p1}%", "number"),
          ("工作日午间平均等待多久？", f"{t} 分钟", "number")]
    return "用户调研结论", "到店顾客问卷 · 9月", b, [], qa


def s_budget(rng):
    tot = rng.choice([48, 56, 72]); hr = round(tot * 0.55, 1); dev = round(tot * 0.25, 1); mk = round(tot - hr - dev, 1)
    b = [(0, f"总预算：{tot} 万元"), (1, f"人力：{hr} 万元"), (1, f"设备与服务器：{dev} 万元"), (1, f"市场推广：{mk} 万元"),
         (0, "审批节点：部门负责人 → 财务 → 总经理"), (0, "预算周期：2026 年 10 月至 12 月")]
    qa = [("总预算多少？", f"{tot} 万元", "number"), ("市场推广预算多少？", f"{mk} 万元", "number")]
    return "Q4 预算申请", None, b, [("总预算", f"{tot}万")], qa


def s_training(rng, similar):
    a, bname = C.SIMILAR_ZH[1] if similar else rng.sample(C.ZH_NAMES, 2)
    d = C.rdate(rng); room = rng.choice(["3 楼大会议室", "B-302", "培训室 2"]); hrs = rng.choice([1.5, 2, 3])
    b = [(0, f"时间：{d.month}月{d.day}日 14:00，时长 {hrs:g} 小时"), (0, f"地点：{room}"),
         (0, f"讲师：{a}（前端）、{bname}（测试）"), (1, f"{a}：小程序发布流程"), (1, f"{bname}：回归测试清单"),
         (0, "参加人员：研发部全员，请提前 10 分钟到场")]
    qa = [("培训在哪里？", room, "exact"), ("谁讲回归测试清单？", bname, "exact"), ("培训多长时间？", f"{hrs:g} 小时", "number")]
    return "新人技术培训安排", None, b, [], qa


def s_agenda(rng):
    b = [(0, "14:00  上周行动项回顾"), (0, "14:15  支付接入方案评审"), (1, "方案 A：聚合支付，费率 0.38%"),
         (1, "方案 B：直连银行，费率 0.25%，开发 3 周"), (0, "14:45  门店灰度计划"), (0, "15:00  其他事项")]
    qa = [("方案 A 的费率是多少？", "0.38%", "number"), ("方案 B 开发需要多久？", "3 周", "number"),
          ("门店灰度计划几点开始讨论？", "14:45", "exact")]
    return "项目例会议程", f"{C.rdate(rng).month}月例会", b, [], qa


def s_en_review(rng):
    rev = rng.choice([1.2, 1.46, 1.83]); qoq = rng.choice([9, 14, 21]); churn = rng.choice([1.8, 2.1, 2.6])
    nps = rng.choice([41, 47, 53]); hc = rng.choice([32, 38, 45])
    b = [(0, f"Revenue ${rev}M, up {qoq}% QoQ"), (0, f"Monthly churn {churn}%"), (1, "Down from 3.0% after the onboarding fix"),
         (0, f"NPS {nps} (survey n = 640)"), (0, f"Headcount {hc}, 4 open roles")]
    qa = [("What was revenue?", f"${rev}M", "number"), ("What is monthly churn?", f"{churn}%", "number"),
          ("What is the NPS?", str(nps), "number")]
    return "Q3 Business Review", "July to September 2026", b, [("Revenue", f"${rev}M"), ("NPS", str(nps))], qa


def s_en_launch(rng):
    d = C.rdate(rng); d2 = C.rdate(rng)
    b = [(0, f"Code freeze: {C.MONTHS_EN[d.month - 1]} {d.day}"), (0, "QA sign-off by the release owner"),
         (0, "Staged rollout: 10% / 50% / 100% over 3 days"), (1, "Roll back if crash rate exceeds 0.5%"),
         (0, "Store review buffer: 5 business days"), (0, f"Post-launch review: {C.MONTHS_EN[d2.month - 1]} {d2.day}")]
    qa = [("When is code freeze?", f"{C.MONTHS_EN[d.month - 1]} {d.day}", "exact"),
          ("What crash rate triggers a rollback?", "0.5%", "number"), ("How long is the store review buffer?", "5 business days", "number")]
    return "Launch Checklist", None, b, [], qa


def s_en_onboard(rng, similar):
    a, bname = C.SIMILAR_EN[1] if similar else rng.sample(C.EN_NAMES, 2)
    b = [(0, "Week 1: accounts, laptop setup, security training (2 h)"), (0, f"Week 2: shadow {a} on support tickets"),
         (0, f"Week 3: first bug fix, reviewed by {bname}"), (0, "Week 4: present a 10-minute demo"),
         (1, "Buddy check-ins every Tuesday at 4 PM")]
    qa = [("Who reviews the first bug fix?", bname, "exact"), ("Whom does the new hire shadow in week 2?", a, "exact"),
          ("How long is the security training?", "2 h", "number")]
    return "New Hire Onboarding Plan", None, b, [], qa


CONTENT = {"weekly": s_weekly, "review": s_review, "launch": s_launch, "research": s_research, "budget": s_budget,
           "training": s_training, "agenda": s_agenda, "en_review": s_en_review, "en_launch": s_en_launch,
           "en_onboard": s_en_onboard}


# --------------------------------------------------------------------------- drawing

def render(title, subtitle, bullets, kpis, theme, dense, footer, page, lang, show_kpis):
    th = THEMES[theme]
    img = Image.new("RGB", (SW, SH), th["bg"])
    d = ImageDraw.Draw(img)
    tkey, bkey = ("helv_bold", "helv") if lang == "en" else ("hei_bold", "hei")
    tsize = 64 if not dense else 52
    y = 0
    if th["band"]:
        d.rectangle([0, 0, SW, 200], fill=th["band"])
        d.text((110, 100 if not subtitle else 80), fonts.check(tkey, title), font=fonts.font(tkey, tsize), fill=th["title"], anchor="lm")
        if subtitle:
            d.text((112, 150), fonts.check(bkey, subtitle), font=fonts.font(bkey, 30), fill=(200, 210, 226), anchor="lm")
        y = 260
    else:
        d.rectangle([80, 90, 92, 190], fill=th["accent"])
        d.text((120, 110), fonts.check(tkey, title), font=fonts.font(tkey, tsize), fill=th["title"])
        if subtitle:
            d.text((122, 110 + tsize + 18), fonts.check(bkey, subtitle), font=fonts.font(bkey, 30), fill=th["sub"])
        y = 290 if subtitle else 250
    bsize = 38 if not dense else 27
    lh = int(bsize * 1.55)
    right = SW - 110 - (560 if show_kpis else 0)
    for level, text in bullets:
        x = 150 + level * 70
        f = fonts.font(bkey, bsize - 4 * level)
        if level == 0:
            d.ellipse([x - 34, y + bsize * 0.42, x - 20, y + bsize * 0.42 + 14], fill=th["accent"])
        else:
            d.line([x - 36, y + bsize * 0.55, x - 18, y + bsize * 0.55], fill=th["sub"], width=3)
        for ln in C.wrap(text, f, right - x, d):
            d.text((x, y), fonts.check(bkey, ln), font=f, fill=th["text"] if level == 0 else th["sub"])
            y += lh - 4 * level
        y += int(bsize * 0.35)
    if show_kpis:
        px0, py0 = SW - 110 - 500, 280
        d.rounded_rectangle([px0, py0, SW - 110, py0 + 160 * len(kpis) + 40], 18, fill=th["panel"])
        for i, (lab, val) in enumerate(kpis):
            yy = py0 + 40 + i * 160
            d.text((px0 + 50, yy), fonts.check(bkey, lab), font=fonts.font(bkey, 30), fill=th["sub"])
            d.text((px0 + 50, yy + 42), fonts.check(tkey, val), font=fonts.font(tkey, 64), fill=th["accent"] if theme != "lowc" else th["text"])
    d.line([110, SH - 90, SW - 110, SH - 90], fill=th["foot"], width=2)
    d.text((110, SH - 58), fonts.check(bkey, footer), font=fonts.font(bkey, 24), fill=th["foot"], anchor="lm")
    d.text((SW - 110, SH - 58), fonts.check(bkey, page), font=fonts.font(bkey, 24), fill=th["foot"], anchor="rm")
    return img


def projected_photo(slide: Image.Image, rng: random.Random) -> Image.Image:
    """Phone photo of the slide on a projector screen: dark room, keystone, glare, blur, noise."""
    cw, ch = 1600, 1200
    room = photo.texture((cw, ch), (46, 44, 48), rng, grain=4, blotch=20)
    screen = Image.new("RGB", (SW + 80, SH + 80), (228, 228, 224))
    screen.paste(slide, (40, 40))
    screen = photo.contrast(screen, 0.88, toward=235)
    quad = photo.jitter_quad(screen.size[0], screen.size[1], cw, ch, rng, fill=0.9, tilt=0.09, rot_deg=3)
    img = photo.place(screen, room, quad)
    img = photo.lighting(img, rng, strength=0.3, vignette=0.35)
    img = photo.glare(img, rng, strength=0.35, radius=0.16)
    img = photo.blur(img, rng.uniform(0.8, 1.4))
    img = photo.noise(img, rng, sigma=6)
    return img


def build(idx: int, v: dict, rng: random.Random) -> dict:
    fn = CONTENT[v["content"]]
    args = (rng, v.get("similar", False)) if v["content"] in ("training", "en_onboard") else (rng,)
    title, subtitle, bullets, kpis, qa = fn(*args)
    lang = "en" if v["content"].startswith("en_") else "zh"
    company = rng.choice(C.EN_COMPANIES if lang == "en" else C.ZH_COMPANIES)
    total = rng.randrange(12, 30)
    page_no = rng.randrange(2, total)
    page = f"{page_no} / {total}"
    footer = company + (" · Internal" if lang == "en" else " · 内部资料")
    theme = v.get("theme", "corporate")
    dense = v.get("dense", False)
    if dense:  # a dense slide carries the notes as extra sub-bullets
        extra = ([(1, "Owner: see the project tracker for details"), (1, "Numbers as of the Friday snapshot")]
                 if lang == "en" else [(1, "详细数据见项目看板，本页为摘要"), (1, "数据截至上周五 18:00")])
        bullets = bullets + extra
    show_kpis = bool(kpis) and v.get("kpi_panel", True)
    img = render(title, subtitle, bullets, kpis, theme, dense, footer, page, lang, show_kpis)
    hard, info = [], {"theme": theme, "dense": dense}
    ext, quality = "png", None
    if v.get("photo"):
        img = projected_photo(img, rng)
        ext, quality = "jpg", 82
        hard += ["photo", "perspective", "glare"]
        info["photo"] = "projected"
    elif v.get("small"):
        img = img.resize((800, 450), Image.LANCZOS)
        ext, quality = "jpg", 72
        hard.append("small_text")
        info["downscale"] = "800x450"
    else:
        img = img.resize((1600, 900), Image.LANCZOS)
    if theme == "lowc":
        hard.append("low_contrast")
    if dense:
        hard.append("dense")
    if v.get("similar"):
        hard.append("similar_names")
    if C.has_units([t for _, t in bullets]):
        hard.append("units")
    img = photo.add_mark(img, corner="tr")
    gt = {"title": title, "subtitle": subtitle or "", "bullets": [{"level": lv, "text": t} for lv, t in bullets],
          "kpis": [{"label": a, "value": b} for a, b in kpis] if show_kpis else [], "footer": footer, "page": page}
    text_lines = [title] + ([subtitle] if subtitle else []) + [t for _, t in bullets] + \
                 ([f"{a} {b}" for a, b in kpis] if show_kpis else []) + [footer, page]
    qa = list(qa) + [("这页幻灯片的标题是什么？" if lang == "zh" else "What is the slide title?", title, "exact")]
    return {"image": img, "ext": ext, "quality": quality, "lang": lang if lang == "en" else C.mixed_lang(" ".join(text_lines)),
            "hard": hard, "render": info, "gt": gt, "text_lines": text_lines,
            "qa": [{"q": q, "a": a, "match": m} for q, a, m in qa], "topic": v["content"]}
