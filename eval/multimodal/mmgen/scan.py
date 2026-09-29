"""(6) Scanned document pages: an A4 PDF typeset with reportlab (CJK faces embedded), rasterised with
pdfium, then put through a flatbed-scan model (skew, paper tint, weak toner, blur, dust, lid shadow, JPEG).

Ground truth: title, key/value header fields, every text block in reading order (headings, paragraphs,
list items, table rows) and `full_text` = those blocks joined with newlines. Paragraph breaks are the
source's; line wraps inside a paragraph are not part of the ground truth.
"""

from __future__ import annotations

import io
import random
from xml.sax.saxutils import escape

import numpy as np
import pypdfium2 as pdfium
from PIL import Image
from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle
from reportlab.lib.units import mm
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle

from . import common as C
from . import fonts, photo

_REGISTERED = False


def _register():
    global _REGISTERED
    if _REGISTERED:
        return
    for name, key in (("SongtiSC", "song"), ("SongtiSCBold", "song_bold"), ("HeitiSC", "heiti"), ("HeitiSCMed", "heiti_med")):
        path, index = fonts.resolve(key)
        pdfmetrics.registerFont(TTFont(name, path, subfontIndex=index))
    _REGISTERED = True


# --------------------------------------------------------------------------- content
# blocks: ("h", text) heading, ("p", text) paragraph, ("li", text) list item, ("table", header, rows)

def d_minutes(rng, similar):
    a, b = C.SIMILAR_ZH[1] if similar else rng.sample(C.ZH_NAMES, 2)
    others = rng.sample(C.ZH_NAMES, 2)
    d = C.rdate(rng); d2 = C.rdate(rng); amt = rng.choice([5.8, 6.2, 7.5]); rate = rng.choice(["0.25%", "0.38%"])
    title = "点单小程序项目会议纪要"
    meta = [("时间", f"2026年{d.month}月{d.day}日 14:00至15:30"), ("地点", "3楼第二会议室"),
            ("参会人", f"{a}、{b}、{others[0]}、{others[1]}"), ("记录人", others[0])]
    blocks = [("h", "一、会议议题"),
              ("p", "本次会议讨论支付接入方案、门店灰度计划和第四季度预算，确认上线前的分工。"),
              ("h", "二、讨论内容"),
              ("p", f"{a}介绍了两种支付接入方案：聚合支付接入快、费率较高；直连方案费率为{rate}，但需要约 3 周开发。"
                    f"{b}补充了测试排期，认为回归测试至少需要 5 个工作日。"),
              ("p", f"与会人员同意先上线点单功能，支付功能推迟到{d2.month}月{d2.day}日之后再评估。"),
              ("h", "三、会议决议"),
              ("li", f"1. 项目总预算调整为 {amt} 万元，由{others[1]}在本周五前提交审批。"),
              ("li", "2. 灰度发布先覆盖 2 家门店，观察 7 天后再扩大范围。"),
              ("li", f"3. 支付方案选择直连方案，费率 {rate}。"),
              ("table", ["事项", "负责人", "截止日期"],
               [["提交预算审批", others[1], f"{d.month}月{min(28, d.day + 3)}日"],
                ["回归测试清单", b, f"{d.month}月{min(28, d.day + 5)}日"],
                ["门店培训材料", a, f"{d.month}月{min(28, d.day + 7)}日"]])]
    qa = [("会议在哪里开？", "3楼第二会议室", "exact"), ("项目总预算调整为多少？", f"{amt} 万元", "number"),
          ("谁负责回归测试清单？", b, "exact"), ("直连方案费率是多少？", rate, "number")]
    return title, meta, blocks, qa


