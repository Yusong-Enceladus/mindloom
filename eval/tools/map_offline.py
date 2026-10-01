#!/usr/bin/env python3
"""Run the v7 grouping pass and the matter maps on a COPY of an existing store, without serving it.

Uses the code the service runs (organizer.matter_group.MatterGrouper and organizer.matter_map.MatterMapper through
build_organizer): grouping passes until every matter is placed, then map passes (calls on a thread pool) until
every matter with at least --min-items items has a map; the Home matters (the --home most important ones) are
mapped even when smaller, as the Mac's on-demand request would. Consolidation, the people pass and the home rank
do not run, so the copy keeps its events, titles and order.

Writes --out (GET /v1/state since 0, with maps, facets, ropes and relations) and <out>.summary.json: the Home
matters, per-map cost (tokens, seconds, attempts), validator outcomes (first attempt valid, repaired without a
retry, fixed by the retry, dropped) with the error categories of every failed attempt, the ropes and the relations.

Synthetic data only. Never point it at a live store: it writes to the store it opens.

  python eval/tools/map_offline.py --data-dir <copy>/data --llm-url http://127.0.0.1:8000/v1 \\
      --embed-url http://127.0.0.1:8013/v1 --out state.json [--workers 4] [--home 6]
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "spark"))

from organizer.api import build_organizer  # noqa: E402
from organizer.config import Settings  # noqa: E402
from organizer.keys import synthetic_library_key  # noqa: E402


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", required=True)
    ap.add_argument("--llm-url", default="http://127.0.0.1:8000/v1")
    ap.add_argument("--embed-url", default="http://127.0.0.1:8013/v1")
    ap.add_argument("--out", required=True)
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--home", type=int, default=6, help="the most important matters, mapped whatever their size")
    ap.add_argument("--min-items", type=int, default=8)
    ap.add_argument("--max-passes", type=int, default=40)
    ap.add_argument("--skip-group", action="store_true")
    ap.add_argument("--skip-maps", action="store_true")
    args = ap.parse_args(argv)
    data_dir = Path(args.data_dir).resolve()
    if "Application Support" in str(data_dir):
        raise SystemExit("refusing: synthetic copies only")
    settings = Settings()
    settings.data_dir = data_dir
    settings.skills_dir = ROOT / "skills"
    settings.start_worker = False
    settings.llm_base_url = args.llm_url
    settings.embed_base_url = args.embed_url
    settings.clock = "replay"
    settings.record_inputs = True  # synthetic copy: keep each call's input for inspection
    settings.consolidate = False
    settings.people_pass = False
    settings.map_min_items = args.min_items
    settings.map_max_calls = max(args.workers, 4)
    # Synthetic copies are encrypted with the public synthetic key; a plaintext copy is encrypted with it on open.
    settings.unlock_key = synthetic_library_key()
    org = build_organizer(settings)
    store = org.store

    home = [e["event_id"] for e in sorted((e for e in store.live_events() if not e["feature_less"]),
                                          key=lambda e: (-e["importance"], e["handle"] or 0))[:args.home]]
    home_view = [{"event_id": e, "handle": store.event_handle(e), "title": store.get_event(e)["title"],
                  "items": len(store.event_item_ids(e)), "importance": store.get_event(e)["importance"]} for e in home]
    print("home:", json.dumps(home_view, ensure_ascii=False), flush=True)

    attempts: dict[str, dict] = {}
    real_call = org.mapper.call

    def recorded(ctx):
        res = real_call(ctx)
        attempts[ctx["event_id"]] = {"run_id": res.run_id, "ok": res.ok, "attempts": res.attempts,
                                     "attempt_errors": res.attempt_errors, "final_errors": res.errors[:8]}
        return res
    org.mapper.call = recorded
    group_attempts = []
    real_group = org.harness.run

    def group_run(job, data, **kw):
        res = real_group(job, data, **kw)
        if job == "group":
            group_attempts.append({"run_id": res.run_id, "ok": res.ok, "attempts": res.attempts,
                                   "attempt_errors": res.attempt_errors, "final_errors": res.errors[:8],
                                   "matters": len(data["matters"])})
        return res
    org.harness.run = group_run

    t0 = time.time()
    group_passes = []
    if not args.skip_group:
        for n in range(args.max_passes):
            todo = org.grouper.plan()
            if not todo:
                break
            st = org.grouper.run()
            st["t"] = round(time.time() - t0, 1)
            group_passes.append(st)
            print(f"group pass {n + 1}: {st}", flush=True)
            if not st.get("calls"):
                break
    t_group = time.time() - t0

    pool = ThreadPoolExecutor(max_workers=args.workers)
    map_passes = []
    t1 = time.time()
    if not args.skip_maps:
        for eid in home:
            if store.map_row(eid) is None:
                store.queue_map(eid, 2, "home")
        for n in range(args.max_passes):
            todo = org.mapper.plan(settings.map_max_calls)
            if not todo:
                break
            st = org.mapper.run(pool=pool)
            st["t"] = round(time.time() - t1, 1)
            map_passes.append(st)
            print(f"map pass {n + 1}: {st}", flush=True)
            if not st.get("maps"):
                break
    pool.shutdown(wait=True)
    t_maps = time.time() - t1

    maps = []
    for r in store.all("SELECT m.event_id, m.outcome, m.run_id, m.tries, e.handle, e.title FROM event_maps m"
                       " JOIN events e ON e.event_id = m.event_id ORDER BY e.handle"):
        runs = store.all("SELECT run_id, prompt_tokens, completion_tokens, started_at, ended_at, attempts, ok FROM runs"
                         " WHERE job_type='map' AND subject=? ORDER BY started_at", (r["event_id"],))
        row = store.map_row(r["event_id"])
        m = row["map"] or {}
        prop = store.one("SELECT status FROM proposals WHERE kind='map' AND run_id=?", (r["run_id"],))
        maps.append({"event_id": r["event_id"], "handle": f"E{r['handle']}", "title": r["title"], "outcome": r["outcome"],
                     "status": prop["status"] if prop else None, "items": len(store.event_item_ids(r["event_id"])),
                     "strands": len(m.get("strands") or []), "knots": len(m.get("knots") or []),
                     "health": (m.get("health") or {}).get("level"), "blocks": len(m.get("blocks") or []),
                     "prompt_tokens": sum(x["prompt_tokens"] or 0 for x in runs),
                     "completion_tokens": sum(x["completion_tokens"] or 0 for x in runs),
                     "seconds": round(sum(x["ended_at"] - x["started_at"] for x in runs), 1),
                     "calls": len(runs), "attempts": sum(x["attempts"] for x in runs),
                     "home": r["event_id"] in home, **{k: v for k, v in attempts.get(r["event_id"], {}).items()
                                                       if k in ("attempt_errors", "final_errors")}})
    group_runs = store.all("SELECT prompt_tokens, completion_tokens, started_at, ended_at, attempts, ok FROM runs"
                           " WHERE job_type='group'")
    state = org.state(0)
    summary = {
        "data_dir": str(data_dir.name), "home": home_view, "wall_s": {"group": round(t_group, 1), "maps": round(t_maps, 1)},
        "group_passes": group_passes, "group_calls": group_attempts,
        "group_cost": {"calls": len(group_runs), "prompt_tokens": sum(x["prompt_tokens"] or 0 for x in group_runs),
                       "completion_tokens": sum(x["completion_tokens"] or 0 for x in group_runs),
                       "seconds": round(sum(x["ended_at"] - x["started_at"] for x in group_runs), 1)},
        "map_passes": map_passes, "maps": maps,
        "outcomes": {k: sum(1 for m in maps if m["status"] == k) for k in ("applied", "partial", "rejected")},
        "first_attempt_valid": sum(1 for m in maps if m["status"] == "applied" and m["attempts"] == m["calls"]),
        "ropes": state["ropes"], "relations": {"cross": sum(1 for r in state["relations"] if r["kind"] == "cross"),
                                              "blocks": [r for r in state["relations"] if r["kind"] == "blocks"]},
        "stats": {"maps": org.mapper.stats, "grouping": org.grouper.stats},
        "model": org.harness.client.model_id, "owner_aliases": os.environ.get("ORGANIZER_OWNER_ALIASES", ""),
    }
    Path(args.out).write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    Path(args.out).with_suffix(".summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1),
                                                           encoding="utf-8")
    print(json.dumps({k: summary[k] for k in ("wall_s", "outcomes", "first_attempt_valid", "group_cost")},
                     ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
