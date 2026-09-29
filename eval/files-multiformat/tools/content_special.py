"""Standalone specs for structured and visual types (ics, vcf, eml, mbox, zip, epub, json, xml, images, svg, gifs, ...).

make_standalone(ftype, name, rng) returns a spec in the same shape as content_matters.FILES entries.
Everything is invented; see content_families for the pools.
"""

from __future__ import annotations

import html
import json

import content_families as CF
from content_families import (CITIES, EN_NAMES, EN_ORGS, ORGS, people, person, ymd)
from content_matters import q


def _visual_from(base, style, **kw):
    """Image spec that shows all of a family's content."""
    lines, fields, table = [], [], None
    for b in base["blocks"]:
        if b[0] == "p":
            lines.append(b[1])
        elif b[0] == "ul":
            lines += [f"• {x}" for x in b[1]]
        elif b[0] == "h":
            lines.append(f"【{b[1]}】")
        elif b[0] == "kv":
            fields += list(b[1])
        elif b[0] == "table" and table is None:
            table = b[1]
        elif b[0] == "table":
            lines += ["  ".join(b[1]["columns"])] + ["  ".join(str(c) for c in r) for r in b[1]["rows"]]
    v = {"style": style, "title": base["title"], "lines": lines, "fields": fields, "table": table}
    v.update(kw)
    return v


def _truth(base, notes=None):
    t = {k: base[k] for k in ("key_fields", "numbers", "qa")}
    if notes:
        t["notes"] = notes
    return t


def _slides_from(base, image_slides=(), max_bullets=4):
    """Title slide + one slide per section; tables become their own slide; listed indexes are image-only."""
    slides = [{"title": base["title"], "subtitle": "合成数据 · 仅供评测" if base.get("lang", "zh") == "zh" else "Synthetic data · evaluation only"}]
    cur = None
    for b in base["blocks"]:
        if b[0] == "h":
            cur = {"title": b[1], "bullets": []}
            slides.append(cur)
        elif b[0] in ("p", "ul", "kv"):
            items = [b[1]] if b[0] == "p" else (b[1] if b[0] == "ul" else
                                                  [f"{k}{'：' if base.get('lang', 'zh') == 'zh' else ': '}{v}" for k, v in b[1]])
            if cur is None or len(cur["bullets"]) + len(items) > max_bullets:
                cur = {"title": base["title"] if cur is None else cur["title"] + ("（续）" if base.get("lang", "zh") == "zh" else " (cont.)"),
                       "bullets": []}
                slides.append(cur)
            cur["bullets"] += items
        elif b[0] == "table":
            t = b[1]
            slides.append({"title": t.get("caption") or ("数据表" if base.get("lang", "zh") == "zh" else "Table"), "table": t})
            cur = None
    for i in image_slides:
        if 0 < i < len(slides):
            slides[i]["image"] = True
    return slides


# ============================================================================== epub books

def epub_book(name, rng):
    if name == "travel_book":
        city = rng.choice(CITIES)
        spots = rng.sample(["老城墙", "茶园", "湖心岛", "钟楼", "旧码头", "竹林寺"], 3)
        price = rng.choice([30, 45, 60])
        book = {"title": f"{city}慢游小册", "author": person(rng), "lang": "zh", "identifier": f"urn:uuid:travel-{rng.randint(1000, 9999)}",
                "chapters": [{"title": "第一章 出发前", "blocks": [("p", f"{city}四季分明，最适合出游的是春秋两季。市区地铁共 {rng.randint(4, 9)} 条线路。")]},
                             {"title": "第二章 三个去处", "blocks": [("ul", [f"{s}：建议停留 {rng.randint(1, 3)} 小时" for s in spots]),
                                                                  ("p", f"{spots[1]}门票 {price} 元，周一闭馆。")]},
                             {"title": "第三章 吃什么", "blocks": [("p", "推荐当地的早茶与夜市小吃，人均约 50 元。"), ("p", "本书为合成数据。")]}]}
        truth = {"key_fields": {"城市": city, "门票": price, "闭馆": "周一"}, "numbers": [{"value": price, "label": "门票"}],
                 "qa": [q(f"{spots[1]}门票多少元？", price, "number"), q(f"{spots[1]}哪天闭馆？", "周一"), q("推荐的第一个去处是哪里？", spots[0])]}
    elif name == "recipe_book":
        dishes = [CF.fam_recipe(rng, i) for i in range(3)]
        book = {"title": "周末烘焙三则", "author": person(rng), "lang": "zh", "identifier": f"urn:uuid:bake-{rng.randint(1000, 9999)}",
                "chapters": [{"title": "前言", "blocks": [("p", "本书收录 3 道适合周末的烘焙与小菜，材料都能在超市买到。")]}]
                            + [{"title": d["title"], "blocks": d["blocks"]} for d in dishes]}
        d0, d2 = dishes[0], dishes[2]
        truth = {"key_fields": {"章节数": 3, d0["title"]: d0["key_fields"]["温度"], d2["title"]: d2["key_fields"]["时长"]},
                 "numbers": [{"value": 3, "label": "章节"}],
                 "qa": [q(f"{d0['title']}烤箱预热多少度？", int(d0["key_fields"]["温度"].rstrip("℃")), "number"),
                        q(f"{d2['title']}烘烤多少分钟？", int(d2["key_fields"]["时长"].rstrip("分钟")), "number"),
                        q("书里一共几道菜？", 3, "number")]}
    elif name == "handbook_en":
        org = rng.choice(EN_ORGS)
        days = rng.choice([10, 15, 20])
        wifi = f"{org.split()[0]}-Guest"
        book = {"title": f"{org} Onboarding Handbook", "author": "People Team", "lang": "en", "identifier": f"urn:uuid:hb-{rng.randint(1000, 9999)}",
                "chapters": [{"title": "Your first week", "blocks": [("p", f"On day one you meet your buddy, {rng.choice(EN_NAMES)}, at 9:30 in the lobby."),
                                                                     ("ul", ["Collect your badge", "Set up your laptop", "Book the safety briefing"])]},
                             {"title": "Time off", "blocks": [("p", f"Full-time staff receive {days} days of paid leave per year, plus public holidays.")]},
                             {"title": "Practical things", "blocks": [("p", f"Guest Wi-Fi network: {wifi}. The office opens at 7:30 and closes at 20:00."),
                                                                      ("p", "This handbook is synthetic data for evaluation only.")]}]}
        truth = {"key_fields": {"leave_days": days, "wifi": wifi, "office_hours": "7:30-20:00"}, "numbers": [{"value": days, "label": "leave days"}],
                 "qa": [q("How many days of paid leave per year?", days, "number"), q("What is the guest Wi-Fi network?", wifi, "exact"),
                        q("When does the office close?", "20:00")]}
    else:  # water_book
        litres = rng.choice([120, 150, 180])
        save = rng.choice([20, 25, 30])
        book = {"title": "家庭节水指南", "author": "社区环保小组", "lang": "zh", "identifier": f"urn:uuid:water-{rng.randint(1000, 9999)}",
                "chapters": [{"title": "一、我们用了多少水", "blocks": [("p", f"三口之家每天平均用水约 {litres} 升，其中冲厕约占 30%。")]},
                             {"title": "二、五个小办法", "blocks": [("ul", ["淋浴时间控制在 5 分钟内", "洗菜水用来浇花", "更换节水龙头", "检查马桶是否漏水", "满载再开洗衣机"])]},
                             {"title": "三、效果", "blocks": [("table", {"columns": ["办法", "每月可省（升）"],
                                                                      "rows": [["缩短淋浴", 450], ["节水龙头", 300], ["满载洗衣", 200]]}),
                                                           ("p", f"坚持一个月，用水量可下降约 {save}%。本书为合成数据。")]}]}
        truth = {"key_fields": {"日均用水": litres, "下降比例": f"{save}%", "淋浴时长": "5分钟"},
                 "numbers": [{"value": litres, "label": "升/天"}, {"value": save, "label": "%"}],
                 "qa": [q("三口之家每天用水约多少升？", litres, "number"), q("坚持一个月用水量下降约多少？", save, "number"),
                        q("节水龙头每月可省多少升？", 300, "number")]}
    return {"book": book, "lang": book["lang"], "title": book["title"], "truth": truth}