def d_notice(rng, similar):
    names = rng.sample(C.ZH_NAMES, 4)
    if similar:
        names[0], names[1] = C.SIMILAR_ZH[3]
    tel = f"0000-{rng.randrange(1000, 9999)}"
    title = "关于国庆假期值班安排的通知"
    meta = [("发文部门", "行政部"), ("日期", "2026年9月24日")]
    rows = [[f"10月{d}日", names[(d - 1) % 4], "09:00至18:00"] for d in (1, 2, 3, 4, 5)]
    blocks = [("p", "各部门："),
              ("p", "根据公司安排，2026年国庆假期为10月1日至10月7日，共 7 天。为保证假期期间门店和线上订单正常处理，"
                    "现将值班安排通知如下。"),
              ("table", ["日期", "值班人", "时间"], rows),
              ("p", f"值班人员需保持手机畅通，遇到紧急情况请拨打值班电话 {tel}。10月6日至7日由各门店店长自行安排。"),
              ("p", "特此通知。")]
    qa = [("国庆假期共几天？", "7 天", "number"), ("10月3日谁值班？", names[2], "exact"), ("值班电话是多少？", tel, "exact"),
          ("10月1日谁值班？", names[0], "exact")]
    return title, meta, blocks, qa


def d_lease(rng, similar):
    a, b = rng.sample(C.ZH_NAMES, 2)
    rent = rng.choice([3200, 3500, 4200]); dep = rent * 2; area = rng.choice([68.5, 89.5, 102.3])
    city, dist, road = rng.choice(C.ZH_CITIES), rng.choice(C.ZH_DISTRICTS), rng.choice(C.ZH_ROADS)
    addr = f"{city}{dist}{road}{rng.randrange(1, 200)}号{rng.randrange(1, 12)}栋{rng.randrange(2, 30)}0{rng.randrange(1, 5)}室"
    title = "房屋租赁合同（节选）"
    meta = [("出租方（甲方）", a), ("承租方（乙方）", b), ("合同编号", f"ZL-2026-{rng.randrange(100, 999)}")]
    blocks = [("h", "第一条 房屋基本情况"),
              ("p", f"甲方将位于{addr}的房屋出租给乙方居住，建筑面积 {area} 平方米。"),
              ("h", "第二条 租期"),
              ("p", "租赁期限自2026年10月1日起至2027年9月30日止，共 12 个月。"),
              ("h", "第三条 租金及支付方式"),
              ("p", f"月租金为人民币 {rent:,} 元（大写：{C.cjk_upper(rent)}），按季度支付，每季度首月 5 日前支付。"),
              ("p", f"乙方应于签约当日支付押金 {dep:,} 元，租期届满无违约的，甲方应在 7 日内无息退还。"),
              ("h", "第四条 其他约定"),
              ("p", "物业费由甲方承担，水、电、燃气及网络费用由乙方承担。未经甲方书面同意，乙方不得转租。")]
    qa = [("月租金多少？", f"{rent:,} 元", "number"), ("押金多少？", f"{dep:,} 元", "number"),
          ("建筑面积多少？", f"{area} 平方米", "number"), ("承租方是谁？", b, "exact")]
    return title, meta, blocks, qa


def d_plan(rng, similar):
    a, b = C.SIMILAR_ZH[2] if similar else rng.sample(C.ZH_NAMES, 2)
    d1, d2, d3 = sorted(C.rdate(rng) for _ in range(3))
    budget = rng.choice([36, 48, 52]); stores = rng.choice([6, 8, 12])
    title = "秋季新品上市执行计划"
    meta = [("编制", a), ("审核", b), ("版本", "V1.2")]
    blocks = [("h", "1. 目标"),
              ("p", f"在 {stores} 家门店同步上市 3 款秋季饮品，首月销量目标 2.4 万杯，毛利率不低于 62%。"),
              ("h", "2. 里程碑"),
              ("table", ["阶段", "完成日期", "负责人"],
               [["配方定稿", f"{d1.month}月{d1.day}日", a], ["门店培训", f"{d2.month}月{d2.day}日", b],
                ["正式上市", f"{d3.month}月{d3.day}日", a]]),
              ("h", "3. 预算"),
              ("p", f"总预算 {budget} 万元，其中物料 {round(budget * 0.4, 1)} 万元、推广 {round(budget * 0.45, 1)} 万元、"
                    f"培训及其他 {round(budget - round(budget * 0.4, 1) - round(budget * 0.45, 1), 1)} 万元。"),
              ("h", "4. 风险"),
              ("p", "原料到货若晚于计划 5 天以上，上市日期顺延一周，并提前通知门店。")]
    qa = [("首月销量目标是多少？", "2.4 万杯", "number"), ("门店培训的负责人是谁？", b, "exact"),
          ("正式上市是哪天？", f"{d3.month}月{d3.day}日", "exact"), ("总预算多少？", f"{budget} 万元", "number")]
    return title, meta, blocks, qa


