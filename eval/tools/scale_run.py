#!/usr/bin/env python3
"""From-scratch burst run of a scale scenario (lab / pm / startup) through the real organizer, in process.

The Mac harness of the original scale runs pasted every item at once (pace 0) and let the Spark's worker
drain the queue, so the scheduled passes (consolidation, people, grouping, maps) ran on their own schedule:
every N processed items and when the queue went idle. This does the same without the Mac: it queues every
item (time order, as eval/tools/to_items.py builds them), then steps the organizer until it has nothing
left to do, on the replay clock. Then it writes the final /v1/state snapshot and scores it with eval/score.py
(final state only: there are no per-checkpoint snapshots in a burst run).

Synthetic scenarios only. The data directory is new (or, with --resume, the one a crashed run left: ingest is
idempotent and the job queue resumes where it stopped).

  python3 eval/tools/scale_run.py eval/scenarios/scale-lab/scenario.json --out ~/hack/scale-runs/lab-base-r1 \
      --llm-url http://127.0.0.1:8000/v1 --embed-url http://127.0.0.1:8013/v1

Outputs in --out: config.json, progress.json (every 25 steps), final_state.json, runs.json (every model call:
skill, tokens, seconds), runtime.json (calls and tokens per skill, wall seconds), score.json, score.md.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
import time
import traceback
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "spark"))
sys.path.insert(0, str(ROOT / "eval" / "tools"))
sys.path.insert(0, str(ROOT / "eval"))

import eval_common  # noqa: E402
from organizer.api import build_organizer  # noqa: E402
from organizer.config import Settings  # noqa: E402
from organizer.keys import synthetic_library_key  # noqa: E402
from organizer.schemas import Item  # noqa: E402
from score import markdown_report, score, validate_scenario  # noqa: E402
from to_items import build_items  # noqa: E402


def write_json(path: Path, data) -> None:
    path.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")


def git_head() -> str:
    try:
        head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--short", "HEAD"], capture_output=True,
                              text=True, check=True).stdout.strip()
        dirty = subprocess.run(["git", "-C", str(ROOT), "status", "--porcelain", "--", "spark", "skills"],
                               capture_output=True, text=True, check=True).stdout.strip()
        return head + ("+dirty" if dirty else "")
    except Exception:  # noqa: BLE001 - a copied tree without git
        return "unknown"


def runtime_summary(org, seconds: float, steps: int, completed: bool) -> dict:
    runs = org.store.all("SELECT skill, prompt_tokens, completion_tokens, ok, attempts,"
                         " (ended_at - started_at) AS secs FROM runs")
    per = defaultdict(lambda: {"calls": 0, "ok": 0, "prompt_tokens": 0, "completion_tokens": 0, "seconds": 0.0})
    for r in runs:
        p = per[r["skill"]]
        p["calls"] += 1
        p["ok"] += int(bool(r["ok"]))
        p["prompt_tokens"] += r["prompt_tokens"] or 0
        p["completion_tokens"] += r["completion_tokens"] or 0
        p["seconds"] += r["secs"] or 0.0
    return {"completed": completed, "steps": steps, "seconds": round(seconds, 1), "model_calls": len(runs),
            "prompt_tokens": sum(p["prompt_tokens"] for p in per.values()),
            "completion_tokens": sum(p["completion_tokens"] for p in per.values()),
            "per_skill": {k: {**v, "seconds": round(v["seconds"], 1)} for k, v in sorted(per.items())},
            "consolidator": dict(org.consolidator.stats)}


def run(args) -> int:
    scenario_path = Path(args.scenario).resolve()
    scenario = json.loads(scenario_path.read_text(encoding="utf-8"))
    errors, _ = validate_scenario(scenario)
    if errors:
        raise ValueError(errors)
    out = Path(args.out).expanduser().resolve()
    if out.exists() and not args.resume:
        raise SystemExit(f"{out} exists; use --resume to continue a crashed run")
    out.mkdir(parents=True, exist_ok=True)
    settings = Settings()
    settings.data_dir = out / "data"
    settings.skills_dir = ROOT / "skills"
    settings.start_worker = False
    settings.llm_base_url = args.llm_url
    settings.llm_model = args.model
    settings.llm_timeout_s = args.timeout
    settings.embed_base_url = args.embed_url
    settings.clock = "replay"
    settings.rank_every_n_items = args.rank_every
    settings.record_inputs = False
    if args.workers:
        settings.workers = args.workers
    settings.unlock_key = synthetic_library_key()  # synthetic data only
    org = build_organizer(settings)
    org.rank_on_day_change = False
    config = {"scenario_id": scenario["scenario_id"], "scenario_sha256": hashlib.sha256(scenario_path.read_bytes()).hexdigest(),
              "model": org.harness.client.model_id, "embedding": org.embedder.model_id if org.embedder else None,
              "git": git_head(), "tag": args.tag, "workers": settings.workers, "rank_every": args.rank_every,
              "candidates_k": settings.candidates_k, "started_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
              "resumed": bool(args.resume), "synthetic_data_only": True,
              "skill_hashes": {k: v.prompt_hash for k, v in org.registry.skills.items()}}
    write_json(out / ("config.resume.json" if args.resume and (out / "config.json").exists() else "config.json"), config)
    items = build_items(str(scenario_path), render_missing=False)
    if args.limit:
        items = items[: args.limit]
    started = time.monotonic()
    accepted = dups = 0
    for i in range(0, len(items), 50):
        batch = [Item.model_validate(raw) for raw in items[i:i + 50]]
        a, d = org.ingest([it.model_dump(mode="json", exclude={"image_b64"}) for it in batch],
                          [it.image_bytes() for it in batch])
        accepted, dups = accepted + a, dups + d
    print(json.dumps({"ingested": accepted, "duplicates": dups, "items": len(items)}), flush=True)
    steps, completed = 0, False
    try:
        while True:
            if not org.step():
                break
            steps += 1
            if steps % 25 == 0:
                left = org.store.scalar("SELECT COUNT(*) FROM jobs WHERE state != 'done'")
                prog = {"steps": steps, "jobs_left": left, "elapsed_s": round(time.monotonic() - started, 1),
                        "events": org.store.scalar("SELECT COUNT(*) FROM events WHERE deleted=0")}
                write_json(out / "progress.json", prog)
                print(json.dumps(prog), flush=True)
        failed = org.store.all("SELECT item_id, state, error_category FROM jobs WHERE state NOT IN ('done')")
        if failed:
            (out / "failed_jobs.json").write_text(json.dumps(failed), encoding="utf-8")
        completed = not failed
    except Exception:
        (out / "failure.txt").write_text(traceback.format_exc(), encoding="utf-8")
        raise
    finally:
        seen = [it["item_id"] for it in items]
        state = eval_common.snapshot(org, seen)
        write_json(out / "final_state.json", state)
        write_json(out / "runs.json", org.store.all(
            "SELECT job_type, skill, subject, started_at, ended_at, prompt_tokens, completion_tokens, ok, attempts FROM runs"))
        summary = runtime_summary(org, time.monotonic() - started, steps, completed)
        write_json(out / "runtime.json", summary)
    if completed and not args.limit:
        last_cp = scenario["checkpoints"][-1]["checkpoint_id"]  # final state only, as score.py --state does
        result = score(scenario, {last_cp: state}, state)
        write_json(out / "score.json", result)
        (out / "score.md").write_text(markdown_report(result), encoding="utf-8")
        print(json.dumps({"runtime": {k: v for k, v in summary.items() if k != "per_skill"},
                          "summary": result["summary"]}, ensure_ascii=False), flush=True)
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("scenario")
    ap.add_argument("--out", required=True)
    ap.add_argument("--llm-url", default="http://127.0.0.1:8000/v1")
    ap.add_argument("--embed-url", default="http://127.0.0.1:8013/v1")
    ap.add_argument("--model", default="auto")
    ap.add_argument("--timeout", type=float, default=180)
    ap.add_argument("--workers", type=int, default=0, help="0 = the organizer's default (ORGANIZER_WORKERS, 1)")
    ap.add_argument("--rank-every", type=int, default=10, help="home-rank every N processed items (the service default)")
    ap.add_argument("--tag", default="", help="free label stored in config.json (e.g. baseline / fixed)")
    ap.add_argument("--limit", type=int, default=0, help="only the first N items (smoke test; not scored)")
    ap.add_argument("--resume", action="store_true")
    return run(ap.parse_args())


if __name__ == "__main__":
    sys.exit(main())
