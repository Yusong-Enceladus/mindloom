#!/usr/bin/env python3
"""item-split on the large synthetic scenarios: fixtures, a split-only run, and the segment-truth score.

The scale runs (eval/scale/README.md) send 1,500-1,600 items each through a real organizer. This tool
measures item-split alone on exactly the items such a run received, so a change to the skill or to its
deterministic rules can be compared without organizing the whole week again.

  fixture  ORGANIZER_DB OUT.json          what the organizer received (parent items, latest revision) and the
                                          split it stored (active item_segments). Read-only on the DB.
  directory ORGANIZER_DB OUT.json       the store's live events (handle, title, capture times of their items),
                                          so `run --directory` can show item-split the matters known at each
                                          item's time (known_matters) the way a live organizer would.
  run      FIXTURE OUT.json --llm-url U   Organizer.decide_split on every item, as the organizer calls it
           [--directory DIR.json]         (transcript parse, units, pre-filter, skill, validator, salvage,
                                          segments_from_output), without assignment. Threads share one endpoint.
                                          With --directory, known_matters = the largest events that had at least
                                          3 items captured before the item (their final titles); without it, none.
  score    FIXTURE SCENARIO IDMAP [PRED]  scores PRED (a `run` output), or the fixture's stored split without PRED.

Scoring (the same definitions as the 2026-09-29 scale report): the scenario's quotes (segments /
event_segments / event_spans / matter_segments with a quote) are located in the text the organizer received
and grouped by event; a quote whose event_id is null is an aside. An item with two or more matters should
be split. A matter is recovered when one predicted part (one to one) holds at least half of its quoted
characters; a part's purity is the share of quoted characters inside it that belong to its majority matter.
`single_matter_oversplit_rate` = items with fewer than two matters that were split / all such items. For a stored
split (a full run's database), oversplit_parts_in_several_events counts those whose parts were filed into two or more
events (the harmful kind: they seed fragments).
IDMAP maps the organizer's item ids to scenario item ids ({} or omitted when they are the same).
Synthetic data only.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Optional

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "spark"))


# ---- fixture ---------------------------------------------------------------------------------------

def _open(db: str):
    """A read-only connection to a synthetic run's store: plaintext (from before v6) or encrypted with the public
    synthetic key, through the organizer's one connection helper (organizer/db.py)."""
    from organizer import db as org_db
    c = org_db.open_for_analysis(db)
    c.row_factory = org_db.Row
    return c


def fixture(db: str) -> list[dict]:
    c = _open(db)
    children = {r["child_id"] for r in c.execute("SELECT child_id FROM item_segments")}
    parts: dict[str, list] = {}
    events_of: dict[str, set] = {}
    for r in c.execute("SELECT item_id, event_id FROM event_items WHERE removed = 0"):
        events_of.setdefault(r["item_id"], set()).add(r["event_id"])
    part_events: dict[str, list] = {}
    for r in c.execute('SELECT child_id, parent_id, start, "end", seg_id, gist, active, no_matter FROM item_segments'
                       " ORDER BY parent_id, seg_index"):
        if r["active"]:
            parts.setdefault(r["parent_id"], []).append([r["start"], r["end"], r["seg_id"], r["gist"], r["no_matter"]])
            part_events.setdefault(r["parent_id"], []).append(sorted(events_of.get(r["child_id"], set())))
    latest: dict[str, dict] = {}
    for r in c.execute("SELECT * FROM items"):
        if r["item_id"] in children:
            continue
        if r["item_id"] not in latest or r["revision"] > latest[r["item_id"]]["revision"]:
            latest[r["item_id"]] = dict(r)
    rows = []
    for iid, it in latest.items():
        d = c.execute("SELECT split, derived_text FROM item_derived WHERE item_id=? AND revision=?",
                      (iid, it["revision"])).fetchone()
        rows.append({"item_id": iid, "revision": it["revision"], "kind": it["kind"],
                     "source_app": json.loads(it["source_app"]), "started_at": it["started_at"], "text": it["text"],
                     "meta": json.loads(it["meta"]) if it["meta"] else None,
                     "derived_text": d["derived_text"] if d and it["kind"] == "file" else None,
                     "split": json.loads(d["split"]) if d and d["split"] else None,
                     "active_parts": parts.get(iid, []), "part_events": part_events.get(iid, [])})
    return rows