def d_en_memo(rng, similar):
    a, b = C.SIMILAR_EN[2] if similar else rng.sample(C.EN_NAMES, 2)
    d = C.rdate(rng); room = rng.choice(["4B", "12A", "7C"]); boxes = rng.choice([3, 4, 5]); budget = rng.choice([18500, 22400])
    date_s = f"{C.MONTHS_EN[d.month - 1]} {d.day}, 2026"
    title = "MEMORANDUM"
    meta = [("To", "All staff, Operations"), ("From", a), ("Date", "September 22, 2026"), ("Subject", "Office move to Floor 12")]
    blocks = [("p", f"The operations team will move to Suite {room} on Floor 12 on {date_s}. Please pack your desk into no more "
                    f"than {boxes} boxes and label each box with your name and new desk number."),
              ("p", f"Movers arrive at 8:30 AM. Network and phones will be offline from 6:00 PM the day before until noon on "
                    f"moving day. {b} coordinates the move; send questions to the facilities queue."),
              ("p", f"The approved moving budget is ${budget:,}. Receipts for personal items are not reimbursed."),
              ("li", "1. Pack by 4:00 PM the day before the move."),
              ("li", "2. Keep laptops with you; do not pack them."),
              ("li", "3. Unpack by Friday so the old floor can be handed back.")]
    qa = [("When is the move?", date_s, "exact"), ("Who coordinates the move?", b, "exact"),
          ("How many boxes at most?", str(boxes), "number"), ("What is the moving budget?", f"${budget:,}", "number")]
    return title, meta, blocks, qa


def d_en_policy(rng, similar):
    per = rng.choice([55, 65, 75]); mile = rng.choice([0.67, 0.70]); hotel = rng.choice([180, 220]); days = rng.choice([30, 45])
    title = "Travel Reimbursement Policy (excerpt)"
    meta = [("Policy no.", f"FIN-{rng.randrange(10, 99)}"), ("Effective", "October 1, 2026"), ("Owner", "Finance")]
    blocks = [("h", "1. Meals"),
              ("p", f"Employees on approved travel receive a per diem of ${per} per full day. Travel days are paid at 75% of the per diem."),
              ("h", "2. Mileage"),
              ("p", f"Use of a personal car is reimbursed at ${mile:.2f} per mile. Parking and tolls are reimbursed at cost with receipts."),
              ("h", "3. Lodging"),
              ("p", f"Hotel rates up to ${hotel} per night are pre-approved. Higher rates need written approval from the budget owner."),
              ("h", "4. Claims"),
              ("p", f"Submit claims within {days} days of returning. Claims submitted later than {days} days may be declined."),
              ("table", ["Item", "Limit", "Receipt needed"],
               [["Per diem", f"${per}/day", "No"], ["Mileage", f"${mile:.2f}/mile", "Log only"], ["Hotel", f"${hotel}/night", "Yes"]])]
    qa = [("What is the per diem?", f"${per}", "number"), ("What is the mileage rate?", f"${mile:.2f} per mile", "number"),
          ("Within how many days must claims be submitted?", f"{days} days", "number")]
    return title, meta, blocks, qa


def d_en_minutes(rng, similar):
    a, b = C.SIMILAR_EN[0] if similar else rng.sample(C.EN_NAMES, 2)
    c = rng.choice([n for n in C.EN_NAMES if n not in (a, b)])
    d = C.rdate(rng); pct = rng.choice([12, 15, 18]); ms = rng.choice([450, 600])
    title = "Product Sync - Meeting Minutes"
    meta = [("Date", f"{C.MONTHS_EN[d.month - 1]} {d.day}, 2026"), ("Attendees", f"{a}, {b}, {c}"), ("Note taker", c)]
    blocks = [("h", "Decisions"),
              ("li", "1. Ship ordering in the next release; payments follow in a separate release."),
              ("li", f"2. Raise the checkout timeout alert threshold to {ms} ms."),
              ("h", "Discussion"),
              ("p", f"{a} reported that weekly active users grew {pct}% after the loyalty launch. {b} raised concerns about "
                    "support load during the rollout and asked for a staged release."),
              ("h", "Action items"),
              ("table", ["Action", "Owner", "Due"],
               [["Staged rollout plan", b, "Friday"], ["Alert threshold change", a, "Monday"], ["Release notes", c, "Tuesday"]])]
    qa = [("By how much did weekly active users grow?", f"{pct}%", "number"), ("Who owns the staged rollout plan?", b, "exact"),
          ("What is the new alert threshold?", f"{ms} ms", "number")]
    return title, meta, blocks, qa


