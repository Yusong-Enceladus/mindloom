#!/usr/bin/env python3
"""Run the organizer's consolidation pass on a COPY of an existing store, without serving it.

Uses the same code the service runs (organizer.consolidate.Consolidator through build_organizer): it plans,
calls event-consolidate on a thread pool and applies the verdicts, pass after pass, until no event is eligible
(the idle trigger's condition). Briefs and the home rank are not run, so it is a fast way to measure the
grouping effect on a large store; the service does both afterwards on its own.

Synthetic data only. Never point it at a live store: it writes to the store it opens.

  python eval/tools/consolidate_offline.py --data-dir <copy>/data --llm-url http://127.0.0.1:8000/v1 \\
      --embed-url http://127.0.0.1:8013/v1 --out state.json [--workers 4] [--max-passes 50]
"""

from __future__ import annotations

import argparse
import json
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
    ap.add_argument("--out", required=True, help="write /v1/state (since 0) here after the passes")
    ap.add_argument("--workers", type=int, default=4)
    ap.add_argument("--max-passes", type=int, default=60)
    ap.add_argument("--max-calls", type=int, default=None, help="override the per-pass call budget")
    ap.add_argument("--subject-max", type=int, default=None)
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
    # Synthetic copies are encrypted with the public synthetic key (docs/PRIVACY.md); a plaintext copy from before
    # v6 is encrypted with it on open. A store the Mac keyed with a real library key cannot be opened here.
    settings.unlock_key = synthetic_library_key()
    if args.max_calls:
        settings.consolidate_max_calls = args.max_calls
    if args.subject_max:
        settings.consolidate_subject_max = args.subject_max
    org = build_organizer(settings)
    cons = org.consolidator
    pool = ThreadPoolExecutor(max_workers=args.workers)
    before = org.store.count_events()
    t0 = time.time()
    passes = []
    for n in range(args.max_passes):
        if not cons.idle_due():
            break
        st = cons.run(pool=pool)
        st["t"] = round(time.time() - t0, 1)
        passes.append(st)
        print(f"pass {n + 1}: {st}", flush=True)
    pool.shutdown(wait=True)
    after = org.store.count_events()
    tokens = org.store.one("SELECT COUNT(*) AS calls, COALESCE(SUM(prompt_tokens),0) AS pin,"
                           " COALESCE(SUM(completion_tokens),0) AS pout FROM runs WHERE job_type='consolidate'"
                           " AND started_at >= ?", (t0,))
    summary = {"events_before": before, "events_after": after, "passes": passes, "wall_s": round(time.time() - t0, 1),
               "calls": tokens["calls"], "prompt_tokens": tokens["pin"], "completion_tokens": tokens["pout"],
               "stats": cons.stats}
    print(json.dumps(summary, ensure_ascii=False))
    Path(args.out).write_text(json.dumps(org.state(0), ensure_ascii=False), encoding="utf-8")
    Path(args.out).with_suffix(".summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1),
                                                           encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
