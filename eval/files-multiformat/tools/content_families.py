"""Seeded generators for the standalone (non-scenario) files: invented documents of common everyday kinds.

Each family returns a "base": title, lang, blocks (for prose renderers), plus table/sheets/slides/record hints,
and the truth (key_fields, numbers, qa). Every renderer shows all of a base's content, so each question stays
answerable in every format. All organisations, people, codes, e-mail domains (example.*) and phone numbers
(555 exchange) are invented.
"""

from __future__ import annotations

import random

from content_matters import q

SURNAMES = list("王李张刘陈杨黄赵吴周徐孙朱胡郭何罗高梁宋郑谢韩唐冯于董萧程曹袁邓许傅沈曾彭吕苏卢蒋蔡贾丁魏薛叶阎余潘杜戴夏钟汪田任姜范方石姚谭廖邹熊金陆郝孔白崔康毛邱秦江史顾侯邵孟龙万段雷钱汤尹黎易常武乔贺赖龚文")
GIVEN = ["子涵", "浩然", "雨萱", "思远", "一诺", "梓轩", "若曦", "宇航", "欣怡", "俊杰", "嘉怡", "明哲", "佳宁", "晨阳", "诗琪",
         "文博", "语桐", "天佑", "可馨", "志远", "婉清", "睿", "楠", "昊天", "书瑶", "泽宇", "静怡", "博文", "心怡", "立新"]
ORGS = ["青禾生物科技有限公司", "远帆物流有限公司", "星桥教育咨询有限公司", "北岸食品有限公司", "云杉建筑设计事务所", "蓝湾文化传媒有限公司",
        "启明仪器有限公司", "山海户外用品有限公司", "松间咖啡", "白鹭环保科技有限公司", "知行图书有限公司", "禾木家居有限公司"]
CITIES = ["杭州", "苏州", "成都", "西安", "厦门", "青岛", "武汉", "长沙", "昆明", "大连", "南京", "合肥"]
EN_NAMES = ["Maya Chen", "Daniel Okafor", "Priya Raman", "Lucas Meyer", "Sofia Alvarez", "Tom Becker", "Hana Sato", "Omar Haddad",
            "Grace Liu", "Ethan Novak", "Nora Lindqvist", "Arjun Mehta"]
EN_ORGS = ["Brightline Labs", "Harbor & Pine Consulting", "Cedar Grove School", "Aurora Field Instruments", "Tidewater Analytics",
           "Bluestem Robotics", "Juniper Health Supplies", "Quarry Street Studio"]


def person(rng):
    return rng.choice(SURNAMES) + rng.choice(GIVEN)


def people(rng, n):
    out = []
    while len(out) < n:
        p = person(rng)
        if p not in out:
            out.append(p)
    return out


def ymd(m, d, y=2026):
    return f"{y}年{m}月{d}日"


def money(v):
    return f"{v:,.2f}" if isinstance(v, float) and v != int(v) else f"{int(v):,}"


# ============================================================================== prose families (zh)

def fam_invoice(rng, variant=0):
    vendor = rng.choice(ORGS)
    buyer = rng.choice([o for o in ORGS if o != vendor])
    catalog = [("A4 复印纸（箱）", 128), ("激光打印机硒鼓", 460), ("会议桌（1.8米）", 1350), ("人体工学椅", 890), ("投影仪", 3280),
               ("白板（120×90）", 240), ("移动硬盘 2TB", 520), ("无线键鼠套装", 159), ("文件柜（四门）", 760), ("台灯", 118)]
    items = rng.sample(catalog, rng.randint(2, 4))
    rows, sub = [], 0
    for i, (name, price) in enumerate(items, 1):
        qty = rng.randint(1, 12)
        amt = qty * price
        sub += amt
        rows.append([i, name, qty, price, amt])
    rate = rng.choice([6, 13])
    tax = round(sub * rate / 100, 2)
    total = round(sub + tax, 2)
    no = f"No.{rng.randint(10000000, 99999999)}"
    m, d = rng.randint(3, 11), rng.randint(1, 28)
    kind = ["报价单", "销售单", "收据"][variant % 3]
    pick = rng.choice(rows)
    base = {"title": f"{vendor} {kind}", "lang": "zh", "letterhead": f"{vendor} · {no}",
            "blocks": [("kv", [("单据编号", no), ("客户", buyer), ("日期", ymd(m, d)), ("经办人", person(rng))]),
                       ("table", {"columns": ["序号", "品名", "数量", "单价（元）", "金额（元）"], "rows": rows}),
                       ("kv", [("小计", f"{money(sub)}元"), (f"税额（{rate}%）", f"{money(tax)}元"), ("合计", f"{money(total)}元")]),
                       ("p", "付款方式：银行转账，开票后30日内付清。本单据为合成数据，仅供评测使用。")],
            "table": {"columns": ["序号", "品名", "数量", "单价（元）", "金额（元）"], "rows": rows},
            "chart": {"title": f"{kind}金额构成（元）", "series": {"金额": [r[4] for r in rows]}, "xlabels": [r[1][:6] for r in rows]},
            "key_fields": {"单据编号": no, "客户": buyer, "小计": sub, "税率": f"{rate}%", "合计": total},
            "numbers": [{"value": sub, "label": "小计"}, {"value": tax, "label": "税额"}, {"value": total, "label": "合计"}],
            "qa": [q("合计金额是多少元？", total, "number", tol=0.01), q("单据编号是多少？", no, "exact", accept=[no.replace("No.", "")]),
                   q(f"{pick[1]}买了多少？", pick[2], "number"), q("开给哪个客户？", buyer)]}
    sheets = [{"name": "明细", "title": base["title"], "group_header": [(2, 4, "计价")],
               "columns": ["序号", "品名", "数量", "单价（元）", "金额（元）"],
               "rows": [[r[0], r[1], r[2], r[3], {"f": f"=C{4 + i}*D{4 + i}", "v": r[4]}] for i, r in enumerate(rows)]
               + [["", "小计", None, None, {"f": f"=SUM(E4:E{3 + len(rows)})", "v": sub}],
                  ["", f"税额 {rate}%", None, None, {"f": f"=ROUND(E{4 + len(rows)}*{rate}/100,2)", "v": tax}],
                  ["", "合计", None, None, {"f": f"=E{4 + len(rows)}+E{5 + len(rows)}", "v": total}]],
               "formats": {3: "num", 4: "dec"}, "col_widths": [6, 22, 8, 12, 14]},
              {"name": "单据信息", "columns": ["项目", "内容"],
               "rows": [["单据编号", no], ["客户", buyer], ["日期", ymd(m, d)], ["合计（元）", {"f": f"='明细'!E{6 + len(rows)}", "v": total}]]}]
    base["sheets"] = sheets
    base["record"] = {"doc_type": kind, "number": no, "vendor": vendor, "customer": buyer, "date": f"2026-{m:02d}-{d:02d}",
                      "items": [{"name": r[1], "qty": r[2], "unit_price": r[3], "amount": r[4]} for r in rows],
                      "subtotal": sub, "tax_rate": rate / 100, "tax": tax, "total": total, "currency": "CNY", "note": "合成数据"}
    return base


