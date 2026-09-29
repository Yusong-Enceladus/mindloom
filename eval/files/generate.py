#!/usr/bin/env python3
"""Generate the synthetic file set files-v1 (file-read evaluation). All content is invented.

20 templates x 3 variants: variant A of every template is dev, B and C are test. Office files are
authored with the test builders (spark/tests/filefixtures.py) and, for the legacy / OpenDocument / PDF / RTF
variants, converted with LibreOffice headless (data generation only; the organizer never runs LibreOffice).
Image parts reuse the mm-v1 images of the same split (dev files use dev images, test files test images),
so their gold lines come from eval/multimodal/gt.

Usage (on a Spark with LibreOffice and the organizer venv):
  python eval/files/generate.py            # writes eval/files/data, gold, manifest.json
"""

from __future__ import annotations

import csv
import hashlib
import io
import json
import os
import random
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
MM = REPO / "eval" / "multimodal"
sys.path.insert(0, str(REPO / "spark" / "tests"))
import filefixtures as F  # noqa: E402

DATA, GOLD = HERE / "data", HERE / "gold"
PROFILE = Path(tempfile.gettempdir()) / "lo-profile-files-v1"


def soffice(src: Path, fmt: str) -> bytes:
    out = src.parent / "out"
    out.mkdir(exist_ok=True)
    subprocess.run(["soffice", f"-env:UserInstallation=file://{PROFILE}", "--headless", "--convert-to", fmt,
                    "--outdir", str(out), str(src)], check=True, capture_output=True, timeout=180)
    ext = fmt.split(":")[0]
    return (out / (src.stem + "." + ext)).read_bytes()


def mm_image(image_id: str) -> tuple[bytes, list[str]]:
    item = next(i for i in json.loads((MM / "manifest.json").read_text())["items"] if i["id"] == image_id)
    gt = json.loads((MM / item["gt"]).read_text())
    return (MM / item["image"]).read_bytes(), gt["text_lines"]


def mm_lines(lines: list[str]) -> list[str]:
    """Gold strings of an image part: its first line and the longest printed token with a digit (an order
    number, an amount, a percentage). Whole later lines are not used: how a reading splits a line into
    label and value is up to image-read, and the gold must not depend on it."""
    import re
    tokens = [t for ln in lines[1:] for t in re.split(r"[\s：:，,]+", ln) if any(c.isdigit() for c in t) and len(t) >= 3]
    return [lines[0]] + ([max(tokens, key=len)] if tokens else [])


# ---- templates: each returns (filename, bytes, gold) --------------------------------------------------------
# gold: type, error, must_contain (text the parse must yield), must_contain_image (text only an image read
# yields), summary_groups (each group: alternatives; a summary hits the group if it contains any),
# fields ({key: value} for receipt-like documents), doc_kind (expected, informational)

