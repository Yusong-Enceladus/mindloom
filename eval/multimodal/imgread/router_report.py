#!/usr/bin/env python3
"""Tables for the image-router measurement (eval/multimodal/BENCHMARK.md, "读图路由"). No model is called.

Input: the rows run_imgread.py wrote (all-Qwen and router runs on the mm-v1 test split) and the scorer's JSON
(score_imgread.py). Output: Markdown on stdout, and with --out a JSON with the same numbers.

  python3 router_report.py --gt-root eval/multimodal --split test \
      --run allqwen.r1=out/test-allqwen.r1.jsonl --run router.r1=out/test-router.r1.jsonl ...
Run names are <condition>.<repeat>; the condition is "allqwen" or "router".
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import Counter, defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import score_imgread  # noqa: E402

TYPES = score_imgread.TYPES
LABEL = {"chat_screenshot": "聊天截图", "chart_dashboard": "图表/看板", "slide": "幻灯片",
         "whiteboard_handwriting": "手写/白板", "receipt_invoice": "小票/销售单", "scanned_document": "扫描件",
         "form_label_sign": "标签/面单/标牌"}
SHORT = {"step3-vl-10b": "Step3-VL-10B", "qwen3.6-35b-a3b-nvfp4": "Qwen3.6 NVFP4"}
HEADLINE = {"chat_screenshot": [("sender_acc", "发送者"), ("time_acc", "时间"), ("msg_count_ok", "条数一致")],
            "chart_dashboard": [("point_acc", "数据点"), ("kpi_acc", "KPI")],
            "slide": [("bullet_recall", "要点召回")], "whiteboard_handwriting": [("line_exact", "行完全一致")],
            "receipt_invoice": [("item_f1", "明细 F1")], "scanned_document": [("table_cell_acc", "表格单元格")],
            "form_label_sign": [("label_field_acc", "字段值")]}


def mean(xs):
    xs = [x for x in xs if x is not None]
    return round(statistics.mean(xs), 1) if xs else None


def fmt(x, unit=""):
    return "—" if x is None else f"{x}{unit}"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--gt-root", required=True)
    ap.add_argument("--split", default="test")
    ap.add_argument("--run", action="append", required=True, help="<allqwen|router>.<rN>=path.jsonl")
    ap.add_argument("--out", default="")
    args = ap.parse_args()
    root = Path(args.gt_root)
    manifest = json.loads((root / "manifest.json").read_text())
    recs = {it["id"]: json.loads((root / it["gt"]).read_text()) for it in manifest["items"] if it["split"] == args.split}

    runs: dict[str, dict] = {}
    for spec in args.run:
        name, path = spec.split("=", 1)
        rows = [json.loads(line) for line in Path(path).read_text().splitlines()]
        rows = [r for r in rows if r["id"] in recs]
        meta_path = Path(path).with_suffix(".meta.json")
        wall = None
        if meta_path.exists():
            segs = json.loads(meta_path.read_text()).get("segments", [])
            wall = round(sum(s.get("wall_s", 0) for s in segs), 1)
        runs[name] = {"rows": rows, "score": score_imgread.summarize(rows, recs), "wall_s": wall}
    by_cond = defaultdict(list)
    for name in runs:
        by_cond[name.split(".")[0]].append(name)

    out: dict = {"split": args.split, "runs": {}, "by_type": {}}
    print("### 读图路由 · 整条 image-read 路径（类型步 + 抽取，mm-v1 %s %d 张）\n" % (args.split, len(recs)))
    print("| 条件 · 运行 | 类型判对 | CER ↓ | 关键字段 EM ↑ | QA 可答 ↑ | 重试后仍不合格 | p50 / p90（整次读图） | 整个 test 墙钟 |")
    print("|---|---|---|---|---|---|---|---|")
    for name, r in runs.items():
        s = r["score"]
        e = s["extraction"]
        print(f"| {name} | {s['type_accuracy']}% | {e['cer_macro']}% | {e['key_field_em_macro']}% | {e['qa_found_macro']}% "
              f"| {s['still_failing_after_retry']} | {s['latency_p50']} / {s['latency_p90']} s | {fmt(r['wall_s'], ' s')} |")
        out["runs"][name] = {k: s[k] for k in ("type_accuracy", "still_failing_after_retry", "latency_p50", "latency_p90",
                                              "first_try_valid", "retried", "extraction")}
        out["runs"][name]["wall_s"] = r["wall_s"]

    print("\n### 按图片类型：由哪个模型抽取、准确率、延迟（两次运行的均值；类型步都在 Qwen3.6 上）\n")
    print("| 类型 | 条件 | 抽取模型（张数） | 关键字段 EM | 专项指标 | CER | 整次读图 p50 |")
    print("|---|---|---|---|---|---|---|")
    for t in TYPES:
        for cond in ("allqwen", "router"):
            names = by_cond.get(cond, [])
            if not names:
                continue
            scores = [runs[n]["score"]["by_type"].get(t, {}) for n in names]
            models = Counter()
            for n in names:
                for row in runs[n]["rows"]:
                    if row["type"] == t:
                        models[SHORT.get(row.get("extract_model") or row.get("model"), row.get("extract_model") or row.get("model"))] += 1
            mtxt = "，".join(f"{m} {c // len(names)}" for m, c in models.most_common())
            head = "；".join(f"{lab} {fmt(mean([sc.get(k) for sc in scores]), '%')}" for k, lab in HEADLINE[t])
            cond_name = "全部 Qwen" if cond == "allqwen" else "路由"
            row = {"model": mtxt, "key_em": mean([sc.get("key_field_em") for sc in scores]),
                   "headline": {lab: mean([sc.get(k) for sc in scores]) for k, lab in HEADLINE[t]},
                   "cer": mean([sc.get("cer") for sc in scores]), "p50": mean([sc.get("latency_p50") for sc in scores])}
            out["by_type"].setdefault(t, {})[cond] = row
            print(f"| {LABEL[t]} | {cond_name} | {mtxt} | {fmt(row['key_em'], '%')} | {head} | {fmt(row['cer'], '%')} | {fmt(row['p50'], ' s')} |")

    print("\n### 路由计数（来自各次运行的 .meta.json，只有计数）\n")
    for name in runs:
        meta = Path(next(a.split("=", 1)[1] for a in args.run if a.startswith(name + "="))).with_suffix(".meta.json")
        if meta.exists():
            stats = json.loads(meta.read_text())["segments"][-1].get("route_stats")
            if stats:
                print(f"- {name}: {json.dumps(stats, ensure_ascii=False)}")
    if args.out:
        Path(args.out).write_text(json.dumps(out, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