def fam_minutes(rng, variant=0):
    topic = ["社区读书会筹备会", "新品发布筹备会", "年度团建策划会", "开放日活动协调会", "仓库搬迁协调会", "校友返校日筹备会"][variant % 6]
    host, *att = people(rng, rng.randint(5, 7))
    m, d = rng.randint(3, 11), rng.randint(1, 18)
    place = rng.choice(["三楼会议室", "一号会议室", "多功能厅", "线上（视频会议）", "B座 502"])
    hh = rng.choice(["09:30", "10:00", "14:00", "15:30"])
    budget = rng.randint(8, 60) * 500
    evd = d + rng.randint(3, 9)
    owners = rng.sample(att, 3)
    actions = [(owners[0], "确定场地并签订协议", ymd(m, d + 2)), (owners[1], f"制作宣传物料（预算 {budget:,} 元以内）", ymd(m, d + 3)),
               (owners[2], "汇总报名名单", ymd(m, d + 5))]
    base = {"title": f"{topic}会议纪要", "lang": "zh",
            "blocks": [("kv", [("时间", f"{ymd(m, d)} {hh}"), ("地点", place), ("主持人", host), ("参会人员", "、".join(att)),
                               ("记录人", att[-1])]),
                       ("h", "一、会议决定"),
                       ("ul", [f"活动定于{ymd(m, evd)}举行，预计参与人数 {rng.randint(4, 30) * 10} 人。", f"总预算不超过 {budget:,} 元。",
                               "对外宣传统一由主持人审核后发布。"]),
                       ("h", "二、分工与时限"),
                       ("table", {"columns": ["负责人", "事项", "完成时间"], "rows": [list(a) for a in actions]}),
                       ("p", "下次会议时间另行通知。（合成数据）")],
            "key_fields": {"时间": f"{ymd(m, d)} {hh}", "地点": place, "主持人": host, "参会人数": len(att) + 1, "预算": budget,
                           "活动日期": ymd(m, evd)},
            "numbers": [{"value": budget, "label": "预算"}],
            "qa": [q("会议在哪里开？", place), q(f"谁负责{actions[0][1][:4]}？", owners[0]), q("预算上限是多少元？", budget, "number"),
                   q("活动定在哪天？", ymd(m, evd), accept=[f"{m}月{evd}日", f"2026-{m:02d}-{evd:02d}"])]}
    return base