V = {
    "notice": [dict(org="青松物业", date="10 月 12 日", span="8:00-18:00", bldg="3 栋", img="label-07", sign="2026-10-08"),
               dict(org="绿洲花园物业", date="11 月 3 日", span="9:00-16:30", bldg="7 栋", img="label-02", sign="2026-10-29"),
               dict(org="湖畔家园服务中心", date="10 月 25 日", span="13:00-17:00", bldg="12 栋", img="label-03", sign="2026-10-20")],
    "minutes": [dict(proj="点单小程序", who="唐宁", day="9 月 28 日", act="周四前提交支付联调报告"),
                dict(proj="门店翻新", who="谢雨桐", day="10 月 9 日", act="10 月 15 日前确定施工队"),
                dict(proj="年会筹备", who="Mia Chen", day="11 月 2 日", act="下周一前发出邀请函")],
    "contract": [dict(a="许诺", b="吴昊", rent="4,500", start="2026年10月1日", end="2027年9月30日", no="ZL-2026-451"),
                 dict(a="周明远", b="苏晓", rent="6,200", start="2026年11月1日", end="2027年10月31日", no="ZL-2026-518"),
                 dict(a="林海", b="陈可", rent="3,800", start="2026年12月1日", end="2027年11月30日", no="ZL-2026-602")],
    "invoice": [dict(seller="晨星文具有限公司", no="04412233", date="2026年09月18日", total="1,280.00", item="打印纸"),
                dict(seller="云岭电器有限公司", no="05510987", date="2026年10月02日", total="3,460.50", item="电热水壶"),
                dict(seller="穗禾里食品有限公司", no="06623145", date="2026年10月11日", total="865.00", item="咖啡豆")],
    "booking": [dict(hotel="临溪湖景酒店", no="HB88213", checkin="2026-10-16", checkout="2026-10-18", total="1,176"),
                dict(hotel="白石山居", no="HB90457", checkin="2026-11-05", checkout="2026-11-07", total="2,340"),
                dict(hotel="梧桐大道商务酒店", no="HB91120", checkin="2026-12-24", checkout="2026-12-26", total="980")],
    # (image ids, summary groups): what the first page is about, in words a Chinese summary would use
    "scan": [(["scan-01", "scan-02"], [["国庆"], ["值班"]]), (["scan-00", "scan-03"], [["点单小程序"], ["会议", "纪要"]]),
             (["scan-04", "scan-05"], [["memo", "备忘", "通知", "全体"], ["报销", "差旅", "reimbursement"]])],
    "expense": [dict(month="9月", rows=[("张三", "打车", 58.5), ("李四", "午餐招待", 320), ("王五", "高铁票", 553)]),
                dict(month="10月", rows=[("赵六", "打印", 86), ("钱七", "快递", 42.5), ("孙八", "酒店", 688)]),
                dict(month="11月", rows=[("周九", "会议室", 400), ("吴十", "茶歇", 256), ("郑一", "机票", 1320)])],
    "budget": [dict(name="国庆活动预算", rows=[("场地", 3000), ("餐饮", 1500), ("物料", 820)]),
               dict(name="年会预算", rows=[("场地", 12000), ("抽奖礼品", 6800), ("主持", 2500)]),
               dict(name="培训预算", rows=[("讲师费", 5000), ("教材", 960), ("茶歇", 640)])],
    "inventory": [dict(rows=[("螺丝 M4×20", 200, "A-03"), ("扎带", 150, "B-11")]),
                  dict(rows=[("纸杯 12oz", 800, "C-02"), ("吸管", 1200, "C-05")]),
                  dict(rows=[("咖啡豆 云南日晒", 24, "D-01"), ("牛奶 1L", 36, "冷藏-2")])],
    "roadmap": [dict(title="Q4 门店数字化路线图", img="chart-11", m1="10 月上线会员积分", m2="11 月接入外卖平台"),
                dict(title="2027 上半年产品计划", img="chart-00", m1="3 月发布自助点单", m2="5 月上线储值卡"),
                dict(title="小程序增长方案", img="chart-01", m1="首单立减 5 元", m2="邀请好友各得 10 元券")],
    "training": [dict(title="新员工入职培训", d1="第一天：公司制度与安全", d2="第二天：收银系统实操"),
                 dict(title="咖啡师进阶课程", d1="模块一：意式萃取参数", d2="模块二：拉花基础"),
                 dict(title="门店消防演练", d1="步骤一：发现火情立即报警", d2="步骤二：按疏散路线撤离")],
    "email": [dict(subj="9 月采购对账", img="receipt-10", who="周小满", ask="请在 10 月 8 日前确认金额"),
              dict(subj="门店耗材报销", img="receipt-01", who="李晓", ask="请本周五前审批"),
              dict(subj="样品费用确认", img="receipt-02", who="陈思远", ask="麻烦 10 月 20 日前回复")],
    "invite": [dict(summary="季度复盘会", start="20261015T143000", loc="3楼大会议室", org="王经理"),
               dict(summary="供应商比价会", start="20261103T100000", loc="线上会议 8812", org="赵主管"),
               dict(summary="年度体检", start="20261120T083000", loc="临溪体检中心", org="人事部")],
    "contact": [dict(name="张三", org="青松物业", tel="139-0000-1234", title="客服主管"),
                dict(name="李鸣", org="云岭电器", tel="138-0000-5678", title="销售经理"),
                dict(name="Chen Wei", org="Harbor Design", tel="+86 137 0000 2468", title="Designer")],
    "article": [dict(title="小户型厨房装修清单", p="台面选石英石，预算 8,000 元以内", url="https://example.invalid/kitchen"),
                dict(title="秋季露营装备指南", p="帐篷选三季帐，睡袋舒适温度 5℃", url="https://example.invalid/camping"),
                dict(title="新手养猫准备", p="猫砂盆放在安静角落，疫苗第 8 周开始", url="https://example.invalid/cat")],
    "archive": [dict(name="开业资料", img="board-03", note="开业前一周完成试营业"),
                dict(name="展会资料", img="board-00", note="展位号 B-17，布展 10 月 30 日"),
                dict(name="搬家资料", img="board-01", note="搬家公司预约 11 月 8 日上午")],
    "notes": [dict(title="读书会十月书单", b1="《活着》", b2="周六下午 3 点，湖畔咖啡馆"),
              dict(title="装修待办", b1="确认橱柜尺寸", b2="周三约水电师傅"),
              dict(title="旅行准备", b1="订 10 月 1 日高铁", b2="带好充电宝和雨伞")],
    "ebook": [dict(title="咖啡简史", author="林欣", c1="第一章 咖啡的起源", c2="第二章 从港口到街角"),
              dict(title="园艺入门", author="邓一凡", c1="第一章 认识土壤", c2="第二章 浇水的节奏"),
              dict(title="城市散步", author="谢雨桐", c1="第一章 清晨的菜市场", c2="第二章 老街与新店")],
    "keynote": [dict(img="slide-04"), dict(img="slide-00"), dict(img="slide-01")],
    "locked": [dict(name="工资单.pdf"), dict(name="体检报告.pdf"), dict(name="合同扫描.pdf")],
}


