#!/usr/bin/env python3
"""Score the /v1/state of a store COPY whose item ids are not the scenario's (a store the Mac harness filled).

The scale runs of 2026-09 were driven from the Mac, so their item ids differ from the scenario's; the Mac kept a
send ledger to map them back. This does the same from the store itself: an item is matched to the scenario item
with exactly the same text (first unused one, in time order); a segment keeps its parent's id (the state lists
parents with their segments). Items without a match are dropped from the state (reported).

  python3 eval/tools/score_copy.py --db <copy>/data/organizer.db --state state.json \
      --scenario eval/scenarios/scale-pm/scenario.json --json score.json

Synthetic data only. Needs the organizer's venv (sqlcipher3) to read the store.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "spark"))
sys.path.insert(0, str(ROOT / "eval"))

from organizer import db  # noqa: E402
from score import markdown_report, score  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", required=True)
    ap.add_argument("--state", required=True)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--json")
    ap.add_argument("--md")
    args = ap.parse_args()
    scen = json.loads(Path(args.scenario).read_text(encoding="utf-8"))
    state = json.loads(Path(args.state).read_text(encoding="utf-8"))
    conn = db.open_for_analysis(args.db)
    texts = dict(conn.execute("SELECT item_id, text FROM items i WHERE revision = (SELECT MAX(revision) FROM items j WHERE j.item_id = i.item_id)").fetchall())
    started = dict(conn.execute("SELECT item_id, started_ts FROM items i WHERE revision = (SELECT MAX(revision) FROM items j WHERE j.item_id = i.item_id)").fetchall())
    by_text = defaultdict(list)
    for it in sorted(scen["items"], key=lambda i: i["t"]):
        t = (it.get("text") or "").strip()
        if t:
            by_text[t].append(it["item_id"])
    mapping, used = {}, set()
    for iid in sorted(texts, key=lambda i: (started.get(i, 0), i)):
        t = (texts[iid] or "").strip()
        cand = [g for g in by_text.get(t, []) if g not in used]
        if cand:
            mapping[iid] = cand[0]
            used.add(cand[0])
    gold_ids = {it["item_id"] for it in scen["items"]}
    missing = sorted(gold_ids - used)

    def mp(i):
        return mapping.get(i)

    for e in state.get("events") or []:
        e["item_ids"] = [mp(i) for i in e.get("item_ids") or [] if mp(i)]
        for seg in e.get("segments") or []:
            seg["item_id"] = mp(seg.get("item_id")) or seg.get("item_id")
        e["segments"] = [s for s in e.get("segments") or [] if s["item_id"] in gold_ids]
        for f in e.get("status_facts") or []:
            if isinstance(f, dict):
                f["item_ids"] = [mp(i) for i in f.get("item_ids") or [] if mp(i)]
    state["unfiled"] = [{"item_id": mp(u["item_id"] if isinstance(u, dict) else u)} for u in state.get("unfiled") or []
                        if mp(u["item_id"] if isinstance(u, dict) else u)]
    state["item_persons"] = [{"item_id": mp(l["item_id"]), "person_id": l["person_id"]} for l in state.get("item_persons") or []
                             if mp(l.get("item_id"))]
    state["questions"] = []
    last_cp = scen["checkpoints"][-1]["checkpoint_id"]
    result = score(scen, {last_cp: state}, state)
    result["copy_mapping"] = {"store_items": len(texts), "mapped": len(mapping), "scenario_items_unmatched": len(missing)}
    if args.json:
        Path(args.json).write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    if args.md:
        Path(args.md).write_text(markdown_report(result), encoding="utf-8")
    print(json.dumps({"mapping": result["copy_mapping"], "summary": result["summary"]}, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