# ============================================================================== json / xml

def json_spec(name, rng):
    if name == "itinerary":
        base = CF.fam_itinerary(rng, 1)
        return {"record": base["record"], "title": base["title"], "lang": "zh", "truth": _truth(base)}
    if name == "inventory":
        base = CF.fam_inventory(rng, 0)
        rec = {"status": "ok", "generated_at": "2026-10-01T09:00:00+08:00", "warehouse": base["title"], "data": base["record"]["inventory"],
               "note": "合成数据"}
        return {"record": rec, "title": base["title"], "lang": "zh", "truth": _truth(base)}
    # survey_en
    n = rng.randint(80, 240)
    scores = {"very satisfied": rng.randint(20, 40), "satisfied": rng.randint(30, 45), "neutral": rng.randint(5, 20)}
    scores["unsatisfied"] = 100 - sum(scores.values())
    top = max(scores, key=scores.get)
    rec = {"survey": "Cafeteria feedback", "org": rng.choice(EN_ORGS), "responses": n, "period": {"from": "2026-09-01", "to": "2026-09-30"},
           "results_pct": scores, "top_request": rng.choice(["more vegetarian options", "longer opening hours", "quieter seating"]),
           "note": "synthetic data"}
    truth = {"key_fields": {"responses": n, "top_answer": top, "top_request": rec["top_request"]},
             "numbers": [{"value": n, "label": "responses"}] + [{"value": v, "label": k} for k, v in scores.items()],
             "qa": [q("How many responses were collected?", n, "number"), q("What share answered 'satisfied' (%)?", scores["satisfied"], "number"),
                    q("What was the most frequent request?", rec["top_request"])]}
    return {"record": rec, "title": "Cafeteria feedback survey", "lang": "en", "truth": truth}


def xml_spec(name, rng):
    e = html.escape
    if name == "rss":
        org = rng.choice(ORGS)
        items = [(f"{org[:4]}发布{rng.randint(2, 9)}月运营简报", f"2026-{rng.randint(3, 9):02d}-{rng.randint(1, 28):02d}"),
                 ("新办公区将于下月启用", f"2026-10-{rng.randint(1, 28):02d}"), ("年度志愿服务时长突破 3,000 小时", "2026-09-15")]
        body = "\n".join(f"    <item>\n      <title>{e(t)}</title>\n      <link>https://news.example.com/{i}</link>\n"
                         f"      <pubDate>{d}</pubDate>\n      <description>{e(t)}。（合成数据）</description>\n    </item>" for i, (t, d) in enumerate(items, 1))
        xml = (f'<?xml version="1.0" encoding="UTF-8"?>\n<rss version="2.0">\n  <channel>\n    <title>{e(org)} 新闻</title>\n'
               f'    <link>https://news.example.com/</link>\n    <description>合成数据</description>\n{body}\n  </channel>\n</rss>\n')
        truth = {"key_fields": {"频道": f"{org} 新闻", "条目数": 3}, "numbers": [{"value": 3000, "label": "志愿时长"}],
                 "qa": [q("这个订阅源有几条新闻？", 3, "number", derived=True), q("志愿服务时长突破多少小时？", 3000, "number"),
                        q("第二条新闻的标题是什么？", "新办公区将于下月启用")]}
        return {"xml": xml, "title": f"{org} 新闻 RSS", "lang": "zh", "truth": truth}
    if name == "invoice":
        base = CF.fam_invoice(rng, 1)
        r = base["record"]
        lines = "\n".join(f'    <Line no="{i}"><Item>{e(it["name"])}</Item><Qty>{it["qty"]}</Qty><UnitPrice currency="CNY">{it["unit_price"]}</UnitPrice>'
                          f'<Amount currency="CNY">{it["amount"]}</Amount></Line>' for i, it in enumerate(r["items"], 1))
        xml = (f'<?xml version="1.0" encoding="UTF-8"?>\n<!-- 合成数据 -->\n<Invoice xmlns="urn:example:invoice:2" number="{e(r["number"])}" date="{r["date"]}">\n'
               f'  <Seller>{e(r["vendor"])}</Seller>\n  <Buyer>{e(r["customer"])}</Buyer>\n  <Lines>\n{lines}\n  </Lines>\n'
               f'  <Subtotal>{r["subtotal"]}</Subtotal>\n  <Tax rate="{r["tax_rate"]}">{r["tax"]}</Tax>\n  <Total currency="CNY">{r["total"]}</Total>\n</Invoice>\n')
        return {"xml": xml, "title": base["title"], "lang": "zh", "truth": _truth(base)}
    if name == "inventory":
        base = CF.fam_inventory(rng, 1)
        rows = "\n".join(f'  <item name="{e(i["name"])}" unit="{e(i["unit"])}" stock="{i["stock"]}" safety="{i["safety_stock"]}" reorder="{str(i["reorder"]).lower()}"/>'
                         for i in base["record"]["inventory"])
        xml = f'<?xml version="1.0" encoding="UTF-8"?>\n<inventory title="{e(base["title"])}" note="合成数据">\n{rows}\n</inventory>\n'
        t = _truth(base)
        # "which need reordering" is answerable from reorder="true"
        return {"xml": xml, "title": base["title"], "lang": "zh", "truth": t}
    # registration_en
    names = rng.sample(EN_NAMES, 4)
    ev = rng.choice(["Community Coding Night", "Spring Science Fair", "River Clean-up Day"])
    fees = [rng.choice([0, 10, 15]) for _ in names]
    rows = "\n".join(f'    <attendee id="R{100 + i}"><name>{n}</name><ticket>{"student" if f == 0 else "standard"}</ticket><fee currency="USD">{f}</fee></attendee>'
                     for i, (n, f) in enumerate(zip(names, fees)))
    xml = (f'<?xml version="1.0" encoding="UTF-8"?>\n<registrations event="{ev}" date="2026-11-{rng.randint(1, 28):02d}" note="synthetic data">\n'
           f'  <attendees count="{len(names)}">\n{rows}\n  </attendees>\n  <total_fees currency="USD">{sum(fees)}</total_fees>\n</registrations>\n')
    truth = {"key_fields": {"event": ev, "attendees": len(names), "total_fees": sum(fees)}, "numbers": [{"value": sum(fees), "label": "total fees"}],
             "qa": [q("How many attendees are registered?", len(names), "number", derived=True), q("What are the total fees in USD?", sum(fees), "number"),
                    q("What is the attendee ID of " + names[2] + "?", "R102", "exact")]}
    return {"xml": xml, "title": f"{ev} registrations", "lang": "en", "truth": truth}