def t_notice(p, tmp):
    img, lines = mm_image(p["img"])
    data = F.docx([(f"{p['org']}停水通知", "Heading1"),
                   f"因二次供水设备检修，{p['date']} {p['span']} {p['bldg']}全楼停水，请提前储水。",
                   f"{p['org']}  {p['sign']}"], table=[["楼栋", "停水时段"], [p["bldg"], p["span"]]], image=img)
    return "停水通知.docx", data, dict(
        type="document", must_contain=[f"{p['bldg']}全楼停水", p["span"]], must_contain_image=mm_lines(lines),
        summary_groups=[["停水"], [p["date"].replace(" ", ""), p["date"]]], doc_kind="notice")


def t_minutes(p, tmp):
    src = tmp / "minutes.docx"
    src.write_bytes(F.docx([(f"{p['proj']}项目会议纪要", "Heading1"), f"时间：{p['day']} 14:00", f"记录人：{p['who']}",
                            ("待办", "Heading2")], table=[["事项", "负责人"], [p["act"], p["who"]]]))
    return "会议纪要.doc", soffice(src, "doc"), dict(
        type="document", must_contain=[f"{p['proj']}项目会议纪要", p["act"]], summary_groups=[[p["proj"]], ["纪要", "会议"]],
        doc_kind="minutes")


def t_contract(p, tmp):
    src = tmp / "contract.docx"
    src.write_bytes(F.docx([("房屋租赁合同", "Heading1"), f"合同编号：{p['no']}", f"出租方（甲方）：{p['a']}",
                            f"承租方（乙方）：{p['b']}", f"月租金：人民币 {p['rent']} 元",
                            f"租赁期限：{p['start']}至{p['end']}", "押金为一个月租金，每月 5 日前支付当月租金。"]))
    return "租赁合同.odt", soffice(src, "odt"), dict(
        type="document", must_contain=[p["no"], f"月租金：人民币 {p['rent']} 元"], summary_groups=[["租赁", "租房"], [p["rent"]]],
        fields={"parties": None, "amount": p["rent"], "start_date": p["start"]}, doc_kind="contract")