def directory(db: str) -> list[dict]:
    from datetime import datetime
    c = _open(db)
    ts = {r["item_id"]: r["t"] for r in c.execute("SELECT item_id, MIN(started_ts) AS t FROM items GROUP BY item_id")}
    out = []
    for e in c.execute("SELECT event_id, handle, title, anchor FROM events WHERE deleted = 0 AND handle IS NOT NULL"):
        times = sorted(ts[r["item_id"]] for r in c.execute(
            "SELECT DISTINCT item_id FROM event_items WHERE event_id=? AND removed=0", (e["event_id"],)) if r["item_id"] in ts)
        out.append({"id": f"E{e['handle']}", "order": e["handle"], "title": e["title"] or e["anchor"] or "", "times": times})
    return out


def known_at(events: list[dict], t: float, units_mod) -> list[dict]:
    import bisect
    return units_mod.known_matters([{"id": e["id"], "title": e["title"], "order": e["order"],
                                     "n": bisect.bisect_left(e["times"], t)} for e in events])


def _legacy(org, item: dict, derived: dict) -> dict:
    """The split decision of an organizer from before Organizer.decide_split (item-split <= 1.2.0): the same
    steps its split_plan took, without storing anything. Lets the benchmark measure the older code."""
    import copy
    units_mod = org._units
    text = org.organizing_text(item, derived)
    transcript = org.transcript_of(item)
    units = units_mod.build_units(text, transcript["turns"] if transcript else None) if text else []
    kind = "document" if item["kind"] == "file" else item["kind"]
    plan = {"segments": [], "matters": [], "known": [], "errors": [], "units": len(units)}
    if not text or not units_mod.prefilter(text, len(units), kind, transcript is not None):
        return dict(plan, status="prefilter")
    ids = [u["u"] for u in units]
    data = units_mod.build_data(kind, item["source_app"].get("name", ""), org._local(item["started_at"]), units,
                                transcript["format"] if transcript else "")
    schema = copy.deepcopy(org.registry.for_job("split").schema)
    for key in ("from", "to"):
        schema["properties"]["segments"]["items"]["properties"][key]["enum"] = ids
        schema["properties"]["segments"]["items"]["properties"][key].pop("pattern", None)
    res = org.harness.run("split", data, context={"unit_ids": ids}, schema=schema, subject=item["item_id"])
    out, status = (res.output, "applied") if res.ok else (None, "rejected")
    if out is None:
        validator = org.registry.for_job("split").validator
        out = units_mod.salvage(res.candidate, res.errors, lambda o: validator(o, {"unit_ids": ids}))
        status = "salvaged" if out else status
    segs = units_mod.segments_from_output(out, units) if out else []
    return dict(plan, segments=segs, matters=(out or {}).get("matters") or [], errors=res.errors, status=status)


# ---- run -------------------------------------------------------------------------------------------

def run(rows: list[dict], llm_url: str, threads: int, timeout: float, events: Optional[list] = None) -> dict:
    from organizer.clients import OpenAIChatClient
    from organizer.organizer import Organizer
    from organizer.skills import Harness, SkillRegistry
    from organizer.store import Store

    registry = SkillRegistry(ROOT / "skills")
    store = Store(":memory:")
    kwargs = {"consolidate": {"enabled": False}}
    try:
        org = Organizer(store, registry, Harness(registry, OpenAIChatClient(llm_url, "auto", timeout), store), None,
                        people={"enabled": False}, **kwargs)
    except TypeError:  # an organizer from before the people pass
        org = Organizer(store, registry, Harness(registry, OpenAIChatClient(llm_url, "auto", timeout), store), None,
                        **kwargs)

    units_mod = registry.script("item-split", "units")
    from datetime import datetime

    def one(row: dict) -> tuple[str, dict]:
        if row["kind"] == "image":
            return row["item_id"], {"status": "image"}
        item = {k: row[k] for k in ("item_id", "revision", "kind", "source_app", "started_at", "text")}
        derived = {"derived_text": row.get("derived_text")} if row["kind"] == "file" else {}
        known = known_at(events, datetime.fromisoformat(row["started_at"]).timestamp(), units_mod) if events else []
        t0 = time.time()
        plan = org.decide_split(item, derived, known=known) if hasattr(org, "decide_split") else _legacy(org, item, derived)
        return row["item_id"], {"status": plan["status"], "units": plan["units"], "matters": plan["matters"],
                                "known": plan.get("known") or [], "known_shown": len(known),
                                "parts": [[s["start"], s["end"], s["seg_id"], s["gist"], int(s.get("no_matter") or 0),
                                           s.get("matter")] for s in plan["segments"]],
                                "errors": plan["errors"], "seconds": round(time.time() - t0, 2)}

    with ThreadPoolExecutor(threads) as pool:
        preds = dict(pool.map(one, rows))
    skill = registry.skills["item-split"]
    return {"skill_version": skill.version, "prompt_hash": skill.prompt_hash, "model": org.harness.client.model_id,
            "predictions": preds}


