#!/usr/bin/env python3
"""Print the markdown tables of eval/retrieval/README.md from results/*/*/summary.json and bench/*.json.

  python3 eval/retrieval/report.py
"""

from __future__ import annotations

import json
from pathlib import Path

RES = Path(__file__).resolve().parent / "results"

# (scenario key, run dir per condition); node-a = the organizer's own node (production 0.6B endpoint),
# node-b = the node where 4B was served. The 0.6B row is node-a's endpoint.
SCENARIOS = [("dev-week-v1", "dev"), ("holdout-week-v2", "holdout2"), ("压力池：dev + holdout2 同一周回放", "merged")]
CONDITIONS = [
    ("Qwen3-Embedding-4B（2560 维）", "node-b/{s}-q4b"),
    ("Qwen3-Embedding-0.6B（1024 维，现用）", "node-a/{s}-q06"),
    ("词法基线：字二元组哈希（256 维）", "node-a/{s}-hash"),
    ("不用向量（只剩时间+人物+来源）", "node-a/{s}-none"),
]


def load(rel: str) -> dict:
    return json.loads((RES / rel / "summary.json").read_text(encoding="utf-8"))


def pct(x) -> str:
    return "—" if x is None else f"{100 * x:.1f}"


def main() -> int:
    for title, s in SCENARIOS:
        first = load(CONDITIONS[1][1].format(s=s))
        print(f"\n**{title}**：计分 {first['items_scored']} 条（共 {first['items_total']} 条；"
              f"{first['items_first_mention']} 条是事件的第一条、{first['items_noise']} 条噪声，候选池里没有真事件，不计分），"
              f"候选池平均 {first['mean_pool_size']} 个事件\n")
        print("| 检索用的文本向量 | R@1 | R@3 | R@5（现用 k） | MRR | 只看相似度 R@1 | 前 5 漏掉 |")
        print("|---|---:|---:|---:|---:|---:|---|")
        for name, rel in CONDITIONS:
            r = load(rel.format(s=s))
            f, so = r["fused"], r["similarity_only"]
            sim1 = "n/a" if r["embedder"] == "none" else pct(so["recall@1"])
            misses = ", ".join(m["ref"] for m in r["misses@5"][:6]) + (" …" if len(r["misses@5"]) > 6 else "")
            print(f"| {name} | {pct(f['recall@1'])} | {pct(f['recall@3'])} | {pct(f['recall@5'])} | "
                  f"{f['mrr']:.3f} | {sim1} | {len(r['misses@5'])}{': ' + misses if misses else ''} |")
        rnd = first["random"]
        print(f"| 随机排序（期望值） | {pct(rnd['recall@1'])} | {pct(rnd['recall@3'])} | {pct(rnd['recall@5'])} "
              f"| — | — | — |")

    print("\n| 端点 | 维度 | 单条 p50 / p95 ms | 16 条一批 条/秒 | 进程 GPU 内存 | 权重 | "
          "同卡负载（测完采样的 GPU 占用） |")
    print("|---|---:|---:|---:|---:|---:|---|")
    rows = [("Qwen3-Embedding-4B，node-b，vLLM util 0.16", "node-b/bench/q4b.json", "7.56 GiB", "另一 VLM 评测，39%"),
            ("Qwen3-Embedding-4B，node-b，重测", "node-b/bench/q4b-r2.json", "7.56 GiB", "另一 VLM 评测，95%"),
            ("Qwen3-Embedding-0.6B，node-b，vLLM util 0.05", "node-b/bench/q06.json", "1.12 GiB", "另一 VLM 评测，39%"),
            ("Qwen3-Embedding-0.6B，node-b，重测", "node-b/bench/q06-r2.json", "1.12 GiB", "另一 VLM 评测，95%"),
            ("Qwen3-Embedding-0.6B，node-a :8013（现用）", "node-a/bench/q06.json", "1.12 GiB", "Qwen3.6 主模型，88%"),
            ("字二元组哈希，进程内", "node-a/bench/hash.json", "0", "—")]
    for name, rel, weights, load_ in rows:
        b = json.loads((RES / rel).read_text(encoding="utf-8"))
        mem = b["memory"].get("gpu_used_mib", 0)
        print(f"| {name} | {b['dim']} | {b['single_ms']['p50']} / {b['single_ms']['p95']} | {b['batch']['texts_per_s']} | "
              f"{mem / 1024:.1f} GiB | {weights} | {load_} |")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