def t_invoice(p, tmp):
    src = tmp / "invoice.docx"
    src.write_bytes(F.docx([("增值税普通发票", "Heading1"), f"发票号码：{p['no']}", f"开票日期：{p['date']}",
                            f"销售方：{p['seller']}", "购买方：示例科技有限公司"],
                           table=[["货物名称", "数量", "金额"], [p["item"], "10", p["total"]]]))
    data = soffice(src, "pdf")
    return "发票.pdf", data, dict(
        type="pdf", must_contain=[f"发票号码：{p['no']}", p["seller"]], summary_groups=[["发票"], [p["seller"][:4]]],
        fields={"merchant": p["seller"], "doc_no": p["no"], "date": p["date"]}, doc_kind="receipt_invoice")


def t_booking(p, tmp):
    src = tmp / "booking.docx"
    src.write_bytes(F.docx([("预订确认单", "Heading1"), f"酒店：{p['hotel']}", f"预订号：{p['no']}",
                            f"入住日期：{p['checkin']}", f"离店日期：{p['checkout']}", "房型：大床房 1 间",
                            f"订单总价：¥{p['total']}"]))
    return "预订确认.rtf", soffice(src, "rtf"), dict(
        type="document", must_contain=[f"预订号：{p['no']}", p["checkin"]], summary_groups=[[p["hotel"][:4]], ["预订", "入住"]],
        fields={"booking_no": p["no"], "place": p["hotel"]}, doc_kind="booking_ticket")


def t_scan(spec, tmp):
    ids, groups = spec
    from PIL import Image
    pages, gold_lines = [], []
    for i in ids:
        data, lines = mm_image(i)
        pages.append(Image.open(io.BytesIO(data)).convert("RGB"))
        gold_lines += mm_lines(lines)
    buf = io.BytesIO()
    pages[0].save(buf, "PDF", save_all=True, append_images=pages[1:], resolution=150)
    return "扫描件.pdf", buf.getvalue(), dict(
        type="scanned_pdf", must_contain=[], must_contain_image=gold_lines,
        summary_groups=groups, doc_kind="")


def t_expense(p, tmp):
    rows = [["姓名", "项目", "金额", "状态"]] + [[a, b, c, "已审批" if k % 2 == 0 else "待审批"] for k, (a, b, c) in enumerate(p["rows"])]
    data = F.xlsx({f"{p['month']}报销": rows, "说明": [["报销截止", f"{p['month']}底"]]})
    return "报销明细.xlsx", data, dict(
        type="spreadsheet", must_contain=[f"## 工作表：{p['month']}报销", f"| {p['rows'][1][0]} | {p['rows'][1][1]} |"],
        summary_groups=[["报销"], [p["month"]]], doc_kind="dataset")


def t_budget(p, tmp):
    src = tmp / "budget.xlsx"
    src.write_bytes(F.xlsx({p["name"]: [["项目", "金额（元）"]] + [list(r) for r in p["rows"]]}))
    return "预算.xls", soffice(src, "xls"), dict(
        type="spreadsheet", must_contain=[f"## 工作表：{p['name']}", f"| {p['rows'][0][0]} | {p['rows'][0][1]} |"],
        summary_groups=[[p["name"][:2]], ["预算"]], doc_kind="dataset")


def t_inventory(p, tmp):
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(["物品", "数量", "库位"])
    for r in p["rows"]:
        w.writerow(r)
    return "库存盘点.csv", buf.getvalue().encode("gb18030"), dict(
        type="spreadsheet", must_contain=[f"| {p['rows'][0][0]} | {p['rows'][0][1]} | {p['rows'][0][2]} |"],
        summary_groups=[["库存", "盘点"]], doc_kind="dataset")


def t_roadmap(p, tmp):
    img, lines = mm_image(p["img"])
    data = F.pptx([{"title": p["title"], "bullets": [p["m1"], p["m2"]], "notes": "先讲目标再讲节奏"},
                   {"title": "数据回顾", "bullets": ["见下图"], "image": True}], image=img)
    return "路线图.pptx", data, dict(
        type="slides", must_contain=[p["title"], p["m1"]], must_contain_image=mm_lines(lines),
        summary_groups=[[p["title"][:4]]], doc_kind="plan")