# ============================================================================== visuals (png/jpg/heic/webp/bmp/tiff)

def visual_spec(name, rng):
    if name in ("budget_chart",):
        base = CF.fam_budget(rng, rng.randint(0, 4))
        c = base["chart"]
        v = {"style": "chart", "title": c["title"], "series": c["series"], "xlabels": c["xlabels"], "kind": "bar", "ylabel": "元"}
        return {"visual": v, "title": base["title"], "lang": "zh", "truth": {
            "key_fields": {"类别": c["xlabels"], "预算": c["series"]["预算"], "实际": c["series"]["实际"]},
            "numbers": [{"value": x, "label": f"预算-{k}"} for k, x in zip(c["xlabels"], c["series"]["预算"])],
            "qa": [q(f"{c['xlabels'][0]}的预算是多少元？", c["series"]["预算"][0], "number"),
                   q(f"{c['xlabels'][2]}实际花了多少元？", c["series"]["实际"][2], "number"),
                   q("预算最高的类别是？", base["key_fields"]["最大类别"])]}}
    if name in ("lab_chart",):
        base = CF.fam_labrecord(rng, rng.randint(0, 4))
        c = base["chart"]
        v = {"style": "chart", "title": c["title"], "series": c["series"], "xlabels": c["xlabels"], "kind": "line"}
        k = list(c["series"])[0]
        vals = c["series"][k]
        return {"visual": v, "title": base["title"], "lang": "zh", "truth": {
            "key_fields": {"样品": c["xlabels"], k: vals}, "numbers": [{"value": x, "label": s} for s, x in zip(c["xlabels"], vals)],
            "qa": [q(f"{c['xlabels'][1]} 的{k}是多少？", vals[1], "number"), q("哪个样品最高？", base["key_fields"]["最高样品"], "exact")]}}
    if name in ("league_chart",):
        base = CF.fam_league(rng, rng.randint(0, 3))
        c = base["chart"]
        v = {"style": "chart", "title": c["title"], "series": c["series"], "xlabels": c["xlabels"], "kind": "bar", "w": 900, "h": 560}
        return {"visual": v, "title": base["title"], "lang": "zh", "truth": {
            "key_fields": {"第一名": c["xlabels"][0]}, "numbers": [{"value": x, "label": t} for t, x in zip(c["xlabels"], c["series"]["积分"])],
            "qa": [q("积分最高的是哪个队？", c["xlabels"][0]), q(f"{c['xlabels'][3]}积多少分？", c["series"]["积分"][3], "number")]}}
    if name == "signup_window":
        who = person(rng)
        code = f"BM{rng.randint(100000, 999999)}"
        m, d = rng.randint(3, 11), rng.randint(1, 28)
        fee = rng.choice([0, 30, 50, 80])
        v = {"style": "window", "app": "活动报名系统", "badge": "报名成功",
             "lines": ["报名成功", f"{rng.choice(['城市定向越野', '亲子手工课', '周末读书会'])} · {ymd(m, d)}"],
             "fields": [("报名人", who), ("报名编号", code), ("集合时间", f"{ymd(m, d)} 08:30"), ("集合地点", rng.choice(["东门广场", "图书馆正门", "体育馆北侧"])),
                        ("费用", f"{fee}元")]}
        return {"visual": v, "title": "报名成功截图", "lang": "zh", "truth": {
            "key_fields": {"报名人": who, "报名编号": code, "费用": fee}, "numbers": [{"value": fee, "label": "费用"}],
            "qa": [q("报名编号是多少？", code, "exact"), q("几点集合？", "08:30"), q("费用多少元？", fee, "number")]}}
    if name == "order_window":
        order = f"{rng.randint(2026000000, 2026999999)}"
        items = rng.sample([("降噪耳机", 699), ("保温杯", 89), ("机械键盘", 399), ("护眼台灯", 239), ("双肩包", 259)], 3)
        total = sum(p for _, p in items)
        v = {"style": "window", "app": "订单详情", "badge": "已发货", "lines": ["订单已发货", "预计 2 天内送达（合成数据）"],
             "fields": [("订单号", order), ("收货城市", rng.choice(CITIES))],
             "table": {"columns": ["商品", "单价（元）"], "rows": [[n, p] for n, p in items] + [["实付", total]]}}
        return {"visual": v, "title": "订单详情截图", "lang": "zh", "truth": {
            "key_fields": {"订单号": order, "实付": total}, "numbers": [{"value": total, "label": "实付"}],
            "qa": [q("订单号是多少？", order, "exact"), q("实付多少元？", total, "number"), q(f"{items[1][0]}多少钱？", items[1][1], "number")]}}
    if name in ("notice_card", "notice_photo", "sign"):
        base = CF.fam_notice(rng, rng.randint(0, 4))
        if name == "sign":
            v = {"style": "card", "title": base["title"], "lines": [b[1] for b in base["blocks"] if b[0] == "p"][1:2],
                 "fields": [("联系人", base["key_fields"]["联系人"])], "w": 760, "bg": (255, 214, 0), "accent": (30, 30, 30)}
            t = {"key_fields": {k: base["key_fields"][k] for k in ("地点", "日期", "开始时间", "联系人")}, "numbers": [],
                 "qa": base["qa"]}
            return {"visual": v, "title": base["title"], "lang": "zh", "truth": t}
        v = _visual_from(base, "card", photo=(name == "notice_photo"), w=900)
        return {"visual": v, "title": base["title"], "lang": "zh", "truth": _truth(base)}
    if name in ("receipt_photo",):
        base = CF.fam_invoice(rng, 2)
        v = _visual_from(base, "card", photo=True, w=760, line_size=24)
        return {"visual": v, "title": base["title"], "lang": "zh", "truth": _truth(base, "手机拍摄的收据：倾斜、阴影。")}
    if name == "minutes_photo":
        base = CF.fam_minutes(rng, rng.randint(0, 5))
        v = _visual_from(base, "card", photo=True, w=1000, bg=(250, 250, 246))
        return {"visual": v, "title": base["title"], "lang": "zh", "truth": _truth(base, "白板/打印纪要的照片。")}
    if name in ("label_photo", "label_card"):
        sku = f"SKU-{rng.randint(10000, 99999)}"
        lot = f"L{rng.randint(260101, 261031)}"
        exp = f"2027-{rng.randint(1, 12):02d}"
        qty = rng.choice([50, 100, 200])
        item = rng.choice(["一次性丁腈手套 M 号", "医用酒精棉片", "PP 离心管 15mL", "称量舟 100mL"])
        v = {"style": "card", "title": item, "w": 760, "photo": name == "label_photo", "bg": (248, 248, 240),
             "lines": [f"{rng.choice(ORGS)} 出品"], "fields": [("货号", sku), ("批号", lot), ("有效期至", exp), ("数量", f"{qty} 只/盒")]}
        return {"visual": v, "title": item, "lang": "zh", "truth": {
            "key_fields": {"货号": sku, "批号": lot, "有效期": exp, "数量": qty}, "numbers": [{"value": qty, "label": "数量"}],
            "qa": [q("批号是多少？", lot, "exact"), q("有效期到什么时候？", exp, accept=[exp.replace("-", "年") + "月"]),
                   q("每盒多少只？", qty, "number")]}}
    if name in ("schedule_photo", "schedule_table"):
        base = CF.fam_schedule(rng, rng.randint(0, 3))
        v = _visual_from(base, "card", photo=name == "schedule_photo", w=1100)
        return {"visual": v, "title": base["title"], "lang": "zh", "truth": _truth(base)}
    if name == "recipe_photo":
        base = CF.fam_recipe(rng, rng.randint(0, 4))
        v = _visual_from(base, "card", photo=True, w=900, bg=(255, 250, 240))
        return {"visual": v, "title": base["title"], "lang": "zh", "truth": _truth(base)}
    if name == "league_table":
        base = CF.fam_league(rng, rng.randint(0, 3))
        v = {"style": "window", "app": "赛事积分", "lines": [base["title"], "胜一场积3分（合成数据）"], "table": base["table"]}
        return {"visual": v, "title": base["title"], "lang": "zh", "truth": _truth(base)}
    raise KeyError(name)


