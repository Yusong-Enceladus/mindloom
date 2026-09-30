"""Render the organizer-model comparison tables from ../eval.json into EVAL.md between the markers
<!-- ORG-TABLE:BEGIN --> and <!-- ORG-TABLE:END -->."""
import json
import re
from pathlib import Path

V5 = Path(__file__).resolve().parents[1]
E = json.loads((V5 / "eval.json").read_text())
om = E["organizer_models"]


def f3(x):
    return "—" if x is None else f"{x:.3f}"


def rng(a, k):
    if a["n"] > 1:
        lo, hi = a[k + "_range"]
        return f"**{a[k + '_mean']:.3f}**（{lo:.3f}–{hi:.3f}）" if k == "b3_f1" else f"{a[k + '_mean']:.3f}（{lo:.3f}–{hi:.3f}）"
    v = a[k + "_mean"]
    return ("**" + f3(v) + "**") if k == "b3_f1" and v is not None else f3(v)


def table(scn):
    rows = om[scn]
    out = ["| 模型 | 系列 | 占用 | n | B³ F1 | Link F1 | 卡片事实召回 | 难干扰泄漏 ↓ | 卡片通过校验 | 事件数 预测/真 | 秒/条 |",
           "|---|---|---|---|---|---|---|---|---|---|---|"]
    for a in rows:
        briefs = "、".join(r["brief_ok"] for r in a["runs"])
        ev = "、".join(r["pred_gold_events"] for r in a["runs"])
        spi = "、".join(f"{r['s_per_item']:.1f}" for r in a["runs"])
        out.append(f"| {a['label']} | {a['family']} | {a['hw']} | {a['n']} | {rng(a, 'b3_f1')} | {rng(a, 'link_f1')} | "
                   f"{rng(a, 'card_fact_recall')} | {rng(a, 'hard_decoy_leakage')} | {briefs} | {ev} | {spi} |")
    return "\n".join(out)


RES_ZH = {"aborted": "中止", "unusable": "不可用", "failed to start": "起不来"}


def failed():
    out = ["| 模型 | 系列 | 结果 | 原因 | 出处 |", "|---|---|---|---|---|"]
    for f in om["not_scored"]:
        out.append(f"| {f['model']} | {f.get('family', '')} | {f.get('result_zh', RES_ZH.get(f['result'], f['result']))} | {f.get('why_zh', f['why'])} | {f['src']} |")
    return "\n".join(out)


block = ("**留出集 holdout-week-v2（46 条、7 件事、2 个难干扰）**\n\n" + table("holdout-week-v2") +
         "\n\n**dev-week-v1（82 条、9 件事）**\n\n" + table("dev-week-v1") +
         "\n\n**没能评上分的模型**\n\n" + failed())
md = V5 / "EVAL.md"
s = md.read_text()
s = re.sub(r"<!-- ORG-TABLE:BEGIN -->.*?<!-- ORG-TABLE:END -->",
           lambda m: "<!-- ORG-TABLE:BEGIN -->\n" + block + "\n<!-- ORG-TABLE:END -->", s, flags=re.S)
md.write_text(s)
print(block)
