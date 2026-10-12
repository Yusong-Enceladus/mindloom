#!/usr/bin/env python3
"""Whole-organizer comparison, all-Qwen against the image router, on the same synthetic scenarios (run_router_bench.sh,
part 2). Reads each run directory's score.json, stats.json and runs.jsonl; no model is called. Markdown on stdout.

  python3 e2e_compare.py OUT_DIR scenario [scenario ...]      (OUT_DIR holds e2e-<scenario>-{allqwen,router}[-r2]/ or <scenario>-{...}/)
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from pathlib import Path

KEYS = [("bcubed_f1", "B³ F1"), ("bcubed_precision", "B³ P"), ("bcubed_recall", "B³ R"), ("link_f1", "链接 F1"),
        ("status_fact_recall", "进展行事实召回"), ("hard_decoy_leakage", "困难干扰泄漏 ↓"),
        ("pred_event_count", "预测事件数"), ("gold_event_count", "金标准事件数")]
SHORT = {"step3-vl-10b": "Step3-VL", "qwen3.6-35b-a3b-nvfp4": "Qwen3.6"}


def load(d: Path) -> dict:
    score = json.loads((d / "score.json").read_text())
    stats = json.loads((d / "stats.json").read_text())
    runs = [json.loads(line) for line in (d / "runs.jsonl").read_text().splitlines()]
    reads = Counter(SHORT.get(r["model"], r["model"]) for r in runs if r["job_type"] == "image_read")
    detects = Counter(SHORT.get(r["model"], r["model"]) for r in runs if r["job_type"] == "image_detect")
    return {"summary": score["summary"], "stats": stats, "reads": reads, "detects": detects,
            "image_run_attempts": sum(r["attempts"] for r in runs if r["job_type"] == "image_read")}


def main() -> None:
    out, scenarios = Path(sys.argv[1]), sys.argv[2:]
    print("| 场景 | 条件 | 图片 读图/判类型 的模型 | " + " | ".join(lab for _, lab in KEYS) + " | 回放命中 / 重问 | 整条流水线墙钟 |")
    print("|---|---|---|" + "---|" * len(KEYS) + "---|---|")
    for sc in scenarios:
        for cond, name in (("allqwen", "全部 Qwen"), ("router", "路由"), ("allqwen-r2", "全部 Qwen（重复）"),
                           ("router-r2", "路由（重复）")):
            d = next((x for x in (out / f"e2e-{sc}-{cond}", out / f"{sc}-{cond}") if (x / "score.json").exists()), None)
            if d is None:
                continue
            r = load(d)
            s, st = r["summary"], r["stats"]
            vals = " | ".join("—" if s.get(k) is None else (f"{s[k]:.3f}" if isinstance(s[k], float) else str(s[k])) for k, _ in KEYS)
            rc = st.get("replay_cache") or {}
            model = "，".join(f"{m} {n}" for m, n in r["reads"].most_common()) + " ／ " + "，".join(
                f"{m} {n}" for m, n in r["detects"].most_common())
            print(f"| {sc} | {name} | {model} | {vals} | {rc.get('hits', '—')} / {rc.get('misses', '—')} | {st.get('wall_s', '—')} s |")


if __name__ == "__main__":
    main()
