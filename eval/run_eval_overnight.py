#!/usr/bin/env python3
"""Run synthetic inputs through the real organizer in a new isolated database.

Gold labels are used only by score.py after inference. No existing service or
database is changed. Save checkpoints, failures, token usage and latency.

This is the runner behind docs/EVALUATION_20260926.md and FINAL_EVALUATION_20260927.md
(--mode with-skills|without-skills). eval/run_eval.py is the separate runner behind
skills/*/BENCHMARK.md (--condition skills|bare|baseline); their ablations differ.

Time: --clock replay (default) runs the organizer on its replay clock, so historical items are never
judged against today's date (the 2026-09-26 overnight run used the wall clock and wrote plans as
done: pass --clock wall only to reproduce that). --rank item (default) keeps home-rank after every
item as before (82 calls on dev); --rank checkpoint ranks once per checkpoint like run_eval.py.
Snapshots carry the same eval-only fields as run_eval.py (eval_common.snapshot); runs.json keeps each
call's as_of and exact user message (synthetic data only). --answer-questions gold answers open
same_event questions from gold labels after each item.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import statistics
import sys
import time
import traceback
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "spark"))
sys.path.insert(0, str(ROOT / "eval" / "tools"))
sys.path.insert(0, str(ROOT / "eval"))

import eval_common
from organizer.api import build_organizer
from organizer.config import Settings
from organizer.schemas import Item
from to_items import build_items
from score import score, markdown_report, validate_scenario


def write_json(path, data):
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")


def drain(org, rank_mode: str, max_steps: int = 200) -> int:
    steps = 0
    while steps < max_steps:
        if rank_mode == "checkpoint":
            org._rank_dirty = False
        if not org.step():
            break
        steps += 1
    return steps


def run(args):
    scenario_path = Path(args.scenario).resolve()
    scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
    errors, warnings = validate_scenario(scenario)
    if errors:
        raise ValueError(errors)
    output = Path(args.out).resolve()
    output.mkdir(parents=True, exist_ok=False)
    (output / "snapshots").mkdir()
    settings = Settings()
    settings.data_dir = output / "data"
    settings.skills_dir = ROOT / "skills"
    settings.start_worker = False
    settings.llm_base_url = args.llm_url
    settings.llm_model = args.model
    settings.llm_timeout_s = args.timeout
    settings.embed_base_url = args.embed_url
    settings.clock = args.clock
    settings.record_inputs = True  # synthetic data only
    if args.rank == "checkpoint":
        settings.rank_every_n_items = 10 ** 9
    org = build_organizer(settings)
    org.rank_on_day_change = False  # keep the protocol's rank calls comparable across clocks
    answerer = eval_common.GoldAnswerer(scenario) if args.answer_questions == "gold" else None
    if args.mode == "without-skills":
        # Same model, data, schemas, retrieval and validators; remove skill rules only.
        eval_common.strip_skill_text(org)
    config = {
        "scenario_id": scenario["scenario_id"], "mode": args.mode,
        "scenario_sha256": hashlib.sha256(scenario_path.read_bytes()).hexdigest(),
        "model": org.harness.client.model_id,
        "embedding": org.embedder.model_id if org.embedder else None,
        "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "auto_answer_questions": args.answer_questions == "gold", "synthetic_data_only": True,
        "clock": args.clock, "rank": args.rank,
        "skill_hashes": {k: v.prompt_hash for k, v in org.registry.skills.items()},
    }
    write_json(output / "config.json", config)
    cp_by_item = {}
    for cp in scenario["checkpoints"]:
        cp_by_item.setdefault(cp["after_item_id"], []).append(cp["checkpoint_id"])
    snapshots, latencies, seen = {}, [], []
    started = time.monotonic()
    completed = False
    try:
        items = build_items(str(scenario_path), render_missing=False)
        for index, raw in enumerate(items, 1):
            item_started = time.monotonic()
            it = Item.model_validate(raw)
            payload = it.model_dump(mode="json", exclude={"image_b64"})
            org.ingest([payload], [it.image_bytes()])
            seen.append(it.item_id)
            if args.rank == "checkpoint":
                org._rank_dirty = False
            steps = drain(org, args.rank)
            if answerer and answerer.answer_open(org):
                steps += drain(org, args.rank)
            jobs = org.store.all("SELECT state, error_category FROM jobs WHERE state != 'done'")
            if steps >= 200 or jobs:
                raise RuntimeError(f"item {index} did not drain: {jobs}")
            latency = time.monotonic() - item_started
            latencies.append(latency)
            for cp_id in cp_by_item.get(it.item_id, []):
                if args.rank == "checkpoint":
                    org.rank()
                snapshots[cp_id] = eval_common.snapshot(org, seen)
                write_json(output / "snapshots" / f"{cp_id}.json", snapshots[cp_id])
            progress = {"items_done": index, "items_total": len(items), "last_item_seconds": latency,
                        "elapsed_seconds": time.monotonic() - started}
            write_json(output / "progress.json", progress)
            print(json.dumps(progress), flush=True)
        completed = True
    except Exception:
        (output / "failure.txt").write_text(traceback.format_exc(), encoding="utf-8")
        raise
    finally:
        state = eval_common.snapshot(org, seen)
        write_json(output / "final_state.json", state)
        runs = org.store.all("SELECT * FROM runs ORDER BY started_at")
        write_json(output / "runs.json", runs)
        summary = {"completed": completed, "items_processed": len(latencies),
                   "seconds": time.monotonic() - started, "skill_runs": len(runs),
                   "skill_failures": sum(not r["ok"] for r in runs),
                   "prompt_tokens": sum(r.get("prompt_tokens") or 0 for r in runs),
                   "completion_tokens": sum(r.get("completion_tokens") or 0 for r in runs),
                   "latency_median_s": statistics.median(latencies) if latencies else None,
                   "latency_max_s": max(latencies) if latencies else None}
        write_json(output / "runtime.json", summary)
        if completed:
            result = score(scenario, snapshots, state)
            write_json(output / "score.json", result)
            (output / "score.md").write_text(markdown_report(result), encoding="utf-8")
            print(json.dumps({"runtime": summary, "scores": result["summary"]}), flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("scenario")
    ap.add_argument("--out", required=True, help="new directory; existing directories are refused")
    ap.add_argument("--llm-url", default="http://127.0.0.1:8000/v1")
    ap.add_argument("--model", default="auto")
    ap.add_argument("--embed-url", default="", help="empty disables embeddings explicitly")
    ap.add_argument("--timeout", type=float, default=90)
    ap.add_argument("--mode", choices=["with-skills", "without-skills"], default="with-skills")
    ap.add_argument("--clock", choices=["replay", "wall"], default="replay",
                    help="organizer clock; wall reproduces the 2026-09-26 overnight condition")
    ap.add_argument("--rank", choices=["item", "checkpoint"], default="item",
                    help="item = home-rank after every item (previous protocol); checkpoint = once per checkpoint")
    ap.add_argument("--answer-questions", choices=["none", "gold"], default="none")
    run(ap.parse_args())


if __name__ == "__main__":
    main()