def fam_notice(rng, variant=0):
    kinds = [("计划停电通知", "因线路检修，{place}将于{date} {t1}至{t2}停电，请提前保存工作并关闭用电设备。"),
             ("消防演练通知", "{date} {t1}在{place}举行消防疏散演练，警铃响后请沿安全通道撤离至集合点，{t2}前结束。"),
             ("图书馆临时闭馆通知", "因设备更换，{place}于{date} {t1}至{t2}暂停开放，期间可使用线上借阅服务。"),
             ("停车场改造通知", "{place}将于{date} {t1}起封闭施工，预计{t2}恢复，请车辆改停东侧临时停车区。"),
             ("讲座报名通知", "{date} {t1}在{place}举办公益讲座，限额报名，{t2}截止报名。")]
    title, tpl = kinds[variant % len(kinds)]
    org = rng.choice(ORGS)
    place = rng.choice(["A座1–5层", "科技园3号楼", "中心图书馆", "北区地下停车场", "报告厅二楼", "学生活动中心"])
    m, d = rng.randint(3, 11), rng.randint(4, 19)
    t1 = rng.choice(["08:00", "09:00", "13:30", "14:00"])
    t2 = rng.choice(["12:00", "17:30", "18:00"]) if variant % 5 not in (3, 4) else ymd(m, d + rng.randint(2, 9))
    contact = person(rng)
    ext = f"+86-10-5550-{rng.randint(100, 199):04d}"
    body = tpl.format(place=place, date=ymd(m, d), t1=t1, t2=t2)
    base = {"title": title, "lang": "zh",
            "blocks": [("p", "各位同事："), ("p", body),
                       ("kv", [("联系人", contact), ("电话", ext), ("发布单位", f"{org} 行政部"), ("发布日期", ymd(m, max(1, d - 3)))]),
                       ("p", "特此通知。（合成数据）")],
            "key_fields": {"地点": place, "日期": ymd(m, d), "开始时间": t1, "联系人": contact, "电话": ext},
            "numbers": [],
            "qa": [q("涉及哪个地点？", place), q("哪天？", ymd(m, d), accept=[f"{m}月{d}日", f"2026-{m:02d}-{d:02d}"]),
                   q("几点开始？", t1), q("联系人是谁？", contact)]}
    return base


def fam_labrecord(rng, variant=0):
    exps = [("酶活性测定", "吸光度", "OD"), ("材料拉伸测试", "抗拉强度", "MPa"), ("土壤pH测定", "pH", ""), ("催化剂转化率筛选", "转化率", "%"),
            ("水样浊度检测", "浊度", "NTU")]
    name, metric, unit = exps[variant % len(exps)]
    op = person(rng)
    m, d = rng.randint(3, 11), rng.randint(1, 28)
    temp = rng.choice([22, 25, 30, 37])
    dur = rng.choice([15, 30, 45, 60])
    rows = []
    for i in range(rng.randint(4, 6)):
        v = round(rng.uniform(1, 9), 2) if unit in ("OD", "", "NTU") else round(rng.uniform(20, 95), 1)
        rows.append([f"S{i + 1:02d}", v])
    vals = [r[1] for r in rows]
    avg = round(sum(vals) / len(vals), 2)
    best = max(rows, key=lambda r: r[1])
    eid = f"EXP-{rng.randint(2026000, 2026999)}"
    base = {"title": f"实验记录：{name}", "lang": "zh",
            "blocks": [("kv", [("实验编号", eid), ("日期", ymd(m, d)), ("操作人", op), ("温度", f"{temp}℃"), ("反应/测试时间", f"{dur} 分钟")]),
                       ("table", {"columns": ["样品", f"{metric}{('（' + unit + '）') if unit else ''}"], "rows": rows}),
                       ("p", f"平均值 {avg}{unit}，最高为样品 {best[0]}（{best[1]}{unit}）。"),
                       ("p", "结论：数据重复性良好，下次增加对照组。本记录为合成数据。")],
            "table": {"columns": ["样品", f"{metric}{('（' + unit + '）') if unit else ''}"], "rows": rows},
            "chart": {"title": f"{name}：各样品{metric}", "series": {metric: vals}, "xlabels": [r[0] for r in rows]},
            "key_fields": {"实验编号": eid, "操作人": op, "温度": f"{temp}℃", "平均值": avg, "最高样品": best[0]},
            "numbers": [{"value": avg, "label": "平均值"}, {"value": temp, "label": "温度"}],
            "qa": [q("实验温度是多少摄氏度？", temp, "number"), q(f"样品 {rows[1][0]} 的{metric}是多少？", rows[1][1], "number"),
                   q("哪个样品最高？", best[0], "exact"), q("操作人是谁？", op)]}
    return base


