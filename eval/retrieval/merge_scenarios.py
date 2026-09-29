#!/usr/bin/env python3
"""Stress pool: replay two synthetic weeks as one stream on the same dates.

dev-week-v1 (2026-09-14..20, 9 events) and holdout-week-v2 (2026-11-09..15, 7 events) are both
Monday-to-Sunday weeks; the second is moved back 56 days so the two interleave in time. The candidate
pool then holds up to 16 live events, the time term no longer separates the two stories, and the
top-5 cut actually drops events. It is a pool-size stress test, not a new scenario: the two stories
have different owners and domains, so cross-story distractors are easier than the in-story decoys.

Only ids, refs and times change: the second scenario's person ids get a prefix (both use p_owner),
its refs get "h2-" (screenshot assets are copied under the new names), its times move -56 days.
Labels and texts are untouched. Writes <out>/scenario.json and <out>/assets/.

  python3 eval/retrieval/merge_scenarios.py eval/scenarios/dev-week-v1/scenario.json \
      eval/scenarios/holdout-week-v2/scenario.json --out /tmp/merged-2wk
"""

from __future__ import annotations

import argparse
import json
import shutil
from datetime import datetime, timedelta
from pathlib import Path


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("first")
    ap.add_argument("second")
    ap.add_argument("--shift-days", type=int, default=-56)
    ap.add_argument("--prefix", default="h2")
    ap.add_argument("--out", required=True)
    args = ap.parse_args(argv)
    a = json.loads(Path(args.first).read_text(encoding="utf-8"))
    b = json.loads(Path(args.second).read_text(encoding="utf-8"))
    if a.get("synthetic") is not True or b.get("synthetic") is not True:
        raise SystemExit("both scenarios must be marked synthetic")
    out = Path(args.out)
    (out / "assets").mkdir(parents=True, exist_ok=True)
    pre = args.prefix
    pid = lambda p: f"{pre}_{p}"  # noqa: E731
    shift = timedelta(days=args.shift_days)

    people = list(a["people"])
    for p in b["people"]:
        people.append({**p, "person_id": pid(p["person_id"])})
    items = list(a["items"])
    for it in a["items"]:
        src = Path(args.first).parent / "assets" / f"{it['ref']}.png"
        if it["kind"] == "image":
            shutil.copyfile(src, out / "assets" / f"{it['ref']}.png")
    for it in b["items"]:
        new = dict(it)
        new["ref"] = f"{pre}-{it['ref']}"
        new["t"] = (datetime.fromisoformat(it["t"]) + shift).isoformat()
        new["persons"] = [pid(p) for p in it.get("persons") or []]
        if it.get("segments"):
            new["segments"] = [{**s, "person_id": pid(s["person_id"])} if s.get("person_id") else s
                               for s in it["segments"]]
        if it["kind"] == "image":
            shutil.copyfile(Path(args.second).parent / "assets" / f"{it['ref']}.png",
                            out / "assets" / f"{new['ref']}.png")
        items.append(new)
    merged = {
        "scenario_id": f"{a['scenario_id']}+{b['scenario_id']}", "version": 1, "split": "stress",
        "synthetic": True, "locale": a.get("locale"),
        "title": "retrieval stress pool (two synthetic weeks on the same dates)",
        "owner_person_id": a["owner_person_id"], "people": people,
        "events": a["events"] + b["events"], "items": items, "facts": [], "checkpoints": [],
    }
    (out / "scenario.json").write_text(json.dumps(merged, ensure_ascii=False, indent=1), encoding="utf-8")
    print(f"{out / 'scenario.json'}: {len(items)} items, {len(merged['events'])} events")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
