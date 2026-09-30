"""Per-skill latency / token / throughput numbers from the three scale runs' organizer ledgers.

Input: <scale-runs>/{lab,startup,pm}/score/spark-db-extract.json (the Spark organizer.db
`runs` and `jobs` tables, exported after each run) and spark-metrics.jsonl (5-min vLLM/GPU samples).
All synthetic. No new model calls. Output: ledger_latency.json next to this file.
"""
import json
import statistics
from collections import defaultdict
from pathlib import Path

BASE = Path("<demo>/scale")
OUT = Path(__file__).with_name("ledger_latency.json")


def pct(xs, q):
    if not xs:
        return None
    xs = sorted(xs)
    k = (len(xs) - 1) * q
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


res = {}
for sc in ("lab", "startup", "pm"):
    d = json.load(open(BASE / sc / "score" / "spark-db-extract.json"))
    summ = json.load(open(BASE / sc / "run" / "scenario-summary.json"))
    runs, jobs = d["runs"], d["jobs"]
    if sc == "lab":  # lab's extract has no token columns; same runs table re-exported from the Spark DB
        runs = json.load(open(Path(__file__).with_name("lab-runs-tokens.json")))
    t0 = min(r["started_at"] for r in runs)
    t1 = max(r["ended_at"] for r in runs)
    by = defaultdict(list)
    for r in runs:
        by[r["skill"]].append(r)
    skills = {}
    for sk, rs in sorted(by.items(), key=lambda kv: -len(kv[1])):
        lat = [r["ended_at"] - r["started_at"] for r in rs]
        pt = [r["prompt_tokens"] or 0 for r in rs]
        ct = [r["completion_tokens"] or 0 for r in rs]
        skills[sk] = {
            "calls": len(rs),
            "ok_rate": round(sum(1 for r in rs if r["ok"]) / len(rs), 3),
            "retried_share": round(sum(1 for r in rs if (r["attempts"] or 1) > 1) / len(rs), 3),
            "latency_p50_s": round(pct(lat, 0.5), 2),
            "latency_p95_s": round(pct(lat, 0.95), 2),
            "latency_mean_s": round(statistics.mean(lat), 2),
            "busy_seconds_total": round(sum(lat)),
            "prompt_tokens_mean": round(statistics.mean(pt)),
            "completion_tokens_mean": round(statistics.mean(ct)),
            "prompt_tokens_total": sum(pt),
            "completion_tokens_total": sum(ct),
        }
    tot_pt = sum(s["prompt_tokens_total"] for s in skills.values())
    tot_busy = sum(s["busy_seconds_total"] for s in skills.values())
    for s in skills.values():
        s["share_of_prompt_tokens"] = round(s["prompt_tokens_total"] / tot_pt, 3)
        s["share_of_call_seconds"] = round(s["busy_seconds_total"] / tot_busy, 3)
    # per-job (one item or one Spark-made segment) processing time
    jt = [j["run_ended"] - j["run_started"] for j in jobs if j.get("run_started") and j.get("run_ended")]
    ingest_jobs = [j for j in jobs if j["reason"] == "ingest"]
    items = summ["items_in_scenario"]
    # GPU utilisation inside the processing window
    gpu = []
    for line in open(BASE / sc / "spark-metrics.jsonl"):
        try:
            m = json.loads(line)
        except ValueError:
            continue
        if t0 <= m.get("ts", 0) <= t1 and m.get("gpu_util_pct") is not None:
            gpu.append(m["gpu_util_pct"])
    res[sc] = {
        "items": items,
        "spark_host": summ.get("host"),
        "organize_minutes": round(summ["organize_seconds"] / 60, 1),
        "wall_seconds_per_item": round(summ["organize_seconds"] / items, 1),
        "items_per_min": round(items / (summ["organize_seconds"] / 60), 2),
        "items_per_min_reported": summ.get("items_per_minute"),
        "calls_total": len(runs),
        "calls_per_item": round(len(runs) / items, 2),
        "prompt_tokens_per_item": round(tot_pt / items),
        "completion_tokens_per_item": round(sum(s["completion_tokens_total"] for s in skills.values()) / items),
        "model_call_seconds_per_item": round(tot_busy / items, 1),
        "effective_call_concurrency": round(tot_busy / summ["organize_seconds"], 2),
        "jobs": len(jobs),
        "job_seconds_p50": round(pct(jt, 0.5), 1),
        "job_seconds_p95": round(pct(jt, 0.95), 1),
        "ingest_jobs": len(ingest_jobs),
        "gpu_util_mean_pct_reported": {"lab": 93.6, "startup": 94.1, "pm": 87.0}[sc],  # scale/SUMMARY.md
        "skills": skills,
    }

# pooled across the three runs
pool = defaultdict(list)
for sc in ("lab", "startup", "pm"):
    d = json.load(open(BASE / sc / "score" / "spark-db-extract.json"))
    if sc == "lab":
        d["runs"] = json.load(open(Path(__file__).with_name("lab-runs-tokens.json")))
    for r in d["runs"]:
        pool[r["skill"]].append(r)
pooled = {}
for sk, rs in sorted(pool.items(), key=lambda kv: -len(kv[1])):
    lat = [r["ended_at"] - r["started_at"] for r in rs]
    pooled[sk] = {
        "calls": len(rs),
        "latency_p50_s": round(pct(lat, 0.5), 2),
        "latency_p95_s": round(pct(lat, 0.95), 2),
        "prompt_tokens_mean": round(statistics.mean([r["prompt_tokens"] or 0 for r in rs])),
        "completion_tokens_mean": round(statistics.mean([r["completion_tokens"] or 0 for r in rs])),
        "ok_rate": round(sum(1 for r in rs if r["ok"]) / len(rs), 3),
    }
res["pooled_three_runs"] = pooled
OUT.write_text(json.dumps(res, ensure_ascii=False, indent=1))
print(json.dumps(res, ensure_ascii=False, indent=1))