# ---- score -----------------------------------------------------------------------------------------

def _gold_quotes(item: dict) -> list[dict]:
    extra = (item.get("event_segments") or []) + (item.get("event_spans") or []) + (item.get("matter_segments") or [])
    return [s for s in (item.get("segments") or []) + extra if "quote" in s]


def _overlap(a, b) -> int:
    return max(0, min(a[1], b[1]) - max(a[0], b[0]))


def score(rows: list[dict], scenario: dict, idmap: dict, parts_of: dict, stored: bool = False) -> dict:
    """parts_of: organizer item id -> [(start, end), ...] (fewer than two = not split). stored: the parts are the
    fixture's own stored split, so the events its parts were filed into (part_events) can be counted too."""
    rec = {r["item_id"]: r for r in rows}
    to_org = {v: k for k, v in idmap.items()} if idmap else {}
    st = {"items_scored": 0, "gold_multi": 0, "pred_multi": 0, "tp": 0, "fp": 0, "fn": 0, "tn": 0,
          "gold_matters_in_multi": 0, "matters_recovered": 0, "multi_all_recovered": 0,
          "pred_parts_in_multi": 0, "pred_parts_matched": 0, "skipped_quote_not_found": 0}
    purities: list[float] = []
    per_item: dict[str, dict] = {}
    for item in scenario["items"]:
        oid = to_org.get(item["item_id"], item["item_id"])
        r = rec.get(oid)
        if not r or r["kind"] == "image":
            continue
        text = r.get("text") or r.get("derived_text") or ""
        if not text:
            continue
        groups: dict[str, list] = {}
        ok = True
        for s in _gold_quotes(item):
            k = text.find(s["quote"])
            if k < 0:
                ok = False
                break
            groups.setdefault(s.get("event_id") or "_aside", []).append((k, k + len(s["quote"])))
        if not ok:
            st["skipped_quote_not_found"] += 1
            continue
        matters = {e: sp for e, sp in groups.items() if e != "_aside"}
        gm = len(matters) >= 2
        p = sorted(tuple(x[:2]) for x in parts_of.get(oid) or [])
        pm = len(p) >= 2
        parts = p if pm else [(0, len(text))]
        st["items_scored"] += 1
        if stored and (not gm) and pm and r.get("part_events") is not None and len(r.get("part_events") or []) >= 2:
            evs = [set(e) for e in r["part_events"] if not isinstance(e, int)]
            allev = set().union(*evs) if evs else set()
            st["oversplit_parts_filed"] = st.get("oversplit_parts_filed", 0) + 1
            st["oversplit_parts_in_several_events"] = st.get("oversplit_parts_in_several_events", 0) + (len(allev) > 1)
        st["gold_multi"] += gm
        st["pred_multi"] += pm
        st["tp"] += gm and pm
        st["fp"] += (not gm) and pm
        st["fn"] += gm and not pm
        st["tn"] += (not gm) and not pm
        per_item[oid] = {"scenario_id": item["item_id"], "gold_matters": len(matters), "pred_parts": len(p)}
        if not gm:
            continue
        tot = {e: sum(b - a for a, b in sp) for e, sp in matters.items()}
        cov = {(i, e): sum(_overlap(pp, x) for x in sp) for i, pp in enumerate(parts) for e, sp in matters.items()}
        pairs = sorted(((v, i, e) for (i, e), v in cov.items() if tot[e] and v >= 0.5 * tot[e]), reverse=True)
        used_i, used_e = set(), set()
        for _, i, e in pairs:
            if i not in used_i and e not in used_e:
                used_i.add(i)
                used_e.add(e)
        st["gold_matters_in_multi"] += len(matters)
        st["matters_recovered"] += len(used_e)
        st["multi_all_recovered"] += len(used_e) == len(matters)
        st["pred_parts_in_multi"] += len(parts)
        st["pred_parts_matched"] += len(used_i)
        if pm:
            for i in range(len(parts)):
                vals = [cov[(i, e)] for e in matters]
                if sum(vals) > 0:
                    purities.append(max(vals) / sum(vals))
    n = st["items_scored"]
    prec = st["tp"] / max(1, st["tp"] + st["fp"])
    rec_ = st["tp"] / max(1, st["tp"] + st["fn"])
    st.update({
        "single_matter_oversplit_rate": round(st["fp"] / max(1, st["fp"] + st["tn"]), 3),
        "split_decision_accuracy": round((st["tp"] + st["tn"]) / max(1, n), 3),
        "split_decision_precision": round(prec, 3),
        "split_decision_recall": round(rec_, 3),
        "split_decision_f1": round(2 * prec * rec_ / max(1e-9, prec + rec_), 3),
        "matter_recall_in_multi": round(st["matters_recovered"] / max(1, st["gold_matters_in_multi"]), 3),
        "part_precision_in_multi": round(st["pred_parts_matched"] / max(1, st["pred_parts_in_multi"]), 3),
        "multi_all_matters_recovered": round(st["multi_all_recovered"] / max(1, st["gold_multi"]), 3),
        "part_purity_mean": round(sum(purities) / len(purities), 3) if purities else None,
    })
    return {"summary": st, "items": per_item}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    f = sub.add_parser("fixture")
    f.add_argument("db")
    f.add_argument("out")
    d = sub.add_parser("directory")
    d.add_argument("db")
    d.add_argument("out")
    r = sub.add_parser("run")
    r.add_argument("fixture")
    r.add_argument("out")
    r.add_argument("--llm-url", default="http://127.0.0.1:8000/v1")
    r.add_argument("--threads", type=int, default=8)
    r.add_argument("--timeout", type=float, default=300.0)
    r.add_argument("--directory", help="events JSON from the `directory` command (known_matters at each item's time)")
    s = sub.add_parser("score")
    s.add_argument("fixture")
    s.add_argument("scenario")
    s.add_argument("idmap", nargs="?")
    s.add_argument("pred", nargs="?")
    s.add_argument("--out")
    args = ap.parse_args(argv)
    if args.cmd == "fixture":
        rows = fixture(args.db)
        Path(args.out).write_text(json.dumps(rows, ensure_ascii=False), encoding="utf-8")
        print(f"{len(rows)} items, {sum(1 for x in rows if len(x['active_parts']) >= 2)} stored as split")
        return 0
    if args.cmd == "directory":
        evs = directory(args.db)
        Path(args.out).write_text(json.dumps(evs, ensure_ascii=False), encoding="utf-8")
        print(f"{len(evs)} live events")
        return 0
    rows = json.loads(Path(args.fixture).read_text(encoding="utf-8"))
    if args.cmd == "run":
        t0 = time.time()
        events = json.loads(Path(args.directory).read_text(encoding="utf-8")) if args.directory else None
        out = run(rows, args.llm_url, args.threads, args.timeout, events)
        out["seconds"] = round(time.time() - t0, 1)
        Path(args.out).write_text(json.dumps(out, ensure_ascii=False), encoding="utf-8")
        statuses: dict[str, int] = {}
        for p in out["predictions"].values():
            statuses[p["status"]] = statuses.get(p["status"], 0) + 1
        print(json.dumps({"seconds": out["seconds"], "statuses": statuses, "skill_version": out["skill_version"]}))
        return 0
    scenario = json.loads(Path(args.scenario).read_text(encoding="utf-8"))
    idmap = json.loads(Path(args.idmap).read_text(encoding="utf-8")) if args.idmap else {}
    if args.pred:
        preds = json.loads(Path(args.pred).read_text(encoding="utf-8"))["predictions"]
        parts_of = {k: v.get("parts") or [] for k, v in preds.items()}
    else:
        parts_of = {x["item_id"]: x["active_parts"] for x in rows}
    result = score(rows, scenario, idmap, parts_of, stored=not args.pred)
    if args.out:
        Path(args.out).write_text(json.dumps(result, ensure_ascii=False, indent=1), encoding="utf-8")
    print(json.dumps(result["summary"]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