def fam_itinerary(rng, variant=0):
    who = person(rng)
    a, b = rng.sample(CITIES, 2)
    m, d = rng.randint(3, 11), rng.randint(1, 24)
    train = variant % 2 == 0
    no1 = f"G{rng.randint(100, 1999)}" if train else f"MU{rng.randint(1000, 9999)}"
    no2 = f"G{rng.randint(100, 1999)}" if train else f"MU{rng.randint(1000, 9999)}"
    dep = rng.choice(["07:25", "08:40", "10:15", "13:05"])
    arr = rng.choice(["11:52", "12:30", "14:47", "16:20"])
    back_dep = rng.choice(["16:10", "17:45", "19:30"])
    nights = rng.randint(1, 3)
    hotel = f"{b}{rng.choice(['云栖', '湖畔', '栖霞', '望江'])}酒店"
    conf = f"{rng.choice(['HT', 'RZ', 'BK'])}{rng.randint(100000, 999999)}"
    price = rng.choice([380, 420, 468, 520])
    base = {"title": f"出差行程单（{who}）", "lang": "zh",
            "blocks": [("kv", [("出差人", who), ("事由", rng.choice(["客户拜访", "行业展会", "项目验收", "培训"])), ("目的地", b)]),
                       ("table", {"columns": ["日期", "车次/航班", "出发", "到达"],
                                  "rows": [[ymd(m, d), no1, f"{a} {dep}", f"{b} {arr}"], [ymd(m, d + nights), no2, f"{b} {back_dep}", a]]}),
                       ("kv", [("酒店", hotel), ("入住", f"{ymd(m, d)}，共 {nights} 晚"), ("确认号", conf), ("房价", f"{price}元/晚")]),
                       ("p", f"住宿合计 {price * nights} 元，按差旅标准报销。（合成数据）")],
            "key_fields": {"出差人": who, "去程": no1, "到达时间": arr, "酒店确认号": conf, "晚数": nights, "住宿合计": price * nights},
            "numbers": [{"value": price * nights, "label": "住宿合计"}],
            "qa": [q("去程车次/航班号是什么？", no1, "exact"), q("几点到达目的地？", arr), q("酒店确认号？", conf, "exact"),
                   q("住宿合计多少元？", price * nights, "number")]}
    base["record"] = {"traveler": who, "from": a, "to": b,
                      "segments": [{"no": no1, "date": f"2026-{m:02d}-{d:02d}", "dep": dep, "arr": arr},
                                   {"no": no2, "date": f"2026-{m:02d}-{d + nights:02d}", "dep": back_dep}],
                      "hotel": {"name": hotel, "nights": nights, "confirmation": conf, "rate_cny": price, "total_cny": price * nights},
                      "note": "合成数据"}
    return base


def fam_budget(rng, variant=0):
    proj = ["社区运动会", "年度客户答谢会", "夏令营", "新店开业", "图书节"][variant % 5]
    cats = rng.sample(["场地", "餐饮", "物料", "交通", "奖品", "宣传", "人员", "保险"], 5)
    plan = [rng.randint(4, 40) * 500 for _ in cats]
    actual = [p + rng.randint(-8, 8) * 100 for p in plan]
    tp, ta = sum(plan), sum(actual)
    mx = cats[plan.index(max(plan))]
    rows = [[c, p, a, a - p] for c, p, a in zip(cats, plan, actual)]
    base = {"title": f"{proj}预算与实际支出", "lang": "zh",
            "blocks": [("p", f"{proj}总预算 {tp:,} 元，实际支出 {ta:,} 元。"),
                       ("table", {"columns": ["类别", "预算（元）", "实际（元）", "差额（元）"], "rows": rows + [["合计", tp, ta, ta - tp]]}),
                       ("p", f"预算最大的类别是{mx}。（合成数据）")],
            "table": {"columns": ["类别", "预算（元）", "实际（元）", "差额（元）"], "rows": rows + [["合计", tp, ta, ta - tp]]},
            "chart": {"title": f"{proj}：预算 vs 实际（元）", "series": {"预算": plan, "实际": actual}, "xlabels": cats, "kind": "bar"},
            "key_fields": {"总预算": tp, "实际支出": ta, "最大类别": mx},
            "numbers": [{"value": tp, "label": "总预算"}, {"value": ta, "label": "实际"}],
            "qa": [q("总预算是多少元？", tp, "number"), q("实际支出多少元？", ta, "number"), q("预算最大的类别是什么？", mx),
                   q(f"{cats[1]}的预算是多少元？", plan[1], "number")]}
    n = len(rows)
    base["sheets"] = [{"name": "预算", "title": base["title"], "group_header": [(1, 2, "金额（元）")],
                       "columns": ["类别", "预算（元）", "实际（元）", "差额（元）"],
                       "rows": [[c, p, a, {"f": f"=C{4 + i}-B{4 + i}", "v": a - p}] for i, (c, p, a) in enumerate(zip(cats, plan, actual))]
                       + [["合计", {"f": f"=SUM(B4:B{3 + n})", "v": tp}, {"f": f"=SUM(C4:C{3 + n})", "v": ta},
                           {"f": f"=C{4 + n}-B{4 + n}", "v": ta - tp}]],
                       "formats": {1: "num", 2: "num", 3: "num"}, "col_widths": [10, 12, 12, 12]},
                      {"name": "说明", "columns": ["项目", "内容"],
                       "rows": [["活动", proj], ["最大类别", mx], ["执行率", {"f": f"=ROUND('预算'!C{4 + n}/'预算'!B{4 + n},4)", "v": round(ta / tp, 4)}]]}]
    return base