def tiff_spec(name, rng):
    if name == "lease_scan2":
        base = CF.fam_lease(rng, 0)
        app = {"title": "附件：房屋交接清单", "lang": "zh",
               "blocks": [("table", {"columns": ["物品", "数量", "状态"], "rows": [["空调", 2, "正常"], ["冰箱", 1, "正常"], ["钥匙", 3, "已交"]]}),
                          ("p", "双方确认以上物品完好。（合成数据）")]}
        t = _truth(base, "两页 TIFF 扫描：第 1 页合同摘要，第 2 页交接清单。")
        t["qa"] = t["qa"] + [q("交接了几把钥匙？", 3, "number")]
        return {"pages": [base, app], "title": base["title"], "lang": "zh", "truth": t}
    fam = {"labrecord_scan": CF.fam_labrecord, "notice_fax": CF.fam_notice, "invoice_scan": CF.fam_invoice}[name]
    base = fam(rng, rng.randint(0, 3))
    return {"pages": [base], "title": base["title"], "lang": "zh", "bilevel": name == "notice_fax",
            "truth": _truth(base, "传真式 1 位黑白扫描。" if name == "notice_fax" else "灰度扫描，倾斜与噪点。")}


def svg_spec(name, rng):
    if name == "poster":
        base = CF.fam_notice(rng, 4)
        k = base["key_fields"]
        lines = [(base["title"], 40, "#ffffff"), (f"时间：{k['日期']} {k['开始时间']}", 28, "#ffe8a3"), (f"地点：{k['地点']}", 28, "#ffffff"),
                 (f"联系人：{k['联系人']} {k['电话']}", 24, "#dfe6f5")]
        return {"svg": {"lines": lines, "bg": "#8a2d3b"}, "title": base["title"], "lang": "zh",
                "truth": {"key_fields": k, "numbers": [], "qa": base["qa"]}}
    if name == "bar_chart":
        base = CF.fam_league(rng, 1)
        c = base["chart"]
        return {"svg": {"chart": {"title": c["title"], "labels": c["xlabels"], "values": c["series"]["积分"]}}, "title": c["title"], "lang": "zh",
                "truth": {"key_fields": {"第一名": c["xlabels"][0]}, "numbers": [{"value": v, "label": l} for l, v in zip(c["xlabels"], c["series"]["积分"])],
                          "qa": [q("积分最高的队？", c["xlabels"][0]), q(f"{c['xlabels'][1]}多少分？", c["series"]["积分"][1], "number")]}}
    if name == "org_chart":
        org = rng.choice(ORGS)
        ceo, a, b, c = people(rng, 4)
        boxes = [("总经理", ceo, 0), ("研发部经理", a, 1), ("市场部经理", b, 1), ("财务主管", c, 1)]
        return {"svg": {"org": {"title": f"{org} 组织架构", "boxes": boxes}}, "title": f"{org} 组织架构", "lang": "zh",
                "truth": {"key_fields": {"总经理": ceo, "研发部经理": a, "市场部经理": b, "财务主管": c}, "numbers": [],
                          "qa": [q("总经理是谁？", ceo), q("市场部经理是谁？", b), q("图里有几个岗位？", 4, "number", derived=True)]}}
    # seat_map
    names = people(rng, 6)
    room = rng.choice(["302 会议室", "考场 B-105", "创新工坊"])
    return {"svg": {"seats": {"title": f"{room} 座位表", "names": names, "cols": 3}}, "title": f"{room} 座位表", "lang": "zh",
            "truth": {"key_fields": {"房间": room, "A1": names[0], "B3": names[5]}, "numbers": [],
                      "qa": [q("A1 座是谁？", names[0]), q("B3 座是谁？", names[5]), q("一共几个座位？", 6, "number", derived=True)]}}


# ============================================================================== slides / gif / video

def slides_spec(ftype, name, rng, i):
    if name == "training":
        topics = ["实验室安全培训", "新员工 IT 入门", "数据备份规范"]
        t = topics[i % 3]
        n = rng.randint(3, 5)
        pw = rng.choice([10, 12, 14])
        base = {"title": t, "lang": "zh",
                "blocks": [("h", "为什么重要"), ("ul", [f"去年共发生 {n} 起可避免的事故", "大部分源于流程不清"]),
                           ("h", "三条规则"), ("ul", ["离开工位锁屏", f"密码至少 {pw} 位", "每周五 17:00 前完成备份"]),
                           ("h", "考核"), ("ul", ["培训后在线测验，80 分及格", "不及格者一周内补考"])],
                "key_fields": {"事故数": n, "密码位数": pw, "及格线": 80, "备份时间": "每周五17:00前"},
                "numbers": [{"value": n, "label": "事故"}, {"value": pw, "label": "密码位数"}, {"value": 80, "label": "及格线"}],
                "qa": [q("密码至少几位？", pw, "number"), q("测验多少分及格？", 80, "number"), q("每周什么时候前完成备份？", "每周五 17:00", accept=["周五17:00", "17:00"])]}
    else:
        base = CF.PROSE_FAMILIES[name](rng, i)
    img = (2,) if ftype in ("pptx", "odp") and i % 2 == 0 else ((2, 3) if ftype in ("pptx", "odp") else ())
    slides = _slides_from(base, image_slides=img)
    if ftype == "pptx" and name == "budget":
        c = base["chart"]
        slides.append({"title": c["title"], "image": True, "chart": c})
    return {"slides": slides, "title": base["title"], "lang": base["lang"], "truth": _truth(base)}


