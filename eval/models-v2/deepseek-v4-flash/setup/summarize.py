"""Compact organizer-quality metrics for one or more run_eval.py output dirs."""
import json
import sys
from pathlib import Path

LLM_JOBS = ("assign", "brief", "rank", "split")  # image_detect/image_read/screenshot_read go to the vision model


def row(run: Path) -> dict:
    s = json.loads((run / "score.json").read_text())["summary"]
    sc = json.loads((run / "score.json").read_text())
    st = json.loads((run / "stats.json").read_text())
    meta = json.loads((run / "meta.json").read_text())
    n = sc["n_items"]
    jobs = st["per_job"]
    comp = sum(jobs[j]["completion_tokens_total"] for j in LLM_JOBS if j in jobs)
    lat = sum(jobs[j]["latency_total_s"] for j in LLM_JOBS if j in jobs)
    img = {k: v for k, v in jobs.items() if k not in LLM_JOBS}
    return {
        "run": run.name, "scenario": sc["scenario_id"], "model": meta["model"], "items": n,
        "b3_f1": round(s["bcubed_f1"], 3), "link_f1": round(s["link_f1"], 3),
        "card_fact_recall": round(s["card_fact_recall"], 3),
        "status_fact_recall": round(s["status_fact_recall"], 3),
        "asks_per_100": s["asks_per_100_items"], "ungrounded_dates": s["ungrounded_card_dates"],
        "plan_as_done": s["plan_as_done"], "plan_labelled_done": s["plan_labelled_done"],
        "unsupported_completion": s["unsupported_completion"],
        "hard_decoy_leakage": s["hard_decoy_leakage"], "noise_abstention": s["noise_abstention"],
        "relative_date_in_card": s["relative_date_in_card"], "stale_fact_rate": s["stale_fact_rate"],
        "absorbed_matters": s["absorbed_matters"],
        "brief_ok": f'{jobs["brief"]["ok"]}/{jobs["brief"]["calls"]}',
        "home_ndcg5": round(s["home_ndcg5"], 3) if s.get("home_ndcg5") is not None else None,
        "pred_gold_events": f'{s["pred_event_count"]}/{s["gold_event_count"]}',
        "wall_s": st["wall_s"], "s_per_item": round(st["wall_s"] / n, 2),
        "llm_s_per_item": round(lat / n, 2),
        "completion_tok_s": round(comp / lat, 1) if lat else None,
        "llm_calls": sum(jobs[j]["calls"] for j in LLM_JOBS if j in jobs),
        "llm_failed": sum(jobs[j]["calls"] - jobs[j]["ok"] for j in LLM_JOBS if j in jobs),
        "retried": {j: jobs[j]["retried"] for j in LLM_JOBS if j in jobs},
        "latency_median_s": {j: jobs[j]["latency_median_s"] for j in LLM_JOBS if j in jobs},
        "image_jobs": {k: f'{v["ok"]}/{v["calls"]}' for k, v in img.items()},
        "prompt_hashes": meta.get("prompt_hashes"),
    }


if __name__ == "__main__":
    rows = [row(Path(p)) for p in sys.argv[1:]]
    print(json.dumps(rows, ensure_ascii=False, indent=1))
