#!/usr/bin/env python3
"""Post-review corrections to the assembled scale-pm scenario, applied once before freezing.

  python3 patch_frozen.py eval/scenarios/scale-pm/scenario.json [--render]

The spot check before freezing found generation slips that assemble.py does not catch:
- email headers: a "pid.<family>.<given>@" handle for people without a Latin alias (reads like a gold id) and
  bodies written by the owner under someone else's From line (gen.fix_email_direction, now also in assemble.py);
- wrong years in dated documents (2023/2024/2025 for things that happen in 2026);
- the 栖木 offer scan addressed to the referrer instead of the owner;
- the 8/11 referral screenshot, whose generated chat was incoherent for that day (offer already "定岗", the owner
  forwarding the referral to her current boss); REWRITES replaces its messages by hand, keeping the planned fact.
Every edit is a literal replacement on the item's own strings (text, reading, image, matter quotes), so gold
labels are untouched. --render re-renders the PNG/PDF assets of the items it changed (text PDFs need reportlab).
Idempotent.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, ".."))

import gen  # noqa: E402

FIXES = {
    "p-promo_v1": [("2023 年 8 月 14 日", "2026 年 8 月 14 日"), ("2023 年 8 月 25 日", "2026 年 8 月 25 日")],
    "p-comp_v2": [("2024年新款降噪耳机", "2026年新款降噪耳机")],
    "p-calib_table": [("2024 年度中期评估", "2026 年度中期评估")],
    "p-okr_v3": [("2024 年第四季度", "2026 年第四季度")],
    "z-0813-106": [("2025年8月报销单", "2026年8月报销单")],
    "z-0918-067": [("2023年9月份", "2026年9月份")],
    "p-qimu_offer": [("致：叶知秋 女士", "致：江予安 女士"), ("首席技术官（CTO）田野 先生", "创始人兼 CEO 周屹 先生"),
                     ("2023 年", "2026 年"), ("202309", "202609"), ("XM20230915", "XM20260915")],
}

REWRITES = {
    "s-chat_ye_referral": {
        "messages": [
            {"sender": "叶子", "time": "20:45", "text": "安安，白天说的栖木那个 AI Agent 产品总监，我这边内推入口开好了"},
            {"sender": "我", "time": "20:48", "text": "好，简历我今晚改一版发你"},
            {"sender": "叶子", "time": "20:50", "text": "不急，田总那边我打过招呼了，他看了你的背景挺感兴趣"},
            {"sender": "我", "time": "20:52", "text": "这事先别跟别人提，公司这边我还不想让人知道"},
            {"sender": "叶子", "time": "20:55", "text": "放心，走内推流程，HR 那边是王蕊对接"},
            {"sender": "我", "time": "21:00", "text": "收到，谢啦，改完发你"},
        ],
        "person_mentions": [{"person_id": "ye_zhiqiu", "surface": "叶子"}],
    },
}


def patch_strings(obj, pairs):
    if isinstance(obj, str):
        for a, b in pairs:
            obj = obj.replace(a, b)
        return obj
    if isinstance(obj, list):
        return [patch_strings(v, pairs) for v in obj]
    if isinstance(obj, dict):
        return {k: (v if k in ("item_id", "ref", "t", "content_time") else patch_strings(v, pairs)) for k, v in obj.items()}
    return obj


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario")
    ap.add_argument("--render", action="store_true")
    args = ap.parse_args(argv)
    with open(args.scenario, encoding="utf-8") as fh:
        s = json.load(fh)
    changed = []
    for i, it in enumerate(s["items"]):
        new = it
        if it.get("format") == "email" and it.get("text"):
            new = dict(new, text=gen.fix_email_direction(new["text"]))
        if it["ref"] in FIXES:
            new = patch_strings(new, FIXES[it["ref"]])
        if it["ref"] in REWRITES:
            rw = REWRITES[it["ref"]]
            image = dict(new["image"], messages=rw["messages"])
            new = dict(new, image=image, reading=gen.image_text(image), person_mentions=rw["person_mentions"])
        if new != it:
            s["items"][i] = new
            changed.append(new)
    with open(args.scenario, "w", encoding="utf-8") as fh:
        json.dump(s, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    print(f"patched {len(changed)} items", file=sys.stderr)
    if args.render:
        assets = os.path.join(os.path.dirname(os.path.abspath(args.scenario)), "assets")
        for it in changed:
            if it.get("format") != "pdf" and it.get("kind") != "image":
                continue
            if it.get("image"):
                import render_screenshots as rs
                from PIL import Image
                png = os.path.join(assets, it["ref"] + ".png")
                rs.render(it["image"], png)
                if it["image"].get("style") == "generic_doc":
                    Image.open(png).convert("RGB").save(os.path.join(assets, it["ref"] + ".pdf"), "PDF", resolution=150)
            else:
                import render_pdfs
                render_pdfs.render(it["text"], os.path.join(assets, it["ref"] + ".pdf"))
            print("rendered", it["ref"], file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