def gif_spec(name, rng, i):
    if name == "notice":
        base = CF.fam_notice(rng, i)
        k = base["key_fields"]
        frames = [{"title": base["title"], "bullets": [k["地点"]]}, {"title": k["日期"], "bullets": [f"{k['开始时间']} 开始"]},
                  {"title": f"联系人：{k['联系人']}", "bullets": [k["电话"]]}]
        return {"frames": frames, "title": base["title"], "lang": "zh", "truth": _truth(base, "3 帧动图，每帧信息不同。")}
    if name == "progress":
        proj = rng.choice(["新馆装修", "系统迁移", "年度盘点"])
        steps = [rng.randint(10, 30), rng.randint(40, 65), rng.randint(70, 95)]
        frames = [{"title": f"{proj}进度", "big": f"{p}%", "bullets": [f"第{j + 1}周"]} for j, p in enumerate(steps)]
        return {"frames": frames, "title": f"{proj}进度", "lang": "zh", "truth": {
            "key_fields": {"第1周": f"{steps[0]}%", "第3周": f"{steps[2]}%"}, "numbers": [{"value": p, "label": f"第{j + 1}周"} for j, p in enumerate(steps)],
            "qa": [q("第3周进度是多少？", steps[2], "number"), q("第1周进度是多少？", steps[0], "number"), q("这是什么项目？", proj)],
            "notes": "3 帧进度动图；只看首帧会答错第 3 周。"}}
    if name == "recipe":
        base = CF.fam_recipe(rng, i)
        k = base["key_fields"]
        frames = [{"title": base["title"], "bullets": [f"砂糖 {k['砂糖']} 克"]}, {"title": "预热", "bullets": [f"烤箱 {k['温度']}"]},
                  {"title": "烘烤", "bullets": [k["时长"]]}]
        return {"frames": frames, "title": base["title"], "lang": "zh", "truth": _truth(base, "3 帧步骤动图。")}
    base = CF.fam_agenda_en(rng, i)
    k = base["key_fields"]
    rows = [b[1] for b in base["blocks"] if b[0] == "table"][0]["rows"]
    frames = [{"title": base["title"], "bullets": [k["venue"], f"Capacity: {k['capacity']} participants"]},
              {"title": "Morning", "bullets": [f"{r[0]} {r[1]} ({r[2]})" for r in rows[:3]]},
              {"title": "Afternoon", "bullets": [f"{r[0]} {r[1]} ({r[2]})" for r in rows[3:]]}]
    return {"frames": frames, "title": base["title"], "lang": "en", "truth": _truth(base, "3-frame animated agenda.")}


# ============================================================================== ics / vcf

def ics_spec(name, rng):
    if name == "weekly_meeting":
        who = people(rng, 3)
        room = rng.choice(["会议室 A", "301", "线上会议室"])
        cal = {"name": "团队日历", "events": [
            {"uid": f"weekly-{rng.randint(1000, 9999)}@example.com", "summary": "周例会", "start": "20261019T100000", "end": "20261019T110000",
             "location": room, "rrule": "FREQ=WEEKLY;BYDAY=MO;COUNT=6", "organizer": (who[0], "host@example.com"),
             "description": f"每周一例会，共 6 次。主持：{who[0]}（合成数据）", "alarm": "-PT15M"},
            {"uid": f"review-{rng.randint(1000, 9999)}@example.com", "summary": "季度复盘", "start": "20261030T143000", "end": "20261030T170000",
             "location": room, "organizer": (who[1], "review@example.com"), "description": f"准备人：{who[2]}"}]}
        truth = {"key_fields": {"例会": "每周一 10:00-11:00 共6次", "复盘": "2026-10-30 14:30", "地点": room},
                 "numbers": [{"value": 6, "label": "次数"}],
                 "qa": [q("周例会一共几次？", 6, "number"), q("季度复盘几点开始？", "14:30"), q("例会在哪？", room),
                        q("周例会是每周几？", "周一", accept=["星期一", "MO", "Monday"])]}
        return {"calendar": cal, "title": "团队日历", "lang": "zh", "truth": truth}
    if name == "allday_conf":
        conf = rng.choice(["智慧农业大会", "城市设计论坛", "青年创业周"])
        city = rng.choice(CITIES)
        cal = {"name": "会议", "events": [
            {"uid": f"conf-{rng.randint(1000, 9999)}@example.com", "summary": f"{conf}（{city}）", "start_date": "20261105", "end_date": "20261107",
             "location": f"{city}国际会展中心 {rng.randint(1, 8)}号馆", "description": "两天全天会议，需提前线上签到。（合成数据）", "alarm": "-P1D"}]}
        loc = cal["events"][0]["location"]
        truth = {"key_fields": {"会议": conf, "日期": "2026-11-05至11-06", "地点": loc}, "numbers": [],
                 "qa": [q("会议在哪个城市？", city), q("会议哪天开始？", "11月5日", accept=["2026-11-05", "11/05", "20261105"]),
                        q("会议持续几天？", 2, "number", derived=True)]}
        return {"calendar": cal, "title": conf, "lang": "zh", "truth": truth}
    who = rng.choice(EN_NAMES)
    flight = f"{rng.choice(['QT', 'NV', 'LX'])} {rng.randint(100, 999)}"
    cal = {"name": "Trip", "events": [
        {"uid": f"trip1-{rng.randint(1000, 9999)}@example.com", "summary": f"Flight {flight} to Lisbon", "start": "20261112T071500",
         "end": "20261112T101000", "location": "Terminal 2, Gate B14", "description": f"Traveller: {who}. Seat 14C. Synthetic data."},
        {"uid": f"trip2-{rng.randint(1000, 9999)}@example.com", "summary": "Client workshop", "start": "20261112T140000", "end": "20261112T170000",
         "location": "Rua das Flores 12, Lisbon", "description": "Bring the prototype."}]}
    truth = {"key_fields": {"flight": flight, "gate": "B14", "seat": "14C", "workshop": "14:00"}, "numbers": [],
             "qa": [q("What is the flight number?", flight, "exact", accept=[flight.replace(" ", "")]), q("Which gate?", "B14"),
                    q("What time does the client workshop start?", "14:00"), q("What is the seat?", "14C")]}
    return {"calendar": cal, "title": "Trip calendar", "lang": "en", "truth": truth}