CONTENT = {"minutes": (d_minutes, "zh"), "notice": (d_notice, "zh"), "lease": (d_lease, "zh"), "plan": (d_plan, "zh"),
           "en_memo": (d_en_memo, "en"), "en_policy": (d_en_policy, "en"), "en_minutes": (d_en_minutes, "en")}


# --------------------------------------------------------------------------- typesetting

def typeset(title, meta, blocks, lang: str, body_pt: float) -> bytes:
    _register()
    if lang == "zh":
        body_f, bold_f, head_f = "SongtiSC", "HeitiSCMed", "HeitiSCMed"
        wrap = "CJK"
    else:
        body_f, bold_f, head_f = "Times-Roman", "Times-Bold", "Helvetica-Bold"
        wrap = None
    lead = body_pt * 1.6
    st_title = ParagraphStyle("t", fontName=head_f, fontSize=body_pt * 1.75, leading=body_pt * 2.4, alignment=TA_CENTER,
                              spaceAfter=body_pt)
    st_meta = ParagraphStyle("m", fontName=body_f, fontSize=body_pt, leading=lead, wordWrap=wrap)
    st_body = ParagraphStyle("b", fontName=body_f, fontSize=body_pt, leading=lead, spaceAfter=body_pt * 0.6,
                             firstLineIndent=body_pt * 2 if lang == "zh" else 0, wordWrap=wrap)
    st_li = ParagraphStyle("l", parent=st_body, firstLineIndent=0, leftIndent=body_pt * 1.2, spaceAfter=body_pt * 0.3)
    st_h = ParagraphStyle("h", fontName=bold_f, fontSize=body_pt * 1.1, leading=lead * 1.1, spaceBefore=body_pt * 0.6,
                          spaceAfter=body_pt * 0.3, wordWrap=wrap)
    st_cell = ParagraphStyle("c", fontName=body_f, fontSize=body_pt * 0.95, leading=body_pt * 1.35, wordWrap=wrap)
    story = [Paragraph(escape(title), st_title)]
    sep = "：" if lang == "zh" else ": "
    for k, v in meta:
        story.append(Paragraph(escape(f"{k}{sep}{v}"), st_meta))
    story.append(Spacer(1, body_pt))
    for b in blocks:
        if b[0] == "h":
            story.append(Paragraph(escape(b[1]), st_h))
        elif b[0] == "p":
            story.append(Paragraph(escape(b[1]), st_body))
        elif b[0] == "li":
            story.append(Paragraph(escape(b[1]), st_li))
        else:
            data = [[Paragraph(escape(c), st_cell) for c in b[1]]] + [[Paragraph(escape(c), st_cell) for c in r] for r in b[2]]
            t = Table(data, hAlign="LEFT", colWidths=[55 * mm, 45 * mm, 45 * mm])
            t.setStyle(TableStyle([("GRID", (0, 0), (-1, -1), 0.6, colors.black),
                                   ("BACKGROUND", (0, 0), (-1, 0), colors.Color(0.9, 0.9, 0.9)),
                                   ("VALIGN", (0, 0), (-1, -1), "MIDDLE")]))
            story += [Spacer(1, body_pt * 0.4), t, Spacer(1, body_pt * 0.8)]
    buf = io.BytesIO()
    doc = SimpleDocTemplate(buf, pagesize=A4, leftMargin=25 * mm, rightMargin=25 * mm, topMargin=25 * mm, bottomMargin=25 * mm,
                            title="synthetic", author="synthetic", creator="mindloom eval generator")
    page_label = "第 1 页 共 1 页" if lang == "zh" else "Page 1 of 1"

    def footer(canvas, _doc):
        canvas.saveState()
        canvas.setFont(body_f, body_pt * 0.8)
        canvas.drawCentredString(A4[0] / 2, 14 * mm, page_label)
        canvas.restoreState()

    doc.build(story, onFirstPage=footer)
    data = buf.getvalue()
    if len(pdfium.PdfDocument(data)) != 1:
        raise ValueError(f"'{title}' does not fit on one page")
    return data