def t_training(p, tmp):
    src = tmp / "training.pptx"
    src.write_bytes(F.pptx([{"title": p["title"], "bullets": [p["d1"], p["d2"]]}, {"title": "考核", "bullets": ["结业测验 80 分合格"]}]))
    return "培训.ppt", soffice(src, "ppt"), dict(
        type="slides", must_contain=[p["title"], p["d1"], "结业测验 80 分合格"], summary_groups=[[p["title"][:4]]],
        doc_kind="plan")


def t_email(p, tmp):
    img, lines = mm_image(p["img"])
    att = F.xlsx({"对账": [["日期", "金额"], ["9月3日", 1260], ["9月17日", 845]]})
    data = F.eml(p["subj"], f"李四你好，\n附件是{p['subj']}的明细和小票照片，{p['ask']}。\n{p['who']}",
                 [("对账明细.xlsx", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", att),
                  ("小票.jpg", "image/jpeg", img)])
    return f"{p['subj']}.eml", data, dict(
        type="email", must_contain=[f"主题：{p['subj']}", p["ask"], "| 9月3日 | 1260 |"], must_contain_image=mm_lines(lines),
        summary_groups=[[p["subj"].replace(" ", "")[:4], p["subj"][:4]]], doc_kind="letter")


def t_invite(p, tmp):
    ics = F.ics().decode("utf-8").replace("季度复盘会", p["summary"]).replace("20261015T143000", p["start"]) \
        .replace("3楼大会议室", p["loc"]).replace("王经理", p["org"])
    day = f"{p['start'][:4]}-{p['start'][4:6]}-{p['start'][6:8]}"
    return "invite.ics", ics.encode("utf-8"), dict(
        type="calendar", must_contain=[f"日程：{p['summary']}", day], summary_groups=[[p["summary"]]], doc_kind="plan",
        det_fields={"summary": p["summary"], "location": p["loc"]})


def t_contact(p, tmp):
    v = (f"BEGIN:VCARD\r\nVERSION:3.0\r\nFN:{p['name']}\r\nORG:{p['org']}\r\nTITLE:{p['title']}\r\n"
         f"TEL;TYPE=CELL:{p['tel']}\r\nEND:VCARD\r\n")
    return f"{p['name']}.vcf", v.encode("utf-8"), dict(
        type="contact", must_contain=[f"姓名：{p['name']}", f"电话：{p['tel']}"], summary_groups=[[p["name"]]],
        doc_kind="other", det_fields={"name": p["name"], "phone": p["tel"]})


def t_article(p, tmp):
    html = (f"<html><head><title>{p['title']}</title><script>track()</script></head><body><h1>{p['title']}</h1>"
            f"<p>{p['p']}。</p><ul><li>先量尺寸</li><li>再比三家</li></ul></body></html>")
    return "收藏.webarchive", F.webarchive(p["url"], html), dict(
        type="web", must_contain=[f"网址：{p['url']}", p["p"]], summary_groups=[[p["title"][:4]]], doc_kind="manual")


def t_archive(p, tmp):
    img, lines = mm_image(p["img"])
    inner_doc = F.docx([f"{p['name']}说明", p["note"]])
    data = F.zip_of({f"{p['name']}/说明.docx": inner_doc, f"{p['name']}/清单.csv": "物品,数量\n桌子,4\n椅子,16\n".encode(),
                     f"{p['name']}/白板.jpg": img, "__MACOSX/._说明.docx": b"x"})
    return f"{p['name']}.zip", data, dict(
        type="archive", must_contain=[p["note"], "| 椅子 | 16 |"], must_contain_image=mm_lines(lines)[:1],
        summary_groups=[[p["name"][:2]]], doc_kind="other")


def t_notes(p, tmp):
    md = f"# {p['title']}\n\n- {p['b1']}\n- {p['b2']}\n"
    return "笔记.md", md.encode("utf-8"), dict(
        type="text", must_contain=[p["b1"], p["b2"]], summary_groups=[[p["title"][:3]]], doc_kind="plan")


def t_ebook(p, tmp):
    return f"{p['title']}.epub", F.epub(p["title"], p["author"], [p["c1"], p["c2"]]), dict(
        type="ebook", must_contain=[f"书名：{p['title']}", p["c2"]], summary_groups=[[p["title"]]], doc_kind="other",
        det_fields={"title": p["title"], "creator": p["author"]})


def t_keynote(p, tmp):
    img, lines = mm_image(p["img"])
    from PIL import Image
    buf = io.BytesIO()
    Image.open(io.BytesIO(img)).convert("RGB").save(buf, "JPEG", quality=90)
    return "汇报.key", F.iwork_with_preview(buf.getvalue()), dict(
        type="slides", must_contain=[], must_contain_image=mm_lines(lines), summary_groups=[[lines[0][:4]]], doc_kind="")


def t_locked(p, tmp):
    return p["name"], F.encrypted_pdf(), dict(type="pdf", error="encrypted", must_contain=[], summary_groups=[["加密"]])


# Summary keywords for templates whose titles make poor literal prefixes (set after dev-r3, before any test
# result was looked at): a summary may paraphrase a title, so the gold names the topic words instead.
SUMMARY_OVERRIDES = {
    "keynote-a": [["预算"]], "keynote-b": [["周报", "点单小程序"]], "keynote-c": [["复盘", "经营"]],
    "roadmap-a": [["数字化", "路线图"]], "roadmap-b": [["产品计划", "2027"]], "roadmap-c": [["增长", "拉新"]],
    "training-a": [["入职", "培训"]], "training-b": [["咖啡师"]], "training-c": [["消防"]],
    "notes-a": [["读书会"]], "notes-b": [["装修"]], "notes-c": [["旅行", "出行"]],
}

TEMPLATES = {"notice": t_notice, "minutes": t_minutes, "contract": t_contract, "invoice": t_invoice,
             "booking": t_booking, "scan": t_scan, "expense": t_expense, "budget": t_budget, "inventory": t_inventory,
             "roadmap": t_roadmap, "training": t_training, "email": t_email, "invite": t_invite, "contact": t_contact,
             "article": t_article, "archive": t_archive, "notes": t_notes, "ebook": t_ebook, "keynote": t_keynote,
             "locked": t_locked}


def main() -> None:
    random.seed(1)
    for d in (DATA, GOLD):
        if d.exists():
            shutil.rmtree(d)
        d.mkdir(parents=True)
    items = []
    with tempfile.TemporaryDirectory() as t:
        for name, fn in TEMPLATES.items():
            for k, params in enumerate(V[name]):
                tmp = Path(t) / f"{name}-{k}"
                tmp.mkdir()
                filename, data, gold = fn(params, tmp)
                fid = f"{name}-{'abc'[k]}"
                ext = filename.rsplit(".", 1)[-1]
                (DATA / f"{fid}.{ext}").write_bytes(data)
                gold = {"id": fid, "template": name, "split": "dev" if k == 0 else "test", "filename": filename,
                        "path": f"data/{fid}.{ext}", "sha256": hashlib.sha256(data).hexdigest(), "size": len(data),
                        "error": None, "must_contain_image": [], "fields": {}, "det_fields": {}, **gold}
                if fid in SUMMARY_OVERRIDES:
                    gold["summary_groups"] = SUMMARY_OVERRIDES[fid]
                (GOLD / f"{fid}.json").write_text(json.dumps(gold, ensure_ascii=False, indent=1), encoding="utf-8")
                items.append({k2: gold[k2] for k2 in ("id", "template", "split", "filename", "path", "type", "sha256", "size")})
    soffice_version = subprocess.run(["soffice", "--version"], capture_output=True, text=True).stdout.strip()
    manifest = {"version": "files-v1", "description": "Synthetic files for file-read (all content invented).",
                "rules": "dev = variant a of each template; test = variants b and c. Tune on dev only.",
                "generator": {"libreoffice": soffice_version, "python": sys.version.split()[0]},
                "counts": {"dev": sum(i["split"] == "dev" for i in items), "test": sum(i["split"] == "test" for i in items)},
                "items": items}
    (HERE / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(manifest["counts"]), sum(i["size"] for i in items), "bytes")


if __name__ == "__main__":
    os.environ.setdefault("SAL_USE_VCLPLUGIN", "svp")
    main()