def vcf_spec(name, rng):
    if name == "contacts_zh":
        names = people(rng, 3)
        cs = [{"fn": n, "family": n[0], "given": n[1:], "org": rng.choice(ORGS), "title": rng.choice(["采购经理", "销售代表", "行政主管"]),
               "tel": f"+86-10-5550-{rng.randint(100, 199):04d}", "email": f"{['qinghe', 'yuanfan', 'xingqiao'][j]}.user{j}@example.com"}
              for j, n in enumerate(names)]
        truth = {"key_fields": {c["fn"]: c["tel"] for c in cs}, "numbers": [],
                 "qa": [q(f"{cs[0]['fn']}的电话？", cs[0]["tel"][-9:], accept=[cs[0]["tel"]]), q(f"{cs[1]['fn']}在哪家公司？", cs[1]["org"]),
                        q("一共几个联系人？", 3, "number", derived=True)]}
        return {"contacts": cs, "title": "联系人", "lang": "zh", "truth": truth}
    if name == "contacts_en":
        names = rng.sample(EN_NAMES, 3)
        cs = [{"fn": n, "family": n.split()[-1], "given": n.split()[0], "org": rng.choice(EN_ORGS),
               "title": rng.choice(["Lab Manager", "Account Executive", "Research Engineer"]), "tel": f"+1-202-555-01{rng.randint(10, 99)}",
               "email": f"{n.split()[0].lower()}.{rng.choice(['brightline', 'tidewater', 'bluestem'])}@example.com"} for n in names]
        truth = {"key_fields": {c["fn"]: c["email"] for c in cs}, "numbers": [],
                 "qa": [q(f"What is {cs[0]['fn']}'s email?", cs[0]["email"], "exact"), q(f"What is {cs[2]['fn']}'s job title?", cs[2]["title"]),
                        q(f"Which organisation does {cs[1]['fn']} work for?", cs[1]["org"])]}
        return {"contacts": cs, "title": "Contacts", "lang": "en", "vcf_version": "4.0", "truth": truth}
    if name == "contacts_qp":
        names = people(rng, 2)
        cs = [{"fn": n, "family": n[0], "given": n[1:], "org": rng.choice(ORGS), "tel": f"+86-10-5550-{rng.randint(100, 199):04d}",
               "note": rng.choice(["周末勿扰", "只接受邮件报价", "负责华东区"])} for n in names]
        truth = {"key_fields": {c["fn"]: c["tel"] for c in cs}, "numbers": [],
                 "qa": [q(f"{cs[0]['fn']}的备注是什么？", cs[0]["note"]), q(f"{cs[1]['fn']}的电话？", cs[1]["tel"][-9:], accept=[cs[1]["tel"]])],
                 "notes": "旧安卓导出格式：vCard 2.1，CHARSET=UTF-8;ENCODING=QUOTED-PRINTABLE。"}
        return {"contacts": cs, "title": "联系人（旧手机导出）", "lang": "zh", "vcf_version": "2.1", "truth": truth}
    n = person(rng)
    city = rng.choice(CITIES)
    c = {"fn": n, "family": n[0], "given": n[1:], "org": rng.choice(ORGS), "title": "项目总监", "tel": f"+86-10-5550-{rng.randint(100, 199):04d}",
         "tel2": f"+86-10-5550-{rng.randint(200, 299):04d}", "email": "director@example.com",
         "adr": ("", "", f"{rng.choice(['云栖', '临湖', '青石'])}路{rng.randint(1, 99)}号", city, "", f"{rng.randint(100000, 899999)}", "中国"),
         "url": "https://www.example.com/team", "note": "合成数据"}
    truth = {"key_fields": {"姓名": n, "城市": city, "邮编": c["adr"][5], "职位": "项目总监"}, "numbers": [],
             "qa": [q(f"{n}在哪个城市？", city), q("邮编是多少？", c["adr"][5], "exact"), q("职位是什么？", "项目总监"),
                    q("办公电话之外的第二个号码？", c["tel2"][-9:], accept=[c["tel2"]])]}
    return {"contacts": [c], "title": n, "lang": "zh", "truth": truth}


# ============================================================================== eml / mbox / zip

def eml_spec(name, rng):
    if name == "notice_xlsx":
        base = CF.fam_budget(rng, rng.randint(0, 4))
        sender = person(rng)
        em = {"from": (sender, "admin@example.com"), "to": [(person(rng), "team@example.com")],
              "date": "2026-10-09T10:20:00+08:00", "subject": f"【请查收】{base['title']}", "message_id": f"<bud-{rng.randint(1000, 9999)}@example.com>",
              "cte": "base64",
              "body": f"各位好：\n\n附件是{base['title']}，总预算 {base['key_fields']['总预算']:,} 元，请在周五前核对各自负责的类别。\n\n{sender}\n（合成数据）",
              "attachments": [{"filename": f"{base['title']}.xlsx", "kind": "xlsx", "sheets": base["sheets"]}]}
        return {"email": em, "title": em["subject"], "lang": "zh", "truth": _truth(base, "正文 base64；明细在 xlsx 附件里。")}
    if name == "po_pdf_en":
        base = CF.fam_po_en(rng, 0)
        k = base["key_fields"]
        em = {"from": (rng.choice(EN_NAMES), "purchasing@example.com"), "to": [("Orders", "orders@example.com")],
              "date": "2026-10-08T15:05:00+08:00", "subject": f"{k['po_number']} — please confirm", "message_id": f"<po-{rng.randint(1000, 9999)}@example.com>",
              "cte": "quoted-printable",
              "body": f"Hello,\n\nPlease find attached purchase order {k['po_number']}. Kindly confirm the delivery date by reply.\n\nThanks,\nPurchasing\n(synthetic data)",
              "attachments": [{"filename": f"{k['po_number']}.pdf", "kind": "pdf", "doc": base}]}
        return {"email": em, "title": em["subject"], "lang": "en", "truth": _truth(base, "Order details only in the PDF attachment.")}
    base = CF.fam_travel(rng, rng.randint(0, 11))
    em = {"from": ("城市生活周刊", "news@example.com"), "to": [("订阅用户", "reader@example.com")],
          "date": "2026-10-10T07:30:00+08:00", "subject": f"本周推荐：{base['title']}", "message_id": f"<nl-{rng.randint(1000, 9999)}@example.com>",
          "html_only": True, "html_doc": base, "inline_image": True,
          "attachments": [{"filename": "路线.csv", "kind": "csv", "columns": ["时间", "地点", "门票（元）"],
                           "rows": [b for b in base["blocks"] if b[0] == "table"][0][1]["rows"]}]}
    return {"email": em, "title": em["subject"], "lang": "zh", "truth": _truth(base, "只有 HTML 正文（无纯文本），内嵌图片，另附 CSV。")}