def rasterise(pdf: bytes, dpi: int) -> Image.Image:
    page = pdfium.PdfDocument(pdf)[0]
    return page.render(scale=dpi / 72).to_pil().convert("RGB")


def scan_model(img: Image.Image, rng: random.Random, v: dict) -> tuple[Image.Image, dict]:
    info = {}
    if v.get("faint"):
        img = photo.contrast(img, 0.42)
        info["toner"] = 0.42
    tint = rng.choice([(246, 244, 236), (240, 240, 238), (250, 248, 242)])  # paper colour, multiplied in
    img = Image.fromarray((np.asarray(img, np.float32) / 255.0 * np.array(tint, np.float32)).clip(0, 255).astype(np.uint8))
    deg = v.get("rotate", rng.uniform(-1.2, 1.2))
    img = photo.rotate_scan(img, deg, fill=(214, 214, 210))
    info["rotate_deg"] = round(deg, 2)
    if v.get("lid_shadow", True):
        w, h = img.size
        edge = Image.new("RGB", (w, h), (0, 0, 0))
        mask = Image.linear_gradient("L").rotate(90 if rng.random() < 0.5 else -90).resize((w, h))
        mask = mask.point(lambda p: max(0, p - 200) * 3)
        img = Image.composite(edge, img, mask.point(lambda p: int(p * 0.5)))
    img = photo.blur(img, v.get("blur", 0.6))
    img = photo.noise(img, rng, sigma=v.get("noise", 3.5))
    img = photo.speckle(img, rng, density=0.0006)
    if v.get("gray", True):
        img = img.convert("L").convert("RGB")
    info["blur"] = v.get("blur", 0.6)
    return img, info


def build(idx: int, v: dict, rng: random.Random) -> dict:
    fn, lang = CONTENT[v["content"]]
    title, meta, blocks, qa = fn(rng, v.get("similar", False))
    body_pt = v.get("body_pt", 11.0)
    pdf = typeset(title, meta, blocks, lang, body_pt)
    dpi = v.get("dpi", 150)
    img = rasterise(pdf, dpi)
    img, info = scan_model(img, rng, v)
    img = photo.add_mark(img, corner="tr")
    info.update(dpi=dpi, body_pt=body_pt, engine="reportlab+pdfium")
    sep = "：" if lang == "zh" else ": "
    lines = [title] + [f"{k}{sep}{val}" for k, val in meta]
    table = None
    for b in blocks:
        if b[0] == "table":
            table = {"header": b[1], "rows": b[2]}
            lines += [" | ".join(b[1])] + [" | ".join(r) for r in b[2]]
        else:
            lines.append(b[1])
    lines.append("第 1 页 共 1 页" if lang == "zh" else "Page 1 of 1")
    hard = []
    if body_pt <= 9:
        hard.append("small_text")
    if v.get("faint"):
        hard.append("low_contrast")
    if abs(info["rotate_deg"]) >= 2.5:
        hard.append("rotation")
    if v.get("blur", 0.6) >= 1.2:
        hard.append("blur")
    if v.get("similar"):
        hard.append("similar_names")
    if table:
        hard.append("table")
    if C.has_units(lines):
        hard.append("units")
    gt = {"title": title, "fields": [{"key": k, "value": val} for k, val in meta],
          "blocks": [{"type": {"h": "heading", "p": "paragraph", "li": "list_item"}[b[0]], "text": b[1]} if b[0] != "table"
                     else {"type": "table", "header": b[1], "rows": b[2]} for b in blocks],
          "full_text": "\n".join(lines)}
    return {"image": img, "ext": "jpg", "quality": v.get("jpeg", 78), "lang": lang, "hard": hard, "render": info, "gt": gt, "text_lines": lines,
            "qa": [{"q": q, "a": a, "match": m} for q, a, m in qa], "topic": v["content"]}