def fam_weekly(rng, variant=0):
    who = person(rng)
    team = rng.choice(["市场部", "产品组", "运营组", "研发二组", "客服中心"])
    m, d = rng.randint(3, 11), rng.randint(1, 22)
    prog = rng.randint(35, 95)
    risk = rng.choice(["供应商交期推迟一周", "测试环境不稳定", "两名同事休假，人手紧张", "预算审批未通过"])
    nxt = rng.choice(["完成用户访谈 8 场", "上线 2.3 版本", "提交季度汇报", "完成招标文件"])
    base = {"title": f"{team}周报（{m}月{d}日—{m}月{d + 4}日）", "lang": "zh",
            "blocks": [("kv", [("填写人", who), ("整体进度", f"{prog}%")]),
                       ("h", "本周完成"), ("ul", ["完成需求评审", f"处理工单 {rng.randint(20, 90)} 个", "更新项目排期"]),
                       ("h", "风险"), ("ul", [risk]),
                       ("h", "下周计划"), ("ul", [nxt, "周五前同步进度"]), ("p", "（合成数据）")],
            "key_fields": {"填写人": who, "进度": f"{prog}%", "风险": risk, "下周": nxt},
            "numbers": [{"value": prog, "label": "进度%"}],
            "qa": [q("整体进度是多少？", prog, "number"), q("本周最大的风险是什么？", risk), q("下周的主要计划是什么？", nxt),
                   q("周报是谁写的？", who)]}
    return base


def fam_schedule(rng, variant=0):
    what = ["值班表", "培训课程表", "场地使用安排", "志愿者排班表"][variant % 4]
    m, d = rng.randint(3, 11), rng.randint(1, 20)
    names = people(rng, 5)
    rooms = ["201", "305", "报告厅", "实训室", "会议室A"]
    rows = []
    for i in range(5):
        rows.append([f"{m}月{d + i}日", rng.choice(["08:30–12:00", "13:30–17:30", "18:00–21:00"]), rng.choice(["讲解", "巡查", "登记", "培训", "接待"]),
                     names[i], rng.choice(rooms)])
    pick = rows[2]
    base = {"title": f"{rng.choice(ORGS)} {what}", "lang": "zh",
            "blocks": [("table", {"columns": ["日期", "时间", "内容", "负责人", "地点"], "rows": rows}),
                       ("p", "如需调班，请提前一天告知。（合成数据）")],
            "table": {"columns": ["日期", "时间", "内容", "负责人", "地点"], "rows": rows},
            "key_fields": {"条目数": 5, pick[0]: f"{pick[3]} {pick[1]} {pick[4]}"},
            "numbers": [],
            "qa": [q(f"{pick[0]}由谁负责？", pick[3]), q(f"{pick[0]}在哪里？", pick[4]), q(f"{rows[4][0]}是什么时间段？", rows[4][1])]}
    base["sheets"] = [{"name": "安排", "title": base["title"], "columns": ["日期", "时间", "内容", "负责人", "地点"], "rows": rows,
                       "col_widths": [10, 14, 8, 10, 10]},
                      {"name": "统计", "columns": ["负责人", "次数"],
                       "rows": [[n, {"f": f"=COUNTIF('安排'!D3:D7,\"{n}\")", "v": 1}] for n in names]}]
    return base


def fam_recipe(rng, variant=0):
    dishes = [("南瓜芝士蛋糕", 170, 55), ("全麦核桃面包", 190, 35), ("蜂蜜烤鸡翅", 200, 25), ("抹茶磅蛋糕", 165, 45), ("焦糖布丁", 150, 40)]
    name, temp, mins = dishes[variant % len(dishes)]
    serv = rng.choice([4, 6, 8])
    ings = [("主料", rng.randint(2, 6) * 50), ("鸡蛋", rng.randint(2, 4) * 50), ("砂糖", rng.randint(3, 8) * 10), ("黄油", rng.randint(3, 8) * 10)]
    base = {"title": f"{name}（{serv}人份）", "lang": "zh",
            "blocks": [("table", {"columns": ["材料", "用量（克）"], "rows": [list(i) for i in ings]}),
                       ("h", "步骤"),
                       ("ul", ["材料室温回软后混合均匀", f"烤箱预热至 {temp}℃", f"入炉烘烤 {mins} 分钟，中途转盘一次", "出炉冷却 20 分钟后切块"]),
                       ("p", "小贴士：糖可减少两成。（合成数据）")],
            "key_fields": {"份数": serv, "温度": f"{temp}℃", "时长": f"{mins}分钟", "砂糖": ings[2][1]},
            "numbers": [{"value": temp, "label": "温度"}, {"value": mins, "label": "分钟"}],
            "qa": [q("烤箱预热到多少度？", temp, "number"), q("烘烤多少分钟？", mins, "number"), q("砂糖用多少克？", ings[2][1], "number"),
                   q("这是几人份？", serv, "number")]}
    return base