def mbox_spec(name, rng):
    if name == "venue_thread":
        a, b = people(rng, 2)
        room = rng.choice(["多功能厅", "一楼报告厅", "露台花园"])
        price = rng.choice([1800, 2400, 3200])
        msgs = [{"from": (a, "event@example.com"), "to": [(b, "venue@example.com")], "date": "2026-10-05T09:00:00+08:00",
                 "subject": "场地预订咨询", "body": f"您好，想预订{room}，11月8日下午，约60人，请问价格？\n{a}"},
                {"from": (b, "venue@example.com"), "to": [(a, "event@example.com")], "date": "2026-10-05T14:10:00+08:00",
                 "subject": "Re: 场地预订咨询", "body": f"{a}您好，{room}半天 {price} 元，含投影和音响，需付 30% 定金。\n{b}"},
                {"from": (a, "event@example.com"), "to": [(b, "venue@example.com")], "date": "2026-10-06T10:00:00+08:00",
                 "subject": "Re: Re: 场地预订咨询", "body": f"好的，确认预订，定金 {int(price * 0.3)} 元今天转账。\n{a}\n（合成数据）"}]
        truth = {"key_fields": {"场地": room, "价格": price, "定金": int(price * 0.3), "日期": "11月8日下午"},
                 "numbers": [{"value": price, "label": "价格"}, {"value": int(price * 0.3), "label": "定金"}],
                 "qa": [q("场地半天多少钱？", price, "number"), q("定金多少元？", int(price * 0.3), "number"), q("预订的是哪个场地？", room)]}
        return {"messages": msgs, "title": "场地预订往来", "lang": "zh", "truth": truth}
    if name == "hiring_en":
        cand, rec, mgr = rng.sample(EN_NAMES, 3)
        role = rng.choice(["Data Analyst", "Lab Technician", "Frontend Engineer"])
        day = rng.choice(["Tuesday, November 3", "Wednesday, November 4", "Thursday, November 5"])
        msgs = [{"from": (rec, "recruit@example.org"), "to": [(cand, "cand@example.net")], "date": "2026-10-20T09:00:00+08:00",
                 "subject": f"Interview for {role}", "body": f"Hi {cand.split()[0]},\n\nWe'd like to invite you to interview for the {role} role. Are you free on {day}?\n\n{rec}"},
                {"from": (cand, "cand@example.net"), "to": [(rec, "recruit@example.org")], "date": "2026-10-20T12:30:00+08:00",
                 "subject": f"Re: Interview for {role}", "body": f"Hi {rec.split()[0]},\n\n{day} works. Morning would be best.\n\n{cand}"},
                {"from": (rec, "recruit@example.org"), "to": [(cand, "cand@example.net")], "cc": [(mgr, "mgr@example.org")],
                 "date": "2026-10-20T16:45:00+08:00", "subject": f"Re: Interview for {role}",
                 "body": f"Great, confirmed for {day} at 10:30, room 4B. You'll meet {mgr}. The interview lasts 45 minutes."},
                {"from": (cand, "cand@example.net"), "to": [(rec, "recruit@example.org")], "date": "2026-10-21T08:10:00+08:00",
                 "subject": f"Re: Interview for {role}", "body": "Thank you, see you then. (synthetic data)"}]
        truth = {"key_fields": {"role": role, "day": day, "time": "10:30", "room": "4B", "interviewer": mgr, "minutes": 45},
                 "numbers": [{"value": 45, "label": "minutes"}],
                 "qa": [q("What time is the interview?", "10:30"), q("Which room?", "4B"), q("Who will the candidate meet?", mgr),
                        q("How long is the interview (minutes)?", 45, "number")]}
        return {"messages": msgs, "title": f"Interview for {role}", "lang": "en", "truth": truth}
    if name == "gbk_thread":
        a, b = people(rng, 2)
        amt = rng.choice([860, 1240, 2380])
        msgs = [{"from": (a, "fin@example.com"), "to": [(b, "b@example.com")], "date": "2026-09-28T11:00:00+08:00",
                 "subject": "报销单退回", "charset": "gbk",
                 "body": f"{b}，你的报销单（{amt} 元）缺少发票原件，已退回，请补齐后重新提交。\n{a}"},
                {"from": (b, "b@example.com"), "to": [(a, "fin@example.com")], "date": "2026-09-28T15:20:00+08:00",
                 "subject": "Re: 报销单退回", "charset": "gbk", "body": f"收到，发票原件明天上午交到财务室 204。\n{b}\n（合成数据）"}]
        truth = {"key_fields": {"金额": amt, "原因": "缺少发票原件", "房间": "204"}, "numbers": [{"value": amt, "label": "报销金额"}],
                 "qa": [q("报销单金额多少元？", amt, "number"), q("为什么被退回？", "缺少发票原件"), q("原件交到哪个房间？", "204")],
                 "notes": "GBK 字符集的邮件。"}
        return {"messages": msgs, "title": "报销单退回", "lang": "zh", "truth": truth}
    tid = f"WX{rng.randint(10000, 99999)}"
    room = f"{rng.randint(2, 9)}0{rng.randint(1, 9)}"
    tech = person(rng)
    msgs = [{"from": ("报修系统", "noreply@example.com"), "to": [("用户", "user@example.com")], "date": f"2026-10-1{j}T{8 + j:02d}:00:00+08:00",
             "subject": f"[{tid}] {s}", "body": body} for j, (s, body) in enumerate([
        ("工单已创建", f"工单 {tid}：{room} 房间空调不制冷，已登记。"),
        ("已派单", f"工单 {tid} 已派给维修员 {tech}，预计今天 16:00 前上门。"),
        ("处理中", f"{tech} 已到场，需更换电容，等待配件。"),
        ("已完成", f"工单 {tid} 已完成：更换电容 1 个，费用 0 元（保修期内）。"),
        ("请评价", "请为本次服务打分（1–5 分）。（合成数据）")])]
    truth = {"key_fields": {"工单号": tid, "房间": room, "维修员": tech, "更换": "电容 1 个"}, "numbers": [],
             "qa": [q("工单号是多少？", tid, "exact"), q("维修员是谁？", tech), q("换了什么配件？", "电容"), q("一共几封通知邮件？", 5, "number", derived=True)]}
    return {"messages": msgs, "title": f"报修工单 {tid}", "lang": "zh", "truth": truth}


def zip_spec(name, rng):
    if name == "reimburse":
        inv = CF.fam_invoice(rng, 2)
        it = CF.fam_itinerary(rng, 0)
        members = [{"name": "报销说明.txt", "kind": "text", "text": f"报销材料清单\n1. 收据（{inv['key_fields']['单据编号']}）\n2. 行程单\n合计报销：{inv['key_fields']['合计']} 元 + 住宿 {it['key_fields']['住宿合计']} 元\n合成数据\n"},
                   {"name": "收据.jpg", "kind": "image", "visual": _visual_from(inv, "card", photo=True, w=760, line_size=24)},
                   {"name": "行程单.pdf", "kind": "pdf", "doc": it}]
        truth = {"key_fields": {"文件数": 3, "收据合计": inv["key_fields"]["合计"], "去程": it["key_fields"]["去程"]},
                 "numbers": [{"value": inv["key_fields"]["合计"], "label": "收据合计"}, {"value": it["key_fields"]["住宿合计"], "label": "住宿"}],
                 "qa": [q("压缩包里有几个文件？", 3, "number", derived=True), q("收据合计多少元？", inv["key_fields"]["合计"], "number", tol=0.01),
                        q("行程单里的去程车次/航班？", it["key_fields"]["去程"], "exact")]}
        return {"members": members, "title": "报销材料", "lang": "zh", "truth": truth}
    if name == "project_docs":
        mins = CF.fam_minutes(rng, rng.randint(0, 5))
        bud = CF.fam_budget(rng, rng.randint(0, 4))
        members = [{"name": "docs/会议纪要.docx", "kind": "docx", "doc": mins}, {"name": "data/预算.xlsx", "kind": "xlsx", "sheets": bud["sheets"]},
                   {"name": "README.md", "kind": "text", "text": "# 项目资料\n\n- docs/ 会议纪要\n- data/ 预算表\n\n> 合成数据\n"}]
        truth = {"key_fields": {"文件数": 3, "会议地点": mins["key_fields"]["地点"], "总预算": bud["key_fields"]["总预算"]},
                 "numbers": [{"value": bud["key_fields"]["总预算"], "label": "总预算"}],
                 "qa": [q("会议纪要里的会议地点？", mins["key_fields"]["地点"]), q("预算表的总预算多少元？", bud["key_fields"]["总预算"], "number"),
                        q("压缩包里有几个文件？", 3, "number", derived=True)]}
        return {"members": members, "title": "项目资料", "lang": "zh", "truth": truth}
    if name == "photos":
        a = visual_spec("label_photo", rng)
        b = visual_spec("notice_photo", rng)
        c = visual_spec("order_window", rng)
        members = [{"name": "IMG_2031.jpg", "kind": "image", "visual": a["visual"]}, {"name": "IMG_2032.jpg", "kind": "image", "visual": b["visual"]},
                   {"name": "Screenshot_订单.png", "kind": "image", "fmt": "png", "visual": c["visual"]}]
        qa = [a["truth"]["qa"][0], b["truth"]["qa"][0], c["truth"]["qa"][1], q("压缩包里有几张图片？", 3, "number", derived=True)]
        truth = {"key_fields": {"图片数": 3, **{f"IMG_2031.{k}": v for k, v in a["truth"]["key_fields"].items()}},
                 "numbers": a["truth"]["numbers"] + c["truth"]["numbers"], "qa": qa}
        return {"members": members, "title": "照片", "lang": "zh", "truth": truth}
    po = CF.fam_po_en(rng, 1)
    st = CF.fam_status_en(rng, 2)
    sv = json_spec("survey_en", rng)
    members = [{"name": "status.md", "kind": "md", "doc": st}, {"name": "po.csv", "kind": "csv", "columns": [b for b in po["blocks"] if b[0] == "table"][0][1]["columns"],
                                                                "rows": [b for b in po["blocks"] if b[0] == "table"][0][1]["rows"]},
               {"name": "survey.json", "kind": "json", "record": sv["record"]}]
    truth = {"key_fields": {"files": 3, "status": st["key_fields"]["status"], "responses": sv["record"]["responses"]},
             "numbers": [{"value": sv["record"]["responses"], "label": "responses"}],
             "qa": [q("What is the overall project status in status.md?", st["key_fields"]["status"]),
                    q("How many survey responses are there?", sv["record"]["responses"], "number"),
                    q(f"How many units of '{[b for b in po['blocks'] if b[0] == 'table'][0][1]['rows'][0][0]}' are in po.csv?",
                      [b for b in po["blocks"] if b[0] == "table"][0][1]["rows"][0][1], "number")]}
    return {"members": members, "title": "English pack", "lang": "en", "truth": truth}


# ============================================================================== webarchive / epub dispatch

def webarchive_spec(name, rng, i):
    if name == "product":
        price = rng.choice([1299, 1899, 2499])
        model = f"{rng.choice(['AirLite', 'Nimbus', 'Orbit'])}-{rng.randint(10, 99)}"
        base = {"title": f"{model} 空气净化器 · 产品详情", "lang": "zh", "site": "禾木家居商城",
                "blocks": [("kv", [("型号", model), ("价格", f"¥{price:,}"), ("适用面积", f"{rng.randint(30, 80)}㎡"), ("噪音", f"{rng.randint(22, 35)}dB")]),
                           ("p", "包邮，30 天无理由退换。"), ("p", "（合成数据页面）")],
                "key_fields": {"型号": model, "价格": price}, "numbers": [{"value": price, "label": "价格"}],
                "qa": [q("这款净化器多少钱？", price, "number"), q("型号是什么？", model, "exact"), q("几天无理由退换？", 30, "number")]}
    else:
        base = CF.PROSE_FAMILIES[name](rng, i)
        base.setdefault("site", rng.choice(["社区服务平台", "城市生活网", "美食记"]))
    url = f"https://www.{['news', 'city', 'shop', 'food'][i % 4]}.example.com/page/{rng.randint(1000, 9999)}"
    return {"doc": base, "url": url, "title": base["title"], "lang": base["lang"], "truth": _truth(base, "Safari 网页归档，含一个 PNG 子资源。")}


def make_standalone(ftype, name, rng, i):
    """Return a spec (content + truth) for one standalone file."""
    prose_types = {"txt", "md", "rtf", "html", "docx", "doc", "odt", "pdf", "pdf_scanned"}
    if ftype in prose_types:
        base = CF.PROSE_FAMILIES[name](rng, i)
        spec = {"doc": base, "title": base["title"], "lang": base["lang"], "truth": _truth(base)}
        if ftype == "txt":
            spec["encoding"] = ["utf-8", "utf-8", "utf-8-sig", "utf-8"][i % 4]
            spec["newline"] = "\r\n" if i == 1 else "\n"
            if i == 1:
                spec["truth"]["notes"] = "CRLF 换行。"
            if i == 2:
                spec["truth"]["notes"] = "UTF-8 带 BOM。"
        return spec
    if ftype == "epub":
        return epub_book(name, rng)
    if ftype == "webarchive":
        return webarchive_spec(name, rng, i)
    if ftype in ("csv", "xlsx", "ods"):
        base = CF.PROSE_FAMILIES[name](rng, i)
        spec = {"title": base["title"], "lang": base["lang"], "truth": _truth(base)}
        if ftype == "csv":
            t = base["table"]
            enc, delim = [("utf-8", ","), ("utf-8", ";"), ("utf-8", "\t")][i % 3]
            spec["csv"] = {"columns": t["columns"], "rows": [[str(c) for c in r] for r in t["rows"]], "encoding": enc, "delimiter": delim}
            spec["truth"]["notes"] = {",": "逗号分隔", ";": "分号分隔", "\t": "制表符分隔"}[delim]
        else:
            spec["sheets"] = base["sheets"]
            spec["truth"]["notes"] = "多工作表；合并单元格；公式带缓存值。"
        return spec
    if ftype == "json":
        return json_spec(name, rng)
    if ftype == "xml":
        return xml_spec(name, rng)
    if ftype in ("pptx", "odp", "mp4", "mov"):
        s = slides_spec(ftype, name, rng, i)
        if ftype in ("mp4", "mov"):
            s["slides"] = [dict(x, image=False) for x in s["slides"]]
            s["seconds"] = [2.5] * len(s["slides"])
            s["silent_audio"] = ftype == "mov" and i % 2 == 0
        return s
    if ftype == "gif":
        return gif_spec(name, rng, i)
    if ftype in ("png", "jpg", "heic", "webp", "bmp"):
        return visual_spec(name, rng)
    if ftype == "tiff":
        return tiff_spec(name, rng)
    if ftype == "svg":
        return svg_spec(name, rng)
    if ftype == "ics":
        return ics_spec(name, rng)
    if ftype == "vcf":
        return vcf_spec(name, rng)
    if ftype == "eml":
        return eml_spec(name, rng)
    if ftype == "mbox":
        return mbox_spec(name, rng)
    if ftype == "zip":
        return zip_spec(name, rng)
    raise KeyError(ftype)