def fam_lease(rng, variant=0):
    landlord, tenant = people(rng, 2)
    city = rng.choice(CITIES)
    addr = f"{city}市{rng.choice(['梧桐', '青石', '临江', '松柏'])}路{rng.randint(10, 300)}号{rng.randint(1, 12)}栋{rng.randint(101, 1802)}室"
    rent = rng.randint(18, 90) * 100
    dep = rent * rng.choice([1, 2])
    m = rng.randint(1, 12)
    years = rng.choice([1, 2])
    payday = rng.choice([1, 5, 10, 15])
    base = {"title": "房屋租赁合同（摘要）", "lang": "zh",
            "blocks": [("kv", [("出租方", landlord), ("承租方", tenant), ("房屋地址", addr), ("租期", f"{years}年，自{ymd(m, 1)}起"),
                               ("月租金", f"{rent:,}元"), ("押金", f"{dep:,}元"), ("付款日", f"每月{payday}日前")]),
                       ("p", "水电燃气费由承租方承担；提前退租需提前30日书面通知。"),
                       ("p", "（合成数据，非真实合同）")],
            "key_fields": {"月租金": rent, "押金": dep, "付款日": f"每月{payday}日", "租期": f"{years}年", "地址": addr},
            "numbers": [{"value": rent, "label": "月租"}, {"value": dep, "label": "押金"}],
            "qa": [q("月租金多少元？", rent, "number"), q("押金多少元？", dep, "number"), q("每月几号前付租？", payday, "number"),
                   q("承租方是谁？", tenant)]}
    return base


def fam_inventory(rng, variant=0):
    items = rng.sample([("一次性手套", "盒"), ("移液枪头 200μL", "包"), ("75%酒精", "瓶"), ("称量纸", "包"), ("离心管 1.5mL", "袋"),
                        ("口罩", "盒"), ("滤纸", "包"), ("标签纸", "卷"), ("护目镜", "副")], 6)
    rows = []
    for j, (name, unit) in enumerate(items):
        safe = rng.choice([5, 10, 15])
        stock = rng.randint(0, safe - 1) if j == 1 else rng.randint(0, 40)
        rows.append([name, unit, stock, safe, "是" if stock < safe else "否"])
    need = [r[0] for r in rows if r[4] == "是"] or ["无"]
    pick = rows[3]
    base = {"title": f"{rng.choice(['A', 'B', 'C'])}区耗材库存表（{rng.randint(3, 11)}月盘点）", "lang": "zh",
            "blocks": [("table", {"columns": ["名称", "单位", "库存", "安全库存", "需补货"], "rows": rows}),
                       ("p", f"需补货：{'、'.join(need)}。（合成数据）")],
            "table": {"columns": ["名称", "单位", "库存", "安全库存", "需补货"], "rows": rows},
            "key_fields": {"需补货": need, pick[0]: pick[2]},
            "numbers": [{"value": pick[2], "label": pick[0]}],
            "qa": [q(f"{pick[0]}的库存是多少？", pick[2], "number"), q("哪些需要补货？", need[0]), q(f"{rows[0][0]}的安全库存是多少？", rows[0][3], "number")]}
    base["sheets"] = [{"name": "库存", "title": base["title"], "columns": ["名称", "单位", "库存", "安全库存", "需补货"],
                       "rows": [[r[0], r[1], r[2], r[3], {"f": f'=IF(C{3 + i}<D{3 + i},"是","否")', "v": r[4]}] for i, r in enumerate(rows)],
                       "col_widths": [18, 6, 8, 10, 8]},
                      {"name": "汇总", "columns": ["指标", "数值"],
                       "rows": [["品类数", {"f": "=COUNTA('库存'!A3:A8)", "v": 6}],
                                ["需补货数", {"f": "=COUNTIF('库存'!E3:E8,\"是\")", "v": sum(1 for r in rows if r[4] == '是')}]]}]
    base["record"] = {"inventory": [{"name": r[0], "unit": r[1], "stock": r[2], "safety_stock": r[3], "reorder": r[4] == "是"} for r in rows],
                      "note": "合成数据"}
    return base


def fam_league(rng, variant=0):
    sport = ["羽毛球", "篮球", "乒乓球", "足球"][variant % 4]
    teams = rng.sample(["飞鹰队", "海豚队", "青松队", "火焰队", "北极星队", "闪电队", "银杏队"], 5)
    rows = []
    for t in teams:
        w = rng.randint(1, 8)
        l = rng.randint(0, 6)
        rows.append([t, w, l, w * 3])
    rows.sort(key=lambda r: (-r[3], r[2]))
    base = {"title": f"{rng.choice(ORGS)[:4]}杯{sport}联赛积分榜", "lang": "zh",
            "blocks": [("table", {"columns": ["队名", "胜", "负", "积分"], "rows": rows}), ("p", "胜一场积3分，负不得分。（合成数据）")],
            "table": {"columns": ["队名", "胜", "负", "积分"], "rows": rows},
            "chart": {"title": f"{sport}联赛积分", "series": {"积分": [r[3] for r in rows]}, "xlabels": [r[0] for r in rows], "kind": "bar"},
            "key_fields": {"第一名": rows[0][0], rows[2][0]: rows[2][3]},
            "numbers": [{"value": rows[0][3], "label": "第一名积分"}],
            "qa": [q("积分榜第一是哪个队？", rows[0][0]), q(f"{rows[2][0]}积多少分？", rows[2][3], "number"),
                   q(f"{rows[1][0]}赢了几场？", rows[1][1], "number")]}
    n = len(rows)
    base["sheets"] = [{"name": "积分榜", "title": base["title"], "columns": ["队名", "胜", "负", "积分"],
                       "rows": [[r[0], r[1], r[2], {"f": f"=B{3 + i}*3", "v": r[3]}] for i, r in enumerate(rows)],
                       "col_widths": [12, 6, 6, 8]},
                      {"name": "统计", "columns": ["指标", "数值"],
                       "rows": [["总场次（胜）", {"f": f"=SUM('积分榜'!B3:B{2 + n})", "v": sum(r[1] for r in rows)}],
                                ["最高积分", {"f": f"=MAX('积分榜'!D3:D{2 + n})", "v": rows[0][3]}]]}]
    return base


def fam_travel(rng, variant=0):
    city = CITIES[variant % len(CITIES)]
    spots = rng.sample(["老街", "植物园", "博物馆", "江边步道", "古塔", "美术馆", "夜市", "湿地公园"], 4)
    times = ["09:00", "11:00", "14:30", "18:30"]
    prices = [rng.choice([0, 20, 35, 60, 80]) for _ in spots]
    total = sum(prices)
    base = {"title": f"{city}一日游路线", "lang": "zh",
            "blocks": [("p", f"适合周末的{city}城市漫步路线，全程步行加地铁。"),
                       ("table", {"columns": ["时间", "地点", "门票（元）"], "rows": [[t, s, p] for t, s, p in zip(times, spots, prices)]}),
                       ("p", f"门票合计 {total} 元。建议穿舒适的鞋。（合成数据）")],
            "key_fields": {"城市": city, "第一站": spots[0], "门票合计": total},
            "numbers": [{"value": total, "label": "门票合计"}],
            "qa": [q("第一站去哪？", spots[0]), q("门票合计多少元？", total, "number"), q(f"几点到{spots[2]}？", times[2])]}
    return base


# ============================================================================== English families

def fam_po_en(rng, variant=0):
    buyer, vendor = rng.sample(EN_ORGS, 2)
    po = f"PO-{rng.randint(2026000, 2026999)}"
    items = rng.sample([("USB-C docking station", 129.0), ("27-inch monitor", 239.0), ("Label printer", 89.5), ("Ergonomic chair", 310.0),
                        ("Wireless headset", 74.9), ("Portable projector", 420.0)], 3)
    rows, sub = [], 0.0
    for name, price in items:
        qty = rng.randint(1, 10)
        amt = round(qty * price, 2)
        sub = round(sub + amt, 2)
        rows.append([name, qty, f"{price:.2f}", f"{amt:,.2f}"])
    ship = rng.choice([0.0, 25.0, 40.0])
    total = round(sub + ship, 2)
    m, d = rng.randint(3, 11), rng.randint(1, 20)
    months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    base = {"title": f"Purchase Order {po}", "lang": "en",
            "blocks": [("kv", [("Buyer", buyer), ("Vendor", vendor), ("Order date", f"{months[m - 1]} {d}, 2026"),
                               ("Deliver by", f"{months[m - 1]} {d + 7}, 2026"), ("Contact", rng.choice(EN_NAMES))]),
                       ("table", {"columns": ["Item", "Qty", "Unit price (USD)", "Amount (USD)"], "rows": rows}),
                       ("kv", [("Subtotal", f"USD {sub:,.2f}"), ("Shipping", f"USD {ship:,.2f}"), ("Total", f"USD {total:,.2f}")]),
                       ("p", "Payment terms: net 30. Synthetic document for evaluation only.")],
            "key_fields": {"po_number": po, "vendor": vendor, "total_usd": total, "deliver_by": f"2026-{m:02d}-{d + 7:02d}"},
            "numbers": [{"value": sub, "label": "subtotal"}, {"value": total, "label": "total"}],
            "qa": [q("What is the PO number?", po, "exact"), q("What is the order total in USD?", total, "number", tol=0.01),
                   q(f"How many units of '{rows[0][0]}' are ordered?", rows[0][1], "number"), q("Who is the vendor?", vendor)]}
    return base


def fam_agenda_en(rng, variant=0):
    topic = ["Data Literacy Workshop", "Field Safety Training", "Product Design Sprint", "Open Science Day"][variant % 4]
    venue = rng.choice(["Room 204, Hall B", "Main Auditorium", "Lab Annex 1", "Online (video call)"])
    spk = rng.sample(EN_NAMES, 4)
    slots = [("09:00", "Welcome and goals", spk[0]), ("09:30", "Hands-on session 1", spk[1]), ("11:00", "Case study", spk[2]),
             ("13:30", "Group exercise", spk[3]), ("15:30", "Wrap-up and feedback", spk[0])]
    m, d = rng.randint(3, 11), rng.randint(1, 28)
    months = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    cap = rng.choice([24, 30, 40, 60])
    base = {"title": f"{topic} — Agenda", "lang": "en",
            "blocks": [("kv", [("Date", f"{months[m - 1]} {d}, 2026"), ("Venue", venue), ("Capacity", f"{cap} participants")]),
                       ("table", {"columns": ["Time", "Session", "Speaker"], "rows": [list(s) for s in slots]}),
                       ("p", "Lunch is served 12:15–13:30. Synthetic agenda for evaluation only.")],
            "key_fields": {"date": f"2026-{m:02d}-{d:02d}", "venue": venue, "capacity": cap, "case_study_speaker": spk[2]},
            "numbers": [{"value": cap, "label": "capacity"}],
            "qa": [q("Where is the workshop held?", venue), q("Who presents the case study?", spk[2]),
                   q("What time does the group exercise start?", "13:30"), q("How many participants can attend?", cap, "number")]}
    return base


def fam_status_en(rng, variant=0):
    proj = ["Warehouse Scanner Rollout", "Website Redesign", "Customer Portal v2", "Solar Monitoring Pilot"][variant % 4]
    status = rng.choice(["Green", "Amber", "Red"])
    spent = rng.randint(30, 90)
    budget = rng.randint(40, 300) * 1000
    ms = [("Design sign-off", "done"), ("Pilot at 2 sites", rng.choice(["in progress", "done"])), ("Full rollout", "planned")]
    m, d = rng.randint(3, 11), rng.randint(1, 28)
    risk = rng.choice(["Vendor delivery slipped by 10 days", "Two key testers unavailable in week 3", "Integration API rate limits"])
    owner = rng.choice(EN_NAMES)
    base = {"title": f"Project Status Update: {proj}", "lang": "en",
            "blocks": [("kv", [("Owner", owner), ("Overall status", status), ("Budget", f"USD {budget:,}"), ("Budget spent", f"{spent}%")]),
                       ("h", "Milestones"), ("table", {"columns": ["Milestone", "State"], "rows": [list(x) for x in ms]}),
                       ("h", "Top risk"), ("p", risk),
                       ("h", "Next report"), ("p", f"Next update due on 2026-{m:02d}-{d:02d}. Synthetic report for evaluation only.")],
            "key_fields": {"owner": owner, "status": status, "budget_usd": budget, "spent_pct": spent, "top_risk": risk},
            "numbers": [{"value": budget, "label": "budget"}, {"value": spent, "label": "spent %"}],
            "qa": [q("What is the overall status?", status), q("What percentage of the budget is spent?", spent, "number"),
                   q("What is the top risk?", risk), q("Who owns the project?", owner)]}
    return base


PROSE_FAMILIES = {"invoice": fam_invoice, "minutes": fam_minutes, "notice": fam_notice, "labrecord": fam_labrecord,
                  "itinerary": fam_itinerary, "budget": fam_budget, "weekly": fam_weekly, "schedule": fam_schedule,
                  "recipe": fam_recipe, "lease": fam_lease, "inventory": fam_inventory, "league": fam_league, "travel": fam_travel,
                  "po_en": fam_po_en, "agenda_en": fam_agenda_en, "status_en": fam_status_en}

# Standalone plan: type -> list of family names (one file each). Table/structured types use families that carry sheets/records.
PLAN = {
    "txt": ["minutes", "weekly", "recipe", "status_en"],
    "md": ["weekly", "recipe", "agenda_en", "labrecord"],
    "rtf": ["lease", "notice", "minutes", "po_en"],
    "html": ["notice", "travel", "status_en", "league"],
    "docx": ["minutes", "lease", "agenda_en"],
    "doc": ["notice", "weekly", "labrecord", "po_en"],
    "odt": ["minutes", "itinerary", "recipe", "status_en"],
    "pdf": ["invoice", "agenda_en"],
    "pdf_scanned": ["invoice", "notice", "lease", "labrecord"],
    "epub": ["travel_book", "recipe_book", "handbook_en", "water_book"],
    "webarchive": ["notice", "travel", "product", "recipe"],
    "csv": ["schedule", "league", "inventory"],
    "xlsx": ["budget", "invoice", "inventory"],
    "ods": ["budget", "league", "schedule", "invoice"],
    "json": ["itinerary", "inventory", "survey_en"],
    "xml": ["rss", "invoice", "inventory", "registration_en"],
    "pptx": ["weekly", "status_en", "budget", "training"],
    "odp": ["minutes", "travel", "status_en", "labrecord"],
    "mp4": ["weekly", "budget", "notice", "agenda_en"],
    "mov": ["status_en", "recipe", "league", "itinerary"],
    "gif": ["notice", "progress", "recipe", "agenda_en"],
    "png": ["budget_chart", "signup_window", "notice_card"],
    "jpg": ["receipt_photo", "minutes_photo", "notice_photo"],
    "heic": ["label_photo", "receipt_photo", "schedule_photo", "recipe_photo"],
    "webp": ["order_window", "lab_chart", "notice_card", "league_table"],
    "bmp": ["league_chart", "label_card", "schedule_table", "sign"],
    "tiff": ["lease_scan2", "labrecord_scan", "notice_fax", "invoice_scan"],
    "svg": ["poster", "bar_chart", "org_chart", "seat_map"],
    "ics": ["weekly_meeting", "allday_conf", "trip_en"],
    "vcf": ["contacts_zh", "contacts_en", "contacts_qp", "contact_full"],
    "eml": ["notice_xlsx", "po_pdf_en", "newsletter_html"],
    "mbox": ["venue_thread", "hiring_en", "gbk_thread", "tickets"],
    "zip": ["reimburse", "project_docs", "photos", "english_pack"],
}
